#!/usr/bin/env bash
# Create Desktop / app-menu launchers that open the scoreboard in a browser.
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
mkdir -p "$DESKTOP" "$HOME_DIR/.local/bin" "$HOME_DIR/.config/autostart"

# Remove launchers from older versions of this script
rm -f "$DESKTOP/DCIG Scoreboard.html" "$DESKTOP/DCIG-Scoreboard.desktop" "$HOME_DIR/open-scoreboard.sh"

# 1) Opener: browser if there is a desktop session, otherwise print URL + score
OPENER="$HOME_DIR/.local/bin/open-scoreboard"
cat > "$OPENER" <<EOF
#!/bin/bash
URL="${URL}"
if [[ -n "\${DISPLAY:-}\${WAYLAND_DISPLAY:-}" ]]; then
  for b in xdg-open sensible-browser firefox chromium google-chrome; do
    if command -v "\$b" >/dev/null 2>&1; then "\$b" "\$URL" >/dev/null 2>&1 & exit 0; fi
  done
fi
if command -v scoreboard >/dev/null 2>&1; then scoreboard; else echo "Open in a browser: \$URL"; fi
EOF
chmod 755 "$OPENER"

# 2) .desktop launcher (GNOME/KDE/XFCE). Exec must be an absolute path.
LAUNCHER_BODY="[Desktop Entry]
Version=1.0
Type=Application
Name=DCIG Scoreboard
Comment=Open the live team scoreboard
Exec=$OPENER
Icon=web-browser
Terminal=false
Categories=Network;"
DESKTOP_FILE="$DESKTOP/dcig-scoreboard.desktop"
printf '%s\n' "$LAUNCHER_BODY" > "$DESKTOP_FILE"
chmod 755 "$DESKTOP_FILE"

# App menu copy needs no "trust" step
if [[ $EUID -eq 0 ]]; then
  printf '%s\n' "$LAUNCHER_BODY" > /usr/share/applications/dcig-scoreboard.desktop
  chmod 644 /usr/share/applications/dcig-scoreboard.desktop
fi

# GNOME blocks Desktop launchers until marked trusted, and gio only works inside
# the user's session, so mark it at login via autostart.
cat > "$HOME_DIR/.config/autostart/dcig-trust-scoreboard.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=DCIG trust scoreboard launcher
Exec=gio set $DESKTOP_FILE metadata::trusted true
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

# 3) Plain URL file (any file manager / browser can open it)
cat > "$DESKTOP/DCIG Scoreboard URL.txt" <<EOF
Live scoreboard: ${URL}
Terminal: run  scoreboard
EOF

chown -R "$USER_NAME:$USER_NAME" "$DESKTOP" "$HOME_DIR/.local" "$HOME_DIR/.config" 2>/dev/null || true
echo "[shortcut] scoreboard launchers -> $DESKTOP (user $USER_NAME) url=$URL"
