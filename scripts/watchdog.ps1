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
    [switch]$RemoveAll,
    [switch]$DailyRestart
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

# 用户按 [2] 停止时 stop.ps1 会落下 manualStop 标记。没有它的话，看门狗分不清
# "用户主动停的"和"进程崩了"，5 分钟后照样拉起来 —— 停不掉的代理。
#
# 标记必须能自我过期：只要进程又活着了（用户 [1] 启动、开机自启、4 点重启任务），
# 就说明这次手动停止已经结束，立刻清掉恢复守护。否则标记会永久黏住，
# 看门狗从此形同虚设 —— 比原来的 bug 更糟。
function Test-ManualStop {
    $manual = [bool](Get-ToolkitState).manualStop
    if (-not $manual) { return $false }

    if (Test-SingBoxRunning) {
        Write-Log "INFO" "sing-box is running again, clearing manualStop flag"
        # 看门狗是 SYSTEM 跑的，写 state 文件失败不该让整次体检崩掉。
        # 清不掉就按"未停止"继续 —— 宁可守护照常跑，也不能让标记黏住把看门狗废掉。
        try { Set-ToolkitState "manualStop" $false }
        catch { Write-Log "WARN" "Failed to clear manualStop flag: $($_.Exception.Message)" }
        return $false
    }
    return $true
}

