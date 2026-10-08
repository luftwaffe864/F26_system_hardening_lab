#!/usr/bin/env bash
# =============================================================================
#  DCIG System Hardening — Linux Phase 1 setup
#  Run as root on dcig-syslab-teamNN-ubuntu or homelab ubuntuNN:
#    sudo ./setup_phase1.sh
#    sudo ./setup_phase1.sh --no-switch
#
#  Optional env:
#    SCOREBOARD_URL=http://10.0.0.5:8080
#    HARDENING_SECRET=dcig-hardening-2026
#    STUDENT_USER=student
# =============================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0"; exit 1; }

SWITCH=1
[[ "${1:-}" == "--no-switch" ]] && SWITCH=0

STUDENT="${STUDENT_USER:-student}"
STUDENT_PW="${STUDENT_PW:-Hardening2026!}"
CFG=/etc/hardening-lab
LIB=/usr/local/lib/hardening-lab
CACHE=/usr/local/lib/.hl-cache
SELF="$(readlink -f "$0")"
ROOT="$(dirname "$SELF")"
SCOREBOARD_URL="${SCOREBOARD_URL:-http://192.168.1.7:8080}"
HARDENING_SECRET="${HARDENING_SECRET:-dcig-hardening-2026}"

log() { echo "[hardening-linux] $*"; }

TEAM_ID_SCRIPT="$ROOT/../scripts/team_id.sh"
[[ -f "$TEAM_ID_SCRIPT" ]] && # shellcheck source=/dev/null
  source "$TEAM_ID_SCRIPT"

team_from_host() {
  if declare -F team_from_hostname >/dev/null 2>&1; then
    team_from_hostname
  else
    local h n
    h="$(hostname -s 2>/dev/null || hostname)"
    n="$(printf '%s' "$h" | grep -oiE 'team[0-9]+' | head -1 | grep -oE '[0-9]+' || true)"
    if [[ -n "$n" ]]; then printf '%02d' "$((10#$n))"; return; fi
    n="$(printf '%s' "$h" | grep -oE '[0-9]+$' || true)"
    if [[ -n "$n" ]]; then printf '%02d' "$((10#$n))"; else echo "00"; fi
  fi
}

install_dirs() {
  install -d -m 755 "$CFG" "$LIB" "$CACHE" /opt/PCCleaner /opt/SystemHealth
  printf '%s\n' "$HARDENING_SECRET" > "$CFG/secret"
  printf '%s\n' "$SCOREBOARD_URL" > "$CFG/scoreboard_url"
  printf '%s\n' "$(team_from_host)" > "$CFG/team"
  printf 'phase1\n' > "$CFG/phase"
  printf '%s\n' "$STUDENT_PW" > "$CFG/student_password"
  chmod 600 "$CFG/secret" "$CFG/student_password"
  chmod 644 "$CFG/scoreboard_url" "$CFG/team" "$CFG/phase"
  # Clear prior quest / Phase-2 markers so mentors can re-test after re-apply
  rm -rf /home/"$STUDENT"/.hardening-quest 2>/dev/null || true
  rm -f "$CFG/phase2_auto_done.flag" "$CFG/start_phase2.flag" 2>/dev/null || true
  rm -f /home/"$STUDENT"/PHASE2.txt /var/log/hardening-phase2-prep.log 2>/dev/null || true
}

install_student() {
  if ! id "$STUDENT" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -c "DCIG Hardening Student" "$STUDENT"
  fi
  echo "$STUDENT:$STUDENT_PW" | chpasswd
  install -d -m 755 /etc/sudoers.d
  echo "$STUDENT ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-hardening-lab
  chmod 440 /etc/sudoers.d/90-hardening-lab
}

install_game() {
  install -m 755 "$ROOT/hardening_quest.sh" /usr/local/bin/hardening-quest
  install -m 755 "$ROOT/prepare_phase2.sh" "$LIB/prepare_phase2.sh"
  install -m 755 "$ROOT/score_agent.sh" "$LIB/score_agent.sh"
  install -m 755 "$SELF" "$LIB/setup_phase1.sh"
  if [[ -f "$TEAM_ID_SCRIPT" ]]; then
    install -m 644 "$TEAM_ID_SCRIPT" "$LIB/team_id.sh"
  fi
  if [[ -f "$ROOT/../scripts/make_scoreboard_shortcut.sh" ]]; then
    install -m 755 "$ROOT/../scripts/make_scoreboard_shortcut.sh" "$LIB/make_scoreboard_shortcut.sh"
  fi
  install -m 755 "$ROOT/scoreboard_cli.sh" /usr/local/bin/scoreboard
  # convenience symlink for prepare
  ln -sfn "$LIB/prepare_phase2.sh" /usr/local/sbin/hardening-prepare-phase2

  # Oneshto service: quest finish runs "sudo systemctl start hardening-prepare-phase2"
  # so students never invoke prepare_phase2.sh themselves.
  cat > /etc/systemd/system/hardening-prepare-phase2.service <<EOF
[Unit]
Description=DCIG Hardening Lab — Phase 2 prepare (auto after Linux quest)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hardening-prepare-phase2
StandardOutput=append:/var/log/hardening-phase2-prep.log
StandardError=append:/var/log/hardening-phase2-prep.log

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  touch /var/log/hardening-phase2-prep.log
  chmod 644 /var/log/hardening-phase2-prep.log
  log "installed hardening-quest + auto Phase-2 service"
}

