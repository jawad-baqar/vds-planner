# Simulates the change of one vCenter from its VDS Planner project file, with no vCenter and no PowerCLI.
# The fake vCenter (FakeVCenter.ps1) gets the clusters, hosts, ESXi versions, standard switch uplinks and existing VDS
# of the project inventory. Then, for each VDS of the draft, in order: the plan checks (Test-VdsPlan and the planner
# rules V-05 and V-06), the preflight (Get-VdsPlanLiveFinding) and a run of Invoke-VdsPlan.ps1 against the fake vCenter.
# The result files hold environment data: write them to a folder in the environment of the data owner, not to the repository.
# -AssumeTrunkConfirmed: as if the network team confirmed the VLAN trunk of all partial port groups (V-05).
# -PortGroupFile: the <site>_portgroups.csv of the export, for the list of hosts that miss port groups.
# Output: <site>-simulation-summary.csv, <site>-simulation-findings.csv and <site>-readiness.html.
# Run: .\tests\Invoke-InventorySimulation.ps1 -ProjectFile <site>.vdsplan.json -OutputFolder <folder>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ProjectFile,
    [Parameter(Mandatory)] [string] $OutputFolder,
    [string] $Draft,
    [switch] $AssumeTrunkConfirmed,
    [string] $PortGroupFile
)
$ErrorActionPreference = 'Stop'
$Root = Join-Path $PSScriptRoot '..'
Import-Module (Join-Path $Root 'scripts\lib\VdsPlan.psm1') -Force
. (Join-Path $PSScriptRoot 'FakeVCenter.ps1')
New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
$work = Join-Path ([IO.Path]::GetTempPath()) ('vdssim-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null

$project = [IO.File]::ReadAllText((Resolve-Path $ProjectFile).Path) | ConvertFrom-Json
$d = if ($Draft) { @($project.drafts) | Where-Object name -eq $Draft } else { @($project.drafts)[0] }
if (-not $d) { throw "The project has no draft $Draft." }
$site = $project.site
$vc = if ($project.vcenter) { $project.vcenter } else { 'vcenter.simulation' }
$project.vcenter = $vc
$findings = New-Object System.Collections.ArrayList
function Add-Result([string] $Vds, [string] $Level, [string] $Stage, [string] $Text) {
    [void]$findings.Add([pscustomobject]@{ Site = $site; Vds = $Vds; Level = $Level; Stage = $Stage; Finding = $Text })
}

# fake vCenter with the inventory of the project
Reset-Fake
$global:FakeVc.Clusters = @{}; $global:FakeVc.Hosts = @{}; $global:FakeVc.Version = @{}; $global:FakeVc.SwOf = @{}; $global:FakeVc.SwNics = @{}; $global:FakeVc.Vmk = @{}; $global:FakeVc.Vds = @{}
foreach ($cp in $project.inventory.clusters.PSObject.Properties) {
    $c = $cp.Name
    foreach ($h in @($cp.Value.hosts)) {
        $global:FakeVc.Clusters[$c] = $h.Datacenter
        if (-not $global:FakeVc.Hosts.ContainsKey($c)) { $global:FakeVc.Hosts[$c] = @() }
        if ($global:FakeVc.Hosts[$c] -notcontains $h.Host) { $global:FakeVc.Hosts[$c] += $h.Host }
        if ($h.EsxVersion) { $global:FakeVc.Version[$h.Host] = $h.EsxVersion }
        if (-not $global:FakeVc.SwOf.ContainsKey($h.Host)) { $global:FakeVc.SwOf[$h.Host] = @() }
        $global:FakeVc.SwOf[$h.Host] += $h.Switch
        $global:FakeVc.SwNics["$($h.Host)|$($h.Switch)"] = @("$($h.Uplinks)" -split '\s+' | Where-Object { $_ })
        $global:FakeVc.Vmk[$h.Host] = New-Object System.Collections.ArrayList
    }
}
foreach ($g in (@($project.inventory.existing) | Where-Object { $_ } | Group-Object Vds)) {
    $v = New-FakeVds $g.Name "$($g.Group[0].Datacenter)" 2
    foreach ($e in $g.Group) { New-FakePg $v $e.PortGroup | Out-Null }
}
$global:DefaultVIServers = @([pscustomobject]@{ Name = $vc })

# plan checks: the same rules as the commit in the planner
$run = ConvertTo-VdsPlanRun -Project $project -Draft $d
$planObj = ($run | ConvertTo-Json -Depth 30) | ConvertFrom-Json
$planErr = @(Test-VdsPlan -Plan $planObj | Where-Object { $_ -ne 'The plan has no VDS.' })
if (-not @($planObj.vds).Count) { Add-Result '(none)' 'Info' 'Plan' 'The draft has no VDS. The vCenter has no standard switch to convert (rules V-07 and V-10).' }
$names = @($planObj.vds.name) | Sort-Object Length -Descending
$blockedByPlan = @{}
foreach ($e in $planErr) {
    $n = $names | Where-Object { $e.StartsWith("${_}:") -or $e.StartsWith("$_ /") -or $e -match [regex]::Escape("'$_'") } | Select-Object -First 1
    if (-not $n) { $n = '(plan)' }
    Add-Result $n 'Block' 'Plan' $e; $blockedByPlan[$n] = 1
}
foreach ($v in @($d.vds)) {
    $part = @($v.portGroups | Where-Object { $_.include -and $_.partial -and -not $_.trunkConfirmed })
    if ($part.Count -and $AssumeTrunkConfirmed) { Add-Result $v.name 'Info' 'Plan' "$($v.name): $($part.Count) port groups are not on all hosts. The simulation assumes that the network team confirmed the VLAN trunk (V-05)." }
    elseif ($part.Count) {
        foreach ($p in $part) { Add-Result $v.name 'Block' 'Plan' "$($v.name) / $($p.name): the port group is not on all hosts. Confirm the VLAN trunk on all hosts first (V-05)." }
        $blockedByPlan[$v.name] = 1
    }
    foreach ($m in @($v.members | Where-Object { $_.deviating })) { Add-Result $v.name 'Warn' 'Plan' "$($v.name): hosts with a different uplink layout: $($m.deviating) (V-06)." }
}

# the simulated run uses the plan checks as the planner does, but goes on: a VDS that the plan blocks is not run
$okVds = @($planObj.vds | Where-Object { -not $blockedByPlan.ContainsKey($_.name) })
$planObj.vds = $okVds
$planFile = Join-Path $work 'plan-simulation-v1.json'
[IO.File]::WriteAllText($planFile, ($planObj | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding $false))
[IO.File]::WriteAllText("$planFile.sha256", "$(Get-VdsPlanHash -Path $planFile)  plan-simulation-v1.json`n")
$runner = Join-Path $Root 'scripts\network\Invoke-VdsPlan.ps1'
$summary = foreach ($v in @($d.vds)) {
    $st = 'Ready'; $made = ''
    if ($blockedByPlan.ContainsKey($v.name)) { $st = 'Blocked by the plan checks' }
    else {
        $pv = $okVds | Where-Object name -eq $v.name
        $live = @(Get-VdsPlanLiveFinding -Plan $planObj -Vds $pv)
        foreach ($f in $live) { Add-Result $v.name $f.Level 'Preflight' "$($f.Object): $($f.Finding)" }
        if ($live | Where-Object Level -eq 'Block') { $st = 'Blocked by the preflight' }
        else {
            $global:Calls.Clear()
            try { & $runner -PlanFile $planFile -VdsName $v.name -OutputFolder (Join-Path $work 'output') -Confirm:$false *>&1 | Out-Null }
            catch { $st = 'Run stopped'; Add-Result $v.name 'Block' 'Run' $_.Exception.Message }
            $made = '{0} VDS, {1} port groups, {2} hosts added' -f @($global:Calls | Where-Object Cmd -eq 'New-VDSwitch').Count, @($global:Calls | Where-Object Cmd -eq 'New-VDPortgroup').Count, (@($global:Calls | Where-Object Cmd -eq 'Add-VDSwitchVMHost' | ForEach-Object { @($_.P.VMHost) }) | Measure-Object).Count
            if ($st -eq 'Ready') { $st = 'Simulated run done' }
        }
    }
    [pscustomobject]@{ Site = $site; Vds = $v.name; Clusters = (@($v.members.cluster) -join ' '); Switch = $v.members[0].sourceSwitch; Uplinks = $v.uplinkCount
        PortGroups = @($v.portGroups | Where-Object include).Count; Partial = @($v.portGroups | Where-Object { $_.include -and $_.partial }).Count; Status = $st; Simulated = $made
        Blocks = @($findings | Where-Object { $_.Vds -eq $v.name -and $_.Level -eq 'Block' }).Count; Warnings = @($findings | Where-Object { $_.Vds -eq $v.name -and $_.Level -eq 'Warn' }).Count }
}
$summary = @($summary)
$sfx = $(if ($d.name -match 'names fixed') { '-names-fixed' } else { '' }) + $(if ($AssumeTrunkConfirmed) { '-trunk-confirmed' } else { '' })
$summary | Export-Csv (Join-Path $OutputFolder "$site-simulation-summary$sfx.csv") -NoTypeInformation -Encoding UTF8
$findings | Export-Csv (Join-Path $OutputFolder "$site-simulation-findings$sfx.csv") -NoTypeInformation -Encoding UTF8
# readiness report (HTML) for the design team
$esc = { param($t) [System.Net.WebUtility]::HtmlEncode("$t") }
$cat = { param($t)
    if ($t -match 'V-05') { 'V-05: port group not on all hosts of the cluster' } elseif ($t -match 'more than one time') { 'Same port group name with different VLANs on one VDS' }
    elseif ($t -match 'V-02') { 'V-02: fewer than two uplinks' } elseif ($t -match 'unique in a datacenter') { 'Port group name in use on another VDS in the datacenter' }
    elseif ($t -match 'V-06') { 'V-06: hosts with a different uplink layout' } elseif ($t -match 'ESXi') { 'ESXi version earlier than the VDS version' }
    elseif ($t -match 'not connected|state is') { 'Host not connected' } elseif ($t -match 'exists') { 'Object exists in the vCenter (not changed)' } else { 'Other' } }
$byCat = @($findings | ForEach-Object { [pscustomobject]@{ Level = $_.Level; Cat = (& $cat $_.Finding) } } | Group-Object Level, Cat | Sort-Object Count -Descending)
$dups = @(foreach ($v in @($d.vds)) {
        foreach ($g in (@($v.portGroups | Where-Object include) | Group-Object name | Where-Object Count -gt 1)) {
            [pscustomobject]@{ Vds = $v.name; PortGroup = $g.Name; Vlans = (($g.Group | ForEach-Object { if ($_.vlanType -eq 'trunk') { 'trunk' } else { $_.vlan } }) -join ', ') } } })
$clash = @($findings | Where-Object { $_.Finding -match 'unique in a datacenter' })
$gaps = @()
if ($PortGroupFile -and (Test-Path $PortGroupFile)) {
    $rows = Import-Csv $PortGroupFile -Encoding UTF8
    foreach ($g in ($rows | Group-Object Cluster, Switch)) {
        $all = @($g.Group.PortGroup | Sort-Object -Unique).Count
        foreach ($h in ($g.Group | Group-Object Host)) {
            $miss = $all - @($h.Group.PortGroup | Sort-Object -Unique).Count
            if ($miss -gt 0) { $gaps += [pscustomobject]@{ Cluster = $g.Group[0].Cluster; Switch = $g.Group[0].Switch; Host = $h.Name; Has = $all - $miss; Of = $all; Missing = $miss } }
        }
    }
    $gaps = @($gaps | Sort-Object Missing -Descending)
}
$tag = { param($s) switch -Wildcard ($s) { 'Simulated*' { 't-ok' } 'Blocked*' { 't-bad' } 'Run stopped' { 't-bad' } default { 't-warn' } } }
$css = ':root{--ink:#1b1c1e;--muted:#62656b;--line:#d7d9dd;--soft:#eef0f2;--ok:#2e7d4f;--okb:#e2f2e8;--warn:#9a6a00;--warnb:#fbf0d4;--bad:#a63a32;--badb:#f8e3e1;--acc:#2f5d8a;--accb:#e3ecf5}' +
    '@media (prefers-color-scheme:dark){:root{--ink:#e7e8ea;--muted:#9a9ea6;--line:#363a41;--soft:#2a2d33;--ok:#6cc495;--okb:#1d3428;--warn:#e0b450;--warnb:#3a3018;--bad:#ec8a80;--badb:#3d2220;--acc:#7fb0e0;--accb:#22344a}body{background:#16171a}}' +
    'body{font:14px/1.55 system-ui,"Segoe UI",sans-serif;color:var(--ink);margin:0;padding:24px 16px}main{max-width:1100px;margin:0 auto}h1{font-size:23px;margin:0 0 4px}h2{font-size:17px;margin:26px 0 8px;border-top:1px solid var(--line);padding-top:10px}' +
    '.m{color:var(--muted)}.tbl{overflow-x:auto;border:1px solid var(--line);border-radius:8px}table{border-collapse:collapse;width:100%;font-size:13px}th,td{text-align:left;padding:5px 9px;border-bottom:1px solid var(--line);vertical-align:top}th{background:var(--soft)}' +
    '.tag{font:11px/1.6 ui-monospace,Consolas,monospace;padding:0 7px;border-radius:10px;border:1px solid currentColor;white-space:nowrap}.t-ok{color:var(--ok);background:var(--okb)}.t-warn{color:var(--warn);background:var(--warnb)}.t-bad{color:var(--bad);background:var(--badb)}.t-info{color:var(--acc);background:var(--accb)}' +
    '.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin:12px 0}.stat{border:1px solid var(--line);border-radius:8px;padding:8px 12px}.stat b{display:block;font-size:21px}.stat span{color:var(--muted);font-size:12px}' +
    'ol li{margin:3px 0}@media print{.tbl{break-inside:avoid}}'
$h = New-Object System.Text.StringBuilder
[void]$h.Append("<!doctype html><html lang=`"en`"><head><meta charset=`"utf-8`"><meta name=`"viewport`" content=`"width=device-width, initial-scale=1`"><title>$(& $esc $site) readiness</title><style>$css</style></head><body><main>")
$sfxDraft = ($d.name -replace '[^\w]+', '-').Trim('-').ToLower()
[void]$h.Append("<h1>$(& $esc $site): VDS readiness</h1><p class=`"m`">RW-08 · simulation of draft $(& $esc $d.name) against the inventory of the vCenter, with no connection to the vCenter$(if ($AssumeTrunkConfirmed) { ' · assumes that the VLAN trunk check (V-05) is confirmed' }).</p>")
$stat = @(@($summary.Count, 'VDS in the draft'), @(@($summary | Where-Object Status -eq 'Simulated run done').Count, 'simulated run done'), @(@($summary | Where-Object Status -like 'Blocked*').Count, 'blocked'), @(($summary | Measure-Object PortGroups -Sum).Sum, 'port groups'), @(($summary | Measure-Object Partial -Sum).Sum, 'not on all hosts (V-05)'), @($dups.Count, 'duplicate names'))
[void]$h.Append('<div class="stats">' + (($stat | ForEach-Object { "<div class=`"stat`"><b>$($_[0])</b><span>$($_[1])</span></div>" }) -join '') + '</div>')
[void]$h.Append('<h2>Next actions</h2><ol>')
if (($summary | Measure-Object Partial -Sum).Sum -and -not $AssumeTrunkConfirmed) { [void]$h.Append('<li>Network team: confirm the VLAN trunk on the uplinks of all hosts for the port groups that are not on all hosts (V-05). Then set the trunk check on each VDS in the planner. The host table below shows the hosts that miss the most port groups.</li>') }
if ($dups.Count) { [void]$h.Append('<li>Correct the port groups that have the same name and different VLANs on hosts of one cluster. Use one VLAN, or give one of them a new name in the planner.</li>') }
if ($clash.Count) { [void]$h.Append('<li>Rename the port groups whose names are in use on another VDS in the datacenter (Add a name prefix on the VDS).</li>') }
if ($findings | Where-Object { $_.Finding -match 'V-02' }) { [void]$h.Append('<li>Add a second uplink to the standard switches with one uplink (V-02), or keep them out of the plan.</li>') }
if ($findings | Where-Object { $_.Finding -match 'V-06' }) { [void]$h.Append('<li>Correct the uplinks of the hosts with a different layout before the migration (V-06).</li>') }
[void]$h.Append('<li>Set the security zone of each cluster in the planner. Examine the VDS names and the port group settings. Commit, then run the package with -Part Check in the change window preparation.</li></ol>')
[void]$h.Append('<h2>VDS</h2><div class="tbl"><table><tr><th>VDS</th><th>Cluster</th><th>Switch</th><th>Uplinks</th><th>Port groups</th><th>V-05</th><th>Status</th><th>Blocking</th><th>Warnings</th><th>Simulated run</th></tr>')
foreach ($r in $summary) { [void]$h.Append("<tr><td>$(& $esc $r.Vds)</td><td>$(& $esc $r.Clusters)</td><td>$(& $esc $r.Switch)</td><td>$($r.Uplinks)</td><td>$($r.PortGroups)</td><td>$($r.Partial)</td><td><span class=`"tag $(& $tag $r.Status)`">$(& $esc $r.Status)</span></td><td>$($r.Blocks)</td><td>$($r.Warnings)</td><td>$(& $esc $r.Simulated)</td></tr>") }
[void]$h.Append('</table></div><h2>Findings by rule</h2><div class="tbl"><table><tr><th>Level</th><th>Finding</th><th>Count</th></tr>')
foreach ($g in $byCat) { $lv, $ct = $g.Name -split ', ', 2; $cls = @{ Block = 't-bad'; Warn = 't-warn'; Info = 't-info' }[$lv]; [void]$h.Append("<tr><td><span class=`"tag $cls`">$lv</span></td><td>$(& $esc $ct)</td><td>$($g.Count)</td></tr>") }
[void]$h.Append('</table></div>')
if ($dups.Count) { [void]$h.Append('<h2>Same name, different VLANs</h2><div class="tbl"><table><tr><th>VDS</th><th>Port group</th><th>VLANs on the hosts</th></tr>' + (($dups | ForEach-Object { "<tr><td>$(& $esc $_.Vds)</td><td>$(& $esc $_.PortGroup)</td><td>$(& $esc $_.Vlans)</td></tr>" }) -join '') + '</table></div>') }
if ($clash.Count) { [void]$h.Append('<h2>Names in use on another VDS</h2><div class="tbl"><table><tr><th>VDS</th><th>Finding</th></tr>' + (($clash | ForEach-Object { "<tr><td>$(& $esc $_.Vds)</td><td>$(& $esc $_.Finding)</td></tr>" }) -join '') + '</table></div>') }
if ($gaps.Count) {
    [void]$h.Append("<h2>Hosts that miss port groups (V-05)</h2><p class=`"m`">$($gaps.Count) hosts do not have all port groups of their cluster switch. The first 40 are below. A host that misses many port groups is often the cause of many V-05 items.</p>")
    [void]$h.Append('<div class="tbl"><table><tr><th>Cluster</th><th>Switch</th><th>Host</th><th>Port groups</th><th>Missing</th></tr>' + (($gaps | Select-Object -First 40 | ForEach-Object { "<tr><td>$(& $esc $_.Cluster)</td><td>$(& $esc $_.Switch)</td><td>$(& $esc $_.Host)</td><td>$($_.Has) of $($_.Of)</td><td>$($_.Missing)</td></tr>" }) -join '') + '</table></div>')
}
$other = @($findings | Where-Object { $_.Level -ne 'Info' -and $_.Finding -notmatch 'V-05' } | Select-Object -First 200)
if ($other.Count) { [void]$h.Append('<h2>Other findings</h2><div class="tbl"><table><tr><th>VDS</th><th>Level</th><th>Stage</th><th>Finding</th></tr>' + (($other | ForEach-Object { "<tr><td>$(& $esc $_.Vds)</td><td>$($_.Level)</td><td>$($_.Stage)</td><td>$(& $esc $_.Finding)</td></tr>" }) -join '') + '</table></div>') }
[void]$h.Append('<p class="m">All findings are in the CSV file next to this report.</p></main></body></html>')
$suffix = $sfx
[IO.File]::WriteAllText((Join-Path $OutputFolder "$site-readiness$suffix.html"), $h.ToString(), (New-Object Text.UTF8Encoding $true))

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
[pscustomobject]@{ Site = $site; Vds = $summary.Count; SimulatedRunDone = @($summary | Where-Object Status -eq 'Simulated run done').Count
    BlockedByPlan = @($summary | Where-Object Status -eq 'Blocked by the plan checks').Count; BlockedByPreflight = @($summary | Where-Object Status -eq 'Blocked by the preflight').Count
    RunStopped = @($summary | Where-Object Status -eq 'Run stopped').Count; Blocks = @($findings | Where-Object Level -eq 'Block').Count; Warnings = @($findings | Where-Object Level -eq 'Warn').Count }
