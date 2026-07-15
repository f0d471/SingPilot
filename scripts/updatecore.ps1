# SingPilot - Update sing-box Core
# 从 GitHub 拉最新内核。关键安全点：换上去之前先用"新内核"校验现有配置，
# 因为新版可能移除旧写法（比如 1.14 会移除 legacy DNS 格式），
# 配置过不了就别装 —— 装了会开不起来。
param(
    [switch]$CheckOnly,     # 只查版本，不安装
    [switch]$Force,         # 即使已是最新也重装
    [switch]$Pre            # 允许预发布版
)
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\env.ps1"

Clear-Host
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Update Core" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-SingBoxExists)) {
    Write-Host "  sing-box.exe 不存在，请先放进目录。" -ForegroundColor Red
    Write-Host ""; Read-Host "Press Enter to return"; return
}

$current = Get-SingBoxVersion
Write-Host "  当前版本: " -NoNewline -ForegroundColor DarkGray
Write-Host $current -ForegroundColor White

# ---- 查询官方最新版 ----
Write-Host "  查询 GitHub..." -ForegroundColor Yellow
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $api = if ($Pre) { "https://api.github.com/repos/SagerNet/sing-box/releases" }
           else      { "https://api.github.com/repos/SagerNet/sing-box/releases/latest" }
    $rel = Invoke-RestMethod $api -Headers @{ 'User-Agent' = 'SingPilot' } -TimeoutSec 30
    if ($Pre) { $rel = @($rel)[0] }
} catch {
    Write-Host "  查询失败: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""; Read-Host "Press Enter to return"; return
}

$latest = $rel.tag_name -replace '^v', ''
Write-Host "  最新版本: " -NoNewline -ForegroundColor DarkGray
Write-Host $latest -NoNewline -ForegroundColor White
Write-Host "   (发布于 $(([datetime]$rel.published_at).ToString('yyyy-MM-dd')))" -ForegroundColor DarkGray

if ($latest -eq $current -and -not $Force) {
    Write-Host ""
    Write-Host "  已是最新版本。" -ForegroundColor Green
    Write-Host ""; Read-Host "Press Enter to return"; return
}
if ($CheckOnly) {
    Write-Host ""
    Write-Host "  有新版本可用：$current -> $latest" -ForegroundColor Yellow
    Write-Host ""; Read-Host "Press Enter to return"; return
}

# ---- 找 Windows 安装包 ----
$arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
$asset = $rel.assets | Where-Object { $_.name -like "*windows-$arch.zip" } | Select-Object -First 1
if (-not $asset) {
    Write-Host "  没找到 windows-$arch 安装包。" -ForegroundColor Red
    Write-Host ""; Read-Host "Press Enter to return"; return
}

Write-Host ""
Write-Host "  即将升级: " -NoNewline -ForegroundColor DarkGray
Write-Host "$current -> $latest" -ForegroundColor Yellow
Write-Host "  安装包: $($asset.name)  ($([math]::Round($asset.size/1MB,1)) MB)" -ForegroundColor DarkGray
Write-Host ""
$go = Read-Host "  继续? [Y/n]"
if ($go -eq 'n' -or $go -eq 'N') { Write-Host "  已取消" -ForegroundColor DarkGray; return }

# ---- 下载并解包到临时目录 ----
$tmp = Join-Path $env:TEMP "singpilot-core-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$zip = Join-Path $tmp $asset.name
Write-Host ""
Write-Host "  下载中..." -ForegroundColor Yellow
try {
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -TimeoutSec 300
    Write-Host "  OK: 已下载" -ForegroundColor Green
} catch {
    Write-Host "  下载失败: $($_.Exception.Message)" -ForegroundColor Red
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ""; Read-Host "Press Enter to return"; return
}

try {
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
} catch {
    Write-Host "  解压失败: $($_.Exception.Message)" -ForegroundColor Red
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ""; Read-Host "Press Enter to return"; return
}

$newExe = Get-ChildItem $tmp -Recurse -Filter "sing-box.exe" | Select-Object -First 1
if (-not $newExe) {
    Write-Host "  压缩包里没有 sing-box.exe。" -ForegroundColor Red
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ""; Read-Host "Press Enter to return"; return
}

