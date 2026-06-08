# Self-built Iosevka Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the out-of-band Iosevka Etoile webfont with a reproducible, self-built one: a pinned containerized Iosevka build producing a committed per-weight master, exact-subset against rendered content at site-build time via `hb-subset`.

**Architecture:** Two cadences. (1) **Occasional** — a throwaway container clones pinned Iosevka, builds the Etoile master TTF from a committed `private-build-plans.toml`, and also compiles a self-contained `hb-subset`; both are committed. npm/Node never leave the container. (2) **Every build** — `build.sh` runs `hb-subset` against the just-rendered `public/**/*.html` to emit a tiny content-matched woff2 into `public/fonts/`.

**Tech Stack:** Hugo, Typst, Forgejo Actions, podman; Iosevka (Node/npm, containerized) v34.6.1; HarfBuzz `hb-subset` 12.3.2; fonttools (dev verification only).

**Spec:** `docs/superpowers/specs/2026-06-08-iosevka-custom-build-design.md`

---

## Scope

This plan ships the **pipeline** plus a single self-built **Regular (400)** weight — visually identical to today's site (the weight hierarchy is currently flat at 400 anyway), but reproducible and ~10 KB instead of ~30 KB. The deferred frontend-design decisions (weight count, italics, retained layout features) are **out of scope** here; the pipeline supports them by adding weights to the toml / `@font-face` and rebuilding the master. See "Follow-up (post-FE-review)".

## Prerequisites (one-time, local dev machine)

The site `build.sh` will call `hb-subset`; install it and the dev verification tool:

```bash
sudo apt-get install -y libharfbuzz-bin   # provides hb-subset (>=12 emits woff2)
hb-subset --version                        # expect: hb-subset (HarfBuzz) 12.x
python3 -m venv ~/.cache/futro-font-venv && ~/.cache/futro-font-venv/bin/pip -q install fonttools brotli
```

`podman` (already present, v5.7) is needed for the container build in Task 3.

## File structure

| Path | Responsibility | Created/Modified |
| --- | --- | --- |
| `tools/font/private-build-plans.toml` | Iosevka build config: Etoile variants + owner's tweaks + Regular weight | Create |
| `tools/font/Containerfile` | Pinned Iosevka master build + self-contained `hb-subset` compile; exports both | Create |
| `scripts/build-font.sh` | Drives the container, extracts master TTF + `hb-subset` binary into the repo | Create |
| `tools/font/masters/iosevka-etoile-regular.ttf` | Committed Regular master: T4 coverage + curated OT-feature menu (source, not served) | Generated+committed |
| `tools/font/bin/hb-subset` | Committed self-contained `hb-subset` for CI | Generated+committed |
| `scripts/build.sh` | Add build-time exact-subset step after Hugo | Modify |
| `assets/scss/main.scss` | `@font-face` → new filename | Modify (lines 3-9) |
| `layouts/_partials/head.html` | preload → new filename | Modify (line 7) |
| `static/fonts/iosevka-etoile-latin.woff2` | Old out-of-band asset | Delete |
| `.forgejo/workflows/build.yml` | Put vendored `hb-subset` on CI `PATH` | Modify |

---

## Task 1: Iosevka build config

**Files:**
- Create: `tools/font/private-build-plans.toml`

This is the official `IosevkaEtoile` plan, renamed to `IosevkaFutro` to avoid colliding with Iosevka's own `build-plans.toml`, restricted to the Regular weight. **The owner has an existing variant config — merge their `variants.*` selections over the stock blocks below before building.** The `family` string is the font's internal name; the site's CSS `font-family` ("Iosevka Etoile") is independent of it.

- [ ] **Step 1: Write the config**

