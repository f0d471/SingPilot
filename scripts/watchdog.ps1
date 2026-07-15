# SingPilot - 健康监控看门狗
# 用法:
#   watchdog.ps1                    单次检查（计划任务调用）
#   watchdog.ps1 -SetupTask         交互式安装（菜单调用）
#   watchdog.ps1 -SetupTaskSilent   静默安装（setup 向导调用）
#   watchdog.ps1 -RemoveAll         移除所有看门狗任务

param(
    [int]$IntervalSec = 0,
    [int]$MaxLogLines = 200,
    [switch]$SetupTask,
    [switch]$SetupTaskSilent,
    [switch]$RemoveAll
)

$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\env.ps1"

$LogFile = $WatchdogLog
$SingBoxPath = $SingBoxExe
$ScriptPath = $ToolkitRoot

# ========== 日志函数 ==========
function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"

    if (Test-Path $LogFile) {
        $logSize = (Get-Item $LogFile).Length
        if ($logSize -gt 512KB) {
            Move-Item $LogFile "$ScriptPath\logs\watchdog.old.log" -Force
        }
    }

    Add-Content $LogFile $line -Encoding UTF8

    $allLines = @(Get-Content $LogFile -ErrorAction SilentlyContinue)
    if ($allLines.Count -gt $MaxLogLines) {
        $keep = [Math]::Max(0, $allLines.Count - $MaxLogLines)
        $allLines[$keep..($allLines.Count - 1)] | Out-File $LogFile -Encoding utf8
    }
}

Write-Log "INFO" "=========================================="
Write-Log "INFO" "Watchdog started"

# ========== 核心检查逻辑 ==========
function Test-SingBoxRunning {
    return (Get-Process -Name "sing-box" -ErrorAction SilentlyContinue).Count -gt 0
}

function Get-SingBoxMemory {
    $p = Get-Process -Name "sing-box" -ErrorAction SilentlyContinue
    if ($p) { return [math]::Round($p.WorkingSet64 / 1MB, 1) }
    return 0
}

function Stop-SingBox {
    Write-Log "WARN" "Stopping sing-box..."
    Get-Process -Name "sing-box" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    $leftover = Get-Process -Name "sing-box" -ErrorAction SilentlyContinue
    if ($leftover) { $leftover | Stop-Process -Force; Start-Sleep -Seconds 1 }
    Write-Log "INFO" "sing-box stopped"
}

