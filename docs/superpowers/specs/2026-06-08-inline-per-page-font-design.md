# Inline per-page font subset

## Goal

Embed a page-specific webfont subset directly into each HTML page as a base64 `data:` URI, so every page is a single self-contained response (inlined CSS + JS + font) with zero subresource requests. This replaces the current scheme of one site-wide subset served as a separate, content-hashed `/fonts/*.woff2` file referenced via `<link rel="preload">` and a shared `@font-face`.

The change is motivated by two things:

1. **Size.** A per-page subset covers only the glyphs that page actually renders (~3.3 KiB woff2 on the home page, ~3.8 KiB on a post) versus the ~6.6 KiB site-wide subset every page shares today.
2. **A preload-scheduling bug** (`Sohex/vps-setup#82`): Zen Browser — and vanilla Firefox on the owner's laptop — defer processing of `<head>` `<link>` elements until after `DOMContentLoaded`, leaving a ~430 ms gap before the preloaded font starts downloading. The markup is correct and stock Chrome/Firefox honor it; this is a client-side scheduling quirk, not a markup bug. Inlining removes the `<link>` entirely, so there is nothing to defer.

**Trade-off accepted:** today's font is content-hashed and served `immutable` — fetched once, then cached across every page and across deploys. Inlining duplicates the font bytes into every HTML response, and HTML is not `immutable`-cached, so a multi-page session re-sends a (smaller, per-page) font on each navigation. For a ~7-page site at ~3–4 KiB/page this is the right trade — the `#82` fix and per-page minimalism outweigh the repeat-visit byte cost — but it is a real reversal of the caching story, not a pure win.

## Current context

- `scripts/build.sh` runs after Hugo: it calls `scripts/font-codepoints.py public` to collect the union of all rendered glyphs, subsets `tools/font/masters/iosevka-custom-regular.ttf` to one woff2, content-hashes the filename, `mv`s it to `public/fonts/`, then `sed`-rewrites the stable token `/fonts/iosevka-custom.woff2` to the hashed name across every `*.html`. Two guards: the codepoint floor must contain `◐`, and the rewritten token must appear in `public/index.html`.
- `layouts/_partials/head.html:7` carries `<link rel="preload" href="/fonts/iosevka-custom.woff2" as="font" type="font/woff2" crossorigin>`.
- `assets/scss/main.scss:3-9` defines the `@font-face` (`font-family: "Iosevka Custom"`, `font-display: swap`, `src: url("/fonts/iosevka-custom.woff2")`). The SCSS is fingerprinted and inlined into every page by Hugo. The `font-family` is used on body and code elements (`main.scss:42`, `:117`).
- `scripts/font-codepoints.py` strips `<script>/<style>` bodies and tags, HTML-unescapes the remaining text, and adds an ASCII + design-punctuation floor. It is also used for manual coverage checks outside the build.
- `scripts/check-page-weight.sh` sums the gzipped size of every `*.css`/`*.js`/`*.woff2` in `public` as a shared bucket, then asserts `page_gz + shared <= 76800` (75 KiB) for each `*.html`. CSS and JS are inlined into the HTML, so today the shared bucket is effectively just the one woff2.
- The site has **no client-side-generated text**: `assets/js/theme.js` only flips `aria-pressed`; the `◐` toggle glyph is in static HTML (`layouts/_partials/header.html:7`). Therefore per-page extraction from the rendered HTML captures everything that actually renders, and the ASCII floor in today's build is purely defensive future-proofing.

## Design

### Coverage

Each page's subset covers **exactly the glyphs rendered on that page** (the output of the same strip/unescape extraction used today), with **no** ASCII safety floor. This is safe because nothing on the site generates text client-side; `◐` is captured because it is static HTML present on every page via the header.

Trade-off accepted: if a future feature injects text via JS, that text would render as tofu until `build.sh` is re-run. No such feature exists today.

### Per-page injection

A new `scripts/font-inline.py` replaces the font block of `build.sh`. For each `public/**/*.html`:

