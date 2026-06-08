# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Source for https://futro.dev — a Hugo static site (custom in-repo theme, no external theme) plus a resume PDF, self-hosted on the owner's OVH server. Design spec and implementation plan live in `docs/superpowers/`.

## Commands

```bash
./scripts/install-tools.sh          # install pinned toolchain (hugo, typst, lychee, htmltest) from versions.env into ~/.local/bin
./scripts/install-tools.sh --update # resolve latest releases, rewrite versions.env, install
./scripts/build.sh                  # full build: hugo --minify --panicOnWarning, then typst renders public/resume.pdf
./scripts/check.sh                  # all verification gates (run AFTER build.sh): htmltest, lychee, page-weight
hugo server                         # local dev server (note: /resume.pdf does not exist in dev — typst only runs in build.sh)
```

There are no unit tests. Verification = `build.sh` then `check.sh`. Build order matters: typst writes the PDF into `public/` after Hugo, and the link checkers run after that so the `/resume.pdf` link is covered.

## Hard constraints

- **Toolchain ethos: pinned single binaries only.** No npm, no JVM, no CSS frameworks anywhere in the build path. Versions are pinned in `versions.env`. Do not introduce package-manager dependencies.
- **Page weight CI gate:** each page ≤ 75 KiB gzipped (page HTML + all shared CSS/JS/fonts), enforced by `scripts/check-page-weight.sh`.
- **JavaScript:** the dark-mode toggle (`assets/js/theme.js`) is the only JS on the site. Keep it that way.
- **Strict builds:** `refLinksErrorLevel = "ERROR"` + `--panicOnWarning` — broken internal refs or any Hugo warning fails the build.
- Lighthouse 100 across all four mobile categories is the development bar (checked manually, deliberately not CI-gated).
- No snap packages on this machine; for headless visual checks use Playwright's bundled browsers.

## Architecture

- **Resume is single-sourced from `data/resume.yaml`:** the HTML page renders it via `layouts/_default/resume.html`; the PDF is rendered by Typst (`typst/resume.typ`), which reads the same YAML directly via its built-in `yaml()` loader. Edit content in the YAML, never in the templates.
- **Theme is hand-rolled:** `layouts/` (templates + `_partials/`), `assets/scss/main.scss` (hand-written SCSS via Hugo's pipeline, fingerprinted), `assets/js/theme.js`. Typography-first, near-monochrome + one accent, light/dark via CSS custom properties.
- **RSS:** the canonical feed is the posts section feed at `/posts/index.xml`; the site-level feed is disabled (`outputs` in `hugo.toml`).
- **Content:** `content/posts/` and `content/projects/` (one `.md` per entry), `content/_index.md` homepage. No taxonomies (`disableKinds`).

## Forge / PRs

This repo is hosted on a self-hosted Forgejo instance (`git.int.futro.dev`), not GitHub — `gh` does not work here. Use the `fj` CLI for forge operations (PRs, issues, releases, actions): e.g. `fj pr create --base main --head <branch> --body "..."`, `fj pr merge <n> --method merge --delete`.

## CI / deploy (`.forgejo/workflows/build.yml`)

Forgejo Actions, not GitHub Actions (`.github/workflows/` is empty). Quirks that will bite if "fixed":

- `actions/upload-artifact` / `download-artifact` are pinned at **v3** — Forgejo speaks the classic artifact API; v4+ refuses non-github.com hosts.
- The publish job (main only) `docker build --push`es a `FROM scratch` image (`Containerfile`, just `COPY public/ /site/`) to `registry.int.futro.dev` (Zot, tailnet-gated, no auth — no registry login step), then triggers deployment via ntfy (`secrets.NTFY_DEPLOY_TOKEN`). The runner's docker is buildx with the container driver, so the push must happen from the build command itself — a separate `docker push` finds no image.
- This repo's contract ends at "image in registry + ntfy trigger". Caddy config, podman mount, and observability wiring live in the separate IaC repo.
