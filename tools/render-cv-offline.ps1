<#
.SYNOPSIS
    Build the on-disk CVs: the public CV, and one CV with references per
    third-reference alternate - each as .pdf and .tex.

.DESCRIPTION
    Referee files live in <JobMarketDir>\CV-private\:

      references.md        referees on every application, in the order listed
      third-reference\     one .md per alternate for the third slot

    Every build writes:

      CV-snapshots\CV-Jensen_<date>.pdf/.tex                              public
      CV-private\CV-Jensen-with-references-<Alternate>_<date>.pdf/.tex    one per alternate

    With third-reference\ empty, a single CV-Jensen-with-references_<date>
    pair is built from references.md alone.

    All variants render from the same snapshot of cv.qmd in one run, so they
    differ only in the References section. The public pair is saved first, so
    a problem in a referee file never stops the public CV from being current.

    The public CV lists referees by name, position, institution and email:
    university-affiliated details they agreed to publish. Phone numbers never
    go in the repo, because naj2r.github.io is PUBLIC on GitHub. They live only
    in the private referee files, and this script splices those into a scratch
    copy of cv.qmd between the offline-references markers, renders, verifies,
    saves, and deletes the scratch copy - even when a render fails.

    Referee files hold paragraphs only; the build wraps them in the
    cv-referees grid. A line containing TODO (outside HTML comments) blocks
    that CV, so a half-filled entry never reaches an application: a TODO in
    references.md blocks every with-references CV, a TODO in an alternate
    blocks only that alternate's CV.

    The .tex files are the exact sources LuaLaTeX compiled, with the header
    template inlined, so each compiles alone in an empty folder. They need
    LuaLaTeX or XeLaTeX (fontspec with Libertinus Serif).

    Rendering happens in a short, dot-free scratch path outside Dropbox: Quarto
    cannot find its inputs under a dot-directory (worktrees live under
    .claude\), and the Dropbox client can lock files mid-render.

.PARAMETER JobMarketDir
    Folder holding CV-private\ and CV-snapshots\. Point it at the new folder
    each job market cycle.

.PARAMETER Stamp
    Date string for filenames. Default: today as M-d-yy (9-17-26). Dated names
    mean a copy already sent to a committee is never overwritten by a build on
    a later day.

.EXAMPLE
    .\tools\render-cv-offline.ps1
