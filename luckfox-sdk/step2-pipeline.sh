#!/usr/bin/env bash
# Runs detached on the build PC (ssh luckfox-build) after the stock build:
#   setsid nohup ~/luckfox/changes/step2-pipeline.sh > ~/luckfox/logs/02-pipeline.log 2>&1 < /dev/null &
# 1) save the stock image as a known-good fallback, 2) apply the ESP-Hosted changes (modules),
# 3) rebuild everything, 4) build esp32_sdio.ko, 5) run checks that don't need the board.
# Never flashes anything.
set -uo pipefail

C=luckfox-sdk
SDK=/luckfox/luckfox-pico
H=$HOME/luckfox
step() { echo; echo "===== [$(date '+%H:%M:%S')] $* ====="; }
inc() { docker exec -w "$SDK" "$C" bash -c "$*"; }

step "wait for the previous chown to finish"
# pgrep -x matches the process NAME only. (pgrep -f on "chown -R ..." also matched an orphaned shell whose
# own command line contained that text, and waited on it forever on 2026-10-11.)
while pgrep -x chown >/dev/null; do sleep 10; done

step "1. save stock image -> ~/luckfox/out/stock-image"
if [ ! -f "$H/out/stock-image/update.img" ]; then
    mkdir -p "$H/out/stock-image"
    inc "cp -a output/image/. /luckfox/out/stock-image/ && cd /luckfox/out/stock-image && sha256sum *.img download.bin > SHA256SUMS.txt"
fi
ls -la "$H/out/stock-image"

step "2. apply ESP-Hosted changes (m = cfg80211/BT as modules)"
inc "/luckfox/changes/apply-esp-hosted-changes.sh m" || { echo "apply failed"; echo "PIPELINE_EXIT=1"; exit 1; }

step "3. rebuild: ./build.sh all"
inc "./build.sh all" > "$H/logs/02-esp-hosted-all.log" 2>&1
rc=$?
tail -n 3 "$H/logs/02-esp-hosted-all.log"
echo "build.sh all exit=$rc"
[ $rc -eq 0 ] || { echo "PIPELINE_EXIT=$rc"; exit $rc; }

step "4. build esp32_sdio.ko"
inc "/luckfox/changes/build-esp-hosted-ko.sh" || { echo "ko build failed"; echo "PIPELINE_EXIT=4"; exit 4; }

step "5. checks"
inc '
set -u
echo "--- boot.img size vs 4 MiB boot partition"
s=$(stat -c %s output/image/boot.img); echo "boot.img=$s bytes, partition=4194304, headroom=$((4194304 - s))"
echo "--- DTB: SDIO controller"
dtb=$(find sysdrv/source/objs_kernel/arch/arm/boot/dts -name rv1106g-luckfox-pico-pro-max.dtb)
dtc -q -I dtb -O dts "$dtb" | grep -A 30 "mmc@ff9a0000 {" | grep -E "mmc@ff9a0000|status|bus-width|max-frequency|non-removable|cap-sdio-irq|no-1-8-v|pinctrl-0"
echo "--- kernel .config"
grep -E "^CONFIG_(CFG80211|BT|MMC_DW_ROCKCHIP|PWRSEQ_SIMPLE|MODULES)=" sysdrv/source/objs_kernel/.config
echo "--- kernel modules built (cfg80211 / bluetooth)"
find sysdrv/source/objs_kernel -name "cfg80211.ko" -o -name "bluetooth.ko" | xargs -r ls -la
echo "--- where the image put them"
find output/out -name "cfg80211.ko" -o -name "bluetooth.ko" -o -name "esp32_sdio.ko" 2>/dev/null
echo "--- userspace Wi-Fi tools in the rootfs"
find output/out/rootfs_uclibc_rv1106 \( -name wpa_supplicant -o -name wpa_cli -o -name iw \) 2>/dev/null
echo "--- esp32_sdio.ko"
ls -la /luckfox/out/esp32_sdio.ko && grep -E "^(vermagic|depends|version)=" /luckfox/out/esp32_sdio.modinfo.txt && cat sysdrv/source/objs_kernel/include/config/kernel.release
echo "--- final image"
ls -la output/image/
'

step "6. save esp-hosted image -> ~/luckfox/out/esp-hosted-image"
mkdir -p "$H/out/esp-hosted-image"
inc "cp -a output/image/. /luckfox/out/esp-hosted-image/ && cd /luckfox/out/esp-hosted-image && sha256sum *.img download.bin > SHA256SUMS.txt"
# cfg80211.ko / bluetooth.ko (stripped) next to esp32_sdio.ko, for loading by hand if the image doesn't ship them.
inc 'X=tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf/bin/arm-rockchip830-linux-uclibcgnueabihf-
for m in net/wireless/cfg80211.ko net/bluetooth/bluetooth.ko; do
    test -f sysdrv/source/objs_kernel/$m && ${X}strip --strip-debug -o /luckfox/out/$(basename $m) sysdrv/source/objs_kernel/$m
done; ls -la /luckfox/out/*.ko'
inc "git status --short -- sysdrv/source/kernel project/cfg sysdrv/tools/board/buildroot; git diff -- sysdrv/source/kernel project/cfg sysdrv/tools/board/buildroot > /luckfox/out/esp-hosted-sdk.diff"

step "give files back to $(id -un)"
docker exec "$C" chown -R "$(id -u):$(id -g)" /luckfox/out /luckfox/logs
echo "PIPELINE_EXIT=0"
