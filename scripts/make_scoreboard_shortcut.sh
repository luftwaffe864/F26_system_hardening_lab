#!/usr/bin/env bash
# Create Desktop / home launchers that open the scoreboard in a browser.
# Usage:
#   make_scoreboard_shortcut.sh <url> [username]
# If username omitted, uses SUDO_USER or current user.
set -euo pipefail

URL="${1:-}"
USER_NAME="${2:-${SUDO_USER:-$(id -un)}}"
[[ -n "$URL" ]] || { echo "usage: $0 <scoreboard-url> [username]"; exit 1; }
URL="${URL%/}/"

HOME_DIR="$(getent passwd "$USER_NAME" 2>/dev/null | cut -d: -f6 || true)"
[[ -n "$HOME_DIR" && -d "$HOME_DIR" ]] || HOME_DIR="/home/$USER_NAME"
DESKTOP="$HOME_DIR/Desktop"
mkdir -p "$DESKTOP"

# Escape URL for HTML attribute (minimal)
html_esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/"/\&quot;/g'; }

HURL="$(html_esc "$URL")"

# 1) HTML redirect — double-click friendly
HTML="$DESKTOP/DCIG Scoreboard.html"
cat > "$HTML" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta http-equiv="refresh" content="0; url=${HURL}"/>
  <title>DCIG Hardening Scoreboard</title>
  <script>window.location.replace("${URL}");</script>
</head>
<body style="font-family:sans-serif;background:#0b1220;color:#e8eefc;padding:2rem">
  <h1>Opening scoreboard…</h1>
  <p>If nothing happens, <a href="${HURL}" style="color:#3dd6c6">click here</a>.</p>
</body>
</html>
EOF

# 2) .desktop launcher (GNOME/KDE/XFCE)
DESKTOP_FILE="$DESKTOP/DCIG-Scoreboard.desktop"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=DCIG Hardening Scoreboard
Comment=Open the live team scoreboard in your browser
Exec=xdg-open ${URL}
Icon=web-browser
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=true
EOF
chmod +x "$DESKTOP_FILE"
if command -v gio >/dev/null 2>&1; then
  sudo -u "$USER_NAME" gio set "$DESKTOP_FILE" metadata::trusted true 2>/dev/null || \
    gio set "$DESKTOP_FILE" metadata::trusted true 2>/dev/null || true
fi

# 3) Shell helper (SSH / no GUI)
cat > "$HOME_DIR/open-scoreboard.sh" <<EOF
#!/bin/bash
URL="${URL}"
if command -v xdg-open >/dev/null 2>&1; then
  xdg-open "\$URL" >/dev/null 2>&1 &
elif command -v sensible-browser >/dev/null 2>&1; then
  sensible-browser "\$URL" >/dev/null 2>&1 &
else
  echo "Open this URL in a browser: \$URL"
fi
EOF
chmod +x "$HOME_DIR/open-scoreboard.sh"

chown -R "$USER_NAME:$USER_NAME" "$DESKTOP" "$HOME_DIR/open-scoreboard.sh" 2>/dev/null || true
echo "[shortcut] scoreboard launchers -> $DESKTOP (user $USER_NAME) url=$URL"
