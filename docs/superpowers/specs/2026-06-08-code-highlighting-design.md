# Code highlighting design

**Status:** approved (brainstorming)
**Date:** 2026-06-08
**Closes:** [#21 — Enable class-based chroma syntax highlighting (CSP-compatible, conditional per-page)](https://git.int.futro.dev/cfutro/futro-dev/issues/21)
**Related:** [`2026-06-08-csp-per-page-meta-design.md`](2026-06-08-csp-per-page-meta-design.md)

## Goal

Render syntax-highlighted code blocks on posts/projects without breaking the
per-page hash-based CSP, without paying any cost on code-free pages (notably the
tight 10 KiB home budget), and without imported color schemes that fight the
site's typography-first, near-monochrome aesthetic.

## Hard constraint (from #21): class-based chroma only

Chroma has two output modes. Only one is viable here:

| Mode | inline `style=` attrs | new CSP hashes | CSP build guard |
|---|---|---|---|
| **class-based** (`noClasses=false`) | 0 | 0 | passes |
| inline-style (`noClasses=true`) | ~99 | n/a | **fails** |

`scripts/csp-inline.py` ships no `'unsafe-inline'`/`'unsafe-hashes'` and its
`find_violations()` rejects any `style=` attribute. Inline-style chroma stamps a
`style=` on nearly every token span, so the guard correctly fails the build.
**Class-based mode is the only option**; `noClasses=true` is out of scope.

## Decisions

### 1. Hand-written palette, not an imported chroma stylesheet

We do **not** ship a built-in chroma style's colors (no `bw`/`monokai`/`github`
stylesheet checked in). Built-in styles emit fixed hex and cannot follow the site's
light/dark var swap; a two-built-in `[data-theme]`-gated approach would ship the
palette twice (~900–1100 B brotli).

Instead we hand-write `assets/scss/chroma.scss` that maps chroma's token classes
to the site's existing CSS custom properties (`--fg`, `--fg-muted`, `--accent`).
Because the color *values* are `var()` references, the existing light/dark swap
recolors code for free from a single stylesheet — and it is the smallest option
(~150–250 B brotli, est.).

**Class list is harvested, not remembered.** Chroma's token class names are the
one fragile input here. At implementation time, run `hugo gen chromastyles`
(against the hugo pinned in `versions.env`) once as the *authoritative source of the
current token-class set*, then hand-map each Comment / Keyword / String / Number
sub-class to a `var()` per §2. We use `gen chromastyles` only to enumerate selectors
— none of its color values are kept.

### 2. Palette: "Literals in green"

Structure is carried by **weight and italics**; the single green accent is spent
on exactly one semantic group — literal values — so green stays meaningful rather
than smeared across every keyword.

| Token group | Treatment |
|---|---|
| Comments | `--fg-muted`, italic |
| Keywords (incl. type keywords) | `--fg`, `font-weight: 600` |
| Strings (all string sub-classes) | `--accent` |
| Numbers (all numeric sub-classes) | `--accent` |
| Names, operators, punctuation, everything else | inherit `--fg` (no rule) |

**Each "group" is several chroma sub-classes, not one class** — CSS cannot
prefix-match them, so every sub-class must be listed explicitly in the selector. The
indicative sets (confirm against `hugo gen chromastyles` per §1 at implementation):

| Group → treatment | Sub-class selectors |
|---|---|
| Comments → `--fg-muted` italic | `.c .ch .cm .cp .cpf .c1 .cs` |
| Keywords → bold `--fg` | `.k .kc .kd .kn .kp .kr .kt` |
| Strings → `--accent` | `.s .sa .sb .sc .dl .sd .s2 .se .sh .si .sx .sr .s1 .ss` |
| Numbers → `--accent` | `.m .mb .mf .mh .mi .mo .il` |

All selectors are scoped under the chroma wrapper (see §3) so they cannot leak onto
inline `<code>`. Names (`.n .na .nb .nf .nc …`), operators (`.o`), and punctuation
(`.p`) get **no** rule — they inherit the `pre`/`code` `--fg`.

No backgrounds are set by the palette — the existing `pre { background: var(--bg-alt) }`
rule (`assets/scss/main.scss`) already provides the block surface, and
`pre code { background: none; padding: 0 }` already neutralizes inline-code styling
inside `<pre>`.

#### Alternative considered: "Keywords in green" (explicit comparison)

