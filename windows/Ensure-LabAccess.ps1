<#
================================================================================
 DCIG lab safety net - keep RDP + student login working during hardening.
 Run as SYSTEM (scheduled task). Re-applies access rules; does not remove scored plants.
================================================================================
#>
$ErrorActionPreference = 'SilentlyContinue'
$LabRoot = 'C:\HardeningLab'
$Cfg     = Join-Path $LabRoot 'config'
$PwFile  = Join-Path $Cfg 'student_password.txt'
$Student = 'student'

if (-not (Test-Path $PwFile)) { exit 0 }
$plain = (Get-Content $PwFile -Raw).Trim()
if ([string]::IsNullOrEmpty($plain)) { exit 0 }

$sec = ConvertTo-SecureString $plain -AsPlainText -Force

# --- student account ---------------------------------------------------------
if (-not (Get-LocalUser -Name $Student -EA SilentlyContinue)) {
    New-LocalUser -Name $Student -Password $sec -FullName 'DCIG Student' `
        -PasswordNeverExpires | Out-Null
} else {
    Set-LocalUser -Name $Student -Password $sec -PasswordNeverExpires $true | Out-Null
}
Enable-LocalUser -Name $Student -EA SilentlyContinue | Out-Null
cmd /c "net user $Student /passwordchg:no" | Out-Null
Add-LocalGroupMember -Group 'Administrators' -Member $Student -EA SilentlyContinue | Out-Null

# --- Remote Desktop ----------------------------------------------------------
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
    -Name 'fDenyTSConnections' -Value 0 -Force | Out-Null
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -EA SilentlyContinue | Out-Null

# Dedicated rule (re-created if deleted) - separate from scored "bad" rules
$rdpName = 'DCIG Lab RDP Access'
$existing = Get-NetFirewallRule -DisplayName $rdpName -EA SilentlyContinue
if (-not $existing) {
    New-NetFirewallRule -DisplayName $rdpName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort 3389 -Profile Any `
        -Description 'DCIG range - do not remove; keeps student RDP working' | Out-Null
} else {
    Enable-NetFirewallRule -DisplayName $rdpName -EA SilentlyContinue | Out-Null
    Set-NetFirewallRule -DisplayName $rdpName -Enabled True -Action Allow -EA SilentlyContinue | Out-Null
}

try {
    Set-Service -Name 'TermService' -StartupType Manual -EA SilentlyContinue | Out-Null
    Start-Service -Name 'TermService' -EA SilentlyContinue | Out-Null
} catch {}

# Repair logon only if userinit.exe itself was removed. Leave an extra comma-program
# in place: that is a scored Phase-2 finding, not a lockout.
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$ui = [string](Get-ItemProperty $wl -EA SilentlyContinue).Userinit
if ($ui -and $ui -notmatch '(?i)userinit\.exe') {
    Set-ItemProperty -Path $wl -Name 'Userinit' -Value 'C:\Windows\system32\userinit.exe,' | Out-Null
}

exit 0
