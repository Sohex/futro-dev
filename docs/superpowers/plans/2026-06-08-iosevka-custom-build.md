# Self-built Iosevka Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the out-of-band Iosevka webfont with a reproducible, self-built one: a pinned containerized Iosevka build producing a committed per-weight master TTF, exact-subset against rendered content at site-build time with `fonttools` (`pyftsubset --flavor=woff2`).

**Architecture:** Two cadences. (1) **Occasional** — a throwaway container clones pinned Iosevka, `npm`-builds the unhinted TTF from a committed `private-build-plans.toml`, then `pyftsubset`s it to the committed master (T4 coverage + a curated OpenType-feature menu). npm/Node never leave the container. (2) **Every build** — `build.sh` runs `pyftsubset` against the just-rendered `public/**/*.html` (+ a safety floor) to emit a tiny content-matched woff2 into `public/fonts/`.

**Tech Stack:** Hugo, Typst, Forgejo Actions, podman; Iosevka (Node/npm, containerized) v34.6.1; fonttools 4.63.0 + brotli 1.2.0 (`pyftsubset`, real woff2 output).

**Spec:** `docs/superpowers/specs/2026-06-08-iosevka-custom-build-design.md`

> **Note (why fonttools, not hb-subset):** `hb-subset` writes SFNT only — it does **not** emit woff2 regardless of file extension (verified: its `.woff2` output has TTF magic `0001 0000`). `pyftsubset --flavor=woff2` produces real brotli woff2 (magic `wOF2`, ~5.7 KB) in one step, so the pipeline uses fonttools and needs no static `hb-subset`/`woff2_compress` binary and no CI binary vendoring.

---

## Scope

This plan ships the **pipeline** plus a single self-built **Regular (400)** weight — visually identical to today's site (the weight hierarchy is currently flat at 400 anyway), but reproducible and ~6 KB instead of ~30 KB. The deferred frontend-design decisions (weight count, italics, which curated layout features to actually ship) are **out of scope** here; the pipeline supports them by adding weights to the toml / `@font-face` and flipping `pyftsubset` flags. See "Follow-up (post-FE-review)".

## Prerequisites (one-time, local dev machine)

`build.sh` will subset with fonttools. Create a pinned venv and point `FONT_PYTHON` at it (the scripts default `FONT_PYTHON` to `python3`, so set it in your shell or `direnv`):

```bash
python3 -m venv ~/.cache/futro-font-venv
~/.cache/futro-font-venv/bin/pip install fonttools==4.63.0 brotli==1.2.0   # matches tools/font/requirements.txt
export FONT_PYTHON="$HOME/.cache/futro-font-venv/bin/python"               # used by build.sh + verification
"$FONT_PYTHON" -m fontTools.subset --help >/dev/null && echo "pyftsubset OK"
```

`podman` (already present, v5.7) is needed for the container build in Task 3.

## File structure

| Path | Responsibility | Created/Modified |
| --- | --- | --- |
| `tools/font/private-build-plans.toml` | Iosevka build config: owner's `IosevkaCustom` variants + Regular weight | Create (from owner's `private_build_plan.toml`) |
| `tools/font/requirements.txt` | Pinned fonttools+brotli, used by the container and CI | Create |
| `tools/font/Containerfile` | Pinned Iosevka build → `pyftsubset` master; exports the master TTF | Create |
| `scripts/build-font.sh` | Drives the container, extracts the master TTF into the repo | Create |
| `scripts/font-codepoints.py` | Shared: emit codepoints used in built HTML + safety floor (stdlib only) | Create |
| `tools/font/masters/iosevka-custom-regular.ttf` | Committed Regular master: T4 + curated OT-feature menu (source, not served) | Generated+committed |
| `scripts/build.sh` | Add build-time `pyftsubset` step after Hugo | Modify |
| `assets/scss/main.scss` | `@font-face` + font stacks → "Iosevka Custom" / new filename | Modify (lines 4, 8, 42, 117) |
| `layouts/_partials/head.html` | preload → new filename | Modify (line 7) |
| `static/fonts/iosevka-etoile-latin.woff2` | Old out-of-band asset | Delete |
| `private_build_plan.toml` (repo root) | Owner's source config, moved into `tools/font/` | Delete after copy |
| `.forgejo/workflows/build.yml` | Provision the fonttools venv + `FONT_PYTHON` in the build job | Modify |

---

## Task 1: Iosevka build config

