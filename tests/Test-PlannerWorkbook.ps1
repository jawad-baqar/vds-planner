<#
.SYNOPSIS
Makes sure that the workbook import of the VDS Planner gives the same inventory as Export-PlannerInventory.ps1 (RW-08).

.DESCRIPTION
The script is read-only. For each workbook it:
1. Runs Export-PlannerInventory.ps1 into a temporary folder.
2. Runs the workbook part of planner\vds-planner.html (between WB-BEGIN and WB-END) with Node.js.
3. Compares the plan rows, the host rows, the existing VDS rows, the vCenter name and the hosts with no cluster.
The script writes only counts and the names of the fields that are not the same. It does not write environment data.
Node.js 18 or later must be installed. If Node.js is not installed, the script writes a warning and stops.

.PARAMETER Workbook
The inventory workbooks.

.EXAMPLE
.\tests\Test-PlannerWorkbook.ps1 -Workbook .\inventory\vc01.xlsx
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string[]] $Workbook)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { Write-Warning 'Node.js is not installed. The planner workbook test did not run.'; return }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('vdsplan-wb-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
$runner = Join-Path $tmp 'run.mjs'
[IO.File]::WriteAllText($runner, @'
import { readFileSync } from 'node:fs';
const [html, wb] = process.argv.slice(2);
const src = readFileSync(html, 'utf8');
const code = src.slice(src.indexOf('// WB-BEGIN'), src.indexOf('// WB-END'));
const f = new Function('parseCsv', code + '\nreturn { readWorkbook, convertWorkbook };')(null);
const { sheets } = await f.readWorkbook(new Uint8Array(readFileSync(wb)), 'workbook');
const r = f.convertWorkbook(sheets);
process.stdout.write(JSON.stringify({ plan: r.plan, hosts: r.hosts, existing: r.existing, standalone: r.standalone, vcenter: r.vcenter }));
'@, (New-Object Text.UTF8Encoding $false))

$planFields = 'Cluster', 'Datacenter', 'Switch', 'NewVds', 'StandardUplinks', 'DeviatingHosts', 'PortGroup', 'Vlan', 'HostsWithPortGroup', 'HostsWithSwitch', 'VdsPortGroup', 'Flags', 'Promiscuous', 'MacChanges', 'ForgedTransmits', 'LoadBalancing'
$hostFields = 'Cluster', 'Datacenter', 'Host', 'EsxVersion', 'EsxBuild', 'Switch', 'Uplinks', 'UplinkCount', 'SpeedMbps', 'Mtu'
$existFields = 'Datacenter', 'Vds', 'PortGroup', 'Vlan'
function Compare-Rows($Ps, $Js, [string[]] $Fields) {
    # returns the names of the fields that are not the same, and the count of rows that are not the same
    $bad = @{}; $rows = 0
    # an empty list arrives as $null
    $Ps = @($Ps | Where-Object { $_ }); $Js = @($Js | Where-Object { $_ })
    if (@($Ps).Count -ne @($Js).Count) { return [pscustomobject]@{ Rows = -1; Fields = 'row count' } }
    for ($i = 0; $i -lt @($Ps).Count; $i++) {
        $diff = @($Fields | Where-Object { "$(@($Ps)[$i].$_)" -cne "$(@($Js)[$i].$_)" })
        if ($diff.Count) { $rows++; $diff | ForEach-Object { $bad[$_] = 1 } }
    }
    [pscustomobject]@{ Rows = $rows; Fields = (@($bad.Keys | Sort-Object) -join ', ') }
}

$i = 0; $fail = 0
try {
    foreach ($wb in $Workbook) {
        $i++
        $out = Join-Path $tmp "wb$i"
        $c = & (Join-Path $root 'scripts\inventory\Export-PlannerInventory.ps1') -Workbook $wb -Name "wb$i" -OutputFolder $out 3>$null
        $read = { param($n) $p = Join-Path $out "wb${i}_$n.csv"; if (Test-Path $p) { @(Import-Csv $p -Encoding UTF8) } else { @() } }
        $psPlan = & $read 'vdsplan'; $psHosts = & $read 'hosts'; $psExist = & $read 'existing_vds'
        $json = & $node.Source $runner (Join-Path $root 'planner\vds-planner.html') (Resolve-Path $wb).Path
        if ($LASTEXITCODE) { throw "Node.js stopped with exit code $LASTEXITCODE." }
        $js = $json | ConvertFrom-Json
        $p = Compare-Rows $psPlan @($js.plan) $planFields
        $h = Compare-Rows $psHosts @($js.hosts) $hostFields
        $e = Compare-Rows $psExist @($js.existing) $existFields
        $same = $p.Rows -eq 0 -and $h.Rows -eq 0 -and $e.Rows -eq 0 -and "$($c.VCenter)" -eq "$($js.vcenter)" -and $c.StandaloneHosts -eq @($js.standalone).Count
        if (-not $same) { $fail++ }
        [pscustomobject]@{
            Workbook = "wb$i"; Result = $(if ($same) { 'same' } else { 'DIFFERENT' })
            PlanRows = "$(@($psPlan).Count) / $(@($js.plan).Count)"; PlanDiff = $(if ($p.Rows) { "$($p.Rows): $($p.Fields)" } else { '' })
            HostRows = "$(@($psHosts).Count) / $(@($js.hosts).Count)"; HostDiff = $(if ($h.Rows) { "$($h.Rows): $($h.Fields)" } else { '' })
            ExistingRows = "$(@($psExist).Count) / $(@($js.existing).Count)"; ExistingDiff = $(if ($e.Rows) { "$($e.Rows): $($e.Fields)" } else { '' })
        }
    }
}
finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
if ($fail) { Write-Warning "$fail workbooks do not give the same inventory." }
