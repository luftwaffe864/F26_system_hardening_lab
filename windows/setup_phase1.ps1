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
    cmd /c "sc.exe stop SysCacheSvc >nul 2>&1"
    cmd /c "sc.exe delete SysCacheSvc >nul 2>&1"
    foreach ($d in @($Rogue, $Bloat, $LabRoot, 'C:\ProgramData\SysCache')) {
        if (Test-Path $d) { Remove-Item $d -Recurse -Force -EA SilentlyContinue }
    }
    foreach ($u in @('tempadmin','guestuser','jmiller','asmith','bjones','cwong')) {
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

# Clear prior quest progress + Phase-2 markers so mentors can re-test after re-apply
foreach ($qd in @(
    (Join-Path $env:LOCALAPPDATA 'HardeningQuest'),
    'C:\Users\student\AppData\Local\HardeningQuest'
)) {
    Remove-Item -LiteralPath $qd -Recurse -Force -EA SilentlyContinue
}
Remove-Item -Force -EA SilentlyContinue @(
    (Join-Path $Cfg 'phase2_auto_done.flag'),
    (Join-Path $Cfg 'start_phase2.flag'),
    (Join-Path $LabRoot 'PHASE2.txt')
)
Say 'reset quest progress + Phase-2 flags (ready for a fresh Phase 1 run)'

# copy scripts next to lab root if present beside this file
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($f in @('hardening_quest.ps1','prepare_phase2.ps1','score_agent.ps1','Ensure-LabAccess.ps1',
                 'Show-Scoreboard.ps1','Open-Scoreboard.ps1')) {
    $src = Join-Path $here $f
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $LabRoot $f) -Force
        Say "installed $f"
    }
}
# Keep shortcut helpers on the box for mentors / re-runs
foreach ($helper in @('Make-ScoreboardShortcut.ps1', 'Make-QuestShortcut.ps1')) {
    $scSrc = Join-Path (Split-Path $here -Parent) "scripts\$helper"
    if (Test-Path $scSrc) {
        Copy-Item $scSrc (Join-Path $LabRoot $helper) -Force
    }
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

# Range/ops accounts that existed before the lab: listed as authorized so students leave them alone.
# Lab-planted names (Phase 1 + Phase 2) and built-ins (SID -500/-501/-503/-504) are excluded.
$LabAccounts = @('student','tempadmin','guestuser','jmiller','asmith','bjones','cwong','tempvendor','contractor')
$adminSet = @(cmd /c 'net localgroup Administrators' 2>$null | ForEach-Object { $_.Trim().Split('\')[-1].ToLower() })
$rangeAdmins = @(); $rangeUsers = @()
foreach ($lu in (Get-LocalUser)) {
    if ($LabAccounts -contains $lu.Name.ToLower()) { continue }
    if ($lu.SID.Value -match '-(500|501|503|504)$') { continue }
    if (-not $lu.Enabled) { continue }
    if ($adminSet -contains $lu.Name.ToLower()) { $rangeAdmins += $lu.Name } else { $rangeUsers += $lu.Name }
}

# Account drills: authorized staff, one wrongly promoted to admin, two unapproved
# accounts, and a fired employee who was never deactivated.
foreach ($u in @(
    @{ Name='asmith';    Pass='Ledger2026!'; Fallback='Ledger2026!Aa'; Full='Alice Smith';         Desc='Accounting'; Admin=$false },
    @{ Name='bjones';    Pass='Sales2026!';  Fallback='Sales2026!Aa';  Full='Ben Jones';           Desc='Sales';      Admin=$true },
    @{ Name='cwong';     Pass='Front2026!';  Fallback='Front2026!Aa';  Full='Carol Wong';          Desc='Front desk'; Admin=$false },
    @{ Name='jmiller';   Pass='Summer2026!'; Fallback='Summer2026!Aa'; Full='Jordan Miller';       Desc='Sales';      Admin=$false },
    @{ Name='tempadmin'; Pass='Password1';   Fallback='Password1!Aa';  Full='Temp Admin';          Desc='';           Admin=$true },
    @{ Name='guestuser'; Pass='guest';       Fallback='GuestUser1!';   Full='Guest user';          Desc='';           Admin=$false }
)) {
    if (New-LabLocalUser -Name $u.Name -Password $u.Pass -FullName $u.Full -FallbackPassword $u.Fallback) {
        Enable-LocalUser -Name $u.Name -EA SilentlyContinue
        if ($u.Desc) { Set-LocalUser -Name $u.Name -Description $u.Desc -EA SilentlyContinue }
        Add-LocalGroupMember -Group 'Users' -Member $u.Name -EA SilentlyContinue
        if ($u.Admin) { Add-LocalGroupMember -Group 'Administrators' -Member $u.Name -EA SilentlyContinue }
        else { Remove-LocalGroupMember -Group 'Administrators' -Member $u.Name -EA SilentlyContinue }
    }
}
Say 'planted account drills (asmith/bjones/cwong authorized, tempadmin/guestuser/jmiller not)'

# Authorized list: who SHOULD exist. Unauthorized accounts are deliberately not named.
$adminLines = @('  Administrator    built-in - do not delete', '  student          lab account - do not change')
$adminLines += $rangeAdmins | ForEach-Object { '  {0,-16} range management - do not change' -f $_ }
$userLines = @(
    '  asmith           Alice Smith - Accounting',
    '  bjones           Ben Jones - Sales',
    '  cwong            Carol Wong - Front desk'
)
$userLines += $rangeUsers | ForEach-Object { '  {0,-16} range management - do not change' -f $_ }
$auth = @"
AUTHORIZED ACCOUNTS - $env:COMPUTERNAME (Team $Team)
Approved by IT. Any account not listed here is NOT authorized.

Administrators
$($adminLines -join "`r`n")

Standard users (must NOT be administrators)
$($userLines -join "`r`n")

Built-in Windows accounts (Administrator, Guest, DefaultAccount,
WDAGUtilityAccount) are system accounts - do not delete them.
Former employees under an HR hold may remain, but only if disabled.
"@
Set-Content -Path (Join-Path $LabRoot 'authorized_users.txt') -Value $auth -Encoding ASCII

$memo = @"
HR NOTICE - account action required

Employee:  Jordan Miller (username: jmiller)
Status:    Terminated - last day 2026-09-30
Action:    Disable the account now. Do NOT delete it - Legal needs it
           kept for 90 days.
"@
Set-Content -Path (Join-Path $LabRoot 'hr_memo.txt') -Value $memo -Encoding ASCII

# briefing
$brief = @"
DCIG System Hardening - Windows box
Hostname: $env:COMPUTERNAME
Team: $Team

Authorized accounts: C:\HardeningLab\authorized_users.txt
HR notices:          C:\HardeningLab\hr_memo.txt

Lab note: keep RDP (port 3389) working and do not change the student account.
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

# rogue auto-start service (PowerShell loop; SCM never sees it "start", which is fine for the drill)
$svcDir = 'C:\ProgramData\SysCache'
New-Item -ItemType Directory -Force -Path $svcDir | Out-Null
$svcPs1 = Join-Path $svcDir 'cache.ps1'
Set-Content $svcPs1 -Value 'while ($true) { Start-Sleep 60 }' -Encoding ASCII
cmd /c "sc.exe stop SysCacheSvc >nul 2>&1"
cmd /c "sc.exe delete SysCacheSvc >nul 2>&1"
Start-Sleep -Milliseconds 500
try {
    New-Service -Name 'SysCacheSvc' -DisplayName 'System Cache Service' -StartupType Automatic `
        -BinaryPathName "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$svcPs1`"" `
        -EA Stop | Out-Null
    Say 'planted rogue service SysCacheSvc'
} catch {
    Warn "could not create SysCacheSvc (close services.msc and re-run): $($_.Exception.Message)"
}

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

# helper launcher + Desktop icon (double-click starts quest; finish auto-runs Phase 2)
New-Item -ItemType Directory -Force -Path (Join-Path $LabRoot 'bin') | Out-Null
$launch = @"
@echo off
title DCIG Hardening Quest
cd /d "$LabRoot"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath (Join-Path `$PSHOME 'powershell.exe') -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$LabRoot\hardening_quest.ps1`"'"
"@
Set-Content -Path (Join-Path $LabRoot 'bin\hardening-quest.cmd') -Value $launch -Encoding ASCII

$questScCandidates = @(
    (Join-Path (Split-Path $here -Parent) 'scripts\Make-QuestShortcut.ps1'),
    (Join-Path $LabRoot 'Make-QuestShortcut.ps1')
)
$questSc = $questScCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($questSc) {
    Copy-Item $questSc (Join-Path $LabRoot 'Make-QuestShortcut.ps1') -Force
    & $questSc -LabRoot $LabRoot -AlsoUserDesktop 'student'
    Say 'Hardening Quest Desktop shortcut (Public + student)'
} else {
    foreach ($desk in @((Join-Path $env:PUBLIC 'Desktop'), 'C:\Users\student\Desktop')) {
        New-Item -ItemType Directory -Force -Path $desk | Out-Null
        Set-Content -Path (Join-Path $desk 'Hardening Quest.cmd') -Value $launch -Encoding ASCII
    }
    Say 'Hardening Quest Desktop .cmd (inline fallback)'
}

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

# IE Enhanced Security Configuration blocks the scoreboard in IE11 (admins + users; next logon)
foreach ($escId in @('{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}', '{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}')) {
    $escKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$escId"
    if (Test-Path $escKey) { Set-ItemProperty -Path $escKey -Name 'IsInstalled' -Value 0 -EA SilentlyContinue }
}

# Desktop scoreboard shortcut (double-click -> browser)
$scCandidates = @(
    (Join-Path (Split-Path $here -Parent) 'scripts\Make-ScoreboardShortcut.ps1'),
    (Join-Path $LabRoot 'Make-ScoreboardShortcut.ps1')
)
$scHit = $scCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($scHit) {
    & $scHit -Url $ScoreboardUrl -AlsoUserDesktop 'student' -LabRoot $LabRoot
    Say "scoreboard Desktop shortcut -> $ScoreboardUrl"
} else {
    $urlClean = $ScoreboardUrl.TrimEnd('/') + '/'
    foreach ($desk in @((Join-Path $env:PUBLIC 'Desktop'), 'C:\Users\student\Desktop')) {
        New-Item -ItemType Directory -Force -Path $desk | Out-Null
        "[InternetShortcut]`r`nURL=$urlClean`r`n" | Set-Content (Join-Path $desk 'DCIG Scoreboard.url') -Encoding ASCII
    }
    Say "scoreboard shortcut (inline) -> $urlClean"
}

Say "Quest: Desktop 'Hardening Quest' icon  (or $LabRoot\bin\hardening-quest.cmd)"
Say "Student login: student / $StudentPassword"
Say 'Phase 1 complete. Quest finish auto-starts Phase 2 (hardening race).'

