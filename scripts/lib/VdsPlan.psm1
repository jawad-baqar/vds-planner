<#
.SYNOPSIS
Reads and checks a committed VDS plan file of the VDS Planner (RW-08).

.DESCRIPTION
The VDS Planner (planner\vds-planner.html) writes a plan file (plan-<draft>-v<n>.json) and a hash file (plan-<draft>-v<n>.json.sha256) at each commit.
Get-VdsPlan reads the plan file. It stops if the SHA-256 hash of the file is not the hash in the hash file.
Test-VdsPlan checks the content of the plan against the rules V-01 to V-10 of the guide and returns one message for each error.
It also checks the new VMkernel adapters of the plan (service, TCP/IP stack, MTU, IP address and subnet mask of each host).
The module is read-only. It makes no connection to vCenter.
#>

$script:LoadBalancing = 'LoadBalanceSrcId', 'LoadBalanceSrcMac', 'LoadBalanceIP', 'LoadBalanceLoadBased', 'ExplicitFailover'

function Test-VdsPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Plan)
    $e = @()
    # vdsplan-run/1. An earlier identifier had a prefix before 'vdsplan'. Committed plans with it stay valid.
    if ("$($Plan.format)" -notmatch '^([a-z0-9]+-)?vdsplan-run/1$') { return "Unknown plan format '$($Plan.format)'." }
    if (-not $Plan.vcenter) { $e += 'The plan has no vCenter.' }
    if ([int]$Plan.version -lt 1) { $e += 'The plan has no version number.' }
    if (-not @($Plan.vds).Count) { $e += 'The plan has no VDS.' }

    $vdsNames = @{}
    $ips = @{}
    foreach ($v in @($Plan.vds)) {
        $n = $v.name
        if (-not $n -or $n -match '[\\/%]' -or $n.Length -gt 80) { $e += "VDS name '$n' is not valid." }
        if ($vdsNames.ContainsKey("$n")) { $e += "VDS name '$n' is in the plan more than one time." }
        $vdsNames["$n"] = 1
        $clusters = @($v.clusters)
        if (-not $clusters.Count) { $e += "${n}: the VDS has no cluster." }
        # pass: the standard switches are the same. accepted: the designer accepted the listed differences in the planner.
        if ($clusters.Count -gt 1 -and -not ($v.shared -and ($v.v08Check -eq 'pass' -or ($v.v08Check -eq 'accepted' -and @($v.v08Accepted | Where-Object { $_ }).Count)))) {
            $e += "${n}: a VDS for more than one cluster needs a passed or accepted shared-VDS check (V-08)."
        }
        $uc = [int]$v.uplinkCount
        if ($uc -lt 2 -or $uc -gt 8) { $e += "${n}: the VDS must have 2 to 8 uplinks (V-02)." }
        if ($v.version -notmatch '^8\.0\.\d$') { $e += "${n}: VDS version '$($v.version)' is not 8.0.x (V-09)." }
        if ([int]$v.mtu -lt 1280 -or [int]$v.mtu -gt 9000) { $e += "${n}: MTU $($v.mtu) is not in the range 1280 to 9000." }
        $uplinks = 1..([math]::Max($uc, 1)) | ForEach-Object { "dvUplink$_" }

        $pgNames = @{}
        foreach ($p in @($v.portGroups)) {
            $pn = $p.name
            $where = "$n / $pn"
            if (-not $pn -or $pn.Length -gt 80) { $e += "${n}: port group name '$pn' is not valid." }
            if ($pgNames.ContainsKey("$pn")) { $e += "${where}: the port group is on the VDS more than one time." }
            $pgNames["$pn"] = 1
            switch ($p.vlanType) {
                'none'  { }
                'vlan'  { if ([int]$p.vlan -lt 1 -or [int]$p.vlan -gt 4094) { $e += "${where}: VLAN $($p.vlan) is not in the range 1 to 4094." } }
                'trunk' {
                    $ok = $p.trunk -match '^\d+(-\d+)?(,\d+(-\d+)?)*$'
                    if ($ok) { $ok = -not (($p.trunk -split '[,-]') | Where-Object { [int]$_ -gt 4094 }) }
                    if (-not $ok) { $e += "${where}: VLAN trunk range '$($p.trunk)' is not valid." }
                }
                default { $e += "${where}: VLAN type '$($p.vlanType)' is not none, vlan or trunk." }
            }
            if ($p.binding -eq 'static') {
                if ([int]$p.ports -lt 1 -or [int]$p.ports -gt 8192) { $e += "${where}: the number of ports must be 1 to 8192." }
                if ('elastic', 'fixed' -notcontains $p.allocation) { $e += "${where}: port allocation '$($p.allocation)' is not elastic or fixed." }
            }
            elseif ($p.binding -ne 'ephemeral') { $e += "${where}: port binding '$($p.binding)' is not static or ephemeral." }
            if ($script:LoadBalancing -notcontains $p.loadBalancing) { $e += "${where}: load balancing '$($p.loadBalancing)' is not known." }
            $active = @($p.active); $standby = @($p.standby)
            if (-not $active.Count) { $e += "${where}: the port group has no active uplink." }
            foreach ($u in ($active + $standby)) { if ($uplinks -notcontains $u) { $e += "${where}: uplink '$u' is not on the VDS." } }
            foreach ($u in $active) { if ($standby -contains $u) { $e += "${where}: uplink '$u' is active and standby." } }
            foreach ($f in 'allowPromiscuous', 'macChanges', 'forgedTransmits') {
                if ($p.$f -isnot [bool]) { $e += "${where}: security setting '$f' is not true or false." }
            }
        }

        $members = @($v.members | Where-Object { $_ })
        if ($members.Count) {
            $mc = @($members.cluster | Sort-Object -Unique)
            if (Compare-Object $mc @($clusters | Sort-Object -Unique)) { $e += "${n}: the members are not the same as the clusters." }
            if ($members | Where-Object { -not $_.sourceSwitch }) { $e += "${n}: a member has no standard switch." }
        }

        foreach ($k in @($v.vmkernel | Where-Object { $_ })) {
            $where = "$n / VMkernel $($k.service) on $($k.portGroup)"
            if (-not $pgNames.ContainsKey("$($k.portGroup)")) { $e += "${where}: the port group is not on the VDS." }
            if ($script:Services -notcontains $k.service) { $e += "${where}: service '$($k.service)' is not known." }
            if ($script:Stacks.Keys -notcontains $k.stack) { $e += "${where}: TCP/IP stack '$($k.stack)' is not known." }
            elseif ($script:Stacks[$k.stack] -and $script:Stacks[$k.stack] -ne $k.service) { $e += "${where}: the $($k.stack) stack is for $($script:Stacks[$k.stack]) only." }
            if ([int]$k.mtu -lt 1280 -or [int]$k.mtu -gt [int]$v.mtu) { $e += "${where}: MTU $($k.mtu) must be 1280 or more and not more than the VDS MTU $($v.mtu)." }
            $rows = @($k.hosts | Where-Object { $_ })
            if (-not $rows.Count) { $e += "${where}: the adapter has no host." }
            $seen = @{}
            foreach ($r in $rows) {
                if (-not $r.host) { $e += "${where}: a row has no host name." }
                elseif ($seen.ContainsKey($r.host)) { $e += "${where}: host $($r.host) is in the list more than one time." }
                $seen["$($r.host)"] = 1
                if (-not (Test-Ipv4 $r.ip)) { $e += "${where}: $($r.host) has no valid IP address ('$($r.ip)')." }
                elseif ($ips.ContainsKey($r.ip)) { $e += "${where}: IP address $($r.ip) is used more than one time in the plan." }
                else { $ips[$r.ip] = 1 }
                if (-not (Test-Ipv4Mask $r.mask)) { $e += "${where}: $($r.host) has no valid subnet mask ('$($r.mask)')." }
            }
        }
    }
    $e
}

