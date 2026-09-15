---
name: update-cv
description: Add or update an entry on Nicholas Jensen's CV and academic website (naj2r.github.io) — publications, working papers, papers under review, conference presentations, workshops, awards, grants, teaching, or media appearances — then rebuild and commit the site. Use this skill whenever the user wants to put something new on their CV or research page, mentions a paper being accepted, published, sent out for review, or moving journals, mentions a conference talk they gave or will give, an award or fellowship, a class they taught, or a news interview or quote — even if they just paste a LaTeX title block, a citation, a DOI, or a screenshot and say "add this." Also use it when they ask to fix or correct something already on the CV.
---

# Updating the CV and website

The CV and the research page are two separate hand-edited Quarto source files
that render into one site. Most of the work in this skill is knowing **which
file(s) an item belongs in** and **which formatting idiom that section uses** —
get those right and the rest is mechanical.

## The two source files

| File | What it is | Audience |
|---|---|---|
| `cv.qmd` | The full CV. Renders to **both** `docs/cv.html` and `docs/cv.pdf` | Complete record, terse entries |
| `research/index.qmd` | The Research & Publications page. HTML only | Selected work, with abstracts and DOI buttons |

Never edit anything under `docs/` — it is generated output. Edit the `.qmd`
source, then re-render.

## Where each item goes

| Item | `cv.qmd` | `research/index.qmd` |
|---|---|---|
| Journal article | yes | yes |
| Book chapter | yes | yes |
| Paper under review | yes | yes |
| Working paper | yes | yes |
| Conference presentation | yes | no |
| Colloquium / workshop attended | yes | no |
| Award, honor, grant | yes | no |
| Teaching | yes | no |
| Media appearance | yes | no |

Anything paper-shaped lives in both files. Everything else is CV-only. When an
item goes in both, add it to both in the same change — the two drifting apart
is the most common defect here.

## Formatting idioms

`cv.qmd` uses two different idioms depending on the section. Match the
surrounding entries rather than inventing a format.

**Research sections** (Journal Articles, Book Chapters, Under Review, Working
Papers) are plain markdown bullet lists:

```markdown
### Working Papers

- "Title of the Paper" (with Coauthor Name)
- "Solo-Authored Title"

### Under Review

- "Title" (with Coauthor), at *Journal Name* | [Preprint](https://url)

### Journal Articles

- Author, A., & Jensen, N. (2026). "Title." *Journal*, 57(3), 441--475. [doi: 10.xxxx/yyyy](https://doi.org/10.xxxx/yyyy)
```

**Dated sections** (Presentations, Colloquia, Awards, Teaching) use `cv-entry`
divs, with an optional `cv-detail` for a second line:

```markdown
::: {.cv-entry}
Southern Economic Association 95th Annual Meeting, Tampa, FL

[November 22-24, 2025]{.date}
:::

::: {.cv-detail}
Institution or supplementary note
:::
```

`research/index.qmd` uses headed entries separated by `---` rules:

```markdown
### Paper Title

**Nicholas Jensen and Coauthor Name** | *Working Paper*

Optional abstract paragraph.

[doi: 10.xxxx/yyyy](https://doi.org/10.xxxx/yyyy){.btn .btn-primary}

---
```

Author names there are written out in reading order ("Nicholas Jensen and
Patricia J. Hummel"), not in citation form.

## Two constraints worth knowing

**No inline formatting in a `cv-entry`'s first line.** The Lua filter at
`templates/cv-filter.lua` builds the LaTeX version by calling
`pandoc.utils.stringify`, which flattens italics and bold to bare text. Markup
there survives in HTML and silently vanishes in the PDF, leaving you with two
CVs that disagree. Write plain text; if emphasis feels necessary, reconsider
the wording instead.

**Escape `&`, `#`, and `%`** anywhere in `cv.qmd`. The filter escapes those for
LaTeX, but only in the places it handles — a stray one elsewhere can break the
PDF build.

## Paper lifecycle

A paper moves through sections as it progresses, and it must move in **both**
files at once:

```
Working Papers  ->  Under Review  ->  Journal Articles
```

When the user says a paper was accepted or published, the job is a *move*, not
an addition: delete the old entry, add the new one in the right section, and
upgrade the metadata (add volume/pages/DOI, drop the preprint link if a
published version supersedes it). Leaving a stale copy in Working Papers while
adding it to Journal Articles is the failure mode to watch for.

## Dates and forthcoming items

Presentations are listed newest-first. If a presentation's date is in the
future relative to today, append `(scheduled)` to the venue line so it does not
read as already delivered:

```markdown
::: {.cv-entry}
Southern Economic Association 96th Annual Meeting, Houston, TX (scheduled)

[November 21-23, 2026]{.date}
:::
```

Check the date before assuming; conferences are often added a year ahead.

## Workflow

1. **Read the target section first.** Conventions vary section to section, and
   matching what is already there matters more than any rule above.
2. **Make the edit** in `cv.qmd`, `research/index.qmd`, or both per the routing
   table.
3. **Render** — always via the script, never `quarto render` directly:

   ```powershell
   .\tools\render-site.ps1
   ```

   Running `quarto render` from a worktree silently produces nothing: Quarto's
   walker skips dot-directories on the absolute path, so a project under
   `.claude/worktrees/` is invisible to itself. It finds zero inputs, wipes
   `docs/`, writes a ~110-byte empty sitemap, and exits 0 reporting success.
   The script renders from a dot-free temp path, verifies inputs were actually
   discovered, sanity-checks the output, and mirrors `docs/` back. It refuses
   to overwrite `docs/` with an empty render.

4. **Verify the change landed** in the built output — grep `docs/cv.html` and
   `docs/research/index.html` for the new text rather than assuming.
5. **Commit** the `.qmd` sources and the regenerated `docs/` together.

## Handling pasted input

The user often pastes a LaTeX title block, a BibTeX entry, a DOI, or a
screenshot rather than typing out fields. Extract the title, authors, venue and
date from it and discard the rest — abstracts, keywords, JEL codes,
acknowledgements, and email addresses do not belong on the CV.

**Never put coauthors' email addresses anywhere in the CV or on the site**,
even when the pasted source contains them. Only Nicholas's own contact details
appear, in the header block.

If the user's paste implies a section that does not exist yet (for example a
first "Invited Talks" entry), ask before creating a new section — there is a
commented-out `Invited Talks` block in `cv.qmd` that may be the intended home.
