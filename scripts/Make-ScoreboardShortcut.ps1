<#
.SYNOPSIS
  Create a Desktop shortcut that opens the hardening scoreboard in a browser.
  On lab boxes it launches C:\HardeningLab\Open-Scoreboard.ps1 (picks Edge/Chrome/
  Firefox, or IE11 -> /lite). Elsewhere it falls back to a plain .url file.
.EXAMPLE
  .\Make-ScoreboardShortcut.ps1 -Url 'http://172.31.31.2:8080/'
  .\Make-ScoreboardShortcut.ps1 -Url 'http://172.31.31.2:8080/' -AlsoUserDesktop student
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Url,
    [string]$AlsoUserDesktop = '',
    [string]$LabRoot = 'C:\HardeningLab'
)

if ($Url -notmatch '/$') { $Url = "$Url/" }
$opener = Join-Path $LabRoot 'Open-Scoreboard.ps1'

function Write-ShortcutFiles([string]$DesktopDir) {
    if (-not $DesktopDir) { return }
    New-Item -ItemType Directory -Force -Path $DesktopDir | Out-Null

    # Older versions left three icons, and the .lnk pointed straight at a URL (broken)
    foreach ($old in @('DCIG Scoreboard.url', 'DCIG Scoreboard.html', 'DCIG Scoreboard.lnk')) {
        Remove-Item (Join-Path $DesktopDir $old) -Force -EA SilentlyContinue
    }

    if (Test-Path $opener) {
        try {
            $w = New-Object -ComObject WScript.Shell
            $s = $w.CreateShortcut((Join-Path $DesktopDir 'DCIG Scoreboard.lnk'))
            $s.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $s.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$opener`""
            $s.WorkingDirectory = $LabRoot
            $s.WindowStyle = 7
            $s.IconLocation = "$env:ProgramFiles\Internet Explorer\iexplore.exe,0"
            $s.Description = 'DCIG Hardening live scoreboard'
            $s.Save()
            return
        } catch { }
    }

    "[InternetShortcut]`r`nURL=$Url`r`n" |
        Set-Content -Path (Join-Path $DesktopDir 'DCIG Scoreboard.url') -Encoding ASCII
}

$public = Join-Path $env:PUBLIC 'Desktop'
if (Test-Path (Split-Path $public -Parent)) { Write-ShortcutFiles $public }

$userDesk = [Environment]::GetFolderPath('Desktop')
if ($userDesk) { Write-ShortcutFiles $userDesk }

if ($AlsoUserDesktop) {
    $other = "C:\Users\$AlsoUserDesktop\Desktop"
    Write-ShortcutFiles $other
    try { icacls $other /grant "${AlsoUserDesktop}:(OI)(CI)(M)" | Out-Null } catch {}
}

Write-Host "[shortcut] scoreboard launcher created for $Url"
