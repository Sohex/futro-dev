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
- **Exact-subset sizes (woff2):** a clean exact subset (no unused substitution features) is **~5 KB/weight
  with fonttools, ~10 KB/weight with `hb-subset`** (the production tool), vs ~30 KB for today's latin
  asset. The dominant levers are (a) exact glyph set and (b) **dropping unused *substitution* features**
  (`calt`/`frac`/`numr`/`dnom`/`locl`) — if kept, they drag ~60 extra fraction/superscript/alternate
  glyphs into the subset via glyph closure. Etoile has **no kerning** (`GPOS` empty; quasi-proportional
  spacing is in advance widths), so there's no kern data to preserve.
- **`hb-subset` (≥12) emits woff2 directly** (built with brotli) — no separate woff2-compress step — and
  subsets the full 8 MB master to the shipped woff2 in **~5 ms/weight**, so build-time subsetting adds
  negligible wall-clock.
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
| Subsetter | **`hb-subset`** — vendored static build for CI, `apt` (`libharfbuzz-bin`) locally; **not** managed by `install-tools.sh`/`versions.env` |
| Master artifact | Committed per-weight TTF master at **T4 coverage + a curated OT-feature menu** (~101 KB gz/weight): latin+European, Greek, Cyrillic, punctuation/currency/letterlike, arrows, math operators, box-drawing, geometric shapes, dingbats; plus useful typographic features (fractions, super/subscripts, ordinals, number styles, slashed zero, ligatures, case, localization, combining marks) — excluding cv##/ss## and coding ligatures. Produced by the container; source, not served |
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
2. Inside the image, `hb-subset` each weight's full TTF (~8 MB) down to the **T4 master** (ranges below),
   retaining a **curated OpenType-feature menu** (fractions, super/subscripts, ordinals, number styles,
   slashed zero, ligatures, case, localization, combining marks) but dropping cv##/ss## and coding
   ligatures — ~101 KB gz/weight (vs ~87 KB feature-stripped, vs ~392 KB everything). This lets `build.sh`
   enable any menu feature later without a master rebuild. Covers realistic prose, European names,
   Greek/Cyrillic, and the technical symbols code blocks render in Iosevka.
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
   © → ◐`). The floor means routine edits never need a font rebuild.
2. For each committed master, run **`hb-subset`** to that codepoint set with the **retained layout-feature
   set chosen by the FE review** (default: drop all — `--layout-features='' --no-layout-closure` — since
   Iosevka's substitution features otherwise drag in fraction/superscript/alternate glyphs, ~10 KB vs
   ~17 KB). `hb-subset` (≥12) writes **woff2 directly**; no separate compress step. Output to
   `public/fonts/` under a **stable filename** (~10 KB/weight, ~5 ms).

Because the subset is regenerated from a broad master against the *actual* content on every build, the
shipped font always matches the page — no stale-subset tofu for anything the master covers. (Glyphs
outside the master's bounded coverage fall back to the system font, exactly as today.)

### Site integration (the only authored files that change)

- `assets/scss/main.scss` `@font-face`: keep `font-family: "Iosevka Etoile"`, point `src` at the
  stable `/fonts/…` path, set `font-weight` to the shipped value(s) (e.g. `400`, or one `@font-face` per
  shipped weight). Keep `font-display: swap`. The font is referenced by absolute path, not Hugo's
  fingerprinted pipeline — consistent with today's `static/fonts/` → `public/fonts/` model.
- `layouts/_partials/head.html`: preload `href` → the stable filename (`type="font/woff2"`).

## Subsetter sourcing

`build.sh` requires `hb-subset` on `PATH`:

- **Locally:** `apt install libharfbuzz-bin`.
- **CI (`ubuntu-latest` runner, `.forgejo/workflows/build.yml`):** a **vendored static `hb-subset`** made
  available to the build job. It is produced once (the font container has the toolchain to build HarfBuzz
  static) and pinned; the workflow places it on `PATH` alongside the `install-tools.sh` binaries.

This is deliberately outside the `versions.env`/`install-tools.sh` release-asset model (HarfBuzz publishes
no Linux `hb-subset` release binary). The exact CI wiring (workflow step vs. baked image) is a plan
detail; the contract is "a pinned static `hb-subset` is on `PATH` in CI."

## Pinning

- **Iosevka:** a git tag consumed only by `build-font.sh` / the Containerfile (`git clone --branch`).
  **Not** in `versions.env`: `install-tools.sh --update` rewrites `versions.env` with only its four
  hardwired tools, which would silently delete an `IOSEVKA_VERSION` line. Bumping Iosevka is a manual edit
  + a `build-font.sh` run.
- **hb-subset:** pinned as the vendored static binary (CI) / whatever `apt` provides (local dev).

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
- **`hb-subset` vs fonttools parity.** The spike used fonttools; the pipeline uses `hb-subset`. Sizes are
  in the same ballpark, but the feature-dropping flags must be set explicitly (the spike showed unused
  substitution features otherwise inflate the subset ~2×).
- **Sole-shared-asset assumption.** The headroom math assumes CSS/JS stay inlined. If a future change
  externalizes CSS, the per-page budget shifts.

## Out of scope

- Caddy config, podman mount, observability wiring (separate IaC repo).
- Any change to the dark-mode JS or the SCSS pipeline beyond the `@font-face` block.
- Switching the spacing/serif variant family (Etoile stays).
- The resume PDF's font path (Typst reads the YAML/its own font; unaffected by the web subset).
