# How this server is built — post + project page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "How this server is built" post (a deeper technical tour of the `vps-setup` IaC repo) and a `vps-setup` project page to futro.dev, and wire the two existing "forthcoming" references in `how-this-site-ships` to the new post.

**Architecture:** Two new Hugo content files (`content/posts/`, `content/projects/`) plus a small edit to one existing post. Pure content — no templates, SCSS, or build-script changes. The full prose is provided verbatim below; execution is: create files → build → verify gates → commit.

**Tech Stack:** Hugo (custom in-repo theme), markdown content, verified by `./scripts/build.sh` + `./scripts/check.sh` (htmltest, lychee, page-weight gate at 14.5 KB brotli/page).

---

## Conventions for this plan

- There are **no unit tests**. The verification at each gate is: Hugo builds with no warnings (`--panicOnWarning`), and `./scripts/check.sh` passes (htmltest + lychee + page-weight). This replaces the usual "write failing test" TDD loop.
- Content files are markdown — use the built-in Read/Write/Edit tools (not Serena), per the project rule that Serena is for code files.
- All prose below is final copy. Paste it exactly. Do not paraphrase or "improve" it during execution; copy edits are a separate review pass.
- **Security:** the copy below deliberately omits the break-glass password, Tailscale IPs, and the IPMI/Serial-over-LAN hostname. Do not add them.

---

## File Structure

| File | Responsibility |
|---|---|
| `content/posts/how-this-server-is-built.md` | The post — deeper technical tour, one section per layer, full ASCII architecture diagram, trade-offs woven in. |
| `content/projects/vps-setup.md` | Project-page entry — five bold-led bullets in the `futro-dev.md` house style. |
| `content/posts/how-this-site-ships.md` | Edit only: convert two `[how this server is built] - forthcoming` mentions into live links to the new post. |

---

## Task 1: Create the post

**Files:**
- Create: `content/posts/how-this-server-is-built.md`

- [ ] **Step 1: Write the post file**

Create `content/posts/how-this-server-is-built.md` with exactly this content:

````markdown
---
title: "How this server is built"
date: 2026-06-10
description: "A companion to the site colophon: how the box behind futro.dev rebuilds itself from a git repo — provisioning, self-convergence, rootless-Podman stacks, btrfs, and a two-tier network."
---

My last post ended on a promissory note. The site is shipped as an immutable
image to "the IaC side of things," and I said I'd explain that side later. This
is later.

Everything about the server that serves this site lives in one git repository,
`vps-setup`. The repository is the source of truth in the strongest sense I
could manage: a wiped box rebuilds from it, and — more interestingly — the
running box keeps *itself* in sync with it. There is no deploy script I run. I
merge a pull request, and within half an hour the server has reshaped itself to
match.

The box is a single OVH dedicated server running Ubuntu 26.04, with two 2 TB
spinning disks. On it sits a small estate of personal services — authentication,
a password manager, media streaming, torrenting, a container registry,
observability, a self-hosted dependency-update bot — each walled off from the
others. Here's the whole thing at a glance:

```
              ┌─────────────────────────────────────────────┐
 edit → PR →  │ git repo, branch main                       │
              └──────────────────┬──────────────────────────┘
                                 │ ansible-pull (systemd timer, ~30 min)
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ OVH dedicated box — Ubuntu 26.04                                    │
│                                                                     │
│  internet ─► :80/:443 edge Caddy ─► Authelia ─► public services     │
│              (only open ports)      (jellyfin, navidrome, auth)     │
│  tailnet ──► proxy Caddy on the Tailscale iface ─► private UIs      │
│              (*arr, flood, metrics, vault, … — *.int.futro.dev)     │
│                                                                     │
│  rootless Podman stacks — Quadlet units, one unprivileged user each │
│    edge  dns  proxy  media  downloads  vault  observ  cicd  …       │
│                                                                     │
│  storage   md0 (mdadm RAID1 + btrfs): / , /srv , container roots    │
│            /data (separate btrfs span): media + torrents            │
└─────────────────────────────────────────────────────────────────────┘
```

## Provisioning happens once

The very first step is the only one I do by hand, and even then barely. The box
boots into OVH's rescue mode, I run an install script, and it lays down the disk
layout — an [mdadm] RAID1 mirror with [btrfs] on top — and a bootable Ubuntu,
then hands off to a one-time bootstrap.

