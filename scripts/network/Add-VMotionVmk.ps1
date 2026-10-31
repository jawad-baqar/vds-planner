<#
.SYNOPSIS
Adds a dedicated vMotion VMkernel adapter on each host of one cluster from an IP plan CSV (RW-07, sample B-4).

.DESCRIPTION
The script creates the vMotion port group on the VDS if it does not exist. For each host in the CSV, it adds a VMkernel adapter with vMotion on, and turns vMotion off on vmk0.
CSV columns: Host, IP, SubnetMask. Use -WhatIf first.

.EXAMPLE
.\Add-VMotionVmk.ps1 -VdsName Cluster01-vds01 -VlanId 200 -IpPlanCsv .\samples\vmotion_ipplan.sample.csv -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string] $VdsName,
    [Parameter(Mandatory)] [ValidateRange(1, 4094)] [int] $VlanId,
    [Parameter(Mandatory)] [string] $IpPlanCsv,
    [string] $PortGroup = 'pg-vmotion',
    [int] $Mtu = 9000
)
$ErrorActionPreference = 'Stop'
$vds = Get-VDSwitch -Name $VdsName
$pg = Get-VDPortgroup -VDSwitch $vds -Name $PortGroup -ErrorAction SilentlyContinue
if (-not $pg -and $PSCmdlet.ShouldProcess("$VdsName / $PortGroup (VLAN $VlanId)", 'Create port group')) { $pg = New-VDPortgroup -VDSwitch $vds -Name $PortGroup -VlanId $VlanId }

foreach ($r in (Import-Csv $IpPlanCsv)) {
    $vmh = Get-VMHost -Name $r.Host
    if (Get-VMHostNetworkAdapter -VMHost $vmh -VMKernel | Where-Object { $_.VMotionEnabled -and $_.PortGroupName -eq $PortGroup }) { Write-Verbose "$($r.Host): already done"; continue }
    if ($PSCmdlet.ShouldProcess("$($r.Host) $($r.IP)", 'Add vMotion VMkernel adapter')) {
        New-VMHostNetworkAdapter -VMHost $vmh -VirtualSwitch $vds -PortGroup $PortGroup -IP $r.IP -SubnetMask $r.SubnetMask -Mtu $Mtu -VMotionEnabled $true -Confirm:$false | Out-Null
        Get-VMHostNetworkAdapter -VMHost $vmh -VMKernel -Name vmk0 | Set-VMHostNetworkAdapter -VMotionEnabled $false -Confirm:$false | Out-Null
    }
}
