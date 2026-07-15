# SingPilot - Node Speed Test & Selector
# 直接打 Clash API 并发测速，绕开浏览器每源 6 连接的限制。
param(
    [string]$Url = "https://www.gstatic.com/generate_204",
    [int]$Timeout = 5000,
    [int]$Concurrency = 32,
    [switch]$Enforce,      # 非交互：按偏好地区自动选节点（看门狗调用）
    [int]$Tolerance = 100  # 容差(ms)：新节点要快过当前这么多才值得切，防止来回横跳
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

function Set-GroupNode($api, $group, $node) {
    $e = [uri]::EscapeDataString($group)
    $body = @{ name = $node } | ConvertTo-Json -Compress
    # body 必须显式转成 UTF-8 字节：PS 5.1 的 Invoke-RestMethod 对字符串 body
    # 不按 UTF-8 编码，节点名含中文/emoji 时会传成乱码，sing-box 报
    # "Selector update error: not found"。节点名是 ASCII 时碰巧没事，很能骗人。
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    Invoke-RestMethod "$($api.BaseUrl)/proxies/$e" -Method PUT -Headers $api.Headers `
        -Body $bytes -ContentType "application/json" -ErrorAction Stop | Out-Null
}

# 找出该操作哪个分组：优先含"主代理"的 selector
function Get-TargetGroup($groups) {
    $t = $groups | Where-Object { $_.Name -match '主代理|Proxy|PROXY' } | Select-Object -First 1
    if (-not $t) { $t = $groups | Select-Object -First 1 }
    return $t
}

# ---------------- 偏好地区强制执行 ----------------
# 语义："只要该地区还有活节点，就用该地区最快的；全挂了才退到兜底。"
# sing-box 的 urltest 只认延迟不认地区，selector 又不会故障转移，
# 所以这个语义只能在外面定期强制。
function Invoke-PreferEnforce {
    param($api, $info, [string]$region, [switch]$Quiet)

    $target = Get-TargetGroup $info.Groups
    if (-not $target) { return $null }

    $members = @($target.All)
    $cands = @($members | Where-Object { $_ -match "^$region" -and $info.Nodes -contains $_ })
    if ($cands.Count -eq 0) {
        if (-not $Quiet) { Write-Host "  分组 $($target.Name) 里没有匹配 '$region' 的节点" -ForegroundColor Yellow }
        return $null
    }

    # 只测该地区的几个节点，很快
    $res = Test-NodesParallel $api $cands $Url $Timeout $Concurrency
    $alive = @($res | Where-Object { $_.OK } | Sort-Object Delay)

    if ($alive.Count -gt 0) {
        $pick = $alive[0].Node
        $why  = "$region 最快 ($($alive[0].Delay)ms)"

        # 抖动抑制：当前节点如果就在偏好地区且还活着，除非新节点快出容差，
        # 否则不动。同地区节点延迟常在几十 ms 内浮动，不加这个的话看门狗
        # 每 5 分钟就会在 SG1/SG2 之间来回切，每切一次都断连接。
        $cur = $alive | Where-Object { $_.Node -eq $target.Now } | Select-Object -First 1
        if ($cur -and $pick -ne $cur.Node -and ($cur.Delay - $alive[0].Delay) -le $Tolerance) {
            $pick = $cur.Node
            $why  = "保持 $($cur.Node) ($($cur.Delay)ms)，最快的 $($alive[0].Node) ($($alive[0].Delay)ms) 未快出 ${Tolerance}ms"
        }
    } else {
        # 该地区全挂 —— 退到 urltest 分组（它每隔一段自测、能自愈），
        # 没有 urltest 就退到全局最快的活节点。
        $auto = @($members | Where-Object { $_ -notin $info.Nodes -and $_ -ne 'Direct' }) | Select-Object -First 1
        if ($auto) {
            $pick = $auto
            $why  = "$region 全部不可用，退到 $auto"
        } else {
            $allRes = Test-NodesParallel $api @($members | Where-Object { $info.Nodes -contains $_ }) $Url $Timeout $Concurrency
            $allAlive = @($allRes | Where-Object { $_.OK } | Sort-Object Delay)
            if ($allAlive.Count -eq 0) { return $null }
            $pick = $allAlive[0].Node
            $why  = "$region 全部不可用，退到全局最快 $pick"
        }
    }

    if ($target.Now -ne $pick) {
        # 切换失败必须如实报告，别报了成功其实没切
        try {
            Set-GroupNode $api $target.Name $pick
        } catch {
            return [PSCustomObject]@{ Group = $target.Name; From = $target.Now; To = $pick
                                      Why = $why; Changed = $false; Failed = $_.Exception.Message }
        }
        return [PSCustomObject]@{ Group = $target.Name; From = $target.Now; To = $pick; Why = $why; Changed = $true }
    }
    return [PSCustomObject]@{ Group = $target.Name; From = $target.Now; To = $pick; Why = $why; Changed = $false }
}

# ---------------- -Enforce：非交互，供看门狗调用 ----------------
if ($Enforce) {
    $region = (Get-ToolkitState).preferredRegion
    if (-not $region) { return }
    if (-not (Test-SingBoxRunning)) { return }
    $api = Get-ClashApi
    if ($null -eq $api) { return }
    try { $info = Get-Nodes $api } catch { return }
    $r = Invoke-PreferEnforce $api $info $region -Quiet
    if (-not $r) {
        # 说出来，否则偏好地区写错了会永远静默不生效
        Write-Output "no usable node for region '$region'"
        return
    }
    if ($r.Failed) { Write-Output "FAILED to switch to $($r.To): $($r.Failed)" }
    else { Write-Output "$($r.Group): $($r.From) -> $($r.To)  ($($r.Why))  changed=$($r.Changed)" }
    return
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

$target = Get-TargetGroup $info.Groups

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
    $region = (Get-ToolkitState).preferredRegion
    Write-Host "  偏好地区: " -NoNewline -ForegroundColor DarkGray
    if ($region) {
        Write-Host $region -NoNewline -ForegroundColor Cyan
        Write-Host "  (看门狗每次检查都会拉回该地区最快的；全挂才退到兜底)" -ForegroundColor DarkGray
    } else {
        Write-Host "未设置" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  [1-$($ok.Count)] 切换到指定节点    [f] 切到最快    [g] 换分组"
    Write-Host "  [p] 设置偏好地区    [r] 重测    [0] 返回"
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
    } elseif ($choice -eq 'p') {
        Write-Host ""
        $prefixes = @($ok | ForEach-Object { if ($_.Node -match '^([A-Za-z]+)') { $matches[1] } } | Select-Object -Unique | Sort-Object)
        Write-Host "  可用地区前缀: $($prefixes -join ', ')" -ForegroundColor DarkGray
        Write-Host "  留空 = 清除偏好" -ForegroundColor DarkGray
        Write-Host ""
        $r = Read-Host "  偏好地区 (当前: $(if ($region) { $region } else { '未设置' }))"
        if ([string]::IsNullOrWhiteSpace($r)) {
            Set-ToolkitState 'preferredRegion' $null
            Write-Host "  已清除偏好" -ForegroundColor Green
        } else {
            Set-ToolkitState 'preferredRegion' $r.Trim()
            Write-Host "  偏好已设为: $($r.Trim())" -ForegroundColor Green
            $er = Invoke-PreferEnforce $api $info $r.Trim()
            if ($er) {
                if ($er.Changed) { Write-Host "  $($er.Group): $($er.From) -> $($er.To)   ($($er.Why))" -ForegroundColor Green }
                else { Write-Host "  已经是 $($er.To)，无需切换  ($($er.Why))" -ForegroundColor DarkGray }
                $target.Now = $er.To
            }
        }
        Write-Host ""
        Read-Host "  Press Enter to continue"
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
            try {
                Set-GroupNode $api $target.Name $pick
                $target.Now = $pick
                Write-Host ""
                Write-Host "  $($target.Name)  ->  $pick" -ForegroundColor Green
            } catch {
                Write-Host "  切换失败: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        Write-Host ""
        Read-Host "  Press Enter to continue"
    } elseif ($choice -notin @('r', 'g', 'p')) {
        Write-Host "  无效选择" -ForegroundColor Red
        Start-Sleep -Seconds 1
    }
} while ($true)
