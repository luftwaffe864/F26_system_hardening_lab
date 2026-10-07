<#
================================================================================
 DCIG System Hardening - Windows Quest (Phase 1)
 Hands-on GUI drills (lusrmgr, regedit, Task Manager, services.msc, wf.msc,
 Windows Security), then auto Phase-2 prep.

   powershell.exe -ExecutionPolicy Bypass -File C:\HardeningLab\hardening_quest.ps1
================================================================================
#>
[CmdletBinding()]
param()

# Tools opened from this window inherit its admin token, so re-launch elevated once.
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

function Test-Answer([string]$Got, [string[]]$Accept) {
    $g = $Got.Trim().Trim('"').ToLower()
    return ($Accept | ForEach-Object { $_.ToLower() }) -contains $g
}

# Open = what to type at the prompt to launch the tool. Task = goal only.
# 'answer' steps: find something in the GUI and name it. 'auto' steps: fix it in the GUI;
# the quest notices on its own within a few seconds. Answers live in the LAST hint.
$Levels = @(
    @{
        Title = 'Notepad - read the briefing'
        Open  = 'notepad C:\HardeningLab\briefing.txt'
        Task  = 'What is your team number?  answer <NN>'
        Type  = 'answer'
        Check = { param($a) Test-Answer $a @($TeamNN, [string][int]$TeamNN) }
        Hints = @('Type the Open line at the hardening prompt and press Enter', 'Look for the line that starts with Team:', "answer $TeamNN")
    },
    @{
        Title = 'Local Users and Groups - find a bad admin'
        Open  = @('lusrmgr.msc', 'notepad C:\HardeningLab\authorized_users.txt')
        Task  = "Open Groups > Administrators and compare with the list.`nWhich AUTHORIZED user should not be an admin?  answer <username>"
        Type  = 'answer'
        Check = { param($a) Test-Answer $a @('bjones') }
        Hints = @('Double-click Administrators in the Groups folder to see its members', 'The list says this person is a standard user in Sales', 'answer bjones')
    },
    @{
        Title = 'Local Users and Groups - fix Administrators'
        Open  = 'lusrmgr.msc'
        Task  = "Remove every Administrators member the list does not name as an admin.`n(select the member > Remove > OK)"
        Type  = 'auto'
        Check = {
            $a = Get-AdminNames
            ($a -notcontains 'tempadmin') -and ($a -notcontains 'bjones') -and
                [bool](Get-LocalUser -Name 'bjones' -EA SilentlyContinue)
        }
        Hints = @('Only Administrator, student, and range accounts belong in this group', 'Two must go: a temporary admin and the sales user - keep their accounts for now', 'Remove tempadmin and bjones from Administrators')
    },
    @{
        Title = 'Local Users and Groups - former employee'
        Open  = @('notepad C:\HardeningLab\hr_memo.txt', 'lusrmgr.msc')
        Task  = "Do exactly what the HR memo asks.`n(Users > double-click the user > General tab)"
        Type  = 'auto'
        Check = {
            $u = Get-LocalUser -Name 'jmiller' -EA SilentlyContinue
            (-not $u) -or (-not $u.Enabled)
        }
        Hints = @('The memo says keep the account, so do not delete it', 'There is a checkbox on the General tab for this', 'Open jmiller > tick "Account is disabled" > OK')
    },
    @{
        Title = 'Local Users and Groups - unauthorized accounts'
        Open  = 'lusrmgr.msc'
        Task  = "In Users, delete accounts that are not on the authorized list.`nLeave built-in accounts and the disabled HR-hold account."
        Type  = 'auto'
        Check = {
            foreach ($u in @('guestuser', 'tempadmin')) {
                if (Get-LocalUser -Name $u -EA SilentlyContinue) { return $false }
            }
            foreach ($u in @('asmith', 'bjones', 'cwong')) {
                if (-not (Get-LocalUser -Name $u -EA SilentlyContinue)) { return $false }
            }
            $true
        }
        Hints = @('Compare the Users folder with authorized_users.txt', 'One looks like a guest, one is a leftover temporary admin', 'Right-click guestuser and tempadmin > Delete > Yes')
    },
    @{
        Title = 'Registry Editor - find a startup entry'
        Open  = 'regedit'
        Task  = "Go to HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run`nWhich value starts a program from C:\ProgramData?  answer <value name>"
        Type  = 'answer'
        Check = { param($a) Test-Answer $a @('SysHealthUpdate') }
        Hints = @('Paste the path into the address bar at the top of regedit', 'Read the Data column of each value', 'answer SysHealthUpdate')
    },
    @{
        Title = 'Registry Editor - remove it'
        Open  = 'regedit'
        Task  = 'Delete that value. Leave every other value alone.'
        Type  = 'auto'
        Check = { [string]::IsNullOrEmpty((Get-ItemProperty $RunKey -EA SilentlyContinue).SysHealthUpdate) }
        Hints = @('It is the value you named in the last step', 'Right-click the value > Delete > Yes', 'Delete SysHealthUpdate under ...\CurrentVersion\Run')
    },
    @{
        Title = 'Task Manager - end the process'
        Open  = 'taskmgr'
        Task  = "That startup entry already launched a program. Find it and end it.`n(More details > Details tab)"
        Type  = 'auto'
        Check = { -not (Get-Process -Name 'health_update' -EA SilentlyContinue) }
        Hints = @('Click the Name column to sort the Details tab', 'Its name matches the .exe in C:\ProgramData\SysHealth', 'Right-click health_update.exe > End task')
    },
    @{
        Title = 'Services - find the rogue service'
        Open  = 'services.msc'
        Task  = "One service runs a PowerShell script from C:\ProgramData.`nWhat is its Service name?  answer <service name>"
        Type  = 'answer'
        Check = { param($a) Test-Answer $a @('SysCacheSvc', 'System Cache Service') }
        Hints = @('Double-click a service: the General tab shows Service name and Path to executable', 'It has no description and a generic name with Cache in it', 'answer SysCacheSvc')
    },
    @{
        Title = 'Services - disable it'
        Open  = 'services.msc'
        Task  = "Open that service: Stop it if it is running, set Startup type to Disabled, Apply."
        Type  = 'auto'
        Check = {
            $s = Get-Service -Name 'SysCacheSvc' -EA SilentlyContinue
            (-not $s) -or ($s.StartType -eq 'Disabled' -and $s.Status -ne 'Running')
        }
        Hints = @('Startup type is a dropdown on the General tab', 'Choose Disabled - Manual still lets it start', 'System Cache Service > Startup type: Disabled > Apply')
    },
    @{
        Title = 'Windows Firewall - find the bad rule'
        Open  = 'wf.msc'
        Task  = "Look at Inbound Rules. One enabled rule is for remote support.`nWhich local port does it open?  answer <port>"
        Type  = 'answer'
        Check = { param($a) Test-Answer $a @('5555', 'tcp 5555', '5555/tcp') }
        Hints = @('Scroll right to the Local Port column', 'The rule is named Remote Admin Support', 'answer 5555')
    },
    @{
        Title = 'Windows Firewall - remove it'
        Open  = 'wf.msc'
        Task  = "Disable or delete that rule. Do NOT touch 'DCIG Lab RDP Access'."
        Type  = 'auto'
        Check = {
            $r = Get-NetFirewallRule -DisplayName 'Remote Admin Support' -EA SilentlyContinue
            (-not $r) -or (@($r | Where-Object { $_.Enabled -eq 'True' }).Count -eq 0)
        }
        Hints = @('Right-click the rule in Inbound Rules', 'Disable Rule or Delete both work', 'Right-click Remote Admin Support > Disable Rule')
    },
    @{
        Title = 'Windows Security - antivirus'
        Open  = 'start windowsdefender:'
        Task  = "Virus and threat protection > Manage settings: turn Real-time protection On.`n(Also reachable: Settings > Update and Security > Windows Security)"
        Type  = 'auto'
        Check = { try { -not (Get-MpPreference).DisableRealtimeMonitoring } catch { $false } }
        Hints = @('Click Virus and threat protection, then Manage settings under its settings heading', 'Real-time protection is the first toggle; if it is greyed out, ask a mentor', 'Toggle Real-time protection to On (PowerShell: Set-MpPreference -DisableRealtimeMonitoring $false)')
    }
)

