# SingPilot - Node Speed Test & Selector
# 直接打 Clash API 并发测速，绕开浏览器每源 6 连接的限制。
param(
    [string]$Url = "https://www.gstatic.com/generate_204",
    [int]$Timeout = 5000,
    [int]$Concurrency = 32
)
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\env.ps1"

# 分组和内置出站不是"节点"，测它们没有意义
$GroupTypes = @('Selector', 'URLTest', 'Direct', 'Reject', 'RejectDrop',
                'Block', 'Dns', 'Compatible', 'Fallback', 'LoadBalance', 'Pass')

function Get-Nodes($api) {
    $p = Invoke-RestMethod "$($api.BaseUrl)/proxies" -Headers $api.Headers
    $real = @()
    $groups = @()
    foreach ($prop in $p.proxies.PSObject.Properties) {
        if ($prop.Value.type -eq 'Selector') {
            $groups += [PSCustomObject]@{ Name = $prop.Name; Now = $prop.Value.now; All = @($prop.Value.all) }
        } elseif ($prop.Value.type -notin $GroupTypes) {
            $real += $prop.Name
        }
    }
    return @{ Nodes = $real; Groups = $groups }
}

# PowerShell 5.1 没有 ForEach-Object -Parallel，用 runspace pool 手动并发。
function Test-NodesParallel($api, $nodes, $url, $timeoutMs, $throttle) {
    $pool = [RunspaceFactory]::CreateRunspacePool(1, $throttle)
    $pool.Open()
    $work = @()
    $enc = [uri]::EscapeDataString($url)

    $sb = {
        param($baseUrl, $headers, $node, $enc, $timeoutMs)
        $e = [uri]::EscapeDataString($node)
        $uri = "$baseUrl/proxies/$e/delay?timeout=$timeoutMs&url=$enc"
        try {
            $r = Invoke-RestMethod $uri -Headers $headers -TimeoutSec ([int]($timeoutMs / 1000) + 10)
            [PSCustomObject]@{ Node = $node; Delay = [int]$r.delay; OK = $true }
        } catch {
            [PSCustomObject]@{ Node = $node; Delay = 0; OK = $false }
        }
    }

    foreach ($n in $nodes) {
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript($sb).AddArgument($api.BaseUrl).AddArgument($api.Headers).
                    AddArgument($n).AddArgument($enc).AddArgument($timeoutMs)
        $work += [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
    }

    $results = @()
    foreach ($w in $work) {
        try { $results += $w.PS.EndInvoke($w.Handle) } catch { }
        $w.PS.Dispose()
    }
    $pool.Close(); $pool.Dispose()
    return $results
}

function Show-Results($results) {
    $ok   = @($results | Where-Object { $_.OK } | Sort-Object Delay)
    $dead = @($results | Where-Object { -not $_.OK })

    Write-Host ""
    Write-Host "  可用节点 ($($ok.Count))" -ForegroundColor Green
    Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
    $i = 1
    foreach ($r in $ok) {
        $color = if ($r.Delay -lt 300) { "Green" } elseif ($r.Delay -lt 800) { "Yellow" } else { "Red" }
        Write-Host ("  {0,3}. " -f $i) -NoNewline -ForegroundColor DarkGray
        Write-Host ("{0,-32}" -f $r.Node) -NoNewline -ForegroundColor White
        Write-Host ("{0,6} ms" -f $r.Delay) -ForegroundColor $color
        $i++
    }
    if ($dead.Count -gt 0) {
        Write-Host ""
        Write-Host "  超时/不可用 ($($dead.Count)): " -NoNewline -ForegroundColor DarkGray
        Write-Host (($dead | Select-Object -ExpandProperty Node) -join ", ") -ForegroundColor DarkGray
    }
    return $ok
}

# ---------------- 主流程 ----------------
Clear-Host
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Speed Test" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

if (-not (Test-SingBoxRunning)) {
    Write-Host ""
    Write-Host "  代理未运行，请先在主菜单选 [1] 启动。" -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to return"
    return
}

$api = Get-ClashApi
if ($null -eq $api) {
    Write-Host ""
    Write-Host "  config.json 未启用 clash_api，无法测速。" -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to return"
    return
}

try {
    $info = Get-Nodes $api
} catch {
    Write-Host ""
    Write-Host "  无法连接 Clash API ($($api.BaseUrl)): $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to return"
    return
}

$nodes = $info.Nodes
if ($nodes.Count -eq 0) {
    Write-Host ""
    Write-Host "  配置里没有可测的节点。" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to return"
    return
}

# 默认操作含 "主代理" 的分组；没有就用第一个 selector
$target = $info.Groups | Where-Object { $_.Name -match '主代理|Proxy|PROXY' } | Select-Object -First 1
if (-not $target) { $target = $info.Groups | Select-Object -First 1 }

do {
    Write-Host ""
    Write-Host "  正在并发测速 $($nodes.Count) 个节点 (并发 $Concurrency, 超时 $($Timeout)ms)..." -ForegroundColor Yellow
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $results = Test-NodesParallel $api $nodes $Url $Timeout $Concurrency
    $sw.Stop()

    $ok = Show-Results $results
    Write-Host ""
    Write-Host ("  耗时 {0:N1}s   测速地址 {1}" -f ($sw.ElapsedMilliseconds / 1000), $Url) -ForegroundColor DarkGray

    if ($target) {
        Write-Host ""
        Write-Host "  目标分组: " -NoNewline -ForegroundColor DarkGray
        Write-Host $target.Name -NoNewline -ForegroundColor Cyan
        Write-Host "   当前: " -NoNewline -ForegroundColor DarkGray
        Write-Host $target.Now -ForegroundColor White
    }

    Write-Host ""
    Write-Host "  [1-$($ok.Count)] 切换到指定节点    [f] 切到最快    [g] 换分组    [r] 重测    [0] 返回"
    Write-Host ""
    $choice = Read-Host "  Select"

    $pick = $null
    if ($choice -eq 'f') {
        if ($ok.Count -gt 0) { $pick = $ok[0].Node }
    } elseif ($choice -eq 'g') {
        Write-Host ""
        $gi = 1
        foreach ($g in $info.Groups) { Write-Host ("  {0,3}. {1}  (当前: {2})" -f $gi, $g.Name, $g.Now); $gi++ }
        Write-Host ""
        $gc = Read-Host "  选择分组"
        $gn = 0
        if ([int]::TryParse($gc, [ref]$gn) -and $gn -ge 1 -and $gn -le $info.Groups.Count) {
            $target = $info.Groups[$gn - 1]
            Write-Host "  已切换目标分组: $($target.Name)" -ForegroundColor Green
            Start-Sleep -Seconds 1
        }
        continue
    } elseif ($choice -eq 'r') {
        continue
    } elseif ($choice -eq '0') {
        break
    } else {
        $n = 0
        if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $ok.Count) {
            $pick = $ok[$n - 1].Node
        }
    }

    if ($pick) {
        if (-not $target) {
            Write-Host "  没有可操作的分组。" -ForegroundColor Red
        } elseif ($target.All -notcontains $pick) {
            Write-Host "  节点 $pick 不属于分组 $($target.Name)，换个分组试试。" -ForegroundColor Red
        } else {
            $e = [uri]::EscapeDataString($target.Name)
            $body = @{ name = $pick } | ConvertTo-Json -Compress
            try {
                Invoke-RestMethod "$($api.BaseUrl)/proxies/$e" -Method PUT -Headers $api.Headers `
                    -Body $body -ContentType "application/json" | Out-Null
                $target.Now = $pick
                Write-Host ""
                Write-Host "  $($target.Name)  ->  $pick" -ForegroundColor Green
            } catch {
                Write-Host "  切换失败: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        Write-Host ""
        Read-Host "  Press Enter to continue"
    } elseif ($choice -ne 'r' -and $choice -ne 'g') {
        Write-Host "  无效选择" -ForegroundColor Red
        Start-Sleep -Seconds 1
    }
} while ($true)
