"""Build the SLLCM release zip from the release .toc.

Usage: python tools/package.py

Zips the release .toc and only the files it lists, so dev-only files (the -Dev toc, Watch.lua) stay
out. Named after the toc's ## Version; refuses to overwrite an existing zip.
"""
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NAME = "SkyborneLeyLineConvergenceMarker"
ADDON = ROOT / NAME
TOC = ADDON / f"{NAME}.toc"


def main():
    text = TOC.read_text(encoding="utf-8-sig")
    version = re.search(r"^## Version:\s*(\S+)", text, re.M)
    if not version:
        sys.exit("no ## Version in the toc")
    files = [line.strip() for line in text.splitlines()
             if line.strip() and not line.startswith("#")]
    missing = [f for f in files if not (ADDON / f).is_file()]
    if missing:
        sys.exit("listed in the toc but missing: " + ", ".join(missing))

    out = ROOT / f"{NAME} v{version.group(1)}.zip"
    if out.exists():
        sys.exit(f"{out.name} already exists (bump ## Version?)")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for f in [f"{NAME}.toc"] + files:
            z.write(ADDON / f, f"{NAME}/{f}")
    print(f"{out.name}: {', '.join([TOC.name] + files)}")
    left_out = sorted(p.name for p in ADDON.iterdir() if p.is_file() and p.name not in files + [TOC.name])
    if left_out:
        print("left out: " + ", ".join(left_out))


if __name__ == "__main__":
    main()
