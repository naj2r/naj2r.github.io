<#
.SYNOPSIS
    Build the private CV that includes referee contact details.

.DESCRIPTION
    The public CV (cv.qmd, served at nicholas-jensen.com) says "Available upon
    request" under References, and it has to: this repository is PUBLIC on
    GitHub, so anything written into cv.qmd is published - including referees'
    email addresses and phone numbers, which are other people's details.

    This script builds the version you send with applications without the
    references ever touching the repo:

      1. copies the project to a short, dot-free scratch path outside Dropbox
      2. swaps the block between the offline-references markers in the scratch
         copy of cv.qmd for the contents of your private references file
      3. renders only the PDF there
      4. verifies the referees actually made it into the PDF
      5. copies the PDF to your private folder

    The repo's cv.qmd is never modified. The scratch copy holds the private
    details, so it is deleted afterwards even if the render fails.

    Why a scratch copy instead of rendering in place: Quarto cannot find its
    own inputs from a path containing a dot-directory (worktrees live under
    .claude\), and the Dropbox client can lock files mid-render. See
    tools/render-site.ps1.

.PARAMETER PrivateDir
    Folder holding references.md and receiving the built PDF.

.PARAMETER ReferencesFile
    Private Quarto-markdown file with the referee entries.
    Default: <PrivateDir>\references.md

.PARAMETER OutFile
    Destination PDF. Default is dated (CV-Jensen-with-references_9-16-26.pdf),
    so a copy you already sent to a committee is never overwritten by a later
    build on a different day.

.EXAMPLE
    .\tools\render-cv-offline.ps1
#>
[CmdletBinding()]
param(
    [string] $PrivateDir     = (Join-Path $env:USERPROFILE 'Dropbox\Job Market Materials\Job Market 2026\CV-private'),
    [string] $ReferencesFile = '',
    [string] $OutFile        = '',
    [string] $RepoRoot       = (Split-Path $PSScriptRoot -Parent),
    [string] $WorkDir        = (Join-Path $env:TEMP 'qr-naj2r-offline')
)

$ErrorActionPreference = 'Stop'

function Write-Section { param([string]$Text) Write-Host ''; Write-Host $Text -ForegroundColor Cyan }
function Write-Ok      { param([string]$Text) Write-Host "  $Text" -ForegroundColor Green }
function Write-Warn    { param([string]$Text) Write-Host "  $Text" -ForegroundColor Yellow }
function Write-Err     { param([string]$Text) Write-Host "  $Text" -ForegroundColor Red }

