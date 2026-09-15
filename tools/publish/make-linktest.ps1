<#
.SYNOPSIS
    Generate a throwaway linktest.pdf for the share-link stability test.

.DESCRIPTION
    Writes a minimal but valid PDF whose page count and cover text both encode
    the revision number, so each revision is unmistakably different from the
    last when you open the share URL in a browser.

    This exists for one job: proving that replacing a file through publish.ps1
    keeps its Dropbox share link alive. Run it, publish, check the link, then
    run it again with a higher -Revision and publish again.

    No external dependency - the PDF is emitted byte by byte with a correct
    xref table, so it does not need LaTeX or any PDF library.

.PARAMETER Revision
    Revision number. Also becomes the page count, so revision 3 is a 3-page PDF.

.PARAMETER Path
    Output file. Default: %USERPROFILE%\website-materials\linktest.pdf

.EXAMPLE
    .\make-linktest.ps1 -Revision 1

.EXAMPLE
    .\make-linktest.ps1 -Revision 2
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 20)]
    [int]    $Revision = 1,
    [string] $Path = (Join-Path (Join-Path $env:USERPROFILE 'website-materials') 'linktest.pdf')
)

$ErrorActionPreference = 'Stop'

$pageCount = $Revision
$stamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'

# Object numbering:
#   1                 catalog
#   2                 page tree
#   3                 font
#   4 + 2i            page i
#   5 + 2i            contents for page i
$objCount = 3 + (2 * $pageCount)

$objects = New-Object 'System.Collections.Generic.List[string]'

$kids = @()
for ($i = 0; $i -lt $pageCount; $i++) { $kids += ('{0} 0 R' -f (4 + 2 * $i)) }

$objects.Add('<< /Type /Catalog /Pages 2 0 R >>')
$objects.Add('<< /Type /Pages /Kids [' + ($kids -join ' ') + '] /Count ' + $pageCount + ' >>')
$objects.Add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')

for ($i = 0; $i -lt $pageCount; $i++) {
    $contentObjNum = 5 + 2 * $i
    $pageNo = $i + 1

    $lines = @(
        'BT /F1 28 Tf 72 700 Td (LINKTEST REVISION ' + $Revision + ') Tj ET',
        'BT /F1 14 Tf 72 660 Td (Page ' + $pageNo + ' of ' + $pageCount + ') Tj ET',
        'BT /F1 14 Tf 72 630 Td (Generated ' + $stamp + ') Tj ET',
        'BT /F1 11 Tf 72 590 Td (If this share link still resolves and shows REVISION ' + $Revision + ',) Tj ET',
        'BT /F1 11 Tf 72 572 Td (then overwriting the file preserved its Dropbox file object.) Tj ET'
    )
    $stream = ($lines -join "`n")

    $objects.Add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents ' +
                 $contentObjNum + ' 0 R /Resources << /Font << /F1 3 0 R >> >> >>')
    $objects.Add('<< /Length ' + $stream.Length + " >>`nstream`n" + $stream + "`nendstream")
}

# --- assemble, tracking byte offsets for the xref table ---
$sb      = New-Object System.Text.StringBuilder
$offsets = New-Object 'System.Collections.Generic.List[int]'

[void]$sb.Append("%PDF-1.4`n")

for ($n = 1; $n -le $objCount; $n++) {
    $offsets.Add($sb.Length)
    [void]$sb.Append($n.ToString() + " 0 obj`n" + $objects[$n - 1] + "`nendobj`n")
}

$xrefOffset = $sb.Length
[void]$sb.Append("xref`n0 " + ($objCount + 1) + "`n")
[void]$sb.Append("0000000000 65535 f `n")
foreach ($off in $offsets) {
    [void]$sb.Append($off.ToString('0000000000') + " 00000 n `n")
}
[void]$sb.Append("trailer`n<< /Size " + ($objCount + 1) + " /Root 1 0 R >>`n")
[void]$sb.Append("startxref`n" + $xrefOffset + "`n%%EOF`n")

$dir = Split-Path $Path -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

# ASCII, no BOM, no CRLF translation - byte offsets in the xref must be exact.
[System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.ASCIIEncoding))

$f = Get-Item $Path
Write-Host ('  Wrote {0}' -f $f.FullName) -ForegroundColor Green
Write-Host ('  revision {0}, {1} page(s), {2:N0} bytes' -f $Revision, $pageCount, $f.Length) -ForegroundColor Green
Write-Host ''
Write-Host '  Next:  .\publish.ps1 -File linktest.pdf' -ForegroundColor DarkGray
