# Copy of esp-hosted-linux/esp/esp_driver/setup.ps1 (upstream master 172a719, 2026-10-08)
# with the minimum changes needed to run on Windows PowerShell 5.1 on this PC:
#
#   1. [Alias("h", "help")] -> [Alias("h")]. On PS 5.1 the alias "help" clashes with the
#      parameter's own name "Help", so upstream setup.ps1 fails before doing anything:
#      "The parameter 'Help' cannot be specified because it conflicts with the parameter alias".
#   2. git clone / submodule update get "-c core.longpaths=true -c core.autocrlf=false",
#      so deep submodule paths check out and the IDF patches apply (no CRLF conversion).
#   3. IDF_TOOLS_PATH defaults to a dedicated folder (C:\Users\<me>\.espressif-idf61), so the
#      v6.1 toolchain never mixes with the EIM-managed v5.5.4 install in C:\Espressif\tools.
#   4. The script cd's into esp-hosted-linux\esp\esp_driver itself (upstream uses relative paths).
#   5. install.ps1 is called with "esp32c6" so only the RISC-V toolchain is downloaded.
#      Use ".\install.ps1" with no argument (or "esp32c6,esp32c3,...") if you add other chips.
#   6. When replacing esp-idf\components\esp_wifi\lib, the submodule's hidden ".git" file is kept
#      (see the comment at the bottom). Without this the first build restores the stock Wi-Fi libs.
#
# Everything else (pinned IDF commit from .env, rom.patch + OpenThread RCP patch, replacing
# esp-idf\components\esp_wifi\lib with the hosted FullMAC libs) is unchanged on purpose:
# without those steps the firmware is not ESP-Hosted.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-idf61.ps1

param(
    [Alias("f")]
    [switch]$Force,
    [Alias("u", "update-idf")]
    [switch]$UpdateIdf,
    [Alias("h")]
    [switch]$Help,
    [string]$EspDriverDir = (Join-Path $PSScriptRoot "..\esp-hosted-linux\esp\esp_driver"),
    [string]$ToolsPath = (Join-Path $env:USERPROFILE ".espressif-idf61")
)

$ErrorActionPreference = "Continue"
$env:IDF_TOOLS_PATH = $ToolsPath
Write-Host "IDF_TOOLS_PATH = $env:IDF_TOOLS_PATH"
Set-Location (Resolve-Path $EspDriverDir)
Write-Host "Working in $(Get-Location)"

$GitSafe = @("-c", "core.longpaths=true", "-c", "core.autocrlf=false")

function Apply-IdfPatchOnce {
    param([Parameter(Mandatory = $true)][string]$Patch)

    $null = & git apply --recount --reverse --check $Patch 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "ESP hosted: patch already applied: $Patch"
        return
    }

    & git apply --recount --check $Patch
    if ($LASTEXITCODE -ne 0) {
        throw "ESP hosted: patch does not apply cleanly: $Patch"
    }
    & git apply --recount $Patch
    if ($LASTEXITCODE -ne 0) {
        throw "ESP hosted: failed to apply patch: $Patch"
    }
}

function Apply-HostedIdfPatches {
    Apply-IdfPatchOnce "../lib/rom.patch"

    $kconfig = "components/openthread/Kconfig"
    if (Select-String -Path $kconfig -SimpleMatch "config OPENTHREAD_RCP_CUSTOM" -Quiet) {
        Write-Host "ESP hosted: native OpenThread custom RCP transport present"
        return
    }

    Apply-IdfPatchOnce "../lib/idf-openthread-custom-rcp-v6.1.patch"
}

function Show-Help {
    Write-Host "Usage: ./setup-idf61.ps1 [-f] [-u|--update-idf] [-h]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -f             Force reset and re-clone esp-idf (will delete all local changes)"
    Write-Host "  -u             Only update esp-idf to specific commit (resets esp-idf dir only)"
    Write-Host "  -h             Show this help message"
    exit 0
}

if ($Help) { Show-Help }

$envFile = ".env"
if (-not (Test-Path $envFile)) {
    Write-Error ".env file not found!"
    exit 1
}

# Parse .env
Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]*)=(.*)') {
        $name = $matches[1].Trim()
        $value = $matches[2].Trim().Trim('"')
        Set-Item -Path "env:$name" -Value $value
    }
}

if (-not $env:IDF_TAG -or -not $env:IDF_COMMIT) {
    Write-Error "IDF_TAG or IDF_COMMIT not defined in .env"
    exit 1
}

