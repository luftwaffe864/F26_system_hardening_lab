#!/usr/bin/env bash
# =============================================================================
#  DCIG System Hardening — Linux Phase 2 prepare
#  Called automatically at the end of the Linux quest (or manually by mentors).
#    sudo /usr/local/sbin/hardening-prepare-phase2
# =============================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

CFG=/etc/hardening-lab
LIB=/usr/local/lib/hardening-lab
CACHE=/usr/local/lib/.hl-cache
STUDENT="${STUDENT_USER:-student}"
SCOREBOARD_URL="$(cat "$CFG/scoreboard_url" 2>/dev/null || echo 'http://127.0.0.1:8080')"
SECRET="$(cat "$CFG/secret" 2>/dev/null || echo 'dcig-hardening-2026')"
TEAM="$(cat "$CFG/team" 2>/dev/null || echo '00')"

log() { echo "[phase2-linux] $*"; }

# Clear quest progress so Phase 2 is a fresh box story
rm -rf /home/"$STUDENT"/.hardening-quest 2>/dev/null || true

# Remove leftover Phase-1 implants if still present (students may have fixed them)
systemctl disable --now cache-sync.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/cache-sync.service
systemctl daemon-reload || true
pkill -f 'listen9999.py' 2>/dev/null || true
rm -rf /opt/PCCleaner /opt/SystemHealth 2>/dev/null || true
rm -f /etc/cron.d/pccleaner
# Keep tempadmin state as students left it; plant NEW issues below

# ---- harder Phase-2 plants --------------------------------------------------
log "planting Phase 2 findings for team $TEAM"

# 1) Stealth sudo user
if ! id sysmaint >/dev/null 2>&1; then
  useradd -m -s /bin/bash -c "System Maintenance" sysmaint
fi
echo "sysmaint:Summer2026!" | chpasswd
usermod -aG sudo sysmaint

# 2) World-writable cron dropper
cat > /var/tmp/.update_check.sh <<'EOF'
#!/bin/bash
# lab implant
exit 0
EOF
chmod 777 /var/tmp/.update_check.sh
echo "*/15 * * * * root /var/tmp/.update_check.sh" > /etc/cron.d/system-update-check
chmod 644 /etc/cron.d/system-update-check

# 3) Rogue service (different name)
install -d -m 755 "$CACHE"
cat > "$CACHE/nethelper.sh" <<'EOF'
#!/bin/bash
while true; do sleep 45; done
EOF
chmod 755 "$CACHE/nethelper.sh"
cat > /etc/systemd/system/net-helper.service <<EOF
[Unit]
Description=Network Helper Daemon
After=network.target
[Service]
Type=simple
ExecStart=$CACHE/nethelper.sh
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now net-helper.service >/dev/null 2>&1 || true

# 4) Listener on 4444
cat > "$CACHE/listen4444.py" <<'EOF'
#!/usr/bin/env python3
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 4444))
s.listen(1)
while True:
    time.sleep(60)
EOF
chmod 755 "$CACHE/listen4444.py"
pkill -f 'listen4444.py' 2>/dev/null || true
nohup python3 "$CACHE/listen4444.py" >/dev/null 2>&1 &

# 5) Fake binary in /usr/local/bin
cat > /usr/local/bin/chrome-update <<'EOF'
#!/bin/bash
# Fake updater — remove me (lab)
exit 0
EOF
chmod 755 /usr/local/bin/chrome-update

# 6) Sensitive file world-readable in home of sysmaint
echo "backup_password=Summer2026!" > /home/sysmaint/creds.txt
chmod 644 /home/sysmaint/creds.txt
chown sysmaint:sysmaint /home/sysmaint/creds.txt

# 7) UFW: ensure disabled again for Phase 2 (students must re-enable)
if command -v ufw >/dev/null 2>&1; then
  ufw --force disable >/dev/null 2>&1 || true
fi

# 8) Guest-like unused account
if ! id oldintern >/dev/null 2>&1; then
  useradd -m -s /bin/bash -c "Former intern" oldintern
fi
echo "oldintern:password" | chpasswd

printf 'phase2\n' > "$CFG/phase"

# Install / enable score agent timer
cat > /etc/systemd/system/hardening-score-agent.service <<EOF
[Unit]
Description=Hardening lab score agent
After=network.target
[Service]
Type=oneshot
ExecStart=$LIB/score_agent.sh
EOF
cat > /etc/systemd/system/hardening-score-agent.timer <<'EOF'
[Unit]
Description=Hardening lab score agent timer
[Timer]
OnBootSec=20s
OnUnitActiveSec=20s
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now hardening-score-agent.timer >/dev/null 2>&1 || true

# Notify scoreboard that Linux is ready (HMAC)
sig=$(printf 'ready|%s|linux' "$TEAM" | openssl dgst -sha256 -hmac "$SECRET" 2>/dev/null | awk '{print $NF}')
if [[ -z "$sig" ]]; then
  sig=$(python3 - <<PY
import hmac,hashlib
print(hmac.new(b"$SECRET", b"ready|$TEAM|linux", hashlib.sha256).hexdigest())
PY
)
fi
curl -sS -m 5 -X POST "$SCOREBOARD_URL/api/ready" \
  -H 'Content-Type: application/json' \
  -d "{\"team\":\"$TEAM\",\"os\":\"linux\",\"sig\":\"$sig\"}" >/dev/null 2>&1 || \
  log "scoreboard ready-ping failed (ok if board not up yet)"

# Student-facing marker
cat > /home/"$STUDENT"/PHASE2.txt <<EOF
Phase 2 is ready on this Linux box (Team $TEAM).

Find and fix hardening issues. The score agent checks about every 20 seconds
and posts points to the room scoreboard when Phase 2 is opened by mentors.

Hints (high level only):
  - Extra privileged accounts
  - Persistence (cron / systemd)
  - Unexpected listeners
  - Fake tools in PATH
  - Firewall status
  - Sensitive files with weak permissions
EOF
chown "$STUDENT:$STUDENT" /home/"$STUDENT"/PHASE2.txt

log "Phase 2 prep complete for team $TEAM"
