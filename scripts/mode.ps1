# SingPilot - Proxy Mode (rule / global / direct)
# 通过 Clash API 热切换分流模式，不用改配置也不用重启。
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\env.ps1"

Clear-Host
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Proxy Mode" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

if (-not (Test-SingBoxRunning)) {
    Write-Host ""
    Write-Host "  代理未运行，请先在主菜单选 [1] 启动。" -ForegroundColor Red
    Write-Host ""; Read-Host "Press Enter to return"; return
}
$api = Get-ClashApi
if ($null -eq $api) {
    Write-Host ""
    Write-Host "  config.json 未启用 clash_api。" -ForegroundColor Red
    Write-Host ""; Read-Host "Press Enter to return"; return
}

try {
    $cfg = Invoke-RestMethod "$($api.BaseUrl)/configs" -Headers $api.Headers -TimeoutSec 5
} catch {
    Write-Host ""
    Write-Host "  无法连接 Clash API: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""; Read-Host "Press Enter to return"; return
}

$modes = @(
    @{ Key = "1"; Name = "rule";   Desc = "按规则分流 —— 国内直连、国外走代理（日常用这个）" },
    @{ Key = "2"; Name = "global"; Desc = "全部走代理 —— 分流规则失灵时用" },
    @{ Key = "3"; Name = "direct"; Desc = "全部直连 —— 临时不走代理，比停掉代理省事" }
)

Write-Host ""
Write-Host "  当前模式: " -NoNewline -ForegroundColor DarkGray
Write-Host $cfg.mode -ForegroundColor Green
Write-Host ""
foreach ($m in $modes) {
    $isCur = ($cfg.mode -and $cfg.mode.ToLower() -eq $m.Name)
    $mark  = if ($isCur) { "*" } else { " " }
    $color = if ($isCur) { "Green" } else { "White" }
    Write-Host "  $mark [$($m.Key)] " -NoNewline -ForegroundColor $color
    Write-Host ("{0,-7}" -f $m.Name) -NoNewline -ForegroundColor $color
    Write-Host $m.Desc -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "    [0] 返回"
Write-Host ""
$choice = Read-Host "  Select"

$pick = $modes | Where-Object { $_.Key -eq $choice } | Select-Object -First 1
if (-not $pick) { return }

try {
    $body = @{ mode = $pick.Name } | ConvertTo-Json -Compress
    Invoke-RestMethod "$($api.BaseUrl)/configs" -Method PATCH -Headers $api.Headers `
        -Body $body -ContentType "application/json" | Out-Null
    $now = (Invoke-RestMethod "$($api.BaseUrl)/configs" -Headers $api.Headers -TimeoutSec 5).mode
    Write-Host ""
    Write-Host "  模式已切换: $now" -ForegroundColor Green
    Write-Host "  (重启代理后会回到配置里的默认值)" -ForegroundColor DarkGray
} catch {
    Write-Host ""
    Write-Host "  切换失败: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""
Read-Host "Press Enter to return"
