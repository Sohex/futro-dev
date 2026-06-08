#!/usr/bin/env bash
# Local tests for scripts/pr-image-lifecycle.sh. No network calls.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local name=$1
  local expected=$2
  local actual=$3

  if [[ "$actual" != "$expected" ]]; then
    fail "${name}: expected [${expected}], got [${actual}]"
  fi

  echo "PASS: ${name}"
}

assert_contains() {
  local name=$1
  local needle=$2
  local haystack=$3

  if [[ "$haystack" != *"$needle"* ]]; then
    fail "${name}: expected output to contain [${needle}], got [${haystack}]"
  fi

  echo "PASS: ${name}"
}

tags=$(scripts/pr-image-lifecycle.sh pr-tags 12 ABCDEF1234567890)
assert_eq "pr tag generation" $'pr-12\npr-12-abcdef1234567890' "$tags"

merge_pr=$(scripts/pr-image-lifecycle.sh extract-pr-number "Merge pull request 'Build preview' (#12) from feature into main")
assert_eq "merge commit PR extraction" "12" "$merge_pr"

direct_pr=$(scripts/pr-image-lifecycle.sh extract-pr-number "direct commit to main")
assert_eq "direct push PR extraction" "" "$direct_pr"

malformed_pr=$(scripts/pr-image-lifecycle.sh extract-pr-number "fix issue #12 without merge marker")
assert_eq "malformed marker PR extraction" "" "$malformed_pr"

filtered=$(printf '%s\n' '{"name":"futro-dev","tags":["pr-12","pr-12-abc123","pr-123-abc123","pr-1-12","latest","4ebde87"]}' \
  | scripts/pr-image-lifecycle.sh filter-tags 12)
assert_eq "cleanup tag filtering" $'pr-12\npr-12-abc123' "$filtered"

mock_dir=$(mktemp -d)
trap 'rm -rf "$mock_dir"' EXIT
cat > "$mock_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

out_file=""
write_fmt=""
method="GET"
url=""

while (($#)); do
  case "$1" in
    -sS)
      shift
      ;;
    -o)
      out_file=$2
      shift 2
      ;;
    -w)
      write_fmt=$2
      shift 2
      ;;
    -X)
      method=$2
      shift 2
      ;;
    http*)
      url=$1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

case "${method}|${url}" in
  GET|*/tags/list)
    printf '%s' "${MOCK_TAGS_JSON:?}" > "$out_file"
    printf '%s' "${MOCK_TAGS_STATUS:-200}"
    ;;
  DELETE|*/manifests/pr-12)
    : > "$out_file"
    printf '%s' "${MOCK_DELETE_PR12_STATUS:-200}"
    ;;
  DELETE|*/manifests/pr-12-abc123)
    : > "$out_file"
    printf '%s' "${MOCK_DELETE_PR12_SHA_STATUS:-200}"
    ;;
  *)
    echo "unexpected curl call: ${method} ${url}" >&2
    exit 99
    ;;
esac
EOF
chmod +x "$mock_dir/curl"

cleanup_success_output=$(
  PATH="$mock_dir:$PATH" \
    MOCK_TAGS_JSON='{"name":"futro-dev","tags":["pr-12","pr-12-abc123","latest"]}' \
    scripts/pr-image-lifecycle.sh cleanup 12
)
assert_contains "cleanup success deleted exact tag" "deleted futro-dev:pr-12" "$cleanup_success_output"
assert_contains "cleanup success deleted sha tag" "deleted futro-dev:pr-12-abc123" "$cleanup_success_output"

cleanup_404_output=$(
  PATH="$mock_dir:$PATH" \
    MOCK_TAGS_JSON='{"name":"futro-dev","tags":["pr-12","pr-12-abc123","latest"]}' \
    MOCK_DELETE_PR12_STATUS=404 \
    scripts/pr-image-lifecycle.sh cleanup 12
)
assert_contains "cleanup 404 tolerated" "already absent futro-dev:pr-12" "$cleanup_404_output"

set +e
cleanup_500_output=$(
  PATH="$mock_dir:$PATH" \
  MOCK_TAGS_JSON='{"name":"futro-dev","tags":["pr-12","pr-12-abc123","latest"]}' \
  MOCK_DELETE_PR12_STATUS=500 \
  scripts/pr-image-lifecycle.sh cleanup 12 2>&1
)
cleanup_500_status=$?
set -e
if [[ "$cleanup_500_status" -eq 0 ]]; then
  fail "cleanup 500 handling: expected failure, got success"
fi
assert_contains "cleanup 500 surfaces error" "ERROR: delete failed for futro-dev:pr-12 with HTTP 500" "$cleanup_500_output"

set +e
cleanup_bad_json_output=$(
  PATH="$mock_dir:$PATH" \
    MOCK_TAGS_JSON='not-json' \
    scripts/pr-image-lifecycle.sh cleanup 12 2>&1
)
cleanup_bad_json_status=$?
set -e
if [[ "$cleanup_bad_json_status" -eq 0 ]]; then
  fail "cleanup invalid JSON handling: expected failure, got success"
fi
assert_contains "cleanup invalid JSON surfaces error" "ERROR: failed to parse tags/list response for futro-dev" "$cleanup_bad_json_output"

echo "pr-image-lifecycle tests OK"
