# Sing-Box Toolkit - Setup Wizard
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\env.ps1"

Clear-Host
Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Sing-Box Setup Wizard" -ForegroundColor White
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host " This wizard will auto-detect your environment and configure everything." -ForegroundColor White
Write-Host ""

$ok = $true

# Step 1: Environment
Write-Host "--- Step 1/4: Environment Check" -ForegroundColor Cyan
if (-not (Test-SingBoxExists)) {
    Write-Host "  FAIL: sing-box.exe not found" -ForegroundColor Red
    Write-Host "         Download from https://github.com/Sagernet/sing-box/releases" -ForegroundColor DarkGray
    Write-Host "         Place it in: $ToolkitRoot" -ForegroundColor DarkGray
    $ok = $false
} else {
    Write-Host "  OK: sing-box $(Get-SingBoxVersion)" -ForegroundColor Green
}

if (-not (Test-ConfigExists)) {
    Write-Host "  FAIL: config.json not found" -ForegroundColor Red
    Write-Host "         Place your service provider config.json in: $ToolkitRoot" -ForegroundColor DarkGray
    $ok = $false
} elseif (-not (Test-ConfigValid)) {
    Write-Host "  FAIL: config.json is invalid" -ForegroundColor Red
    $check = & $SingBoxExe check -c $ConfigPath 2>&1
    Write-Host "         Error: $($check -join ' ')" -ForegroundColor DarkGray
    $ok = $false
} else {
    $caps = Get-ConfigCapabilities
    $feats = @()
    if ($caps.HasTUN) { $feats += "TUN" } else { $feats += "Port-only" }
    if ($caps.HasClashAPI) { $feats += "ClashAPI" }
    if ($caps.HasRouteRules) { $feats += "Routing" }
    Write-Host "  OK: config.json valid ($($feats -join ', '), $($caps.NodeCount) nodes)" -ForegroundColor Green
}

if (-not (Test-IsAdmin)) {
    Write-Host "  WARNING: Not running as admin, some features limited" -ForegroundColor Yellow
}

Write-Host ""
if (-not $ok) {
    Write-Host "Setup aborted. Fix the above issues and retry." -ForegroundColor Red
    Read-Host "Press Enter to return"
    return
}

# Step 2: Connectivity Test
Write-Host "--- Step 2/4: Connectivity Test" -ForegroundColor Cyan
$alreadyRunning = Test-SingBoxRunning
if (-not $alreadyRunning) {
    Write-Host "  Starting sing-box temporarily..." -ForegroundColor Yellow
    Start-Process -FilePath $SingBoxExe -ArgumentList "run", "-c", $ConfigPath -Verb RunAs -WindowStyle Hidden -WorkingDirectory $ToolkitRoot
    Start-Sleep -Seconds 4
}
$net = Test-NetworkConnectivity
Write-Host "  Domestic (Baidu)  : $(if ($net.Domestic) {'OK'} else {'FAIL'})" -ForegroundColor $(if ($net.Domestic) {'Green'} else {'Red'})
Write-Host "  Foreign (Google)  : $(if ($net.Foreign) {'OK'} else {'FAIL'})" -ForegroundColor $(if ($net.Foreign) {'Green'} else {'Red'})
if (-not $alreadyRunning) {
    Write-Host "  Test complete, stopping..." -ForegroundColor DarkGray
    Get-Process -Name "sing-box" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
}
Write-Host ""

# Step 3: Autostart
Write-Host "--- Step 3/4: Autostart" -ForegroundColor Cyan
if (Test-AutostartInstalled) {
    Write-Host "  OK: Autostart already enabled" -ForegroundColor Green
} else {
    $choice = Read-Host "  Enable autostart on boot? [Y/n]"
    if ($choice -ne 'n' -and $choice -ne 'N') {
        try {
            $act = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -Command `"Start-Process -FilePath '$SingBoxExe' -ArgumentList 'run', '-c', '$ConfigPath' -WorkingDirectory '$ToolkitRoot' -Verb RunAs -WindowStyle Hidden`""
            $trig = New-ScheduledTaskTrigger -AtStartup
            $prin = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
            $sets = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
            Unregister-ScheduledTask -TaskName "Sing-Box" -Confirm:$false -ErrorAction SilentlyContinue
            Register-ScheduledTask -TaskName "Sing-Box" -Action $act -Trigger $trig -Principal $prin -Settings $sets -Force | Out-Null
            Write-Host "  OK: Autostart enabled" -ForegroundColor Green
        } catch { Write-Host "  FAIL: $($_.Exception.Message)" -ForegroundColor Red }
    }
}
Write-Host ""

# Step 4: Watchdog
Write-Host "--- Step 4/4: Watchdog (anti-freeze)" -ForegroundColor Cyan
Write-Host "  Watchdog auto-restarts sing-box if it freezes or runs out of memory." -ForegroundColor White
$wd = Test-WatchdogInstalled
if ($wd.Installed) {
    Write-Host "  OK: Watchdog already installed ($($wd.Count)/3 tasks)" -ForegroundColor Green
} else {
    $choice = Read-Host "  Install watchdog? [Y/n]"
    if ($choice -ne 'n' -and $choice -ne 'N') {
        try {
            & "$ScriptDir\watchdog.ps1" -SetupTaskSilent
            Write-Host "  OK: Watchdog installed" -ForegroundColor Green
        } catch { Write-Host "  FAIL: $($_.Exception.Message)" -ForegroundColor Red }
    }
}

# Done
Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host "  Setup Complete!" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Quick reference:" -ForegroundColor White
Write-Host "    Start proxy : manage.bat -> [1]" -ForegroundColor DarkGray
Write-Host "    Switch node : http://127.0.0.1:9090/ui" -ForegroundColor DarkGray
Write-Host "    Update conf : manage.bat -> [5]" -ForegroundColor DarkGray
Write-Host "    View status : manage.bat -> [3]" -ForegroundColor DarkGray
Write-Host ""

try {
    @{ initialized = $true; initDate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); toolkitVer = "1.0" } | ConvertTo-Json | Out-File $StateFile -Encoding utf8
} catch { }
Read-Host "Press Enter to return to menu"
