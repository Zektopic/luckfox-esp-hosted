#!/bin/sh
# Hardware video encoder benchmark (RV1106 VEPU) with Rockchip's mpi_enc_test (MPP), runs ON the Luckfox:
#   scp bench/memwatch.sh bench/venc-bench.sh luckfox:/tmp/ && ssh luckfox 'sh /tmp/venc-bench.sh [frames]'
# No camera needed: without -i, mpi_enc_test generates its own test frames (on the CPU).
# fps = frames / (wall time of an N-frame run - wall time of a 1-frame run), i.e. without start-up.
# Output to /dev/null; CPU and memory via memwatch.sh.
N=${1:-300}
export LD_LIBRARY_PATH=/oem/usr/lib
ENC=/oem/usr/bin/mpi_enc_test
W=/tmp/memwatch.sh
echo "venc-bench start $(date '+%F %T') frames=$N armclk=$(awk '/ armclk /{print $5/1e6}' /sys/kernel/debug/clk/clk_summary 2>/dev/null)MHz vepu=$(awk '/ clk_core_vepu /{print $5/1e6}' /sys/kernel/debug/clk/clk_summary 2>/dev/null)MHz"
for codec in h264:7 h265:16777220; do
    name=${codec%%:*}; t=${codec#*:}
    for res in 2304x1296 1920x1080 1280x720; do
        w=${res%x*}; h=${res#*x}
        one=$($W x $ENC -w $w -h $h -t $t -n 1 -o /dev/null | sed -n 's/.*wall=\([0-9.]*\)s.*/\1/p')
        line=$($W "$name $res" $ENC -w $w -h $h -t $t -n $N -o /dev/null | tee /tmp/venc-last.log | grep '^MEMWATCH')
        bps=$(sed -n 's/.*total frame [0-9]* bps \([0-9]*\).*/\1/p' /tmp/venc-last.log)
        wall=$(echo "$line" | sed -n 's/.*wall=\([0-9.]*\)s.*/\1/p')
        echo "$line" | awk -v n=$N -v w=$wall -v o=$one -v b=$bps \
            '{printf "%s fps=%.1f (init %.1fs) bitrate=%.1fMbit/s\n", $0, n/(w-o), o, b/1e6}'
    done
done
echo "venc-bench end $(date '+%F %T')"