# service of each TCP/IP stack ($null: any service)
$script:Stacks = @{ defaultTcpipStack = $null; vmotion = 'vMotion'; vSphereProvisioning = 'Provisioning' }
$script:Services = 'vMotion', 'Provisioning', 'Management', 'vSAN', 'FaultTolerance', 'Replication', 'NfcReplication'

function Test-Ipv4([string] $Text) {
    $a = $null
    $Text -match '^\d{1,3}(\.\d{1,3}){3}$' -and [ipaddress]::TryParse($Text, [ref]$a) -and $Text -ne '0.0.0.0'
}

function Test-Ipv4Mask([string] $Text) {
    if (-not (Test-Ipv4 $Text)) { return $false }
    $bits = ($Text -split '\.' | ForEach-Object { [Convert]::ToString([int]$_, 2).PadLeft(8, '0') }) -join ''
    $bits -match '^1{8,30}0+$'
}

function Get-VdsPlanHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-VdsPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    $Path = (Resolve-Path $Path).Path
    $hashFile = "$Path.sha256"
    if (-not (Test-Path $hashFile)) { throw "The hash file $hashFile is missing. Generate the package again in the VDS Planner." }
    $expected = ((Get-Content $hashFile -TotalCount 1) -split '\s+')[0].ToLowerInvariant()
    $actual = Get-VdsPlanHash -Path $Path
    if ($expected -ne $actual) { throw "The plan file changed after the commit. Expected SHA-256 $expected, found $actual." }
    $text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($Path)).TrimStart([char]0xFEFF)
    $plan = $text | ConvertFrom-Json
    # PowerShell 7 makes a date of an ISO date text. Keep the text of the plan file.
    if ($plan.committedAt -is [datetime]) { $plan.committedAt = $plan.committedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
    $errors = @(Test-VdsPlan -Plan $plan)
    if ($errors.Count) { throw ("The plan has {0} errors:`n- {1}" -f $errors.Count, ($errors -join "`n- ")) }
    $plan
}

