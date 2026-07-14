# Sing-Box 开机自启管理
param([switch]$Remove)

$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\env.ps1"

$taskName = "Sing-Box"

if ($Remove) {
    Write-Host "移除开机自启..." -ForegroundColor Yellow
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-Host "已取消开机自启" -ForegroundColor Green
    } catch {
        Write-Host "未找到开机自启任务" -ForegroundColor DarkGray
    }
} else {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    Write-Host "设置开机自启..." -ForegroundColor Yellow

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -Command `"Start-Process -FilePath '$SingBoxExe' -ArgumentList 'run', '-c', '$ConfigPath' -WorkingDirectory '$ToolkitRoot' -Verb RunAs -WindowStyle Hidden`""

    $trigger = New-ScheduledTaskTrigger -AtStartup

    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "Sing-Box 代理开机自动启动" `
        -Force | Out-Null

    Write-Host "开机自启已设置" -ForegroundColor Green
    Write-Host ""
    Write-Host "说明:" -ForegroundColor White
    Write-Host "  - 开机后自动以 SYSTEM 权限启动，无窗口" -ForegroundColor DarkGray
    Write-Host "  - 如果崩溃会自动重试 3 次（间隔 1 分钟）" -ForegroundColor DarkGray
    Write-Host "  - 双击 manage.bat 不影响，会自动替换旧进程" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "取消: .\autostart.ps1 -Remove" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "按任意键退出..." -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
