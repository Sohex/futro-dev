# Code Highlighting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render class-based, CSP-compatible syntax highlighting on code-bearing pages, with a near-monochrome palette that follows the site's light/dark theme and costs zero on code-free pages.

**Architecture:** Hugo emits class-based chroma spans for fenced code (`codeFences=true`, `noClasses=false`). A code-block render hook sets a per-page `hasCode` flag; `baseof.html` forces content evaluation before `<head>` so the flag is visible; `head.html` inlines a hand-written `chroma.scss` palette only when the flag is set. The palette maps chroma token classes to existing CSS custom properties (`--fg`, `--fg-muted`, `--accent`), so the light/dark var swap recolors code for free. The existing post-build `csp-inline.py` hashes the extra inline `<style>` per page with no change.

**Tech Stack:** Hugo v0.162.1 extended (pinned in `versions.env`), hand-written SCSS via Hugo's `css.Sass` pipeline, stdlib Python CSP pass. No npm, no new dependencies.

**Spec:** `docs/superpowers/specs/2026-06-08-code-highlighting-design.md`

**Project testing model:** There are no unit tests for templates/SCSS. Verification is `scripts/build.sh` then `scripts/check.sh`, plus targeted `grep` assertions on the built HTML/CSS in `public/`. Each task below uses a build + `grep` as its "test". `scripts/build.sh` needs a Python venv with `fonttools`+`brotli` on `FONT_PYTHON` (see CLAUDE.md / CI); for template-only checks a bare `hugo --minify --panicOnWarning` is sufficient and is what most steps use.

**Authoritative chroma class list** (harvested from `hugo gen chromastyles` with the pinned hugo; embedded here so no task needs to re-run it):
- Comments: `.c .ch .cm .c1 .cs .cp .cpf`
- Keywords: `.k .kc .kd .kn .kp .kr .kt`
- Strings: `.s .sa .sb .sc .dl .sd .s2 .se .sh .si .sx .sr .s1 .ss`
- Numbers: `.m .mb .mf .mh .mi .il .mo`

Token spans render under `<pre class="chroma">`, so all selectors are scoped under `.chroma` (this also prevents the palette from touching inline `<code>`).

---

## File Structure

| File | Create/Modify | Responsibility |
|---|---|---|
| `content/posts/snippets.md` | Create | Permanent sample post; multi-language fences exercising every token group; the page the verification gate renders |
| `hugo.toml` | Modify (`[markup.highlight]`, line 16) | Turn on class-based fenced highlighting |
| `layouts/_default/_markup/render-codeblock.html` | Create | Highlight each fence; set page `hasCode` flag |
| `layouts/baseof.html` | Modify (before line 3) | Force content render before `<head>` so `hasCode` is visible |
| `layouts/_partials/head.html` | Modify (after line 22) | Inline `chroma.scss` only when `hasCode` is set |
| `assets/scss/chroma.scss` | Create | Token-class → `var()` palette (theme-aware) |

`csp-inline.py` is intentionally untouched.

---

## Task 1: Sample post (the test fixture)

Create the code-bearing page first, so every later task has a concrete page to render and assert against. With highlighting still off, it renders as plain `<pre><code>` — that is the "before" state.

**Files:**
- Create: `content/posts/snippets.md`

- [ ] **Step 1: Write the sample post**

Create `content/posts/snippets.md` with real frontmatter and four language blocks chosen to collectively emit every styled token group. Sub-classes below are what the pinned hugo's lexers actually emit for these exact snippets (verified by render — note bash hashbang is `.cp` not `.ch`, Go backtick tags are plain `.s` not `.sb`, Python docstrings are `.s2` not `.sd`):
- **bash** → comments `.cp` (hashbang) / `.c1`, keywords (`if`/`then`), string `.s2`, int `.mi`
- **python** → keywords `.k` (`def`/`for`/`return`) / `.kn` (`import`), docstring `.s2`, f-string `.sa`+`.si`, comment `.c1`, numbers `.mi`/`.mf`
- **go** → keywords `.kd` (`type`/`const`) / `.kt` (`int`/`uint32`), block comment `.cm`, backtick string `.s`, hex `.mh`
- **toml** → comment `.c1`, string `.s2`, numbers `.mi`/`.mf`

Together these hit every styled group: comments (`.cp`/`.c1`/`.cm`), keywords (`.k`/`.kd`/`.kt`/`.kn`), strings (`.s`/`.s2`/`.si`/`.sa`), numbers (`.mi`/`.mf`/`.mh`).

````markdown
---
title: "A few snippets I reach for"
date: 2026-06-08
description: "A handful of small patterns across shell, Python, Go, and TOML."
---

