<#
================================================================================
 DCIG System Hardening - Windows score agent (Phase 2)
 Machine-state checks only - Windows-native findings (not a Linux mirror).
 25 findings / 295 pts:  8 Easy (5), 7 Medium (10), 5 Hard (15),
                         3 Very Hard (20), 2 Almost Impossible (25).
 Point values MUST match scoreboard/server.py (the board rejects mismatches).
================================================================================
#>
$ErrorActionPreference = 'SilentlyContinue'
$LabRoot = 'C:\HardeningLab'
$Cfg     = Join-Path $LabRoot 'config'
$State   = Join-Path $LabRoot 'score_state'
New-Item -ItemType Directory -Force -Path $State | Out-Null

$Team = (Get-Content (Join-Path $Cfg 'team.txt') -Raw).Trim()
$Secret = (Get-Content (Join-Path $Cfg 'secret.txt') -Raw).Trim()
$ScoreboardUrl = (Get-Content (Join-Path $Cfg 'scoreboard_url.txt') -Raw).Trim()
$OsName = 'windows'

function Get-Sig([string]$Fid, [int]$Pts) {
    $msg = "$Team|$OsName|$Fid|$Pts"
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [Text.Encoding]::UTF8.GetBytes($Secret)
    return (($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($msg)) | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Post-Finding([string]$Fid, [int]$Pts) {
    $marker = Join-Path $State "got_$Fid"
    if (Test-Path $marker) { return }
    $body = @{
        team = $Team
        os = $OsName
        finding_id = $Fid
        points = $Pts
        sig = (Get-Sig $Fid $Pts)
    } | ConvertTo-Json
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "$ScoreboardUrl/api/score" `
            -ContentType 'application/json' -Body $body -TimeoutSec 5
        if ($resp.ok) { New-Item -ItemType File -Path $marker -Force | Out-Null }
    } catch {}
}

function Test-FwGoneOrOff([string]$DisplayName) {
    $r = Get-NetFirewallRule -DisplayName $DisplayName -EA SilentlyContinue
    return (-not $r -or (@($r | Where-Object Enabled -eq 'True').Count -eq 0))
}

# Get-LocalGroupMember throws on orphaned SIDs on some Server 2019 builds; net.exe does not.
function Get-AdminNames {
    $out = cmd /c 'net localgroup Administrators' 2>$null
    $inList = $false
    foreach ($l in $out) {
        if ($l -match '^-{5,}') { $inList = $true; continue }
        if (-not $inList) { continue }
        if ($l -match '^The command completed') { break }
        if ($l.Trim()) { $l.Trim().Split('\')[-1].ToLower() }
    }
}

# ======================= EASY (5) =======================
# WE1 Guest disabled or removed
$guest = Get-LocalUser -Name 'Guest' -EA SilentlyContinue
if (($guest -and -not $guest.Enabled) -or (-not $guest)) { Post-Finding 'WE1' 5 }

# WE2 tempvendor removed
if (-not (Get-LocalUser -Name 'tempvendor' -EA SilentlyContinue)) { Post-Finding 'WE2' 5 }

# WE3 UAC re-enabled (EnableLUA = 1)
$lua = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -EA SilentlyContinue).EnableLUA
if ($lua -eq 1) { Post-Finding 'WE3' 5 }

# WE4 TeamDrop share gone or Everyone FullAccess removed
$share = Get-SmbShare -Name 'TeamDrop' -EA SilentlyContinue
if (-not $share) { Post-Finding 'WE4' 5 }
else {
    $access = Get-SmbShareAccess -Name 'TeamDrop' -EA SilentlyContinue
    $everyoneFull = $access | Where-Object {
        $_.AccountName -match 'Everyone' -and $_.AccessRight -eq 'Full' -and $_.AccessControlType -eq 'Allow'
    }
    if (-not $everyoneFull) { Post-Finding 'WE4' 5 }
}

# WE5 SMB signing required
$smbSign = (Get-SmbServerConfiguration -EA SilentlyContinue).RequireSecuritySignature
if ($null -ne $smbSign -and $smbSign -eq $true) { Post-Finding 'WE5' 5 }

# WE6 Sticky Keys IFEO debugger cleared
$ifeo = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sethc.exe' -EA SilentlyContinue
if (-not $ifeo -or [string]::IsNullOrEmpty([string]$ifeo.Debugger)) { Post-Finding 'WE6' 5 }

# WE7 SMBv1 disabled
$smb1 = (Get-SmbServerConfiguration -EA SilentlyContinue).EnableSMB1Protocol
if ($null -ne $smb1 -and $smb1 -eq $false) { Post-Finding 'WE7' 5 }

# WE8 Firewall re-enabled on all profiles
$prof = Get-NetFirewallProfile -Profile Domain, Private, Public -EA SilentlyContinue
if ($prof -and (@($prof | Where-Object { -not $_.Enabled }).Count -eq 0)) { Post-Finding 'WE8' 5 }

# ======================= MEDIUM (10) =======================
# WM1 contractor not admin / deleted
$con = Get-LocalUser -Name 'contractor' -EA SilentlyContinue
if (-not $con) { Post-Finding 'WM1' 10 }
elseif ((Get-AdminNames) -notcontains 'contractor') { Post-Finding 'WM1' 10 }

# WM2 RDP NLA required (UserAuthentication = 1)
$nla = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -EA SilentlyContinue).UserAuthentication
if ($nla -eq 1) { Post-Finding 'WM2' 10 }

# WM3 SNMP firewall hole closed
if (Test-FwGoneOrOff 'Temp SNMP Access') { Post-Finding 'WM3' 10 }

# WM4 AlwaysInstallElevated cleared in both hives (missing or 0)
$hk = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer' -EA SilentlyContinue).AlwaysInstallElevated
$cu = (Get-ItemProperty 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Installer' -EA SilentlyContinue).AlwaysInstallElevated
if (($null -eq $hk -or $hk -eq 0) -and ($null -eq $cu -or $cu -eq 0)) { Post-Finding 'WM4' 10 }

# WM5 Remote Registry not set to Automatic (Manual/Disabled is fine)
$rr = Get-Service -Name 'RemoteRegistry' -EA SilentlyContinue
if (-not $rr -or $rr.StartType -ne 'Automatic') { Post-Finding 'WM5' 10 }

# WM6 WDigest cleartext caching off
$wd = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' -EA SilentlyContinue).UseLogonCredential
if ($null -eq $wd -or $wd -eq 0) { Post-Finding 'WM6' 10 }

# WM7 LLMNR disabled (EnableMulticast = 0)
$llmnr = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -EA SilentlyContinue).EnableMulticast
if ($null -ne $llmnr -and $llmnr -eq 0) { Post-Finding 'WM7' 10 }

# ======================= HARD (15) =======================
# WH1 RestrictAnonymous hardened (>= 1)
$ra = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -EA SilentlyContinue).RestrictAnonymous
if ($null -ne $ra -and [int]$ra -ge 1) { Post-Finding 'WH1' 15 }

# WH2 LM compatibility not weak (>= 3)
$lm = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -EA SilentlyContinue).LmCompatibilityLevel
if ($null -ne $lm -and [int]$lm -ge 3) { Post-Finding 'WH2' 15 }

# WH3 WinRM does not allow unencrypted
$allowUnenc = $null
try { $allowUnenc = (Get-Item -Path WSMan:\localhost\Service\AllowUnencrypted -EA SilentlyContinue).Value } catch {}
if ($null -eq $allowUnenc) {
    # WinRM path unavailable - no free points
} elseif (-not $allowUnenc -or $allowUnenc -eq $false -or "$allowUnenc" -eq 'false') {
    Post-Finding 'WH3' 15
}

# WH4 payroll.csv gone or Everyone Full removed
$pay = 'C:\Shares\HR\payroll.csv'
if (-not (Test-Path $pay)) { Post-Finding 'WH4' 15 }
else {
    $acl = Get-Acl $pay
    if (-not ($acl.Access | Where-Object { $_.IdentityReference -match 'Everyone' -and $_.FileSystemRights -match 'FullControl' })) {
        Post-Finding 'WH4' 15
    }
}

# WH5 AutoAdminLogon off + DefaultPassword cleared
$wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -EA SilentlyContinue
if ($null -eq $wl -or (($wl.AutoAdminLogon -ne '1') -and [string]::IsNullOrEmpty([string]$wl.DefaultPassword))) {
    Post-Finding 'WH5' 15
}

# ======================= VERY HARD (20) =======================
# WV1 unquoted VendorUpd service removed OR ImagePath properly quoted
$vs = Get-CimInstance Win32_Service -Filter "Name='VendorUpd'" -EA SilentlyContinue
if (-not $vs) { Post-Finding 'WV1' 20 }
else {
    $img = [string]$vs.PathName
    if ($img -match '^".+"') { Post-Finding 'WV1' 20 }
}

# WV2 HLPrintHelp stopped+disabled or deleted
$svc = Get-Service -Name 'HLPrintHelp' -EA SilentlyContinue
if (-not $svc) { Post-Finding 'WV2' 20 }
elseif ($svc.StartType -eq 'Disabled') { Post-Finding 'WV2' 20 }

# WV3 hidden scheduled task removed or disabled
cmd /c 'schtasks /Query /TN WindowsHealthTelemetry >nul 2>&1'
if ($LASTEXITCODE -ne 0) { Post-Finding 'WV3' 20 }
else {
    $q = cmd /c 'schtasks /Query /TN WindowsHealthTelemetry /FO LIST 2>nul'
    if ($q -match '(?im)^\s*Status:\s*Disabled') { Post-Finding 'WV3' 20 }
}

# ======================= ALMOST IMPOSSIBLE (25) =======================
# WX1 WMI event subscription removed (our filter gone)
$filt = Get-CimInstance -Namespace 'root\subscription' -ClassName __EventFilter -EA SilentlyContinue |
    Where-Object { $_.Name -eq 'DCIGHealthFilter' }
if (-not $filt) { Post-Finding 'WX1' 25 }

# WX2 hidden admin account support$ removed
if (-not (Get-LocalUser -Name 'support$' -EA SilentlyContinue)) { Post-Finding 'WX2' 25 }
