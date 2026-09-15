<#
.SYNOPSIS
    Publish finished PDFs to Dropbox with share links that never change.

.DESCRIPTION
    Copies PDFs from a local publish folder to a Dropbox folder using rclone,
    which talks to the Dropbox API directly and writes a new REVISION of the
    existing file object (mode=overwrite). The file object survives, so any
    share link already pointing at it keeps working.

    That is the entire point of this script. The Dropbox desktop client treats
    a replaced file as delete-then-create, which mints a new object and
    silently breaks every published URL. rclone does not.

    Deliberate design constraints:
      * Uses `rclone copy`, NEVER `rclone sync`. `sync` makes the destination
        match the source, so deleting a local PDF would delete the remote one
        and kill a live link on the CV. `copy` only adds and overwrites.
      * Refuses to run if the publish folder sits inside a Dropbox-synced tree,
        because the desktop client would then manage the same files.
      * Only *.pdf is ever uploaded. The remote folder is effectively public.
      * Never reads, writes, or creates share links or sharing settings.

.PARAMETER File
    Publish a single file by name (e.g. jensen-absinthe.pdf) instead of all PDFs.

.PARAMETER PublishFolder
    Local source folder. Default: %USERPROFILE%\website-materials

.PARAMETER Remote
    rclone remote and path. Default: dropbox:website-materials

.PARAMETER DryRun
    Show what would transfer without uploading anything.

.EXAMPLE
    .\publish.ps1

.EXAMPLE
    .\publish.ps1 -File jensen-absinthe.pdf

.EXAMPLE
    .\publish.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string] $File,
    [string] $PublishFolder = (Join-Path $env:USERPROFILE 'website-materials'),
    [string] $Remote        = 'dropbox:website-materials',
    [string] $Manifest      = (Join-Path $PSScriptRoot 'manifest.yml'),
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Section { param([string]$Text) Write-Host ''; Write-Host $Text -ForegroundColor Cyan }
function Write-Ok      { param([string]$Text) Write-Host "  $Text" -ForegroundColor Green }
function Write-Warn    { param([string]$Text) Write-Host "  $Text" -ForegroundColor Yellow }
function Write-Err     { param([string]$Text) Write-Host "  $Text" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Guard: is a path inside a Dropbox-synced tree?
#
# Three layers, because Dropbox ships in two very different shapes on Windows:
#   1. info.json from the classic installer AND from the MSIX/Store package
#      (the Store build hides it under AppData\Local\Packages\DropboxInc.*).
#      Authoritative when present: it lists the real sync roots.
#   2. .dropbox / .dropbox.device marker files, walking up from the path.
#      Works regardless of how Dropbox was installed.
#   3. A path component literally named "Dropbox". Last-resort heuristic.
# ---------------------------------------------------------------------------
function Get-DropboxSyncRoots {
    $roots = New-Object System.Collections.Generic.List[string]

    $infoPaths = @(
        (Join-Path $env:LOCALAPPDATA 'Dropbox\info.json'),
        (Join-Path $env:APPDATA      'Dropbox\info.json')
    )

    $pkgBase = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path $pkgBase) {
        Get-ChildItem $pkgBase -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'DropboxInc*' } |
            ForEach-Object {
                $infoPaths += (Join-Path $_.FullName 'LocalCache\Local\Dropbox\info.json')
                $infoPaths += (Join-Path $_.FullName 'LocalCache\Roaming\Dropbox\info.json')
            }
    }

    foreach ($ip in $infoPaths) {
        if (Test-Path $ip) {
            try {
                $info = Get-Content $ip -Raw | ConvertFrom-Json
                foreach ($acct in $info.PSObject.Properties) {
                    if ($acct.Value -and $acct.Value.path) {
                        $roots.Add([string]$acct.Value.path)
                    }
                }
            } catch {
                Write-Warn "Could not parse $ip - falling back to marker detection."
            }
        }
    }

    return $roots
}

