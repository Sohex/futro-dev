# Per-page hash-based Content-Security-Policy

## Goal

Ship a strict, hash-based `Content-Security-Policy` on every built page of futro.dev, delivered as a per-page `<meta http-equiv="Content-Security-Policy">` tag. Because the site is fully self-contained — inline CSS, inline JS, and a per-page `data:` font/image set, with **no** external subresource loads — the policy can be maximally strict (`default-src 'none'`) and use **per-block SHA-256 hashes for every inline `<style>` and executable `<script>`**, with **no `'unsafe-inline'` anywhere**.

This resolves `Sohex/vps-setup#98`. That issue assumed the CSP would be a Caddy response header on the public edge, but a single static header cannot carry per-page hashes (the inline `<style>` set varies per page — see below), which would force `style-src 'unsafe-inline'`. Generating the CSP per page in this repo instead keeps it self-contained, hashes styles as well as scripts, and introduces zero cross-repo coupling. The edge Caddy needs **no change**: the existing `security_headers` snippet (HSTS, `X-Content-Type-Options`, `Referrer-Policy`, `X-Frame-Options: SAMEORIGIN`, `Permissions-Policy`) stays as-is and continues to cover framing.

## Current context

### What each page actually loads (verified against `public/`)

- **Two executable inline `<script>` blocks, both static across every page:**
  1. The theme bootstrap in `layouts/_partials/head.html:15-20` (reads `localStorage` on load to set `data-theme` before paint).
  2. `assets/js/theme.js`, inlined via `layouts/baseof.html:11` (`<script>{{ $js.Content | safeJS }}</script>` — wires the toggle button).
- **One `<script type="application/ld+json">`** on the home page only (`head.html:27-34`). This is a data block, **not executed**, and is **not** subject to `script-src` — it must be excluded from hashing.
- **Inline `<style>` blocks (the per-page-varying part):**
  1. The compiled `main.scss`, inlined into every page (`head.html`, `resources.Get "scss/main.scss" | css.Sass | minify`). Static across pages.
  2. The home-page headshot styles in `layouts/index.html:4-30`, which embed the light/dark headshot as `data:image/webp` CSS `mask` URLs. **Home page only.**
  3. A `@font-face` block carrying a **per-page** base64 `data:font/woff2` subset, injected **after Hugo** by `scripts/font-inline.py` (see below). Different bytes on every page.
- **No external resource loads.** `github.com`, `linkedin.com`, `typst.app`, `gohugo.io` appear only as `<a href>` link targets (CSP does not govern navigation). Favicon is an inline `data:image/svg+xml` (`head.html:14`).
- **No `style=` attributes, no `on*=` inline event handlers, no `javascript:` URLs** in the built HTML (verified by grep over `public/`). The toggle is wired entirely through `theme.js`. This is what makes a pure hash policy (no `'unsafe-inline'`) viable.
- The dev server's `<script src="/livereload.js">` exists only under `hugo server`; the production `hugo --minify` build does not emit it, and the CSP step runs only in the production build (`build.sh`), so it is irrelevant.

### The build pipeline

`scripts/build.sh` runs, in order:

1. `hugo --minify --panicOnWarning` → renders HTML into `public/`.
2. `scripts/font-inline.py public` → for each `public/**/*.html`, subsets the master font to that page's glyphs and injects a `<style>@font-face{…data:font/woff2…}</style>` immediately before `</head>`.
3. `typst compile … public/resume.pdf` → the resume PDF (no HTML impact).
4. `scripts/brotli-precompress.py public` → writes quality-11 `.br` siblings of text assets (`.html`, `.css`, `.js`, …) for Caddy/SWS to serve precompressed.

`scripts/font-inline.py` is the model for this work: it globs `public/**/*.html`, reads each page, injects before the first `</head>`, writes back, and **fails the build (`sys.exit`) on any invariant violation** (lost glyph, font bloat over baseline). `scripts/font_common.py:extract_html_chars` shows the existing strip-`<script>`/`<style>`-bodies-then-tags parsing approach used in this repo.

### Why the CSP must be a post-build step, not a Hugo template

A `<meta>` CSP sits in `<head>`, but a hash policy needs the hash of **every** inline block on the page. Two of the three `<style>` sources are unavailable when Hugo renders `<head>`:

- The home-page headshot `<style>` is in the body (`index.html`), rendered **after** `<head>`.
- The `@font-face` `<style>` is injected by `font-inline.py` **after Hugo finishes**.

