# Pester 5: checks of the VDS plan module that need no vCenter. Run: Invoke-Pester .\tests
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\lib\VdsPlan.psm1') -Force
    $samplePath = Join-Path $PSScriptRoot '..\samples\plan-cluster01-v1.sample.json'
    function Get-Sample { Get-Content $samplePath -Raw | ConvertFrom-Json }
}

Describe 'Test-VdsPlan' {
    It 'finds no error in the sample plan' {
        @(Test-VdsPlan -Plan (Get-Sample)) | Should -BeNullOrEmpty
    }
    It 'stops a VDS with one uplink (V-02)' {
        $p = Get-Sample
        $p.vds[0].uplinkCount = 1
        (Test-VdsPlan -Plan $p) -join "`n" | Should -Match 'V-02'
    }
    It 'stops a VDS for two clusters with no passed shared-VDS check (V-08)' {
        $p = Get-Sample
        $p.vds[0].clusters = @('Cluster01', 'Cluster02')
        (Test-VdsPlan -Plan $p) -join "`n" | Should -Match 'V-08'
    }
    It 'stops an uplink that is not on the VDS' {
        $p = Get-Sample
        $p.vds[0].portGroups[0].active = @('dvUplink3')
        (Test-VdsPlan -Plan $p) -join "`n" | Should -Match "uplink 'dvUplink3' is not on the VDS"
    }
    It 'stops a VLAN trunk range above 4094' {
        $p = Get-Sample
        $p.vds[0].portGroups[3].trunk = '0-4095'
        (Test-VdsPlan -Plan $p) -join "`n" | Should -Match 'trunk range'
    }
    It 'stops a static port group with no ports' {
        $p = Get-Sample
        $p.vds[0].portGroups[2].ports = 0
        (Test-VdsPlan -Plan $p) -join "`n" | Should -Match 'number of ports'
    }
    It 'stops two port groups with the same name' {
        $p = Get-Sample
        $p.vds[0].portGroups[1].name = $p.vds[0].portGroups[0].name
        (Test-VdsPlan -Plan $p) -join "`n" | Should -Match 'more than one time'
    }
}

Describe 'Test-VdsPlan with a shared VDS and new VMkernel adapters' {
    BeforeAll {
        $demoPath = Join-Path $PSScriptRoot '..\samples\demo-package\plan-shared-db-vds-v1.json'
        function Get-Demo { Get-Content $demoPath -Raw | ConvertFrom-Json }
    }
    It 'reads the demo package plan when the hash is correct' {
        $p = Get-VdsPlan -Path $demoPath
        $p.vds[0].shared | Should -BeTrue
        @($p.vds[0].vmkernel[0].hosts).Count | Should -Be 6
    }
    It 'stops members that are not the clusters' {
        $p = Get-Demo
        $p.vds[0].members[1].cluster = 'Cluster09'
        (Test-VdsPlan -Plan $p) -join "`n" | Should -Match 'members are not the same'
    }
    It 'stops a VMkernel adapter on a port group that is not on the VDS' {
        $p = Get-Demo
        $p.vds[0].vmkernel[0].portGroup = 'nothing'
        (Test-VdsPlan -Plan $p) -join "`n" | Should -Match 'port group is not on the VDS'
    }
    It 'stops a vMotion stack for another service' {
        $p = Get-Demo
        $p.vds[0].vmkernel[0].service = 'Management'
        (Test-VdsPlan -Plan $p) -join "`n" | Should -Match 'stack is for vMotion only'
    }
    It 'stops a VMkernel MTU above the VDS MTU' {
        $p = Get-Demo
        $p.vds[0].mtu = 1500
        (Test-VdsPlan -Plan $p) -join "`n" | Should -Match 'not more than the VDS MTU'
    }
    It 'stops a bad IP address, a bad mask and a duplicate IP address' {
        $p = Get-Demo
        $h = $p.vds[0].vmkernel[0].hosts
        $h[0].ip = '10.0.20.300'
        $h[1].mask = '255.0.255.0'
        $h[3].ip = $h[2].ip
        $text = (Test-VdsPlan -Plan $p) -join "`n"
        $text | Should -Match 'no valid IP address'
        $text | Should -Match 'no valid subnet mask'
        $text | Should -Match 'used more than one time'
    }
}

Describe 'Get-VdsPlan' {
    It 'reads the sample plan when the hash is correct' {
        (Get-VdsPlan -Path $samplePath).vds[0].name | Should -Be 'Cluster01-vds01'
    }
    It 'stops when the plan file changed after the commit' {
        $f = Join-Path $TestDrive 'plan.json'
        Copy-Item $samplePath $f
        Copy-Item "$samplePath.sha256" "$f.sha256"
        Add-Content $f ' '
        { Get-VdsPlan -Path $f } | Should -Throw '*changed after the commit*'
    }
    It 'stops when the hash file is missing' {
        $f = Join-Path $TestDrive 'nohash.json'
        Copy-Item $samplePath $f
        { Get-VdsPlan -Path $f } | Should -Throw '*hash file*'
    }
}
