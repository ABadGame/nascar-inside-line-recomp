# Wheel setup wizard: turns a steering wheel (or any joystick) into an SDL
# gamepad mapping the game understands - steering on the left stick, pedals on
# the triggers, buttons where you want them. Saves to
# nascar\out\build\win-amd64-release\gamecontrollerdb.user.txt, which the game
# loads after its bundled controller database.
#
#   wheel_setup.ps1             open the wizard
#   wheel_setup.ps1 -SelfTest   check the mapping logic without hardware
param([switch]$SelfTest)

$ErrorActionPreference = "Stop"
$Root   = Split-Path -Parent $PSScriptRoot
$ExeDir = Join-Path $Root "nascar\out\build\win-amd64-release"
$Probe  = Join-Path $ExeDir "wheel_probe.exe"
$UserDb = Join-Path $ExeDir "gamecontrollerdb.user.txt"
$StateFile = Join-Path $Root "work\wheel_state.json"

# --- mapping logic (pure functions) ------------------------------------------

# Axis that moved the most between two snapshots, or $null if nothing moved enough.
function Find-MovedAxis([int[]]$Before, [int[]]$After, [int]$MinDelta = 12000) {
    $best = $null; $bestDelta = $MinDelta
    for ($i = 0; $i -lt [math]::Min($Before.Count, $After.Count); $i++) {
        $d = [math]::Abs($After[$i] - $Before[$i])
        if ($d -gt $bestDelta) { $best = $i; $bestDelta = $d }
    }
    return $best
}

# Steering: turned LEFT should read negative on the game's left stick X.
function Get-SteerBinding([int]$Axis, [int]$Center, [int]$Left) {
    if ($Left -lt $Center) { "a$Axis" } else { "a$Axis~" }
}

# Pedal -> trigger. Rests at an end of the axis: full-axis binding (inverted if
# it rests high). Rests near the middle (combined/half axes): half-axis binding.
function Get-PedalBinding([int]$Axis, [int]$Rest, [int]$Pressed) {
    if ([math]::Abs($Rest) -gt 24000) {
        if ($Rest -gt 0) { "a$Axis~" } else { "a$Axis" }
    } else {
        if ($Pressed -gt $Rest) { "+a$Axis" } else { "-a$Axis" }
    }
}

# First input that became active between two snapshots: a button or a hat direction.
function Find-PressedInput($Before, $After) {
    for ($i = 0; $i -lt $After.buttons.Count; $i++) {
        if ($After.buttons[$i] -and -not $Before.buttons[$i]) { return "b$i" }
    }
    for ($h = 0; $h -lt $After.hats.Count; $h++) {
        $new = [int]$After.hats[$h] -band (-bnot [int]$Before.hats[$h])
        foreach ($bit in 1, 2, 4, 8) { if ($new -band $bit) { return "h$h.$bit" } }
    }
    return $null
}

function New-MappingLine([string]$Guid, [string]$Name, [hashtable]$Bindings) {
    $clean = ($Name -replace '[,\r\n]', ' ').Trim()
    $order = "leftx", "lefttrigger", "righttrigger", "a", "b", "x", "y", "start", "back",
             "leftshoulder", "rightshoulder", "dpup", "dpdown", "dpleft", "dpright"
    $parts = foreach ($k in $order) { if ($Bindings[$k]) { "${k}:$($Bindings[$k])" } }
    "$Guid,$clean,$($parts -join ','),platform:Windows,"
}

# Replace (or add) the line for this GUID in the user mapping file.
function Save-Mapping([string]$Path, [string]$Guid, [string]$Line) {
    $lines = @()
    if (Test-Path $Path) { $lines = @(Get-Content $Path | Where-Object { $_ -and -not $_.StartsWith("$Guid,") }) }
    if (-not ($lines | Where-Object { $_.StartsWith("#") })) {
        $lines = @("# Controller mappings made by the launcher's wheel setup. Loaded after gamecontrollerdb.txt.") + $lines
    }
    Set-Content $Path ($lines + $Line) -Encoding ascii
}

