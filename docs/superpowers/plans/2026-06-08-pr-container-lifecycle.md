# PR Container Image Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and push same-repo PR container images tagged as both `pr-N` and `pr-N-<sha>`, then delete the merged PR's tags after the main image is built, pushed, and deployed.

**Architecture:** Keep the workflow simple by adding one focused shell helper, `scripts/pr-image-lifecycle.sh`, for tag generation, merge-commit PR extraction, tag filtering, and Zot cleanup. Add a script-level test harness so the tricky string parsing and filtering behavior is verified locally before wiring it into `.forgejo/workflows/build.yml`. Forgejo Actions remains the orchestrator; Zot remains unauthenticated and tailnet-gated from CI.

**Tech Stack:** Forgejo Actions, Docker buildx via `docker build --push`, Zot registry HTTP API, Bash, Python 3 stdlib for JSON parsing.

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `scripts/pr-image-lifecycle.sh` | Generate PR tags, extract merged PR number from commit text, filter Zot tag lists, and delete matching PR tags from Zot. |
| `scripts/test-pr-image-lifecycle.sh` | Local script tests for tag generation, PR-number extraction, and cleanup tag filtering. |
| `.forgejo/workflows/build.yml` | Checkout same-repo PR heads explicitly, add same-repo PR image publishing, and add post-deploy merged-PR cleanup. Keep artifact actions pinned to v3. |
| `docs/superpowers/plans/2026-06-08-pr-container-lifecycle.md` | This implementation plan. |

The helper script is intentionally kept separate from workflow YAML so the non-trivial parsing can be tested without running Forgejo Actions. The workflow only passes event values through environment variables and calls the helper.

## Task 1: Add the PR Image Lifecycle Helper

**Files:**
- Create: `scripts/pr-image-lifecycle.sh`

- [ ] **Step 1: Create `scripts/pr-image-lifecycle.sh`**

```bash
#!/usr/bin/env bash
# Helpers for PR preview image tags and merged-PR registry cleanup.
set -euo pipefail

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
prefix = f"pr-{pr_number}-"
exact = f"pr-{pr_number}"

payload = json.load(sys.stdin)
for tag in payload.get("tags") or []:
    if tag == exact or tag.startswith(prefix):
        print(tag)
' "$pr_number"
}

merged_pr_from_git() {
  git log -1 --format=%B | "$0" extract-pr-number
}

delete_tag() {
  local tag=$1
  local response_file
  local status

  response_file=$(mktemp)
  status=$(curl -sS -o "$response_file" -w '%{http_code}' \
    -X DELETE "${REGISTRY_URL}/v2/${IMAGE_REPO}/manifests/${tag}" || true)

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

  local tags
  tags=$(curl -fsS "${REGISTRY_URL}/v2/${IMAGE_REPO}/tags/list" | "$0" filter-tags "$pr_number")

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
```

- [ ] **Step 2: Make the helper executable**

Run:

```bash
chmod +x scripts/pr-image-lifecycle.sh
```

Expected: command exits 0.

- [ ] **Step 3: Smoke-test tag generation**

Run:

```bash
scripts/pr-image-lifecycle.sh pr-tags 12 ABCDEF1234567890
```

Expected:

```text
pr-12
pr-12-abcdef1234567890
```

- [ ] **Step 4: Smoke-test merge commit extraction**

Run:

```bash
scripts/pr-image-lifecycle.sh extract-pr-number "Merge pull request 'Example' (#12) from branch into main"
```

Expected:

```text
12
```

- [ ] **Step 5: Commit the helper**

```bash
git add scripts/pr-image-lifecycle.sh
git commit -m "ci: add PR image lifecycle helper"
```

## Task 2: Add Local Tests for the Helper

**Files:**
- Create: `scripts/test-pr-image-lifecycle.sh`

- [ ] **Step 1: Create `scripts/test-pr-image-lifecycle.sh`**