install_access_guard() {
  install -m 755 "$ROOT/ensure_lab_access.sh" "$LIB/ensure_lab_access.sh"
  cat > /etc/systemd/system/hardening-ensure-access.service <<EOF
[Unit]
Description=DCIG Hardening — keep SSH and student access working
After=network.target

[Service]
Type=oneshot
ExecStart=$LIB/ensure_lab_access.sh
EOF
  cat > /etc/systemd/system/hardening-ensure-access.timer <<'EOF'
[Unit]
Description=DCIG Hardening — access safety net timer

[Timer]
OnBootSec=45s
OnUnitActiveSec=3min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now hardening-ensure-access.timer >/dev/null 2>&1 || true
  "$LIB/ensure_lab_access.sh" || true
  log "installed SSH/student access safety net (timer every 3 min)"
}

plant_users() {
  # Extra admin with a weak password (least privilege / passwords)
  if ! id tempadmin >/dev/null 2>&1; then
    useradd -m -s /bin/bash -c "Temp Admin - REMOVE" tempadmin
  fi
  echo "tempadmin:Password1" | chpasswd
  usermod -aG sudo tempadmin

  # Unused account (attack surface)
  if ! id guestuser >/dev/null 2>&1; then
    useradd -m -s /bin/bash -c "Unused guest account" guestuser
  fi
  echo "guestuser:guest" | chpasswd

  # Older builds planted backupop for a sudoers drill that no longer exists
  { grep -l backupop /etc/sudoers.d/* 2>/dev/null || true; } | xargs -r rm -f
  userdel -r backupop >/dev/null 2>&1 || true

  # Root-lock drill: root gets a usable password
  echo "root:Toor2026!" | chpasswd
}

plant_policy() {
  # Password-policy drill: back to weak defaults (also keeps planted weak passwords settable)
  sed -i 's/^[[:space:]]*PASS_MAX_DAYS.*/PASS_MAX_DAYS\t99999/' /etc/login.defs
  if [[ -f /etc/security/pwquality.conf ]]; then
    sed -i 's/^[[:space:]]*minlen[[:space:]]*=.*/# minlen = 8/' /etc/security/pwquality.conf
  fi
  sed -i -E 's/(pam_pwquality\.so.*) minlen=[0-9]+/\1/' /etc/pam.d/common-password 2>/dev/null || true
  # chage drill: student's password starts as never-expiring
  chage -M 99999 "$STUDENT" 2>/dev/null || true
}

set_sshd_opt() {
  local key="$1" val="$2" f=/etc/ssh/sshd_config
  local re="^[[:space:]]*#?[[:space:]]*${key}[[:space:]]"
  if grep -qiE "$re" "$f"; then
    sed -i -E "0,/${re}/I{s/${re}.*/${key} ${val}/I}" "$f"
  else
    printf '%s %s\n' "$key" "$val" >> "$f"
  fi
}

plant_ssh() {
  [[ -f /etc/ssh/sshd_config ]] || return 0
  # Drop-ins win over the main file; clear any that would mask the drill
  rm -f /etc/ssh/sshd_config.d/99-lab-insecure.conf
  { grep -liE '^[[:space:]]*(PermitRootLogin|MaxAuthTries|X11Forwarding)' /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true; } |
    { grep -v '50-dcig-lab-access.conf' || true; } | xargs -r rm -f
  # Drill 9 can be solved with a one-line drop-in, so the main file must include them
  install -d -m 755 /etc/ssh/sshd_config.d
  grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config ||
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  set_sshd_opt PermitRootLogin yes
  set_sshd_opt MaxAuthTries 10
  set_sshd_opt X11Forwarding yes
  install -d -m 755 /run/sshd
  if /usr/sbin/sshd -t; then
    cp -f /etc/ssh/sshd_config "$LIB/sshd_config.lab-good"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  fi
}

plant_files() {
  cat > /home/"$STUDENT"/briefing.txt <<EOF
DCIG System Hardening — Linux box
Hostname: $(hostname -s)
Team: $(team_from_host)

Someone left this workstation messy. Your job in the quest is to find the attack
surface and harden what you can. When you finish, go to your matching Windows box and continue there
(e.g. win19_srvNN on the range — same minion ID as Salt).

Password reuse note found on sticky pad: tempadmin also uses Password1 on email.

Lab note: do not remove the student account or block port 22 — mentors can
reset access, but you will lose time.
EOF
  chown "$STUDENT:$STUDENT" /home/"$STUDENT"/briefing.txt

  mkdir -p /opt/vault
  echo "API_KEY=vault-demo-key-not-real" > /opt/vault/keys.txt
  chmod 777 /opt/vault /opt/vault/keys.txt

  # Fake bloatware
  cat > /opt/PCCleaner/pccleaner.sh <<'EOF'
#!/bin/bash
# Fake bloatware — safe for lab
while true; do sleep 3600; done
EOF
  chmod 755 /opt/PCCleaner/pccleaner.sh

  cat > /opt/SystemHealth/healthd.sh <<'EOF'
#!/bin/bash
# Looks like a health daemon; actually a lab stand-in for malware
while true; do sleep 30; done
EOF
  chmod 755 /opt/SystemHealth/healthd.sh
}

plant_service_and_process() {
  cat > /etc/systemd/system/cache-sync.service <<'EOF'
[Unit]
Description=Cache Sync Helper (lab implant — remove me)
After=network.target

[Service]
Type=simple
ExecStart=/opt/SystemHealth/healthd.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now cache-sync.service >/dev/null 2>&1 || true

  # Listening junk on high port (attack surface)
  cat > "$CACHE/listen9999.py" <<'EOF'
#!/usr/bin/env python3
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 9999))
s.listen(1)
while True:
    time.sleep(60)