function Test-InDropboxSync {
    param([Parameter(Mandatory)][string] $Path)

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')

    # Layer 1: declared sync roots
    foreach ($root in (Get-DropboxSyncRoots)) {
        $r = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
        if ($full -eq $r -or $full.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return @{ InSync = $true; Reason = "it is inside the Dropbox sync root declared in info.json: $r" }
        }
    }

    # Layer 2: marker files, walking up
    $dir = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
    while ($dir) {
        foreach ($marker in @('.dropbox', '.dropbox.device')) {
            if (Test-Path (Join-Path $dir.FullName $marker)) {
                return @{ InSync = $true; Reason = "an ancestor contains the Dropbox marker '$marker': $($dir.FullName)" }
            }
        }
        $dir = $dir.Parent
    }

    # Layer 3: name heuristic
    foreach ($seg in ($full -split '\\')) {
        if ($seg -eq 'Dropbox') {
            return @{ InSync = $true; Reason = "a folder in the path is named 'Dropbox': $full" }
        }
    }

    return @{ InSync = $false; Reason = '' }
}

# ---------------------------------------------------------------------------
# Manifest: parsed for reading, edited surgically for writing.
#
# We never reserialize this file. A round-trip through a YAML emitter would
# reformat the comments and risk mangling share_url values typed by hand, and
# share_url is the one field here that cannot be regenerated. So a write
# replaces exactly one line.
# ---------------------------------------------------------------------------
function Read-Manifest {
    param([string] $Path)

    $entries = @()
    if (-not (Test-Path $Path)) { return $entries }

    $lines = @(Get-Content $Path)
    $cur = $null

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if ($line -match '^-\s+paper:\s*(.*)$') {
            if ($cur) { $entries += $cur }
            $cur = [ordered]@{
                paper          = $Matches[1].Trim()
                filename       = ''
                share_url      = ''
                last_pushed    = ''
                startLine      = $i
                lastPushedLine = -1
                endLine        = $i
            }
        } elseif ($cur) {
            if ($line -match '^\s+filename:\s*(.*)$') {
                $cur.filename = $Matches[1].Trim().Trim([char]34).Trim([char]39)
                $cur.endLine  = $i
            } elseif ($line -match '^\s+share_url:\s*(.*)$') {
                $cur.share_url = $Matches[1].Trim().Trim([char]34).Trim([char]39)
                $cur.endLine   = $i
            } elseif ($line -match '^\s+last_pushed:\s*(.*)$') {
                $cur.last_pushed    = $Matches[1].Trim().Trim([char]34).Trim([char]39)
                $cur.lastPushedLine = $i
                $cur.endLine        = $i
            }
        }
    }

    if ($cur) { $entries += $cur }
    return $entries
}

function Set-ManifestLastPushed {
    param(
        [string] $Path,
        [string] $Filename,
        [string] $Stamp
    )

    $lines   = @(Get-Content $Path)
    $entries = Read-Manifest -Path $Path
    $entry   = $entries | Where-Object { $_.filename -eq $Filename } | Select-Object -First 1
    if (-not $entry) { return $false }

    if ($entry.lastPushedLine -ge 0) {
        $lines[$entry.lastPushedLine] = '  last_pushed: "' + $Stamp + '"'
    } else {
        # Entry has no last_pushed line; insert one after its last known field.
        $head = $lines[0..$entry.endLine]
        $tailStart = $entry.endLine + 1
        if ($tailStart -le ($lines.Count - 1)) {
            $tail = $lines[$tailStart..($lines.Count - 1)]
        } else {
            $tail = @()
        }
        $lines = $head + @('  last_pushed: "' + $Stamp + '"') + $tail
    }

    Set-Content -Path $Path -Value $lines -Encoding UTF8
    return $true
}

function Add-ManifestStub {
    param([string] $Path, [string] $Filename, [string] $Stamp)

    $stub = @(
        '',
        '- paper: TODO - describe this paper',
        "  filename: $Filename",
        '  share_url: ""',
        '  last_pushed: "' + $Stamp + '"'
    )
    Add-Content -Path $Path -Value $stub -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Locate rclone.
#
# winget installs rclone as a portable package and does not always create a
# shim in its Links folder, so `rclone` may not be on PATH at all. The install
# directory is version-stamped (rclone-v1.75.1-windows-amd64), so putting it
# on PATH would break at the next upgrade. Resolve it at run time instead.
# ---------------------------------------------------------------------------
function Resolve-Rclone {
    $cmd = Get-Command rclone -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $searchRoots = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'),
        (Join-Path $env:ProgramFiles 'rclone'),
        (Join-Path $env:ProgramData 'chocolatey\bin'),
        (Join-Path $env:USERPROFILE 'scoop\shims')
    )

    foreach ($root in $searchRoots) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem $root -Filter 'rclone.exe' -Recurse -ErrorAction SilentlyContinue |
               Sort-Object FullName -Descending |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    return $null
}

