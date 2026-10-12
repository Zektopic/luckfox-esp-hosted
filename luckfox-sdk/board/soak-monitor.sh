#!/bin/sh
# Luckfox side of the Wi-Fi soak test (runs ON the Luckfox, detached):
#   setsid nohup /userdata/esp-hosted/soak-monitor.sh <peer_ip> [hours] > /dev/null 2>&1 < /dev/null &
# - keeps an iperf3 server listening on the current wlan IPv4 (restarts it if it dies or the IP changes)
# - pins the route to <peer_ip> to wlan0 (eth0 may be on the same subnet)
# - logs board/Wi-Fi health once a minute -> /userdata/esp-hosted/soak/monitor.csv
# The traffic itself is driven from the peer by scripts/soak-orchestrator.sh (iperf3 client, both directions).
# Note: run the iperf3 *client* on the peer: iperf3 3.14 on the Luckfox fails reverse mode with
# "unable to receive results: Cannot allocate memory".

PEER=${1:?usage: $0 <peer_ip> [hours]}
HOURS=${2:-3}
TOTAL_S=${TOTAL_S:-$((HOURS * 3600 + 600))}     # a little longer than the orchestrator
OUT=/userdata/esp-hosted/soak
CSV=$OUT/monitor.csv
mkdir -p $OUT
END=$(( $(cut -d. -f1 /proc/uptime) + TOTAL_S ))
[ -f $CSV ] || echo "time,uptime_s,iface,ipv4,wpa_state,rssi_dbm,tx_mbytes,rx_mbytes,sdio_err_84,recover_failed,iperf3_srv,temp_c,mem_avail_kb" > $CSV
echo "monitor start $(date '+%F %T %z') peer=$PEER" >> $OUT/monitor.status
SRV_IP=""

while [ "$(cut -d. -f1 /proc/uptime)" -lt "$END" ]; do
    IF=$(ls /sys/class/net | grep -m1 '^wlan')
    IP=""
    [ -n "$IF" ] && IP=$(ip -4 addr show "$IF" | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | grep -v '^169\.254' | head -1)
    if [ -n "$IP" ]; then
        ip route replace "$PEER/32" dev "$IF" src "$IP" 2> /dev/null
        if ! pidof iperf3 > /dev/null || [ "$IP" != "$SRV_IP" ]; then
            killall iperf3 2> /dev/null
            iperf3 -s -D -B "$IP" --logfile $OUT/iperf3-server.log
            SRV_IP=$IP
        fi
    fi
    S=/sys/class/net/$IF/statistics
    tx=$(( $(cat $S/tx_bytes 2> /dev/null || echo 0) / 1048576 ))
    rx=$(( $(cat $S/rx_bytes 2> /dev/null || echo 0) / 1048576 ))
    rssi=$(iw dev "$IF" link 2> /dev/null | sed -n 's/.*signal: \(-[0-9]*\).*/\1/p')
    st=$(/usr/sbin/wpa_cli -i "$IF" status 2> /dev/null | sed -n 's/^wpa_state=//p')
    e84=$(dmesg | grep -c 'ret=-84')
    rf=$(dmesg | grep -c 'recover failed')
    srv=$(pidof iperf3 > /dev/null && echo up || echo down)
    t=$(( $(cat /sys/class/thermal/thermal_zone0/temp 2> /dev/null || echo 0) / 1000 ))
    mf=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    echo "$(date '+%F %T'),$(cut -d. -f1 /proc/uptime),$IF,$IP,$st,$rssi,$tx,$rx,$e84,$rf,$srv,$t,$mf" >> $CSV
    sleep 60
done
killall iperf3 2> /dev/null
echo "monitor done $(date '+%F %T %z')" >> $OUT/monitor.status
