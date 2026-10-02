<#
.SYNOPSIS
  Create Desktop shortcuts that open the hardening scoreboard in a browser.
.EXAMPLE
  .\Make-ScoreboardShortcut.ps1 -Url 'http://192.168.1.7:8080/'
  .\Make-ScoreboardShortcut.ps1 -Url 'http://192.168.1.7:8080/' -AlsoUserDesktop student
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Url,
    [string]$AlsoUserDesktop = ''
)

if ($Url -notmatch '/$') { $Url = "$Url/" }

function Write-ShortcutFiles([string]$DesktopDir) {
    if (-not $DesktopDir) { return }
    New-Item -ItemType Directory -Force -Path $DesktopDir | Out-Null

    # Internet Shortcut — double-click opens default browser
    $urlFile = Join-Path $DesktopDir 'DCIG Scoreboard.url'
    @"
[InternetShortcut]
URL=$Url
IconIndex=0
"@ | Set-Content -Path $urlFile -Encoding ASCII

    # HTML redirect fallback (also double-clickable)
    $htmlFile = Join-Path $DesktopDir 'DCIG Scoreboard.html'
    @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta http-equiv="refresh" content="0; url=$Url"/>
  <title>DCIG Hardening Scoreboard</title>
  <script>window.location.replace("$Url");</script>
</head>
<body style="font-family:Segoe UI,sans-serif;background:#0b1220;color:#e8eefc;padding:2rem">
  <h1>Opening scoreboard…</h1>
  <p>If nothing happens, <a href="$Url" style="color:#3dd6c6">click here</a>.</p>
</body>
</html>
"@ | Set-Content -Path $htmlFile -Encoding UTF8

    # Optional .lnk via WScript if available (nicer icon)
    try {
        $lnkPath = Join-Path $DesktopDir 'DCIG Scoreboard.lnk'
        $w = New-Object -ComObject WScript.Shell
        $s = $w.CreateShortcut($lnkPath)
        $s.TargetPath = $Url
        $s.Description = 'DCIG Hardening live scoreboard'
        $s.Save()
    } catch { }
}

# Public Desktop (all users)
$public = Join-Path $env:PUBLIC 'Desktop'
if (Test-Path (Split-Path $public -Parent)) {
    Write-ShortcutFiles $public
}

# Current user Desktop
$userDesk = [Environment]::GetFolderPath('Desktop')
if ($userDesk) { Write-ShortcutFiles $userDesk }

# Optional named user (e.g. student)
if ($AlsoUserDesktop) {
    $other = "C:\Users\$AlsoUserDesktop\Desktop"
    Write-ShortcutFiles $other
    try {
        icacls $other /grant "${AlsoUserDesktop}:(OI)(CI)(M)" | Out-Null
    } catch {}
}

Write-Host "[shortcut] scoreboard launchers created for $Url"
