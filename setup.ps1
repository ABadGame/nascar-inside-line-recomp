# One-step build of the native Windows port from YOUR OWN copy of the game.
#
#   pwsh .\setup.ps1 -Iso "D:\path\to\NASCAR the Game - Inside Line (USA).iso"
#
# Steps: check tools -> fetch + patch the ReXGlue SDK -> extract the disc ->
# verify the game executables -> recompile (codegen) -> build -> ready to play.
# Safe to re-run: finished steps are skipped or redone incrementally.
param(
    [Parameter(Mandatory = $true)][string]$Iso,
    [switch]$KeepIntros,     # keep the Activision logo + trailer videos
    [int]$Jobs = 8           # parallel compile jobs (each can need 1-3 GB RAM)
)

# Not "Stop": in Windows PowerShell 5.1 that turns ANY text a program writes to
# stderr (git progress, "not a git repository", ...) into a fatal error. Every
# step below checks exit codes itself and stops with Fail instead.
$ErrorActionPreference = "Continue"
. "$PSScriptRoot\tools\common.ps1"
$r = $PSScriptRoot
$logs = "$r\work"
New-Item -ItemType Directory -Force $logs | Out-Null

# The recompilation (function fixups, setjmp/longjmp addresses) is specific to
# this exact release: NASCAR The Game: Inside Line (USA), Xbox 360, title 415608D2.
$Expected = @{
    "default.xex" = "1ACF6131ED2DEFB2A3458E28C63ADA82B55EFDF705B6DE68C5D02BFB783DFA71"
    "extras.xex"  = "9B189D4F3738ADF893D60BD1344749DF6D705DACD87019E9942FD208AC9B434B"
}

function Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Fail([string]$Text) { Write-Host "`nERROR: $Text" -ForegroundColor Red; exit 1 }

# Run a program, show its stdout+stderr as plain indented log lines (5.1 would
# otherwise print stderr as red "NativeCommandError" records), return its exit code.
function Run([string]$Exe, [string[]]$ArgList, [switch]$Quiet) {
    $ErrorActionPreference = "Continue"
    if ($Quiet) { & $Exe @ArgList *> $null }
    else { & $Exe @ArgList 2>&1 | ForEach-Object { Write-Host "  $_" } }
    return $LASTEXITCODE
}

# --- 1. Tools ----------------------------------------------------------------
Step "Checking required tools"
foreach ($c in "git", "cmake", "ninja", "python") {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
        Fail "'$c' was not found on PATH. See README.md > Requirements."
    }
}
try { $null = Get-VcVars } catch { Fail $_.Exception.Message }
if (-not (Test-Path $Iso)) { Fail "ISO not found: $Iso" }
Write-Host "  ok"

# --- 2. SDK ------------------------------------------------------------------
Step "Fetching the ReXGlue SDK and applying this project's patches"
$sdk = "$r\tools\rexglue-sdk"
$SdkUrl = "https://github.com/rexglue/rexglue-sdk.git"
$SdkCommit = "546a082a4356173635f6c40510a41ff53e518b5a"   # must match the submodule pin
if (Test-Path "$r\.git") {
    # Cloned with git: use the submodule.
    Write-Host "  git checkout - updating the tools/rexglue-sdk submodule"
    if (Run git @("-C", $r, "-c", "core.longpaths=true", "submodule", "update", "--init", "--recursive", "tools/rexglue-sdk")) {
        Fail "git submodule update failed (see the lines above)"
    }
} elseif (-not (Test-Path "$sdk\CMakeLists.txt")) {
    # Downloaded as a ZIP (no .git): clone the SDK at the pinned commit.
    Write-Host "  ZIP download - cloning the ReXGlue SDK (a few hundred MB)"
    Remove-Item $sdk -Recurse -Force -ErrorAction SilentlyContinue
    if (Run git @("-c", "core.longpaths=true", "clone", "--progress", $SdkUrl, $sdk)) {
        Fail "could not clone the ReXGlue SDK from $SdkUrl (check your internet connection; see the lines above)"
    }
    if (Run git @("-C", $sdk, "-c", "core.longpaths=true", "checkout", "--quiet", $SdkCommit)) {
        Fail "could not check out ReXGlue commit $SdkCommit"
    }
    if (Run git @("-C", $sdk, "-c", "core.longpaths=true", "submodule", "update", "--init", "--recursive")) {
        Fail "could not fetch the SDK's own submodules (see the lines above)"
    }
}
foreach ($p in Get-ChildItem "$r\patches\rexglue-sdk\*.patch" | Sort-Object Name) {
    if ((Run git @("-C", $sdk, "apply", "--check", "-R", "--whitespace=nowarn", $p.FullName) -Quiet) -eq 0) {
        Write-Host "  already applied: $($p.Name)"; continue
    }
    if (Run git @("-C", $sdk, "apply", "--whitespace=nowarn", $p.FullName)) {
        Fail "could not apply $($p.Name) - is tools/rexglue-sdk at the pinned commit?"
    }
    Write-Host "  applied: $($p.Name)"
}

