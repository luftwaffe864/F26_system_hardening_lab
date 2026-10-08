#!/usr/bin/env bash
# =============================================================================
#  DCIG System Hardening — Linux Quest (Phase 1)
#  Run as student:  hardening-quest
# =============================================================================
set -o pipefail

# nano/vim misread arrow keys when TERM is missing (web consoles, su -c, desktop launchers)
case "${TERM:-}" in ""|dumb|unknown) export TERM=xterm-256color ;; esac

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
answer "ls ~ to see what is in your home folder|cat ~/briefing.txt|answer $TEAM_NN"

add_level "getent — group members" \
"Tool  getent group <group>
Task  Who in the sudo group should not be an admin?  answer <user>" \
answer "getent group sudo|Ignore student - that is you|answer tempadmin"

add_level "ss — listening ports" \
"Tool  ss -tulnp   (-t tcp  -u udp  -l listening  -n numeric  -p process)
Task  Find the odd TCP port listening on this box.  answer <port>" \
answer "ss -tulnp|Look at Local Address for a high port that is not 22|answer 9999"

add_level "systemctl — stop a service" \
"Tool  systemctl list-units --type=service --state=running
      sudo systemctl disable --now <unit>
Task  A fake service is running. Stop it and keep it off after reboot." \
auto "systemctl list-units --type=service --state=running|Its name has 'cache' in it|sudo systemctl disable --now cache-sync"

add_level "cron + rm — persistence" \
"Tool  ls /etc/cron.d    cat <file>    sudo rm [-rf] <path>
Task  A fake cleaner runs from cron. Delete the cron job and the program it runs." \
auto "ls /etc/cron.d then cat the odd file|The job runs something under /opt|sudo rm -f /etc/cron.d/pccleaner && sudo rm -rf /opt/PCCleaner"

add_level "ufw — default deny firewall" \
"Tool  sudo ufw default <allow|deny> incoming
      sudo ufw allow <port>/tcp
      sudo ufw --force enable      sudo ufw status verbose
Task  Block all incoming traffic except SSH (22) and web (80), then turn ufw on." \
auto "sudo ufw default deny incoming|sudo ufw allow 22/tcp && sudo ufw allow 80/tcp|sudo ufw --force enable  (--force skips the y/n prompt)"

add_level "sudoers — give one user one command" \
"Task  User backupop has NO sudo rights. Give it permission to run exactly one
      command with sudo:   systemctl restart cron
      Do NOT add backupop to the sudo group (that would allow everything).
Tool  sudo visudo -f /etc/sudoers.d/backupop   (opens an editor; save: Ctrl+O Enter Ctrl+X)
      Rule format:  <user> ALL=(root) /full/path/to/command args
      sudo -l -U backupop                      (shows what backupop may run)" \
auto "Step 1: run  which systemctl  to get its full path|Step 2: sudo visudo -f /etc/sudoers.d/backupop, type ONE rule line, save and exit|Put this single line in the file: backupop ALL=(root) /usr/bin/systemctl restart cron"

add_level "passwd — disable root" \
"Tool  sudo passwd -S <user>    (P = usable password, L = locked)
      sudo passwd -l <user>
Task  Root has a password and can log in directly. Lock it." \
auto "sudo passwd -S root|-l locks the password; sudo still works for admins|sudo passwd -l root"

add_level "sshd_config — secure SSH" \
"Tool  sudo nano /etc/ssh/sshd_config
      sudo sshd -t                          (test syntax)
      sudo sshd -T | grep -i <setting>      (effective value)
      sudo systemctl reload ssh
Task  No root login, at most 3 auth tries, no X11 forwarding." \
auto "Settings: PermitRootLogin  MaxAuthTries  X11Forwarding|sshd uses the FIRST value it finds - edit existing lines, do not just append|PermitRootLogin no / MaxAuthTries 3 / X11Forwarding no, then sudo sshd -t && sudo systemctl reload ssh"

add_level "password policy" \
"Tool  sudo nano /etc/login.defs              (account aging)
      sudo nano /etc/security/pwquality.conf  (password strength)
Task  Passwords expire within 90 days and must be at least 12 characters." \
auto "Look for PASS_MAX_DAYS and minlen|Lines starting with # are ignored - remove the #|PASS_MAX_DAYS 90 in login.defs and minlen = 12 in pwquality.conf"