function Start-SingBox {
    Write-Log "INFO" "Starting sing-box..."
    $check = & $SingBoxPath check -c $ConfigPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR" "Config check failed"
        if (Test-Path $ConfigBackup) {
            Write-Log "WARN" "Restoring backup..."
            Copy-Item $ConfigBackup $ConfigPath -Force
        }
        return $false
    }
    try {
        # -WorkingDirectory 不能省：看门狗是 SYSTEM 计划任务调起来的，工作目录默认
        # 是 System32，而 config.json 里 log.output / external_ui 都是相对路径，
        # 拉起来的 sing-box 会没有面板、日志写进 System32。
        Start-Process -FilePath $SingBoxPath -ArgumentList "run", "-c", $ConfigPath `
            -WorkingDirectory $ToolkitRoot -Verb RunAs -WindowStyle Hidden
        Start-Sleep -Seconds 4
        if (Test-SingBoxRunning) { Write-Log "INFO" "Started OK"; return $true }
        else { Write-Log "ERROR" "Start failed"; return $false }
    } catch {
        Write-Log "ERROR" "Start exception: $($_.Exception.Message)"
        return $false
    }
}

# sing-box.log 自身没有轮转机制，会无限增长。
# 只在进程已停止（文件句柄释放）时轮转，避免占用冲突。
function Reset-SingBoxLog {
    param([int]$MaxMB = 20)
    $boxLog = Join-Path $ToolkitRoot "sing-box.log"
    if (-not (Test-Path $boxLog)) { return }
    try {
        $sizeMB = (Get-Item $boxLog).Length / 1MB
        if ($sizeMB -gt $MaxMB) {
            Move-Item $boxLog (Join-Path $ToolkitRoot "sing-box.old.log") -Force
            Write-Log "INFO" "Rotated sing-box.log ($([math]::Round($sizeMB,1))MB -> sing-box.old.log)"
        }
    } catch {
        Write-Log "WARN" "sing-box.log rotation skipped: $($_.Exception.Message)"
    }
}

function Restart-SingBox {
    Write-Log "WARN" "===== Restarting ====="
    Stop-SingBox
    Reset-SingBoxLog
    Start-Sleep -Seconds 1
    Start-SingBox
}

function Invoke-SingleCheck {
    Write-Log "DEBUG" "Health check running..."
    $healthy = $true; $reason = ""

    if (-not (Test-SingBoxRunning)) {
        Write-Log "ERROR" "Process not found"
        $healthy = $false; $reason = "Process not found"
    } else {
        $mem = Get-SingBoxMemory
        if ($mem -gt 800) {
            Write-Log "WARN" "High memory: ${mem}MB"
            $healthy = $false; $reason = "High memory (${mem}MB)"
        }

        try {
            $proxyPort = Get-ProxyPort
            $tcp = Get-NetTCPConnection -LocalPort $proxyPort -State Listen -ErrorAction SilentlyContinue
            if ($null -eq $tcp) {
                Write-Log "ERROR" "Port $proxyPort not listening"
                $healthy = $false; $reason = "Port not listening"
            }
        } catch {
            Write-Log "ERROR" "Port check exception"
            $healthy = $false; $reason = "Port check exception"
        }

        try {
            $netOk = Test-TcpPort "223.5.5.5" 53 3000
            if (-not $netOk) {
                Write-Log "ERROR" "Network unreachable (TCP 223.5.5.5:53)"
                $healthy = $false; $reason = "Network down"
            }
        } catch {
            Write-Log "ERROR" "Network test exception: $($_.Exception.Message)"
            $healthy = $false; $reason = "Network test exception"
        }
    }

    if (-not $healthy) {
        Write-Log "WARN" "Health check FAILED: $reason, restarting..."
        Restart-SingBox
        Start-Sleep -Seconds 5
        if (Test-SingBoxRunning) { Write-Log "INFO" "Restart OK" }
        else { Write-Log "ERROR" "Restart FAILED!" }
    } else {
        Write-Log "DEBUG" "All OK"
    }

    # 进程活着才谈得上选节点
    if (Test-SingBoxRunning) { Invoke-PreferCheck }
    return $healthy
}

# 偏好地区：只要该地区还有活节点就拉回去，全挂了才退到兜底。
# 只测该地区那几个节点，很快；没设偏好就直接跳过。
function Invoke-PreferCheck {
    $region = (Get-ToolkitState).preferredRegion
    if (-not $region) { return }
    try {
        $out = & "$ScriptDir\speedtest.ps1" -Enforce 2>&1
        foreach ($line in @($out)) {
            $s = "$line"
            if ($s -match 'changed=True')  { Write-Log "INFO"  "Prefer[$region] $s" }
            elseif ($s -match 'changed=False') { Write-Log "DEBUG" "Prefer[$region] $s" }
            elseif ($s) { Write-Log "WARN" "Prefer[$region] $s" }
        }
    } catch {
        Write-Log "WARN" "Prefer check failed: $($_.Exception.Message)"
    }
}

# ========== 安装计划任务 ==========
function Install-ScheduledTasks {
    param([bool]$Silent = $false)

    if (-not $Silent) {
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  Sing-Box Watchdog Setup" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host ""
    }

    # Task 1: Health check - BootTrigger + 5min repeat
    if (-not $Silent) { Write-Host "1/3 Installing health check (every 5min)..." -ForegroundColor Yellow }
    Unregister-ScheduledTask -TaskName "Sing-Box-Watchdog" -Confirm:$false -ErrorAction SilentlyContinue
    $t1a = New-ScheduledTaskTrigger -AtStartup -RandomDelay (New-TimeSpan -Minutes 1)
    $t1a.Repetition = (New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition
    $t1b = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    $a1 = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptDir\watchdog.ps1`""
    $p1 = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $s1 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName "Sing-Box-Watchdog" -Action $a1 -Trigger $t1a, $t1b -Principal $p1 -Settings $s1 -Description "Sing-Box health monitor: auto-restart on failure" -Force | Out-Null
    if (-not $Silent) { Write-Host "   OK: Sing-Box-Watchdog" -ForegroundColor Green }

    # Task 2: Daily restart at 4:00 AM
    if (-not $Silent) { Write-Host "2/3 Installing daily restart (4:00 AM)..." -ForegroundColor Yellow }
    Unregister-ScheduledTask -TaskName "Sing-Box-DailyRestart" -Confirm:$false -ErrorAction SilentlyContinue
    $t2 = New-ScheduledTaskTrigger -Daily -At "04:00"
    $a2 = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -Command `"Get-Process -Name sing-box -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2; Start-Process -FilePath '$SingBoxPath' -ArgumentList 'run', '-c', '$ConfigPath' -WorkingDirectory '$ToolkitRoot' -Verb RunAs -WindowStyle Hidden`""
    $p2 = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $s2 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -WakeToRun -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName "Sing-Box-DailyRestart" -Action $a2 -Trigger $t2 -Principal $p2 -Settings $s2 -Description "Sing-Box daily restart to prevent freeze" -Force | Out-Null
    if (-not $Silent) { Write-Host "   OK: Sing-Box-DailyRestart" -ForegroundColor Green }

    # Task 3: Memory guard - BootTrigger + 10min repeat
    if (-not $Silent) { Write-Host "3/3 Installing memory guard (every 10min)..." -ForegroundColor Yellow }
    Unregister-ScheduledTask -TaskName "Sing-Box-MemoryGuard" -Confirm:$false -ErrorAction SilentlyContinue
    $t3a = New-ScheduledTaskTrigger -AtStartup -RandomDelay (New-TimeSpan -Minutes 2)
    $t3a.Repetition = (New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition
    $t3b = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650)
    $a3 = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -Command `"`$p = Get-Process -Name sing-box -ErrorAction SilentlyContinue; if (`$p -and ([math]::Round(`$p.WorkingSet64/1MB,0) -gt 600)) { Get-Process -Name sing-box | Stop-Process -Force; Start-Sleep 2; Start-Process -FilePath '$SingBoxPath' -ArgumentList 'run', '-c', '$ConfigPath' -WorkingDirectory '$ToolkitRoot' -Verb RunAs -WindowStyle Hidden }`""
    $p3 = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $s3 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName "Sing-Box-MemoryGuard" -Action $a3 -Trigger $t3a, $t3b -Principal $p3 -Settings $s3 -Description "Sing-Box memory guard: restart if >600MB" -Force | Out-Null
    if (-not $Silent) { Write-Host "   OK: Sing-Box-MemoryGuard" -ForegroundColor Green }

    if (-not $Silent) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  All tasks installed!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Installed: Watchdog (5min) | DailyRestart (4AM) | MemoryGuard (10min)" -ForegroundColor DarkGray
        Write-Host "Log: $LogFile" -ForegroundColor DarkGray
        Write-Host ""
        Read-Host "按 Enter 返回"
    }
}

# ========== 移除所有任务 ==========
function Remove-AllTasks {
    Write-Host "Removing all Watchdog scheduled tasks..." -ForegroundColor Yellow
    @("Sing-Box-Watchdog", "Sing-Box-DailyRestart", "Sing-Box-MemoryGuard") | ForEach-Object {
        Unregister-ScheduledTask -TaskName $_ -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  Removed: $_" -ForegroundColor DarkGray
    }
    Write-Host "All removed" -ForegroundColor Green
}

# ========== 主入口 ==========
if ($SetupTask) {
    Install-ScheduledTasks -Silent $false
    exit 0
}

if ($SetupTaskSilent) {
    Install-ScheduledTasks -Silent $true
    exit 0
}

if ($RemoveAll) {
    Remove-AllTasks
    exit 0
}

if ($IntervalSec -gt 0) {
    Write-Log "INFO" "Loop mode (interval: ${IntervalSec}s)"
    while ($true) {
        Invoke-SingleCheck | Out-Null
        Start-Sleep -Seconds $IntervalSec
    }
} else {
    Invoke-SingleCheck | Out-Null
}
