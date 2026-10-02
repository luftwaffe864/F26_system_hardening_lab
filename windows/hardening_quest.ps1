<#
================================================================================
 DCIG System Hardening — Windows Quest (Phase 1)
 Short ~10 min tool drill, then auto Phase-2 prep.

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

# Short tool drill — teach command, use once, move on (~10 min)
$Levels = @(
    @{
        M=1; Title='Get-Content — read a file'
        Task="Tool:  Get-Content <path>`nRun:   Get-Content C:\HardeningLab\briefing.txt`nSubmit your two-digit team number.  answer <NN>"
        Why='You will read notes and configs in Phase 2.'
        Type='answer'; Hints=@('Get-Content C:\HardeningLab\briefing.txt','Look for Team:')
    },
    @{
        M=1; Title='Get-LocalGroupMember — who is admin?'
        Task="Tool:  Get-LocalGroupMember -Group Administrators`nRun that. Which extra user should NOT be an admin?  answer <username>"
        Why='Phase 2: hunt unexpected Administrators the same way.'
        Type='answer'; Hints=@('Get-LocalGroupMember Administrators','tempadmin')
    },
    @{
        M=1; Title='Run key — startup persistence'
        Task="Tool:  Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run`nSubmit the suspicious value NAME.  answer <name>"
        Why='Run keys are classic Phase 2 findings (Task Manager > Startup also works).'
        Type='answer'; Hints=@('Get-ItemProperty ...\Run','SysHealthUpdate')
    },
    @{
        M=1; Title='Remove-ItemProperty — delete a Run key'
        Task="Tool:  Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run -Name <Name>`nPractice:`n  Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run -Name SysHealthUpdate`nAuto-passes when that value is gone."
        Why='Same pattern for NetHelper-style keys in Phase 2.'
        Type='auto'; Hints=@('Remove-ItemProperty ... -Name SysHealthUpdate')
    },
    @{
        M=1; Title='Firewall — find and remove a bad rule'
        Task="Tools:  Get-NetFirewallRule -DisplayName '*Support*'`n        Remove-NetFirewallRule -DisplayName 'Remote Admin Support'`n   Or:  wf.msc`nRemove/disable 'Remote Admin Support'. Auto-passes when gone or disabled."
        Why='Phase 2 plants more inbound allows — same cmdlets / wf.msc.'
        Type='auto'; Hints=@('Remove-NetFirewallRule -DisplayName "Remote Admin Support"')
    },
    @{
        M=1; Title='Defender — real-time protection ON'
        Task="Tools:  Get-MpPreference`n        Set-MpPreference -DisableRealtimeMonitoring `$false`n   Or:  Windows Security > Virus & threat protection`nTurn real-time ON. Auto-passes when monitoring is enabled."
        Why='Firewall is not antivirus. Phase 2 scores Defender being on.'
        Type='auto'; Hints=@('Set-MpPreference -DisableRealtimeMonitoring $false','Windows Security GUI')
    }
)

function Test-Level([int]$idx, [string]$Answer) {
    $n = $idx + 1
    switch ($n) {
        1 { return ($Answer.Trim() -eq (Get-Team)) }
        2 { return ($Answer.Trim().ToLower() -eq 'tempadmin') }
        3 { return ($Answer.Trim() -eq 'SysHealthUpdate') }
        4 {
            $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -EA SilentlyContinue).SysHealthUpdate
            return [string]::IsNullOrEmpty($v)
        }
        5 {
            $r = Get-NetFirewallRule -DisplayName 'Remote Admin Support' -EA SilentlyContinue
            if (-not $r) { return $true }
            return (($r | Where-Object { $_.Enabled -eq 'True' }).Count -eq 0)
        }
        6 {
            try {
                $p = Get-MpPreference
                return (-not $p.DisableRealtimeMonitoring)
            } catch { return $false }
        }
        default { return $false }
    }
}

function Show-Banner {
    Write-Host ''
    Write-Host '  HARDENING QUEST  ·  Windows  ·  ~10 min tool drill' -ForegroundColor Cyan
    Write-Host '  Learn the tools for the CyberPatriot race. Type help any time.' -ForegroundColor DarkGray
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
    Write-Host ("  DRILL · {0}" -f $L.Title) -ForegroundColor White
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
    Write-Host ("  Windows tool drill complete. Score: {0}" -f $script:Score) -ForegroundColor Green
    Write-Host ''
    Write-Host '  Please wait while we prepare your system for the CyberPatriot race...' -ForegroundColor Yellow
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

    New-Item -ItemType Directory -Force -Path $Cfg | Out-Null
    'go' | Set-Content -Path $flag -Encoding ASCII
    Set-Content -Path $phaseFile -Value 'phase1-done' -Encoding ASCII

    $kicked = $false
    try {
        $null = schtasks /Run /TN 'HardeningPreparePhase2' 2>&1
        if ($LASTEXITCODE -eq 0) { $kicked = $true }
    } catch { }

    if (-not $kicked -and (Test-Path $prep)) {
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
        Write-Host '  Phase 2 is ready — spend your time here hunting findings.' -ForegroundColor Green
    } else {
        Write-Host '  Phase 2 prep is still running (or needs a mentor). Check C:\HardeningLab\phase2-prep.log' -ForegroundColor Yellow
    }
    Write-Host ("  When mentors open scoring, fix findings for Team {0} — Linux + Windows both count." -f $team) -ForegroundColor Cyan
    Write-Host '  Read C:\HardeningLab\PHASE2.txt for categories. Double-click Desktop Scoreboard for live points.' -ForegroundColor DarkGray
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
            Write-Host '  Tool drill — learn commands for the CyberPatriot Phase 2 race.'
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
            } else { Write-Host '  Not it. Try hint.' -ForegroundColor Red }
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
