@echo off
rem Start the native Windows build (run setup.ps1 first).
set "EXE=%~dp0nascar\out\build\win-amd64-release\nascar.exe"
if not exist "%EXE%" (
  echo nascar.exe not found. Build it first:  pwsh .\setup.ps1 -Iso "path\to\your.iso"
  pause
  exit /b 1
)
start "" /D "%~dp0nascar\out\build\win-amd64-release" "%EXE%"
