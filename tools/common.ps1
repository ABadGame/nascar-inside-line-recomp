# Shared helpers for the PowerShell tools. Dot-source it: . "$PSScriptRoot\common.ps1"

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

# Locate vcvars64.bat of a Visual Studio install that has the Clang tools.
function Get-VcVars {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "Visual Studio was not found. Install Visual Studio 2022 or newer with the " +
              "'Desktop development with C++' workload and the 'C++ Clang tools for Windows' component."
    }
    $inst = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Llvm.Clang -property installationPath
    if (-not $inst) {
        throw "Visual Studio is installed, but without the 'C++ Clang tools for Windows' component. " +
              "Add it in the Visual Studio Installer (Modify > Individual components)."
    }
    $bat = Join-Path $inst "VC\Auxiliary\Build\vcvars64.bat"
    if (-not (Test-Path $bat)) { throw "vcvars64.bat not found under $inst" }
    return $bat
}

# Run a command line inside the Visual Studio x64 developer environment.
# Returns the exit code. Output goes to the console unless redirected in $Command.
function Invoke-VsCmd([string]$Command) {
    $bat = Get-VcVars
    cmd /c "`"$bat`" >nul 2>nul && $Command"
    return $LASTEXITCODE
}
