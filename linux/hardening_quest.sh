#!/usr/bin/env bash
# =============================================================================
#  DCIG System Hardening — Linux Quest (Phase 1)
#  Run as student:  hardening-quest
# =============================================================================
set -o pipefail

CFG=/etc/hardening-lab
H="${HOME:-/home/student}"
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
LEVEL=1; SCORE=0; HINTS_USED=0; LAST_OUT=""
[[ -f "$PROGRESS" ]] && LEVEL=$(( $(cat "$PROGRESS") + 1 ))
[[ -f "$SCOREFILE" ]] && SCORE=$(cat "$SCOREFILE")

# ---- missions / levels ------------------------------------------------------
M_NAME=("ATTACK SURFACE" "LOCKDOWN" "HARDEN")
M_TAG=("M1" "M2" "M3")
M_STORY=(
"Lab 001 — before you change anything, map what an attacker could use.
Open ports, weird accounts, startup-like persistence, and junk software all count."
"Cut privilege and password risk. Extra admins and world-writable secrets are free wins for attackers."
"Shut the remaining windows: rogue service, listening junk, firewall, and fake 'cleaner' malware."
)
M_OBJ=(
"List users, services, and listening ports
Spot software that should not be here
Answer a few inventory questions"
"Remove or demote the risky admin
Fix dangerous file permissions"
"Stop persistence and open listeners
Turn the firewall back on
Remove bloat / fake malware paths"
)

L_M=(); L_TITLE=(); L_TASK=(); L_WHY=(); L_TYPE=(); L_HINTS=()
add_level() {
  L_M+=("$1"); L_TITLE+=("$2"); L_TASK+=("$3"); L_WHY+=("$4"); L_TYPE+=("$5"); L_HINTS+=("$6")
}

# Mission 1 — attack surface
add_level 1 "Read the briefing" \
"Read ~/briefing.txt and submit the team number printed there (two digits).  answer <NN>" \
"Know which box and team you are before you change anything." \
answer "cat ~/briefing.txt|grep Team"

add_level 1 "Who has a login shell?" \
"How many local users in /etc/passwd have /bin/bash as their shell?  answer <number>" \
"Every interactive account is part of the attack surface." \
answer "grep bash /etc/passwd|grep -c '/bin/bash'"

add_level 1 "Suspicious software" \
"There is fake bloatware under /opt. Submit the directory name of the 'cleaner' app (just the folder name under /opt).  answer <name>" \
"Unused or sketchy software is another open window." \
answer "ls /opt|PCCleaner"

add_level 1 "Listening ports" \
"Something is listening on TCP port 9999. Submit the port number to confirm you found it.  answer 9999" \
"ss -tulnp (or ss -tlnp) shows listeners. Unexpected ports are findings." \
answer "ss -tlnp|9999"

add_level 1 "Rogue service name" \
"A suspicious systemd service is running. Submit its unit name without .service.  answer <name>" \
"systemctl list-units --type=service --state=running" \
answer "systemctl|cache-sync"

# Mission 2 — lockdown
add_level 2 "Find the extra admin" \
"One local user should not be in the sudo group. Submit that username.  answer <user>" \
"Least privilege: almost nobody needs admin on a workstation." \
answer "getent group sudo|tempadmin"

add_level 2 "Demote or remove tempadmin" \
"Remove tempadmin from the sudo group (or delete the account). The level auto-passes when they are no longer an admin." \
"usermod -G ... or deluser. Prefer removing sudo first if you want to keep the account for forensics." \
auto "sudo deluser tempadmin sudo|sudo gpasswd -d tempadmin sudo"

add_level 2 "Fix the secret file" \
"/opt/vault/keys.txt is world-writable. Make it readable only by root (mode 600) and owned by root." \
"chmod / chown. Secrets should never be 777." \
auto "sudo chmod 600 /opt/vault/keys.txt"

# Mission 3 — harden
add_level 3 "Stop the rogue service" \
"Stop and disable the cache-sync service so it cannot come back after reboot." \
"systemctl stop / disable. During IR you often disable rather than delete." \
auto "sudo systemctl disable --now cache-sync"

