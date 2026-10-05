#!/usr/bin/env bash
# =============================================================================
#  DCIG System Hardening — Linux Quest (Phase 1)
#  Run as student:  hardening-quest
# =============================================================================
set -o pipefail

CFG=/etc/hardening-lab
LIB=/usr/local/lib/hardening-lab
H="${HOME:-/home/student}"
[[ -f "$LIB/team_id.sh" ]] && # shellcheck source=/dev/null
  source "$LIB/team_id.sh"
STATE="$H/.hardening-quest"
PROGRESS="$STATE/progress"; SCOREFILE="$STATE/score"
SHOW_SCORE_CODE=${SHOW_SCORE_CODE:-0}

[[ -t 1 ]] && { R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; BOLD=$'\e[1m'; DIM=$'\e[2m'; N=$'\e[0m'; } \
            || { R=; G=; Y=; C=; BOLD=; DIM=; N=; }
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✔ %s%s\n' "$G" "$*" "$N"; }
warn() { printf '%s! %s%s\n' "$Y" "$*" "$N"; }
err()  { printf '%s✘ %s%s\n' "$R" "$*" "$N"; }
line() { printf '%s────────────────────────────────────────────────────────%s\n' "$DIM" "$N"; }
as_root() { if [[ ${EUID:-1} -eq 0 ]]; then "$@"; else sudo -n "$@"; fi; }
norm() { tr '[:upper:]' '[:lower:]' <<<"$1" | tr -d '[:space:]'; }
svc_active()  { systemctl is-active "$1" 2>/dev/null | grep -qx active; }
svc_enabled() { systemctl is-enabled "$1" 2>/dev/null | grep -qx enabled; }

mkdir -p "$STATE"
LEVEL=1; SCORE=0; HINTS_USED=0
[[ -f "$PROGRESS" ]] && LEVEL=$(( $(cat "$PROGRESS") + 1 ))
[[ -f "$SCOREFILE" ]] && SCORE=$(cat "$SCOREFILE")

# ---- missions / levels ------------------------------------------------------
# Short tool drill (~10 min). Teach command → use once → next. Phase 2 is the real race.
M_NAME=("TOOL DRILL")
M_TAG=("DRILL")
M_STORY=(
"Goal: under ~10 minutes, learn the Linux tools you need for the CyberPatriot race.
Each step shows the command (and important flags). Run it, prove it worked, move on.
When you finish, Phase 2 plants harder findings automatically — that is where you spend your time."
)
M_OBJ=(
"Accounts, listeners, services, firewall, cron, files — quick reps only"
)

L_M=(); L_TITLE=(); L_TASK=(); L_WHY=(); L_TYPE=(); L_HINTS=()
add_level() {
  L_M+=("$1"); L_TITLE+=("$2"); L_TASK+=("$3"); L_WHY+=("$4"); L_TYPE+=("$5"); L_HINTS+=("$6")
}

# 1 — cat
add_level 1 "cat — read a file" \
"Tool:  cat <file>
Run:   cat ~/briefing.txt
Submit your two-digit team number.  answer <NN>" \
"You will read notes and configs constantly in Phase 2." \
answer "cat ~/briefing.txt"

# 2 — users / sudo group
add_level 1 "getent — list a group" \
"Tool:  getent group <name>
Run:   getent group sudo
Who should NOT be an admin here? Submit that username.  answer <user>" \
"Phase 2: hunt extra sudo users the same way." \
answer "getent group sudo|tempadmin"

# 3 — listeners
add_level 1 "ss — listening ports" \
"Tool:  ss -tulnp
  -t tcp   -u udp   -l listening   -n numeric   -p process
Run:   ss -tulnp
Something is listening on TCP 9999. Confirm with:  answer 9999" \
"Unexpected listeners are high-value Phase 2 findings." \
answer "ss -tulnp|9999"

# 4 — services (practice stop/disable)
add_level 1 "systemctl — stop a service" \
"Tool:  sudo systemctl disable --now <unit>
  disable = no start on boot    --now = also stop right now
Practice on the planted unit:
  sudo systemctl disable --now cache-sync
Level auto-passes when cache-sync is stopped and disabled." \
"Phase 2 will have stealthier service names — same commands." \
auto "systemctl disable --now cache-sync"

# 5 — firewall (--force skips the y|n prompt that breaks this REPL over SSH)
add_level 1 "ufw — enable firewall" \
"Tool:  sudo ufw status
        sudo ufw --force enable
