<#
.SYNOPSIS
  Uninstall Acrylic DNS-redirect: restore DNS, stop+remove the service, delete files.

.PARAMETER KeepFiles
  Restore DNS and remove the service but leave InstallDir on disk.

.EXAMPLE
  .\uninstall.ps1
.EXAMPLE
  irm https://raw.githubusercontent.com/fdoo24/acrylic-dns-unlock/main/uninstall.ps1 | iex
#>
param(
  [string]$InstallDir = "$env:LOCALAPPDATA\AcrylicDNS",
  [string]$RepoBase = 'https://raw.githubusercontent.com/fdoo24/acrylic-dns-unlock/main',
  [switch]$KeepFiles
)
$ErrorActionPreference = 'Continue'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
  $tmp = Join-Path $env:TEMP 'acrylic-dns-unlock-uninstall.ps1'
  if ($PSCommandPath) { Copy-Item $PSCommandPath $tmp -Force }
  else { Invoke-WebRequest -UseBasicParsing "$RepoBase/uninstall.ps1" -OutFile $tmp }
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tmp,
         '-InstallDir', $InstallDir, '-RepoBase', $RepoBase)
  if ($KeepFiles) { $a += '-KeepFiles' }
  Start-Process powershell -Verb RunAs -ArgumentList $a
  Write-Host 'Requesting elevation (UAC)...'
  return
}

Write-Host '=== Uninstall Acrylic DNS-redirect ===' -ForegroundColor Cyan

# 1. restore DNS first (so internet works even if removal fails)
$backupPath = Join-Path $InstallDir 'acrylic-backup.json'
if (Test-Path $backupPath) {
  try {
    $b = Get-Content $backupPath -Raw | ConvertFrom-Json
    Set-DnsClientServerAddress -InterfaceIndex $b.ifIndex -ResetServerAddresses
    Write-Host "DNS restored on ifIndex $($b.ifIndex)"
  } catch { Write-Host "Backup unreadable: $_" }
}
Get-DnsClientServerAddress -AddressFamily IPv4 |
  Where-Object { $_.ServerAddresses -contains '127.0.0.1' } |
  ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.InterfaceIndex -ResetServerAddresses }
ipconfig /flushdns | Out-Null

# 2. stop + uninstall service
$ui = Join-Path $InstallDir 'AcrylicUI.exe'
if (Test-Path $ui) {
  Push-Location $InstallDir
  & $ui StopAcrylicService | Out-Null
  & $ui UninstallAcrylicService | Out-Null
  Pop-Location
} else {
  Stop-Service AcrylicDNSProxySvc -Force -ErrorAction SilentlyContinue
  sc.exe delete AcrylicDNSProxySvc | Out-Null
}
Start-Sleep -Seconds 1
Write-Host 'Service removed.'

# 3. delete files
if (-not $KeepFiles -and (Test-Path $InstallDir)) {
  Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "Deleted $InstallDir"
}
Write-Host 'Uninstall complete. DNS is back to DHCP/router.' -ForegroundColor Green