**Files:**
- Create: `tools/font/private-build-plans.toml`

This is the owner's `private_build_plan.toml` (at the repo root), moved to `tools/font/private-build-plans.toml` (the filename Iosevka's build expects) and **restricted to the Regular weight** for the initial ship. The owner's `variants.*` selections, `noCvSs = true` (cv##/ss## features not built — variants baked as defaults, no cv/ss bloat), and `slopes.Upright` (upright only, no italic) carry over **verbatim**. Bold is dropped here — adding weights is the FE-review follow-up.

- [ ] **Step 1: Write the config** (owner's content, weights restricted to Regular)

```toml
# tools/font/private-build-plans.toml
# Owner's custom Iosevka (quasi-proportional slab-serif). Regular only for the
# initial ship; FE review adds weights. noCvSs => variants baked, no cv/ss features.
[buildPlans.IosevkaCustom]
family = "Iosevka Custom"
spacing = "quasi-proportional"
serifs = "slab"
noCvSs = true
exportGlyphNames = false

[buildPlans.IosevkaCustom.variants.design]
one = "base"
three = "flat-top-serifed"
four = "semi-open-serifed"
five = "upright-arched-serifless"
six = "closed-contour"
seven = "curly-serifed"
eight = "two-circles"
nine = "closed-contour"
zero = "dotted"
capital-a = "straight-base-serifed"
capital-c = "bilateral-inward-serifed"
capital-e = "serifed"
capital-g = "toothed-inward-serifed-hooked"
capital-j = "serifed"
capital-q = "closed-swash"
capital-s = "bilateral-inward-serifed"
c = "bilateral-inward-serifed"
g = "double-storey"
q = "diagonal-tailed-motion-serifed"
s = "bilateral-inward-serifed"
z = "straight-serifed"
asterisk = "turn-hex-mid"
paren = "flat-arc"
brace = "curly-flat-boundary"
number-sign = "upright"
ampersand = "closed"
dollar = "open"
cent = "open"
percent = "rings-continuous-slash-also-connected"
lig-equal-chain = "with-notch"

[buildPlans.IosevkaCustom.weights.Regular]
shape = 400
menu = 400
css = 400

[buildPlans.IosevkaCustom.slopes.Upright]
angle = 0
shape = "upright"
menu = "upright"
css = "normal"
```

- [ ] **Step 2: Verify it parses as TOML**

Run: `python3 -c "import tomllib; tomllib.load(open('tools/font/private-build-plans.toml','rb')); print('ok')"`
Expected: `ok`

- [ ] **Step 3: Remove the root copy and commit**

```bash
rm -f private_build_plan.toml
git add tools/font/private-build-plans.toml
git commit -m "feat(font): Iosevka Custom build plan (Regular)"
```

---

## Task 2: requirements.txt + Containerfile (Iosevka master via pyftsubset)

**Files:**
- Create: `tools/font/requirements.txt`
- Create: `tools/font/Containerfile`

The container builds the unhinted Iosevka TTF and `pyftsubset`s it to the **T4 master** with a curated OpenType-feature menu (incl. coding ligatures for code blocks), ~112 KB gz. The dist path is **globbed**, not hardcoded, because Iosevka's output filename casing can vary.

- [ ] **Step 1: Write `tools/font/requirements.txt`**

```
fonttools==4.63.0
brotli==1.2.0
```

- [ ] **Step 2: Write `tools/font/Containerfile`**

```dockerfile
# tools/font/Containerfile
# Builds (occasionally): the Iosevka Custom master TTF. Build context is tools/font/
# (contains private-build-plans.toml + requirements.txt). npm/Node stay in this image.
ARG IOSEVKA_VERSION=v34.6.1

FROM node:22-bookworm AS build
ARG IOSEVKA_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /tmp/requirements.txt
RUN pip install --break-system-packages -r /tmp/requirements.txt

RUN git clone --depth 1 --branch "$IOSEVKA_VERSION" https://github.com/be5invis/Iosevka /src/iosevka
WORKDIR /src/iosevka
COPY private-build-plans.toml .
RUN npm install
# Unhinted: webfonts don't need TTF hinting (browsers rasterize) and it keeps the master smaller.
RUN npm run build -- ttf-unhinted::IosevkaCustom

# T4 master + curated feature menu INCLUDING coding ligatures (calt/clig/dlig/rlig) so
# build.sh can ship any of them later without a master rebuild. noCvSs already prevents the
# cv##/ss## blowup. Glob the unhinted Regular TTF (filename casing varies across versions).
RUN set -eux; \
    src="$(find dist -path '*TTF-Unhinted*' -name '*-Regular.ttf' | head -1)"; \
    test -n "$src" || { echo "no unhinted Regular TTF found:"; find dist -name '*.ttf'; exit 1; }; \
    mkdir -p /out/masters; \
    python3 -m fontTools.subset "$src" \
      --unicodes="U+0000-024F,U+0370-03FF,U+0400-04FF,U+1E00-1EFF,U+2000-206F,U+20A0-20BF,U+2100-214F,U+2190-21FF,U+2200-22FF,U+2500-257F,U+25A0-25FF,U+2700-27BF,U+2C60-2C7F" \
      --layout-features="case,locl,frac,numr,dnom,sups,subs,sinf,ordn,zero,tnum,pnum,onum,lnum,liga,calt,clig,dlig,rlig,ccmp,mark,mkmk" \
      --output-file=/out/masters/iosevka-custom-regular.ttf

FROM scratch
COPY --from=build /out/ /
```

- [ ] **Step 3: Commit**

```bash
git add tools/font/requirements.txt tools/font/Containerfile
git commit -m "feat(font): containerized Iosevka master build (pyftsubset)"
```

---

## Task 3: build-font.sh — run the container, vendor the master

**Files:**
- Create: `scripts/build-font.sh`
- Generated+committed: `tools/font/masters/iosevka-custom-regular.ttf`

- [ ] **Step 1: Write the driver script**

```bash
#!/usr/bin/env bash
# Occasional: rebuild the committed Iosevka master. Run when private-build-plans.toml
# or the pinned Iosevka version changes. Requires podman.
set -euo pipefail
cd "$(dirname "$0")/.."

IOSEVKA_VERSION="${IOSEVKA_VERSION:-v34.6.1}"

rm -rf tools/font/_export
podman build -f tools/font/Containerfile \
  --build-arg IOSEVKA_VERSION="$IOSEVKA_VERSION" \
  -o "type=local,dest=tools/font/_export" \
  tools/font

mkdir -p tools/font/masters
cp tools/font/_export/masters/*.ttf tools/font/masters/
rm -rf tools/font/_export

echo "vendored master:"
ls -l tools/font/masters/*.ttf
```

- [ ] **Step 2: Make executable and run it** (slow — `npm install` + Iosevka build, several minutes)

Run: `chmod +x scripts/build-font.sh && ./scripts/build-font.sh`
Expected: ends with `vendored master:` listing `tools/font/masters/iosevka-custom-regular.ttf`.

- [ ] **Step 3: Verify the master is sane** (coverage + features + no cv/ss)

Run:
```bash
ls -l tools/font/masters/iosevka-custom-regular.ttf   # expect ~247 KB raw
"$FONT_PYTHON" -c "from fontTools.ttLib import TTFont; f=TTFont('tools/font/masters/iosevka-custom-regular.ttf'); print('glyphs', f['maxp'].numGlyphs); cps=set().union(*[t.cmap.keys() for t in f['cmap'].tables]); print('has A,euro,box,toggle:', all(c in cps for c in (0x41,0x20AC,0x2500,0x25D0))); feats={fr.FeatureTag for fr in f['GSUB'].table.FeatureList.FeatureRecord} if 'GSUB' in f else set(); print('has frac+calt:', {'frac','calt'} <= feats); print('no cv/ss:', not any(t.startswith(('cv','ss')) for t in feats))"
```
Expected: `glyphs` ~2700; `has A,euro,box,toggle: True`; `has frac+calt: True`; `no cv/ss: True`.

- [ ] **Step 4: Commit the script and the master**

```bash
git add scripts/build-font.sh tools/font/masters/iosevka-custom-regular.ttf
git commit -m "feat(font): vendor Iosevka Custom master TTF"
```

---

## Task 4: shared codepoint script + build-time subset step

**Files:**
- Create: `scripts/font-codepoints.py`
- Modify: `scripts/build.sh`

`font-codepoints.py` is the single source of truth for "what the webfont must cover" — used by both the shipper (`build.sh`) and the verifier (Task 6), so they can't drift. It strips tags/script/style (so inlined CSS/JS content isn't dragged in) and adds a fixed safety floor.

