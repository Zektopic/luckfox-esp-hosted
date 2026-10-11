#!/usr/bin/env bash
# Build the ESP-Hosted-Linux host driver (esp32_sdio.ko) against the Luckfox SDK kernel.
# Run inside the SDK container from the SDK root, AFTER the kernel with esp-hosted.config is built:
#   ~/luckfox/lf.sh run /luckfox/changes/build-esp-hosted-ko.sh
# Output: /luckfox/out/esp32_sdio.ko (+ modinfo), i.e. ~/luckfox/out on the build PC.
set -euo pipefail

SDK=$(pwd)
HOSTED=/luckfox/esp-hosted-linux/host
OUT=/luckfox/out
CROSS=$SDK/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf/bin/arm-rockchip830-linux-uclibcgnueabihf-

# The kernel is built out-of-tree (make O=...). Its output dir is the one with Module.symvers + .config.
KDIR=$(dirname "$(find "$SDK/sysdrv" -name Module.symvers -path '*kernel*' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2)")
test -f "$KDIR/.config" || { echo "kernel build dir not found (build the kernel first)"; exit 1; }
echo "KERNEL build dir: $KDIR"
echo "kernel release:   $(cat "$KDIR/include/config/kernel.release")"
for opt in CONFIG_CFG80211 CONFIG_BT CONFIG_MMC_DW_ROCKCHIP CONFIG_MODULES CONFIG_PWRSEQ_SIMPLE; do
    printf '  %-24s %s\n' "$opt" "$(grep -E "^$opt=|^# $opt is not set" "$KDIR/.config" || echo 'not present')"
done
grep -qE '^CONFIG_CFG80211=(y|m)' "$KDIR/.config" || { echo "CONFIG_CFG80211 missing in kernel .config"; exit 1; }
grep -qE '^CONFIG_BT=(y|m)' "$KDIR/.config" || { echo "CONFIG_BT missing in kernel .config"; exit 1; }

git -C "$HOSTED" log -1 --format='esp-hosted-linux: %h %s'
# Local patches on top of 172a719 (idempotent). 0001: import the VFS symbol namespace, needed on
# Rockchip's Android-derived 5.10 kernel for filp_open()/kernel_read() (host-side OTA).
for p in /luckfox/changes/patches/*.patch; do
    [ -e "$p" ] || continue
    if git -C "$HOSTED" apply --reverse --check "$p" 2>/dev/null; then
        echo "patch already applied: $(basename "$p")"
    else
        git -C "$HOSTED" apply "$p" && echo "patch applied: $(basename "$p")"
    fi
done
make -C "$HOSTED" target=sdio ARCH=arm CROSS_COMPILE="$CROSS" KERNEL="$KDIR"

mkdir -p "$OUT"
# The SDK image has no modinfo (kmod); read the .modinfo section with the cross objcopy instead.
modinfo_of() { "${CROSS}objcopy" -O binary --only-section=.modinfo "$1" /dev/stdout | tr '\0' '\n' | grep -v '^$'; }
cp -f "$HOSTED/esp32_sdio.ko" "$OUT/esp32_sdio.debug.ko"                       # with debug info (~3.6 MB)
"${CROSS}strip" --strip-debug -o "$OUT/esp32_sdio.ko" "$HOSTED/esp32_sdio.ko"   # for the board
ls -la "$OUT"/esp32_sdio*.ko
modinfo_of "$OUT/esp32_sdio.ko" | tee "$OUT/esp32_sdio.modinfo.txt"
mod_rel=$(sed -n 's/^vermagic=//p' "$OUT/esp32_sdio.modinfo.txt" | cut -d' ' -f1)
krel=$(cat "$KDIR/include/config/kernel.release")
echo "vermagic check: module=$mod_rel kernel=$krel $([ "$mod_rel" = "$krel" ] && echo MATCH || echo MISMATCH)"
[ "$mod_rel" = "$krel" ]