# ---- 换上去之前：用新内核验证现有配置 ----
# 这是整个脚本最重要的一步。新版可能移除你配置里正在用的旧写法，
# 装完才发现就晚了（代理起不来 = 断网）。
Write-Host ""
Write-Host "  用新内核校验现有配置..." -ForegroundColor Yellow
$verOut = & $newExe.FullName version 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host "  新内核跑不起来，放弃升级。" -ForegroundColor Red
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ""; Read-Host "Press Enter to return"; return
}
if (Test-ConfigExists) {
    $checkOut = & $newExe.FullName check -c $ConfigPath 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "  ❌ 现有配置在 $latest 下校验失败，升级已中止：" -ForegroundColor Red
        ($checkOut -split "`n" | Where-Object { $_ -match 'FATAL|ERROR' } | Select-Object -First 5) |
            ForEach-Object { Write-Host "     $($_.Trim())" -ForegroundColor Red }
        Write-Host ""
        Write-Host "  内核没动，代理不受影响。先把配置迁移到新写法再升级。" -ForegroundColor Yellow
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ""; Read-Host "Press Enter to return"; return
    }
    $warns = @($checkOut -split "`n" | Where-Object { $_ -match 'WARN' })
    Write-Host "  OK: 配置在 $latest 下有效" -NoNewline -ForegroundColor Green
    if ($warns.Count) { Write-Host "  (但有 $($warns.Count) 条弃用警告)" -ForegroundColor Yellow } else { Write-Host "" }
}

# ---- 停 -> 备份 -> 替换 -> 启动 ----
$wasRunning = Test-SingBoxRunning
if ($wasRunning) {
    Write-Host "  停止代理..." -ForegroundColor Yellow
    $proc = Get-SingBoxProcess
    try { $proc | Stop-Process -Force -ErrorAction Stop } catch {
        # 进程是提权跑的，普通权限停不掉 —— 提权再来一次
        Start-Process powershell -Verb RunAs -WindowStyle Hidden -Wait `
            -ArgumentList '-Command', "Stop-Process -Id $($proc.Id) -Force"
    }
    Start-Sleep -Seconds 2
}
if (Test-SingBoxRunning) {
    Write-Host "  进程停不掉，无法替换文件。请以管理员身份重试。" -ForegroundColor Red
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ""; Read-Host "Press Enter to return"; return
}

$exeBackup = Join-Path $BackupDir "sing-box-$current.exe"
Copy-Item $SingBoxExe $exeBackup -Force
Write-Host "  OK: 旧内核已备份 -> backup\sing-box-$current.exe" -ForegroundColor DarkGray

try {
    Copy-Item $newExe.FullName $SingBoxExe -Force
    Write-Host "  OK: 已替换为 $latest" -ForegroundColor Green
} catch {
    Write-Host "  替换失败: $($_.Exception.Message)" -ForegroundColor Red
    Copy-Item $exeBackup $SingBoxExe -Force
    Write-Host "  已回滚到 $current" -ForegroundColor Yellow
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

$installed = Get-SingBoxVersion
Write-Host "  实测版本: $installed" -ForegroundColor White

if ($wasRunning) {
    Write-Host "  重启代理..." -ForegroundColor Yellow
    Start-Process -FilePath $SingBoxExe -ArgumentList "run", "-c", $ConfigPath `
        -Verb RunAs -WindowStyle Hidden -WorkingDirectory $ToolkitRoot
    Start-Sleep -Seconds 3
    if (Test-SingBoxRunning) {
        Write-Host "  OK: 已用 $installed 重启 (PID: $((Get-SingBoxProcess).Id))" -ForegroundColor Green
    } else {
        # 起不来就把旧内核换回去 —— 断网比版本旧严重得多
        Write-Host "  ❌ 新内核启动失败，正在回滚..." -ForegroundColor Red
        Copy-Item $exeBackup $SingBoxExe -Force
        Start-Process -FilePath $SingBoxExe -ArgumentList "run", "-c", $ConfigPath `
            -Verb RunAs -WindowStyle Hidden -WorkingDirectory $ToolkitRoot
        Start-Sleep -Seconds 3
        if (Test-SingBoxRunning) { Write-Host "  已回滚到 $current 并重启" -ForegroundColor Yellow }
        else { Write-Host "  回滚后仍未启动，请手动运行 [1] Start" -ForegroundColor Red }
    }
}

Write-Host ""
Read-Host "Press Enter to return"
