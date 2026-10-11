#!/bin/sh
# Load ESP-Hosted-Linux (ESP32-C6 over SDIO) on the Luckfox Pico Max, built from luckfox-sdk/ on 2026-10-11.
# Copy esp32_sdio.ko + this script to the board, e.g.:
#   adb shell mkdir -p /userdata/esp-hosted
#   adb push esp32_sdio.ko esp-hosted-load.sh /userdata/esp-hosted/
#   adb shell sh /userdata/esp-hosted/esp-hosted-load.sh            # Wi-Fi only
#   adb shell sh /userdata/esp-hosted/esp-hosted-load.sh bt         # Wi-Fi + BLE (HCI over SDIO)
#
# cfg80211.ko, bluetooth.ko and their crypto deps ship in the image under /oem/usr/ko/ (no modprobe/depmod index,
# so everything is insmod'ed by path, in dependency order):
#   esp32_sdio -> cfg80211, bluetooth;  bluetooth -> libaes, ecdh_generic;  ecdh_generic -> ecc.
# The C6 must already be powered and wired (header pins 21-27) when the kernel boots: &sdio probes at boot.

KO=/oem/usr/ko
HERE=$(cd "$(dirname "$0")" && pwd)
SERVICE=${1:-none}          # none | bt   (radio_service, see esp-hosted-linux docs)

loaded() { grep -q "^$(basename "$1" .ko) " /proc/modules; }
load() {      # required: stop on failure
    if loaded "$1"; then echo "  $(basename "$1") already loaded"; return 0; fi
    echo "  insmod $*"
    insmod "$@" || { echo "FAILED: insmod $*"; exit 1; }
}
try_load() {  # optional: warn and continue
    [ -f "$1" ] || { echo "  (missing $1)"; return 0; }
    loaded "$1" || { echo "  insmod $1"; insmod "$1" || echo "  warning: insmod $1 failed"; }
}

# ESP32-C5/C6/C61 enumerate as SDIO vendor 0x0092, device 0x6666 (or 0x7777); see host/sdio/esp_sdio_decl.h.
echo "--- SDIO devices before loading (expect SDIO_ID=0092:6666 for the C6):"
for d in /sys/bus/sdio/devices/*; do [ -e "$d/uevent" ] && cat "$d/uevent"; done

echo "--- loading modules"
load $KO/cfg80211.ko
load $KO/libaes.ko
load $KO/ecc.ko
load $KO/ecdh_generic.ko
if [ "$SERVICE" = "bt" ]; then
    # BT SMP asks the crypto API for ecb(aes), cmac(aes) and an RNG when hci0 registers; without a modprobe
    # index the kernel can't auto-load them, so load them up front.
    for m in hmac jitterentropy_rng drbg ecb cmac; do try_load $KO/$m.ko; done
fi
load $KO/bluetooth.ko
load "$HERE/esp32_sdio.ko" radio_service="$SERVICE"

sleep 2
echo "--- result"
grep -E "^(esp32_sdio|cfg80211|bluetooth) " /proc/modules
dmesg | grep -i -E "esp|sdio|mmc" | tail -n 25
iw dev
ip link | grep -A1 wlan

cat <<'EOF'
--- next (Wi-Fi station):
  Use the Buildroot wpa_supplicant v2.10 in /usr/sbin. /usr/bin/wpa_supplicant is Rockchip's old v2.6 and comes first in PATH.
  /usr/sbin/wpa_supplicant -B -D nl80211 -i wlan0 -c /etc/wpa_supplicant.conf     (adjust wlanX / conf)
  dhcpcd wlan0   (or: udhcpc -i wlan0)
EOF
