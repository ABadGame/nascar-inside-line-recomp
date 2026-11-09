# Developer loop: codegen -> incremental build -> timed launch, logging under work\.
# usage: pwsh tools\regen_build_run.ps1 -Tag run2 [-Seconds 90] [-SkipCodegen] [-ExtraArgs "--flag=x"]
param([string]$Tag = "run", [int]$Seconds = 90, [switch]$SkipCodegen, [string[]]$ExtraArgs = @())

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"
$r   = $RepoRoot
$rex = "$r\tools\rexglue-sdk\out\win-amd64\Release\rexglue.exe"
$w   = "$r\work"
New-Item -ItemType Directory -Force $w | Out-Null

if (-not $SkipCodegen) {
    # rebuild the rexglue CLI first, in case the SDK patches changed
    Push-Location "$r\tools\rexglue-sdk"
    $cliExit = Invoke-VsCmd "cmake --build out/build/win-amd64 --config Release --target rexglue > `"$w\$Tag.cli.log`" 2>&1"
    Pop-Location
    if ($cliExit -ne 0) { "rexglue CLI build failed"; Get-Content "$w\$Tag.cli.log" -Tail 15; exit 1 }

    Push-Location "$r\nascar"
    $t = Measure-Command { & $rex --log-file "$w\$Tag.codegen.log" codegen nascar_manifest.toml *> "$w\$Tag.codegen.out" }
    $cgExit = $LASTEXITCODE
    Pop-Location
    "codegen exit $cgExit ($([int]$t.TotalMinutes) min)"
    Select-String -Path "$w\$Tag.codegen.out" -Pattern 'Unimplemented|Unresolved|error|summary' | ForEach-Object Line
    if ($cgExit -ne 0) { exit 1 }
}

Push-Location "$r\nascar"
$t = Measure-Command { $script:buildExit = Invoke-VsCmd "cmake --build --preset win-amd64-release -j 8 > `"$w\$Tag.build.log`" 2>&1" }
Pop-Location
"build exit $buildExit ($([int]$t.TotalMinutes) min)"
if ($buildExit -ne 0) { Select-String -Path "$w\$Tag.build.log" -Pattern 'error' | Select-Object -First 10 | ForEach-Object Line; exit 1 }

$exe = "$r\nascar\out\build\win-amd64-release\nascar.exe"
$log = "$w\$Tag.log"
Remove-Item $log -ErrorAction SilentlyContinue
$p = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -PassThru `
    -ArgumentList (@("--log_file=`"$log`"", "--fullscreen=false", "--log_level=debug") + $ExtraArgs) `
    -RedirectStandardError "$w\$Tag.stderr" -RedirectStandardOutput "$w\$Tag.stdout"
if ($p.WaitForExit($Seconds * 1000)) { "game exited with code 0x{0:X8}" -f $p.ExitCode }
else { "game still running after ${Seconds}s - stopped"; Stop-Process -Id $p.Id -Force -Confirm:$false }
if (Test-Path $log) { "log lines: " + (Get-Content $log).Count; Get-Content $log -Tail 6 }
