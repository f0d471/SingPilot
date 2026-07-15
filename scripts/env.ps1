# ============================================================
# SingPilot - 环境检测核心
# 所有脚本通过 ". $PSScriptRoot\env.ps1" 引入
# ============================================================

# ---- 路径解析 ----
$Script:ToolkitRoot = if ($PSScriptRoot -match '[\\/]scripts$') {
    Split-Path $PSScriptRoot -Parent
} else {
    $PSScriptRoot
}
$Script:SingBoxExe    = Join-Path $ToolkitRoot "sing-box.exe"
$Script:ConfigPath    = Join-Path $ToolkitRoot "config.json"
$Script:LogDir        = Join-Path $ToolkitRoot "logs"
$Script:UIDir         = Join-Path $ToolkitRoot "ui"
$Script:BackupDir     = Join-Path $ToolkitRoot "backup"
$Script:ConfigBackup  = Join-Path $BackupDir "config.backup.json"
$Script:StateFile     = Join-Path $LogDir "toolkit-state.json"
$Script:WatchdogLog   = Join-Path $LogDir "watchdog.log"

# ---- 确保必要目录存在 ----
@($LogDir, $BackupDir) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

# ---- 基础检测 ----
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-SingBoxExists {
    return Test-Path $SingBoxExe
}

function Get-SingBoxVersion {
    if (-not (Test-SingBoxExists)) { return $null }
    try {
        $output = @(& $SingBoxExe version 2>&1)
        $firstLine = $output[0]
        if ($firstLine -match 'sing-box version (\S+)') { return $matches[1] }
    } catch { }
    return "unknown"
}

function Test-ConfigExists {
    return Test-Path $ConfigPath
}

function Test-ConfigValid {
    if (-not (Test-ConfigExists)) { return $false }
    try {
        $null = & $SingBoxExe check -c $ConfigPath 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

# ---- 进程检测 ----
function Get-SingBoxProcess {
    $procs = @(Get-Process -Name "sing-box" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $null }
    return $procs[0]  # Return only the first one
}

function Test-SingBoxRunning {
    return ($null -ne (Get-SingBoxProcess))
}

function Get-SingBoxStatus {
    $proc = Get-SingBoxProcess
    if ($null -eq $proc) {
        return @{ Running = $false; PID = $null; MemoryMB = 0; Uptime = $null; StartTime = $null }
    }
    # compute uptime safely
    $uptime = $null
    $startTime = $null
    try {
        $startTime = $proc.StartTime
        if ($null -ne $startTime) {
            $uptime = (Get-Date) - $startTime
        }
    } catch { }
    # compute memory safely
    $mem = 0
    try { $mem = [math]::Round($proc.WorkingSet64 / 1MB, 1) } catch { }
    return @{
        Running   = $true
        PID       = $proc.Id
        MemoryMB  = $mem
        Uptime    = $uptime
        StartTime = $startTime
    }
}

# ---- 代理端口解析 ----
# 从 config.json 的 mixed/socks/http 入站读取 listen_port，
# 让工具箱不依赖任何写死的端口号（不同用户配置端口不同）。
function Get-ProxyPort {
    param([int]$Default = 2080)
    if (-not (Test-ConfigExists)) { return $Default }
    try {
        $json = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $inbounds = @($json.inbounds)
        foreach ($type in @('mixed', 'socks', 'http')) {
            $ib = $inbounds | Where-Object { $_.type -eq $type -and $_.listen_port } | Select-Object -First 1
            if ($ib) { return [int]$ib.listen_port }
        }
    } catch { }
    return $Default
}

# ---- 端口检测 ----
function Test-ProxyPortListening {
    param([int]$Port = 0)
    if ($Port -le 0) { $Port = Get-ProxyPort }
    try {
        $tcp = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        return ($null -ne $tcp)
    } catch { return $false }
}

function Get-ListeningPorts {
    $proc = Get-SingBoxProcess
    if (-not $proc) { return @() }
    try {
        return @(Get-NetTCPConnection -OwningProcess $proc.Id -State Listen -ErrorAction SilentlyContinue |
            Select-Object LocalAddress, LocalPort)
    } catch { return @() }
}

# ---- TUN 检测 ----
function Get-TunAdapter {
    return Get-NetAdapter -Name "sing-box*" -ErrorAction SilentlyContinue
}

function Test-TunExists {
    $adapter = Get-TunAdapter
    return ($null -ne $adapter)
}

# ---- 网络连通性 ----
function Test-TcpPort {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMs = 3000
    )
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $result = $client.BeginConnect($HostName, $Port, $null, $null)
        if ($result.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $client.EndConnect($result)
            $client.Close()
            return $true
        }
        $client.Close()
        return $false
    } catch {
        return $false
    }
}

