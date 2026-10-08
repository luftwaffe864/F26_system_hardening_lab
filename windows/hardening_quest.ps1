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

# QuickEdit freezes the script whenever the student clicks inside this window,
# which stops the auto-checks until a key is pressed.
try {
    Add-Type -Namespace DCIG -Name Con -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int h);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(System.IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(System.IntPtr h, uint m);
'@ -EA Stop
    $hIn = [DCIG.Con]::GetStdHandle(-10)
    $mode = [uint32]0
    if ([DCIG.Con]::GetConsoleMode($hIn, [ref]$mode)) {
        [void][DCIG.Con]::SetConsoleMode($hIn, [uint32](($mode -band 0xFFBF) -bor 0x80))
    }
} catch { }

$LabRoot = 'C:\HardeningLab'
$Cfg     = Join-Path $LabRoot 'config'
$Desk    = Join-Path $env:PUBLIC 'Desktop'
# Machine-wide, not per-profile: elevation may run the quest under a different account
$StateDir = Join-Path $Cfg 'quest'
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

function Open-LabFile([string]$Name) {
    $p = Join-Path $Desk $Name
    if (-not (Test-Path $p)) { $p = Join-Path $LabRoot $Name }
    Start-Process notepad.exe -ArgumentList "`"$p`""
}

# Open = what to type at this prompt (or in Start > Run) to launch the tool.
# 'answer' steps: find something and type answer <x>.
# 'auto' steps: Todo returns what is still wrong; the step passes when it returns nothing.
# Answers live in the LAST hint.
$Levels = @(
    @{
        Title = 'Notepad - read the briefing'
        Open  = @('briefing.txt on the Desktop   (or type: briefing)')
        Task  = 'What is your team number?  answer <NN>'
        Type  = 'answer'
        Check = { param($a) Test-Answer $a @($TeamNN, [string][int]$TeamNN) }
        Hints = @('Double-click briefing.txt on the Desktop', 'Look for the line that starts with Team:', "answer $TeamNN")
    },
    @{
        Title = 'Local Users and Groups - spot a bad admin'
        Open  = @('lusrmgr.msc', 'authorized_users.txt on the Desktop   (or type: users)')
        Task  = "Open Groups > Administrators and compare it with the list.`nName ONE member who should not be an admin.  answer <username>"
        Type  = 'answer'
        Check = { param($a) Test-Answer $a @('bjones', 'tempadmin') }
        Hints = @('Double-click Administrators in the Groups folder to see its members', 'Only the accounts under "Administrators" in the list belong there', 'answer tempadmin   (bjones is also correct)')
    },
    @{
        Title = 'Local Users and Groups - fix Administrators'
        Open  = @('lusrmgr.msc')
        Task  = "Remove BOTH members the list does not name as admins.`n(Groups > Administrators > select member > Remove > OK)`nKeep their user accounts for now."
        Type  = 'auto'
        Todo  = {
            $a = Get-AdminNames
            if ($a -contains 'tempadmin') { 'tempadmin is still in Administrators' }
            if ($a -contains 'bjones') { 'bjones is still in Administrators' }
            if (-not (Get-LocalUser -Name 'bjones' -EA SilentlyContinue)) {
                'bjones (authorized) was deleted - type skip and tell a mentor'
            }
        }
        Hints = @('Type check to see who is still left', 'One is a leftover temporary admin, the other is a Sales user', 'Remove tempadmin and bjones from Administrators')
    },
    @{
        Title = 'Local Users and Groups - former employee'
        Open  = @('hr_memo.txt on the Desktop   (or type: memo)', 'lusrmgr.msc')
        Task  = "Do exactly what the HR memo asks.`n(Users > double-click the user > General tab)"
        Type  = 'auto'
        Todo  = {
            $u = Get-LocalUser -Name 'jmiller' -EA SilentlyContinue
            if ($u -and $u.Enabled) { 'jmiller is still enabled' }
        }
        Hints = @('The memo says keep the account, so do not delete it', 'There is a checkbox on the General tab for this', 'Open jmiller > tick "Account is disabled" > OK')
    },
    @{
        Title = 'Local Users and Groups - unauthorized accounts'
        Open  = @('lusrmgr.msc', 'authorized_users.txt on the Desktop   (or type: users)')
        Task  = "In Users, delete every account that is NOT on the list.`nKEEP: everyone on the list, built-in accounts (Administrator, Guest,`nDefaultAccount, WDAGUtilityAccount), and the disabled HR-hold account."
        Type  = 'auto'
        Todo  = {
            $left = @('guestuser', 'tempadmin' | Where-Object { Get-LocalUser -Name $_ -EA SilentlyContinue }).Count
            if ($left) { "$left account(s) not on the list still exist" }
            foreach ($u in @('asmith', 'bjones', 'cwong')) {
                if (-not (Get-LocalUser -Name $u -EA SilentlyContinue)) { "$u is authorized but was deleted - type skip and tell a mentor" }
            }
        }
        Hints = @('Go down the Users folder one by one and look each name up in the list', 'Two accounts are not on the list: a guest-looking one and a leftover temporary admin', 'Right-click guestuser and tempadmin > Delete > Yes')
    },
    @{
        Title = 'Registry Editor - find a startup entry'
        Open  = @('regedit')
        Task  = "Go to HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run`nWhich value starts a program from C:\ProgramData?  answer <value name>"
        Type  = 'answer'
        Check = { param($a) Test-Answer $a @('SysHealthUpdate') }
        Hints = @('Paste the path into the address bar at the top of regedit', 'Read the Data column of each value', 'answer SysHealthUpdate')
    },
    @{
        Title = 'Registry Editor - remove it'
        Open  = @('regedit')
        Task  = 'Delete the SysHealthUpdate value. Leave every other value alone.'
        Type  = 'auto'
        Todo  = {
            if (-not [string]::IsNullOrEmpty((Get-ItemProperty $RunKey -EA SilentlyContinue).SysHealthUpdate)) {
                'SysHealthUpdate is still in the Run key'
            }
        }
        Hints = @('It is in the same Run key as the last step', 'Right-click the value > Delete > Yes', 'Delete SysHealthUpdate under ...\CurrentVersion\Run')
    },
    @{
        Title = 'Task Manager - end the process'
        Open  = @('taskmgr')
        Task  = "SysHealthUpdate already started health_update.exe. End it.`n(More details > Details tab)"
        Type  = 'auto'
        Todo  = {
            if (Get-Process -Name 'health_update' -EA SilentlyContinue) { 'health_update.exe is still running' }
        }
        Hints = @('Click the Name column on the Details tab to sort it', 'It is listed as health_update.exe', 'Right-click health_update.exe > End task')
    },
    @{
        Title = 'Services - find the rogue service'
        Open  = @('services.msc')
        Task  = "One service runs a PowerShell script from C:\ProgramData.`nDouble-click it: what is its Service name?  answer <service name>"
        Type  = 'answer'
        Check = { param($a) Test-Answer $a @('SysCacheSvc', 'System Cache Service') }
        Hints = @('The list shows Display names; the Service name is at the top of the General tab', 'Its Display name is System Cache Service', 'answer SysCacheSvc')
    },
    @{
        Title = 'Services - disable it'
        Open  = @('services.msc')
        Task  = "Open System Cache Service: set Startup type to Disabled, click Stop if`nit is running, then Apply."
        Type  = 'auto'
        Todo  = {
            $s = Get-Service -Name 'SysCacheSvc' -EA SilentlyContinue
            if ($s) {
                if ($s.StartType -ne 'Disabled') { "Startup type is still $($s.StartType)" }
                if ($s.Status -eq 'Running') { 'the service is still running' }
            }
        }
        Hints = @('Startup type is a dropdown on the General tab', 'Choose Disabled - Manual still lets it start', 'System Cache Service > Startup type: Disabled > Apply')
    },
    @{
        Title = 'Windows Firewall - find the bad rule'
        Open  = @('wf.msc')
        Task  = "Click Inbound Rules. One enabled rule is for remote support.`nWhich local port does it open?  answer <port>"
        Type  = 'answer'
        Prep  = {
            if (-not (Get-NetFirewallRule -DisplayName 'Remote Admin Support' -EA SilentlyContinue)) {
                try {
                    New-NetFirewallRule -DisplayName 'Remote Admin Support' -Direction Inbound -Action Allow `
                        -Protocol TCP -LocalPort 5555 -Profile Any -Enabled True `
                        -Description 'Vendor remote support listener' -EA Stop | Out-Null
                } catch {
                    cmd /c 'netsh advfirewall firewall add rule name="Remote Admin Support" dir=in action=allow protocol=TCP localport=5555 profile=any enable=yes >nul 2>&1' | Out-Null
                }
            }
        }
        Check = { param($a) Test-Answer $a @('5555', 'tcp 5555', '5555/tcp') }
        Hints = @('Click the Name column header to sort A-Z (press F5 if wf.msc was already open), then scroll to R', 'The rule is named Remote Admin Support; scroll right to the Local Port column', 'answer 5555')
    },
    @{
        Title = 'Windows Firewall - remove it'
        Open  = @('wf.msc')
        Task  = "Disable or delete 'Remote Admin Support'. Do NOT touch 'DCIG Lab RDP Access'."
        Type  = 'auto'
        Todo  = {
            $r = Get-NetFirewallRule -DisplayName 'Remote Admin Support' -EA SilentlyContinue
            if ($r -and @($r | Where-Object { $_.Enabled -eq 'True' }).Count -gt 0) { 'Remote Admin Support is still enabled' }
        }
        Hints = @('Right-click the rule in Inbound Rules (sort by Name, press F5 to refresh)', 'Disable Rule or Delete both work', 'Right-click Remote Admin Support > Disable Rule')
    },
    @{
        Title = 'Windows Security - antivirus'
        Open  = @('start windowsdefender:')
        Task  = "Virus and threat protection > Manage settings: turn Real-time protection On.`n(Also reachable: Start > Settings > Update and Security > Windows Security)"
        Type  = 'auto'
        Todo  = {
            $on = $false
            try { $on = [bool](Get-MpComputerStatus -EA Stop).RealTimeProtectionEnabled } catch { }
            if (-not $on) {
                try { $on = -not (Get-MpPreference -EA Stop).DisableRealtimeMonitoring } catch { }
            }
            if (-not $on) { 'Real-time protection is still off' }
        }
        Hints = @('Click Virus and threat protection, then Manage settings under its settings heading', 'Real-time protection is the first toggle; if it is greyed out, ask a mentor', 'Toggle Real-time protection to On (PowerShell: Set-MpPreference -DisableRealtimeMonitoring $false)')
    }
)

