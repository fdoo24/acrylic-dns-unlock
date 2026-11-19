<#
.SYNOPSIS
  Interactive menu for Acrylic DNS-redirect management.
  One script to rule them all: install, diagnose, fix, update, restore, uninstall.

.DESCRIPTION
  Run without arguments - shows an interactive menu.
  No need to remember script names. Self-elevates for operations that need admin rights.

.EXAMPLE
  .\menu.ps1
#>
param(
  [string]$InstallDir = "$env:LOCALAPPDATA\AcrylicDNS",
  [string]$RepoBase   = 'https://raw.githubusercontent.com/fdoo24/acrylic-dns-unlock/main'
)
$ErrorActionPreference = 'Continue'
$ScriptDir = $PSScriptRoot

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ScriptPath([string]$name) {
  $local = Join-Path $ScriptDir "$name.ps1"
  if (Test-Path $local) { return $local }
  # download to temp if running remotely
  $tmp = Join-Path $env:TEMP "acrylic-dns-unlock-$name.ps1"
  Invoke-WebRequest -UseBasicParsing "$RepoBase/$name.ps1" -OutFile $tmp
  return $tmp
}

function Run-Script([string]$name, [string[]]$args_) {
  $path = Get-ScriptPath $name
  Write-Host ''
  if (Test-Admin) {
    & $path @args_
  } else {
    # run elevated
    $allArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path) + $args_
    Start-Process powershell -Verb RunAs -ArgumentList $allArgs -Wait
  }
}

function Get-QuickStatus {
  $svc = Get-Service AcrylicDNSProxySvc -ErrorAction SilentlyContinue
  $netcfg = Get-NetIPConfiguration |
    Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
    Select-Object -First 1
  $adapterDNS = if ($netcfg) {
    @(Get-DnsClientServerAddress -InterfaceIndex $netcfg.InterfaceIndex -AddressFamily IPv4).ServerAddresses -join ', '
  } else { 'no active adapter' }
  $dnsOk = $adapterDNS -like '*127.0.0.1*'

  Write-Host ''
  Write-Host '  Quick status:' -ForegroundColor DarkCyan -NoNewline
  if ($svc -and $svc.Status -eq 'Running' -and $dnsOk) {
    Write-Host ' OK - Service running, DNS correctly set' -ForegroundColor Green
  } elseif (-not $svc -or $svc.Status -ne 'Running') {
    Write-Host ' !! Service NOT running' -ForegroundColor Red
  } else {
    $adapter = if ($netcfg) { $netcfg.NetAdapter.Name } else { 'unknown' }
    Write-Host " !! Adapter '$adapter' DNS is $adapterDNS (not 127.0.0.1)" -ForegroundColor Red
  }
  Write-Host ''
}

# ---------------------------------------------------------------------------
# Main menu loop
# ---------------------------------------------------------------------------
while ($true) {
  Clear-Host
  Write-Host '╔════════════════════════════════════════════╗' -ForegroundColor Cyan
  Write-Host '║   Acrylic DNS-redirect — Control Menu      ║' -ForegroundColor Cyan
  Write-Host '╠════════════════════════════════════════════╣' -ForegroundColor Cyan
  Write-Host '║                                            ║' -ForegroundColor Cyan
  Write-Host '║  1. Diagnose — check what is broken        ║' -ForegroundColor Cyan
  Write-Host '║  2. Fix now  — diagnose + auto-repair      ║' -ForegroundColor Cyan
  Write-Host '║  3. Install / Reinstall                    ║' -ForegroundColor Cyan
  Write-Host '║  4. Update exit IP                         ║' -ForegroundColor Cyan
  Write-Host '║  5. Restore DNS (emergency - no Acrylic)   ║' -ForegroundColor Cyan
  Write-Host '║  6. Uninstall (remove everything)          ║' -ForegroundColor Cyan
  Write-Host '║  7. Exit                                   ║' -ForegroundColor Cyan
  Write-Host '║                                            ║' -ForegroundColor Cyan
  Write-Host '╚════════════════════════════════════════════╝' -ForegroundColor Cyan

  Get-QuickStatus

  $choice = Read-Host 'Choose option (1-7)'

  switch ($choice.Trim()) {

    '1' {
      Write-Host '' ; Write-Host 'Running diagnostics...' -ForegroundColor Yellow
      Run-Script 'diagnose' @('-InstallDir', $InstallDir)
      Write-Host '' ; Read-Host 'Press Enter to return to menu'
    }

    '2' {
      Write-Host '' ; Write-Host 'Running diagnose + auto-fix (requires admin)...' -ForegroundColor Yellow
      Run-Script 'diagnose' @('-Fix', '-InstallDir', $InstallDir)
      Write-Host '' ; Read-Host 'Press Enter to return to menu'
    }

    '3' {
      Write-Host '' ; Write-Host 'Starting installer (requires admin)...' -ForegroundColor Yellow
      $ip = Read-Host 'Exit IP to use? (press Enter for default 179.254.143.17)'
      $args_ = @('-InstallDir', $InstallDir)
      if ($ip.Trim()) { $args_ += @('-ExitIP', $ip.Trim()) }
      Run-Script 'install' $args_
      Write-Host '' ; Read-Host 'Press Enter to return to menu'
    }

    '4' {
      Write-Host '' ; Write-Host 'Update exit IP' -ForegroundColor Yellow
      $ip = Read-Host 'New exit IP (e.g. 1.2.3.4)'
      if (-not $ip.Trim()) {
        Write-Host 'No IP entered, cancelled.' -ForegroundColor DarkGray
      } else {
        Run-Script 'update-ip' @('-NewIP', $ip.Trim(), '-InstallDir', $InstallDir)
      }
      Write-Host '' ; Read-Host 'Press Enter to return to menu'
    }

    '5' {
      Write-Host '' -ForegroundColor Yellow
      Write-Host 'EMERGENCY: This will restore your original DNS and bypass Acrylic.' -ForegroundColor Red
      Write-Host 'Gemini / AI sites will stop working until you reinstall.' -ForegroundColor Red
      $confirm = Read-Host 'Type YES to confirm'
      if ($confirm -eq 'YES') {
        Run-Script 'restore-dns' @('-InstallDir', $InstallDir)
      } else {
        Write-Host 'Cancelled.' -ForegroundColor DarkGray
      }
      Write-Host '' ; Read-Host 'Press Enter to return to menu'
    }

    '6' {
      Write-Host '' -ForegroundColor Yellow
      Write-Host 'UNINSTALL: This will remove the Acrylic service and restore your DNS.' -ForegroundColor Red
      $confirm = Read-Host 'Type YES to confirm full uninstall'
      if ($confirm -eq 'YES') {
        Run-Script 'uninstall' @('-InstallDir', $InstallDir)
      } else {
        Write-Host 'Cancelled.' -ForegroundColor DarkGray
      }
      Write-Host '' ; Read-Host 'Press Enter to return to menu'
    }

    '7' { Write-Host 'Bye!' -ForegroundColor Cyan ; break }

    default { Write-Host 'Invalid choice, try again.' -ForegroundColor DarkGray ; Start-Sleep -Seconds 1 }
  }

  if ($choice.Trim() -eq '7') { break }
}
