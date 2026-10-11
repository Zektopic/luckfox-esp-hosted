# Luckfox Pico Max SDK build: ESP-Hosted step 2 (host side)

Builds the Luckfox Pico **Max** (RV1106G3, 256 MB, SPI-NAND) Buildroot image with what the ESP32-C6
co-processor needs. Also builds the matching `esp32_sdio.ko`. **Nothing here flashes the board.**

## Where it runs

The SDK needs x86-64 Ubuntu 22.04, so everything runs on the Linux PC **`ssh luckfox-build`**
(`manupa@192.168.1.9`, Pop!_OS 24.04, key login), inside Luckfox's official Docker image
**`luckfoxtech/luckfox_pico:1.0`** (Ubuntu 22.04.3). Docker works there without sudo.
This folder holds the scripts and docs; they're copied to the build PC.

| Build PC path | What |
|---|---|
| `~/luckfox/luckfox-pico` | `LuckfoxTECH/luckfox-pico`, shallow clone, SDK commit `824b817f8` (2026-03-22), 4.6 GB |
| `~/luckfox/esp-hosted-linux` | `espressif/esp-hosted-linux` @ **`172a719`** (same commit as the C6 firmware) |
| `~/luckfox/lf.sh` | helper (= `lf.sh` here): container up, board select, detached builds, logs |
| `~/luckfox/changes/` | `apply-esp-hosted-changes.sh`, `build-esp-hosted-ko.sh`, the SDIO `.dtsi` |
| `~/luckfox/logs/` | build logs |
| `~/luckfox/out/` | `esp32_sdio.ko` + modinfo |
| `~/luckfox/luckfox-pico/output/image/` | the flashable image files |

Container: `luckfox-sdk` (long-lived; `~/luckfox` mounted at `/luckfox`). It runs as root, so `lf.sh` gives the files back to
`manupa` after each build (`lf.sh fixperms` does it by hand).

## Steps

```bash
ssh luckfox-build
~/luckfox/lf.sh up                         # start container
~/luckfox/lf.sh board                      # .BoardConfig.mk -> BoardConfig-SPI_NAND-Buildroot-RV1106_Luckfox_Pico_Pro_Max-IPC.mk
~/luckfox/lf.sh build 01-stock-all all     # 1) stock build first: proves the environment
~/luckfox/lf.sh run /luckfox/changes/apply-esp-hosted-changes.sh m   # 2) our changes (m = modules, y = built in)
~/luckfox/lf.sh build 02-esp-hosted-all all                          # 3) rebuild
~/luckfox/lf.sh run /luckfox/changes/build-esp-hosted-ko.sh          # 4) esp32_sdio.ko against that kernel
~/luckfox/lf.sh status <log name>          # progress
```

`./build.sh lunch` is an interactive menu; `lf.sh board` makes the same `.BoardConfig.mk` symlink directly.
`build.sh` uses `nproc/2+1` = 7 jobs on the 12-thread Ryzen, which is fine for the build PC's ~13 GB RAM.

## What the changes are (and why)

| Change | File(s) | Why |
|---|---|---|
| Enable SDIO controller `&sdio` on pins 21–27 (`sdmmc1m0`, GPIO2_A0–A5), 4-bit, 10 MHz, `non-removable` | `esp-hosted-sdio-pro-max.dtsi`, `#include`d at the end of `rv1106g-luckfox-pico-pro-max.dts` | It's off by default. Wiring: `../README.md` step 2 |
| Kernel fragment `esp-hosted.config`: `CONFIG_CFG80211=m`, `CONFIG_BT=m` | `arch/arm/configs/esp-hosted.config` + `RK_KERNEL_DEFCONFIG_FRAGMENT` in the board config | `esp32_sdio.ko` needs cfg80211 **and** always links the BT HCI API (`hci_alloc_dev`/`hci_register_dev`), even for Wi-Fi only. **Correction:** the stock build already produced `cfg80211.ko` (Luckfox's in-tree Wi-Fi drivers pull it in, although `luckfox_rv1106_linux_defconfig` doesn't list it). **`BT` was the missing piece.** |
| Buildroot: `wpa_supplicant` (nl80211, `wpa_cli`) + `iw` | `sysdrv/tools/board/buildroot/luckfox_pico_defconfig` | `iw` was missing. **Correction:** the stock image *does* have a `wpa_supplicant`, but it's Rockchip's old **v2.6** in `/usr/bin` (from `project/app/wifi_app`, built because `RK_ENABLE_WIFI=y`). Buildroot's **v2.10** lands in `/usr/sbin`. `PATH` is `/bin:/sbin:/usr/bin:/usr/sbin`, so call **`/usr/sbin/wpa_supplicant`** explicitly |
| esp-hosted-linux host: `MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver)` | `patches/0001-host-import-VFS-namespace-for-Android-derived-kernels.patch` (applied by `build-esp-hosted-ko.sh`) | Rockchip's Android-derived 5.10 kernel exports `filp_open`/`kernel_read` (used by host-side OTA) only in that namespace, so modpost failed |

