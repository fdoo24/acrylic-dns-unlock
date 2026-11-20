<#
.SYNOPSIS
  Diagnose and optionally fix Acrylic DNS-redirect health.

.DESCRIPTION
  Checks the full chain: service → adapter DNS → Acrylic upstream → AI redirect →
  normal DNS → system resolve → exit IP reachability.
  With -Fix, automatically repairs any detected issues under the current active adapter.

.PARAMETER Fix
  Apply fixes for any detected problems (requires elevation).

.PARAMETER InstallDir
  Acrylic install directory. Default %LOCALAPPDATA%\AcrylicDNS.

.PARAMETER ExitIP
  Expected exit IP for AI domains. Read from AcrylicHosts.txt if not supplied.

.PARAMETER TestDomain
  Domain used to verify AI redirect. Default gemini.google.com.

.EXAMPLE
  .\diagnose.ps1
.EXAMPLE
  .\diagnose.ps1 -Fix
#>
param(
  [switch]$Fix,
  [string]$InstallDir = "$env:LOCALAPPDATA\AcrylicDNS",
  [string]$ExitIP     = '',
  [string]$TestDomain = 'gemini.google.com',
  [string]$RepoBase   = 'https://raw.githubusercontent.com/fdoo24/acrylic-dns-unlock/main'
)
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

function Show-Result([string]$label, [bool]$ok, [string]$value, [string]$hint = '') {
  $icon   = if ($ok) { '[OK]' } else { '[!!]' }
  $color  = if ($ok) { 'Green' } else { 'Red' }
  $line   = "  $icon  $($label.PadRight(32)) $value"
  Write-Host $line -ForegroundColor $color
  if (-not $ok -and $hint) { Write-Host "        >> $hint" -ForegroundColor Yellow }
}

# ---------------------------------------------------------------------------
# self-elevate when -Fix is requested and not already admin
# ---------------------------------------------------------------------------
if ($Fix -and -not (Test-Admin)) {
  $tmp = Join-Path $env:TEMP 'acrylic-dns-unlock-diagnose.ps1'
  if ($PSCommandPath) { Copy-Item $PSCommandPath $tmp -Force }
  else { Invoke-WebRequest -UseBasicParsing "$RepoBase/diagnose.ps1" -OutFile $tmp }
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tmp,
         '-Fix', '-InstallDir', $InstallDir, '-TestDomain', $TestDomain)
  if ($ExitIP) { $a += @('-ExitIP', $ExitIP) }
  Write-Host 'Requesting elevation (UAC) for -Fix mode...'
  Start-Process powershell -Verb RunAs -ArgumentList $a
  return
}

Write-Host ''
Write-Host '=== Acrylic DNS — Self-Diagnosis ===' -ForegroundColor Cyan
Write-Host "    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   InstallDir: $InstallDir"
Write-Host ''

$issues   = 0
$iniPath  = Join-Path $InstallDir 'AcrylicConfiguration.ini'
$hostsPath= Join-Path $InstallDir 'AcrylicHosts.txt'

# ---------------------------------------------------------------------------
# 0. resolve ExitIP from AcrylicHosts.txt if not supplied
# ---------------------------------------------------------------------------
if (-not $ExitIP -and (Test-Path $hostsPath)) {
  $firstRule = Get-Content $hostsPath |
    Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}\s+>' } |
    Select-Object -First 1
  if ($firstRule -match '^(\d{1,3}(\.\d{1,3}){3})') { $ExitIP = $Matches[1] }
}
if (-not $ExitIP) { $ExitIP = '179.254.143.17' }   # project default

# ---------------------------------------------------------------------------
# 1. Service
# ---------------------------------------------------------------------------
Write-Host '--- [1] Acrylic Service ---' -ForegroundColor DarkCyan
$svc = Get-Service -Name 'AcrylicDNSProxySvc' -ErrorAction SilentlyContinue
$svcOk = ($svc -ne $null -and $svc.Status -eq 'Running')
$autoOk= ($svc -ne $null -and $svc.StartType -eq 'Automatic')
$svcStatus = if ($svc) { "$($svc.Status)" } else { 'NOT FOUND' }
$svcStartType = if ($svc) { "$($svc.StartType)" } else { '-' }
Show-Result 'Service status' $svcOk $svcStatus `
  'Run: Start-Service AcrylicDNSProxySvc  (or use -Fix)'
Show-Result 'Service startup type' $autoOk $svcStartType `
  'Run: Set-Service AcrylicDNSProxySvc -StartupType Automatic  (or use -Fix)'
if (-not $svcOk) { $issues++ }
if (-not $autoOk) { $issues++ }

# ---------------------------------------------------------------------------
# 2. Active adapter + its DNS
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- [2] Active Network Adapter ---' -ForegroundColor DarkCyan
$netcfg = Get-NetIPConfiguration |
  Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
  Select-Object -First 1

$adapterOk = $false
$ifAlias   = '(none)'
$ifIndex   = $null
$gateway   = '(none)'
$adapterDNS= @()

