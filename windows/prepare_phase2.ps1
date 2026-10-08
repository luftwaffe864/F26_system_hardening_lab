<#
================================================================================
 DCIG System Hardening - Windows Phase 2 prepare
 Auto-run after Windows quest. Plants Windows-native findings (not a Linux mirror).
 Every plant is independent and verified; results go to
 C:\HardeningLab\phase2-status.txt so mentors can see what landed.
================================================================================
#>
[CmdletBinding()]
param()

# One failed plant must never stop the rest (or leave the box half in Phase 2).
$ErrorActionPreference = 'Continue'
$LabRoot = 'C:\HardeningLab'
$Cfg     = Join-Path $LabRoot 'config'
$RunKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$ShareRoot = 'C:\Shares'
$UnquotedDir = 'C:\Program Files\Vendor Update'
$PubDesk = Join-Path $env:PUBLIC 'Desktop'
$StatusFile = Join-Path $LabRoot 'phase2-status.txt'

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

$script:Results = New-Object System.Collections.ArrayList
"Phase 2 prep started $(Get-Date -Format s) on $env:COMPUTERNAME (Team $Team)" | Set-Content $StatusFile -Encoding ASCII

# Runs one plant, then its Verify block; records OK/FAIL either way.
function Plant([string]$Id, [string]$Desc, [scriptblock]$Do, [scriptblock]$Verify) {
    $ok = $false; $why = ''
    try {
        $ErrorActionPreference = 'Stop'
        & $Do | Out-Null
        $ok = if ($Verify) { [bool](& $Verify) } else { $true }
        if (-not $ok) { $why = 'verify failed' }
    } catch { $why = $_.Exception.Message }
    $line = if ($ok) { "OK    $Id  $Desc" } else { "FAIL  $Id  $Desc  ($why)" }
    [void]$script:Results.Add($line)
    Add-Content $StatusFile $line -Encoding ASCII
    if ($ok) { Say $line } else { Write-Host "[phase2-win] $line" -ForegroundColor Yellow }
    if ($ok -and $Id -ne 'AGENT') {
        $pdir = Join-Path $LabRoot 'config\planted'
        New-Item -ItemType Directory -Force -Path $pdir | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $pdir $Id) | Out-Null
    }
}

function Invoke-StudentHive([scriptblock]$Do) {
    $sid = (New-Object System.Security.Principal.NTAccount('student')).Translate(
        [System.Security.Principal.SecurityIdentifier]).Value
    $loaded = $false
    if (-not (Test-Path "Registry::HKEY_USERS\$sid")) {
        $hive = 'C:\Users\student\NTUSER.DAT'
        if (-not (Test-Path $hive)) { return $null }
        & reg.exe load "HKU\$sid" $hive | Out-Null
        $loaded = $true
    }
    try { return & $Do $sid }
    finally { if ($loaded) { & reg.exe unload "HKU\$sid" | Out-Null } }
}

function Set-LabUser([string]$Name, [string]$Pass, [string]$Full, [string]$Desc) {
    $sec = ConvertTo-SecureString $Pass -AsPlainText -Force
    if (Get-LocalUser -Name $Name -EA SilentlyContinue) {
        Set-LocalUser -Name $Name -Password $sec -PasswordNeverExpires $true
    } else {
        New-LocalUser -Name $Name -Password $sec -FullName $Full -Description $Desc -PasswordNeverExpires | Out-Null
    }
    Enable-LocalUser -Name $Name
}

Say "preparing Phase 2 findings (Windows-native, easy->hard) for Team $Team"

# Plant accounts need weak-ish passwords to be accepted
try {
    net accounts /minpwlen:0 /maxpwage:unlimited /uniquepw:0 | Out-Null
    $inf = Join-Path $env:TEMP 'dcig_lab_secpol_p2.inf'
    $db  = Join-Path $env:TEMP 'dcig_lab_secpol_p2.sdb'
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
    Start-Process -FilePath 'secedit.exe' -ArgumentList "/configure /db `"$db`" /cfg `"$inf`" /areas SECURITYPOLICY" `
        -Wait -WindowStyle Hidden | Out-Null
} catch {}

