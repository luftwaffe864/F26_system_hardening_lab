<#
================================================================================
 Homelab ONLY — cyber range Windows boxes already have 192.168.1.11.
 Windows Server 2019 target base setup. Run elevated AFTER a fresh install:

   Set-ExecutionPolicy Bypass -Scope Process -Force
   .\setup_windows.ps1
   .\setup_windows.ps1 -IPAddress 192.168.1.11 -InterfaceAlias Ethernet0
   .\setup_windows.ps1 -SkipNetwork
   .\setup_windows.ps1 -DefenderExclusions
   .\setup_windows.ps1 -InstallSaltMinion -SaltMaster 192.168.1.7

 Does NOT create the lab "student" account — setup_phase1.ps1 does that.
 A reboot is required after rename; re-run with -SkipRename if needed.
================================================================================
#>
[CmdletBinding()]
param(
    [string]$Hostname       = 'win19_srv01',
    [string]$IPAddress      = '192.168.1.11',
    [int]$PrefixLength      = 24,
    [string]$Gateway        = '192.168.1.1',
    [string[]]$DnsServers   = @('1.1.1.1', '8.8.8.8'),
    [string]$InterfaceAlias = '',
    [string]$KaliIp         = '192.168.1.7',
    [string]$UbuntuIp       = '192.168.1.10',
    [switch]$SkipNetwork,
    [switch]$SkipRename,
    [switch]$DefenderExclusions,
    [switch]$InstallSaltMinion,
    [string]$SaltMaster     = '192.168.1.7',
    [string]$SaltMinionId   = ''
)

$ErrorActionPreference = 'Stop'

function Say($m)  { Write-Host "[setup-windows] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[setup-windows] $m" -ForegroundColor Yellow }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Run this script from elevated PowerShell.' -ForegroundColor Red
    exit 1
}

if ($Hostname -notmatch '(?i)team\d+' -and $Hostname -notmatch '\d+$') {
    Warn "Hostname '$Hostname' has no teamNN or trailing digits — Team ID will be 00"
}

# --- rename ------------------------------------------------------------------
$needReboot = $false
if (-not $SkipRename) {
    if ($env:COMPUTERNAME -ne $Hostname) {
        Say "Renaming computer $($env:COMPUTERNAME) -> $Hostname (reboot required after script)"
        Rename-Computer -NewName $Hostname -Force
        $needReboot = $true
    } else {
        Say "Hostname already $Hostname"
    }
}

# --- network -----------------------------------------------------------------
if (-not $SkipNetwork) {
    if (-not $InterfaceAlias) {
        $nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } |
            Select-Object -First 1
        if (-not $nic) {
            $nic = Get-NetAdapter | Where-Object { $_.InterfaceDescription -notmatch 'Loopback' } | Select-Object -First 1
        }
        if (-not $nic) { throw 'No network adapter found. Pass -InterfaceAlias Ethernet0' }
        $InterfaceAlias = $nic.Name
    }
    Say "Configuring $InterfaceAlias -> $IPAddress/$PrefixLength gw $Gateway"

    # Remove existing IPv4 addresses on this NIC (lab box — expected)
    Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        ForEach-Object {
            Remove-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $_.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
        }
    Get-NetRoute -InterfaceAlias $InterfaceAlias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $IPAddress `
        -PrefixLength $PrefixLength -DefaultGateway $Gateway | Out-Null
    Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $DnsServers
    Say "IP configured"
} else {
    Say 'Skipping network (-SkipNetwork)'
}

# --- firewall / RDP helpers --------------------------------------------------
Say 'Allowing ICMPv4 echo (ping)'
New-NetFirewallRule -DisplayName 'Lab ICMPv4-In' -Protocol ICMPv4 -IcmpType 8 `
    -Direction Inbound -Action Allow -ErrorAction SilentlyContinue | Out-Null

Say 'Enabling PowerShell remoting / RemoteSigned for lab scripts'
try { Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null } catch { Warn $_.Exception.Message }
Set-ExecutionPolicy RemoteSigned -Force -ErrorAction SilentlyContinue

# Optional RDP
try {
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
    Say 'RDP enabled'
} catch { Warn "RDP enable skipped: $($_.Exception.Message)" }

# --- hosts -------------------------------------------------------------------
$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$entries = @(
    "$KaliIp`tkali-mentor",
    "$UbuntuIp`tubuntu01",
    "$IPAddress`twin19_srv01"
)
$raw = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue
if (-not $raw) { $raw = '' }
foreach ($e in $entries) {
    $name = ($e -split '\s+')[1]
    if ($raw -match "(?m)^[0-9.]+\s+$([regex]::Escape($name))\b") {
        $raw = [regex]::Replace($raw, "(?m)^[0-9.]+\s+$([regex]::Escape($name)).*$", $e)
    } else {
        if ($raw -and -not $raw.EndsWith("`n")) { $raw += "`r`n" }
        $raw += "$e`r`n"
    }
}
Set-Content -Path $hostsPath -Value $raw -Encoding ASCII
Say 'Updated hosts file'

# --- Defender exclusions (optional, disposable lab only) ---------------------
if ($DefenderExclusions) {
    Say 'Adding Defender path exclusions (homelab only)'
    try {
        Add-MpPreference -ExclusionPath @(
            'C:\HardeningLab',
            'C:\ProgramData\SysHealth',
            'C:\ProgramData\NetHelper',
            'C:\Labs'
        ) -ErrorAction Stop
    } catch { Warn "Defender exclusions failed: $($_.Exception.Message)" }
}

# --- Salt minion note --------------------------------------------------------
if ($InstallSaltMinion) {
    if (-not $SaltMinionId) { $SaltMinionId = $Hostname }
    Warn @"
Salt Minion for Windows is installed via the official MSI (not this script).

  1) Download Salt Minion for Windows from Salt's install guide
  2) Master = $SaltMaster
  3) Minion ID = $SaltMinionId
  4) Start the salt-minion service
  5) On Kali: salt-key -A
               salt '$SaltMinionId' grains.setval role hardening-windows
"@
}

Say @"

DONE
  Hostname : $Hostname  (current: $env:COMPUTERNAME)
  IP       : $IPAddress/$PrefixLength
  Student  : NOT created yet (run windows\setup_phase1.ps1 for that)
"@

# Scoreboard Desktop shortcut (Public Desktop) → browser
$repoRoot = Split-Path -Parent $PSScriptRoot
$sc = Join-Path $repoRoot 'scripts\Make-ScoreboardShortcut.ps1'
$sbUrl = "http://$($KaliIp):8080/"
if (Test-Path $sc) {
    & $sc -Url $sbUrl
    Say "scoreboard Desktop shortcut -> $sbUrl"
} else {
    Warn "Make-ScoreboardShortcut.ps1 not found; Phase-1 setup will still add shortcuts."
}

Say @"

Next:
  1) Reboot if the hostname changed
  2) Copy F26_system_hardening_lab to e.g. C:\Labs\F26_system_hardening_lab
  3) Elevated:
       .\windows\setup_phase1.ps1 -ScoreboardUrl 'http://$KaliIp`:8080' -Secret 'dcig-hardening-2026'
  4) Login as .\student / Hardening2026!
  5) Run C:\HardeningLab\hardening_quest.ps1
     Double-click Desktop "DCIG Scoreboard" anytime to view the live board
"@

if ($needReboot) {
    Warn 'REBOOT REQUIRED for hostname. Re-run with -SkipRename -SkipNetwork if IP already set after reboot.'
    $ans = Read-Host 'Reboot now? [y/N]'
    if ($ans -match '^[Yy]') { Restart-Computer -Force }
}