The conventional syntax-highlighting instinct puts the accent on control-flow
**keywords** (`def`/`if`/`import`/`return`) and uses bold `--fg` for function/type
names, `--fg` strings, `--fg-muted` numbers:

| Token group | "Literals in green" (chosen) | "Keywords in green" (alt) |
|---|---|---|
| Keywords | bold `--fg` | `--accent` |
| Strings | `--accent` | `--fg` |
| Numbers | `--accent` | `--fg-muted` |
| Function/type names | `--fg` | bold `--fg` |
| Comments | muted italic | muted italic |

Trade-off: "Keywords in green" reads as more obviously *highlighted*, but keywords
are the most frequent tokens, so green appears everywhere and the accent loses the
specialness it has elsewhere on the site (links, blockquote rules). "Literals in
green" lands the accent on the sparse, high-value tokens the eye hunts for (string
and number values in configs/calls) and conveys structure with weight — a tighter
fit for a typography-first, one-accent site.

**Switching to the alternative is a localized edit to `chroma.scss`** (move
`--accent` from the string/number selectors to the keyword selectors, add bold
`--fg` on the function/type-name selectors, drop numbers to `--fg-muted`); the rest
of this design is unaffected.

### 3. Conditional injection — `<style>` in `<head>`, content forced first

A code-block render hook sets a per-page flag; the head partial emits the chroma
`<style>` only when the flag is set, so code-free pages pay nothing.

`layouts/_default/_markup/render-codeblock.html` — the `Set` line is whitespace-
trimmed so the hook injects no stray text node (Hugo `--minify` strips it in prod
regardless, but the trim keeps `hugo server` output clean too):

```go-html-template
{{- .Page.Store.Set "hasCode" true -}}
{{ highlight (trim .Inner "\n") .Type .Options }}
```

Hugo wraps `highlight` output as `<div class="highlight"><pre class="chroma"><code>…`,
so **`chroma.scss` scopes all token selectors under `.highlight`** (e.g.
`.highlight { .c { … } .k { … } … }`). This is what guarantees the §2 selectors
cannot color inline `<code>`.

**Ordering wrinkle and its resolution.** The `head` partial renders before the
body content, so the page Store flag is still unset when `head` runs. We force
content evaluation in `layouts/baseof.html` *before* the head partial, using the
**assign-and-discard** idiom (a bare `{{ .WordCount }}` would print its integer into
the document — verified — so the discard form is required):

```go-html-template
{{- $_ := .WordCount -}}   {{/* render content now so code-block hooks set hasCode before <head> */}}
{{ partial "head.html" . }}
```

`.WordCount` triggers content rendering (and thus the render hooks) and is cheaper
to read than `.Content`; Hugo caches the render so there is no double pass. This
sets `hasCode`, and `head.html` then reads it. The chroma `<style>` sits in `<head>`
beside the inlined `main.scss` — no FOUC, semantically canonical, all inline styles
co-located.

`layouts/_partials/head.html` (added near the existing `main.scss` `<style>`):

```go-html-template
{{ if .Store.Get "hasCode" }}
{{ $chroma := resources.Get "scss/chroma.scss" | css.Sass | minify }}
<style>{{ $chroma.Content | safeCSS }}</style>
{{ end }}
```

`.Page.Store` (set in the hook) and `.Store` (read in the partial, where `.` is the
page) are the same page-scoped store. The `| safeCSS` mirrors the existing
`main.scss` line at `head.html:22` — `css.Sass` already returns safe CSS, so it is a
no-op kept only for consistency with that line.

**List / section pages.** The flag is set by the page's *own* content render, so a
section `_index.md` whose body contains a fenced code block correctly inlines the
palette on that list page (and a code-free `_index.md`, including the home page,
does not). Same rule, no special case.

### 4. `hugo.toml`

```toml
[markup.highlight]
  codeFences = true
  noClasses = false
```

Other defaults are kept: `lineNos` off (no line-number gutter, so no `.ln`/`.lnt`
classes to style), `guessSyntax` off (untagged fences render as un-tokenized
plaintext rather than mis-guessed colorings).

### 5. Sample post (permanent content + verification artifact)

A new permanent post under `content/posts/` is the first page on the site to carry
code blocks, and doubles as the page the verification gate exercises. It is written
like a real post — proper frontmatter (`title`, `date`, `description`) and short
neutral technical prose — but its subject is incidental; the fenced blocks are the
point. (Until this exists, no built page contains a code block, so nothing exercises
the palette, the conditional `<style>`, or the extra CSP hash.)

