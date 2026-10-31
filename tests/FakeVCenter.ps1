# A small fake vCenter for tests that need no vCenter and no PowerCLI.
# Dot-source it: . .\tests\FakeVCenter.ps1
# The functions have the names of the PowerCLI commands that the toolkit uses. A function comes before a cmdlet,
# so the toolkit scripts call these functions. Each change command records its parameters in $global:Calls.
# The fake vCenter state is $global:FakeVc (not a short name: the scripts have variables like $f, and names are not case-sensitive).
if (-not ('VMware.Vim.DVPortgroupConfigSpec' -as [type])) {
    Add-Type -TypeDefinition 'namespace VMware.Vim { public class DVPortgroupConfigSpec { public string ConfigVersion; public bool? AutoExpand; } }'
}
$global:Calls = New-Object System.Collections.ArrayList
function global:Rec([string] $Cmd, $Bound, $Extra) {
    $h = @{}; foreach ($k in $Bound.Keys) { if ($k -ne 'InputObject' -and $k -ne 'ErrorAction') { $h[$k] = $Bound[$k] } }
    if ($Extra) { foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] } }
    [void]$global:Calls.Add([pscustomobject]@{ Cmd = $Cmd; P = $h })
}
function global:Reset-Fake {
    $global:Calls.Clear()
    $global:FakeVc = @{
        Clusters = @{ Cluster02 = 'DC-A'; Cluster04 = 'DC-A' }
        Hosts    = @{ Cluster02 = @('esx11', 'esx12', 'esx13'); Cluster04 = @('esx21', 'esx22', 'esx23') }
        Version  = @{}; State = @{}; SwNics = @{}
        Vds      = @{}; Uplinks = @{}; Vmk = @{}; Seq = 5
    }
    foreach ($c in @($global:FakeVc.Hosts.Keys)) { $global:FakeVc.Hosts[$c] = @($global:FakeVc.Hosts[$c] | ForEach-Object { "$_.example.local" }) }
    foreach ($h in ($global:FakeVc.Hosts.Values | ForEach-Object { $_ })) { $global:FakeVc.Vmk[$h] = New-Object System.Collections.ArrayList; [void]$global:FakeVc.Vmk[$h].Add([pscustomobject]@{ Name = 'vmk0'; IP = '10.0.10.' + ($h -replace '\D', ''); VMotionEnabled = $true; Switch = 'vSwitch0'; PortGroupName = 'Management Network' }) }
    $global:DefaultVIServers = @([pscustomobject]@{ Name = 'vc01.example.local' })
}
function global:New-FakeVds([string] $Name, [string] $Dc, [int] $Uplinks, [string] $Version = '8.0.3') {
    $v = [pscustomobject]@{ Name = $Name; NumUplinkPorts = $Uplinks; Version = $Version; Datacenter = $Dc; Hosts = (New-Object System.Collections.ArrayList); Pgs = @{}
        ExtensionData = [pscustomobject]@{ Config = [pscustomobject]@{ UplinkPortPolicy = [pscustomobject]@{ UplinkPortName = @(1..$Uplinks | ForEach-Object { "dvUplink$_" }) } } } }
    $global:FakeVc.Vds[$Name] = $v; $v
}
function global:New-FakePg($Vds, [string] $Name) {
    $ed = [pscustomobject]@{ Config = [pscustomobject]@{ ConfigVersion = '1' }; Vm = @() }
    $ed | Add-Member ScriptMethod ReconfigureDVPortgroup { param($spec) Rec 'ReconfigureDVPortgroup' @{} @{ AutoExpand = $spec.AutoExpand } }
    $pg = [pscustomobject]@{ Name = $Name; VDSwitch = $Vds; ExtensionData = $ed }
    $Vds.Pgs[$Name] = $pg; $pg
}
function global:Get-Cluster { param($Name, $ErrorAction) if ($global:FakeVc.Clusters.ContainsKey($Name)) { [pscustomobject]@{ Name = $Name } } elseif ($ErrorAction -ne 'SilentlyContinue') { throw "Cluster $Name not found" } }
function global:Get-Datacenter { param($Cluster) [pscustomobject]@{ Name = $global:FakeVc.Clusters[$Cluster.Name] } }
function global:Get-VMHost {
    param([Parameter(ValueFromPipeline)] $InputObject, $Location, $Name)
    process {
        $mk = { param($n) [pscustomobject]@{ Name = $n; ConnectionState = $(if ($global:FakeVc.State[$n]) { $global:FakeVc.State[$n] } else { 'Connected' }); Version = $(if ($global:FakeVc.Version[$n]) { $global:FakeVc.Version[$n] } else { '8.0.3' })
                ExtensionData = [pscustomobject]@{ ConfigManager = [pscustomobject]@{ VirtualNicManager = "vnm-$n" } } } }
        if ($InputObject) { $InputObject.Hosts | ForEach-Object { & $mk $_ } }
        elseif ($Location) { $global:FakeVc.Hosts[$Location.Name] | ForEach-Object { & $mk $_ } }
        elseif ($Name) { & $mk $Name }
    }
}
function global:Get-VirtualSwitch { param($VMHost, [switch] $Standard, $Name, $ErrorAction)
    # SwNics: key "host|switch" (the uplinks of one switch) or "host" (all switches of the host)
    $nicsOf = { param($sw) if ($global:FakeVc.SwNics.ContainsKey("$($VMHost.Name)|$sw")) { @($global:FakeVc.SwNics["$($VMHost.Name)|$sw"]) } elseif ($global:FakeVc.SwNics.ContainsKey($VMHost.Name)) { @($global:FakeVc.SwNics[$VMHost.Name]) } else { @('vmnic0', 'vmnic1') } }
    if ($global:FakeVc.SwOf -and $global:FakeVc.SwOf.ContainsKey($VMHost.Name)) {
        $list = @($global:FakeVc.SwOf[$VMHost.Name])
        if ($Name) { if ($list -contains $Name) { return [pscustomobject]@{ Name = $Name; Nic = (& $nicsOf $Name); Mtu = 1500 } } else { return } }
        return $list | ForEach-Object { [pscustomobject]@{ Name = $_; Nic = (& $nicsOf $_); Mtu = 1500 } }
    }
    if ($Name) { return [pscustomobject]@{ Name = $Name; Nic = (& $nicsOf $Name); Mtu = 1500 } }
    # no name: all standard switches of the host, with the iDRAC USB switch that the export must leave out (V-10)
    [pscustomobject]@{ Name = 'vSwitch0'; Nic = (& $nicsOf 'vSwitch0'); Mtu = 1500 }
    [pscustomobject]@{ Name = 'vSwitchBMC'; Nic = @(); Mtu = 1500 } }