The disk choice is the first deliberate trade-off. btrfs can do its own RAID1,
so putting mdadm underneath it looks redundant. But btrfs-raid1 won't promise to
boot unattended on a degraded mirror, and a box that won't come back up on its
own after a single disk dies is no good to me. mdadm will boot degraded; btrfs
rides on top of the mirror and keeps the parts I actually wanted from it —
snapshots, compression, send/receive.

Because provisioning is the one step I can't easily repeat against the real box,
it gets a VM harness: a single `make` target boots a throwaway VM and runs the
whole sequence — bootstrap, converge, then converge *again* to prove the second
run changes nothing. Idempotence isn't a nicety here; it's the property the
entire model rests on.

## The box converges itself

Here's the spine. The host runs [`ansible-pull`][ansible] on a systemd timer,
roughly every thirty minutes. Each tick it pulls `main`, runs the Ansible
playbook against itself, and decrypts whatever secrets it needs with an age key
that lives only on the box. That's the whole deploy mechanism. Merged commits on
`main` *are* the deployment; there is no push-to-deploy in steady state, and no
workstation that has to be powered on or trusted for a change to land.

I like this for a single-operator box because it inverts who is responsible. The
server owns its own state and heals drift on a schedule, rather than waiting for
me to remember to push. The cost is latency — a change isn't live the instant I
merge — and the loss of that satisfying *deploying… done* moment. For a personal
server I'll take the resilience trade every time.

The obvious worry with "the box reconfigures itself from a branch" is that a bad
commit reconfigures it into a brick. Two things guard against that. Before each
converge, btrfs snapshots the OS and service subvolumes, so a bad change is a
rollback rather than an outage post-mortem. And if a converge fails outright, it
shouts: every alert on this box, this one included, lands in [ntfy] on my phone.

## One user per service

Every service group — the repo calls them stacks — runs as a set of rootless
[Podman] containers under its own unprivileged Linux user. The media stack can't
see the password manager's containers, files, or runtime; they're separated by
user, namespace, and network. Each workload is a [Quadlet] unit, which is to say
systemd is the supervisor: it does the health checks, the restart-on-failure,
the resource limits, the dependency ordering.

This is where I declined to reach for the usual tools. Docker Compose wants a
daemon running as root; Kubernetes wants a control plane. Ten stacks on one box
need neither. Quadlet lets systemd — already running, already supervising
everything else on the machine — be the orchestrator, with no root daemon and
nothing extra to keep alive. The containers themselves are rootless and
daemonless, run with dropped capabilities and `NoNewPrivileges`.

## Two filesystems, on purpose

There are two btrfs filesystems spread across the two disks. The first is the
mdadm mirror from provisioning: it holds the OS and all service state. Service
state lives under `/srv`, which is snapshotted and backed up off-box with
[restic]. The second is a separate span for bulk data — media and torrents —
mounted at `/data`, and deliberately *not* backed up. I can re-acquire a film; I
can't re-acquire my password vault.

Media and torrents share that one `/data` filesystem on purpose, so the library
manager and the torrent client can hardlink and reflink between downloads and
the library instead of copying. A file grabbed and then imported costs one copy
on disk, not two.

## Two front doors

Nothing reaches the box from the public internet except on ports 80 and 443. The
firewall is [nftables], default-deny, for both IPv4 and IPv6. SSH isn't on that
list — it's reachable only over [Tailscale], so the public internet can't even
knock.

Behind those two open ports sits an edge [Caddy] that terminates TLS and hands
every request to [Authelia] for forward authentication before it reaches
anything. Only the genuinely share-worthy services live out here. Everything
sensitive — the library UIs, dashboards, the vault's admin — sits behind a
*second* Caddy bound to the Tailscale interface, reachable only by machines on
my tailnet. Membership of the tailnet is the auth gate there, and those names
never appear in public DNS. Certificates for both tiers come via DNS-01 through
[deSEC], so nothing needs a public-facing ACME challenge.

## Secrets travel with the code

The services need secrets, and the secrets live in the same repository as
everything else — committed, but encrypted, with [SOPS] and [age]. The box
decrypts them at converge into per-stack environment files locked to `0600`,
using its own on-box key. A pre-commit hook and CI both refuse to let a plaintext
secret through.