```toml
# tools/font/private-build-plans.toml
# Iosevka Etoile (quasi-proportional slab-serif), Regular only.
# Base = official build-plans.toml IosevkaEtoile; merge owner's variant tweaks here.
[buildPlans.IosevkaFutro]
family  = "Iosevka Etoile"
desc = "Slab-serif"
spacing = "quasi-proportional"
buildCharMap = true
serifs = 'slab'
exportGlyphNames = true

[buildPlans.IosevkaFutro.variants.design]
capital-m = "flat-bottom-serifed"
capital-w = "straight-almost-flat-top-serifed"
f = "flat-hook-serifed"
i = "serifed"
j = "flat-hook-serifed"
l = "serifed"
t = "flat-hook"
w = "straight-almost-flat-top-serifed"
long-s = "flat-hook-bottom-serifed"
eszet = "longs-s-lig-bottom-serifed"
lower-iota = "serifed-flat-tailed"
lower-lambda = "straight-turn"
lower-tau = "short-tailed"
cyrl-ef = "serifed"
four = "closed-serifed"
six = "closed-contour"
nine = "closed-contour"
brace = "straight"
guillemet = "straight"
at = "fourfold"
percent = "rings-continuous-slash"

[buildPlans.IosevkaFutro.variants.italic]
f = "flat-hook-tailed"
i = "serifed-flat-tailed"
l = "serifed-flat-tailed"
w = "straight-almost-flat-top-motion-serifed"
long-s = "flat-hook-tailed"
eszet = "longs-s-lig-tailed-serifless"
cyrl-ef = "split-cursive"

[buildPlans.IosevkaFutro.widths.Normal]
shape = 600
menu  = 5
css   = "normal"

[buildPlans.IosevkaFutro.weights.Regular]
shape = 400
menu  = 400
css   = 400
```

- [ ] **Step 2: Verify it parses as TOML**

Run: `python3 -c "import tomllib; tomllib.load(open('tools/font/private-build-plans.toml','rb')); print('ok')"`
Expected: `ok`

- [ ] **Step 3: Commit**

```bash
git add tools/font/private-build-plans.toml
git commit -m "feat(font): Iosevka Etoile build plan (Regular)"
```

---

## Task 2: Containerfile (Iosevka master + self-contained hb-subset)

**Files:**
- Create: `tools/font/Containerfile`

One Debian-based image: compiles a self-contained `hb-subset` (static libharfbuzz, glibc-dynamic — runs on Debian/Ubuntu CI), builds the Iosevka Regular TTF, subsets it to the **T4** master (curated OT-feature menu, ~101 KB gz), and exports `bin/hb-subset` + `masters/`. The brotli smoke-test fails the build if the compiled `hb-subset` can't emit woff2 (which `build.sh` needs).

- [ ] **Step 1: Write the Containerfile**

```dockerfile
# tools/font/Containerfile
# Builds (occasionally): a self-contained hb-subset + the Iosevka Etoile master.
# Build context is tools/font/ (contains private-build-plans.toml).
ARG IOSEVKA_VERSION=v34.6.1
ARG HARFBUZZ_VERSION=12.3.2

FROM node:22-bookworm AS build
ARG IOSEVKA_VERSION
ARG HARFBUZZ_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
      meson ninja-build pkg-config gcc g++ \
      libbrotli-dev git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# --- self-contained hb-subset (libharfbuzz linked static; needs brotli for woff2) ---
RUN git clone --depth 1 --branch "$HARFBUZZ_VERSION" https://github.com/harfbuzz/harfbuzz /src/hb \
 && meson setup /src/hb/build /src/hb \
      -Ddefault_library=static -Dutilities=enabled -Dtests=disabled -Ddocs=disabled \
      --buildtype=release \
 && ninja -C /src/hb/build \
 && install -Dm755 /src/hb/build/util/hb-subset /out/bin/hb-subset \
 && /out/bin/hb-subset --version

# --- Iosevka Etoile Regular TTF ---
RUN git clone --depth 1 --branch "$IOSEVKA_VERSION" https://github.com/be5invis/Iosevka /src/iosevka
WORKDIR /src/iosevka
COPY private-build-plans.toml .
RUN npm install
# Unhinted: webfonts don't need TTF hinting (browsers rasterize), and it keeps the master smaller.
RUN npm run build -- ttf-unhinted::IosevkaFutro

# --- T4 master + curated OpenType-feature menu + brotli/woff2 smoke test ---
# Keep useful typographic features so build.sh can enable any of them later WITHOUT a
# master rebuild. Exclude cv##/ss## (variants already baked) and calt/dlig (coding
# ligatures, unwanted in prose) — those are the ~300 KB blowup. Curated menu ~+14 KB.
RUN mkdir -p /out/masters \
 && /out/bin/hb-subset dist/IosevkaFutro/TTF-Unhinted/IosevkaFutro-Regular.ttf \
      --unicodes="U+0000-024F,U+0370-03FF,U+0400-04FF,U+1E00-1EFF,U+2000-206F,U+20A0-20BF,U+2100-214F,U+2190-21FF,U+2200-22FF,U+2500-257F,U+25A0-25FF,U+2700-27BF,U+2C60-2C7F" \
      --layout-features="case,locl,frac,numr,dnom,sups,subs,sinf,ordn,zero,tnum,pnum,onum,lnum,liga,ccmp,mark,mkmk" \
      --output-file=/out/masters/iosevka-etoile-regular.ttf \
 && /out/bin/hb-subset /out/masters/iosevka-etoile-regular.ttf \
      --unicodes=U+0041 --output-file=/tmp/smoke.woff2 \
 && head -c4 /tmp/smoke.woff2 | grep -q 'wOF2' && echo "woff2-ok"

FROM scratch
COPY --from=build /out/ /
```

