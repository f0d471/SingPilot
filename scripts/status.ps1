# Sing-Box Toolkit - Detailed Status
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\env.ps1"
$state = Get-ToolkitSnapshot

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Sing-Box Status" -ForegroundColor Green
Write-Host "  $($state.Timestamp)" -ForegroundColor DarkGray
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# --- Process ---
Write-Host "--- Process" -ForegroundColor Cyan
if ($state.IsRunning) {
    Write-Host "  Status      : [RUNNING]" -ForegroundColor Green
    Write-Host "  PID         : $($state.PID)" -ForegroundColor White
    Write-Host "  Memory      : $($state.MemoryMB) MB" -ForegroundColor White
    if ($state.Uptime) {
        $d = $state.Uptime.Days; $h = $state.Uptime.Hours; $m = $state.Uptime.Minutes
        Write-Host "  Uptime      : ${d}d ${h}h ${m}m" -ForegroundColor White
    }
    if ($state.MemoryMB -gt 500) {
        Write-Host "  WARNING: High memory usage, consider restart" -ForegroundColor Yellow
    }
} else {
    Write-Host "  Status      : [STOPPED]" -ForegroundColor Red
}

# --- TUN ---
Write-Host ""; Write-Host "--- TUN Adapter" -ForegroundColor Cyan
if ($state.TunExists) {
    $tun = Get-TunAdapter
    Write-Host "  Status      : $($tun.Status)" -ForegroundColor Green
    Write-Host "  Name        : $($tun.Name)" -ForegroundColor White
} else { Write-Host "  Status      : Not created" -ForegroundColor DarkGray }

# --- Ports ---
Write-Host ""; Write-Host "--- Listening Ports" -ForegroundColor Cyan
if ($state.ListeningPorts.Count -gt 0) {
    $state.ListeningPorts | ForEach-Object { Write-Host "  $($_.LocalAddress):$($_.LocalPort)" -ForegroundColor White }
} elseif ($state.IsRunning) {
    Write-Host "  Detecting..." -ForegroundColor DarkGray
} else { Write-Host "  (not running)" -ForegroundColor DarkGray }

# --- Network ---
Write-Host ""; Write-Host "--- Connectivity" -ForegroundColor Cyan
$net = $state.Network
if ($net) {
    $d = if ($net.Domestic) { "OK" } else { "FAIL" }
    $f = if ($net.Foreign) { "OK" } else { "FAIL" }
    $p = if ($net.ProxyPort) { "OK" } else { "FAIL" }
    Write-Host "  Domestic (Baidu)   : $d" -ForegroundColor $(if ($net.Domestic) { "Green" } else { "Red" })
    Write-Host "  Foreign (Google)   : $f" -ForegroundColor $(if ($net.Foreign) { "Green" } else { "Red" })
    Write-Host "  Proxy (127.0.0.1)  : $p" -ForegroundColor $(if ($net.ProxyPort) { "Green" } else { "Yellow" })
} else { Write-Host "  (requires admin)" -ForegroundColor DarkGray }

# --- Config ---
Write-Host ""; Write-Host "--- Config" -ForegroundColor Cyan
$caps = $state.Capabilities
if ($caps.Valid) {
    $tunStr = if ($caps.HasTUN) { "Yes" } else { "No" }
    $apiStr = if ($caps.HasClashAPI) { "Yes (port: $($caps.ClashPort))" } else { "No" }
    $routeStr = if ($caps.HasRouteRules) { "Yes" } else { "No" }
    Write-Host "  TUN Mode     : $tunStr" -ForegroundColor White
    Write-Host "  Clash API    : $apiStr" -ForegroundColor White
    Write-Host "  Route Rules  : $routeStr" -ForegroundColor White
    Write-Host "  Nodes        : $($caps.NodeCount)" -ForegroundColor White
} else { Write-Host "  Config invalid or not found" -ForegroundColor Red }

# --- Services ---
Write-Host ""; Write-Host "--- System Services" -ForegroundColor Cyan
$wdStr = if ($state.Watchdog.Installed) { "$($state.Watchdog.Count)/3 tasks" } else { "Not installed" }
$asStr = if ($state.Autostart) { "Enabled" } else { "Disabled" }
$admStr = if ($state.IsAdmin) { "Yes" } else { "Partial" }
Write-Host "  Watchdog     : $wdStr" -ForegroundColor White
Write-Host "  Autostart    : $asStr" -ForegroundColor White
Write-Host "  Admin Rights : $admStr" -ForegroundColor White

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Dashboard: http://127.0.0.1:9090/ui" -ForegroundColor DarkGray
Write-Host "  Process: search 'sing-box' in Task Manager" -ForegroundColor DarkGray
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "Press Enter to return"