function Get-VdsPlanLiveFinding {
    # read-only checks of one VDS of the plan against the connected vCenter. Needs PowerCLI and a connection.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Plan, [Parameter(Mandatory)] $Vds)
    $out = New-Object System.Collections.ArrayList
    function Add-Finding([string] $Level, [string] $Object, [string] $Text) {
        [void]$out.Add([pscustomobject]@{ Vds = $Vds.name; Level = $Level; Object = $Object; Finding = $Text })
    }
    if (@($global:DefaultVIServers).Name -notcontains $Plan.vcenter) {
        Add-Finding 'Block' $Plan.vcenter "The session is not connected to $($Plan.vcenter). The plan is for that vCenter only."
        return $out
    }
    $clusters = @()
    foreach ($c in @($Vds.clusters)) {
        $cl = Get-Cluster -Name $c -ErrorAction SilentlyContinue
        if ($cl) { $clusters += $cl } else { Add-Finding 'Block' $c 'The cluster is not in the vCenter.' }
    }
    if (-not $clusters.Count) { return $out }
    $dcs = @($clusters | ForEach-Object { Get-Datacenter -Cluster $_ } | Sort-Object Name -Unique)
    if ($dcs.Count -ne 1) { Add-Finding 'Block' $Vds.name "The clusters are in more than one datacenter ($($dcs.Name -join ', ')). A VDS is in one datacenter only." }
    $dc = $dcs[0]
    $want = [version]($Vds.version)
    $uplinks = 1..([int]$Vds.uplinkCount) | ForEach-Object { "dvUplink$_" }

    $hostsByName = @{}
    foreach ($cl in $clusters) {
        $m = @($Vds.members | Where-Object { $_ -and $_.cluster -eq $cl.Name }) | Select-Object -First 1
        $src = if ($m) { $m.sourceSwitch } else { $Vds.sourceSwitch }
        foreach ($h in (Get-VMHost -Location $cl)) {
            $hostsByName[$h.Name] = $h
            if ('Connected', 'Maintenance' -notcontains "$($h.ConnectionState)") { Add-Finding 'Block' $h.Name "The host state is $($h.ConnectionState). Connect the host first." }
            if ($h.Version -and [version]$h.Version -lt $want) { Add-Finding 'Block' $h.Name "ESXi $($h.Version) cannot join a VDS of version $($Vds.version). Upgrade the host or use an earlier VDS version." }
            $sw = Get-VirtualSwitch -VMHost $h -Standard -Name $src -ErrorAction SilentlyContinue
            if (-not $sw) { Add-Finding 'Warn' $h.Name "The host has no standard switch $src." }
            elseif (@($sw.Nic).Count -ne [int]$Vds.uplinkCount) { Add-Finding 'Warn' $h.Name "$src has $(@($sw.Nic).Count) uplinks. The plan has $($Vds.uplinkCount) (V-06)." }
        }
    }

    # PowerShell names are not case-sensitive. A variable named like the Vds parameter replaces the plan data.
    $live = Get-VDSwitch -Name $Vds.name -ErrorAction SilentlyContinue
    if ($live) {
        if ($live.NumUplinkPorts -ne [int]$Vds.uplinkCount) { Add-Finding 'Block' $Vds.name "The VDS exists with $($live.NumUplinkPorts) uplinks. The plan has $($Vds.uplinkCount)." }
        else {
            $names = @($live.ExtensionData.Config.UplinkPortPolicy.UplinkPortName)
            if (Compare-Object $names $uplinks) { Add-Finding 'Block' $Vds.name "The uplink names are $($names -join ', '). The plan expects $($uplinks -join ', ')." }
            else { Add-Finding 'Info' $Vds.name 'The VDS exists. The script does not change it.' }
        }
        if ("$($live.Version)" -ne "$($Vds.version)") { Add-Finding 'Warn' $Vds.name "The VDS version is $($live.Version). The plan has $($Vds.version)." }
    }
    # a distributed port group name must be unique in its datacenter
    $others = @(Get-VDSwitch -Location $dc -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $Vds.name })
    foreach ($p in @($Vds.portGroups)) {
        foreach ($o in $others) {
            if (Get-VDPortgroup -VDSwitch $o -Name $p.name -ErrorAction SilentlyContinue) {
                Add-Finding 'Block' $p.name "A port group with this name is on VDS $($o.Name) in datacenter $($dc.Name). Port group names must be unique in a datacenter. Rename it in the planner."
            }
        }
        if ($live -and (Get-VDPortgroup -VDSwitch $live -Name $p.name -ErrorAction SilentlyContinue)) { Add-Finding 'Info' $p.name 'The port group exists on the VDS. The script does not change it.' }
    }

    foreach ($k in @($Vds.vmkernel | Where-Object { $_ })) {
        foreach ($r in @($k.hosts)) {
            if (-not $hostsByName.ContainsKey($r.host)) { Add-Finding 'Block' $r.host "The host of the $($k.service) adapter is not in the clusters of the VDS."; continue }
        }
        $planIps = @{}; foreach ($r in @($k.hosts)) { $planIps[$r.ip] = $r.host }
        foreach ($h in $hostsByName.Values) {
            foreach ($nic in @(Get-VMHostNetworkAdapter -VMHost $h -VMKernel -ErrorAction SilentlyContinue)) {
                if ($nic.IP -and $planIps.ContainsKey($nic.IP)) {
                    if ($planIps[$nic.IP] -eq $h.Name) { Add-Finding 'Info' "$($h.Name) $($nic.IP)" "The $($k.service) adapter exists ($($nic.Name)). The script does not change it." }
                    else { Add-Finding 'Block' $nic.IP "The IP address is in use on $($h.Name) $($nic.Name). The plan gives it to $($planIps[$nic.IP])." }
                }
            }
        }
    }
    if ([int]$Vds.mtu -gt 1500) { Add-Finding 'Info' $Vds.name "VDS MTU $($Vds.mtu). Make sure that the physical switches support this MTU on all uplinks." }
    $out
}