- [ ] **Step 2: Commit**

```bash
git add tools/font/Containerfile
git commit -m "feat(font): containerized Iosevka master + hb-subset build"
```

---

## Task 3: build-font.sh — run the container, vendor the artifacts

**Files:**
- Create: `scripts/build-font.sh`
- Generated+committed: `tools/font/masters/iosevka-etoile-regular.ttf`, `tools/font/bin/hb-subset`

- [ ] **Step 1: Write the driver script**

```bash
#!/usr/bin/env bash
# Occasional: rebuild the committed Iosevka master + vendored hb-subset.
# Run when private-build-plans.toml or the pinned versions change. Requires podman.
set -euo pipefail
cd "$(dirname "$0")/.."

IOSEVKA_VERSION="${IOSEVKA_VERSION:-v34.6.1}"
HARFBUZZ_VERSION="${HARFBUZZ_VERSION:-12.3.2}"

rm -rf tools/font/_export
podman build -f tools/font/Containerfile \
  --build-arg IOSEVKA_VERSION="$IOSEVKA_VERSION" \
  --build-arg HARFBUZZ_VERSION="$HARFBUZZ_VERSION" \
  -o "type=local,dest=tools/font/_export" \
  tools/font

mkdir -p tools/font/bin tools/font/masters
install -m 0755 tools/font/_export/bin/hb-subset tools/font/bin/hb-subset
cp tools/font/_export/masters/*.ttf tools/font/masters/
rm -rf tools/font/_export

echo "vendored:"
ls -l tools/font/bin/hb-subset tools/font/masters/*.ttf
```

- [ ] **Step 2: Make executable and run it** (slow — npm install + Iosevka build + harfbuzz compile)

Run: `chmod +x scripts/build-font.sh && ./scripts/build-font.sh`
Expected: ends with `vendored:` listing `tools/font/bin/hb-subset` and `tools/font/masters/iosevka-etoile-regular.ttf`.

- [ ] **Step 3: Verify the vendored hb-subset runs and the master is sane**

Run:
```bash
tools/font/bin/hb-subset --version
ls -l tools/font/masters/iosevka-etoile-regular.ttf   # expect ~215 KB raw
~/.cache/futro-font-venv/bin/python -c "from fontTools.ttLib import TTFont; f=TTFont('tools/font/masters/iosevka-etoile-regular.ttf'); print('glyphs', f['maxp'].numGlyphs); cps=set().union(*[t.cmap.keys() for t in f['cmap'].tables]); print('has A,euro,box,toggle:', all(c in cps for c in (0x41,0x20AC,0x2500,0x25D0))); print('has frac feature:', 'GSUB' in f and any(fr.FeatureTag=='frac' for fr in f['GSUB'].table.FeatureList.FeatureRecord))"
```
Expected: a `hb-subset (HarfBuzz) 12.x` line; `glyphs` ~2425; `has A,euro,box,toggle: True`; `has frac feature: True`.

- [ ] **Step 4: Commit the scripts and the vendored artifacts**

```bash
git add scripts/build-font.sh tools/font/bin/hb-subset tools/font/masters/iosevka-etoile-regular.ttf
git commit -m "feat(font): vendor Iosevka master + hb-subset binary"
```

---

## Task 4: build-time exact-subset step in build.sh

**Files:**
- Modify: `scripts/build.sh`

Insert the subset step after Hugo (so `public/**/*.html` exists) and before Typst. The shipped woff2 is built from the actual rendered content plus a safety floor (printable ASCII via `--unicodes`, plus the non-ASCII symbols the design may use).

- [ ] **Step 1: Replace build.sh with the version below**

