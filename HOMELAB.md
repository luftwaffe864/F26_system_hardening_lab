# Homelab Setup Guide — DCIG System Hardening

End-to-end guide for a **VMware homelab** only. On the **cyber range**, networking is pre-built — use **[RANGE.md](RANGE.md)** (Salt + scoreboard; skip IP setup here).

**Network model:** all three VMs use a single **NAT** NIC (usually VMnet8). That gives them:
- internet access (`apt`, Windows Update, `git clone` from GitHub)
- a private LAN between the VMs for the scoreboard and Salt

| VM | Role | Example hostname | Example IP |
|----|------|------------------|------------|
| Kali Linux | Scoreboard host + optional Salt master | `kali-mentor` | `192.168.1.7` |
| Ubuntu Server 22.04/24.04 | Linux hardening target | `ubuntu01` | `192.168.1.10` |
| Windows Server 2019 (Desktop Experience) | Windows hardening target | `win19_srv01` | `192.168.1.11` |
| VMware NAT gateway | Internet for the VMs | — | `192.168.1.1` |

Production pods use **[RANGE.md](RANGE.md)** (`192.168.1.10` / `.11` / `.18`, hostnames `dcig-syslab-teamNN-*`, Salt master `172.31.31.3`). Homelab VMware NAT may use a **different subnet** — keep the same **last octets** (`.7` mentor Kali, `.10` Linux, `.11` Windows) when possible, or override `--gateway` in section [2](#2-vmware-networking).

**Team ID:** on the range, digits after `team` in the hostname; in homelab, trailing digits (`ubuntu01` + `win19_srv01` → **Team 01**). See [`scripts/team_id.sh`](scripts/team_id.sh).

---

## Table of contents

0. [Quick start with setup scripts](#0-quick-start-with-setup-scripts)
1. [What you need](#1-what-you-need)
2. [VMware networking](#2-vmware-networking)
3. [Create the three VMs](#3-create-the-three-vms)
4. [Kali mentor box (detail)](#4-kali-mentor-box-detail)
5. [Ubuntu target (detail)](#5-ubuntu-target-detail)
6. [Windows Server 2019 target (detail)](#6-windows-server-2019-target-detail)
7. [Verify connectivity](#7-verify-connectivity)
8. [Get the lab files onto each machine](#8-get-the-lab-files-onto-each-machine)
9. [Run the scoreboard](#9-run-the-scoreboard)
10. [First dry-run without Salt](#10-first-dry-run-without-salt)
11. [Optional: Salt master on Kali](#11-optional-salt-master-on-kali)
12. [Snapshots and reset workflow](#12-snapshots-and-reset-workflow)
13. [Troubleshooting](#13-troubleshooting)
14. [Checklist](#14-checklist)

---

## 0. Quick start with setup scripts

### 0.1 Discover your NAT subnet (do this once)

1. VMware Workstation: **Edit → Virtual Network Editor** (run as Administrator if needed).
2. Select **VMnet8** (NAT).
3. Note:
   - **Subnet IP** (e.g. `192.168.1.0`)
   - **Subnet mask** (usually `255.255.255.0` → `/24`)
4. **Gateway:** on the **cyber range** use **`192.168.1.1`**. On **VMware NAT**, the gateway is often **`.2`** on whatever subnet VMnet8 uses (e.g. `192.168.64.2`) — not `.1`.
5. Pick static IPs outside DHCP. Range layout: admin Kali **`.7`**, Ubuntu **`.10`**, Windows **`.11`**.

If VMnet8 is not `192.168.1.0/24`, pass your gateway to the scripts, e.g. `--gateway 192.168.64.2 --ip 192.168.64.10`.

### 0.2 Run the scripts

After each OS is installed with its NIC set to **NAT**, use [`homelab/`](homelab/). See [`homelab/README.md`](homelab/README.md).

```bash
# --- Kali (NAT + internet: clone works before or after static IP) ---
git clone https://github.com/luftwaffe864/F26_system_hardening_lab.git
cd F26_system_hardening_lab/homelab
sed -i 's/\r$//' *.sh
ip -br link

sudo bash setup_kali.sh \
  --iface eth0 \
  --ip 192.168.1.7 \
  --gateway 192.168.1.1 \
  --ubuntu-ip 192.168.1.10 \
  --win-ip 192.168.1.11

# Confirm internet still works, then start the board:
ping -c 2 1.1.1.1
bash start_scoreboard.sh

# --- Ubuntu ---
sudo bash setup_ubuntu.sh \
  --iface ens33 \
  --ip 192.168.1.10 \
  --gateway 192.168.1.1 \
  --kali-ip 192.168.1.7 \
  --win-ip 192.168.1.11
sudo reboot   # if prompted

# --- Windows (elevated PowerShell) ---
.\setup_windows.ps1 `
  -InterfaceAlias Ethernet0 `
  -IPAddress 192.168.1.11 `
  -Gateway 192.168.1.1 `
  -KaliIp 192.168.1.7 `
  -UbuntuIp 192.168.1.10
```

Script defaults match **[RANGE.md](RANGE.md)** (`192.168.1.0/24`, gateway `.1`).  
These scripts only prepare the VMs (hostname, IP, packages). Lab planting is still `linux/setup_phase1.sh` and `windows/setup_phase1.ps1`.

---

## 1. What you need

### Software
- VMware Workstation / Player / Fusion (or ESXi — same ideas)
- ISO or official images:
  - [Kali Linux](https://www.kali.org/get-kali/)
  - Ubuntu Server 22.04 LTS or 24.04 LTS
  - Windows Server 2019 **with Desktop Experience** (GUI required for the Windows quest)
- Git + a browser on Kali
- This repo: https://github.com/luftwaffe864/F26_system_hardening_lab  
  (Public clone has **no** `ANSWER_KEY.txt`. Keep the answer key only on Kali if you copy it from your private folder.)

### Suggested VM sizing

| VM | vCPU | RAM | Disk |
|----|------|-----|------|
| Kali | 2 | 4 GB | 40 GB |
| Ubuntu Server | 2 | 2–4 GB | 25 GB |
| Win Server 2019 | 2 | 4–8 GB | 60 GB |

### Accounts you will end up with

| Where | Account | Password (lab default) | Purpose |
|-------|---------|------------------------|---------|
| Kali | your normal user + `sudo` | (yours) | Mentor / Salt / scoreboard |
| Ubuntu / Windows | `student` | `Hardening2026!` | Created by Phase-1 setup; used to play the quests |
| Ubuntu / Windows | your admin user | (yours) | Install packages, Salt, run setup as root/Admin |

Do **not** pre-create `student` unless you have to; Phase-1 scripts create and configure it.

---

## 2. VMware networking

Goal: all three VMs share **one NAT network** so they can:
1. reach the **internet** (clone this repo, `apt update`, Windows Update)
2. reach **each other** (scoreboard on Kali, optional Salt)

### Recommended: NAT only (one NIC each)

1. In VMware: **Edit → Virtual Network Editor** → select **VMnet8 (NAT)**.
2. Write down your subnet, for example:

   | Setting | Cyber range | VMware NAT (common) |
   |---------|-------------|---------------------|
   | Subnet | `192.168.1.0/24` | e.g. `192.168.64.0/24` |
   | VM default gateway | **`192.168.1.1`** | often **`.2`** on that subnet (e.g. `192.168.64.2`) |
   | Static IPs (same last octets everywhere) | Kali **`.7`**, Ubuntu **`.10`**, Win **`.11`** | same octets if you mimic range |

3. On **each** VM: Settings → Network Adapter → **NAT** (same VMnet8 for all three). Use **one** NIC.

4. Assign static IPs outside DHCP (range layout):

   | VM | Hostname | Static IP | Gateway (range) | DNS |
   |----|----------|-----------|-----------------|-----|
   | Kali | `kali-mentor` | `192.168.1.7` | `192.168.1.1` | `1.1.1.1` / `8.8.8.8` |
   | Ubuntu | `ubuntu01` | `192.168.1.10` | `192.168.1.1` | `1.1.1.1` / `8.8.8.8` |
   | Windows | `win19_srv01` | `192.168.1.11` | `192.168.1.1` | `1.1.1.1` / `8.8.8.8` |

On **VMware NAT**, if your subnet is not `192.168.1.0/24`, use gateway **`.2`** for that subnet and pass `--gateway` to the homelab scripts (see section 0.1).

### Install-time tip (easiest clone)

During OS install, leave the NIC on **NAT + DHCP**. You will get internet immediately so you can `git clone` / browse. After install, run the setup scripts to switch to a **static** IP with the correct gateway for your subnet.

### Optional: Host-Only instead

Only if you want a fully offline lab LAN: use VMnet1 Host-Only, gateway usually `.1`, and no internet unless you add a second NAT NIC. This guide assumes **NAT**.

### Firewall note

On Windows, allow ICMPv4 Echo for testing. Inbound TCP **8080** is only needed on Kali (scoreboard). Targets make outbound HTTP to Kali:8080; they do not need 8080 open inbound.

---

## 3. Create the three VMs

Create three separate VMs from ISO. During install:

1. **Kali** — default install is fine; enable SSH if you want to scp from another machine.
2. **Ubuntu Server** — enable OpenSSH server when the installer asks.
3. **Windows Server 2019** — choose **Desktop Experience**, set a strong local Administrator password, complete OOBE.

After install, take a snapshot named **`00-fresh-install`** on each VM before changing hostnames/IPs (optional but useful).

---

## 4. Kali mentor box (detail)

Log in as your normal Kali user (the one with sudo).

### 4.1 Hostname

```bash
sudo hostnamectl set-hostname kali-mentor
echo "127.0.1.1   kali-mentor" | sudo tee -a /etc/hosts
```

Log out/in or reboot so the shell prompt updates.

### 4.2 Static IP on NAT (NetworkManager — typical on Kali)

Prefer the script: `sudo bash homelab/setup_kali.sh --iface eth0 --ip … --gateway …`

Manual path — find the NAT interface:

```bash
ip -br link
ip route
# often eth0 / eth1 / ens33 — the NAT NIC (after DHCP you may already have internet)
```

Set a static address with `nmcli` (replace `eth0` / connection name; **gateway = range `.1` or VMware NAT `.2`**):

```bash
IFACE=eth0
sudo nmcli con show
# Note the connection NAME for that device, e.g. "Wired connection 1"

sudo nmcli con mod "Wired connection 1" \
  ipv4.addresses 192.168.1.7/24 \
  ipv4.gateway 192.168.1.1 \
  ipv4.dns "1.1.1.1 8.8.8.8" \
  ipv4.method manual

sudo nmcli con up "Wired connection 1"
ip -br addr
ping -c 2 1.1.1.1          # internet should still work
ping -c 2 github.com       # DNS should resolve
```

You only need **one** NIC (NAT). Do not add a second adapter for this guide.

**Optional `/etc/hosts` convenience on Kali:**

```bash
sudo tee -a /etc/hosts <<'EOF'
192.168.1.7  kali-mentor
192.168.1.10  ubuntu01
192.168.1.11  win19_srv01
EOF
```

### 4.3 Base packages

```bash
sudo apt update
sudo apt install -y git curl python3 python3-venv python3-pip openssh-client
```

### 4.4 Clone the lab

```bash
cd ~
git clone https://github.com/luftwaffe864/F26_system_hardening_lab.git
cd ~/F26_system_hardening_lab
```

If you have a private `ANSWER_KEY.txt`, copy it here (do not commit/push it).

### 4.5 Mentor users

No special lab user is required on Kali. Use your sudo account. Optionally create a dedicated mentor account:

```bash
sudo adduser mentor
sudo usermod -aG sudo mentor
```

---

## 5. Ubuntu target (detail)

Log in as the admin user you created during install (not `student` yet).

### 5.1 Hostname (required for Team ID)

```bash
sudo hostnamectl set-hostname ubuntu01
```

Edit `/etc/hosts` so the old name is gone:

```bash
# Ensure a line like:
# 127.0.1.1   ubuntu01
sudo nano /etc/hosts
```

Reboot:

```bash
sudo reboot
```

Confirm:

```bash
hostname -s    # must print: ubuntu01
```

### 5.2 Static IP on NAT with netplan

Prefer the script: `sudo bash homelab/setup_ubuntu.sh --iface ens33 --ip … --gateway …`

List interfaces:

```bash
ip -br link
ls /etc/netplan/
```

Edit the netplan YAML (name varies, e.g. `00-installer-config.yaml` or `50-cloud-init.yaml`):

```bash
sudo nano /etc/netplan/00-installer-config.yaml
```

Example (replace `ens33` with your NIC name):

```yaml
network:
  version: 2
  ethernets:
    ens33:
      dhcp4: false
      addresses:
        - 192.168.1.10/24
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
```

Apply:

```bash
sudo netplan apply
ip -br addr
ping -c 2 192.168.1.7    # Kali
ping -c 2 1.1.1.1          # internet via NAT gateway
```

If cloud-init keeps rewriting netplan, either disable cloud-init network config or put your file in a higher-priority netplan name and reboot once.

### 5.3 SSH and sudo

Confirm your admin user can sudo without drama:

```bash
sudo -v
sudo apt update
sudo apt install -y openssh-server curl
```

Optional: allow password SSH for lab convenience (`/etc/ssh/sshd_config` → `PasswordAuthentication yes`, then `sudo systemctl restart ssh`).

### 5.4 Do not create `student` yet

Phase-1 `setup_phase1.sh` creates:

- user `student` / `Hardening2026!`
- passwordless sudo for the quest checks

---

## 6. Windows Server 2019 target (detail)

Sign in as **Administrator** (or an admin you created).

### 6.1 Hostname (required for Team ID)

PowerShell (elevated):

```powershell
Rename-Computer -NewName 'win19_srv01' -Restart
```

After reboot:

```powershell
hostname   # win19_srv01
```

### 6.2 Static IP on NAT

**GUI:** Settings → Network → Ethernet → Edit IP → Manual:

- IP: `192.168.1.11`
- Prefix: `24`
- Gateway: `192.168.1.1`
- DNS: `1.1.1.1` / `8.8.8.8`

**PowerShell** (replace `Ethernet0` with your adapter name from `Get-NetAdapter`):

```powershell
Get-NetAdapter
New-NetIPAddress -InterfaceAlias 'Ethernet0' -IPAddress 192.168.1.11 -PrefixLength 24 -DefaultGateway 192.168.1.1
Set-DnsClientServerAddress -InterfaceAlias 'Ethernet0' -ServerAddresses 1.1.1.1,8.8.8.8
```

If an old DHCP address exists, remove it first:

```powershell
Get-NetIPAddress -InterfaceAlias 'Ethernet0' -AddressFamily IPv4
Remove-NetIPAddress -InterfaceAlias 'Ethernet0' -AddressFamily IPv4 -Confirm:$false
# then New-NetIPAddress as above
```

Allow ping (optional, for testing):

```powershell
New-NetFirewallRule -DisplayName 'ICMPv4-In' -Protocol ICMPv4 -IcmpType 8 -Direction Inbound -Action Allow
```

Enable RDP if you want console from the host (optional):

```powershell
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
```

### 6.3 Users before Phase 1

Keep **Administrator** (or your admin). Phase-1 will create **`student` / `Hardening2026!`** and add them to **Administrators** so UAC prompts work for prep scripts.

### 6.4 PowerShell execution policy (lab)

Elevated PowerShell:

```powershell
Set-ExecutionPolicy RemoteSigned -Force
```

### 6.5 Defender note (homelab)

Phase-1 plants a harmless fake “updater” process. Real Defender may quarantine it. For dry-runs you can add exclusions **after** you understand the risk of doing so on a disposable lab VM:

```powershell
Add-MpPreference -ExclusionPath 'C:\HardeningLab','C:\ProgramData\SysHealth','C:\ProgramData\NetHelper'
```

On the real range, follow mentor policy — do not assume exclusions are allowed.

### 6.6 Optional: hosts file

```powershell
Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value @"
192.168.1.7 kali-mentor
192.168.1.10 ubuntu01
192.168.1.11 win19_srv01
"@
```

---

## 7. Verify connectivity

From **Kali**:

```bash
ping -c 2 192.168.1.10
ping -c 2 192.168.1.11
```

From **Ubuntu**:

```bash
ping -c 2 192.168.1.7
ping -c 2 192.168.1.11
```

From **Windows** (PowerShell):

```powershell
Test-Connection 192.168.1.7 -Count 2
Test-Connection 192.168.1.10 -Count 2
```

Fix NICs / VMware network assignment until all three pass before continuing.

Take snapshot **`01-base-networked`** on each VM.

---

## 8. Get the lab files onto each machine

### Kali (already cloned)

```bash
cd ~/F26_system_hardening_lab
git pull   # when you update the repo
```

### Ubuntu — copy from Kali

```bash
# On Kali:
scp -r ~/F26_system_hardening_lab YOUR_ADMIN@192.168.1.10:~/
```

Or on Ubuntu:

```bash
sudo apt install -y git
git clone https://github.com/luftwaffe864/F26_system_hardening_lab.git ~/F26_system_hardening_lab
```

### Windows — pick one

- **Git for Windows** + `git clone` into `C:\Labs\F26_system_hardening_lab`
- **WinSCP / scp** from Kali into `C:\Labs\...`
- VMware **Shared Folder** + copy

You need at least the `windows\` folder on the Windows box for Phase-1 setup.

---

## 9. Run the scoreboard

On **Kali**:

```bash
cd ~/F26_system_hardening_lab/scoreboard
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

export HARDENING_SECRET=dcig-hardening-2026
export HARDENING_ADMIN=dcig-admin-2026
export HARDENING_HOST=0.0.0.0
export HARDENING_PORT=8080

python server.py
```

Leave this terminal open. Open a browser to:

`http://192.168.1.7:8080/`

You should see **Phase 2: closed** and **0 teams**.

### Optional: systemd service (Kali)

```bash
sudo tee /etc/systemd/system/hardening-scoreboard.service <<EOF
[Unit]
Description=DCIG Hardening Scoreboard
After=network.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=/home/$(whoami)/F26_system_hardening_lab/scoreboard
Environment=HARDENING_SECRET=dcig-hardening-2026
Environment=HARDENING_ADMIN=dcig-admin-2026
Environment=HARDENING_HOST=0.0.0.0
Environment=HARDENING_PORT=8080
ExecStart=/home/$(whoami)/F26_system_hardening_lab/scoreboard/.venv/bin/python server.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# create venv first if you have not
cd ~/F26_system_hardening_lab/scoreboard
python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt

sudo systemctl daemon-reload
sudo systemctl enable --now hardening-scoreboard.service
sudo systemctl status hardening-scoreboard.service
```

Admin controls (from Kali):

```bash
# Open Phase 2 scoring
curl -X POST http://127.0.0.1:8080/api/admin/open \
  -H 'Content-Type: application/json' \
  -d '{"admin":"dcig-admin-2026"}'

# Freeze board
curl -X POST http://127.0.0.1:8080/api/admin/freeze \
  -H 'Content-Type: application/json' \
  -d '{"admin":"dcig-admin-2026"}'

# Reset all scores
curl -X POST http://127.0.0.1:8080/api/admin/reset \
  -H 'Content-Type: application/json' \
  -d '{"admin":"dcig-admin-2026"}'
```

---

## 10. First dry-run without Salt

Do this once before introducing Salt.

### 10.1 Ubuntu Phase 1

```bash
cd ~/F26_system_hardening_lab

# Fix Windows CRLF if scripts were copied oddly:
sed -i 's/\r$//' linux/*.sh

export SCOREBOARD_URL=http://192.168.1.7:8080
export HARDENING_SECRET=dcig-hardening-2026

sudo bash linux/setup_phase1.sh --no-switch
```

Play the quest:

```bash
sudo -u student -i
# password if asked: Hardening2026!
hardening-quest
```

Commands inside the quest: `help`, `task`, `hint`, `answer <value>`, `progress`, `quit`.

At the end, the quest tells you to go to `win19_srv01` and starts Linux Phase 2 prep in the background.

Optional checks:

```bash
tail -f /var/log/hardening-phase2-prep.log
cat /home/student/PHASE2.txt
cat /etc/hardening-lab/team   # should be 01
```

### 10.2 Windows Phase 1

Elevated PowerShell on Windows:

```powershell
cd C:\Labs\F26_system_hardening_lab   # or wherever you put it
.\windows\setup_phase1.ps1 `
  -ScoreboardUrl 'http://192.168.1.7:8080' `
  -Secret 'dcig-hardening-2026'
```

Sign out of Administrator. Sign in as:

- Username: `student` (local account: `.\student`)
- Password: `Hardening2026!`

Run the quest:

```powershell
powershell -ExecutionPolicy Bypass -File C:\HardeningLab\hardening_quest.ps1
```

At the end, accept UAC if prompted so Phase 2 prep can finish. Read `C:\HardeningLab\PHASE2.txt`.

### 10.3 Open Phase 2 and score

On the scoreboard UI, Team **01** should show ready flags when prep pings succeed.

From Kali:

```bash
curl -X POST http://192.168.1.7:8080/api/admin/open \
  -H 'Content-Type: application/json' \
  -d '{"admin":"dcig-admin-2026"}'
```

Harden both boxes (use your private `ANSWER_KEY.txt` for the finding list). Linux agent ~20s; Windows agent ~1 min. Points should appear under **Team 01**.

---

## 11. Optional: Salt master on Kali

Use this to practice the same push model as the club range. Complete section 10 once first.

### 11.1 Install Salt master (Kali)

```bash
sudo apt update
sudo apt install -y salt-master
```

Minimal master config — ensure file roots include `/srv/salt`:

```bash
sudo mkdir -p /srv/salt /srv/pillar
grep -n file_roots /etc/salt/master || true
```

If needed, set in `/etc/salt/master` (uncomment/edit):

```yaml
file_roots:
  base:
    - /srv/salt

pillar_roots:
  base:
    - /srv/pillar
```

Link the lab and install the state:

```bash
sudo ln -sfn /home/YOURUSER/F26_system_hardening_lab /srv/salt/F26_system_hardening_lab
sudo cp /srv/salt/F26_system_hardening_lab/salt/hardening-lab.sls /srv/salt/hardening-lab.sls
```

Replace `YOURUSER` with your Kali username.

Pillar:

```bash
sudo tee /srv/pillar/hardening.sls <<'EOF'
hardening_lab:
  files_root: /srv/salt/F26_system_hardening_lab
  scoreboard_url: http://192.168.1.7:8080
  secret: dcig-hardening-2026
  student_password: Hardening2026!
EOF

sudo tee /srv/pillar/top.sls <<'EOF'
base:
  '*':
    - hardening
EOF
```

Optional top for states (`/srv/salt/top.sls`) — or apply by name:

```bash
# You can apply explicitly without top:
#   salt -G 'role:hardening-linux' state.apply hardening-lab
```

Start master:

```bash
sudo systemctl enable --now salt-master
sudo systemctl status salt-master
```

### 11.2 Ubuntu minion

```bash
sudo apt update
sudo apt install -y salt-minion
```

Edit `/etc/salt/minion` (or drop a file in `/etc/salt/minion.d/master.conf`):

```yaml
master: 192.168.1.7
id: ubuntu01
```

```bash
sudo systemctl enable --now salt-minion
sudo systemctl restart salt-minion
```

### 11.3 Windows minion

1. Download the **Salt Minion** Windows installer matching your Salt major version when possible: https://docs.saltproject.io/salt/install-guide/en/latest/
2. During setup, set **Master** = `192.168.1.7`, **Minion ID** = `win19_srv01`.
3. Start the **Salt Minion** service (Services.msc or PowerShell):

```powershell
Get-Service salt-minion
Start-Service salt-minion
Set-Service salt-minion -StartupType Automatic
```

Config file is usually `C:\ProgramData\Salt Project\Salt\conf\minion`.

### 11.4 Accept keys and set roles (Kali)

```bash
sudo salt-key -L
sudo salt-key -A          # accept ubuntu01 and win19_srv01
sudo salt '*' test.ping

sudo salt 'ubuntu01' grains.setval role hardening-linux
sudo salt 'win19_srv01' grains.setval role hardening-windows

sudo salt 'ubuntu01' grains.get role
sudo salt 'win19_srv01' grains.get role
```

### 11.5 Push Phase 1 via Salt

Scoreboard should already be running on Kali.

```bash
sudo salt -G 'role:hardening-linux' state.apply hardening-lab
sudo salt -G 'role:hardening-windows' state.apply hardening-lab
```

Then log in as `student` on each target and run the quests interactively (Salt only provisions; it does not play the quest for you).

### 11.6 Re-provision after a snapshot revert

```bash
sudo salt -G 'role:hardening-linux' state.apply hardening-lab
sudo salt -G 'role:hardening-windows' state.apply hardening-lab
```

---

## 12. Snapshots and reset workflow

Suggested snapshot chain **per target VM**:

| Snapshot | When |
|----------|------|
| `00-fresh-install` | Right after OS install |
| `01-base-networked` | Hostname + static IP + ping OK (+ Salt joined if you use it) |
| `02-pre-lab` | Lab files present; no Phase-1 run yet |

**Between full practice runs:** revert Ubuntu + Windows to `02-pre-lab` (or `01` and re-copy files). Reset the scoreboard (`/api/admin/reset`). Re-run setup or `state.apply`. Keep Kali unless you broke the scoreboard venv.

Phase-2 prep is triggered by finishing the quests; you normally do **not** run `prepare_phase2` by hand unless testing that script alone.

---

## 13. Troubleshooting

| Problem | What to check |
|---------|----------------|
| Team shows as `00` | Hostname missing `teamNN` (range) or trailing digits (homelab) |
| Cannot ping between VMs | All three on **NAT** (same VMnet8); correct IPs/mask; Windows ICMP rule |
| No internet / cannot `git clone` | Gateway must be NAT **`.2`** (not `.1`); DNS `1.1.1.1`; NIC type = NAT in VM settings |
| Scoreboard page won’t load from Ubuntu | `curl -v http://192.168.1.7:8080/api/status` from Ubuntu; Kali firewall; `HARDENING_HOST=0.0.0.0` |
| Scores never appear | Phase 2 still closed; `HARDENING_SECRET` mismatch; agents not running (`systemctl list-timers` / `schtasks`) |
| Linux script errors / `$'\r'` | `sed -i 's/\r$//' linux/*.sh` |
| Windows quest can’t prep Phase 2 | Run prep elevated; UAC denied; `C:\HardeningLab\prepare_phase2.ps1` missing |
| Defender kills health_update | Homelab exclusions (section 6.5) or note for range policy |
| Salt `test.ping` fails | `salt-key`, master IP in minion config, firewall TCP 4505–4506 on Kali |
| Salt state can’t find files | Symlink `/srv/salt/F26_system_hardening_lab` and `hardening-lab.sls` path |

Kali Salt ports (if a host firewall is on):

```bash
sudo # allow 4505, 4506/tcp from 192.168.1.0/24 if needed
```

---

## 14. Checklist

**Build**
- [ ] All three VMs on **NAT** (VMnet8); subnet noted from Virtual Network Editor
- [ ] Kali `192.168.1.7`, Ubuntu `ubuntu01` / `.10`, Windows `win19_srv01` / `.11` (gateway `.1` on range, or NAT `.2` on homelab)
- [ ] `ping 1.1.1.1` works on Kali and Ubuntu (internet)
- [ ] All three ping each other
- [ ] Snapshot `01-base-networked`

**Manual dry-run**
- [ ] Scoreboard up on Kali
- [ ] Linux Phase-1 + quest + handoff
- [ ] Windows Phase-1 + quest + prep wait
- [ ] Team 01 ready on board
- [ ] `/api/admin/open` → points move when you fix findings

**Optional Salt**
- [ ] `salt '*' test.ping` OK
- [ ] grains `hardening-linux` / `hardening-windows`
- [ ] `state.apply hardening-lab` provisions both
- [ ] Quests still work as `student`

**Defaults (change for anything beyond a private homelab)**
- Scoreboard secret: `dcig-hardening-2026`
- Admin token: `dcig-admin-2026`
- Student: `student` / `Hardening2026!`

---

## Related files in this repo

| File | Purpose |
|------|---------|
| [README.md](README.md) | Lab overview and short commands |
| [linux/](linux/) | Ubuntu Phase-1 / quest / Phase-2 / agent |
| [windows/](windows/) | Windows Phase-1 / quest / Phase-2 / agent |
| [scoreboard/](scoreboard/) | Live team board |
| [salt/](salt/) | State + pillar examples |
| `ANSWER_KEY.txt` (local only) | Mentor finding list — not on public GitHub |

When the homelab dry-run is solid, the same scripts and Salt state are what you push from the club Salt master to ~30 pairs (`ubuntuNN` / `win19_srvNN`).