function global:Get-VirtualPortGroup { param($VirtualSwitch, [switch] $Standard, $VMHost, $Name)
    if ($VirtualSwitch.Name -ne 'vSwitch0') { return [pscustomobject]@{ Name = 'BMC Network'; VLanId = 0 } }
    [pscustomobject]@{ Name = 'Management Network'; VLanId = 10 }
    [pscustomobject]@{ Name = 'DB-Prod-Ünïcode'; VLanId = 210 }
    [pscustomobject]@{ Name = 'Appliance trunk'; VLanId = 4095 }
    if ($global:FakeVc.PartialPg) { [pscustomobject]@{ Name = 'Partial'; VLanId = 77 } }
    $global:FakeVc.PartialPg = $false }
function global:Get-VDSwitch { param($Name, $Location, $ErrorAction)
    if ($Name) { $v = $global:FakeVc.Vds[$Name]; if (-not $v -and $ErrorAction -ne 'SilentlyContinue') { throw "VDS $Name not found" }; return $v }
    if ($Location) { $global:FakeVc.Vds.Values | Where-Object Datacenter -eq $Location.Name } }
function global:New-VDSwitch { param($Name, $Location, $Version, $NumUplinkPorts, $Mtu, $LinkDiscoveryProtocol, $LinkDiscoveryProtocolOperation)
    Rec 'New-VDSwitch' $PSBoundParameters; New-FakeVds $Name $Location.Name $NumUplinkPorts $Version }
function global:Get-VDPortgroup { param($VDSwitch, $Name, $ErrorAction) if ($Name) { $VDSwitch.Pgs[$Name] } else { $VDSwitch.Pgs.Values } }
function global:New-VDPortgroup { param($VDSwitch, $Name, $NumPorts, $VlanId, $VlanTrunkRange, $PortBinding)
    Rec 'New-VDPortgroup' $PSBoundParameters; New-FakePg $VDSwitch $Name }
