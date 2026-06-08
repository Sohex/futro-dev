#!/usr/bin/env python3
# Write a quality-11 brotli sibling (foo.html -> foo.html.br) next to every compressible
# file under public/, so Caddy can serve it via `file_server { precompressed br }` instead
# of re-compressing per request at a lower quality. Run after build.sh's Hugo + font steps,
# against public/. Needs the brotli module (the FONT_PYTHON venv). Run from repo root.
import sys
import glob
import os
import brotli

# Text-based, worth compressing. Everything else under public/ (woff2 is inlined, the PDF and
# raster/ico images are already compressed) gets no .br — Caddy then serves it as-is.
EXTS = (".html", ".css", ".js", ".svg", ".xml", ".json", ".txt", ".webmanifest")


def main(public):
    files = sorted(
        p for p in glob.glob(f"{public}/**/*", recursive=True)
        if os.path.isfile(p) and p.endswith(EXTS)
    )
    if not files:
        sys.exit(f"brotli-precompress: no compressible files under {public}/")
    raw_total = comp_total = 0
    written = skipped = 0
    for path in files:
        with open(path, "rb") as f:
            raw = f.read()
        comp = brotli.compress(raw, mode=brotli.MODE_TEXT, quality=11)
        # A .br larger than the original would make Caddy serve a worse payload to br-capable
        # clients, so leave it off and let Caddy fall back to the identity file.
        if len(comp) >= len(raw):
            skipped += 1
            print(f"  skip (no gain)  {path}")
            continue
        with open(path + ".br", "wb") as f:
            f.write(comp)
        raw_total += len(raw)
        comp_total += len(comp)
        written += 1
        print(f"  {len(raw):7d} -> {len(comp):7d} B  {path}")
    pct = 100 * (1 - comp_total / raw_total) if raw_total else 0
    print(f"brotli-precompress: {written} .br files, {skipped} skipped, "
          f"{raw_total} -> {comp_total} B ({pct:.1f}% smaller)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "public")
