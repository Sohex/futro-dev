# futro.dev — Personal Website Design

**Date:** 2026-06-03
**Status:** Approved pending final review

## Purpose

Personal website for Conor Futro at `futro.dev`: contact info and social links, a couple of project spotlights, a blog, and a resume. Clean, minimal, low-maintenance. Self-hosted on his OVH dedicated server as a deliberate tradecraft showcase — the deployment itself is material for a project spotlight or blog post.

## Decisions (settled during brainstorming)

| Decision | Choice | Why |
|---|---|---|
| Generator | Hugo (pinned single binary) | Zero npm toolchain, built-in RSS/sitemap/asset pipeline, near-zero supply-chain surface, user already knows it. Site interactivity is one dark-mode toggle, so Astro/Eleventy's DX advantages don't pay for their dependency weight. |
| Theme | Custom, in-repo, from scratch | Bespoke design; avoids stock-Hugo-theme look. No CSS framework. |
| Design | Clean & minimal ("Zen") | Typography-first, generous whitespace, near-monochrome + one accent. |
| Hosting | Self-hosted on OVH box | Marginal ops cost ~zero (IaC + monitoring already exist); enables zero-JS server-side analytics; reversible (see escape hatch). |
| Serving | Existing Caddy ingress, `file_server` from a podman image mount | No new running service; immutable artifact. |
| Artifact | `FROM scratch` container image containing the built site | Image-based deploy uniform with existing IaC; podman mounts it read-only into the Caddy container. |
| CI | GitHub Actions | Repo on GitHub; hosted runners; no CI→server credentials needed (IaC pulls the image). |
| Analytics | Caddy JSON access logs → Vector → VictoriaMetrics → Perses | Reuses existing observability stack; zero client-side JavaScript. |
| Blog | Markdown posts + listing + RSS from day one; no tags/categories | Aspirationally regular blogger; pipeline is cheap, taxonomy machinery is not yet needed. |
| Resume | HTML page + PDF from one source (`data/resume.yaml`); PDF rendered by Typst | One source of truth, both formats regenerate together; Typst is a pinned single binary. |
| Extras | Dark-mode toggle. No contact form, no third-party analytics, no trackers. | Contact is mailto + social links. |

## Site structure & content model

```
futro-dev/
├── hugo.toml              # site config
├── content/
│   ├── _index.md          # homepage content
│   ├── posts/             # blog posts, one .md each
│   ├── projects/          # project spotlights, one .md each
│   └── resume/            # resume page front matter (content rendered from data/resume.yaml)
├── data/
│   └── resume.yaml        # single source of truth for resume content
├── layouts/               # custom theme (templates, partials)
├── assets/                # SCSS, dark-mode JS
├── static/                # favicon, images
└── docs/superpowers/      # specs and plans
```

**Pages:**

- **Home** — short intro, contact (mailto) + social links, recent posts, featured projects. Contact also repeated in the site footer; no separate contact page.
- **Projects** — listing plus one page per spotlight (start with ~2).
- **Posts** — listing plus one page per post; RSS at `/posts/index.xml`.
- **Resume** — HTML page rendered from `data/resume.yaml` by a Hugo template; link to the PDF generated from the same YAML.
- **404** — custom page.

## Theme & frontend

- **Typography-first:** one well-chosen typeface (or one serif/sans pairing); content column ~65ch; generous whitespace; no hero images, animations, or decoration.
- **Color:** near-monochrome with one restrained accent. Light and dark palettes as CSS custom properties.
- **Dark mode:** follows `prefers-color-scheme` by default; manual toggle persists to `localStorage`. A few inline lines in `<head>` prevent flash-of-wrong-theme. This is the only JavaScript on the site.
- **Fonts:** either zero web fonts (system stack) or one self-hosted variable font — decided when the typeface is chosen. No third-party font CDNs (privacy + no external requests).
- **CSS:** hand-written SCSS via Hugo's asset pipeline — fingerprinted and minified. No framework.
- **Performance bar:** every page well under 100KB transferred; Lighthouse 100s as the acceptance target.

