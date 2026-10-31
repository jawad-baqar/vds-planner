<#
.SYNOPSIS
Moves the VM network adapters of one standard port group to its VDS port group, and writes a rollback CSV (RW-08, sample B-3).

.DESCRIPTION
The script moves all adapters in the cluster that use the standard port group. Before each move, it writes the VM, the adapter and the old port group to a rollback CSV.
To roll back, run the script with -RollbackCsv. Use -WhatIf first.

.EXAMPLE
.\Move-VmNetworkToVds.ps1 -Cluster Cluster01 -VdsName Cluster01-vds01 -StandardPortGroup 'VLAN100' -VdsPortGroup 'VLAN100' -WhatIf

.EXAMPLE
.\Move-VmNetworkToVds.ps1 -RollbackCsv .\output\rollback_Cluster01_VLAN100_20261030-0900.csv
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Move')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Move')] [string] $Cluster,
    [Parameter(Mandatory, ParameterSetName = 'Move')] [string] $VdsName,
    [Parameter(Mandatory, ParameterSetName = 'Move')] [string] $StandardPortGroup,
    [Parameter(Mandatory, ParameterSetName = 'Move')] [string] $VdsPortGroup,
    [Parameter(Mandatory, ParameterSetName = 'Rollback')] [string] $RollbackCsv,
    [string] $OutputFolder
)
$ErrorActionPreference = 'Stop'
# set here, not in param(): $PSScriptRoot is empty in a param() default under powershell.exe -File (5.1)
if (-not $OutputFolder) { $OutputFolder = Join-Path $PSScriptRoot '..\..\output' }
New-Item -ItemType Directory -Force -Path $OutputFolder -WhatIf:$false | Out-Null

if ($PSCmdlet.ParameterSetName -eq 'Rollback') {
    foreach ($r in (Import-Csv $RollbackCsv)) {
        $na = Get-VM -Name $r.VM | Get-NetworkAdapter -Name $r.Adapter
        $pg = Get-VirtualPortGroup -VMHost (Get-VM -Name $r.VM).VMHost -Standard -Name $r.OldPortGroup
        if ($PSCmdlet.ShouldProcess("$($r.VM) $($r.Adapter)", "Move back to $($r.OldPortGroup)")) { Set-NetworkAdapter -NetworkAdapter $na -Portgroup $pg -Confirm:$false | Out-Null }
    }
    return
}

$stamp = Get-Date -Format yyyyMMdd-HHmmss-fff
$log = Join-Path $OutputFolder ("rollback_{0}_{1}_{2}.csv" -f ($Cluster -replace '[^\w-]', '_'), ($StandardPortGroup -replace '[^\w-]', '_'), $stamp)
$new = Get-VDPortgroup -VDSwitch (Get-VDSwitch -Name $VdsName) -Name $VdsPortGroup
$adapters = Get-VM -Location (Get-Cluster -Name $Cluster) | Get-NetworkAdapter | Where-Object NetworkName -eq $StandardPortGroup
foreach ($na in $adapters) {
    [pscustomobject]@{ VM = $na.Parent.Name; Adapter = $na.Name; OldPortGroup = $StandardPortGroup; NewPortGroup = $VdsPortGroup } |
        Export-Csv $log -NoTypeInformation -Encoding UTF8 -Append -WhatIf:$false
    if ($PSCmdlet.ShouldProcess("$($na.Parent.Name) $($na.Name)", "Move to $VdsPortGroup")) { Set-NetworkAdapter -NetworkAdapter $na -Portgroup $new -Confirm:$false | Out-Null }
}
Write-Output "$(@($adapters).Count) adapters. Rollback file: $log"
