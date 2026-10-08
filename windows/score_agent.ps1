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

# Points only after prepare confirmed the plant (no free points when a plant failed).
function Test-Planted([string]$Id) {
    Test-Path (Join-Path $LabRoot "config\planted\$Id")
}
function Get-StudentAie {
    try {
        $sid = (New-Object System.Security.Principal.NTAccount('student')).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
    } catch { return $null }
    $loaded = $false
    if (-not (Test-Path "Registry::HKEY_USERS\$sid")) {
        $hive = 'C:\Users\student\NTUSER.DAT'
        if (-not (Test-Path $hive)) { return $null }
        & reg.exe load "HKU\$sid" $hive | Out-Null
        $loaded = $true
    }
    $v = (Get-ItemProperty "Registry::HKEY_USERS\$sid\SOFTWARE\Policies\Microsoft\Windows\Installer" -EA SilentlyContinue).AlwaysInstallElevated
    if ($loaded) { & reg.exe unload "HKU\$sid" | Out-Null }
    return $v
}

# --- EASY (5) ---
if (Test-Planted 'WE-01') {
    $guest = Get-LocalUser -Name 'Guest' -EA SilentlyContinue
    if ((-not $guest) -or (-not $guest.Enabled)) { Post-Finding 'WE-01' 5 }
}
if ((Test-Planted 'WE-02') -and -not (Get-LocalUser -Name 'tempvendor' -EA SilentlyContinue)) { Post-Finding 'WE-02' 5 }
$startup = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\CouponHelper.bat'
if ((Test-Planted 'WE-03') -and -not (Test-Path $startup)) { Post-Finding 'WE-03' 5 }
if (Test-Planted 'WE-04') {
    $share = Get-SmbShare -Name 'TeamDrop' -EA SilentlyContinue
    if (-not $share) { Post-Finding 'WE-04' 5 }
    else {
        $access = Get-SmbShareAccess -Name 'TeamDrop' -EA SilentlyContinue
        $everyoneFull = $access | Where-Object {
            $_.AccountName -match 'Everyone' -and $_.AccessRight -eq 'Full' -and $_.AccessControlType -eq 'Allow'
        }
        if (-not $everyoneFull) { Post-Finding 'WE-04' 5 }
    }
}
if ((Test-Planted 'WE-05') -and -not (Test-Path (Join-Path $env:PUBLIC 'Documents\passwords.txt'))) { Post-Finding 'WE-05' 5 }
if (Test-Planted 'WE-06') {
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (-not (Select-String -Path $hosts -Pattern 'dcig-lab-plant' -Quiet -EA SilentlyContinue)) { Post-Finding 'WE-06' 5 }
}
if ((Test-Planted 'WE-07') -and (Test-FwGoneOrOff 'Allow Remote Debug')) { Post-Finding 'WE-07' 5 }
if ((Test-Planted 'WE-08') -and -not (Test-Path 'C:\Program Files\CouponPrinter')) { Post-Finding 'WE-08' 5 }

