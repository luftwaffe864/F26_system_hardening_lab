<#
================================================================================
 DCIG System Hardening — Windows Phase 2 prepare
 Auto-run after Windows quest. Plants easy → hard findings for CyberPatriot scoring.
================================================================================
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$LabRoot = 'C:\HardeningLab'
$Cfg     = Join-Path $LabRoot 'config'
$Rogue2  = 'C:\ProgramData\NetHelper'
$RunKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$RunOnce = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$StartupAll = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp'

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

Say "preparing Phase 2 findings (easy→hard) for Team $Team"

Remove-Item (Join-Path $env:LOCALAPPDATA 'HardeningQuest') -Recurse -Force -EA SilentlyContinue

# Clear Phase-1 leftovers
Remove-ItemProperty -Path $RunKey -Name 'SysHealthUpdate' -EA SilentlyContinue
Get-Process -Name 'health_update' -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Remove-NetFirewallRule -DisplayName 'Remote Admin Support' -EA SilentlyContinue
Remove-Item 'C:\ProgramData\SysHealth' -Recurse -Force -EA SilentlyContinue
Remove-Item 'C:\Program Files\PCOptimizer Pro' -Recurse -Force -EA SilentlyContinue
try { Set-MpPreference -DisableRealtimeMonitoring $false -EA SilentlyContinue } catch {}

