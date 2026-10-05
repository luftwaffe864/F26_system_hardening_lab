#!/usr/bin/env bash
# =============================================================================
#  Homelab ONLY — cyber range Ubuntu boxes already have 192.168.1.10.
#  Ubuntu hardening target base setup. Run AFTER a fresh install (sudo admin):
#
#    sudo bash setup_ubuntu.sh
#    sudo bash setup_ubuntu.sh --ip 192.168.1.10 --iface ens33
#    sudo bash setup_ubuntu.sh --hostname ubuntu01 --ip 192.168.1.10
#    sudo bash setup_ubuntu.sh --salt-minion --master 192.168.1.7
#    sudo bash setup_ubuntu.sh --skip-net
#
#  Does NOT create the lab "student" account — Phase-1 setup_phase1.sh does that.
#  Reboot after hostname change if the script asks you to.
# =============================================================================
set -euo pipefail

HOSTNAME_NEW="${HOSTNAME_NEW:-ubuntu01}"
IP_ADDR="${IP_ADDR:-192.168.1.10}"
PREFIX="${PREFIX:-24}"
GATEWAY="${GATEWAY:-192.168.1.1}"
DNS1="${DNS1:-1.1.1.1}"
DNS2="${DNS2:-8.8.8.8}"
IFACE="${IFACE:-}"
KALI_IP="${KALI_IP:-192.168.1.7}"
WIN_IP="${WIN_IP:-192.168.1.11}"
SKIP_NET=0
INSTALL_SALT=0
MASTER_IP="${MASTER_IP:-192.168.1.7}"
NEED_REBOOT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname) HOSTNAME_NEW="$2"; shift 2 ;;
    --ip) IP_ADDR="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --gateway) GATEWAY="$2"; shift 2 ;;
    --dns1) DNS1="$2"; shift 2 ;;
    --dns2) DNS2="$2"; shift 2 ;;
    --iface) IFACE="$2"; shift 2 ;;
    --kali-ip) KALI_IP="$2"; shift 2 ;;
    --win-ip) WIN_IP="$2"; shift 2 ;;
    --skip-net) SKIP_NET=1; shift ;;
    --salt-minion) INSTALL_SALT=1; shift ;;
    --master) MASTER_IP="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0 ..."; exit 1; }

# Team ID: range uses teamNN in name; homelab uses trailing digits (ubuntu01)
if ! [[ "$HOSTNAME_NEW" =~ [Tt][Ee][Aa][Mm][0-9]+ ]] && ! [[ "$HOSTNAME_NEW" =~ [0-9]+$ ]]; then
  echo "WARNING: hostname '$HOSTNAME_NEW' has no teamNN or trailing digits — Team ID will be 00"
fi

log() { echo "[setup-ubuntu] $*"; }

# --- hostname ----------------------------------------------------------------
CUR="$(hostname -s || true)"
if [[ "$CUR" != "$HOSTNAME_NEW" ]]; then
  log "hostname $CUR -> $HOSTNAME_NEW"
  hostnamectl set-hostname "$HOSTNAME_NEW"
  if grep -qE '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\\.0\\.1\\.1.*/127.0.1.1\t${HOSTNAME_NEW}/" /etc/hosts
  else
    echo -e "127.0.1.1\t${HOSTNAME_NEW}" >> /etc/hosts
  fi
  NEED_REBOOT=1
else
  log "hostname already $HOSTNAME_NEW"
fi

