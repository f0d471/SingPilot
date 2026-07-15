# SingPilot - Interactive Menu Engine
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\env.ps1"

function Pause-Menu {
    Write-Host ""
    Read-Host "Press Enter to return"
}

function Show-Header {
    Clear-Host
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  SingPilot" -NoNewline -ForegroundColor White
    Write-Host "  ~ AI-native control plane for sing-box" -ForegroundColor DarkGray
    Write-Host "========================================" -ForegroundColor Cyan
}

function Show-StatusLine($Label, $Value, $Color = "White") {
    Write-Host "  $Label" -NoNewline -ForegroundColor DarkGray
    Write-Host ": $Value" -ForegroundColor $Color
}

function Show-MenuItem($Key, $Text, $Enabled = $true) {
    if ($Enabled) {
        Write-Host "  [$Key] $Text" -ForegroundColor White
    } else {
        Write-Host "  [$Key] $Text (N/A)" -ForegroundColor DarkGray
    }
}

do {
    Show-Header
    $state = Get-ToolkitSnapshot

    # --- Status block ---
    if ($state.SingBoxExists) {
        Show-StatusLine "sing-box.exe" "OK v$($state.SingBoxVersion)" "Green"
    } else {
        Show-StatusLine "sing-box.exe" "NOT FOUND" "Red"
    }

    if ($state.ConfigExists -and $state.ConfigValid) {
        $feats = @()
        if ($state.Capabilities.HasTUN) { $feats += "TUN" }
        if ($state.Capabilities.HasClashAPI) { $feats += "ClashAPI" }
        if ($state.Capabilities.HasRouteRules) { $feats += "Routing" }
        $feats += "$($state.Capabilities.NodeCount) nodes"
        Show-StatusLine "config.json" "OK ($($feats -join ', '))" "Green"
    } elseif ($state.ConfigExists) {
        Show-StatusLine "config.json" "INVALID" "Yellow"
    } else {
        Show-StatusLine "config.json" "NOT FOUND" "Red"
    }

    if (-not $state.SingBoxExists -or -not $state.ConfigExists) {
        Show-StatusLine "Status" "Waiting for files..." "Yellow"
    } elseif ($state.IsRunning) {
        $uptimeStr = ""
        try {
            $ts = $state.Uptime
            if ($ts -and $ts.TotalSeconds -gt 0) {
                if ($ts.Days -gt 0) { $uptimeStr = "$($ts.Days)d $($ts.Hours)h $($ts.Minutes)m" }
                elseif ($ts.Hours -gt 0) { $uptimeStr = "$($ts.Hours)h $($ts.Minutes)m" }
                else { $uptimeStr = "$($ts.Minutes)m" }
            }
        } catch { }
        Show-StatusLine "Status" "RUNNING  PID:$($state.PID)  Mem:$($state.MemoryMB)MB  Up:$uptimeStr" "Green"
    } else {
        Show-StatusLine "Status" "STOPPED" "Red"
    }

    $extras = @()
    if ($state.Watchdog.Installed) { $extras += "Watchdog: $($state.Watchdog.Count)/3" }
    if ($state.Autostart) { $extras += "Autostart: ON" }
    if ($extras.Count -gt 0) {
        Show-StatusLine "Services" ($extras -join '  |  ') "DarkGray"
    }

    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # --- Menu items ---
    $ready = $state.SingBoxExists -and $state.ConfigExists -and $state.ConfigValid

    Show-MenuItem "1" "Start Proxy" $ready
    Show-MenuItem "2" "Stop Proxy" ($ready -and $state.IsRunning)
    Show-MenuItem "3" "View Status" $ready
    Show-MenuItem "4" "Switch Nodes (Dashboard)" ($ready -and $state.IsRunning -and $state.Capabilities.HasClashAPI)
    Show-MenuItem "5" "Update Config" $ready
    Show-MenuItem "6" $(if ($state.Watchdog.Installed) { "Remove Watchdog" } else { "Install Watchdog (anti-freeze)" }) $ready
    Show-MenuItem "7" $(if ($state.Autostart) { "Disable Autostart" } else { "Enable Autostart" }) $ready
    Show-MenuItem "8" "Setup Wizard" $true
    Show-MenuItem "9" "System Proxy" $ready
    Show-MenuItem "10" "DNS Tools" $ready
    Show-MenuItem "11" "Log Viewer" $ready
    Show-MenuItem "12" "Speed Test / Switch Node" ($ready -and $state.IsRunning -and $state.Capabilities.HasClashAPI)
    Show-MenuItem "13" "Proxy Mode (rule/global/direct)" ($ready -and $state.IsRunning -and $state.Capabilities.HasClashAPI)
    Show-MenuItem "14" "Update Core (sing-box.exe)" $state.SingBoxExists
    Show-MenuItem "0" "Exit" $true

    Write-Host ""

    # --- Hints ---
    if (-not $state.SingBoxExists) {
        Write-Host "  TIP: Download sing-box.exe from https://github.com/Sagernet/sing-box/releases" -ForegroundColor Yellow
    }
    if (-not $state.ConfigExists) {
        Write-Host "  TIP: Place your config.json here, then run [8] Setup Wizard" -ForegroundColor Yellow
    }
    if ($state.SingBoxExists -and $state.ConfigValid -and -not $state.IsRunning) {
        Write-Host "  TIP: Proxy not running, select [1] to start" -ForegroundColor Yellow
    }

    Write-Host ""
    $choice = Read-Host "  Select [0-14]"

    switch ($choice) {
        "1" {
            if (-not $ready) { Write-Host "Cannot start: missing files" -ForegroundColor Red; Pause-Menu; continue }
            if ($state.IsRunning) { Write-Host "Already running" -ForegroundColor Yellow; Pause-Menu; continue }
            & "$ScriptDir\start.ps1"
            Pause-Menu
        }
        "2" {
            if (-not $state.IsRunning) { Write-Host "Not running" -ForegroundColor Yellow; Pause-Menu; continue }
            & "$ScriptDir\stop.ps1"
            Write-Host ""
            Write-Host "Proxy 已停止，请关闭此窗口。" -ForegroundColor Green
            Read-Host "按 Enter 退出"
            $choice = "0"
        }
        "3" {
            & "$ScriptDir\status.ps1"
        }
        "4" {
            if (-not $state.IsRunning) { Write-Host "Proxy not running" -ForegroundColor Red; Pause-Menu; continue }
            $port = if ($state.Capabilities.ClashPort) { $state.Capabilities.ClashPort } else { "9090" }
            $url = "http://127.0.0.1:${port}/ui"
            Write-Host ""; Write-Host "Opening browser: $url" -ForegroundColor Yellow
            try { Start-Process $url } catch { Write-Host "Please visit: $url" -ForegroundColor DarkGray }
            Pause-Menu
        }
        "5" {
            & "$ScriptDir\update.ps1"
            Pause-Menu
        }
        "6" {
            if ($state.Watchdog.Installed) {
                & "$ScriptDir\watchdog.ps1" -RemoveAll
            } else {
                & "$ScriptDir\watchdog.ps1" -SetupTask
            }
            Pause-Menu
        }
        "7" {
            if ($state.Autostart) {
                Write-Host ""; Write-Host "Removing autostart..." -ForegroundColor Yellow
                try { Unregister-ScheduledTask -TaskName "Sing-Box" -Confirm:$false -ErrorAction Stop; Write-Host "Done: disabled" -ForegroundColor Green } catch { Write-Host "Failed" -ForegroundColor Red }
            } else {
                Write-Host ""; Write-Host "Setting autostart..." -ForegroundColor Yellow
                $exe = $ToolkitRoot + "\sing-box.exe"; $cfg = $ToolkitRoot + "\config.json"
                $act = New-ScheduledTaskAction -Execute $exe -Argument "run -c `"$cfg`""
                $trig = New-ScheduledTaskTrigger -AtStartup
                $prin = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
                $sets = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
                try {
                    Unregister-ScheduledTask -TaskName "Sing-Box" -Confirm:$false -ErrorAction SilentlyContinue
                    Register-ScheduledTask -TaskName "Sing-Box" -Action $act -Trigger $trig -Principal $prin -Settings $sets -Force | Out-Null
                    Write-Host "Done: enabled" -ForegroundColor Green
                } catch { Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red }
            }
            Pause-Menu
        }
        "8" {
            & "$ScriptDir\setup.ps1"
            Pause-Menu
        }
        "9" {
            & "$ScriptDir\sysproxy.ps1"
        }
        "10" {
            & "$ScriptDir\dnstool.ps1"
        }
        "11" {
            & "$ScriptDir\logview.ps1"
        }
        "12" {
            if (-not $state.IsRunning) { Write-Host "Proxy not running" -ForegroundColor Red; Pause-Menu; continue }
            & "$ScriptDir\speedtest.ps1"
        }
        "13" {
            if (-not $state.IsRunning) { Write-Host "Proxy not running" -ForegroundColor Red; Pause-Menu; continue }
            & "$ScriptDir\mode.ps1"
        }
        "14" {
            & "$ScriptDir\updatecore.ps1"
        }
        "0" {
            Write-Host ""; Write-Host "Bye!" -ForegroundColor Green
            $choice = "0"
        }
        default {
            Write-Host "Invalid choice" -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
} while ($choice -ne "0")
