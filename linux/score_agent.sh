#!/usr/bin/env bash
# =============================================================================
#  DCIG System Hardening — Linux score agent (Phase 2)
#  Runs via systemd timer. POSTs newly-passed findings to the scoreboard.
# =============================================================================
set -euo pipefail

CFG=/etc/hardening-lab
STATE=/var/lib/hardening-lab
mkdir -p "$STATE"
SCOREBOARD_URL="$(cat "$CFG/scoreboard_url" 2>/dev/null || echo 'http://127.0.0.1:8080')"
SECRET="$(cat "$CFG/secret" 2>/dev/null || echo 'dcig-hardening-2026')"
TEAM="$(cat "$CFG/team" 2>/dev/null || echo '00')"
OS_NAME=linux

sign() {
  local fid="$1" pts="$2"
  python3 - <<PY
import hmac, hashlib
print(hmac.new(b"""$SECRET""", f"{"""$TEAM"""}|{"""$OS_NAME"""}|{"""$fid"""}|{"""$pts"""}".encode(), hashlib.sha256).hexdigest())
PY
}

post() {
  local fid="$1" pts="$2" marker="$STATE/got_$fid"
  [[ -f "$marker" ]] && return 0
  local sig
  sig="$(sign "$fid" "$pts")"
  local resp
  resp="$(curl -sS -m 5 -X POST "$SCOREBOARD_URL/api/score" \
    -H 'Content-Type: application/json' \
    -d "{\"team\":\"$TEAM\",\"os\":\"$OS_NAME\",\"finding_id\":\"$fid\",\"points\":$pts,\"sig\":\"$sig\"}" || true)"
  if printf '%s' "$resp" | grep -q '"ok": true\|"ok":true'; then
    touch "$marker"
  fi
}

# Finding checks — ids must match ANSWER_KEY.txt
# L2-01 remove sysmaint from sudo or delete (15)
if ! id sysmaint >/dev/null 2>&1 || ! id -nG sysmaint 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then
  post L2-01 15
fi
# L2-02 remove oldintern account (10)
if ! id oldintern >/dev/null 2>&1; then
  post L2-02 10
fi
# L2-03 remove cron persistence (15)
if [[ ! -e /etc/cron.d/system-update-check ]] && [[ ! -e /var/tmp/.update_check.sh ]]; then
  post L2-03 15
fi
# L2-04 stop/disable net-helper (20)
if ! systemctl is-active net-helper >/dev/null 2>&1 && ! systemctl is-enabled net-helper >/dev/null 2>&1; then
  post L2-04 20
fi
# L2-05 kill 4444 listener (15)
if ! ss -tln 2>/dev/null | grep -q ':4444'; then
  post L2-05 15
fi
# L2-06 remove fake chrome-update (10)
if [[ ! -e /usr/local/bin/chrome-update ]]; then
  post L2-06 10
fi
# L2-07 tighten creds.txt to 600 or delete (10)
if [[ ! -e /home/sysmaint/creds.txt ]]; then
  post L2-07 10
elif [[ "$(stat -c %a /home/sysmaint/creds.txt 2>/dev/null)" == "600" ]]; then
  post L2-07 10
fi
# L2-08 ufw active (15)
if command -v ufw >/dev/null && ufw status 2>/dev/null | head -1 | grep -qi active; then
  post L2-08 15
fi

exit 0
