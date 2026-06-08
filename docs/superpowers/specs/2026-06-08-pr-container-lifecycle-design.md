# PR container image lifecycle

## Goal

Every pull request should produce a registry image that can be pulled and inspected before merge. After the pull request is merged, the main branch image must be built and pushed first, then the PR images for that merged PR should be removed from the registry.

The current deploy contract stays unchanged: this repo is responsible for building the static site, packaging `public/` into the scratch image defined by `Containerfile`, pushing that image to `registry.int.futro.dev`, and triggering deploy through ntfy. Runtime serving and registry configuration remain outside this repo.

## Current context

- CI runs in Forgejo Actions from `.forgejo/workflows/build.yml`.
- `pull_request` currently builds, verifies, and uploads `public/` as an artifact.
- `push` to `main` currently builds, verifies, downloads the artifact in `publish`, then runs `docker build --push` with:
  - `registry.int.futro.dev/futro-dev:latest`
  - `registry.int.futro.dev/futro-dev:${{ github.sha }}`
- The registry is Zot at `registry.int.futro.dev`, reachable from the runner, tailnet-gated, and currently has no CI registry login step.
- The runner uses Docker buildx with the container driver, so images must be pushed from `docker build --push`; a later `docker push` is not reliable in this environment.

## Tag model

For pull request number `N` and PR head commit SHA `S`, the PR publish job pushes two tags in one build:

- `registry.int.futro.dev/futro-dev:pr-N`
- `registry.int.futro.dev/futro-dev:pr-N-S`

`pr-N` is the moving preview tag for the latest successful build of that PR. `pr-N-S` is the immutable image for the exact PR commit. Both tags point at the same image manifest for that CI run.

Main branch publishing remains:

- `registry.int.futro.dev/futro-dev:latest`
- `registry.int.futro.dev/futro-dev:${{ github.sha }}`

No PR tag is used for deployment. Deployment is still driven only by the main branch publish job after `latest` and the main SHA tag are pushed.

## Workflow changes

### Pull request publish

Add a `publish-pr` job that runs only for `pull_request` events after the existing `build` job succeeds.

The job downloads the `site` artifact into `public/`, then runs a single `docker build --push -f Containerfile` with both PR tags:

```sh
docker build --push -f Containerfile \
  -t "registry.int.futro.dev/futro-dev:pr-${PR_NUMBER}" \
  -t "registry.int.futro.dev/futro-dev:pr-${PR_NUMBER}-${PR_HEAD_SHA}" \
  .
```

The workflow should use Forgejo's pull request fields for `PR_NUMBER` and `PR_HEAD_SHA`. The implementation plan must verify the exact expression names against Forgejo Actions before editing the workflow.

`publish-pr` failures should fail the PR check. Once PR images are part of the workflow contract, a PR that cannot publish its preview image is not fully green.

### Main publish

Keep the existing main publish behavior and ordering:

1. Download the built `site` artifact.
2. Build and push `latest` and `${{ github.sha }}` from `Containerfile`.
3. Trigger the ntfy deploy.
4. Clean up PR tags for the merged PR, if the main commit can be associated with one.

Cleanup intentionally happens after the main image push. If cleanup breaks, it must not delete the only image associated with the just-merged code before the deployable image exists.

## Cleanup strategy

The cleanup step identifies the pull request number that was merged by the current main commit. The first implementation should use the most reliable Forgejo-provided metadata available in a `push` workflow. If that is unavailable, use the merge commit message convention for Forgejo merge commits, such as extracting `#N` from a message like `Merge pull request ... (#N) ...`.

If no pull request number can be found, cleanup should log that decision and exit successfully. This avoids failing normal direct pushes to `main` or unusual merge formats that have no PR image lifecycle to clean up.

When a PR number is found, cleanup deletes:

- `pr-N`
- every tag matching `pr-N-*`

The deletion flow should list tags from Zot, filter them locally, and call Zot's registry API to delete each matching reference. Zot supports deleting an image manifest by reference at:

```text
DELETE /v2/{name}/manifests/{reference}
```

For this repository, the path is:

```text
DELETE https://registry.int.futro.dev/v2/futro-dev/manifests/<tag>
```

The cleanup script should treat `404` for a tag as non-fatal, because the tag may already have been removed by a retry or manual cleanup. Other delete failures should fail the cleanup step so broken registry deletion is visible.

## Retention fallback

Registry-side retention is a useful safety net but not the primary lifecycle mechanism. Zot should eventually have a policy for `futro-dev` that bounds `pr-*` tags by age or count. That protects registry storage if a main cleanup step is skipped or broken.

Retention must not replace explicit cleanup, because it is not tied to merge completion and may delete images for open PRs if configured too aggressively.

## Error handling

- PR build or verification failure: no PR image is pushed.
- PR image publish failure: PR workflow fails.
- Main image publish failure: deploy trigger and cleanup do not run.
- Deploy trigger failure: existing behavior applies; cleanup should not run before a successful main image push, but whether it runs after a failed deploy trigger is an implementation choice. Prefer keeping the initial sequence simple: deploy trigger first, cleanup second.
- Cleanup cannot identify PR number: log and exit successfully.
- Cleanup finds no matching PR tags: log and exit successfully.
- Cleanup delete returns `404`: log and continue.
- Cleanup delete returns another non-2xx status: fail the main workflow.

## Testing and verification

Static verification:

- Validate workflow YAML syntax with the repo's existing parser/actionlint fallback pattern.
- Validate the cleanup tag filter against sample tag lists:
  - `pr-12`
  - `pr-12-abc123`
  - `pr-123-abc123`
  - `pr-1-12`
  - `latest`
  - a main SHA tag
- Confirm the filter for PR `12` selects only `pr-12` and tags beginning `pr-12-`.

Live verification:

1. Open or update a test PR.
2. Confirm CI pushes both `pr-N` and `pr-N-<head-sha>`.
3. Push a second commit to the same PR.
4. Confirm `pr-N` now points to the second commit's image and both SHA-specific tags still exist.
5. Merge the PR.
6. Confirm the main workflow pushes `latest` and the main SHA tag.
7. Confirm `pr-N` and all `pr-N-*` tags for the merged PR are deleted.

## Non-goals

- Changing the deploy mechanism.
- Adding registry authentication unless Zot configuration starts requiring it.
- Cleaning up PR images from other repositories.
- Deleting main branch SHA tags.
- Solving registry retention policy configuration in this repo.
