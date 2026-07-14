# ============================================================
# Sing-Box Toolkit - 环境检测核心
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
