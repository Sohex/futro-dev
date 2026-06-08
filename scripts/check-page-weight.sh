#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUDGET=14500       # every page: fit in the initial TCP congestion window (IW10 ≈ 10×1460 B)
HOME_BUDGET=10240  # 10 KiB, the home page (public/index.html) specifically

# Served weight: the brotli sibling Caddy actually ships, or the raw file where
# brotli-precompress.py found no gain (.br absent) and Caddy serves identity.
served() {
  [ -f "$1.br" ] && wc -c <"$1.br" || wc -c <"$1"
}

shared=0
while IFS= read -r -d '' f; do
  shared=$(( shared + $(served "$f") ))
done < <(find public \( -name '*.css' -o -name '*.js' -o -name '*.woff2' \) -print0)

status=0
while IFS= read -r -d '' page; do
  budget=$BUDGET
  [ "$page" = public/index.html ] && budget=$HOME_BUDGET
  total=$(( $(served "$page") + shared ))
  if (( total > budget )); then
    echo "FAIL $page: ${total} bytes brotli > ${budget}" >&2
    status=1
  fi
done < <(find public -name '*.html' -print0)

(( status == 0 )) && echo "page-weight OK (shared assets ${shared} bytes brotli, budget ${BUDGET}, home ${HOME_BUDGET})"
exit "$status"
