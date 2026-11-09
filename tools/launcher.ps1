# NASCAR Inside Line - PC port launcher.
# Pick your ISO, install missing build tools, build, play. Started by Launcher.bat.
# Runs setup.ps1 in a background process and follows its log, so the window
# stays responsive during the (long) build.

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
. "$PSScriptRoot\common.ps1"

$Root   = $RepoRoot
$Work   = Join-Path $Root "work"
$ExeDir = Join-Path $Root "nascar\out\build\win-amd64-release"
$Exe    = Join-Path $ExeDir "nascar.exe"
$State  = Join-Path $Work "launcher.json"
New-Item -ItemType Directory -Force $Work | Out-Null

# --- prerequisites -----------------------------------------------------------
$VsOverride = "--wait --passive --includeRecommended " +
              "--add Microsoft.VisualStudio.Workload.VCTools " +
              "--add Microsoft.VisualStudio.Component.VC.Llvm.Clang " +
              "--add Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset"
$Prereqs = @(
    @{ Name = "Visual Studio Build Tools + Clang 20+"; Id = "Microsoft.VisualStudio.BuildTools"; Override = $VsOverride; Check = {
        try {
            $bat = Get-VcVars
            # vcvars64.bat is in <VS>\VC\Auxiliary\Build; Clang is in <VS>\VC\Tools\Llvm.
            $vc = Split-Path (Split-Path (Split-Path $bat))
            $clang = Join-Path $vc "Tools\Llvm\x64\bin\clang-cl.exe"
            if (-not (Test-Path $clang)) { return "Clang tools missing" }
            $v = (& $clang --version 2>$null | Select-Object -First 1) -replace '.*version (\d+)\..*', '$1'
            if ([int]$v -lt 20) { return "Clang $v is too old (need 20+)" }
            return $null
        } catch { return "not installed" } } }
    @{ Name = "Git";    Id = "Git.Git";            Check = { if (Get-Command git -ErrorAction SilentlyContinue) { $null } else { "not installed" } } }
    @{ Name = "CMake";  Id = "Kitware.CMake";      Check = { if (Get-Command cmake -ErrorAction SilentlyContinue) { $null } else { "not installed" } } }
    @{ Name = "Ninja";  Id = "Ninja-build.Ninja";  Check = { if (Get-Command ninja -ErrorAction SilentlyContinue) { $null } else { "not installed" } } }
    @{ Name = "Python 3"; Id = "Python.Python.3.13"; Check = {
        $v = & python --version 2>&1
        if ("$v" -match 'Python 3\.(\d+)' -and [int]$Matches[1] -ge 10) { $null } else { "not installed" } } }
)

function Update-Path {
    # Pick up tools installed since this window opened.
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
}

# --- saved state -------------------------------------------------------------
$saved = [pscustomobject]@{ iso = ""; intros = $false; jobs = 0 }
if (Test-Path $State) { try { $saved = Get-Content $State -Raw | ConvertFrom-Json } catch {} }
function Save-State { @{ iso = $isoBox.Text; intros = $introsBox.Checked; jobs = [int]$jobsBox.Value } |
    ConvertTo-Json | Set-Content $State }

# --- window ------------------------------------------------------------------
$font = New-Object System.Drawing.Font("Segoe UI", 9.5)
$form = New-Object System.Windows.Forms.Form -Property @{
    Text = "NASCAR The Game: Inside Line - PC port"; Size = New-Object System.Drawing.Size(820, 720)
    StartPosition = "CenterScreen"; Font = $font; MinimumSize = New-Object System.Drawing.Size(720, 600)
}
if (Test-Path "$Root\nascar\generated\icon\nascar.ico") {
    $form.Icon = New-Object System.Drawing.Icon("$Root\nascar\generated\icon\nascar.ico")
}

function Add-Ctl($ctl, $x, $y, $w, $h, $anchor = "Top,Left") {
    $ctl.Location = New-Object System.Drawing.Point($x, $y)
    $ctl.Size = New-Object System.Drawing.Size($w, $h)
    $ctl.Anchor = $anchor
    $form.Controls.Add($ctl); $ctl
}