```bash
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

echo "pr-image-lifecycle tests OK"
```

- [ ] **Step 2: Make the test executable**

Run:

```bash
chmod +x scripts/test-pr-image-lifecycle.sh
```

Expected: command exits 0.

- [ ] **Step 3: Run the tests**

Run:

```bash
scripts/test-pr-image-lifecycle.sh
```

Expected:

```text
PASS: pr tag generation
PASS: merge commit PR extraction
PASS: direct push PR extraction
PASS: malformed marker PR extraction
PASS: cleanup tag filtering
pr-image-lifecycle tests OK
```

- [ ] **Step 4: Commit the tests**

```bash
git add scripts/test-pr-image-lifecycle.sh
git commit -m "test: cover PR image lifecycle helper"
```

## Task 3: Wire Same-Repo PR Image Publishing

**Files:**
- Modify: `.forgejo/workflows/build.yml`

- [ ] **Step 1: Confirm Forgejo event fields locally from documentation**

Use the Forgejo Actions reference before editing the workflow. Confirm these expressions are supported in Forgejo's GitHub-compatible context:

```text
github.event_name
github.event.pull_request.number
github.event.pull_request.head.sha
github.event.pull_request.head.repo.full_name
github.event.repository.full_name
github.sha
```

Expected: Forgejo documents that `github` is equivalent to `forgejo`, and that `github.event` contains the webhook payload. If an expression name differs on this Forgejo version, use the actual event payload path and update the workflow below consistently.

- [ ] **Step 2: Make same-repo PR checkout identity explicit in the `build` job**

Modify the existing first checkout step in `.forgejo/workflows/build.yml` from:

```yaml
      - uses: actions/checkout@v6
```

to:

```yaml
      - uses: actions/checkout@v6
        with:
          ref: ${{ github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.event.repository.full_name && github.event.pull_request.head.sha || github.sha }}
```

Then add this step immediately after checkout:

```yaml
      - name: Confirm same-repo PR checkout SHA
        if: github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.event.repository.full_name
        env:
          PR_HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        run: |
          checked_out="$(git rev-parse HEAD)"
          echo "checked out ${checked_out}"
          test "$checked_out" = "$PR_HEAD_SHA"
```

For same-repo PRs, the `site` artifact now represents the exact commit named by `pr-N-<sha>`. Fork PRs still run build and verification, but they use the normal event SHA and never run `publish-pr`.

- [ ] **Step 3: Add the `publish-pr` job after `build` and before `publish`**

Modify `.forgejo/workflows/build.yml` so the `jobs:` block contains this new job between the existing `build` and `publish` jobs:

```yaml
  publish-pr:
    if: github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.event.repository.full_name
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          ref: ${{ github.event.pull_request.head.sha }}

      - uses: actions/download-artifact@v3
        with:
          name: site
          path: public

      - name: Build and push PR artifact image
        env:
          PR_NUMBER: ${{ github.event.pull_request.number }}
          PR_HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        run: |
          readarray -t pr_tags < <(./scripts/pr-image-lifecycle.sh pr-tags "$PR_NUMBER" "$PR_HEAD_SHA")
          docker build --push -f Containerfile \
            -t "registry.int.futro.dev/futro-dev:${pr_tags[0]}" \
            -t "registry.int.futro.dev/futro-dev:${pr_tags[1]}" \
            .
```

Keep the existing `publish` job's condition as:

```yaml
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
```

Do not change `actions/upload-artifact@v3` or `actions/download-artifact@v3`; Forgejo needs the classic artifact API.

- [ ] **Step 4: Validate workflow YAML syntax**

Run:

```bash
actionlint .forgejo/workflows/build.yml 2>/dev/null || python3 -c "import yaml; yaml.safe_load(open('.forgejo/workflows/build.yml')); print('YAML-OK')"
```

Expected: either `actionlint` exits 0 with no output, or the fallback prints:

```text
YAML-OK
```

- [ ] **Step 5: Run helper tests again**

Run:

```bash
scripts/test-pr-image-lifecycle.sh
```

Expected:

```text
PASS: pr tag generation
PASS: merge commit PR extraction
PASS: direct push PR extraction
PASS: malformed marker PR extraction
PASS: cleanup tag filtering
pr-image-lifecycle tests OK
```

- [ ] **Step 6: Commit PR publish workflow**

```bash
git add .forgejo/workflows/build.yml
git commit -m "ci: publish preview images for same-repo PRs"
```

## Task 4: Wire Post-Deploy Cleanup for Merged PR Images

**Files:**
- Modify: `.forgejo/workflows/build.yml`

- [ ] **Step 1: Decide whether low-complexity squash cleanup is available**

Inspect the push event payload and local Forgejo CLI help before editing cleanup behavior:

```bash
python3 - <<'PY'
import json
import os
path = os.environ.get("GITHUB_EVENT_PATH")
if not path or not os.path.exists(path):
    print("GITHUB_EVENT_PATH unavailable outside Forgejo Actions")
else:
    payload = json.load(open(path))
    for key in ("commits", "head_commit", "repository", "ref"):
        print(f"{key}: {'present' if key in payload else 'missing'}")
PY
fj pr --help
```

Expected outside CI: the Python snippet prints `GITHUB_EVENT_PATH unavailable outside Forgejo Actions`, and `fj pr --help` lists available PR commands. During implementation, if `fj` exposes a simple command that maps the current main commit SHA to the merged PR number, add that lookup to `merged_pr_from_git()` before commit-message parsing and add one test fixture for its output shape. If there is no one-command lookup, do not add squash cleanup in this implementation; merge commits remain the guaranteed cleanup path.

- [ ] **Step 2: Add cleanup after the deploy trigger**

Modify the existing main-only `publish` job so this step appears immediately after `Trigger site deploy`:

```yaml
      - name: Clean up merged PR artifact images
        run: ./scripts/pr-image-lifecycle.sh cleanup
```

The final main `publish` job should preserve this order:

```text
checkout
download site artifact
docker build --push latest + main SHA
curl ntfy deploy trigger
scripts/pr-image-lifecycle.sh cleanup
```

- [ ] **Step 3: Validate workflow YAML syntax**

Run:

```bash
actionlint .forgejo/workflows/build.yml 2>/dev/null || python3 -c "import yaml; yaml.safe_load(open('.forgejo/workflows/build.yml')); print('YAML-OK')"
```

Expected: either `actionlint` exits 0 with no output, or the fallback prints:

```text
YAML-OK
```

- [ ] **Step 4: Verify cleanup skips direct-push messages**

Run:

```bash
scripts/pr-image-lifecycle.sh extract-pr-number "direct commit to main"
```

Expected: no output, exit 0.

- [ ] **Step 5: Verify cleanup extracts Forgejo merge PR numbers**

Run:

```bash
scripts/pr-image-lifecycle.sh extract-pr-number "Merge pull request 'Preview images' (#12) from pr-images into main"
```

Expected:

```text
12
```

- [ ] **Step 6: Commit cleanup workflow**

```bash
git add .forgejo/workflows/build.yml
git commit -m "ci: clean up merged PR preview images"
```

## Task 5: Final Static Verification and Documentation Check

**Files:**
- Modify only if tracking checkbox progress: `docs/superpowers/plans/2026-06-08-pr-container-lifecycle.md`

- [ ] **Step 1: Run helper tests**

Run:

```bash
scripts/test-pr-image-lifecycle.sh
```

Expected:

```text
PASS: pr tag generation
PASS: merge commit PR extraction
PASS: direct push PR extraction
PASS: malformed marker PR extraction
PASS: cleanup tag filtering
pr-image-lifecycle tests OK
```

- [ ] **Step 2: Validate workflow YAML**