# --- static IP (netplan) -----------------------------------------------------
if [[ "$SKIP_NET" -eq 0 ]]; then
  if [[ -z "$IFACE" ]]; then
    IFACE="$(ip -br link | awk '$1!="lo" && $2 ~ /UP|UNKNOWN/ {print $1; exit}')"
    [[ -n "$IFACE" ]] || IFACE="$(ip -br link | awk '$1!="lo" {print $1; exit}')"
  fi
  [[ -n "$IFACE" ]] || { echo "Could not detect NIC. Pass --iface ens33"; exit 1; }

  NP_DIR=/etc/netplan
  mkdir -p "$NP_DIR"
  # Disable cloud-init network takeover if present
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  fi

  # Remove installer DHCP-only configs that conflict (back up first)
  for f in "$NP_DIR"/*.yaml "$NP_DIR"/*.yml; do
    [[ -f "$f" ]] || continue
    cp -a "$f" "$f.bak.$(date +%s)" 2>/dev/null || true
  done

  NP_FILE="$NP_DIR/99-hardening-lab.yaml"
  log "writing $NP_FILE ($IFACE -> $IP_ADDR/$PREFIX)"
  cat > "$NP_FILE" <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: false
      addresses:
        - ${IP_ADDR}/${PREFIX}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS1}, ${DNS2}]
EOF
  chmod 600 "$NP_FILE"
  # Drop other netplan files that might still set dhcp on same iface — comment approach: make ours win by name 99-
  netplan generate
  netplan apply || { log "netplan apply had issues — reboot after this script"; NEED_REBOOT=1; }
  sleep 1
  ip -br addr show "$IFACE" || true
else
  log "skipping network config (--skip-net)"
fi

# --- hosts -------------------------------------------------------------------
for pair in "$KALI_IP kali-mentor" "$IP_ADDR ubuntu01" "$WIN_IP win19_srv01"; do
  ip="${pair%% *}"; name="${pair##* }"
  if grep -qE "[[:space:]]${name}([[:space:]]|$)" /etc/hosts; then
    sed -i -E "s/^[0-9.]+[[:space:]]+${name}.*/${ip}\t${name}/" /etc/hosts
  else
    echo -e "${ip}\t${name}" >> /etc/hosts
  fi
done

# --- packages ----------------------------------------------------------------
log "installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq openssh-server curl ca-certificates python3 >/dev/null
systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true

# --- optional salt minion ----------------------------------------------------
if [[ "$INSTALL_SALT" -eq 1 ]]; then
  log "installing salt-minion (master=$MASTER_IP, id=$HOSTNAME_NEW)"
  apt-get install -y -qq salt-minion >/dev/null || {
    log "WARNING: salt-minion install failed — install manually"
  }
  mkdir -p /etc/salt/minion.d
  cat > /etc/salt/minion.d/master.conf <<EOF
master: ${MASTER_IP}
id: ${HOSTNAME_NEW}
EOF
  systemctl enable --now salt-minion
  systemctl restart salt-minion
  log "On Kali: sudo salt-key -A   then   sudo salt '$HOSTNAME_NEW' grains.setval role hardening-linux"
fi

# Scoreboard Desktop shortcut (points at admin Kali scoreboard)
SB_URL="http://${KALI_IP}:8080/"
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$SCRIPT_ROOT/scripts/make_scoreboard_shortcut.sh" ]]; then
  # Current admin user + placeholder for student once Phase-1 creates them
  bash "$SCRIPT_ROOT/scripts/make_scoreboard_shortcut.sh" "$SB_URL" "${SUDO_USER:-$(logname 2>/dev/null || echo root)}" || true
fi

cat <<EOF

[setup-ubuntu] DONE
  Hostname : $HOSTNAME_NEW
  IP       : $IP_ADDR/$PREFIX  (iface: ${IFACE:-skipped})
  Student  : NOT created yet (run linux/setup_phase1.sh for that)
  Shortcut : Desktop scoreboard launcher -> $SB_URL
             (Phase-1 also places one on the student Desktop)

Next (after reboot if prompted):
  1) Copy/clone F26_system_hardening_lab onto this box
  2) export SCOREBOARD_URL=http://${KALI_IP}:8080
  3) export HARDENING_SECRET=dcig-hardening-2026
  4) sudo bash linux/setup_phase1.sh --no-switch
  5) sudo -u student -i hardening-quest

EOF

if [[ "$NEED_REBOOT" -eq 1 ]]; then
  log "REBOOT RECOMMENDED so hostname/network fully settle:  sudo reboot"
fi
