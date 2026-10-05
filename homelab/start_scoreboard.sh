#!/usr/bin/env bash
# Start the hardening scoreboard (range master or homelab Kali).
#   bash start_scoreboard.sh
#   bash start_scoreboard.sh --bind 0.0.0.0 --port 8080
#
# If the lab tree is root-owned (/srv/salt/...), the venv is created under
# $HOME/.cache/... so you do not need write access to the repo.
#
# Debian/Ubuntu Salt master without python3-venv: install once (sudo):
#   apt install -y python3-venv python3-pip
# Or this script falls back to: pip3 install --user flask
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

PYTHON="python3"
VENV_DIR="${HARDENING_VENV:-}"

install_flask_user() {
  echo "[scoreboard] installing Flask for current user (no venv)"
  if pip3 install --user -r "$SB/requirements.txt" 2>/dev/null; then
    return 0
  fi
  pip3 install --user --break-system-packages -r "$SB/requirements.txt"
}

try_venv() {
  local dir="$1"
  mkdir -p "$(dirname "$dir")"
  if [[ -d "$dir" ]] && [[ ! -x "$dir/bin/python3" ]]; then
    echo "[scoreboard] removing broken venv at $dir"
    rm -rf "$dir"
  fi
  if [[ -d "$dir" ]]; then
    # shellcheck disable=SC1091
    source "$dir/bin/activate"
    PYTHON="python"
    VENV_DIR="$dir"
    return 0
  fi
  echo "[scoreboard] creating venv at $dir"
  if ! python3 -m venv "$dir" 2>/dev/null; then
    rm -rf "$dir"
    return 1
  fi
  if [[ ! -x "$dir/bin/python3" ]]; then
    rm -rf "$dir"
    return 1
  fi
  # shellcheck disable=SC1091
  source "$dir/bin/activate"
  pip install -r "$SB/requirements.txt"
  PYTHON="python"
  VENV_DIR="$dir"
  return 0
}

if [[ -n "$VENV_DIR" ]]; then
  try_venv "$VENV_DIR" || { echo "[scoreboard] HARDENING_VENV failed; install python3-venv or use pip fallback"; exit 1; }
else
  if [[ -w "$SB" ]] || [[ -w "$SB/.venv" ]]; then
    CAND="$SB/.venv"
  else
    CAND="${XDG_CACHE_HOME:-$HOME/.cache}/dcig-hardening-scoreboard/venv"
  fi
  if ! try_venv "$CAND"; then
    echo "[scoreboard] venv unavailable (install: sudo apt install -y python3-venv)"
    install_flask_user
    PYTHON="python3"
    VENV_DIR="(user site-packages)"
  fi
fi

cd "$SB"
echo "[scoreboard] http://$(hostname -I 2>/dev/null | awk '{print $1}'):$PORT/  (bind $BIND)"
echo "[scoreboard] python=$PYTHON venv=$VENV_DIR"
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -n "$IP" && -f "$ROOT/scripts/make_scoreboard_shortcut.sh" ]]; then
  bash "$ROOT/scripts/make_scoreboard_shortcut.sh" "http://${IP}:${PORT}/" "${SUDO_USER:-$(id -un)}" || true
fi
exec "$PYTHON" server.py
