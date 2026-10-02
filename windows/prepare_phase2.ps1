<#
================================================================================
 DCIG System Hardening — Windows Phase 2 prepare
 Runs at end of Windows quest (elevated).
================================================================================
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$LabRoot = 'C:\HardeningLab'
$Cfg     = Join-Path $LabRoot 'config'
$Rogue2  = 'C:\ProgramData\NetHelper'
$RunKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'

function Say($m) { Write-Host "[phase2-win] $m" -ForegroundColor Green }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Must run elevated.'; exit 1
}

$Team = if (Test-Path (Join-Path $Cfg 'team.txt')) {
    (Get-Content (Join-Path $Cfg 'team.txt') -Raw).Trim()
} elseif ($env:COMPUTERNAME -match '(\d+)$') {
    '{0:D2}' -f [int]$Matches[1]
} else { '00' }

$Secret = if (Test-Path (Join-Path $Cfg 'secret.txt')) {
    (Get-Content (Join-Path $Cfg 'secret.txt') -Raw).Trim()
} else { 'dcig-hardening-2026' }

$ScoreboardUrl = if (Test-Path (Join-Path $Cfg 'scoreboard_url.txt')) {
    (Get-Content (Join-Path $Cfg 'scoreboard_url.txt') -Raw).Trim()
} else { 'http://127.0.0.1:8080' }

Say "preparing Phase 2 for Team $Team"

# Clear quest progress
Remove-Item (Join-Path $env:LOCALAPPDATA 'HardeningQuest') -Recurse -Force -EA SilentlyContinue

# Clean obvious Phase-1 leftovers (students may already have fixed)
Remove-ItemProperty -Path $RunKey -Name 'SysHealthUpdate' -EA SilentlyContinue
Get-Process -Name 'health_update' -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Remove-NetFirewallRule -DisplayName 'Remote Admin Support' -EA SilentlyContinue
Remove-Item 'C:\ProgramData\SysHealth' -Recurse -Force -EA SilentlyContinue
Remove-Item 'C:\Program Files\PCOptimizer Pro' -Recurse -Force -EA SilentlyContinue
try { Set-MpPreference -DisableRealtimeMonitoring $false -EA SilentlyContinue } catch {}

# ---- Phase 2 plants ---------------------------------------------------------
# Stealth admin
$pass = ConvertTo-SecureString 'Summer2026!' -AsPlainText -Force
if (-not (Get-LocalUser -Name 'sysmaint' -EA SilentlyContinue)) {
    New-LocalUser -Name 'sysmaint' -Password $pass -FullName 'System Maintenance' -PasswordNeverExpires | Out-Null
} else {
    Set-LocalUser -Name 'sysmaint' -Password $pass
}
Add-LocalGroupMember -Group 'Administrators' -Member 'sysmaint' -EA SilentlyContinue

if (-not (Get-LocalUser -Name 'oldintern' -EA SilentlyContinue)) {
    New-LocalUser -Name 'oldintern' -Password (ConvertTo-SecureString 'password' -AsPlainText -Force) `
        -FullName 'Former intern' -PasswordNeverExpires | Out-Null
}

# Scheduled task persistence
$taskScript = 'C:\ProgramData\update_check.ps1'
Set-Content -Path $taskScript -Value 'Start-Sleep -Seconds 1' -Encoding ASCII
schtasks /Create /TN 'SystemUpdateCheck' /SC MINUTE /MO 15 /RU SYSTEM `
    /TR "powershell.exe -WindowStyle Hidden -File $taskScript" /F | Out-Null

# Rogue run key + process
New-Item -ItemType Directory -Force -Path $Rogue2 | Out-Null
$burn = Join-Path $Rogue2 'loop.ps1'
Set-Content $burn -Value 'while ($true) { Start-Sleep -Seconds 45 }' -Encoding ASCII
Copy-Item "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" (Join-Path $Rogue2 'net_helper.exe') -Force
$cmd = '"' + (Join-Path $Rogue2 'net_helper.exe') + '" -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $burn + '"'
New-ItemProperty -Path $RunKey -Name 'NetHelper' -Value $cmd -PropertyType String -Force | Out-Null
Start-Process -FilePath (Join-Path $Rogue2 'net_helper.exe') -ArgumentList '-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$burn -WindowStyle Hidden -EA SilentlyContinue

# Firewall hole
New-NetFirewallRule -DisplayName 'Legacy Backup Port' -Direction Inbound `
    -Action Allow -Protocol TCP -LocalPort 4444 -Profile Any -EA SilentlyContinue | Out-Null

# Defender off again
try { Set-MpPreference -DisableRealtimeMonitoring $true -EA SilentlyContinue } catch {}

# Fake tool
New-Item -ItemType Directory -Force -Path 'C:\Program Files\ChromeUpdater' | Out-Null
Set-Content 'C:\Program Files\ChromeUpdater\chrome-update.bat' -Value '@echo off' -Encoding ASCII

# Weak ACL secrets
New-Item -ItemType Directory -Force -Path 'C:\CaseFiles' | Out-Null
Set-Content 'C:\CaseFiles\backup_creds.txt' -Value 'backup_password=Summer2026!' -Encoding ASCII
icacls 'C:\CaseFiles\backup_creds.txt' /grant Everyone:F | Out-Null

Set-Content (Join-Path $Cfg 'phase.txt') 'phase2'
New-Item -ItemType File -Path (Join-Path $Cfg 'phase2_auto_done.flag') -Force | Out-Null
Remove-Item (Join-Path $Cfg 'start_phase2.flag') -Force -EA SilentlyContinue


# Score agent scheduled task (every 20 sec via a wrapper that loops is heavy —
# use a 1-min task that runs the agent once)
$agent = Join-Path $LabRoot 'score_agent.ps1'
if (-not (Test-Path $agent)) {
    $agent = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'score_agent.ps1'
    Copy-Item $agent (Join-Path $LabRoot 'score_agent.ps1') -Force -EA SilentlyContinue
}
schtasks /Create /TN 'HardeningScoreAgent' /SC MINUTE /MO 1 /RU SYSTEM `
    /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\HardeningLab\score_agent.ps1" /F | Out-Null

# Ready ping
$sigMsg = "ready|$Team|windows"
$hmac = New-Object System.Security.Cryptography.HMACSHA256
$hmac.Key = [Text.Encoding]::UTF8.GetBytes($Secret)
$sig = ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($sigMsg)) | ForEach-Object { $_.ToString('x2') }) -join ''
try {
    Invoke-RestMethod -Method Post -Uri "$ScoreboardUrl/api/ready" -ContentType 'application/json' `
        -Body (@{ team=$Team; os='windows'; sig=$sig } | ConvertTo-Json) -TimeoutSec 5 | Out-Null
} catch {
    Say "scoreboard ready-ping failed (board may be down): $($_.Exception.Message)"
}

@"
Phase 2 is ready on this Windows box (Team $Team).

Find and fix hardening issues. The score agent runs about once a minute and
posts points when mentors open Phase 2 on the scoreboard.

Look for:
  - Extra administrators / stale accounts
  - Startup Run keys and scheduled tasks
  - Bad firewall rules
  - Defender real-time protection
  - Fake software folders
  - Sensitive files with Everyone Full Control
"@ | Set-Content (Join-Path $LabRoot 'PHASE2.txt') -Encoding ASCII

Say 'Phase 2 prep complete.'
