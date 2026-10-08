#!/usr/bin/env bash
# =============================================================================
#  DCIG System Hardening — Linux Phase 2 prepare
#  Auto-run after Linux quest. Plants easy → hard findings for machine-state scoring.
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
# One failed plant must not abort the rest (scoring uses planted flags, not "already fixed").
set +e

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
# Quest accounts are not part of the race
for u in tempadmin guestuser; do userdel -r "$u" >/dev/null 2>&1 || true; done
# Re-runs: drop the very-hard / almost-impossible units before replanting
systemctl disable --now log-rotate-helper.timer log-rotate-helper.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/log-rotate-helper.timer /etc/systemd/system/log-rotate-helper.service
chattr -i /etc/cron.hourly/.sync-cache 2>/dev/null || true
rm -f /etc/cron.hourly/.sync-cache /etc/sudoers.d/010-staff
userdel -r auditor >/dev/null 2>&1 || true
userdel -r polkitd-helper >/dev/null 2>&1 || true

log "planting Phase 2 findings (25: easy 5 -> almost impossible 25) for team $TEAM"
install -d -m 755 "$CACHE"
PLANT=/var/lib/hardening-lab/planted
rm -rf "$PLANT"
install -d -m 755 "$PLANT"
rm -f /var/lib/hardening-lab/got_* 2>/dev/null || true
mark() { touch "$PLANT/$1"; echo "[phase2-linux] planted $1"; }

command -v setcap >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libcap2-bin >/dev/null 2>&1 || true
# Quest drop-in would override the Phase-2 root-login plant (first match wins)
rm -f /etc/ssh/sshd_config.d/00-hardening.conf

# ========== EASY ==========
# L2-02 unused account
if ! id oldintern >/dev/null 2>&1; then
  useradd -m -s /bin/bash -c "Former intern" oldintern
fi
echo "oldintern:password" | chpasswd || true
id oldintern >/dev/null 2>&1 && mark LE-01

# LE-02 another unused account
if ! id gamesuser >/dev/null 2>&1; then
  useradd -m -s /bin/bash -c "Games account - unused" gamesuser
fi
echo "gamesuser:games" | chpasswd || true
id gamesuser >/dev/null 2>&1 && mark LE-02

# LE-03 fake tool in PATH
cat > /usr/local/bin/snap-repair <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 /usr/local/bin/snap-repair
[[ -x /usr/local/bin/snap-repair ]] && mark LE-03

# LE-04 fake bloat software under /opt
install -d -m 755 /opt/CodecPack
echo "Fake codec pack - delete this folder" > /opt/CodecPack/README.txt
[[ -d /opt/CodecPack ]] && mark LE-04

# LE-05 plaintext secrets in the student home
mkdir -p /home/"$STUDENT"/Documents
cat > /home/"$STUDENT"/Documents/wifi-notes.txt <<'EOF'
DO NOT SHARE
wifi: Winter2024!
email: Password1
admin backup: Summer2026!
EOF
chown -R "$STUDENT:$STUDENT" /home/"$STUDENT"/Documents
chmod 644 /home/"$STUDENT"/Documents/wifi-notes.txt
[[ -f /home/$STUDENT/Documents/wifi-notes.txt ]] && mark LE-05

# LE-06 obvious password file in a temp directory
cat > /var/tmp/backup-passwords.txt <<'EOF'
router: admin / admin
vpn: TeamVPN / Winter2024!
EOF
chmod 666 /var/tmp/backup-passwords.txt
[[ -f /var/tmp/backup-passwords.txt ]] && mark LE-06

# ========== MEDIUM ==========
# L2-01 stealth sudo user
if ! id sysmaint >/dev/null 2>&1; then
  useradd -m -s /bin/bash -c "System Maintenance" sysmaint
fi
echo "sysmaint:Summer2026!" | chpasswd
usermod -aG sudo sysmaint
id -nG sysmaint 2>/dev/null | tr ' ' '\n' | grep -qx sudo && mark LM-01

