# Shared team ID + peer hostname helpers (cyber range + homelab).

function Get-TeamIdFromHostname {
    param([string]$Hostname = $env:COMPUTERNAME)
    if ($Hostname -match '(?i)team(\d+)') {
        return ('{0:D2}' -f [int]$Matches[1])
    }
    if ($Hostname -match '(\d+)$') {
        return ('{0:D2}' -f [int]$Matches[1])
    }
    return '00'
}

function Get-LinuxPeerHostname {
    param(
        [string]$TeamId,
        [string]$LocalHostname = $env:COMPUTERNAME
    )
    # Range Linux target naming (Windows minion is win19_srvNN).
    if ($LocalHostname -match '(?i)^win19_srv\d+$' -or $LocalHostname -match '(?i)team\d+-jump') {
        return "dcig-syslab-team$TeamId-ubuntu"
    }
    if ($LocalHostname -match '(?i)team\d+|dcig-syslab') {
        return "dcig-syslab-team$TeamId-ubuntu"
    }
    return "ubuntu$TeamId"
}
