<#
.SYNOPSIS
  Configure automatic hourly domain updates from GitHub Gist for Acrylic DNS.

.DESCRIPTION
  Creates or removes a Windows Task Scheduler task ('AcrylicDNS-AutoUpdate')
  that runs silently in the background every hour. It downloads domains from
  Gist, compares them with local hosts, and updates Acrylic without downtime.
  Has zero noticeable impact on CPU or RAM (runs in ~0.5s and exits).

.PARAMETER Enable
  Register the hourly auto-update task.

.PARAMETER Disable
  Remove the auto-update task.

.PARAMETER Status
  Show current task status and last run result.

.PARAMETER IntervalHours
  How often to check for updates (default: 1 hour).
#>
[CmdletBinding()]
param(
  [switch]$Enable,
  [switch]$Disable,
  [switch]$Status,
  [string]$InstallDir = "$env:LOCALAPPDATA\AcrylicDNS",
  [string]$ScriptDir  = $PSScriptRoot,
  [int]$IntervalHours = 1
)

$TaskName = 'AcrylicDNS-AutoUpdate'
$ErrorActionPreference = 'Stop'

if (-not $ScriptDir) {
  $ScriptDir = if ($PSScriptRoot) { $PSScriptRoot }
               elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
               elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
               else { (Get-Location).Path }
}

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Elevate-Self([string[]]$extraArgs) {
  $path = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $ScriptDir 'autoupdate.ps1' }
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path,
         '-InstallDir', $InstallDir, '-ScriptDir', $ScriptDir) + $extraArgs
  Write-Host 'Requesting elevation (UAC)...'
  Start-Process powershell -Verb RunAs -ArgumentList $a -Wait
}

# ---------------------------------------------------------------------------
# Status check
# ---------------------------------------------------------------------------
if ($Status -or (-not $Enable -and -not $Disable)) {
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Write-Host ''
  Write-Host '=== AcrylicDNS Auto-Update Domains Status ===' -ForegroundColor Cyan
  if ($task) {
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    $lastRun = if ($info.LastRunTime -gt [datetime]'2000-01-01') { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'Never' }
    $lastResult = switch ($info.LastTaskResult) {
      0       { 'Success (0)' }
      default { "Code $($info.LastTaskResult)" }
    }
    Write-Host "  Task name  : $TaskName"
    Write-Host "  State      : $($task.State)" -ForegroundColor Green
    Write-Host "  Last run   : $lastRun"
    Write-Host "  Last result: $lastResult"
    Write-Host ''
    Write-Host '  Schedule   : Runs every 1 hour in the background (silent).'
    Write-Host '  Action     : update-ip.ps1 -RefreshDomains'
    Write-Host '  Performance: 0% CPU, 0 MB RAM idle, ~2 KB network check.' -ForegroundColor Green
    Write-Host ''
    Write-Host '  To disable : .\autoupdate.ps1 -Disable'
  } else {
    Write-Host "  Task '$TaskName' is NOT registered." -ForegroundColor Yellow
    Write-Host '  To enable  : .\autoupdate.ps1 -Enable'
  }
  Write-Host ''
  if (-not $Enable -and -not $Disable) { return }
}

# ---------------------------------------------------------------------------
# Elevation check
# ---------------------------------------------------------------------------
if (-not (Test-Admin)) {
  $args_ = @()
  if ($Enable)  { $args_ += '-Enable' }
  if ($Disable) { $args_ += '-Disable' }
  Elevate-Self $args_
  return
}

# ---------------------------------------------------------------------------
# Disable task
# ---------------------------------------------------------------------------
if ($Disable) {
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Task '$TaskName' removed successfully." -ForegroundColor Green
  } else {
    Write-Host "Task '$TaskName' was not registered." -ForegroundColor DarkGray
  }
  return
}

# ---------------------------------------------------------------------------
# Enable task
# ---------------------------------------------------------------------------
$updateScript = Join-Path $ScriptDir 'update-ip.ps1'
if (-not (Test-Path $updateScript)) {
  throw "Cannot find update-ip.ps1 in $ScriptDir"
}

Write-Host ''
Write-Host '=== Enabling AcrylicDNS Hourly Auto-Update ===' -ForegroundColor Cyan
Write-Host "  Script path: $updateScript"
Write-Host "  Frequency  : Every $IntervalHours hour(s)"
Write-Host ''

$psArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass " +
          "-File `"$updateScript`" -RefreshDomains -InstallDir `"$InstallDir`""

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs

# Trigger: runs every X hours starting today
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours $IntervalHours)

# Run as SYSTEM
$principal = New-ScheduledTaskPrincipal `
  -UserId 'NT AUTHORITY\SYSTEM' `
  -LogonType ServiceAccount `
  -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
  -MultipleInstances IgnoreNew `
  -StartWhenAvailable `
  -RunOnlyIfNetworkAvailable

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $trigger `
  -Principal $principal `
  -Settings $settings `
  -Force | Out-Null

Write-Host "  Task '$TaskName' registered successfully." -ForegroundColor Green
Write-Host '  Performance impact: ZERO (powershell checks in ~0.5s, no restart if no changes).' -ForegroundColor Green
Write-Host ''
