<#
.SYNOPSIS
Makes the preloaded VDS Planner material for each vCenter from its inventory workbook, with no connection to vCenter (RW-01, RW-08).

.DESCRIPTION
The script is read-only for vCenter. For each workbook it:
1. Runs Export-PlannerInventory.ps1. The result is the planner input files and a project file with two drafts.
2. Runs the simulation (tests\Invoke-InventorySimulation.ps1) for the two drafts, with the VLAN trunk check (V-05) open and with it confirmed.
3. Writes a start page (index.html) with the result of each site and links to the project files and the readiness reports.
The output holds environment data. Keep it in the environment of the organization that owns the data. Do not put it in the toolkit repository.

.PARAMETER Workbook
The inventory workbooks, one for each vCenter.

.PARAMETER Site
The site names, in the same sequence as the workbooks. The default is the workbook file names.

.PARAMETER OutputFolder
The folder for the material. The script makes one folder for each site.

.EXAMPLE
.\Export-PlannerPreload.ps1 -Workbook .\inv\prd.xlsx, .\inv\dr.xlsx -Site PRD, DR -OutputFolder 'D:\VDS Planner'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string[]] $Workbook,
    [string[]] $Site,
    [Parameter(Mandatory)] [string] $OutputFolder
)
$ErrorActionPreference = 'Stop'
$tk = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ($Site -and $Site.Count -ne $Workbook.Count) { throw 'Give one site name for each workbook.' }
New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
$ps = (Get-Process -Id $PID).Path
$results = @()
for ($i = 0; $i -lt $Workbook.Count; $i++) {
    $wbPath = (Resolve-Path $Workbook[$i]).Path
    $name = if ($Site) { $Site[$i] } else { [IO.Path]::GetFileNameWithoutExtension($wbPath).Trim() -replace '[^\w-]', '-' }
    $inv = Join-Path $OutputFolder "$name\inventory"; $sim = Join-Path $OutputFolder "$name\simulation"
    Write-Output "--- $name"
    $c = & (Join-Path $PSScriptRoot 'Export-PlannerInventory.ps1') -Workbook $wbPath -Name $name -OutputFolder $inv 3>$null
    if (Test-Path $sim) { Remove-Item $sim -Recurse -Force }
    $scen = @()
    $drafts = @('Standard layout (V-01)'); if ($c.SwitchesToConvert) { $drafts += 'Standard layout (V-01), names fixed' }
    foreach ($dn in $drafts) {
        foreach ($assume in $false, $true) {
            if (-not $c.SwitchesToConvert -and $assume) { continue }
            # a separate PowerShell process: the fake vCenter of the simulation stays out of this session
            $sw = if ($assume) { '-AssumeTrunkConfirmed' } else { '' }
            $cmd = "& '$tk\tests\Invoke-InventorySimulation.ps1' -ProjectFile '$inv\$name.vdsplan.json' -OutputFolder '$sim' -PortGroupFile '$inv\${name}_portgroups.csv' -Draft '$dn' $sw | ConvertTo-Json -Compress"
            $j = & $ps -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>$null | Select-Object -Last 1
            $r = $j | ConvertFrom-Json
            $sfx = $(if ($dn -match 'names fixed') { '-names-fixed' } else { '' }) + $(if ($assume) { '-trunk-confirmed' } else { '' })
            $scen += [pscustomobject]@{ Draft = $dn; Trunk = $(if ($assume) { 'confirmed' } else { 'open' }); Vds = $r.Vds; Done = $r.SimulatedRunDone; Blocks = $r.Blocks; Report = "$name/simulation/$name-readiness$sfx.html" }
        }
    }
    $results += [pscustomobject]@{ Site = $name; Conv = $c; Scen = $scen }
}

$esc = { param($t) [System.Net.WebUtility]::HtmlEncode("$t") }
$css = ':root{--ink:#1b1c1e;--muted:#62656b;--line:#d7d9dd;--soft:#eef0f2;--ok:#2e7d4f;--okb:#e2f2e8;--warn:#9a6a00;--warnb:#fbf0d4;--bad:#a63a32;--badb:#f8e3e1}' +
    '@media (prefers-color-scheme:dark){:root{--ink:#e7e8ea;--muted:#9a9ea6;--line:#363a41;--soft:#2a2d33;--ok:#6cc495;--okb:#1d3428;--warn:#e0b450;--warnb:#3a3018;--bad:#ec8a80;--badb:#3d2220}body{background:#16171a}}' +
    'body{font:14px/1.55 system-ui,"Segoe UI",sans-serif;color:var(--ink);margin:0;padding:24px 16px}main{max-width:1100px;margin:0 auto}h1{font-size:24px;margin:0 0 4px}h2{font-size:17px;margin:26px 0 8px;border-top:1px solid var(--line);padding-top:10px}' +
    '.m{color:var(--muted)}a{color:#2f5d8a}.tbl{overflow-x:auto;border:1px solid var(--line);border-radius:8px}table{border-collapse:collapse;width:100%;font-size:13px}th,td{text-align:left;padding:6px 9px;border-bottom:1px solid var(--line);vertical-align:top}th{background:var(--soft)}' +
    '.tag{font:11px/1.6 ui-monospace,Consolas,monospace;padding:0 7px;border-radius:10px;border:1px solid currentColor;white-space:nowrap}.t-ok{color:var(--ok);background:var(--okb)}.t-warn{color:var(--warn);background:var(--warnb)}.t-bad{color:var(--bad);background:var(--badb)}ol li{margin:4px 0}code{font-family:Consolas,monospace;background:var(--soft);padding:1px 4px;border-radius:3px}'
