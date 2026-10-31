# Offline tests of the toolkit. Needs no vCenter, no PowerCLI and no Pester. Run: .\tests\Invoke-OfflineTests.ps1
# Part 1 checks the scripts (parse, help, -WhatIf). Part 2 checks the plan file checks.
# The fake vCenter state is $global:FakeVc (not a short name: the scripts have variables like $f, and names are not case-sensitive).
# Part 3 runs the scripts against recording stubs of the PowerCLI commands (a small fake vCenter)
# and checks each command and parameter that the scripts send.
[CmdletBinding()]
param([string] $Root)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path $PSScriptRoot '..' }
$Root = (Resolve-Path $Root).Path
$script:pass = 0; $script:fail = 0
function Check([string] $Name, [scriptblock] $Test) {
    try { $r = & $Test } catch { $r = $false; $Name += " ($($_.Exception.Message))" }
    if ($r) { $script:pass++; Write-Output "PASS $Name" }
    else {
        $script:fail++; Write-Output "FAIL $Name"
        # show the last calls to the fake vCenter and the last script output
        if ($global:Calls) { $global:Calls | Select-Object -Last 8 | ForEach-Object { $c = $_; "     call $($c.Cmd) " + (($c.P.Keys | Sort-Object | ForEach-Object { "$_=$(@($c.P[$_]) -join '+')" }) -join ' ') } }
        if ($script:o) { "     output: " + (($script:o -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 6) -join ' / ') }
    }
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('vdstk-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null

# ---------- part 1: static checks ----------
$all = @(Get-ChildItem "$Root\scripts" -Recurse -Include *.ps1, *.psm1) + @(Get-ChildItem "$Root\samples\demo-package" -Filter *.ps1)
foreach ($f in $all) {
    $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$err)
    Check "parse $($f.Name)" { -not $err }
    $help = [regex]::Match((Get-Content $f.FullName -Raw), '(?s)<#.*?#>').Value
    Check "help has no semicolon: $($f.Name)" { $help -notmatch ';' }
    if ($f.Extension -eq '.ps1') {
        $text = Get-Content $f.FullName -Raw
        if ($f.BaseName -notmatch '^(Get|Export)-') { Check "supports -WhatIf: $($f.Name)" { $text -match 'SupportsShouldProcess' } }
        else { Check "read-only script has no ShouldProcess: $($f.Name)" { $text -notmatch 'SupportsShouldProcess' } }
        # PowerShell 5.1 gives an empty $PSScriptRoot to a param() default under powershell.exe -File
        Check "no PSScriptRoot in a param() default: $($f.Name)" { -not ($ast.ParamBlock -and ($ast.ParamBlock.Parameters | Where-Object { $_.DefaultValue -and $_.DefaultValue.Extent.Text -match 'PSScriptRoot' })) }
    }
}

# ---------- part 2: plan file checks ----------
Import-Module "$Root\scripts\lib\VdsPlan.psm1" -Force
$demo = "$Root\samples\demo-package\plan-shared-db-vds-v1.json"
$sample = "$Root\samples\plan-cluster01-v1.sample.json"
function Get-Demo { Get-Content $demo -Raw | ConvertFrom-Json }
function Save-Plan($Plan, [string] $Name) {
    $p = Join-Path $tmp $Name
    [IO.File]::WriteAllText($p, ($Plan | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $false))
    [IO.File]::WriteAllText("$p.sha256", "$(Get-VdsPlanHash -Path $p)  $Name`n")
    $p
}
Check 'sample plan is valid' { -not @(Test-VdsPlan -Plan (Get-Content $sample -Raw | ConvertFrom-Json)).Count }
Check 'demo plan reads with a correct hash' { (Get-VdsPlan -Path $demo).vds[0].shared }
Check 'commit time stays ISO text (PowerShell 7 makes a date of it)' { $c = (Get-VdsPlan -Path $demo).committedAt; $c -is [string] -and $c -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d' }
$cases = @(
    @{ n = 'one uplink (V-02)'; f = { param($p) $p.vds[0].uplinkCount = 1 }; m = 'V-02' }
    @{ n = 'two clusters, no V-08 pass'; f = { param($p) $p.vds[0].v08Check = 'fail' }; m = 'V-08' }
    @{ n = 'two clusters, V-08 accepted with no accepted difference'; f = { param($p) $p.vds[0].v08Check = 'accepted' }; m = 'V-08' }
    @{ n = 'uplink not on the VDS'; f = { param($p) $p.vds[0].portGroups[0].active = @('dvUplink3') }; m = 'not on the VDS' }
    @{ n = 'trunk above 4094'; f = { param($p) $p.vds[0].portGroups[0].vlanType = 'trunk'; $p.vds[0].portGroups[0].trunk = '0-4095' }; m = 'trunk range' }
    @{ n = 'static port group with 0 ports'; f = { param($p) $p.vds[0].portGroups[0].ports = 0 }; m = 'number of ports' }
    @{ n = 'same port group name two times'; f = { param($p) $p.vds[0].portGroups[1].name = $p.vds[0].portGroups[0].name }; m = 'more than one time' }
    @{ n = 'members not the clusters'; f = { param($p) $p.vds[0].members[1].cluster = 'X' }; m = 'members are not the same' }
    @{ n = 'VMkernel port group not on the VDS'; f = { param($p) $p.vds[0].vmkernel[0].portGroup = 'X' }; m = 'port group is not on the VDS' }
    @{ n = 'vMotion stack for another service'; f = { param($p) $p.vds[0].vmkernel[0].service = 'vSAN' }; m = 'stack is for vMotion only' }
    @{ n = 'VMkernel MTU above the VDS MTU'; f = { param($p) $p.vds[0].mtu = 1500 }; m = 'not more than the VDS MTU' }
    @{ n = 'IP address not valid'; f = { param($p) $p.vds[0].vmkernel[0].hosts[0].ip = '10.0.20.300' }; m = 'no valid IP' }
    @{ n = 'subnet mask not valid'; f = { param($p) $p.vds[0].vmkernel[0].hosts[0].mask = '255.0.255.0' }; m = 'no valid subnet mask' }
    @{ n = 'same IP address two times'; f = { param($p) $p.vds[0].vmkernel[0].hosts[1].ip = $p.vds[0].vmkernel[0].hosts[0].ip }; m = 'used more than one time' }
    @{ n = 'VDS version not 8.0.x'; f = { param($p) $p.vds[0].version = '7.0.3' }; m = 'V-09' }
)
foreach ($c in $cases) {
    $p = Get-Demo; & $c.f $p
    Check "Test-VdsPlan stops: $($c.n)" { ((Test-VdsPlan -Plan $p) -join ' ') -match [regex]::Escape($c.m) }
}
$p = Get-Demo; $p.vds[0].v08Check = 'accepted'; $p.vds[0] | Add-Member -Force v08Accepted @('The NIC speeds are different (10000, 25000 Mbps).')
Check 'Test-VdsPlan passes a VDS for two clusters with accepted differences (V-08)' { -not @(Test-VdsPlan -Plan $p | Where-Object { $_ -match 'V-08' }).Count }
# a plan committed with the earlier format identifier (a prefix before vdsplan) stays valid
$lp = Join-Path $tmp 'legacy.json'
[IO.File]::WriteAllText($lp, ([IO.File]::ReadAllText($demo) -replace '"format": "vdsplan-run/1"', '"format": "x-vdsplan-run/1"'), (New-Object Text.UTF8Encoding $false))
[IO.File]::WriteAllText("$lp.sha256", (Get-VdsPlanHash -Path $lp) + "  legacy.json`n", (New-Object Text.UTF8Encoding $false))
Check 'Get-VdsPlan reads a plan with the earlier format identifier' { $l = Get-VdsPlan -Path $lp; $l.format -eq 'x-vdsplan-run/1' -and -not @(Test-VdsPlan -Plan $l).Count }
Check 'Test-VdsPlan refuses an unknown format' { $p = Get-Demo; $p.format = 'other-plan/1'; ((Test-VdsPlan -Plan $p) -join ' ') -match 'Unknown plan format' }
$t = Join-Path $tmp 'tampered.json'; Copy-Item $demo $t; Copy-Item "$demo.sha256" "$t.sha256"; Add-Content $t ' '
Check 'Get-VdsPlan stops a changed plan file' { try { Get-VdsPlan -Path $t | Out-Null; $false } catch { $_.Exception.Message -match 'changed after the commit' } }
Remove-Item "$t.sha256"
Check 'Get-VdsPlan stops when the hash file is missing' { try { Get-VdsPlan -Path $t | Out-Null; $false } catch { $_.Exception.Message -match 'hash file' } }

# ---------- part 3: scripts against a fake vCenter ----------
. (Join-Path $PSScriptRoot 'FakeVCenter.ps1')

$runner = "$Root\scripts\network\Invoke-VdsPlan.ps1"
$pre = "$Root\scripts\network\Get-VdsPlanPreflight.ps1"
$remove = "$Root\scripts\network\Remove-VdsPlanSwitch.ps1"
$out = Join-Path $tmp 'output'
$changing = 'New-VDSwitch', 'New-VDPortgroup', 'Set-VDUplinkTeamingPolicy', 'Set-VDSecurityPolicy', 'Add-VDSwitchVMHost', 'New-VMHostNetworkAdapter', 'Set-VMHostNetworkAdapter', 'SelectVnicForNicType', 'ReconfigureDVPortgroup', 'Remove-VDSwitch'
# use @(Of ...) for a count: a single pscustomobject has no Count in PowerShell 5.1
function Changes { $global:Calls | Where-Object { $changing -contains $_.Cmd } }
function Of([string] $Cmd) { $global:Calls | Where-Object Cmd -eq $Cmd }
function Run([scriptblock] $Block) {
    # keep the output that comes before an error
    $buf = New-Object System.Collections.ArrayList
    try { & $Block *>&1 | ForEach-Object { [void]$buf.Add(($_ | Out-String)) } } catch { [void]$buf.Add("THROW: $($_.Exception.Message) AT $(($_.ScriptStackTrace -split "`n")[0])") }
    $buf -join "`n"
}
$vds = 'DB-shared-vds01'

Reset-Fake
$o = Run { & $runner -PlanFile $demo -VdsName $vds -OutputFolder $out -WhatIf }
Check 'Switch -WhatIf: no change' { @(Changes).Count -eq 0 -and $o -notmatch 'THROW' }
Check 'Switch -WhatIf: transcript in the output folder' { @(Get-ChildItem $out -Filter 'Invoke-VdsPlan_Switch_*transcript.txt').Count -ge 1 }

Reset-Fake
$o = Run { & $runner -PlanFile $demo -VdsName $vds -OutputFolder $out -Confirm:$false }
$nv = @(Of 'New-VDSwitch')
Check 'Switch: VDS created with version, uplinks, MTU, LLDP both, datacenter' { $nv.Count -eq 1 -and $nv[0].P.Version -eq '8.0.3' -and $nv[0].P.NumUplinkPorts -eq 2 -and $nv[0].P.Mtu -eq 9000 -and "$($nv[0].P.LinkDiscoveryProtocol)" -eq 'LLDP' -and "$($nv[0].P.LinkDiscoveryProtocolOperation)" -eq 'Both' -and $nv[0].P.Location.Name -eq 'DC-A' }
$np = @(Of 'New-VDPortgroup')
Check 'Switch: 5 port groups created' { $np.Count -eq 5 }
$eph = $np | Where-Object { $_.P.Name -eq 'vcenter-ephemeral' }
Check 'Switch: ephemeral port group has no port count' { "$($eph.P.PortBinding)" -eq 'Ephemeral' -and -not $eph.P.ContainsKey('NumPorts') -and $eph.P.VlanId -eq 10 }
$db = $np | Where-Object { $_.P.Name -eq 'DB-Prod' }
Check 'Switch: static port group with 128 ports and VLAN 210' { "$($db.P.PortBinding)" -eq 'Static' -and $db.P.NumPorts -eq 128 -and $db.P.VlanId -eq 210 }
Check 'Switch: elastic allocation set on the 4 static port groups only' { $r = @(Of 'ReconfigureDVPortgroup'); $r.Count -eq 4 -and -not ($r | Where-Object { $_.P.AutoExpand -ne $true }) }
$tm = @(Of 'Set-VDUplinkTeamingPolicy') | Where-Object { $_.P.Pg -eq 'DB-shared-vds01-vmotion' }
Check 'Switch: vMotion port group explicit failover, dvUplink1 active, dvUplink2 standby' { "$($tm.P.LoadBalancingPolicy)" -eq 'ExplicitFailover' -and (@($tm.P.ActiveUplinkPort) -join ',') -eq 'dvUplink1' -and (@($tm.P.StandbyUplinkPort) -join ',') -eq 'dvUplink2' -and -not $tm.P.ContainsKey('UnusedUplinkPort') }
Check 'Switch: security set to Reject on all port groups' { $s = @(Of 'Set-VDSecurityPolicy'); $s.Count -eq 5 -and -not ($s | Where-Object { $_.P.AllowPromiscuous -or $_.P.MacChanges -or $_.P.ForgedTransmits }) }
Check 'Switch: hosts of both clusters added with no uplink' { $a = @(Of 'Add-VDSwitchVMHost'); $a.Count -eq 2 -and ((@($a.P.VMHost | ForEach-Object { $_ }) | Sort-Object) -join ',') -eq 'esx11.example.local,esx12.example.local,esx13.example.local,esx21.example.local,esx22.example.local,esx23.example.local' }
Check 'Switch: CSV log written' { @(Get-ChildItem $out -Filter 'Invoke-VdsPlan_Switch_*.csv').Count -ge 1 }

$global:Calls.Clear()
$o = Run { & $runner -PlanFile $demo -VdsName $vds -OutputFolder $out -Confirm:$false }
Check 'Switch run again: nothing changes (idempotent)' { @(Changes).Count -eq 0 -and $o -match 'Exists, not changed' }

Reset-Fake; $global:FakeVc.Version['esx22.example.local'] = '8.0.2'; $global:FakeVc.SwNics['esx13.example.local'] = @('vmnic0')
$o = Run { & $runner -PlanFile $demo -VdsName $vds -OutputFolder $out -Confirm:$false }
Check 'Block: ESXi 8.0.2 host stops the run before any change' { @(Changes).Count -eq 0 -and $o -match 'blocking findings' -and $o -match 'ESXi 8.0.2' }
Check 'Warn: host with a different uplink layout (V-06)' { $o -match 'esx13.*V-06' }

Reset-Fake; $global:FakeVc.State['esx12.example.local'] = 'NotResponding'
$o = Run { & $runner -PlanFile $demo -VdsName $vds -OutputFolder $out -Confirm:$false }
Check 'Block: host not connected' { @(Changes).Count -eq 0 -and $o -match 'NotResponding' }

Reset-Fake; $other = New-FakeVds 'Cluster01-vds01' 'DC-A' 2; New-FakePg $other 'Backup' | Out-Null
$o = Run { & $runner -PlanFile $demo -VdsName $vds -OutputFolder $out -Confirm:$false }
Check 'Block: port group name on another VDS in the same datacenter' { @(Changes).Count -eq 0 -and $o -match 'Backup' -and $o -match 'unique in a datacenter' }
Reset-Fake; $other = New-FakeVds 'Cluster09-vds01' 'DC-B' 2; New-FakePg $other 'Backup' | Out-Null
$o = Run { & $runner -PlanFile $demo -VdsName $vds -OutputFolder $out -Confirm:$false }
Check 'Same port group name in another datacenter is permitted' { @(Of 'New-VDSwitch').Count -eq 1 }

Reset-Fake; New-FakeVds $vds 'DC-A' 4 | Out-Null
$o = Run { & $runner -PlanFile $demo -VdsName $vds -OutputFolder $out -Confirm:$false }
Check 'Block: VDS exists with a different number of uplinks' { @(Changes).Count -eq 0 -and $o -match 'exists with 4 uplinks' }

Reset-Fake; $global:FakeVc.Clusters.Remove('Cluster04')
$o = Run { & $runner -PlanFile $demo -VdsName $vds -OutputFolder $out -Confirm:$false }
Check 'Block: cluster not in the vCenter' { @(Changes).Count -eq 0 -and $o -match 'Cluster04' }

Reset-Fake; $global:FakeVc.Clusters['Cluster04'] = 'DC-B'
$o = Run { & $runner -PlanFile $demo -VdsName $vds -OutputFolder $out -Confirm:$false }
Check 'Block: clusters in two datacenters' { @(Changes).Count -eq 0 -and $o -match 'more than one datacenter' }

Reset-Fake; $global:DefaultVIServers = @([pscustomobject]@{ Name = 'vc99.example.local' })
$o = Run { & $runner -PlanFile $demo -VdsName $vds -OutputFolder $out -Confirm:$false }
Check 'Stop: connected to a different vCenter' { @(Changes).Count -eq 0 -and $o -match 'Connect to vc01.example.local' }

Reset-Fake
$o = Run { & $runner -PlanFile $demo -VdsName 'nothing' -OutputFolder $out -Confirm:$false }
Check 'Stop: VDS not in the plan' { $o -match 'The plan has no VDS nothing' }

# VMkernel part
Reset-Fake
Run { & $runner -PlanFile $demo -VdsName $vds -OutputFolder $out -Confirm:$false } | Out-Null
$global:Calls.Clear()
$o = Run { & $runner -PlanFile $demo -VdsName $vds -Part VMkernel -VMHost esx12.example.local -OutputFolder $out -Confirm:$false }
Check 'VMkernel: stops when the host has no uplink on the VDS' { @(Changes).Count -eq 0 -and $o -match 'no uplink' }
$o = Run { & $runner -PlanFile $demo -VdsName $vds -Part VMkernel -OutputFolder $out -Confirm:$false }
Check 'VMkernel: -VMHost is necessary' { $o -match 'Use -VMHost' }
$global:FakeVc.Uplinks['esx12.example.local'] = @('vmnic0', 'vmnic1')
$o = Run { & $runner -PlanFile $demo -VdsName $vds -Part VMkernel -VMHost esx12.example.local -OutputFolder $out -WhatIf }
Check 'VMkernel -WhatIf: no change' { @(Changes).Count -eq 0 -and $o -notmatch 'THROW' }
$o = Run { & $runner -PlanFile $demo -VdsName $vds -Part VMkernel -VMHost esx12.example.local -OutputFolder $out -Confirm:$false }
$na = @(Of 'New-VMHostNetworkAdapter')
Check 'VMkernel: adapter on the vMotion stack with IP, mask, MTU and port group' { $na.Count -eq 1 -and $na[0].P.NetworkStack -eq 'vmotion' -and $na[0].P.IP -eq '10.0.20.12' -and $na[0].P.SubnetMask -eq '255.255.255.0' -and $na[0].P.Mtu -eq 9000 -and $na[0].P.PortGroup -eq 'DB-shared-vds01-vmotion' -and -not $na[0].P.ContainsKey('VMotionEnabled') }
Check 'VMkernel: vMotion turned off on vmk0' { $s = @(Of 'Set-VMHostNetworkAdapter'); $s.Count -eq 1 -and $s[0].P.VirtualNic -eq 'vmk0' -and $s[0].P.VMotionEnabled -eq $false }
$global:Calls.Clear()
$o = Run { & $runner -PlanFile $demo -VdsName $vds -Part VMkernel -VMHost esx12.example.local -OutputFolder $out -Confirm:$false }
Check 'VMkernel run again: nothing changes' { @(Changes).Count -eq 0 -and $o -match 'Exists, not changed' }

# Provisioning on the default stack, vSAN service
$p = Get-Demo; $p.vds[0].vmkernel[0].service = 'Provisioning'; $p.vds[0].vmkernel[0].stack = 'defaultTcpipStack'
$p.vds[0].vmkernel[0].hosts = @($p.vds[0].vmkernel[0].hosts[0]); $prov = Save-Plan $p 'prov.json'
Reset-Fake; Run { & $runner -PlanFile $prov -VdsName $vds -OutputFolder $out -Confirm:$false } | Out-Null
$global:FakeVc.Uplinks['esx11.example.local'] = @('vmnic0'); $global:Calls.Clear()
Run { & $runner -PlanFile $prov -VdsName $vds -Part VMkernel -VMHost esx11.example.local -OutputFolder $out -Confirm:$false } | Out-Null
Check 'VMkernel: Provisioning on the default stack is tagged with the API' { $s = @(Of 'SelectVnicForNicType'); $s.Count -eq 1 -and $s[0].P.NicType -eq 'vSphereProvisioning' -and -not @(Of 'New-VMHostNetworkAdapter')[0].P.NetworkStack }
$p.vds[0].vmkernel[0].service = 'vSAN'; $vsan = Save-Plan $p 'vsan.json'
Reset-Fake; Run { & $runner -PlanFile $vsan -VdsName $vds -OutputFolder $out -Confirm:$false } | Out-Null
$global:FakeVc.Uplinks['esx11.example.local'] = @('vmnic0'); $global:Calls.Clear()
Run { & $runner -PlanFile $vsan -VdsName $vds -Part VMkernel -VMHost esx11.example.local -OutputFolder $out -Confirm:$false } | Out-Null
Check 'VMkernel: vSAN uses VsanTrafficEnabled' { $n = @(Of 'New-VMHostNetworkAdapter'); $n.Count -eq 1 -and $n[0].P.VsanTrafficEnabled -eq $true -and @(Of 'SelectVnicForNicType').Count -eq 0 }

# trunk, fixed allocation, unused uplink, accept security
$p = Get-Demo; $g = $p.vds[0].portGroups[2]; $g.vlanType = 'trunk'; $g.trunk = '100-200,300'; $g.allocation = 'fixed'
$g.active = @('dvUplink1'); $g.standby = @(); $g.forgedTransmits = $true; $trunk = Save-Plan $p 'trunk.json'
Reset-Fake; Run { & $runner -PlanFile $trunk -VdsName $vds -OutputFolder $out -Confirm:$false } | Out-Null
$bk = @(Of 'New-VDPortgroup') | Where-Object { $_.P.Name -eq 'Backup' }
Check 'Trunk port group uses VlanTrunkRange and no VlanId' { $bk.P.VlanTrunkRange -eq '100-200,300' -and -not $bk.P.ContainsKey('VlanId') }
Check 'Fixed allocation sets AutoExpand false' { @(Of 'ReconfigureDVPortgroup' | Where-Object { $_.P.AutoExpand -eq $false }).Count -eq 1 }
Check 'Uplink not active or standby is set as unused' { $t = @(Of 'Set-VDUplinkTeamingPolicy') | Where-Object { $_.P.Pg -eq 'Backup' }; (@($t.P.UnusedUplinkPort) -join ',') -eq 'dvUplink2' }
Check 'Forged transmits Accept is sent' { $s = @(Of 'Set-VDSecurityPolicy') | Where-Object { $_.P.Pg -eq 'Backup' }; $s.P.ForgedTransmits -eq $true -and $s.P.AllowPromiscuous -eq $false }

# preflight
Reset-Fake; $global:FakeVc.Vmk['esx21.example.local'].Add([pscustomobject]@{ Name = 'vmk1'; IP = '10.0.20.12'; VMotionEnabled = $false; Switch = 'vSwitch0' }) | Out-Null
$o = Run { & $pre -PlanFile $demo -OutputFolder $out }
Check 'Preflight: read-only, finds the IP address in use on another host' { @(Changes).Count -eq 0 -and $o -match '10.0.20.12' -and $o -match 'NOT READY' }
Check 'Preflight: CSV report written' { @(Get-ChildItem $out -Filter 'Get-VdsPlanPreflight_*.csv').Count -ge 1 }
Reset-Fake
$o = Run { & $pre -PlanFile $demo -OutputFolder $out }
Check 'Preflight: clean plan is READY' { @(Changes).Count -eq 0 -and $o -match 'READY for Invoke-VdsPlan' -and $o -notmatch 'NOT READY' }

# rollback
Reset-Fake; Run { & $runner -PlanFile $demo -VdsName $vds -OutputFolder $out -Confirm:$false } | Out-Null
$global:FakeVc.Uplinks['esx11.example.local'] = @('vmnic1'); $global:Calls.Clear()
$o = Run { & $remove -PlanFile $demo -VdsName $vds -OutputFolder $out -Confirm:$false }
Check 'Rollback: stops when a host has an uplink on the VDS' { @(Of 'Remove-VDSwitch').Count -eq 0 -and $o -match 'is in use' }
$global:FakeVc.Uplinks.Clear(); $global:FakeVc.Vds[$vds].Pgs['DB-Prod'].ExtensionData.Vm = @('vm-1', 'vm-2')
$o = Run { & $remove -PlanFile $demo -VdsName $vds -OutputFolder $out -Confirm:$false }
Check 'Rollback: stops when VMs use a port group' { @(Of 'Remove-VDSwitch').Count -eq 0 -and $o -match 'DB-Prod: 2 VMs' }
$global:FakeVc.Vds[$vds].Pgs['DB-Prod'].ExtensionData.Vm = @()
$o = Run { & $remove -PlanFile $demo -VdsName $vds -OutputFolder $out -WhatIf }
Check 'Rollback -WhatIf: nothing removed' { @(Of 'Remove-VDSwitch').Count -eq 0 -and $global:FakeVc.Vds.ContainsKey($vds) }
$o = Run { & $remove -PlanFile $demo -VdsName $vds -OutputFolder $out -Confirm:$false }
Check 'Rollback: removes the VDS when nothing uses it' { @(Of 'Remove-VDSwitch').Count -eq 1 -and -not $global:FakeVc.Vds.ContainsKey($vds) }
$o = Run { & $remove -PlanFile $demo -VdsName 'Other-vds01' -OutputFolder $out -Confirm:$false }
Check 'Rollback: refuses a VDS that is not in the plan' { $o -match 'not in the plan' }

# inventory export (T-01) feeds the planner
$export = "$Root\scripts\inventory\Export-VssLayout.ps1"
$xo = Join-Path $tmp 'export'
Reset-Fake; $global:FakeVc.SwNics['esx13.example.local'] = @('vmnic0', 'vmnic2'); $global:FakeVc.PartialPg = $true
$o = Run { & $export -Cluster Cluster02 -OutputFolder $xo }
Check 'Export-VssLayout: writes the hosts, port group and plan CSV files' { (Test-Path "$xo\Cluster02_hosts.csv") -and (Test-Path "$xo\Cluster02_portgroups.csv") -and (Test-Path "$xo\Cluster02_vdsplan.csv") }
$xp = @(Import-Csv "$xo\Cluster02_vdsplan.csv" -Encoding UTF8); $xh = @(Import-Csv "$xo\Cluster02_hosts.csv" -Encoding UTF8)
Check 'Export-VssLayout: plan CSV has the columns of the planner' { $c = $xp[0].PSObject.Properties.Name; -not (@('Cluster', 'Datacenter', 'Switch', 'NewVds', 'StandardUplinks', 'DeviatingHosts', 'PortGroup', 'Vlan', 'HostsWithPortGroup', 'HostsWithSwitch', 'VdsPortGroup', 'Flags') | Where-Object { $c -notcontains $_ }) }
Check 'Export-VssLayout: hosts CSV has the columns of the planner' { $c = $xh[0].PSObject.Properties.Name; -not (@('Cluster', 'Datacenter', 'Host', 'EsxVersion', 'Switch', 'Uplinks', 'UplinkCount', 'SpeedMbps') | Where-Object { $c -notcontains $_ }) }
Check 'Export-VssLayout: VDS name by rule V-01 and datacenter in each row' { -not ($xp | Where-Object { $_.NewVds -ne 'Cluster02-vds01' -or $_.Datacenter -ne 'DC-A' }) }
Check 'Export-VssLayout: iDRAC USB / BMC switch left out (V-10)' { -not ($xp | Where-Object Switch -eq 'vSwitchBMC') -and -not ($xh | Where-Object Switch -eq 'vSwitchBMC') }
Check 'Export-VssLayout: non-ASCII port group name kept (UTF-8)' { [bool]($xp | Where-Object PortGroup -eq 'DB-Prod-Ünïcode') }
Check 'Export-VssLayout: partial port group flagged (V-05)' { ($xp | Where-Object PortGroup -eq 'Partial').Flags -match 'V-05' }
Check 'Export-VssLayout: VLAN 4095 flagged for trunk 0-4094' { ($xp | Where-Object PortGroup -eq 'Appliance trunk').Flags -match '4095' }
Check 'Export-VssLayout: host with other uplinks marked (V-06)' { ($xp[0].DeviatingHosts -eq 'esx13.example.local') -and $xp[0].StandardUplinks -eq 'vmnic0 vmnic1' }
Check 'Export-VssLayout: VMkernel port group flagged' { ($xp | Where-Object PortGroup -eq 'Management Network').Flags -match 'VMkernel' }
Check 'Export-VssLayout: ESXi version and speed in the hosts CSV' { $xh[0].EsxVersion -eq '8.0.3' -and $xh[0].SpeedMbps -eq '10000' }
Check 'Export-VssLayout: read-only' { @(Changes).Count -eq 0 }

# inventory workbook -> planner input -> project with two drafts -> simulation
function New-TestWorkbook([string] $Path, $Sheets) {
    # a minimal .xlsx with inline text cells (no Excel needed)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    if (Test-Path $Path) { Remove-Item $Path }
    $zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
    $put = { param($n, $t) $e = $zip.CreateEntry($n); $w = New-Object IO.StreamWriter($e.Open(), (New-Object Text.UTF8Encoding $false)); $w.Write($t); $w.Dispose() }
    $x = { param($v) [Security.SecurityElement]::Escape("$v") }
    $names = @($Sheets.Keys)
    & $put '[Content_Types].xml' ('<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' + (($names | ForEach-Object -Begin { $i = 0 } -Process { $i++; "<Override PartName=`"/xl/worksheets/sheet$i.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml`"/>" }) -join '') + '</Types>')
    & $put '_rels/.rels' '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
    $i = 0; $sh = ''; $rel = ''
    foreach ($n in $names) { $i++; $sh += "<sheet name=`"$(& $x $n)`" sheetId=`"$i`" r:id=`"rId$i`"/>"; $rel += "<Relationship Id=`"rId$i`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet`" Target=`"worksheets/sheet$i.xml`"/>" }
    & $put 'xl/workbook.xml' "<?xml version=`"1.0`" encoding=`"UTF-8`"?><workbook xmlns=`"http://schemas.openxmlformats.org/spreadsheetml/2006/main`" xmlns:r=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships`"><sheets>$sh</sheets></workbook>"
    & $put 'xl/_rels/workbook.xml.rels' "<?xml version=`"1.0`" encoding=`"UTF-8`"?><Relationships xmlns=`"http://schemas.openxmlformats.org/package/2006/relationships`">$rel</Relationships>"
    $i = 0
    foreach ($n in $names) {
        $i++; $rows = ''; $r = 0
        foreach ($row in $Sheets[$n]) {
            $r++; $c = 0; $cells = ''
            foreach ($v in $row) { $c++; $col = [char](64 + $c); $cells += "<c r=`"$col$r`" t=`"inlineStr`"><is><t>$(& $x $v)</t></is></c>" }
            $rows += "<row r=`"$r`">$cells</row>"
        }
        & $put "xl/worksheets/sheet$i.xml" "<?xml version=`"1.0`" encoding=`"UTF-8`"?><worksheet xmlns=`"http://schemas.openxmlformats.org/spreadsheetml/2006/main`"><sheetData>$rows</sheetData></worksheet>"
    }
    $zip.Dispose()
}
$wb = Join-Path $tmp 'inventory.xlsx'
$vhost = @(, @('Host', 'Datacenter', 'Cluster', 'ESX Version', 'VI SDK Server'))
foreach ($h in 'h1', 'h2', 'h3') { $vhost += , @("$h.example.local", 'DC1', 'C1', 'VMware ESXi 8.0.3 build-24022510', 'vc9.example.local') }
foreach ($h in 'h4', 'h5') { $vhost += , @("$h.example.local", 'DC1', 'C2', 'VMware ESXi 8.0.3 build-24022510', 'vc9.example.local') }
$vhost += , @('s1.example.local', 'DC1', '', 'VMware ESXi 8.0.3 build-24022510', 'vc9.example.local')
$vsw = @(, @('Host', 'Switch', 'MTU')); $nic = @(, @('Host', 'Network Device', 'Speed', 'Switch')); $vmk = @(, @('Host', 'Port Group', 'Device'))
$vport = @(, @('Host', 'Port Group', 'Switch', 'VLAN', 'Promiscuous Mode', 'Mac Changes', 'Forged Transmits', 'Policy'))
# one row: the comma keeps the row as one item when it is added to the sheet
$pgx = { param($h, $n, $vl, $sw) @("$h.example.local", $n, $sw, $vl, 'False', 'False', 'False', 'loadbalance_srcid') }
foreach ($h in 'h1', 'h2', 'h3', 'h4', 'h5', 's1') {
    $vsw += , @("$h.example.local", 'vSwitch0', '1500'); $vsw += , @("$h.example.local", 'vSwitchBMC', '1500')
    $nic += , @("$h.example.local", 'vmnic0', '10000', 'vSwitch0'); $nic += , @("$h.example.local", 'vusb0', '100', 'vSwitchBMC')
    $nic += , @("$h.example.local", $(if ($h -eq 'h3') { 'vmnic2' } else { 'vmnic1' }), '10000', 'vSwitch0')
    $vport += , (& $pgx $h 'Management Network' '10' 'vSwitch0'); $vport += , (& $pgx $h 'BMC Network' '0' 'vSwitchBMC')
    $vmk += , @("$h.example.local", 'Management Network', 'vmk0')
}
foreach ($h in 'h1', 'h2', 'h3') { $vport += , (& $pgx $h 'App' '100' 'vSwitch0'); $vport += , (& $pgx $h 'Trunk' '4095' 'vSwitch0') }
foreach ($h in 'h1', 'h2') { $vport += , (& $pgx $h 'Partial' '200' 'vSwitch0') }
$vport += , (& $pgx 'h1' 'Dup' '300' 'vSwitch0'); $vport += , (& $pgx 'h2' 'Dup' '301' 'vSwitch0'); $vport += , (& $pgx 'h3' 'Dup' '300' 'vSwitch0')
foreach ($h in 'h4', 'h5') { $vport += , (& $pgx $h 'DB' '210' 'vSwitch0'); $vport += , (& $pgx $h 'Wörk-Ünï' '220' 'vSwitch0') }
New-TestWorkbook $wb ([ordered]@{ vHost = $vhost; vSwitch = $vsw; vPort = $vport; vNIC = $nic; vSC_VMK = $vmk
        dvSwitch = @(@('Switch', 'Datacenter', 'Name', 'Version'), @('Old-vds', 'DC1', 'x', '8.0.0')); dvPort = @(@('Port', 'Switch', 'Type', 'VLAN'), @('App', 'Old-vds', 'earlyBinding', '100')) })
$pio = Join-Path $tmp 'preload'
$conv = & "$Root\scripts\inventory\Export-PlannerInventory.ps1" -Workbook $wb -Name 'TestSite' -OutputFolder $pio 3>$null
$wr = @(Import-Csv "$pio\TestSite_vdsplan.csv" -Encoding UTF8); $wh = @(Import-Csv "$pio\TestSite_hosts.csv" -Encoding UTF8)
Check 'Workbook: plan rows for 2 clusters, BMC switch and standalone host left out' { $conv.Clusters -eq 2 -and $conv.StandaloneHosts -eq 1 -and -not ($wr | Where-Object Switch -eq 'vSwitchBMC') -and -not ($wh | Where-Object Host -like 's1*') }
Check 'Workbook: same columns as the live export, plus security and teaming' { $c = $wr[0].PSObject.Properties.Name; -not (@('Cluster', 'Datacenter', 'Switch', 'NewVds', 'StandardUplinks', 'DeviatingHosts', 'PortGroup', 'Vlan', 'HostsWithPortGroup', 'HostsWithSwitch', 'VdsPortGroup', 'Flags', 'Promiscuous', 'LoadBalancing') | Where-Object { $c -notcontains $_ }) }
Check 'Workbook: partial port group (V-05), VLAN 4095, VMkernel and V-06 flags' { ($wr | Where-Object PortGroup -eq 'Partial').Flags -match 'V-05' -and ($wr | Where-Object PortGroup -eq 'Trunk').Flags -match '4095' -and ($wr | Where-Object PortGroup -eq 'Management Network' | Select-Object -First 1).Flags -match 'VMkernel' -and ($wr | Where-Object Cluster -eq 'C1' | Select-Object -First 1).DeviatingHosts -eq 'h3.example.local' }
Check 'Workbook: ESXi version, speed and teaming from the workbook' { $wh[0].EsxVersion -eq '8.0.3' -and $wh[0].SpeedMbps -eq '10000' -and $wr[0].LoadBalancing -eq 'LoadBalanceSrcId' }
Check 'Workbook: non-ASCII name kept' { [bool]($wr | Where-Object PortGroup -eq 'Wörk-Ünï') }
Check 'Workbook: existing VDS file' { $e = @(Import-Csv "$pio\TestSite_existing_vds.csv"); $e.Count -eq 1 -and $e[0].Datacenter -eq 'DC1' -and $e[0].PortGroup -eq 'App' }
if (Get-Command node -ErrorAction SilentlyContinue) { Check 'Workbook: the planner import gives the same inventory as the script (Node.js)' { $t = @(& "$Root\tests\Test-PlannerWorkbook.ps1" -Workbook $wb 3>$null); $t.Count -eq 1 -and $t[0].Result -eq 'same' } }
$wp = [IO.File]::ReadAllText("$pio\TestSite.vdsplan.json") | ConvertFrom-Json
$sample = [IO.File]::ReadAllText("$Root\samples\site-a.sample.vdsplan.json") | ConvertFrom-Json
$keys = { param($o) @($o.PSObject.Properties.Name | Sort-Object) -join ',' }
Check 'Project: same fields as a project saved by the planner (project, VDS, port group, member)' {
    (& $keys $wp) -eq (& $keys $sample) -and (& $keys $wp.drafts[0].vds[0]) -eq (& $keys ($sample.drafts[1].vds[0])) -and
    (& $keys $wp.drafts[0].vds[0].portGroups[0]) -eq (& $keys ($sample.drafts[1].vds[0].portGroups[0])) -and (& $keys $wp.drafts[0].vds[0].members[0]) -eq (& $keys ($sample.drafts[1].vds[0].members[0])) }
$fx = $wp.drafts[1]
Check 'Project: two drafts, names unchanged in the first' { $wp.drafts.Count -eq 2 -and @($wp.drafts[0].vds.portGroups.name) -contains 'Management Network' }
Check 'Names fixed: duplicate gets the VLAN, clash in the datacenter and with the existing VDS gets the cluster name' {
    $n = @($fx.vds.portGroups.name); ($n -contains 'Dup-vlan300') -and ($n -contains 'Dup-vlan301') -and ($n -contains 'C1-Management Network') -and ($n -contains 'C2-Management Network') -and ($n -contains 'C1-App') -and ($n -contains 'DB') }
$so = Join-Path $tmp 'sim'
$s1 = & "$PSScriptRoot\Invoke-InventorySimulation.ps1" -ProjectFile "$pio\TestSite.vdsplan.json" -OutputFolder $so -PortGroupFile "$pio\TestSite_portgroups.csv"
# C1 stops at the plan checks, so it is not made, and C2 then has no name clash
Check 'Simulation, names as exported: C1 blocked by the plan (V-05, duplicate), C2 runs' { $s1.SimulatedRunDone -eq 1 -and $s1.BlockedByPlan -eq 1 -and $s1.BlockedByPreflight -eq 0 }
$s3 = & "$PSScriptRoot\Invoke-InventorySimulation.ps1" -ProjectFile "$pio\TestSite.vdsplan.json" -OutputFolder (Join-Path $tmp 'sim3') -Draft 'Standard layout (V-01), names fixed'
Check 'Simulation, names fixed but V-05 open: C1 blocked by V-05 only' { $s3.BlockedByPlan -eq 1 -and $s3.SimulatedRunDone -eq 1 }
$s2 = & "$PSScriptRoot\Invoke-InventorySimulation.ps1" -ProjectFile "$pio\TestSite.vdsplan.json" -OutputFolder $so -Draft 'Standard layout (V-01), names fixed' -AssumeTrunkConfirmed -PortGroupFile "$pio\TestSite_portgroups.csv"
Check 'Simulation, names fixed and V-05 confirmed: both VDS run, no block' { $s2.SimulatedRunDone -eq 2 -and $s2.Blocks -eq 0 }
Check 'Simulation: readiness reports and CSV files written' { @(Get-ChildItem $so -Filter 'TestSite-readiness*.html').Count -eq 2 -and @(Get-ChildItem $so -Filter 'TestSite-simulation-*.csv').Count -eq 4 }
Check 'Simulation: report lists the host that misses port groups' { (Get-Content "$so\TestSite-readiness.html" -Raw) -match 'h3\.example\.local' }

# launcher of the demo package
$launch = "$Root\samples\demo-package\Invoke-shared-db-vds-v1.ps1"
Reset-Fake; $global:DefaultVIServers = @()
$o = Run { & $launch -ToolkitPath $Root -WhatIf }
Check 'Launcher -WhatIf: asks for the credential, connects, runs the runner, no change' { $c = @(Of 'Connect-VIServer'); $c.Count -eq 1 -and $c[0].P.User -eq 'administrator@vsphere.local' -and $c[0].P.Server -eq 'vc01.example.local' -and @(Changes).Count -eq 0 -and $o -match "DB-shared-vds01 \(Switch\)" -and @(Of 'Disconnect-VIServer').Count -eq 1 }
Reset-Fake; $global:DefaultVIServers = @()
$o = Run { & $launch -ToolkitPath $Root -Part VMkernel -VMHost esx99.example.local -WhatIf }
Check 'Launcher: VMkernel for a host that is not in the plan stops before the login' { $o -match 'no new VMkernel adapter for esx99' -and @(Of 'Connect-VIServer').Count -eq 0 }
Reset-Fake; $global:DefaultVIServers = @()
$o = Run { & $launch -ToolkitPath $Root -Part Check }
Check 'Launcher -Part Check: runs the read-only preflight' { @(Changes).Count -eq 0 -and $o -match 'READY for Invoke-VdsPlan' -and @(Of 'Connect-VIServer').Count -eq 1 }
Reset-Fake; $global:DefaultVIServers = @()
$o = Run { & $launch -ToolkitPath 'C:\nothing' -WhatIf }
Check 'Launcher: wrong toolkit folder stops with a message' { $o -match 'is not in C:\\nothing' }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ''
Write-Output "RESULT: $script:pass passed, $script:fail failed (PowerShell $($PSVersionTable.PSVersion))"
if ($script:fail) { exit 1 }
