#!/usr/bin/env bash
# Helpers for PR preview image tags and merged-PR registry cleanup.
set -euo pipefail

REGISTRY_URL="${REGISTRY_URL:-https://registry.int.futro.dev}"
IMAGE_REPO="${IMAGE_REPO:-futro-dev}"
SCRIPT_PATH="${BASH_SOURCE[0]}"

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
  if [[ $# -gt 0 ]]; then
    local message="$*"
    printf '%s' "$message" | python3 -c '
import re
import sys

message = sys.stdin.read()
match = re.search(r"\(#([1-9][0-9]*)\)", message)
if match:
    print(match.group(1))
'
    return 0
  fi

  python3 -c '
import re
import sys

message = sys.stdin.read()
match = re.search(r"\(#([1-9][0-9]*)\)", message)
if match:
    print(match.group(1))
'
}

cmd_filter_tags() {
  [[ $# -eq 1 ]] || { usage; exit 2; }

  local pr_number=$1
  validate_pr_number "$pr_number"

  python3 -c '
import json
import sys

pr_number = sys.argv[1]
exact = f"pr-{pr_number}"
prefix = f"pr-{pr_number}-"

payload = json.load(sys.stdin)
for tag in payload.get("tags") or []:
    if tag == exact or tag.startswith(prefix):
        print(tag)
' "$pr_number"
}

merged_pr_from_git() {
  git log -1 --format=%B 2>/dev/null | "$SCRIPT_PATH" extract-pr-number || true
}

delete_tag() {
  local tag=$1
  local status

  status=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X DELETE "${REGISTRY_URL}/v2/${IMAGE_REPO}/manifests/${tag}" || true)

  case "$status" in
    2??)
      echo "deleted ${IMAGE_REPO}:${tag}"
      ;;
    404)
      echo "already absent ${IMAGE_REPO}:${tag}"
      ;;
    *)
      echo "ERROR: delete failed for ${IMAGE_REPO}:${tag} with HTTP ${status}" >&2
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

  if ! curl -fsS "${REGISTRY_URL}/v2/${IMAGE_REPO}/tags/list" \
    | "$SCRIPT_PATH" filter-tags "$pr_number" \
    | while IFS= read -r tag; do
      [[ -n "$tag" ]] || continue
      delete_tag "$tag"
    done; then
    exit 1
  fi

  echo "Cleanup complete for PR #${pr_number}."
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