Check status, then enable with --force (no y/n prompt). SSH (port 22) is pre-allowed
so you won't lock yourself out. Or skip the command:  answer ufw" \
"Firewall on = free points in Phase 2 if someone turned it off." \
auto "sudo ufw --force enable|answer ufw"

# 6 — cron + remove bloat (one quick combo)
add_level 1 "cron + rm — persistence & junk software" \
"Tools:  ls /etc/cron.d
         sudo rm -rf <path>     and/or     sudo rm /etc/cron.d/<file>
1) List cron drop-ins:  ls /etc/cron.d
2) Remove the fake cleaner and its cron:
     sudo rm -rf /opt/PCCleaner
     sudo rm -f /etc/cron.d/pccleaner
Auto-passes when both are gone. Or skip the deletes:  answer pccleaner" \
"Phase 2: more cron paths and /opt junk — same pattern." \
auto "rm PCCleaner|answer pccleaner"

TOTAL=${#L_TITLE[@]}

check_1()  { [[ "$(norm "$1")" == "$(norm "$(as_root cat "$CFG/team" 2>/dev/null)")" ]]; }
check_2()  { [[ "$(norm "$1")" == "tempadmin" ]]; }
check_3()  { [[ "$(norm "$1")" == "9999" ]]; }
check_4()  { ! svc_active cache-sync && ! svc_enabled cache-sync; }
check_5()  {
  # Auto path: firewall already active. Answer path: they typed the tool name.
  if [[ -n "${1:-}" ]]; then
    [[ "$(norm "$1")" == "ufw" ]]
  else
    command -v ufw >/dev/null && ufw status 2>/dev/null | head -1 | grep -qi 'active'
  fi
}
check_6()  {
  if [[ -n "${1:-}" ]]; then
    [[ "$(norm "$1")" == "pccleaner" ]]
  else
    [[ ! -e /opt/PCCleaner ]] && [[ ! -e /etc/cron.d/pccleaner ]]
  fi
}

base_points() { echo 10; }
level_points() { local p=$(( $(base_points) - 2 * HINTS_USED )); (( p < 0 )) && p=0; echo "$p"; }
save() { echo "$((LEVEL - 1))" > "$PROGRESS"; echo "$SCORE" > "$SCOREFILE"; }

banner() {
  cat <<EOF
${C}${BOLD}
  HARDENING QUEST  ·  Linux  ·  ~10 min tool drill
${N}${DIM}  Learn the commands for the CyberPatriot race. Type ${N}help${DIM} any time.${N}

EOF
}

show_help() {
  line
  say "  ${C}task${N}  ${C}mission${N}  ${C}hint${N}  ${C}answer X${N}  ${C}skip${N}  ${C}progress${N}  ${C}quit${N}"
  say "  Everything else runs as a real shell command."
  line
}

show_mission() {
  local m=$1 i=$((m - 1))
  line
  printf '%s MISSION %d: %s%s\n' "$BOLD" "$m" "${M_NAME[$i]}" "$N"
  printf '%s\n' "${M_STORY[$i]}" | sed 's/^/  /'
  line
}

show_task() {
  local i=$((LEVEL - 1))
  line
  printf '%s%s · %s%s\n' "$BOLD" "${M_TAG[$(( ${L_M[$i]} - 1 ))]}" "${L_TITLE[$i]}" "$N"
  printf '%s\n' "${L_TASK[$i]}" | sed 's/^/  /'
  say "  ${DIM}Why: ${L_WHY[$i]}${N}"
  line
}

show_hint() {
  local i=$((LEVEL - 1))
  IFS='|' read -r -a hints <<<"${L_HINTS[$i]}"
  if (( HINTS_USED >= ${#hints[@]} )); then warn "No more hints."; return; fi
  printf '%sHint %d (-2 pts):%s %s\n' "$Y" $((HINTS_USED + 1)) "$N" "${hints[$HINTS_USED]}"
  HINTS_USED=$((HINTS_USED + 1))
}

advance() {
  local pts=${1:-$(level_points)} m=${L_M[$((LEVEL - 1))]}
  SCORE=$((SCORE + pts))
  ok "Level complete  +$pts   (total $SCORE)"
  LEVEL=$((LEVEL + 1)); save
  if (( LEVEL > TOTAL )); then finish; exit 0; fi
  if [[ "${L_M[$((LEVEL - 1))]}" != "$m" ]]; then show_mission "${L_M[$((LEVEL - 1))]}"; fi
  HINTS_USED=0
  show_task
}

try_auto() {
  [[ "${L_TYPE[$((LEVEL - 1))]}" == "auto" ]] || return 0
  "check_$LEVEL" && advance
}

try_answer() {
  local t="${L_TYPE[$((LEVEL - 1))]}"
  # "auto" levels may still accept answer <value> when the hint string includes it
  if [[ "$t" != "answer" && "$t" != "auto" ]]; then
    warn "This level does not take an answer."; return
  fi
  if [[ "$t" == "auto" && "${L_HINTS[$((LEVEL - 1))]}" != *answer* ]]; then
    warn "This level auto-passes; no answer needed."; return
  fi
  [[ -n "${1:-}" ]] || { warn "Usage: answer <value>"; return; }
  if "check_$LEVEL" "$1"; then advance; else err "Not it. Try hint."; fi
}

finish() {
  line
  printf '%s%s Linux quest complete. Score: %d%s\n' "$G" "$BOLD" "$SCORE" "$N"
  say ""
  local team winhost
  team="$(as_root cat "$CFG/team" 2>/dev/null || echo 'NN')"
  if declare -F windows_peer_hostname >/dev/null 2>&1; then
    winhost="$(windows_peer_hostname "$team")"
  else
    winhost="win19_srv${team}"
  fi
  say "  ${BOLD}NEXT:${N} Log into your Windows box ${C}${winhost}${N} and run the short Windows tool drill:"
  say "    ${C}hardening-quest${N}"
  say ""
  say "  Phase 2 (CyberPatriot race) prep starts automatically on this Linux box."
  line

  # Auto-start Phase-2 prep (no student action). Prefer systemd oneshot; fall back to nohup.
  local started=0
  if systemctl list-unit-files hardening-prepare-phase2.service >/dev/null 2>&1; then
    if as_root systemctl start hardening-prepare-phase2.service; then
      started=1
      ok "Phase 2 prep started (systemctl hardening-prepare-phase2)"
    fi
  fi
  if [[ "$started" -eq 0 && -x /usr/local/sbin/hardening-prepare-phase2 ]]; then
    # Redirects must run as root (student cannot write /var/log)
    if as_root bash -c 'nohup /usr/local/sbin/hardening-prepare-phase2 >>/var/log/hardening-phase2-prep.log 2>&1 &'; then
      started=1
      ok "Phase 2 prep started in background"
    fi
  fi
  if [[ "$started" -eq 0 ]]; then
    warn "Could not auto-start Phase 2 prep — ask a mentor (sudo systemctl start hardening-prepare-phase2)."
  else
    say "  ${DIM}Log: /var/log/hardening-phase2-prep.log${N}"
  fi
  printf 'phase1-done\n' | as_root tee "$CFG/phase" >/dev/null 2>&1 || true
}

# ---- main loop --------------------------------------------------------------
banner
show_help
if (( LEVEL > TOTAL )); then finish; exit 0; fi
show_mission "${L_M[$((LEVEL - 1))]}"
show_task

trap 'printf "\n"; warn "Ctrl+C stopped the command, not the quest. Type quit to exit.";' INT

# Always drive the REPL from the real TTY. Shared stdin + a child command
# (or Guacamole/SSH quirks) otherwise EOFs `read` and silently drops to the shell.
QUEST_IN=/dev/tty
[[ -r "$QUEST_IN" ]] || QUEST_IN=/dev/stdin

while true; do
  printf '%s hardening:%s%s%s> %s' "$DIM" "$N" "$C" "$LEVEL" "$N"
  IFS= read -r cmd <"$QUEST_IN" || { say ""; break; }
  case "$cmd" in
    "" ) continue ;;
    help ) show_help ;;
    task ) show_task ;;
    mission ) show_mission "${L_M[$((LEVEL - 1))]}" ;;
    hint ) show_hint ;;
    progress )
      line; say "  Level $LEVEL / $TOTAL   Score $SCORE"; line ;;
    skip )
      warn "Skipped (0 pts)."; LEVEL=$((LEVEL + 1)); HINTS_USED=0; save
      if (( LEVEL > TOTAL )); then finish; exit 0; fi
      show_task ;;
    quit|exit ) save; say "Saved. Bye."; exit 0 ;;
    answer\ * )
      try_answer "${cmd#answer }" ;;
    * )
      # Subshell so command redirects cannot poison this loop's stdin.
      set +e
      ( eval "$cmd" ) <"$QUEST_IN"
      set +e
      try_auto
      ;;
  esac
done
