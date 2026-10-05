# DCIG System Hardening Lab (Fall · Oct 8 meeting)

Guided quests on **Linux then Windows**, then a CyberPatriot-style **Phase 2** find-and-fix with a live **team** scoreboard.

Each student gets a paired box set on an **isolated `192.168.1.0/24`** (range ops pre-configure subnet and IPs):

| Role | Salt minion ID (range) | IP (in each pod) |
|------|------------------------|------------------|
| Linux target | `dcig-syslab-teamNN-ubuntu` | **`192.168.1.10`** |
| Windows target | `win19_srvNN` | **`192.168.1.11`** |
| Jumpbox | `teamNN-jump` | **`192.168.1.18`** |

**Team NN** = digits after `team` in the hostname (e.g. `team07` → Team 07). Homelab may still use `ubuntu01` / `win19_srv01` (trailing digits).

**Mentors:** Salt master **`172.31.31.2`** + scoreboard. Push lab with Salt — **do not** re-IP student VMs. Students: **jumpbox** → SSH Linux / RDP Windows. See **[RANGE.md](RANGE.md)**.

## Student flow

1. **Linux tool drill** (~10 min) → `hardening-quest` — learn commands, not a full IR story
2. Drill ends → **Phase 2 prep auto-starts on Linux**; go to matching **Windows** box
3. **Windows tool drill** (~10 min) → `hardening-quest`
4. Drill ends → **Phase 2 prep auto-starts** on Windows
5. Mentors **open Phase 2** → CyberPatriot-style race (most of the meeting time)

```text
jumpbox (.18) ──► Linux .10 ──~10m drill──► handoff + linux prepare_phase2
                              │
                              ▼
                   Windows .11 ──~10m drill──► prepare_phase2
                              │
                              ▼
                   Phase 2 find-and-fix (majority of time) ──► live scoreboard
```

## Homelab dry-run (1 Linux + 1 Windows)

**Full walkthrough (VMware, static IPs, users, Salt):** see **[HOMELAB.md](HOMELAB.md)**.

Short version — use hostnames `ubuntu01` / `win19_srv01` (or any names ending in digits).

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
export SCOREBOARD_URL=http://192.168.1.7:8080
export HARDENING_SECRET=dcig-hardening-2026
sudo bash linux/setup_phase1.sh --no-switch
sudo -u student -i hardening-quest
```

```powershell
# Windows box (elevated)
.\windows\setup_phase1.ps1 -ScoreboardUrl 'http://192.168.1.7:8080' -Secret 'dcig-hardening-2026'
# Then login as student / Hardening2026!
powershell -ExecutionPolicy Bypass -File C:\HardeningLab\hardening_quest.ps1
```

When ready to race:

```bash
curl -X POST http://<scoreboard-ip>:8080/api/admin/open \
  -H 'Content-Type: application/json' \
  -d '{"admin":"dcig-admin-2026"}'
```

## Salt (cyber range · ~30 pairs)

Networking is already on the images. Mentors only deploy lab content:

1. Repo on master: `/srv/salt/F26_system_hardening_lab`
2. Pillar: [`salt/pillar.example`](salt/pillar.example) — `scoreboard_url`, `secret`, `student_password`
3. Grains: `role:hardening-linux` / `role:hardening-windows`
4. `salt -G 'role:hardening-linux' state.apply hardening-lab` (and Windows)

Details: **[RANGE.md](RANGE.md)**. Homelab VMware setup (where you *do* set IPs): **[HOMELAB.md](HOMELAB.md)**.

## Layout

| Path | Role |
|------|------|
| [`RANGE.md`](RANGE.md) | **Cyber range** pod layout (`192.168.1.0/24`, Salt, scoreboard) |
| [`config/range.env.example`](config/range.env.example) | Env vars for range IPs / scoreboard URL |
| [`HOMELAB.md`](HOMELAB.md) | **VMware homelab** (can mimic `.10`/`.11` or use NAT overrides) |
| [`scripts/`](scripts/) | Desktop scoreboard shortcut helpers (double-click → browser) |
| [`homelab/`](homelab/) | **Setup scripts** for Kali / Ubuntu / Windows base config |
| [`linux/`](linux/) | Phase-1 setup, quest, Phase-2 prep, score agent |
| [`windows/`](windows/) | Same for Windows Server |
| [`scoreboard/`](scoreboard/) | Live team board (Flask + SSE) |
| [`salt/`](salt/) | State + pillar examples |
| [`ANSWER_KEY.txt`](ANSWER_KEY.txt) | Mentor-only plants + finding IDs (local; not on public GitHub) |
| [`systemHardeningMeetingOutline.pdf`](systemHardeningMeetingOutline.pdf) | Meeting outline |

## Meeting tip

Project the scoreboard early (closed). Teach from the outline with call-and-response while students work Linux → Windows. Open Phase 2 when most machines show Ready L+W (or when you call time). Freeze at the end; debrief with CISA password guidance and NIST least privilege.

## Defaults

- Student: `student` / `Hardening2026!`
- Secret / admin: see `scoreboard/scoreboard.env.example` and `ANSWER_KEY.txt`
