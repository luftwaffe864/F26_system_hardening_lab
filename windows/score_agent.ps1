<#
================================================================================
 DCIG System Hardening — Windows score agent (Phase 2)
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

# W2-01 sysmaint not admin / deleted (15)
$sys = Get-LocalUser -Name 'sysmaint' -EA SilentlyContinue
if (-not $sys) { Post-Finding 'W2-01' 15 }
else {
    $admins = Get-LocalGroupMember Administrators | ForEach-Object { $_.Name.Split('\')[-1].ToLower() }
    if ($admins -notcontains 'sysmaint') { Post-Finding 'W2-01' 15 }
}

# W2-02 oldintern removed (10)
if (-not (Get-LocalUser -Name 'oldintern' -EA SilentlyContinue)) { Post-Finding 'W2-02' 10 }

# W2-03 scheduled task gone (15)
$taskOut = cmd /c "schtasks /Query /TN SystemUpdateCheck 2>&1"
if ($taskOut -match 'ERROR|cannot find|does not exist' -or $LASTEXITCODE -ne 0) {
    Post-Finding 'W2-03' 15
}

# W2-04 NetHelper Run key gone (20)
$nk = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -EA SilentlyContinue).NetHelper
if ([string]::IsNullOrEmpty($nk)) { Post-Finding 'W2-04' 20 }

# W2-05 firewall rule gone/disabled (15)
$r = Get-NetFirewallRule -DisplayName 'Legacy Backup Port' -EA SilentlyContinue
if (-not $r -or (@($r | Where-Object Enabled -eq 'True').Count -eq 0)) { Post-Finding 'W2-05' 15 }

# W2-06 Defender RTP on (15)
try {
    $p = Get-MpPreference
    if (-not $p.DisableRealtimeMonitoring) { Post-Finding 'W2-06' 15 }
} catch {}

# W2-07 ChromeUpdater removed (10)
if (-not (Test-Path 'C:\Program Files\ChromeUpdater')) { Post-Finding 'W2-07' 10 }

# W2-08 backup_creds fixed/removed (10)
$path = 'C:\CaseFiles\backup_creds.txt'
if (-not (Test-Path $path)) { Post-Finding 'W2-08' 10 }
else {
    $acl = Get-Acl $path
    if (-not ($acl.Access | Where-Object { $_.IdentityReference -match 'Everyone' })) {
        Post-Finding 'W2-08' 10
    }
}
