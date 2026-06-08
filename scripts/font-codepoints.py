#!/usr/bin/env python3
# Emit (to stdout) the characters the webfont must cover: every char rendered across
# the built HTML (tags/script/style stripped) + a fixed safety floor. Stdlib only,
# so it runs under any python3. Used by build.sh; reused by the plan's manual coverage check.
import sys, glob
from font_common import extract_html_chars

root = sys.argv[1] if len(sys.argv) > 1 else "public"
chars = set()
for path in glob.glob(f"{root}/**/*.html", recursive=True):
    with open(path, encoding="utf-8") as fh:
        chars |= extract_html_chars(fh.read())

chars.update(chr(c) for c in range(0x20, 0x7F))          # printable ASCII floor
chars.update("·–—‘’“”…©®™→←↑↓◐•§†‡€£")                    # non-ASCII the design may use
for ws in "\t\n\r":
    chars.discard(ws)
sys.stdout.write("".join(sorted(chars)))