# --- MEDIUM (10) ---
if (Test-Planted 'WM-01') {
    $con = Get-LocalUser -Name 'contractor' -EA SilentlyContinue
    if ((-not $con) -or ((Get-AdminNames) -notcontains 'contractor')) { Post-Finding 'WM-01' 10 }
}
if (Test-Planted 'WM-02') {
    $nla = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -EA SilentlyContinue).UserAuthentication
    if ($nla -eq 1) { Post-Finding 'WM-02' 10 }
}
if (Test-Planted 'WM-03') {
    try {
        $p = Get-MpPreference -EA Stop
        $s = Get-MpComputerStatus -EA SilentlyContinue
        if ($p -and $p.DisableRealtimeMonitoring -eq $false -and (-not $s -or $s.RealTimeProtectionEnabled)) {
            Post-Finding 'WM-03' 10
        }
    } catch {}
}
if (Test-Planted 'WM-04') {
    $hk = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer' -EA SilentlyContinue).AlwaysInstallElevated
    $cu = Get-StudentAie
    if (($null -eq $hk -or $hk -eq 0) -and ($null -eq $cu -or $cu -eq 0)) { Post-Finding 'WM-04' 10 }
}
if (Test-Planted 'WM-05') {
    $wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -EA SilentlyContinue
    if ($wl -and ($wl.AutoAdminLogon -ne '1') -and [string]::IsNullOrEmpty([string]$wl.DefaultPassword)) {
        Post-Finding 'WM-05' 10
    }
}
if (Test-Planted 'WM-06') {
    $rr = Get-Service -Name 'RemoteRegistry' -EA SilentlyContinue
    if ((-not $rr) -or $rr.StartType -ne 'Automatic') { Post-Finding 'WM-06' 10 }
}
if (Test-Planted 'WM-07') {
    $pay = 'C:\Shares\HR\payroll.csv'
    if (-not (Test-Path $pay)) { Post-Finding 'WM-07' 10 }
    else {
        $acl = Get-Acl $pay
        if (-not ($acl.Access | Where-Object { $_.IdentityReference -match 'Everyone' -and $_.FileSystemRights -match 'FullControl' })) {
            Post-Finding 'WM-07' 10
        }
    }
}

# --- HARD (15) ---
if (Test-Planted 'WH-01') {
    $wd = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' -EA SilentlyContinue).UseLogonCredential
    if ($null -eq $wd -or $wd -eq 0) { Post-Finding 'WH-01' 15 }
}
if (Test-Planted 'WH-02') {
    $ra = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -EA SilentlyContinue).RestrictAnonymous
    if ($null -ne $ra -and [int]$ra -ge 1) { Post-Finding 'WH-02' 15 }
}
if (Test-Planted 'WH-03') {
    $lm = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -EA SilentlyContinue).LmCompatibilityLevel
    if ($null -ne $lm -and [int]$lm -ge 3) { Post-Finding 'WH-03' 15 }
}
if (Test-Planted 'WH-04') {
    $vs = Get-CimInstance Win32_Service -Filter "Name='VendorUpd'" -EA SilentlyContinue
    if (-not $vs) { Post-Finding 'WH-04' 15 }
    elseif ([string]$vs.PathName -match '^".+"') { Post-Finding 'WH-04' 15 }
}
if (Test-Planted 'WH-05') {
    $svc = Get-Service -Name 'HLPrintHelp' -EA SilentlyContinue
    if ((-not $svc) -or $svc.StartType -eq 'Disabled') { Post-Finding 'WH-05' 15 }
}

# --- VERY HARD (20) ---
if ((Test-Planted 'WV-01') -and -not (Get-ScheduledTask -TaskName 'CacheCleanup' -EA SilentlyContinue)) {
    Post-Finding 'WV-01' 20
}
if (Test-Planted 'WV-02') {
    $ui = [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -EA SilentlyContinue).Userinit
    if ($ui -and $ui -notmatch 'updater\.exe') { Post-Finding 'WV-02' 20 }
}
if (Test-Planted 'WV-03') {
    $ns = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -EA SilentlyContinue).RestrictNullSessAccess
    if ($null -ne $ns -and [int]$ns -ge 1) { Post-Finding 'WV-03' 20 }
}

# --- ALMOST IMPOSSIBLE (25) ---
if (Test-Planted 'WI-01') {
    $mag = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\magnify.exe' -EA SilentlyContinue
    if ((-not $mag) -or [string]::IsNullOrEmpty([string]$mag.Debugger)) { Post-Finding 'WI-01' 25 }
}
if (Test-Planted 'WI-02') {
    $ini = Join-Path $env:SystemRoot 'System32\GroupPolicy\Machine\Scripts\scripts.ini'
    if (-not (Test-Path $ini) -or -not (Select-String -Path $ini -Pattern 'lab-sync' -Quiet -EA SilentlyContinue)) {
        Post-Finding 'WI-02' 25
    }
}