# --- 3. Game files -----------------------------------------------------------
Step "Extracting game files from the ISO (about 2.4 GB)"
if (Run python @("-I", "$r\tools\extract_iso.py", $Iso, "$r\game")) {
    Fail "ISO extraction failed (is it an Xbox 360 XGD2 image?)"
}

Step "Verifying the game executables"
foreach ($name in $Expected.Keys) {
    $hash = (Get-FileHash "$r\game\$name" -Algorithm SHA256).Hash
    if ($hash -ne $Expected[$name]) {
        Fail "$name does not match the supported release (got $hash). Only NASCAR The Game: Inside Line (USA), title update 0, is supported."
    }
    Write-Host "  $name ok"
}
New-Item -ItemType Directory -Force "$r\update" | Out-Null
if (-not $KeepIntros) {
    $vids = "$r\game\nas2\xenon\data\videos"
    $off = "$r\game_disabled\nas2\xenon\data\videos"
    New-Item -ItemType Directory -Force $off | Out-Null
    Get-ChildItem "$vids\*.bik" -ErrorAction SilentlyContinue | Move-Item -Destination $off -Force
    Write-Host "  intro videos moved to game_disabled\ (re-run with -KeepIntros to keep them)"
}

# --- 4. Recompile ------------------------------------------------------------
Step "Building the rexglue tool"
Push-Location $sdk
if (-not (Test-Path "out\build\win-amd64\build.ninja")) {
    if (Invoke-VsCmd "cmake --preset win-amd64 > `"$logs\setup-sdk-configure.log`" 2>&1") { Pop-Location; Fail "SDK configure failed - see work\setup-sdk-configure.log" }
}
if (Invoke-VsCmd "cmake --build out/build/win-amd64 --config Release --target rexglue > `"$logs\setup-sdk-build.log`" 2>&1") { Pop-Location; Fail "rexglue build failed - see work\setup-sdk-build.log" }
Pop-Location

Step "Recompiling the game code to C++ (20-30 minutes)"
Push-Location "$r\nascar"
& "$sdk\out\win-amd64\Release\rexglue.exe" codegen nascar_manifest.toml *> "$logs\setup-codegen.log"
$cg = $LASTEXITCODE
Pop-Location
if ($cg) { Fail "codegen failed - see work\setup-codegen.log" }

Step "Extracting the game's title icon for nascar.exe"
# Taken from YOUR default.xex into nascar\generated\icon\ (git-ignored); optional.
$iconDir = "$r\nascar\generated\icon"
& "$sdk\out\win-amd64\Release\rexglue.exe" extract-icon "$r\game\default.xex" "$iconDir\title.png" *> "$logs\setup-icon.log"
if ($LASTEXITCODE -eq 0) {
    python -I "$r\tools\png_to_ico.py" "$iconDir\title.png" "$iconDir\nascar.ico" "$iconDir\nascar.rc"
} else {
    Write-Host "  no icon extracted (see work\setup-icon.log) - building without it"
}

# --- 5. Build ----------------------------------------------------------------
Step "Compiling nascar.exe (30-60 minutes; downloads AMD FidelityFX on first run)"
Push-Location "$r\nascar"
if (-not (Test-Path "out\build\win-amd64-release\build.ninja")) {
    if (Invoke-VsCmd "cmake --preset win-amd64-release > `"$logs\setup-configure.log`" 2>&1") { Pop-Location; Fail "configure failed - see work\setup-configure.log" }
}
if (Invoke-VsCmd "cmake --build --preset win-amd64-release -j $Jobs > `"$logs\setup-build.log`" 2>&1") { Pop-Location; Fail "build failed - see work\setup-build.log" }
Pop-Location

Step "Done"
Write-Host "  Start the game with Play.bat. Settings: nascar\out\build\win-amd64-release\nascar.toml" -ForegroundColor Green