if ($SelfTest) {
    $fail = 0
    function Check($what, $got, $want) {
        if ("$got" -ne "$want") { Write-Host "FAIL $what : got '$got' want '$want'"; $script:fail++ } else { Write-Host "ok   $what" }
    }
    Check "moved axis"            (Find-MovedAxis @(0, 0, 32767, 32767) @(-32000, 100, 32767, 32767)) 0
    Check "no axis moved"         (Find-MovedAxis @(0, 0) @(500, -300)) ""
    Check "steer normal"          (Get-SteerBinding 0 0 -32768) "a0"
    Check "steer inverted"        (Get-SteerBinding 0 0 32767) "a0~"
    Check "pedal rests high"      (Get-PedalBinding 2 32767 -32768) "a2~"
    Check "pedal rests low"       (Get-PedalBinding 2 -32768 32767) "a2"
    Check "combined axis gas"     (Get-PedalBinding 1 0 32767) "+a1"
    Check "combined axis brake"   (Get-PedalBinding 1 0 -32768) "-a1"
    $b = [pscustomobject]@{ buttons = @(0, 0, 0); hats = @(0) }
    Check "button press"          (Find-PressedInput $b ([pscustomobject]@{ buttons = @(0, 1, 0); hats = @(0) })) "b1"
    Check "hat press"             (Find-PressedInput $b ([pscustomobject]@{ buttons = @(0, 0, 0); hats = @(4) })) "h0.4"
    Check "mapping line"          (New-MappingLine "0300abcd" "Wheel, Pro" @{ leftx = "a0"; righttrigger = "a2~"; lefttrigger = "a3~"; a = "b0"; dpup = "h0.1" }) `
                                  "0300abcd,Wheel  Pro,leftx:a0,lefttrigger:a3~,righttrigger:a2~,a:b0,dpup:h0.1,platform:Windows,"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "wheel_selftest.txt"
    Save-Mapping $tmp "g1" "g1,One,leftx:a0,platform:Windows,"
    Save-Mapping $tmp "g2" "g2,Two,leftx:a0,platform:Windows,"
    Save-Mapping $tmp "g1" "g1,One,leftx:a1,platform:Windows,"
    $c = Get-Content $tmp
    Check "save replaces by guid" ($c | Where-Object { $_ -like "g1,*" }) "g1,One,leftx:a1,platform:Windows,"
    Check "save keeps others"     (($c | Where-Object { $_ -like "g*" }).Count) 2
    Remove-Item $tmp
    if ($fail) { Write-Host "$fail check(s) failed"; exit 1 } else { Write-Host "all checks passed"; exit 0 }
}

# --- wizard UI -----------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not (Test-Path $Probe)) {
    [System.Windows.Forms.MessageBox]::Show("wheel_probe.exe not found - build the game first.", "Wheel setup") | Out-Null
    exit 1
}
$devices = @(& $Probe list | ConvertFrom-Json)
if ($devices.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show("No wheel or controller found. Plug it in (and turn it on), then open Wheel setup again.", "Wheel setup") | Out-Null
    exit 0
}

$steps = @(
    @{ Key = "leftx";        Kind = "steer"; Text = "Turn the wheel fully LEFT and hold it there, then click Next." }
    @{ Key = "righttrigger"; Kind = "pedal"; Text = "Press the GAS pedal all the way down and hold it, then click Next." }
    @{ Key = "lefttrigger";  Kind = "pedal"; Text = "Press the BRAKE pedal all the way down and hold it, then click Next." }
    @{ Key = "a";     Kind = "input"; Text = "Press the button to use as A (select / accept)." }
    @{ Key = "b";     Kind = "input"; Text = "Press the button to use as B (back / cancel)." }
    @{ Key = "start"; Kind = "input"; Text = "Press the button to use as START (pause)." }
    @{ Key = "back";  Kind = "input"; Text = "Press the button to use as BACK." }
    @{ Key = "x";     Kind = "input"; Text = "Press the button to use as X." }
    @{ Key = "y";     Kind = "input"; Text = "Press the button to use as Y." }
    @{ Key = "leftshoulder";  Kind = "input"; Text = "Press the button to use as LB (left bumper)." }
    @{ Key = "rightshoulder"; Kind = "input"; Text = "Press the button to use as RB (right bumper)." }
    @{ Key = "dpup";    Kind = "input"; Text = "Press D-pad UP (or the button to use for it)." }
    @{ Key = "dpdown";  Kind = "input"; Text = "Press D-pad DOWN." }
    @{ Key = "dpleft";  Kind = "input"; Text = "Press D-pad LEFT." }
    @{ Key = "dpright"; Kind = "input"; Text = "Press D-pad RIGHT." }
)

$form = New-Object System.Windows.Forms.Form -Property @{
    Text = "Wheel setup"; Size = New-Object System.Drawing.Size(640, 440); StartPosition = "CenterScreen"
    Font = New-Object System.Drawing.Font("Segoe UI", 9.5); FormBorderStyle = "FixedDialog"; MaximizeBox = $false }
function Add-Ctl($ctl, $x, $y, $w, $h) {
    $ctl.Location = New-Object System.Drawing.Point($x, $y); $ctl.Size = New-Object System.Drawing.Size($w, $h)
    $form.Controls.Add($ctl); $ctl }

$null = Add-Ctl (New-Object System.Windows.Forms.Label -Property @{ Text = "Device:" }) 16 18 60 22
$devBox = Add-Ctl (New-Object System.Windows.Forms.ComboBox -Property @{ DropDownStyle = "DropDownList" }) 80 15 530 24
foreach ($d in $devices) { $null = $devBox.Items.Add("$($d.name)  [$($d.type), $($d.axes) axes, $($d.buttons) buttons]") }
$pick = [array]::IndexOf(@($devices | ForEach-Object { $_.type }), "wheel")
$devBox.SelectedIndex = if ($pick -ge 0) { $pick } else { 0 }
$note = Add-Ctl (New-Object System.Windows.Forms.Label -Property @{ ForeColor = "DimGray" }) 16 46 600 36
$live = Add-Ctl (New-Object System.Windows.Forms.Label -Property @{
    Font = New-Object System.Drawing.Font("Consolas", 9); BorderStyle = "FixedSingle" }) 16 86 594 70
$stepLbl = Add-Ctl (New-Object System.Windows.Forms.Label -Property @{
    Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold) }) 16 168 594 50
$result = Add-Ctl (New-Object System.Windows.Forms.TextBox -Property @{
    Multiline = $true; ReadOnly = $true; Font = New-Object System.Drawing.Font("Consolas", 8.5) }) 16 226 594 120
$startBtn = Add-Ctl (New-Object System.Windows.Forms.Button -Property @{ Text = "Start" }) 16 356 100 32
$nextBtn  = Add-Ctl (New-Object System.Windows.Forms.Button -Property @{ Text = "Next"; Enabled = $false }) 124 356 90 32
$skipBtn  = Add-Ctl (New-Object System.Windows.Forms.Button -Property @{ Text = "Skip"; Enabled = $false }) 222 356 90 32
$saveBtn  = Add-Ctl (New-Object System.Windows.Forms.Button -Property @{ Text = "Save"; Enabled = $false }) 510 356 100 32

$script:watch = $null; $script:cur = $null; $script:base = $null
$script:stepIx = -1; $script:bind = @{}; $script:steerAxis = $null

function Stop-Watch { if ($script:watch -and -not $script:watch.HasExited) { $script:watch.Kill() }; $script:watch = $null }
function Start-Watch {
    Stop-Watch
    Remove-Item $StateFile -ErrorAction SilentlyContinue
    $d = $devices[$devBox.SelectedIndex]
    $note.Text = if ($d.gamepad) { "This device already works as a controller. Setting it up here replaces its button layout in the game." }
                 else { "Not recognised as a controller yet - set it up below to use it in the game." }
    $script:watch = Start-Process $Probe -PassThru -WindowStyle Hidden -ArgumentList @("watch", $d.guid, "`"$StateFile`"", $PID)
}

