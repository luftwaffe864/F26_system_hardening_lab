# Homelab setup scripts

Run these **after** each OS is installed in VMware. They configure hostname, static IP, hosts file, and base packages. They do **not** plant the hardening lab — that is still `linux/setup_phase1.sh` / `windows/setup_phase1.ps1`.

Default LAN (change flags if yours differs):

| Host | Hostname | IP |
|------|----------|-----|
| Kali | `kali-mentor` | `192.168.56.10` |
| Ubuntu | `ubuntu01` | `192.168.56.11` |
| Windows | `win19_srv01` | `192.168.56.12` |
| Gateway | | `192.168.56.1` |

## 1. Kali (scoreboard / mentor)

Copy this folder onto Kali (or clone the whole repo), then:

```bash
cd F26_system_hardening_lab/homelab
# If copied from Windows:
sed -i 's/\r$//' *.sh

# List NICs first if unsure:
ip -br link

sudo bash setup_kali.sh --iface eth0
# optional Salt master:
# sudo bash setup_kali.sh --iface eth0 --salt-master

bash start_scoreboard.sh
```

## 2. Ubuntu target

```bash
cd F26_system_hardening_lab/homelab
sed -i 's/\r$//' *.sh
ip -br link    # note ens33 / eth0 / etc.

sudo bash setup_ubuntu.sh --iface ens33
sudo reboot    # if the script says so

# optional Salt minion:
# sudo bash setup_ubuntu.sh --iface ens33 --skip-net --salt-minion --master 192.168.56.10
```

Then run Phase 1 when ready:

```bash
cd ~/F26_system_hardening_lab   # or wherever the repo is
export SCOREBOARD_URL=http://192.168.56.10:8080
export HARDENING_SECRET=dcig-hardening-2026
sudo bash linux/setup_phase1.sh --no-switch
```

## 3. Windows Server 2019

Elevated PowerShell:

```powershell
cd C:\Labs\F26_system_hardening_lab\homelab
Set-ExecutionPolicy Bypass -Scope Process -Force
Get-NetAdapter   # note InterfaceAlias

.\setup_windows.ps1 -InterfaceAlias Ethernet0
# optional lab Defender exclusions:
# .\setup_windows.ps1 -SkipRename -SkipNetwork -DefenderExclusions

# Reboot if renamed, then Phase 1:
cd ..\windows
.\setup_phase1.ps1 -ScoreboardUrl 'http://192.168.56.10:8080' -Secret 'dcig-hardening-2026'
```

## 4. Verify from Kali or Ubuntu

```bash
bash verify_connectivity.sh
```

## Script list

| Script | Runs on | Purpose |
|--------|---------|---------|
| `setup_kali.sh` | Kali | Hostname, static IP, hosts, packages, clone repo, scoreboard venv, optional Salt master |
| `setup_ubuntu.sh` | Ubuntu | Hostname, netplan IP, hosts, SSH, optional Salt minion |
| `setup_windows.ps1` | Windows | Rename, static IP, ping/RDP, hosts, optional Defender exclusions |
| `start_scoreboard.sh` | Kali | Start Flask scoreboard |
| `verify_connectivity.sh` | Linux | Ping + scoreboard check |

Full narrative guide: [../HOMELAB.md](../HOMELAB.md).