```bash
#!/usr/bin/env bash
# Full site build: Hugo, then the web font subset, then the resume PDF into public/.
# Order matters — lychee/htmltest must run AFTER this so /resume.pdf and the font are checked.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf public
hugo --minify --panicOnWarning

# --- web font: exact-subset the committed master against the rendered content ---
HB_SUBSET="${HB_SUBSET:-hb-subset}"
charset="$(mktemp)"
trap 'rm -f "$charset"' EXIT
find public -name '*.html' -exec cat {} + > "$charset"
# safety floor (non-ASCII the design may use); printable ASCII added via --unicodes below
printf '%s' $'·–—‘’“”…©®™→←↑↓◐•§†‡€£' >> "$charset"
mkdir -p public/fonts
# Default ships NO OpenType features (smallest). The master carries a curated menu
# (case,locl,frac,numr,dnom,sups,subs,sinf,ordn,zero,tnum,pnum,onum,lnum,liga,ccmp,mark,mkmk);
# to enable some, set e.g. --layout-features=frac,sups and DROP --no-layout-closure
# (so the feature's glyphs ship too). No master rebuild needed.
"$HB_SUBSET" tools/font/masters/iosevka-etoile-regular.ttf \
  --unicodes=U+0020-007E \
  --text-file="$charset" \
  --layout-features='' --no-layout-closure \
  --output-file=public/fonts/iosevka-etoile.woff2

typst compile --root . typst/resume.typ public/resume.pdf
```

- [ ] **Step 2: Build and verify the woff2 is produced and small**

Run: `./scripts/build.sh && ls -l public/fonts/iosevka-etoile.woff2`
Expected: file exists, ~8-15 KB.

- [ ] **Step 3: Verify it covers every rendered codepoint** (dev check)

Run:
```bash
~/.cache/futro-font-venv/bin/python - <<'PY'
import glob, re, html
from fontTools.ttLib import TTFont
used=set()
for f in glob.glob("public/**/*.html", recursive=True):
    t=open(f,encoding="utf-8").read()
    t=re.sub(r"<(script|style)\b.*?</\1>"," ",t,flags=re.S|re.I); t=re.sub(r"<[^>]+>"," ",t)
    used.update(html.unescape(t))
used={ord(c) for c in used if c not in "\t\n\r"}
font=TTFont("public/fonts/iosevka-etoile.woff2")
cov=set().union(*[t.cmap.keys() for t in font['cmap'].tables])
missing=sorted(used-cov)
print("missing codepoints:", ["U+%04X"%c for c in missing] or "none")
assert not missing, "subset missing glyphs the site renders"
print("coverage OK")
PY
```
Expected: `missing codepoints: none` then `coverage OK`.

- [ ] **Step 4: Commit**

```bash
git add scripts/build.sh
git commit -m "feat(font): build-time exact subset into public/fonts"
```

---

## Task 5: Point the site at the new asset; remove the old one

**Files:**
- Modify: `assets/scss/main.scss` (lines 3-9)
- Modify: `layouts/_partials/head.html` (line 7)
- Delete: `static/fonts/iosevka-etoile-latin.woff2`

- [ ] **Step 1: Update the `@font-face` src in `assets/scss/main.scss`**

Replace:
```scss
  src: url("/fonts/iosevka-etoile-latin.woff2") format("woff2");
```
with:
```scss
  src: url("/fonts/iosevka-etoile.woff2") format("woff2");
```

- [ ] **Step 2: Update the preload in `layouts/_partials/head.html` (line 7)**

Replace:
```html
  <link rel="preload" href="/fonts/iosevka-etoile-latin.woff2" as="font" type="font/woff2" crossorigin>
```
with:
```html
  <link rel="preload" href="/fonts/iosevka-etoile.woff2" as="font" type="font/woff2" crossorigin>
```

- [ ] **Step 3: Delete the old out-of-band asset**

Run: `git rm static/fonts/iosevka-etoile-latin.woff2`

- [ ] **Step 4: Rebuild and verify the new URL is wired and the old one is gone**

Run:
```bash
./scripts/build.sh
grep -rq "/fonts/iosevka-etoile\.woff2" public/index.html && echo "preload OK"
grep -rq "iosevka-etoile-latin" public && echo "STALE REF FOUND" || echo "no stale refs"
test -f public/fonts/iosevka-etoile.woff2 && echo "asset present"
```
Expected: `preload OK`, `no stale refs`, `asset present`.

- [ ] **Step 5: Commit**

```bash
git add assets/scss/main.scss layouts/_partials/head.html
git commit -m "feat(font): serve self-built Iosevka subset, drop old asset"
```

---

## Task 6: Full verification (gates + render)

**Files:** none (verification only)

- [ ] **Step 1: Run the full build + checks**