$null = Add-Ctl (New-Object System.Windows.Forms.Label -Property @{
    Text = "Builds a native Windows version from YOUR OWN copy of the game. No game files are downloaded or shared." }) 16 12 770 22

# ISO row
$null = Add-Ctl (New-Object System.Windows.Forms.Label -Property @{ Text = "Game ISO:" }) 16 46 70 22
$isoBox = Add-Ctl (New-Object System.Windows.Forms.TextBox) 90 43 590 24 "Top,Left,Right"
$isoBox.Text = "$($saved.iso)"
$browse = Add-Ctl (New-Object System.Windows.Forms.Button -Property @{ Text = "Browse..." }) 690 41 100 28 "Top,Right"

# Requirements
$reqList = Add-Ctl (New-Object System.Windows.Forms.ListView -Property @{
    View = "Details"; FullRowSelect = $true; HeaderStyle = "Nonclickable" }) 16 82 664 160 "Top,Left,Right"
$null = $reqList.Columns.Add("Requirement", 330); $null = $reqList.Columns.Add("Status", 310)
$recheck = Add-Ctl (New-Object System.Windows.Forms.Button -Property @{ Text = "Re-check" }) 690 82 100 28 "Top,Right"
$install = Add-Ctl (New-Object System.Windows.Forms.Button -Property @{ Text = "Install missing" }) 690 116 100 44 "Top,Right"

# Options
$introsBox = Add-Ctl (New-Object System.Windows.Forms.CheckBox -Property @{ Text = "Keep intro videos" }) 16 252 160 24
$introsBox.Checked = [bool]$saved.intros
$null = Add-Ctl (New-Object System.Windows.Forms.Label -Property @{ Text = "Compile jobs:" }) 190 254 90 22
$jobsBox = Add-Ctl (New-Object System.Windows.Forms.NumericUpDown -Property @{ Minimum = 1; Maximum = 64 }) 282 251 60 24
$ramGb = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$jobsBox.Value = if ($saved.jobs) { $saved.jobs } else { [math]::Max(1, [math]::Min([Environment]::ProcessorCount, [math]::Floor($ramGb / 4))) }
$null = Add-Ctl (New-Object System.Windows.Forms.Label -Property @{
    Text = "(each job can use 1-3 GB of RAM; this PC has $ramGb GB)"; ForeColor = "DimGray" }) 350 254 330 22

# Build controls
$build  = Add-Ctl (New-Object System.Windows.Forms.Button -Property @{ Text = "Build" }) 16 286 120 34
$cancel = Add-Ctl (New-Object System.Windows.Forms.Button -Property @{ Text = "Cancel"; Enabled = $false }) 144 286 90 34
$progress = Add-Ctl (New-Object System.Windows.Forms.ProgressBar -Property @{ Maximum = 9 }) 244 292 546 22 "Top,Left,Right"
$status = Add-Ctl (New-Object System.Windows.Forms.Label -Property @{ Text = "" }) 16 326 774 22 "Top,Left,Right"
$log = Add-Ctl (New-Object System.Windows.Forms.TextBox -Property @{
    Multiline = $true; ReadOnly = $true; ScrollBars = "Vertical"; WordWrap = $false
    Font = New-Object System.Drawing.Font("Consolas", 9); BackColor = "White" }) 16 352 774 260 "Top,Bottom,Left,Right"

# Bottom row
$play     = Add-Ctl (New-Object System.Windows.Forms.Button -Property @{ Text = "Play" }) 16 624 120 36 "Bottom,Left"
$settings = Add-Ctl (New-Object System.Windows.Forms.Button -Property @{ Text = "Settings" }) 144 624 100 36 "Bottom,Left"
$wheel    = Add-Ctl (New-Object System.Windows.Forms.Button -Property @{ Text = "Wheel setup" }) 252 624 110 36 "Bottom,Left"
$logs     = Add-Ctl (New-Object System.Windows.Forms.Button -Property @{ Text = "Open logs" }) 370 624 100 36 "Bottom,Left"

function Write-Log([string]$text) { $log.AppendText($text.TrimEnd() + "`r`n") }