# iDRAC USB and BMC switches are removed, not converted (V-10)
function Get-VdsPlanSkippedSwitch { 'vSwitchiDRACvusb', 'vSwitchBMC' }

function Group-InOrder([object[]] $Items, [scriptblock] $Key) {
    # groups in the sequence of their first item, with keys that ignore case
    # not Group-Object: PowerShell 7 sorts the groups, PowerShell 5.1 does not
    $map = [ordered]@{}
    foreach ($i in $Items) {
        if ($null -eq $i) { continue }
        $k = "$(& $Key $i)"
        if (-not $map.Contains($k)) { $map[$k] = New-Object System.Collections.ArrayList }
        [void]$map[$k].Add($i)
    }
    foreach ($k in $map.Keys) { [pscustomobject]@{ Name = "$(& $Key $map[$k][0])"; Count = $map[$k].Count; Group = @($map[$k]) } }
}

function ConvertTo-VdsPlanRow {
    # makes the VDS plan rows of one cluster from its host rows and port group rows (rules V-01, V-05, V-06, V-07)
    # used by Export-VssLayout.ps1 (live vCenter) and Export-PlannerInventory.ps1 (inventory workbook)
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Cluster,
        [string] $Datacenter,
        [Parameter(Mandatory)] [int] $HostCount,
        [object[]] $HostRows = @(),
        [object[]] $PortGroupRows = @()
    )
    $switchNames = @($HostRows.Switch | Sort-Object -Unique | Where-Object { $_ -ne 'vSwitch0' })
    foreach ($sw in (Group-InOrder $HostRows { param($r) $r.Switch })) {
        $onSwitch = $sw.Group.Count
        # rule V-06: the layout of most hosts. On a tie, the layout of the first host.
        # not Sort-Object -Descending: PowerShell 5.1 and 7 put equal items in a different sequence
        $std = $null
        foreach ($g in (Group-InOrder $sw.Group { param($r) $r.Uplinks })) { if (-not $std -or $g.Count -gt $std.Count) { $std = $g } }
        # rule V-07: a switch on a minority of hosts with no uplinks is not converted
        if ($onSwitch * 2 -le $HostCount -and -not $std.Name) { continue }
        $index = if ($sw.Name -eq 'vSwitch0') { 1 } else { 2 + [array]::IndexOf($switchNames, $sw.Name) }
        $vdsName = '{0}-vds{1:d2}' -f ($Cluster -replace '[ &]', '-'), $index
        $deviating = ($sw.Group | Where-Object Uplinks -ne $std.Name).Host -join ' '
        foreach ($pg in (Group-InOrder @($PortGroupRows | Where-Object Switch -eq $sw.Name) { param($r) "$($r.PortGroup)|$($r.Vlan)" })) {
            $first = $pg.Group[0]
            $flags = @()
            if ($pg.Count -lt $onSwitch) { $flags += "On $($pg.Count) of $onSwitch hosts: check the VLAN trunk (V-05)" }
            if ("$($first.Vlan)" -eq '4095') { $flags += 'VLAN 4095: use VLAN trunking 0-4094' }
            if ($pg.Group.Vmk -join '') { $flags += 'VMkernel port group' }
            [pscustomobject]@{
                Cluster = $Cluster; Datacenter = $Datacenter; Switch = $sw.Name; NewVds = $vdsName; StandardUplinks = $std.Name
                DeviatingHosts = $deviating; PortGroup = $first.PortGroup; Vlan = $first.Vlan
                HostsWithPortGroup = $pg.Count; HostsWithSwitch = $onSwitch; VdsPortGroup = $first.PortGroup; Flags = ($flags -join ' | ')
            }
        }
    }
}

