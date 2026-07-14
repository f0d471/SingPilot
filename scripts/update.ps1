# Sing-Box Toolkit - Update Config
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\env.ps1"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Sing-Box - Update Config" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$subUrl = $null
if (Test-Path $StateFile) {
    try { $saved = Get-Content $StateFile -Raw | ConvertFrom-Json; $subUrl = $saved.subscriptionUrl } catch { }
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
if ($p) { Write-Host "OK: Updated and restarted (PID: $($p.Id))" -ForegroundColor Green }
else { Write-Host "FAIL: Start failed" -ForegroundColor Red }
Write-Host ""
Read-Host "Press Enter to return"
