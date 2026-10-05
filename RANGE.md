# Cyber range layout — System Hardening Lab

Isolated **pod** model: every team gets **`192.168.1.0/24`**, pre-built by range ops. **You do not reconfigure IPs or subnet on student VMs** — they arrive with networking already set.

## Per team (one pod)

Replace **`NN`** with the team number (e.g. `01`, `07`, `30`).

| Role | IP | Salt minion ID (what `salt-key -L` shows) |
|------|-----|-------------------------------------------|
| Linux hardening target | **`192.168.1.10`** | `dcig-syslab-teamNN-ubuntu` |
| Windows hardening target | **`192.168.1.11`** | `win19_srvNN` |
| Jumpbox (student access) | **`192.168.1.18`** | `teamNN-jump` |

Guacamole may show a longer display name for the jumpbox; **target Salt commands by minion ID** in the table above.

- **Team NN** = digits after `team` in the minion name (`dcig-syslab-team07-ubuntu`, `team07-jump` → **07**), or trailing digits on `win19_srv07` → **07**.
- **Students:** land on the **jumpbox** (Guacamole), then **SSH** to the Linux target (`.10`) and **RDP** to Windows (`.11`). The jumpbox is for access only — lab state and scoring run on `.10` / `.11`.
- **Lockout padding:** Phase-1 installs a safety net on targets (SSH port 22 / RDP 3389 + `student` account reset every few minutes).
- **Homelab** still uses short names like `ubuntu01` / `win19_srv01`; team ID falls back to trailing digits (see [`scripts/team_id.sh`](scripts/team_id.sh)).

## Shared infrastructure (mentors / range ops)

| Role | Address | Notes |
|------|---------|--------|
| Salt master | **`172.31.31.2`** | Deploy lab from `/srv/salt/F26_system_hardening_lab` |
| Guacamole / mentor hop | **`172.31.31.3`** (guac-salt) | SSH jump to `.2` if you have no direct route to the master |
| Scoreboard | **`http://172.31.31.2:8080`** (typical) | Set `hardening_lab:scoreboard_url` in pillar; must be reachable from **`.10` / `.11`** |

Do **not** run [`homelab/setup_*.sh`](homelab/) or [`homelab/setup_windows.ps1`](homelab/setup_windows.ps1) on range student VMs — those scripts are for **VMware homelab** networking only.

## What mentors run on the range

1. Put this repo on the Salt master: `/srv/salt/F26_system_hardening_lab`
2. Pillar (see [`salt/pillar.example`](salt/pillar.example)) — at minimum:
   - `scoreboard_url` (URL student agents can reach from the pod)
   - `secret`, `student_password`
3. Grains on **hardening targets only** (`.10` / `.11` — not the jumpbox):
   - `role:hardening-linux` on `dcig-syslab-teamNN-ubuntu`
   - `role:hardening-windows` on `win19_srvNN`
4. Apply Phase-1 lab state (**pilot: one team by minion ID**):

```bash
# Example: Team 30 only
sudo salt 'dcig-syslab-team30-ubuntu' state.apply hardening-lab
sudo salt 'win19_srv30' state.apply hardening-lab
```

Fleet-wide (after grains are set on all targets):

```bash
sudo salt -G 'role:hardening-linux' state.apply hardening-lab
sudo salt -G 'role:hardening-windows' state.apply hardening-lab
```

That runs `linux/setup_phase1.sh` / `windows/setup_phase1.ps1` (plants + quest install + **auto Phase-2 hooks**). When a student finishes the quest, Phase-2 prep starts by itself — they never run `prepare_phase2` manually.

**Reset quests for mentor re-test** (clears progress, re-plants Phase 1, clears Phase-2 done flags):

```bash
sudo salt -L 'dcig-syslab-team30-ubuntu,win19_srv30' state.apply hardening-lab
# optional: wipe Team 30 scoreboard row
curl -X POST http://172.31.31.2:8080/api/admin/reset \
  -H 'Content-Type: application/json' \
  -d '{"admin":"dcig-admin-2026"}'
```

After pulling state updates on the master, re-copy the state file:

```bash
sudo cp /srv/salt/F26_system_hardening_lab/salt/hardening-lab.sls /srv/salt/hardening-lab.sls
```

Windows note: Salt `file.recurse` must **not** set Unix `file_mode`/`dir_mode` on Windows minions (error: *mode management is not supported on Windows*). Lab files land under `C:\HardeningLab\src` on Windows.

5. Start scoreboard on the mentor host (often the Salt master at `172.31.31.2`) — [`scoreboard/`](scoreboard/) or [`homelab/start_scoreboard.sh`](homelab/start_scoreboard.sh).

   On a minimal Ubuntu Salt master, install once: `sudo apt install -y python3-venv python3-pip`  
   If venv is missing, the start script falls back to `pip3 install --user flask`. Remove a broken partial venv: `rm -rf ~/.cache/dcig-hardening-scoreboard/venv`
6. Students play quests on **`.10` then `.11`**, then mentors open Phase 2:

```bash
curl -X POST "http://172.31.31.2:8080/api/admin/open" \
  -H 'Content-Type: application/json' \
  -d '{"admin":"dcig-admin-2026"}'
```

## Quick checks (optional)

From the Linux target (`.10`):

```bash
hostname -s          # often dcig-syslab-teamNN-ubuntu
ip -br addr          # 192.168.1.10 on the lab NIC
cat /etc/hardening-lab/team   # NN zero-padded
curl -sS -m 3 http://172.31.31.2:8080/api/status
```

From Windows (`.11`): `hostname` (often `win19_srvNN`), RDP from jumpbox, quest as `student` after Phase-1.

From jumpbox (`.18`): `ping -c1 192.168.1.10`, `ping -c1 192.168.1.11`.

Salt connectivity (on master):

```bash
sudo salt 'dcig-syslab-team30-ubuntu' test.ping
sudo salt 'win19_srv30' test.ping
sudo salt 'team30-jump' test.ping          # optional; no lab grain
```

## Reference: addressing

| Item | Value |
|------|--------|
| Pod subnet | `192.168.1.0/24` (isolated per team) |
| Linux target | `192.168.1.10` |
| Windows target | `192.168.1.11` |
| Jumpbox | `192.168.1.18` |
| Salt master | `172.31.31.2` |
| Scoreboard (pillar example) | `http://172.31.31.2:8080` |

## Homelab

Building VMs yourself in VMware? Use **[HOMELAB.md](HOMELAB.md)** and **[homelab/](homelab/)** to set hostname + static IP locally. Target IPs **`.10` / `.11`** match the range; hostnames can stay `ubuntu01` / `win19_srv01`.
