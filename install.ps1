<#
.SYNOPSIS
  Acrylic DNS-redirect installer for Windows. Routes AI domains (Gemini, ChatGPT,
  Claude, ...) through a remote SNI exit IP via local DNS rewrite. No VPN/proxy needed.

.DESCRIPTION
  Installs Acrylic DNS Proxy as a local service, generates wildcard hosts from
  domains.txt, points the active network adapter's DNS at 127.0.0.1, and verifies.
  Self-elevates (UAC). Can be run from a local clone or via:
    irm https://raw.githubusercontent.com/fdoo24/acrylic-dns-unlock/main/install.ps1 | iex

.PARAMETER ExitIP
  Remote exit IP that AI domains are rewritten to. Default 179.254.143.17.
  Overrides the per-line IP in domains.txt when set explicitly.

.PARAMETER UpstreamDNS
  Upstream DNS for all non-rewritten queries (router / ISP). Auto-detected if empty.

.PARAMETER InstallDir
  Where Acrylic is installed. Default %LOCALAPPDATA%\AcrylicDNS.

.PARAMETER RepoBase
  Raw GitHub base used to download assets when not running from a local clone.

.EXAMPLE
  .\install.ps1
.EXAMPLE
  .\install.ps1 -ExitIP 1.2.3.4 -UpstreamDNS 192.168.1.1
#>
param(
  [string]$ExitIP = '179.254.143.17',
  [string]$UpstreamDNS = '',
  [string]$InstallDir = "$env:LOCALAPPDATA\AcrylicDNS",
  [string]$RepoBase = 'https://raw.githubusercontent.com/fdoo24/acrylic-dns-unlock/main',
  [string]$TestDomain = 'gemini.google.com'
)
$ErrorActionPreference = 'Stop'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- self-elevate -----------------------------------------------------------
if (-not (Test-Admin)) {
  $tmp = Join-Path $env:TEMP 'acrylic-dns-unlock-install.ps1'
  if ($PSCommandPath) { Copy-Item $PSCommandPath $tmp -Force }
  else { Invoke-WebRequest -UseBasicParsing "$RepoBase/install.ps1" -OutFile $tmp }
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tmp,
         '-ExitIP', $ExitIP, '-InstallDir', $InstallDir, '-RepoBase', $RepoBase,
         '-TestDomain', $TestDomain)
  if ($UpstreamDNS) { $a += @('-UpstreamDNS', $UpstreamDNS) }
  Write-Host 'Requesting elevation (UAC)... continuation in the new window.'
  Start-Process powershell -Verb RunAs -ArgumentList $a
  return
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

Write-Host '=== Acrylic DNS-redirect install ===' -ForegroundColor Cyan

# --- acquire assets (local clone or download) -------------------------------
$zipLocal = Join-Path $PSScriptRoot 'vendor\Acrylic-Portable.zip'
$domLocal = Join-Path $PSScriptRoot 'domains.txt'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$zipPath = Join-Path $InstallDir 'Acrylic-Portable.zip'
$domPath = Join-Path $InstallDir 'domains.txt'
if (Test-Path $zipLocal) { Copy-Item $zipLocal $zipPath -Force }
else {
  Write-Host "Downloading Acrylic from $RepoBase ..."
  Invoke-WebRequest -UseBasicParsing "$RepoBase/vendor/Acrylic-Portable.zip" -OutFile $zipPath
}
if (Test-Path $domLocal) { Copy-Item $domLocal $domPath -Force }
else { Invoke-WebRequest -UseBasicParsing "$RepoBase/domains.txt" -OutFile $domPath }

# --- stop existing service so files can be overwritten ----------------------
$svc = Get-Service -Name 'AcrylicDNSProxySvc' -ErrorAction SilentlyContinue
if ($svc) {
  Write-Host 'Existing Acrylic service found, stopping...'
  Stop-Service AcrylicDNSProxySvc -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
}

# --- extract ----------------------------------------------------------------
Expand-Archive -Path $zipPath -DestinationPath $InstallDir -Force
$iniPath = Join-Path $InstallDir 'AcrylicConfiguration.ini'
$hostsPath = Join-Path $InstallDir 'AcrylicHosts.txt'
$ui = Join-Path $InstallDir 'AcrylicUI.exe'
if (-not (Test-Path $ui)) { throw "AcrylicUI.exe not found in $InstallDir" }

# --- detect active adapter + upstream DNS -----------------------------------
$netcfg = Get-NetIPConfiguration |
  Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
  Select-Object -First 1
if (-not $netcfg) { throw 'No active network adapter with a default gateway found.' }
$ifIndex = $netcfg.InterfaceIndex
$ifAlias = $netcfg.NetAdapter.Name
$curDNS = @(Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4).ServerAddresses
$up = $UpstreamDNS
if (-not $up) { $up = $curDNS | Where-Object { $_ -notmatch '^127\.' } | Select-Object -First 1 }
if (-not $up) { $up = $netcfg.IPv4DefaultGateway.NextHop }
if (-not $up) { throw 'Could not determine upstream DNS. Pass -UpstreamDNS <router-ip>.' }
Write-Host "Adapter: $ifAlias (ifIndex $ifIndex)"
Write-Host "Current DNS: $($curDNS -join ', ')"
Write-Host "Upstream DNS: $up"

# --- backup current DNS (for restore-dns.ps1) -------------------------------
$backup = [ordered]@{
  ifIndex   = $ifIndex
  ifAlias   = $ifAlias
  dns       = $curDNS
  upstream  = $up
  exitIP    = $ExitIP
  date      = (Get-Date).ToString('s')
}
Write-Utf8NoBom (Join-Path $InstallDir 'acrylic-backup.json') ($backup | ConvertTo-Json)

