#!/usr/bin/env bash
# =============================================================================
#  DCIG System Hardening — Linux score agent (Phase 2)
#  Machine-state checks only — no typed answers.
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

# --- EASY ---
# L2-02 remove oldintern (10)
if ! id oldintern >/dev/null 2>&1; then post L2-02 10; fi
# L2-09 remove gamesuser (10)
if ! id gamesuser >/dev/null 2>&1; then post L2-09 10; fi
# L2-06 remove snap-repair (10)
if [[ ! -e /usr/local/bin/snap-repair ]]; then post L2-06 10; fi
# L2-10 remove CodecPack (10)
if [[ ! -e /opt/CodecPack ]]; then post L2-10 10; fi
# L2-11 remove wifi-notes.txt (10)
STUDENT_HOME=$(getent passwd student 2>/dev/null | cut -d: -f6)
STUDENT_HOME=${STUDENT_HOME:-/home/student}
if [[ ! -e "$STUDENT_HOME/Documents/wifi-notes.txt" ]]; then post L2-11 10; fi

# --- MEDIUM ---
# L2-01 sysmaint not in sudo / deleted (15)
if ! id sysmaint >/dev/null 2>&1 || ! id -nG sysmaint 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then
  post L2-01 15
fi
# L2-07 creds.txt gone or 600 (10)
if [[ ! -e /home/sysmaint/creds.txt ]]; then
  post L2-07 10
elif [[ "$(stat -c %a /home/sysmaint/creds.txt 2>/dev/null)" == "600" ]]; then
  post L2-07 10
fi
# L2-03 cron.d + script gone (15)
if [[ ! -e /etc/cron.d/system-update-check ]] && [[ ! -e /var/tmp/.update_check.sh ]]; then
  post L2-03 15
fi
# L2-05 no listener on 5555 (15)
if ! ss -tln 2>/dev/null | grep -q ':5555'; then post L2-05 15; fi
# L2-08 ufw active (15)
if command -v ufw >/dev/null && ufw status 2>/dev/null | head -1 | grep -qi active; then
  post L2-08 15
fi
# L2-12 bad sudoers drop-in removed (20)
if [[ ! -e /etc/sudoers.d/99-helpdesk-temp ]]; then post L2-12 20; fi
# L2-13 PermitRootLogin not yes (15)
root_ok=1
if [[ -f /etc/ssh/sshd_config.d/99-lab-insecure.conf ]]; then root_ok=0; fi
if grep -RiqE '^\s*PermitRootLogin\s+yes' /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null; then
  root_ok=0
fi
if [[ "$root_ok" -eq 1 ]]; then post L2-13 15; fi

# --- HARD ---
# L2-04 net-helper stopped+disabled (20)
if ! systemctl is-active net-helper >/dev/null 2>&1 && ! systemctl is-enabled net-helper >/dev/null 2>&1; then
  post L2-04 20
fi
# L2-14 root crontab beacon line gone (15)
if ! crontab -l 2>/dev/null | grep -q 'hl-beacon'; then post L2-14 15; fi
# L2-15 rc.local cleaned (15)
if [[ ! -e /etc/rc.local ]] || ! grep -q 'hl-cache/beacon\|lab persistence' /etc/rc.local 2>/dev/null; then
  post L2-15 15
fi
# L2-16 root authorized_keys backdoor gone (20)
if [[ ! -e /root/.ssh/authorized_keys ]] || ! grep -q 'lab-backdoor' /root/.ssh/authorized_keys 2>/dev/null; then
  post L2-16 20
fi
# L2-17 backup-tool not setuid / removed (20)
if [[ ! -e /usr/local/bin/backup-tool ]]; then
  post L2-17 20
elif ! [[ -u /usr/local/bin/backup-tool ]]; then
  post L2-17 20
fi
# L2-18 no listener on 31337 (20)
if ! ss -tln 2>/dev/null | grep -q ':31337'; then post L2-18 20; fi
# L2-19 vault2 secrets fixed (15)
if [[ ! -e /opt/vault2/db.conf ]]; then
  post L2-19 15
elif [[ "$(stat -c %a /opt/vault2 2>/dev/null)" != "777" ]] && [[ "$(stat -c %a /opt/vault2/db.conf 2>/dev/null)" != "666" ]]; then
  # directory not world-writable AND file not world-writable
  post L2-19 15
elif [[ "$(stat -c %a /opt/vault2/db.conf 2>/dev/null)" == "600" ]] || [[ "$(stat -c %a /opt/vault2/db.conf 2>/dev/null)" == "640" ]]; then
  post L2-19 15
fi

exit 0
