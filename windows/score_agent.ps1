<#
================================================================================
 DCIG System Hardening - Windows score agent (Phase 2)
 Machine-state checks only - Windows-native findings (not a Linux mirror).
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

# --- EASY ---
# W2-02 Guest disabled or removed
$guest = Get-LocalUser -Name 'Guest' -EA SilentlyContinue
if ($guest -and -not $guest.Enabled) { Post-Finding 'W2-02' 10 }
elseif (-not $guest) { Post-Finding 'W2-02' 10 }

# W2-09 tempvendor removed
if (-not (Get-LocalUser -Name 'tempvendor' -EA SilentlyContinue)) { Post-Finding 'W2-09' 10 }

# W2-07 Sticky Keys IFEO debugger cleared
$ifeo = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sethc.exe' -EA SilentlyContinue
if (-not $ifeo -or [string]::IsNullOrEmpty([string]$ifeo.Debugger)) { Post-Finding 'W2-07' 10 }

# W2-10 TeamDrop share gone or Everyone FullAccess removed
$share = Get-SmbShare -Name 'TeamDrop' -EA SilentlyContinue
if (-not $share) { Post-Finding 'W2-10' 10 }
else {
    $access = Get-SmbShareAccess -Name 'TeamDrop' -EA SilentlyContinue
    $everyoneFull = $access | Where-Object {
        $_.AccountName -match 'Everyone' -and $_.AccessRight -eq 'Full' -and $_.AccessControlType -eq 'Allow'
    }
    if (-not $everyoneFull) { Post-Finding 'W2-10' 10 }
}

# W2-11 UAC re-enabled (EnableLUA = 1)
$lua = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -EA SilentlyContinue).EnableLUA
if ($lua -eq 1) { Post-Finding 'W2-11' 10 }

# --- MEDIUM ---
# W2-01 contractor not admin / deleted
$con = Get-LocalUser -Name 'contractor' -EA SilentlyContinue
if (-not $con) { Post-Finding 'W2-01' 15 }
elseif ((Get-AdminNames) -notcontains 'contractor') { Post-Finding 'W2-01' 15 }

# W2-03 RDP NLA required (UserAuthentication = 1)
$nla = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -EA SilentlyContinue).UserAuthentication
if ($nla -eq 1) { Post-Finding 'W2-03' 15 }

# W2-05 SNMP firewall hole closed
if (Test-FwGoneOrOff 'Temp SNMP Access') { Post-Finding 'W2-05' 15 }

# W2-06 Defender real-time on
# A failed query must not count as "on"
try {
    $p = Get-MpPreference -EA Stop
    $s = Get-MpComputerStatus -EA SilentlyContinue
    if ($p -and $p.DisableRealtimeMonitoring -eq $false -and (-not $s -or $s.RealTimeProtectionEnabled)) {
        Post-Finding 'W2-06' 15
    }
} catch {}

# W2-08 AlwaysInstallElevated cleared in both hives (missing or 0)
$hk = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer' -EA SilentlyContinue).AlwaysInstallElevated
$cu = (Get-ItemProperty 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Installer' -EA SilentlyContinue).AlwaysInstallElevated
if (($null -eq $hk -or $hk -eq 0) -and ($null -eq $cu -or $cu -eq 0)) { Post-Finding 'W2-08' 15 }

# W2-12 AutoAdminLogon off + DefaultPassword cleared
$wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -EA SilentlyContinue
if ($null -eq $wl -or (($wl.AutoAdminLogon -ne '1') -and [string]::IsNullOrEmpty([string]$wl.DefaultPassword))) {
    Post-Finding 'W2-12' 20
}

# W2-13 WDigest cleartext caching off
$wd = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' -EA SilentlyContinue).UseLogonCredential
if ($null -eq $wd -or $wd -eq 0) { Post-Finding 'W2-13' 15 }

# W2-14 Remote Registry not set to Automatic (Manual/Disabled is fine)
$rr = Get-Service -Name 'RemoteRegistry' -EA SilentlyContinue
if (-not $rr -or $rr.StartType -ne 'Automatic') { Post-Finding 'W2-14' 15 }

# --- HARD ---
# W2-04 RestrictAnonymous hardened (>= 1)
$ra = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -EA SilentlyContinue).RestrictAnonymous
if ($null -ne $ra -and [int]$ra -ge 1) { Post-Finding 'W2-04' 20 }

# W2-15 LM compatibility not weak (>= 3)
$lm = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -EA SilentlyContinue).LmCompatibilityLevel
if ($null -ne $lm -and [int]$lm -ge 3) { Post-Finding 'W2-15' 15 }

# W2-16 WinRM does not allow unencrypted
$allowUnenc = $null
try { $allowUnenc = (Get-Item -Path WSMan:\localhost\Service\AllowUnencrypted -EA SilentlyContinue).Value } catch {}
if ($null -eq $allowUnenc) {
    # If WinRM path unavailable, treat as fixed only when we cannot read true (avoid free points)
    # Fall through - no auto-award
} elseif (-not $allowUnenc -or $allowUnenc -eq $false -or "$allowUnenc" -eq 'false') {
    Post-Finding 'W2-16' 15
}

# W2-17 unquoted VendorUpd service removed OR ImagePath properly quoted without exploit pattern
$vs = Get-CimInstance Win32_Service -Filter "Name='VendorUpd'" -EA SilentlyContinue
if (-not $vs) { Post-Finding 'W2-17' 20 }
else {
    $img = [string]$vs.PathName
    # Fixed if path is quoted starting at C:\Program Files
    if ($img -match '^".+"') { Post-Finding 'W2-17' 20 }
}

# W2-18 HLPrintHelp stopped+disabled or deleted
$svc = Get-Service -Name 'HLPrintHelp' -EA SilentlyContinue
if (-not $svc) { Post-Finding 'W2-18' 25 }
elseif ($svc.StartType -eq 'Disabled') { Post-Finding 'W2-18' 25 }

# W2-19 payroll.csv gone or Everyone Full removed
$pay = 'C:\Shares\HR\payroll.csv'
if (-not (Test-Path $pay)) { Post-Finding 'W2-19' 15 }
else {
    $acl = Get-Acl $pay
    if (-not ($acl.Access | Where-Object { $_.IdentityReference -match 'Everyone' -and $_.FileSystemRights -match 'FullControl' })) {
        Post-Finding 'W2-19' 15
    }
}
