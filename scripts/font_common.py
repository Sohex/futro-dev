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
