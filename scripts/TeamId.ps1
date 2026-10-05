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
    if ($LocalHostname -match '(?i)team\d+|dcig-syslab') {
        return "dcig-syslab-team$TeamId-ubuntu"
    }
    return "ubuntu$TeamId"
}
