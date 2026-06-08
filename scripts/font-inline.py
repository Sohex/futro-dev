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
    opts.drop_tables += ["GSUB", "GPOS", "GDEF"]  # no features shipped -> drop the now-dead layout tables
    opts.name_IDs = []               # browsers match @font-face on the CSS family, not the font's name table
    opts.name_legacy = False
    opts.name_languages = []
    sub = Subsetter(options=opts)
    sub.populate(text="".join(sorted(chars)))
    sub.subset(font)
    font.flavor = "woff2"            # REQUIRED: Options.flavor is CLI-only; else save() emits raw SFNT
    buf = BytesIO()
    font.save(buf)
    woff2 = buf.getvalue()
    if woff2[:4] != b"wOF2":
        sys.exit(f"font-inline: emitted font is not woff2 (magic {woff2[:4]!r}) — font.flavor not applied")
    sub_cmap = TTFont(BytesIO(woff2)).getBestCmap() or {}  # re-parse emitted bytes; validates serialized output
    missing = sorted(ch for ch in chars if ord(ch) in master_cmap and ord(ch) not in sub_cmap)
    if missing:
        sys.exit(f"font-inline: subset dropped supported glyphs {missing!r} — stale/mutated master?")
    return woff2


def inject(path, master_cmap):
    with open(path, encoding="utf-8") as f:
        page = f.read()
    if "</head>" not in page:
        sys.exit(f"font-inline: {path} has no </head> to inject before")
    page_chars = extract_html_chars(page)
    woff2 = subset_woff2(page_chars, master_cmap)
    style = FACE.format(b64=base64.b64encode(woff2).decode("ascii"))
    with open(path, "w", encoding="utf-8") as f:
        f.write(page.replace("</head>", style + "</head>", 1))
    return len(woff2), page_chars


def main(public):
    pages = sorted(glob.glob(f"{public}/**/*.html", recursive=True))
    if not pages:
        sys.exit(f"font-inline: no HTML under {public}/")
    master_cmap = TTFont(MASTER).getBestCmap()
    worst = 0
    found_home = False
    for path in pages:
        size, page_chars = inject(path, master_cmap)
        worst = max(worst, size)
        if path == f"{public}/index.html" and "◐" not in page_chars:
            sys.exit("font-inline: home page glyph set lost the ◐ toggle")
        if path == f"{public}/index.html":
            found_home = True
        print(f"  {size:6d} B  {path}")
    if not found_home:
        sys.exit(f"font-inline: {public}/index.html not found")
    if worst >= BASELINE:
        sys.exit(f"font-inline: largest page font {worst} B >= baseline {BASELINE} B (SFNT bloat?)")
    print(f"font-inline: inlined {len(pages)} pages, largest {worst} B (baseline {BASELINE} B)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "public")
