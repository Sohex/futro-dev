# Self-built Iosevka: containerized build + build-time exact subsetting

Date: 2026-06-08
Status: Approved (design). Weight/italic *count* pending a frontend-design review — see Leanness.

## Problem

The site uses **Iosevka Etoile** (Iosevka's quasi-proportional *slab-serif* variant — `serifs = "slab"`).
Today it ships as a latin-subset, single-weight (400) woff2 at `static/fonts/iosevka-etoile-latin.woff2`,
produced **out-of-band** — commit `316e159` drops the binary in, with no reproducible build and no
recorded configuration.

Consequences:

1. **No provenance / no custom config.** We can't change character variants, weights, or coverage and
   rebuild deterministically.
2. **The weight hierarchy doesn't render.** `assets/scss/main.scss` references `font-weight` 330/400/500/
   550, but only 400 ships, so every element renders at 400 — hierarchy is currently carried by size,
   margin, letter-spacing, and colour alone.

We want to build Iosevka ourselves from a committed, pinned config, and ship only what the design needs.

## Viability spike (done locally, Iosevka v34.6.1)

Before specifying, the key risks were tested on the box with a real 2-weight Etoile build (the official
`IosevkaEtoile` plan restricted to Regular + Medium), subset with fonttools:

- **No variable font.** Iosevka has no `fvar`/`gvar`/`STAT`/`fontmake` anywhere; build targets are static
  per-weight only (`ttf`/`woff2`/`webfont`). **The variable-woff2 idea is dead — masters are static.**
- **The site renders 77 unique codepoints**, 5 of them non-ASCII: `·` (U+00B7), `–` (U+2013), `—`
  (U+2014), `’` (U+2019), `◐` (U+25D0, the theme-toggle glyph).
- **Exact-subset sizes:** a clean exact subset (no unused substitution features) is **~6 KB/weight**
  (real woff2, `pyftsubset --flavor=woff2`), vs ~30 KB for today's latin asset. The dominant levers are
  (a) exact glyph set and (b) **dropping unused *substitution* features** (`calt`/`frac`/`numr`/`dnom`/
  `locl`) — if kept, they drag ~60 extra fraction/superscript/alternate glyphs into the subset via glyph
  closure. Etoile has **no kerning** (`GPOS` empty; quasi-proportional spacing is in advance widths), so
  there's no kern data to preserve.
- **Subsetter = fonttools `pyftsubset`, not `hb-subset`.** `hb-subset` writes SFNT only — it does **not**
  emit woff2 regardless of file extension (verified: its `.woff2` output has TTF magic `0001 0000`).
  `pyftsubset --flavor=woff2` produces real brotli woff2 (`wOF2`) in one step, subset + compress, in well
  under a second — so build-time subsetting adds negligible wall-clock and needs no separate compressor.
- **Therefore the page-weight gate is no longer the binding constraint.** Even 3 weights + a real italic
  (~20 KB) sit far under the ceiling.

## Page-weight reality

`scripts/check-page-weight.sh` computes, per page, `gzip(page.html) + Σ gzip(shared .css/.js/.woff2)`,
failing above **76800 bytes**. Two facts:

- **woff2 does not gzip** (already Brotli-coded; gzip is a no-op or slightly larger), so a font's gate
  cost is its **raw size**.
- **CSS/JS are inlined** into each page (the "inline critical CSS/JS" work), so `public/` has no separate
  css/js — the **font is the only shared asset**, and CSS/JS cost is already inside each page's HTML.

Heaviest page (resume) HTML gz ≈ 4684 bytes ⇒ font may be up to ~**72 KB raw** and still pass. At ~10 KB/
weight, bytes are a non-issue; **leanness, not the gate, governs how many weights we ship.**

## Decisions

| Decision | Choice |
| --- | --- |
| Variants | Keep the owner's existing selections (a tweak of the official `IosevkaEtoile` plan) |
| Variable vs static | **Static per-weight** (Iosevka has no VF build) |
| Subsetting | **Build-time exact subset** in `build.sh` against rendered HTML (+ a safety floor), dropping unused substitution features |
| Subsetter | **fonttools `pyftsubset`** (real woff2 in one step) via a pinned venv (`tools/font/requirements.txt`); provisioned in CI with a venv step, not `install-tools.sh`/`versions.env` |
| Master artifact | Committed per-weight TTF master at **T4 coverage + a curated OT-feature menu** (~112 KB gz/weight): latin+European, Greek, Cyrillic, punctuation/currency/letterlike, arrows, math operators, box-drawing, geometric shapes, dingbats; plus typographic features (fractions, super/subscripts, ordinals, number styles, slashed zero, ligatures, case, localization, combining marks) **and coding ligatures** (calt/clig/dlig/rlig, for code blocks). cv##/ss## are not built (`noCvSs`). Produced by the container; source, not served |
| Build host | **Containerized one-shot**; npm isolated in a throwaway image |
| Iosevka pin | A **git tag**, pinned in the font pipeline (Containerfile / `build-font.sh`), **not** `versions.env` |
| Weight/italic count | **Deferred** to a frontend-design review; leanness governs (freed bytes ≠ add weights) |

## Architecture

Two stages with very different cadence.

### Stage 1 — container (occasional: only when config or Iosevka pin changes)

`tools/font/Containerfile` + `scripts/build-font.sh`:

1. `podman build` clones **pinned** Iosevka (`git clone --depth 1 --branch <tag>`), `npm install`, copies
   the owner's `private-build-plans.toml` (Etoile variants + the weights to ship), builds the static TTFs
   (`npm run build -- ttf::<plan>`; hinted — `ttfautohint` is in the image).
2. Inside the image, `pyftsubset` each weight's full TTF (~8 MB) down to the **T4 master** (ranges below),
   retaining a **curated OpenType-feature menu** (fractions, super/subscripts, ordinals, number styles,
   slashed zero, ligatures, case, localization, combining marks) **plus coding ligatures**
   (calt/clig/dlig/rlig, for code blocks) — ~112 KB gz/weight (vs ~87 KB with no features, ~392 KB with
   everything). cv##/ss## are not built (`noCvSs` in the build plan), so the variant choices are baked as
   defaults and there's no cv/ss bloat. This lets `build.sh` enable any menu feature later without a master
   rebuild. Covers realistic prose, European names, Greek/Cyrillic, and the technical symbols code blocks
   render in Iosevka.
3. `build-font.sh` extracts the master TTFs to the font-source dir; the owner commits them + the toml +
   the pipeline.

**T4 master coverage** (unicode ranges): `U+0000-024F` (Basic/Latin-1/Ext-A/Ext-B), `U+0370-03FF` (Greek),
`U+0400-04FF` (Cyrillic), `U+1E00-1EFF` (Latin Extended Additional), `U+2000-206F` (General Punctuation),
`U+20A0-20BF` (Currency), `U+2100-214F` (Letterlike), `U+2190-21FF` (Arrows), `U+2200-22FF` (Math
Operators), `U+2500-257F` (Box Drawing), `U+25A0-25FF` (Geometric Shapes, incl. the `◐` toggle glyph),
`U+2700-27BF` (Dingbats), `U+2C60-2C7F` (Latin Extended-C).

npm/Node live only in this throwaway image; the host and `build.sh` never see them.

### Stage 2 — `build.sh` (every site build, local and CI)

Inserted after `hugo --minify` (so rendered HTML exists) and before the checks:

1. Collect the codepoints used across `public/**/*.html` (strip tags/script/style, unescape entities) and
   union with a **safety floor**: printable ASCII (U+0020–007E) + the design's known symbols (`· – — ’ …
   © → ◐`). A shared `scripts/font-codepoints.py` produces this set, so the shipper and the coverage
   verifier can't drift. The floor means routine edits never need a font rebuild.
2. For each committed master, run **`pyftsubset --flavor=woff2`** to that codepoint set with the
   **retained layout-feature set chosen by the FE review** (default: drop all — `--layout-features=''
   --no-layout-closure` — since Iosevka's substitution features otherwise drag in fraction/superscript/
   alternate glyphs). Output to `public/fonts/` under a **content-hashed filename**
   (`iosevka-custom.<sha256[:8]>.woff2`, ~6 KB/weight, real woff2), then rewrite the stable token in the
   inlined HTML to that name (see Cache-busting).

Because the subset is regenerated from a broad master against the *actual* content on every build, the
shipped font always matches the page — no stale-subset tofu for anything the master covers. (Glyphs
outside the master's bounded coverage fall back to the system font, exactly as today.)

### Site integration (the only authored files that change)

- `assets/scss/main.scss` `@font-face` + font stacks: rename the CSS family to `"Iosevka Custom"` (3
  spots), point `src` at the **stable token** `/fonts/iosevka-custom.woff2`, set `font-weight` to the
  shipped value(s) (e.g. `400`, or one `@font-face` per shipped weight). Keep `font-display: swap`.
- `layouts/_partials/head.html`: preload `href` → the same stable token (`type="font/woff2"`).

### Cache-busting (Caddy `immutable`)

The serving Caddyfile sets `Cache-Control: immutable` on `/fonts/*`, and the font is not run through
Hugo's fingerprinting pipeline (it's generated post-Hugo by `build.sh`). So `build.sh` **content-hashes**
the filename (`iosevka-custom.<sha256[:8]>.woff2`) and `sed`s the stable token
(`/fonts/iosevka-custom.woff2`) to that name across all `public/**/*.html` (the token appears per-page
because CSS/JS are inlined). The name changes iff the bytes change — so `immutable` never serves a stale
font, and byte-identical rebuilds keep their cache.

## Subsetter sourcing

`build.sh` subsets with `pyftsubset` from a **pinned fonttools venv**, located via `FONT_PYTHON` (default
`python3`). Pins live in `tools/font/requirements.txt` (`fonttools==4.63.0`, `brotli==1.2.0`).

- **Locally:** a venv (see Prerequisites) with `FONT_PYTHON` exported to its `python`.
- **CI (`ubuntu-latest`, `.forgejo/workflows/build.yml`):** a workflow step creates a venv, `pip install`s
  the pinned requirements, and exports `FONT_PYTHON` via `$GITHUB_ENV` before `build.sh` runs. The publish
  job is unchanged — it consumes the already-built `public/` and needs no subsetter.

This is deliberately outside the `versions.env`/`install-tools.sh` release-asset model (fonttools is a
Python package, not a single release binary). We considered a vendored static `hb-subset`, but `hb-subset`
cannot emit woff2, so a binary-only path would also need `woff2_compress` — fonttools does subset + woff2
in one pinned tool and removes the static-compile and glibc-portability risk.

## Pinning

- **Iosevka:** a git tag consumed only by `build-font.sh` / the Containerfile (`git clone --branch`).
  **Not** in `versions.env`: `install-tools.sh --update` rewrites `versions.env` with only its four
  hardwired tools, which would silently delete an `IOSEVKA_VERSION` line. Bumping Iosevka is a manual edit
  + a `build-font.sh` run.
- **fonttools/brotli:** pinned in `tools/font/requirements.txt`, installed into a venv locally and in CI.

Pinned tag + committed `private-build-plans.toml` + committed masters give **functional** reproducibility.
Iosevka builds aren't byte-reproducible; we don't claim that.

## Leanness (governs the deferred decisions)

The gate no longer limits weight count — but **freed headroom is not a reason to add weights.** Every
weight and any italic must justify itself on typographic merit, defaulting to fewer. The frontend-design
review decides:

1. **Weight count** — 1 / 2 / 3. Collapse the imperceptible 500↔550 into one Medium regardless; decide
   whether the 330 light hero (`.intro h1`) is deliberate (keep) or incidental (drop to 400). Bias toward
   the fewest weights that carry the hierarchy.
2. **Italics** — currently synthesized. Choose **drop** (lean), **keep synthetic oblique**, or **ship a
   real italic** (the Etoile build produces an italic master for free; ~10 KB subset). Bias toward drop.
3. **Layout features** — which OpenType features (if any) the shipped subset retains, drawn from the
   master's curated menu. Default is **drop all** (prose font, smallest output); the review confirms
   whether any are wanted (e.g. fractions, localized forms). Selecting from the menu is a `build.sh`
   `--layout-features` flag — **no master rebuild**; only a feature outside the menu (cv##/ss##, coding
   ligatures) needs one.

These are CSS/asset/flag choices; they do not change the pipeline. Whatever the review picks, Stage 1
rebuilds the needed master weights and `main.scss` declares the matching `@font-face`(s).

## Verification

- **Glyph coverage:** assert the generated subset's `cmap` covers every codepoint used across
  `public/**/*.html` (the build-time scan makes this inherent, but verify, incl. the 5 non-ASCII glyphs).
- **Multi-weight render check:** a Playwright snapshot confirming the shipped weights render as distinct
  strokes (so a missing master or `font-display` synthesis can't fake the hierarchy).
- Existing gates stay green: `./scripts/build.sh` then `./scripts/check.sh` (htmltest, lychee,
  page-weight). Lighthouse 100 across the four mobile categories remains the manual bar.

## Risks / unknowns

- **Master coverage bound (T4).** Content using a glyph outside T4 (CJK, rare scripts, exotic symbols)
  falls back to the system font — much wider than today's latin asset, but still bounded. Widen the range
  + rebuild (container) if that ever bites.
- **Feature-dropping flags must be explicit.** The default shipped subset passes `--layout-features=''
  --no-layout-closure`; without them, Iosevka's substitution features drag ~60 extra glyphs into the
  subset (~2× size), so the flags are load-bearing, not cosmetic.
- **Python in the build path.** `build.sh` and CI depend on a pinned fonttools venv — the agreed tradeoff
  for one-tool real-woff2 output (vs a static `hb-subset` + `woff2_compress` binary pair).
- **Sole-shared-asset assumption.** The headroom math assumes CSS/JS stay inlined. If a future change
  externalizes CSS, the per-page budget shifts.

## Out of scope

- Caddy config, podman mount, observability wiring (separate IaC repo).
- Any change to the dark-mode JS or the SCSS pipeline beyond the `@font-face` block.
- Switching the spacing/serif variant family (Etoile stays).
- The resume PDF's font path (Typst reads the YAML/its own font; unaffected by the web subset).
