<#
 Open the live scoreboard in the best browser on this box.
 Server 2019 often only has IE11, which cannot run the full page, so IE gets /lite.
#>
$Cfg = 'C:\HardeningLab\config'
$url = (Get-Content (Join-Path $Cfg 'scoreboard_url.txt') -Raw -EA SilentlyContinue)
if (-not $url) { $url = 'http://172.31.31.2:8080' }
$url = $url.Trim().TrimEnd('/') + '/'

$modern = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
    "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if ($modern) {
    Start-Process -FilePath $modern -ArgumentList $url
} else {
    $ie = "$env:ProgramFiles\Internet Explorer\iexplore.exe"
    if (Test-Path $ie) { Start-Process -FilePath $ie -ArgumentList ($url + 'lite') }
    else { Start-Process ($url + 'lite') }
}