# ========== EASY ==========
# W2-02 unused account
if (-not (Get-LocalUser -Name 'oldintern' -EA SilentlyContinue)) {
    New-LocalUser -Name 'oldintern' -Password (ConvertTo-SecureString 'password' -AsPlainText -Force) `
        -FullName 'Former intern' -PasswordNeverExpires | Out-Null
}

# W2-09 enable Guest
try {
    $g = Get-LocalUser -Name 'Guest' -EA SilentlyContinue
    if ($g) { Enable-LocalUser -Name 'Guest' -EA SilentlyContinue }
} catch {}

# W2-07 fake software
New-Item -ItemType Directory -Force -Path 'C:\Program Files\ChromeUpdater' | Out-Null
Set-Content 'C:\Program Files\ChromeUpdater\chrome-update.bat' -Value '@echo off' -Encoding ASCII

# W2-10 more bloat
New-Item -ItemType Directory -Force -Path 'C:\Program Files\FreeGameLauncher' | Out-Null
Set-Content 'C:\Program Files\FreeGameLauncher\readme.txt' -Value 'Fake game launcher — delete this folder' -Encoding ASCII

# W2-11 plaintext passwords on student desktop
$desk = 'C:\Users\student\Desktop'
New-Item -ItemType Directory -Force -Path $desk | Out-Null
Set-Content (Join-Path $desk 'passwords.txt') -Value "wifi=Winter2024!`r`nadmin=Password1`r`n" -Encoding ASCII
icacls (Join-Path $desk 'passwords.txt') /grant 'Users:F' | Out-Null

# ========== MEDIUM ==========
# W2-01 stealth admin
$pass = ConvertTo-SecureString 'Summer2026!' -AsPlainText -Force
if (-not (Get-LocalUser -Name 'sysmaint' -EA SilentlyContinue)) {
    New-LocalUser -Name 'sysmaint' -Password $pass -FullName 'System Maintenance' -PasswordNeverExpires | Out-Null
} else {
    Set-LocalUser -Name 'sysmaint' -Password $pass
}
Add-LocalGroupMember -Group 'Administrators' -Member 'sysmaint' -EA SilentlyContinue

# W2-03 scheduled task
$taskScript = 'C:\ProgramData\update_check.ps1'
Set-Content -Path $taskScript -Value 'Start-Sleep -Seconds 1' -Encoding ASCII
schtasks /Create /TN 'SystemUpdateCheck' /SC MINUTE /MO 15 /RU SYSTEM `
    /TR "powershell.exe -WindowStyle Hidden -File $taskScript" /F | Out-Null

# W2-05 firewall hole
New-NetFirewallRule -DisplayName 'Legacy Backup Port' -Direction Inbound `
    -Action Allow -Protocol TCP -LocalPort 4444 -Profile Any -EA SilentlyContinue | Out-Null

# W2-06 Defender off
try { Set-MpPreference -DisableRealtimeMonitoring $true -EA SilentlyContinue } catch {}

# W2-08 weak ACL secrets
New-Item -ItemType Directory -Force -Path 'C:\CaseFiles' | Out-Null
Set-Content 'C:\CaseFiles\backup_creds.txt' -Value 'backup_password=Summer2026!' -Encoding ASCII
icacls 'C:\CaseFiles\backup_creds.txt' /grant Everyone:F | Out-Null

# W2-12 AutoAdminLogon with password in registry
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
New-ItemProperty -Path $wl -Name 'AutoAdminLogon' -Value '1' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $wl -Name 'DefaultUserName' -Value 'sysmaint' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $wl -Name 'DefaultPassword' -Value 'Summer2026!' -PropertyType String -Force | Out-Null

# W2-13 second firewall allow (high port)
New-NetFirewallRule -DisplayName 'Vendor Support Tunnel' -Direction Inbound `
    -Action Allow -Protocol TCP -LocalPort 1337 -Profile Any -EA SilentlyContinue | Out-Null

# W2-14 helpdesk in Administrators (second bad admin)
$hdPass = ConvertTo-SecureString 'Helpdesk1' -AsPlainText -Force
if (-not (Get-LocalUser -Name 'helpdesk' -EA SilentlyContinue)) {
    New-LocalUser -Name 'helpdesk' -Password $hdPass -FullName 'Help Desk Temp' -PasswordNeverExpires | Out-Null
}
Add-LocalGroupMember -Group 'Administrators' -Member 'helpdesk' -EA SilentlyContinue

# ========== HARD ==========
# W2-04 Run key + process
New-Item -ItemType Directory -Force -Path $Rogue2 | Out-Null
$burn = Join-Path $Rogue2 'loop.ps1'
Set-Content $burn -Value 'while ($true) { Start-Sleep -Seconds 45 }' -Encoding ASCII
Copy-Item "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" (Join-Path $Rogue2 'net_helper.exe') -Force
$cmd = '"' + (Join-Path $Rogue2 'net_helper.exe') + '" -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $burn + '"'
New-ItemProperty -Path $RunKey -Name 'NetHelper' -Value $cmd -PropertyType String -Force | Out-Null
Start-Process -FilePath (Join-Path $Rogue2 'net_helper.exe') -ArgumentList '-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$burn -WindowStyle Hidden -EA SilentlyContinue

# W2-15 All-Users Startup folder persistence
New-Item -ItemType Directory -Force -Path $StartupAll | Out-Null
Set-Content (Join-Path $StartupAll 'SecurityUpdate.bat') -Value '@echo off`r`nrem lab persistence — delete this file' -Encoding ASCII

# W2-16 RunOnce persistence
New-ItemProperty -Path $RunOnce -Name 'FlushCache' -Value 'cmd.exe /c echo lab' -PropertyType String -Force | Out-Null

# W2-17 stealth scheduled task (different name)
$stealth = 'C:\ProgramData\svc_health.ps1'
Set-Content -Path $stealth -Value '# lab' -Encoding ASCII
schtasks /Create /TN 'WindowsHealthMonitor' /SC HOURLY /RU SYSTEM `
    /TR "powershell.exe -WindowStyle Hidden -File $stealth" /F | Out-Null

# W2-18 simple rogue service (if we can create one)
$svcDir = 'C:\ProgramData\WinUpdSvc'
New-Item -ItemType Directory -Force -Path $svcDir | Out-Null
$svcPs1 = Join-Path $svcDir 'run.ps1'
Set-Content $svcPs1 -Value 'while ($true) { Start-Sleep 60 }' -Encoding ASCII
# Use sc to create a service that runs powershell - may show as startable finding; students stop/delete
$bin = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$svcPs1`""
cmd /c "sc.exe create HLWinUpd binPath= `"$bin`" start= auto DisplayName= `"Windows Update Compatibility`" >nul 2>&1"
cmd /c "sc.exe start HLWinUpd >nul 2>&1"

# W2-19 world-readable secrets under ProgramData
Set-Content 'C:\ProgramData\app_secrets.ini' -Value "api_key=not-a-real-key`r`n" -Encoding ASCII
icacls 'C:\ProgramData\app_secrets.ini' /grant Everyone:F | Out-Null

Set-Content (Join-Path $Cfg 'phase.txt') 'phase2'
New-Item -ItemType File -Path (Join-Path $Cfg 'phase2_auto_done.flag') -Force | Out-Null
Remove-Item (Join-Path $Cfg 'start_phase2.flag') -Force -EA SilentlyContinue

$agent = Join-Path $LabRoot 'score_agent.ps1'
if (-not (Test-Path $agent)) {
    $agent = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'score_agent.ps1'
    Copy-Item $agent (Join-Path $LabRoot 'score_agent.ps1') -Force -EA SilentlyContinue
}
schtasks /Create /TN 'HardeningScoreAgent' /SC MINUTE /MO 1 /RU SYSTEM `
    /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\HardeningLab\score_agent.ps1" /F | Out-Null

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

CyberPatriot-style scoring: fix the MACHINE. The score agent checks system
state about once a minute — you do NOT type answers into a prompt.

Categories (easy → hard):
  - Unused / Guest accounts
  - Sketchy Program Files folders and Desktop password files
  - Windows Defender real-time protection
  - Extra Administrators
  - Bad inbound firewall rules
  - Startup Run keys, Startup folder, RunOnce
  - Scheduled tasks
  - AutoAdminLogon / passwords in Winlogon
  - Unexpected services
  - Sensitive files with Everyone Full Control

Mentors open the room scoreboard when the race starts.
"@ | Set-Content (Join-Path $LabRoot 'PHASE2.txt') -Encoding ASCII

Say 'Phase 2 prep complete.'
