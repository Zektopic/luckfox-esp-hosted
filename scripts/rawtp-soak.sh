#!/bin/sh
# SDIO bus check without Wi-Fi in the loop: runs ESP-Hosted's raw throughput test for a while
# and counts SDIO CRC (-84) / timeout (-110) errors. Runs ON the Luckfox:
#   ssh luckfox 'sh -s' < scripts/rawtp-soak.sh <mode> <seconds> [clock_hz]
#   mode 1 = Luckfox -> C6 (host TX), mode 2 = C6 -> Luckfox (host RX, the direction Wi-Fi RX uses)
# Stop the Wi-Fi service first (esp-hosted.sh stop), or its watchdog will reload the driver mid-test.
MODE=${1:-2}
SECS=${2:-180}
CLOCK=${3:-}
D=ff9a0000.mmc
DRV=/sys/bus/platform/drivers/dwmmc_rockchip
KO=/oem/usr/ko

rmmod esp32_sdio 2> /dev/null
mount | grep -q debugfs || mount -t debugfs none /sys/kernel/debug
sleep 1
echo $D > $DRV/unbind; sleep 1; echo $D > $DRV/bind; sleep 2
H=$(basename "$(ls -d /sys/bus/platform/devices/$D/mmc_host/mmc* | head -1)")
[ -n "$CLOCK" ] && echo "$CLOCK" > /sys/kernel/debug/$H/clock
for m in cfg80211 libaes ecc ecdh_generic bluetooth; do
    grep -q "^$m " /proc/modules || insmod $KO/$m.ko
done
MARK="rawtp-soak mode=$MODE secs=$SECS clock=${CLOCK:-default} $(date +%s)"
logger -t rawtp "$MARK"
echo "== $MARK, host $H"
insmod /userdata/esp-hosted/esp32_sdio.ko raw_tp_mode=$MODE radio_service=none
# keep dhcpcd off the test interface: an address on it makes the driver send a "set IP" command the
# C6 can't answer while it is busy with raw throughput -> command timeout -> the driver resets the C6
sleep 1; IF=$(ls /sys/class/net | grep -m1 '^wlan'); [ -n "$IF" ] && dhcpcd -x "$IF" > /dev/null 2>&1
sleep 2
echo "== bus: $(grep -E '^(actual clock|bus width|timing spec)' /sys/kernel/debug/$H/ios | tr -s '\t' ' ' | tr '\n' ' ')"
sleep "$SECS"
rmmod esp32_sdio
sleep 1
# everything the kernel logged since the marker (syslog keeps more than the small dmesg ring)
sed -n "/$MARK/,\$p" /var/log/messages > /tmp/rawtp.log
echo "== errors -84: $(grep -c 'ret=-84' /tmp/rawtp.log)  -110: $(grep -c 'ret=-110' /tmp/rawtp.log)  recover failed: $(grep -c 'recover failed' /tmp/rawtp.log)"
echo "== first error: $(grep -m1 -E 'ret=-84|ret=-110' /tmp/rawtp.log | cut -c1-160)"
grep -iE 'mbps|mbit|throughput' /tmp/rawtp.log | tail -4 | cut -c1-160
