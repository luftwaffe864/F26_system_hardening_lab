<#
================================================================================
 DCIG System Hardening - Windows Phase 2 prepare
 Auto-run after Windows quest. Plants Windows-native findings (not a Linux mirror).
 25 findings across 5 difficulty tiers:
   8 Easy (5) + 7 Medium (10) + 5 Hard (15) + 3 Very Hard (20) + 2 Almost
   Impossible (25) = 295 points. IDs: WE1-8, WM1-7, WH1-5, WV1-3, WX1-2.
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
$HiddenTaskDir = 'C:\ProgramData\WindowsTelemetry'
$HiddenTaskName = 'WindowsHealthTelemetry'
$WmiFilterName = 'DCIGHealthFilter'
$WmiConsumerName = 'DCIGHealthConsumer'
$HiddenAdmin = 'support$'
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

Say "preparing Phase 2 findings (Windows-native, 5 tiers) for Team $Team"

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

# ============================================================================
# EASY  (8 x 5 pts)
# ============================================================================
Plant 'WE1' 'Guest account enabled' {
    Enable-LocalUser -Name 'Guest'
} { (Get-LocalUser -Name 'Guest').Enabled }

Plant 'WE2' 'leftover account tempvendor' {
    Set-LabUser 'tempvendor' 'TempVendor1!' 'Temp Vendor Access' 'Remove after install'
} { [bool](Get-LocalUser -Name 'tempvendor' -EA SilentlyContinue) }

