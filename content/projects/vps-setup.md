---
title: "vps-setup"
date: 2026-06-09
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
