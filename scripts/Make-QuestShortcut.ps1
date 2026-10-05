<#
.SYNOPSIS
  Create Desktop shortcuts that launch the Windows Hardening Quest (Phase 1).
  Double-click opens an elevated PowerShell window (one UAC Yes); quest finish
  auto-starts Phase 2.
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

# Shared launcher body: start elevated so HKLM / firewall / Defender drills work
$launchBody = @"
@echo off
title DCIG Hardening Quest
cd /d "$LabRoot"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath (Join-Path `$PSHOME 'powershell.exe') -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$questPs1`"'"
"@

function Set-LnkRunAsAdmin([string]$LnkPath) {
    # Flip the .lnk "Run as administrator" bit (byte 0x15 |= 0x20)
    try {
        if (-not (Test-Path $LnkPath)) { return }
        $bytes = [System.IO.File]::ReadAllBytes($LnkPath)
        if ($bytes.Length -gt 0x15) {
            $bytes[0x15] = $bytes[0x15] -bor 0x20
            [System.IO.File]::WriteAllBytes($LnkPath, $bytes)
        }
    } catch { }
}

function Write-QuestLaunchers([string]$DesktopDir) {
    if (-not $DesktopDir) { return }
    New-Item -ItemType Directory -Force -Path $DesktopDir | Out-Null

    $cmdPath = Join-Path $DesktopDir 'Hardening Quest.cmd'
    Set-Content -Path $cmdPath -Value $launchBody -Encoding ASCII

    try {
        $lnkPath = Join-Path $DesktopDir 'Hardening Quest.lnk'
        $w = New-Object -ComObject WScript.Shell
        $s = $w.CreateShortcut($lnkPath)
        $s.TargetPath = 'powershell.exe'
        $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$questPs1`""
        $s.WorkingDirectory = $LabRoot
        $s.WindowStyle = 1
        $s.Description = 'DCIG Hardening Quest - Phase 1 (runs as Administrator)'
        $s.IconLocation = 'imageres.dll,109'
        $s.Save()
        Set-LnkRunAsAdmin $lnkPath
    } catch { }

    try {
        icacls $DesktopDir /grant "Users:(OI)(CI)(RX)" | Out-Null
    } catch { }
}

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

New-Item -ItemType Directory -Force -Path (Join-Path $LabRoot 'bin') | Out-Null
Set-Content -Path $questCmd -Value $launchBody -Encoding ASCII

Write-Host "[quest-shortcut] Hardening Quest Desktop launchers created (Run as Administrator)"
