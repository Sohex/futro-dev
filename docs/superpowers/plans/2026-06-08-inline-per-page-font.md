# Inline Per-Page Font Subset — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the site-wide content-hashed `/fonts/*.woff2` + `<link rel="preload">` font scheme with a per-page base64 `data:` URI woff2 subset injected into each built HTML page's `<head>`, so every page is one self-contained response.

**Architecture:** A new `scripts/font-inline.py` runs after Hugo (inside `build.sh`), and for each `public/**/*.html` it subsets the committed master TTF to that page's exact rendered glyph set, emits woff2, base64-encodes it, and injects a `<style>@font-face{…}</style>` before `</head>`. Glyph extraction is shared with the existing `font-codepoints.py` via a new `font_common.py`. The standalone font file, its hashed-name rewrite, the preload `<link>`, and the SCSS `@font-face` are all removed.

**Tech Stack:** Python 3 + fontTools `Subsetter` API + brotli (the `FONT_PYTHON` venv at `./.venv/bin/python`), Hugo, bash, SCSS.

**Testing note (read first):** This project has **no unit-test framework** and the toolchain ethos forbids adding package-manager dev deps. Per the repo's `CLAUDE.md`, verification is `scripts/build.sh` then `scripts/check.sh`. So "tests" in this plan are (a) concrete verification commands run with `./.venv/bin/python` against the real master TTF / built `public/`, and (b) the durable correctness guards baked **into** `font-inline.py` itself. Do **not** scaffold pytest or a `tests/` directory. All commands assume the repo root as the working directory.

---

## File Structure

