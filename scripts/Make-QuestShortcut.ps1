<#
.SYNOPSIS
  Create Desktop shortcuts that launch the Windows Hardening Quest (Phase 1).
  Double-click opens a PowerShell window; quest finish auto-starts Phase 2.
.EXAMPLE
  .\Make-QuestShortcut.ps1
  .\Make-QuestShortcut.ps1 -AlsoUserDesktop student
#>
[CmdletBinding()]
param(
    [string]$LabRoot = 'C:\HardeningLab',
    [string]$AlsoUserDesktop = 'student'
)

$questPs1 = Join-Path $LabRoot 'hardening_quest.ps1'
$questCmd = Join-Path $LabRoot 'bin\hardening-quest.cmd'
if (-not (Test-Path $questPs1)) {
    Write-Warning "[quest-shortcut] missing $questPs1"
    return
}

function Write-QuestLaunchers([string]$DesktopDir) {
    if (-not $DesktopDir) { return }
    New-Item -ItemType Directory -Force -Path $DesktopDir | Out-Null

    # .cmd fallback - always double-clickable, stays open after finish
    $cmdPath = Join-Path $DesktopDir 'Hardening Quest.cmd'
    @"
@echo off
title DCIG Hardening Quest
cd /d "$LabRoot"
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "$questPs1"
"@ | Set-Content -Path $cmdPath -Encoding ASCII

    # Nice .lnk icon when COM is available
    try {
        $lnkPath = Join-Path $DesktopDir 'Hardening Quest.lnk'
        $w = New-Object -ComObject WScript.Shell
        $s = $w.CreateShortcut($lnkPath)
        $s.TargetPath = 'powershell.exe'
        $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$questPs1`""
        $s.WorkingDirectory = $LabRoot
        $s.WindowStyle = 1
        $s.Description = 'DCIG Hardening Quest - Phase 1 tool drill (auto Phase 2 on finish)'
        # Shield / admin-looking icon from imageres
        $s.IconLocation = 'imageres.dll,109'
        $s.Save()
    } catch { }

    try {
        icacls $DesktopDir /grant "Users:(OI)(CI)(RX)" | Out-Null
    } catch { }
}

# Public Desktop (all users see it at login)
$public = Join-Path $env:PUBLIC 'Desktop'
if (Test-Path (Split-Path $public -Parent)) {
    Write-QuestLaunchers $public
}

$userDesk = [Environment]::GetFolderPath('Desktop')
if ($userDesk) { Write-QuestLaunchers $userDesk }

if ($AlsoUserDesktop) {
    $other = "C:\Users\$AlsoUserDesktop\Desktop"
    Write-QuestLaunchers $other
    try {
        icacls $other /grant "${AlsoUserDesktop}:(OI)(CI)(M)" | Out-Null
    } catch { }
}

# Keep bin launcher in sync (used by mentors / PATH)
New-Item -ItemType Directory -Force -Path (Join-Path $LabRoot 'bin') | Out-Null
@"
@echo off
title DCIG Hardening Quest
cd /d "$LabRoot"
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "$questPs1"
"@ | Set-Content -Path $questCmd -Encoding ASCII

Write-Host "[quest-shortcut] Hardening Quest Desktop launchers created"
