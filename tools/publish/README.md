# website-materials publishing pipeline

One command pushes finished paper PDFs to Dropbox under share links that
**never change**, so the URLs printed on the CV and website stay valid across
every revision.

```
drop PDF in C:\Users\<you>\website-materials\  ->  .\publish.ps1  ->  done
```

## Why this exists

A Dropbox share link points at a file *object*, not a path.

| Action | File object | Share link |
|---|---|---|
| Update the file via the API with `mode=overwrite` | preserved, new revision | **survives** |
| Delete the file and create a new one at the same path | new object | **dies silently** |

The Dropbox **desktop client** does the second thing when it replaces a file.
**rclone** uses the API and does the first. That is the entire reason for this
setup.

Corollary: where the local PDF came from is irrelevant — a fresh Overleaf
download, a local `latexmk` run, a renamed copy. Local file identity does not
matter. Only the remote path and the overwrite mode do.

## Layout

| Path | What |
|---|---|
| `C:\Users\<you>\website-materials\` | local publish folder. **Outside** the Dropbox-synced tree, on purpose |
| `dropbox:website-materials/` | remote folder. Publishable PDFs only — it is effectively public |
| `manifest.yml` | paper -> filename -> share URL lookup table |
| `publish.ps1` | push everything (or one file) |
| `stage.ps1` | copy an arbitrary PDF in under its canonical name |
| `make-linktest.ps1` | generate the throwaway PDF for the link-stability test |

## One-time setup

1. rclone (already installed via `winget install --id Rclone.Rclone --exact`).
   winget did not create a PATH shim, so `publish.ps1` resolves `rclone.exe`
   itself — nothing to configure.
2. Create the Dropbox remote. **Interactive, opens a browser:**

   ```
   rclone config
   ```

   `n` (new remote) -> name it `dropbox` -> storage type `dropbox` -> accept the
   defaults for client_id/client_secret (blank) -> `y` to use auto config ->
   sign in when the browser opens -> `y` to confirm -> `q` to quit.
3. Create the `website-materials` folder in Dropbox (the first push creates it
   too).

## Daily use

```powershell
# push everything in the publish folder
.\publish.ps1

# push one file
.\publish.ps1 -File jensen-absinthe.pdf

# see what would move, change nothing
.\publish.ps1 -DryRun

# stage a fresh Overleaf download under its permanent name, then push
.\stage.ps1 ~\Downloads\absinthe_v7.pdf jensen-absinthe.pdf -Publish
```

After a **first** push of a new filename, `publish.ps1` appends a stub entry to
`manifest.yml` and tells you a link is needed. Create it by hand in Dropbox
(right-click -> Copy link) and paste it into `share_url`. The script never
touches sharing settings.

## Naming convention

Permanent, venue-free, date-free, version-free. Venue names go stale when a
paper moves journals; dates belong on the PDF title page where readers look.

```
jensen-emissions.pdf          not  jensen-emissions-jre-r3.pdf
jensen-absinthe.pdf           not  jensen-absinthe-2026-09.pdf
jensen-prosecutor-turnover.pdf
jensen-cv.pdf
```

## Rules the scripts enforce

1. **The publish folder must not be inside the Dropbox-synced tree.** If the
   desktop client also manages it, the client will delete-and-create and break
   links. `publish.ps1` refuses to run and explains why. Detection is three
   layers: `info.json` sync roots (classic *and* MSIX/Store install paths),
   `.dropbox` marker files walking up, then a path-name heuristic.
2. **`rclone copy`, never `rclone sync`.** `sync` makes the destination match
   the source, so deleting a local PDF would delete the remote one and kill a
   live link on the CV. `copy` only adds and overwrites.
3. **Never rename a published file.** A rename is a delete plus a create.
   Filenames are permanent once a share link exists. `stage.ps1` warns on any
   canonical name not already in the manifest, and `publish.ps1` flags manifest
   entries whose local file has vanished — often the fingerprint of a rename.
4. **PDFs only.** Anything else in the publish folder is listed and skipped.
5. **The scripts never create, read, or modify share links.**

Also, out of band: do **not** enable Overleaf's built-in Dropbox sync for these
projects. It syncs whole projects including source files and behaves like the
desktop client.

## Acceptance test (run before trusting it with a real paper)

1. `.\make-linktest.ps1 -Revision 1` then `.\publish.ps1 -File linktest.pdf`
2. Create a share link for `linktest.pdf` by hand in Dropbox.
3. Check that **both** the plain link and the `?raw=1` form resolve to the PDF.
4. `.\make-linktest.ps1 -Revision 2` then `.\publish.ps1 -File linktest.pdf`
5. Re-check **both** URL forms. They must still resolve, and must now show
   "LINKTEST REVISION 2" across 2 pages.
6. Repeat with `-Revision 3`. **Two consecutive replacements, not one** — a
   delete-and-create path sometimes only shows up on the second.

If any link dies, stop. The fallback is a shared *folder* link, which is stable
but lands visitors on a file browser instead of the paper.

## Notes

- `publish.ps1` uses `--checksum`, so rclone compares content hashes rather
  than size+modtime. A regenerated PDF is never skipped because its timestamp
  happened to match.
- Each run writes an rclone log to `%TEMP%\rclone-publish-<timestamp>.log`.
- `manifest.yml` is edited surgically, one line at a time. It is never
  reserialized, because a YAML round-trip would reformat the comments and risk
  mangling hand-typed `share_url` values — the one field here that cannot be
  regenerated.