So the only place that sees the complete, final set of inline blocks is a post-build pass over the rendered HTML. Hashing the **final served bytes** also eliminates any chance of a hash/served-content mismatch from minification or later post-processing.

## Design

### Delivery

A per-page `<meta http-equiv="Content-Security-Policy" content="…">` injected into `<head>`. (`<meta>` cannot express `frame-ancestors`, `report-uri`/`report-to`, or `Content-Security-Policy-Report-Only`; those are addressed under "Deliberately out of scope" below.)

### New step: `scripts/csp-inline.py public`

Added to `scripts/build.sh` **after `font-inline.py` and before `brotli-precompress.py`** — after font-inline so the `@font-face` block is present and gets hashed; before brotli so the `.br` copies include the meta tag. Structurally mirrors `font-inline.py`: glob `public/**/*.html`, process each page, inject before the first `</head>`, write back, fail loudly on any problem.

Per page:

1. **Parse inline blocks from the final HTML.** Extract the exact text content (the bytes between the open and close tags, UTF-8) of:
   - every `<style>…</style>` block → contributes a `style-src` hash;
   - every executable `<script>…</script>` block → contributes a `script-src` hash. A `<script>` is "executable" iff its `type`, lowercased and trimmed, is empty/absent or one of the JavaScript MIME types {`text/javascript`, `application/javascript`, `module`}; any other `type` (notably `application/ld+json`) is **skipped**. Everything-not-in-the-allow-list is treated as non-executable, so an unrecognized future type fails closed (un-hashed) rather than being hashed as script.
   - `<script src=…>` (external) is not expected in production; if encountered, see the guard below.

   **Attribute parsing must handle unquoted values.** `hugo --minify` emits unquoted attributes — verified in the production build: `<script type=application/ld+json>` and `<meta charset=utf-8>`, not the quoted forms. The `type` matcher (and the `charset` anchor in step 4) must accept double-quoted, single-quoted, and bare values, e.g. `type\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))`. A regex assuming `type="…"` would misclassify the minified `ld+json` block as executable.

   **Block-extraction rule.** `<script>`/`<style>` are raw-text elements: the first `</script>`/`</style>` ends the block, exactly as the browser tokenizer does (it does not parse JS/CSS string or comment context). Extract left-to-right, non-overlapping; hash the captured body bytes directly and never re-derive them. The current build was verified to contain no inline script/style body holding a literal `<`, so this is unambiguous today; the rule is stated so a future block that does is handled the same way the browser handles it.
