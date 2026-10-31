<#
.SYNOPSIS
Reads the sheets of an .xlsx workbook with no Excel and no extra module.

.DESCRIPTION
Get-WorkbookSheet returns the names of the sheets in a workbook.
Import-WorkbookSheet returns the rows of one sheet as objects. The first row gives the property names.
The module reads the file only. It does not change the workbook. It opens the file with read sharing, so the workbook can be open in Excel.
#>

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

function Open-Workbook([string] $Path) {
    $fs = [System.IO.File]::Open((Resolve-Path $Path).Path, 'Open', 'Read', 'ReadWrite')
    New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
}

function Read-ZipXml($Zip, [string] $Name) {
    $e = $Zip.GetEntry($Name)
    if (-not $e) { return $null }
    $r = New-Object System.IO.StreamReader($e.Open())
    try { $x = New-Object System.Xml.XmlDocument; $x.LoadXml($r.ReadToEnd()); $x } finally { $r.Dispose() }
}

function Get-SheetMap($Zip) {
    $wb = Read-ZipXml $Zip 'xl/workbook.xml'
    $rels = Read-ZipXml $Zip 'xl/_rels/workbook.xml.rels'
    $targets = @{}
    foreach ($r in $rels.Relationships.Relationship) { $targets[$r.Id] = $r.Target }
    $map = [ordered]@{}
    foreach ($s in $wb.workbook.sheets.sheet) {
        $id = $s.GetAttribute('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
        $t = $targets[$id] -replace '^/', ''
        if ($t -notmatch '^xl/') { $t = 'xl/' + $t }
        $map[$s.name] = $t
    }
    $map
}

function Get-WorkbookSheet {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    $zip = Open-Workbook $Path
    try { @((Get-SheetMap $zip).Keys) } finally { $zip.Dispose() }
}

function Import-WorkbookSheet {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Sheet, [int] $MaxRows = 0)
    $zip = Open-Workbook $Path
    try {
        $map = Get-SheetMap $zip
        if (-not $map.Contains($Sheet)) { return }
        $shared = @()
        $ss = Read-ZipXml $zip 'xl/sharedStrings.xml'
        if ($ss) { $shared = @($ss.sst.si | ForEach-Object { $_.InnerText }) }
        $doc = Read-ZipXml $zip $map[$Sheet]
        $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
        $ns.AddNamespace('m', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
        $head = $null; $n = 0
        foreach ($row in $doc.SelectNodes('//m:sheetData/m:row', $ns)) {
            $cells = @{}; $max = -1
            foreach ($c in $row.SelectNodes('m:c', $ns)) {
                $ref = $c.GetAttribute('r') -replace '\d', ''
                $col = 0; foreach ($ch in $ref.ToCharArray()) { $col = $col * 26 + ([int][char]$ch - 64) }; $col--
                $v = $c.SelectSingleNode('m:v', $ns)
                $val = switch ($c.GetAttribute('t')) {
                    's' { if ($v) { $shared[[int]$v.InnerText] } }
                    'inlineStr' { $c.SelectSingleNode('m:is', $ns).InnerText }
                    'b' { if ($v) { [bool][int]$v.InnerText } }
                    default { if ($v) { $v.InnerText } }
                }
                $cells[$col] = $val; if ($col -gt $max) { $max = $col }
            }
            if (-not $head) {
                $head = @(0..$max | ForEach-Object { if ($cells.ContainsKey($_) -and "$($cells[$_])") { "$($cells[$_])" } else { "Column$($_ + 1)" } })
                continue
            }
            $o = [ordered]@{}
            for ($i = 0; $i -lt $head.Count; $i++) { $o[$head[$i]] = $(if ($cells.ContainsKey($i)) { $cells[$i] } else { '' }) }
            [pscustomobject]$o
            $n++
            if ($MaxRows -and $n -ge $MaxRows) { break }
        }
    }
    finally { $zip.Dispose() }
}

Export-ModuleMember -Function Get-WorkbookSheet, Import-WorkbookSheet
