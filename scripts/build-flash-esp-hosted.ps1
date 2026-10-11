# Build the ESP-Hosted-Linux co-processor firmware for the ESP32-C6 and flash it.
#
# Prerequisite: scripts\setup-idf61.ps1 has been run once (pinned ESP-IDF v6.1 + hosted Wi-Fi libs).
#
# Usage (from any directory, in a fresh Windows PowerShell; do NOT load the v5.5.4 EIM profile first):
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-flash-esp-hosted.ps1               # build + flash COM4
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-flash-esp-hosted.ps1 -NoFlash      # build only
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-flash-esp-hosted.ps1 -Port COM7 -Clean
#
# Transport: SDIO (the esp-hosted-linux default for ESP32-C6). The SPI build is NOT offered here:
# its SPI CS is hard-coded to GPIO10 in network_adapter\main\spi_slave_api.c, and GPIO10/GPIO11
# are not bonded out on this board's ESP32-C6FH4 (QFN32, in-package flash). See README.md.

param(
    [string]$Port = "COM4",
    [string]$Target = "esp32c6",
    [switch]$NoFlash,
    [switch]$Clean,
    [string]$ToolsPath = (Join-Path $env:USERPROFILE ".espressif-idf61")
)

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$EspDriver = Join-Path $Root "esp-hosted-linux\esp\esp_driver"
$App = Join-Path $EspDriver "network_adapter"
$Idf = Join-Path $EspDriver "esp-idf"

if (-not (Test-Path (Join-Path $Idf "export.ps1"))) {
    throw "ESP-IDF v6.1 not found at $Idf. Run scripts\setup-idf61.ps1 first."
}

# The ESP-Hosted FullMAC Wi-Fi libs must be in the IDF tree, not the stock ones, or linking fails
# with "undefined reference to ieee80211_send_mgmt_internal" etc. Check libnet80211.a byte-for-byte.
$hostedLib = Join-Path $EspDriver "lib\$Target\libnet80211.a"
$idfLib = Join-Path $Idf "components\esp_wifi\lib\$Target\libnet80211.a"
if ((Get-FileHash $hostedLib).Hash -ne (Get-FileHash $idfLib).Hash) {
    throw "esp-idf\components\esp_wifi\lib has the stock Wi-Fi libs, not the ESP-Hosted ones. Re-run scripts\setup-idf61.ps1."
}
# Stop the IDF build's submodule check from ever "repairing" esp_wifi\lib back to stock.
$env:IDF_SKIP_CHECK_SUBMODULES = "1"

# Keep the v6.1 toolchain separate from the EIM-managed v5.5.4 install.
$env:IDF_TOOLS_PATH = $ToolsPath
Remove-Item Env:IDF_PYTHON_ENV_PATH -ErrorAction SilentlyContinue
. (Join-Path $Idf "export.ps1")

Set-Location $App

if ($Clean) {
    Remove-Item -Recurse -Force build, sdkconfig -ErrorAction SilentlyContinue
}

# set-target only when needed: it regenerates sdkconfig from the defaults.
$needTarget = -not (Test-Path sdkconfig) -or -not (Select-String -Path sdkconfig -Pattern "^CONFIG_IDF_TARGET=`"$Target`"" -Quiet)
if ($needTarget) {
    idf.py set-target $Target
    if ($LASTEXITCODE -ne 0) { throw "idf.py set-target failed" }
}

# Guard: refuse to flash anything that is not an SDIO build.
if (-not (Select-String -Path sdkconfig -Pattern "^CONFIG_ESP_SDIO_HOST_INTERFACE=y" -Quiet)) {
    throw "sdkconfig is not set to the SDIO transport. Run with -Clean, or fix it in 'idf.py menuconfig'."
}

# This folder is deep (~95 chars to esp-idf\components), and main\app_main.c gets ~150 -I paths,
# which overflowed Windows' 32K CreateProcess limit:
#   "ninja: fatal: CreateProcess: The parameter is incorrect. (is the command line too long?)"
# Forcing response files makes ninja pass the flags/includes via a file instead.
$CMakeArgs = @("-DCMAKE_NINJA_FORCE_RESPONSE_FILE=ON")

idf.py @CMakeArgs build
if ($LASTEXITCODE -ne 0) { throw "idf.py build failed" }
idf.py @CMakeArgs size

if (-not $NoFlash) {
    idf.py @CMakeArgs -p $Port flash
    if ($LASTEXITCODE -ne 0) { throw "idf.py flash failed" }
    Write-Host ""
    Write-Host "Flashed. Check the boot log with:"
    Write-Host "  python scripts\serial_capture.py --port $Port --seconds 10"
    Write-Host "or interactively: idf.py -p $Port monitor   (Ctrl+] to quit)"
}