function Test-Current([string]$Answer) {
    $L = $Levels[$script:Level - 1]
    try {
        if ($L.Type -eq 'answer') { return [bool](& $L.Check $Answer) }
        return [bool](& $L.Check)
    } catch { return $false }
}

function Show-Line { Write-Host ('-' * 60) -ForegroundColor DarkGray }

function Show-Banner {
    Write-Host ''
    Write-Host '  HARDENING QUEST - Windows' -ForegroundColor Cyan
    Write-Host ("  {0} hands-on steps using the built-in Windows tools." -f $Levels.Count) -ForegroundColor DarkGray
    Write-Host ''
}

function Show-Help {
    Show-Line
    Write-Host '  task  hint  answer X  skip  progress  scoreboard  quit' -ForegroundColor Yellow
    Write-Host '  Type an Open line here to launch that tool. Fix steps pass by themselves.' -ForegroundColor DarkGray
    Show-Line
}

function Show-Task {
    if ($script:Level -gt $Levels.Count) { return }
    $L = $Levels[$script:Level - 1]
    Show-Line
    Write-Host ("STEP {0}/{1} - {2}" -f $script:Level, $Levels.Count, $L.Title) -ForegroundColor White
    $firstOpen = $true
    foreach ($o in @($L.Open)) {
        $lead = if ($firstOpen) { '  Open  ' } else { '        ' }
        Write-Host ("{0}{1}" -f $lead, $o) -ForegroundColor Cyan
        $firstOpen = $false
    }
    $first = $true
    foreach ($t in ($L.Task -split "`n")) {
        if ($first) { Write-Host ("  Task  {0}" -f $t); $first = $false }
        else { Write-Host ("        {0}" -f $t) }
    }
    if ($L.Type -eq 'auto') { Write-Host '        (passes automatically once fixed)' -ForegroundColor DarkGray }
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

function Advance {
    $pts = [Math]::Max(0, 10 - 2 * $script:Hints)
    $script:Score += $pts
    Write-Host ("OK Step complete  +{0}   (total {1})" -f $pts, $script:Score) -ForegroundColor Green
    $script:Level++
    $script:Hints = 0
    Save-Progress
    if ($script:Level -gt $Levels.Count) { Finish-Quest; return }
    Show-Task
}

# Waits for typing, but re-checks 'auto' steps every few seconds so a fix made in a
# GUI tool advances the quest without coming back to type anything.
function Read-QuestLine {
    try {
        $next = (Get-Date).AddSeconds(3)
        while (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds 250
            if ((Get-Date) -ge $next) {
                if ($Levels[$script:Level - 1].Type -eq 'auto' -and (Test-Current '')) { return $null }
                $next = (Get-Date).AddSeconds(3)
            }
        }
    } catch { }
    return Read-Host
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
    Write-Host '  Live points: Desktop "DCIG Scoreboard".' -ForegroundColor DarkGray
    Write-Host ''
}

Show-Banner
Show-Help
if ($script:Level -gt $Levels.Count) { Finish-Quest; return }
Show-Task

:quest while ($true) {
    if ($script:Level -gt $Levels.Count) { break }
    Write-Host -NoNewline "hardening:$($script:Level)> "
    $cmd = Read-QuestLine
    if ($null -eq $cmd) {
        Write-Host ''
        Advance
        continue
    }
    if ([string]::IsNullOrWhiteSpace($cmd)) {
        if ($Levels[$script:Level - 1].Type -eq 'auto' -and (Test-Current '')) { Advance }
        continue
    }
    switch -Regex ($cmd.Trim()) {
        '^help$' { Show-Help; continue }
        '^task$' { Show-Task; continue }
        '^hint$' { Show-Hint; continue }
        '^scoreboard$' { Show-Scoreboard; continue }
        '^progress$' {
            Write-Host ("  Step {0}/{1}  Score {2}" -f $script:Level, $Levels.Count, $script:Score)
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
                Write-Host '  This step passes by itself once the system is fixed.' -ForegroundColor Yellow
                continue
            }
            if (Test-Current $ans) { Advance }
            else { Write-Host '  Not it. Try hint.' -ForegroundColor Red }
            continue
        }
        default {
            try {
                Invoke-Expression $cmd | Out-Host
            } catch {
                Write-Host $_.Exception.Message -ForegroundColor Red
            }
            if ($Levels[$script:Level - 1].Type -eq 'auto' -and (Test-Current '')) { Advance }
        }
    }
}