# ---- clear Phase-1 leftovers (quest content must not bleed into the race) ----
Remove-ItemProperty -Path $RunKey -Name 'SysHealthUpdate' -EA SilentlyContinue
Get-Process -Name 'health_update' -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Remove-NetFirewallRule -DisplayName 'Remote Admin Support' -EA SilentlyContinue
Remove-Item 'C:\ProgramData\SysHealth', 'C:\Program Files\PCOptimizer Pro', 'C:\ProgramData\SysCache' -Recurse -Force -EA SilentlyContinue
cmd /c "sc.exe stop SysCacheSvc >nul 2>&1"
cmd /c "sc.exe delete SysCacheSvc >nul 2>&1"
foreach ($u in @('tempadmin', 'guestuser', 'jmiller')) { Remove-LocalUser -Name $u -EA SilentlyContinue }
Remove-LocalGroupMember -Group 'Administrators' -Member 'bjones' -EA SilentlyContinue
foreach ($f in @('hr_memo.txt', 'briefing.txt', 'authorized_users.txt')) {
    Remove-Item (Join-Path $PubDesk $f) -Force -EA SilentlyContinue
}
Remove-Item (Join-Path $LabRoot 'hr_memo.txt') -Force -EA SilentlyContinue
Remove-Item (Join-Path $LabRoot 'score_state') -Recurse -Force -EA SilentlyContinue
Remove-Item (Join-Path $Cfg 'planted') -Recurse -Force -EA SilentlyContinue
# UAC-off needs a reboot and is no longer scored; put it back
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA' -Value 1 -EA SilentlyContinue
try { Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $false -Force -EA SilentlyContinue } catch {}

# ========== EASY (5) ==========
Plant 'WE-01' 'Guest account enabled' {
    Enable-LocalUser -Name 'Guest'
} { (Get-LocalUser -Name 'Guest').Enabled }

Plant 'WE-02' 'leftover account tempvendor' {
    Set-LabUser 'tempvendor' 'TempVendor1!' 'Temp Vendor Access' 'Remove after install'
} { [bool](Get-LocalUser -Name 'tempvendor' -EA SilentlyContinue) }