add_level 3 "Kill the listener" \
"Stop whatever is bound to TCP 9999 (kill the process). Level passes when nothing listens on 9999." \
"ss -tlnp to find the PID, then kill." \
auto "sudo kill|pkill listen9999"

add_level 3 "Enable the firewall" \
"Enable ufw and make sure it is active (default deny incoming is fine for this lab)." \
"sudo ufw enable — having a firewall is not the same as antivirus, but you want both ideas on a real Windows box." \
auto "sudo ufw enable"

add_level 3 "Remove bloat + cron" \
"Delete the /opt/PCCleaner tree and remove /etc/cron.d/pccleaner." \
"Unused software and persistence belong in the trash." \
auto "sudo rm -rf /opt/PCCleaner"

TOTAL=${#L_TITLE[@]}

check_1()  { [[ "$(norm "$1")" == "$(norm "$(as_root cat "$CFG/team" 2>/dev/null)")" ]]; }
check_2()  {
  local n
  n=$(grep -c '/bin/bash$' /etc/passwd 2>/dev/null || echo 0)
  [[ "$(norm "$1")" == "$(norm "$n")" ]]
}
check_3()  { local a; a=$(norm "$1"); [[ "$a" == "pccleaner" ]]; }
check_4()  { [[ "$(norm "$1")" == "9999" ]]; }
check_5()  { local a; a=$(norm "$1"); [[ "$a" == "cachesync" || "$a" == "cache-sync" ]]; }
check_6()  { [[ "$(norm "$1")" == "tempadmin" ]]; }
check_7()  { ! id tempadmin >/dev/null 2>&1 || ! id -nG tempadmin 2>/dev/null | tr ' ' '\n' | grep -qx sudo; }
check_8()  {
  [[ "$(stat -c %a /opt/vault/keys.txt 2>/dev/null)" == "600" ]] &&
  [[ "$(stat -c %U /opt/vault/keys.txt 2>/dev/null)" == "root" ]]
}
check_9()  { ! svc_active cache-sync && ! svc_enabled cache-sync; }
check_10() { ! ss -tln | grep -q ':9999'; }
check_11() { command -v ufw >/dev/null && ufw status 2>/dev/null | head -1 | grep -qi 'active'; }
check_12() { [[ ! -e /opt/PCCleaner ]] && [[ ! -e /etc/cron.d/pccleaner ]]; }

base_points() { echo 10; }
level_points() { local p=$(( $(base_points) - 2 * HINTS_USED )); (( p < 0 )) && p=0; echo "$p"; }
save() { echo "$((LEVEL - 1))" > "$PROGRESS"; echo "$SCORE" > "$SCOREFILE"; }

banner() {
  cat <<EOF
${C}${BOLD}
  HARDENING QUEST  ·  Linux
${N}${DIM}  Map the attack surface. Lock it down. Type ${N}help${DIM} any time.${N}

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
  [[ "${L_TYPE[$((LEVEL - 1))]}" == "answer" ]] || { warn "This level auto-passes; no answer needed."; return; }
  [[ -n "${1:-}" ]] || { warn "Usage: answer <value>"; return; }
  if "check_$LEVEL" "$1"; then advance; else err "Not it. Try hint."; fi
}

finish() {
  line
  printf '%s%s Linux quest complete. Score: %d%s\n' "$G" "$BOLD" "$SCORE" "$N"
  say ""
  local team winhost
  team="$(as_root cat "$CFG/team" 2>/dev/null || echo 'NN')"
  winhost="win19_srv${team}"
  say "  ${BOLD}NEXT:${N} Log into your Windows box ${C}${winhost}${N} and run:"
  say "    ${C}hardening-quest${N}"
  say ""
  say "  Phase 2 prep starts automatically on this Linux box — you do not run anything else here."
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

while true; do
  printf '%s hardening:%s%s%s> %s' "$DIM" "$N" "$C" "$LEVEL" "$N"
  IFS= read -r cmd || { say ""; break; }
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
      LAST_OUT=""
      set +e
      LAST_OUT="$(eval "$cmd" 2>&1)"
      rc=$?
      set -e
      printf '%s\n' "$LAST_OUT"
      (( rc == 0 )) || true
      try_auto
      ;;
  esac
done
