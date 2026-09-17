<#
.SYNOPSIS
    Build the on-disk CV pair - public and with-references, each as .pdf and .tex.

.DESCRIPTION
    Every build writes four files:

      <JobMarketDir>\CV-snapshots\CV-Jensen_<date>.pdf                  public CV
      <JobMarketDir>\CV-snapshots\CV-Jensen_<date>.tex
      <JobMarketDir>\CV-private\CV-Jensen-with-references_<date>.pdf    sent with applications
      <JobMarketDir>\CV-private\CV-Jensen-with-references_<date>.tex

    Both variants are rendered from the same snapshot of cv.qmd in the same
    run, so they are identical except for the References section.

    The with-references variant can never live in the repo: naj2r.github.io is
    PUBLIC on GitHub, so referee contact details written into cv.qmd would be
    published. Referees live in a private file outside the repo. This script
    splices that file into a scratch copy of cv.qmd between the
    offline-references markers, renders, verifies, saves, and deletes the
    scratch copy - even when the build fails.

    The .tex files are the exact sources LuaLaTeX compiled, with the header
    template inlined, so each compiles on its own in an empty folder. They need
    LuaLaTeX or XeLaTeX, because the CV uses fontspec with Libertinus Serif.

    Rendering happens in a short, dot-free scratch path outside Dropbox: Quarto
    cannot find its inputs from a path containing a dot-directory (worktrees
    live under .claude\), and the Dropbox client can lock files mid-render.

.PARAMETER JobMarketDir
    Folder that holds CV-private\ and CV-snapshots\. Point this at the new
    folder each job market cycle.

.PARAMETER ReferencesFile
    Private Quarto-markdown file with the referee entries.
    Default: <JobMarketDir>\CV-private\references.md

.PARAMETER Stamp
    Date string used in the filenames. Default: today as M-d-yy (9-17-26), the
    convention CV-snapshots already uses. Dated names mean a copy already sent
    to a committee is never overwritten by a build on a later day.

.EXAMPLE
    .\tools\render-cv-offline.ps1

.EXAMPLE
    .\tools\render-cv-offline.ps1 -JobMarketDir "$env:USERPROFILE\Dropbox\Job Market Materials\Job Market 2027"
