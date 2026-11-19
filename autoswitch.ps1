<#
.SYNOPSIS
  Enable or disable automatic DNS fix when Windows connects to a new network.

.DESCRIPTION
  Creates (or removes) a Windows Task Scheduler task that fires 5 seconds after
  any network connection event (Event ID 10000, Microsoft-Windows-NetworkProfile).
  The task silently runs diagnose.ps1 -Fix in the background, so switching between
  Ethernet, Wi-Fi, or a mobile hotspot never breaks Acrylic DNS-redirect again.

.PARAMETER Enable
  Register the auto-switch task (default action when no switch given).

.PARAMETER Disable
  Remove the auto-switch task.

.PARAMETER Status
  Show whether the task exists and its last run result.

.PARAMETER InstallDir
  Acrylic install directory. Default %LOCALAPPDATA%\AcrylicDNS.

.PARAMETER ScriptDir
  Directory containing diagnose.ps1. Default: same folder as this script.

.EXAMPLE
  .\autoswitch.ps1 -Enable
.EXAMPLE
  .\autoswitch.ps1 -Disable
.EXAMPLE
  .\autoswitch.ps1 -Status
#>
param(
  [switch]$Enable,
  [switch]$Disable,
  [switch]$Status,
  [string]$InstallDir = "$env:LOCALAPPDATA\AcrylicDNS",
  [string]$ScriptDir  = $PSScriptRoot,
  [string]$RepoBase   = 'https://raw.githubusercontent.com/fdoo24/acrylic-dns-unlock/main'
)
$ErrorActionPreference = 'Stop'

$TaskName = 'AcrylicDNS-AutoSwitch'

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Elevate-Self([string[]]$extraArgs) {
  $tmp = Join-Path $env:TEMP 'acrylic-dns-unlock-autoswitch.ps1'
  if ($PSCommandPath) { Copy-Item $PSCommandPath $tmp -Force }
  else { Invoke-WebRequest -UseBasicParsing "$RepoBase/autoswitch.ps1" -OutFile $tmp }
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tmp,
         '-InstallDir', $InstallDir, '-ScriptDir', $ScriptDir) + $extraArgs
  Write-Host 'Requesting elevation (UAC)...'
  Start-Process powershell -Verb RunAs -ArgumentList $a -Wait
}

function Get-DiagnoseScriptPath {
  # Prefer local clone; fall back to temp download
  $local = Join-Path $ScriptDir 'diagnose.ps1'
  if (Test-Path $local) { return $local }
  $tmp = Join-Path $env:TEMP 'acrylic-dns-unlock-diagnose.ps1'
  if (-not (Test-Path $tmp)) {
    Invoke-WebRequest -UseBasicParsing "$RepoBase/diagnose.ps1" -OutFile $tmp
  }
  return $tmp
}

# ---------------------------------------------------------------------------
# -Status: no elevation needed
# ---------------------------------------------------------------------------
if ($Status -or (-not $Enable -and -not $Disable)) {
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($task) {
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    $lastRun    = if ($info.LastRunTime  -gt [datetime]'2000-01-01') { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss')  } else { 'Never' }
    $lastResult = $info.LastTaskResult
    $resultText = switch ($lastResult) {
      0          { 'Success (0)' }
      267009     { 'Still running (267009)' }
      2147942402 { 'File not found - check script path' }
      default    { "Code $lastResult" }
    }
    Write-Host ''
    Write-Host '=== AcrylicDNS Auto-Switch Status ===' -ForegroundColor Cyan
    Write-Host "  Task name  : $TaskName"
    Write-Host "  State      : $($task.State)" -ForegroundColor Green
    Write-Host "  Last run   : $lastRun"
    Write-Host "  Last result: $resultText"
    Write-Host ''
    Write-Host '  Trigger: fires 5 sec after every new network connection (Event 10000).'
    Write-Host '  Action : diagnose.ps1 -Fix  (silent, hidden window, runs as SYSTEM)'
    Write-Host ''
    Write-Host "  To disable: .\autoswitch.ps1 -Disable"
  } else {
    Write-Host ''
    Write-Host '=== AcrylicDNS Auto-Switch Status ===' -ForegroundColor Cyan
    Write-Host "  Task '$TaskName' is NOT registered." -ForegroundColor Yellow
    Write-Host '  To enable: .\autoswitch.ps1 -Enable'
    Write-Host ''
  }
  if (-not $Enable -and -not $Disable) { return }
}

# ---------------------------------------------------------------------------
# Elevation check for -Enable / -Disable
# ---------------------------------------------------------------------------
if (-not (Test-Admin)) {
  if ($Enable)  { Elevate-Self @('-Enable') }
  if ($Disable) { Elevate-Self @('-Disable') }
  return
}

# ---------------------------------------------------------------------------
# -Disable
# ---------------------------------------------------------------------------
if ($Disable) {
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Task '$TaskName' removed. Auto-switch is OFF." -ForegroundColor Green
  } else {
    Write-Host "Task '$TaskName' was not registered." -ForegroundColor DarkGray
  }
  return
}

