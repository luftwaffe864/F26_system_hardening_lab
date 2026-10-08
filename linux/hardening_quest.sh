#!/usr/bin/env bash
# =============================================================================
#  DCIG System Hardening — Linux Quest (Phase 1)
#  Run as student:  hardening-quest
# =============================================================================
set -o pipefail

# nano/vim misread arrow keys when TERM is missing (web consoles, su -c, desktop launchers)
case "${TERM:-}" in ""|dumb|unknown) export TERM=xterm-256color ;; esac
# Remmina/xrdp keymap fix (arrow keys) - installed by setup
[[ -x /usr/local/bin/dcig-fix-keys ]] && /usr/local/bin/dcig-fix-keys

CFG=/etc/hardening-lab
LIB=/usr/local/lib/hardening-lab
H="${HOME:-/home/student}"
[[ -f "$LIB/team_id.sh" ]] && # shellcheck source=/dev/null
  source "$LIB/team_id.sh"
STATE="$H/.hardening-quest"
PROGRESS="$STATE/progress"; SCOREFILE="$STATE/score"

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
TEAM_NN="$(cat "$CFG/team" 2>/dev/null || echo NN)"

# ---- levels -----------------------------------------------------------------
# Task text = tool syntax + goal only. Answers live in the LAST hint.
L_TITLE=(); L_TASK=(); L_TYPE=(); L_HINTS=()
add_level() { L_TITLE+=("$1"); L_TASK+=("$2"); L_TYPE+=("$3"); L_HINTS+=("$4"); }

add_level "cat — read a file" \
"Tool  cat <file>
Task  Read the briefing in your home folder.  answer <team number>" \
answer "ls ~ to see what is in your home folder||cat ~/briefing.txt||answer $TEAM_NN"

add_level "getent — group members" \
"Tool  getent group <group>
Task  Who in the sudo group should not be an admin?  answer <user>" \
answer "getent group sudo||Ignore student - that is you||answer tempadmin"

add_level "ss — listening ports" \
"Tool  ss -tulnp   (-t tcp  -u udp  -l listening  -n numeric  -p process)
Task  Find the odd TCP port listening on this box.  answer <port>" \
answer "ss -tulnp||Look at Local Address for a high port that is not 22||answer 9999"

add_level "systemctl — stop a service" \
"Tool  systemctl list-units --type=service --state=running
      sudo systemctl disable --now <unit>
Task  A fake service is running. Stop it and keep it off after reboot." \
auto "systemctl list-units --type=service --state=running||Its name has 'cache' in it||sudo systemctl disable --now cache-sync"

add_level "cron + rm — persistence" \
"Tool  ls /etc/cron.d    cat <file>    sudo rm [-rf] <path>
Task  A fake cleaner runs from cron. Find its cron job and delete it." \
auto "ls /etc/cron.d - one file there is not a normal system job||cat it to confirm it runs something under /opt||sudo rm /etc/cron.d/pccleaner   (optional: sudo rm -rf /opt/PCCleaner)"

add_level "ufw — default deny firewall" \
"Tool  sudo ufw default <allow|deny> incoming
      sudo ufw allow <port>/tcp
      sudo ufw --force enable      sudo ufw status verbose
Task  Block all incoming traffic except SSH (22) and web (80), then turn ufw on." \
auto "sudo ufw default deny incoming||sudo ufw allow 22/tcp && sudo ufw allow 80/tcp||sudo ufw --force enable  (--force skips the y/n prompt)"

add_level "passwd — disable root" \
"Tool  sudo passwd -S <user>    (P = usable password, L = locked)
      sudo passwd -l <user>
Task  Root has a password and can log in directly. Lock it." \
auto "sudo passwd -S root||-l locks the password; sudo still works for admins||sudo passwd -l root"

add_level "sshd — no root login over SSH" \
"Task  Root can log in over SSH. Turn that off.
Tool  sudo sshd -T | grep permitrootlogin      (current value)
      echo '<Setting> <value>' | sudo tee /etc/ssh/sshd_config.d/00-hardening.conf
      sudo systemctl reload ssh                (apply)" \
auto "The setting is PermitRootLogin||Files in /etc/ssh/sshd_config.d/ override the main config||echo 'PermitRootLogin no' | sudo tee /etc/ssh/sshd_config.d/00-hardening.conf   then   sudo systemctl reload ssh"

add_level "chage — password expiry" \
"Task  Your password never expires. Make it expire every 90 days.
Tool  sudo chage -l <user>          (show password aging)
      sudo chage -M <days> <user>   (maximum days before a change is required)" \
auto "Your username is $(id -un)||-M sets the maximum password age in days||sudo chage -M 90 $(id -un)"