#>
[CmdletBinding()]
param(
    [string] $JobMarketDir   = (Join-Path $env:USERPROFILE 'Dropbox\Job Market Materials\Job Market 2026'),
    [string] $PrivateDir     = '',
    [string] $PublicDir      = '',
    [string] $ReferencesFile = '',
    [string] $Stamp          = (Get-Date).ToString('M-d-yy'),
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

# Render cv.qmd in $Dir to PDF, keeping the .tex. Returns $true on success.
function Invoke-CvRender {
    param([string] $Dir)

    # Clear outputs from any earlier render so a failure cannot leave a stale
    # file that looks like fresh output.
    foreach ($stale in @((Join-Path $Dir 'docs\cv.pdf'), (Join-Path $Dir 'cv.tex'))) {
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
    }

    Push-Location $Dir
    try {
        cmd /c "quarto render cv.qmd --to pdf -M keep-tex:true > render.log 2>&1"
        $rc = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $pdf = Join-Path $Dir 'docs\cv.pdf'
    $tex = Join-Path $Dir 'cv.tex'
    if ($rc -ne 0 -or -not (Test-Path $pdf) -or -not (Test-Path $tex)) {
        Write-Err "quarto render failed (exit $rc)."
        $log = Join-Path $Dir 'render.log'
        if (Test-Path $log) {
            Get-Content $log -Tail 25 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
        return $false
    }
    return $true
}

$StartMarker = '<!-- offline-references:start'
$EndMarker   = '<!-- offline-references:end -->'
$Utf8NoBom   = New-Object System.Text.UTF8Encoding($false)

if (-not $PrivateDir)     { $PrivateDir     = Join-Path $JobMarketDir 'CV-private' }
if (-not $PublicDir)      { $PublicDir      = Join-Path $JobMarketDir 'CV-snapshots' }
if (-not $ReferencesFile) { $ReferencesFile = Join-Path $PrivateDir 'references.md' }

$Out = [ordered]@{
    PublicPdf = Join-Path $PublicDir  ('CV-Jensen_{0}.pdf' -f $Stamp)
    PublicTex = Join-Path $PublicDir  ('CV-Jensen_{0}.tex' -f $Stamp)
    RefsPdf   = Join-Path $PrivateDir ('CV-Jensen-with-references_{0}.pdf' -f $Stamp)
    RefsTex   = Join-Path $PrivateDir ('CV-Jensen-with-references_{0}.tex' -f $Stamp)
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
    Write-Host '  Each job market cycle, point -JobMarketDir at the new folder, or create'
    Write-Host '  references.md there from the previous cycle''s copy.'
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

$private = @($ReferencesFile, $Out.RefsPdf, $Out.RefsTex)
foreach ($root in $publicRoots) {
    foreach ($p in $private) {
        if (Test-PathInside $p $root) {
            Write-Err 'REFUSING: private CV material would sit inside the public repo.'
            Write-Host "  $p is under $root, which is published on GitHub."
            exit 1
        }
    }
}

# Everything in the publish staging folder gets pushed to a shared Dropbox
# folder whose files carry public links. No CV output belongs there.
$stagingFolder = Join-Path $env:USERPROFILE 'website-materials'
foreach ($p in $Out.Values) {
    if (Test-PathInside $p $stagingFolder) {
        Write-Err 'REFUSING: a CV output would land in the publish staging folder.'
        Write-Host "  Everything in $stagingFolder is pushed to a public Dropbox share."
        exit 1
    }
}

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
    Write-Warn 'No email addresses found in the references file - verification will be limited.'
}

$startClose = $src.IndexOf('-->', $si)
$spliced = $src.Substring(0, $startClose + 3) + "`n`n" + $refs.Trim() + "`n`n" + $src.Substring($ei)

$pdfToText = Resolve-PdfToText
if (-not $pdfToText) {
    Write-Warn 'pdftotext not found - checking the .tex sources only, not the PDF text.'
}

# ===========================================================================
# 2. Scratch copy, two renders, verification
#    Private details exist only inside WorkDir, which is always deleted.
# ===========================================================================
$exitCode = 0
try {
    # do/while($false) gives the body a structured early exit. `break` leaves
    # the block and falls through to the exit handling below. `return` would
    # NOT work here: at script scope it exits the whole script, skipping the
    # final `exit $exitCode`, so a failed build would report success.
    do {
        Write-Section 'Staging (scratch copy; removed at the end)'

        if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

        # Skip dot-directories (.git, .claude, .github, .handoffs) and the
        # built site. None are needed for the CV, and docs/ is large.
        Get-ChildItem $RepoRoot -Force |
            Where-Object { -not ($_.PSIsContainer -and ($_.Name.StartsWith('.') -or $_.Name -eq 'docs')) } |
            ForEach-Object { Copy-Item $_.FullName -Destination $WorkDir -Recurse -Force }

        $held = Join-Path $WorkDir '_built'
        New-Item -ItemType Directory -Path $held -Force | Out-Null
        Write-Ok 'project copied'

        # ------------------------------------------------------------------
        # Variant 1: public (cv.qmd exactly as committed)
        # ------------------------------------------------------------------
        Write-Section 'Render 1 of 2: public CV'

        if (-not @(Invoke-CvRender -Dir $WorkDir)[-1]) { $exitCode = 1; break }

        $pubTex = [System.IO.File]::ReadAllText((Join-Path $WorkDir 'cv.tex'), [System.Text.Encoding]::UTF8)
        $leaked = @($refEmails | Where-Object { $pubTex.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
        if ($pdfToText) {
            $pubPdfText = (& $pdfToText -layout (Join-Path $WorkDir 'docs\cv.pdf') - | Out-String)
            $leaked += @($refEmails | Where-Object { $pubPdfText.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
            if ($pubPdfText -notmatch '(?i)available upon request') {
                Write-Err 'The public CV no longer says "Available upon request". Check cv.qmd between the markers.'
                $exitCode = 1; break
            }
        }
        if ($leaked.Count -gt 0) {
            Write-Err 'A referee email address appears in the PUBLIC CV. Something is written into cv.qmd that must not be.'
            $exitCode = 1; break
        }
        Move-Item (Join-Path $WorkDir 'docs\cv.pdf') (Join-Path $held 'public.pdf')
        Move-Item (Join-Path $WorkDir 'cv.tex')      (Join-Path $held 'public.tex')
        Write-Ok 'rendered; no referee details present'

        # ------------------------------------------------------------------
        # Variant 2: with references spliced in
        # ------------------------------------------------------------------
        Write-Section 'Render 2 of 2: CV with references'

        [System.IO.File]::WriteAllText((Join-Path $WorkDir 'cv.qmd'), $spliced, $Utf8NoBom)
        if (-not @(Invoke-CvRender -Dir $WorkDir)[-1]) { $exitCode = 1; break }

        $refTex = [System.IO.File]::ReadAllText((Join-Path $WorkDir 'cv.tex'), [System.Text.Encoding]::UTF8)
        $missing = @($refEmails | Where-Object { $refTex.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 })
        if ($pdfToText) {
            $refPdfText = (& $pdfToText -layout (Join-Path $WorkDir 'docs\cv.pdf') - | Out-String)
            $missing += @($refEmails | Where-Object { $refPdfText.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 })
            if ($refPdfText -match '(?i)available upon request') {
                Write-Err 'The CV with references still says "Available upon request" - the swap did not take effect.'
                $exitCode = 1; break
            }
        }
        $missing = @($missing | Sort-Object -Unique)
        if ($missing.Count -gt 0) {
            Write-Err "$($missing.Count) referee email(s) did not make it into the CV:"
            foreach ($m in $missing) { Write-Host "    $m" }
            $exitCode = 1; break
        }
        Move-Item (Join-Path $WorkDir 'docs\cv.pdf') (Join-Path $held 'refs.pdf')
        Move-Item (Join-Path $WorkDir 'cv.tex')      (Join-Path $held 'refs.tex')
        Write-Ok "rendered; all $($refEmails.Count) referee email(s) present"

        # ------------------------------------------------------------------
        # Save all four
        # ------------------------------------------------------------------
        Write-Section 'Save'

        foreach ($dir in @($PublicDir, $PrivateDir)) {
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        }
        Copy-Item (Join-Path $held 'public.pdf') $Out.PublicPdf -Force
        Copy-Item (Join-Path $held 'public.tex') $Out.PublicTex -Force
        Copy-Item (Join-Path $held 'refs.pdf')   $Out.RefsPdf   -Force
        Copy-Item (Join-Path $held 'refs.tex')   $Out.RefsTex   -Force

        foreach ($p in $Out.Values) {
            Write-Ok ('{0}  ({1:N0} KB)' -f $p, ((Get-Item $p).Length / 1KB))
        }
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
Write-Host '  The with-references files contain referees'' contact details. Send them with' -ForegroundColor Yellow
Write-Host '  applications; never stage them for publishing (publish.ps1 refuses them).' -ForegroundColor Yellow

# Explicit: a native command above may have left a non-zero $LASTEXITCODE.
exit 0
