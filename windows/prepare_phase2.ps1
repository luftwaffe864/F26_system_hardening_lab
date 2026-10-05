<#
================================================================================
 DCIG System Hardening - Windows Phase 2 prepare
 Auto-run after Windows quest. Plants Windows-native findings (not a Linux mirror).
================================================================================
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$LabRoot = 'C:\HardeningLab'
$Cfg     = Join-Path $LabRoot 'config'
$RunKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$ShareRoot = 'C:\Shares'
$UnquotedDir = 'C:\Program Files\Vendor Update'

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

Say "preparing Phase 2 findings (Windows-native, easy→hard) for Team $Team"

# Ensure plant accounts can be created if local policy is strict
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

Remove-Item (Join-Path $env:LOCALAPPDATA 'HardeningQuest') -Recurse -Force -EA SilentlyContinue

# Clear Phase-1 leftovers
Remove-ItemProperty -Path $RunKey -Name 'SysHealthUpdate' -EA SilentlyContinue
Get-Process -Name 'health_update' -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Remove-NetFirewallRule -DisplayName 'Remote Admin Support' -EA SilentlyContinue
Remove-Item 'C:\ProgramData\SysHealth' -Recurse -Force -EA SilentlyContinue
Remove-Item 'C:\Program Files\PCOptimizer Pro' -Recurse -Force -EA SilentlyContinue
try { Set-MpPreference -DisableRealtimeMonitoring $false -EA SilentlyContinue } catch {}

# ========== EASY ==========
# W2-02 Guest enabled (Windows built-in weak account)
try {
    $g = Get-LocalUser -Name 'Guest' -EA SilentlyContinue
    if ($g) { Enable-LocalUser -Name 'Guest' -EA SilentlyContinue }
} catch {}