- [ ] **Step 1: Write `scripts/font-codepoints.py`**

```python
#!/usr/bin/env python3
# Emit (to stdout) the characters the webfont must cover: every char rendered across
# the built HTML (tags/script/style stripped) + a fixed safety floor. Stdlib only,
# so it runs under any python3. Used by build.sh (shipper) and the Task 6 verifier.
import sys, glob, re, html

root = sys.argv[1] if len(sys.argv) > 1 else "public"
chars = set()
for path in glob.glob(f"{root}/**/*.html", recursive=True):
    t = open(path, encoding="utf-8").read()
    t = re.sub(r"<(script|style)\b.*?</\1>", " ", t, flags=re.S | re.I)  # drop inlined JS/CSS bodies
    t = re.sub(r"<[^>]+>", " ", t)                                        # drop tags
    chars.update(html.unescape(t))

chars.update(chr(c) for c in range(0x20, 0x7F))          # printable ASCII floor
chars.update("·–—‘’“”…©®™→←↑↓◐•§†‡€£")                    # non-ASCII the design may use
for ws in "\t\n\r":
    chars.discard(ws)
sys.stdout.write("".join(sorted(chars)))
```

- [ ] **Step 2: Replace `scripts/build.sh` with the version below**

```bash
#!/usr/bin/env bash
# Full site build: Hugo, then the web font subset, then the resume PDF into public/.
# Order matters — lychee/htmltest must run AFTER this so /resume.pdf and the font are checked.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf public
hugo --minify --panicOnWarning

# --- web font: exact-subset the committed master against the rendered content ---
# FONT_PYTHON points at a venv with fonttools+brotli (see Prerequisites / CI). Default ships
# NO OpenType features (smallest). The master carries a curated menu
# (case,locl,frac,numr,dnom,sups,subs,sinf,ordn,zero,tnum,pnum,onum,lnum,liga,calt,clig,dlig,rlig,ccmp,mark,mkmk);
# to enable some, set e.g. --layout-features=calt,clig and DROP --no-layout-closure (so the
# feature's glyphs ship). Coding ligatures should also be scoped to code/pre via CSS so prose isn't ligated.
FONT_PYTHON="${FONT_PYTHON:-python3}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
"$FONT_PYTHON" scripts/font-codepoints.py public > "$work/charset"
grep -q '◐' "$work/charset" || { echo "ERROR: codepoint floor lost the ◐ toggle glyph" >&2; exit 1; }
mkdir -p public/fonts
"$FONT_PYTHON" -m fontTools.subset tools/font/masters/iosevka-custom-regular.ttf \
  --text-file="$work/charset" \
  --layout-features='' --no-layout-closure \
  --flavor=woff2 \
  --output-file="$work/font.woff2"

# Content-hash the filename. Caddy serves /fonts/* with `immutable`, and this file is NOT
# Hugo-fingerprinted, so its name MUST change iff the bytes change — otherwise clients keep a
# stale cached font forever. main.scss's @font-face src and the head.html preload carry the
# stable token `/fonts/iosevka-custom.woff2`, rewritten here to the hashed name across the
# inlined HTML (CSS/JS are inlined into every page, so the token appears per-page).
hash="$(sha256sum "$work/font.woff2" | cut -c1-8)"
asset="iosevka-custom.${hash}.woff2"
mv "$work/font.woff2" "public/fonts/${asset}"
find public -name '*.html' -print0 | xargs -0 sed -i "s|/fonts/iosevka-custom\.woff2|/fonts/${asset}|g"

typst compile --root . typst/resume.typ public/resume.pdf
```

