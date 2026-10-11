#!/usr/bin/env bash
# Apply the ESP-Hosted (ESP32-C6 over SDIO) changes to the Luckfox Pico SDK.
# Run inside the SDK container from the SDK root:   ~/luckfox/lf.sh run /luckfox/changes/apply-esp-hosted-changes.sh [y|m]
# Idempotent: safe to run again. Undo with:          git -C ~/luckfox/luckfox-pico checkout -- . && git clean -fd <listed files>
#
#   1. Device tree: enable the RV1106 SDIO controller (&sdio) on pins 21-27 (GPIO2_A0..A5, sdmmc1m0)
#      by #including esp-hosted-sdio-pro-max.dtsi at the end of rv1106g-luckfox-pico-pro-max.dts.
#   2. Kernel: fragment arch/arm/configs/esp-hosted.config with CFG80211 + BT (the esp32_sdio host
#      driver always links the Bluetooth HCI API), added via RK_KERNEL_DEFCONFIG_FRAGMENT in the board config.
#      $1 = m (modules, default: stock boot.img leaves only ~458 KB of its 4 MB partition) or y (built in).
#   3. Buildroot: wpa_supplicant (nl80211 + wpa_cli) and iw, which the stock Pro/Max image lacks.
set -euo pipefail

MODE=${1:-m}
case "$MODE" in y|m) ;; *) echo "usage: $0 [y|m]"; exit 1;; esac

SDK=$(pwd)
CHANGES=$(cd "$(dirname "$0")" && pwd)
DTS_DIR=sysdrv/source/kernel/arch/arm/boot/dts
BOARD_DTS=$DTS_DIR/rv1106g-luckfox-pico-pro-max.dts
CFG_DIR=sysdrv/source/kernel/arch/arm/configs
BOARD_CFG=project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1106_Luckfox_Pico_Pro_Max-IPC.mk
BR_DEFCONFIG=sysdrv/tools/board/buildroot/luckfox_pico_defconfig

test -f "$BOARD_DTS" || { echo "run from the luckfox-pico SDK root"; exit 1; }

# 1. Device tree
cp -f "$CHANGES/esp-hosted-sdio-pro-max.dtsi" "$DTS_DIR/"
grep -q 'esp-hosted-sdio-pro-max.dtsi' "$BOARD_DTS" || \
    printf '\n/* ESP32-C6 (ESP-Hosted-Linux) over SDIO on header pins 21-27 */\n#include "esp-hosted-sdio-pro-max.dtsi"\n' >> "$BOARD_DTS"
echo "[dts] $(grep -n 'esp-hosted-sdio-pro-max.dtsi' "$BOARD_DTS")"

# 2. Kernel config fragment
cat > "$CFG_DIR/esp-hosted.config" <<EOF
# ESP-Hosted-Linux host driver (esp32_sdio.ko) needs cfg80211 and the Bluetooth core.
CONFIG_CFG80211=$MODE
CONFIG_BT=$MODE
EOF
if grep -q '^export RK_KERNEL_DEFCONFIG_FRAGMENT=' "$BOARD_CFG"; then
    grep -q 'esp-hosted.config' "$BOARD_CFG" || \
        sed -i 's/^export RK_KERNEL_DEFCONFIG_FRAGMENT="\{0,1\}\([^"]*\)"\{0,1\}$/export RK_KERNEL_DEFCONFIG_FRAGMENT="\1 esp-hosted.config"/' "$BOARD_CFG"
else
    echo 'export RK_KERNEL_DEFCONFIG_FRAGMENT=esp-hosted.config' >> "$BOARD_CFG"
fi
echo "[kernel] $(cat "$CFG_DIR/esp-hosted.config" | grep CONFIG | tr '\n' ' ')"
echo "[kernel] $(grep RK_KERNEL_DEFCONFIG_FRAGMENT "$BOARD_CFG")"

# 3. Buildroot packages
for opt in BR2_PACKAGE_WPA_SUPPLICANT BR2_PACKAGE_WPA_SUPPLICANT_NL80211 BR2_PACKAGE_WPA_SUPPLICANT_CLI BR2_PACKAGE_IW; do
    grep -q "^$opt=y" "$BR_DEFCONFIG" || echo "$opt=y" >> "$BR_DEFCONFIG"
done
echo "[buildroot] $(grep -E 'WPA_SUPPLICANT|BR2_PACKAGE_IW' "$BR_DEFCONFIG" | tr '\n' ' ')"
# sysdrv/Makefile copies the defconfig into Buildroot's configs/ only when it first unpacks Buildroot,
# but runs "make luckfox_pico_defconfig" on every build. Sync the copy, or the change is silently ignored.
BR_TREE=sysdrv/source/buildroot/buildroot-2023.02.6
if [ -d "$BR_TREE/configs" ]; then
    cp -f "$BR_DEFCONFIG" "$BR_TREE/configs/"
    echo "[buildroot] synced defconfig into $BR_TREE/configs/"
fi

echo "--- git status"
git -C "$SDK" status --short || true
