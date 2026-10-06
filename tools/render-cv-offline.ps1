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

    Two more variants carry no References section, for applications that take
    the reference list as its own document, and use the short institute name
    ("Stephenson Institute") throughout:

      CV-private\CV-Jensen-no-references-ShortStephenson_<date>.pdf/.tex
      CV-private\CV-Jensen-no-references-ShortStephenson-noJMP_<date>.pdf/.tex

    The second also hides the "Job Market Paper" label, for applications where
    the job market paper is chosen by fit. That label is a switch in cv.qmd
    (content-visible unless-meta="no-jmp"); a render turns it off with
    -M no-jmp:true. Neither holds referee details. The mobile number is added
    afterwards by the private CV-private\add-mobile.ps1, as for the others.

    Each CV with references also has a twin with the short institute name and
    no "Job Market Paper" label (CV-Jensen-with-references-<Alternate>-
    ShortStephenson-noJMP_<date>), built the same way as the no-references ones.

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
    param([string] $Dir, [string[]] $Meta = @())

    # Extra Quarto metadata, e.g. 'no-jmp:true' to hide the Job Market Paper label.
    $metaArgs = (@($Meta) | ForEach-Object { '-M ' + $_ }) -join ' '

    # Clear outputs from any earlier render so a failure cannot leave a stale
    # file that looks like fresh output.
    foreach ($stale in @((Join-Path $Dir 'docs\cv.pdf'), (Join-Path $Dir 'cv.tex'))) {
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
    }

    Push-Location $Dir
    try {
        cmd /c "quarto render cv.qmd --to pdf -M keep-tex:true $metaArgs > render.log 2>&1"
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
# Each also gets a twin with the short institute name and no "Job Market Paper"
# label, for applications where the job market paper is chosen by fit.
$variants = @()
if ($alternates.Count -eq 0) {
    $variants += [pscustomobject]@{ Label = ''; Parts = @($fixed); Short = $false; HideJmp = $false; Suffix = '' }
} else {
    foreach ($a in $alternates) {
        $label = $a.Name -replace '[^A-Za-z0-9-]', ''
        $variants += [pscustomobject]@{ Label = $label; Parts = @($fixed, $a); Short = $false; HideJmp = $false; Suffix = '' }
    }
}
$variants += @($variants | ForEach-Object {
    [pscustomobject]@{ Label = $_.Label; Parts = $_.Parts; Short = $true; HideJmp = $true; Suffix = '-ShortStephenson-noJMP' }
})
foreach ($v in $variants) {
    $stem = if ($v.Label) { 'CV-Jensen-with-references-{0}' -f $v.Label } else { 'CV-Jensen-with-references' }
    $base = '{0}{1}_{2}' -f $stem, $v.Suffix, $Stamp
    $v | Add-Member -NotePropertyName Pdf -NotePropertyValue (Join-Path $PrivateDir "$base.pdf")
    $v | Add-Member -NotePropertyName Tex -NotePropertyValue (Join-Path $PrivateDir "$base.tex")
}

# CVs without a References section, with the short institute name throughout.
# The second also hides the "Job Market Paper" label through the unless-meta
# switch in cv.qmd. Neither holds referee details.
$plainVariants = @(
    [pscustomobject]@{ Title = 'CV without references (short institute name)';               Base = 'CV-Jensen-no-references-ShortStephenson';       HideJmp = $false }
    [pscustomobject]@{ Title = 'CV without references (short institute name, no JMP label)'; Base = 'CV-Jensen-no-references-ShortStephenson-noJMP'; HideJmp = $true  }
)
foreach ($pv in $plainVariants) {
    $pv | Add-Member -NotePropertyName Pdf -NotePropertyValue (Join-Path $PrivateDir ('{0}_{1}.pdf' -f $pv.Base, $Stamp))
    $pv | Add-Member -NotePropertyName Tex -NotePropertyValue (Join-Path $PrivateDir ('{0}_{1}.tex' -f $pv.Base, $Stamp))
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

$privatePaths = @($ReferencesFile, $ThirdDir) + @(@($variants) + @($plainVariants) | ForEach-Object { $_.Pdf, $_.Tex })
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
foreach ($p in @($publicPdf, $publicTex) + @(@($variants) + @($plainVariants) | ForEach-Object { $_.Pdf, $_.Tex })) {
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
        # CVs without references. They need nothing from the referee files, so
        # they sit ahead of the with-references section: a problem in a referee
        # file never stops them.
        # ------------------------------------------------------------------
        $refEmails = @((@($fixed) + $alternates) | ForEach-Object { $_.Emails } | Sort-Object -Unique)
        $fullName  = 'Stephenson Institute for Classical Liberalism'
        foreach ($pv in $plainVariants) {
            Write-Section $pv.Title

            # Cut the whole References section, from its heading to the end marker.
            $hm = [regex]::Matches($src, '(?m)^## References[ \t]*\r?$')
            if ($hm.Count -ne 1 -or $hm[0].Index -gt $si) {
                Write-Err 'cv.qmd must have exactly one "## References" heading ahead of the offline-references markers.'
                $blocked.Add($pv.Title); continue
            }
            $cut = $src.Substring(0, $hm[0].Index) + $src.Substring($ei + $EndMarker.Length)
            $cut = $cut.TrimEnd() + "`n"

            if ($cut.IndexOf($fullName) -lt 0) {
                Write-Err "cv.qmd no longer contains '$fullName', so there is nothing to shorten."
                $blocked.Add($pv.Title); continue
            }
            $cut = $cut.Replace($fullName, 'Stephenson Institute')
            [System.IO.File]::WriteAllText((Join-Path $WorkDir 'cv.qmd'), $cut, $Utf8NoBom)

            $meta = @()
            if ($pv.HideJmp) { $meta += 'no-jmp:true' }
            if (-not @(Invoke-CvRender -Dir $WorkDir -Meta $meta)[-1]) { $blocked.Add($pv.Title); continue }

            $tex  = [System.IO.File]::ReadAllText((Join-Path $WorkDir 'cv.tex'), [System.Text.Encoding]::UTF8)
            $text = ''
            if ($pdfToText) { $text = (& $pdfToText -layout (Join-Path $WorkDir 'docs\cv.pdf') - | Out-String) }
            $all = $tex + "`n" + $text

            # The label can be split across a line break in the .tex, so match
            # on any run of whitespace.
            $bad = @()
            if ($all.IndexOf($fullName) -ge 0)                                  { $bad += 'the full institute name is still there' }
            if ($all.IndexOf('Stephenson Institute') -lt 0)                     { $bad += 'the short institute name is missing' }
            $jmp = [regex]::IsMatch($all, 'Job\s+Market\s+Paper')
            if ($pv.HideJmp -and $jmp)           { $bad += 'the Job Market Paper label is still there' }
            if (-not $pv.HideJmp -and -not $jmp) { $bad += 'the Job Market Paper label is missing' }
            if ($tex -match '\\subsection\{References\}' -or $text -match '(?m)^\s*References\s*$') { $bad += 'a References section is present' }
            if (@($refEmails | Where-Object { $all.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0) { $bad += 'a referee email address is present' }
            if (@(Get-Phones $all).Count -gt 0)  { $bad += 'a phone number is present' }
            if ($bad.Count -gt 0) {
                foreach ($b in $bad) { Write-Err $b }
                $blocked.Add($pv.Title); continue
            }
            Write-Ok ('short institute name throughout; Job Market Paper label {0}; no References section; no referee details' -f $(if ($pv.HideJmp) { 'hidden' } else { 'kept' }))
            Save-Pair -Dir $WorkDir -PdfDest $pv.Pdf -TexDest $pv.Tex
            $saved.Add($pv.Pdf); $saved.Add($pv.Tex)
        }

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
            if ($v.Short) { $title += ' - short institute name, no JMP label' }
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
            if ($v.Short) {
                # Shortened everywhere, including the referee entry from the private file.
                $spliced = $spliced.Replace('Stephenson Institute for Classical Liberalism', 'Stephenson Institute')
            }
            [System.IO.File]::WriteAllText((Join-Path $WorkDir 'cv.qmd'), $spliced, $Utf8NoBom)

            $meta = @()
            if ($v.HideJmp) { $meta += 'no-jmp:true' }
            if (-not @(Invoke-CvRender -Dir $WorkDir -Meta $meta)[-1]) { $blocked.Add($title); continue }

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
            if ($v.Short) {
                $bad = @()
                $all = $tex + "`n" + $text
                if ($all.IndexOf('Stephenson Institute for Classical Liberalism') -ge 0) { $bad += 'the full institute name is still there' }
                if ([regex]::IsMatch($all, 'Job\s+Market\s+Paper'))                       { $bad += 'the Job Market Paper label is still there' }
                if ($bad.Count -gt 0) {
                    foreach ($b in $bad) { Write-Err $b }
                    $blocked.Add($title); continue
                }
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

if ($saved | Where-Object { $_ -like '*references*' }) {
    Write-Host ''
    Write-Host '  The private CVs still need your mobile number: run CV-private\add-mobile.ps1.' -ForegroundColor Yellow
    Write-Host '  With it they carry a phone number; never publish them.' -ForegroundColor Yellow
}

if ($exitCode -ne 0) { exit $exitCode }
# Explicit: a native command above may have left a non-zero $LASTEXITCODE.
exit 0
