#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUDGET=76800  # 75 KiB

shared=0
while IFS= read -r -d '' f; do
  shared=$(( shared + $(gzip -9 -c "$f" | wc -c) ))
done < <(find public \( -name '*.css' -o -name '*.js' -o -name '*.woff2' \) -print0)

status=0
while IFS= read -r -d '' page; do
  page_gz=$(gzip -9 -c "$page" | wc -c)
  total=$(( page_gz + shared ))
  if (( total > BUDGET )); then
    echo "FAIL $page: ${total} bytes gzipped > ${BUDGET}" >&2
    status=1
  fi
done < <(find public -name '*.html' -print0)

(( status == 0 )) && echo "page-weight OK (shared assets ${shared} bytes gzipped, budget ${BUDGET})"
exit "$status"
