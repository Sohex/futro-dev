---
title: "futro.dev"
date: 2026-06-03
description: "This website: a static site shipped as an immutable artifact to my own infrastructure."
---

The site you're reading. A deliberately minimal static site that doubles as a
small showcase of how I like to ship software:

- **Build**: Hugo with a custom theme and no JavaScript to speak of; the body
  font is a custom Iosevka build, subset per page and inlined as a data-URI
  `@font-face`. Resume HTML and PDF come from one YAML source, the PDF rendered
  by Typst.
- **Verify**: a pinned single-binary toolchain in CI — link checking, HTML
  validation, a per-page hash-based Content-Security-Policy, and a hard
  page-weight budget (14.5 KB brotli per page, so each fits in one TCP
  congestion window).
- **Ship**: the built site is packed into a `FROM scratch` image and pushed to
  my own registry; CI then fires an ntfy push that triggers the pull. The files
  are served by static-web-server behind Caddy. Deploys are immutable,
  rollbacks are an image tag.
- **Observe**: zero client-side analytics. Caddy access logs flow through
  Vector into VictoriaMetrics, with a realtime Perses dashboard and alerting,
  plus GoAccess for traffic analytics.

Source: [github.com/Sohex/futro-dev](https://github.com/Sohex/futro-dev) —
write-up in [How this site ships](/posts/how-this-site-ships/).
