#!/usr/bin/env bash
# All verification gates. Run after scripts/build.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/test_csp_inline.py   # csp-inline parser/guard unit fixtures (stdlib only, no build needed)
htmltest -c .htmltest.yml
lychee --no-progress --root-dir "$PWD/public" \
  --remap "https://futro\\.dev file://$PWD/public" \
  public
./scripts/check-page-weight.sh