$h = New-Object System.Text.StringBuilder
[void]$h.Append("<!doctype html><html lang=`"en`"><head><meta charset=`"utf-8`"><meta name=`"viewport`" content=`"width=device-width, initial-scale=1`"><title>VDS Planner material</title><style>$css</style></head><body><main>")
[void]$h.Append('<h1>VDS Planner: preloaded material</h1><p class="m">RW-08 · made from the inventory workbook of each vCenter, with no connection to vCenter. The simulation runs the toolkit against a copy of the inventory.</p>')
[void]$h.Append('<h2>Start</h2><ol><li>Open <code>toolkit\planner\vds-planner.html</code> in Microsoft Edge.</li><li>Select <b>Open project</b> and select <code>&lt;site&gt;\inventory\&lt;site&gt;.vdsplan.json</code>.</li><li>Select the draft <i>Standard layout (V-01), names fixed</i> or <i>Standard layout (V-01)</i>. Read the readiness report of the site first.</li><li>Set the security zone of each cluster. Confirm the VLAN trunk check (V-05) on each VDS when the network team confirms it. Commit, then follow the operator guide.</li></ol>')
[void]$h.Append('<h2>Sites</h2><div class="tbl"><table><tr><th>Site</th><th>Clusters</th><th>Hosts</th><th>Switches to convert</th><th>Port groups</th><th>Existing VDS</th><th>Project</th></tr>')
foreach ($r in $results) {
    $c = $r.Conv
    [void]$h.Append("<tr><td><b>$(& $esc $r.Site)</b></td><td>$($c.Clusters)</td><td>$($c.Hosts)$(if ($c.StandaloneHosts) { " (+$($c.StandaloneHosts) with no cluster)" })</td><td>$($c.SwitchesToConvert)</td><td>$($c.PlanPortGroups)</td><td>$($c.ExistingVds)</td><td><a href=`"$(& $esc $r.Site)/inventory/$(& $esc $r.Site).vdsplan.json`">project file</a></td></tr>")
}
[void]$h.Append('</table></div><h2>Simulation</h2><p class="m">Each line is one simulated change of all VDS of the draft, in sequence, against the inventory. A VDS that a check blocks is not made, so later VDS can pass checks that they fail after the block is corrected. The scenario with names fixed and V-05 confirmed shows the work that is left.</p>')
[void]$h.Append('<div class="tbl"><table><tr><th>Site</th><th>Draft</th><th>V-05 trunk check</th><th>VDS</th><th>Simulated run done</th><th>Blocking items</th><th>Report</th></tr>')
foreach ($r in $results) {
    foreach ($s in $r.Scen) {
        $cls = if (-not $s.Vds) { 't-ok' } elseif ($s.Done -eq $s.Vds -and -not $s.Blocks) { 't-ok' } elseif ($s.Done) { 't-warn' } else { 't-bad' }
        $txt = if (-not $s.Vds) { 'nothing to convert' } else { "$($s.Done) of $($s.Vds)" }
        [void]$h.Append("<tr><td>$(& $esc $r.Site)</td><td>$(& $esc $s.Draft)</td><td>$($s.Trunk)</td><td>$($s.Vds)</td><td><span class=`"tag $cls`">$txt</span></td><td>$($s.Blocks)</td><td><a href=`"$(& $esc $s.Report)`">readiness</a></td></tr>")
    }
}
[void]$h.Append('</table></div><h2>Notes</h2><ul><li><i>names fixed</i> adds the VLAN to a port group name that is on one VDS with different VLANs, and the cluster name in front of a name that is on more than one VDS of a datacenter (vCenter needs unique port group names in a datacenter). This changes the network names that the VMs show. A shared VDS for clusters with the same switches (V-08) is the other option. This is a design decision.</li><li>A site with nothing to convert has only switches that rule V-07 or V-10 removes (for example the iDRAC USB / BMC switch, workstream RW-09).</li><li>Run <code>toolkit\scripts\inventory\Export-PlannerPreload.ps1</code> again after a new inventory export.</li></ul></main></body></html>')
[IO.File]::WriteAllText((Join-Path $OutputFolder 'index.html'), $h.ToString(), (New-Object Text.UTF8Encoding $true))
$results | ForEach-Object { [pscustomobject]@{ Site = $_.Site; SwitchesToConvert = $_.Conv.SwitchesToConvert; Scenarios = (($_.Scen | ForEach-Object { "$($_.Done)/$($_.Vds)" }) -join ' ') } }
