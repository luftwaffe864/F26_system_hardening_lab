# Cyber range layout — System Hardening Lab

Isolated **pod** model (same as [F26_enum_lab](../F26_enum_lab/README.md)): every team gets **`192.168.1.0/24`**, pre-built by range ops. **You do not reconfigure IPs or subnet on student VMs** — they arrive with networking already set.

## Per student (one pod)

| Role | Hostname pattern | IP (fixed in every pod) |
|------|------------------|-------------------------|
| Linux hardening target | `ubuntu01` … `ubuntu30` | **`192.168.1.10`** |
| Windows hardening target | `win19_srv01` … `win19_srv30` | **`192.168.1.11`** |

- **Team NN** = trailing digits on the hostname (`ubuntu07` + `win19_srv07` → Team 07). Hostnames should already match the infra request.
- Students: **Guacamole** → SSH to Ubuntu, RDP to Windows. **No** student Kali/jumpbox.

## Mentors only (shared)

| Role | Notes |
|------|--------|
| Admin Kali | Salt master; run scoreboard on TCP **8080** |
| Pillar | `scoreboard_url` must be reachable from inside pods (HTTP from `.10` / `.11`) |

Do **not** run [`homelab/setup_*.sh`](homelab/) or [`homelab/setup_windows.ps1`](homelab/setup_windows.ps1) on range student VMs — those scripts are for **VMware homelab** networking only.

## What mentors run on the range

1. Put this repo on the Salt master: `/srv/salt/F26_system_hardening_lab`
2. Pillar (see [`salt/pillar.example`](salt/pillar.example)) — at minimum:
   - `scoreboard_url` (admin Kali URL students’ agents can reach)
   - `secret`, `student_password`
3. Grains on minions: `role:hardening-linux` / `role:hardening-windows`
4. Apply Phase-1 lab state:

```bash
sudo salt -G 'role:hardening-linux' state.apply hardening-lab
sudo salt -G 'role:hardening-windows' state.apply hardening-lab
```

That runs `linux/setup_phase1.sh` / `windows/setup_phase1.ps1` (plants + quest install + **auto Phase-2 hooks**). When a student finishes the quest, Phase-2 prep starts by itself — they never run `prepare_phase2` manually.

5. Start scoreboard on admin Kali ([`scoreboard/`](scoreboard/)).
6. Students play quests, then mentors open Phase 2:

```bash
curl -X POST "http://<scoreboard-host>:8080/api/admin/open" \
  -H 'Content-Type: application/json' \
  -d '{"admin":"dcig-admin-2026"}'
```

## Quick checks (optional)

From a student Ubuntu pod:

```bash
hostname -s          # ubuntuNN
ip -br addr          # should show 192.168.1.10 on the lab NIC
curl -sS -m 3 http://<scoreboard-url>/api/status
```

From Windows: `hostname`, confirm RDP/SSH from Guacamole, run quest as `student` after Phase-1.

## Reference: addressing

| Item | Value |
|------|--------|
| Pod subnet | `192.168.1.0/24` (isolated per team) |
| Linux target | `192.168.1.10` |
| Windows target | `192.168.1.11` |
| Scoreboard (pillar default example) | `http://192.168.1.7:8080` — change if ops use another host |

## Homelab

Building VMs yourself in VMware? Use **[HOMELAB.md](HOMELAB.md)** and **[homelab/](homelab/)** to set hostname + static IP locally. The **`.10` / `.11` layout** matches the range so habits transfer; homelab is the only place you configure networking in this repo.