- [ ] **Step 3: Build and verify a real woff2 is produced and small**

Run:
```bash
chmod +x scripts/font-codepoints.py
./scripts/build.sh
woff2=$(ls public/fonts/iosevka-custom.*.woff2); ls -l "$woff2"
head -c4 "$woff2" | xxd | head -1   # MUST be 'wOF2' (real woff2)
grep -rq '/fonts/iosevka-custom\.woff2"' public && echo "TOKEN NOT REWRITTEN" || echo "token rewritten"
grep -rqE 'iosevka-custom\.[0-9a-f]{8}\.woff2' public/index.html && echo "hashed ref present"
```
Expected: one content-hashed file ~5-8 KB (e.g. `iosevka-custom.1a2b3c4d.woff2`); magic line `774f 4632  wOF2`; `token rewritten`; `hashed ref present`.

- [ ] **Step 4: Commit**

```bash
git add scripts/font-codepoints.py scripts/build.sh
git commit -m "feat(font): build-time exact subset into public/fonts (pyftsubset)"
```

---

## Task 5: Point the site at the new asset; remove the old one

**Files:**
- Modify: `assets/scss/main.scss` (lines 4, 8, 42, 117)
- Modify: `layouts/_partials/head.html` (line 7)
- Delete: `static/fonts/iosevka-etoile-latin.woff2`

