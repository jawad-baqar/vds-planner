<#
.SYNOPSIS
Creates one VDS of a committed VDS Planner plan file, or adds the new VMkernel adapters of one host (RW-08).

.DESCRIPTION
The script reads a plan file of the VDS Planner (planner\vds-planner.html). It stops if the hash of the plan file is not the hash in the .sha256 file, or if the plan has errors.
It works on one VDS of the plan at a time.
-Part Switch (the default) creates the VDS, creates the port groups with their settings (binding, ports, allocation, VLAN, teaming, security) and adds all hosts of the plan clusters with no uplink. Before it changes anything, it does all the read-only checks of Get-VdsPlanPreflight.ps1 (clusters, datacenter, host state, ESXi version, source switches, port group names in the datacenter, IP addresses). It stops if a check finds a blocking item.
-Part VMkernel adds the new VMkernel adapters of the plan on one host (-VMHost). The host must have one uplink or more on the VDS. Move the uplinks first with Move-HostToVds.ps1.
The script does not move uplinks, existing VMkernel adapters or VMs. Use Move-HostToVds.ps1 and Move-VmNetworkToVds.ps1 for these steps.
A VDS, a port group or a VMkernel adapter that exists is not changed. The script writes a message and continues.
Connect to the vCenter of the plan first. Use -WhatIf first.
The script writes a transcript and a CSV log to the output folder.

.PARAMETER PlanFile
The plan file, for example plan-cluster01-v1.json. The hash file plan-cluster01-v1.json.sha256 must be in the same folder.

.PARAMETER VdsName
The VDS of the plan, for example Cluster01-vds01.

.PARAMETER Part
Switch or VMkernel. The default is Switch.

.PARAMETER VMHost
For -Part VMkernel: the host to add the VMkernel adapters on.

.PARAMETER OutputFolder
The folder for the transcript and the CSV log. The default is .\output.

.EXAMPLE
Connect-VIServer -Server vc01.example.local -Credential (Get-Credential administrator@vsphere.local)
.\Invoke-VdsPlan.ps1 -PlanFile .\plan-cluster01-v1.json -VdsName Cluster01-vds01 -WhatIf

.EXAMPLE
.\Invoke-VdsPlan.ps1 -PlanFile .\plan-cluster01-v1.json -VdsName Cluster01-vds01 -Part VMkernel -VMHost esx01.example.local -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string] $PlanFile,
    [Parameter(Mandatory)] [string] $VdsName,
    [ValidateSet('Switch', 'VMkernel')] [string] $Part = 'Switch',
    [string] $VMHost,
    [string] $OutputFolder
)
$ErrorActionPreference = 'Stop'
# set here, not in param(): $PSScriptRoot is empty in a param() default under powershell.exe -File (5.1)
if (-not $OutputFolder) { $OutputFolder = Join-Path $PSScriptRoot '..\..\output' }
if ($Part -eq 'VMkernel' -and -not $VMHost) { throw 'Use -VMHost with -Part VMkernel. The script adds VMkernel adapters on one host at a time.' }
Import-Module (Join-Path $PSScriptRoot '..\lib\VdsPlan.psm1') -Force
New-Item -ItemType Directory -Force -Path $OutputFolder -WhatIf:$false | Out-Null
$stamp = Get-Date -Format yyyyMMdd-HHmmss-fff
$safeName = ($VdsName + $(if ($VMHost) { "_$VMHost" })) -replace '[^\w-]', '_'
Start-Transcript -Path (Join-Path $OutputFolder "Invoke-VdsPlan_${Part}_${safeName}_$stamp.transcript.txt") -WhatIf:$false | Out-Null
$log = New-Object System.Collections.ArrayList
function Write-Step([string] $Object, [string] $Action, [string] $Result) {
    [void]$log.Add([pscustomobject]@{ Time = (Get-Date -Format s); Vds = $VdsName; Part = $Part; Object = $Object; Action = $Action; Result = $Result })
    Write-Output "${Object}: $Action - $Result"
}

