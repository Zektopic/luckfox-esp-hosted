#!/bin/sh
# ALPR-shaped load on the Luckfox: NPU (YOLOv5 640) and the hardware encoder at the same time.
#   scp bench/memwatch.sh bench/combined-bench.sh <rknn_bench> <yolov5.rknn> luckfox:/tmp/
#   ssh luckfox 'sh /tmp/combined-bench.sh [seconds=20] [codec=7|16777220] [WxH=2304x1296]'
# Three memwatch instances: one per workload (own CPU, own latency/fps) and a "system" one that only
# sleeps, to capture the combined peak of the media DMA heap and the MemAvailable low point.
SECS=${1:-20}
T=${2:-7}
RES=${3:-2304x1296}
W=${RES%x*}; H=${RES#*x}
export LD_LIBRARY_PATH=/oem/usr/lib
cd /tmp
FRAMES=$((SECS * 40))   # more than the encoder can do in SECS; it is stopped when the NPU run ends
echo "combined start $(date '+%F %T') secs=$SECS codec=$T res=$RES"
./memwatch.sh "system (both running)" sleep $((SECS + 2)) > /tmp/cb-sys.log 2>&1 &
S=$!
./memwatch.sh "npu yolov5 (with encoder)" ./rknn_bench /tmp/yolov5.rknn 0 5 $SECS > /tmp/cb-npu.log 2>&1 &
N=$!
./memwatch.sh "venc $RES t=$T (with NPU)" /oem/usr/bin/mpi_enc_test -w $W -h $H -t $T -n $FRAMES -o /dev/null > /tmp/cb-enc.log 2>&1 &
E=$!
wait $N
killall -INT mpi_enc_test 2> /dev/null; sleep 1; killall mpi_enc_test 2> /dev/null
wait $E; wait $S
grep -E '^NPU|MEMWATCH' /tmp/cb-npu.log
n=$(grep -c 'frame_count' /tmp/cb-enc.log); w=$(sed -n 's/.*wall=\([0-9.]*\)s.*/\1/p' /tmp/cb-enc.log)
grep MEMWATCH /tmp/cb-enc.log | awk -v n=$n -v w=$w '{printf "%s frames=%d fps=%.1f\n", $0, n, n/w}'
grep MEMWATCH /tmp/cb-sys.log
rm -f /tmp/cb-*.log
echo "combined end $(date '+%F %T')"