The `src`/`href` below use the **stable token** `/fonts/iosevka-custom.woff2`. That exact path is never served — `build.sh` (Task 4) rewrites it to the content-hashed name (`iosevka-custom.<hash>.woff2`) in the built HTML. Author the token; the build does the rest.

- [ ] **Step 1: Rename the CSS family to "Iosevka Custom" (3 occurrences) in `assets/scss/main.scss`**

The `@font-face` `font-family` (line 4) and both font stacks (lines 42 and 117) currently say `"Iosevka Etoile"`. Replace all three:
```bash
sed -i 's/"Iosevka Etoile"/"Iosevka Custom"/g' assets/scss/main.scss
grep -c '"Iosevka Custom"' assets/scss/main.scss   # expect 3
```

- [ ] **Step 2: Update the `@font-face` src filename in `assets/scss/main.scss` (line 8)**

Replace:
```scss
  src: url("/fonts/iosevka-etoile-latin.woff2") format("woff2");
```
with:
```scss
  src: url("/fonts/iosevka-custom.woff2") format("woff2");
```

- [ ] **Step 3: Update the preload in `layouts/_partials/head.html` (line 7)**

Replace:
```html
  <link rel="preload" href="/fonts/iosevka-etoile-latin.woff2" as="font" type="font/woff2" crossorigin>
```
with:
```html
  <link rel="preload" href="/fonts/iosevka-custom.woff2" as="font" type="font/woff2" crossorigin>
```

- [ ] **Step 4: Delete the old out-of-band asset**

Run: `git rm static/fonts/iosevka-etoile-latin.woff2`

- [ ] **Step 5: Rebuild and verify the new URL is wired and the old one is gone**

Run:
```bash
./scripts/build.sh
grep -rqE "/fonts/iosevka-custom\.[0-9a-f]{8}\.woff2" public/index.html && echo "preload OK"
grep -rq "iosevka-etoile" public && echo "STALE REF FOUND" || echo "no stale refs"
ls public/fonts/iosevka-custom.*.woff2 >/dev/null && echo "asset present"
```
Expected: `preload OK`, `no stale refs`, `asset present`.

- [ ] **Step 6: Commit**

```bash
git add assets/scss/main.scss layouts/_partials/head.html
git commit -m "feat(font): serve self-built Iosevka subset, drop old asset"
```

---

## Task 6: Full verification (gates + coverage + render)

**Files:** none (verification only)

- [ ] **Step 1: Run the full build + checks**

Run: `./scripts/build.sh && ./scripts/check.sh`
Expected: ends with `page-weight OK ...`; htmltest and lychee report no errors (the `/fonts/iosevka-custom.woff2` preload resolves).

- [ ] **Step 2: Verify the shipped woff2 covers every rendered codepoint** (uses the same `font-codepoints.py` as the shipper)

Run:
```bash
"$FONT_PYTHON" scripts/font-codepoints.py public > /tmp/want.txt
"$FONT_PYTHON" - <<'PY'
import glob
from fontTools.ttLib import TTFont
want = {ord(c) for c in open('/tmp/want.txt', encoding='utf-8').read()}
woff2 = glob.glob('public/fonts/iosevka-custom.*.woff2')[0]
cov = set().union(*[t.cmap.keys() for t in TTFont(woff2)['cmap'].tables])
missing = sorted(want - cov)
print("missing:", ["U+%04X" % c for c in missing] or "none")
assert not missing, "subset missing glyphs the site renders"
print("coverage OK")
PY
```
Expected: `missing: none` then `coverage OK`.

- [ ] **Step 3: Confirm the page-weight headroom**

Run: `ls -l public/fonts/iosevka-custom.*.woff2`
Expected: one content-hashed file ~5-8 KB (well under the prior ~30 KB; gate has wide margin).

- [ ] **Step 4: Visual render check (no tofu)**

