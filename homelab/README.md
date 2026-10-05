# Homelab setup scripts (VMware only)

**Not for the cyber range** — student VMs there already have `192.168.1.10` / `.11` / `.18` and hostnames like `dcig-syslab-teamNN-*`. On the range, use Salt only ([RANGE.md](../RANGE.md)).

These scripts configure hostname + static IP on **local VMware** VMs before Phase-1.

**Same addressing as the range** (see [RANGE.md](../RANGE.md)) — pod layout **`192.168.1.0/24`**:

| Host | Hostname | IP | Role |
|------|----------|-----|------|
| Admin Kali | `kali-mentor` (homelab) | **`192.168.1.7`** | Salt master + scoreboard |
| Ubuntu | `ubuntu01` | **`192.168.1.10`** | Linux hardening target |
| Windows | `win19_srv01` | **`192.168.1.11`** | Windows hardening target |
| Gateway | | **`192.168.1.1`** | Confirm with range ops |

Script defaults use the table above. **VMware NAT** often uses a different subnet (e.g. `192.168.64.0/24`, gateway `.2`) — keep **`.10` / `.11`** for targets if you want to mimic the range, but pass `--gateway` and adjust the admin Kali IP to match your LAN. See [HOMELAB.md](../HOMELAB.md).

## 1. Admin Kali (Salt + scoreboard)

```bash
git clone https://github.com/luftwaffe864/F26_system_hardening_lab.git
cd F26_system_hardening_lab/homelab
sed -i 's/\r$//' *.sh
ip -br link

sudo bash setup_kali.sh --iface eth0
# optional: --salt-master
# VMware NAT example:
# sudo bash setup_kali.sh --iface eth0 --ip 192.168.64.7 --gateway 192.168.64.2 \
#   --ubuntu-ip 192.168.64.10 --win-ip 192.168.64.11

bash start_scoreboard.sh
```

## 2. Ubuntu target

```bash
sudo bash setup_ubuntu.sh --iface ens33
sudo reboot   # if prompted

export SCOREBOARD_URL=http://192.168.1.7:8080
export HARDENING_SECRET=dcig-hardening-2026
sudo bash ../linux/setup_phase1.sh --no-switch
```

## 3. Windows target

```powershell
.\setup_windows.ps1 -InterfaceAlias Ethernet0
# Reboot if renamed, then:
cd ..\windows
.\setup_phase1.ps1 -ScoreboardUrl 'http://192.168.1.7:8080' -Secret 'dcig-hardening-2026'
```

## 4. Verify

```bash
bash verify_connectivity.sh
```

| Script | Purpose |
|--------|---------|
| `setup_kali.sh` | Admin Kali @ `.7`, clone repo, venv, optional Salt master |
| `setup_ubuntu.sh` | `ubuntuNN` @ `.10` |
| `setup_windows.ps1` | `win19_srvNN` @ `.11` |
| `start_scoreboard.sh` | Flask board on `:8080` |
| `verify_connectivity.sh` | Ping + scoreboard probe |
