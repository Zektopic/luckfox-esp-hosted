#!/usr/bin/env bash
# Peer side of the Wi-Fi soak test. Runs on the Linux build PC (ssh luckfox-build), detached:
#   setsid nohup ~/luckfox/soak-orchestrator.sh <luckfox_wlan_ip> [hours] [segment_s] > /dev/null 2>&1 < /dev/null &
# Alternates iperf3 TCP segments against the iperf3 server on the Luckfox (started by soak-monitor.sh):
#   odd  segments: "up"   = Luckfox -> peer   (client -R: the Luckfox sends)
#   even segments: "down" = peer -> Luckfox
# Results: ~/luckfox/soak/<start>/results.csv (+ seg-NNN.txt raw iperf3 output). Uses the
# networkstatic/iperf3 Docker image, so nothing needs installing on the build PC.
set -u
LF=${1:?usage: $0 <luckfox_wlan_ip> [hours] [segment_s]}
HOURS=${2:-3}
SEG=${3:-600}
TOTAL_S=${TOTAL_S:-$((HOURS * 3600))}
DIR=$HOME/luckfox/soak/$(date +%Y%m%d-%H%M%S)
mkdir -p "$DIR"
ln -sfn "$DIR" "$HOME/luckfox/soak/latest"
CSV=$DIR/results.csv
echo "time,segment,direction,result,mbps_receiver,mbps_sender,retransmits,mbytes" > "$CSV"
echo "start $(date '+%F %T %z') luckfox=$LF hours=$HOURS segment=${SEG}s" > "$DIR/status"

END=$(( $(date +%s) + TOTAL_S ))
n=0
while [ "$(date +%s)" -lt "$END" ]; do
    n=$((n + 1))
    left=$(( END - $(date +%s) )); dur=$SEG; [ $left -lt $dur ] && dur=$left; [ $dur -lt 10 ] && break
    if [ $((n % 2)) -eq 1 ]; then d=up; extra=-R; else d=down; extra=; fi
    f=$DIR/seg-$(printf %03d $n)-$d.txt
    docker run --rm --network host networkstatic/iperf3:latest -c "$LF" -f m -t "$dur" -i 60 $extra > "$f" 2>&1
    snd=$(grep -E ' sender$' "$f" | tail -1)
    rcv=$(grep -E ' receiver$' "$f" | tail -1)
    if [ -n "$rcv" ]; then
        res=ok
        mr=$(awk '{for(i=1;i<=NF;i++) if($i=="Mbits/sec") print $(i-1)}' <<< "$rcv")
        ms=$(awk '{for(i=1;i<=NF;i++) if($i=="Mbits/sec") print $(i-1)}' <<< "$snd")
        rt=$(awk '{for(i=1;i<=NF;i++) if($i=="Mbits/sec") print $(i+1)}' <<< "$snd")
        mb=$(awk '{for(i=1;i<=NF;i++){ if($i=="MBytes") print $(i-1); if($i=="KBytes") print $(i-1)/1024; if($i=="GBytes") print $(i-1)*1024 }}' <<< "$rcv" | head -1)
    else
        res=fail; mr=0; ms=0; rt=; mb=0
        sleep 15     # Wi-Fi reconnecting / server restarting
    fi
    echo "$(date '+%F %T'),$n,$d,$res,$mr,$ms,$rt,$mb" >> "$CSV"
done
echo "done $(date '+%F %T %z') segments=$n" >> "$DIR/status"
