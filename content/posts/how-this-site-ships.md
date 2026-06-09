---
title: "How this site ships"
date: 2026-06-03
description: "A colophon: Hugo and Typst, a font subset inlined per page, a FROM scratch image, and the self-hosted pipeline that serves and watches it."
---

This site is intentionally boring, which took a little work.

The pages are built by [Hugo](https://gohugo.io/) with a hand-written theme —
no CSS framework, and no JavaScript except the dark-mode toggle in the header.
The body font is a custom [Iosevka](https://typeof.net/Iosevka/) build, then
subset per page down to the exact glyphs that page uses and inlined as a
base64 `@font-face`, so every page is one self-contained response with no
separate font request. The [resume](/resume/) page and its [PDF](/resume.pdf)
are rendered from the same YAML file — the PDF by [Typst](https://typst.app/) —
so they can't drift apart.

Two budgets keep it honest. Every page has to fit in 14.5 KB brotli — one TCP
slow-start window, so the whole page arrives in the first round trip — and the
home page is held tighter still. And the Content-Security-Policy is generated
at build time as a per-page hash of every inline style and script, injected as
a `<meta>` tag, with no `unsafe-inline` anywhere. A build that can't satisfy
either one fails.

Every push runs through CI on my own [Forgejo](https://forgejo.org/): a pinned
set of single-binary tools (Hugo, Typst, `lychee`, `htmltest`) builds the site
and checks every link, the markup, and the page weight. The output is packed
into a `FROM scratch` image — no shell, no process, just files — and pushed to
my own registry. CI then sends an [ntfy](https://ntfy.sh/) push that triggers
the pull, so a deploy is one notification and an image swap.

On the server those files are served by
[static-web-server](https://static-web-server.net/) behind
[Caddy](https://caddyserver.com/), which terminates TLS out front. Caddy's
access logs are the only telemetry: [Vector](https://vector.dev/) derives
request-count metrics from them into VictoriaMetrics, a
[Perses](https://perses.dev/) dashboard renders those in realtime, and
`vmalert` raises any alerts back out through the same ntfy.
[GoAccess](https://goaccess.io/) reads the raw logs for traffic analytics. Nothing on the site phones home;
there is no client-side analytics at all.

The box is a dedicated server I already run. There's a good argument that a
personal site belongs on free static hosting — fewer moving parts, someone
else's pager. But the moving parts were already here, already automated, and
already monitored; the marginal cost of self-hosting was a container image.
Some things are worth doing yourself when yourself is already set up for it.