# ===========================================================================
# 1. Preflight
# ===========================================================================
Write-Section 'Preflight'

$rclone = Resolve-Rclone
if (-not $rclone) {
    Write-Err 'rclone is not installed, or could not be found.'
    Write-Host '  Install it with:  winget install --id Rclone.Rclone --exact'
    exit 1
}
Write-Ok "rclone: $rclone"

if (-not (Test-Path $PublishFolder)) {
    Write-Err "Publish folder does not exist: $PublishFolder"
    exit 1
}
$PublishFolder = (Resolve-Path $PublishFolder).Path
Write-Ok "publish folder: $PublishFolder"

# The hard constraint. If the desktop client manages these files, it will
# delete-and-create on every replacement and every share link dies.
$guard = Test-InDropboxSync -Path $PublishFolder
if ($guard.InSync) {
    Write-Host ''
    Write-Err 'REFUSING TO RUN.'
    Write-Host "  The publish folder is inside a Dropbox-synced tree, because $($guard.Reason)" -ForegroundColor Red
    Write-Host ''
    Write-Host '  Why this matters: the Dropbox desktop client replaces a changed file by'
    Write-Host '  deleting it and creating a new one. That mints a new file object, and every'
    Write-Host '  share link pointing at the old object stops working - including the URLs'
    Write-Host '  already printed on your CV and website.'
    Write-Host ''
    Write-Host '  Fix: move the publish folder somewhere the client does not manage, e.g.'
    Write-Host "       $(Join-Path $env:USERPROFILE 'website-materials')"
    Write-Host '  rclone reaches Dropbox through the API and does not need the client at all.'
    exit 1
}
Write-Ok 'publish folder is outside the Dropbox sync tree'

$remoteName = ($Remote -split ':')[0]

# Do NOT redirect rclone's stderr here. In PowerShell 5.1, redirecting a native
# command's stderr (2>$null or 2>&1) wraps each line in an ErrorRecord, which
# $ErrorActionPreference = 'Stop' then promotes to a terminating error - so
# rclone's harmless "config file not found" NOTICE would abort the script.
# --log-level ERROR silences that notice at the source instead.
$configured = @(& $rclone listremotes --log-level ERROR)
if ($LASTEXITCODE -ne 0 -or ($configured -notcontains ($remoteName + ':'))) {
    Write-Err "rclone remote '${remoteName}:' is not configured."
    Write-Host '  Run:  rclone config'
    Write-Host "  Create a new remote named '$remoteName', type 'dropbox', accept the defaults,"
    Write-Host '  and complete the browser sign-in when it opens.'
    exit 1
}
Write-Ok "remote: $Remote"

# ===========================================================================
# 2. Decide what to send
# ===========================================================================
Write-Section 'Source files'

if ($File) {
    $local = Join-Path $PublishFolder $File
    if (-not (Test-Path $local)) {
        Write-Err "No such file in the publish folder: $File"
        exit 1
    }
    if ([System.IO.Path]::GetExtension($File).ToLower() -ne '.pdf') {
        Write-Err "Only PDFs are published. Refusing: $File"
        exit 1
    }
    $includes   = @('--include', $File)
    $candidates = @(Get-Item $local)
} else {
    $includes   = @('--include', '*.pdf')
    $candidates = @(Get-ChildItem $PublishFolder -Filter *.pdf -File)
}

if ($candidates.Count -eq 0) {
    Write-Warn "No PDFs found in $PublishFolder - nothing to do."
    exit 0
}

foreach ($c in $candidates) {
    Write-Ok ('{0}  ({1:N0} KB)' -f $c.Name, ($c.Length / 1KB))
}

$nonPdf = @(Get-ChildItem $PublishFolder -File | Where-Object { $_.Extension.ToLower() -ne '.pdf' })
if ($nonPdf.Count -gt 0) {
    Write-Warn "Ignoring $($nonPdf.Count) non-PDF file(s) in the publish folder (never uploaded):"
    foreach ($n in $nonPdf) { Write-Warn "  $($n.Name)" }
}

# ===========================================================================
# 3. Transfer
#
# `copy`, never `sync`. --checksum compares content hashes rather than
# size+modtime, so a regenerated PDF is never skipped just because its
# timestamp happened to match. Progress goes to the console; a parseable
# record goes to the log file.
# ===========================================================================
Write-Section 'Transfer'

