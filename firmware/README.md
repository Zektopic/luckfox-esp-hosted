# Firmware

All firmware images for the Luckfox-ALPR / ESP-Hosted work, one folder per board. Every folder has a `SHA256SUMS.txt`.

| Folder | Board | What | Status |
|---|---|---|---|
| `luckfox-pico-max/2026-10-11_esp-hosted/` | Luckfox Pico **Max** (RV1106G3, 256 MB, SPI-NAND) | **Image to flash**: Buildroot + SDIO on header pins 21–27 + `CONFIG_BT=m` + wpa_supplicant 2.10/iw. Also `esp32_sdio.ko` | Built 2026-10-11, **not flashed yet** |
| `luckfox-pico-max/2026-10-11_stock/` | Luckfox Pico Max | Unmodified SDK build (`824b817f8`), `update.img` only | **Recovery fallback** |
| `esp32c6-supermini/2026-10-11_esp-hosted-linux_NG-1.0.6.0.15_sdio/` | ESP32-C6 SuperMini (C6FH4) | ESP-Hosted-Linux co-processor firmware, SDIO | **On the C6** (flashed 2026-10-11) |
| `esp32c6-supermini/2026-10-11_original-arduino-backup/` | ESP32-C6 SuperMini | Partial backup of the Arduino sketch that was on it before | Archive |

How they were built: `../README.md` (C6) and `../luckfox-sdk/README.md` (Luckfox).

> **Cloned the repo?** The `*.img` files are not in git (too big). Download them from the GitHub Release
> [`luckfox-pico-max-2026-10-11`](https://github.com/Zektopic/luckfox-esp-hosted/releases/tag/luckfox-pico-max-2026-10-11).
> Rename them to `update.img` / `boot.img` inside `luckfox-pico-max/2026-10-11_esp-hosted/` (or `_stock/`) and check them against `SHA256SUMS.txt`.
> The Arduino backup folder is local-only (it holds saved Wi-Fi credentials).

## Flash the Luckfox Pico Max (Windows)

> **This replaces the Max's whole system on SPI-NAND** (whatever is in `/userdata` and `/oem` too). Keep the stock image as the way back.

From Luckfox's [image-flashing guide](https://wiki.luckfox.com/Luckfox-Pico-RV1106/Getting-Started/Image-flashing):

1. Download **[SocToolKit v1.98](https://files.luckfox.com/wiki/Luckfox-Pico/Software/SocToolKit_v1.98_20240705_01_win.zip)**, extract it,
   right-click → **Run as administrator**, select chip **RV1106**.
2. Put the Max in flashing mode: **hold BOOT while plugging in USB-C** (or `reboot loader` on a running board).
   The tool should show a **MaskRom** or **Loader** device.
   If nothing appears, install Rockchip's USB driver (DriverAssitant). **Verify**: Luckfox's guide doesn't mention the driver.
3. Click **Firmware** → select the folder
   `C:\Users\manup\Documents\GitHub\ESP32\esp-hosted\firmware\luckfox-pico-max\2026-10-11_esp-hosted`
   (it contains `update.img`) → click **Upgrade**. Wait for it to finish; the board reboots.
4. **Recovery:** the same, selecting `firmware\luckfox-pico-max\2026-10-11_stock`.

Alternatives: **Search Path** + tick partitions + **Download** flashes single partition images from the same folder
(e.g. only `boot.img` after a kernel/DTS change). On Linux: `upgrade_tool uf update.img` (prints "Upgrade firmware ok.").

**After flashing**, ESP-Hosted is loaded by hand (see `../luckfox-sdk/README.md`, "Next: flash + test"):

```powershell
adb shell mkdir -p /userdata/esp-hosted
adb push firmware\luckfox-pico-max\2026-10-11_esp-hosted\esp32_sdio.ko luckfox-sdk\board\esp-hosted-load.sh /userdata/esp-hosted/
adb shell sh /userdata/esp-hosted/esp-hosted-load.sh        # add "bt" for BLE
```

The C6 must be wired (pins 21–28, pull-ups) and powered when the Max boots. Use `/usr/sbin/wpa_supplicant` (v2.10).

| File (`luckfox-pico-max/2026-10-11_esp-hosted/`) | SHA256 |
|---|---|
| `update.img` (82 MB, all partitions) | `49533da732980ca4e6bd346865aa4ac6ec67aa0f3aa0fcc71ce06346ae3a8fe7` |
| `boot.img` (kernel 5.10.160 + DTB with `&sdio`) | `c758ec858b3aca51de706dc6e73e5604212d5661edf5b5dc9e486f9510c05ae8` |
| `rootfs.img` | `ba5551833ad6fb1c50490b4047c30c69379d436ee62c6e0c132b7fd9a5888585` |
| `oem.img` (incl. `/oem/usr/ko/cfg80211.ko`, `bluetooth.ko`) | `8d4ccb86d2eb583b3d18a9098ee01694fe64d9312e191089f6e74fabcff8867d` |
| `esp32_sdio.ko` (136 KB, vermagic 5.10.160) | `2f20e59320dbaa6c73b54148717ecf170a49514107e8810aa1523343d6dac983` |
| stock `update.img` (`2026-10-11_stock/`) | `76dd08ebea06c0a15279fb6eb27d350034eb061d92cb8289298ad17b380b514e` |

## Re-flash the ESP32-C6 SuperMini

See `../README.md` ("Quick start" / "Re-flash the archived build"). It needs esptool 5 (`write-flash "@flash_args"`
in `esp32c6-supermini/2026-10-11_esp-hosted-linux_NG-1.0.6.0.15_sdio/`).