TOTAL=${#L_TITLE[@]}

check_1() { [[ "$(norm "$1")" == "$(norm "$TEAM_NN")" ]]; }
check_2() { [[ "$(norm "$1")" == "tempadmin" ]]; }
check_3() { [[ "$(norm "$1")" == "9999" ]]; }
check_4() { ! svc_active cache-sync && ! svc_enabled cache-sync; }
# Passes once no cron entry points at PCCleaner (deleting the program is optional).
check_5() {
  [[ ! -e /etc/cron.d/pccleaner ]] &&
    ! grep -rqis 'pccleaner' /etc/cron.d /etc/crontab 2>/dev/null
}
check_6() {
  local s; s="$(as_root ufw status verbose 2>/dev/null)" || return 1
  grep -qi '^Status: active' <<<"$s" &&
    grep -qiE '^Default: (deny|reject) \(incoming\)' <<<"$s" &&
    grep -qE '^(22(/tcp)?|OpenSSH)[[:space:]]+ALLOW' <<<"$s" &&
    grep -qE '^80(/tcp)?[[:space:]]+ALLOW' <<<"$s"
}
check_7() { [[ "$(as_root passwd -S root 2>/dev/null | awk '{print $2}')" == "L" ]]; }
check_8() {
  as_root install -d -m 755 /run/sshd >/dev/null 2>&1 || true
  as_root /usr/sbin/sshd -T 2>/dev/null | grep -qx 'permitrootlogin no'
}
# Field 5 of the shadow entry = maximum password age in days
check_9() {
  local d; d="$(as_root getent shadow "$(id -un)" 2>/dev/null | cut -d: -f5)"
  [[ "$d" =~ ^[0-9]+$ ]] && (( d >= 1 && d <= 90 ))
}

level_points() { local p=$(( 10 - 2 * HINTS_USED )); (( p < 0 )) && p=0; echo "$p"; }
save() { echo "$((LEVEL - 1))" > "$PROGRESS"; echo "$SCORE" > "$SCOREFILE"; }

banner() {
  say ""
  say "${C}${BOLD}  HARDENING QUEST · Linux${N}"
  say "${DIM}  $TOTAL short drills. Type ${N}help${DIM} for commands.${N}"
  say ""
}

show_help() {
  line
  say "  ${C}task${N}  ${C}hint${N}  ${C}check${N}  ${C}answer X${N}  ${C}skip${N}  ${C}progress${N}  ${C}scoreboard${N}  ${C}quit${N}"
  say "  ${C}keys${N}  ${DIM}nano / vim shortcuts (if arrow keys misbehave)${N}"
  say "  ${DIM}Anything else runs as a normal shell command. Up arrow = previous commands.${N}"
  say "  ${DIM}Fix drills pass after your next command (or press Enter / type check).${N}"
  line
}

show_keys() {
  line
  say "  ${BOLD}nano${N}  Ctrl+A start of line   Ctrl+E end of line   Ctrl+W search"
  say "        Alt+\\ top of file   Alt+/ end of file   Ctrl+_ go to line number"
  say "        Ctrl+O Enter = save   Ctrl+X = exit   Ctrl+K cut line   Ctrl+U paste"
  say "  ${BOLD}vim${N}   i insert   Esc stop inserting   h j k l = left down up right"
  say "        0 start of line   \$ end of line   A append at end of line"
  say "        /text search   :42 go to line 42   :wq save+quit   :q! quit, no save"
  line
}

show_task() {
  local i=$((LEVEL - 1))
  line
  printf '%sDRILL %d/%d · %s%s\n' "$BOLD" "$LEVEL" "$TOTAL" "${L_TITLE[$i]}" "$N"
  printf '%s\n' "${L_TASK[$i]}" | sed 's/^/  /'
  line
}

show_hint() {
  local i=$((LEVEL - 1)) label
  # Hints are separated by "||" so a hint can itself contain a | pipe
  local raw="${L_HINTS[$i]//||/$'\x1f'}"
  IFS=$'\x1f' read -r -a hints <<<"$raw"
  if (( HINTS_USED >= ${#hints[@]} )); then warn "No more hints."; return; fi
  label="Hint $((HINTS_USED + 1))/${#hints[@]}"
  (( HINTS_USED == ${#hints[@]} - 1 )) && label="Answer"
  printf '%s%s (-2 pts):%s %s\n' "$Y" "$label" "$N" "${hints[$HINTS_USED]}"
  HINTS_USED=$((HINTS_USED + 1))
}

show_scoreboard() {
  if command -v scoreboard >/dev/null 2>&1; then
    scoreboard
  else
    say "  Scoreboard: $(cat "$CFG/scoreboard_url" 2>/dev/null || echo 'ask a mentor')"
  fi
}

advance() {
  local pts=${1:-$(level_points)}
  SCORE=$((SCORE + pts))
  ok "Level complete  +$pts   (total $SCORE)"
  LEVEL=$((LEVEL + 1)); HINTS_USED=0; save
  if (( LEVEL > TOTAL )); then finish; exit 0; fi
  show_task
}

try_auto() {
  [[ "${L_TYPE[$((LEVEL - 1))]}" == "auto" ]] || return 0
  "check_$LEVEL" && advance
}

is_auto() { [[ "${L_TYPE[$((LEVEL - 1))]}" == "auto" ]]; }

# read -e = readline: arrow keys, Home/End, and Up/Down history at the quest prompt.
# Colour codes are wrapped in \001..\002 so readline measures the prompt correctly.
# Returns 0 = got a line, 1 = EOF, 2 = interrupted (Ctrl+C).
read_cmd() {
  local rc p
  p=$'\001'"$DIM"$'\002'" hardening:"$'\001'"$N$C"$'\002'"$LEVEL"$'\001'"$N"$'\002'"> "
  IFS= read -e -r -p "$p" cmd <"$QUEST_IN"
  rc=$?
  if (( rc == 0 )); then
    if [[ -n "$cmd" ]]; then
      history -s "$cmd"
      printf '%s\n' "$cmd" >>"$QUEST_HIST" 2>/dev/null
    fi
    return 0
  fi
  (( rc > 128 )) && return 2
  return 1
}

try_answer() {
  [[ "${L_TYPE[$((LEVEL - 1))]}" == "answer" ]] || { warn "This drill passes on its own once the system is fixed."; return; }
  [[ -n "${1:-}" ]] || { warn "Usage: answer <value>"; return; }
  if "check_$LEVEL" "$1"; then advance; else err "Not it. Try hint."; fi
}

finish() {
  line
  printf '%s%s Linux quest complete. Score: %d%s\n' "$G" "$BOLD" "$SCORE" "$N"
  say ""
  local winhost
  if declare -F windows_peer_hostname >/dev/null 2>&1; then
    winhost="$(windows_peer_hostname "$TEAM_NN")"
  else
    winhost="win19_srv${TEAM_NN}"
  fi
  say "  ${BOLD}NEXT:${N} RDP to ${C}${winhost}${N} and double-click ${C}Hardening Quest${N} on the Desktop."
  say "  Phase 2 prep is starting on this Linux box now."
  line

  # Auto-start Phase-2 prep (no student action). Prefer systemd oneshot; fall back to nohup.
  local started=0
  if systemctl list-unit-files hardening-prepare-phase2.service >/dev/null 2>&1; then
    if as_root systemctl start hardening-prepare-phase2.service; then
      started=1
      ok "Phase 2 prep started"
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
    warn "Could not auto-start Phase 2 prep — ask a mentor."
  fi
  printf 'phase1-done\n' | as_root tee "$CFG/phase" >/dev/null 2>&1 || true
}

# ---- main loop --------------------------------------------------------------
banner
show_help
if (( LEVEL > TOTAL )); then finish; exit 0; fi
show_task

trap 'printf "\n"; warn "Ctrl+C stopped the command, not the quest. Type quit to exit.";' INT

# Always drive the REPL from the real TTY. Shared stdin + a child command
# (or Guacamole/SSH quirks) otherwise EOFs `read` and silently drops to the shell.
QUEST_IN=/dev/tty
[[ -r "$QUEST_IN" ]] || QUEST_IN=/dev/stdin

# Up-arrow history survives quitting and re-opening the quest
QUEST_HIST="$STATE/history"
[[ -f "$QUEST_HIST" ]] && history -r "$QUEST_HIST"
stty sane <"$QUEST_IN" 2>/dev/null

while true; do
  read_cmd
  case $? in 1) say ""; break ;; 2) continue ;; esac
  case "$cmd" in
    "" ) try_auto ;;
    help ) show_help ;;
    task ) show_task ;;
    hint ) show_hint ;;
    keys ) show_keys ;;
    check )
      if ! is_auto; then warn "This drill needs: answer <value>"
      elif "check_$LEVEL"; then advance
      else warn "Not fixed yet - keep going or type hint."; fi ;;
    scoreboard ) show_scoreboard ;;
    progress )
      line; say "  Drill $LEVEL / $TOTAL   Score $SCORE"; line ;;
    skip )
      warn "Skipped (0 pts)."; LEVEL=$((LEVEL + 1)); HINTS_USED=0; save
      if (( LEVEL > TOTAL )); then finish; exit 0; fi
      show_task ;;
    quit|exit ) save; say "Saved. Bye."; exit 0 ;;
    answer\ * )
      try_answer "${cmd#answer }" ;;
    * )
      # Subshell so command redirects cannot poison this loop's stdin.
      # stty sane: undo any raw/no-echo mode a previous program left behind, so
      # nano/vim get a normal terminal and arrow keys arrive as arrow keys.
      set +e
      stty sane <"$QUEST_IN" 2>/dev/null
      ( eval "$cmd" ) <"$QUEST_IN"
      stty sane <"$QUEST_IN" 2>/dev/null
      try_auto
      ;;
  esac
done
