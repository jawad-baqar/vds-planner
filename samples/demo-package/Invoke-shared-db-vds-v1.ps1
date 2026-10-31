<#
.SYNOPSIS
Runs VDS plan Shared DB VDS version 1 on vc01.example.local (RW-08).

.DESCRIPTION
The VDS Planner generated this file. Do not edit it. Commit a new version in the VDS Planner to make a change.
The script asks for the vCenter credential, connects to vc01.example.local and runs Invoke-VdsPlan.ps1 for each VDS of the plan.
-Part Switch (the default) creates the VDS and the port groups and adds the hosts with no uplink.
-Part VMkernel adds the new VMkernel adapters on one host (-VMHost). Run it after Move-HostToVds.ps1 moved the uplinks of that host.
-Part Check runs the read-only preflight (Get-VdsPlanPreflight.ps1) for all VDS of the plan. Run it before the change window.
Invoke-VdsPlan.ps1 checks the SHA-256 hash of the plan file before it starts. Use -WhatIf first.
The report plan-shared-db-vds-v1-report.html shows the plan and the run steps.

.PARAMETER Part
Switch, VMkernel or Check. The default is Switch.

.PARAMETER VMHost
For -Part VMkernel: the host.

.PARAMETER ToolkitPath
The folder of the toolkit (with scripts\network\Invoke-VdsPlan.ps1).

.PARAMETER UserName
The vCenter user. The default is administrator@vsphere.local.

.EXAMPLE
.\Invoke-shared-db-vds-v1.ps1 -Part Check

.EXAMPLE
.\Invoke-shared-db-vds-v1.ps1 -WhatIf

.EXAMPLE
.\Invoke-shared-db-vds-v1.ps1 -Part VMkernel -VMHost esx01.example.local -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Switch', 'VMkernel', 'Check')] [string] $Part = 'Switch',
    [string] $VMHost,
    [string] $ToolkitPath = 'C:\Tools\vds-toolkit',
    [string] $UserName = 'administrator@vsphere.local'
)
$ErrorActionPreference = 'Stop'
if ($Part -eq 'VMkernel' -and -not $VMHost) { throw 'Use -VMHost with -Part VMkernel.' }
$server = 'vc01.example.local'
$planFile = Join-Path $PSScriptRoot 'plan-shared-db-vds-v1.json'
$runner = Join-Path $ToolkitPath 'scripts\network\Invoke-VdsPlan.ps1'
if (-not (Test-Path $runner)) { throw "Invoke-VdsPlan.ps1 is not in $ToolkitPath. Use -ToolkitPath." }
$vdsList = @('DB-shared-vds01')
if ($Part -eq 'VMkernel') {
    $plan = [IO.File]::ReadAllText($planFile) | ConvertFrom-Json
    $vdsList = @($plan.vds | Where-Object { @($_.vmkernel | ForEach-Object { @($_.hosts).host }) -contains $VMHost } | ForEach-Object { $_.name })
    if (-not $vdsList.Count) { throw "The plan has no new VMkernel adapter for $VMHost." }
}
$cred = Get-Credential -UserName $UserName -Message "Log in to $server"
$vi = Connect-VIServer -Server $server -Credential $cred
try {
    if ($Part -eq 'Check') { & (Join-Path $ToolkitPath 'scripts\network\Get-VdsPlanPreflight.ps1') -PlanFile $planFile; return }
    foreach ($vds in $vdsList) {
        Write-Output "--- $vds ($Part) ---"
        if ($Part -eq 'VMkernel') { & $runner -PlanFile $planFile -VdsName $vds -Part VMkernel -VMHost $VMHost -WhatIf:$WhatIfPreference }
        else { & $runner -PlanFile $planFile -VdsName $vds -WhatIf:$WhatIfPreference }
    }
}
finally { Disconnect-VIServer -Server $vi -Confirm:$false }