function Test-NetworkConnectivity {
    $results = @{ Domestic = $false; Foreign = $false; ProxyPort = $false }

    $results.Domestic = Test-TcpPort "223.5.5.5" 53
    if (-not $results.Domestic) {
        $results.Domestic = Test-TcpPort "www.baidu.com" 443
    }

    $results.Foreign   = Test-TcpPort "www.google.com" 443
    $results.ProxyPort = Test-TcpPort "127.0.0.1" (Get-ProxyPort)

    return $results
}

# ---- 配置能力检测 ----
function Get-ConfigCapabilities {
    if (-not (Test-ConfigExists)) {
        return @{
            Valid         = $false
            HasTUN        = $false
            HasClashAPI   = $false
            HasRouteRules = $false
            NodeCount     = 0
            InboundTypes  = @()
        }
    }
    try {
        $json = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

        $inbounds = @($json.inbounds)
        $outbounds = @($json.outbounds)

        $tunInbound = $inbounds | Where-Object { $_.type -eq 'tun' }
        $hasClash = $null -ne $json.experimental -and $null -ne $json.experimental.clash_api
        $hasRoute = $null -ne $json.route -and $null -ne $json.route.rules

        $nodes = $outbounds | Where-Object {
            $_.type -notin @('selector', 'urltest', 'direct', 'dns', 'block')
        }

        $clashPort = if ($hasClash) { $json.experimental.clash_api.external_controller -replace '127\.0\.0\.1:', '' } else { $null }

        return @{
            Valid         = $true
            HasTUN        = ($null -ne $tunInbound)
            HasClashAPI   = $hasClash
            ClashPort     = $clashPort
            HasRouteRules = $hasRoute
            NodeCount     = $nodes.Count
            InboundTypes  = @($inbounds | ForEach-Object { $_.type })
            MixedPort     = if ($inbounds | Where-Object type -eq 'mixed') { ($inbounds | Where-Object type -eq 'mixed').listen_port } else { $null }
            ExternalUI    = if ($hasClash) { $json.experimental.clash_api.external_ui } else { $null }
        }
    } catch {
        return @{ Valid = $false; Error = $_.Exception.Message }
    }
}

# ---- 本地覆盖层 ----
# 订阅是机场原样生成的，会冲掉本地定制（日志输出、TUN 网卡名等）。
# config.local.json 里的设置在每次更新后重新合并回去，这样定制不会丢。
# 合并规则：对象递归合并；数组按 tag 配对合并（sing-box 的 inbounds/outbounds 都有 tag），
# overlay 里 tag 对不上的元素追加到末尾；其余类型直接覆盖。
function Merge-ConfigObject {
    param($Base, $Overlay)

    if ($Overlay -is [System.Management.Automation.PSCustomObject] -and
        $Base    -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $Overlay.PSObject.Properties) {
            $name = $prop.Name
            if ($Base.PSObject.Properties.Name -contains $name) {
                $Base.$name = Merge-ConfigObject $Base.$name $prop.Value
            } else {
                $Base | Add-Member -NotePropertyName $name -NotePropertyValue $prop.Value -Force
            }
        }
        return $Base
    }

    if ($Overlay -is [Array] -and $Base -is [Array]) {
        $result = [System.Collections.ArrayList]@($Base)
        foreach ($item in $Overlay) {
            $tag = $null
            if ($item -is [System.Management.Automation.PSCustomObject] -and
                $item.PSObject.Properties.Name -contains 'tag') { $tag = $item.tag }
            $idx = -1
            if ($tag) {
                for ($i = 0; $i -lt $result.Count; $i++) {
                    $b = $result[$i]
                    if ($b -is [System.Management.Automation.PSCustomObject] -and
                        $b.PSObject.Properties.Name -contains 'tag' -and $b.tag -eq $tag) { $idx = $i; break }
                }
            }
            if ($idx -ge 0) { $result[$idx] = Merge-ConfigObject $result[$idx] $item }
            else { $null = $result.Add($item) }
        }
        return @($result)
    }

    # 标量 / 类型不一致 —— overlay 说了算
    return $Overlay
}