function ConvertTo-StringRow($Row) {
    # the planner keeps inventory rows as text, like a CSV file
    $o = [ordered]@{}
    foreach ($p in $Row.PSObject.Properties) { $o[$p.Name] = "$($p.Value)" }
    $o
}

function ConvertTo-PlannerPortGroup($Row, [int] $UplinkCount) {
    # same defaults as pgFromRow in the planner
    $vlan = 0; [void][int]::TryParse("$($Row.Vlan)", [ref]$vlan)
    $type = if ($vlan -eq 4095) { 'trunk' } elseif ($vlan -eq 0) { 'none' } else { 'vlan' }
    $lbs = 'LoadBalanceSrcId', 'LoadBalanceSrcMac', 'LoadBalanceIP', 'LoadBalanceLoadBased', 'ExplicitFailover'
    [ordered]@{
        name = $(if ($Row.VdsPortGroup) { "$($Row.VdsPortGroup)" } else { "$($Row.PortGroup)" }); include = $true; source = "$($Row.PortGroup)"; sourceVlan = $vlan
        vlanType = $type; vlan = $(if ($type -eq 'vlan') { $vlan } else { 0 }); trunk = $(if ($type -eq 'trunk') { '0-4094' } else { '' })
        binding = 'static'; ports = 8; allocation = 'elastic'; loadBalancing = $(if ($lbs -contains "$($Row.LoadBalancing)") { "$($Row.LoadBalancing)" } else { 'LoadBalanceSrcId' })
        active = @(1..([math]::Max($UplinkCount, 1)) | ForEach-Object { "dvUplink$_" }); standby = @()
        allowPromiscuous = ("$($Row.Promiscuous)" -eq 'True'); macChanges = ("$($Row.MacChanges)" -eq 'True'); forgedTransmits = ("$($Row.ForgedTransmits)" -eq 'True')
        partial = ([int]"0$($Row.HostsWithPortGroup)" -lt [int]"0$($Row.HostsWithSwitch)"); vmk = ("$($Row.Flags)" -match 'VMkernel'); trunkConfirmed = $false; flags = "$($Row.Flags)"
    }
}

