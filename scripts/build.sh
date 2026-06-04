#!/usr/bin/env bash
# Full site build: Hugo first, then the resume PDF into public/.
# Order matters — lychee/htmltest must run AFTER this so /resume.pdf is checked.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf public
hugo --minify --panicOnWarning
typst compile --root . typst/resume.typ public/resume.pdf
