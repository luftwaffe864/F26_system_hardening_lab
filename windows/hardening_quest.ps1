<#
================================================================================
 DCIG System Hardening — Windows Quest (Phase 1)
 Run as the student account:

   powershell.exe -ExecutionPolicy Bypass -File C:\HardeningLab\hardening_quest.ps1
================================================================================
#>
[CmdletBinding()]
param()

$LabRoot = 'C:\HardeningLab'
$Cfg     = Join-Path $LabRoot 'config'
$StateDir = Join-Path $env:LOCALAPPDATA 'HardeningQuest'
$Progress = Join-Path $StateDir 'progress.txt'
$ScoreFile = Join-Path $StateDir 'score.txt'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

$script:Level = 1
$script:Score = 0
$script:Hints = 0
if (Test-Path $Progress) { $script:Level = [int](Get-Content $Progress) + 1 }
if (Test-Path $ScoreFile) { $script:Score = [int](Get-Content $ScoreFile) }

function Save-Progress {
    Set-Content $Progress ($script:Level - 1)
    Set-Content $ScoreFile $script:Score
}

function Get-Team {
    if (Test-Path (Join-Path $Cfg 'team.txt')) {
        return (Get-Content (Join-Path $Cfg 'team.txt') -Raw).Trim()
    }
    if ($env:COMPUTERNAME -match '(\d+)$') { return ('{0:D2}' -f [int]$Matches[1]) }
    return '00'
}

$Levels = @(
    @{
        M=1; Title='Read the briefing'
        Task='Read C:\HardeningLab\briefing.txt and submit your team number (two digits).  answer <NN>'
        Why='Confirm you are on the right Windows box for your team.'
        Type='answer'; Hints=@('type C:\HardeningLab\briefing.txt','Look for the Team: line')
    },
    @{
        M=1; Title='Startup inventory'
        Task='How many values are under HKLM Run (startup programs for all users)?  answer <number>'
        Why='Startup entries are classic persistence / bloat.'
        Type='answer'; Hints=@('Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','Count the note properties that are not PS*')
    },
    @{
        M=1; Title='Name the startup implant'
        Task='Submit the Run-key value name that launches the fake health updater.  answer <name>'
        Why='Attack surface includes persistence names, not just counts.'
        Type='answer'; Hints=@('Look in Task Manager > Startup or the Run key','SysHealthUpdate')
    },
    @{
        M=1; Title='Bloatware folder'
        Task='Submit the folder name under "C:\Program Files" that is fake optimizer bloat (exact name).  answer <name>'
        Why='Unused sketchy software should go.'
        Type='answer'; Hints=@('dir "C:\Program Files"','PCOptimizer Pro')
    },
    @{
        M=2; Title='Extra administrator'
        Task='Which local user (besides Administrator/student) is in Administrators and should not be?  answer <user>'
        Why='Least privilege — very few accounts need admin.'
        Type='answer'; Hints=@('Get-LocalGroupMember Administrators','tempadmin')
    },
    @{
        M=2; Title='Remove tempadmin rights'
        Task='Remove tempadmin from Administrators (or delete the account). Auto-passes when fixed.'
        Why='Demote or remove risky admins.'
        Type='auto'; Hints=@('Remove-LocalGroupMember -Group Administrators -Member tempadmin','Or Remove-LocalUser tempadmin')
    },
    @{
        M=2; Title='Fix the keys file'
        Task='C:\CaseFiles\keys.txt allows Everyone Full Control. Remove Everyone and set inheritance off with Administrators+SYSTEM only, or delete the file. Auto-passes when Everyone is gone (or file deleted).'
        Why='Secrets and open ACLs are free loot.'
        Type='auto'; Hints=@('icacls C:\CaseFiles\keys.txt','icacls ... /remove Everyone')
    },
    @{
        M=3; Title='Kill startup persistence'
        Task='Remove the SysHealthUpdate Run-key value (and optionally end health_update). Auto-passes when the Run value is gone.'
        Why='Stopping the process is temporary; remove persistence.'
        Type='auto'; Hints=@('Remove-ItemProperty -Path HKLM:\...\Run -Name SysHealthUpdate','Task Manager > Startup')
    },
    @{
        M=3; Title='Delete the firewall hole'
        Task='Disable or delete the inbound firewall rule named "Remote Admin Support".'
        Why='Firewalls filter ports/connections; this rule opens TCP 5555 to the world.'
        Type='auto'; Hints=@('wf.msc or Get-NetFirewallRule','Remove-NetFirewallRule -DisplayName "Remote Admin Support"')
    },
    @{
        M=3; Title='Turn Defender real-time back on'
        Task='Enable Windows Defender real-time protection. Auto-passes when real-time monitoring is on.'
        Why='Firewall ≠ antivirus. You want Defender running.'
        Type='auto'; Hints=@('Windows Security > Virus & threat protection','Set-MpPreference -DisableRealtimeMonitoring $false')
    },
    @{
        M=3; Title='Remove bloat folder'
        Task='Delete "C:\Program Files\PCOptimizer Pro". Auto-passes when it is gone.'
        Why='Only keep software you need from trusted sources.'
        Type='auto'; Hints=@('Remove-Item -Recurse -Force "C:\Program Files\PCOptimizer Pro"')
    }
)

