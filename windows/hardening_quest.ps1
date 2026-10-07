<#
================================================================================
 DCIG System Hardening - Windows Quest (Phase 1)
 Short tool drills, then auto Phase-2 prep.

   powershell.exe -ExecutionPolicy Bypass -File C:\HardeningLab\hardening_quest.ps1
================================================================================
#>
[CmdletBinding()]
param()

# HKLM Run keys, firewall, and Defender need a real admin token (UAC).
# Re-launch elevated once so Desktop double-click works after a single Yes.
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $self = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    $argList = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$self`""
    try {
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList $argList | Out-Null
    } catch {
        Write-Host ''
        Write-Host '  Hardening Quest needs Administrator rights.' -ForegroundColor Yellow
        Write-Host '  Close this window, then right-click "Hardening Quest" -> Run as administrator.' -ForegroundColor Yellow
        Write-Host ''
        Read-Host 'Press Enter to close'
    }
    exit 0
}

$LabRoot = 'C:\HardeningLab'
$Cfg     = Join-Path $LabRoot 'config'
$StateDir = Join-Path $env:LOCALAPPDATA 'HardeningQuest'
$Progress = Join-Path $StateDir 'progress.txt'
$ScoreFile = Join-Path $StateDir 'score.txt'
$RunKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
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
$TeamNN = Get-Team

# Get-LocalGroupMember throws on orphaned SIDs on some Server 2019 builds; net.exe does not.
function Get-AdminNames {
    $out = cmd /c 'net localgroup Administrators' 2>$null
    $inList = $false
    $names = @()
    foreach ($l in $out) {
        if ($l -match '^-{5,}') { $inList = $true; continue }
        if (-not $inList) { continue }
        if ($l -match '^The command completed') { break }
        if ($l.Trim()) { $names += $l.Trim().Split('\')[-1].ToLower() }
    }
    return $names
}

# Task = tool syntax + goal only. Answers live in the LAST hint.
$Levels = @(
    @{
        Title='Get-Content - read a file'
        Task="Tool  Get-Content <path>`nTask  Read the briefing in C:\HardeningLab.  answer <team number>"
        Type='answer'
        Hints=@('Get-ChildItem C:\HardeningLab', 'Get-Content C:\HardeningLab\briefing.txt', "answer $TeamNN")
    },
    @{
        Title='Administrators - who should be admin?'
        Task="Tool  Get-LocalGroupMember Administrators`n      Remove-LocalGroupMember Administrators -Member <user>`nTask  Make the Administrators group match C:\HardeningLab\authorized_users.txt."
        Type='auto'
        Hints=@('Get-Content C:\HardeningLab\authorized_users.txt', 'Two members are admins but should not be - one is an authorized standard user, keep that account', 'Remove-LocalGroupMember Administrators -Member tempadmin,bjones')
    },
    @{
        Title='Get-LocalUser - unauthorized accounts'
        Task="Tool  Get-LocalUser`n      Remove-LocalUser <user>`nTask  Delete accounts that are not on the authorized list (leave built-in accounts)."
        Type='auto'
        Hints=@('Compare Get-LocalUser with authorized_users.txt', 'Two accounts were never approved; one of them looks like a guest', 'Remove-LocalUser guestuser,tempadmin')
    },
    @{
        Title='Disable-LocalUser - former employee'
        Task="Tool  Get-LocalUser <user> | Select-Object Name,Enabled,Description`n      Disable-LocalUser <user>`nTask  Someone left the company but can still log in. Follow C:\HardeningLab\hr_memo.txt."
        Type='auto'
        Hints=@('Get-Content C:\HardeningLab\hr_memo.txt', 'The memo says keep the account for records - disable it, do not delete it', 'Disable-LocalUser jmiller')
    },
    @{
        Title='Run key - startup persistence'
        Task="Tool  Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run`n      Remove-ItemProperty -Path <key> -Name <value>`nTask  Something launches a fake updater at every login. Remove that startup entry."
        Type='auto'
        Hints=@('Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'The odd value points into C:\ProgramData\SysHealth', 'Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run -Name SysHealthUpdate')
    },
    @{
        Title='Services - rogue service'
        Task="Tool  Get-CimInstance Win32_Service | Select-Object Name,StartMode,PathName`n      Stop-Service <name> -Force`n      Set-Service <name> -StartupType Disabled`nTask  A fake service starts from C:\ProgramData. Stop it and keep it off after reboot."
        Type='auto'
        Hints=@('Get-CimInstance Win32_Service | Where-Object PathName -like "*powershell*" | Select-Object Name,PathName', 'The service is SysCacheSvc', 'Stop-Service SysCacheSvc -Force; Set-Service SysCacheSvc -StartupType Disabled')
    },
    @{
        Title='Firewall - remove a bad inbound rule'
        Task="Tool  Get-NetFirewallRule -Direction Inbound -Enabled True | Select-Object DisplayName`n      Remove-NetFirewallRule -DisplayName <name>`nTask  Remove the rule that opens a remote-support port. Do not touch 'DCIG Lab RDP Access'."
        Type='auto'
        Hints=@("Get-NetFirewallRule -DisplayName '*Support*'", 'The rule opens TCP 5555', 'Remove-NetFirewallRule -DisplayName "Remote Admin Support"')
    },
    @{
        Title='Defender - real-time protection'
        Task="Tool  Get-MpPreference | Select-Object DisableRealtimeMonitoring`n      Set-MpPreference -DisableRealtimeMonitoring <bool>`nTask  Turn Defender real-time protection back on."
        Type='auto'
        Hints=@('Get-MpPreference | Select-Object DisableRealtimeMonitoring', 'True means protection is OFF', 'Set-MpPreference -DisableRealtimeMonitoring $false')
    }
)