# ---------------------------------------------------------------------------
# -Enable: build and register the task
# ---------------------------------------------------------------------------
$diagPath = Get-DiagnoseScriptPath

Write-Host ''
Write-Host '=== Enabling AcrylicDNS Auto-Switch ===' -ForegroundColor Cyan
Write-Host "  diagnose.ps1 path : $diagPath"
Write-Host "  Install dir       : $InstallDir"
Write-Host ''

# PowerShell command the task will run (hidden, no window)
$psArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass " +
          "-File `"$diagPath`" -Fix -InstallDir `"$InstallDir`""

$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs

# Trigger: Microsoft-Windows-NetworkProfile / Operational, Event 10000 (network connected)
# Delay 5s to let Windows fully assign DHCP/DNS before we reconfigure.
$triggerXml = @"
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational">
    <Select Path="Microsoft-Windows-NetworkProfile/Operational">
      *[System[EventID=10000]]
    </Select>
  </Query>
</QueryList>
"@
$trigger = New-ScheduledTaskTrigger -AtStartup   # placeholder; replaced below via CIM

# Run as SYSTEM (no interactive session needed, works even at login screen)
$principal = New-ScheduledTaskPrincipal `
  -UserId 'NT AUTHORITY\SYSTEM' `
  -LogonType ServiceAccount `
  -RunLevel Highest

$settings  = New-ScheduledTaskSettingsSet `
  -ExecutionTimeLimit  (New-TimeSpan -Minutes 2) `
  -MultipleInstances   IgnoreNew `
  -StartWhenAvailable

# Register with the placeholder trigger first, then swap it via raw XML
$task = Register-ScheduledTask `
  -TaskName  $TaskName `
  -Action    $action `
  -Principal $principal `
  -Settings  $settings `
  -Force

# Replace trigger with event-based via COM (CIM XML method)
$scheduler = New-Object -ComObject 'Schedule.Service'
$scheduler.Connect()
$folder    = $scheduler.GetFolder('\')
$rawTask   = $folder.GetTask($TaskName)
$definition= $rawTask.Definition

# Remove the placeholder trigger
$definition.Triggers.Clear()

# Add the EventTrigger
$evtTrigger = $definition.Triggers.Create(0)   # 0 = EVENT trigger
$evtTrigger.Subscription = "<QueryList><Query Id=`"0`" Path=`"Microsoft-Windows-NetworkProfile/Operational`"><Select Path=`"Microsoft-Windows-NetworkProfile/Operational`">*[System[EventID=10000]]</Select></Query></QueryList>"
$evtTrigger.Delay   = 'PT5S'   # wait 5 sec for network to fully connect
$evtTrigger.Enabled = $true

$folder.RegisterTaskDefinition(
  $TaskName,
  $definition,
  6,          # TASK_CREATE_OR_UPDATE
  'NT AUTHORITY\SYSTEM',
  $null,
  5           # TASK_LOGON_SERVICE_ACCOUNT
) | Out-Null

Write-Host "  Task '$TaskName' registered successfully." -ForegroundColor Green
Write-Host ''
Write-Host '  How it works:' -ForegroundColor DarkCyan
Write-Host '    Every time Windows connects to any network (Ethernet, Wi-Fi, mobile'
Write-Host '    hotspot) — after 5 seconds, diagnose.ps1 -Fix runs silently.'
Write-Host '    If Acrylic DNS is misconfigured for the new adapter, it fixes itself.'
Write-Host '    If everything is already correct — it does nothing.'
Write-Host ''
Write-Host "  To disable: .\autoswitch.ps1 -Disable"
Write-Host "  To verify : .\autoswitch.ps1 -Status"
