<#
.SYNOPSIS
  Emergency recovery: return adapter DNS to DHCP/router, bypassing Acrylic.
  Does NOT remove the Acrylic service - DNS simply goes around it.

.DESCRIPTION
  Uses acrylic-backup.json (written by install.ps1) when present, otherwise resets
  every adapter whose DNS contains 127.0.0.1. Self-elevates. Run if the exit/DNS
  server dies and you need normal internet back immediately.

.EXAMPLE
  .\restore-dns.ps1
.EXAMPLE
  irm https://raw.githubusercontent.com/fdoo24/acrylic-dns-unlock/main/restore-dns.ps1 | iex
#>
param(
  [string]$InstallDir = "$env:LOCALAPPDATA\AcrylicDNS",
  [string]$RepoBase = 'https://raw.githubusercontent.com/fdoo24/acrylic-dns-unlock/main'
)
$ErrorActionPreference = 'Continue'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
  $tmp = Join-Path $env:TEMP 'acrylic-dns-unlock-restore.ps1'
  if ($PSCommandPath) { Copy-Item $PSCommandPath $tmp -Force }
  else { Invoke-WebRequest -UseBasicParsing "$RepoBase/restore-dns.ps1" -OutFile $tmp }
  Start-Process powershell -Verb RunAs -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tmp,
    '-InstallDir', $InstallDir, '-RepoBase', $RepoBase)
  Write-Host 'Requesting elevation (UAC)...'
  return
}

Write-Host '=== RESTORE DNS (bypass Acrylic) ===' -ForegroundColor Cyan
$backupPath = Join-Path $InstallDir 'acrylic-backup.json'
$done = $false
if (Test-Path $backupPath) {
  try {
    $b = Get-Content $backupPath -Raw | ConvertFrom-Json
    Write-Host "Resetting ifIndex $($b.ifIndex) ($($b.ifAlias)) to DHCP"
    Set-DnsClientServerAddress -InterfaceIndex $b.ifIndex -ResetServerAddresses
    $done = $true
  } catch { Write-Host "Backup unreadable, falling back to scan: $_" }
}
if (-not $done) {
  Get-DnsClientServerAddress -AddressFamily IPv4 |
    Where-Object { $_.ServerAddresses -contains '127.0.0.1' } |
    ForEach-Object {
      Write-Host "Resetting ifIndex $($_.InterfaceIndex) ($($_.InterfaceAlias))"
      Set-DnsClientServerAddress -InterfaceIndex $_.InterfaceIndex -ResetServerAddresses
    }
}
ipconfig /flushdns | Out-Null
Write-Host 'DNS restored to DHCP/router. Acrylic service left installed.' -ForegroundColor Green
Get-DnsClientServerAddress -AddressFamily IPv4 |
  Where-Object { $_.ServerAddresses } |
  Format-Table InterfaceIndex, InterfaceAlias, ServerAddresses -AutoSize