#>
[CmdletBinding()]
param(
    [string] $JobMarketDir = (Join-Path $env:USERPROFILE 'Dropbox\Job Market Materials\Job Market 2026'),
    [string] $PrivateDir   = '',
    [string] $PublicDir    = '',
    [string] $Stamp        = (Get-Date).ToString('M-d-yy'),
    [string] $RepoRoot     = (Split-Path $PSScriptRoot -Parent),
    [string] $WorkDir      = (Join-Path $env:TEMP 'qr-naj2r-offline')
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

function Get-Emails {
    param([string] $Text)
    return @([regex]::Matches($Text, '[\w.+-]+@[\w-]+\.[\w.-]+') | ForEach-Object { $_.Value } | Sort-Object -Unique)
}

# A US-style phone number. The lookarounds stop it matching inside a longer run
# of characters: a DOI such as 10.1007/s11127-026-01386-6 contains 3-3-4 digit
# groups that a looser pattern reads as a number. Kept identical to the pattern
# in tools/publish/publish.ps1, which was tested on the published papers (no
# hits) and on every private CV (all hit).
$PhonePattern = '(?<![\w.-])(?:\+?1[\s.-])?\(?\d{3}\)?[\s.-]{1,2}\d{3}[\s.-]\d{4}(?![\w-])'

# Phone numbers in $Text as bare 10-digit strings, so formatting never matters.
function Get-Phones {
    param([string] $Text)
    return @([regex]::Matches($Text, $PhonePattern) |
        ForEach-Object { ($_.Value -replace '\D', '') } |
        ForEach-Object { $_.Substring($_.Length - 10) } |
        Sort-Object -Unique)
}

# Read a referee file. HTML comments carry instructions and may mention TODO
# or fences freely, so they are stripped before anything is checked.
function Read-RefereeFile {
    param([string] $Path)
    $raw  = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $body = ([regex]::Replace($raw, '(?s)<!--.*?-->', '')).Trim()
    $problems = @()
    if (-not $body)                    { $problems += 'is empty' }
    if ($body -match '(?m)^\s*:::')    { $problems += 'contains ::: fences (referee files hold paragraphs only; the build adds the grid)' }
    if ($body -match '(?i)\bTODO\b')   { $problems += 'has unfilled TODO placeholders' }
    return [pscustomobject]@{
        Path     = $Path
        Name     = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        Body     = $body
        Emails   = @(Get-Emails $body)
        Phones   = @(Get-Phones $body)
        Problems = $problems
    }
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

    if ($rc -ne 0 -or -not (Test-Path (Join-Path $Dir 'docs\cv.pdf')) -or -not (Test-Path (Join-Path $Dir 'cv.tex'))) {
        Write-Err "quarto render failed (exit $rc)."
        $log = Join-Path $Dir 'render.log'
        if (Test-Path $log) {
            Get-Content $log -Tail 25 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
        return $false
    }
    return $true
}

function Save-Pair {
    param([string] $Dir, [string] $PdfDest, [string] $TexDest)
    foreach ($d in @((Split-Path $PdfDest -Parent), (Split-Path $TexDest -Parent))) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    Copy-Item (Join-Path $Dir 'docs\cv.pdf') $PdfDest -Force
    Copy-Item (Join-Path $Dir 'cv.tex')      $TexDest -Force
    Write-Ok ('saved {0}  ({1:N0} KB)' -f (Split-Path $PdfDest -Leaf), ((Get-Item $PdfDest).Length / 1KB))
    Write-Ok ('saved {0}  ({1:N0} KB)' -f (Split-Path $TexDest -Leaf), ((Get-Item $TexDest).Length / 1KB))
}

$StartMarker = '<!-- offline-references:start'
$EndMarker   = '<!-- offline-references:end -->'
$Utf8NoBom   = New-Object System.Text.UTF8Encoding($false)

if (-not $PrivateDir) { $PrivateDir = Join-Path $JobMarketDir 'CV-private' }
if (-not $PublicDir)  { $PublicDir  = Join-Path $JobMarketDir 'CV-snapshots' }
$ReferencesFile = Join-Path $PrivateDir 'references.md'
$ThirdDir       = Join-Path $PrivateDir 'third-reference'

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
    Write-Host '  Each job market cycle, point -JobMarketDir at the new folder and carry'
    Write-Host '  CV-private\ (references.md and third-reference\) over from the last cycle.'
    exit 1
}

$fixed = Read-RefereeFile $ReferencesFile
$alternates = @()
if (Test-Path $ThirdDir) {
    $alternates = @(Get-ChildItem $ThirdDir -Filter *.md -File | Sort-Object Name | ForEach-Object { Read-RefereeFile $_.FullName })
}
Write-Ok "fixed referees: $ReferencesFile"
Write-Ok ("third-slot alternates: {0}" -f $(if ($alternates.Count) { ($alternates | ForEach-Object { $_.Name }) -join ', ' } else { 'none' }))

# One variant per alternate; with no alternates, one variant of the fixed list.
$variants = @()
if ($alternates.Count -eq 0) {
    $variants += [pscustomobject]@{ Label = ''; Parts = @($fixed) }
} else {
    foreach ($a in $alternates) {
        $label = $a.Name -replace '[^A-Za-z0-9-]', ''
        $variants += [pscustomobject]@{ Label = $label; Parts = @($fixed, $a) }
    }
}
foreach ($v in $variants) {
    $base = if ($v.Label) { 'CV-Jensen-with-references-{0}_{1}' -f $v.Label, $Stamp } else { 'CV-Jensen-with-references_{0}' -f $Stamp }
    $v | Add-Member -NotePropertyName Pdf -NotePropertyValue (Join-Path $PrivateDir "$base.pdf")
    $v | Add-Member -NotePropertyName Tex -NotePropertyValue (Join-Path $PrivateDir "$base.tex")
}

$publicPdf = Join-Path $PublicDir ('CV-Jensen_{0}.pdf' -f $Stamp)
$publicTex = Join-Path $PublicDir ('CV-Jensen_{0}.tex' -f $Stamp)

# Every root belonging to the public repo. From a worktree, RepoRoot is the
# worktree; the main checkout is the parent of git's common directory.
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

$privatePaths = @($ReferencesFile, $ThirdDir) + @($variants | ForEach-Object { $_.Pdf, $_.Tex })
foreach ($root in $publicRoots) {
    foreach ($p in $privatePaths) {
        if (Test-PathInside $p $root) {
            Write-Err 'REFUSING: private CV material would sit inside the public repo.'
            Write-Host "  $p is under $root, which is published on GitHub."
            exit 1
        }
    }
}

# The publish staging folder is pushed to a shared Dropbox folder with public
# links. No CV output belongs there.
$stagingFolder = Join-Path $env:USERPROFILE 'website-materials'
foreach ($p in @($publicPdf, $publicTex) + @($variants | ForEach-Object { $_.Pdf, $_.Tex })) {
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
$startClose = $src.IndexOf('-->', $si)
Write-Ok 'offline-references markers found in cv.qmd'

# Every phone number in every referee file - the public CV must contain none.
$allRefereePhones = @((@($fixed) + $alternates) | ForEach-Object { $_.Phones } | Sort-Object -Unique)

$pdfToText = Resolve-PdfToText
if (-not $pdfToText) {
    Write-Warn 'pdftotext not found - checking the .tex sources only, not the PDF text.'
}

# ===========================================================================
# 2. Scratch copy, renders, verification
#    Private details exist only inside WorkDir, which is always deleted.
# ===========================================================================
$exitCode = 0
$saved    = New-Object System.Collections.Generic.List[string]
$blocked  = New-Object System.Collections.Generic.List[string]
try {
    # do/while($false) gives the body a structured early exit. `break` leaves
    # the block and falls through to the exit handling below. `return` would
    # NOT work here: at script scope it exits the whole script, skipping the
    # final `exit $exitCode`, so a failed build would report success.
    # Inside the per-variant foreach, use `continue`: `break` there would only
    # leave the foreach.
    do {
        Write-Section 'Staging (scratch copy; removed at the end)'

        if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

        # Skip dot-directories (.git, .claude, .github, .handoffs) and the
        # built site. None are needed for the CV, and docs/ is large.
        Get-ChildItem $RepoRoot -Force |
            Where-Object { -not ($_.PSIsContainer -and ($_.Name.StartsWith('.') -or $_.Name -eq 'docs')) } |
            ForEach-Object { Copy-Item $_.FullName -Destination $WorkDir -Recurse -Force }
        Write-Ok 'project copied'

        # ------------------------------------------------------------------
        # Public CV - saved first, so referee problems never block it
        # ------------------------------------------------------------------
        Write-Section 'Public CV'

        if (-not @(Invoke-CvRender -Dir $WorkDir)[-1]) { $exitCode = 1; break }

        $pubTex  = [System.IO.File]::ReadAllText((Join-Path $WorkDir 'cv.tex'), [System.Text.Encoding]::UTF8)
        $pubText = ''
        if ($pdfToText) { $pubText = (& $pdfToText -layout (Join-Path $WorkDir 'docs\cv.pdf') - | Out-String) }
        $pubAll = $pubTex + "`n" + $pubText

        # Referees' names, positions, institutions and emails may be public.
        # Their phone numbers may not. Two independent checks: anything shaped
        # like a phone number, and each known referee number as a bare digit
        # run (which catches formatting the pattern would miss).
        $leakedPhones = @(Get-Phones $pubAll)
        $pubDigits    = $pubAll -replace '\D', ''
        $leakedPhones += @($allRefereePhones | Where-Object { $pubDigits.IndexOf($_) -ge 0 })
        $leakedPhones = @($leakedPhones | Sort-Object -Unique)
        if ($leakedPhones.Count -gt 0) {
            $tails = ($leakedPhones | ForEach-Object { '...' + $_.Substring(6) }) -join ', '
            Write-Err "$($leakedPhones.Count) phone number(s) appear in the PUBLIC CV ($tails). Phone numbers live only in the private referee files."
            $exitCode = 1; break
        }
        Write-Ok "no phone numbers in the public CV (checked $($allRefereePhones.Count) referee number(s) plus the general phone pattern)"

        # The public list is hand-maintained in cv.qmd. Say so if it has drifted
        # from the referees who are on every application.
        $notListed = @($fixed.Emails | Where-Object { $pubAll.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 })
        if ($notListed.Count -gt 0) {
            Write-Warn "The public CV does not list: $($notListed -join ', '). Update the References block in cv.qmd."
        }
        Save-Pair -Dir $WorkDir -PdfDest $publicPdf -TexDest $publicTex
        $saved.Add($publicPdf); $saved.Add($publicTex)

        # ------------------------------------------------------------------
        # CVs with references
        # ------------------------------------------------------------------
        if ($fixed.Problems.Count -gt 0) {
            Write-Section 'CVs with references: BLOCKED'
            Write-Err "references.md $($fixed.Problems -join '; ')."
            Write-Host '  It is on every application, so no CV with references was built.'
            $blocked.Add('all CVs with references (references.md)')
            $exitCode = 1; break
        }

        foreach ($v in $variants) {
            $title = if ($v.Label) { "CV with references (third slot: $($v.Label))" } else { 'CV with references' }
            Write-Section $title

            $alt = if ($v.Label) { $v.Parts[-1] } else { $null }
            if ($alt -and $alt.Problems.Count -gt 0) {
                Write-Err "third-reference\$($alt.Name).md $($alt.Problems -join '; ')."
                Write-Host '  Skipped this CV; the others still build.'
                $blocked.Add($title)
                continue
            }

            $grid = "::: {.cv-referees}`n`n" + (($v.Parts | ForEach-Object { $_.Body }) -join "`n`n") + "`n`n:::"
            $spliced = $src.Substring(0, $startClose + 3) + "`n`n" + $grid + "`n`n" + $src.Substring($ei)
            [System.IO.File]::WriteAllText((Join-Path $WorkDir 'cv.qmd'), $spliced, $Utf8NoBom)

            if (-not @(Invoke-CvRender -Dir $WorkDir)[-1]) { $blocked.Add($title); continue }

            $want      = @($v.Parts | ForEach-Object { $_.Emails } | Sort-Object -Unique)
            $wantPhone = @($v.Parts | ForEach-Object { $_.Phones } | Sort-Object -Unique)
            if ($want.Count -eq 0)      { Write-Warn 'No email addresses in these referee entries - verification is limited.' }
            if ($wantPhone.Count -eq 0) { Write-Warn 'No phone numbers in these referee entries - this CV adds nothing to the public one.' }

            $tex  = [System.IO.File]::ReadAllText((Join-Path $WorkDir 'cv.tex'), [System.Text.Encoding]::UTF8)
            $text = ''
            if ($pdfToText) { $text = (& $pdfToText -layout (Join-Path $WorkDir 'docs\cv.pdf') - | Out-String) }

            $missing = @($want | Where-Object { $tex.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 })
            if ($pdfToText) { $missing += @($want | Where-Object { $text.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 }) }
            $missing = @($missing | Sort-Object -Unique)

            # Phones are compared as bare digits so any formatting counts. The
            # public block carries emails but no phones, so a missing phone is
            # also how a swap that did not take effect shows up.
            $texDigits  = $tex  -replace '\D', ''
            $textDigits = $text -replace '\D', ''
            $missingPhone = @($wantPhone | Where-Object { $texDigits.IndexOf($_) -lt 0 })
            if ($pdfToText) { $missingPhone += @($wantPhone | Where-Object { $textDigits.IndexOf($_) -lt 0 }) }
            $missingPhone = @($missingPhone | Sort-Object -Unique)

            if ($missing.Count -gt 0) {
                Write-Err "$($missing.Count) referee email(s) did not make it into the CV:"
                foreach ($m in $missing) { Write-Host "    $m" }
                $blocked.Add($title); continue
            }
            if ($missingPhone.Count -gt 0) {
                Write-Err "$($missingPhone.Count) referee phone number(s) did not make it into the CV - the swap may not have taken effect."
                $blocked.Add($title); continue
            }
            Write-Ok "all $($want.Count) referee email(s) and $($wantPhone.Count) phone number(s) present"
            Save-Pair -Dir $WorkDir -PdfDest $v.Pdf -TexDest $v.Tex
            $saved.Add($v.Pdf); $saved.Add($v.Tex)
        }

        if ($blocked.Count -gt 0) { $exitCode = 1 }
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

Write-Section 'Summary'
Write-Host "  saved $($saved.Count) file(s)"
if ($blocked.Count -gt 0) {
    Write-Host '  not built:' -ForegroundColor Yellow
    foreach ($b in $blocked) { Write-Host "    $b" -ForegroundColor Yellow }
}
if ($saved | Where-Object { $_ -like '*with-references*' }) {
    Write-Host ''
    Write-Host '  CVs with references carry referees'' phone numbers. Send them with' -ForegroundColor Yellow
    Write-Host '  applications; never stage them for publishing (publish.ps1 refuses them).' -ForegroundColor Yellow
}

if ($exitCode -ne 0) { exit $exitCode }
# Explicit: a native command above may have left a non-zero $LASTEXITCODE.
exit 0
