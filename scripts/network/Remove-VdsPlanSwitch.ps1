<#
.SYNOPSIS
Removes one VDS of a committed VDS Planner plan when nothing uses it (RW-08, RB-03 pilot safety net).

.DESCRIPTION
Use this script to undo Invoke-VdsPlan.ps1 -Part Switch on a pilot cluster, for example after a failed test.
The script removes the VDS only when all of these conditions are true:
- The VDS is in the plan file and the hash of the plan file is correct.
- No host has a physical uplink on the VDS.
- No host has a VMkernel adapter on the VDS.
- No VM has a network adapter on a port group of the VDS.
If a condition is not true, the script stops and changes nothing. First move the VMs back with Move-VmNetworkToVds.ps1 -RollbackCsv, and move the uplinks and the VMkernel adapters back to the standard switch.
Use -WhatIf first. The script writes a transcript and a CSV log to the output folder.

.PARAMETER PlanFile
The plan file that created the VDS.

.PARAMETER VdsName
The VDS to remove.

.PARAMETER OutputFolder
The folder for the transcript and the CSV log. The default is .\output.

.EXAMPLE
.\Remove-VdsPlanSwitch.ps1 -PlanFile .\plan-cluster01-v1.json -VdsName Cluster01-vds01 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string] $PlanFile,
    [Parameter(Mandatory)] [string] $VdsName,
    [string] $OutputFolder
)
$ErrorActionPreference = 'Stop'
# set here, not in param(): $PSScriptRoot is empty in a param() default under powershell.exe -File (5.1)
if (-not $OutputFolder) { $OutputFolder = Join-Path $PSScriptRoot '..\..\output' }
Import-Module (Join-Path $PSScriptRoot '..\lib\VdsPlan.psm1') -Force
New-Item -ItemType Directory -Force -Path $OutputFolder -WhatIf:$false | Out-Null
$stamp = Get-Date -Format yyyyMMdd-HHmmss-fff
$safeName = $VdsName -replace '[^\w-]', '_'
Start-Transcript -Path (Join-Path $OutputFolder "Remove-VdsPlanSwitch_${safeName}_$stamp.transcript.txt") -WhatIf:$false | Out-Null
$log = New-Object System.Collections.ArrayList
try {
    $plan = Get-VdsPlan -Path $PlanFile
    if (-not (@($plan.vds) | Where-Object name -eq $VdsName)) { throw "$VdsName is not in the plan. The script removes only a VDS of the plan." }
    if (@($global:DefaultVIServers).Name -notcontains $plan.vcenter) { throw "Connect to $($plan.vcenter) first." }
    $vds = Get-VDSwitch -Name $VdsName -ErrorAction SilentlyContinue
    if (-not $vds) { Write-Output "$VdsName is not in the vCenter. Nothing to do."; return }

    $inUse = @()
    foreach ($h in @($vds | Get-VMHost)) {
        $pn = @(Get-VMHostNetworkAdapter -VMHost $h -VirtualSwitch $vds -Physical -ErrorAction SilentlyContinue)
        $vk = @(Get-VMHostNetworkAdapter -VMHost $h -VirtualSwitch $vds -VMKernel -ErrorAction SilentlyContinue)
        if ($pn.Count) { $inUse += "$($h.Name): uplinks $($pn.Name -join ', ')" }
        if ($vk.Count) { $inUse += "$($h.Name): VMkernel adapters $($vk.Name -join ', ')" }
    }
    foreach ($pg in @(Get-VDPortgroup -VDSwitch $vds)) {
        $vms = @($pg.ExtensionData.Vm).Count
        if ($vms) { $inUse += "$($pg.Name): $vms VMs" }
    }
    foreach ($u in $inUse) { [void]$log.Add([pscustomobject]@{ Time = (Get-Date -Format s); Vds = $VdsName; Item = $u; Result = 'In use' }) }
    if ($inUse.Count) { throw "$VdsName is in use. The script changed nothing.`n- $($inUse -join "`n- ")" }

    if ($PSCmdlet.ShouldProcess($VdsName, 'Remove VDS and its port groups (not in use)')) {
        Remove-VDSwitch -VDSwitch $vds -Confirm:$false
        [void]$log.Add([pscustomobject]@{ Time = (Get-Date -Format s); Vds = $VdsName; Item = $VdsName; Result = 'Removed' })
        Write-Output "Removed: $VdsName."
    }
}
finally {
    if ($log.Count) { $log | Export-Csv (Join-Path $OutputFolder "Remove-VdsPlanSwitch_${safeName}_$stamp.csv") -NoTypeInformation -Encoding UTF8 -WhatIf:$false }
    Stop-Transcript | Out-Null
}
