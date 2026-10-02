<#
================================================================================
 DCIG System Hardening — Windows score agent (Phase 2)
 Machine-state checks only — no typed answers.
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

function Test-NoTask([string]$Name) {
    $taskOut = cmd /c "schtasks /Query /TN `"$Name`" 2>&1"
    return ($taskOut -match 'ERROR|cannot find|does not exist' -or $LASTEXITCODE -ne 0)
}

function Test-FwGoneOrOff([string]$DisplayName) {
    $r = Get-NetFirewallRule -DisplayName $DisplayName -EA SilentlyContinue
    return (-not $r -or (@($r | Where-Object Enabled -eq 'True').Count -eq 0))
}

# --- EASY ---
if (-not (Get-LocalUser -Name 'oldintern' -EA SilentlyContinue)) { Post-Finding 'W2-02' 10 }

$guest = Get-LocalUser -Name 'Guest' -EA SilentlyContinue
if ($guest -and -not $guest.Enabled) { Post-Finding 'W2-09' 10 }
elseif (-not $guest) { Post-Finding 'W2-09' 10 }

if (-not (Test-Path 'C:\Program Files\ChromeUpdater')) { Post-Finding 'W2-07' 10 }
if (-not (Test-Path 'C:\Program Files\FreeGameLauncher')) { Post-Finding 'W2-10' 10 }
if (-not (Test-Path 'C:\Users\student\Desktop\passwords.txt')) { Post-Finding 'W2-11' 10 }

# --- MEDIUM ---
$sys = Get-LocalUser -Name 'sysmaint' -EA SilentlyContinue
if (-not $sys) { Post-Finding 'W2-01' 15 }
else {
    $admins = Get-LocalGroupMember Administrators | ForEach-Object { $_.Name.Split('\')[-1].ToLower() }
    if ($admins -notcontains 'sysmaint') { Post-Finding 'W2-01' 15 }
}

if (Test-NoTask 'SystemUpdateCheck') { Post-Finding 'W2-03' 15 }
if (Test-FwGoneOrOff 'Legacy Backup Port') { Post-Finding 'W2-05' 15 }

try {
    $p = Get-MpPreference
    if (-not $p.DisableRealtimeMonitoring) { Post-Finding 'W2-06' 15 }
} catch {}

$path = 'C:\CaseFiles\backup_creds.txt'
if (-not (Test-Path $path)) { Post-Finding 'W2-08' 10 }
else {
    $acl = Get-Acl $path
    if (-not ($acl.Access | Where-Object { $_.IdentityReference -match 'Everyone' })) {
        Post-Finding 'W2-08' 10
    }
}

$wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -EA SilentlyContinue
# Fixed when AutoAdminLogon is not enabled and DefaultPassword is cleared
if ($null -eq $wl -or (($wl.AutoAdminLogon -ne '1') -and [string]::IsNullOrEmpty([string]$wl.DefaultPassword))) {
    Post-Finding 'W2-12' 20
}

if (Test-FwGoneOrOff 'Vendor Support Tunnel') { Post-Finding 'W2-13' 15 }

$hd = Get-LocalUser -Name 'helpdesk' -EA SilentlyContinue
if (-not $hd) { Post-Finding 'W2-14' 15 }
else {
    $admins = Get-LocalGroupMember Administrators | ForEach-Object { $_.Name.Split('\')[-1].ToLower() }
    if ($admins -notcontains 'helpdesk') { Post-Finding 'W2-14' 15 }
}

# --- HARD ---
$nk = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -EA SilentlyContinue).NetHelper
if ([string]::IsNullOrEmpty($nk)) { Post-Finding 'W2-04' 20 }

if (-not (Test-Path 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\SecurityUpdate.bat')) {
    Post-Finding 'W2-15' 15
}

$ro = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -EA SilentlyContinue).FlushCache
if ([string]::IsNullOrEmpty($ro)) { Post-Finding 'W2-16' 15 }

if (Test-NoTask 'WindowsHealthMonitor') { Post-Finding 'W2-17' 20 }

$svc = Get-Service -Name 'HLWinUpd' -EA SilentlyContinue
if (-not $svc) { Post-Finding 'W2-18' 25 }
elseif ($svc.Status -ne 'Running' -and $svc.StartType -eq 'Disabled') { Post-Finding 'W2-18' 25 }
# Also accept deleted service only (stopped but still present is not enough for full points unless disabled)
elseif ($svc.StartType -eq 'Disabled') { Post-Finding 'W2-18' 25 }

$sec = 'C:\ProgramData\app_secrets.ini'
if (-not (Test-Path $sec)) { Post-Finding 'W2-19' 15 }
else {
    $acl = Get-Acl $sec
    if (-not ($acl.Access | Where-Object { $_.IdentityReference -match 'Everyone' })) {
        Post-Finding 'W2-19' 15
    }
}
