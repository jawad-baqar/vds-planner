<#
.SYNOPSIS
Checks a committed VDS Planner plan against the connected vCenter before the change window (RW-08).

.DESCRIPTION
The script is read-only. It checks the hash and the content of the plan file. Then, for each VDS of the plan (or one VDS with -VdsName), it reads the vCenter and finds the items that stop the change or need attention.
Blocking items are a missing cluster, clusters in more than one datacenter, a host that is not connected, an ESXi version that is earlier than the VDS version, a VDS that exists with different uplinks, a port group name that is on another VDS in the same datacenter, and an IP address that is in use on another host.
Warnings are hosts with a different standard switch layout (V-06) and a VDS that exists with a different version.
Invoke-VdsPlan.ps1 does the same checks before it changes anything.
The script writes a CSV file and a transcript to the output folder.

.PARAMETER PlanFile
The plan file, for example plan-cluster01-v1.json. The hash file must be in the same folder.

.PARAMETER VdsName
One VDS of the plan. If you do not give it, the script checks all VDS of the plan.

.PARAMETER OutputFolder
The folder for the CSV file and the transcript. The default is .\output.

.EXAMPLE
Connect-VIServer -Server vc01.example.local -Credential (Get-Credential administrator@vsphere.local)
.\Get-VdsPlanPreflight.ps1 -PlanFile .\plan-cluster01-v1.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PlanFile,
    [string] $VdsName,
    [string] $OutputFolder
)
$ErrorActionPreference = 'Stop'
# set here, not in param(): $PSScriptRoot is empty in a param() default under powershell.exe -File (5.1)
if (-not $OutputFolder) { $OutputFolder = Join-Path $PSScriptRoot '..\..\output' }
Import-Module (Join-Path $PSScriptRoot '..\lib\VdsPlan.psm1') -Force
New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
$stamp = Get-Date -Format yyyyMMdd-HHmmss-fff
Start-Transcript -Path (Join-Path $OutputFolder "Get-VdsPlanPreflight_$stamp.transcript.txt") | Out-Null
try {
    $plan = Get-VdsPlan -Path $PlanFile
    Write-Output "Plan '$($plan.draft)' version $($plan.version) for $($plan.vcenter). The hash and the content are correct."
    $list = @($plan.vds | Where-Object { -not $VdsName -or $_.name -eq $VdsName })
    if (-not $list.Count) { throw "The plan has no VDS $VdsName." }
    $all = foreach ($v in $list) { Get-VdsPlanLiveFinding -Plan $plan -Vds $v }
    $all = @($all)
    $csv = Join-Path $OutputFolder "Get-VdsPlanPreflight_$stamp.csv"
    if ($all.Count) { $all | Export-Csv $csv -NoTypeInformation -Encoding UTF8 }
    $all | Sort-Object @{ e = { @{ Block = 0; Warn = 1; Info = 2 }[$_.Level] } }, Vds | Format-Table Level, Vds, Object, Finding -AutoSize -Wrap | Out-String -Width 220 | Write-Output
    $b = @($all | Where-Object Level -eq 'Block').Count
    $w = @($all | Where-Object Level -eq 'Warn').Count
    Write-Output ("{0} VDS checked: {1} blocking, {2} warnings, {3} notes. {4}" -f $list.Count, $b, $w, ($all.Count - $b - $w), $(if ($all.Count) { "Report: $csv" } else { '' }))
    if ($b) { Write-Output 'Result: NOT READY. Correct the blocking items, then run the preflight again.' } else { Write-Output 'Result: READY for Invoke-VdsPlan.ps1 -WhatIf.' }
}
finally { Stop-Transcript | Out-Null }