The full SDK diff (tracked files) is in `../firmware/luckfox-pico-max/2026-10-11_esp-hosted/esp-hosted-sdk.diff`.
`esp-hosted.config` and the `.dtsi` are new, untracked files.

**Gotchas found in the SDK:**

- `sysdrv/Makefile` copies `luckfox_pico_defconfig` into Buildroot's `configs/` **only when it first unpacks Buildroot**, but
  re-runs `make luckfox_pico_defconfig` every time. The apply script therefore also syncs the copy, or the change would be silently ignored.
- The `boot` partition is only **4 MB** (`RK_PARTITION_CMD_IN_ENV`: `4M(boot)`), and the stock `boot.img` already uses 3.55 MB,
  so cfg80211/BT are built as **modules** (the default `m`) to keep the kernel image the same size.

## Status (2026-10-11): ✅ built and checked, ❌ not flashed, not tested on hardware

| Check (no board needed) | Result |
|---|---|
| Stock build (`./build.sh all`) | ✅ `EXIT=0`, ~65 min (first run, incl. Buildroot downloads) |
| ESP-Hosted rebuild | ✅ `EXIT=0`, ~3 min incremental |
| Generated kernel `.config` | `CONFIG_CFG80211=m`, `CONFIG_BT=m`, `CONFIG_MMC_DW_ROCKCHIP=y`, `CONFIG_MODULES=y`, `CONFIG_PWRSEQ_SIMPLE=y` |
| DTB `mmc@ff9a0000` (decompiled) | `status = "okay"`, `bus-width = <4>`, `max-frequency = <10000000>`, `cap-sdio-irq`, `non-removable`, `no-1-8-v`, 3 pinctrl groups |
| `boot.img` | 3,725,312 bytes (stock 3,724,800), **468,992 bytes headroom** in the 4 MB partition |
| `esp32_sdio.ko` | 136,560 bytes stripped (3.6 MB `.debug.ko` kept), `depends=cfg80211,bluetooth`, `vermagic=5.10.160 mod_unload ARMv7 thumb2 p2v8` = kernel `5.10.160` ✅ |
| Kernel modules in the image (`/oem/usr/ko/`) | `cfg80211.ko` 225 KB, `bluetooth.ko` 307 KB (+ deps `libaes`, `ecc`, `ecdh_generic`) |
| Rootfs | `/usr/sbin/wpa_supplicant` (v2.10), `/usr/sbin/wpa_cli`, `/usr/sbin/iw` ✅ (plus Rockchip's old v2.6 `wpa_supplicant`/`wpa_cli` in `/usr/bin`, also in stock) |
| Packed images vs stock (SHA256) | `boot`, `rootfs`, `oem` changed ✅; `uboot`, `idblock`, `download.bin`, `userdata` also differ (rebuild timestamps, presumably); `env.img` identical |
| Startup scripts vs `wlanX` | Only `S99hciinit` touches `wlan0`, and only when Luckfox's own `aic8800_fdrv` is loaded, so it won't interfere |

Notes:

- **Why modules:** the stock `boot.img` was 3,724,800 bytes of a 4,194,304-byte partition (~458 KB free).
- Kernel out-of-tree build dir (`KERNEL=` for the host module): `sysdrv/source/objs_kernel`. Kernel `5.10.160`.
- Buildroot fetches package sources on the first build. SourceForge 404s (e.g. expat) are harmless: it falls back to `sources.buildroot.net`.
- At boot, `RkLunch.sh` runs `/oem/usr/ko/insmod_ko.sh` (camera/NPU) and `insmod_wifi.sh` (Luckfox's AIC8800/ATBM/Hi3861 Wi-Fi only).
  Neither loads ESP-Hosted, so `board/esp-hosted-load.sh` does it.

## Outputs (in `../firmware/luckfox-pico-max/` and `logs/`, SHA256 verified)

| Path | What |
|---|---|
| `../firmware/luckfox-pico-max/2026-10-11_esp-hosted/` | **The new image**: `update.img` (all-in-one) + the separate partition images, `download.bin`, `SHA256SUMS.txt`, plus `esp32_sdio.ko`, `esp32_sdio.debug.ko`, `esp32_sdio.modinfo.txt`, `cfg80211.ko`, `bluetooth.ko`, `esp-hosted-sdk.diff` |
| `../firmware/luckfox-pico-max/2026-10-11_stock/update.img` | **Known-good stock image** (unmodified SDK `824b817f8`), the recovery fallback. Full stock set: `~/luckfox/out/stock-image/` on the build PC |
| `logs/` | all clone/build/pipeline logs (attempts 1–3 failed and are kept for the record, see below) |
| `board/esp-hosted-load.sh` | Loads cfg80211 → libaes/ecc/ecdh_generic → bluetooth → `esp32_sdio.ko` on the board and shows `iw dev` |

Pipeline attempts that failed (all fixed in the scripts):

1. `git status` inside the container: "dubious ownership" (files owned by uid 1000, container runs as root). Fix: `git config --global --add safe.directory '*'` in the container.
2. modpost: `esp32_sdio uses symbol kernel_read/filp_open from namespace VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver` → patch 0001.
3. `modinfo: command not found` in the SDK image. Fix: read `.modinfo` with the cross `objcopy`.

Plus one self-inflicted hang: a wait loop with `pgrep -f "chown -R ..."` matched an orphaned shell whose own command line contained that text. Now uses `pgrep -x chown`.

## Next: flash + test (needs the board, and your OK; replaces the Max's current OS)

1. **Flash** `../firmware/luckfox-pico-max/2026-10-11_esp-hosted/update.img` to SPI-NAND. Full steps are in
   [`../firmware/README.md`](../firmware/README.md), following Luckfox's
   [image-flashing guide](https://wiki.luckfox.com/Luckfox-Pico-RV1106/Getting-Started/Image-flashing):
   SocToolKit v1.98 → RV1106 → hold BOOT + plug USB-C (MaskRom) → **Firmware** = that folder → **Upgrade**.
   Recovery = the same with `../firmware/luckfox-pico-max/2026-10-11_stock/`. Linux alternative: `upgrade_tool uf update.img`.
2. **Wire** the C6 SuperMini to pins 21–28 (`../README.md` step 2), with pull-ups. Power both boards together.
3. After boot: `cat /sys/bus/sdio/devices/*/uevent` should show `SDIO_ID=0092:6666`. Then:
   `adb shell mkdir -p /userdata/esp-hosted` →
   `adb push ../firmware/luckfox-pico-max/2026-10-11_esp-hosted/esp32_sdio.ko board/esp-hosted-load.sh /userdata/esp-hosted/` →
   `adb shell sh /userdata/esp-hosted/esp-hosted-load.sh` (add `bt` for BLE; it also loads ecb/cmac/drbg for BT pairing crypto).
4. `iw dev` → `wlanX`; then `/usr/sbin/wpa_supplicant -B -D nl80211 -i wlanX -c <conf>` + `dhcpcd wlanX` → ping.

**Plan B** (if `&sdio` on pins 21–27 won't enumerate): wire the C6 to the microSD slot (`&sdmmc`, already
`supports-sdio`) via a breakout adapter. It still needs **this** image (the stock kernel has no `bluetooth.ko`).