Plant 'WE3' 'UAC disabled (EnableLUA=0)' {
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name 'EnableLUA' -Value 0 -PropertyType DWord -Force | Out-Null
} { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').EnableLUA -eq 0 }

Plant 'WE4' 'TeamDrop share, Everyone Full' {
    New-Item -ItemType Directory -Force -Path (Join-Path $ShareRoot 'TeamDrop') | Out-Null
    Set-Content (Join-Path $ShareRoot 'TeamDrop\readme.txt') -Value 'Lab drop share - lock this down' -Encoding ASCII
    if (Get-SmbShare -Name 'TeamDrop' -EA SilentlyContinue) { Remove-SmbShare -Name 'TeamDrop' -Force }
    New-SmbShare -Name 'TeamDrop' -Path (Join-Path $ShareRoot 'TeamDrop') -FullAccess 'Everyone' | Out-Null
} { [bool](Get-SmbShare -Name 'TeamDrop' -EA SilentlyContinue) }

Plant 'WE5' 'SMB signing not required' {
    # Phase 1 already drills Defender real-time — do not re-use that finding.
    Set-SmbServerConfiguration -RequireSecuritySignature $false -EnableSecuritySignature $false -Force
} { (Get-SmbServerConfiguration).RequireSecuritySignature -eq $false }

Plant 'WE6' 'Sticky Keys IFEO debugger' {
    $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sethc.exe'
    New-Item -Path $ifeo -Force | Out-Null
    New-ItemProperty -Path $ifeo -Name 'Debugger' -Value 'C:\Windows\System32\cmd.exe' -PropertyType String -Force | Out-Null
} { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sethc.exe').Debugger }

Plant 'WE7' 'legacy SMBv1 protocol enabled' {
    Set-SmbServerConfiguration -EnableSMB1Protocol $true -Force
} { (Get-SmbServerConfiguration).EnableSMB1Protocol -eq $true }

Plant 'WE8' 'Windows Firewall profiles turned OFF' {
    Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled False
} {
    $p = Get-NetFirewallProfile -Profile Domain, Private, Public -EA SilentlyContinue
    [bool](@($p | Where-Object { -not $_.Enabled }).Count -ge 1)
}

# ============================================================================
# MEDIUM  (7 x 10 pts)
# ============================================================================
Plant 'WM1' 'contractor in Administrators' {
    Set-LabUser 'contractor' 'Contract2026!' 'Outside Contractor' ''
    cmd /c 'net localgroup Administrators contractor /add >nul 2>&1' | Out-Null
} { [bool]((cmd /c 'net localgroup Administrators') -match '(^|\\)contractor\s*$') }

Plant 'WM2' 'RDP without Network Level Authentication' {
    $rdp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    New-ItemProperty -Path $rdp -Name 'UserAuthentication' -Value 0 -PropertyType DWord -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
} { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp').UserAuthentication -eq 0 }

Plant 'WM3' 'firewall rule Temp SNMP Access (UDP 161)' {
    Remove-NetFirewallRule -DisplayName 'Temp SNMP Access' -EA SilentlyContinue
    New-NetFirewallRule -DisplayName 'Temp SNMP Access' -Direction Inbound -Action Allow `
        -Protocol UDP -LocalPort 161 -Profile Any -Enabled True | Out-Null
} { [bool](Get-NetFirewallRule -DisplayName 'Temp SNMP Access' -EA SilentlyContinue) }

Plant 'WM4' 'AlwaysInstallElevated (HKLM + HKCU)' {
    foreach ($root in @('HKLM:', 'HKCU:')) {
        $p = "$root\SOFTWARE\Policies\Microsoft\Windows\Installer"
        New-Item -Path $p -Force | Out-Null
        New-ItemProperty -Path $p -Name 'AlwaysInstallElevated' -Value 1 -PropertyType DWord -Force | Out-Null
    }
} { (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer').AlwaysInstallElevated -eq 1 }

Plant 'WM5' 'Remote Registry set to Automatic' {
    Set-Service -Name 'RemoteRegistry' -StartupType Automatic
    Start-Service -Name 'RemoteRegistry' -EA SilentlyContinue
} { (Get-Service -Name 'RemoteRegistry').StartType -eq 'Automatic' }

Plant 'WM6' 'WDigest cleartext credential caching' {
    $wd = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest'
    New-Item -Path $wd -Force | Out-Null
    New-ItemProperty -Path $wd -Name 'UseLogonCredential' -Value 1 -PropertyType DWord -Force | Out-Null
} { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest').UseLogonCredential -eq 1 }

Plant 'WM7' 'LLMNR enabled (EnableMulticast=1)' {
    $dns = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'
    New-Item -Path $dns -Force | Out-Null
    New-ItemProperty -Path $dns -Name 'EnableMulticast' -Value 1 -PropertyType DWord -Force | Out-Null
} { (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient').EnableMulticast -eq 1 }

# ============================================================================
# HARD  (5 x 15 pts)
# ============================================================================
Plant 'WH1' 'RestrictAnonymous = 0' {
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' `
        -Name 'RestrictAnonymous' -Value 0 -PropertyType DWord -Force | Out-Null
} { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa').RestrictAnonymous -eq 0 }

Plant 'WH2' 'weak LmCompatibilityLevel = 1' {
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' `
        -Name 'LmCompatibilityLevel' -Value 1 -PropertyType DWord -Force | Out-Null
} { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa').LmCompatibilityLevel -eq 1 }

Plant 'WH3' 'WinRM AllowUnencrypted = true' {
    Start-Service -Name 'WinRM' -EA SilentlyContinue
    try {
        Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $true -Force
    } catch {
        cmd /c "winrm set winrm/config/service @{AllowUnencrypted=`"true`"} >nul 2>&1" | Out-Null
    }
} {
    $v = $null
    try { $v = (Get-Item WSMan:\localhost\Service\AllowUnencrypted).Value } catch { }
    if ($null -eq $v) {
        $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Service' -EA SilentlyContinue).allow_unencrypted
    }
    "$v" -match '^(true|1)$'
}

Plant 'WH4' 'payroll.csv with Everyone Full Control' {
    New-Item -ItemType Directory -Force -Path (Join-Path $ShareRoot 'HR') | Out-Null
    $pay = Join-Path $ShareRoot 'HR\payroll.csv'
    Set-Content $pay -Value "name,salary`r`nalice,90000`r`n" -Encoding ASCII
    cmd /c "icacls `"$pay`" /grant Everyone:F >nul 2>&1" | Out-Null
} { Test-Path (Join-Path $ShareRoot 'HR\payroll.csv') }

Plant 'WH5' 'AutoAdminLogon with password in Winlogon' {
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    New-ItemProperty -Path $wl -Name 'AutoAdminLogon' -Value '1' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $wl -Name 'DefaultUserName' -Value 'contractor' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $wl -Name 'DefaultPassword' -Value 'Contract2026!' -PropertyType String -Force | Out-Null
} { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').DefaultPassword }

# ============================================================================
# VERY HARD  (3 x 20 pts)
# ============================================================================
Plant 'WV1' 'unquoted service path VendorUpd' {
    New-Item -ItemType Directory -Force -Path $UnquotedDir | Out-Null
    Copy-Item "$env:SystemRoot\System32\cmd.exe" (Join-Path $UnquotedDir 'update.exe') -Force
    cmd /c "sc.exe stop VendorUpd >nul 2>&1"
    cmd /c "sc.exe delete VendorUpd >nul 2>&1"
    Start-Sleep -Milliseconds 500
    cmd /c 'sc.exe create VendorUpd binPath= "C:\Program Files\Vendor Update\update.exe" start= demand DisplayName= VendorUpdateHelper >nul 2>&1' | Out-Null
    # sc.exe keeps the quotes above; rewrite ImagePath unquoted on purpose
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\VendorUpd' -Name 'ImagePath' `
        -Value 'C:\Program Files\Vendor Update\update.exe'
} { [bool](Get-Service -Name 'VendorUpd' -EA SilentlyContinue) }

Plant 'WV2' 'rogue auto-start service HLPrintHelp' {
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

Plant 'WV3' 'hidden scheduled task persistence' {
    New-Item -ItemType Directory -Force -Path $HiddenTaskDir | Out-Null
    $taskPs1 = Join-Path $HiddenTaskDir 'health.ps1'
    Set-Content $taskPs1 -Value 'Start-Sleep -Seconds 1; exit 0' -Encoding ASCII
    cmd /c "schtasks /Delete /TN $HiddenTaskName /F >nul 2>&1" | Out-Null
    $tr = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$taskPs1`""
    cmd.exe /c "schtasks /Create /TN $HiddenTaskName /SC ONLOGON /RU SYSTEM /RL HIGHEST /TR `"$tr`" /F >nul 2>&1" | Out-Null
} { cmd /c "schtasks /Query /TN $HiddenTaskName >nul 2>&1"; $LASTEXITCODE -eq 0 }

# ============================================================================
# ALMOST IMPOSSIBLE  (2 x 25 pts)
# ============================================================================
Plant 'WX1' 'WMI permanent event subscription persistence' {
    $ns = 'root\subscription'
    # Remove any prior lab objects so re-runs stay clean (no duplicate bindings).
    Get-CimInstance -Namespace $ns -ClassName __FilterToConsumerBinding -EA SilentlyContinue |
        Where-Object { $_.Filter -match $WmiFilterName -or $_.Consumer -match $WmiConsumerName } |
        Remove-CimInstance -EA SilentlyContinue
    Get-CimInstance -Namespace $ns -ClassName __EventFilter -EA SilentlyContinue |
        Where-Object { $_.Name -eq $WmiFilterName } | Remove-CimInstance -EA SilentlyContinue
    Get-CimInstance -Namespace $ns -ClassName CommandLineEventConsumer -EA SilentlyContinue |
        Where-Object { $_.Name -eq $WmiConsumerName } | Remove-CimInstance -EA SilentlyContinue

    $query = "SELECT * FROM __InstanceModificationEvent WITHIN 600 WHERE TargetInstance ISA 'Win32_PerfFormattedData_PerfOS_System'"
    $filter = Set-WmiInstance -Namespace $ns -Class __EventFilter -Arguments @{
        Name = $WmiFilterName; EventNamespace = 'root\cimv2'; QueryLanguage = 'WQL'; Query = $query
    }
    $consumer = Set-WmiInstance -Namespace $ns -Class CommandLineEventConsumer -Arguments @{
        Name = $WmiConsumerName; CommandLineTemplate = 'cmd.exe /c exit'
    }
    Set-WmiInstance -Namespace $ns -Class __FilterToConsumerBinding -Arguments @{
        Filter = $filter; Consumer = $consumer
    } | Out-Null
} {
    [bool](Get-CimInstance -Namespace 'root\subscription' -ClassName __EventFilter -EA SilentlyContinue |
        Where-Object { $_.Name -eq $WmiFilterName })
}

Plant 'WX2' 'hidden administrator account support$' {
    cmd /c "net user `"$HiddenAdmin`" `"Sup3rSecret!1`" /add >nul 2>&1" | Out-Null
    Set-LocalUser -Name $HiddenAdmin -PasswordNeverExpires $true -EA SilentlyContinue
    Enable-LocalUser -Name $HiddenAdmin -EA SilentlyContinue
    cmd /c "net localgroup Administrators `"$HiddenAdmin`" /add >nul 2>&1" | Out-Null
} { [bool](Get-LocalUser -Name $HiddenAdmin -EA SilentlyContinue) }

# ---- score agent (ALWAYS overwrite so Phase-2 finding updates actually deploy) ----
$agent = Join-Path $LabRoot 'score_agent.ps1'
$src = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'score_agent.ps1'
if (Test-Path $src) {
    Copy-Item $src $agent -Force
} elseif (-not (Test-Path $agent)) {
    Write-Host '[phase2-win] WARNING: score_agent.ps1 source missing; cannot deploy agent' -ForegroundColor Yellow
}
Plant 'AGENT' 'HardeningScoreAgent task (every minute)' {
    cmd.exe /c "schtasks /Create /TN HardeningScoreAgent /SC MINUTE /MO 1 /RU SYSTEM /TR `"powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\HardeningLab\score_agent.ps1`" /F >nul 2>&1" | Out-Null
} { cmd /c 'schtasks /Query /TN HardeningScoreAgent >nul 2>&1'; $LASTEXITCODE -eq 0 }

# ---- Desktop briefing: everything students need for the race ----
$LabAccounts = @('student','tempadmin','guestuser','jmiller','asmith','bjones','cwong','tempvendor','contractor','support$')
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
  Find and fix 25 planted security problems on this machine. A score agent
  checks the machine about once a minute and awards points on its own - there
  is nothing to type in. Watch your points on the Desktop "DCIG Scoreboard".

SCORING  (25 findings, 295 points total)
  8 Easy (5 ea)   7 Medium (10 ea)   5 Hard (15 ea)
  3 Very Hard (20 ea)   2 Almost Impossible (25 ea)
  Harder tiers are deliberately better hidden - persistence, odd locations,
  and fixes that take more than one step.

RULES
  - Keep Remote Desktop working: leave port 3389 and the
    'DCIG Lab RDP Access' firewall rule alone.
  - Do not rename, disable, or delete the student account.
  - Do not delete any authorized account listed below.
  - Leave the lab scheduled tasks named Hardening* and DCIG* alone - they run
    the scoring agent and the access safety net.

AUTHORIZED ACCOUNTS  (any account not listed here is NOT authorized)
  Administrators
$($adminLines -join "`r`n")
  Standard users (must NOT be administrators)
$($userLines -join "`r`n")
  Built-in accounts (Guest, DefaultAccount, WDAGUtilityAccount) stay on the
  system, but they must not be usable.

WHAT TO HUNT FOR  (easy -> almost impossible)
  - Accounts that should not exist, are enabled, or are admins (watch for
    hidden accounts that do not show up in a casual listing)
  - SMB message signing required
  - User Account Control (UAC)
  - Legacy protocols (SMBv1) and the host firewall being off
  - Overly open file shares and file permissions
  - Accessibility tools hijacked for a login-screen backdoor
  - Remote Desktop security (Network Level Authentication)
  - Firewall rules that open unexpected ports
  - Name resolution (LLMNR) left on
  - Auto-logon with a stored password
  - Credential caching and old authentication settings
  - Remote management services and their encryption
  - Services that are unexpected or have unsafe paths
  - Installer policies that grant admin rights
  - Hidden persistence: scheduled tasks, WMI event subscriptions

USEFUL TOOLS  (Start > Run, or Win+R)
  lusrmgr.msc   users and groups        services.msc   services
  wf.msc        firewall                fsmgmt.msc     shared folders
  regedit       registry                secpol.msc     local security policy
  taskschd.msc  scheduled tasks         Windows Security (Start menu)
  PowerShell:   Get-LocalUser  Get-WmiObject -Namespace root\subscription *
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
