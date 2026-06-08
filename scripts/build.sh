#!/usr/bin/env bash
# Full site build: Hugo, then the web font subset, then the resume PDF into public/.
# Order matters — lychee/htmltest must run AFTER this so /resume.pdf and the font are checked.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf public
hugo --minify --panicOnWarning

# --- web font: exact-subset the committed master against the rendered content ---
# FONT_PYTHON points at a venv with fonttools+brotli (see Prerequisites / CI). Default ships
# NO OpenType features (smallest). Master carries a curated menu; to enable some, set e.g.
# --layout-features=calt,clig and DROP --no-layout-closure (so the feature's glyphs ship).
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