Run a local server and screenshot with Playwright's bundled browser (no snap; per project constraints):
```bash
hugo server &   # serves the build; note /resume.pdf is absent in dev (expected)
# In Playwright: load http://localhost:1313/ and a post page, screenshot, confirm:
#  - body/headings render in Iosevka Custom (slab serifs visible), NO .notdef boxes for ·–—' or ◐ toggle
#  - the owner's baked variants show: dotted zero (0), double-storey g, the chosen 1/4/7 forms
```
Expected: text renders in the self-built font with the owner's variants; `◐` shows; no tofu. Kill the server when done.

---

## Task 7: CI — provision fonttools for the build job

**Files:**
- Modify: `.forgejo/workflows/build.yml`

CI is `ubuntu-latest` running `install-tools.sh` → `build.sh` → `check.sh`. `build.sh` needs `pyftsubset`; provision a pinned fonttools venv and expose it via `FONT_PYTHON`. The **publish** job needs no change — it consumes the already-built `public/` (which includes the woff2), so no fonttools there.

- [ ] **Step 1: Add a venv step before "Build site" in the `build` job**

Insert after the existing `Install pinned toolchain` step (current lines 14-17):
```yaml
      - name: Font subsetter (fonttools)
        run: |
          python3 -m venv "$HOME/.font-venv"
          "$HOME/.font-venv/bin/pip" install -q -r tools/font/requirements.txt
          echo "FONT_PYTHON=$HOME/.font-venv/bin/python" >> "$GITHUB_ENV"
```

- [ ] **Step 2: Verify locally that build.sh works with only the venv python** (simulate CI)

Run (uses the venv explicitly, not your shell's fonttools):
```bash
FONT_PYTHON="$HOME/.cache/futro-font-venv/bin/python" ./scripts/build.sh
head -c4 public/fonts/iosevka-custom.woff2 | xxd | head -1   # expect wOF2
```
Expected: build completes; magic is `wOF2`.

- [ ] **Step 3: Commit**

```bash
git add .forgejo/workflows/build.yml
git commit -m "ci(font): provision fonttools venv for the build job"
```

---

## Follow-up (post-FE-review, out of scope here)

The frontend-design review decides three things; each is a small change on this pipeline, not a redesign:

1. **Weight count** — add `[buildPlans.IosevkaCustom.weights.<Name>]` entries (e.g. Medium 500), rerun `build-font.sh` (new master per weight), add an `@font-face` per weight in `main.scss`, and a `pyftsubset` step per master in `build.sh`.
2. **Italics** — the committed config builds **upright only** (`slopes.Upright`). If a real italic is chosen, add a `[buildPlans.IosevkaCustom.slopes.Italic]` block, rerun `build-font.sh`, and add an italic `@font-face`. Default (drop) needs nothing.
3. **Layout features** — the master carries a curated menu (typographic features + coding ligatures). Enabling any is a `build.sh` flag change (`--layout-features=<set>`, and drop `--no-layout-closure` so the glyphs ship) — **no master rebuild**. Coding ligatures should be scoped to `code`/`pre` via CSS `font-feature-settings` so prose isn't ligated. Only a feature *outside* the menu needs a master rebuild.

## Notes / risks

- **Python in the build path (accepted).** `build.sh` (and CI) now depend on a pinned fonttools venv. This is the agreed tradeoff for real woff2 in one tool — `hb-subset` can't emit woff2, and it removes the static-binary compile + CI vendoring + glibc-portability concerns entirely. Pins live in `tools/font/requirements.txt`.
- **Content-hashed font URL (Caddy `immutable`).** The serving Caddyfile sets `Cache-Control: immutable` on `/fonts/*`, and this file isn't Hugo-fingerprinted, so `build.sh` content-hashes the name (`iosevka-custom.<sha256[:8]>.woff2`) and rewrites the stable token across the inlined HTML. The name changes iff the bytes change — so `immutable` is safe and byte-identical rebuilds keep caching.
- **Master coverage bound (T4).** A glyph outside T4 (CJK, rare scripts) falls back to the system font, and Task 6 Step 2 flags it as `missing` — widen the `--unicodes` range in the Containerfile and rerun `build-font.sh`.
- **Shipper/verifier agree by construction.** Both `build.sh` and the Task 6 coverage check call `scripts/font-codepoints.py`, so the subset is built from, and checked against, the same codepoint set.
- **Config provenance.** `tools/font/private-build-plans.toml` is the owner's `IosevkaCustom` config verbatim, minus Bold (FE review adds weights). `noCvSs = true` bakes the variant selections as defaults and skips cv##/ss##, so the curated master menu carries only typographic features + coding ligatures.
