#!/usr/bin/env bash
# =============================================================================
#  DCIG System Hardening — Linux Phase 1 setup
#  Run as root on ubuntuNN (homelab or Salt):
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
SCOREBOARD_URL="${SCOREBOARD_URL:-http://127.0.0.1:8080}"
HARDENING_SECRET="${HARDENING_SECRET:-dcig-hardening-2026}"

log() { echo "[hardening-linux] $*"; }

team_from_host() {
  local h n
  h="$(hostname -s 2>/dev/null || hostname)"
  n="$(printf '%s' "$h" | grep -oE '[0-9]+$' || true)"
  if [[ -n "$n" ]]; then printf '%02d' "$((10#$n))"
  else echo "00"; fi
}

install_dirs() {
  install -d -m 755 "$CFG" "$LIB" "$CACHE" /opt/PCCleaner /opt/SystemHealth
  printf '%s\n' "$HARDENING_SECRET" > "$CFG/secret"
  printf '%s\n' "$SCOREBOARD_URL" > "$CFG/scoreboard_url"
  printf '%s\n' "$(team_from_host)" > "$CFG/team"
  printf 'phase1\n' > "$CFG/phase"
  chmod 600 "$CFG/secret"
  chmod 644 "$CFG/scoreboard_url" "$CFG/team" "$CFG/phase"
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
  # convenience symlink for prepare
  ln -sfn "$LIB/prepare_phase2.sh" /usr/local/sbin/hardening-prepare-phase2
  log "installed hardening-quest"
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
}

plant_files() {
  cat > /home/"$STUDENT"/briefing.txt <<EOF
DCIG System Hardening — Linux box
Hostname: $(hostname -s)
Team: $(team_from_host)

Someone left this workstation messy. Your job in the quest is to find the attack
surface and harden what you can. When you finish, go to your matching Windows box
(win19_srvNN) and continue there.

Password reuse note found on sticky pad: tempadmin also uses Password1 on email.
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
  if command -v ufw >/dev/null 2>&1; then
    ufw --force disable >/dev/null 2>&1 || true
    ufw --force reset >/dev/null 2>&1 || true
  else
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null 2>&1 || true
    ufw --force disable >/dev/null 2>&1 || true
  fi
}

packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq curl python3 ufw cron procps psmisc iproute2 >/dev/null 2>&1 || true
}

main() {
  log "Phase 1 setup on $(hostname -s) team=$(team_from_host)"
  packages
  install_dirs
  install_student
  install_game
  plant_users
  plant_files
  plant_service_and_process
  plant_firewall
  log "done. Student: $STUDENT / $STUDENT_PW"
  log "Start quest: sudo -u $STUDENT -i hardening-quest"
  if [[ "$SWITCH" -eq 1 && -t 0 ]]; then
    exec su - "$STUDENT" -c hardening-quest
  fi
}

main "$@"