Run:

```bash
actionlint .forgejo/workflows/build.yml 2>/dev/null || python3 -c "import yaml; yaml.safe_load(open('.forgejo/workflows/build.yml')); print('YAML-OK')"
```

Expected: either `actionlint` exits 0 with no output, or the fallback prints:

```text
YAML-OK
```

- [ ] **Step 3: Inspect the workflow diff**

Run:

```bash
git diff -- .forgejo/workflows/build.yml scripts/pr-image-lifecycle.sh scripts/test-pr-image-lifecycle.sh
```

Expected:

```text
The diff adds only:
- scripts/pr-image-lifecycle.sh
- scripts/test-pr-image-lifecycle.sh
- explicit same-repo PR head checkout and checkout SHA assertion in the build job
- publish-pr job for same-repo PRs
- post-deploy cleanup step in the main publish job
```

- [ ] **Step 4: Commit plan checkbox updates if execution checked boxes**

If this plan was executed by checking off steps in `docs/superpowers/plans/2026-06-08-pr-container-lifecycle.md`, commit the checkbox updates:

```bash
git add docs/superpowers/plans/2026-06-08-pr-container-lifecycle.md
git commit -m "docs: update PR image lifecycle plan progress"
```

Expected: commit exits 0 if checkbox state changed. If no checkbox state changed, `git status --short docs/superpowers/plans/2026-06-08-pr-container-lifecycle.md` prints nothing.

## Task 6: Live Forgejo/Zot Verification

**Files:**
- No repo file changes expected.

- [ ] **Step 1: Push the branch**

Run:

```bash
git push -u origin pr-container-lifecycle-spec
```

Expected: branch pushes successfully.

- [ ] **Step 2: Open or update a same-repo PR**

Run:

```bash
fj pr create --base main --head pr-container-lifecycle-spec --body "Build PR preview images and clean them after merge."
```

Expected: Forgejo creates a PR and returns its PR number. Record that number as `N`.

- [ ] **Step 3: Confirm PR workflow publishes both tags**

After the PR workflow completes, run:

```bash
curl -fsS https://registry.int.futro.dev/v2/futro-dev/tags/list | scripts/pr-image-lifecycle.sh filter-tags N
```

Replace `N` with the PR number from Step 2.

Expected output includes:

```text
pr-N
pr-N-<head-sha>
```

Capture the first PR head SHA and image digest:

```bash
FIRST_HEAD_SHA=$(git rev-parse HEAD)
digest_for() {
  curl -fsSI \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://registry.int.futro.dev/v2/futro-dev/manifests/$1" \
    | awk 'BEGIN{IGNORECASE=1} /^Docker-Content-Digest:/ {gsub(/\r/,"",$2); print $2}'
}
FIRST_SHA_DIGEST=$(digest_for "pr-N-${FIRST_HEAD_SHA}")
FIRST_MOVING_DIGEST=$(digest_for "pr-N")
test -n "$FIRST_SHA_DIGEST"
test "$FIRST_SHA_DIGEST" = "$FIRST_MOVING_DIGEST"
```

Replace `N` with the PR number. Expected: both `test` commands exit 0, proving `pr-N` points at the same digest as `pr-N-<first-head-sha>`.

- [ ] **Step 4: Push a second same-PR commit**

Make a harmless docs-only commit or amend this plan's checkbox progress, then push:

```bash
git push
```

Expected: the PR workflow reruns.

- [ ] **Step 5: Confirm mutable and immutable PR tags after the second PR build**

Run:

```bash
curl -fsS https://registry.int.futro.dev/v2/futro-dev/tags/list | scripts/pr-image-lifecycle.sh filter-tags N
```

Replace `N` with the PR number.

Expected output includes:

```text
pr-N
pr-N-<first-head-sha>
pr-N-<second-head-sha>
```

