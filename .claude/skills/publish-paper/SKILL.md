---
name: publish-paper
description: Publish a finished paper PDF to Dropbox under its permanent canonical filename via the rclone pipeline in tools/publish/, then wire the resulting share link into the CV and research page. Use this skill whenever the user wants a PDF to be downloadable from their website — they hand over a fresh Overleaf download or a draft and say publish it, upload it, post it, put it online, share it, or push the new version; when they want to replace an already-linked PDF with a revised draft; when they ask to add a download link or preprint link to a paper; or when they mention the publish folder, website-materials, rclone, or the manifest. Also use it when they ask why a paper link is broken or whether a link will survive an update.
---

# Publishing a paper PDF

The job: get a PDF into Dropbox under a filename that never changes, so the URL
printed on the CV and website keeps working across every revision.

## The one idea everything follows from

A Dropbox share link points at a **file object**, not a path.

| Action | File object | Share link |
|---|---|---|
| Overwrite via the API (`mode=overwrite`) | preserved, new revision | **survives** |
| Delete and recreate at the same path | new object | **dies silently** |

The Dropbox desktop client does the second thing. `rclone` uses the API and
does the first. That is the entire reason this pipeline exists, and it explains
every rule below.

Consequences that are easy to get wrong:

- **Renaming a published file breaks it.** A rename is a delete plus a create.
  Filenames are permanent once a share link exists. The same applies to moving
  the remote folder.
- **`rclone copy`, never `rclone sync`.** `sync` makes the destination match
  the source, so deleting a local PDF would delete the remote one and kill a
  live link on the CV.
- **Where the local PDF came from is irrelevant.** A fresh Overleaf download, a
  local `latexmk` run, a renamed copy — local file identity means nothing to
  Dropbox. Only the remote path and the overwrite mode matter.

## Layout

| Path | What |
|---|---|
| `C:\Users\jensenn\website-materials\` | local staging folder, deliberately **outside** the Dropbox-synced tree |
| `dropbox:Published/website-materials/` | remote folder, effectively public — publishable PDFs only |
| `tools/publish/manifest.yml` | paper → filename → `share_url` → `last_pushed` |
| `tools/publish/publish.ps1` | push everything, or one file with `-File` |
| `tools/publish/stage.ps1` | copy an arbitrary PDF in under its canonical name |

`tools/publish/README.md` has the full rationale and the link-stability
acceptance test.

## Workflow

### 1. Find the canonical filename

`manifest.yml` is the source of truth. Match the user's paper against its
entries by title. If nothing matches, the file has never been published — say
so and agree a name before touching anything, because the name is permanent.

Names are venue-free, date-free, version-free: `jensen-absinthe.pdf`, not
`jensen-absinthe-jpe-r2-2026-09.pdf`. Venue names go stale when a paper moves
journals; dates belong on the PDF title page where readers actually look.

Never invent a filename silently, and never quietly pick a different name for a
paper that already has one — that is the rename trap wearing a disguise.

### 2. Stage and publish

```powershell
.\tools\publish\stage.ps1 <source-pdf> <canonical-name> -Publish
```

Or separately if the PDF is already staged:

```powershell
.\tools\publish\publish.ps1 -File <canonical-name>
```

`publish.ps1` refuses to run if the staging folder is inside a Dropbox-synced
tree, reports what transferred versus what was skipped as unchanged, and
updates `last_pushed` in the manifest. Use `-DryRun` to preview.

If a shell reports `rclone: command not found`, the environment is stale rather
than broken — rclone is on the persistent user PATH but not in already-running
shells. Refresh it:

```powershell
$env:Path += ';' + [Environment]::GetEnvironmentVariable('Path','User')
```

`publish.ps1` resolves `rclone.exe` on its own, so this only matters for manual
rclone calls.

### 3. First publish: the user creates the share link

The scripts never create, read, or modify sharing settings — deliberately. On a
first push, `publish.ps1` appends a stub entry to the manifest and says a link
is needed.

Ask the user to right-click the file in Dropbox → **Copy link**, and paste it
back. Then write it into that entry's `share_url` in `manifest.yml`. This is
the one field that cannot be regenerated, so edit the manifest surgically —
change that line and leave the rest of the file alone.

For a link that should serve the PDF directly rather than Dropbox's preview
page, the `?raw=1` form is what belongs on the website.

### 4. Update the site links

Put the URL where readers will find it — `research/index.qmd`, and
`cv.qmd` if the paper is listed with a preprint or download link. Match the
surrounding link idiom in each file. The `update-cv` skill covers the
conventions of those two files in detail; read it if the edit is more than
swapping a URL.

### 5. Render and commit

```powershell
.\tools\render-site.ps1
```

Never run `quarto render` directly — from a worktree it silently finds zero
inputs, wipes `docs/`, and exits 0 reporting success. The script guards against
that. Then commit the sources, the manifest, and the regenerated `docs/`.

## Things only the user can do

- **`rclone config`** is an interactive OAuth wizard that opens a browser. It
  cannot run from an agent shell (stdin is the null device) and it cannot run
  from a shell whose environment predates the rclone install. Hand it over with
  instructions; do not try to automate it.
- **Creating share links**, per above.

## Safety

The remote folder is effectively public. Only `*.pdf` is ever uploaded, and
`Published/` exists solely to keep that folder away from personal ones — a
misplaced file lands somewhere harmless instead of one right-click from being
world-readable. Never stage anything there that would embarrass the user in
front of a referee.

`rclone.conf` in `%APPDATA%\rclone\` holds a Dropbox refresh token. Never copy
it into the repo (public, serves GitHub Pages) or into Dropbox itself
(circular). On a new machine, re-run `rclone config` rather than moving the
file.

## Worth mentioning when it comes up

The site already serves PDFs directly from `docs/files/` on GitHub Pages, and
those URLs are path-based — they are stable by construction, need none of this
machinery, and travel with the repo to any machine. Dropbox earns its place for
files heavy enough that you would not want every revision living in git history
forever. If the user is deciding where a new PDF should live, that is the real
tradeoff.
