<#
.SYNOPSIS
Exports the standard switch layout of all hosts in one cluster and proposes the VDS plan (RW-01, RW-08).

.DESCRIPTION
The script is read-only. It reads each host of the cluster and writes three CSV files to the output folder:
- <cluster>_hosts.csv: one row for each host and standard switch, with the ESXi version, the uplinks and the uplink speed. The VDS Planner uses it for the NIC speed check (V-08) and the VMkernel IP plan.
- <cluster>_portgroups.csv: one row for each standard port group, with the VLAN and the number of hosts that have it.
- <cluster>_vdsplan.csv: one row for each port group to create on the new VDS (rules V-01 to V-10 of the guide). The rows include the datacenter, because a distributed port group name must be unique in its datacenter.
The standard layout is the layout of the majority of the hosts (rule V-06). Hosts that do not match are marked.
The iDRAC USB and BMC switches are not in the plan (rule V-10).

.PARAMETER Cluster
The name of the cluster.

.PARAMETER OutputFolder
The folder for the CSV files. The default is .\output.

.EXAMPLE
.\Export-VssLayout.ps1 -Cluster 'Cluster01'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Cluster,
    [string] $OutputFolder
)
$ErrorActionPreference = 'Stop'
# set here, not in param(): $PSScriptRoot is empty in a param() default under powershell.exe -File (5.1)
if (-not $OutputFolder) { $OutputFolder = Join-Path $PSScriptRoot '..\..\output' }
Import-Module (Join-Path $PSScriptRoot '..\lib\VdsPlan.psm1') -Force
$skip = Get-VdsPlanSkippedSwitch
New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null

$cl = Get-Cluster -Name $Cluster
$dc = Get-Datacenter -Cluster $cl
$hosts = Get-VMHost -Location $cl | Sort-Object Name
$hostRows = @(); $pgRows = @()

foreach ($vmh in $hosts) {
    foreach ($vss in (Get-VirtualSwitch -VMHost $vmh -Standard | Where-Object { $skip -notcontains $_.Name })) {
        $nics = @($vss.Nic | Sort-Object)
        $speeds = $nics | ForEach-Object { (Get-VMHostNetworkAdapter -VMHost $vmh -Physical -Name $_).BitRatePerSec }
        $hostRows += [pscustomobject]@{
            Cluster = $Cluster; Datacenter = $dc.Name; Host = $vmh.Name; EsxVersion = $vmh.Version; EsxBuild = $vmh.Build; Switch = $vss.Name; Uplinks = ($nics -join ' '); UplinkCount = $nics.Count
            SpeedMbps = (($speeds | Sort-Object -Unique) -join ' '); Mtu = $vss.Mtu
        }
        foreach ($pg in (Get-VirtualPortGroup -VirtualSwitch $vss -Standard)) {
            $vmk = Get-VMHostNetworkAdapter -VMHost $vmh -VMKernel | Where-Object PortGroupName -eq $pg.Name
            $pgRows += [pscustomobject]@{ Cluster = $Cluster; Host = $vmh.Name; Switch = $vss.Name; PortGroup = $pg.Name; Vlan = $pg.VLanId; Vmk = (($vmk.Name) -join ' ') }
        }
    }
}

$plan = ConvertTo-VdsPlanRow -Cluster $Cluster -Datacenter $dc.Name -HostCount $hosts.Count -HostRows $hostRows -PortGroupRows $pgRows

$base = Join-Path $OutputFolder ($Cluster -replace '[^\w-]', '_')
$hostRows | Export-Csv "${base}_hosts.csv" -NoTypeInformation -Encoding UTF8
$pgRows   | Export-Csv "${base}_portgroups.csv" -NoTypeInformation -Encoding UTF8
$plan     | Export-Csv "${base}_vdsplan.csv" -NoTypeInformation -Encoding UTF8
Write-Output ("{0} hosts, {1} switch rows, {2} port groups in the VDS plan. Files: {3}_*.csv" -f $hosts.Count, $hostRows.Count, @($plan).Count, $base)
