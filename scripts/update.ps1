# SingPilot - Update Config
param([switch]$Reset)   # -Reset: 忘掉已保存的订阅地址，重新输入
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\env.ps1"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  SingPilot - Update Config" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$subUrl = $null
if ($Reset -and (Test-Path $StateFile)) {
    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    Write-Host "Saved subscription cleared." -ForegroundColor Yellow
}
if (-not $Reset -and (Test-Path $StateFile)) {
    try { $saved = Get-Content $StateFile -Raw | ConvertFrom-Json; $subUrl = $saved.subscriptionUrl } catch { }
    if ($subUrl) {
        # 只显示主机名 —— 完整地址含 token，等于机场账号密码
        $shown = try { ([uri]$subUrl).Host } catch { "?" }
        Write-Host "Using saved subscription: " -NoNewline -ForegroundColor DarkGray
        Write-Host $shown -ForegroundColor White
        if ($saved.lastUpdate) { Write-Host "Last update: $($saved.lastUpdate)" -ForegroundColor DarkGray }
        Write-Host "(change it with: update.ps1 -Reset)" -ForegroundColor DarkGray
        Write-Host ""
    }
}
if (-not $subUrl -and (Test-ConfigExists)) {
    try { $raw = Get-Content $ConfigPath -Raw; if ($raw -match '(https?://[^\s"''<>]+(?:sid|token|sub|subscribe)[^\s"''<>]*)') { $detected = $matches[1]; Write-Host "Detected URL: $detected" -ForegroundColor DarkGray; $use = Read-Host "Use this? [Y/n]"; if ($use -ne 'n' -and $use -ne 'N') { $subUrl = $detected } } } catch { }
}
if (-not $subUrl) {
    Write-Host "Enter subscription URL (from your service provider):" -ForegroundColor Yellow
    $subUrl = Read-Host "URL"
    if (-not $subUrl) { Write-Host "Cancelled" -ForegroundColor Red; Read-Host "Press Enter to return"; exit 1 }
}
try { @{ subscriptionUrl = $subUrl; lastUpdate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") } | ConvertTo-Json | Out-File $StateFile -Encoding utf8 } catch { }

$old = Get-Process -Name "sing-box" -ErrorAction SilentlyContinue
if ($old) { Write-Host "Stopping..." -ForegroundColor Yellow; $old | Stop-Process -Force; Start-Sleep -Seconds 1 }
if (Test-Path $ConfigPath) {
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    Copy-Item $ConfigPath $ConfigBackup -Force
    Write-Host "OK: Config backed up" -ForegroundColor DarkGray
}
Write-Host "Downloading..." -ForegroundColor Yellow
try {
    $resp = Invoke-WebRequest -Uri $subUrl -UseBasicParsing -TimeoutSec 30
    [System.IO.File]::WriteAllText($ConfigPath, $resp.Content, [System.Text.UTF8Encoding]::new($false))
    Write-Host "OK: Downloaded ($($resp.Content.Length) chars)" -ForegroundColor Green
} catch {
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path $ConfigBackup) { Copy-Item $ConfigBackup $ConfigPath -Force; Write-Host "Backup restored" -ForegroundColor Yellow }
    Read-Host "Press Enter to return"; exit 1
}
# 订阅是机场原样生成的，本地定制（日志输出、TUN 网卡名等）必须重新贴回去。
# 放在校验之前：万一覆盖层写错了，下面的 check 会失败并自动回滚。
Write-Host "Applying local overrides..." -ForegroundColor Yellow
try {
    if (Merge-LocalOverrides $ConfigPath) {
        Write-Host "OK: config.local.json merged" -ForegroundColor Green
    } else {
        Write-Host "SKIP: no config.local.json" -ForegroundColor DarkGray
    }
} catch {
    Write-Host "FAIL: merge error: $($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path $ConfigBackup) { Copy-Item $ConfigBackup $ConfigPath -Force; Write-Host "Backup restored" -ForegroundColor Yellow }
    Read-Host "Press Enter to return"; exit 1
}

Write-Host "Validating..." -ForegroundColor Yellow
$check = & $SingBoxExe check -c $ConfigPath 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAIL: Invalid config" -ForegroundColor Red
    if (Test-Path $ConfigBackup) { Copy-Item $ConfigBackup $ConfigPath -Force; Write-Host "Backup restored" -ForegroundColor Yellow }
    Read-Host "Press Enter to return"; exit 1
}
Write-Host "OK: Config valid" -ForegroundColor Green
Write-Host "Starting..." -ForegroundColor Yellow
Start-Process -FilePath $SingBoxExe -ArgumentList "run", "-c", $ConfigPath -Verb RunAs -WindowStyle Hidden -WorkingDirectory $ToolkitRoot
Start-Sleep -Seconds 3
$p = Get-Process -Name "sing-box" -ErrorAction SilentlyContinue
if ($p) {
    Write-Host "OK: Updated and restarted (PID: $($p.Id))" -ForegroundColor Green
} else {
    # check 通过不代表起得来：有些错误只在启动时暴露
    # （比如新版 DNS 格式下 detour 指向空 direct 出站，check 不报、启动直接 FATAL）。
    # 起不来就把配置换回去 —— 断网比订阅旧严重得多。
    Write-Host "FAIL: 新配置启动失败，正在回滚..." -ForegroundColor Red
    if (Test-Path $ConfigBackup) {
        Copy-Item $ConfigBackup $ConfigPath -Force
        Start-Process -FilePath $SingBoxExe -ArgumentList "run", "-c", $ConfigPath -Verb RunAs -WindowStyle Hidden -WorkingDirectory $ToolkitRoot
        Start-Sleep -Seconds 3
        if (Get-Process -Name "sing-box" -ErrorAction SilentlyContinue) {
            Write-Host "已回滚到更新前的配置并重启。" -ForegroundColor Yellow
        } else {
            Write-Host "回滚后仍未启动，请手动运行 [1] Start。" -ForegroundColor Red
        }
    } else {
        Write-Host "没有备份可回滚。" -ForegroundColor Red
    }
}
Write-Host ""
Read-Host "Press Enter to return"