$logFile = Join-Path $env:TEMP ('rclone-publish-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$rcArgs  = @(
    'copy', $PublishFolder, $Remote,
    '--checksum',
    '--progress',
    '--log-file', $logFile,
    '--log-level', 'INFO'
) + $includes

if ($DryRun) {
    $rcArgs += '--dry-run'
    Write-Warn 'DRY RUN - nothing will actually be uploaded.'
}

Write-Host "  rclone $($rcArgs -join ' ')" -ForegroundColor DarkGray
& $rclone @rcArgs
$rcExit = $LASTEXITCODE

if ($rcExit -ne 0) {
    Write-Err "rclone exited with code $rcExit. Manifest not updated."
    if (Test-Path $logFile) {
        Write-Host '  --- log tail ---' -ForegroundColor DarkGray
        Get-Content $logFile -Tail 20 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
    exit $rcExit
}

# ===========================================================================
# 4. Report and update the manifest
# ===========================================================================
Write-Section 'Result'

$copied    = New-Object System.Collections.Generic.List[string]
$unchanged = New-Object System.Collections.Generic.List[string]

if (Test-Path $logFile) {
    foreach ($line in (Get-Content $logFile)) {
        if ($line -match 'INFO\s*:\s*(?<f>.+?):\s*Copied\s*\(') {
            if (-not $copied.Contains($Matches['f'])) { $copied.Add($Matches['f']) }
        } elseif ($line -match 'INFO\s*:\s*(?<f>.+?):\s*Unchanged skipping') {
            if (-not $unchanged.Contains($Matches['f'])) { $unchanged.Add($Matches['f']) }
        }
    }
}

if ($copied.Count -gt 0) {
    Write-Host '  Transferred:' -ForegroundColor Green
    foreach ($f in $copied) { Write-Ok "  $f" }
} else {
    Write-Host '  Transferred: (none)' -ForegroundColor DarkGray
}

if ($unchanged.Count -gt 0) {
    Write-Host '  Skipped as unchanged:' -ForegroundColor DarkGray
    foreach ($f in $unchanged) { Write-Host "    $f" -ForegroundColor DarkGray }
}

if ($DryRun) {
    Write-Warn 'Dry run - manifest not updated.'
    exit 0
}

$stamp   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$entries = Read-Manifest -Path $Manifest
$newOnes = New-Object System.Collections.Generic.List[string]

foreach ($f in $copied) {
    $known = $entries | Where-Object { $_.filename -eq $f } | Select-Object -First 1
    if ($known) {
        [void](Set-ManifestLastPushed -Path $Manifest -Filename $f -Stamp $stamp)
    } else {
        Add-ManifestStub -Path $Manifest -Filename $f -Stamp $stamp
        $newOnes.Add($f)
    }
}

# ===========================================================================
# 5. What still needs a human
# ===========================================================================
$entries = Read-Manifest -Path $Manifest

if ($newOnes.Count -gt 0) {
    Write-Section 'ACTION NEEDED - new files have no share link'
    foreach ($f in $newOnes) {
        Write-Warn "$f was published for the first time and added to the manifest as a stub."
    }
    Write-Host ''
    Write-Host '  Create each share link by hand in Dropbox (right-click the file > Copy link),'
    Write-Host "  then paste it into share_url in $Manifest"
    Write-Host '  This script never creates or modifies share links.'
}

$missingUrl = @($entries | Where-Object { $_.filename -and -not $_.share_url -and $_.last_pushed })
if ($missingUrl.Count -gt 0) {
    Write-Section 'Published but no share_url recorded'
    foreach ($e in $missingUrl) { Write-Warn "$($e.filename)  -  $($e.paper)" }
}

# A manifest entry whose file has vanished locally is worth flagging: it is
# often the fingerprint of a rename, and a rename breaks the published link.
$localNames = @((Get-ChildItem $PublishFolder -Filter *.pdf -File).Name)
$orphans    = @($entries | Where-Object { $_.filename -and ($localNames -notcontains $_.filename) })
if ($orphans.Count -gt 0) {
    Write-Section 'Manifest entries with no local file'
    foreach ($e in $orphans) { Write-Host "    $($e.filename)  -  $($e.paper)" -ForegroundColor DarkGray }
    Write-Host '    (Fine if you simply have not staged them yet. But if one of these was'
    Write-Host '     renamed, the published link for the old name is already broken - a'
    Write-Host '     rename is a delete plus a create.)' -ForegroundColor DarkGray
}

Write-Host ''
Write-Ok "Done. rclone log: $logFile"
