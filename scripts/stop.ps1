# Sing-Box Toolkit - Stop Proxy
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\env.ps1"

# 停止是"用户主动"还是"进程崩了"，光看进程在不在是分不出来的。
# 不留标记的话，看门狗下一次 5 分钟体检就会把它当崩溃重新拉起来。
function Set-ManualStop {
    Set-ToolkitState "manualStop" $true
    Set-ToolkitState "manualStopAt" (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Write-Host "已标记为手动停止，看门狗不会自动拉起（[1] 启动后恢复守护）" -ForegroundColor DarkGray
}

$p = Get-Process -Name "sing-box" -ErrorAction SilentlyContinue
if (-not $p) {
    Write-Host "Sing-Box is not running" -ForegroundColor DarkGray
    # 进程已经不在，但可能是被外力杀的：标记照样要落，否则看门狗仍会拉起
    Set-ManualStop
    exit 0
}

Write-Host "Stopping Sing-Box (PID: $($p.Id))..." -ForegroundColor Yellow

$p | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

$still = Get-Process -Name "sing-box" -ErrorAction SilentlyContinue
if (-not $still) {
    Write-Host "OK: Stopped" -ForegroundColor Green
    Set-ManualStop
    exit 0
}

$cmd = "Stop-Process -Id $($p.Id) -Force"
Start-Process powershell -Verb RunAs -WindowStyle Hidden -Wait -ArgumentList "-Command", $cmd
Start-Sleep -Seconds 1

$leftover = Get-Process -Name "sing-box" -ErrorAction SilentlyContinue
if ($leftover) {
    # 没停下来就不能标记，否则代理还在跑、守护却被关掉了
    Write-Host "FAIL: Unable to stop, run as Administrator" -ForegroundColor Red
}
else {
    Write-Host "OK: Stopped" -ForegroundColor Green
    Set-ManualStop
}