Run: `./scripts/build.sh && ./scripts/check.sh`
Expected: ends with `page-weight OK ...`; htmltest and lychee report no errors (the `/fonts/iosevka-etoile.woff2` preload resolves).

- [ ] **Step 2: Confirm the page-weight headroom**

Run: `ls -l public/fonts/iosevka-etoile.woff2`
Expected: ~8-15 KB (well under the prior ~30 KB; gate has wide margin).

- [ ] **Step 3: Visual render check (no tofu)**

Run a local server and screenshot with Playwright's bundled browser (no snap; per project constraints):
```bash
hugo server &   # serves the build; note /resume.pdf is absent in dev (expected)
# In Playwright: load http://localhost:1313/ and a post page, screenshot, confirm body/headings
# render in Iosevka Etoile (slab serifs visible) with NO .notdef boxes for ·–—' and the ◐ toggle.
```
Expected: text renders in the self-built Iosevka; toggle glyph `◐` shows; no tofu. Kill the server when done.

---

## Task 7: CI — vendored hb-subset on PATH

**Files:**
- Modify: `.forgejo/workflows/build.yml`

CI is `ubuntu-latest` running `install-tools.sh` → `build.sh` → `check.sh`. `build.sh` needs `hb-subset`; provide the committed vendored binary by prepending its dir to `PATH`.

- [ ] **Step 1: Add a PATH step after "Install pinned toolchain" in the `build` job**

Insert after the existing `Install pinned toolchain` step (current lines 14-17):
```yaml
      - name: Vendored hb-subset on PATH
        run: echo "$PWD/tools/font/bin" >> "$GITHUB_PATH"
```

- [ ] **Step 2: Verify the vendored binary works standalone** (simulate CI's isolation)

Run (uses ONLY the committed binary, not the apt one):
```bash
rm -rf public && hugo --minify --panicOnWarning
HB_SUBSET="$PWD/tools/font/bin/hb-subset" bash -c '
  charset=$(mktemp); find public -name "*.html" -exec cat {} + > "$charset"
  mkdir -p public/fonts
  "$HB_SUBSET" tools/font/masters/iosevka-etoile-regular.ttf --unicodes=U+0020-007E --text-file="$charset" --layout-features="" --no-layout-closure --output-file=public/fonts/iosevka-etoile.woff2
  head -c4 public/fonts/iosevka-etoile.woff2 | grep -q wOF2 && echo "vendored hb-subset OK"'
```
Expected: `vendored hb-subset OK`.

- [ ] **Step 3: Commit**

```bash
git add .forgejo/workflows/build.yml
git commit -m "ci(font): put vendored hb-subset on PATH"
```

---

## Follow-up (post-FE-review, out of scope here)

The frontend-design review decides three things; each is a small change on this pipeline, not a redesign:

1. **Weight count** — add `[buildPlans.IosevkaFutro.weights.<Name>]` entries (e.g. Medium 500), rerun `build-font.sh` (new master per weight), add an `@font-face` per weight in `main.scss`, and a subset step per master in `build.sh`.
2. **Italics** — if a real italic is chosen, the Etoile build already produces an italic face; build/commit its master and add an italic `@font-face`. Default (drop) needs nothing.
3. **Layout features** — the master already carries a curated menu (fractions, super/subscripts, ordinals, number styles, slashed zero, standard ligatures, case, localization, combining marks). Enabling any of them is a `build.sh` flag change (`--layout-features=<set>`, and drop `--no-layout-closure` so the glyphs ship) — **no master rebuild**. Only a feature *outside* the menu (cv##/ss## alternates, coding ligatures) needs a master rebuild.

## Notes / risks

- **Static hb-subset is the riskiest step.** Task 2's brotli/woff2 smoke test (`woff2-ok`) and Task 7 Step 2 are the gates. If meson can't find brotli, woff2 output fails — `libbrotli-dev` is installed in the Containerfile for exactly this.
- **Non-fingerprinted font URL.** `/fonts/iosevka-etoile.woff2` has a stable name (matching today's model), so a content change with an unchanged URL relies on normal cache expiry. Acceptable for a rarely-changing font; out of scope to add hashing.
- **Master coverage bound (T4).** A glyph outside T4 (CJK, rare scripts) falls back to the system font and Task 4 Step 3 will flag it as `missing` — widen the `--unicodes` range in the Containerfile and rerun `build-font.sh`.
- **Owner's variant config** must be merged into `private-build-plans.toml` (Task 1) before `build-font.sh`; the stock Etoile variants are the base.
