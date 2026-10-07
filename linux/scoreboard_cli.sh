#!/usr/bin/env bash
# Show the scoreboard URL, phase state, and this team's score from a terminal.
# Installed as /usr/local/bin/scoreboard; works over SSH with no browser.
CFG=/etc/hardening-lab
URL="$(cat "$CFG/scoreboard_url" 2>/dev/null)"
URL="${URL%/}"
TEAM="$(cat "$CFG/team" 2>/dev/null)"

[[ -n "$URL" ]] || { echo "Scoreboard URL not set ($CFG/scoreboard_url) - ask a mentor."; exit 1; }
echo "Scoreboard: $URL/   (open in a browser on your jumpbox)"

json="$(curl -sS -m 4 "$URL/api/status" 2>/dev/null)" || {
  echo "Could not reach the scoreboard right now."
  exit 0
}

SB_JSON="$json" TEAM="$TEAM" python3 - <<'PY'
import json, os

try:
    d = json.loads(os.environ.get("SB_JSON", ""))
except ValueError:
    print("Scoreboard returned an unexpected response.")
    raise SystemExit(0)

team = os.environ.get("TEAM", "")
if d.get("frozen"):
    state = "FROZEN"
elif d.get("phase2_open"):
    state = "OPEN"
else:
    state = "not open yet"
print("Phase 2:", state)

for r in d.get("teams", []):
    if r.get("team") == team:
        print("%s: rank %s  total %s/%s  (Linux %s, Windows %s)" % (
            r.get("name"), r.get("rank"), r.get("total"), d.get("max_points"),
            r.get("linux"), r.get("windows")))
        break
else:
    print("Team %s has no points yet." % (team or "??"))
PY