function Test-Level([int]$idx, [string]$Answer) {
    switch ($idx + 1) {
        1 { return ($Answer.Trim() -eq $TeamNN) }
        2 {
            $a = Get-AdminNames
            return (($a -notcontains 'tempadmin') -and ($a -notcontains 'bjones') -and
                    [bool](Get-LocalUser -Name 'bjones' -EA SilentlyContinue))
        }
        3 {
            foreach ($u in @('guestuser', 'tempadmin')) {
                if (Get-LocalUser -Name $u -EA SilentlyContinue) { return $false }
            }
            foreach ($u in @('asmith', 'bjones', 'cwong')) {
                if (-not (Get-LocalUser -Name $u -EA SilentlyContinue)) { return $false }
            }
            return $true
        }
        4 {
            $u = Get-LocalUser -Name 'jmiller' -EA SilentlyContinue
            return ((-not $u) -or (-not $u.Enabled))
        }
        5 {
            $v = (Get-ItemProperty $RunKey -EA SilentlyContinue).SysHealthUpdate
            return [string]::IsNullOrEmpty($v)
        }
        6 {
            $s = Get-Service -Name 'SysCacheSvc' -EA SilentlyContinue
            return ((-not $s) -or ($s.StartType -eq 'Disabled' -and $s.Status -ne 'Running'))
        }
        7 {
            $r = Get-NetFirewallRule -DisplayName 'Remote Admin Support' -EA SilentlyContinue
            if (-not $r) { return $true }
            return (@($r | Where-Object { $_.Enabled -eq 'True' }).Count -eq 0)
        }
        8 {
            try { return (-not (Get-MpPreference).DisableRealtimeMonitoring) } catch { return $false }
        }
        default { return $false }
    }
}

function Show-Line { Write-Host ('-' * 56) -ForegroundColor DarkGray }

function Show-Banner {
    Write-Host ''
    Write-Host '  HARDENING QUEST - Windows' -ForegroundColor Cyan
    Write-Host ("  {0} short drills. Type help for commands." -f $Levels.Count) -ForegroundColor DarkGray
    Write-Host ''
}

function Show-Help {
    Show-Line
    Write-Host '  task  hint  answer X  skip  progress  scoreboard  quit' -ForegroundColor Yellow
    Write-Host '  Anything else runs as a normal PowerShell command.' -ForegroundColor DarkGray
    Show-Line
}

function Show-Task {
    if ($script:Level -gt $Levels.Count) { return }
    $L = $Levels[$script:Level - 1]
    Show-Line
    Write-Host ("DRILL {0}/{1} - {2}" -f $script:Level, $Levels.Count, $L.Title) -ForegroundColor White
    foreach ($t in ($L.Task -split "`n")) { Write-Host ("  {0}" -f $t) }
    Show-Line
}

function Show-Hint {
    $h = $Levels[$script:Level - 1].Hints
    if ($script:Hints -ge $h.Count) { Write-Host '  No more hints.' -ForegroundColor Yellow; return }
    $label = if ($script:Hints -eq $h.Count - 1) { 'Answer' } else { "Hint $($script:Hints + 1)/$($h.Count)" }
    Write-Host ("  {0} (-2 pts): {1}" -f $label, $h[$script:Hints]) -ForegroundColor Yellow
    $script:Hints++
}