function Show-Step {
    if ($script:stepIx -ge $steps.Count) {
        $stepLbl.Text = "Done. Check the mapping below, then click Save."
        $nextBtn.Enabled = $false; $skipBtn.Enabled = $false; $saveBtn.Enabled = $true
        return
    }
    $s = $steps[$script:stepIx]
    $stepLbl.Text = "Step $($script:stepIx + 1) of $($steps.Count): $($s.Text)"
    $nextBtn.Enabled = $s.Kind -ne "input"
    $skipBtn.Enabled = $s.Key -notin "leftx", "righttrigger", "lefttrigger"
    $script:base = $script:cur
}

function Update-Result {
    $d = $devices[$devBox.SelectedIndex]
    $result.Text = (New-MappingLine $d.guid $d.name $script:bind) +
        "`r`n`r`nSteering: $($script:bind.leftx)   Gas: $($script:bind.righttrigger)   Brake: $($script:bind.lefttrigger)"
}

$timer = New-Object System.Windows.Forms.Timer -Property @{ Interval = 50 }
$timer.Add_Tick({
    try { $script:cur = Get-Content $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return }
    $pressed = @(for ($i = 0; $i -lt $script:cur.buttons.Count; $i++) { if ($script:cur.buttons[$i]) { "b$i" } })
    $live.Text = "Axes:    " + (($script:cur.axes | ForEach-Object { "{0,7}" -f $_ }) -join "") + "`r`n" +
                 "Buttons: " + $(if ($pressed) { $pressed -join " " } else { "-" }) + "`r`n" +
                 "Hats:    " + (($script:cur.hats) -join " ")
    if ($script:stepIx -ge 0 -and $script:stepIx -lt $steps.Count -and $steps[$script:stepIx].Kind -eq "input" -and $script:base) {
        $hit = Find-PressedInput $script:base $script:cur
        if ($hit) {
            $script:bind[$steps[$script:stepIx].Key] = $hit
            Update-Result
            $script:stepIx++; Show-Step
        }
    }
})

