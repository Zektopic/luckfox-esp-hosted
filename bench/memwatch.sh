#!/bin/sh
# Run a command on the Luckfox and record CPU and memory while it runs.
#   memwatch.sh <label> <command...>
# Prints the command's output, then one summary line:
#   label, exact wall time, the command's own CPU % (its utime+stime, read from this shell's
#   cutime/cstime after reaping it), system-wide CPU busy %, peak drops in MemAvailable and in the
#   media DMA heap, the command's peak RSS (VmHWM), NPU load peak, SoC temperature start/end.
# Media buffers (encoder, NPU, ISP, RGA) come from the 66 MB rk_dma_heap_cma region (kernel cmdline
# rk_dma_heap_cma=66M). It is reserved at boot and NOT part of MemTotal, so these allocations barely
# move MemAvailable: watch dma_heap_peak (/proc/rk_dma_heap/alloc_bitmap "Used:") instead.
# Timing: the start is stamped right before exec, the end when `wait` returns (no polling delay).
# Sampling (every 0.5 s, in a background subshell) uses shell builtins only: a fork-per-sample loop
# cost ~55 % of this single Cortex-A7 by itself.
LABEL=$1; shift
LOG=/tmp/memwatch.$$; TF=$LOG.t; SF=$LOG.s
INTERVAL=0.5

# helpers set globals instead of echoing: $(...) forks a subshell in ash
avail() { while read -r k v _; do [ "$k" = MemAvailable: ] && { A=$v; return; }; done < /proc/meminfo; }
heap()  { while read -r k v _; do [ "$k" = Used: ] && { H=$v; return; }; done < /proc/rk_dma_heap/alloc_bitmap; }
cpu()   { read -r _ u n s i w q sq _ < /proc/stat; CB=$((u + n + s + q + sq + w)); CI=$i; }   # busy idle (jiffies)
temp()  { read -r t < /sys/class/thermal/thermal_zone0/temp; T=$((t / 1000)); }
up()    { read -r U _ < /proc/uptime; }
childcpu() { read -r st < /proc/$$/stat; set -- ${st#*) }; CC=$((${14} + ${15})); }   # cutime + cstime (fields 16, 17)

avail; A0=$A; heap; H0=$H; temp; T0=$T; cpu; CB0=$CB; CI0=$CI; childcpu; CC0=$CC
( read -r t _ < /proc/uptime; echo $t > $TF; exec "$@" ) > $LOG 2>&1 &
PID=$!
(
    amin=$A0; hmax=$H0; hwm=0; npu=0
    while kill -0 $PID 2> /dev/null; do
        avail; heap
        [ "$A" -lt "$amin" ] && amin=$A
        [ "$H" -gt "$hmax" ] && hmax=$H
        while read -r k v _; do [ "$k" = VmHWM: ] && [ "$v" -gt "$hwm" ] && hwm=$v; done < /proc/$PID/status 2> /dev/null
        read -r l < /proc/rknpu/load 2> /dev/null; l=${l#*load:}; l=${l%%%*}; l=${l# }
        [ -n "$l" ] && [ "$l" -gt "$npu" ] 2> /dev/null && npu=$l
        echo "$amin $hmax $hwm $npu" > $SF
        sleep $INTERVAL
    done
) &
SPID=$!
wait $PID; RC=$?
up; S1=$U
childcpu; CC1=$CC; cpu; temp; T1=$T
kill $SPID 2> /dev/null; wait $SPID 2> /dev/null
read -r S0 < $TF
read -r amin hmax hwm npu < $SF 2> /dev/null || { amin=$A0; hmax=$H0; hwm=0; npu=0; }
cat $LOG; rm -f $LOG $TF $SF
echo "$CB0 $CI0 $CB $CI" | awk -v l="$LABEL" -v s0=$S0 -v s1=$S1 -v rc=$RC -v da=$((A0 - amin)) -v dh=$((hmax - H0)) \
    -v hwm=$hwm -v npu=$npu -v t0=$T0 -v t1=$T1 -v pc=$((CC1 - CC0)) \
    '{busy=$3-$1; idle=$4-$2; w=s1-s0;
      printf "MEMWATCH %s: rc=%d wall=%.2fs proc_cpu=%.0f%% sys_cpu_busy=%.0f%% memavail_drop=%.1fMB dma_heap_peak=%.1fMB rss_peak=%.1fMB npu_load_peak=%d%% temp=%d->%dC\n",
             l, rc, w, pc/w, 100*busy/(busy+idle), da/1024, dh/1024, hwm/1024, npu, t0, t1}'