Plant 'WE-03' 'all-users Startup script' {
    $dir = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Content (Join-Path $dir 'CouponHelper.bat') -Value "@echo off`r`n" -Encoding ASCII
} { Test-Path (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\CouponHelper.bat') }

Plant 'WE-04' 'TeamDrop share, Everyone Full' {
    New-Item -ItemType Directory -Force -Path (Join-Path $ShareRoot 'TeamDrop') | Out-Null
    Set-Content (Join-Path $ShareRoot 'TeamDrop\readme.txt') -Value 'Lab drop share - lock this down' -Encoding ASCII
    if (Get-SmbShare -Name 'TeamDrop' -EA SilentlyContinue) { Remove-SmbShare -Name 'TeamDrop' -Force }
    New-SmbShare -Name 'TeamDrop' -Path (Join-Path $ShareRoot 'TeamDrop') -FullAccess 'Everyone' | Out-Null
} { [bool](Get-SmbShare -Name 'TeamDrop' -EA SilentlyContinue) }

Plant 'WE-05' 'plaintext passwords in Public Documents' {
    $doc = Join-Path $env:PUBLIC 'Documents'
    New-Item -ItemType Directory -Force -Path $doc | Out-Null
    Set-Content (Join-Path $doc 'passwords.txt') -Value "wifi Winter2024!`r`nvpn TeamVPN`r`n" -Encoding ASCII
} { Test-Path (Join-Path $env:PUBLIC 'Documents\passwords.txt') }

Plant 'WE-06' 'hosts file extra line' {
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (-not (Select-String -Path $hosts -Pattern 'dcig-lab-plant' -Quiet -EA SilentlyContinue)) {
        Add-Content -Path $hosts -Value '10.255.255.254 intranet.dcig.lab # dcig-lab-plant' -Encoding ASCII
    }
} { [bool](Select-String -Path (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts') -Pattern 'dcig-lab-plant' -Quiet -EA SilentlyContinue) }

Plant 'WE-07' 'firewall rule Allow Remote Debug (TCP 9000)' {
    Remove-NetFirewallRule -DisplayName 'Temp SNMP Access' -EA SilentlyContinue
    Remove-NetFirewallRule -DisplayName 'Allow Remote Debug' -EA SilentlyContinue
    New-NetFirewallRule -DisplayName 'Allow Remote Debug' -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort 9000 -Profile Any -Enabled True | Out-Null
} { [bool](Get-NetFirewallRule -DisplayName 'Allow Remote Debug' -EA SilentlyContinue) }

Plant 'WE-08' 'CouponPrinter folder' {
    $dir = 'C:\Program Files\CouponPrinter'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Content (Join-Path $dir 'readme.txt') -Value 'Delete this program.' -Encoding ASCII
} { Test-Path 'C:\Program Files\CouponPrinter' }

# ========== MEDIUM (10) ==========
Plant 'WM-01' 'contractor in Administrators' {
    Set-LabUser 'contractor' 'Contract2026!' 'Outside Contractor' ''
    cmd /c 'net localgroup Administrators contractor /add >nul 2>&1' | Out-Null
} { [bool]((cmd /c 'net localgroup Administrators') -match '(^|\\)contractor\s*$') }

Plant 'WM-02' 'RDP without Network Level Authentication' {
    $rdp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    New-ItemProperty -Path $rdp -Name 'UserAuthentication' -Value 0 -PropertyType DWord -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
} { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp').UserAuthentication -eq 0 }

Plant 'WM-03' 'Defender real-time protection OFF' {
    Set-MpPreference -DisableRealtimeMonitoring $true
    Start-Sleep -Seconds 3
} { (Get-MpPreference).DisableRealtimeMonitoring -eq $true }

Plant 'WM-04' 'AlwaysInstallElevated (machine + student)' {
    $p = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer'
    New-Item -Path $p -Force | Out-Null
    New-ItemProperty -Path $p -Name 'AlwaysInstallElevated' -Value 1 -PropertyType DWord -Force | Out-Null
    Invoke-StudentHive {
        param($sid)
        $sp = "Registry::HKEY_USERS\$sid\SOFTWARE\Policies\Microsoft\Windows\Installer"
        New-Item -Path $sp -Force | Out-Null
        New-ItemProperty -Path $sp -Name 'AlwaysInstallElevated' -Value 1 -PropertyType DWord -Force | Out-Null
    } | Out-Null
} {
    $hk = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer' -EA SilentlyContinue).AlwaysInstallElevated
    $cu = Invoke-StudentHive {
        param($sid)
        (Get-ItemProperty "Registry::HKEY_USERS\$sid\SOFTWARE\Policies\Microsoft\Windows\Installer" -EA SilentlyContinue).AlwaysInstallElevated
    }
    ($hk -eq 1) -and ($cu -eq 1)
}

Plant 'WM-05' 'AutoAdminLogon with password in Winlogon' {
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    New-ItemProperty -Path $wl -Name 'AutoAdminLogon' -Value '1' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $wl -Name 'DefaultUserName' -Value 'contractor' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $wl -Name 'DefaultPassword' -Value 'Contract2026!' -PropertyType String -Force | Out-Null
} { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').DefaultPassword }

Plant 'WM-06' 'Remote Registry set to Automatic' {
    Set-Service -Name 'RemoteRegistry' -StartupType Automatic
    Start-Service -Name 'RemoteRegistry' -EA SilentlyContinue
} { (Get-Service -Name 'RemoteRegistry').StartType -eq 'Automatic' }

Plant 'WM-07' 'payroll.csv with Everyone Full Control' {
    New-Item -ItemType Directory -Force -Path (Join-Path $ShareRoot 'HR') | Out-Null
    $pay = Join-Path $ShareRoot 'HR\payroll.csv'
    Set-Content $pay -Value "name,salary`r`nalice,90000`r`n" -Encoding ASCII
    cmd /c "icacls `"$pay`" /grant Everyone:F >nul 2>&1" | Out-Null
} { Test-Path (Join-Path $ShareRoot 'HR\payroll.csv') }

# ========== HARD (15) ==========
Plant 'WH-01' 'WDigest cleartext credential caching' {
    $wd = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest'
    New-Item -Path $wd -Force | Out-Null
    New-ItemProperty -Path $wd -Name 'UseLogonCredential' -Value 1 -PropertyType DWord -Force | Out-Null
} { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest').UseLogonCredential -eq 1 }

Plant 'WH-02' 'RestrictAnonymous = 0' {
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' `
        -Name 'RestrictAnonymous' -Value 0 -PropertyType DWord -Force | Out-Null
} { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa').RestrictAnonymous -eq 0 }

Plant 'WH-03' 'weak LmCompatibilityLevel = 1' {
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' `
        -Name 'LmCompatibilityLevel' -Value 1 -PropertyType DWord -Force | Out-Null
} { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa').LmCompatibilityLevel -eq 1 }

Plant 'WH-04' 'unquoted service path VendorUpd' {
    New-Item -ItemType Directory -Force -Path $UnquotedDir | Out-Null
    Copy-Item "$env:SystemRoot\System32\cmd.exe" (Join-Path $UnquotedDir 'update.exe') -Force
    cmd /c "sc.exe stop VendorUpd >nul 2>&1"
    cmd /c "sc.exe delete VendorUpd >nul 2>&1"
    Start-Sleep -Milliseconds 500
    cmd /c 'sc.exe create VendorUpd binPath= "C:\Program Files\Vendor Update\update.exe" start= demand DisplayName= VendorUpdateHelper >nul 2>&1' | Out-Null
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\VendorUpd' -Name 'ImagePath' `
        -Value 'C:\Program Files\Vendor Update\update.exe'
} { [bool](Get-Service -Name 'VendorUpd' -EA SilentlyContinue) }

Plant 'WH-05' 'rogue auto-start service HLPrintHelp' {
    $svcDir = 'C:\ProgramData\PrintNotifyHelper'
    New-Item -ItemType Directory -Force -Path $svcDir | Out-Null
    $svcPs1 = Join-Path $svcDir 'run.ps1'
    Set-Content $svcPs1 -Value 'while ($true) { Start-Sleep 60 }' -Encoding ASCII
    cmd /c "sc.exe stop HLPrintHelp >nul 2>&1"
    cmd /c "sc.exe delete HLPrintHelp >nul 2>&1"
    Start-Sleep -Milliseconds 500
    New-Service -Name 'HLPrintHelp' -DisplayName 'Print Notify Compatibility' -StartupType Automatic `
        -BinaryPathName "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$svcPs1`"" | Out-Null
    cmd /c "sc.exe start HLPrintHelp >nul 2>&1"
} { (Get-Service -Name 'HLPrintHelp' -EA SilentlyContinue).StartType -eq 'Automatic' }

# ========== VERY HARD (20) ==========
Plant 'WV-01' 'scheduled task disguised as maintenance' {
    $dir = 'C:\ProgramData\Microsoft\Cache'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Content (Join-Path $dir 'clean.ps1') -Value 'Start-Sleep -Seconds 2' -Encoding ASCII
    $tr = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dir\clean.ps1`""
    cmd /c "schtasks /Delete /TN `"\Microsoft\Windows\Maintenance\CacheCleanup`" /F >nul 2>&1"
    cmd /c "schtasks /Create /TN `"\Microsoft\Windows\Maintenance\CacheCleanup`" /SC HOURLY /RU SYSTEM /TR `"$tr`" /F >nul 2>&1"
    if (-not (Get-ScheduledTask -TaskName 'CacheCleanup' -EA SilentlyContinue)) {
        cmd /c "schtasks /Create /TN CacheCleanup /SC HOURLY /RU SYSTEM /TR `"$tr`" /F >nul 2>&1"
    }
} { [bool](Get-ScheduledTask -TaskName 'CacheCleanup' -EA SilentlyContinue) }

Plant 'WV-02' 'extra program on Winlogon Userinit' {
    Copy-Item "$env:SystemRoot\System32\hostname.exe" 'C:\ProgramData\updater.exe' -Force
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    New-ItemProperty -Path $wl -Name 'Userinit' -PropertyType String -Force `
        -Value 'C:\Windows\system32\userinit.exe,C:\ProgramData\updater.exe' | Out-Null
} { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').Userinit -match 'updater\.exe' }

Plant 'WV-03' 'anonymous null sessions allowed' {
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' `
        -Name 'RestrictNullSessAccess' -Value 0 -PropertyType DWord -Force | Out-Null
} { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters').RestrictNullSessAccess -eq 0 }

# ========== ALMOST IMPOSSIBLE (25) ==========
Plant 'WI-01' 'Magnifier IFEO debugger (not Sticky Keys)' {
    $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\magnify.exe'
    New-Item -Path $ifeo -Force | Out-Null
    New-ItemProperty -Path $ifeo -Name 'Debugger' -Value 'C:\Windows\System32\cmd.exe' -PropertyType String -Force | Out-Null
} { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\magnify.exe').Debugger }

Plant 'WI-02' 'local Group Policy machine startup script' {
    $dir = Join-Path $env:SystemRoot 'System32\GroupPolicy\Machine\Scripts\Startup'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Content (Join-Path $dir 'lab-sync.bat') -Value "@echo off`r`n" -Encoding ASCII
    $ini = Join-Path $env:SystemRoot 'System32\GroupPolicy\Machine\Scripts\scripts.ini'
    @"
[Startup]
0CmdLine=lab-sync.bat
0Parameters=
"@ | Set-Content -Path $ini -Encoding ASCII
} { [bool](Select-String -Path (Join-Path $env:SystemRoot 'System32\GroupPolicy\Machine\Scripts\scripts.ini') -Pattern 'lab-sync' -Quiet -EA SilentlyContinue) }

# ---- score agent ----
$agent = Join-Path $LabRoot 'score_agent.ps1'
if (-not (Test-Path $agent)) {
    $src = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'score_agent.ps1'
    Copy-Item $src $agent -Force -EA SilentlyContinue
}
Plant 'AGENT' 'HardeningScoreAgent task (every minute)' {
    cmd.exe /c "schtasks /Create /TN HardeningScoreAgent /SC MINUTE /MO 1 /RU SYSTEM /TR `"powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\HardeningLab\score_agent.ps1`" /F >nul 2>&1" | Out-Null
} { cmd /c 'schtasks /Query /TN HardeningScoreAgent >nul 2>&1'; $LASTEXITCODE -eq 0 }

# ---- Desktop briefing: everything students need for the race ----
$LabAccounts = @('student','tempadmin','guestuser','jmiller','asmith','bjones','cwong','tempvendor','contractor')
$adminSet = @(cmd /c 'net localgroup Administrators' 2>$null | ForEach-Object { $_.Trim().Split('\')[-1].ToLower() })
$rangeAdmins = @(); $rangeUsers = @()
foreach ($lu in (Get-LocalUser)) {
    if ($LabAccounts -contains $lu.Name.ToLower()) { continue }
    if ($lu.SID.Value -match '-(500|501|503|504)$') { continue }
    if (-not $lu.Enabled) { continue }
    if ($adminSet -contains $lu.Name.ToLower()) { $rangeAdmins += $lu.Name } else { $rangeUsers += $lu.Name }
}
$adminLines = @('    Administrator    built-in - do not delete', '    student          lab account - do not change')
$adminLines += $rangeAdmins | ForEach-Object { '    {0,-16} range management - do not change' -f $_ }
$userLines = @(
    '    asmith           Alice Smith - Accounting',
    '    bjones           Ben Jones - Sales',
    '    cwong            Carol Wong - Front desk'
)
$userLines += $rangeUsers | ForEach-Object { '    {0,-16} range management - do not change' -f $_ }

$phase2 = @"
DCIG SYSTEM HARDENING - PHASE 2 (Windows)
Host: $env:COMPUTERNAME     Team: $Team

GOAL
  25 findings. A score agent checks the machine about once a minute and
  awards points on its own - there is nothing to type in.
  Watch your points on the Desktop "DCIG Scoreboard".

  Easy               8 x  5 =  40
  Medium             7 x 10 =  70
  Hard               5 x 15 =  75
  Very hard          3 x 20 =  60
  Almost impossible  2 x 25 =  50
  This box max: 295

RULES
  - Keep Remote Desktop working: leave port 3389 and the
    'DCIG Lab RDP Access' firewall rule alone.
  - Do not rename, disable, or delete the student account.
  - Do not delete any authorized account listed below.

AUTHORIZED ACCOUNTS  (any account not listed here is NOT authorized)
  Administrators
$($adminLines -join "`r`n")
  Standard users (must NOT be administrators)
$($userLines -join "`r`n")
  Built-in accounts (Guest, DefaultAccount, WDAGUtilityAccount) stay on the
  system, but they must not be usable.

WHAT TO HUNT FOR
  - Accounts that should not exist, are enabled, or are administrators
  - The all-users Startup folder, scheduled tasks, and services
  - Programs that should not be installed, and plaintext password files
  - The hosts file
  - File shares and file permissions
  - Firewall rules that open unexpected ports
  - Antivirus real-time protection
  - Remote Desktop Network Level Authentication
  - Auto-logon and a stored password
  - Installer policy that lets a normal user install as admin
  - Credential caching, anonymous access, and old authentication settings
  - Service paths that are not quoted
  - Winlogon (what runs at logon)
  - Accessibility programs set to open a debugger
  - Local Group Policy startup scripts

USEFUL TOOLS  (Start > Run, or Win+R)
  lusrmgr.msc   users and groups        services.msc    services
  taskschd.msc  scheduled tasks         wf.msc          firewall
  fsmgmt.msc    shared folders          regedit         registry
  secpol.msc    local security policy   gpedit.msc      group policy
  notepad C:\Windows\System32\drivers\etc\hosts
  Windows Security (Start menu)

The Linux box is a different set of problems. A few ideas appear on both
(leftover accounts, too much privilege, a firewall hole, plaintext passwords,
something that starts by itself) because those matter on every system.
"@
$phase2 | Set-Content (Join-Path $LabRoot 'PHASE2.txt') -Encoding ASCII
Copy-Item (Join-Path $LabRoot 'PHASE2.txt') (Join-Path $PubDesk 'PHASE2.txt') -Force -EA SilentlyContinue

# ---- mark done (always, even if some plants failed) ----
Set-Content (Join-Path $Cfg 'phase.txt') 'phase2'
New-Item -ItemType File -Path (Join-Path $Cfg 'phase2_auto_done.flag') -Force | Out-Null
Remove-Item (Join-Path $Cfg 'start_phase2.flag') -Force -EA SilentlyContinue

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

$ensure = Join-Path $LabRoot 'Ensure-LabAccess.ps1'
if (Test-Path $ensure) {
    & $ensure
    Say 're-applied RDP/student access safety net'
}

$fails = @($script:Results | Where-Object { $_ -like 'FAIL*' }).Count
$summary = "Phase 2 prep finished $(Get-Date -Format s): $($script:Results.Count - $fails) OK, $fails FAIL"
Add-Content $StatusFile $summary -Encoding ASCII
Say $summary