try {
    $plan = Get-VdsPlan -Path $PlanFile
    Write-Output "Plan '$($plan.draft)' version $($plan.version) for $($plan.vcenter), committed by $($plan.committedBy) at $($plan.committedAt)."
    $v = @($plan.vds) | Where-Object name -eq $VdsName
    if (-not $v) { throw "The plan has no VDS $VdsName. VDS in the plan: $((@($plan.vds).name) -join ', ')." }
    if (@($global:DefaultVIServers).Name -notcontains $plan.vcenter) { throw "Connect to $($plan.vcenter) first. The plan is for that vCenter only." }
    $uplinks = 1..([int]$v.uplinkCount) | ForEach-Object { "dvUplink$_" }

    if ($Part -eq 'Switch') {
        # all read-only checks first. A blocking finding stops the script before it changes anything.
        $findings = @(Get-VdsPlanLiveFinding -Plan $plan -Vds $v)
        foreach ($f in $findings) {
            if ($f.Level -eq 'Warn') { Write-Warning "$($f.Object): $($f.Finding)" }
            Write-Step $f.Object "Check ($($f.Level))" $f.Finding
        }
        $blocks = @($findings | Where-Object Level -eq 'Block')
        if ($blocks.Count) { throw "$($blocks.Count) blocking findings for $VdsName. The script changed nothing. Correct the findings (see the log), then run again." }
        $clusters = foreach ($c in @($v.clusters)) { Get-Cluster -Name $c }
        $dcs = @($clusters | ForEach-Object { Get-Datacenter -Cluster $_ } | Sort-Object Name -Unique)

        $vds = Get-VDSwitch -Name $VdsName -ErrorAction SilentlyContinue
        if ($vds) {
            Write-Step $VdsName 'Create VDS' 'Exists, not changed'
        }
        elseif ($PSCmdlet.ShouldProcess("$VdsName in $($dcs[0].Name)", "Create VDS version $($v.version), $($v.uplinkCount) uplinks, MTU $($v.mtu)")) {
            $vds = New-VDSwitch -Name $VdsName -Location $dcs[0] -Version $v.version -NumUplinkPorts ([int]$v.uplinkCount) -Mtu ([int]$v.mtu) `
                -LinkDiscoveryProtocol LLDP -LinkDiscoveryProtocolOperation Both
            Write-Step $VdsName 'Create VDS' 'Done'
        }
        if ($vds) {
            $names = @($vds.ExtensionData.Config.UplinkPortPolicy.UplinkPortName)
            if (Compare-Object $names $uplinks) { throw "The uplink names of $VdsName are $($names -join ', '). The plan expects $($uplinks -join ', ')." }
        }

        foreach ($p in @($v.portGroups)) {
            $vlanText = switch ($p.vlanType) { 'vlan' { "VLAN $($p.vlan)" } 'trunk' { "trunk $($p.trunk)" } default { 'no VLAN' } }
            $what = if ($p.binding -eq 'static') { "static, $($p.ports) ports, $($p.allocation)" } else { 'ephemeral' }
            if ($vds -and (Get-VDPortgroup -VDSwitch $vds -Name $p.name -ErrorAction SilentlyContinue)) { Write-Step $p.name 'Create port group' 'Exists, not changed'; continue }
            if (-not $PSCmdlet.ShouldProcess("$VdsName / $($p.name)", "Create port group ($vlanText, $what, $($p.loadBalancing))")) { continue }

            $pgArgs = @{ VDSwitch = $vds; Name = $p.name; PortBinding = $(if ($p.binding -eq 'static') { 'Static' } else { 'Ephemeral' }) }
            if ($p.binding -eq 'static') { $pgArgs.NumPorts = [int]$p.ports }
            if ($p.vlanType -eq 'vlan') { $pgArgs.VlanId = [int]$p.vlan }
            if ($p.vlanType -eq 'trunk') { $pgArgs.VlanTrunkRange = $p.trunk }
            $pg = New-VDPortgroup @pgArgs

            if ($p.binding -eq 'static') {
                # elastic or fixed port allocation has no PowerCLI parameter, so set it with the vSphere API
                $spec = New-Object VMware.Vim.DVPortgroupConfigSpec
                $spec.ConfigVersion = $pg.ExtensionData.Config.ConfigVersion
                $spec.AutoExpand = ($p.allocation -eq 'elastic')
                $pg.ExtensionData.ReconfigureDVPortgroup($spec)
            }
            $team = @{ LoadBalancingPolicy = $p.loadBalancing; ActiveUplinkPort = @($p.active) }
            if (@($p.standby).Count) { $team.StandbyUplinkPort = @($p.standby) }
            $unused = @($uplinks | Where-Object { @($p.active) -notcontains $_ -and @($p.standby) -notcontains $_ })
            if ($unused.Count) { $team.UnusedUplinkPort = $unused }
            $pg | Get-VDUplinkTeamingPolicy | Set-VDUplinkTeamingPolicy @team | Out-Null
            $pg | Get-VDSecurityPolicy | Set-VDSecurityPolicy -AllowPromiscuous $p.allowPromiscuous -MacChanges $p.macChanges -ForgedTransmits $p.forgedTransmits | Out-Null
            Write-Step $p.name 'Create port group' "Done ($vlanText, $what)"
        }

        foreach ($cl in $clusters) {
            $missing = @(Get-VMHost -Location $cl | Where-Object { -not $vds -or ($vds | Get-VMHost).Name -notcontains $_.Name })
            if (-not $missing.Count) { Write-Step $cl.Name 'Add hosts' 'All hosts are on the VDS'; continue }
            if ($PSCmdlet.ShouldProcess(($missing.Name -join ', '), "Add hosts of $($cl.Name) to $VdsName with no uplink")) {
                Add-VDSwitchVMHost -VDSwitch $vds -VMHost $missing
                Write-Step $cl.Name 'Add hosts' "Done ($($missing.Count) hosts, no uplink)"
            }
        }
        $vmkHosts = @($v.vmkernel | Where-Object { $_ } | ForEach-Object { @($_.hosts).host } | Sort-Object -Unique)
        if ($vmkHosts.Count) { Write-Output "The plan has new VMkernel adapters for $($vmkHosts.Count) hosts. After Move-HostToVds.ps1, run -Part VMkernel -VMHost <host> for each host." }
    }
    else {
        $entries = @($v.vmkernel | Where-Object { $_ -and (@($_.hosts).host -contains $VMHost) })
        if (-not $entries.Count) { throw "The plan has no new VMkernel adapter for $VMHost on $VdsName." }
        $vds = Get-VDSwitch -Name $VdsName
        $vmh = Get-VMHost -Name $VMHost
        if (($vds | Get-VMHost).Name -notcontains $vmh.Name) { throw "$VMHost is not on $VdsName. Run -Part Switch first." }
        if (-not @(Get-VMHostNetworkAdapter -VMHost $vmh -VirtualSwitch $vds -Physical).Count) {
            throw "$VMHost has no uplink on $VdsName. Move the uplinks first with Move-HostToVds.ps1."
        }
        $nicTypes = @{ Provisioning = 'vSphereProvisioning'; Replication = 'vSphereReplication'; NfcReplication = 'vSphereReplicationNFC' }
        foreach ($k in $entries) {
            $row = @($k.hosts) | Where-Object host -eq $VMHost | Select-Object -First 1
            $label = "$VMHost $($row.ip)/$($row.mask)"
            if (Get-VMHostNetworkAdapter -VMHost $vmh -VMKernel | Where-Object IP -eq $row.ip) { Write-Step $label "Add $($k.service) VMkernel adapter" 'Exists, not changed'; continue }
            $then = if ($k.service -eq 'vMotion' -and $k.disableVmotionOnVmk0) { ', then turn off vMotion on vmk0' } else { '' }
            if (-not $PSCmdlet.ShouldProcess("$label on $VdsName / $($k.portGroup)", "Add VMkernel adapter for $($k.service), stack $($k.stack), MTU $($k.mtu)$then")) { continue }

            $na = @{ VMHost = $vmh; VirtualSwitch = $vds; PortGroup = $k.portGroup; IP = $row.ip; SubnetMask = $row.mask; Mtu = [int]$k.mtu; Confirm = $false }
            if ($k.stack -ne 'defaultTcpipStack') { $na.NetworkStack = Get-VMHostNetworkStack -VMHost $vmh -Id $k.stack }
            switch ($k.service) {
                'vMotion'        { if ($k.stack -eq 'defaultTcpipStack') { $na.VMotionEnabled = $true } }
                'Management'     { $na.ManagementTrafficEnabled = $true }
                'vSAN'           { $na.VsanTrafficEnabled = $true }
                'FaultTolerance' { $na.FaultToleranceLoggingEnabled = $true }
            }
            $nic = New-VMHostNetworkAdapter @na
            if ($nicTypes[$k.service] -and $k.stack -eq 'defaultTcpipStack') {
                # these services have no PowerCLI parameter, so tag the adapter with the vSphere API
                (Get-View $vmh.ExtensionData.ConfigManager.VirtualNicManager).SelectVnicForNicType($nicTypes[$k.service], $nic.Name)
            }
            Write-Step $label "Add $($k.service) VMkernel adapter" "Done ($($nic.Name))"

            if ($k.service -eq 'vMotion' -and $k.disableVmotionOnVmk0) {
                $vmk0 = Get-VMHostNetworkAdapter -VMHost $vmh -VMKernel -Name vmk0
                if ($vmk0.VMotionEnabled -and $PSCmdlet.ShouldProcess("$VMHost vmk0", 'Turn off vMotion')) {
                    Set-VMHostNetworkAdapter -VirtualNic $vmk0 -VMotionEnabled $false -Confirm:$false | Out-Null
                    Write-Step "$VMHost vmk0" 'Turn off vMotion' 'Done'
                }
            }
        }
    }
}
finally {
    if ($log.Count) { $log | Export-Csv (Join-Path $OutputFolder "Invoke-VdsPlan_${Part}_${safeName}_$stamp.csv") -NoTypeInformation -Encoding UTF8 -WhatIf:$false }
    Stop-Transcript | Out-Null
}