- **Create** `scripts/font_common.py` — single responsibility: extract the set of rendered characters from one HTML string (strip `<script>`/`<style>` bodies + tags, HTML-unescape). Imported by both font scripts so the extraction logic cannot drift. (A new module is required because `font-codepoints.py`'s hyphen makes it un-importable.)
- **Modify** `scripts/font-codepoints.py` — keep its CLI behavior (whole-site union + safety floor, used for manual coverage checks) byte-for-byte identical, but source its per-page extraction from `font_common`.
- **Create** `scripts/font-inline.py` — per-page subset → woff2 → base64 → inject, with payload guards. The build's font step.
- **Modify** `scripts/build.sh` — replace the font block (lines 9–36) with a single call to `font-inline.py`.
- **Modify** `layouts/_partials/head.html` — remove the preload `<link>`.
- **Modify** `assets/scss/main.scss` — remove the `@font-face` block.

---

## Task 1: Shared glyph extractor (`font_common.py`)

**Files:**
- Create: `scripts/font_common.py`

- [ ] **Step 1: Write the failing test**

Run this — it MUST fail because the module doesn't exist yet:

```bash
./.venv/bin/python -c '
import sys; sys.path.insert(0, "scripts")
from font_common import extract_html_chars
got = extract_html_chars("<p>Hi &amp; bye</p><style>.x{color:red}</style><script>var a=1</script>")
assert got == set("Hi & bye"), got
assert "\n" not in got and "\t" not in got
print("PASS")
'
```

- [ ] **Step 2: Run it to confirm it fails**

Expected: `ModuleNotFoundError: No module named 'font_common'`.

- [ ] **Step 3: Create `scripts/font_common.py`**

```python
#!/usr/bin/env python3
# Shared glyph extraction for the font scripts. Strips <script>/<style> bodies and tags,
# HTML-unescapes the remaining text, and returns the set of rendered characters (NO floor).
# Imported by font-codepoints.py (manual coverage check) and font-inline.py (the build).
import re
import html


def extract_html_chars(text):
    text = re.sub(r"<(script|style)\b.*?</\1>", " ", text, flags=re.S | re.I)  # drop inlined JS/CSS bodies
    text = re.sub(r"<[^>]+>", " ", text)                                        # drop tags
    chars = set(html.unescape(text))
    for ws in "\t\n\r":
        chars.discard(ws)
    return chars
```

- [ ] **Step 4: Run the test to confirm it passes**

Run the Step 1 command. Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/font_common.py
git commit -m "feat: shared HTML glyph extractor for font scripts"
```

---

## Task 2: Refactor `font-codepoints.py` onto the shared extractor (output unchanged)

**Files:**
- Modify: `scripts/font-codepoints.py`

The safety-floor lines (the two `chars.update(...)` lines and the `for ws ...` discard) contain hand-picked non-ASCII characters. **Do not retype them** — leave them exactly as they are. Only change the imports and the extraction loop.

Why the output stays byte-identical even though the `\t\n\r` discard moves into `extract_html_chars`: the ASCII floor re-adds every printable character anyway, and no page's extracted text contains exotic whitespace (`\x0b`, `\x0c`, `\xa0`) that the old single global discard would have kept. The equivalence is content-dependent, which is exactly why Step 4 re-verifies it by diff rather than by reasoning.

- [ ] **Step 1: Capture the current output as a regression baseline**

A fresh `public/` must exist first:

```bash
hugo --minify >/dev/null
./.venv/bin/python scripts/font-codepoints.py public > /tmp/cp.before
wc -c /tmp/cp.before
```

Expected: a non-zero byte count (the current charset).

- [ ] **Step 2: Edit the imports**

Replace the import line:

```python
import sys, glob, re, html
```

with:

```python
import sys, glob
from font_common import extract_html_chars
```

- [ ] **Step 3: Edit the extraction loop**

Replace this block:

```python
for path in glob.glob(f"{root}/**/*.html", recursive=True):
    with open(path, encoding="utf-8") as fh:
        t = fh.read()
    t = re.sub(r"<(script|style)\b.*?</\1>", " ", t, flags=re.S | re.I)  # drop inlined JS/CSS bodies
    t = re.sub(r"<[^>]+>", " ", t)                                        # drop tags
    chars.update(html.unescape(t))
```

with:

```python
for path in glob.glob(f"{root}/**/*.html", recursive=True):
    with open(path, encoding="utf-8") as fh:
        chars |= extract_html_chars(fh.read())
```

Leave everything below it (the floor `chars.update(...)` lines, the `for ws` discard, the `sys.stdout.write(...)`) untouched.

- [ ] **Step 4: Run the regression test — output must be byte-identical**

```bash
./.venv/bin/python scripts/font-codepoints.py public > /tmp/cp.after
diff /tmp/cp.before /tmp/cp.after && echo "IDENTICAL"
```

Expected: `IDENTICAL` (empty diff, exit 0). If the diff is non-empty, the extraction changed — fix before continuing.

- [ ] **Step 5: Commit**

```bash
git add scripts/font-codepoints.py
git commit -m "refactor: source font-codepoints extraction from font_common"
```

---

## Task 3: Per-page inliner (`font-inline.py`)

**Files:**
- Create: `scripts/font-inline.py`

This script carries the durable guards. Two fontTools traps it must defend against (both verified real):
1. `Options.flavor` is honored only by the `fontTools.subset` **CLI**, not by `TTFont.save()`. Without `font.flavor = "woff2"`, `save()` emits raw uncompressed SFNT (`\x00\x01\x00\x00`) ~70% larger.
2. `Subsetter.subset()` **mutates the `TTFont` in place** — reusing one master across pages collapses it (2671 → 4 → 1 glyph), so the master is reloaded per page.

- [ ] **Step 1: Write the failing test**

Run — MUST fail because the script doesn't exist:

```bash
rm -rf /tmp/fi && cp -r public /tmp/fi
./.venv/bin/python scripts/font-inline.py /tmp/fi
# every page must carry the inline font:
miss=0; for f in $(find /tmp/fi -name '*.html'); do grep -q 'data:font/woff2;base64,' "$f" || { echo "MISSING $f"; miss=1; }; done
test "$miss" = 0 && echo "ALL PAGES OK"
rm -rf /tmp/fi
```

- [ ] **Step 2: Run it to confirm it fails**

Expected: `can't open file '.../scripts/font-inline.py'` (No such file).

- [ ] **Step 3: Create `scripts/font-inline.py`**

```python
#!/usr/bin/env python3
# Inline a per-page Iosevka Custom woff2 subset into each built HTML page as a base64
# data: @font-face, replacing the site-wide /fonts/*.woff2 + <link preload> scheme. Run
# after Hugo, against public/. Needs fonttools + brotli (the FONT_PYTHON venv). Run from repo root.
import sys
import glob
import base64
from io import BytesIO
from fontTools.subset import Subsetter, Options
from fontTools.ttLib import TTFont
from font_common import extract_html_chars

MASTER = "tools/font/masters/iosevka-custom-regular.ttf"
BASELINE = 6676  # bytes; the old shared subset every page used to pay. Each page must beat it.

FACE = ('<style>@font-face{{font-family:"Iosevka Custom";font-style:normal;font-weight:400;'
        'font-display:swap;src:url(data:font/woff2;base64,{b64}) format("woff2")}}</style>')


def subset_woff2(chars, master_cmap):
    font = TTFont(MASTER)            # reload per page: Subsetter.subset() mutates in place
    opts = Options()
    opts.layout_features = []        # match the old --layout-features='' (ship no features)
    opts.layout_closure = False      # match the old --no-layout-closure
    sub = Subsetter(options=opts)
    sub.populate(text="".join(sorted(chars)))
    sub.subset(font)
    font.flavor = "woff2"            # REQUIRED: Options.flavor is CLI-only; else save() emits raw SFNT
    buf = BytesIO()
    font.save(buf)
    woff2 = buf.getvalue()
    if woff2[:4] != b"wOF2":
        sys.exit(f"font-inline: emitted font is not woff2 (magic {woff2[:4]!r}) — font.flavor not applied")
    sub_cmap = TTFont(BytesIO(woff2)).getBestCmap()
    missing = sorted(ch for ch in chars if ord(ch) in master_cmap and ord(ch) not in sub_cmap)
    if missing:
        sys.exit(f"font-inline: subset dropped supported glyphs {missing!r} — stale/mutated master?")
    return woff2


def inject(path, master_cmap):
    page = open(path, encoding="utf-8").read()
    if "</head>" not in page:
        sys.exit(f"font-inline: {path} has no </head> to inject before")
    woff2 = subset_woff2(extract_html_chars(page), master_cmap)
    style = FACE.format(b64=base64.b64encode(woff2).decode("ascii"))
    open(path, "w", encoding="utf-8").write(page.replace("</head>", style + "</head>", 1))
    return len(woff2)


def main(public):
    pages = sorted(glob.glob(f"{public}/**/*.html", recursive=True))
    if not pages:
        sys.exit(f"font-inline: no HTML under {public}/")
    master_cmap = TTFont(MASTER).getBestCmap()
    worst = 0
    for path in pages:
        size = inject(path, master_cmap)
        worst = max(worst, size)
        print(f"  {size:6d} B  {path}")
    index = f"{public}/index.html"
    if index not in pages:
        sys.exit(f"font-inline: {index} not found")
    if "◐" not in extract_html_chars(open(index, encoding="utf-8").read()):
        sys.exit("font-inline: home page glyph set lost the ◐ toggle")
    if worst >= BASELINE:
        sys.exit(f"font-inline: largest page font {worst} B >= baseline {BASELINE} B (SFNT bloat?)")
    print(f"font-inline: inlined {len(pages)} pages, largest {worst} B (baseline {BASELINE} B)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "public")
```

- [ ] **Step 4: Run the test to confirm it passes**

Run the Step 1 command. Expected: per-page size lines, a `font-inline: inlined N pages, largest ≈4.6 KiB …` summary (resume is the worst case, ~4.6 KiB — the exact byte count shifts with content), then `ALL PAGES OK`.

- [ ] **Step 5: Sanity-check the guards actually fire**

Confirm a broken font is rejected (temporarily neuter the flavor line in a throwaway copy). Run from the repo root — `font-inline.py` resolves `MASTER` relative to the cwd, and the system `python3` has no fonttools so the venv interpreter is required:

```bash
sed 's/font.flavor = "woff2"/pass  # flavor disabled/' scripts/font-inline.py > /tmp/fib.py
cp scripts/font_common.py /tmp/font_common.py
rm -rf /tmp/fi2 && cp -r public /tmp/fi2
PYTHONPATH=/tmp ./.venv/bin/python /tmp/fib.py /tmp/fi2 >/dev/null 2>/tmp/err; cat /tmp/err
rm -rf /tmp/fi2 /tmp/fib.py /tmp/font_common.py
```

Expected: it exits non-zero printing `font-inline: emitted font is not woff2 (magic b'\x00\x01\x00\x00') …`. This targets the `/tmp/fi2` copy (never the real `public/`) and proves the `wOF2` guard rejects SFNT.

- [ ] **Step 6: Commit**

```bash
git add scripts/font-inline.py
git commit -m "feat: per-page inline woff2 subset injector"
```

---

## Task 4: Integrate — swap the build, remove the preload + SCSS @font-face

**Files:**
- Modify: `scripts/build.sh:9-36`
- Modify: `layouts/_partials/head.html:7`
- Modify: `assets/scss/main.scss:3-9`

These three edits flip the site from the old scheme to the new one atomically. Do all three before rebuilding, so there is no half-state with a dangling `/fonts/` 404.

- [ ] **Step 1: Replace the font block in `scripts/build.sh`**

Replace lines 9–36 (from the `# --- web font:` comment through the `grep -rq … token not rewritten …` guard) with:

```bash
# --- web font: inline a per-page woff2 subset into each built HTML page ---
# FONT_PYTHON points at a venv with fonttools+brotli (see Prerequisites / CI). font-inline.py
# subsets the committed master to each page's exact glyph set and injects it as a base64 data:
# @font-face, so every page is one self-contained response (no /fonts request, no preload).
FONT_PYTHON="${FONT_PYTHON:-python3}"
"$FONT_PYTHON" scripts/font-inline.py public
```

(This also removes the now-unused `work=$(mktemp -d)` / `trap` lines, which only served the old font block. Leave the `typst compile …` line below intact.)

- [ ] **Step 2: Remove the preload link in `layouts/_partials/head.html`**

Delete this line:

```html
  <link rel="preload" href="/fonts/iosevka-custom.woff2" as="font" type="font/woff2" crossorigin>
```

- [ ] **Step 3: Remove the `@font-face` block in `assets/scss/main.scss`**

Delete these lines (the block plus its trailing blank line), leaving `$column: 42rem;` followed by a single blank line, then `@mixin dark {`:

```scss
@font-face {
  font-family: "Iosevka Custom";
  font-style: normal;
  font-weight: 400;
  font-display: swap;
  src: url("/fonts/iosevka-custom.woff2") format("woff2");
}

```

The `font-family: "Iosevka Custom", …` usages further down (`main.scss:42`, `:117`) stay — only the `@font-face` declaration moves into the per-page injected `<style>`.

- [ ] **Step 4: Full build + verify the new scheme**

```bash
FONT_PYTHON=./.venv/bin/python ./scripts/build.sh
ls public/fonts 2>/dev/null && echo "FAIL: public/fonts still exists" || echo "OK: no public/fonts"
grep -rl '/fonts/iosevka-custom' public && echo "FAIL: stale /fonts ref remains" || echo "OK: no stale /fonts refs"
grep -c 'rel="preload"' public/index.html
grep -c 'data:font/woff2;base64,' public/index.html
```

Expected: build runs clean and prints the `font-inline:` summary; `OK: no public/fonts`; `OK: no stale /fonts refs`; preload count `0`; data-URI count `1`.

- [ ] **Step 5: Run the full verification gates**

```bash
./scripts/check.sh
```

Expected: htmltest, lychee, and page-weight all pass (`page-weight OK …`). The shared-asset font bucket is now 0; each page carries its own ≤4.7 KiB font and stays far under the 75 KiB gate.

- [ ] **Step 6: Commit**

```bash
git add scripts/build.sh layouts/_partials/head.html assets/scss/main.scss
git commit -m "feat: inline per-page font, drop standalone woff2 + preload"
```

---

## Task 5: Manual browser verification (owner-only — cannot be automated)

The `#82` fix is unverifiable by tooling: Playwright can't drive Zen, and the vanilla-Firefox repro is environment-specific. This is a manual gate, not a build claim.

- [ ] **Step 1: Serve the built site and open the home page in the affected browser(s)**

```bash
./scripts/build.sh   # if not already built
python3 -m http.server -d public 8099
```

Open `http://localhost:8099/` in Zen and in the affected Firefox. In DevTools → Network (cold cache, no throttling): confirm there is **no** `/fonts/*.woff2` request at all, and the page renders in Iosevka Custom from first paint with **no** FOUT/late font swap. Confirm a post page (`/posts/how-this-site-ships/`) the same way.

- [ ] **Step 2: Record the outcome**

Note the result on `Sohex/vps-setup#82` (font now inlined; FOUT gone / still present). Stop the server (`Ctrl-C`).

---

## Self-Review

- **Spec coverage:** exact per-page glyphs (Task 3 `subset_woff2`/`extract_html_chars`, no floor) ✓; remove standalone woff2 + hashed-name rewrite + preload + SCSS `@font-face` (Task 4) ✓; per-page injection via new script (Task 3) ✓; `font.flavor`/in-place-mutation traps handled (Task 3) ✓; payload guards: `wOF2` magic + cmap-coverage + `◐` + size-regression (Task 3) ✓; shared extractor imported, not copied (Tasks 1–2) ✓; XML/sitemap out of scope (Task 3 globs `*.html` only) ✓; 404 in scope (Task 3 processes it) ✓; `check-page-weight.sh` unchanged + re-run (Task 4 Step 5) ✓; manual `#82` verification (Task 5) ✓. CSP `font-src data:` and the IaC `Link`-header caveat are documented in the spec as out-of-band notes — no task needed in this repo.
- **Placeholder scan:** none — every step has runnable commands or complete code.
- **Type/name consistency:** `extract_html_chars` (Task 1) is the name imported in Tasks 2 and 3; `subset_woff2(chars, master_cmap)` / `inject(path, master_cmap)` / `main(public)` signatures are internally consistent; `MASTER`, `BASELINE`, `FACE` referenced consistently.