## Build & deploy pipeline

**CI (GitHub Actions), on push to `main`:**

1. Checkout; install pinned Hugo binary (version pinned in the workflow).
2. `hugo --minify` with strict ref checking (broken internal links/refs fail the build).
3. Generate resume PDF from `data/resume.yaml` with Typst (pinned single binary, same ethos as Hugo) into `public/resume/` after the Hugo build. Local `hugo server` won't have the PDF; the resume page links to its CI-built path.
4. Verify: `lychee` link check + HTML validation against the built output.
5. Build `FROM scratch` image: `COPY public/ /site`. Push to GHCR, tagged `latest` and the commit SHA.

**On pull requests:** steps 1–4 only (build + checks, no image push).

**Deploy (IaC side, out of this repo's scope):** podman mounts the artifact image read-only into the existing Caddy container (`--mount type=image,...`); Caddy serves `/site` via `file_server`. Rollout = pull new image + remount, per the IaC's normal pattern.

**The repo's contract ends at "correct scratch image in GHCR."** Caddy site block, mount config, and observability wiring live in the IaC repo; this spec's appendices provide reference shapes to lift over.

**Escape hatch (kept deliberately):** `public/` remains a plain static artifact. Swapping the scratch-image job for a GitHub Pages (or any other) deploy job touches nothing upstream of it.

## Analytics & monitoring

- Caddy emits structured JSON access logs for the site; Vector parses them and emits counters to VictoriaMetrics; a small Perses dashboard shows page views, status codes, and top paths.
- **Cardinality guard:** never put raw `path` or `referrer` into metric labels. Normalize in Vector: count 2xx on known content paths, bucket everything else as `other`; referrers stay in raw logs only.
- No unique-visitor counting — page views and paths suffice. Zero client-side analytics.
- Monitoring: existing system adds an HTTP check for `futro.dev`. No `/healthz` needed unless the existing checks prefer one (trivial Caddy addition if so).

## Testing & error handling

Deliberately thin — it's a static site:

- **Build-time:** Hugo strict mode, `lychee` link check, HTML validation. All run on PRs and on `main`.
- **Runtime:** custom 404 page. No other runtime handling; failure modes are "build broke" (caught in CI) and "box down" (caught by existing monitoring).
- **Visual verification during development:** Claude works headless on the server; visual iteration uses a headless browser (Playwright bundled browsers — **no snap packages on this box**) and/or Conor's eyes on `hugo server`.

## Out of scope

- Tags/categories/taxonomies for posts.
- Contact form.
- Comments, search, newsletter.
- Multi-author or i18n anything.
- The IaC-side changes themselves (Caddy block, podman mount, Vector/VM/Perses wiring) — speced as appendices, applied by Conor in the IaC repo.

## Appendix A — Caddy site block (reference shape)

```caddyfile
futro.dev {
    root * /site
    file_server
    encode gzip zstd

    handle_errors {
        rewrite * /404.html
        file_server
    }

    @immutable path /css/* /js/* /fonts/*   # fingerprinted assets
    header @immutable Cache-Control "public, max-age=31536000, immutable"
    header Cache-Control "public, max-age=300"   # HTML and everything else

    log {
        output ...        # wherever Vector tails on this box
        format json
    }
}
```

(Exact asset paths to match the theme's fingerprinted output; adjust log output to the box's Vector source.)

## Appendix B — Vector transform (reference shape)

```toml
# source: caddy JSON access logs for futro.dev
# transform: remap → normalize, then log_to_metric

# remap (VRL) sketch:
#   status_class = "2xx" | "3xx" | "4xx" | "5xx"
#   page = known content path (/, /posts/<slug>/, /projects/<slug>/, /resume/) else "other"

# log_to_metric sketch:
#   counter: site_requests_total{status_class, page}

# sink: VictoriaMetrics (prometheus remote write or native)
```

(Referrers deliberately excluded from labels; available in raw logs.)