I considered an external secrets manager and decided against the dependency. A
KMS or a Vault server is one more thing that has to be up, reachable, and itself
managed, just for the box to be able to start its own services. With SOPS the
secret is versioned alongside the code that consumes it, and the only thing the
box needs in order to decrypt is a key it already holds.

## Watching it

The site post described the server-side observability for the website; the same
machinery watches the box itself. Host and per-container metrics flow through
[Vector] into [VictoriaMetrics], and [Perses] renders the dashboards. A
companion, vmalert, evaluates threshold rules and — like every other alert here
— pushes to ntfy when something needs my attention. There is one alert sink, and
it's my phone.

## Closing the loop

So that's the other half. The website builds itself into an image and pushes it
to a registry; the server pulls `main`, rebuilds itself to match, and mounts that
image behind its reverse proxy. Two repositories, each ignorant of the other's
internals, meeting at a registry tag and an ntfy ping.

Is running your own dedicated server to host a static site a reasonable thing to
do? Still no. But the box now rebuilds from a git history I can read, and that
was the whole point.

The repository — including the design doc with everything I considered and
deliberately rejected — is at [github.com/Sohex/vps-setup].

[mdadm]: https://en.wikipedia.org/wiki/Mdadm
[btrfs]: https://btrfs.readthedocs.io/
[ansible]: https://docs.ansible.com/ansible/latest/cli/ansible-pull.html
[ntfy]: https://ntfy.sh/
[Podman]: https://podman.io/
[Quadlet]: https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html
[restic]: https://restic.net/
[nftables]: https://nftables.org/
[Tailscale]: https://tailscale.com/
[Caddy]: https://caddyserver.com/
[Authelia]: https://www.authelia.com/
[deSEC]: https://desec.io/
[SOPS]: https://github.com/getsops/sops
[age]: https://github.com/FiloSottile/age
[Vector]: https://vector.dev/
[VictoriaMetrics]: https://victoriametrics.com/
[Perses]: https://perses.dev/
[github.com/Sohex/vps-setup]: https://github.com/Sohex/vps-setup
````

- [ ] **Step 2: Build and verify the post renders with no Hugo warnings**

Run: `./scripts/build.sh`
Expected: build completes; no panic. The post appears at `public/posts/how-this-server-is-built/index.html`.

- [ ] **Step 3: Commit**

```bash
git add content/posts/how-this-server-is-built.md
git commit -m "$(cat <<'EOF'
content: add "How this server is built" post

Companion to how-this-site-ships: a technical tour of the vps-setup IaC repo.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Create the project page

**Files:**
- Create: `content/projects/vps-setup.md`

- [ ] **Step 1: Write the project file**

Create `content/projects/vps-setup.md` with exactly this content:

```markdown
---
title: "vps-setup"
date: 2026-06-10
description: "Infrastructure-as-code for the dedicated server behind futro.dev — a box that rebuilds itself from a git repo."
---

The single OVH dedicated server that hosts this site, defined entirely in one
git repository. A wiped box rebuilds from it, and the running host converges
itself from `main` — merging a pull request is the deploy.

- **Provision**: a rescue-mode installer lays down an mdadm-RAID1 + btrfs disk
  layout and a bootable Ubuntu, then hands off to a one-time bootstrap. A
  throwaway-VM harness proves the whole bootstrap → converge → idempotence
  sequence before it touches the real box.
- **Converge**: the host runs `ansible-pull` on a ~30-minute systemd timer —
  there's no push-to-deploy. Merged commits on `main` are what ship; a
  pre-converge btrfs snapshot turns a bad change into a rollback, not an outage.
- **Isolate**: every service runs as rootless Podman Quadlet units under its own
  unprivileged user, supervised by systemd — no root daemon, no orchestrator.
  Ingress is two-tier: nftables default-deny with only 80/443 public, a public
  Caddy behind Authelia, and a second Caddy on the tailnet for everything
  sensitive. SSH is Tailscale-only.
- **Store**: two btrfs filesystems across two disks — OS and service state on a
  RAID1 mirror (`/srv` snapshotted and restic-backed), with media and torrents
  sharing a separate `/data` span so reflinks and hardlinks work.
- **Observe**: host and container metrics flow Vector → VictoriaMetrics →
  Perses, with threshold alerts routed through ntfy.

