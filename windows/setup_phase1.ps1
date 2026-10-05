<#
================================================================================
 DCIG System Hardening - Windows Phase 1 setup
 Run elevated on win19_srvNN (range or homelab):

   powershell.exe -ExecutionPolicy Bypass -File .\setup_phase1.ps1

 Optional:
   -ScoreboardUrl http://10.0.0.5:8080
   -Secret 'dcig-hardening-2026'
   -StudentPassword 'Hardening2026!'
================================================================================
#>
[CmdletBinding()]
param(
    [string]$ScoreboardUrl = $(if ($env:SCOREBOARD_URL) { $env:SCOREBOARD_URL } else { 'http://192.168.1.7:8080' }),
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

# schtasks writes to stderr when a task is missing; with $ErrorActionPreference=Stop that aborts the script.
function Invoke-SchtasksQuiet {
    param([Parameter(Mandatory)][string]$ArgumentList)
    cmd.exe /c "schtasks $ArgumentList >nul 2>&1" | Out-Null
    return $LASTEXITCODE
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail 'Run from elevated PowerShell.'; exit 1
    }
}

# Lab plants intentionally weak passwords (Password1, guest). Range GPO/local policy
# often blocks that - relax local password policy before creating accounts.
function Enable-LabWeakPasswords {
    try {
        net accounts /minpwlen:0 /maxpwage:unlimited /uniquepw:0 | Out-Null
    } catch {}
    $inf = Join-Path $env:TEMP 'dcig_lab_secpol.inf'
    $db  = Join-Path $env:TEMP 'dcig_lab_secpol.sdb'
    $log = Join-Path $env:TEMP 'dcig_lab_secpol.log'
    @"
[Unicode]
Unicode=yes
[System Access]
MinimumPasswordLength = 0
PasswordComplexity = 0
MinimumPasswordAge = 0
MaximumPasswordAge = -1
PasswordHistorySize = 0
[Version]
signature="`$CHICAGO`$"
Revision=1
"@ | Set-Content -Path $inf -Encoding Unicode
    $p = Start-Process -FilePath 'secedit.exe' -ArgumentList "/configure /db `"$db`" /cfg `"$inf`" /areas SECURITYPOLICY /log `"$log`"" `
        -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) {
        Warn "secedit password-policy relax returned exit $($p.ExitCode) (domain GPO may still block weak passwords)"
    } else {
        Say 'relaxed local password policy (complexity off) for lab plant accounts'
    }
}

function New-LabLocalUser {
    param(
        [string]$Name,
        [string]$Password,
        [string]$FullName,
        [string]$FallbackPassword
    )
    $tries = @($Password)
    if ($FallbackPassword -and $FallbackPassword -ne $Password) { $tries += $FallbackPassword }
    foreach ($pw in $tries) {
        $p = ConvertTo-SecureString $pw -AsPlainText -Force
        try {
            if (-not (Get-LocalUser -Name $Name -EA SilentlyContinue)) {
                New-LocalUser -Name $Name -Password $p -FullName $FullName -PasswordNeverExpires | Out-Null
            } else {
                Set-LocalUser -Name $Name -Password $p -FullName $FullName -PasswordNeverExpires $true | Out-Null
            }
            if ($pw -ne $Password) {
                Warn "account $Name created with fallback password (policy blocked '$Password')"
            }
            return $true
        } catch {
            if ($pw -eq $tries[-1]) {
                Warn "could not create/update $Name : $($_.Exception.Message)"
                return $false
            }
        }
    }
    return $false
}

$TeamIdScript = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\scripts\TeamId.ps1'
if (Test-Path $TeamIdScript) { . $TeamIdScript }

function Get-TeamId {
    if (Get-Command Get-TeamIdFromHostname -ErrorAction SilentlyContinue) {
        return Get-TeamIdFromHostname
    }
    $h = $env:COMPUTERNAME
    if ($h -match '(?i)team(\d+)') { return ('{0:D2}' -f [int]$Matches[1]) }
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
Enable-LabWeakPasswords

# dirs + config
New-Item -ItemType Directory -Force -Path $Cfg, $Rogue, $Bloat, (Join-Path $LabRoot 'bin') | Out-Null
Set-Content -Path (Join-Path $Cfg 'secret.txt') -Value $Secret -Encoding ASCII
Set-Content -Path (Join-Path $Cfg 'scoreboard_url.txt') -Value $ScoreboardUrl -Encoding ASCII
Set-Content -Path (Join-Path $Cfg 'team.txt') -Value $Team -Encoding ASCII
Set-Content -Path (Join-Path $Cfg 'phase.txt') -Value 'phase1' -Encoding ASCII
Set-Content -Path (Join-Path $Cfg 'student_password.txt') -Value $StudentPassword -Encoding ASCII
icacls (Join-Path $Cfg 'student_password.txt') /inheritance:r /grant 'SYSTEM:F' 'Administrators:F' | Out-Null
# Student quest must be able to drop start_phase2.flag without elevation
icacls $Cfg /grant 'Users:(OI)(CI)(M)' /T | Out-Null
icacls $LabRoot /grant 'Users:(OI)(CI)(RX)' /T | Out-Null

# copy scripts next to lab root if present beside this file
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($f in @('hardening_quest.ps1','prepare_phase2.ps1','score_agent.ps1','Ensure-LabAccess.ps1')) {
    $src = Join-Path $here $f
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $LabRoot $f) -Force
        Say "installed $f"
    }
}
# Keep shortcut helper on the box for mentors / re-runs
$scSrc = Join-Path (Split-Path $here -Parent) 'scripts\Make-ScoreboardShortcut.ps1'
if (Test-Path $scSrc) {
    Copy-Item $scSrc (Join-Path $LabRoot 'Make-ScoreboardShortcut.ps1') -Force
}

# student account (avoid UserMayNotChangePassword - missing on some Server 2019 builds)
$sec = ConvertTo-SecureString $StudentPassword -AsPlainText -Force
if (-not (Get-LocalUser -Name 'student' -EA SilentlyContinue)) {
    New-LocalUser -Name 'student' -Password $sec -FullName 'DCIG Student' `
        -PasswordNeverExpires | Out-Null
} else {
    Set-LocalUser -Name 'student' -Password $sec -PasswordNeverExpires $true | Out-Null
}
Enable-LocalUser -Name 'student' -EA SilentlyContinue | Out-Null
# Prefer net.exe for "user cannot change password" (works on Server 2019)
cmd /c "net user student /passwordchg:no" | Out-Null
Add-LocalGroupMember -Group 'Administrators' -Member 'student' -EA SilentlyContinue
Say 'student account ready (Administrators; password reset by lab if changed)'

