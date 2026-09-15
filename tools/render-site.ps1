<#
.SYNOPSIS
    Render the Quarto site safely and mirror the output back into docs/.

.DESCRIPTION
    Running `quarto render` directly in this repo can fail in two different
    ways, and one of them fails SILENTLY. This script routes around both.

    Failure 1 - the dot-directory trap (silent, the dangerous one)
      Quarto's project walker skips path components beginning with "." and
      evaluates that on the ABSOLUTE path. A git worktree lives under
      .claude/worktrees/<name>/, so the project becomes invisible to itself:
      quarto finds zero input files, wipes docs/, writes a ~110-byte empty
      sitemap, and exits 0 reporting success. Nothing warns you.

    Failure 2 - the Dropbox lock
      The repo lives inside the Dropbox-synced tree. Quarto deletes the whole
      output directory before a project render, and the Dropbox client can be
      holding a handle on docs/, producing
      "The process cannot access the file ... remove '...\docs'".

    The fix for both: render from a short, dot-free path outside Dropbox, then
    mirror the finished docs/ back. This also means sync no longer has to be
    paused to render.

    The script verifies inputs were actually discovered BEFORE rendering, so
    the silent failure becomes a loud one.

.PARAMETER RepoRoot
    Project root. Defaults to the parent of this script's directory.

.PARAMETER WorkDir
    Scratch render location. Must be short, outside Dropbox, and contain no
    dot-directories. Default: %TEMP%\qr-naj2r

.PARAMETER KeepWorkDir
    Leave the scratch copy in place afterwards (useful for debugging a render).

.EXAMPLE
    .\render-site.ps1
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [string] $WorkDir  = (Join-Path $env:TEMP 'qr-naj2r'),
    [switch] $KeepWorkDir
)

$ErrorActionPreference = 'Stop'

