<#
.SYNOPSIS
Creates the VDS and the port groups for one standard switch of one cluster (RW-08, sample B-1).

.DESCRIPTION
The script reads the VDS plan CSV of Export-VssLayout.ps1 (rows of one NewVds only). It creates the VDS, the port groups and the teaming, and adds all hosts of the cluster with no uplink.
It does not move uplinks, VMkernel adapters or VMs. Use -WhatIf first.

.PARAMETER Cluster
The name of the cluster.

.PARAMETER PlanCsv
The VDS plan CSV. Columns used: NewVds, VdsPortGroup, Vlan.

.PARAMETER VdsName
The VDS to create, for example Cluster01-vds01. The script uses only the plan rows of this VDS.

.PARAMETER UplinkCount
The number of uplinks of the standard switch. Use 2 or more (rule V-02).

.PARAMETER Version
The VDS version. The default is 8.0.3.

.EXAMPLE
.\New-ClusterVds.ps1 -Cluster 'Cluster01' -PlanCsv .\output\Cluster01_vdsplan.csv -VdsName 'Cluster01-vds01' -UplinkCount 2 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string] $Cluster,
    [Parameter(Mandatory)] [string] $PlanCsv,
    [Parameter(Mandatory)] [string] $VdsName,
    [ValidateRange(2, 8)] [int] $UplinkCount = 2,
    [string] $Version = '8.0.3',
    [int] $Mtu = 1500,
    [string] $OutputFolder
)
$ErrorActionPreference = 'Stop'
# set here, not in param(): $PSScriptRoot is empty in a param() default under powershell.exe -File (5.1)
if (-not $OutputFolder) { $OutputFolder = Join-Path $PSScriptRoot '..\..\output' }
New-Item -ItemType Directory -Force -Path $OutputFolder -WhatIf:$false | Out-Null
Start-Transcript -Path (Join-Path $OutputFolder "New-ClusterVds_${VdsName}_$(Get-Date -Format yyyyMMdd-HHmmss-fff).transcript.txt") -WhatIf:$false | Out-Null
try {
    $rows = Import-Csv $PlanCsv | Where-Object NewVds -eq $VdsName
    if (-not $rows) { throw "The plan has no rows for $VdsName." }
    $cl = Get-Cluster -Name $Cluster
    $dc = Get-Datacenter -Cluster $cl

    $vds = Get-VDSwitch -Name $VdsName -ErrorAction SilentlyContinue
    if (-not $vds -and $PSCmdlet.ShouldProcess($VdsName, 'Create VDS')) {
        $vds = New-VDSwitch -Name $VdsName -Location $dc -Version $Version -NumUplinkPorts $UplinkCount -Mtu $Mtu `
            -LinkDiscoveryProtocol LLDP -LinkDiscoveryProtocolOperation Both
    }
    $uplinks = 1..$UplinkCount | ForEach-Object { "dvUplink$_" }

    foreach ($r in $rows) {
        if ($vds -and (Get-VDPortgroup -VDSwitch $vds -Name $r.VdsPortGroup -ErrorAction SilentlyContinue)) { Write-Verbose "Exists: $($r.VdsPortGroup)"; continue }
        if (-not $PSCmdlet.ShouldProcess("$VdsName / $($r.VdsPortGroup) (VLAN $($r.Vlan))", 'Create port group')) { continue }
        $pg = switch ($r.Vlan) {
            '4095'  { New-VDPortgroup -VDSwitch $vds -Name $r.VdsPortGroup -VlanTrunkRange '0-4094' }
            '0'     { New-VDPortgroup -VDSwitch $vds -Name $r.VdsPortGroup }
            default { New-VDPortgroup -VDSwitch $vds -Name $r.VdsPortGroup -VlanId ([int]$r.Vlan) }
        }
        # same teaming as the standard switch: originating port ID, all uplinks active
        $pg | Get-VDUplinkTeamingPolicy | Set-VDUplinkTeamingPolicy -LoadBalancingPolicy LoadBalanceSrcId -ActiveUplinkPort $uplinks | Out-Null
    }

    $missing = Get-VMHost -Location $cl | Where-Object { -not $vds -or ($vds | Get-VMHost) -notcontains $_ }
    if ($missing -and $PSCmdlet.ShouldProcess(($missing.Name -join ', '), "Add hosts to $VdsName with no uplink")) {
        Add-VDSwitchVMHost -VDSwitch $vds -VMHost $missing
    }
    Write-Output "Done: $VdsName, $(@($rows).Count) port groups in the plan."
}
finally { Stop-Transcript | Out-Null }
