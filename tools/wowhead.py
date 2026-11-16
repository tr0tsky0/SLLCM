"""Compare Wowhead's leyline / convergence coords with SLLCM's Data.lua.

Usage: python tools/wowhead.py

Reads g_mapperData from the two Forever object pages and prints, per zone, the Wowhead points
that aren't in Data.lua (as Data.lua lines, ready to paste) and the Data.lua points Wowhead
doesn't show. Run by hand only; nothing is written.
"""
import json
import math
import re
import sys
import urllib.request
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "SkyborneLeyLineConvergenceMarker" / "Data.lua"
PAGES = {
    "LeyLines": 602735,               # Leyline
    "ElementalConvergences": 616992,  # Elemental Convergence
}
SAME = 0.012  # map units; closer than this counts as the same node


def read_data(retired=False):
    """SLLCM_Data's points, or with retired=True SLLCM_Retired's (same layout, at the end of Data.lua)."""
    main, _, rest = DATA.read_text(encoding="utf-8").partition("SLLCM_Retired")
    src = rest if retired else main
    out = {}
    for key in PAGES:
        m = re.search(key + r"\s*=\s*\{(.*?)\n  \},", src, re.S)
        zones = {}
        for map_id, body in re.findall(r"\[(\d+)\]\s*=\s*\{(.*?)\n    \}", m.group(1) if m else "", re.S):
            zones[int(map_id)] = [(float(x), float(y))
                                  for x, y in re.findall(r"\{\s*([\d.]+),\s*([\d.]+)\s*\}", body)]
        out[key] = zones
    return out


def fetch(object_id):
    req = urllib.request.Request(f"https://www.wowhead.com/forever/object={object_id}",
                                 headers={"User-Agent": "Mozilla/5.0"})
    html = urllib.request.urlopen(req, timeout=60).read().decode("utf-8")
    m = re.search(r"g_mapperData\s*=\s*(\{.*?\});", html)
    if not m:
        sys.exit(f"object {object_id}: no g_mapperData on the page (layout changed or blocked)")
    zones = {}
    for floors in json.loads(m.group(1)).values():
        for z in floors:
            zones.setdefault(z["uiMapId"], {"name": z["uiMapName"], "pts": []})
            zones[z["uiMapId"]]["pts"] += [(x / 100, y / 100) for x, y in z["coords"]]
    return zones


def near(p, pts):
    return any(math.hypot(p[0] - q[0], p[1] - q[1]) < SAME for q in pts)


def main():
    ours, retired = read_data(), read_data(retired=True)
    total_new = 0
    for key, object_id in PAGES.items():
        wh = fetch(object_id)
        print(f"\n== {key} (object {object_id}): {sum(len(z['pts']) for z in wh.values())} points in {len(wh)} zones")
        for map_id in sorted(wh):
            z = wh[map_id]
            have = ours[key].get(map_id, [])
            gone = retired[key].get(map_id, [])
            new = [p for p in z["pts"] if not near(p, have) and not near(p, gone)]
            missing = [p for p in have if not near(p, z["pts"])]
            for x, y in (p for p in z["pts"] if near(p, gone)):
                print(f"      retired, but Wowhead has it: {x * 100:.1f}, {y * 100:.1f}")
            print(f"[{map_id}] {z['name']}: wowhead {len(z['pts'])}, ours {len(have)}")
            for x, y in new:
                print(f"      {{ {x:.4f}, {y:.4f} }},  -- NEW from Wowhead")
            for x, y in missing:
                print(f"      ours only: {x * 100:.1f}, {y * 100:.1f}")
            total_new += len(new)
    print(f"\n{total_new} new point(s). Wowhead coords are 1 decimal (roughly 5-25 yd).")


if __name__ == "__main__":
    main()
