# Design: "How this server is built" post + vps-setup project page

**Date:** 2026-06-10
**Status:** Approved, pre-implementation

## Goal

Add two pieces of content to futro.dev describing the infrastructure-as-code
repo (`vps-setup`) that runs the server this site is hosted on:

1. A **post** — a deeper technical tour of the server's build, fulfilling the
   "how this server is built — forthcoming" promise made twice in the existing
   post `how-this-site-ships`.
2. A **project page** — a short, scannable entry mirroring the `futro.dev`
   project page's format.

The companion post already hands off to "the IaC side of things"; this work
closes that loop.

## Source material

- `~/git/vps-setup/README.md` and `~/git/vps-setup/CLAUDE.md` are the factual
  basis. Do not invent capabilities not present there.
- The full design rationale (including rejected alternatives) lives in
  `vps-setup`'s own `docs/superpowers/specs/2026-05-27-vps-iac-design.md`.

## Files

| File | Action |
|---|---|
| `content/posts/how-this-server-is-built.md` | **Create** — the post |
| `content/projects/vps-setup.md` | **Create** — the project page |
| `content/posts/how-this-site-ships.md` | **Edit** — wire its two `[how this server is built] - forthcoming` references to the new post; drop "forthcoming" |

### Frontmatter

Match existing published files (not the `draft: true` archetypes):

- **Post:** `title`, `date: 2026-06-10`, `description` (one sentence, colophon
  style; no `draft` key, matching the live `how-this-site-ships.md`).
- **Project:** `title: "vps-setup"`, `date: 2026-06-10`, `description`
  (matching `futro-dev.md`, which carries a `date`).

## Post: structure

Format: **deeper technical tour** — a section per layer, ~1500+ words, more
annotated-architecture than colophon. Trade-offs (what was rejected and why)
are **woven into each layer**, not collected in one section. Less of the Q&A
interlocutor gimmick than `how-this-site-ships`, but the same near-monochrome,
plain, link-heavy prose voice.

1. **Intro / thesis** — callback to the site post ("the IaC side I handed off
   to"). The repo is the source of truth; a wiped box rebuilds from it; the
   running host *converges itself from `main`*. Frame: one OVH dedicated box,
   Ubuntu 26.04.
2. **Architecture diagram** — reuse the README's full box-drawing diagram in a
   `<pre>` block.
3. **Provisioning** (one-time) — rescue-mode install lays down mdadm-RAID1 +
   btrfs + bootable Ubuntu, hands off to the one-time push bootstrap; a VM
   harness exercises bootstrap → converge → idempotence end-to-end.
   *Trade-off: mdadm under btrfs, not btrfs-raid1 — boots degraded unattended
   after a disk death.*
4. **Convergence** (the spine) — `ansible-pull` on a ~30-min systemd timer
   pulls `main`, runs `site.yml`, decrypts secrets with the on-box age key.
   Merged commits *are* the deploy — no push-to-deploy in steady state.
   Pre-converge btrfs snapshots make a bad change a rollback, not an outage;
   convergence failures alert via ntfy.
   *Trade-off: pull over push — the box owns its state and heals drift on a
   timer; no workstation must be up or trusted to deploy.*
5. **Stacks / isolation** — rootless Podman, one unprivileged user per stack,
   workloads as systemd-supervised Quadlet units (health checks, resource
   limits, dropped caps). No stack can reach another's runtime.
   *Trade-off: Quadlet over Compose/Kubernetes — systemd is the supervisor; ten
   stacks on one box don't need a control plane or a root daemon.*
6. **Storage** — two btrfs filesystems across two HDDs: OS + service state on an
   mdadm-RAID1 mirror; `/srv` snapshotted + restic-backed; a separate `/data`
   span for media + torrents, deliberately *not* backed up, sharing one
   filesystem so reflinks/hardlinks work.
7. **Networking** — two-tier ingress: nftables default-deny (v4+v6), only
   80/443 public; edge Caddy terminates TLS → Authelia forward-auth for
   share-worthy services; a second Caddy on the Tailscale interface fronts
   sensitive UIs; SSH is Tailscale-only; certs via DNS-01 (deSEC).
8. **Secrets** — SOPS + age, committed encrypted, decrypted at converge into
   `0600` per-stack env files; CI rejects any plaintext secret.
   *Trade-off: SOPS + age over an external KMS — no KMS dependency, secrets
   versioned with the code that consumes them.*
9. **Observe** — Caddy/host metrics via a Vector → VictoriaMetrics → Perses
   pipeline; vmalert → ntfy for threshold alerts. Ties back to the site post's
   server-side observability.
10. **Close** — the loop the site post left open is now closed.

Bottom-of-file link-reference definitions (matching the existing post's style)
for: Ansible, ansible-pull, Podman, Quadlet, btrfs, mdadm, SOPS, age, nftables,
Caddy, Authelia, Tailscale, deSEC, restic, Vector, VictoriaMetrics, Perses,
ntfy — plus the repo (`github.com/Sohex/vps-setup`) and its design doc.

## Project page: structure

Mirror `futro-dev.md`'s shape, expanded to **five** bold-led bullets:

- One-line intro sentence.
- **Provision** — rescue-mode installer lays down RAID1 + btrfs + bootable
  Ubuntu; a VM harness proves bootstrap → converge → idempotence.
- **Converge** — `ansible-pull` on a timer; merging a PR to `main` *is* the
  deploy; pre-converge btrfs snapshots make a bad change a rollback.
- **Isolate** — rootless Podman, one unprivileged user per stack, Quadlet units
  under systemd; two-tier nftables/Caddy ingress, SSH tailnet-only.
- **Store** — two btrfs filesystems across two HDDs; `/srv` snapshotted +
  restic-backed, `/data` (media + torrents) sharing one filesystem for
  reflinks.
- **Observe** — Vector → VictoriaMetrics → Perses, alerts via ntfy.
- `Source:` line (`github.com/Sohex/vps-setup`) + link to the new post.

## Guardrails

- **Security disclosure:** nothing operationally sensitive in either page — no
  break-glass password, no Tailscale IPs, no IPMI/Serial-over-LAN hostname, no
  key material or recipient identities. Architecture and rationale only.
- **Source links:** GitHub (`github.com/Sohex/...`), matching the rest of the
  site — not the Forgejo working remote.
- **Page-weight gate (14.5 KB brotli/page):** the reused ASCII diagram is the
  byte risk. After writing, run `./scripts/build.sh` then `./scripts/check.sh`.
  If the post exceeds the gate, fall back to a slimmer convergence-only diagram
  and report it. Also sanity-check the wide `<pre>` doesn't overflow awkwardly
  on mobile.

## Verification

`./scripts/build.sh` then `./scripts/check.sh` must pass: htmltest, lychee
(covers the new external links and the cross-link to the post), and the
page-weight gate. The cross-references edited into `how-this-site-ships.md`
must resolve to the new post.

## Out of scope

- No changes to templates, SCSS, or build scripts.
- No new taxonomies or navigation changes (the site has `disableKinds` for
  taxonomies; posts and projects sections already exist).