1. Extract the page's codepoints using the same strip/unescape logic as `font-codepoints.py`.
2. **Reload the master TTF for this page** — `TTFont(master)` (or `copy.deepcopy` of a cached parse). `Subsetter.subset()` mutates the `TTFont` in place and destroys it for subsequent pages, so the master must be re-parsed per page. Reloading all pages costs ~0.5 s total, so there is no "load once" optimization.
3. Subset the master to those glyphs in memory with no OpenType features and no layout closure (matching today's `--layout-features='' --no-layout-closure`).
4. **Set `font.flavor = "woff2"` on the `TTFont` object before `save()`** — `Options.flavor` is honored only by the `fontTools.subset` CLI, not by the in-memory `TTFont.save()`. Setting `Options.flavor` alone silently emits raw, uncompressed SFNT (verified: `\x00\x01\x00\x00`, ~1.4 KiB) instead of woff2 (`wOF2`, ~0.8 KiB). Save to a `BytesIO`.
5. Base64-encode the woff2 bytes and build `data:font/woff2;base64,<b64>`.
6. Inject `<style>@font-face{font-family:"Iosevka Custom";font-style:normal;font-weight:400;font-display:swap;src:url(<data-uri>) format("woff2")}</style>` immediately before `</head>` (i.e. after the inlined `main.scss` `<style>`; `@font-face` ordering relative to the SCSS does not matter).

Injection is done in Python, not `sed`: base64 contains `/` and `+`, which would break a `sed` replacement. `font-display: swap` is retained — harmless, and it covers the sub-millisecond window before the embedded bytes decode.

**Scope of injection:** only `public/**/*.html` is processed. XML outputs (`posts/index.xml` RSS, `sitemap.xml`) carry no font and are explicitly out of scope — the glob must not be broadened to them. `public/404.html` *is* in scope and gets its own subset (Caddy serves it as the error page); it is one of the "self-contained" pages even though it is never reached by normal navigation.

### Guards

The guards must validate the **payload**, not just the label, because the two API traps above (SFNT-mislabeled-as-woff2, and pages 2..N rendering tofu from a mutated master) would both pass a naive string check while `index.html` still looked fine. `font-inline.py` fails the build loudly if, **for every** processed page:

- The emitted subset bytes do not start with the `wOF2` magic (catches the `font.flavor` trap).
- Round-trip-loading the emitted subset (`TTFont(BytesIO(...))`) yields a glyph count that is not plausible — at minimum `> 1`, and not less than the page's distinct codepoint count (catches the in-place-mutation trap, where later pages collapse to 1 glyph).
- The injected `data:font/woff2;base64,` string is not present in the page after injection.

Plus the existing sanity check: `public/index.html`'s extracted glyph set must contain `◐`.

### File changes

- **`scripts/build.sh`** — replace the font block (subset, hash, `mv`, `sed` rewrite, both guards, `public/fonts` creation) with a single call to `font-inline.py public`. `FONT_PYTHON` is reused.
- **`scripts/font-inline.py`** (new) — the loop and guards above.
- **`scripts/font-codepoints.py`** — unchanged (still used for manual coverage checks). `font-inline.py` must **import** its extraction function rather than copy the regex, so the strip/unescape logic cannot drift between the two scripts (the build guard depends on both extracting identically). This may require factoring the extraction into a small importable function in `font-codepoints.py`.
- **`layouts/_partials/head.html:7`** — delete the preload `<link>`.
- **`assets/scss/main.scss:3-9`** — remove the `@font-face` block. The `font-family` usages on body/code are untouched.
- **`scripts/check-page-weight.sh`** — no change. The `*.woff2` glob now matches nothing (shared font bucket → 0); each page's inlined font is counted within its HTML. The assertion stays correct.

What is explicitly **not** changed: the Caddy `Link`-header / 103 Early-Hints mitigations sketched in `#82` are made moot by inlining and are not implemented. The IaC repo's `/fonts/` serving becomes dead config — harmless, and out of this repo's scope. One caveat to confirm out-of-band (not blocking this repo): if the IaC Caddy ever emits a `Link: </fonts/...>; rel=preload` response header, it must be removed — after this change it would point at a never-built path and re-trigger a failed preload.

**Future CSP note:** the site has no Content-Security-Policy today. If one is ever added, it must include `font-src data:`, otherwise the inlined fonts are blocked. This is a property of the "self-contained `data:` response" approach worth recording, not a change to make now.

## Verification

- `scripts/build.sh` then `scripts/check.sh` pass clean (htmltest, lychee, page-weight).
- Page-weight: every page must clear the 75 KiB gate. The resume page has the richest glyph set, so it is verified explicitly rather than assumed. Getting the resume page under the informal 10 KiB/page goal is a nice-to-have, **not** a gate; all other pages are expected to land well under 10 KiB gzipped.
- **Size-regression check:** `font-inline.py` logs each page's emitted woff2 size to build output. Each page's inlined font must be smaller than the current ~6.7 KiB shared baseline it replaces — this is the cheap canary for the SFNT-mislabeling trap (an SFNT payload gzips ~29% larger and would show up immediately here even if the 75 KiB gate still passed).
- The `#82` fix is **manually verified by the owner** — Playwright cannot drive Zen and the vanilla-Firefox repro is environment-specific. After the build, open a page in Zen / the affected Firefox and confirm the font paints at first paint with no FOUT. This is a manual gate, not a claim made by the build.