function Invoke-SingleCheck {
    Write-Log "DEBUG" "Health check running..."

    if (Test-ManualStop) {
        $at = (Get-ToolkitState).manualStopAt
        Write-Log "INFO" "Skipped: manually stopped at $at (use [1] to resume guarding)"
        return $true
    }

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
# 注册结果必须如实上报。原来是 Register-ScheduledTask | Out-Null 之后无条件
# 打印 "OK"，非管理员下三次 Access denied 照样宣布 "All tasks installed!"，
# 一个都没装。
function Register-TaskSafe {
    param($Name, $Action, $Trigger, $Principal, $Settings, $Description, [bool]$Silent)
    try {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $Name -Action $Action -Trigger $Trigger `
            -Principal $Principal -Settings $Settings -Description $Description `
            -Force -ErrorAction Stop | Out-Null
        if (-not $Silent) { Write-Host "   OK: $Name" -ForegroundColor Green }
        return $true
    } catch {
        if (-not $Silent) { Write-Host "   FAIL: $Name -> $($_.Exception.Message)" -ForegroundColor Red }
        return $false
    }
}

function Install-ScheduledTasks {
    param([bool]$Silent = $false)

    if (-not $Silent) {
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  Sing-Box Watchdog Setup" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host ""
    }

    # 注册 SYSTEM 计划任务必须管理员，否则每个 Register 都会 Access denied
    if (-not (Test-IsAdmin)) {
        if ($Silent) { return }
        Write-Host "需要管理员权限，正在请求提权..." -ForegroundColor Yellow
        Write-Host ""
        try {
            Start-Process powershell -Verb RunAs -Wait -ArgumentList `
                '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-SetupTask' -ErrorAction Stop
        } catch {
            Write-Host "提权被拒绝或失败：$($_.Exception.Message)" -ForegroundColor Red
            Write-Host "请用桌面的「Sing-Box 管理（管理员）」快捷方式重试。" -ForegroundColor Yellow
            Write-Host ""
            Read-Host "按 Enter 返回"
            return
        }
        # 提权窗口自己会报结果，这里只复核一遍
        $wd = Test-WatchdogInstalled
        Write-Host ""
        if ($wd.AllThree) { Write-Host "复核：3/3 已安装 ✅" -ForegroundColor Green }
        else { Write-Host "复核：只装上 $($wd.Count)/3 ❌" -ForegroundColor Red }
        Write-Host ""
        Read-Host "按 Enter 返回"
        return
    }

    $okCount = 0

    # Task 1: Health check - BootTrigger + 5min repeat
    if (-not $Silent) { Write-Host "1/3 Installing health check (every 5min)..." -ForegroundColor Yellow }
    $t1a = New-ScheduledTaskTrigger -AtStartup -RandomDelay (New-TimeSpan -Minutes 1)
    $t1a.Repetition = (New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition
    $t1b = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    $a1 = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptDir\watchdog.ps1`""
    $p1 = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $s1 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
    if (Register-TaskSafe "Sing-Box-Watchdog" $a1 @($t1a, $t1b) $p1 $s1 "Sing-Box health monitor: auto-restart on failure" $Silent) { $okCount++ }

    # Task 2: Daily restart at 4:00 AM
    if (-not $Silent) { Write-Host "2/3 Installing daily restart (4:00 AM)..." -ForegroundColor Yellow }
    $t2 = New-ScheduledTaskTrigger -Daily -At "04:00"
    # 调脚本而不是内联命令：内联版本无条件 Start，用户手动停了照样凌晨 4 点复活，
    # 而且逻辑锁在计划任务里改不动也测不了。
    $a2 = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptDir\watchdog.ps1`" -DailyRestart"
    $p2 = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $s2 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -WakeToRun -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    if (Register-TaskSafe "Sing-Box-DailyRestart" $a2 $t2 $p2 $s2 "Sing-Box daily restart to prevent freeze" $Silent) { $okCount++ }

    # Task 3: Memory guard - BootTrigger + 10min repeat
    if (-not $Silent) { Write-Host "3/3 Installing memory guard (every 10min)..." -ForegroundColor Yellow }
    $t3a = New-ScheduledTaskTrigger -AtStartup -RandomDelay (New-TimeSpan -Minutes 2)
    $t3a.Repetition = (New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition
    $t3b = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650)
    $a3 = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -Command `"`$p = Get-Process -Name sing-box -ErrorAction SilentlyContinue; if (`$p -and ([math]::Round(`$p.WorkingSet64/1MB,0) -gt 600)) { Get-Process -Name sing-box | Stop-Process -Force; Start-Sleep 2; Start-Process -FilePath '$SingBoxPath' -ArgumentList 'run', '-c', '$ConfigPath' -WorkingDirectory '$ToolkitRoot' -Verb RunAs -WindowStyle Hidden }`""
    $p3 = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $s3 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
    if (Register-TaskSafe "Sing-Box-MemoryGuard" $a3 @($t3a, $t3b) $p3 $s3 "Sing-Box memory guard: restart if >600MB" $Silent) { $okCount++ }

    # 不能光看 Register 有没有抛错，再去系统里查一遍才算数
    $verify = Test-WatchdogInstalled

    if (-not $Silent) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        if ($verify.AllThree) {
            Write-Host "  已安装 3/3 ✅" -ForegroundColor Green
        } else {
            Write-Host "  只装上 $($verify.Count)/3 ❌" -ForegroundColor Red
        }
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host ""
        if ($verify.AllThree) {
            Write-Host "Watchdog (5min) | DailyRestart (4AM) | MemoryGuard (10min)" -ForegroundColor DarkGray
            $region = (Get-ToolkitState).preferredRegion
            if ($region) { Write-Host "偏好地区 $region：每次健康检查都会拉回该地区最快的节点" -ForegroundColor DarkGray }
        } else {
            Write-Host "请用桌面的「Sing-Box 管理（管理员）」快捷方式重试。" -ForegroundColor Yellow
        }
        Write-Host "Log: $LogFile" -ForegroundColor DarkGray
        Write-Host ""
        Read-Host "按 Enter 返回"
    }
    return $verify.AllThree
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

# 每日 4:00 主动重启，防慢性内存泄漏。用户手动停止期间跳过 —— 这个任务
# 原本是无条件 Start，是"停了第二天早上又自己回来"的第二个来源。
if ($DailyRestart) {
    if (Test-ManualStop) {
        $at = (Get-ToolkitState).manualStopAt
        Write-Log "INFO" "Daily restart skipped: manually stopped at $at"
        exit 0
    }
    Write-Log "INFO" "Daily scheduled restart"
    Restart-SingBox
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
