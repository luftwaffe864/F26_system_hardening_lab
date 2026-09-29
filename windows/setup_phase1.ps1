<#
================================================================================
 DCIG System Hardening — Windows Phase 1 setup
 Run elevated on win19_srvNN:

   powershell.exe -ExecutionPolicy Bypass -File .\setup_phase1.ps1

 Optional:
   -ScoreboardUrl http://10.0.0.5:8080
   -Secret 'dcig-hardening-2026'
   -StudentPassword 'Hardening2026!'
================================================================================
#>
[CmdletBinding()]
param(
    [string]$ScoreboardUrl = $(if ($env:SCOREBOARD_URL) { $env:SCOREBOARD_URL } else { 'http://127.0.0.1:8080' }),
    [string]$Secret        = $(if ($env:HARDENING_SECRET) { $env:HARDENING_SECRET } else { 'dcig-hardening-2026' }),
    [string]$StudentPassword = 'Hardening2026!',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$LabRoot = 'C:\HardeningLab'
$Cfg     = Join-Path $LabRoot 'config'
$Rogue   = 'C:\ProgramData\SysHealth'
$Bloat   = 'C:\Program Files\PCOptimizer Pro'
$RunKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'

function Say($m)  { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[x] $m" -ForegroundColor Red }
function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail 'Run from elevated PowerShell.'; exit 1
    }
}

function Get-TeamId {
    $h = $env:COMPUTERNAME
    if ($h -match '(\d+)$') { return ('{0:D2}' -f [int]$Matches[1]) }
    return '00'
}

Assert-Admin
$Team = Get-TeamId

if ($Uninstall) {
    Step 'Uninstall Phase-1 artifacts'
    Get-Process -Name 'health_update' -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Remove-ItemProperty -Path $RunKey -Name 'SysHealthUpdate' -EA SilentlyContinue
    Remove-NetFirewallRule -DisplayName 'Remote Admin Support' -EA SilentlyContinue
    foreach ($d in @($Rogue, $Bloat, $LabRoot)) {
        if (Test-Path $d) { Remove-Item $d -Recurse -Force -EA SilentlyContinue }
    }
    foreach ($u in @('tempadmin','guestuser')) {
        Remove-LocalUser -Name $u -EA SilentlyContinue
    }
    Say 'Uninstall done (student account left in place).'
    exit 0
}

Step "Phase 1 setup on $env:COMPUTERNAME (Team $Team)"

# dirs + config
New-Item -ItemType Directory -Force -Path $Cfg, $Rogue, $Bloat, (Join-Path $LabRoot 'bin') | Out-Null
Set-Content -Path (Join-Path $Cfg 'secret.txt') -Value $Secret -Encoding ASCII
Set-Content -Path (Join-Path $Cfg 'scoreboard_url.txt') -Value $ScoreboardUrl -Encoding ASCII
Set-Content -Path (Join-Path $Cfg 'team.txt') -Value $Team -Encoding ASCII
Set-Content -Path (Join-Path $Cfg 'phase.txt') -Value 'phase1' -Encoding ASCII

# copy scripts next to lab root if present beside this file
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($f in @('hardening_quest.ps1','prepare_phase2.ps1','score_agent.ps1')) {
    $src = Join-Path $here $f
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $LabRoot $f) -Force
        Say "installed $f"
    }
}

