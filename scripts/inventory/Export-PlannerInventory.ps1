<#
.SYNOPSIS
Makes the VDS Planner input files from an inventory workbook of one vCenter, with no connection to vCenter (RW-01, RW-08).

.DESCRIPTION
The script is read-only. It reads an inventory workbook (.xlsx) of one vCenter and writes the same CSV files as Export-VssLayout.ps1, for all clusters of the vCenter:
- <name>_hosts.csv: one row for each host and standard switch, with the datacenter, the ESXi version, the uplinks, the NIC speed and the MTU.
- <name>_portgroups.csv: one row for each standard port group on each host, with the VLAN and the VMkernel adapters.
- <name>_vdsplan.csv: the VDS plan rows (rules V-01, V-05, V-06, V-07 and V-10 of the guide), with the security and teaming settings of each port group.
- <name>_existing_vds.csv: the VDS and port groups that exist in the vCenter. The planner uses this file to find port group names that are already in use in a datacenter.
If the vCenter has no standard switch to convert, the script writes only the existing VDS file.
- <name>.vdsplan.json: a VDS Planner project with the inventory and two drafts with one VDS for each standard switch. "Standard layout (V-01)" keeps the port group names. "Standard layout (V-01), names fixed" gives the VLAN to the end of a name that is on one VDS more than one time, and the cluster name to the front of a name that is on more than one VDS of a datacenter. Open the project in the planner with Open project.
The workbook must have the sheets vHost, vSwitch, vPort, vNIC and vSC_VMK. The sheets dvSwitch and dvPort are optional.
Hosts with no cluster are not in the plan. The script lists them.
Keep the output in the environment of the organization that owns the data. Do not put it in the toolkit repository.

.PARAMETER Workbook
The inventory workbook of one vCenter.

.PARAMETER Name
The name for the output files, for example the site. The default is the workbook file name.

.PARAMETER OutputFolder
The folder for the CSV files. The default is .\output.

.EXAMPLE
.\Export-PlannerInventory.ps1 -Workbook '.\inventory\vc01.xlsx' -Name SiteA -OutputFolder '.\output\SiteA'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Workbook,
    [string] $Name,
    [string] $OutputFolder
)
$ErrorActionPreference = 'Stop'
# set here, not in param(): $PSScriptRoot is empty in a param() default under powershell.exe -File (5.1)
if (-not $OutputFolder) { $OutputFolder = Join-Path $PSScriptRoot '..\..\output' }
Import-Module (Join-Path $PSScriptRoot '..\lib\Workbook.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\VdsPlan.psm1') -Force
New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
if (-not $Name) { $Name = [IO.Path]::GetFileNameWithoutExtension($Workbook).Trim() }
$safe = $Name -replace '[^\w-]', '_'
$skip = Get-VdsPlanSkippedSwitch

$sheets = Get-WorkbookSheet $Workbook
foreach ($s in 'vHost', 'vSwitch', 'vPort', 'vNIC', 'vSC_VMK') { if ($sheets -notcontains $s) { throw "The workbook has no sheet $s." } }
$vHost = @(Import-WorkbookSheet $Workbook 'vHost')
$vSwitch = @(Import-WorkbookSheet $Workbook 'vSwitch')
$vPort = @(Import-WorkbookSheet $Workbook 'vPort')
$vNic = @(Import-WorkbookSheet $Workbook 'vNIC')
$vVmk = @(Import-WorkbookSheet $Workbook 'vSC_VMK')
# @() around if: an if statement returns one item as an item, not as an array
$dvSwitch = @(if ($sheets -contains 'dvSwitch') { Import-WorkbookSheet $Workbook 'dvSwitch' })
$dvPort = @(if ($sheets -contains 'dvPort') { Import-WorkbookSheet $Workbook 'dvPort' })
$vcenter = ($vHost | Where-Object { $_.'VI SDK Server' } | Select-Object -First 1).'VI SDK Server'

# indexes, so that a large vCenter takes seconds and not minutes
function Group-ByKey($Rows, [scriptblock] $Key) {
    $h = @{}
    foreach ($r in $Rows) { $k = & $Key $r; if (-not $h.ContainsKey($k)) { $h[$k] = New-Object System.Collections.ArrayList }; [void]$h[$k].Add($r) }
    $h
}
$nicBy = Group-ByKey $vNic { param($r) "$($r.Host)|$($r.Switch)" }
$pgBy = Group-ByKey $vPort { param($r) "$($r.Host)|$($r.Switch)" }
$vmkBy = Group-ByKey $vVmk { param($r) "$($r.Host)|$($r.'Port Group')" }
$swBy = Group-ByKey $vSwitch { param($r) $r.Host }
$lbMap = @{ loadbalance_srcid = 'LoadBalanceSrcId'; loadbalance_srcmac = 'LoadBalanceSrcMac'; loadbalance_ip = 'LoadBalanceIP'; loadbalance_loadbased = 'LoadBalanceLoadBased'; failover_explicit = 'ExplicitFailover' }