# LM-05 weak perms on secrets
echo "backup_password=Summer2026!" > /home/sysmaint/creds.txt
chmod 644 /home/sysmaint/creds.txt
chown sysmaint:sysmaint /home/sysmaint/creds.txt
[[ "$(stat -c %a /home/sysmaint/creds.txt 2>/dev/null)" == "644" ]] && mark LM-05

# LM-02 cron persistence
cat > /var/tmp/.update_check.sh <<'EOF'
#!/bin/bash
# lab implant
exit 0
EOF
chmod 777 /var/tmp/.update_check.sh
echo "*/15 * * * * root /var/tmp/.update_check.sh" > /etc/cron.d/system-update-check
chmod 644 /etc/cron.d/system-update-check
[[ -f /etc/cron.d/system-update-check && -f /var/tmp/.update_check.sh ]] && mark LM-02

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
sleep 0.4
ss -tln 2>/dev/null | grep -q ':5555' && mark LE-07

# LE-08 firewall off
if command -v ufw >/dev/null 2>&1; then
  ufw --force disable >/dev/null 2>&1 || true
  ufw status 2>/dev/null | head -1 | grep -qi inactive && mark LE-08
fi

# L2-12 bad sudoers drop-in (NOPASSWD for non-admin user)
if ! id helpdesk >/dev/null 2>&1; then
  useradd -m -s /bin/bash -c "Helpdesk - should not have root" helpdesk
fi
echo "helpdesk:Helpdesk1" | chpasswd
echo 'helpdesk ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-helpdesk-temp
chmod 440 /etc/sudoers.d/99-helpdesk-temp
[[ -f /etc/sudoers.d/99-helpdesk-temp ]] && mark LM-03

# L2-13 PermitRootLogin yes (if sshd present)
if [[ -d /etc/ssh/sshd_config.d ]]; then
  echo 'PermitRootLogin yes' > /etc/ssh/sshd_config.d/99-lab-insecure.conf
  systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
elif [[ -f /etc/ssh/sshd_config ]]; then
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
  systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
fi
/usr/sbin/sshd -T 2>/dev/null | grep -qx 'permitrootlogin yes' && mark LM-04

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
systemctl is-enabled net-helper >/dev/null 2>&1 && mark LM-06

# L2-14 root crontab persistence (in addition to cron.d)
(crontab -l 2>/dev/null | grep -v 'hl-beacon' || true; echo '*/20 * * * * /usr/local/lib/.hl-cache/beacon.sh >/dev/null 2>&1 # hl-beacon') | crontab -
cat > "$CACHE/beacon.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 "$CACHE/beacon.sh"
crontab -l 2>/dev/null | grep -q 'hl-beacon' && mark LH-01

# L2-15 /etc/rc.local implant
cat > /etc/rc.local <<'EOF'
#!/bin/bash
# lab persistence — remove this file or empty it
/usr/local/lib/.hl-cache/beacon.sh >/dev/null 2>&1 &
exit 0
EOF
chmod 755 /etc/rc.local
grep -q 'lab persistence' /etc/rc.local && mark LH-02

# L2-16 backdoor SSH key on root
install -d -m 700 /root/.ssh
cat > /root/.ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILabBackdoorKeyDoNotUseInProd lab-backdoor@attacker
EOF
chmod 600 /root/.ssh/authorized_keys
grep -q 'lab-backdoor' /root/.ssh/authorized_keys && mark LH-03

# L2-17 SUID binary (harmless wrapper — still a finding)
cat > /usr/local/bin/backup-tool <<'EOF'
#!/bin/bash
# Lab SUID finding — should not be setuid
echo "backup-tool lab stub"
exit 0
EOF
chmod 4755 /usr/local/bin/backup-tool
[[ -u /usr/local/bin/backup-tool ]] && mark LH-04

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
sleep 0.4
ss -tln 2>/dev/null | grep -q ':31337' && mark LH-05

# LM-07 world-writable secrets directory
install -d -m 777 /opt/vault2
echo "db_password=SuperSecret!" > /opt/vault2/db.conf
chmod 666 /opt/vault2/db.conf
[[ "$(stat -c %a /opt/vault2/db.conf 2>/dev/null)" == "666" ]] && mark LM-07

