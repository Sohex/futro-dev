# futro.dev — Personal Website Design

**Date:** 2026-06-03
**Status:** Approved (spec-plan-reviewer findings applied 2026-06-03)

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
| Resume | HTML page + PDF from one source (`data/resume.yaml`); PDF rendered by Typst, which reads the YAML directly via its built-in `yaml()` loader (no intermediate transform) | One source of truth, both formats regenerate together; Typst is a pinned single binary. |
| Toolchain ethos | Build/check tools are single pinned binaries (Hugo, Typst, lychee, htmltest) | No npm or JVM anywhere in the build path; minimal supply-chain surface; toolchain still works unchanged in years. |
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
└── docs/superpowers/      # specs and plans (not site source; ignored by Hugo)
```

**Pages:**

- **Home** — short intro, contact (mailto) + social links, recent posts, featured projects. Contact also repeated in the site footer; no separate contact page.
- **Projects** — listing plus one page per spotlight (start with ~2).
- **Posts** — listing plus one page per post. **Canonical RSS feed is the posts section feed at `/posts/index.xml`**; `<head>` autodiscovery on all pages points there; the site-level `/index.xml` is disabled.
- **Resume** — HTML page at `/resume/` rendered from `data/resume.yaml` by a Hugo template; links to the PDF at the literal path **`/resume.pdf`** (site root — generated from the same YAML; see Build step 3).
- **404** — custom page. The theme must include a `404.html` layout — Caddy's `handle_errors` (Appendix A) depends on `public/404.html` existing.

## Theme & frontend

- **Typography-first:** one well-chosen typeface (or one serif/sans pairing); content column ~65ch; generous whitespace; no hero images, animations, or decoration.
- **Color:** near-monochrome with one restrained accent. Light and dark palettes as CSS custom properties.
- **Dark mode:** follows `prefers-color-scheme` by default; manual toggle persists to `localStorage`. A few inline lines in `<head>` prevent flash-of-wrong-theme. This is the only JavaScript on the site.
- **Fonts:** either zero web fonts (system stack) or one self-hosted variable font — decided when the typeface is chosen. No third-party font CDNs (privacy + no external requests). **Note for the plan:** typeface choice is an early, blocking task — a variable font costs ~20–40 KB against the page-weight budget and shapes the CSS; it is not a cosmetic late step.
- **CSS:** hand-written SCSS via Hugo's asset pipeline — fingerprinted and minified. No framework.
- **Performance bars:**
  - **Page weight (CI-gated):** each page's total gzip-compressed transfer (HTML + CSS + JS + fonts; images excluded but used sparingly) ≤ 75 KB, asserted by a small shell script in CI against the built `public/`. Compressed units chosen deliberately to match Caddy's on-the-fly `encode` (Appendix A).
  - **Lighthouse (development bar, not CI-gated):** all four categories (Performance, Accessibility, Best Practices, SEO) = 100 on the mobile profile, verified during development via the headless browser. Not gated in CI — gating would pull the npm Lighthouse toolchain permanently into the build path, against the toolchain ethos.

## Build & deploy pipeline

**CI (GitHub Actions), on push to `main`:**

1. Checkout; install pinned Hugo binary (version pinned in the workflow).
2. Build: `hugo --minify --panicOnWarning`, with `refLinksErrorLevel = "ERROR"` in `hugo.toml` so broken internal links/refs fail the build (`--minify` alone does not).
3. Generate resume PDF with Typst (pinned single binary, same ethos as Hugo): the Typst template loads `data/resume.yaml` directly via Typst's built-in `yaml()` function — no intermediate transform — and writes `public/resume.pdf` after the Hugo build. Local `hugo server` won't have the PDF; the resume page links to the literal `/resume.pdf`. *(De-risk: the implementation plan's first task is a small spike confirming Typst's `yaml()` handles the resume schema.)*
4. Verify, strictly after step 3 so the PDF link is covered: `lychee` link check + `htmltest` HTML validation (single pinned Go binary — no npm/JVM validators) against the built `public/`, plus the page-weight gate (see Performance bars).
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

- **Build-time:** Hugo strict refs (`refLinksErrorLevel = ERROR` + `--panicOnWarning`), `lychee` link check, `htmltest` validation, page-weight gate. All run on PRs and on `main`.
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