Source: [github.com/Sohex/vps-setup](https://github.com/Sohex/vps-setup) —
write-up in [How this server is built](/posts/how-this-server-is-built/).
```

- [ ] **Step 2: Build and verify the project page renders**

Run: `./scripts/build.sh`
Expected: build completes; no panic. Page at `public/projects/vps-setup/index.html`; the in-site link to `/posts/how-this-server-is-built/` resolves (that post exists from Task 1).

- [ ] **Step 3: Commit**

```bash
git add content/projects/vps-setup.md
git commit -m "$(cat <<'EOF'
content: add vps-setup project page

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire the cross-references in the existing post

**Files:**
- Modify: `content/posts/how-this-site-ships.md` (two occurrences of `[how this server is built] - forthcoming`)

- [ ] **Step 1: Replace both "forthcoming" mentions with live links**

In `content/posts/how-this-site-ships.md`, both occurrences read:

```
[how this server is built] - forthcoming
```

Replace **both** (replace-all) with:

```
[how this server is built](/posts/how-this-server-is-built/)
```

Context for confirmation — the two sites are:
1. `…triggers the pull from the IaC side of things (see [how this server is built] - forthcoming).`
2. `For more on the server this all runs on, and how all the services on it are set up, see [how this server is built] - forthcoming.`

After the edit they become:
1. `…triggers the pull from the IaC side of things (see [how this server is built](/posts/how-this-server-is-built/)).`
2. `For more on the server this all runs on, and how all the services on it are set up, see [how this server is built](/posts/how-this-server-is-built/).`

- [ ] **Step 2: Build and verify**

Run: `./scripts/build.sh`
Expected: build completes; no panic. The two links in `public/posts/how-this-site-ships/index.html` now point to `/posts/how-this-server-is-built/`.

- [ ] **Step 3: Commit**

```bash
git add content/posts/how-this-site-ships.md
git commit -m "$(cat <<'EOF'
content: link how-this-site-ships to the new server post

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Full verification gate (and page-weight fallback)

**Files:** none (verification only, plus a conditional edit)

- [ ] **Step 1: Run the full build**

Run: `./scripts/build.sh`
Expected: clean build, no Hugo warning/panic.

- [ ] **Step 2: Run all check gates**

Run: `./scripts/check.sh`
Expected: PASS — htmltest (no broken internal refs), lychee (the new external links above and the in-site cross-links all resolve), and `check-page-weight.sh` (every page ≤ 14500 bytes brotli; home ≤ 10 KiB).

- [ ] **Step 3: If — and only if — the page-weight gate fails on `how-this-server-is-built`**

The reused ASCII diagram is the byte risk. If `check-page-weight.sh` reports the new post over 14500 bytes, replace the full diagram block in `content/posts/how-this-server-is-built.md` (the fenced block between the intro and the "## Provisioning happens once" heading) with this slimmer convergence-only diagram:

````markdown
```
   edit → PR → merge to main
                    │
                    ▼   ansible-pull (systemd timer, ~30 min)
        ┌──────────────────────────────┐
        │ OVH box — Ubuntu 26.04        │  pulls main, runs the playbook,
        │ converges itself from main    │  decrypts secrets with its on-box key
        └──────────────────────────────┘
```
````

Then change the sentence that introduces the diagram from
`Here's the whole thing at a glance:` to
`Here's the shape of it:`
(the full box diagram was a "whole thing at a glance"; the slim one isn't).

Re-run `./scripts/build.sh && ./scripts/check.sh` and confirm the gate passes. If it still fails, stop and report the measured byte counts rather than trimming prose blindly.

- [ ] **Step 4: Commit (only if Step 3 changed anything)**

```bash
git add content/posts/how-this-server-is-built.md
git commit -m "$(cat <<'EOF'
content: slim server-post diagram to fit page-weight gate

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: Report**

State plainly: did `check.sh` pass, and which diagram (full or slim) is in the post. If anything was skipped or failed, say so with the output.

---

## Notes for the implementer

- **Do not** add a `draft:` key to either new file — the live `how-this-site-ships.md` and `futro-dev.md` omit it, and `draft: true` from the archetype would hide the page.
- **Do not** open a PR or push unless the user asks — this plan ends at a clean local branch with passing gates.
- If `hugo server` is used for a quick look, remember the per-page font subset only exists after `build.sh`; judge layout against the built `public/`, not the dev server.
