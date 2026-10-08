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

# Points only after prepare confirmed the plant (no free points when a plant failed).
PLANT=/var/lib/hardening-lab/planted
ok() { [[ -f "$PLANT/$1" ]]; }
STUDENT_HOME=$(getent passwd student 2>/dev/null | cut -d: -f6)
STUDENT_HOME=${STUDENT_HOME:-/home/student}

# --- EASY (5) ---
ok LE-01 && ! id oldintern >/dev/null 2>&1 && post LE-01 5
ok LE-02 && ! id gamesuser >/dev/null 2>&1 && post LE-02 5
ok LE-03 && [[ ! -e /usr/local/bin/snap-repair ]] && post LE-03 5
ok LE-04 && [[ ! -e /opt/CodecPack ]] && post LE-04 5
ok LE-05 && [[ ! -e "$STUDENT_HOME/Documents/wifi-notes.txt" ]] && post LE-05 5
ok LE-06 && [[ ! -e /var/tmp/backup-passwords.txt ]] && post LE-06 5
ok LE-07 && ! ss -tln 2>/dev/null | grep -q ':5555' && post LE-07 5
ok LE-08 && command -v ufw >/dev/null && ufw status 2>/dev/null | head -1 | grep -qi active && post LE-08 5

# --- MEDIUM (10) ---
if ok LM-01 && { ! id sysmaint >/dev/null 2>&1 || ! id -nG sysmaint 2>/dev/null | tr ' ' '\n' | grep -qx sudo; }; then
  post LM-01 10
fi
ok LM-02 && [[ ! -e /etc/cron.d/system-update-check ]] && [[ ! -e /var/tmp/.update_check.sh ]] && post LM-02 10
ok LM-03 && [[ ! -e /etc/sudoers.d/99-helpdesk-temp ]] && post LM-03 10
if ok LM-04; then
  t="$(/usr/sbin/sshd -T 2>/dev/null || true)"
  grep -qx 'permitrootlogin yes' <<<"$t" || post LM-04 10
fi
if ok LM-05; then
  if [[ ! -e /home/sysmaint/creds.txt ]]; then post LM-05 10
  elif [[ "$(stat -c %a /home/sysmaint/creds.txt 2>/dev/null)" == "600" ]]; then post LM-05 10
  fi
fi
if ok LM-06 && ! systemctl is-active net-helper >/dev/null 2>&1 && ! systemctl is-enabled net-helper >/dev/null 2>&1; then
  post LM-06 10
fi
if ok LM-07; then
  if [[ ! -e /opt/vault2/db.conf ]]; then post LM-07 10
  elif [[ "$(stat -c %a /opt/vault2 2>/dev/null)" != "777" && "$(stat -c %a /opt/vault2/db.conf 2>/dev/null)" != "666" ]]; then
    post LM-07 10
  fi
fi

# --- HARD (15) ---
ok LH-01 && ! crontab -l 2>/dev/null | grep -q 'hl-beacon' && post LH-01 15
ok LH-02 && { [[ ! -e /etc/rc.local ]] || ! grep -q 'hl-cache/beacon\|lab persistence' /etc/rc.local 2>/dev/null; } && post LH-02 15
ok LH-03 && { [[ ! -e /root/.ssh/authorized_keys ]] || ! grep -q 'lab-backdoor' /root/.ssh/authorized_keys 2>/dev/null; } && post LH-03 15
if ok LH-04; then
  if [[ ! -e /usr/local/bin/backup-tool ]]; then post LH-04 15
  elif [[ ! -u /usr/local/bin/backup-tool ]]; then post LH-04 15
  fi
fi
ok LH-05 && ! ss -tln 2>/dev/null | grep -q ':31337' && post LH-05 15

# --- VERY HARD (20) ---
if ok LV-01; then
  if [[ ! -e /usr/local/libexec/health-check ]]; then post LV-01 20
  elif ! getcap /usr/local/libexec/health-check 2>/dev/null | grep -q 'cap_setuid'; then post LV-01 20
  fi
fi
if ok LV-02 && ! systemctl is-enabled log-rotate-helper.timer >/dev/null 2>&1; then
  post LV-02 20
fi
ok LV-03 && [[ ! -e /etc/sudoers.d/010-staff ]] && post LV-03 20

# --- ALMOST IMPOSSIBLE (25) ---
ok LI-01 && [[ ! -e /etc/cron.hourly/.sync-cache ]] && post LI-01 25
if ok LI-02; then
  shell="$(getent passwd polkitd-helper 2>/dev/null | cut -d: -f7)"
  if [[ -z "$shell" || "$shell" != */bin/bash && "$shell" != */bin/sh ]]; then
    post LI-02 25
  fi
fi

exit 0