EOF
  chmod 755 "$CACHE/listen9999.py"
  pkill -f 'listen9999.py' 2>/dev/null || true
  nohup python3 "$CACHE/listen9999.py" >/dev/null 2>&1 &

  # Cron persistence
  echo "*/10 * * * * root /opt/PCCleaner/pccleaner.sh >/dev/null 2>&1" > /etc/cron.d/pccleaner
  chmod 644 /etc/cron.d/pccleaner
}

plant_firewall() {
  if ! command -v ufw >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null 2>&1 || true
  fi
  ufw --force disable >/dev/null 2>&1 || true
  ufw --force reset >/dev/null 2>&1 || true
  # reset restores deny-incoming; the drill needs students to set it themselves
  ufw default allow incoming >/dev/null 2>&1 || true
}

packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  # Full vim + nano: vim-tiny runs in vi-compatible mode where arrow keys type A/B/C/D
  apt-get install -y -qq curl python3 ufw cron procps psmisc iproute2 \
    openssh-server libpam-pwquality nano vim x11-xkb-utils libcap2-bin e2fsprogs >/dev/null 2>&1 || true
  install -d -m 755 /etc/vim
  cat > /etc/vim/vimrc.local <<'EOF'
" DCIG lab: arrow keys, backspace, and line numbers behave as expected
set nocompatible
silent! set esckeys
" Web consoles can split an arrow key's escape sequence; wait long enough to rejoin it
set ttimeout ttimeoutlen=200
set backspace=indent,eol,start
set whichwrap+=<,>,[,]
set number
set showmode
set mouse=
EOF
  # Offline boxes keep vim-tiny, which ignores vimrc.local
  [[ -f /etc/vim/vimrc.tiny ]] && sed -i 's/^\s*set compatible/set nocompatible/' /etc/vim/vimrc.tiny || true

  # nano: decode arrow keys itself instead of trusting terminfo (fixes TERM/console
  # mismatches where arrows otherwise do nothing or print junk)
  touch /etc/nanorc
  sed -i '/^# DCIG lab begin$/,/^# DCIG lab end$/d' /etc/nanorc
  cat >> /etc/nanorc <<'EOF'
# DCIG lab begin
set rawsequences
set linenumbers
set constantshow
# DCIG lab end
EOF
}

# Remmina -> xrdp sessions often get a keymap where arrow keys send the wrong
# keycodes (dead in every terminal, nano, and vim). Re-applying a plain US layout
# inside the X session fixes it; run at login, in every new terminal, and by the quest.
install_keyboard_fix() {
  cat > /usr/local/bin/dcig-fix-keys <<'EOF'
#!/bin/sh
[ -n "$DISPLAY" ] && command -v setxkbmap >/dev/null 2>&1 &&
  setxkbmap -model pc105 -layout us -option '' >/dev/null 2>&1
exit 0
EOF
  chmod 755 /usr/local/bin/dcig-fix-keys
  install -d -m 755 /etc/xdg/autostart
  cat > /etc/xdg/autostart/dcig-fix-keys.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=DCIG keyboard fix
Exec=/usr/local/bin/dcig-fix-keys
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
  cat > /etc/profile.d/dcig-fix-keys.sh <<'EOF'
[ -n "$DISPLAY" ] && [ -x /usr/local/bin/dcig-fix-keys ] && /usr/local/bin/dcig-fix-keys
EOF
  grep -q 'dcig-fix-keys' /etc/bash.bashrc 2>/dev/null ||
    echo '[ -n "$DISPLAY" ] && [ -x /usr/local/bin/dcig-fix-keys ] && /usr/local/bin/dcig-fix-keys' >> /etc/bash.bashrc
}

