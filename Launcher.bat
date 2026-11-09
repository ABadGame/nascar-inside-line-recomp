@echo off
rem Opens the build/play launcher. Uses PowerShell 7 if installed, else Windows PowerShell.
where pwsh >nul 2>nul
if %errorlevel%==0 (
  start "" pwsh -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0tools\launcher.ps1"
) else (
  start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0tools\launcher.ps1"
)
