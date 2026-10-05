#!/usr/bin/env bash
# =============================================================================
#  DCIG lab safety net — keep SSH + student login working during hardening.
#  Run as root (systemd timer). Does not undo scored findings except access paths.
# =============================================================================
set -euo pipefail

CFG=/etc/hardening-lab
STUDENT="${STUDENT_USER:-student}"
STUDENT_PW_FILE="$CFG/student_password"

[[ -f "$STUDENT_PW_FILE" ]] || exit 0
STUDENT_PW="$(cat "$STUDENT_PW_FILE")"
[[ -n "$STUDENT_PW" ]] || exit 0

# --- student account ---------------------------------------------------------
if ! id "$STUDENT" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -c "DCIG Hardening Student" "$STUDENT"
fi
echo "$STUDENT:$STUDENT_PW" | chpasswd
usermod -aG sudo "$STUDENT" 2>/dev/null || true
# Keep quest sudo (NOPASSWD) if Phase-1 installed it
if [[ -f /etc/sudoers.d/90-hardening-lab ]]; then
  chmod 440 /etc/sudoers.d/90-hardening-lab
fi

# --- SSH ---------------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
  systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null || true
fi
install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/50-dcig-lab-access.conf <<'EOF'
# DCIG lab: students must keep SSH on port 22 with password auth.
Port 22
PasswordAuthentication yes
PubkeyAuthentication yes
EOF
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

# --- firewall: never block SSH when ufw is on --------------------------------
if command -v ufw >/dev/null 2>&1; then
  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw allow 22/tcp comment 'DCIG lab SSH' >/dev/null 2>&1 || true
fi

exit 0
