<#
.SYNOPSIS
Moves the uplinks and the VMkernel adapters of one host from a standard switch to its VDS, in stages (RW-08, sample B-2).

.DESCRIPTION
Stage 1 moves one uplink to the VDS. The standard switch keeps the other uplinks.
Stage 2 (after the VM networks moved, Move-VmNetworkToVds.ps1) moves the VMkernel adapters and the remaining uplinks together.
After each stage, the script checks that the host is still connected to vCenter. If it is not connected, wait for the automatic network rollback (RB-03).
Run one host at a time. Use -WhatIf first.

.PARAMETER VMHost
The host name.

.PARAMETER VdsName
The target VDS.

.PARAMETER Stage
1 or 2.

.PARAMETER FirstUplink
The physical NIC to move in stage 1. The default is vmnic1.

.PARAMETER VmkMap
For stage 2: a hashtable of VMkernel adapter to VDS port group, for example @{ vmk0 = 'Management Network' }.

.EXAMPLE
.\Move-HostToVds.ps1 -VMHost esx01.example.local -VdsName Cluster01-vds01 -Stage 1 -WhatIf

.EXAMPLE
.\Move-HostToVds.ps1 -VMHost esx01.example.local -VdsName Cluster01-vds01 -Stage 2 -VmkMap @{ vmk0 = 'Management Network' }
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string] $VMHost,
    [Parameter(Mandatory)] [string] $VdsName,
    [Parameter(Mandatory)] [ValidateSet(1, 2)] [int] $Stage,
    [string] $FirstUplink = 'vmnic1',
    [hashtable] $VmkMap = @{},
    [string] $SourceSwitch = 'vSwitch0',
    [string] $OutputFolder
)
$ErrorActionPreference = 'Stop'
# set here, not in param(): $PSScriptRoot is empty in a param() default under powershell.exe -File (5.1)
if (-not $OutputFolder) { $OutputFolder = Join-Path $PSScriptRoot '..\..\output' }
New-Item -ItemType Directory -Force -Path $OutputFolder -WhatIf:$false | Out-Null
Start-Transcript -Path (Join-Path $OutputFolder "Move-HostToVds_$($VMHost)_stage${Stage}_$(Get-Date -Format yyyyMMdd-HHmmss-fff).transcript.txt") -WhatIf:$false | Out-Null
try {
    $vmh = Get-VMHost -Name $VMHost
    $vds = Get-VDSwitch -Name $VdsName
    $vss = Get-VirtualSwitch -VMHost $vmh -Standard -Name $SourceSwitch
    $pnic = Get-VMHostNetworkAdapter -VMHost $vmh -Physical

    if ($Stage -eq 1) {
        if (@($vss.Nic).Count -lt 2) { throw "$SourceSwitch has fewer than two uplinks. Add an uplink first (V-02)." }
        $nic = $pnic | Where-Object Name -eq $FirstUplink
        if ($PSCmdlet.ShouldProcess("$VMHost $FirstUplink", "Move to $VdsName")) {
            Add-VDSwitchPhysicalNetworkAdapter -DistributedSwitch $vds -VMHostPhysicalNic $nic -Confirm:$false
        }
    }
    else {
        if ($VmkMap.Count -eq 0) { throw 'Stage 2 needs -VmkMap.' }
        $vmks = @(); $pgs = @()
        foreach ($k in $VmkMap.Keys) {
            $vmks += Get-VMHostNetworkAdapter -VMHost $vmh -VMKernel -Name $k
            $pgs  += Get-VDPortgroup -VDSwitch $vds -Name $VmkMap[$k]
        }
        $rest = $pnic | Where-Object { @($vss.Nic) -contains $_.Name }
        if ($PSCmdlet.ShouldProcess("$VMHost $($VmkMap.Keys -join ' ') and $($rest.Name -join ' ')", "Move to $VdsName")) {
            Add-VDSwitchPhysicalNetworkAdapter -DistributedSwitch $vds -VMHostPhysicalNic $rest `
                -VMHostVirtualNic $vmks -VirtualNicPortgroup $pgs -Confirm:$false
        }
    }

    Start-Sleep -Seconds 30
    $state = (Get-VMHost -Name $VMHost).ConnectionState
    if ($state -notin 'Connected', 'Maintenance') { Write-Warning "$VMHost is $state. Wait for the automatic network rollback. Then find the cause (RB-03)." }
    else { Write-Output "$VMHost stage $Stage done. Connection state: $state." }
}
finally { Stop-Transcript | Out-Null }