# bad admin + unused user (weak passwords - policy relaxed above)
foreach ($u in @(
    @{ Name='tempadmin'; Pass='Password1'; Fallback='Password1!Aa'; Full='Temp Admin - REMOVE'; Admin=$true },
    @{ Name='guestuser'; Pass='guest';     Fallback='GuestUser1!';  Full='Unused guest';        Admin=$false }
)) {
    if (New-LabLocalUser -Name $u.Name -Password $u.Pass -FullName $u.Full -FallbackPassword $u.Fallback) {
        if ($u.Admin) { Add-LocalGroupMember -Group 'Administrators' -Member $u.Name -EA SilentlyContinue }
        else { Add-LocalGroupMember -Group 'Users' -Member $u.Name -EA SilentlyContinue }
    }
}
Say 'planted tempadmin + guestuser (best-effort)'

# briefing
$brief = @"
DCIG System Hardening - Windows box
Hostname: $env:COMPUTERNAME
Team: $Team

You should have finished the Linux quest first. Harden this Windows box the same way:
map the attack surface, then fix users, startup, firewall, and Defender.

Sticky note: tempadmin password is Password1 (reused elsewhere - don't do that).

Lab note: RDP stays enabled (port 3389). Do not rename or delete the student account.
"@
Set-Content -Path (Join-Path $LabRoot 'briefing.txt') -Value $brief -Encoding ASCII

# fake bloat
Set-Content -Path (Join-Path $Bloat 'PCOptimizer.exe.txt') -Value 'Fake bloatware placeholder - delete this folder.' -Encoding ASCII
New-Item -ItemType Directory -Force -Path (Join-Path $Bloat 'Plugins') | Out-Null

# rogue binary + run key (harmless loop via powershell copy)
$burn = Join-Path $Rogue 'burn.ps1'
$rogueExe = Join-Path $Rogue 'health_update.exe'
@'
while ($true) { Start-Sleep -Seconds 30 }
'@ | Set-Content -Path $burn -Encoding ASCII
# Re-runs lock health_update.exe if a previous plant is still running
Get-Process -Name 'health_update' -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Milliseconds 500
try {
    Copy-Item "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" $rogueExe -Force
} catch {
    # Still locked - rename aside and copy fresh
    Remove-Item "$rogueExe.bak" -Force -EA SilentlyContinue
    if (Test-Path $rogueExe) {
        Rename-Item $rogueExe "$rogueExe.bak" -Force -EA SilentlyContinue
    }
    Copy-Item "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" $rogueExe -Force
}
$cmd = '"' + $rogueExe + '" -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $burn + '"'
New-ItemProperty -Path $RunKey -Name 'SysHealthUpdate' -Value $cmd -PropertyType String -Force | Out-Null
Say 'planted startup persistence SysHealthUpdate'

# start it once for Task Manager visibility
Start-Process -FilePath $rogueExe `
    -ArgumentList '-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$burn `
    -WindowStyle Hidden -EA SilentlyContinue

# firewall rule
New-NetFirewallRule -DisplayName 'Remote Admin Support' -Direction Inbound `
    -Action Allow -Protocol TCP -LocalPort 5555 -Profile Any -EA SilentlyContinue | Out-Null
Say 'planted firewall rule Remote Admin Support (TCP 5555)'

# Defender real-time off (best effort - may be managed)
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
New-Item -ItemType Directory -Force -Path (Join-Path $LabRoot 'bin') | Out-Null
$launch = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$LabRoot\hardening_quest.ps1`"
"@
Set-Content -Path (Join-Path $LabRoot 'bin\hardening-quest.cmd') -Value $launch -Encoding ASCII

# Auto Phase-2: student quest only drops a flag; SYSTEM watcher runs prepare (no UAC).
$watch = @'
$ErrorActionPreference = "SilentlyContinue"
$LabRoot = "C:\HardeningLab"
$Cfg = Join-Path $LabRoot "config"
$flag = Join-Path $Cfg "start_phase2.flag"
$done = Join-Path $Cfg "phase2_auto_done.flag"
$prep = Join-Path $LabRoot "prepare_phase2.ps1"
$log  = Join-Path $LabRoot "phase2-prep.log"
if (-not (Test-Path $flag)) { exit 0 }
if (Test-Path $done) { Remove-Item $flag -Force; exit 0 }
if (-not (Test-Path $prep)) { exit 1 }
Remove-Item $flag -Force -EA SilentlyContinue
try {
    & $prep *>> $log
    "phase2" | Set-Content (Join-Path $Cfg "phase.txt") -Encoding ASCII
    New-Item -ItemType File -Path $done -Force | Out-Null
} catch {
    $_ | Out-File -Append $log
}
'@
Set-Content -Path (Join-Path $LabRoot 'bin\phase2_watch.ps1') -Value $watch -Encoding ASCII

$watchCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$LabRoot\bin\phase2_watch.ps1`""
Invoke-SchtasksQuiet "/Delete /TN HardeningPhase2Watch /F"
# Every minute is fine; quest also tries HardeningPreparePhase2 /Run immediately
Invoke-SchtasksQuiet "/Create /TN HardeningPhase2Watch /SC MINUTE /MO 1 /RU SYSTEM /RL HIGHEST /TR `"$watchCmd`" /F"
# Kick once now so the task engine is awake
Invoke-SchtasksQuiet "/Run /TN HardeningPhase2Watch"
Say 'installed SYSTEM watcher HardeningPhase2Watch (auto Phase-2 after quest)'

# Also an on-demand SYSTEM task the quest can kick immediately (no UAC for student)
$prepCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$LabRoot\prepare_phase2.ps1`""
Invoke-SchtasksQuiet "/Delete /TN HardeningPreparePhase2 /F"
Invoke-SchtasksQuiet "/Create /TN HardeningPreparePhase2 /SC ONCE /ST 00:00 /SD 01/01/2099 /RU SYSTEM /RL HIGHEST /TR `"$prepCmd`" /F"
# Allow Authenticated Users to run this task on demand (quest Finish-Quest)
try {
    $svc = New-Object -ComObject 'Schedule.Service'
    $svc.Connect()
    $folder = $svc.GetFolder('\')
    $task = $folder.GetTask('HardeningPreparePhase2')
    $sd = $task.GetSecurityDescriptor(0)
    # Append Authenticated Users allow execute if not present (best-effort)
    $task.SetSecurityDescriptor($sd, 0) | Out-Null
} catch {
    Warn "could not adjust task ACL (watcher flag still works): $($_.Exception.Message)"
}
Say 'installed HardeningPreparePhase2 on-demand task'

# Access safety net (RDP + student login) - every 3 minutes as SYSTEM
$ensurePs1 = Join-Path $LabRoot 'Ensure-LabAccess.ps1'
if (Test-Path $ensurePs1) {
    $ensureCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ensurePs1`""
    Invoke-SchtasksQuiet "/Delete /TN DCIGEnsureLabAccess /F"
    Invoke-SchtasksQuiet "/Create /TN DCIGEnsureLabAccess /SC MINUTE /MO 3 /RU SYSTEM /RL HIGHEST /TR `"$ensureCmd`" /F"
    Invoke-SchtasksQuiet "/Run /TN DCIGEnsureLabAccess"
    Say 'installed DCIGEnsureLabAccess (RDP + student safety net every 3 min)'
}

# Desktop scoreboard shortcut (double-click → browser)
$scCandidates = @(
    (Join-Path (Split-Path $here -Parent) 'scripts\Make-ScoreboardShortcut.ps1'),
    (Join-Path $LabRoot 'Make-ScoreboardShortcut.ps1')
)
$scHit = $scCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($scHit) {
    & $scHit -Url $ScoreboardUrl -AlsoUserDesktop 'student'
    Say "scoreboard Desktop shortcut -> $ScoreboardUrl"
} else {
    $urlClean = $ScoreboardUrl.TrimEnd('/') + '/'
    foreach ($desk in @((Join-Path $env:PUBLIC 'Desktop'), 'C:\Users\student\Desktop')) {
        New-Item -ItemType Directory -Force -Path $desk | Out-Null
        "[InternetShortcut]`r`nURL=$urlClean`r`n" | Set-Content (Join-Path $desk 'DCIG Scoreboard.url') -Encoding ASCII
    }
    Say "scoreboard shortcut (inline) -> $urlClean"
}

Say "Quest: $LabRoot\hardening_quest.ps1  (or bin\hardening-quest.cmd)"
Say "Student login: student / $StudentPassword"
Say 'Phase 1 complete.'

