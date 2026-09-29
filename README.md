# DCIG System Hardening Lab (Fall · Oct 8 meeting)

Guided quests on **Linux then Windows**, then a CyberPatriot-style **Phase 2** find-and-fix with a live **team** scoreboard.

Each student gets a paired box set:

| OS | Hostname pattern |
|----|------------------|
| Linux | `ubuntu01` … `ubuntu30` |
| Windows | `win19_srv01` … `win19_srv30` |

**Team NN** = trailing digits (e.g. `ubuntu07` + `win19_srv07` → Team 07).

## Student flow

1. Start on **Linux** → run `hardening-quest`
2. Linux quest end → go to matching **Windows** box; Linux **Phase 2 prep** starts in the background
3. On Windows → run `hardening-quest`
4. Windows quest end → “please wait…” while **Windows Phase 2 prep** runs
5. Mentors **open Phase 2** on the scoreboard → students harden both boxes; agents post points under Team NN

```text
ubuntuNN ──quest──► handoff ──► (linux prepare_phase2)
                         │
                         ▼
              win19_srvNN ──quest──► wait/prepare_phase2
                         │
                         ▼
              Phase 2 find-and-fix (both) ──► live scoreboard
```

## Homelab dry-run (1 Linux + 1 Windows)

Use hostnames `ubuntu01` / `win19_srv01` (or any names ending in digits).

```bash
# On mentor/scoreboard host
cd scoreboard
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
export HARDENING_SECRET=dcig-hardening-2026
export HARDENING_ADMIN=dcig-admin-2026
python server.py
# projector: http://<this-host>:8080/
```

```bash
# Linux box (as root) — fix CRLF if copied from Windows:
#   sed -i 's/\r$//' linux/*.sh
export SCOREBOARD_URL=http://<scoreboard-ip>:8080
export HARDENING_SECRET=dcig-hardening-2026
sudo bash linux/setup_phase1.sh --no-switch
sudo -u student -i hardening-quest
```

```powershell
# Windows box (elevated)
.\windows\setup_phase1.ps1 -ScoreboardUrl 'http://<scoreboard-ip>:8080' -Secret 'dcig-hardening-2026'
# Then login as student / Hardening2026!
powershell -ExecutionPolicy Bypass -File C:\HardeningLab\hardening_quest.ps1
```

When ready to race:

```bash
curl -X POST http://<scoreboard-ip>:8080/api/admin/open \
  -H 'Content-Type: application/json' \
  -d '{"admin":"dcig-admin-2026"}'
```

## Salt (range · ~30 pairs)

Files expected on the master at `/srv/salt/F26_system_hardening_lab` (symlink this repo).

1. Copy [`salt/hardening-lab.sls`](salt/hardening-lab.sls) into the master’s state tree as `hardening-lab.sls` (or include from there).
2. Pillar: see [`salt/pillar.example`](salt/pillar.example) — set `scoreboard_url` + `secret`.
3. Grains per minion: `role:hardening-linux` or `role:hardening-windows`.
4. Apply:

```bash
salt -G 'role:hardening-linux' state.apply hardening-lab
salt -G 'role:hardening-windows' state.apply hardening-lab
```

Same commands work for a single homelab pair.

## Layout

| Path | Role |
|------|------|
| [`linux/`](linux/) | Phase-1 setup, quest, Phase-2 prep, score agent |
| [`windows/`](windows/) | Same for Windows Server |
| [`scoreboard/`](scoreboard/) | Live team board (Flask + SSE) |
| [`salt/`](salt/) | State + pillar examples |
| [`ANSWER_KEY.txt`](ANSWER_KEY.txt) | Mentor-only plants + finding IDs |
| [`systemHardeningMeetingOutline.pdf`](systemHardeningMeetingOutline.pdf) | Meeting outline |

## Meeting tip

Project the scoreboard early (closed). Teach from the outline with call-and-response while students work Linux → Windows. Open Phase 2 when most machines show Ready L+W (or when you call time). Freeze at the end; debrief with CISA password guidance and NIST least privilege.

## Defaults

- Student: `student` / `Hardening2026!`
- Secret / admin: see `scoreboard/scoreboard.env.example` and `ANSWER_KEY.txt`
