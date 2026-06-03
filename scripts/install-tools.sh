#!/usr/bin/env bash
# Installs the pinned toolchain from versions.env into ~/.local/bin (or $TOOLS_BIN).
# --update: resolve latest releases, rewrite versions.env, then install.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${TOOLS_BIN:-$HOME/.local/bin}"
mkdir -p "$BIN"

latest_tag() {
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name
}

if [[ "${1:-}" == "--update" ]]; then
  cat > versions.env <<EOF
HUGO_VERSION=$(latest_tag gohugoio/hugo)
TYPST_VERSION=$(latest_tag typst/typst)
LYCHEE_VERSION=$(latest_tag lycheeverse/lychee)
HTMLTEST_VERSION=$(latest_tag wjdp/htmltest)
EOF
  echo "wrote versions.env:" && cat versions.env
fi

# shellcheck source=/dev/null
source versions.env

install_release() { # repo tag asset_regex binary_name
  local repo=$1 tag=$2 regex=$3 name=$4
  if [[ -x "$BIN/$name" ]] && "$BIN/$name" --version 2>/dev/null | grep -qF "${tag#v}"; then
    echo "$name $tag already installed"
    return
  fi
  local url
  url=$(curl -fsSL "https://api.github.com/repos/$repo/releases/tags/$tag" \
        | jq -r '.assets[].browser_download_url' | grep -E "$regex" | head -1)
  [[ -n "$url" ]] || { echo "ERROR: no asset for $repo $tag matching $regex" >&2; exit 1; }
  local tmp
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/pkg"
  case "$url" in
    *.tar.gz|*.tgz) tar -xzf "$tmp/pkg" -C "$tmp" ;;
    *.tar.xz)       tar -xJf "$tmp/pkg" -C "$tmp" ;;
    *)              mv "$tmp/pkg" "$tmp/$name" ;;
  esac
  find "$tmp" -type f -name "$name" | head -1 | xargs -I{} install -m 0755 {} "$BIN/$name"
  rm -rf "$tmp"
  echo "installed $name $tag -> $BIN/$name"
}

install_release gohugoio/hugo      "$HUGO_VERSION"     'hugo_extended_.*_linux-amd64\.tar\.gz$'    hugo
install_release typst/typst        "$TYPST_VERSION"    'typst-x86_64-unknown-linux-musl\.tar\.xz$' typst
install_release lycheeverse/lychee "$LYCHEE_VERSION"   'x86_64-unknown-linux-gnu\.tar\.gz$'        lychee
install_release wjdp/htmltest      "$HTMLTEST_VERSION" 'linux_amd64\.tar\.gz$'                     htmltest
