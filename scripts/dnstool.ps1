# SingPilot - DNS Tools
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\env.ps1"

Clear-Host
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  DNS Tools" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Show current DNS config from config.json
if (Test-ConfigExists) {
    try {
        $json = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($json.dns) {
            Write-Host "--- Current DNS Configuration ---" -ForegroundColor Cyan
            $servers = @($json.dns.servers)
            Write-Host "  Servers:" -ForegroundColor White
            $servers | ForEach-Object {
                $tag = if ($_.tag) { $_.tag } else { "(no tag)" }
                $addr = $_.address -replace '\\/', '/'
                Write-Host "    $tag -> $addr" -ForegroundColor DarkGray
            }
            if ($json.dns.fakeip -and $json.dns.fakeip.enabled) {
                Write-Host "  FakeIP : ON ($($json.dns.fakeip.inet4_range))" -ForegroundColor DarkGray
            }
            if ($json.dns.final) {
                Write-Host "  Final  : $($json.dns.final)" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "(no DNS section in config)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "(unable to parse config)" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "--- DNS Speed Test ---" -ForegroundColor Cyan
Write-Host ""

$dnsList = @(
    @{Name="Ali DNS"       ; IP="223.5.5.5"       },
    @{Name="Tencent DNS"   ; IP="119.29.29.29"    },
    @{Name="Google DNS"    ; IP="8.8.8.8"          }
)

$results = @()
foreach ($dns in $dnsList) {
    Write-Host "  Testing $($dns.Name) ($($dns.IP))..." -NoNewline
    $min = 9999; $max = 0; $total = 0; $ok = 0
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $ping = Test-Connection -ComputerName $dns.IP -Count 1 -TimeoutSeconds 2 -ErrorAction SilentlyContinue
            if ($ping) {
                $ms = $ping.ResponseTime
                if ($ms -lt $min) { $min = $ms }
                if ($ms -gt $max) { $max = $ms }
                $total += $ms
                $ok++
            }
        } catch { }
    }
    if ($ok -gt 0) {
        $avg = [math]::Round($total / $ok, 1)
        Write-Host " ${avg}ms" -ForegroundColor $(if ($avg -lt 30){"Green"}elseif($avg -lt 80){"Yellow"}else{"Red"})
        $results += [PSCustomObject]@{Name=$dns.Name; IP=$dns.IP; Avg=$avg; Min=$min; Max=$max; Lost=(3-$ok)}
    } else {
        Write-Host " TIMEOUT" -ForegroundColor Red
        $results += [PSCustomObject]@{Name=$dns.Name; IP=$dns.IP; Avg="FAIL"; Min="-"; Max="-"; Lost=3}
    }
}

Write-Host ""
Write-Host "--- Results ---" -ForegroundColor Cyan
$results | Format-Table Name, IP, @{N='Avg(ms)';E={$_.Avg}}, @{N='Min';E={$_.Min}}, @{N='Max';E={$_.Max}}, @{N='Lost';E={$_.Lost}} -AutoSize

Write-Host ""
Read-Host "Press Enter to return"