# ========== VERY HARD ==========
# LV-01 file capability (find -perm -4000 does not show this)
install -d -m 755 /usr/local/libexec
cp -f /bin/true /usr/local/libexec/health-check
chmod 755 /usr/local/libexec/health-check
if setcap cap_setuid+ep /usr/local/libexec/health-check 2>/dev/null; then
  getcap /usr/local/libexec/health-check 2>/dev/null | grep -q cap_setuid && mark LV-01
fi

# LV-02 systemd timer, not a normal service
cat > "$CACHE/rotate.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 "$CACHE/rotate.sh"
cat > /etc/systemd/system/log-rotate-helper.service <<EOF
[Unit]
Description=Log Rotate Helper
[Service]
Type=oneshot
ExecStart=$CACHE/rotate.sh
EOF
cat > /etc/systemd/system/log-rotate-helper.timer <<'EOF'
[Unit]
Description=Log Rotate Helper schedule
[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
AccuracySec=1min
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now log-rotate-helper.timer >/dev/null 2>&1 || true
systemctl is-enabled log-rotate-helper.timer >/dev/null 2>&1 && mark LV-02

# LV-03 sudoers for a user who is NOT in the sudo group (easy sudo checks miss it)
if ! id auditor >/dev/null 2>&1; then
  useradd -m -s /bin/bash -c "Internal audit" auditor
fi
echo "auditor:Audit2026!" | chpasswd || true
echo 'auditor ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/010-staff
chmod 440 /etc/sudoers.d/010-staff
[[ -f /etc/sudoers.d/010-staff ]] && mark LV-03

# ========== ALMOST IMPOSSIBLE ==========
# LI-01 hidden name (ls misses it) and immutable (rm fails until chattr -i)
cat > /etc/cron.hourly/.sync-cache <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 /etc/cron.hourly/.sync-cache
chattr +i /etc/cron.hourly/.sync-cache 2>/dev/null || true
[[ -f /etc/cron.hourly/.sync-cache ]] && mark LI-01

# LI-02 looks like a system account, but it has a real login shell
if ! id polkitd-helper >/dev/null 2>&1; then
  useradd -r -s /bin/bash -c "PolicyKit helper" polkitd-helper
fi
echo "polkitd-helper:Helper2026!" | chpasswd || true
shell="$(getent passwd polkitd-helper 2>/dev/null | cut -d: -f7)"
[[ "$shell" == */bin/bash ]] && mark LI-02

log "plant flags: $(ls "$PLANT" 2>/dev/null | wc -l)/25"

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

25 findings. The score agent checks the machine about every 20 seconds.
You do NOT type answers. Run  scoreboard  to see your points.

  Easy               8 x  5 =  40
  Medium             7 x 10 =  70
  Hard               5 x 15 =  75
  Very hard          3 x 20 =  60
  Almost impossible  2 x 25 =  50
  This box max: 295

Where to hunt (not a checklist of answers):
  - Local accounts, including ones that look like system accounts
  - Extra sudo group members and files in /etc/sudoers.d
  - Programs under /usr/local and /opt, and files in home directories
  - cron.d, cron.hourly, the root crontab, and rc.local
  - systemd services AND timers
  - Listening ports (ss) and the ufw firewall
  - SSH: root login, and root's trusted keys
  - Setuid bits and file capabilities
  - File permissions on anything that holds a password

Keep SSH working: if you turn the firewall on, leave port 22 allowed.
Do not remove or lock the student account.

The Windows box is a different set of problems. A few ideas appear on both
(leftover accounts, too much privilege, a firewall hole, plaintext passwords,
something that starts by itself) because those matter on every system.

Mentors open the room scoreboard when the race starts.
EOF
chown "$STUDENT:$STUDENT" /home/"$STUDENT"/PHASE2.txt

if [[ -x "$LIB/ensure_lab_access.sh" ]]; then
  "$LIB/ensure_lab_access.sh" || true
fi

log "Phase 2 prep complete for team $TEAM"