function New-VdsPlanProject {
    # makes a VDS Planner project file with the inventory and one draft with one VDS for each standard switch (rule V-01)
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Site,
        [string] $VCenter = '',
        [object[]] $PlanRows = @(),
        [object[]] $HostRows = @(),
        [object[]] $ExistingRows = @(),
        [string] $DraftName = 'Standard layout (V-01)',
        [string[]] $Files = @()
    )
    $at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $clusters = [ordered]@{}
    foreach ($c in (@($PlanRows.Cluster) + @($HostRows.Cluster) | Where-Object { $_ } | Sort-Object -Unique)) {
        $clusters[$c] = [ordered]@{ importedAt = $at; file = ($Files -join ', ')
            rows = @($PlanRows | Where-Object Cluster -eq $c | ForEach-Object { ConvertTo-StringRow $_ })
            hosts = @($HostRows | Where-Object Cluster -eq $c | ForEach-Object { ConvertTo-StringRow $_ }); zone = '' }
    }
    $vds = foreach ($g in (Group-InOrder $PlanRows { param($r) "$($r.Cluster)|$($r.NewVds)" })) {
        $f = $g.Group[0]; $n = @("$($f.StandardUplinks)" -split '\s+' | Where-Object { $_ }).Count
        [ordered]@{ name = "$($f.NewVds)"
            members = @([ordered]@{ cluster = "$($f.Cluster)"; newVds = "$($f.NewVds)"; sourceSwitch = "$($f.Switch)"; uplinks = "$($f.StandardUplinks)"; deviating = "$($f.DeviatingHosts)" })
            uplinkCount = $n; version = '8.0.3'; mtu = 1500
            portGroups = @($g.Group | ForEach-Object { ConvertTo-PlannerPortGroup $_ $n }); vmkernel = @() }
    }
    [ordered]@{
        format = 'vdsplan-project/1'; vcenter = $VCenter; site = $Site
        settings = [ordered]@{ toolkitPath = 'C:\Tools\vds-toolkit'; userName = 'administrator@vsphere.local' }
        inventory = [ordered]@{ clusters = $clusters; history = @([ordered]@{ at = $at; clusters = @($clusters.Keys); changes = 0; files = @($Files) })
            existing = @($ExistingRows | ForEach-Object { [ordered]@{ Datacenter = "$($_.Datacenter)"; Vds = "$($_.Vds)"; PortGroup = "$($_.PortGroup)"; Vlan = "$($_.Vlan)" } }) }
        drafts = @([ordered]@{ id = 'd' + [guid]::NewGuid().ToString('N').Substring(0, 10); name = $DraftName; vds = @($vds); versions = @() })
    }
}