# --- requirement checks ------------------------------------------------------
$script:missing = @()
function Test-Prereqs {
    Update-Path
    $reqList.Items.Clear()
    $script:missing = @()
    foreach ($p in $Prereqs) {
        $problem = & $p.Check
        $item = New-Object System.Windows.Forms.ListViewItem($p.Name)
        $null = $item.SubItems.Add($(if ($problem) { "MISSING - $problem" } else { "OK" }))
        $item.ForeColor = if ($problem) { "Firebrick" } else { "ForestGreen" }
        $null = $reqList.Items.Add($item)
        if ($problem) { $script:missing += $p }
    }
    $freeGb = [math]::Floor((Get-PSDrive ($Root.Substring(0, 1))).Free / 1GB)
    $item = New-Object System.Windows.Forms.ListViewItem("Free disk space (10 GB needed)")
    $null = $item.SubItems.Add("$freeGb GB")
    $item.ForeColor = if ($freeGb -lt 10) { "Firebrick" } else { "ForestGreen" }
    $null = $reqList.Items.Add($item)
    $install.Enabled = $script:missing.Count -gt 0
    Update-Buttons
}

function Update-Buttons {
    $busy = $null -ne $script:proc -and -not $script:proc.HasExited
    $build.Enabled = -not $busy -and $script:missing.Count -eq 0
    $cancel.Enabled = $busy
    $recheck.Enabled = -not $busy
    $play.Enabled = -not $busy -and (Test-Path $Exe)
    $settings.Enabled = Test-Path $ExeDir
    $wheel.Enabled = -not $busy -and (Test-Path (Join-Path $ExeDir "wheel_probe.exe"))
}

# --- background process + log follower ----------------------------------------
$script:proc = $null; $script:procLog = $null; $script:logPos = 0; $script:mode = ""
$shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }

function Start-Background([string]$mode, [string]$scriptText) {
    $script:mode = $mode
    $script:procLog = Join-Path $Work "launcher-$mode.log"
    Set-Content $script:procLog "" -Encoding utf8
    $script:logPos = 0
    $runner = Join-Path $Work "launcher-$mode.ps1"
    Set-Content $runner $scriptText -Encoding utf8
    # Anything that escapes the script (a crash, an uncaught error) is caught
    # and written to the same log; the process's raw stderr goes to a side file
    # that is appended to the log when the process ends. Nothing is hidden.
    $script:procErr = Join-Path $Work "launcher-$mode.stderr.txt"
    Remove-Item $script:procErr -ErrorAction SilentlyContinue
    $logq = $script:procLog
    $script:proc = Start-Process $shell -PassThru -WindowStyle Hidden -RedirectStandardError $script:procErr -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
        "try { & '$runner' *>&1 | Out-File -FilePath '$logq' -Encoding utf8 -Append; exit `$LASTEXITCODE } " +
        "catch { ('CRASH: ' + (`$_ | Out-String)) | Out-File -FilePath '$logq' -Encoding utf8 -Append; exit 1 }")
    $progress.Value = 0
    Update-Buttons
    $timer.Start()
}

$timer = New-Object System.Windows.Forms.Timer -Property @{ Interval = 500 }
$timer.Add_Tick({
    if (Test-Path $script:procLog) {
        $fs = [System.IO.File]::Open($script:procLog, "Open", "Read", "ReadWrite")
        try {
            if ($fs.Length -gt $script:logPos) {
                $fs.Position = $script:logPos
                $reader = New-Object System.IO.StreamReader($fs)
                $new = $reader.ReadToEnd()
                $script:logPos = $fs.Length
                foreach ($line in ($new -split "`r?`n")) {
                    if (-not $line) { continue }
                    Write-Log $line
                    if ($line -match '^== (.+)') {
                        $status.Text = $Matches[1]
                        if ($script:mode -eq "build" -and $progress.Value -lt $progress.Maximum) { $progress.Value++ }
                    }
                }
            }
        } finally { $fs.Dispose() }
    }
    if ($script:proc -and $script:proc.HasExited) {
        $timer.Stop()
        $code = $script:proc.ExitCode
        $errText = if (Test-Path $script:procErr) { (Get-Content $script:procErr -Raw) } else { "" }
        if ($errText -and $errText.Trim()) {
            Write-Log "---- error output ----"
            Write-Log $errText
            Add-Content $script:procLog "`r`n---- error output ----`r`n$errText" -Encoding utf8
        }
        if ($script:mode -eq "build") {
            if ($code -eq 0) { $progress.Value = $progress.Maximum; $status.Text = "Build finished - press Play." }
            else { $status.Text = "Build failed (exit $code). The log above and the files in work\ show why." }
        } elseif ($script:mode -eq "install") {
            $status.Text = if ($code -eq 0) { "Installs finished." } else { "An install failed (exit $code) - see the log." }
            Test-Prereqs
        }
        $script:proc = $null
        Update-Buttons
    }
})

