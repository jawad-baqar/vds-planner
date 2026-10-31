<#
.SYNOPSIS
Records the multipathing state of all hosts of one cluster: PowerPath/VE or NMP (RW-05, sample B-5).

.DESCRIPTION
The script is read-only. For each host, it lists the PowerPath/VE VIBs and the Dell EMC LUNs with their path policy.
A blank path policy on a Dell EMC LUN means that PowerPath/VE claims it. A cluster with both PowerPath/VE and NMP hosts must be aligned before the vLCM image conversion (RB-21).

.EXAMPLE
.\Get-MultipathState.ps1 -Cluster Cluster01
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Cluster,
    [string] $OutputFolder
)
$ErrorActionPreference = 'Stop'
# set here, not in param(): $PSScriptRoot is empty in a param() default under powershell.exe -File (5.1)
if (-not $OutputFolder) { $OutputFolder = Join-Path $PSScriptRoot '..\..\output' }
New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
$rows = Get-VMHost -Location (Get-Cluster -Name $Cluster) | Sort-Object Name | ForEach-Object {
    $esx = Get-EsxCli -VMHost $_ -V2
    $pp = $esx.software.vib.list.Invoke() | Where-Object Name -match 'powerpath'
    $dev = @(Get-ScsiLun -VmHost $_ -LunType disk | Where-Object Vendor -match 'EMC|DellEMC|DGC')
    [pscustomobject]@{
        Host = $_.Name
        PowerPath = ($pp | ForEach-Object { "$($_.Name) $($_.Version)" }) -join ', '
        EmcLuns = $dev.Count
        NmpRoundRobin = @($dev | Where-Object MultipathPolicy -eq 'RoundRobin').Count
        ClaimedByPowerPath = @($dev | Where-Object { -not $_.MultipathPolicy }).Count
        Method = if ($pp) { 'PowerPath/VE' } else { 'NMP' }
    }
}
$out = Join-Path $OutputFolder ("multipath_{0}.csv" -f ($Cluster -replace '[^\w-]', '_'))
$rows | Export-Csv $out -NoTypeInformation -Encoding UTF8
$methods = @($rows.Method | Sort-Object -Unique)
if ($methods.Count -gt 1) { Write-Warning "$Cluster mixes PowerPath/VE and NMP. Align the hosts before the image conversion (RW-05, RB-21)." }
Write-Output "File: $out"
