#!/usr/bin/env bash
# =============================================================================
#  Homelab ONLY — not for cyber range student/target VMs.
#  Kali mentor box base setup. Run AFTER a fresh install (your sudo user):
#
#    sudo bash setup_kali.sh
#    sudo bash setup_kali.sh --ip 192.168.1.7 --iface eth0
#    sudo bash setup_kali.sh --ip 192.168.1.7 --iface eth0 --salt-master
#    sudo bash setup_kali.sh --skip-net   # hostname/packages only
#
#  Defaults match RANGE.md (admin Kali / Salt + scoreboard at 192.168.1.7).
#  Homelab on VMware NAT: pass --ip/--gateway if your subnet is not 192.168.1.0/24.
# =============================================================================
set -euo pipefail

HOSTNAME_NEW="${HOSTNAME_NEW:-kali-mentor}"
IP_ADDR="${IP_ADDR:-192.168.1.7}"
PREFIX="${PREFIX:-24}"
GATEWAY="${GATEWAY:-192.168.1.1}"
DNS="${DNS:-1.1.1.1,8.8.8.8}"
IFACE="${IFACE:-}"
UBUNTU_IP="${UBUNTU_IP:-192.168.1.10}"
WIN_IP="${WIN_IP:-192.168.1.11}"
LAB_DIR="${LAB_DIR:-}"
SKIP_NET=0
INSTALL_SALT=0
CLONE_LAB=1
REPO_URL="${REPO_URL:-https://github.com/luftwaffe864/F26_system_hardening_lab.git}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname) HOSTNAME_NEW="$2"; shift 2 ;;
    --ip) IP_ADDR="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --gateway) GATEWAY="$2"; shift 2 ;;
    --dns) DNS="$2"; shift 2 ;;
    --iface) IFACE="$2"; shift 2 ;;
    --ubuntu-ip) UBUNTU_IP="$2"; shift 2 ;;
    --win-ip) WIN_IP="$2"; shift 2 ;;
    --lab-dir) LAB_DIR="$2"; shift 2 ;;
    --skip-net) SKIP_NET=1; shift ;;
    --salt-master) INSTALL_SALT=1; shift ;;
    --no-clone) CLONE_LAB=0; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0 ..."; exit 1; }

REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
  REAL_USER="$(logname 2>/dev/null || echo root)"
fi
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
[[ -n "$LAB_DIR" ]] || LAB_DIR="$REAL_HOME/F26_system_hardening_lab"

log() { echo "[setup-kali] $*"; }

# --- hostname ----------------------------------------------------------------
log "hostname -> $HOSTNAME_NEW"
hostnamectl set-hostname "$HOSTNAME_NEW"
if grep -qE '^127\.0\.1\.1' /etc/hosts; then
  sed -i "s/^127\\.0\\.1\\.1.*/127.0.1.1\t${HOSTNAME_NEW}/" /etc/hosts
else
  echo -e "127.0.1.1\t${HOSTNAME_NEW}" >> /etc/hosts
fi

# --- static IP (NetworkManager) ----------------------------------------------
if [[ "$SKIP_NET" -eq 0 ]]; then
  if ! command -v nmcli >/dev/null 2>&1; then
    log "nmcli not found; installing network-manager"
    apt-get update -qq
    apt-get install -y -qq network-manager >/dev/null
  fi

  if [[ -z "$IFACE" ]]; then
    # Prefer a non-loopback ethernet that is UP or has a carrier
    IFACE="$(ip -br link | awk '$1!="lo" && $2 ~ /UP|UNKNOWN/ {print $1; exit}')"
    [[ -n "$IFACE" ]] || IFACE="$(ip -br link | awk '$1!="lo" {print $1; exit}')"
  fi
  [[ -n "$IFACE" ]] || { echo "Could not detect NIC. Pass --iface eth0"; exit 1; }

  CON="$(nmcli -t -f NAME,DEVICE con show | awk -F: -v d="$IFACE" '$2==d {print $1; exit}')"
  if [[ -z "$CON" ]]; then
    CON="lab-$IFACE"
    nmcli con add type ethernet ifname "$IFACE" con-name "$CON" || true
  fi

  log "static IP $IP_ADDR/$PREFIX on $IFACE (conn: $CON), gw $GATEWAY"
  nmcli con mod "$CON" \
    ipv4.addresses "${IP_ADDR}/${PREFIX}" \
    ipv4.gateway "$GATEWAY" \
    ipv4.dns "${DNS//,/ }" \
    ipv4.method manual \
    connection.autoconnect yes
  nmcli con up "$CON" || nmcli device reapply "$IFACE" || true
  sleep 1
  ip -br addr show "$IFACE" || true
