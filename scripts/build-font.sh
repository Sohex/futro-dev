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
