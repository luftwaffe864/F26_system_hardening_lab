#!/usr/bin/env bash
# Start the hardening scoreboard on Kali (after setup_kali.sh).
#   bash start_scoreboard.sh
#   bash start_scoreboard.sh --bind 0.0.0.0 --port 8080
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB="$ROOT/scoreboard"
BIND="${HARDENING_HOST:-0.0.0.0}"
PORT="${HARDENING_PORT:-8080}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bind) BIND="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

export HARDENING_SECRET="${HARDENING_SECRET:-dcig-hardening-2026}"
export HARDENING_ADMIN="${HARDENING_ADMIN:-dcig-admin-2026}"
export HARDENING_HOST="$BIND"
export HARDENING_PORT="$PORT"

cd "$SB"
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
  # shellcheck disable=SC1091
  source .venv/bin/activate
  pip install -r requirements.txt
else
  # shellcheck disable=SC1091
  source .venv/bin/activate
fi

echo "[scoreboard] http://$(hostname -I 2>/dev/null | awk '{print $1}'):$PORT/  (bind $BIND)"
# Refresh Desktop shortcut to this host
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -n "$IP" && -f "$ROOT/scripts/make_scoreboard_shortcut.sh" ]]; then
  bash "$ROOT/scripts/make_scoreboard_shortcut.sh" "http://${IP}:${PORT}/" "${SUDO_USER:-$(id -un)}" || true
fi
exec python server.py