$IDF_TAG = $env:IDF_TAG
$IDF_COMMIT = $env:IDF_COMMIT
$ESP_IDF_DIR = "esp-idf"

# Check current esp-idf status
$ESP_IDF_PRESENT = Test-Path $ESP_IDF_DIR
$ESP_IDF_CORRECT = $false
$CURRENT_COMMIT = ""

if ($ESP_IDF_PRESENT) {
    Push-Location $ESP_IDF_DIR
    try {
        $CURRENT_COMMIT = git rev-parse HEAD 2>$null
        if ($CURRENT_COMMIT -eq $IDF_COMMIT) {
            $ESP_IDF_CORRECT = $true
        }
    } catch {}
    Pop-Location
}

# Commit mismatch but no -f or -u
if ($ESP_IDF_PRESENT -and -not $ESP_IDF_CORRECT -and -not $Force -and -not $UpdateIdf) {
    Write-Error "esp-idf is at $CURRENT_COMMIT but expected $IDF_COMMIT. Use -f to reset or -u to update."
    exit 1
}

# Handle -f (full reset)
if ($Force) {
    $response = Read-Host "WARNING: This will reset the repo and delete all local changes. Continue? [y/N]"
    if ($response -ne 'y') { Write-Host "Aborted."; exit 1 }

    git reset --hard
    Remove-Item -Recurse -Force $ESP_IDF_DIR -ErrorAction SilentlyContinue
}

# Clone if not present
if (-not (Test-Path $ESP_IDF_DIR)) {
    Write-Host "ESP hosted: cloning esp-idf at commit $IDF_COMMIT (tag: $IDF_TAG)"
    git @GitSafe clone --branch $IDF_TAG --depth 100 https://github.com/espressif/esp-idf.git $ESP_IDF_DIR
    Push-Location $ESP_IDF_DIR
    git config core.longpaths true
    git config core.autocrlf false
    git checkout -f $IDF_COMMIT
    Write-Host "ESP hosted: applying IDF patches"
    Apply-HostedIdfPatches
    Write-Host "ESP hosted: initializing submodules"
    git @GitSafe submodule update --init --depth 1 --recursive
    Write-Host "ESP hosted: installing prerequisites for esp-idf"
    .\install.ps1 esp32c6
    Pop-Location
    $ESP_IDF_PRESENT = $true
    $ESP_IDF_CORRECT = $true
}

# Handle -u (update-only)
if ($UpdateIdf) {
    $response = Read-Host "WARNING: This will reset changes inside esp-idf only. Continue? [y/N]"
    if ($response -ne 'y') { Write-Host "Aborted."; exit 1 }

    if (-not (Test-Path $ESP_IDF_DIR)) {
        Write-Host "esp-idf not found. Cloning it now..."
        git @GitSafe clone --branch $IDF_TAG --depth 100 https://github.com/espressif/esp-idf.git $ESP_IDF_DIR
    }

    Push-Location $ESP_IDF_DIR
    git fetch --depth 100 origin $IDF_TAG
    git reset --hard $IDF_COMMIT
    git clean -fdx
    Write-Host "ESP hosted: applying IDF patches"
    Apply-HostedIdfPatches
    Write-Host "ESP hosted: updating submodules"
    git @GitSafe submodule update --init --depth 1 --recursive
    Write-Host "ESP hosted: installing prerequisites for esp-idf"
    .\install.ps1 esp32c6
    Pop-Location
}

# Existing correct checkouts may predate a newly added patch. Re-run the
# idempotent patch step on every setup invocation.
Push-Location $ESP_IDF_DIR
try {
    Apply-HostedIdfPatches
} finally {
    Pop-Location
}

# Copy wireless libs (always after valid clone or update)
Write-Host "ESP hosted: replacing wireless libraries"

$destRoot = ".\esp-idf\components\esp_wifi\lib\"
if (Test-Path $destRoot) {
    # Change 6: keep the submodule's hidden ".git" file. Upstream's Remove-Item "$destRoot\*" -Force
    # deletes it on Windows (Linux's rm glob skips dotfiles); the submodule then shows as missing ("-"),
    # and the IDF build's git_submodules.cmake runs "git submodule update --init", silently putting the
    # stock Wi-Fi libs back -> link errors (undefined ieee80211_send_mgmt_internal, ...).
    Get-ChildItem $destRoot -Force | Where-Object { $_.Name -ne ".git" } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} else {
    New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
}

Copy-Item ".\lib\*" $destRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "###### Setup Done ######"
