---
created: 2026-10-11
tags:
  - type/project-doc
  - type/reference
  - area/electronics
  - area/firmware
  - project/luckfox-alpr
aliases:
  - ESP-Hosted on ESP32-C6
  - ESP-Hosted step 1
---

# ESP-Hosted on the ESP32-C6: step 1, co-processor firmware

Goal of the whole ESP-Hosted track: give the Luckfox a **real Linux `wlanX`** by using the ESP32-C6 as a Wi-Fi co-processor (the "Raspberry Pi article" idea from [[01-Idea-and-Conversation]]).

**Step 1 (this note):** build the ESP-Hosted firmware and flash it to the C6 on the PC (COM4). Wiring to the Luckfox, the device tree and the kernel module are step 2.

Work folder: `C:\Users\manup\Documents\GitHub\ESP32\esp-hosted\` (its `README.md` has the same details plus the scripts).
Repo (private): **[Zektopic/luckfox-esp-hosted](https://github.com/Zektopic/luckfox-esp-hosted)**. The work folder *is* this repo. The Luckfox `.img` files are Release assets, and a copy of this note lives in `docs/obsidian/`.

## The board on COM4

| | |
|---|---|
| Board | **ESP32-C6 SuperMini** (GPIO18–23 confirmed on the headers 2026-10-11) |
| Chip | **ESP32-C6FH4 (QFN32)**, revision v0.1, 4 MB **in-package** flash, 40 MHz crystal |
| On-board pins | GPIO8 = WS2812 RGB LED, GPIO9 = BOOT, GPIO15 = status LED, GPIO12/13 = USB. None clash with SDIO |
| Features | Wi-Fi 6 (2.4 GHz), BLE 5, 802.15.4, single core + LP core, 160 MHz |
| MAC | `e4:b0:63:41:e0:1c` |
| USB | Built-in USB-Serial/JTAG (VID:PID `303A:1001`), no separate USB-UART chip |
| Was running | An Arduino sketch (arduino-esp32 core, IDF v5.1.4, built Jun 24 2024), default Arduino 4 MB partition table |

The QFN32 + in-package flash combination matters (no GPIO10/11), see "Transport" below. Pinouts: [mischianti](https://mischianti.org/esp32-c6-supermini-high-resolution-pinout-datasheet-schema-and-specs/), [espboards](https://www.espboards.dev/esp32/esp32-c6-super-mini/).

### Wiring: Luckfox Pico Pro/Max ↔ C6 SuperMini (planned, not wired yet)

Host board: **Luckfox Pico Max** (RV1106G3, 256 MB; user, 2026-10-11). The RV1106 SDIO controller has two pin options. **M0 = GPIO2_A0–A5** sits in one tight block on the right-hand header (3.3 V domain, GND on both sides), so that's the one to use. Pin numbers come from [Luckfox's Pro/Max GPIO page](https://wiki.luckfox.com/Luckfox-Pico-Pro-Max/GPIO) (a copy of the image is in the work folder, `step2-luckfox/`). The pin-mux groups come from the SDK's `rv1106-pinctrl.dtsi` (`sdmmc1m0_*`).

| Signal | Pro/Max pin | RV1106 | C6 SuperMini | Pull-up |
|---|---|---|---|---|
| D3 | **21** | GPIO2_A4 | GPIO23 | 10 kΩ → 3V3 |
| D2 | **22** | GPIO2_A5 | GPIO22 | 10 kΩ |
| GND | **23** | – | GND | |
| D1 | **24** | GPIO2_A0 | GPIO21 | 10 kΩ (also the SDIO interrupt line) |
| D0 | **25** | GPIO2_A1 | GPIO20 | 10 kΩ |
| CLK | **26** | GPIO2_A2 | GPIO19 | none |
| CMD | **27** | GPIO2_A3 | GPIO18 | 10 kΩ |
| GND | **28** | – | GND | |
| 5 V | **40** (VBUS) | – | 5V | not `3V3(OUT)`; see backfeed note |

- On a stock image those Luckfox pins are free: `uart1` is disabled, `i2c4` (camera) uses its M2 pins, and `i2s0_8ch` (internal audio codec) has no external pins. **Don't enable UART1 or I2C4-M0 in `luckfox-config`.**
- The other option, M1 = GPIO1_C0–C5 (pins 6/7/12/14/15/16), is scattered and takes SPI0. Not used.
- **No reset line by default.** I couldn't confirm that the SuperMini brings EN out to a pin (only a RESET button is documented). Powering both boards together is fine: the C6 reaches SDIO init ~0.6 s after power-up, long before the Luckfox kernel probes MMC. If an EN pad turns up, the draft DTS has an optional `mmc-pwrseq` on pin 29 (GPIO2_A6).
- **Power backfeed:** while the SuperMini is plugged into the PC over USB, don't also feed its 5V pin from Luckfox pin 40. Share only GND. **Verify** whether the SuperMini has a VBUS diode.
- Leave **GPIO4/5** (MTMS/MTDI strapping pins) unconnected so nothing drives them at reset. **Verify** what they strap on the C6 (datasheet, "Strapping Pins").

## What changed upstream (checked 2026-10-11)

- `espressif/esp-hosted` **master is now a docs-only hub** (commit "docs: strip off FG/NG code", 2026-09-09). The old code is on branch `legacy/fg-ng`.
- **ESP-Hosted-NG → [esp-hosted-linux](https://github.com/espressif/esp-hosted-linux)**: FullMAC, `cfg80211`/`nl80211`, native `wlanX`, `wpa_supplicant`/`NetworkManager`, BLE over HCI. **This is the one for the Luckfox.**
- ESP-Hosted-FG → [esp-hosted-mcu](https://github.com/espressif/esp-hosted-mcu): ESP-IDF `esp_wifi_*` APIs over RPC on the host. Not needed here.
- esp-hosted-linux supports the **C6 over SDIO or SPI** (and the C5 is now fully supported, so the "C5 may still be beta" line in [[01-Idea-and-Conversation]] is out of date). Host driver compatibility: Linux 4.9–7.2.

## Transport decision: SDIO

| | SDIO | SPI |
|---|---|---|
| C6 pins | CLK 19, CMD 18, D0 20, D1 21, D2 22, D3 23 (fixed by hardware) | CS **10**, SCLK 6, MOSI 7, MISO 2, Handshake 3, Data-Ready 4 |
| Extra host GPIOs | None after enumeration (optional reset for `mmc-pwrseq`) | Reset, Handshake, Data-Ready |
| Pull-ups | **10 kΩ on CMD + D0–D3** | 10 kΩ on CS recommended |
| Speed (Espressif, C6) | up to 55.6 Mbit/s TCP / 90.4 Mbit/s UDP | lower |
| Works on **this** C6? | ✅ GPIO18–23 exist on QFN32 | ❌ **GPIO10/11 are not bonded out** on in-package-flash C6 parts, and the firmware hard-codes CS = GPIO10 |

**Decision: SDIO.** It's the repo default for the C6, needs no source changes, and it's the reason the C6 was picked over the C3 in [[03-System-Architecture]]. SPI stays a fallback only if the Luckfox can't do SDIO. It would need a one-line change in `network_adapter/main/spi_slave_api.c` (CS → a free pin).

> [!warning] Clash with the UART uplink plan
> [[03-System-Architecture]] wires the C6's **GPIO6/7** to Luckfox UART3 for the MQTT event uplink. ESP-Hosted is a **different firmware** on the same chip: the C6 can run *either* the UART uplink app *or* ESP-Hosted, not both. If ESP-Hosted works, the Luckfox gets `wlan0` itself and the UART uplink is no longer needed (MQTT runs on the Luckfox). In SPI mode GPIO6/7 would also be taken by SCLK/MOSI. SDIO uses GPIO18–23 and leaves 6/7 free.

## Toolchain: a second ESP-IDF (v6.1) next to v5.5.4

esp-hosted-linux pins **ESP-IDF v6.1 @ `fff9895c`**. Its setup patches that IDF (`rom.patch`, OpenThread custom-RCP patch) and **replaces `esp_wifi/lib` with Espressif's hosted FullMAC Wi-Fi libraries**. Those are built for that exact IDF, so the EIM-installed **v5.5.4 can't build it**.

Kept separate on purpose:

| | v5.5.4 (EIM, unchanged) | v6.1 (for ESP-Hosted only) |
|---|---|---|
| IDF | `C:\esp\v5.5.4\esp-idf` | `…\esp-hosted\esp-hosted-linux\esp\esp_driver\esp-idf` |
| Tools / venv | `C:\Espressif\tools` | `C:\Users\manup\.espressif-idf61` |
| Activate | `Microsoft.v5.5.4.PowerShell_profile.ps1` | `esp-idf\export.ps1` with `IDF_TOOLS_PATH` set (the build script does this) |
| Toolchain | riscv32-esp-elf GCC 14.2 | riscv32-esp-elf GCC 15.2 |

Don't load both in one shell. To uninstall v6.1: delete the two v6.1 folders.

> [!warning] 2026-10-12: v6.1 tools folder deleted
> `C:\Users\manup\.espressif-idf61` was deleted on 2026-10-12 00:39 and is in the **Recycle Bin**. The IDF source (790 MB, inside the repo) is still there. Before building or re-flashing the C6 again: restore it, or run `install.ps1 esp32c6` with `IDF_TOOLS_PATH` set (see the work folder README).

All firmware images now live in the work folder's **`firmware\`** folder, one subfolder per board, with flashing steps in `firmware\README.md`.

**Gotcha:** upstream `setup.ps1` fails on Windows PowerShell 5.1 (`The parameter 'Help' cannot be specified because it conflicts with the parameter alias of the same name`). There's no PowerShell 7 on this PC, so `scripts/setup-idf61.ps1` is a copy with that alias removed (plus `core.longpaths`, `autocrlf=false`, a separate tools path, and the C6-only toolchain).

## Steps (repeatable)

```powershell
cd C:\Users\manup\Documents\GitHub\ESP32\esp-hosted
# one-time: clone + patch + install IDF v6.1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-idf61.ps1
# build (SDIO, esp32c6) and flash COM4
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-flash-esp-hosted.ps1
# reset + capture the boot log (pyserial from the v6.1 venv)
& "$env:USERPROFILE\.espressif-idf61\python_env\idf6.1_py3.13_env\Scripts\python.exe" scripts\serial_capture.py --port COM4 --seconds 8 --out logs\boot.txt
```

## Backup of the old firmware

Over the C6's USB-Serial/JTAG on this PC, **long flash reads fail** (stub: stall at 4 % / `Corrupt data`; ROM loader: `Packet content transfer stopped` from 0x20000). Saved in `firmware/esp32c6-supermini/2026-10-11_original-arduino-backup/`:

- `0x0000–0x10000` complete: bootloader, partition table, NVS, otadata.
- First 64 KB of the 922 KB Arduino sketch only. **The sketch is gone**: to go back, re-upload it from the Arduino source (that rewrites the bootloader and partition table too). Then, only if the old NVS matters, write back just the NVS slice (0x9000, 0x5000 bytes). Never write the whole 64 KB file to 0x0 over ESP-Hosted. The work folder README has the commands.

## Result (2026-10-11): ✅ firmware flashed and booting

- **Firmware:** ESP-Hosted-Linux `NG-1.0.6.0.15` (esp-hosted-linux `172a719`), ESP-IDF v6.1 `fff9895c` (+ hosted patches), target `esp32c6`, **SDIO**, Wi-Fi + BLE with HCI over SDIO.
- **Size:** app 0xF0840 (≈985 KB) in a 0x120000 factory slot (16 % free). Partitions: nvs, otadata, phy_init, factory, ota_0, ota_1, so it can be OTA-updated from Linux later.
- **Flash:** bootloader @0x0, partition table @0x8000, otadata @0xD000, app @0x10000; esptool verified every hash.
- **Boot log** (`logs/04-boot.log`):

```
ESP-Hosted Firmware version :: NG-1.0.6.0.15
Transport used :: SDIO only
FW_MAIN: - WLAN over SDIO
FW_BT: - HCI Over SDIO / BLE only
wifi:wifi firmware version: 3ab2604
FW_MAIN: ESP Bluetooth MAC addr: e4-b0-63-41-e0-1e
FW_SDIO_SLAVE: Using SDIO interface
```

The C6 is now **waiting for a Linux SDIO host**. That means "firmware flashed and running", **not** "Wi-Fi working": there is no `wlanX` until step 2.

The exact flashed binaries (+ `flash_args`, `sdkconfig`, `.elf`, SHA256) are archived in `firmware/esp32c6-supermini/2026-10-11_esp-hosted-linux_NG-1.0.6.0.15_sdio/` in the work folder, so I can re-flash without rebuilding.

## Windows gotchas hit on the way (all fixed in the scripts)

| Symptom | Cause | Fix |
|---|---|---|
| `setup.ps1`: `parameter 'Help' … conflicts with the parameter alias` | PS 5.1 alias clash in upstream script | Own copy `scripts/setup-idf61.ps1` |
| `ninja: fatal: CreateProcess … (is the command line too long?)` | Deep folder × ~150 include paths > 32 K | `-DCMAKE_NINJA_FORCE_RESPONSE_FILE=ON` |
| Link errors `undefined reference to ieee80211_send_mgmt_internal` … | Upstream's `Remove-Item …\* -Force` deletes the `esp_wifi/lib` submodule's hidden `.git` on Windows, and the IDF build then "repairs" it back to the **stock** Wi-Fi libs | Keep `.git`; build script checks the lib hash and sets `IDF_SKIP_CHECK_SUBMODULES=1` |
| Long `read_flash` over the C6's USB-Serial/JTAG fails | Stub stalls / "Corrupt data"; ROM mode "Packet content transfer stopped" | Only 64 KB chunks via ROM loader worked (see backup) |
| No boot log after an RTS reset from pyserial | `usbser.sys` only sends line state when DTR is written | Re-write DTR after RTS (as esptool does) |

## Step 2: hooking it to the Luckfox (build done, hardware to do)

- [x] Record the C6 dev board model and check that GPIO18–23 are on its header. **ESP32-C6 SuperMini, all six on the headers** (2026-10-11), so SDIO is wireable.
- [x] Build the host module from the **same esp-hosted-linux commit `172a719`**. (The repo's `VERSION` file says `1.0.6.0.7` while the firmware banner says `NG-1.0.6.0.15`; that's expected for this commit, not a mismatch.)
- [x] Find the RV1106 SDIO pins on the Luckfox header. **Pro/Max: SDIO M0 on pins 21–27** (table above).
- [x] Pro vs Max: **Max (RV1106G3, 256 MB)**, recorded 2026-10-11.
- [x] Device tree: `esp-hosted-sdio-pro-max.dtsi` `#include`d in `rv1106g-luckfox-pico-pro-max.dts`. The decompiled DTB shows `mmc@ff9a0000` `status = "okay"`, 4-bit, 10 MHz, `cap-sdio-irq`, `non-removable`, `no-1-8-v`. Still **unproven on hardware**.
- [x] Kernel config: `CONFIG_BT=m` added (**required even for Wi-Fi only**: `esp32_sdio.ko` always links the BT HCI API). `CONFIG_CFG80211=m` was **already** in the stock build (pulled in by Luckfox's in-tree Wi-Fi drivers, though the defconfig doesn't list it). Both are modules because `boot.img` only has ~458 KB free in its 4 MB partition.
- [x] Buildroot: `wpa_supplicant` v2.10 (nl80211 + `wpa_cli`) and `iw` added, in `/usr/sbin`. `iw` was missing. The stock image *does* have Rockchip's old **v2.6** `wpa_supplicant` in `/usr/bin` (first in `PATH`), so call `/usr/sbin/wpa_supplicant` explicitly.
- [x] Cross-compiled `esp32_sdio.ko`: 136 KB stripped, `depends=cfg80211,bluetooth`, vermagic `5.10.160` = kernel ✅. Needed patch 0001 (`MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver)`), because Rockchip's Android-derived kernel namespaces `filp_open`/`kernel_read`.
- [ ] **Flash** `update.img` (needs my OK; replaces the Max's OS). Fallback: the stock `update.img`.
- [ ] Wire CLK/CMD/D0–D3 + GND (short wires, 10 kΩ pull-ups on CMD/D0–D3). Power the C6 from 5 V, not `3V3(OUT)`.
- [ ] Boot → `cat /sys/bus/sdio/devices/*/uevent` shows `SDIO_ID=0092:6666` → `adb shell mkdir -p /userdata/esp-hosted`, push `esp32_sdio.ko` + `esp-hosted-load.sh` → run it (no `modprobe`: there's no depmod index for `/oem/usr/ko`) → `iw dev` shows `wlanX` → `/usr/sbin/wpa_supplicant -D nl80211` + `dhcpcd` → ping.

### Step 2a: the SDK build (2026-10-11)

- **Where:** the Linux PC `ssh luckfox-build` (`manupa@192.168.1.9`, Pop!_OS 24.04, Ryzen 5 8600G), inside Luckfox's official Docker image `luckfoxtech/luckfox_pico:1.0` (Ubuntu 22.04.3). No sudo needed. SDK `LuckfoxTECH/luckfox-pico` @ `824b817f8`, shallow clone, 4.6 GB, in `~/luckfox/`.
- **How:** scripts in the work folder's `luckfox-sdk/`: `lf.sh` (container, board select without the `lunch` menu, detached builds), `apply-esp-hosted-changes.sh`, `build-esp-hosted-ko.sh`, `step2-pipeline.sh`. Full write-up: `luckfox-sdk/README.md`.
- **Times:** stock build ~65 min (first run, incl. Buildroot downloads), then the ESP-Hosted rebuild ~3 min (incremental).
- **SDK gotchas:**
  - `lunch` is just a `.BoardConfig.mk` symlink.
  - The Buildroot defconfig is copied into Buildroot only on the first unpack, so later edits must be synced.
  - The `boot` partition is 4 MB.
  - The image has no `modinfo`.
  - The container runs as root, which leaves root-owned files and makes git complain about "dubious ownership".
- **Outputs** (work folder `firmware/luckfox-pico-max/`, logs in `luckfox-sdk/logs/`, SHA256 verified): the new image `2026-10-11_pico-max_esp-hosted/update.img` + partition images + `esp32_sdio.ko`/`cfg80211.ko`/`bluetooth.ko` + SDK diff; the **stock** `update.img` as the recovery fallback; all logs.
- **Boot-time loading:** Luckfox's `RkLunch.sh` → `/oem/usr/ko/insmod_ko.sh` (camera/NPU) and `insmod_wifi.sh` (only Luckfox's own AIC8800/ATBM/Hi3861 Wi-Fi). Neither loads ESP-Hosted, so `luckfox-sdk/board/esp-hosted-load.sh` loads `cfg80211 → libaes, ecc, ecdh_generic → bluetooth → esp32_sdio`.

### First hardware test (2026-10-12)

The Max was flashed with the new image and the C6 SuperMini wired to pins 21–28 (no pull-up resistors, as far as I know).

- ✅ **`&sdio` works on the Luckfox**: at boot `mmc2: new high speed SDIO card at address 0001`, 4-bit, 9.9 MHz, `/sys/bus/sdio/devices` shows `0092:6666` + `0092:7777`.
- ✅ `esp-hosted-load.sh`: cfg80211 + bluetooth + `esp32_sdio.ko` loaded. `Chipset=ESP32-C6 detected over SDIO`, firmware `NG-1.0.6.0.15`, **`wlan0` created** (MAC `e4:b0:63:41:e0:1c`).
- ❌ The **first data transfer failed**: `CMD53 write failed ret=-84` (CRC error), then `-110` timeouts. Transport recovery loops (`re-enable function failed -110`). The C6 is wedged until power-cycled (no reset line).
- First guess was signal integrity (no pull-ups). **Disproved:** at a confirmed **1 MHz** (`/sys/kernel/debug/mmcN/clock`, debugfs mounted) the failure is identical.
- **What really happens** (C6 console on COM4 captured at the same time as the Luckfox dmesg):
  - Reads work: the boot event, chip ID and version all arrive intact.
  - Small writes work too: the C6 logs `FW_CMD: Setting STA mode`, `wifi:mode : sta`, `station started`.
  - The **first 512-byte block write** (`cmd_get_tx_power`) fails with CRC `-84` (the C6 reports the data arrived corrupted).
  - Then `Stop Data Path` and the C6 reboots (`rst:0xc (SW_CPU)`). The host can't re-enable the function without a full re-detect, hence the endless `-110` loop.
- **Diagnosis: clock-edge timing.** A failure that doesn't depend on frequency points to edge timing. esp-hosted-linux sets the C6 to `SDIO_SLAVE_TIMING_NSEND_PSAMPLE` (samples host data on the **rising** edge) while advertising high speed. ESP-IDF's own docs say HS should use `PSEND_PSAMPLE`, and the firmware source says to "tune timing" exactly when "the SDIO card is detected but gets problem in Read/Write". The Luckfox's DW-MMC host evidently changes data too close to that edge.
- **Fix to try:** rebuild the C6 firmware with `SDIO_SLAVE_TIMING_NSEND_NSAMPLE` (keep sending on the falling edge, so reads keep working; sample on the **falling** edge, half a clock away from the host's data change). Also set `SDIO_SLAVE_FLAG_INTERNAL_PULLUP`, since there are no external pull-ups.
- **Test round r1** (C6 rebuilt with `NSEND_NSAMPLE` + `SDIO_SLAVE_FLAG_INTERNAL_PULLUP`, patch `scripts/patches/0001-*`): **identical failure.** The sampling edge isn't the cause either. If it were, the first two writes would fail too.
- **Refined diagnosis (r1):**
  - Every host write is a 512-byte block. The first two (init, *Setting STA mode*) succeed; the third fails.
  - With both logs aligned (host probe ≈ C6 `Start Data Path`), the failing write lands at **+72 ms = the C6's `wifi:mode : sta` / `enable tsf`, i.e. the radio/PHY calibration switching on**.
  - `Stop Data Path` + restart is just the host's `CLOSE_DATA_PATH` after the error.
  - Prime suspect is now **power/ground integrity during the C6's RF start-up current burst** (supply sag or ground bounce between the two boards corrupting what the C6 samples). It's independent of clock, edge and pull-ups, which matches everything seen so far.
- **Wiring at r1 (from the user):** C6 powered by the PC's USB, Luckfox by its own supply, **the two 5 V rails tied together**, and **only one GND wire**. The signal wires vary by ±1 cm in length; that's irrelevant here (~50 ps skew against a 100 ns clock period at 10 MHz).
  - Two supplies on one 5 V net push current into each other (risk to the PC's USB port and the adapter).
  - All return current and the SDIO signal returns share one jumper, so the C6's radio start-up spike becomes ground bounce right when the third write arrives.
- **Fix requested (r2):** for development, keep the C6 on PC USB (for COM4) and the Luckfox on its supply, but **remove the 5 V link**. Connect **GND on both pins 23 and 28** (more is better, ideally running next to CLK). Final in-car setup: a single 5 V source (Luckfox pin 40 → C6 5V, C6 USB unplugged).
- ✅ **Fixed (r2, 2026-10-12): wiring.**
  - New wiring: **separate power** (the 5 V link between the boards removed; C6 on PC USB, Luckfox on its own supply), **2 GND wires** (pins 23 + 28) and **decoupling capacitors** added by the user.
  - Result: **`RESULT: PASS`**. 0 transport errors; the C6 logs `station started` and `wifi scanning done`; `iw dev wlan0 scan` sees 7 networks.
  - Stress: 5 back-to-back scans gave 5, 8, 10, 10, 10 BSS with 0 errors. **r3** (fresh C6 reset) PASS again.
  - Bus: 4-bit, 9.9 MHz, `sd high-speed`, still without external pull-ups. The C6 runs the patched firmware (`NSEND_NSAMPLE` + internal pull-ups); whether the stock `NSEND_PSAMPLE` also works with the good wiring hasn't been A/B-tested yet.
  - **Lesson:** a single GND wire plus two supplies tied on one 5 V net corrupted host→C6 writes exactly when the C6's radio started. Use ≥2 GNDs, one power source per board (or one shared source), and decoupling.
- Test loop: `scripts/test-luckfox-sdio.sh <name> [clock_hz]` (work folder) resets the C6 via COM4, re-detects the card on the Luckfox, loads the driver, runs `iw scan` and prints PASS/FAIL with both logs.
- Handy for testing without a reboot: `rmmod esp32_sdio` → reset the C6 over COM4 (RTS) → `echo ff9a0000.mmc > /sys/bus/platform/drivers/dwmmc_rockchip/unbind` then `bind` (forces a re-detect) → `insmod`. Access: `ssh luckfox` (root@192.168.1.64).

> [!tip] Plan B: if the `&sdio` controller (pins 21–27) won't enumerate
> Wire the C6 to the Pro/Max **microSD slot** (`&sdmmc`, already configured with `supports-sdio`, `cap-sdio-irq` and `non-removable`) through a microSD breakout/sniffer adapter. It still needs **the new image**: the stock kernel has no `bluetooth.ko`, so `esp32_sdio.ko` can't load on it. The only thing Plan B avoids is relying on the unproven `&sdio` controller. Cost: no SD card. The board boots from SPI-NAND, but ALPR storage would then live on the NAND.

## Related Notes

- [[Projects/Electronics/OSS/Luckfox-ALPR/00-INDEX|Luckfox ALPR index]]
- [[01-Idea-and-Conversation]] — where the ESP-Hosted idea came from
- [[03-System-Architecture]] — connectivity options and the UART uplink wiring this replaces
- [[05-Dev-Environment-and-Flashing]] — device tree and kernel build for step 2
- [[Gate Remote - Firmware Architecture]] — my other ESP-IDF project