$devBox.Add_SelectedIndexChanged({ $script:stepIx = -1; $script:bind = @{}; $result.Text = ""; Start-Watch })
$startBtn.Add_Click({
    if (-not $script:cur) { $stepLbl.Text = "Waiting for the device... (is it plugged in?)"; return }
    $script:bind = @{}; $script:stepIx = 0; $saveBtn.Enabled = $false; $result.Text = ""; Show-Step
})
$nextBtn.Add_Click({
    $s = $steps[$script:stepIx]
    $axis = Find-MovedAxis $script:base.axes $script:cur.axes
    if ($s.Kind -eq "pedal" -and $null -ne $axis -and $axis -eq $script:steerAxis) { $axis = $null }
    if ($null -eq $axis) { $stepLbl.Text = "Nothing moved far enough - $($s.Text)"; return }
    if ($s.Kind -eq "steer") {
        $script:steerAxis = $axis
        $script:bind.leftx = Get-SteerBinding $axis $script:base.axes[$axis] $script:cur.axes[$axis]
    } else {
        $script:bind[$s.Key] = Get-PedalBinding $axis $script:base.axes[$axis] $script:cur.axes[$axis]
    }
    Update-Result
    $script:stepIx++; Show-Step
})
$skipBtn.Add_Click({ $script:stepIx++; Show-Step })
$saveBtn.Add_Click({
    $d = $devices[$devBox.SelectedIndex]
    Save-Mapping $UserDb $d.guid (New-MappingLine $d.guid $d.name $script:bind)
    [System.Windows.Forms.MessageBox]::Show("Saved. Restart the game to use it.`n`n$UserDb", "Wheel setup") | Out-Null
    $form.Close()
})
$form.Add_FormClosing({ $timer.Stop(); Stop-Watch })
$form.Add_Shown({
    $stepLbl.Text = "Release all pedals, centre the wheel, then click Start."
    Start-Watch; $timer.Start()
})
[void]$form.ShowDialog()