function Test-Level([int]$idx, [string]$Answer) {
    $n = $idx + 1
    switch ($n) {
        1 { return ($Answer.Trim() -eq (Get-Team)) }
        2 {
            $p = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
            $count = @($p.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }).Count
            return ($Answer.Trim() -eq "$count")
        }
        3 { return ($Answer.Trim() -eq 'SysHealthUpdate') }
        4 { return ($Answer.Trim() -eq 'PCOptimizer Pro') }
        5 { return ($Answer.Trim().ToLower() -eq 'tempadmin') }
        6 {
            $u = Get-LocalUser -Name 'tempadmin' -EA SilentlyContinue
            if (-not $u) { return $true }
            $admins = Get-LocalGroupMember -Group 'Administrators' | ForEach-Object { $_.Name.Split('\')[-1].ToLower() }
            return ($admins -notcontains 'tempadmin')
        }
        7 {
            if (-not (Test-Path 'C:\CaseFiles\keys.txt')) { return $true }
            $acl = Get-Acl 'C:\CaseFiles\keys.txt'
            return -not ($acl.Access | Where-Object { $_.IdentityReference -match 'Everyone' })
        }
        8 {
            $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -EA SilentlyContinue).SysHealthUpdate
            return [string]::IsNullOrEmpty($v)
        }
        9 {
            $r = Get-NetFirewallRule -DisplayName 'Remote Admin Support' -EA SilentlyContinue
            if (-not $r) { return $true }
            return (($r | Where-Object { $_.Enabled -eq 'True' }).Count -eq 0)
        }
        10 {
            try {
                $p = Get-MpPreference
                return (-not $p.DisableRealtimeMonitoring)
            } catch { return $false }
        }
        11 { return -not (Test-Path 'C:\Program Files\PCOptimizer Pro') }
        default { return $false }
    }
}

function Show-Banner {
    Write-Host ''
    Write-Host '  HARDENING QUEST  ·  Windows' -ForegroundColor Cyan
    Write-Host '  Map the attack surface. Lock it down. Type help any time.' -ForegroundColor DarkGray
    Write-Host ''
}

function Show-Help {
    Write-Host '  task  mission  hint  answer X  skip  progress  quit' -ForegroundColor Yellow
    Write-Host '  Or run real PowerShell commands at the prompt.' -ForegroundColor DarkGray
}

function Show-Task {
    if ($script:Level -gt $Levels.Count) { return }
    $L = $Levels[$script:Level - 1]
    Write-Host ('─' * 56) -ForegroundColor DarkGray
    Write-Host ("  M{0} · {1}" -f $L.M, $L.Title) -ForegroundColor White
    Write-Host ("  {0}" -f $L.Task)
    Write-Host ("  Why: {0}" -f $L.Why) -ForegroundColor DarkGray
    Write-Host ('─' * 56) -ForegroundColor DarkGray
}

function Advance([int]$Pts) {
    $script:Score += $Pts
    Write-Host ("✔ Level complete  +{0}   (total {1})" -f $Pts, $script:Score) -ForegroundColor Green
    $script:Level++
    $script:Hints = 0
    Save-Progress
    if ($script:Level -gt $Levels.Count) { Finish-Quest; return }
    Show-Task
}