function Write-Section { param([string]$Text) Write-Host ''; Write-Host $Text -ForegroundColor Cyan }
function Write-Ok      { param([string]$Text) Write-Host "  $Text" -ForegroundColor Green }
function Write-Warn    { param([string]$Text) Write-Host "  $Text" -ForegroundColor Yellow }
function Write-Err     { param([string]$Text) Write-Host "  $Text" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Section 'Preflight'

if (-not (Get-Command quarto -ErrorAction SilentlyContinue)) {
    Write-Err 'quarto is not on PATH.'
    exit 1
}
$RepoRoot = (Resolve-Path $RepoRoot).Path
if (-not (Test-Path (Join-Path $RepoRoot '_quarto.yml'))) {
    Write-Err "No _quarto.yml at $RepoRoot - is that the project root?"
    exit 1
}
Write-Ok "repo: $RepoRoot"

# The scratch path must not reintroduce the very problem we are avoiding.
$leaf = Split-Path $WorkDir -Leaf
foreach ($seg in ($WorkDir -split '\\')) {
    if ($seg.StartsWith('.')) {
        Write-Err "Work dir contains a dot-directory ('$seg'): $WorkDir"
        Write-Host '  Quarto would find zero inputs there too. Pick a dot-free path.'
        exit 1
    }
}
if ($WorkDir -match '(?i)\\Dropbox\\') {
    Write-Err "Work dir is inside Dropbox: $WorkDir"
    Write-Host '  Renders there can fail on a Dropbox file lock. Pick a path outside the sync tree.'
    exit 1
}
Write-Ok "work dir: $WorkDir"

# ---------------------------------------------------------------------------
# Stage a clean copy
#
# .git and .claude are excluded: they are large, irrelevant to the render, and
# .claude in particular is the dot-directory that causes the whole problem.
# ---------------------------------------------------------------------------
Write-Section 'Staging'

if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

$skip = @('.git', '.claude')
Get-ChildItem $RepoRoot -Force |
    Where-Object { $skip -notcontains $_.Name } |
    ForEach-Object { Copy-Item $_.FullName -Destination $WorkDir -Recurse -Force }

Write-Ok "copied project to work dir"

# ---------------------------------------------------------------------------
# Verify Quarto can actually see the inputs.
#
# This is the whole point of the script. If files.input is empty, rendering
# would "succeed" while destroying docs/, so stop here instead.
# ---------------------------------------------------------------------------
Write-Section 'Input discovery check'

Push-Location $WorkDir
try {
    cmd /c "quarto inspect > inspect.json 2>&1" | Out-Null
    $inspect = $null
    try { $inspect = Get-Content 'inspect.json' -Raw | ConvertFrom-Json } catch { }

    $inputs = @()
    if ($inspect -and $inspect.files -and $inspect.files.input) { $inputs = @($inspect.files.input) }

    if ($inputs.Count -eq 0) {
        Write-Err 'Quarto found ZERO input files. Refusing to render.'
        Write-Host '  Rendering now would wipe docs/ and exit 0 as if it had worked.'
        Write-Host "  Check for a dot-directory in the work dir path, or a .quartoignore"
        Write-Host '  rule that is matching too broadly.'
        Pop-Location
        exit 1
    }

    Write-Ok "$($inputs.Count) input file(s) found:"
    foreach ($i in $inputs) {
        # Show the path relative to the work dir - two different index.qmd files
        # (root and research/) would otherwise both print as "index.qmd" and look
        # like a duplicate.
        $rel = $i
        if ($i.StartsWith($WorkDir)) { $rel = $i.Substring($WorkDir.Length).TrimStart('\') }
        Write-Host "    $rel" -ForegroundColor DarkGray
    }
    Remove-Item 'inspect.json' -Force -ErrorAction SilentlyContinue
} finally {
    if ((Get-Location).Path -eq $WorkDir) { Pop-Location }
}

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
Write-Section 'Render'

Push-Location $WorkDir
try {
    cmd /c "quarto render > render.log 2>&1"
    $renderExit = $LASTEXITCODE
    $log = ''
    if (Test-Path 'render.log') { $log = Get-Content 'render.log' -Raw }

    if ($log) { $log.TrimEnd() -split "`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }

    if ($renderExit -ne 0) {
        Write-Err "quarto render exited $renderExit"
        Pop-Location
        exit $renderExit
    }
} finally {
    if ((Get-Location).Path -eq $WorkDir) { Pop-Location }
}

# ---------------------------------------------------------------------------
# Sanity-check the output before letting it overwrite docs/
# ---------------------------------------------------------------------------
Write-Section 'Output check'

$builtDocs = Join-Path $WorkDir 'docs'
if (-not (Test-Path $builtDocs)) {
    Write-Err "No docs/ produced at $builtDocs"
    exit 1
}

$sitemap = Join-Path $builtDocs 'sitemap.xml'
if (Test-Path $sitemap) {
    $size = (Get-Item $sitemap).Length
    # An empty sitemap (~110 bytes) is the fingerprint of a zero-input render.
    if ($size -lt 300) {
        Write-Err "sitemap.xml is only $size bytes - that means no pages were rendered."
        Write-Host '  Not mirroring this over docs/. Investigate before retrying.'
        exit 1
    }
    Write-Ok "sitemap.xml: $size bytes"
}

$pages = @(Get-ChildItem $builtDocs -Filter *.html -File -Recurse)
if ($pages.Count -eq 0) {
    Write-Err 'No HTML pages produced. Not mirroring.'
    exit 1
}
Write-Ok "$($pages.Count) HTML page(s) produced"

# ---------------------------------------------------------------------------
# Mirror back
#
# /MIR makes docs/ match the fresh render exactly, which also clears stale
# artifacts (e.g. an orphaned hashed CSS file no page references any more).
# ---------------------------------------------------------------------------
Write-Section 'Mirror into repo'

$targetDocs = Join-Path $RepoRoot 'docs'
robocopy $builtDocs $targetDocs /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
$rc = $LASTEXITCODE

# robocopy exit codes: 0-7 are success (8+ indicates a real failure).
if ($rc -ge 8) {
    Write-Err "robocopy failed with exit code $rc"
    exit 1
}
Write-Ok "docs/ updated (robocopy code $rc)"

if (-not $KeepWorkDir) {
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok 'work dir cleaned up'
} else {
    Write-Warn "work dir kept: $WorkDir"
}

Write-Host ''
Write-Ok 'Render complete.'

# robocopy sets $LASTEXITCODE to 1 on "files copied successfully". Without an
# explicit exit, that code leaks out as this script's status and every caller
# reads a successful render as a failure.
exit 0
