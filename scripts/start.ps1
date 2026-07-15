# SingPilot - Start Proxy
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\env.ps1"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Sing-Box - Start" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

$old = Get-Process -Name "sing-box" -ErrorAction SilentlyContinue
if ($old) {
    Write-Host "Stopping old process..." -ForegroundColor DarkGray
    try { $old | Stop-Process -Force -ErrorAction Stop } catch {
        $stopCmd = "Stop-Process -Id $($old.Id) -Force"
        Start-Process powershell -Verb RunAs -WindowStyle Hidden -Wait -ArgumentList '-Command', $stopCmd
    }
    Start-Sleep -Seconds 1
}

Write-Host "Starting..." -ForegroundColor Green
Start-Process -FilePath $SingBoxExe -ArgumentList "run", "-c", $ConfigPath -Verb RunAs -WindowStyle Hidden -WorkingDirectory $ToolkitRoot
Start-Sleep -Seconds 3

$p = Get-Process -Name "sing-box" -ErrorAction SilentlyContinue
if ($p) {
    Write-Host "OK: Started (PID: $($p.Id))" -ForegroundColor Green
    Write-Host ""
    Write-Host "Browse the web directly, no proxy config needed." -ForegroundColor White
} else {
    Write-Host "FAIL: 启动失败，请以管理员身份运行" -ForegroundColor Red
}