function Finish-Quest {
    $team = Get-Team
    Write-Host ''
    Write-Host ("  Windows quest complete. Score: {0}" -f $script:Score) -ForegroundColor Green
    Write-Host ''
    Write-Host '  Please wait while we prepare your system for the next lab...' -ForegroundColor Yellow
    Write-Host '  (Phase 2 prep starts automatically — do not run any extra scripts.)' -ForegroundColor DarkGray
    Write-Host ''

    $prep = Join-Path $LabRoot 'prepare_phase2.ps1'
    if (-not (Test-Path $prep)) {
        $prep = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'prepare_phase2.ps1'
    }
    $flag = Join-Path $Cfg 'start_phase2.flag'
    $done = Join-Path $Cfg 'phase2_auto_done.flag'
    $phaseFile = Join-Path $Cfg 'phase.txt'
    $phase2Txt = Join-Path $LabRoot 'PHASE2.txt'

    # Signal the SYSTEM watcher (works without UAC). Also try on-demand task.
    New-Item -ItemType Directory -Force -Path $Cfg | Out-Null
    'go' | Set-Content -Path $flag -Encoding ASCII
    Set-Content -Path $phaseFile -Value 'phase1-done' -Encoding ASCII

    $kicked = $false
    try {
        $null = schtasks /Run /TN 'HardeningPreparePhase2' 2>&1
        if ($LASTEXITCODE -eq 0) { $kicked = $true }
    } catch { }

    if (-not $kicked -and (Test-Path $prep)) {
        # Last resort: try elevated RunAs (may prompt UAC in console sessions)
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList @(
                '-NoProfile','-ExecutionPolicy','Bypass','-File', $prep
            ) -EA Stop
            $kicked = $true
        } catch {
            try {
                & $prep
                $kicked = $true
            } catch {
                Write-Host '  Waiting for SYSTEM watcher to pick up Phase 2 prep...' -ForegroundColor DarkGray
            }
        }
    }

    # Wait up to ~2 minutes for prep to finish (PHASE2.txt or phase=phase2)
    $ready = $false
    for ($i = 0; $i -lt 24; $i++) {
        Start-Sleep -Seconds 5
        $ph = ''
        if (Test-Path $phaseFile) { $ph = (Get-Content $phaseFile -Raw).Trim() }
        if ((Test-Path $phase2Txt) -or (Test-Path $done) -or $ph -eq 'phase2') {
            $ready = $true
            break
        }
        Write-Host -NoNewline '.'
    }
    Write-Host ''

    if ($ready) {
        Write-Host '  Phase 2 is ready on this Windows box.' -ForegroundColor Green
    } else {
        Write-Host '  Phase 2 prep is still running (or needs a mentor). Check C:\HardeningLab\phase2-prep.log' -ForegroundColor Yellow
        Write-Host '  You can keep waiting, or ask a mentor to run prepare_phase2.ps1 elevated.' -ForegroundColor DarkGray
    }
    Write-Host ("  When mentors open scoring, fix findings for Team {0} — Linux + Windows both count." -f $team) -ForegroundColor Cyan
    Write-Host '  Read C:\HardeningLab\PHASE2.txt for a high-level checklist once it appears.' -ForegroundColor DarkGray
    Write-Host ''
}

Show-Banner
Show-Help
if ($script:Level -gt $Levels.Count) { Finish-Quest; return }
Show-Task

while ($true) {
    if ($script:Level -gt $Levels.Count) { break }
    $prompt = "hardening:$($script:Level)> "
    Write-Host -NoNewline $prompt
    $cmd = Read-Host
    if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
    switch -Regex ($cmd.Trim()) {
        '^help$' { Show-Help; continue }
        '^task$' { Show-Task; continue }
        '^mission$' {
            $m = $Levels[$script:Level - 1].M
            Write-Host ("  Mission {0} — hardening objectives for this stage." -f $m)
            continue
        }
        '^hint$' {
            $h = $Levels[$script:Level - 1].Hints
            if ($script:Hints -ge $h.Count) { Write-Host '  No more hints.'; continue }
            Write-Host ("  Hint (-2 pts): {0}" -f $h[$script:Hints]) -ForegroundColor Yellow
            $script:Hints++
            continue
        }
        '^progress$' {
            Write-Host ("  Level {0}/{1}  Score {2}" -f $script:Level, $Levels.Count, $script:Score)
            continue
        }
        '^skip$' {
            Write-Host '  Skipped (0 pts).' -ForegroundColor Yellow
            $script:Level++; $script:Hints = 0; Save-Progress
            if ($script:Level -gt $Levels.Count) { Finish-Quest; break }
            Show-Task; continue
        }
        '^(quit|exit)$' { Save-Progress; Write-Host 'Saved. Bye.'; break }
        '^answer\s+(.+)$' {
            $ans = $Matches[1]
            $L = $Levels[$script:Level - 1]
            if ($L.Type -ne 'answer') { Write-Host '  This level auto-passes.'; continue }
            if (Test-Level ($script:Level - 1) $ans) {
                $pts = [Math]::Max(0, 10 - 2 * $script:Hints)
                Advance $pts
            } else { Write-Host '  ✘ Not it. Try hint.' -ForegroundColor Red }
            continue
        }
        default {
            try {
                Invoke-Expression $cmd | Out-Host
            } catch {
                Write-Host $_.Exception.Message -ForegroundColor Red
            }
            $L = $Levels[$script:Level - 1]
            if ($L.Type -eq 'auto' -and (Test-Level ($script:Level - 1) '')) {
                $pts = [Math]::Max(0, 10 - 2 * $script:Hints)
                Advance $pts
            }
        }
    }
}
