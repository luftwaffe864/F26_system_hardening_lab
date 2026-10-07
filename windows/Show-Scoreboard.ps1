<#
 Print the scoreboard URL, phase state, and this team's score in the console.
 Used by the quest "scoreboard" command; works without a browser.
#>
$Cfg = 'C:\HardeningLab\config'
$url = (Get-Content (Join-Path $Cfg 'scoreboard_url.txt') -Raw -EA SilentlyContinue)
if (-not $url) { Write-Host '  Scoreboard URL not set - ask a mentor.' -ForegroundColor Yellow; return }
$url = $url.Trim().TrimEnd('/')
$team = (Get-Content (Join-Path $Cfg 'team.txt') -Raw -EA SilentlyContinue)
if ($team) { $team = $team.Trim() }

Write-Host "  Scoreboard: $url/"
try {
    $d = Invoke-RestMethod -Uri "$url/api/status" -TimeoutSec 4
} catch {
    Write-Host '  Could not reach the scoreboard right now.' -ForegroundColor Yellow
    return
}

$state = if ($d.frozen) { 'FROZEN' } elseif ($d.phase2_open) { 'OPEN' } else { 'not open yet' }
Write-Host "  Phase 2: $state"
$r = $d.teams | Where-Object { $_.team -eq $team } | Select-Object -First 1
if ($r) {
    Write-Host ("  {0}: rank {1}  total {2}/{3}  (Linux {4}, Windows {5})" -f `
        $r.name, $r.rank, $r.total, $d.max_points, $r.linux, $r.windows) -ForegroundColor Cyan
} else {
    Write-Host "  Team $team has no points yet."
}
