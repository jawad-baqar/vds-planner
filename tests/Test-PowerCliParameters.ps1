# Checks that each PowerCLI command and parameter that the toolkit uses exists in the installed PowerCLI.
# Needs PowerCLI. Needs no vCenter. Run: .\tests\Test-PowerCliParameters.ps1
[CmdletBinding()]
param([string] $Root)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path $PSScriptRoot '..' }
$WarningPreference = 'SilentlyContinue'
$mods = 'VMware.VimAutomation.Core', 'VMware.VimAutomation.Vds'
$loaded = @()
foreach ($m in $mods) {
    try { Import-Module $m -ErrorAction Stop 3>$null; $loaded += $m } catch { Write-Output "SKIP module $m is not installed. Its commands are not checked." }
}
if (-not $loaded) { Write-Output 'SKIP PowerCLI is not installed.'; return }

# parameters given with a hashtable (splat) in the scripts
$splats = @{
    'Invoke-VdsPlan.ps1|New-VDPortgroup'           = 'VDSwitch', 'Name', 'PortBinding', 'NumPorts', 'VlanId', 'VlanTrunkRange'
    'Invoke-VdsPlan.ps1|Set-VDUplinkTeamingPolicy' = 'LoadBalancingPolicy', 'ActiveUplinkPort', 'StandbyUplinkPort', 'UnusedUplinkPort'
    'Invoke-VdsPlan.ps1|New-VMHostNetworkAdapter'  = 'VMHost', 'VirtualSwitch', 'PortGroup', 'IP', 'SubnetMask', 'Mtu', 'Confirm', 'NetworkStack', 'VMotionEnabled', 'ManagementTrafficEnabled', 'VsanTrafficEnabled', 'FaultToleranceLoggingEnabled'
}
$fail = 0; $okCount = 0; $skip = 0; $skipped = @{}
$files = @(Get-ChildItem (Join-Path $Root 'scripts') -Recurse -Include *.ps1, *.psm1) + @(Get-ChildItem (Join-Path $Root 'samples\demo-package') -Filter *.ps1 -ErrorAction SilentlyContinue)
foreach ($f in $files) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $c.GetCommandName()
        if (-not $name) { continue }
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $cmd -or $mods -notcontains $cmd.ModuleName) {
            if ($name -cmatch '^(New|Get|Set|Add|Remove)-(VD[A-Z]|VMHost|VirtualSwitch|VirtualPortGroup)' -and -not $cmd) {
                if (-not $skipped.ContainsKey($name)) { Write-Output "SKIP $name (module not installed)" }
                $skipped[$name] = 1; $skip++
            }
            continue
        }
        $params = @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object ParameterName)
        $splatKey = "$($f.Name)|$name"
        if ($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted }) {
            if ($splats.ContainsKey($splatKey)) { $params += $splats[$splatKey] } else { Write-Output "FAIL $($f.Name): $name uses a splat that the test does not know"; $fail++ }
        }
        foreach ($p in ($params | Sort-Object -Unique)) {
            if ($cmd.Parameters.ContainsKey($p)) { $okCount++ }
            else { Write-Output "FAIL $($f.Name) line $($c.Extent.StartLineNumber): $name has no parameter -$p"; $fail++ }
        }
    }
}
Write-Output "PowerCLI parameter check: $okCount parameters correct, $fail wrong, $skip commands not checked. Modules: $($loaded -join ', ')."
if ($fail) { exit 1 }
