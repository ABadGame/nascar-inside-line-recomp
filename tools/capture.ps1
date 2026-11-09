# Launch nascar.exe windowed, wait, capture ONLY the game window's own content
# (PrintWindow with PW_RENDERFULLCONTENT - other windows on screen are never
# captured, even if they overlap it), then close the game.
# usage: pwsh tools\capture.ps1 -Tag scale1 -Seconds 45 -ExtraArgs "--resolution_scale=1"
param([string]$Tag = "cap", [int]$Seconds = 45, [string[]]$ExtraArgs = @())

$ErrorActionPreference = "Stop"
$r = Split-Path -Parent $PSScriptRoot
$d = "$r\nascar\out\build\win-amd64-release"
$w = "$r\work"

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[Win]::SetProcessDPIAware() | Out-Null

$log = "$w\$Tag.log"
Remove-Item $log -ErrorAction SilentlyContinue
$p = Start-Process -FilePath "$d\nascar.exe" -WorkingDirectory $d -PassThru `
    -ArgumentList (@("--log_file=`"$log`"", "--fullscreen=false", "--window_width=1280", "--window_height=720") + $ExtraArgs)
Start-Sleep -Seconds $Seconds
if ($p.HasExited) { "game exited early (0x{0:X8})" -f $p.ExitCode; exit 1 }
$p.Refresh()
$h = $p.MainWindowHandle
$rc = New-Object Win+RECT
[Win]::GetClientRect($h, [ref]$rc) | Out-Null
$bmp = New-Object System.Drawing.Bitmap ($rc.R - $rc.L), ($rc.B - $rc.T)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
# 1 = PW_CLIENTONLY, 2 = PW_RENDERFULLCONTENT (needed for D3D swap chains)
$ok = [Win]::PrintWindow($h, $hdc, 3)
$g.ReleaseHdc($hdc)
$png = "$w\$Tag.png"
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Stop-Process -Id $p.Id -Force -Confirm:$false
"saved $png ($($rc.R)x$($rc.B)) printwindow=$ok"