# student account
$sec = ConvertTo-SecureString $StudentPassword -AsPlainText -Force
if (-not (Get-LocalUser -Name 'student' -EA SilentlyContinue)) {
    New-LocalUser -Name 'student' -Password $sec -FullName 'DCIG Student' `
        -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
} else {
    Set-LocalUser -Name 'student' -Password $sec
}
Add-LocalGroupMember -Group 'Administrators' -Member 'student' -EA SilentlyContinue
Say 'student account ready (Administrators)'

# bad admin + unused user
foreach ($u in @(
    @{ Name='tempadmin'; Pass='Password1'; Full='Temp Admin - REMOVE'; Admin=$true },
    @{ Name='guestuser'; Pass='guest';     Full='Unused guest';        Admin=$false }
)) {
    $p = ConvertTo-SecureString $u.Pass -AsPlainText -Force
    if (-not (Get-LocalUser -Name $u.Name -EA SilentlyContinue)) {
        New-LocalUser -Name $u.Name -Password $p -FullName $u.Full -PasswordNeverExpires | Out-Null
    } else {
        Set-LocalUser -Name $u.Name -Password $p -FullName $u.Full
    }
    if ($u.Admin) { Add-LocalGroupMember -Group 'Administrators' -Member $u.Name -EA SilentlyContinue }
    else { Add-LocalGroupMember -Group 'Users' -Member $u.Name -EA SilentlyContinue }
}
Say 'planted tempadmin + guestuser'

# briefing
$brief = @"
DCIG System Hardening — Windows box
Hostname: $env:COMPUTERNAME
Team: $Team

You should have finished the Linux quest first. Harden this Windows box the same way:
map the attack surface, then fix users, startup, firewall, and Defender.

Sticky note: tempadmin password is Password1 (reused elsewhere — don't do that).
"@
Set-Content -Path (Join-Path $LabRoot 'briefing.txt') -Value $brief -Encoding ASCII

# fake bloat
Set-Content -Path (Join-Path $Bloat 'PCOptimizer.exe.txt') -Value 'Fake bloatware placeholder — delete this folder.' -Encoding ASCII
New-Item -ItemType Directory -Force -Path (Join-Path $Bloat 'Plugins') | Out-Null

# rogue binary + run key (harmless loop via powershell copy)
$burn = Join-Path $Rogue 'burn.ps1'
@'
while ($true) { Start-Sleep -Seconds 30 }
'@ | Set-Content -Path $burn -Encoding ASCII
Copy-Item "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
          (Join-Path $Rogue 'health_update.exe') -Force
$cmd = '"' + (Join-Path $Rogue 'health_update.exe') + '" -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $burn + '"'
New-ItemProperty -Path $RunKey -Name 'SysHealthUpdate' -Value $cmd -PropertyType String -Force | Out-Null
Say 'planted startup persistence SysHealthUpdate'

# start it once for Task Manager visibility
Start-Process -FilePath (Join-Path $Rogue 'health_update.exe') `
    -ArgumentList '-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$burn `
    -WindowStyle Hidden -EA SilentlyContinue

# firewall rule
New-NetFirewallRule -DisplayName 'Remote Admin Support' -Direction Inbound `
    -Action Allow -Protocol TCP -LocalPort 5555 -Profile Any -EA SilentlyContinue | Out-Null
Say 'planted firewall rule Remote Admin Support (TCP 5555)'

# Defender real-time off (best effort — may be managed)
try {
    Set-MpPreference -DisableRealtimeMonitoring $true -EA Stop
    Say 'disabled Defender real-time monitoring (lab)'
} catch {
    Warn "could not disable Defender RTP: $($_.Exception.Message)"
}

# world-readable secrets file
$secFile = 'C:\CaseFiles\keys.txt'
New-Item -ItemType Directory -Force -Path 'C:\CaseFiles' | Out-Null
Set-Content -Path $secFile -Value 'API_KEY=windows-demo-key-not-real' -Encoding ASCII
icacls $secFile /grant Everyone:F | Out-Null
Say 'planted C:\CaseFiles\keys.txt (Everyone full)'

# helper launcher
$launch = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$LabRoot\hardening_quest.ps1`"
"@
Set-Content -Path (Join-Path $LabRoot 'bin\hardening-quest.cmd') -Value $launch -Encoding ASCII
Say "Quest: $LabRoot\hardening_quest.ps1  (or bin\hardening-quest.cmd)"
Say "Student login: student / $StudentPassword"
Say 'Phase 1 complete.'