2. **Hash each block** as `'sha256-' + base64(sha256(block_text_bytes))` over the captured body bytes from step 1 — the same bytes the browser will hash when enforcing. (CSP spec: the hash covers the element's text content with no surrounding whitespace trimming beyond what is literally between the tags.)
3. **Assemble the policy** (deduplicate identical hashes — e.g. the two static script hashes recur on every page; the home page adds its headshot style hash):

   ```
   default-src 'none';
   script-src 'sha256-<bootstrap>' 'sha256-<theme.js>';
   style-src 'sha256-<main.css>' 'sha256-<font-face>' ['sha256-<headshot, home only>'];
   img-src 'self' data:;
   font-src data:;
   base-uri 'none';
   form-action 'none'
   ```

4. **Inject** `<meta http-equiv="Content-Security-Policy" content="<policy>">` **immediately after the `<meta charset…>` tag**. (Note: charset is *not* the first head element — in the production build the first element is `<meta name=generator content="Hugo …">`, charset second; the anchor must therefore locate the charset tag, not assume head-position 0. The intervening `generator` meta is unhashed and harmless.) A `<meta>` CSP only governs content parsed *after* it, so it must precede the inline bootstrap script/styles it is meant to cover; anchoring right after `charset` keeps the charset declaration within the first 1024 bytes while putting the policy ahead of every inline block it governs (all of which follow charset). The anchor regex must tolerate the unquoted `charset=utf-8` form (see step 1). The script **fails the build** if a page has no `<meta charset…>` to anchor to.

   After injecting, the script **re-parses the written page and asserts** every hashed block's bytes still hash to a value present in the meta `content`, and that the assembled policy contains no `"` (so the double-quoted `content="…"` attribute cannot be broken out of — CSP hashes are base64 with only `/`/`+`, and no directive text contains a quote, but the invariant is asserted rather than assumed).

### Directive rationale

- **`default-src 'none'`** — deny by default; every needed source is then explicitly granted. Directives that fall back to `default-src` (`connect-src`, `object-src`, `media-src`, `child-src`, `worker-src`, etc.) inherit `'none'`, which is correct: the site makes no network requests, embeds no plugins/media/frames.
- **`script-src` / `style-src` = per-block hashes, no `'unsafe-inline'`.** Hash-based, so injected inline scripts/styles are blocked. (Per spec, the presence of any hash/nonce makes browsers ignore `'unsafe-inline'`, so it is simply omitted.) The `ld+json` block is excluded as non-executable.
- **`img-src 'self' data:`** — `data:` covers the inline favicon (`data:image/svg+xml`) and the home-page headshot (`data:image/webp` via CSS `mask`, governed by `img-src`); `'self'` permits future file-based images in posts (`<img src="/posts/…">`). *(Alternative considered and rejected: `data:` only, forcing all images inline to preserve the self-contained ethos. Rejected as too constraining for future post screenshots; `'self'` is same-origin and low-risk.)*
- **`font-src data:`** — the only fonts are the inlined per-page `data:font/woff2` subsets; no `'self'` needed.
- **`base-uri 'none'`, `form-action 'none'`** — hardening; the site has no `<base>` element and no forms. Blocks base-tag injection and form-action hijacking.
- **Framing** — `X-Frame-Options: SAMEORIGIN`, already set on the edge Caddy (`stacks/edge/config/caddy/Caddyfile.j2`, `security_headers` snippet), remains the clickjacking control. `frame-ancestors` is intentionally omitted because `<meta>` ignores it.

### Build-time safety guard

Because `csp-inline.py` sees the final HTML, it can turn "a future change silently breaks under CSP" into a loud build failure. The script **exits non-zero** (matching `font-inline.py`'s guard pattern) if a page contains any construct that a hash-based, `'unsafe-inline'`-free CSP cannot cover and would therefore block at runtime:

- an inline `style=…` attribute (covered only by `'unsafe-inline'`/`'unsafe-hashes'`, neither of which we ship — and we deliberately do not ship `'unsafe-hashes'`, so the only remediation is removing the attribute from source);
- an `on*=` inline event handler (cannot be hashed);
- a `javascript:` URL (in an `href`/`src`/etc. attribute value);
- an executable `<script src=…>` (would require a host/`'self'` source we deliberately do not grant), or any executable `<script>` whose content the script cannot extract to hash.

**How the guard scans (avoiding false positives/negatives).** The strings `style=`, `onclick=`, `javascript:` legitimately occur inside `<script>` bodies (JS source), `<style>` bodies (CSS), `ld+json` data, and prose/code in post HTML — a naive document-wide grep would spuriously fail the build. So the guard scans **element start-tags only**: it first removes `<script>`/`<style>` bodies and `<!-- -->` comments (the `font_common` strip approach), then inspects the remaining start-tags for (a) an attribute named `style`, (b) any attribute name matching `^on`, (c) any attribute *value* that, after HTML-entity-decoding and whitespace-trimming, begins with `javascript:` (entity-decode first, so `&#106;avascript:` is caught). This is the highest-risk surface in the script and gets its own test fixtures (see Verification).

This guard is the mechanism that makes enforce-mode safe: the build refuses to ship a page its own CSP would break.

### Weight impact (measured)

`csp-inline.py` runs *before* `brotli-precompress.py`, so the meta tag is included in the `.br` siblings and `scripts/check-page-weight.sh` covers it automatically. The real budgets that script enforces are tighter than the 75 KiB ceiling in CLAUDE.md: **16 KiB brotli per page, 10 KiB for the home page**, and because the site inlines all CSS/JS/fonts there are **zero shared assets** — each page's gated weight is just the brotli size of its own HTML.

Measured on the home page (`public/index.html`, with the `@font-face` block inlined, against a real `hugo --minify` build):

| | raw | brotli -q11 |
|---|---:|---:|
| before | 18,866 B | 8,850 B |
| after CSP meta | 19,306 B | 9,126 B |
| **delta** | **+440 B** | **+276 B** |

The meta tag is 440 raw bytes carrying 5 hashes (2 script + 3 style; `ld+json` excluded). The base64 hashes are high-entropy and compress poorly (~63% of raw survives brotli), so the served cost is +276 B. Home is the binding case: **9,126 / 10,240 B → ~1,114 B (≈11%) headroom**. All other pages sit against the looser 16 KiB budget with ample room. Recorded here so a future change that erodes this headroom is a conscious decision.

### Scope assumptions (owner-confirmed)

- **JS is frozen at the single toggle snippet.** No additional executable `<script>` is expected ever; the policy will carry exactly the two static script hashes (bootstrap + `theme.js`). The executable-script classification still fails closed for any unrecognized type, so this is an expectation, not a load-bearing assumption.
- **No new style sources beyond syntax highlighting.** The inline-style set is bounded: `main.css` (global), the home headshot block (home only), the per-page `@font-face`, and — if/when enabled — a conditional chroma block on code pages only. The latter is tracked in issue #21 and needs **no change** to `csp-inline.py`: the per-page post-build hashing already covers whatever blocks each page happens to have. Inline-style chroma (`noClasses=true`) is excluded because it emits `style=` attributes the guard rejects.

### Verification

- **Scope:** only `public/**/*.html` receives the policy. XML/feed outputs (`posts/index.xml`, `sitemap.xml`) and `robots.txt` are intentionally untouched — a `<meta>` CSP is meaningless outside HTML.
- **Build-time:** the guard passes; a `<meta>` CSP is present on every `public/**/*.html` (assertable, e.g. like font-inline's "home page found" check); the post-injection re-parse self-check (step 4) confirms each page's hashes match its blocks.
- **Unit fixtures** for the guard and parser: minified-style unquoted `type=application/ld+json` (skipped), unquoted `charset=utf-8` (anchor found), a body containing the literal strings `style=`/`javascript:` inside a `<script>`/`<style>` (must *not* trip the guard), a real `style=` attribute / `onclick=` / `href=javascript:` / `&#106;avascript:` in a start-tag (must *all* trip the guard).
- **Local browser pass (acceptance gate):** serve the built `public/` and load home, a post, the posts list, projects, resume, **and the 404 page**. Confirm **zero CSP violations** in the devtools console, and that the theme toggle, fonts, and headshot all render. This is the gate before merge — no automated headless check is required for v1, though one may be added later if the repo grows a browser-based test harness.
- **No report-only soak.** `<meta>` cannot deliver `Content-Security-Policy-Report-Only`, and there is no reporting endpoint we would watch. The asset set is fully controlled and enumerated, so the path is: verify locally → ship enforcing.

### Integration points (files touched)

- **New:** `scripts/csp-inline.py` (and, if shared parsing helps, additions to `scripts/font_common.py`).
- **Edit:** `scripts/build.sh` — insert `"$FONT_PYTHON" scripts/csp-inline.py public` between the `font-inline.py` and `brotli-precompress.py` steps. (Reuses the existing Python interpreter; the standard library `hashlib`/`base64` suffice — no new dependency beyond what `FONT_PYTHON` already provides.)
- **Possibly:** `scripts/check.sh` / CI docs, to note the CSP step in the build order. No change to `assets/`, `layouts/`, or Hugo config — the policy is derived from the existing markup, not authored into it.

## Deliberately out of scope

- **No Caddy/vps-setup change.** The existing `security_headers` snippet stays; #98 is closed with a pointer to this work.
- **No `frame-ancestors`, `report-uri`/`report-to`, `report-only`** — all unavailable or pointless via `<meta>` for this site (framing handled by `X-Frame-Options`; no report sink).
- **No `nonce`s** — nonces require per-response server cooperation; hashes are correct for a fully static, pre-rendered site.
- **No CSP during `hugo server` dev** — the step runs only in `build.sh`, so local development is unaffected.

## Risks / trade-offs

- **Content discipline.** Authors must not introduce inline `style=`/`on*=`/`javascript:` or external subresources in posts. The build guard enforces this (fails the build), so the failure mode is loud and pre-deploy, not a silently broken live page.
- **`<meta>` timing.** A `<meta>` CSP only governs content parsed *after* it. If it were injected before `</head>` (as `font-inline.py` does for the font block), the earlier inline bootstrap script and `main.scss` style would be parsed *before* the policy and thus go ungoverned — a silent protection gap, not a breakage. The design therefore anchors the meta immediately after `<meta charset…>` (step 4), ahead of every inline block it must cover (all inline blocks follow charset, even though charset is not itself the first head element). The hashes themselves are page-global (they cover every inline block regardless of position), so meta placement affects only parse-order enforcement, not which blocks are listed.
- **Style-src is hash-pinned to built output.** Any change to `main.scss`, the headshot block, or the font subset changes a hash — but since the hash is computed from the same build that produces the HTML, it is always in sync; there is no manual hash to maintain.