function Repair-VdsPlanName {
    # same rules as fixNames in the planner:
    # 1. the same name with different VLANs on one VDS gets the VLAN at the end
    # 2. a name on more than one VDS of a datacenter (planned or existing) gets the cluster name in front
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Draft, [object[]] $Existing = @(), [hashtable] $DatacenterOf = @{})
    $dup = 0; $pre = 0
    $rename = { param($v, $p, $nn) foreach ($k in @($v.vmkernel)) { if ($k -and $k.portGroup -eq $p.name) { $k.portGroup = $nn } }; $p.name = $nn }
    foreach ($v in @($Draft.vds)) {
        foreach ($g in (@($v.portGroups | Where-Object { $_.include }) | Group-Object { $_.name } | Where-Object Count -gt 1)) {
            foreach ($p in $g.Group) {
                $tail = if ($p.vlanType -eq 'trunk') { 'trunk' } elseif ($p.vlanType -eq 'none') { '0' } else { "$($p.vlan)" }
                & $rename $v $p "$($p.name)-vlan$tail"; $dup++
            }
        }
    }
    $owners = @{}
    $own = { param($k, $o) if (-not $owners.ContainsKey($k)) { $owners[$k] = @{} }; $owners[$k][$o] = 1 }
    foreach ($e in @($Existing | Where-Object { $_ })) { & $own "$(if ($e.Datacenter) { $e.Datacenter } else { '?' })|$($e.PortGroup)" "existing:$($e.Vds)" }
    foreach ($v in @($Draft.vds)) {
        $dc = $DatacenterOf["$(@($v.members)[0].cluster)"]; if (-not $dc) { $dc = '?' }
        foreach ($p in @($v.portGroups | Where-Object { $_.include })) { & $own "$dc|$($p.name)" $v.name }
    }
    foreach ($v in @($Draft.vds)) {
        $dc = $DatacenterOf["$(@($v.members)[0].cluster)"]; if (-not $dc) { $dc = '?' }
        $prefix = ((@($v.members) | ForEach-Object { $_.cluster }) -join '-') + '-'
        foreach ($p in @($v.portGroups | Where-Object { $_.include })) {
            $o = @($owners["$dc|$($p.name)"].Keys | Where-Object { $_ -ne "existing:$($v.name)" })
            if ($o.Count -gt 1 -and -not "$($p.name)".StartsWith($prefix)) { & $rename $v $p ($prefix + $p.name); $pre++ }
        }
    }
    [pscustomobject]@{ Duplicates = $dup; Prefixed = $pre }
}

function ConvertTo-VdsPlanRun {
    # makes the run plan of a draft, the same as a commit in the planner (buildPlan), for tests and simulations
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Project, [Parameter(Mandatory)] $Draft, [int] $Version = 1, [string] $CommittedBy = 'Simulation')
    [ordered]@{
        format = 'vdsplan-run/1'; vcenter = $Project.vcenter; site = $Project.site; draft = $Draft.name; draftId = $Draft.id; version = $Version
        committedBy = $CommittedBy; committedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        vds = @($Draft.vds | ForEach-Object {
                $v = $_
                [ordered]@{ name = $v.name; clusters = @($v.members | ForEach-Object { $_.cluster }); sourceSwitch = $v.members[0].sourceSwitch
                    members = @($v.members | ForEach-Object { [ordered]@{ cluster = $_.cluster; sourceSwitch = $_.sourceSwitch } })
                    uplinkCount = $v.uplinkCount; version = $v.version; mtu = $v.mtu; shared = (@($v.members).Count -gt 1); v08Check = 'n/a'
                    portGroups = @($v.portGroups | Where-Object { $_.include } | ForEach-Object {
                            [ordered]@{ name = $_.name; vlanType = $_.vlanType; vlan = $_.vlan; trunk = $_.trunk; binding = $_.binding; ports = $(if ($_.binding -eq 'static') { $_.ports } else { 0 })
                                allocation = $_.allocation; loadBalancing = $_.loadBalancing; active = @($_.active); standby = @($_.standby)
                                allowPromiscuous = $_.allowPromiscuous; macChanges = $_.macChanges; forgedTransmits = $_.forgedTransmits } })
                    vmkernel = @() }
            })
    }
}

Export-ModuleMember -Function Test-VdsPlan, Get-VdsPlanHash, Get-VdsPlan, Get-VdsPlanLiveFinding, ConvertTo-VdsPlanRow, Get-VdsPlanSkippedSwitch, New-VdsPlanProject, ConvertTo-VdsPlanRun, Repair-VdsPlanName
