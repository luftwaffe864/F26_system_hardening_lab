#!/usr/bin/env bash
# Quick connectivity / hostname check from any Linux box (Kali or Ubuntu).
#   bash verify_connectivity.sh
#   bash verify_connectivity.sh --kali 192.168.56.10 --ubuntu 192.168.56.11 --win 192.168.56.12
set -euo pipefail

KALI="${KALI:-192.168.56.10}"
UBUNTU="${UBUNTU:-192.168.56.11}"
WIN="${WIN:-192.168.56.12}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kali) KALI="$2"; shift 2 ;;
    --ubuntu) UBUNTU="$2"; shift 2 ;;
    --win) WIN="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

echo "Hostname: $(hostname -s 2>/dev/null || hostname)"
echo "Addresses:"
ip -br addr 2>/dev/null || ifconfig 2>/dev/null || true
echo

ping_one() {
  local name="$1" ip="$2"
  if ping -c 2 -W 2 "$ip" >/dev/null 2>&1; then
    echo "  OK   $name ($ip)"
  else
    echo "  FAIL $name ($ip)"
  fi
}

echo "Ping checks:"
ping_one kali-mentor "$KALI"
ping_one ubuntu01 "$UBUNTU"
ping_one win19_srv01 "$WIN"

echo
if curl -fsS -m 3 "http://${KALI}:8080/api/status" >/dev/null 2>&1; then
  echo "  OK   scoreboard http://${KALI}:8080/api/status"
  curl -sS "http://${KALI}:8080/api/status" | head -c 200; echo
else
  echo "  ---- scoreboard not reachable at http://${KALI}:8080 (start it on Kali if expected)"
fi
