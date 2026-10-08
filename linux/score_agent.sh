#!/usr/bin/env bash
# =============================================================================
#  DCIG System Hardening — Linux score agent (Phase 2)
#  Machine-state checks only — no typed answers.
#  25 findings / 295 pts:  8 Easy (5), 7 Medium (10), 5 Hard (15),
#                          3 Very Hard (20), 2 Almost Impossible (25).
#  Point values MUST match scoreboard/server.py (the board rejects mismatches).
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

ssh_sets_yes() {
  # $1 = directive name; true if any sshd file sets it to yes
  grep -RiqE "^\s*${1}\s+yes" /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null
}

owner_only() {
  # true if neither group nor other can read the file (owner-only / removed exposure)
  local m g o
  m="$(stat -c %a "$1" 2>/dev/null)" || return 1
  m="$(printf '%03d' "$((10#$m))" 2>/dev/null)" || m="$m"
  g="${m: -2:1}"; o="${m: -1}"
  (( (g & 4) == 0 && (o & 4) == 0 ))
}

STUDENT_HOME=$(getent passwd student 2>/dev/null | cut -d: -f6)
STUDENT_HOME=${STUDENT_HOME:-/home/student}

# ========================= EASY (5) =========================
# LE1 remove oldintern
if ! id oldintern >/dev/null 2>&1; then post LE1 5; fi
# LE2 remove gamesuser
if ! id gamesuser >/dev/null 2>&1; then post LE2 5; fi
# LE3 remove snap-repair
if [[ ! -e /usr/local/bin/snap-repair ]]; then post LE3 5; fi
# LE4 remove CodecPack
if [[ ! -e /opt/CodecPack ]]; then post LE4 5; fi
# LE5 remove wifi-notes.txt
if [[ ! -e "$STUDENT_HOME/Documents/wifi-notes.txt" ]]; then post LE5 5; fi
# LE6 student home not world-writable (other-write bit clear)
home_mode="$(stat -c %a "$STUDENT_HOME" 2>/dev/null || echo '')"
if [[ -n "$home_mode" ]]; then
  home_mode="$(printf '%03d' "$((10#$home_mode))" 2>/dev/null || echo "$home_mode")"
  o="${home_mode: -1}"
  if (( (o & 2) == 0 )); then post LE6 5; fi
fi
# LE7 world-readable account-database backup removed or locked down (no group/other read)
if [[ ! -e /var/backups/passwd.lab.bak ]]; then
  post LE7 5
elif owner_only /var/backups/passwd.lab.bak; then
  post LE7 5
fi
# LE8 exposed private key removed or chmod to owner-only
if [[ ! -e "$STUDENT_HOME/.ssh/id_rsa_backup" ]]; then
  post LE8 5
elif owner_only "$STUDENT_HOME/.ssh/id_rsa_backup"; then
  post LE8 5
fi

# ========================= MEDIUM (10) =========================
# LM1 sysmaint not in sudo / deleted
if ! id sysmaint >/dev/null 2>&1 || ! id -nG sysmaint 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then
  post LM1 10
fi
# LM2 bad sudoers drop-in removed
if [[ ! -e /etc/sudoers.d/99-helpdesk-temp ]]; then post LM2 10; fi
# LM3 cron.d + script gone
if [[ ! -e /etc/cron.d/system-update-check ]] && [[ ! -e /var/tmp/.update_check.sh ]]; then
  post LM3 10
fi
# LM4 hosts.equiv trust-all removed / neutralized
if [[ ! -e /etc/hosts.equiv ]] || ! grep -qE '^[[:space:]]*\+' /etc/hosts.equiv 2>/dev/null; then
  post LM4 10
fi
# LM5 no listener on 5555
if ! ss -tln 2>/dev/null | grep -q ':5555'; then post LM5 10; fi
# LM6 creds.txt gone or 600
if [[ ! -e /home/sysmaint/creds.txt ]]; then
  post LM6 10
elif [[ "$(stat -c %a /home/sysmaint/creds.txt 2>/dev/null)" == "600" ]]; then
  post LM6 10
fi
# LM7 PermitEmptyPasswords not yes
empty_ok=1
[[ -f /etc/ssh/sshd_config.d/98-lab-empty.conf ]] && empty_ok=0
ssh_sets_yes PermitEmptyPasswords && empty_ok=0
if [[ "$empty_ok" -eq 1 ]]; then post LM7 10; fi

# ========================= HARD (15) =========================
# LH1 net-helper stopped+disabled
if ! systemctl is-active net-helper >/dev/null 2>&1 && ! systemctl is-enabled net-helper >/dev/null 2>&1; then
  post LH1 15
fi
# LH2 rc.local cleaned
if [[ ! -e /etc/rc.local ]] || ! grep -q 'hl-cache/beacon\|lab persistence' /etc/rc.local 2>/dev/null; then
  post LH2 15
fi
# LH3 vault2 secrets fixed (dir not world-writable AND file not world-writable)
if [[ ! -e /opt/vault2/db.conf ]]; then
  post LH3 15
else
  dmode="$(stat -c %a /opt/vault2 2>/dev/null)"
  fmode="$(stat -c %a /opt/vault2/db.conf 2>/dev/null)"
  if [[ "$dmode" != "777" ]] && [[ "$fmode" != "666" ]]; then post LH3 15; fi
fi
# LH4 no listener on 31337
if ! ss -tln 2>/dev/null | grep -q ':31337'; then post LH4 15; fi
# LH5 root crontab beacon line gone
if ! crontab -l 2>/dev/null | grep -q 'hl-beacon'; then post LH5 15; fi

# ========================= VERY HARD (20) =========================
# LV1 backup-tool not setuid / removed
if [[ ! -e /usr/local/bin/backup-tool ]]; then
  post LV1 20
elif ! [[ -u /usr/local/bin/backup-tool ]]; then
  post LV1 20
fi
# LV2 root authorized_keys backdoor gone
if [[ ! -e /root/.ssh/authorized_keys ]] || ! grep -q 'lab-backdoor' /root/.ssh/authorized_keys 2>/dev/null; then
  post LV2 20
fi
# LV3 no second UID 0 account besides root
if ! awk -F: '($3==0) && ($1!="root"){found=1} END{exit !found}' /etc/passwd 2>/dev/null; then
  post LV3 20
fi

# ========================= ALMOST IMPOSSIBLE (25) =========================
# LX1 capability backdoor removed or capability stripped
if [[ ! -e /usr/local/bin/.sysdiag ]]; then
  post LX1 25
elif ! getcap /usr/local/bin/.sysdiag 2>/dev/null | grep -qi 'cap_setuid'; then
  post LX1 25
fi
# LX2 login-time update-motd persistence removed/neutralized
MOTD=/etc/update-motd.d/99-dcig-telemetry
if [[ ! -e "$MOTD" ]] || [[ ! -x "$MOTD" ]] || ! grep -q 'hl-motd-beacon' "$MOTD" 2>/dev/null; then
  post LX2 25
fi

exit 0
