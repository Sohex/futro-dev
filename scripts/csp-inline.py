#!/usr/bin/env python3
# Inject a per-page hash-based Content-Security-Policy <meta> into each built HTML page.
# Run after font-inline.py (so the @font-face block is present and gets hashed) and before
# brotli-precompress.py (so the .br copies include the meta). Stdlib only (hashlib/base64/re).
# Hashes the FINAL served bytes of every inline <style> and executable <script>, ships no
# 'unsafe-inline', and FAILS THE BUILD on any construct such a policy cannot cover. Run from repo root.
import sys
import re
import glob
import html
import base64
import hashlib

# A <script> is executable iff its (lowercased, trimmed) type is empty/absent or a JS MIME type.
# Anything else (notably application/ld+json) is a data block: skipped, not hashed.
JS_TYPES = {"", "text/javascript", "application/javascript", "module"}

# Raw-text elements: the first </script>|</style> ends the block (browser tokenizer rule).
BLOCK_RE = re.compile(r"<(script|style)\b([^>]*)>(.*?)</\1>", re.S | re.I)
# Start-tag scan tolerates quoted attribute values that contain '>'.
TAG_RE = re.compile(r"<([a-zA-Z][a-zA-Z0-9]*)((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>")
COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
# charset attribute, quoted or unquoted (hugo --minify emits `<meta charset=utf-8>`).
CHARSET_RE = re.compile(r"<meta\b[^>]*\bcharset\s*=\s*[^>]*>", re.I)


def _attr(attrs, name):
    """Value of attribute `name` in a start-tag's attribute string (quoted/single/bare), or None."""
    m = re.search(rf'\b{name}\s*=\s*("([^"]*)"|\'([^\']*)\'|([^\s>]+))', attrs, re.I)
    if not m:
        return None
    return m.group(2) or m.group(3) or m.group(4) or ""


def hash_block(body):
    digest = hashlib.sha256(body.encode("utf-8")).digest()
    return "'sha256-" + base64.b64encode(digest).decode("ascii") + "'"


def _is_executable_script(attrs):
    return (_attr(attrs, "type") or "").strip().lower() in JS_TYPES


def script_and_style_hashes(page):
    """(script_hashes, style_hashes) over executable scripts and all styles; deduped, order-preserved."""
    scripts, styles = [], []
    for kind, attrs, body in ((m.group(1).lower(), m.group(2), m.group(3)) for m in BLOCK_RE.finditer(page)):
        if kind == "script":
            if _is_executable_script(attrs):
                scripts.append(hash_block(body))
        else:
            styles.append(hash_block(body))
    return _dedup(scripts), _dedup(styles)


def _dedup(xs):
    seen, out = set(), []
    for x in xs:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


def build_policy(script_hashes, style_hashes):
    return (
        "default-src 'none'; "
        f"script-src {' '.join(script_hashes)}; "
        f"style-src {' '.join(style_hashes)}; "
        "img-src 'self' data:; "
        "font-src data:; "
        "base-uri 'none'; "
        "form-action 'none'"
    )


def find_violations(page):
    """Human-readable strings for constructs a hash-based, 'unsafe-inline'-free CSP cannot cover."""
    v = []
    for m in BLOCK_RE.finditer(page):
        kind, attrs = m.group(1).lower(), m.group(2)
        if kind == "script" and _is_executable_script(attrs) and _attr(attrs, "src") is not None:
            v.append(f"external executable <script src>: <script{attrs}>")
    # Scan start-tags only — after dropping script/style bodies and comments, so the literal
    # strings style=/javascript: inside JS or CSS source don't produce false positives.
    stripped = BLOCK_RE.sub(" ", page)
    stripped = COMMENT_RE.sub(" ", stripped)
    for m in TAG_RE.finditer(stripped):
        attrs = m.group(2)
        if re.search(r"\bstyle\s*=", attrs, re.I):
            v.append(f"inline style= attribute: <{m.group(1)}{attrs}>")
        for on in re.finditer(r"\b(on\w+)\s*=", attrs, re.I):
            v.append(f"inline {on.group(1)} handler: <{m.group(1)}{attrs}>")
        for av in re.finditer(r"=\s*(\"([^\"]*)\"|'([^']*)'|([^\s>]+))", attrs):
            val = html.unescape(av.group(2) or av.group(3) or av.group(4) or "")
            if val.strip().lower().startswith("javascript:"):
                v.append(f"javascript: URL: <{m.group(1)}{attrs}>")
    return v


def inject_meta(page):
    """Return `page` with the CSP <meta> injected right after <meta charset…>. Raises ValueError on problems."""
    script_hashes, style_hashes = script_and_style_hashes(page)
    policy = build_policy(script_hashes, style_hashes)
    if '"' in policy:
        raise ValueError(f"assembled policy contains a double quote: {policy!r}")
    meta = f'<meta http-equiv="Content-Security-Policy" content="{policy}">'
    anchor = CHARSET_RE.search(page)
    if not anchor:
        raise ValueError("no <meta charset…> to anchor the CSP meta")
    out = page[: anchor.end()] + meta + page[anchor.end():]
    # Self-check: re-parse the written bytes and confirm every block hash is listed in the policy.
    s2, st2 = script_and_style_hashes(out)
    for h in s2 + st2:
        if h not in policy:
            raise ValueError(f"self-check failed: block hash {h} absent from policy")
    return out


def main(public):
    pages = sorted(glob.glob(f"{public}/**/*.html", recursive=True))
    if not pages:
        sys.exit(f"csp-inline: no HTML under {public}/")
    found_home = False
    for path in pages:
        with open(path, encoding="utf-8") as f:
            page = f.read()
        violations = find_violations(page)
        if violations:
            sys.exit(f"csp-inline: {path} has CSP-incompatible constructs:\n  " + "\n  ".join(violations))
        try:
            out = inject_meta(page)
        except ValueError as e:
            sys.exit(f"csp-inline: {path}: {e}")
        with open(path, "w", encoding="utf-8") as f:
            f.write(out)
        if path == f"{public}/index.html":
            found_home = True
    if not found_home:
        sys.exit(f"csp-inline: {public}/index.html not found")
    print(f"csp-inline: policy injected into {len(pages)} pages")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "public")
