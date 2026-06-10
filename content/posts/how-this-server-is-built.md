---
title: "How this server is built"
date: 2026-06-09
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
