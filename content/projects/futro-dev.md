---
title: "futro.dev"
date: 2026-06-03
description: "This website: a static site shipped as an immutable artifact to my own infrastructure."
---

The site you're reading. A deliberately minimal static site that doubles as a
small showcase of how I like to ship software:

- **Build**: Hugo with a custom theme; resume HTML and PDF generated from one
  YAML source (Typst renders the PDF).
- **Verify**: pinned single-binary toolchain in CI — link checking, HTML
  validation, and a hard page-weight budget gate (75 KB gzipped per page).
- **Ship**: the built site is packed into a `FROM scratch` container image and
  pushed to GHCR; podman mounts it read-only into the Caddy container on my
  dedicated server. Deploys are immutable, rollbacks are an image tag.
- **Observe**: zero client-side analytics; Caddy access logs flow through
  Vector into VictoriaMetrics with a Perses dashboard.

Source: [github.com/Sohex/futro-dev](https://github.com/Sohex/futro-dev) —
write-up in [How this site ships](/posts/how-this-site-ships/).