# Phase 2 plants must not still be on the box when the quest starts.
clear_phase2() {
  systemctl disable --now hardening-score-agent.timer >/dev/null 2>&1 || true
  systemctl disable --now log-rotate-helper.timer log-rotate-helper.service net-helper >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/log-rotate-helper.timer /etc/systemd/system/log-rotate-helper.service \
        /etc/systemd/system/net-helper.service
  systemctl daemon-reload >/dev/null 2>&1 || true
  pkill -f 'listen5555.py|listen31337.py|nethelper.sh' >/dev/null 2>&1 || true
  for u in oldintern gamesuser sysmaint helpdesk auditor polkitd-helper; do
    userdel -r "$u" >/dev/null 2>&1 || true
  done
  rm -f /usr/local/bin/snap-repair /usr/local/bin/backup-tool /usr/local/libexec/health-check \
        /etc/cron.d/system-update-check /var/tmp/.update_check.sh /var/tmp/backup-passwords.txt \
        /etc/sudoers.d/99-helpdesk-temp /etc/sudoers.d/010-staff \
        /etc/ssh/sshd_config.d/99-lab-insecure.conf /etc/rc.local
  rm -rf /opt/CodecPack /opt/vault2 /home/student/Documents/wifi-notes.txt
  chattr -i /etc/cron.hourly/.sync-cache 2>/dev/null || true
  rm -f /etc/cron.hourly/.sync-cache
  if [[ -f /root/.ssh/authorized_keys ]] && grep -q lab-backdoor /root/.ssh/authorized_keys 2>/dev/null; then
    rm -f /root/.ssh/authorized_keys
  fi
  if crontab -l 2>/dev/null | grep -q hl-beacon; then
    crontab -l 2>/dev/null | grep -v hl-beacon | crontab - || true
  fi
  rm -rf /var/lib/hardening-lab/planted
  rm -f /var/lib/hardening-lab/got_* /home/student/PHASE2.txt \
        /home/student/README_SCENARIO.txt /home/student/Desktop/README_SCENARIO.txt 2>/dev/null || true
}

main() {
  log "Phase 1 setup on $(hostname -s) team=$(team_from_host)"
  clear_phase2
  packages
  install_dirs
  install_student
  install_game
  plant_policy
  plant_users
  plant_files
  plant_service_and_process
  plant_firewall
  plant_ssh
  install_access_guard
  install_keyboard_fix
  # Desktop shortcut → open scoreboard in browser (double-click)
  SHORTCUT_SRC="$ROOT/../scripts/make_scoreboard_shortcut.sh"
  if [[ -f "$LIB/make_scoreboard_shortcut.sh" ]]; then
    bash "$LIB/make_scoreboard_shortcut.sh" "$SCOREBOARD_URL" "$STUDENT" || true
  elif [[ -f "$SHORTCUT_SRC" ]]; then
    bash "$SHORTCUT_SRC" "$SCOREBOARD_URL" "$STUDENT" || true
  elif [[ -f "$ROOT/scripts/make_scoreboard_shortcut.sh" ]]; then
    bash "$ROOT/scripts/make_scoreboard_shortcut.sh" "$SCOREBOARD_URL" "$STUDENT" || true
  else
    # Inline fallback if scripts/ not next to linux/
    install -d -m 755 "/home/$STUDENT/Desktop"
    cat > "/home/$STUDENT/Desktop/DCIG Scoreboard.html" <<EOF
<!DOCTYPE html><html><head>
<meta http-equiv="refresh" content="0;url=${SCOREBOARD_URL%/}/"/>
<script>location.replace("${SCOREBOARD_URL%/}/");</script>
</head><body><a href="${SCOREBOARD_URL%/}/">Open scoreboard</a></body></html>
EOF
    chown -R "$STUDENT:$STUDENT" "/home/$STUDENT/Desktop"
  fi
  log "done. Student: $STUDENT / $STUDENT_PW"
  log "Scoreboard: Desktop launcher + 'scoreboard' command -> $SCOREBOARD_URL"
  log "Start quest: sudo -u $STUDENT -i hardening-quest"
  if [[ "$SWITCH" -eq 1 && -t 0 ]]; then
    exec su - "$STUDENT" -c hardening-quest
  fi
}

main "$@"
