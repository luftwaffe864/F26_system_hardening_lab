# Cyber range layout — System Hardening Lab

Isolated **pod** model: every team gets **`192.168.1.0/24`**, pre-built by range ops. **You do not reconfigure IPs or subnet on student VMs** — they arrive with networking already set.

## Per team (one pod)

Replace **`NN`** with the team number (e.g. `01`, `07`, `30`).

| Role | Hostname | IP |
|------|----------|-----|
| Linux hardening target | `dcig-syslab-teamNN-ubuntu` | **`192.168.1.10`** |
| Windows hardening target | `dcig-syslab-teamNN-win19` | **`192.168.1.11`** |
| Ubuntu jumpbox (student access) | `dcig-syslab-teamNN-ubuntu-jumpbox` | **`192.168.1.18`** |

- **Team NN** = digits after `team` in the hostname (`dcig-syslab-team07-ubuntu` → Team **07**). Same on all three pod VMs.
- **Students:** land on the **jumpbox** (Guacamole), then **SSH** to the Linux target (`.10`) and **RDP** to Windows (`.11`). The jumpbox is for access only — lab state and scoring run on `.10` / `.11`.
- **Lockout padding:** Phase-1 installs a safety net on targets (SSH port 22 / RDP 3389 + `student` account reset every few minutes). Students should still avoid disabling remote access on purpose.
- **Homelab** still uses short names like `ubuntu01` / `win19_srv01`; team ID falls back to trailing digits (see [`scripts/team_id.sh`](scripts/team_id.sh)).

## Shared infrastructure (mentors / range ops)

| Role | Address | Notes |
|------|---------|--------|
| Salt master | **`172.31.31.2`** | Deploy lab from `/srv/salt/F26_system_hardening_lab` |
| Scoreboard | **`http://172.31.31.2:8080`** (typical) | Set `hardening_lab:scoreboard_url` in pillar; must be reachable from **`.10` / `.11`** (and jumpbox if you put a shortcut there) |

Do **not** run [`homelab/setup_*.sh`](homelab/) or [`homelab/setup_windows.ps1`](homelab/setup_windows.ps1) on range student VMs — those scripts are for **VMware homelab** networking only.

## What mentors run on the range

1. Put this repo on the Salt master: `/srv/salt/F26_system_hardening_lab`
2. Pillar (see [`salt/pillar.example`](salt/pillar.example)) — at minimum:
   - `scoreboard_url` (URL student agents can reach from the pod)
   - `secret`, `student_password`
3. Grains on **hardening targets only** (`192.168.1.10` / `.11`):
   - `role:hardening-linux` on `dcig-syslab-teamNN-ubuntu`
   - `role:hardening-windows` on `dcig-syslab-teamNN-win19`
4. Apply Phase-1 lab state:

```bash
sudo salt -G 'role:hardening-linux' state.apply hardening-lab
sudo salt -G 'role:hardening-windows' state.apply hardening-lab
```

That runs `linux/setup_phase1.sh` / `windows/setup_phase1.ps1` (plants + quest install + **auto Phase-2 hooks**). When a student finishes the quest, Phase-2 prep starts by itself — they never run `prepare_phase2` manually.

5. Start scoreboard on the mentor host (often the Salt master at `172.31.31.2`) — [`scoreboard/`](scoreboard/) or [`homelab/start_scoreboard.sh`](homelab/start_scoreboard.sh).
6. Students play quests on **`.10` then `.11`**, then mentors open Phase 2:

```bash
curl -X POST "http://172.31.31.2:8080/api/admin/open" \
  -H 'Content-Type: application/json' \
  -d '{"admin":"dcig-admin-2026"}'
```

## Quick checks (optional)

From the Linux target (`.10`):

```bash
hostname -s          # dcig-syslab-teamNN-ubuntu
ip -br addr          # 192.168.1.10 on the lab NIC
cat /etc/hardening-lab/team   # NN zero-padded
curl -sS -m 3 http://172.31.31.2:8080/api/status
```

From Windows (`.11`): `hostname`, RDP from jumpbox, quest as `student` after Phase-1.

From jumpbox (`.18`): `ping -c1 192.168.1.10`, `ping -c1 192.168.1.11`.

## Reference: addressing

| Item | Value |
|------|--------|
| Pod subnet | `192.168.1.0/24` (isolated per team) |
| Linux target | `192.168.1.10` |
| Windows target | `192.168.1.11` |
| Ubuntu jumpbox | `192.168.1.18` |
| Salt master | `172.31.31.2` |
| Scoreboard (pillar example) | `http://172.31.31.2:8080` |

## Homelab

Building VMs yourself in VMware? Use **[HOMELAB.md](HOMELAB.md)** and **[homelab/](homelab/)** to set hostname + static IP locally. Target IPs **`.10` / `.11`** match the range; hostnames can stay `ubuntu01` / `win19_srv01`.