A grab bag of small things, kept here so the syntax highlighting has something
to chew on and so I stop re-deriving them.

A guard at the top of every shell script:

```bash
#!/usr/bin/env bash
set -euo pipefail

# bail early if a required tool is missing
if ! command -v jq >/dev/null; then
  echo "jq is required" >&2
  exit 1
fi
```

A tiny retry helper in Python:

```python
import time

def retry(fn, attempts=3, base=0.5):
    """Call fn, backing off on failure."""
    for n in range(attempts):
        try:
            return fn()
        except Exception as err:  # noqa: BLE001
            if n == attempts - 1:
                raise
            time.sleep(base * 2**n)
            print(f"retry {n + 1}: {err!r}")
```

A struct tag in Go is just a backtick string:

```go
package main

/* Config is loaded from the environment. */
type Config struct {
    Port  int    `env:"PORT"`
    Token string `env:"TOKEN"`
}

const defaultMask uint32 = 0xDEADBEEF
```

And the config it parses:

```toml
# service defaults
port = 8080
timeout = 1.5
name = "edge"
```
````

- [ ] **Step 2: Build and verify it renders as plain code (no token spans yet)**

Run: `hugo --minify --panicOnWarning && grep -c 'class=chroma' public/posts/snippets/index.html`
Expected: build succeeds; the `grep -c` prints `0` — with highlighting off there is no `<pre class=chroma>` wrapper. (NOTE: `--minify` emits **unquoted** attributes, so assertions must match `class=chroma`, not `class="chroma"`.) Also confirm the page exists:
Run: `test -f public/posts/snippets/index.html && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add content/posts/snippets.md
git commit -m "$(cat <<'EOF'
content: add sample post with multi-language code blocks (#21)

Permanent post whose fenced blocks collectively exercise every chroma
token group the palette will style; also the page the highlighting
verification gate renders against.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Enable class-based highlighting + render hook

Turn on fenced highlighting and add the render hook that sets the `hasCode` flag.

**Files:**
- Modify: `hugo.toml:16` (the `[markup.highlight]` table)
- Create: `layouts/_default/_markup/render-codeblock.html`

- [ ] **Step 1: Flip the highlight config**

In `hugo.toml`, replace the current single-line highlight table:

```toml
[markup.highlight]
  codeFences = false       # plain code blocks; class-based chroma can come later
```

with:

```toml
[markup.highlight]
  codeFences = true        # class-based chroma; palette inlined per-page (see render hook)
  noClasses = false        # emit <span class>, NOT inline style= (CSP requires this)
