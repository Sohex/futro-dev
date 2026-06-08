#!/usr/bin/env python3
# Emit (to stdout) the characters the webfont must cover: every char rendered across
# the built HTML (tags/script/style stripped) + a fixed safety floor. Stdlib only,
# so it runs under any python3. Used by build.sh; reused by the plan's manual coverage check.
import sys, glob, re, html

root = sys.argv[1] if len(sys.argv) > 1 else "public"
chars = set()
for path in glob.glob(f"{root}/**/*.html", recursive=True):
    with open(path, encoding="utf-8") as fh:
        t = fh.read()
    t = re.sub(r"<(script|style)\b.*?</\1>", " ", t, flags=re.S | re.I)  # drop inlined JS/CSS bodies
    t = re.sub(r"<[^>]+>", " ", t)                                        # drop tags
    chars.update(html.unescape(t))

chars.update(chr(c) for c in range(0x20, 0x7F))          # printable ASCII floor
chars.update("·–—‘’“”…©®™→←↑↓◐•§†‡€£")                    # non-ASCII the design may use
for ws in "\t\n\r":
    chars.discard(ws)
sys.stdout.write("".join(sorted(chars)))