function Show-Scoreboard {
    $sb = Join-Path $LabRoot 'Show-Scoreboard.ps1'
    if (Test-Path $sb) { & $sb }
    else { Write-Host ("  Scoreboard: {0}" -f (Get-Content (Join-Path $Cfg 'scoreboard_url.txt') -EA SilentlyContinue)) }
}

function Advance([int]$Pts) {
    $script:Score += $Pts
    Write-Host ("OK Level complete  +{0}   (total {1})" -f $Pts, $script:Score) -ForegroundColor Green
    $script:Level++
    $script:Hints = 0
    Save-Progress
    if ($script:Level -gt $Levels.Count) { Finish-Quest; return }
    Show-Task
}

function Finish-Quest {
    Write-Host ''
    Write-Host ("  Windows quest complete. Score: {0}" -f $script:Score) -ForegroundColor Green
    Write-Host '  Starting Phase 2 prep - keep this window open until it says ready.' -ForegroundColor Yellow
    Write-Host ''

    $flag = Join-Path $Cfg 'start_phase2.flag'
    $done = Join-Path $Cfg 'phase2_auto_done.flag'
    $phaseFile = Join-Path $Cfg 'phase.txt'
    $phase2Txt = Join-Path $LabRoot 'PHASE2.txt'

    New-Item -ItemType Directory -Force -Path $Cfg | Out-Null
    # Flag wakes the SYSTEM watcher within ~1 min even if schtasks /Run is denied
    'go' | Set-Content -Path $flag -Encoding ASCII
    Set-Content -Path $phaseFile -Value 'phase1-done' -Encoding ASCII

    foreach ($tn in @('HardeningPreparePhase2', 'HardeningPhase2Watch')) {
        try { $null = schtasks /Run /TN $tn 2>&1 } catch { }
    }

    $ready = $false
    for ($i = 0; $i -lt 36; $i++) {
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
        Write-Host '  Phase 2 is ready. Read C:\HardeningLab\PHASE2.txt and start hardening.' -ForegroundColor Green
    } else {
        Write-Host '  Phase 2 prep is still running - ask a mentor if this does not finish.' -ForegroundColor Yellow
    }
    Write-Host '  Live points: Desktop "DCIG Scoreboard" or type scoreboard in any quest window.' -ForegroundColor DarkGray
    Write-Host ''
}

Show-Banner
Show-Help
if ($script:Level -gt $Levels.Count) { Finish-Quest; return }
Show-Task

:quest while ($true) {
    if ($script:Level -gt $Levels.Count) { break }
    Write-Host -NoNewline "hardening:$($script:Level)> "
    $cmd = Read-Host
    if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
    switch -Regex ($cmd.Trim()) {
        '^help$' { Show-Help; continue }
        '^task$' { Show-Task; continue }
        '^hint$' { Show-Hint; continue }
        '^scoreboard$' { Show-Scoreboard; continue }
        '^progress$' {
            Write-Host ("  Drill {0}/{1}  Score {2}" -f $script:Level, $Levels.Count, $script:Score)
            continue
        }
        '^skip$' {
            Write-Host '  Skipped (0 pts).' -ForegroundColor Yellow
            $script:Level++; $script:Hints = 0; Save-Progress
            if ($script:Level -gt $Levels.Count) { Finish-Quest; break quest }
            Show-Task; continue
        }
        '^(quit|exit)$' { Save-Progress; Write-Host 'Saved. Bye.'; break quest }
        '^answer\s+(.+)$' {
            $ans = $Matches[1]
            if ($Levels[$script:Level - 1].Type -ne 'answer') {
                Write-Host '  This drill passes on its own once the system is fixed.' -ForegroundColor Yellow
                continue
            }
            if (Test-Level ($script:Level - 1) $ans) {
                Advance ([Math]::Max(0, 10 - 2 * $script:Hints))
            } else { Write-Host '  Not it. Try hint.' -ForegroundColor Red }
            continue
        }
        default {
            try {
                Invoke-Expression $cmd | Out-Host
            } catch {
                Write-Host $_.Exception.Message -ForegroundColor Red
            }
            if ($Levels[$script:Level - 1].Type -eq 'auto' -and (Test-Level ($script:Level - 1) '')) {
                Advance ([Math]::Max(0, 10 - 2 * $script:Hints))
            }
        }
    }
}