else
  log "skipping network config (--skip-net)"
fi

# --- /etc/hosts lab map ------------------------------------------------------
for pair in "$IP_ADDR kali-mentor" "$UBUNTU_IP ubuntu01" "$WIN_IP win19_srv01"; do
  ip="${pair%% *}"; name="${pair##* }"
  if grep -qE "[[:space:]]${name}([[:space:]]|$)" /etc/hosts; then
    sed -i -E "s/^[0-9.]+[[:space:]]+${name}.*/${ip}\t${name}/" /etc/hosts
  else
    echo -e "${ip}\t${name}" >> /etc/hosts
  fi
done
log "updated /etc/hosts for kali-mentor / ubuntu01 / win19_srv01"

# --- packages ----------------------------------------------------------------
log "installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl python3 python3-venv python3-pip openssh-client ca-certificates >/dev/null

# --- clone lab ---------------------------------------------------------------
if [[ "$CLONE_LAB" -eq 1 ]]; then
  if [[ -d "$LAB_DIR/.git" ]]; then
    log "lab already present at $LAB_DIR (git pull)"
    sudo -u "$REAL_USER" git -C "$LAB_DIR" pull --ff-only || true
  else
    log "cloning lab -> $LAB_DIR"
    sudo -u "$REAL_USER" git clone "$REPO_URL" "$LAB_DIR"
  fi
fi

# --- optional salt master ----------------------------------------------------
if [[ "$INSTALL_SALT" -eq 1 ]]; then
  log "installing salt-master"
  apt-get install -y -qq salt-master >/dev/null || {
    log "WARNING: salt-master package install failed — install manually for your Kali version"
  }
  mkdir -p /srv/salt /srv/pillar
  if [[ -d "$LAB_DIR" ]]; then
    ln -sfn "$LAB_DIR" /srv/salt/F26_system_hardening_lab
    cp -f "$LAB_DIR/salt/hardening-lab.sls" /srv/salt/hardening-lab.sls
  fi
  cat > /srv/pillar/hardening.sls <<EOF
hardening_lab:
  files_root: /srv/salt/F26_system_hardening_lab
  scoreboard_url: http://${IP_ADDR}:8080
  secret: dcig-hardening-2026
  student_password: Hardening2026!
EOF
  cat > /srv/pillar/top.sls <<'EOF'
base:
  '*':
    - hardening
EOF
  # Ensure file_roots if not already customized — append drop-in
  mkdir -p /etc/salt/master.d
  cat > /etc/salt/master.d/hardening.conf <<'EOF'
file_roots:
  base:
    - /srv/salt
pillar_roots:
  base:
    - /srv/pillar
EOF
  systemctl enable --now salt-master 2>/dev/null || true
  log "Salt master enabled (accept minions later with: sudo salt-key -A)"
fi

# --- scoreboard venv (optional convenience) ----------------------------------
if [[ -d "$LAB_DIR/scoreboard" ]]; then
  log "creating scoreboard venv"
  sudo -u "$REAL_USER" bash -c "
    cd '$LAB_DIR/scoreboard'
    python3 -m venv .venv
    . .venv/bin/activate
    pip install -q -r requirements.txt
  "
fi

cat <<EOF

[setup-kali] DONE
  Hostname : $HOSTNAME_NEW
  IP       : $IP_ADDR/$PREFIX  (iface: ${IFACE:-skipped})
  Lab dir  : $LAB_DIR

Next:
  1) cd $LAB_DIR/scoreboard && source .venv/bin/activate
  2) export HARDENING_SECRET=dcig-hardening-2026 HARDENING_ADMIN=dcig-admin-2026
  3) python server.py
  4) Browser: http://${IP_ADDR}:8080/

  Or: sudo bash $LAB_DIR/homelab/start_scoreboard.sh

EOF
