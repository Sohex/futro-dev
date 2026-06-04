---
title: "How this site ships"
date: 2026-06-03
description: "A colophon: Hugo, Typst, a FROM scratch image, and a read-only mount into Caddy."
---

This site is intentionally boring, which took a little work.

The pages are built by [Hugo](https://gohugo.io/) with a hand-written theme —
no CSS framework, no web fonts, and no JavaScript except the dark-mode toggle
in the header. The [resume](/resume/) page and the [PDF copy](/resume.pdf) are
rendered from the same YAML file, the PDF by [Typst](https://typst.app/), so
they can't drift apart.

Every push runs through GitHub Actions: a pinned set of single-binary tools
(Hugo, Typst, `lychee`, `htmltest`) builds and verifies the site, then packs
the output into a `FROM scratch` container image — no shell, no process, just
files. Podman mounts that image read-only into the Caddy container that fronts
this server, so a deploy is an image pull and nothing more.

Analytics are server-side only. Caddy's access logs flow through Vector into
VictoriaMetrics, and a small dashboard shows page views and not much else.
Nothing on this site phones home.

The server is a dedicated box I run myself. There's a good argument that a
personal site belongs on free static hosting — fewer moving parts, someone
else's pager. But the moving parts were already here, already automated, and
already monitored; the marginal cost of self-hosting was a container mount.
Some things are worth doing yourself when yourself is already set up for it.