if ($netcfg) {
  $ifAlias    = $netcfg.NetAdapter.Name
  $ifIndex    = $netcfg.InterfaceIndex
  $gateway    = $netcfg.IPv4DefaultGateway.NextHop
  $adapterDNS = @(Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4).ServerAddresses
  $adapterOk  = $adapterDNS -contains '127.0.0.1'
}
Show-Result 'Active adapter' ($netcfg -ne $null) $ifAlias 'No adapter with a default gateway found!'
Show-Result 'Gateway' ($gateway -ne '(none)') $gateway ''
Show-Result 'Adapter DNS = 127.0.0.1' $adapterOk ($adapterDNS -join ', ') `
  "DNS bypasses Acrylic. Use -Fix to set 127.0.0.1 on adapter '$ifAlias'"
if (-not $adapterOk) { $issues++ }

# ---------------------------------------------------------------------------
# 3. Upstream DNS in AcrylicConfiguration.ini
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- [3] Acrylic Upstream DNS ---' -ForegroundColor DarkCyan
$iniExists = Test-Path $iniPath
$primaryDNS = ''
$upstreamOk = $false
if ($iniExists) {
  $primaryLine = Get-Content $iniPath | Select-String '^PrimaryServerAddress='
  if ($primaryLine) { $primaryDNS = ($primaryLine -replace '^PrimaryServerAddress=', '').Trim() }
  # test reachability
  if ($primaryDNS) {
    $ping = Test-Connection -ComputerName $primaryDNS -Count 1 -Quiet -ErrorAction SilentlyContinue
    $upstreamOk = $ping
  }
}
Show-Result 'Config file exists' $iniExists $iniPath 'Run install.ps1 first!'
Show-Result "Upstream DNS ($primaryDNS) reachable" $upstreamOk $primaryDNS `
  "Upstream is unreachable - normal sites won't resolve. Use -Fix to switch to 77.88.8.8"
if (-not $upstreamOk) { $issues++ }

# ---------------------------------------------------------------------------
# 4. AI redirect via Acrylic (127.0.0.1)
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- [4] AI Domain Redirect (Acrylic) ---' -ForegroundColor DarkCyan
$aiViaAcrylic = ''
$aiRedirectOk = $false
try {
  $r = Resolve-DnsName -Name $TestDomain -Server 127.0.0.1 -Type A -ErrorAction Stop |
       Where-Object { $_.IPAddress } | Select-Object -First 1
  $aiViaAcrylic = $r.IPAddress
  $aiRedirectOk = ($aiViaAcrylic -eq $ExitIP)
} catch { $aiViaAcrylic = "ERROR: $_" }
Show-Result "Resolve $TestDomain via 127.0.0.1" $aiRedirectOk "$aiViaAcrylic (expected $ExitIP)" `
  'Hosts file missing or Acrylic not running. Run install.ps1 or update-ip.ps1'
if (-not $aiRedirectOk) { $issues++ }

# ---------------------------------------------------------------------------
# 5. Normal (upstream) DNS via Acrylic
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- [5] Normal Sites via Acrylic ---' -ForegroundColor DarkCyan
$yaIP  = ''
$yaOk  = $false
try {
  $y = Resolve-DnsName -Name 'ya.ru' -Server 127.0.0.1 -Type A -ErrorAction Stop |
       Where-Object { $_.IPAddress } | Select-Object -First 1
  $yaIP = $y.IPAddress
  $yaOk = ($yaIP -and $yaIP -ne $ExitIP)
} catch { $yaIP = "ERROR: $_" }
Show-Result 'Resolve ya.ru via 127.0.0.1' $yaOk $yaIP `
  'Upstream DNS unreachable - normal internet broken. Use -Fix to switch upstream.'
if (-not $yaOk) { $issues++ }

# ---------------------------------------------------------------------------
# 6. System DNS (as browsers see it)
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- [6] System Resolve (as browsers see it) ---' -ForegroundColor DarkCyan
$sysIP  = ''
$sysOk  = $false
try {
  $s = Resolve-DnsName -Name $TestDomain -Type A -ErrorAction Stop |
       Where-Object { $_.IPAddress } | Select-Object -First 1
  $sysIP = $s.IPAddress
  $sysOk = ($sysIP -eq $ExitIP)
} catch { $sysIP = "ERROR: $_" }
Show-Result "System resolve $TestDomain" $sysOk "$sysIP (expected $ExitIP)" `
  "Windows ignores Acrylic for this adapter. Use -Fix to set DNS to 127.0.0.1"
if (-not $sysOk) { $issues++ }

# ---------------------------------------------------------------------------
# 7. Exit IP reachability on port 443
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- [7] Exit IP Reachability ---' -ForegroundColor DarkCyan
$exitReach = $false
try {
  $tc = Test-NetConnection -ComputerName $ExitIP -Port 443 -InformationLevel Quiet -ErrorAction Stop -WarningAction SilentlyContinue
  $exitReach = $tc
} catch {}
$exitText = if ($exitReach) { 'Yes' } else { 'No / timeout' }
Show-Result "Exit IP $ExitIP :443 reachable" $exitReach $exitText `
  'The remote SNI proxy may be down or blocked by your ISP. Try a different exit IP via update-ip.ps1'