The post carries **several language-tagged fenced blocks chosen to collectively hit
every §2 token group** — it is not enough to show one Python block, because a single
lexer won't emit all the comment/keyword/string/number sub-classes the palette
selects. Recommended language set and what each contributes:

Sub-classes below are what the pinned hugo's lexers actually emit (verified by
render), not the theoretical maximum a language *could* produce:

| Fence language | Exercises (sub-classes) |
|---|---|
| `python` | keywords `.k` (`def`/`for`/`return`) `.kn` (`import`), docstring `.s2`, f-string affix/interp `.sa .si`, comments `.c1`, float/int `.mf .mi` |
| `go` | declaration/type keywords `.kd .kt`, block comment `.cm`, backtick string `.s` (plain, not `.sb`), hex `.mh` |
| `bash` | hashbang `.cp`, line comment `.c1`, string `.s2`, int `.mi` |
| `toml` | comment `.c1`, string `.s2`, numbers `.mi .mf` |

The exact languages may shift, but the set must, between them, produce a token of
each of the four styled groups (comment, keyword, string, number) so the
verification light/dark check actually proves the palette. Front-matter `date` uses a real date; this post counts toward the
posts RSS feed (`/posts/index.xml`) like any other.

## CSP interaction: zero script changes

`csp-inline.py` already hashes whatever inline `<style>`/`<script>` blocks each
page actually contains, per page, post-build. A code page gains exactly one extra
`style-src` hash for the chroma block; code-free pages (incl. home) gain nothing.
Per-page hash variance is the entire reason the CSP is a post-build pass — a
conditional inline block is precisely what it already handles. **No change to
`csp-inline.py` or its build ordering.**

## Weight budget

Per-page cost, only on code-bearing pages (brotli -q11; span figures are a
representative sample measured in #21 — they scale with code volume, not a ceiling;
stylesheet estimated for the hand-written palette):

| Component | brotli |
|---|---|
| class-decorated `<code>` spans (vs plain `<pre><code>`) | ~+270 B |
| hand-written `chroma.scss` palette | ~+150–250 B |
| **total, code pages only** | **~+0.5 KiB** |

Home and other code-free pages: **0 B** — *contingent on the assign-and-discard
forced-eval idiom in §3*; the bare `{{ .WordCount }}` form would print digits into
every page and break this. Code pages run against the 16 KiB per-page budget with
ample headroom.

## Architecture summary

| Unit | Responsibility | Depends on |
|---|---|---|
| `hugo.toml [markup.highlight]` | turn on class-based fenced highlighting | — |
| `render-codeblock.html` | highlight each fence; set page `hasCode` flag | `highlight` fn |
| `baseof.html` (forced content eval) | render content before head so the flag is visible | render hook |
| `head.html` (conditional block) | inline `chroma.scss` only when `hasCode` | `assets/scss/chroma.scss` |
| `assets/scss/chroma.scss` | token-class → `var()` palette (theme-aware) | site CSS custom props |
| `content/posts/<slug>.md` | sample post; multi-language fences exercising every token group | the above |
| `csp-inline.py` | hash the extra inline `<style>` per page | unchanged |

## Verification

Run `scripts/build.sh` then `scripts/check.sh`. The new sample post (§5) is the page
under test. Specifically confirm:

- [ ] The sample post renders colored token spans (class-based) for each of its
      language blocks; every §2 group (comment, keyword, string, number) is visibly
      styled at least once; inline-code and code-free pages unchanged.
- [ ] `csp-inline.py` passes (no `style=`-attribute violation); build is green
      under `--panicOnWarning`.
- [ ] In devtools on a code page: **zero CSP violations**; the chroma `<style>`'s
      hash is present in that page's `style-src`.
- [ ] Toggle light/dark on a code page: token colors follow the theme (comments
      muted, strings/numbers green, keywords bold).
- [ ] `check-page-weight.sh` green; home page (`public/index.html`) weight
      unchanged from before this work.

## Out of scope

- `noClasses=true` (inline-style chroma) — incompatible with the CSP design.
- Line numbers / line-number gutter, line highlighting, code-block copy buttons,
  filename captions.
- Highlighting untagged/guessed fences (`guessSyntax` stays off).