```

Leave all other highlight options at their defaults (`lineNos` off, `guessSyntax` off).

- [ ] **Step 2: Create the render hook**

Create `layouts/_default/_markup/render-codeblock.html` with exactly these two lines (the `Set` line is whitespace-trimmed so the hook injects no stray text node):

```go-html-template
{{- .Page.Store.Set "hasCode" true -}}
{{ highlight (trim .Inner "\n") .Type .Options }}
```

- [ ] **Step 3: Build and verify token spans now appear**

`--minify` emits unquoted attributes, so match `class=…` without quotes. Use a class set verified present in these exact snippets:

Run: `hugo --minify --panicOnWarning && grep -oE '<span class=(k|kd|kt|cm|cp|mh|mf|mi|s2|si)>' public/posts/snippets/index.html | sort -u`
Expected: build succeeds; output is non-empty and lists several token-class spans spanning all four groups, e.g. `<span class=cm>`/`<span class=cp>` (comments), `<span class=k>`/`<span class=kd>`/`<span class=kt>` (keywords), `<span class=s2>`/`<span class=si>` (strings), `<span class=mh>`/`<span class=mf>`/`<span class=mi>` (numbers) — proving class-based chroma is on.

- [ ] **Step 4: Verify no stray text node leaked from the hook**

Run: `grep -oE '.{0,12}<div class=highlight' public/posts/snippets/index.html | head -1`
Expected: the highlight div abuts the preceding markup with no stray characters between (e.g. `…</p><div class=highlight`), confirming the trimmed `Set` line emitted nothing. (Hugo `--minify` would strip whitespace anyway; this confirms it.)

- [ ] **Step 5: Commit**

```bash
git add hugo.toml layouts/_default/_markup/render-codeblock.html
git commit -m "$(cat <<'EOF'
feat: enable class-based chroma highlighting + hasCode render hook (#21)

codeFences=true, noClasses=false so fenced code emits <span class> tokens
(no inline style=, which the CSP guard rejects). The render hook also sets
a per-page hasCode flag consumed by the conditional palette injection.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Conditional palette injection

Add the `var()`-based palette and wire it to appear only on code-bearing pages, resolving the head/body ordering with forced content evaluation. These three edits are interdependent (none is observable alone), so they share one task.

**Files:**
- Create: `assets/scss/chroma.scss`
- Modify: `layouts/baseof.html` (insert before line 3, the head partial call)
- Modify: `layouts/_partials/head.html` (insert after line 22, the `main.scss` `<style>`)

- [ ] **Step 1: Create the palette**

Create `assets/scss/chroma.scss` — "Literals in green": comments muted+italic, keywords bold `--fg`, strings and numbers `--accent`; names/operators/punctuation inherit `--fg` (no rule). All selectors scoped under `.chroma`:

```scss
// Syntax highlighting palette — "Literals in green" (see
// docs/superpowers/specs/2026-06-08-code-highlighting-design.md).
// Colours are var() references so the light/dark theme swap recolours code.
// Inlined per-page only on pages with code (head.html, gated on hasCode).
.chroma {
  // Comments — recede.
  .c, .ch, .cm, .c1, .cs, .cp, .cpf {
    color: var(--fg-muted);
    font-style: italic;
  }
  // Keywords (incl. type keywords) — structure via weight, not colour.
  .k, .kc, .kd, .kn, .kp, .kr, .kt {
    color: var(--fg);
    font-weight: 600;
  }
  // Strings — the one accent lands on literal values.
  .s, .sa, .sb, .sc, .dl, .sd, .s2, .se, .sh, .si, .sx, .sr, .s1, .ss {
    color: var(--accent);
  }
  // Numbers — also literal values.
  .m, .mb, .mf, .mh, .mi, .il, .mo {
    color: var(--accent);
  }
}
```

- [ ] **Step 2: Force content evaluation in `baseof.html`**

In `layouts/baseof.html`, the current top is:

```go-html-template
<!doctype html>
<html lang="en">
{{ partial "head.html" . }}
```

Insert the assign-and-discard line so content renders (firing the code-block hooks and setting `hasCode`) before the head partial:

```go-html-template
<!doctype html>
<html lang="en">
{{- $_ := .WordCount -}}{{/* render content now so code-block hooks set hasCode before <head> */}}
{{ partial "head.html" . }}
```

NOTE: it must be `{{- $_ := .WordCount -}}` (assign-and-discard). A bare `{{ .WordCount }}` prints its integer into the page and breaks the zero-cost-on-code-free-pages guarantee.

- [ ] **Step 3: Add the conditional `<style>` in `head.html`**

In `layouts/_partials/head.html`, immediately after the existing `main.scss` block (line 22):

```go-html-template
  {{ $css := resources.Get "scss/main.scss" | css.Sass (dict "targetPath" "css/main.css") | minify }}
  <style>{{ $css.Content | safeCSS }}</style>
```

insert:

```go-html-template
  {{ if .Store.Get "hasCode" }}
  {{ $chroma := resources.Get "scss/chroma.scss" | css.Sass | minify }}
  <style>{{ $chroma.Content | safeCSS }}</style>
  {{ end }}
```

- [ ] **Step 4: Build and verify the palette appears on the code page only**

The string `chroma` appears nowhere in `main.scss`, so it is a clean marker for the
conditional palette (it shows up both as the minified selectors `.chroma .c1{…}` and
as `<pre class=chroma>`). Do NOT key off `var(--accent)` — `main.scss` uses it for
links/blockquotes and is inlined on every page.

Run: `hugo --minify --panicOnWarning && grep -c chroma public/posts/snippets/index.html`
Expected: build succeeds; count ≥ 2 (the inlined `.chroma` palette rules + the `<pre class=chroma>` wrapper) — the palette is present on the code page.

Run: `grep -c chroma public/index.html`
Expected: `0` — the home page (no code) gets no chroma `<style>` and no chroma markup.

Run: `grep -o '<html[^>]*>[^<]*<head' public/index.html`
Expected: `<html lang=en><head` (or similar) with **no digits** between `<html…>` and `<head>` — confirms the forced-eval discard idiom leaked nothing.

- [ ] **Step 5: Verify inline code on the existing post is untouched**

Run: `grep -c '<code>' public/posts/how-this-site-ships/index.html`
Expected: a non-zero count (its inline backtick code like `FROM scratch`), and none of it is wrapped in `.chroma` — the palette is scoped, so prose inline-code is unaffected.

- [ ] **Step 6: Commit**

```bash
git add assets/scss/chroma.scss layouts/baseof.html layouts/_partials/head.html
git commit -m "$(cat <<'EOF'
feat: inline a theme-aware chroma palette on code pages only (#21)

Hand-written var()-based palette (assets/scss/chroma.scss) mapped to
--fg/--fg-muted/--accent so light/dark recolours code for free. baseof
forces content eval (assign-and-discard .WordCount) before <head> so the
render hook's hasCode flag is visible; head.html inlines the palette only
when set. Code-free pages, including home, get nothing.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Full verification gate (CSP, weight, light/dark)

Run the real build + check pipeline and confirm the CSP and page-weight gates pass and the highlighting behaves across themes.

**Files:** none (verification only).

- [ ] **Step 1: Full build**

Run: `./scripts/build.sh`
Expected: completes with no error; among other output, `csp-inline: policy injected into N pages`. (Requires `FONT_PYTHON` pointing at the fonttools+brotli venv, per CLAUDE.md.)

- [ ] **Step 2: Verify the chroma `<style>` is covered by that page's CSP**

After a full build every regular post carries two hashed inline `<style>` blocks —
`main.scss` and the per-page `@font-face` block injected by `font-inline.py`. The
code page must have exactly **one more** (the chroma block). Compare the code page to
a **code-free post** as the baseline — NOT the home page: `layouts/index.html` adds a
page-specific `.intro` `<style>` to home only, so home is not a generic baseline (it
also lands at 3 hashes, which would make a home comparison falsely look like "no
delta"). Use `how-this-site-ships` (a code-free post) instead:

Run: `code=$(grep -o "'sha256-" <(grep -o "style-src [^;]*" public/posts/snippets/index.html) | wc -l); base=$(grep -o "'sha256-" <(grep -o "style-src [^;]*" public/posts/how-this-site-ships/index.html) | wc -l); echo "code=$code base=$base"`
Expected: `code=3 base=2` — the code page's `style-src` has exactly one more hash than a code-free post's. The extra hash is the conditional chroma palette, hashed automatically with no change to `csp-inline.py`.

Also confirm home gets no chroma block (its hash count is incidental, but it must not gain the palette):
Run: `grep -c chroma public/index.html`
Expected: `0`.

- [ ] **Step 3: Confirm the CSP guard found no violations**

This is implied by Step 1 succeeding (`csp-inline.py` `sys.exit`s on any `style=`/handler violation). Explicitly re-run the guard's unit fixtures:
Run: `python3 scripts/test_csp_inline.py`
Expected: passes (exit 0), no assertion errors.

- [ ] **Step 4: Run the rest of the verification gates**

Run: `./scripts/check.sh`
Expected: `htmltest` clean, `lychee` clean, and `page-weight OK (…)` — the home page stays under its 10 KiB budget (unchanged: it has no chroma block) and `posts/snippets` is well under 16 KiB.

- [ ] **Step 5: Manual light/dark check (browser)**

Open `public/posts/snippets/index.html` in a browser (or via a static server against `public/`; do NOT use `hugo server` — per project memory it serves no inlined font and isn't the built artifact). Confirm:
- Comments are muted and italic; strings and numbers are the green accent; keywords are bold; function/variable names are default foreground.
- Each of the four blocks shows at least one comment, keyword, string, and number styled.
- Toggle dark mode (header toggle): token colours follow the theme (accent shifts to the dark `--accent`, foreground/muted shift), with no flash of unstyled colour on load.
- Open devtools console: **zero CSP violation messages** on the page.

Document the result in your completion notes (this is a manual gate — state explicitly that it was checked in a real browser, or that it could not be and why).

- [ ] **Step 6: No commit**

This task changes no files. If `build.sh`/`check.sh` produced only `public/` artifacts (gitignored) and nothing tracked changed, there is nothing to commit. Confirm with `git status --short` (expect a clean tree apart from untracked `.claude/` / `.serena/`).

---

## Self-Review Notes (author)

- **Spec coverage:** §1 hand-written palette → Task 3 Step 1 (+ class list embedded in header, harvested from `gen chromastyles`). §2 "Literals in green" + selectors → Task 3 Step 1. §3 render hook + forced eval + conditional `<style>` + `.chroma` scoping → Tasks 2–3. §4 `hugo.toml` → Task 2 Step 1. §5 sample post → Task 1. CSP zero-change → Task 4 Steps 2–3. Weight → Task 4 Step 4. Verification checklist → Task 4 Steps 2–5.
- **Keyword-in-green alternative** is documented in the spec, not implemented (out of scope for this plan).
- **No placeholders:** every code/template/SCSS block is complete and literal; every step has an exact command and expected output.
