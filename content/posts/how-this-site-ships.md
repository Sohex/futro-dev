---
title: "How this site ships"
date: 2026-06-03
description: "A colophon: Hugo and Typst, a font subset inlined per page, a FROM scratch image, and the pipeline that serves it and observes it."
---

This site is intentionally boring, which took a little work.

Before getting into the how, we should look at the objectives that motivated
everything downstream. I wanted a lean, clean personal site, and as I started
building it out it became clear that this meant two things specifically:

1. Every page is self-contained — all CSS, JS, images, and fonts inlined.
2. Every page smaller than 14.5 KB\* on the wire.

\* Keep this number in mind.

By meeting those two objectives, each brotli-compressed page fits entirely
within the initial TCP congestion window of the originating request.

> Well, what's a TCP congestion window?

When a client connects to a server, the server is permitted to send back some
data before receiving acknowledgement from the client side. Specifically, per
[RFC 6928], this window is generally set at 10 segments totalling a maximum of
14600 B, which 14.5 KB is conveniently just shy of (you can stop keeping it in
mind now).

> Great, but what does that mean for me?

It means that every page on this site is immediately served in full as soon as
the request hits the server. No fancy multiplexing, no CDN, no external
resources. One request, one page, one paint with all the bells and whistles.

> Is that even remotely necessary?

Absolutely not — it was certainly fun to build around as a restriction, though!
The homepage is gated even more tightly at 10 KB so I can claim membership in
the 10 KB club.

> What actually makes up a sub-10 KB webpage?

Prior to the addition of this table the breakdown for this post looked like this:

| Component | On disk | On the wire |
|---|--:|--:|
| Font (per-page `woff2` subset, base64) | 5,877 B | 4,419 B |
| HTML &amp; text | 8,104 B | 3,034 B |
| CSS | 4,413 B | 1,265 B |
| JavaScript (the dark-mode toggle) | 590 B | 239 B |
| CSP `<meta>` | 386 B | 257 B |
| **Total** | **19,370 B** | **9,130 B** |

> That's great, but how is the sausage made?

The pages are built by [Hugo] with a hand-written theme (I assume someone has
given Opus hands at some point). There's no CSS framework, and no JavaScript
except the dark-mode toggle in the header. The body font is a custom [Iosevka]
build, then subset per page down to the exact glyphs that page uses and inlined
as a base64 `@font-face`, so there's never a separate font request. The
[resume](/resume/) page and its [PDF](/resume.pdf) are rendered from the same
YAML file to maintain a single source of truth. The PDF is built by [Typst].

A CI run for the repository is triggered by a push to [Forgejo] or by a merge to
the main branch. It proceeds by installing the pinned toolchain and then
executing the build, a process largely coordinated by a bash script with Python
scripts doing the heavy lifting behind the scenes. First the pages are built out
by Hugo. With those available, the glyphs on each page can be identified and the
font subsetting can run. With that in place, inline CSP hashes can be generated
and added where they're needed. Finally the pages are compressed with brotli to
get them as small as possible. Once that's done, everything gets validated by
[lychee] and [htmltest], along with the hard size-limit gates.

When everything checks out, the static files get copied into a `FROM scratch`
container and the image is pushed to my registry. A scratch container maintains
a strict separation of concerns: the site itself isn't concerned with how it
gets served, it just needs to focus on its real objective — being something
worth serving.

After the image has been pushed, the CI runner sends an [ntfy] push to a
listener which triggers the pull from the IaC side of things (see [how this
server is built] - forthcoming). From there the container is mounted as a
read-only image into a single-binary [static-web-server] container, which serves
the site from behind the [Caddy] reverse proxy.

Nothing on the site phones home, and there's zero client-side analytics or
tracking. The Caddy logs feed two arms of server-side observability. [Vector]
derives basic metrics like request-count, which are pushed to [VictoriaMetrics]
so that [Perses] can give a real-time dashboard and [vmalert] can push to ntfy
if errors start spiking. [GoAccess] also reads the raw logs to generate basic
traffic analytics.

For more on the server this all runs on, and how all the services on it are set
up, see [how this server is built] - forthcoming.

> Wow, that seems excessive. I just push my files to Netlify.

And most people probably should! But this lets me ride my data-sovereignty high
horse while building out an interesting little CI/CD system under some tight
constraints. For me, that's a win.

[Hugo]: https://gohugo.io/
[Iosevka]: https://typeof.net/Iosevka/
[Typst]: https://typst.app/
[Forgejo]: https://forgejo.org/
[RFC 6928]: https://datatracker.ietf.org/doc/html/rfc6928
[lychee]: https://github.com/lycheeverse/lychee
[htmltest]: https://github.com/wjdp/htmltest
[ntfy]: https://ntfy.sh/
[static-web-server]: https://static-web-server.net/
[Caddy]: https://caddyserver.com/
[Vector]: https://vector.dev/
[VictoriaMetrics]: https://victoriametrics.com/
[Perses]: https://perses.dev/
[vmalert]: https://docs.victoriametrics.com/vmalert/
[GoAccess]: https://goaccess.io/