function Get-Todo {
    $L = $Levels[$script:Level - 1]
    if ($L.Type -ne 'auto') { return @() }
    try { return @(& $L.Todo | Where-Object { $_ }) } catch { return @('could not check yet') }
}

function Test-Current([string]$Answer) {
    $L = $Levels[$script:Level - 1]
    if ($L.Type -eq 'answer') {
        try { return [bool](& $L.Check $Answer) } catch { return $false }
    }
    return (@(Get-Todo).Count -eq 0)
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
    Write-Host '  task  hint  check  answer X  skip  progress  scoreboard  quit' -ForegroundColor Yellow
    Write-Host '  briefing  users  memo   open the lab files from the Desktop' -ForegroundColor Yellow
    Write-Host '  Type an Open line here or in Start > Run (Win+R) to launch the tool.' -ForegroundColor DarkGray
    Write-Host '  Fix steps pass by themselves; type check to see what is left.' -ForegroundColor DarkGray
    Show-Line
}

function Show-Task {
    if ($script:Level -gt $Levels.Count) { return }
    $L = $Levels[$script:Level - 1]
    if ($L.Prep) { try { & $L.Prep } catch { } }
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
    if ($L.Type -eq 'auto') { Write-Host '        (passes automatically once fixed - type check to see what is left)' -ForegroundColor DarkGray }
    Show-Line
}

