#!/usr/bin/env bash
# All verification gates. Run after scripts/build.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
htmltest -c .htmltest.yml
lychee --no-progress --root-dir "$PWD/public" public
./scripts/check-page-weight.sh
