# futro.dev

Source for <https://futro.dev> — a Hugo static site with a hand-rolled theme and a
Typst-rendered resume PDF, shipped as an immutable container image to a self-hosted
server. For architecture, hard constraints, and CI/deploy internals see
[`CLAUDE.md`](CLAUDE.md); this README is the day-to-day runbook.

## One-time setup

```bash
./scripts/install-tools.sh   # install pinned hugo, typst, lychee, htmltest into ~/.local/bin
```

The font-inlining step needs a Python venv with `fonttools` + `brotli`. Create it once
and point `FONT_PYTHON` at it (see `docs/superpowers/plans/2026-06-08-iosevka-custom-build.md`):

```bash
python3 -m venv ~/.cache/futro-font-venv
~/.cache/futro-font-venv/bin/pip install fonttools==4.63.0 brotli==1.2.0
export FONT_PYTHON="$HOME/.cache/futro-font-venv/bin/python"   # add to your shell profile
```

## Everyday loop

```bash
hugo server          # live preview at http://localhost:1313  (note: /resume.pdf only exists after build.sh)
./scripts/build.sh   # full build: hugo --minify, then Typst renders public/resume.pdf, then font inlining
./scripts/check.sh   # verification gates — run AFTER build.sh (htmltest, lychee, per-page weight budget)
```

All content lives in `content/`. Pages are plain Markdown with YAML front matter.
Adding or removing a file is the whole operation — no index to update; list pages
(`/posts/`, `/projects/`) are generated automatically, sorted newest-first by `date`.

## Add a post

Create `content/posts/<slug>.md`. The filename is the URL slug
(`content/posts/my-thing.md` → `/posts/my-thing/`).

```markdown
---
title: "My post title"
date: 2026-06-08
description: "One-line summary used for the <meta> description and social cards."
---

Body in Markdown. Internal links are root-relative, e.g. [resume](/resume/).
```

- `date` drives ordering on `/posts/` and the "approx. N min read" estimate shown on the page.
- Posts are included in the RSS feed at `/posts/index.xml` automatically.

## Add a project

Create `content/projects/<slug>.md` with the same front matter as a post
(`title`, `date`, `description`). Projects are listed on `/projects/` but are **not**
in any RSS feed (the section is HTML-only by design).

## Remove a post or project

Delete the corresponding `content/posts/<slug>.md` or `content/projects/<slug>.md`,
then rebuild. The list page and feed update on the next build.

> Check for inbound links before deleting — `refLinksErrorLevel = "ERROR"` plus
> `--panicOnWarning` means a dangling internal ref will fail the build. Grep the repo
> for the slug first: `grep -rn "<slug>" content/ layouts/`.

## Edit the resume

The resume is single-sourced from [`data/resume.yaml`](data/resume.yaml). The HTML page
(`/resume/`) and the PDF (`/resume.pdf`, rendered by Typst) both read it — **edit the
YAML, never the templates**, so the two can't drift.

## Edit the homepage

`content/_index.md` — title front matter plus the intro Markdown body.

## Ship it

Commit to a branch and open a PR on the self-hosted Forgejo instance with the `fj` CLI
(`gh` does not work here):

```bash
git checkout -b my-change
git add content/posts/my-thing.md          # stage by name, not -A
git commit -m "post: my thing"
git push -u origin my-change
fj pr create --base main --head my-change "post: my thing" --body "..."
fj pr merge <n> --method merge --delete
```

Merging to `main` triggers CI (Forgejo Actions): it builds, runs the gates, packs
`public/` into a `FROM scratch` image, pushes it to the tailnet registry, and fires an
ntfy deploy trigger. A deploy is just an image pull on the server — no manual step here.
