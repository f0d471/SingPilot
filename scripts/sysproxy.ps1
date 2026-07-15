# SingPilot - System Proxy Toggle
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\env.ps1"

$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$proxyAddr = "127.0.0.1:$(Get-ProxyPort)"

function Get-ProxyStatus {
    $enabled = (Get-ItemProperty -Path $regPath -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
    $server = (Get-ItemProperty -Path $regPath -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
    return @{ Enabled = ($enabled -eq 1); Server = $server }
}

Clear-Host
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  System Proxy" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$status = Get-ProxyStatus

if ($status.Enabled) {
    Write-Host "  Status : ON" -ForegroundColor Green
    Write-Host "  Server : $($status.Server)" -ForegroundColor White
    Write-Host ""
    Write-Host "  [1] Turn OFF"
    Write-Host "  [2] Change address"
    Write-Host "  [0] Back"
}
else {
    Write-Host "  Status : OFF (using TUN mode or direct)" -ForegroundColor Red
    Write-Host "  Proxy  : $proxyAddr (will be set)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [1] Turn ON (set system proxy to $proxyAddr)"
    Write-Host "  [2] Custom address then turn ON"
    Write-Host "  [0] Back"
    Write-Host ""
    Write-Host "  TIP: Use this when TUN mode conflicts with apps." -ForegroundColor DarkGray
    Write-Host "       Browser will use proxy; other apps use direct." -ForegroundColor DarkGray
}

Write-Host ""
$choice = Read-Host "  Select"

switch ($choice) {
    "1" {
        if ($status.Enabled) {
            Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0
            Write-Host "System proxy: OFF" -ForegroundColor Green
        } else {
            Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 1
            Set-ItemProperty -Path $regPath -Name ProxyServer -Value $proxyAddr
            Set-ItemProperty -Path $regPath -Name ProxyOverride -Value "localhost;127.*;10.*;172.16.*;192.168.*;<local>"
            Write-Host "System proxy: ON -> $proxyAddr" -ForegroundColor Green
        }
    }
    "2" {
        if ($status.Enabled) {
            $newAddr = Read-Host "New proxy address (ip:port)"
            if ($newAddr) {
                Set-ItemProperty -Path $regPath -Name ProxyServer -Value $newAddr
                Write-Host "Updated to $newAddr" -ForegroundColor Green
            }
        } else {
            $custom = Read-Host "Proxy address (default: $proxyAddr)"
            if (-not $custom) { $custom = $proxyAddr }
            Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 1
            Set-ItemProperty -Path $regPath -Name ProxyServer -Value $custom
            Set-ItemProperty -Path $regPath -Name ProxyOverride -Value "localhost;127.*;10.*;172.16.*;192.168.*;<local>"
            Write-Host "System proxy: ON -> $custom" -ForegroundColor Green
        }
    }
}

Write-Host ""
Write-Host "NOTE: Some apps need restart to pick up proxy changes." -ForegroundColor DarkGray
Write-Host ""
Read-Host "Press Enter to return"