TOTAL=${#L_TITLE[@]}

check_1() { [[ "$(norm "$1")" == "$(norm "$TEAM_NN")" ]]; }
check_2() { [[ "$(norm "$1")" == "tempadmin" ]]; }
check_3() { [[ "$(norm "$1")" == "9999" ]]; }
check_4() { ! svc_active cache-sync && ! svc_enabled cache-sync; }
# Program gone (empty folder is fine) and no cron entry still pointing at it.
check_5() {
  [[ ! -e /opt/PCCleaner/pccleaner.sh ]] &&
    ! grep -rqs 'PCCleaner' /etc/cron.d /etc/crontab 2>/dev/null
}
check_6() {
  local s; s="$(as_root ufw status verbose 2>/dev/null)" || return 1
  grep -qi '^Status: active' <<<"$s" &&
    grep -qiE '^Default: (deny|reject) \(incoming\)' <<<"$s" &&
    grep -qE '^(22(/tcp)?|OpenSSH)[[:space:]]+ALLOW' <<<"$s" &&
    grep -qE '^80(/tcp)?[[:space:]]+ALLOW' <<<"$s"
}
check_7() {
  as_root visudo -c -q >/dev/null 2>&1 || return 1
  id -nG backupop 2>/dev/null | tr ' ' '\n' | grep -qxE 'sudo|admin|wheel' && return 1
  local l; l="$(as_root sudo -l -U backupop 2>/dev/null)" || return 1
  grep -qE 'systemctl restart cron(\.service)?[[:space:]]*$' <<<"$l" &&
    ! grep -qE '\)[[:space:]]*(NOPASSWD:[[:space:]]*)?ALL[[:space:]]*$' <<<"$l"
}
check_8() { [[ "$(as_root passwd -S root 2>/dev/null | awk '{print $2}')" == "L" ]]; }
check_9() {
  as_root install -d -m 755 /run/sshd >/dev/null 2>&1 || true
  local t m
  t="$(as_root /usr/sbin/sshd -T 2>/dev/null)" || return 1
  m="$(awk '$1=="maxauthtries"{print $2}' <<<"$t")"
  grep -qx 'permitrootlogin no' <<<"$t" &&
    grep -qx 'x11forwarding no' <<<"$t" &&
    [[ "$m" =~ ^[0-9]+$ ]] && (( m <= 3 ))
}
check_10() {
  local d m p
  d="$(awk '/^[[:space:]]*PASS_MAX_DAYS/{v=$2} END{print v}' /etc/login.defs 2>/dev/null)"
  m="$(cat /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf 2>/dev/null |
       awk -F= '/^[[:space:]]*minlen[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); v=$2} END{print v}')"
  p="$(grep -hoE 'pam_pwquality\.so.*minlen=[0-9]+' /etc/pam.d/common-password 2>/dev/null | grep -oE '[0-9]+$' | tail -1)"
  [[ "$p" =~ ^[0-9]+$ ]] && { [[ "$m" =~ ^[0-9]+$ ]] && (( m >= p )) || m="$p"; }
  [[ "$d" =~ ^[0-9]+$ ]] && (( d >= 1 && d <= 90 )) &&
    [[ "$m" =~ ^[0-9]+$ ]] && (( m >= 12 ))
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
  say "  ${DIM}Anything else runs as a normal shell command. Fix drills pass on their own.${N}"
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
  IFS='|' read -r -a hints <<<"${L_HINTS[$i]}"
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

prompt() { printf '%s hardening:%s%s%s> %s' "$DIM" "$N" "$C" "$LEVEL" "$N"; }

# Waits for a line, re-checking 'auto' drills every few seconds so a fix made in
# another terminal (or a long editor session) still advances the quest. The tty is
# line-buffered, so a timeout never eats half-typed input.
read_cmd() {
  local rc
  prompt
  while true; do
    IFS= read -r -t 3 cmd <"$QUEST_IN" && return 0
    rc=$?
    (( rc > 128 )) || return 1
    if is_auto && "check_$LEVEL" >/dev/null 2>&1; then
      say ""
      advance
      prompt
    fi
  done
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

while true; do
  read_cmd || { say ""; break; }
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
      set +e
      ( eval "$cmd" ) <"$QUEST_IN"
      try_auto
      ;;
  esac
done
