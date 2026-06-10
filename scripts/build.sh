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

# --- CSP: inject a per-page hash-based Content-Security-Policy <meta> into each page ---
# After font-inline so the @font-face block is present and gets hashed; before brotli so the
# .br copies carry the meta. Hashes every inline <style>/executable <script> (stdlib only) and
# FAILS THE BUILD on any construct a hash-based, 'unsafe-inline'-free policy cannot cover.
"$FONT_PYTHON" scripts/csp-inline.py public

typst compile --root . --font-path tools/font/masters typst/resume.typ public/resume.pdf

# --- brotli precompression: write quality-11 .br siblings for Caddy's `precompressed br` ---
# After the PDF, so /resume.pdf is on disk (it's skipped as already-compressed). Uses the same
# FONT_PYTHON venv (the brotli module ships there for fonttools' woff2 support).
"$FONT_PYTHON" scripts/brotli-precompress.py public