function Show-Check {
    $L = $Levels[$script:Level - 1]
    if ($L.Type -ne 'auto') { Write-Host '  This step needs: answer <x>' -ForegroundColor Yellow; return $false }
    $todo = @(Get-Todo)
    if ($todo.Count -eq 0) { return $true }
    foreach ($t in $todo) { Write-Host ("  Still to do: {0}" -f $t) -ForegroundColor Yellow }
    return $false
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

# Waits for typing, but re-checks 'auto' steps every couple of seconds so a fix made in
# a GUI tool advances the quest without coming back to type anything.
function Read-QuestLine {
    try {
        $next = (Get-Date).AddSeconds(2)
        while (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds 250
            if ((Get-Date) -ge $next) {
                if ($Levels[$script:Level - 1].Type -eq 'auto' -and (Test-Current '')) { return $null }
                $next = (Get-Date).AddSeconds(2)
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
        Write-Host '  Phase 2 is ready. Read PHASE2.txt on the Desktop and start hardening.' -ForegroundColor Green
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
        '^check$' { if (Show-Check) { Advance }; continue }
        '^briefing(\.txt)?$' { Open-LabFile 'briefing.txt'; continue }
        '^users$|^authorized(_users)?(\.txt)?$' { Open-LabFile 'authorized_users.txt'; continue }
        '^(hr_)?memo(\.txt)?$' { Open-LabFile 'hr_memo.txt'; continue }
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
                Write-Host '  This step passes by itself once the system is fixed (type check).' -ForegroundColor Yellow
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