# --- patch AcrylicConfiguration.ini -----------------------------------------
$ini = Get-Content $iniPath -Raw
$ini = $ini -replace '(?m)^PrimaryServerAddress=.*$',   "PrimaryServerAddress=$up"
$ini = $ini -replace '(?m)^PrimaryServerPort=.*$',      'PrimaryServerPort=53'
$ini = $ini -replace '(?m)^PrimaryServerProtocol=.*$',  'PrimaryServerProtocol=UDP'
$ini = $ini -replace '(?m)^SecondaryServerAddress=.*$', "SecondaryServerAddress=$up"
$ini = $ini -replace '(?m)^SecondaryServerPort=.*$',    'SecondaryServerPort=53'
$ini = $ini -replace '(?m)^SecondaryServerProtocol=.*$','SecondaryServerProtocol=UDP'
$ini = $ini -replace '(?m)^LocalIPv4BindingAddress=.*$','LocalIPv4BindingAddress=127.0.0.1'
$ini = $ini -replace '(?m)^LocalIPv6BindingAddress=.*$','LocalIPv6BindingAddress=::1'
Write-Utf8NoBom $iniPath $ini

# --- generate AcrylicHosts.txt from domains.txt -----------------------------
$rules = foreach ($line in Get-Content $domPath) {
  if ($line -match '^\|\|(.+?)\^\$dnsrewrite=([0-9.]+)\s*$') {
    $ip = if ($PSBoundParameters.ContainsKey('ExitIP')) { $ExitIP } else { $Matches[2] }
    "$ip >$($Matches[1])"
  }
}
if (-not $rules) { throw "No dnsrewrite rules parsed from $domPath" }
$header = @(
  '# AcrylicHosts.txt - AI domains via remote exit (generated by install.ps1).',
  '# Format: IP >domain  (= domain + *.domain, like ||domain^ in AdGuard).',
  '# Everything else (LAN, local sites) is forwarded to the upstream DNS.',
  '# After edits restart the Acrylic service.',
  '127.0.0.1 localhost localhost.localdomain',
  '::1 localhost localhost.localdomain',
  ''
)
Write-Utf8NoBom $hostsPath (($header + $rules) -join "`r`n")
Write-Host "Hosts rules written: $($rules.Count)"

# --- install + start service ------------------------------------------------
Push-Location $InstallDir
& $ui InstallAcrylicService | Out-Null
& $ui StartAcrylicService | Out-Null
Pop-Location
Start-Sleep -Seconds 2
$svc = Get-Service -Name 'AcrylicDNSProxySvc' -ErrorAction SilentlyContinue
if (-not $svc -or $svc.Status -ne 'Running') {
  throw "Acrylic service not running (status: $($svc.Status)). Check $InstallDir."
}
Set-Service -Name 'AcrylicDNSProxySvc' -StartupType Automatic
Write-Host 'Service AcrylicDNSProxySvc: Running (Automatic)' -ForegroundColor Green

# --- point adapter DNS at Acrylic on ALL physical adapters (Ethernet + Wi-Fi) ---
# This prevents the "switched to Wi-Fi / hotspot" problem where only one adapter was set.
$allAdapters = Get-NetIPConfiguration |
  Where-Object { $_.NetAdapter.Status -eq 'Up' -and
                 $_.NetAdapter.InterfaceDescription -notmatch 'Loopback|Virtual|Hyper-V|VPN|TAP|Tunnel' }
foreach ($a in $allAdapters) {
  Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ServerAddresses ('127.0.0.1', '::1') -ErrorAction SilentlyContinue
  Write-Host "Adapter DNS set to 127.0.0.1 / ::1  [$($a.NetAdapter.Name)]"
}
ipconfig /flushdns | Out-Null

# --- verify (both via Acrylic and system-wide) ------------------------------
Start-Sleep -Seconds 1
$okAcrylic = $false
$okSystem  = $false
try {
  $r = Resolve-DnsName -Name $TestDomain -Server 127.0.0.1 -Type A -ErrorAction Stop |
       Where-Object { $_.IPAddress } | Select-Object -First 1
  if ($r -and $r.IPAddress -eq $ExitIP) { $okAcrylic = $true }
  Write-Host "Verify via Acrylic : $TestDomain -> $($r.IPAddress) (expected $ExitIP)"
} catch { Write-Host "Verify (Acrylic) failed: $_" -ForegroundColor Yellow }

try {
  $s = Resolve-DnsName -Name $TestDomain -Type A -ErrorAction Stop |
       Where-Object { $_.IPAddress } | Select-Object -First 1
  if ($s -and $s.IPAddress -eq $ExitIP) { $okSystem = $true }
  Write-Host "Verify via System  : $TestDomain -> $($s.IPAddress) (expected $ExitIP)"
} catch { Write-Host "Verify (System) failed: $_" -ForegroundColor Yellow }

Write-Host ''
if ($okAcrylic -and $okSystem) {
  Write-Host 'SUCCESS: DNS-redirect is fully active.' -ForegroundColor Green
} elseif ($okAcrylic -and -not $okSystem) {
  Write-Host 'PARTIAL: Acrylic works, but system DNS bypasses it on some adapter.' -ForegroundColor Yellow
  Write-Host '         Run diagnose.ps1 -Fix to repair.' -ForegroundColor Yellow
} else {
  Write-Host 'Installed, but verification did not match. Check exit IP / upstream.' -ForegroundColor Yellow
}
Write-Host "Install dir : $InstallDir"
Write-Host "Diagnose    : run diagnose.ps1 (or diagnose.ps1 -Fix) if anything stops working."
Write-Host "Recovery    : run restore-dns.ps1 (returns DNS to DHCP/router) if anything breaks."
Write-Host "Change exit : run update-ip.ps1 -NewIP <ip>"