# Luckfox Pico Max + ESP32-C6 (ESP-Hosted-Linux over SDIO)

Turns an **ESP32-C6 SuperMini** into an **ESP-Hosted-Linux** Wi-Fi/BLE co-processor for a **Luckfox Pico Max**
(RV1106G3), so the Luckfox gets a real Linux `wlanX` interface. This is part of the Luckfox-ALPR project.

- **Step 1:** build and flash the C6 co-processor firmware.
- **Step 2:** wiring, device tree, kernel and `esp32_sdio.ko` on the Luckfox.
- **Status (2026-10-12):** the C6 is detected over SDIO and `wlan0` appears. The data link fails on the first write during the C6's radio start-up, which points to power/ground wiring. See the "First hardware test" section of [`docs/obsidian/11-ESP-Hosted-on-ESP32-C6.md`](docs/obsidian/11-ESP-Hosted-on-ESP32-C6.md).

Obsidian notes (source of `docs/obsidian/`): `manupas-obsidian-notes/Projects/Electronics/OSS/Luckfox-ALPR/11-ESP-Hosted-on-ESP32-C6.md`

## Repository & sources

Private repo: **https://github.com/Zektopic/luckfox-esp-hosted**

| What | Where |
|---|---|
| Scripts, patches, device tree, board loader, docs, logs, C6 firmware binaries, `.ko` modules, checksums | in git |
| Luckfox `update.img` (ESP-Hosted image and stock fallback), `boot.img` | **GitHub Release** `luckfox-pico-max-2026-10-11` (too big for git: 82 MB). Put them back into `firmware/luckfox-pico-max/…/` and check against `SHA256SUMS.txt` |
| Upstream sources | **not vendored**. Recreate them with the commands below |
| Old Arduino flash backup | **not in git**: its NVS holds saved Wi-Fi credentials. It's local only |

```bash
# from the repo root
git clone https://github.com/espressif/esp-hosted-linux.git
git -C esp-hosted-linux checkout 172a719
git -C esp-hosted-linux apply ../scripts/patches/0001-c6-sdio-timing-nsend-nsample-internal-pullup.patch   # C6 firmware tweak (step 2 debugging)
git clone https://github.com/espressif/esp-hosted.git      # optional: the docs-only hub repo
# ESP-IDF v6.1 for the C6 firmware: powershell -ExecutionPolicy Bypass -File scripts/setup-idf61.ps1
# Luckfox SDK (LuckfoxTECH/luckfox-pico @ 824b817f8) + host driver: see luckfox-sdk/README.md (built on a Linux PC)
```

The host-driver patch (`luckfox-sdk/patches/0001-*`) is applied automatically by `luckfox-sdk/build-esp-hosted-ko.sh`.

## Status (2026-10-11): ✅ step 1 done

The C6 on COM4 runs **ESP-Hosted-Linux firmware `NG-1.0.6.0.15`** (esp-hosted-linux `172a719`, ESP-IDF v6.1 `fff9895c`),
**SDIO transport**, Wi-Fi + BLE (HCI over SDIO). esptool verified the hash of every region it wrote. Boot log (`logs/04-boot.log`):

```
I (427) stats:                 ESP-Hosted Firmware version :: NG-1.0.6.0.15
I (436) stats:                 Transport used :: SDIO only
I (454) FW_MAIN: - WLAN over SDIO
I (461) FW_BT: - HCI Over SDIO
I (464) FW_BT:    - BLE only
I (483) wifi:wifi firmware version: 3ab2604
I (579) FW_MAIN: ESP Bluetooth MAC addr: e4-b0-63-41-e0-1e
I (584) FW_SDIO_SLAVE: Using SDIO interface
```

It now sits waiting for a Linux SDIO host. **No `wlanX` exists yet**: that needs step 2 (wiring + device tree + `esp32_sdio.ko` on the Luckfox).

## Layout