$allHosts = @(); $allPgs = @(); $allPlan = @(); $standalone = @()
foreach ($cl in ($vHost | Group-Object Cluster | Sort-Object Name)) {
    if (-not $cl.Name) { $standalone += $cl.Group.Host; continue }
    $hosts = @($cl.Group | Sort-Object Host)
    $dc = ($hosts | Select-Object -First 1).Datacenter
    $hostRows = @(); $pgRows = @()
    foreach ($h in $hosts) {
        $ver = if ($h.'ESX Version' -match '(\d+\.\d+\.\d+)') { $Matches[1] } else { '' }
        $build = if ($h.'ESX Version' -match 'build-(\d+)') { $Matches[1] } else { '' }
        foreach ($sw in @($swBy[$h.Host] | Where-Object { $_ -and $skip -notcontains $_.Switch })) {
            $nics = @($nicBy["$($h.Host)|$($sw.Switch)"] | Where-Object { $_ })
            $hostRows += [pscustomobject]@{
                Cluster = $cl.Name; Datacenter = $dc; Host = $h.Host; EsxVersion = $ver; EsxBuild = $build; Switch = $sw.Switch
                Uplinks = (($nics.'Network Device' | Sort-Object) -join ' '); UplinkCount = $nics.Count
                SpeedMbps = (($nics.Speed | Where-Object { $_ } | Sort-Object -Unique) -join ' '); Mtu = $sw.MTU
            }
            foreach ($p in @($pgBy["$($h.Host)|$($sw.Switch)"] | Where-Object { $_ })) {
                $vmk = @($vmkBy["$($h.Host)|$($p.'Port Group')"] | Where-Object { $_ })
                $pgRows += [pscustomobject]@{
                    Cluster = $cl.Name; Host = $h.Host; Switch = $sw.Switch; PortGroup = $p.'Port Group'; Vlan = $p.VLAN; Vmk = (($vmk.Device) -join ' ')
                    Promiscuous = $p.'Promiscuous Mode'; MacChanges = $p.'Mac Changes'; ForgedTransmits = $p.'Forged Transmits'; Policy = $p.Policy
                }
            }
        }
    }
    $plan = @(ConvertTo-VdsPlanRow -Cluster $cl.Name -Datacenter $dc -HostCount $hosts.Count -HostRows $hostRows -PortGroupRows $pgRows)
    # security and teaming of the standard port group (first host with the port group)
    foreach ($r in $plan) {
        $src = $pgRows | Where-Object { $_.Switch -eq $r.Switch -and $_.PortGroup -eq $r.PortGroup -and "$($_.Vlan)" -eq "$($r.Vlan)" } | Select-Object -First 1
        $r | Add-Member Promiscuous "$($src.Promiscuous)"; $r | Add-Member MacChanges "$($src.MacChanges)"; $r | Add-Member ForgedTransmits "$($src.ForgedTransmits)"
        $r | Add-Member LoadBalancing $(if ($lbMap.ContainsKey("$($src.Policy)")) { $lbMap["$($src.Policy)"] } else { '' })
    }
    $allHosts += $hostRows; $allPgs += $pgRows; $allPlan += $plan
}

$dcOfVds = @{}; foreach ($d in $dvSwitch) { $dcOfVds[$d.Switch] = $d.Datacenter }
$existing = @($dvPort | ForEach-Object { [pscustomobject]@{ Datacenter = $dcOfVds[$_.Switch]; Vds = $_.Switch; PortGroup = $_.Port; Vlan = $_.VLAN; Binding = $_.Type } })

$base = Join-Path $OutputFolder $safe
# no empty files: a vCenter with no standard switch to convert gets only the existing VDS file
if ($allPlan.Count) {
    $allHosts | Export-Csv "${base}_hosts.csv" -NoTypeInformation -Encoding UTF8
    $allPgs | Export-Csv "${base}_portgroups.csv" -NoTypeInformation -Encoding UTF8
    $allPlan | Export-Csv "${base}_vdsplan.csv" -NoTypeInformation -Encoding UTF8
}
else { Write-Warning "$Name has no standard switch to convert (only switches that rule V-07 or V-10 removes)." }

# project file: open it in the planner to start with all switches in one draft
$files = @(Get-ChildItem "${base}_*.csv" -ErrorAction SilentlyContinue | ForEach-Object Name)
$project = New-VdsPlanProject -Site $Name -VCenter "$vcenter" -PlanRows $allPlan -HostRows $allHosts -ExistingRows $existing -Files $files
# second draft: the same layout with names that vCenter accepts (no duplicate, no clash in a datacenter)
if ($allPlan.Count) {
    $fixed = ($project.drafts[0] | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $fixed.id = 'd' + [guid]::NewGuid().ToString('N').Substring(0, 10); $fixed.name = 'Standard layout (V-01), names fixed'
    $dcOf = @{}; foreach ($r in $allPlan) { $dcOf["$($r.Cluster)"] = "$($r.Datacenter)" }
    $rep = Repair-VdsPlanName -Draft $fixed -Existing $existing -DatacenterOf $dcOf
    $project.drafts = @($project.drafts) + @($fixed)
}
[IO.File]::WriteAllText("$base.vdsplan.json", ($project | ConvertTo-Json -Depth 30 -Compress), (New-Object Text.UTF8Encoding $false))
if ($existing.Count) { $existing | Export-Csv "${base}_existing_vds.csv" -NoTypeInformation -Encoding UTF8 }

[pscustomobject]@{
    Name = $Name; VCenter = $vcenter; Datacenters = @($vHost.Datacenter | Sort-Object -Unique).Count
    Clusters = @($allPlan.Cluster | Sort-Object -Unique).Count; Hosts = @($vHost | Where-Object Cluster).Count; StandaloneHosts = $standalone.Count
    SwitchesToConvert = @($allPlan | ForEach-Object { "$($_.Cluster)|$($_.Switch)" } | Sort-Object -Unique).Count
    PlanPortGroups = $allPlan.Count; ExistingVds = $dvSwitch.Count; ExistingVdsPortGroups = $existing.Count
    RenamedDuplicates = $(if ($rep) { $rep.Duplicates } else { 0 }); RenamedForDatacenter = $(if ($rep) { $rep.Prefixed } else { 0 })
    Files = "${base}_*.csv"
}
if ($standalone.Count) { Write-Warning "Hosts with no cluster are not in the plan: $($standalone -join ', ')" }
