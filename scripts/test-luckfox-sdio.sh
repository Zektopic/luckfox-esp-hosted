#!/usr/bin/env bash
# One bring-up test round: ESP32-C6 (ESP-Hosted, SDIO) <-> Luckfox Pico Max.
# Run from the work folder in Git Bash:   scripts/test-luckfox-sdio.sh <name> [clock_hz]
#   - resets the C6 over COM4 and records its console      -> logs/test-<name>-c6.log
#   - on the Luckfox (ssh luckfox): unload esp32_sdio, unbind/bind the SDIO host (forces a fresh
#     card detection), optionally set the bus clock, load the modules, run a Wi-Fi scan
#                                                          -> logs/test-<name>-luckfox.log
#   - prints a PASS/FAIL summary
set -u
NAME=${1:?usage: $0 <name> [clock_hz]}
CLOCK=${2:-}
PY=/c/Espressif/tools/python/v5.5.4/venv/Scripts/python.exe   # any Python with pyserial
C6LOG=logs/test-$NAME-c6.log
LFLOG=logs/test-$NAME-luckfox.log

ssh -o BatchMode=yes luckfox 'rmmod esp32_sdio 2>/dev/null; true'
"$PY" -I scripts/serial_capture.py --port COM4 --seconds 35 --out "$C6LOG" > /dev/null 2>&1 &
CAP=$!
sleep 3   # C6 reaches "FW_SDIO_SLAVE: Using SDIO interface" ~0.8 s after reset

ssh -o BatchMode=yes luckfox "CLOCK='$CLOCK' sh -s" > "$LFLOG" 2>&1 <<'EOF'
D=ff9a0000.mmc
mount | grep -q debugfs || mount -t debugfs none /sys/kernel/debug
echo $D > /sys/bus/platform/drivers/dwmmc_rockchip/unbind; sleep 1
echo $D > /sys/bus/platform/drivers/dwmmc_rockchip/bind;   sleep 2
H=$(basename $(ls -d /sys/bus/platform/devices/$D/mmc_host/mmc* | head -1))
dmesg -c > /dev/null
[ -n "$CLOCK" ] && echo "$CLOCK" > /sys/kernel/debug/$H/clock
echo "== host $H: $(grep -E '^actual clock' /sys/kernel/debug/$H/ios | tr -s '\t' ' '), $(grep timing /sys/kernel/debug/$H/ios | tr -s '\t' ' ')"
echo "== sdio: $(cat /sys/bus/sdio/devices/*/uevent 2>/dev/null | grep SDIO_ID | tr '\n' ' ')"
for m in cfg80211 libaes ecc ecdh_generic bluetooth; do
    grep -q "^$m " /proc/modules || insmod /oem/usr/ko/$m.ko
done
insmod /userdata/esp-hosted/esp32_sdio.ko radio_service=none
sleep 5
IF=$(ls /sys/class/net | grep -m1 '^wlan')
echo "== iface: ${IF:-none}"
if [ -n "$IF" ]; then
    ip link set "$IF" up 2>&1
    sleep 1
    n=$(iw dev "$IF" scan 2>&1 | tee /tmp/scan.txt | grep -c '^BSS ')
    echo "== scan BSS count: $n"
    grep -E 'SSID:' /tmp/scan.txt | head -5
    head -3 /tmp/scan.txt | grep -i -E 'fail|error|busy' || true
fi
echo "== dmesg"
dmesg | grep -i -E 'esp32_sdio|mmc' | grep -v -E 'print_capabilities|print_ext_cap|Boot-up Event tag|get_firmware_data|CIS tuple'
EOF

wait $CAP
errs=$(grep -c -E 'ret=-84|ret=-110|failed with error|recover failed' "$LFLOG")
bss=$(sed -n 's/^== scan BSS count: //p' "$LFLOG")
echo "---------------- test $NAME ----------------"
grep -E '^== (host|sdio|iface|scan)' "$LFLOG"
echo "transport errors in dmesg: $errs"
echo "C6 console (after SDIO init):"
tr -d '\r' < "$C6LOG" | grep -v '^$' | sed -n '/Using SDIO interface/,$p' | grep -v -E 'wifi_init:|Init (data|static|dynamic|management)' | head -25
if [ "${errs:-1}" = "0" ] && [ "${bss:-0}" -gt 0 ] 2>/dev/null; then echo "RESULT: PASS ($bss networks seen)"; else echo "RESULT: FAIL"; fi