| Path | What |
|---|---|
| `esp-hosted/` | `espressif/esp-hosted` hub repo (master `a042292`). Since 2026-09-09 it holds **docs only**. The NG/FG code moved, see below. |
| `esp-hosted-linux/` | `espressif/esp-hosted-linux` (master `172a719`, 2026-10-08, version 1.0.6.0.7). The successor of ESP-Hosted-NG: FullMAC, `cfg80211`, real `wlanX` on Linux. **This is the one we use.** |
| `esp-hosted-linux/esp/esp_driver/esp-idf/` | ESP-IDF **v6.1** at the commit pinned by the repo (`fff9895c`), patched, with the hosted Wi-Fi libraries copied in. Created by `scripts/setup-idf61.ps1`. Not tracked by git. |
| `esp-hosted-linux/esp/esp_driver/network_adapter/` | The co-processor firmware project (`idf.py` runs here). |
| `scripts/setup-idf61.ps1` | One-time: clone + patch + install the pinned ESP-IDF v6.1 (Windows PowerShell 5.1-safe copy of upstream `setup.ps1`). |
| `scripts/build-flash-esp-hosted.ps1` | Build the SDIO firmware for `esp32c6` and flash it to COM4. |
| `scripts/serial_capture.py` | Reset the C6 and save its boot log, without the interactive `idf.py monitor`. |
| `scripts/backup_flash.py` | Chunked/retrying flash backup (the C6's USB link drops long reads). |
| `scripts/test-luckfox-sdio.sh` | **Bring-up test loop**: resets the C6 (COM4), re-detects it on the Luckfox (`ssh luckfox`), loads the driver, runs a Wi-Fi scan, prints PASS/FAIL with both logs. |
| `scripts/patches/` | Our changes to esp-hosted-linux's C6 firmware (applied to the `172a719` clone). |
| `docs/obsidian/` | Copy of the Obsidian project note (full history, diagnosis, wiring). `docs/images/`: Luckfox Pro/Max pinout. |
| **`firmware/`** | **All firmware images, one subfolder per board**. Index and flashing steps: [`firmware/README.md`](firmware/README.md). |
| `firmware/esp32c6-supermini/2026-10-11_esp-hosted-linux_NG-1.0.6.0.15_sdio/` | The exact C6 binaries that were flashed + `flash_args`, `sdkconfig`, `.elf` and `SHA256SUMS.txt`. Re-flash without rebuilding (see below). |
| `firmware/esp32c6-supermini/2026-10-11_original-arduino-backup/` | What was on the C6 before it was overwritten (see below). |
| `firmware/luckfox-pico-max/2026-10-11_esp-hosted/` | **The Luckfox Pico Max image to flash** (`update.img` + partition images) + `esp32_sdio.ko`, `cfg80211.ko`, `bluetooth.ko`. |
| `firmware/luckfox-pico-max/2026-10-11_stock/` | Stock Luckfox Pico Max `update.img`, the recovery fallback. |
| `step2-luckfox/` | Step-2 prep for the Luckfox Pico Pro/Max: SDIO device-tree fragment + Luckfox's pinout image. |
| `luckfox-sdk/` | **Step 2 build**: scripts that build the Luckfox Pico Max image (SDIO + cfg80211/BT + wpa_supplicant/iw) and `esp32_sdio.ko` on the Linux PC (`ssh luckfox-build`, Docker), plus build logs and the board loader. Built and checked 2026-10-11; **not flashed yet**. |
| `logs/` | Setup, build, flash and boot logs from 2026-10-11. |

## Why esp-hosted-linux (and not esp-hosted master / NG)

- `espressif/esp-hosted` master was cut down to a documentation hub on 2026-09-09 ("docs: strip off FG/NG code").
  The old code is on the `legacy/fg-ng` branch.
- **ESP-Hosted-NG → [esp-hosted-linux](https://github.com/espressif/esp-hosted-linux)**: Linux host, `cfg80211`,
  `wpa_supplicant`/`NetworkManager`, native `wlanX`. That's what the Luckfox needs.
- ESP-Hosted-FG → [esp-hosted-mcu](https://github.com/espressif/esp-hosted-mcu): ESP-IDF `esp_wifi_*` RPC API on the
  host. Useful for MCU hosts, not needed here.

## Why a second ESP-IDF (v6.1) next to the installed v5.5.4

esp-hosted-linux pins ESP-IDF **v6.1 @ `fff9895c`** (`esp/esp_driver/.env`). Its setup:

1. applies `lib/rom.patch` and `lib/idf-openthread-custom-rcp-v6.1.patch` to that IDF, and
2. **replaces `components/esp_wifi/lib`** with Espressif's FullMAC/hosted Wi-Fi libraries.

Those libraries are built for that exact IDF, so the EIM-installed v5.5.4 (`C:\esp\v5.5.4`) cannot build this firmware.
To keep the two installs apart:

- the v6.1 IDF lives inside the repo (`esp-hosted-linux/esp/esp_driver/esp-idf`),
- its tools/python env live in **`C:\Users\manup\.espressif-idf61`** (`IDF_TOOLS_PATH`),
- `C:\Espressif\tools` and `C:\esp\v5.5.4` are untouched,
- don't load `Microsoft.v5.5.4.PowerShell_profile.ps1` in the same shell as the v6.1 `export.ps1`.

To remove the v6.1 setup completely, delete `esp-hosted-linux/esp/esp_driver/esp-idf` and `C:\Users\manup\.espressif-idf61`.

### Windows PowerShell 5.1 fix

Upstream `setup.ps1` fails immediately on Windows PowerShell 5.1 (there's no PowerShell 7 on this PC):

```
The parameter 'Help' cannot be specified because it conflicts with the parameter alias of the same name for parameter 'Help'.
```

`scripts/setup-idf61.ps1` is a copy with the minimum changes. The header of the file lists them: the alias fix,
`core.longpaths`/`autocrlf=false` for the clone, a separate `IDF_TOOLS_PATH`, installing only the `esp32c6` toolchain,
and keeping the submodule's `.git` file (next section).

### Other Windows problems hit (and fixed)

| Symptom | Cause | Fix (already in the scripts) |
|---|---|---|
| `ninja: fatal: CreateProcess: The parameter is incorrect. (is the command line too long?)` compiling `main/app_main.c` | This folder is deep; `app_main.c` gets ~150 `-I…/esp-idf/components/…` paths, more than Windows' 32 K command-line limit | `idf.py -DCMAKE_NINJA_FORCE_RESPONSE_FILE=ON …` (flags go through a response file) |
| Link errors: `undefined reference to ieee80211_send_mgmt_internal`, `esp_wifi_send_assoc_internal`, `ieee80211_add_node`, … | Upstream `setup.ps1` clears `esp_wifi\lib` with `Remove-Item "$destRoot\*" -Force`, which on Windows also deletes the submodule's hidden `.git`. The IDF build then sees the submodule as missing and runs `git submodule update --init`, **silently restoring the stock Wi-Fi libs** over the hosted ones. | `setup-idf61.ps1` keeps `.git`; `build-flash-esp-hosted.ps1` checks that `libnet80211.a` matches the hosted one and sets `IDF_SKIP_CHECK_SUBMODULES=1` |
| No boot log captured after an RTS reset from pyserial | Windows' `usbser.sys` only sends the new line state when DTR is written, so an RTS-only change never reaches the C6 | `serial_capture.py` re-writes DTR after each RTS change (as esptool does) |

## Transport: SDIO (and why not SPI on this board)

The board is an **ESP32-C6 SuperMini**: chip **ESP32-C6FH4 (QFN32), rev v0.1, 4 MB in-package flash**
(MAC `e4:b0:63:41:e0:1c`), connected over its built-in USB-Serial/JTAG (VID:PID `303A:1001`).
**GPIO18–23 are all on its headers** (seen on the board 2026-10-11; matches the
[mischianti](https://mischianti.org/esp32-c6-supermini-high-resolution-pinout-datasheet-schema-and-specs/) and
[espboards](https://www.espboards.dev/esp32/esp32-c6-super-mini/) pinouts). On-board parts don't touch the SDIO pins:
GPIO8 = WS2812 RGB LED, GPIO9 = BOOT button, GPIO15 = status LED, GPIO12/13 = USB D−/D+.

- **SDIO** is esp-hosted-linux's default transport for the C6, and the fastest (Espressif measured up to 55.6 Mbit/s TCP and 90.4 Mbit/s UDP).
  Its pins are fixed by the C6's SDIO-slave hardware and all exist on the QFN32 package:

  | SDIO | CLK | CMD | DAT0 | DAT1 | DAT2 | DAT3 |
  |---|---|---|---|---|---|---|
  | ESP32-C6 GPIO | 19 | 18 | 20 | 21 | 22 | 23 |

  CMD and DAT0–3 need **10 kΩ pull-ups** to 3.3 V (the SuperMini has none on these pins). Keep the wires short and
  share GND. The full Luckfox ↔ SuperMini wiring is in [Step 2](#next-step-2-not-done) below.
  Leave **GPIO4/5** (MTMS/MTDI strapping pins) unconnected so nothing drives them at reset. **Verify** what they strap
  on the C6 in the datasheet's "Strapping Pins" section.

- **SPI** in esp-hosted-linux hard-codes the C6's **CS to GPIO10** (`network_adapter/main/spi_slave_api.c`;
  SCLK 6, MOSI 7, MISO 2, Handshake 3, Data-Ready 4). **GPIO10 and GPIO11 are not bonded out on in-package-flash
  C6 parts (C6FH4/FH8, C6-MINI-1)**, so the stock SPI build cannot work on this chip. Using SPI would need a
  one-line source change (CS → a free pin) plus matching wiring and device tree. Only do that if the Luckfox can't do SDIO.

## Quick start

```powershell
# one-time (≈20–30 min, downloads ~1–2 GB):
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-idf61.ps1

# build + flash COM4:
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-flash-esp-hosted.ps1

# check it boots (uses the v6.1 venv's pyserial):
& "$env:USERPROFILE\.espressif-idf61\python_env\idf6.1_py3.13_env\Scripts\python.exe" scripts\serial_capture.py --port COM4 --seconds 8 --out logs\boot.txt
```

Re-flash the archived build without rebuilding. `flash_args` uses esptool 5 option names (`--flash-mode`), so use the
v6.1 venv's esptool 5.5.0. The v5.5.4 venv has esptool 4.x, which only knows `--flash_mode` and would reject the file.

```powershell
cd firmware\esp32c6-supermini\2026-10-11_esp-hosted-linux_NG-1.0.6.0.15_sdio
& "$env:USERPROFILE\.espressif-idf61\python_env\idf6.1_py3.13_env\Scripts\python.exe" -m esptool --chip esp32c6 --port COM4 write-flash "@flash_args"
```

> **2026-10-12:** `C:\Users\manup\.espressif-idf61` (the v6.1 tools + Python env) was deleted at 00:39 and is in the
> **Recycle Bin**. The IDF source in `esp-hosted-linux\esp\esp_driver\esp-idf` (790 MB) is still here. To build or
> re-flash the C6 again, restore it from the Recycle Bin, or reinstall the tools with
> `$env:IDF_TOOLS_PATH="$env:USERPROFILE\.espressif-idf61"; esp-hosted-linux\esp\esp_driver\esp-idf\install.ps1 esp32c6`
> (`setup-idf61.ps1` skips `install.ps1` when the IDF checkout already exists).

Interactive monitor (needs a real terminal): run `esp-idf\export.ps1` with `IDF_TOOLS_PATH=C:\Users\manup\.espressif-idf61`,
then `idf.py -p COM4 monitor` in `network_adapter` (Ctrl+] quits).

## What was on the C6 before (`firmware/esp32c6-supermini/2026-10-11_original-arduino-backup/`)

The board was running an **Arduino sketch** (app descriptor: `arduino-lib-builder`, IDF `v5.1.4-358-gbd2b9390ef`,
built Jun 24 2024), using the default Arduino 4 MB partition table (nvs 20K, otadata, app0/app1 1280K, spiffs 1408K, coredump 64K).

| File | Contents |
|---|---|
| `c6_original_0x0000-0x10000_boot_pt_nvs_otadata.bin` | Bootloader, partition table, NVS, otadata (complete) |
| `c6_original_0x10000-0x20000_app0_PARTIAL_first64KB.bin` | First 64 KB of the 922 KB sketch only |

A full backup was not possible: over the C6's USB-Serial/JTAG on this PC every long `read_flash` failed (stub: stall
at 4 % / "Corrupt data"; ROM loader: "Packet content transfer stopped" from 0x20000 on).

**The Arduino sketch itself is gone.** To go back to it:

1. Re-upload the sketch from its **Arduino source**. That also rewrites the Arduino bootloader, partition table and otadata.
2. Only if the old NVS contents matter (e.g. saved Wi-Fi credentials), write back **just the NVS slice** (file offset
   0x9000, length 0x5000) to 0x9000:
   ```powershell
   cd firmware\esp32c6-supermini\2026-10-11_original-arduino-backup
   $b = [IO.File]::ReadAllBytes("$PWD\c6_original_0x0000-0x10000_boot_pt_nvs_otadata.bin")
   [IO.File]::WriteAllBytes("$PWD\nvs_0x9000.bin", $b[0x9000..0xDFFF])
   python -m esptool --port COM4 write_flash 0x9000 nvs_0x9000.bin
   ```

Don't write the whole 64 KB file back to 0x0 while ESP-Hosted is installed. You'd get the Arduino bootloader and
partition table under the ESP-Hosted app, which boots neither cleanly.

## Next (step 2, not done)

0. **Build the host driver from the same esp-hosted-linux commit (`172a719`).** Don't `git pull` between the firmware
   build and the host build: firmware and `esp32_sdio.ko` must speak the same protocol. Note that the repo's `VERSION`
   file says `1.0.6.0.7` while the firmware banner says `NG-1.0.6.0.15`. That's how this commit reports itself, not a mismatch.
   (Board check done: ESP32-C6 SuperMini, GPIO18–23 on the headers, so SDIO is wireable.)
1. **Wire it** (host: **Luckfox Pico Pro/Max**). Use the RV1106 SDIO controller on pin-mux **M0 = GPIO2_A0–A5**,
   a tight block on the right-hand header (3.3 V domain, GND on both sides). Pin numbers come from Luckfox's wiki image,
   saved as `step2-luckfox/luckfox-pico-pro-max-pinout.png`. Pin groups come from the SDK's `rv1106-pinctrl.dtsi`.

   | Signal | Pro/Max pin | RV1106 | C6 SuperMini | Pull-up |
   |---|---|---|---|---|
   | D3 | **21** | GPIO2_A4 | GPIO23 | 10 kΩ → 3V3 |
   | D2 | **22** | GPIO2_A5 | GPIO22 | 10 kΩ |
   | GND | **23** | – | GND | |
   | D1 | **24** | GPIO2_A0 | GPIO21 | 10 kΩ |
   | D0 | **25** | GPIO2_A1 | GPIO20 | 10 kΩ |
   | CLK | **26** | GPIO2_A2 | GPIO19 | none |
   | CMD | **27** | GPIO2_A3 | GPIO18 | 10 kΩ |
   | GND | **28** | – | GND | |
   | 5 V | **40** (VBUS) | – | 5V | see power note |

   - On a stock Pro/Max image these pins are unused: `uart1` is disabled, `i2c4` (the camera) uses its M2 pins, and
     `i2s0_8ch` (internal audio codec) has no external pins. **Don't enable UART1 or I2C4-M0 with `luckfox-config`.**
   - The other SDIO option (M1 = GPIO1_C0–C5, pins 6/7/12/14/15/16) is spread out and takes SPI0, so it's not used.
   - **No reset line by default.** I haven't confirmed the SuperMini brings EN out to a pin; only a RESET button is
     documented. Power both boards together: the C6 reaches SDIO init ~0.6 s after power-up, long before the Luckfox
     kernel probes MMC. If you find an EN pad, the draft DTS has an optional `mmc-pwrseq` on pin 29 (GPIO2_A6).
   - **Power backfeed:** while the SuperMini is also plugged into the PC over USB, don't connect pin 40 to its 5V pin
     (two 5 V sources). Share only GND. **Verify** whether the SuperMini has a diode on VBUS.
   - **Ground: use both GND pins (23 and 28), not just one.** On 2026-10-12 (one GND wire + both boards' 5 V tied
     across two supplies), every host→C6 write failed with CRC `-84` exactly when the C6 switched its radio on, at any
     clock speed, sampling edge or pull-up setting. See the note "First hardware test".
2. **Device tree:** `step2-luckfox/esp-hosted-sdio-pro-max.dtsi` (**draft, untested**) enables `&sdio` (mmc@ff9a0000)
   with `sdmmc1m0` pins, 4-bit, `non-removable`, `cap-sdio-irq`, `no-1-8-v`, starting at 10 MHz. Include it from
   `rv1106g-luckfox-pico-pro-max.dts` in the Luckfox SDK and rebuild/flash the kernel. `&sdio` hasn't been seen enabled on
   any Luckfox board yet, so treat the controller as unproven.
3. **Kernel config.** Built on 2026-10-11; see **[`luckfox-sdk/`](luckfox-sdk/README.md)** for the image, the modules and every check.

   | Option | Stock build | Needed / done |
   |---|---|---|
   | `CONFIG_MMC`, `CONFIG_MMC_DW`, `CONFIG_MMC_DW_ROCKCHIP` | `y` | ✅ already |
   | `CONFIG_MODULES` | `y` | ✅ already (for `esp32_sdio.ko`) |
   | `CONFIG_CFG80211` | already `m` (Luckfox's in-tree Wi-Fi drivers pull it in; the defconfig alone doesn't show it) | ✅ `m` |
   | `CONFIG_BT` | off | ❗ **required even for Wi-Fi only**: `esp32_sdio.ko` always links the BT HCI API → added as `m` |
   | `CONFIG_PWRSEQ_SIMPLE` | `y` (confirmed in the built `.config`) | only for the optional reset line |

4. ✅ `esp32_sdio.ko` cross-compiled against that kernel (`sysdrv/source/objs_kernel`, `5.10.160`, vermagic matches).
   It needed patch `luckfox-sdk/patches/0001-*` (symbol-namespace import). Output: `firmware/luckfox-pico-max/2026-10-11_esp-hosted/`.
5. On the board (after flashing + wiring): `modprobe` won't work (the modules sit in `/oem/usr/ko/` with no depmod index),
   so use **`luckfox-sdk/board/esp-hosted-load.sh`**. It `insmod`s cfg80211 → libaes/ecc/ecdh_generic → bluetooth → `esp32_sdio.ko`
   and shows `iw dev`. For Wi-Fi, use **`/usr/sbin/wpa_supplicant`** (Buildroot v2.10). `/usr/bin/wpa_supplicant` is
   Rockchip's old v2.6 and comes first in `PATH`.

**Plan B (if the `&sdio` controller won't work):** wire the C6 to the Pro/Max **microSD slot** (`&sdmmc`, already configured
with `supports-sdio`, `cap-sdio-irq`, `non-removable`) through a microSD breakout/sniffer adapter, instead of pins 21–27.
It still needs **this same new image**: the stock kernel has no `bluetooth.ko`, so `esp32_sdio.ko` can't load on it.
The only thing Plan B avoids is relying on the unproven `&sdio` controller. Cost: no SD card; the board still boots from
SPI-NAND, but ALPR storage would have to live on the NAND.

**Board:** Luckfox Pico **Max** (RV1106G3, 256 MB), confirmed by the user 2026-10-11. SDK board config `RV1106_Luckfox_Pico_Pro_Max`.