# W2-09 leftover vendor account (different name/story than Linux)
$vendPass = ConvertTo-SecureString 'TempVendor1!' -AsPlainText -Force
if (-not (Get-LocalUser -Name 'tempvendor' -EA SilentlyContinue)) {
    New-LocalUser -Name 'tempvendor' -Password $vendPass `
        -FullName 'Temp Vendor Access' -Description 'Remove after install' -PasswordNeverExpires | Out-Null
} else {
    Set-LocalUser -Name 'tempvendor' -Password $vendPass -PasswordNeverExpires $true
}

# W2-07 Sticky Keys IFEO debugger backdoor
$ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sethc.exe'
New-Item -Path $ifeo -Force | Out-Null
New-ItemProperty -Path $ifeo -Name 'Debugger' -Value 'C:\Windows\System32\cmd.exe' -PropertyType String -Force | Out-Null

# W2-10 open SMB share with Everyone Full Control
New-Item -ItemType Directory -Force -Path $ShareRoot | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ShareRoot 'TeamDrop') | Out-Null
Set-Content (Join-Path $ShareRoot 'TeamDrop\readme.txt') -Value 'Lab drop share - lock this down' -Encoding ASCII
try { Remove-SmbShare -Name 'TeamDrop' -Force -EA SilentlyContinue } catch {}
New-SmbShare -Name 'TeamDrop' -Path (Join-Path $ShareRoot 'TeamDrop') -FullAccess 'Everyone' -EA SilentlyContinue | Out-Null

# W2-11 UAC disabled
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    -Name 'EnableLUA' -Value 0 -PropertyType DWord -Force | Out-Null

# ========== MEDIUM ==========
# W2-01 excess admin (contractor - not the Linux sysmaint/helpdesk names)
$cPass = ConvertTo-SecureString 'Contract2026!' -AsPlainText -Force
if (-not (Get-LocalUser -Name 'contractor' -EA SilentlyContinue)) {
    New-LocalUser -Name 'contractor' -Password $cPass -FullName 'Outside Contractor' -PasswordNeverExpires | Out-Null
} else {
    Set-LocalUser -Name 'contractor' -Password $cPass
}
Add-LocalGroupMember -Group 'Administrators' -Member 'contractor' -EA SilentlyContinue

# W2-03 RDP without Network Level Authentication
$rdp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
if (Test-Path $rdp) {
    New-ItemProperty -Path $rdp -Name 'UserAuthentication' -Value 0 -PropertyType DWord -Force | Out-Null
}
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0 -EA SilentlyContinue

# W2-05 odd inbound firewall allow (not the Linux listener ports)
Remove-NetFirewallRule -DisplayName 'Temp SNMP Access' -EA SilentlyContinue
New-NetFirewallRule -DisplayName 'Temp SNMP Access' -Direction Inbound `
    -Action Allow -Protocol UDP -LocalPort 161 -Profile Any -EA SilentlyContinue | Out-Null

# W2-06 Defender real-time off (Windows-specific core)
try { Set-MpPreference -DisableRealtimeMonitoring $true -EA SilentlyContinue } catch {}

# W2-08 AlwaysInstallElevated (both hives)
$instPol = 'SOFTWARE\Policies\Microsoft\Windows\Installer'
foreach ($root in @('HKLM:', 'HKCU:')) {
    $p = Join-Path $root $instPol
    New-Item -Path $p -Force | Out-Null
    New-ItemProperty -Path $p -Name 'AlwaysInstallElevated' -Value 1 -PropertyType DWord -Force | Out-Null
}

# W2-12 AutoAdminLogon with password in Winlogon (Windows-specific core)
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
New-ItemProperty -Path $wl -Name 'AutoAdminLogon' -Value '1' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $wl -Name 'DefaultUserName' -Value 'contractor' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $wl -Name 'DefaultPassword' -Value 'Contract2026!' -PropertyType String -Force | Out-Null

# W2-13 WDigest cleartext credential caching
$wd = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest'
New-Item -Path $wd -Force | Out-Null
New-ItemProperty -Path $wd -Name 'UseLogonCredential' -Value 1 -PropertyType DWord -Force | Out-Null

# W2-14 Remote Registry auto-start
Set-Service -Name 'RemoteRegistry' -StartupType Automatic -EA SilentlyContinue
Start-Service -Name 'RemoteRegistry' -EA SilentlyContinue

# ========== HARD ==========
# W2-04 anonymous / SAM enumeration too open
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' `
    -Name 'RestrictAnonymous' -Value 0 -PropertyType DWord -Force | Out-Null

# W2-15 weak LAN Manager authentication level
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' `
    -Name 'LmCompatibilityLevel' -Value 1 -PropertyType DWord -Force | Out-Null

# W2-16 WinRM allow unencrypted traffic
try {
    Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $true -Force -EA SilentlyContinue
} catch {
    # Fallback if WinRM provider path differs
    winrm set winrm/config/service '@{AllowUnencrypted="true"}' 2>$null | Out-Null
}

# W2-17 unquoted service path under Program Files
New-Item -ItemType Directory -Force -Path $UnquotedDir | Out-Null
$payload = Join-Path $UnquotedDir 'update.exe'
Copy-Item "$env:SystemRoot\System32\cmd.exe" $payload -Force
# Intentionally UNQUOTED ImagePath (space in Program Files\Vendor Update)
cmd /c "sc.exe stop VendorUpd >nul 2>&1"
cmd /c "sc.exe delete VendorUpd >nul 2>&1"
cmd /c 'sc.exe create VendorUpd binPath= C:\Program Files\Vendor Update\update.exe start= demand DisplayName= VendorUpdateHelper >nul 2>&1'

# W2-18 unauthorized auto-start service (Windows service abuse - not Linux systemd mirror name)
$svcDir = 'C:\ProgramData\PrintNotifyHelper'
New-Item -ItemType Directory -Force -Path $svcDir | Out-Null
$svcPs1 = Join-Path $svcDir 'run.ps1'
Set-Content $svcPs1 -Value 'while ($true) { Start-Sleep 60 }' -Encoding ASCII
$bin = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$svcPs1`""
cmd /c "sc.exe stop HLPrintHelp >nul 2>&1"
cmd /c "sc.exe delete HLPrintHelp >nul 2>&1"
cmd /c "sc.exe create HLPrintHelp binPath= `"$bin`" start= auto DisplayName= `"Print Notify Compatibility`" >nul 2>&1"
cmd /c "sc.exe start HLPrintHelp >nul 2>&1"

# W2-19 sensitive file on open share ACL (Everyone Full Control)
New-Item -ItemType Directory -Force -Path (Join-Path $ShareRoot 'HR') | Out-Null
$pay = Join-Path $ShareRoot 'HR\payroll.csv'
Set-Content $pay -Value "name,salary`r`nalice,90000`r`n" -Encoding ASCII
icacls $pay /grant Everyone:F | Out-Null

Set-Content (Join-Path $Cfg 'phase.txt') 'phase2'
New-Item -ItemType File -Path (Join-Path $Cfg 'phase2_auto_done.flag') -Force | Out-Null
Remove-Item (Join-Path $Cfg 'start_phase2.flag') -Force -EA SilentlyContinue

$agent = Join-Path $LabRoot 'score_agent.ps1'
if (-not (Test-Path $agent)) {
    $agent = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'score_agent.ps1'
    Copy-Item $agent (Join-Path $LabRoot 'score_agent.ps1') -Force -EA SilentlyContinue
}
cmd.exe /c "schtasks /Create /TN HardeningScoreAgent /SC MINUTE /MO 1 /RU SYSTEM /TR `"powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\HardeningLab\score_agent.ps1`" /F >nul 2>&1" | Out-Null

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
state about once a minute - you do NOT type answers into a prompt.

Windows-focused categories (easy → hard):
  - Built-in / leftover local accounts
  - Accessibility / Image File Execution Options abuse
  - Overly open SMB shares and file ACLs
  - UAC and AlwaysInstallElevated policy
  - Windows Defender real-time protection
  - RDP Network Level Authentication
  - AutoAdminLogon / secrets in Winlogon
  - WDigest credential caching
  - Remote Registry service
  - LSA anonymous / LM compatibility settings
  - WinRM encryption settings
  - Unquoted service paths and unexpected services

These are NOT the same plants as the Linux box - hunt Windows artifacts.

Keep RDP working: port 3389 stays allowed. Do not rename or delete the student account.

Mentors open the room scoreboard when the race starts.
"@ | Set-Content (Join-Path $LabRoot 'PHASE2.txt') -Encoding ASCII

$ensure = Join-Path $LabRoot 'Ensure-LabAccess.ps1'
if (Test-Path $ensure) {
    & $ensure
    Say 're-applied RDP/student access safety net'
}

Say 'Phase 2 prep complete.'
