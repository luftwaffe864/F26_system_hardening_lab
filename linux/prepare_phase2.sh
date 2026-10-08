#!/usr/bin/env bash
# =============================================================================
#  DCIG System Hardening — Linux Phase 2 prepare
#  Auto-run after Linux quest. Plants findings across 5 difficulty tiers for
#  machine-state scoring:
#    8 Easy (5) + 7 Medium (10) + 5 Hard (15) + 3 Very Hard (20)
#    + 2 Almost Impossible (25) = 295 points.
#  IDs: LE1-8, LM1-7, LH1-5, LV1-3, LX1-2.  NOT a mirror of the Windows box.
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
# Phase-1 drill leftovers: drill user + root password should not leak into the race
{ grep -l backupop /etc/sudoers.d/* 2>/dev/null || true; } | xargs -r rm -f
userdel -r backupop >/dev/null 2>&1 || true
passwd -l root >/dev/null 2>&1 || true

log "planting Phase 2 findings (5 tiers) for team $TEAM"
install -d -m 755 "$CACHE"

STUDENT_HOME="$(getent passwd "$STUDENT" 2>/dev/null | cut -d: -f6)"
STUDENT_HOME="${STUDENT_HOME:-/home/$STUDENT}"

# ========================= EASY (8 x 5) =========================
# LE1 unused leftover account
id oldintern >/dev/null 2>&1 || useradd -m -s /bin/bash -c "Former intern" oldintern
echo "oldintern:password" | chpasswd

# LE2 another unused account
id gamesuser >/dev/null 2>&1 || useradd -m -s /bin/bash -c "Games account - unused" gamesuser
echo "gamesuser:games" | chpasswd

# LE3 fake tool in PATH (Linux-only name — not mirrored on Windows)
cat > /usr/local/bin/snap-repair <<'EOF'
#!/bin/bash
# Fake helper — remove me (lab)
exit 0
EOF
chmod 755 /usr/local/bin/snap-repair

# LE4 fake bloat software under /opt
install -d -m 755 /opt/CodecPack
echo "Fake codec pack — uninstall/delete this folder" > /opt/CodecPack/README.txt

# LE5 plaintext secrets in student home
mkdir -p "$STUDENT_HOME/Documents"
cat > "$STUDENT_HOME/Documents/wifi-notes.txt" <<'EOF'
DO NOT SHARE
wifi: Winter2024!
email: Password1
admin backup: Summer2026!
EOF
chown -R "$STUDENT:$STUDENT" "$STUDENT_HOME/Documents"
chmod 644 "$STUDENT_HOME/Documents/wifi-notes.txt"

# LE6 world-writable student home (Phase 1 already drills ufw — do not re-use)
chmod 777 "$STUDENT_HOME"
# ensure ownership stays on the student so chmod-only / restore fixes are valid
chown "$STUDENT:$STUDENT" "$STUDENT_HOME"

# LE7 world-readable copy of the account database (shadow/passwd backup)
install -d -m 755 /var/backups
cat > /var/backups/passwd.lab.bak <<'EOF'
root:$6$labsalt$Q9J0labhashnotrealQ9J0labhashnotreal/:19600:0:99999:7:::
student:$6$labsalt$A1B2labhashnotrealA1B2labhashnotreal/:19600:0:99999:7:::
EOF
chmod 644 /var/backups/passwd.lab.bak

# LE8 stray private key left world-readable in the student home
install -d -m 700 "$STUDENT_HOME/.ssh"
cat > "$STUDENT_HOME/.ssh/id_rsa_backup" <<'EOF'
-----BEGIN OPENSSH PRIVATE KEY-----
bGFiLWR1bW15LWtleS1ub3QtcmVhbC1kby1ub3QtdXNlLWluLXByb2R1Y3Rpb24K
LyoqKiBEQ0lHIGxhYiBzdHViIC0gcmVtb3ZlIG9yIGNobW9kIDYwMCB0aGlzIGtleQ==
-----END OPENSSH PRIVATE KEY-----
EOF
chmod 644 "$STUDENT_HOME/.ssh/id_rsa_backup"
chown -R "$STUDENT:$STUDENT" "$STUDENT_HOME/.ssh"

# ========================= MEDIUM (7 x 10) =========================
# LM1 stealth sudo user
id sysmaint >/dev/null 2>&1 || useradd -m -s /bin/bash -c "System Maintenance" sysmaint
echo "sysmaint:Summer2026!" | chpasswd
usermod -aG sudo sysmaint

# LM2 bad sudoers drop-in (NOPASSWD for non-admin user)
id helpdesk >/dev/null 2>&1 || useradd -m -s /bin/bash -c "Helpdesk - should not have root" helpdesk
echo "helpdesk:Helpdesk1" | chpasswd
echo 'helpdesk ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-helpdesk-temp
chmod 440 /etc/sudoers.d/99-helpdesk-temp

# LM3 cron persistence
cat > /var/tmp/.update_check.sh <<'EOF'
#!/bin/bash
# lab implant
exit 0
EOF
chmod 777 /var/tmp/.update_check.sh
echo "*/15 * * * * root /var/tmp/.update_check.sh" > /etc/cron.d/system-update-check
chmod 644 /etc/cron.d/system-update-check

# LM4 hosts.equiv trust-all (Phase 1 already drills PermitRootLogin — do not re-use)
# Classic r-command / trust misconfig; remove the file (or the "+") to fix.
printf '+\n' > /etc/hosts.equiv
chmod 644 /etc/hosts.equiv

# LM5 unexpected listener via persistent systemd unit (prepare is a oneshot —
# nohup listeners die when it exits, so this MUST be a real unit).
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
systemctl disable --now lab-netprobe.service >/dev/null 2>&1 || true
cat > /etc/systemd/system/lab-netprobe.service <<EOF
[Unit]
Description=Lab Network Probe Helper
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 $CACHE/listen5555.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now lab-netprobe.service >/dev/null 2>&1 || true

# LM6 weak perms on secrets
echo "backup_password=Summer2026!" > /home/sysmaint/creds.txt
chmod 644 /home/sysmaint/creds.txt
chown sysmaint:sysmaint /home/sysmaint/creds.txt

# LM7 SSH allows empty passwords (separate drop-in from LM4 so it is independent)
if [[ -d /etc/ssh/sshd_config.d ]]; then
  echo 'PermitEmptyPasswords yes' > /etc/ssh/sshd_config.d/98-lab-empty.conf
  systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
elif [[ -f /etc/ssh/sshd_config ]]; then
  sed -i 's/^#\?PermitEmptyPasswords.*/PermitEmptyPasswords yes/' /etc/ssh/sshd_config
  grep -q '^PermitEmptyPasswords' /etc/ssh/sshd_config || echo 'PermitEmptyPasswords yes' >> /etc/ssh/sshd_config
  systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
fi

# ========================= HARD (5 x 15) =========================
# LH1 rogue systemd service
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

# LH2 /etc/rc.local implant
cat > /etc/rc.local <<'EOF'
#!/bin/bash
# lab persistence — remove this file or empty it
/usr/local/lib/.hl-cache/beacon.sh >/dev/null 2>&1 &
exit 0
EOF
chmod 755 /etc/rc.local
cat > "$CACHE/beacon.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 "$CACHE/beacon.sh"

# LH3 world-writable sensitive directory with secrets
install -d -m 777 /opt/vault2
echo "db_password=SuperSecret!" > /opt/vault2/db.conf
chmod 666 /opt/vault2/db.conf

# LH4 stealthier listener on 31337 (persistent systemd unit — see LM5 note)
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
systemctl disable --now lab-diagd.service >/dev/null 2>&1 || true
cat > /etc/systemd/system/lab-diagd.service <<EOF
[Unit]
Description=Lab Diagnostics Daemon
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 $CACHE/listen31337.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now lab-diagd.service >/dev/null 2>&1 || true

# LH5 root crontab persistence
(crontab -l 2>/dev/null | grep -v 'hl-beacon' || true; echo '*/20 * * * * /usr/local/lib/.hl-cache/beacon.sh >/dev/null 2>&1 # hl-beacon') | crontab -

# ========================= VERY HARD (3 x 20) =========================
# LV1 SUID binary (harmless wrapper — still a finding)
cat > /usr/local/bin/backup-tool <<'EOF'
#!/bin/bash
# Lab SUID finding — should not be setuid
echo "backup-tool lab stub"
exit 0
EOF
chmod 4755 /usr/local/bin/backup-tool

# LV2 backdoor SSH key on root
install -d -m 700 /root/.ssh
cat > /root/.ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILabBackdoorKeyDoNotUseInProd lab-backdoor@attacker
EOF
chmod 600 /root/.ssh/authorized_keys

# LV3 second UID 0 (root-equivalent) account hidden in /etc/passwd
if ! id toor >/dev/null 2>&1; then
  useradd -o -u 0 -g 0 -M -s /bin/bash -c "toolbox" toor
fi
echo "toor:Toor2026!" | chpasswd

# ========================= ALMOST IMPOSSIBLE (2 x 25) =========================
# LX1 Linux capability privilege backdoor (invisible to find -perm; needs getcap)
if ! command -v setcap >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libcap2-bin >/dev/null 2>&1 || true
fi
cp -f /bin/bash /usr/local/bin/.sysdiag
chmod 755 /usr/local/bin/.sysdiag
setcap cap_setuid+ep /usr/local/bin/.sysdiag >/dev/null 2>&1 || true

# LX2 login-time root persistence via update-motd.d (runs as root on each login)
install -d -m 755 /etc/update-motd.d
cat > /etc/update-motd.d/99-dcig-telemetry <<'EOF'
#!/bin/sh
# hl-motd-beacon — lab persistence that runs at every login; remove or disable me
/usr/local/lib/.hl-cache/beacon.sh >/dev/null 2>&1 || true
exit 0
EOF
chmod 755 /etc/update-motd.d/99-dcig-telemetry

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

cat > "$STUDENT_HOME/PHASE2.txt" <<EOF
Phase 2 is ready on this Linux box (Team $TEAM).

Fix the MACHINE. The score agent checks system state about every 20 seconds —
you do NOT type answers. Run  scoreboard  to see your points.

25 findings worth 295 points:
  8 Easy (5 ea)   7 Medium (10 ea)   5 Hard (15 ea)
  3 Very Hard (20 ea)   2 Almost Impossible (25 ea)
Harder tiers are better hidden (persistence, odd locations, multi-step fixes).

Linux-focused categories (easy -> almost impossible):
  - Unused local accounts
  - Sketchy PATH/opt artifacts and home-directory secrets
  - Exposed account-database backups and private keys
  - Overly open home-directory permissions
  - Extra sudo / sudoers.d privileges
  - Host trust files (hosts.equiv) and empty-password SSH
  - cron.d, root crontab, rc.local persistence
  - Rogue systemd services and unexpected listeners (ss / systemctl)
  - World-writable secret dirs and SUID binaries
  - Root-equivalent (UID 0) accounts, root authorized_keys
  - Stealth persistence: file capabilities (getcap), login-time scripts

These are NOT the same plants as the Windows box — hunt Linux artifacts.

Keep SSH working: port 22 stays allowed if ufw is on. Do not remove the student
account. Leave the hardening-* systemd units alone — they run the scoring agent
and the SSH/student safety net.

Mentors open the room scoreboard when the race starts.
EOF
chown "$STUDENT:$STUDENT" "$STUDENT_HOME/PHASE2.txt"

if [[ -x "$LIB/ensure_lab_access.sh" ]]; then
  "$LIB/ensure_lab_access.sh" || true
fi

log "Phase 2 prep complete for team $TEAM"
