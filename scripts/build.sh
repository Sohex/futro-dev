#!/usr/bin/env bash
# Full site build: Hugo, then the web font subset, then the resume PDF into public/.
# Order matters — lychee/htmltest must run AFTER this so /resume.pdf and the font are checked.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf public
hugo --minify --panicOnWarning

# --- web font: inline a per-page woff2 subset into each built HTML page ---
# FONT_PYTHON points at a venv with fonttools+brotli (see Prerequisites / CI). font-inline.py
# subsets the committed master to each page's exact glyph set and injects it as a base64 data:
# @font-face, so every page is one self-contained response (no /fonts request, no preload).
FONT_PYTHON="${FONT_PYTHON:-python3}"
"$FONT_PYTHON" scripts/font-inline.py public

typst compile --root . typst/resume.typ public/resume.pdf
