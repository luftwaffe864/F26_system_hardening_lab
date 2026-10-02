#!/usr/bin/env bash
# =============================================================================
#  DCIG System Hardening — Linux Phase 2 prepare
#  Auto-run after Linux quest. Plants easy → hard findings for CyberPatriot scoring.
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

rm -rf /home/"$STUDENT"/.hardening-quest 2>/dev/null || true

# Clear Phase-1 leftovers if still present
systemctl disable --now cache-sync.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/cache-sync.service
systemctl daemon-reload || true
pkill -f 'listen9999.py' 2>/dev/null || true
rm -rf /opt/PCCleaner /opt/SystemHealth 2>/dev/null || true
rm -f /etc/cron.d/pccleaner

log "planting Phase 2 findings (easy→hard) for team $TEAM"
install -d -m 755 "$CACHE"

# ========== EASY ==========
# L2-02 unused account
if ! id oldintern >/dev/null 2>&1; then
  useradd -m -s /bin/bash -c "Former intern" oldintern
fi
echo "oldintern:password" | chpasswd

# L2-09 another unused account
if ! id gamesuser >/dev/null 2>&1; then
  useradd -m -s /bin/bash -c "Games account - unused" gamesuser
fi
echo "gamesuser:games" | chpasswd

# L2-06 fake tool in PATH (Linux-only name — not mirrored on Windows)
cat > /usr/local/bin/snap-repair <<'EOF'
#!/bin/bash
# Fake helper — remove me (lab)
exit 0
EOF
chmod 755 /usr/local/bin/snap-repair

# L2-10 fake bloat software under /opt
install -d -m 755 /opt/CodecPack
echo "Fake codec pack — uninstall/delete this folder" > /opt/CodecPack/README.txt

# L2-11 plaintext secrets in student home (Linux home/files concept)
mkdir -p /home/"$STUDENT"/Documents
cat > /home/"$STUDENT"/Documents/wifi-notes.txt <<'EOF'
DO NOT SHARE
wifi: Winter2024!
email: Password1
admin backup: Summer2026!
EOF
chown -R "$STUDENT:$STUDENT" /home/"$STUDENT"/Documents
chmod 644 /home/"$STUDENT"/Documents/wifi-notes.txt

# ========== MEDIUM ==========
# L2-01 stealth sudo user
if ! id sysmaint >/dev/null 2>&1; then
  useradd -m -s /bin/bash -c "System Maintenance" sysmaint
fi
echo "sysmaint:Summer2026!" | chpasswd
usermod -aG sudo sysmaint

# L2-07 weak perms on secrets
echo "backup_password=Summer2026!" > /home/sysmaint/creds.txt
chmod 644 /home/sysmaint/creds.txt
chown sysmaint:sysmaint /home/sysmaint/creds.txt

# L2-03 cron persistence
cat > /var/tmp/.update_check.sh <<'EOF'
#!/bin/bash
# lab implant
exit 0
EOF
chmod 777 /var/tmp/.update_check.sh
echo "*/15 * * * * root /var/tmp/.update_check.sh" > /etc/cron.d/system-update-check
chmod 644 /etc/cron.d/system-update-check

# L2-05 unexpected listener (Linux ss/netstat hunt — not a Windows firewall-rule mirror)
cat > "$CACHE/listen5555.py" <<'EOF'
#!/usr/bin/env python3
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 5555))
s.listen(1)
while True:
    time.sleep(60)
EOF
chmod 755 "$CACHE/listen5555.py"
pkill -f 'listen5555.py' 2>/dev/null || true
pkill -f 'listen4444.py' 2>/dev/null || true
nohup python3 "$CACHE/listen5555.py" >/dev/null 2>&1 &

# L2-08 firewall off
if command -v ufw >/dev/null 2>&1; then
  ufw --force disable >/dev/null 2>&1 || true
fi

# L2-12 bad sudoers drop-in (NOPASSWD for non-admin user)
if ! id helpdesk >/dev/null 2>&1; then
  useradd -m -s /bin/bash -c "Helpdesk - should not have root" helpdesk
fi
echo "helpdesk:Helpdesk1" | chpasswd
echo 'helpdesk ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-helpdesk-temp
chmod 440 /etc/sudoers.d/99-helpdesk-temp

# L2-13 PermitRootLogin yes (if sshd present)
if [[ -d /etc/ssh/sshd_config.d ]]; then
  echo 'PermitRootLogin yes' > /etc/ssh/sshd_config.d/99-lab-insecure.conf
  systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
elif [[ -f /etc/ssh/sshd_config ]]; then
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
  systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
fi

# ========== HARD ==========
# L2-04 rogue systemd service
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

# L2-14 root crontab persistence (in addition to cron.d)
(crontab -l 2>/dev/null | grep -v 'hl-beacon' || true; echo '*/20 * * * * /usr/local/lib/.hl-cache/beacon.sh >/dev/null 2>&1 # hl-beacon') | crontab -
cat > "$CACHE/beacon.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 "$CACHE/beacon.sh"

# L2-15 /etc/rc.local implant
cat > /etc/rc.local <<'EOF'
#!/bin/bash
# lab persistence — remove this file or empty it
/usr/local/lib/.hl-cache/beacon.sh >/dev/null 2>&1 &
exit 0
EOF
chmod 755 /etc/rc.local

# L2-16 backdoor SSH key on root
install -d -m 700 /root/.ssh
cat > /root/.ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILabBackdoorKeyDoNotUseInProd lab-backdoor@attacker
EOF
chmod 600 /root/.ssh/authorized_keys

# L2-17 SUID binary (harmless wrapper — still a finding)
cat > /usr/local/bin/backup-tool <<'EOF'
#!/bin/bash
# Lab SUID finding — should not be setuid
echo "backup-tool lab stub"
exit 0
EOF
chmod 4755 /usr/local/bin/backup-tool

# L2-18 stealthier listener on 31337
cat > "$CACHE/listen31337.py" <<'EOF'
#!/usr/bin/env python3
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 31337))
s.listen(1)
while True:
    time.sleep(60)
EOF
chmod 755 "$CACHE/listen31337.py"
pkill -f 'listen31337.py' 2>/dev/null || true
nohup python3 "$CACHE/listen31337.py" >/dev/null 2>&1 &

# L2-19 world-writable sensitive directory under /etc alternative: /opt/vault
install -d -m 777 /opt/vault2
echo "db_password=SuperSecret!" > /opt/vault2/db.conf
chmod 666 /opt/vault2/db.conf

printf 'phase2\n' > "$CFG/phase"
touch "$CFG/phase2_auto_done" 2>/dev/null || true

# Score agent timer
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

cat > /home/"$STUDENT"/PHASE2.txt <<EOF
Phase 2 is ready on this Linux box (Team $TEAM).

This is CyberPatriot-style scoring: fix the MACHINE. The score agent checks
system state about every 20 seconds — you do NOT type answers.

Linux-focused categories (easy → hard):
  - Unused local accounts
  - Sketchy PATH /opt artifacts and home-directory secrets
  - ufw firewall status
  - Extra sudo / sudoers.d privileges
  - cron.d, root crontab, rc.local persistence
  - Rogue systemd services and unexpected listeners (ss)
  - SSH hardening (PermitRootLogin, authorized_keys)
  - SUID binaries and world-writable secret dirs

These are NOT the same plants as the Windows box — hunt Linux artifacts.

Mentors open the room scoreboard when the race starts.
EOF
chown "$STUDENT:$STUDENT" /home/"$STUDENT"/PHASE2.txt

log "Phase 2 prep complete for team $TEAM"