if (-not $exitReach) { $issues++ }

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '======================================' -ForegroundColor Cyan
if ($issues -eq 0) {
  Write-Host "  ALL CHECKS PASSED - Everything works correctly!" -ForegroundColor Green
} else {
  Write-Host "  $issues problem(s) detected." -ForegroundColor Red
  if (-not $Fix) {
    Write-Host "  Run:  .\diagnose.ps1 -Fix   to auto-repair." -ForegroundColor Yellow
  }
}
Write-Host '======================================' -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------------------
# -Fix: apply repairs
# ---------------------------------------------------------------------------
if ($Fix) {
  Write-Host '--- Applying fixes ---' -ForegroundColor Magenta

  $fixed = 0

  # Fix 1: service not running
  if (-not $svcOk -and $svc) {
    Write-Host '  Starting AcrylicDNSProxySvc...'
    Start-Service AcrylicDNSProxySvc -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $svc2 = Get-Service AcrylicDNSProxySvc -ErrorAction SilentlyContinue
    if ($svc2.Status -eq 'Running') {
      Write-Host '  Service started.' -ForegroundColor Green; $fixed++
    } else {
      Write-Host '  Failed to start service. Try running install.ps1.' -ForegroundColor Red
    }
  }

  # Fix 2: startup type not Automatic
  if (-not $autoOk -and $svc) {
    Set-Service -Name 'AcrylicDNSProxySvc' -StartupType Automatic -ErrorAction SilentlyContinue
    Write-Host '  Startup type set to Automatic.' -ForegroundColor Green; $fixed++
  }

  # Fix 3: adapter DNS not 127.0.0.1
  if (-not $adapterOk -and $ifIndex) {
    Write-Host "  Setting DNS on '$ifAlias' to 127.0.0.1 / ::1..."
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses ('127.0.0.1', '::1') -ErrorAction SilentlyContinue
    Write-Host "  Adapter DNS updated." -ForegroundColor Green; $fixed++
  }

  # Fix 4: upstream DNS unreachable - switch to Yandex public DNS
  if (-not $upstreamOk -and $iniExists) {
    # First try gateway as upstream (more local, better for some ISPs)
    $newUpstream  = '77.88.8.8'
    $newUpstream2 = '8.8.8.8'
    # If gateway is reachable, use gateway for both to prevent secondary timeouts on mobile carriers
    if ($gateway -and $gateway -ne '(none)') {
      $gwOk = Test-Connection -ComputerName $gateway -Count 1 -Quiet -ErrorAction SilentlyContinue
      if (-not $gwOk) {
        $gwOk = [bool](Resolve-DnsName -Name 'ya.ru' -Server $gateway -QuickTimeout -ErrorAction SilentlyContinue)
      }
      if ($gwOk) { $newUpstream = $gateway; $newUpstream2 = $gateway }
    }
    Write-Host "  Upstream unreachable. Switching to $newUpstream / $newUpstream2..."
    $ini = Get-Content $iniPath -Raw
    $ini = $ini -replace '(?m)^PrimaryServerAddress=.*$',   "PrimaryServerAddress=$newUpstream"
    $ini = $ini -replace '(?m)^SecondaryServerAddress=.*$', "SecondaryServerAddress=$newUpstream2"
    Write-Utf8NoBom $iniPath $ini
    Write-Host "  Upstream DNS updated to $newUpstream / $newUpstream2." -ForegroundColor Green
    $fixed++
  }

  # Flush + restart service after any fix
  if ($fixed -gt 0) {
    Write-Host '  Restarting Acrylic service and flushing DNS cache...'
    Restart-Service AcrylicDNSProxySvc -ErrorAction SilentlyContinue
    ipconfig /flushdns | Out-Null
    Start-Sleep -Seconds 2
    Write-Host "  Done. $fixed fix(es) applied." -ForegroundColor Green
  } else {
    Write-Host '  Nothing to fix (or no admin rights for some steps).' -ForegroundColor Yellow
  }

  # Re-verify after fixes
  Write-Host ''
  Write-Host '--- Re-verify after fix ---' -ForegroundColor Magenta
  $r2 = Resolve-DnsName -Name $TestDomain -Server 127.0.0.1 -Type A -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress } | Select-Object -First 1
  $s2 = Resolve-DnsName -Name $TestDomain -Type A -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress } | Select-Object -First 1
  Show-Result "Acrylic: $TestDomain" ($r2.IPAddress -eq $ExitIP) "$($r2.IPAddress) (expected $ExitIP)" ''
  Show-Result "System:  $TestDomain" ($s2.IPAddress -eq $ExitIP) "$($s2.IPAddress) (expected $ExitIP)" ''
  if ($r2.IPAddress -eq $ExitIP -and $s2.IPAddress -eq $ExitIP) {
    Write-Host ''
    Write-Host '  SUCCESS: Redirect is fully active.' -ForegroundColor Green
  } else {
    Write-Host ''
    Write-Host '  Some issues remain. Check the output above or re-run install.ps1.' -ForegroundColor Yellow
  }
}
