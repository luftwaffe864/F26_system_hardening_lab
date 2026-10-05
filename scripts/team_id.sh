#!/usr/bin/env bash
# Shared team ID + peer hostname helpers (cyber range + homelab).
#
# Cyber range Salt minion IDs / hostnames:
#   dcig-syslab-team07-ubuntu   Linux target
#   win19_srv07                 Windows target
#   team07-jump                 jumpbox (access only)
# Homelab: ubuntu07, win19_srv07 (trailing digits)

team_from_hostname() {
  local h="${1:-$(hostname -s 2>/dev/null || hostname)}"
  local n
  n="$(printf '%s' "$h" | grep -oiE 'team[0-9]+' | head -1 | grep -oE '[0-9]+' || true)"
  if [[ -n "$n" ]]; then
    printf '%02d' "$((10#$n))"
    return 0
  fi
  n="$(printf '%s' "$h" | grep -oE '[0-9]+$' || true)"
  if [[ -n "$n" ]]; then
    printf '%02d' "$((10#$n))"
    return 0
  fi
  echo "00"
}

# Windows box name for handoff text (after Linux quest).
windows_peer_hostname() {
  local team="${1:-00}"
  # Range + homelab both use win19_srvNN for the Windows target.
  printf 'win19_srv%s' "$team"
}