function global:Get-VDUplinkTeamingPolicy { param([Parameter(ValueFromPipeline)] $InputObject) process { [pscustomobject]@{ Pg = $InputObject.Name } } }
function global:Set-VDUplinkTeamingPolicy { param([Parameter(ValueFromPipeline)] $InputObject, $LoadBalancingPolicy, $ActiveUplinkPort, $StandbyUplinkPort, $UnusedUplinkPort)
    process { Rec 'Set-VDUplinkTeamingPolicy' $PSBoundParameters @{ Pg = $InputObject.Pg } } }
function global:Get-VDSecurityPolicy { param([Parameter(ValueFromPipeline)] $InputObject) process { [pscustomobject]@{ Pg = $InputObject.Name } } }
function global:Set-VDSecurityPolicy { param([Parameter(ValueFromPipeline)] $InputObject, $AllowPromiscuous, $MacChanges, $ForgedTransmits)
    process { Rec 'Set-VDSecurityPolicy' $PSBoundParameters @{ Pg = $InputObject.Pg } } }
function global:Add-VDSwitchVMHost { param($VDSwitch, $VMHost) Rec 'Add-VDSwitchVMHost' @{ VDSwitch = $VDSwitch.Name; VMHost = @($VMHost.Name) }; foreach ($h in $VMHost) { [void]$VDSwitch.Hosts.Add($h.Name) } }
function global:Remove-VDSwitch { param($VDSwitch, $Confirm) Rec 'Remove-VDSwitch' @{ VDSwitch = $VDSwitch.Name }; $global:FakeVc.Vds.Remove($VDSwitch.Name) }
function global:Get-VMHostNetworkAdapter { param($VMHost, $VirtualSwitch, [switch] $Physical, [switch] $VMKernel, $Name, $ErrorAction)
    if ($Physical -and $Name -and -not $VirtualSwitch) { return [pscustomobject]@{ Name = $Name; BitRatePerSec = 10000 } }
    if ($Physical) { return @($global:FakeVc.Uplinks[$VMHost.Name] | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Name = $_ } }) }
    $list = @($global:FakeVc.Vmk[$VMHost.Name] | Where-Object { $_ })
    if ($VirtualSwitch) { $list = @($list | Where-Object Switch -eq $VirtualSwitch.Name) }
    if ($Name) { $list = @($list | Where-Object Name -eq $Name) }
    $list }
function global:Get-VMHostNetworkStack { param($VMHost, $Id) [pscustomobject]@{ Id = $Id } }
function global:New-VMHostNetworkAdapter { param($VMHost, $VirtualSwitch, $PortGroup, $IP, $SubnetMask, $Mtu, $Confirm, $NetworkStack, $VMotionEnabled, $ManagementTrafficEnabled, $VsanTrafficEnabled, $FaultToleranceLoggingEnabled)
    Rec 'New-VMHostNetworkAdapter' $PSBoundParameters @{ VMHost = $VMHost.Name; NetworkStack = $NetworkStack.Id }
    $n = [pscustomobject]@{ Name = "vmk$($global:FakeVc.Seq)"; IP = $IP; VMotionEnabled = [bool]$VMotionEnabled; Switch = $VirtualSwitch.Name }; $global:FakeVc.Seq++
    [void]$global:FakeVc.Vmk[$VMHost.Name].Add($n); $n }
function global:Set-VMHostNetworkAdapter { param($VirtualNic, $VMotionEnabled, $Confirm) Rec 'Set-VMHostNetworkAdapter' @{ VirtualNic = $VirtualNic.Name; VMotionEnabled = $VMotionEnabled }; $VirtualNic.VMotionEnabled = $VMotionEnabled }
function global:Get-View { param($VIObject) $o = [pscustomobject]@{ Id = $VIObject }; $o | Add-Member ScriptMethod SelectVnicForNicType { param($t, $d) Rec 'SelectVnicForNicType' @{} @{ NicType = $t; Device = $d } }; $o }
function global:Connect-VIServer { param($Server, $Credential) Rec 'Connect-VIServer' @{ Server = $Server; User = $Credential.UserName }; $global:DefaultVIServers = @([pscustomobject]@{ Name = $Server }); $global:DefaultVIServers[0] }
function global:Disconnect-VIServer { param($Server, $Confirm) Rec 'Disconnect-VIServer' @{} }
function global:Get-Credential { param($UserName, $Message) New-Object pscredential ($UserName, (ConvertTo-SecureString 'not-a-real-secret' -AsPlainText -Force)) }
