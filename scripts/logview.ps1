# Sing-Box Toolkit - Log Viewer
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\env.ps1"

$logFile = Join-Path $ToolkitRoot "sing-box.log"

function Get-LogLevel {
    try {
        $json = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return $json.log.level
    } catch { return "unknown" }
}

function Get-LastLines($path, $n = 50) {
    if (-not (Test-Path $path)) { return @("(no log file: $path)") }
    return Get-Content $path -Tail $n -ErrorAction SilentlyContinue
}

Clear-Host
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Log Viewer" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$level = Get-LogLevel
Write-Host "  Config log level : $level" -ForegroundColor $(if ($level -eq "error"){"Red"}elseif($level -eq "warn"){"Yellow"}else{"Green"})
Write-Host "  Log file         : $logFile" -ForegroundColor DarkGray

Write-Host ""
Write-Host "  [1] View last 50 lines"
Write-Host "  [2] View last 200 lines"
if ((Test-SingBoxRunning) -and $level -ne "debug") {
    Write-Host "  [3] Temporarily set log level to debug (shows more detail)"
}
Write-Host "  [4] View watchdog log"
Write-Host "  [0] Back"
Write-Host ""

$choice = Read-Host "  Select"

switch ($choice) {
    "1" {
        Write-Host ""; Write-Host "--- Last 50 lines ---" -ForegroundColor Cyan
        Get-LastLines $logFile 50 | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
    }
    "2" {
        Write-Host ""; Write-Host "--- Last 200 lines ---" -ForegroundColor Cyan
        Get-LastLines $logFile 200 | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
    }
    "3" {
        Write-Host ""
        if (-not (Test-SingBoxRunning)) {
            Write-Host "sing-box is not running. Cannot change log level live." -ForegroundColor Red
        } else {
            Write-Host "NOTE: Changing log level requires config edit + restart." -ForegroundColor Yellow
            Write-Host "Current level: $level" -ForegroundColor White
            Write-Host ""
            Write-Host "Options: trace | debug | info | warn | error | fatal" -ForegroundColor DarkGray
            $newLevel = Read-Host "New level (or Enter to cancel)"
            if ($newLevel -and $newLevel -in @("trace","debug","info","warn","error","fatal")) {
                try {
                    $json = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $json.log.level = $newLevel
                    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
                    Copy-Item $ConfigPath $ConfigBackup -Force
                    $json | ConvertTo-Json -Depth 20 | Out-File $ConfigPath -Encoding utf8
                    Write-Host "OK: Log level changed to $newLevel" -ForegroundColor Green
                    Write-Host "Restart sing-box for changes to take effect." -ForegroundColor Yellow
                } catch {
                    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    }
    "4" {
        Write-Host ""; Write-Host "--- Watchdog Log ---" -ForegroundColor Cyan
        Get-LastLines $WatchdogLog 50 | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
    }
}

Write-Host ""
Read-Host "Press Enter to return"