$Script:ConfigLocal = Join-Path $ToolkitRoot "config.local.json"

# 按 "a.b.c" 取值 / 赋值 / 删除，供 $replace 使用
function Get-PathValue {
    param($Obj, [string]$Path)
    $cur = $Obj
    foreach ($seg in $Path -split '\.') {
        if ($null -eq $cur) { return $null }
        if ($cur.PSObject.Properties.Name -notcontains $seg) { return $null }
        $cur = $cur.$seg
    }
    return $cur
}
function Set-PathValue {
    param($Obj, [string]$Path, $Value)
    $segs = @($Path -split '\.')
    $cur = $Obj
    for ($i = 0; $i -lt $segs.Count - 1; $i++) {
        if ($cur.PSObject.Properties.Name -notcontains $segs[$i]) {
            $cur | Add-Member -NotePropertyName $segs[$i] -NotePropertyValue ([PSCustomObject]@{}) -Force
        }
        $cur = $cur.($segs[$i])   # 必须加括号：$cur.$segs[$i] 会被解析成 ($cur.$segs)[$i]
    }
    $cur | Add-Member -NotePropertyName $segs[-1] -NotePropertyValue $Value -Force
}
function Remove-PathValue {
    param($Obj, [string]$Path)
    $segs = @($Path -split '\.')
    $cur = $Obj
    for ($i = 0; $i -lt $segs.Count - 1; $i++) {
        if ($null -eq $cur -or $cur.PSObject.Properties.Name -notcontains $segs[$i]) { return }
        $cur = $cur.($segs[$i])   # 同上，括号不能省
    }
    if ($null -ne $cur) { $cur.PSObject.Properties.Remove($segs[-1]) }
}