Confirm the moving `pr-N` tag now points at the second commit's image, while the first SHA tag still points at its original digest:

```bash
SECOND_HEAD_SHA=$(git rev-parse HEAD)
SECOND_SHA_DIGEST=$(digest_for "pr-N-${SECOND_HEAD_SHA}")
SECOND_MOVING_DIGEST=$(digest_for "pr-N")
FIRST_SHA_DIGEST_AFTER=$(digest_for "pr-N-${FIRST_HEAD_SHA}")

test -n "$SECOND_SHA_DIGEST"
test "$SECOND_SHA_DIGEST" = "$SECOND_MOVING_DIGEST"
test "$FIRST_SHA_DIGEST" = "$FIRST_SHA_DIGEST_AFTER"
test "$FIRST_SHA_DIGEST" != "$SECOND_SHA_DIGEST"
```

Replace `N` with the PR number. Expected: all `test` commands exit 0. If the last comparison fails because the two commits produced byte-identical site images, confirm the two SHA-specific tags exist and note that the image content did not change; the mutable tag check still passes if `pr-N` equals `pr-N-<second-head-sha>`.

- [ ] **Step 6: Merge the PR with a merge commit**

Run:

```bash
fj pr merge N --method merge --delete
```

Replace `N` with the PR number.

Expected: the PR merges into `main` with a merge commit and deletes the branch.

- [ ] **Step 7: Confirm main publish ran and cleanup removed PR tags**

After the main workflow completes, run:

```bash
curl -fsS https://registry.int.futro.dev/v2/futro-dev/tags/list | scripts/pr-image-lifecycle.sh filter-tags N
```

Expected: no output, exit 0.

Then confirm main tags still exist:

```bash
curl -fsS https://registry.int.futro.dev/v2/futro-dev/tags/list
```

Expected: output includes `latest` and the merge commit SHA tag.

## Notes on Squash Merge Support

The first implementation guarantees cleanup for Forgejo merge commits containing `(#N)`. During implementation, check whether the push event payload at `$GITHUB_EVENT_PATH` or the `fj` CLI can map a squash-merged main commit to a PR number with one simple command. If that command exists, add a small branch inside `merged_pr_from_git()` to use it before falling back to commit-message parsing, and add one test fixture for that command's output shape. If it needs stored state, pagination, or broad API querying, keep squash cleanup out of this implementation and rely on Zot retention for those rare tags.

## Self-Review

Spec coverage:

- Same-repo PR publishing: Task 3 adds the job condition and PR tag push.
- Dual tag model: Task 1 generates `pr-N` and `pr-N-<sha>`; Task 3 pushes both.
- No fork publishing: Task 3 same-repository condition enforces it.
- PR image identity: Task 3 checks out same-repo PR heads explicitly and verifies `git rev-parse HEAD` matches the PR head SHA before building.
- Main publish unchanged: Task 3 keeps the existing main `publish` condition; Task 4 only appends cleanup after deploy.
- Merge-commit cleanup: Task 1 parses `(#N)`; Task 4 investigates low-complexity squash support and wires cleanup after deploy.
- Zot deletion behavior: Task 1 uses `DELETE /v2/futro-dev/manifests/<tag>`, accepts `2xx` and `404`, fails other statuses.
- Static verification: Tasks 2, 3, 4, and 5 cover helper behavior and YAML parsing.
- Live verification: Task 6 covers PR publish, mutable tag digest movement, immutable SHA tag retention, merge, main publish, and cleanup.

Placeholder scan: no unresolved placeholders are required to implement the plan. Values marked `N`, `<head-sha>`, and `<first-head-sha>` are live verification values discovered from the PR being tested.

Type and name consistency:

- Script subcommands are `pr-tags`, `extract-pr-number`, `filter-tags`, and `cleanup`.
- Workflow calls `pr-tags` and `cleanup`.
- Tests call `pr-tags`, `extract-pr-number`, and `filter-tags`.
