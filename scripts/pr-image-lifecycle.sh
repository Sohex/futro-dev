#!/usr/bin/env bash
# Helpers for PR preview image tags and merged-PR registry cleanup.
set -euo pipefail

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
REGISTRY_URL="${REGISTRY_URL:-https://registry.int.futro.dev}"
IMAGE_REPO="${IMAGE_REPO:-futro-dev}"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/pr-image-lifecycle.sh pr-tags <pr-number> <head-sha>
  scripts/pr-image-lifecycle.sh extract-pr-number [message]
  scripts/pr-image-lifecycle.sh filter-tags <pr-number>
  scripts/pr-image-lifecycle.sh cleanup [pr-number]

Environment:
  REGISTRY_URL  Registry base URL. Default: https://registry.int.futro.dev
  IMAGE_REPO    Repository name in the registry. Default: futro-dev
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

validate_pr_number() {
  local pr_number=$1
  [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || die "invalid PR number: $pr_number"
}

validate_sha() {
  local sha=$1
  [[ "$sha" =~ ^[0-9a-fA-F]{7,40}$ ]] || die "invalid commit SHA: $sha"
}

cmd_pr_tags() {
  [[ $# -eq 2 ]] || { usage; exit 2; }
  local pr_number=$1
  local head_sha=$2

  validate_pr_number "$pr_number"
  validate_sha "$head_sha"

  head_sha="${head_sha,,}"
  printf 'pr-%s\n' "$pr_number"
  printf 'pr-%s-%s\n' "$pr_number" "$head_sha"
}

cmd_extract_pr_number() {
  local message
  if [[ $# -gt 0 ]]; then
    message=$*
  else
    message=$(cat)
  fi

  python3 - "$message" <<'PY'
import re
import sys

message = sys.argv[1]
match = re.search(r"\(#([1-9][0-9]*)\)", message)
if match:
    print(match.group(1))
PY
}

cmd_filter_tags() {
  [[ $# -eq 1 ]] || { usage; exit 2; }
  local pr_number=$1
  validate_pr_number "$pr_number"

  python3 -c '
import json
import sys

pr_number = sys.argv[1]
payload = json.load(sys.stdin)
prefix = f"pr-{pr_number}-"
exact = f"pr-{pr_number}"
for tag in payload.get("tags") or []:
    if tag == exact or tag.startswith(prefix):
        print(tag)
' "$pr_number"
}

merged_pr_from_git() {
  git log -1 --format=%B | "$SCRIPT_PATH" extract-pr-number
}

delete_tag() {
  local tag=$1
  local response_file
  local status

  response_file=$(mktemp)
  status=$(
    curl -sS -o "$response_file" -w '%{http_code}' \
      -X DELETE "${REGISTRY_URL}/v2/${IMAGE_REPO}/manifests/${tag}" || true
  )

  case "$status" in
    2??)
      echo "deleted ${IMAGE_REPO}:${tag}"
      rm -f "$response_file"
      ;;
    404)
      echo "already absent ${IMAGE_REPO}:${tag}"
      rm -f "$response_file"
      ;;
    *)
      echo "ERROR: delete failed for ${IMAGE_REPO}:${tag} with HTTP ${status}" >&2
      cat "$response_file" >&2 || true
      rm -f "$response_file"
      exit 1
      ;;
  esac
}

cmd_cleanup() {
  [[ $# -le 1 ]] || { usage; exit 2; }

  local pr_number=${1:-}
  if [[ -z "$pr_number" ]]; then
    pr_number=$(merged_pr_from_git)
  fi

  if [[ -z "$pr_number" ]]; then
    echo "No merged PR number found; skipping PR image cleanup."
    exit 0
  fi

  validate_pr_number "$pr_number"

  local tags_json
  local http_status
  local tags_file

  tags_file=$(mktemp)
  http_status=$(
    curl -sS -o "$tags_file" -w '%{http_code}' \
      "${REGISTRY_URL}/v2/${IMAGE_REPO}/tags/list" || true
  )

  case "$http_status" in
    2??)
      ;;
    404)
      echo "No PR image tags found for PR #${pr_number}."
      rm -f "$tags_file"
      exit 0
      ;;
    *)
      echo "ERROR: failed to list tags for ${IMAGE_REPO} with HTTP ${http_status}" >&2
      cat "$tags_file" >&2 || true
      rm -f "$tags_file"
      exit 1
      ;;
  esac

  tags_json=$(<"$tags_file")
  rm -f "$tags_file"

  local tags
  local parse_err_file
  parse_err_file=$(mktemp)
  if ! tags=$(printf '%s' "$tags_json" | "$SCRIPT_PATH" filter-tags "$pr_number" 2>"$parse_err_file"); then
    echo "ERROR: failed to parse tags/list response for ${IMAGE_REPO}" >&2
    rm -f "$parse_err_file"
    exit 1
  fi
  rm -f "$parse_err_file"

  if [[ -z "$tags" ]]; then
    echo "No PR image tags found for PR #${pr_number}."
    exit 0
  fi

  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    delete_tag "$tag"
  done <<< "$tags"
}

main() {
  [[ $# -ge 1 ]] || { usage; exit 2; }
  local command=$1
  shift

  case "$command" in
    pr-tags) cmd_pr_tags "$@" ;;
    extract-pr-number) cmd_extract_pr_number "$@" ;;
    filter-tags) cmd_filter_tags "$@" ;;
    cleanup) cmd_cleanup "$@" ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