# 把 config.local.json 合并进指定的配置文件（原地改写）。返回是否真的合并了。
#
# 覆盖层支持一个 "$replace" 指令，列出要"整块替换"而非递归合并的路径：
#     { "$replace": ["dns"], "dns": { ... } }
# 之所以需要它：合并只能新增/覆盖字段，删不掉字段。而 DNS 迁移到新格式
# 必须删掉旧的 address/strategy/fakeip —— 只能整块换。
function Merge-LocalOverrides {
    param([string]$Path)
    if (-not (Test-Path $ConfigLocal)) { return $false }
    $overlay = Get-Content $ConfigLocal -Raw -Encoding UTF8 | ConvertFrom-Json
    $base    = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json

    $replacePaths = @()
    if ($overlay.PSObject.Properties.Name -contains '$replace') {
        $replacePaths = @($overlay.'$replace')
        $overlay.PSObject.Properties.Remove('$replace')
    }
    foreach ($p in $replacePaths) {
        $val = Get-PathValue $overlay $p
        if ($null -ne $val) {
            Set-PathValue $base $p $val
            Remove-PathValue $overlay $p   # 已整块替换，别再进递归合并
        }
    }

    # "$insertAfter" —— 把覆盖层的数组元素插到基础数组的指定位置，而不是追加到末尾。
    # route.rules 是有序的（首个匹配生效），clash_mode 规则必须排在 DNS 劫持之后、
    # 正常分流之前；追加到末尾等于永远轮不到，插到最前面又会让 DNS 查询被当普通流量代理走。
    # 锚点是按内容找的（"插在最后一条 hijack-dns 之后"），不写死下标 ——
    # 机场增删规则后位置会变，下标会错位。
    if ($overlay.PSObject.Properties.Name -contains '$insertAfter') {
        $specs = $overlay.'$insertAfter'
        $overlay.PSObject.Properties.Remove('$insertAfter')
        foreach ($spec in $specs.PSObject.Properties) {
            # 注意别叫 $path —— PowerShell 变量名不区分大小写，会覆盖参数 $Path
            $arrPath = $spec.Name
            $anchor  = $spec.Value
            $items   = @(Get-PathValue $overlay $arrPath)
            if ($items.Count -eq 0) { continue }
            $arr = @(Get-PathValue $base $arrPath)

            $at = -1
            for ($i = 0; $i -lt $arr.Count; $i++) {
                $match = $true
                foreach ($ap in $anchor.PSObject.Properties) {
                    if ($arr[$i].PSObject.Properties.Name -notcontains $ap.Name -or
                        $arr[$i].($ap.Name) -ne $ap.Value) { $match = $false; break }
                }
                if ($match) { $at = $i }   # 取最后一个匹配
            }
            if ($at -lt 0) {
                # 锚点没找到就别硬插 —— 位置错了会静默改变分流行为。
                # 抛出去让 update.ps1 回滚，好过装上一份坏配置。
                throw "`$insertAfter: 在 $arrPath 里找不到锚点 $($anchor | ConvertTo-Json -Compress)"
            }

            $new = [System.Collections.ArrayList]@()
            for ($i = 0; $i -le $at; $i++) { $null = $new.Add($arr[$i]) }
            foreach ($it in $items)        { $null = $new.Add($it) }
            for ($i = $at + 1; $i -lt $arr.Count; $i++) { $null = $new.Add($arr[$i]) }

            Set-PathValue $base $arrPath @($new)
            Remove-PathValue $overlay $arrPath
        }
    }

    $merged = Merge-ConfigObject $base $overlay
    $json   = $merged | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

# ---- Clash API 入口 ----
# 统一解析 external_controller / secret，避免各脚本自己拼地址。
# 返回 $null 表示配置里没开 clash_api。
function Get-ClashApi {
    $caps = Get-ConfigCapabilities
    if (-not $caps.HasClashAPI) { return $null }
    try {
        $json = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $ctl = $json.experimental.clash_api.external_controller
        # external_controller 可能写成 ":9090" 或 "0.0.0.0:9090"，都从本机访问
        $port = ($ctl -split ':')[-1]
        $headers = @{}
        $secret = $json.experimental.clash_api.secret
        if ($secret) { $headers['Authorization'] = "Bearer $secret" }
        return @{
            BaseUrl = "http://127.0.0.1:$port"
            Headers = $headers
        }
    } catch { return $null }
}

# ---- 看门狗状态 ----
function Test-WatchdogInstalled {
    $tasks = @("Sing-Box-Watchdog", "Sing-Box-DailyRestart", "Sing-Box-MemoryGuard")
    $installed = 0
    foreach ($t in $tasks) {
        try {
            schtasks /query /tn $t 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $installed++ }
        } catch { }
    }
    return @{
        Installed = ($installed -gt 0)
        AllThree  = ($installed -eq 3)
        Count     = $installed
    }
}

# ---- 开机自启状态 ----
function Test-AutostartInstalled {
    try {
        schtasks /query /tn "Sing-Box" 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

# ---- 状态快照（供菜单使用） ----
function Get-ToolkitSnapshot {
    $caps = Get-ConfigCapabilities
    $status = Get-SingBoxStatus
    $net = if ($status.Running) { Test-NetworkConnectivity } else { $null }
    $wd = Test-WatchdogInstalled
    $as = Test-AutostartInstalled

    return [PSCustomObject]@{
        Timestamp       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        IsAdmin         = Test-IsAdmin
        SingBoxExists   = Test-SingBoxExists
        SingBoxVersion  = Get-SingBoxVersion
        ConfigExists    = Test-ConfigExists
        ConfigValid     = $caps.Valid
        IsRunning       = $status.Running
        PID             = $status.PID
        MemoryMB        = $status.MemoryMB
        Uptime          = $status.Uptime
        ListeningPorts  = if ($status.Running) { Get-ListeningPorts } else { @() }
        TunExists       = Test-TunExists
        Network         = $net
        Capabilities    = $caps
        Watchdog        = $wd
        Autostart       = $as
        ToolkitRoot     = $ToolkitRoot
    }
}

# ---- 输出全局变量供调用方使用 ----
$Global:ToolkitRoot   = $ToolkitRoot
$Global:SingBoxExe    = $SingBoxExe
$Global:ConfigPath    = $ConfigPath
$Global:ConfigBackup  = $ConfigBackup
$Global:LogDir        = $LogDir
$Global:UIDir         = $UIDir
$Global:BackupDir     = $BackupDir
$Global:StateFile     = $StateFile
$Global:WatchdogLog   = $WatchdogLog
$Global:ProxyPort     = Get-ProxyPort

Write-Verbose "env.ps1 loaded - ToolkitRoot: $ToolkitRoot"