# --- actions -----------------------------------------------------------------
$browse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog -Property @{
        Filter = "Xbox 360 disc image (*.iso)|*.iso|All files (*.*)|*.*"; Title = "Select your NASCAR The Game: Inside Line ISO" }
    if ($dlg.ShowDialog() -eq "OK") { $isoBox.Text = $dlg.FileName; Save-State }
})

$recheck.Add_Click({ Test-Prereqs })

$install.Add_Click({
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        [System.Windows.Forms.MessageBox]::Show("winget (App Installer) is not available. Install the missing tools manually - see README.md.", "Install missing") | Out-Null
        return
    }
    $names = ($script:missing | ForEach-Object { " - " + $_.Name }) -join "`n"
    $ok = [System.Windows.Forms.MessageBox]::Show(
        "Install these with winget?`n`n$names`n`nVisual Studio Build Tools is a large download (several GB). Windows may ask for administrator permission.",
        "Install missing tools", "OKCancel", "Question")
    if ($ok -ne "OK") { return }
    $lines = foreach ($p in $script:missing) {
        $wargs = "install --id $($p.Id) --exact --source winget --accept-package-agreements --accept-source-agreements"
        if ($p.Override) { $wargs += " --override `"$($p.Override)`"" }
        "Write-Output '== Installing $($p.Name)'"
        "winget $wargs"
    }
    Start-Background "install" (($lines -join "`r`n") + "`r`nexit 0")
})

$build.Add_Click({
    if (-not (Test-Path $isoBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Choose your game ISO first.", "Build") | Out-Null; return
    }
    Save-State
    $log.Clear()
    $intros = if ($introsBox.Checked) { " -KeepIntros" } else { "" }
    Start-Background "build" "& '$Root\setup.ps1' -Iso '$($isoBox.Text)' -Jobs $([int]$jobsBox.Value)$intros; exit `$LASTEXITCODE"
})

$cancel.Add_Click({
    if ($script:proc -and -not $script:proc.HasExited) {
        # Stop the whole tree (setup -> cmake -> ninja -> clang).
        & taskkill /PID $script:proc.Id /T /F | Out-Null
        $status.Text = "Cancelled. Build again to continue where it stopped."
    }
})

$play.Add_Click({ Start-Process -FilePath $Exe -WorkingDirectory $ExeDir })
$settings.Add_Click({
    $toml = Join-Path $ExeDir "nascar.toml"
    if (-not (Test-Path $toml)) { Copy-Item (Join-Path $Root "nascar\nascar.toml") $toml }
    Start-Process notepad.exe $toml
})
$wheel.Add_Click({
    $wiz = Join-Path $PSScriptRoot "wheel_setup.ps1"
    Start-Process $shell -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", "`"$wiz`"")
})
$logs.Add_Click({ Start-Process explorer.exe $Work })

$form.Add_FormClosing({
    if ($script:proc -and -not $script:proc.HasExited) {
        $r = [System.Windows.Forms.MessageBox]::Show("A build or install is still running. Stop it and close?", "Close", "YesNo", "Warning")
        if ($r -ne "Yes") { $_.Cancel = $true; return }
        & taskkill /PID $script:proc.Id /T /F | Out-Null
    }
    Save-State
})

$form.Add_Shown({
    Test-Prereqs
    if (Test-Path $Exe) { $status.Text = "nascar.exe is built - press Play, or Build again after updating." }
    else { $status.Text = "Choose your ISO, install anything missing, then press Build." }
})
[void]$form.ShowDialog()
