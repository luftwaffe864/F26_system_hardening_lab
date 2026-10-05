#!/usr/bin/env bash
# Start the hardening scoreboard (range master or homelab Kali).
#   bash start_scoreboard.sh
#   bash start_scoreboard.sh --bind 0.0.0.0 --port 8080
#
# If the lab tree is root-owned (/srv/salt/...), the venv is created under
# $HOME/.cache/... so you do not need write access to the repo.
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

# Prefer in-tree .venv when writable; otherwise use a per-user cache dir.
VENV_DIR="${HARDENING_VENV:-}"
if [[ -z "$VENV_DIR" ]]; then
  if [[ -w "$SB" ]] || [[ -w "$SB/.venv" ]]; then
    VENV_DIR="$SB/.venv"
  else
    VENV_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dcig-hardening-scoreboard/venv"
  fi
fi

mkdir -p "$(dirname "$VENV_DIR")"
if [[ ! -d "$VENV_DIR" ]]; then
  echo "[scoreboard] creating venv at $VENV_DIR"
  python3 -m venv "$VENV_DIR"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  pip install -r "$SB/requirements.txt"
else
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
fi

cd "$SB"
echo "[scoreboard] http://$(hostname -I 2>/dev/null | awk '{print $1}'):$PORT/  (bind $BIND)"
echo "[scoreboard] venv=$VENV_DIR"
# Refresh Desktop shortcut to this host (best-effort; may fail without a desktop)
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -n "$IP" && -f "$ROOT/scripts/make_scoreboard_shortcut.sh" ]]; then
  bash "$ROOT/scripts/make_scoreboard_shortcut.sh" "http://${IP}:${PORT}/" "${SUDO_USER:-$(id -un)}" || true
fi
exec python server.py
