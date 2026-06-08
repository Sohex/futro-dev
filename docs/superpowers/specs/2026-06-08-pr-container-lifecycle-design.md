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

Add a `publish-pr` job that runs only for same-repository `pull_request` events after the existing `build` job succeeds. PRs from forks are not trusted for registry publishing and should skip `publish-pr`; they can still run the build and verification checks.

The job downloads the `site` artifact into `public/`, then runs a single `docker build --push -f Containerfile` with both PR tags:

```sh
docker build --push -f Containerfile \
  -t "registry.int.futro.dev/futro-dev:pr-${PR_NUMBER}" \
  -t "registry.int.futro.dev/futro-dev:pr-${PR_NUMBER}-${PR_HEAD_SHA}" \
  .
```

The workflow should use Forgejo's pull request fields for `PR_NUMBER`, `PR_HEAD_SHA`, and the same-repository check. The implementation plan must verify the exact expression names against Forgejo Actions before editing the workflow.

`publish-pr` failures should fail the PR check. Once PR images are part of the workflow contract, a PR that cannot publish its preview image is not fully green.

### Main publish

Keep the existing main publish behavior and ordering:

1. Download the built `site` artifact.
2. Build and push `latest` and `${{ github.sha }}` from `Containerfile`.
3. Trigger the ntfy deploy.
4. Clean up PR tags for the merged PR, if the main commit can be associated with one.

Cleanup intentionally happens after the main image push. If cleanup breaks, it must not delete the only image associated with the just-merged code before the deployable image exists.

## Cleanup strategy

The cleanup step identifies the pull request number that was merged by the current main commit. Cleanup is guaranteed for Forgejo merge commits that include the PR number in the commit message, such as extracting `#N` from `Merge pull request ... (#N) ...`.

Squash merge support is desirable if it is low-complexity. The implementation plan should first check whether Forgejo exposes enough push-event metadata or a simple `fj`/Forgejo API lookup to map the pushed main commit back to the merged PR. If that mapping is straightforward, include squash merge cleanup. If it requires broad API plumbing or stored state, leave squash merge support out of the first implementation and document that squash merges skip cleanup until Zot retention removes the PR tags.

If no pull request number can be found, cleanup should log that decision and exit successfully. This avoids failing normal direct pushes to `main` or unusual merge formats that have no PR image lifecycle to clean up.

When a PR number is found, cleanup deletes:

- `pr-N`
- every tag matching `pr-N-*`

The deletion flow should list all matching tags from Zot before issuing any delete calls, then call Zot's registry API to delete each matching reference. Zot supports deleting an image manifest by reference at:

```text
DELETE /v2/{name}/manifests/{reference}
```

For this repository, the path is:

```text
DELETE https://registry.int.futro.dev/v2/futro-dev/manifests/<tag>
```

The cleanup script should treat `404` for a tag as non-fatal, because the tag may already have been removed by a retry or manual cleanup. Other delete failures should fail the cleanup step so broken registry deletion is visible.

## Retention fallback

Registry-side retention is an external operational recommendation, not an implementation requirement for this repo. Zot should eventually have a policy for `futro-dev` that bounds `pr-*` tags by age or count. That protects registry storage if a main cleanup step is skipped or broken.

Retention must not replace explicit cleanup, because it is not tied to merge completion and may delete images for open PRs if configured too aggressively.

## Error handling

- PR build or verification failure: no PR image is pushed.
- PR image publish failure: PR workflow fails.
- Main image publish failure: deploy trigger and cleanup do not run.
- Deploy trigger failure: cleanup does not run. Keep the initial sequence simple: main image push, deploy trigger, cleanup.
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
- Validate PR number extraction against sample main commit messages:
  - Forgejo merge commit containing `(#12)` selects PR `12`.
  - Direct push with no PR marker selects no PR.
  - Squash merge message selects a PR only if the chosen Forgejo metadata/API lookup supports it.
  - Malformed `#` references select no PR.

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
