# Pester 5: static checks that need no vCenter. Run: Invoke-Pester .\tests
Describe 'Toolkit scripts' {
    $scripts = Get-ChildItem (Join-Path $PSScriptRoot '..\scripts') -Recurse -Filter *.ps1
    It '<_.Name> parses with no errors' -ForEach $scripts {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
    It '<_.Name> supports -WhatIf if it changes the environment' -ForEach ($scripts | Where-Object { $_.BaseName -notmatch '^(Get|Export)-' }) {
        (Get-Content $_.FullName -Raw) | Should -Match 'SupportsShouldProcess'
    }
    It '<_.Name> has no $PSScriptRoot in a param() default (empty under powershell.exe -File in 5.1)' -ForEach $scripts {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
        @($ast.ParamBlock.Parameters | Where-Object { $_.DefaultValue -and $_.DefaultValue.Extent.Text -match 'PSScriptRoot' }) | Should -BeNullOrEmpty
    }
    It '<_.Name> has no semicolons in its help text' -ForEach $scripts {
        $help = [regex]::Match((Get-Content $_.FullName -Raw), '(?s)<#.*?#>').Value
        $help | Should -Not -Match ';'
    }
}