function Test-PathInside {
    param([string] $Child, [string] $Parent)
    $c = [System.IO.Path]::GetFullPath($Child).TrimEnd('\')
    $p = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return ($c -eq $p) -or $c.StartsWith($p + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-PdfToText {
    $cmd = Get-Command pdftotext -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:LOCALAPPDATA 'poppler\bin\pdftotext.exe'
    if (Test-Path $fallback) { return $fallback }
    return $null
}

$StartMarker = '<!-- offline-references:start'
$EndMarker   = '<!-- offline-references:end -->'
$Utf8NoBom   = New-Object System.Text.UTF8Encoding($false)

if (-not $ReferencesFile) { $ReferencesFile = Join-Path $PrivateDir 'references.md' }
if (-not $OutFile) {
    $OutFile = Join-Path $PrivateDir ('CV-Jensen-with-references_{0}.pdf' -f (Get-Date).ToString('M-d-yy'))
}

# ===========================================================================
# 1. Preflight
# ===========================================================================
Write-Section 'Preflight'

if (-not (Get-Command quarto -ErrorAction SilentlyContinue)) {
    Write-Err 'quarto is not on PATH.'
    exit 1
}

$RepoRoot = (Resolve-Path $RepoRoot).Path
$cvPath   = Join-Path $RepoRoot 'cv.qmd'
if (-not (Test-Path $cvPath)) {
    Write-Err "No cv.qmd at $RepoRoot"
    exit 1
}
Write-Ok "repo: $RepoRoot"

if (-not (Test-Path $ReferencesFile)) {
    Write-Err "Private references file not found: $ReferencesFile"
    exit 1
}
Write-Ok "references: $ReferencesFile"

# Collect every root that belongs to the public repo. From a worktree,
# RepoRoot is the worktree; the main checkout is the parent of git's common
# directory. Neither may hold private material.
$publicRoots = @($RepoRoot)
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$common = & git -C $RepoRoot rev-parse --git-common-dir
$gitExit = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($gitExit -eq 0 -and $common) {
    $common = $common.Trim()
    if (-not [System.IO.Path]::IsPathRooted($common)) { $common = Join-Path $RepoRoot $common }
    $publicRoots += (Split-Path ([System.IO.Path]::GetFullPath($common)) -Parent)
}

foreach ($root in $publicRoots) {
    if (Test-PathInside $ReferencesFile $root) {
        Write-Err 'REFUSING: the references file is inside the public repo.'
        Write-Host "  $ReferencesFile is under $root, which is published on GitHub."
        exit 1
    }
    if (Test-PathInside $OutFile $root) {
        Write-Err 'REFUSING: the output PDF would land inside the public repo.'
        Write-Host "  $OutFile is under $root, which is published on GitHub."
        exit 1
    }
}

# The publish staging folder is pushed to a shared Dropbox folder whose files
# get public links. A CV with referee details must never be written there.
$stagingFolder = Join-Path $env:USERPROFILE 'website-materials'
if (Test-PathInside $OutFile $stagingFolder) {
    Write-Err 'REFUSING: the output PDF would land in the publish staging folder.'
    Write-Host "  Everything in $stagingFolder is pushed to a public Dropbox share."
    exit 1
}
Write-Ok "output: $OutFile"

foreach ($seg in ($WorkDir -split '\\')) {
    if ($seg.StartsWith('.')) {
        Write-Err "Work dir contains a dot-directory ('$seg'): $WorkDir"
        exit 1
    }
}
if ($WorkDir -match '(?i)\\Dropbox\\') {
    Write-Err "Work dir is inside Dropbox (it would sync the private details): $WorkDir"
    exit 1
}

# Markers: exactly one of each, in order.
$src = [System.IO.File]::ReadAllText($cvPath, [System.Text.Encoding]::UTF8)
$nStart = ([regex]::Matches($src, [regex]::Escape($StartMarker))).Count
$nEnd   = ([regex]::Matches($src, [regex]::Escape($EndMarker))).Count
$si = $src.IndexOf($StartMarker)
$ei = $src.IndexOf($EndMarker)
if ($nStart -ne 1 -or $nEnd -ne 1 -or $ei -lt $si) {
    Write-Err 'cv.qmd must contain exactly one offline-references start marker and one end marker, in that order.'
    Write-Host "  found start=$nStart end=$nEnd"
    exit 1
}
Write-Ok 'offline-references markers found in cv.qmd'

$refs = [System.IO.File]::ReadAllText($ReferencesFile, [System.Text.Encoding]::UTF8)
$refEmails = @([regex]::Matches($refs, '[\w.+-]+@[\w-]+\.[\w.-]+') | ForEach-Object { $_.Value } | Sort-Object -Unique)
if ($refEmails.Count -eq 0) {
    Write-Warn 'No email addresses found in the references file - the PDF check will be limited.'
}

$startClose = $src.IndexOf('-->', $si)
$spliced = $src.Substring(0, $startClose + 3) + "`n`n" + $refs.Trim() + "`n`n" + $src.Substring($ei)

# ===========================================================================
# 2. Scratch copy, render, verify - private details exist only in WorkDir
# ===========================================================================
$exitCode = 0
try {
    # do/while($false) gives the body a structured early exit. `break` leaves
    # the block and falls through to the exit handling below. `return` would
    # NOT work here: at script scope it exits the whole script, skipping the
    # final `exit $exitCode`, so a failed build would report success.
    do {
    Write-Section 'Staging (scratch copy holds private details; removed at the end)'

    if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

    # Skip dot-directories (.git, .claude, .github, .handoffs) and the built
    # site. None are needed for a single PDF, and docs/ is large.
    Get-ChildItem $RepoRoot -Force |
        Where-Object { -not ($_.PSIsContainer -and ($_.Name.StartsWith('.') -or $_.Name -eq 'docs')) } |
        ForEach-Object { Copy-Item $_.FullName -Destination $WorkDir -Recurse -Force }

    [System.IO.File]::WriteAllText((Join-Path $WorkDir 'cv.qmd'), $spliced, $Utf8NoBom)
    Write-Ok 'references spliced into scratch cv.qmd'

    Write-Section 'Render (PDF only)'

    Push-Location $WorkDir
    try {
        cmd /c "quarto render cv.qmd --to pdf > render.log 2>&1"
        $renderExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $builtPdf = Join-Path $WorkDir 'docs\cv.pdf'
    if ($renderExit -ne 0 -or -not (Test-Path $builtPdf)) {
        Write-Err "quarto render failed (exit $renderExit)."
        $logPath = Join-Path $WorkDir 'render.log'
        if (Test-Path $logPath) {
            Get-Content $logPath -Tail 25 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        }
        $exitCode = 1
        break
    }
    Write-Ok ('rendered ({0:N0} KB)' -f ((Get-Item $builtPdf).Length / 1KB))

    Write-Section 'Verify'

    $pdftotext = Resolve-PdfToText
    if (-not $pdftotext) {
        Write-Warn 'pdftotext not found - cannot confirm the referees made it into the PDF.'
    } else {
        $text = (& $pdftotext -layout $builtPdf - | Out-String)

        if ($text -match '(?i)available upon request') {
            Write-Err 'The PDF still says "Available upon request" - the swap did not take effect.'
            $exitCode = 1
            break
        }

        $missing = @($refEmails | Where-Object { $text.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 })
        if ($missing.Count -gt 0) {
            Write-Err "$($missing.Count) of $($refEmails.Count) referee email(s) are missing from the PDF:"
            foreach ($m in $missing) { Write-Host "    $m" }
            $exitCode = 1
            break
        }
        Write-Ok "all $($refEmails.Count) referee email(s) present; 'upon request' line gone"
    }

    $outDir = Split-Path $OutFile -Parent
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    Copy-Item $builtPdf $OutFile -Force
    Write-Ok "saved: $OutFile"
    } while ($false)
}
finally {
    if (Test-Path $WorkDir) {
        Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $WorkDir) {
        Write-Warn "Could not fully remove the scratch copy (it contains referee details): $WorkDir"
    } else {
        Write-Ok 'scratch copy removed'
    }
}

if ($exitCode -ne 0) { exit $exitCode }

Write-Host ''
Write-Host '  This PDF contains referees'' contact details. Send it with applications;' -ForegroundColor Yellow
Write-Host '  never stage it for publishing. publish.ps1 refuses it if you try.' -ForegroundColor Yellow

# Explicit: a native command above may have left a non-zero $LASTEXITCODE.
exit 0
