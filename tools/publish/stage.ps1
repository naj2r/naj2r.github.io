<#
.SYNOPSIS
    Copy an arbitrary PDF into the publish folder under its canonical name.

.DESCRIPTION
    Overleaf downloads arrive with project-derived filenames in Downloads.
    This drops one into the publish folder under the permanent name the
    website links to, then optionally publishes it.

    Where the local PDF came from is irrelevant: a fresh Overleaf download, a
    local latexmk run, a renamed copy. Local file identity does not matter to
    Dropbox. Only the remote path and the overwrite mode do.

    What DOES matter is the canonical name. Once a share link exists for a
    filename, that filename is permanent - a rename is a delete plus a create,
    and the old link dies. So this warns loudly when the canonical name is not
    already in the manifest.

.PARAMETER Source
    Path to the PDF to stage (e.g. ~\Downloads\absinthe_draft_v7.pdf).

.PARAMETER CanonicalName
    Permanent published filename (e.g. jensen-absinthe.pdf).

.PARAMETER Publish
    Run publish.ps1 for this file after staging.

.PARAMETER Force
    Overwrite an existing staged file without prompting.

.EXAMPLE
    .\stage.ps1 ~\Downloads\absinthe_draft_v7.pdf jensen-absinthe.pdf

.EXAMPLE
    .\stage.ps1 ~\Downloads\absinthe_draft_v7.pdf jensen-absinthe.pdf -Publish
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string] $Source,
    [Parameter(Mandatory, Position = 1)][string] $CanonicalName,
    [string] $PublishFolder = (Join-Path $env:USERPROFILE 'website-materials'),
    [string] $Manifest      = (Join-Path $PSScriptRoot 'manifest.yml'),
    [switch] $Publish,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

function Write-Ok   { param([string]$Text) Write-Host "  $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "  $Text" -ForegroundColor Yellow }
function Write-Err  { param([string]$Text) Write-Host "  $Text" -ForegroundColor Red }

# --- validate source ---
if (-not (Test-Path $Source)) {
    Write-Err "Source file not found: $Source"
    exit 1
}
$src = Get-Item $Source
if ($src.Extension.ToLower() -ne '.pdf') {
    Write-Err "Only PDFs are published. Refusing: $($src.Name)"
    exit 1
}

# --- validate canonical name ---
if ([System.IO.Path]::GetExtension($CanonicalName).ToLower() -ne '.pdf') {
    Write-Err "Canonical name must end in .pdf: $CanonicalName"
    exit 1
}
if ($CanonicalName -match '[\\/]') {
    Write-Err "Canonical name must be a bare filename, not a path: $CanonicalName"
    exit 1
}

if (-not (Test-Path $PublishFolder)) {
    New-Item -ItemType Directory -Path $PublishFolder -Force | Out-Null
    Write-Ok "Created publish folder: $PublishFolder"
}

# --- is this name known to the manifest? ---
$known = $false
if (Test-Path $Manifest) {
    foreach ($line in (Get-Content $Manifest)) {
        if ($line -match '^\s+filename:\s*(.*)$') {
            $n = $Matches[1].Trim().Trim([char]34).Trim([char]39)
            if ($n -eq $CanonicalName) { $known = $true }
        }
    }
}

if (-not $known) {
    Write-Host ''
    Write-Warn "'$CanonicalName' is not in the manifest yet."
    Write-Warn 'That means it has never been published, so no share link exists for it.'
    Write-Warn 'After the first push you will need to create the link by hand in Dropbox'
    Write-Warn "and paste it into share_url in $Manifest"
    Write-Host ''
    Write-Warn 'Double-check the spelling now. Once a link exists, this name is permanent -'
    Write-Warn 'renaming a published file breaks every URL pointing at it.'
    Write-Host ''
}

# --- copy into place ---
$dest = Join-Path $PublishFolder $CanonicalName

if ((Test-Path $dest) -and -not $Force) {
    $existing = Get-Item $dest
    Write-Host ''
    Write-Warn "$CanonicalName already staged:"
    Write-Warn ('  existing: {0:N0} KB, modified {1}' -f ($existing.Length / 1KB), $existing.LastWriteTime)
    Write-Warn ('  incoming: {0:N0} KB, modified {1}' -f ($src.Length / 1KB), $src.LastWriteTime)
    $answer = Read-Host '  Replace it? [y/N]'
    if ($answer -notmatch '^[Yy]') {
        Write-Host '  Aborted; nothing staged.'
        exit 0
    }
}

Copy-Item -LiteralPath $src.FullName -Destination $dest -Force
$staged = Get-Item $dest
Write-Ok ('Staged {0} -> {1} ({2:N0} KB)' -f $src.Name, $CanonicalName, ($staged.Length / 1KB))

# --- optionally publish ---
if ($Publish) {
    Write-Host ''
    Write-Host 'Publishing...' -ForegroundColor Cyan
    $publishScript = Join-Path $PSScriptRoot 'publish.ps1'
    if (-not (Test-Path $publishScript)) {
        Write-Err "publish.ps1 not found next to this script ($PSScriptRoot)."
        exit 1
    }
    & $publishScript -File $CanonicalName -PublishFolder $PublishFolder -Manifest $Manifest
    exit $LASTEXITCODE
} else {
    Write-Host ''
    Write-Host '  Next:  .\publish.ps1' -ForegroundColor DarkGray
    Write-Host "  or:    .\publish.ps1 -File $CanonicalName" -ForegroundColor DarkGray
}
