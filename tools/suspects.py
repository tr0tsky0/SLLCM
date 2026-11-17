"""List likely-bad node locations for SLLCM_Retired: copies of a real node reported a little off.

Usage: python tools/suspects.py [--yards 150]

Reads Data.lua (its comment tags say where each point came from) and the dev copy's SavedVariables:
shared locations (db.shared), last-seen stamps (db.seen) and zone sizes (db.zoneSizes, saved by Watch.lua at
login, so /reload the dev copy first). Writes tools/suspects.txt, grouped like SLLCM_Retired: review it, then
paste the lines you agree with into SLLCM_Retired.

A point is a suspect when it came only from shared reports and sits within --yards of a better-sourced point
(one we found ourselves, or one Wowhead also has) that it could be a copy of, and no sighting is attributable
to it (a stamp within SEEN_YARDS of it and nearer to it than to that point). Points from shared reports in
db.shared that Data.lua lacks are judged against every Data.lua point. Two shared-only Data.lua points close
together with nothing better nearby are listed apart, as "unsure": one is probably a copy of the other.
"""
import argparse
import math
import re
from pathlib import Path

import lupa

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "SkyborneLeyLineConvergenceMarker" / "Data.lua"
SV = Path(r"D:\World of Warcraft\_forever_\WTF\Account\TR0TSKY\SavedVariables\SkyborneLeyLineConvergenceMarker-Dev.lua")
OUT = ROOT / "tools" / "suspects.txt"
KEYS = ("LeyLines", "ElementalConvergences")
SEEN_YARDS = 35  # the racial works from about 30 yd, so a sighting lands that far from the node


def read_data():
    """{key: {mapID: (name, [(x, y, source)])}}, source "good" (own find or Wowhead) or "shared"."""
    src = DATA.read_text(encoding="utf-8").split("SLLCM_Retired")[0]
    out = {}
    for key in KEYS:
        block = re.search(key + r"\s*=\s*\{(.*?)\n  \},", src, re.S).group(1)
        zones = {}
        for map_id, name, body in re.findall(r"\[(\d+)\] = \{ -- ([^\n]*)\n(.*?)\n    \}", block, re.S):
            pts = []
            for x, y, tag in re.findall(r"\{ ([\d.]+), ([\d.]+) \},?[ \t]*(?:-- ([^\n]*))?", body):
                good = "Wowhead" in tag or "shared" not in tag
                pts.append((float(x), float(y), "good" if good else "shared"))
            zones[int(map_id)] = (name.strip(), pts)
        out[key] = zones
    return out


def read_retired():
    src = DATA.read_text(encoding="utf-8").partition("SLLCM_Retired")[2]
    out = {}
    for key in KEYS:
        m = re.search(key + r"\s*=\s*\{(.*?)\n  \},", src, re.S)
        out[key] = {int(mid): [(float(x), float(y)) for x, y in re.findall(r"\{ ([\d.]+), ([\d.]+) \}", body)]
                    for mid, body in re.findall(r"\[(\d+)\] = \{[^\n]*\n(.*?)\n    \}", m.group(1) if m else "", re.S)}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--yards", type=float, default=150, help="how far a copy can sit from the point it copies")
    args = ap.parse_args()

    L = lupa.LuaRuntime()
    L.execute(SV.read_text(encoding="utf-8"))
    db = L.globals().SkyborneMarkerDB
    sizes = {int(m): (float(s[1]), float(s[2])) for m, s in (db.zoneSizes or {}).items()}
    if not sizes:
        raise SystemExit("no zone sizes in the SavedVariables: /reload the dev copy (Watch.lua saves them), then run again")
    data, retired = read_data(), read_retired()

    def lua_points(t):
        return [(float(p[1]), float(p[2])) + ((float(p[3]),) if p[3] else ()) for p in t.values()] if t else []

    lines, unsure, summary = [], [], []
    for key in KEYS:
        shared = db.shared and db.shared[key]
        seen = db.seen and db.seen[key]
        maps = set(data[key]) | {int(m) for m in (shared.keys() if shared else [])}
        found = {}  # mapID -> [(x, y, comment)]
        bands = [0, 0, 0, 0]
        no_size = 0
        for m in sorted(maps):
            if m not in sizes:
                no_size += 1
                continue
            w, h = sizes[m]

            def yd(a, b):
                return math.hypot((a[0] - b[0]) * w, (a[1] - b[1]) * h)

            name, pts = data[key].get(m, ("map %d" % m, []))
            gone = retired[key].get(m, [])
            stamps = lua_points(seen[m]) if seen and seen[m] else []
            extra = [(x, y, "shared-only") for x, y in lua_points(shared[m])] if shared and shared[m] else []

            def seen_at(p, other):
                for s in stamps:
                    if yd(p, s) < SEEN_YARDS and yd(p, s) < yd(other, s):
                        return s[2]

            for p in pts + extra:
                if p[2] == "good" or any(yd(p, g) < 10 for g in gone):
                    continue
                anchors = [q for q in pts if q is not p and (q[2] == "good" or p[2] == "shared-only")]
                a = min(anchors, key=lambda q: yd(p, q)) if anchors else None
                if (a is None or yd(p, a) > args.yards) and p[2] == "shared":
                    # nothing better nearby: another shared Data.lua point close by makes it an unsure pair
                    others = [q for q in pts if q is not p and q[2] == "shared"]
                    a = min(others, key=lambda q: yd(p, q)) if others else None
                if a is None:
                    continue
                d = yd(p, a)
                if d > args.yards or seen_at(p, a):
                    continue
                src = "Data, shared" if p[2] == "shared" else "shared only (not in Data.lua)"
                what = "own find or Wowhead" if a[2] == "good" else "Data, shared"
                note = "%s; %.0f yd from %.2f, %.2f (%s); never seen" % (src, d, a[0] * 100, a[1] * 100, what)
                if a[2] == "shared" and p[2] == "shared":
                    if seen_at(a, p):
                        pass  # the other one was seen: this one is the copy, a plain suspect
                    else:
                        pair = sorted([(p[0], p[1]), (a[0], a[1])])
                        unsure.append("-- %s [%d] %s: { %.4f, %.4f } and { %.4f, %.4f }, %.0f yd apart, neither seen"
                                      % (key, m, name, *pair[0], *pair[1], d))
                        continue
                found.setdefault(m, (name, []))[1].append((p[0], p[1], note))
                bands[0 if d < 70 else 1 if d < 100 else 2 if d < 125 else 3] += 1

        n = sum(len(v[1]) for v in found.values())
        summary.append("-- %s: %d suspects (<70 yd %d, 70-100 %d, 100-125 %d, 125+ %d)%s" % (
            key, n, *bands, ", %d maps skipped (no zone size)" % no_size if no_size else ""))
        if found:
            lines.append("  %s = {" % key)
            for m in sorted(found):
                name, pts = found[m]
                lines.append("    [%d] = { -- %s" % (m, name))
                lines += ["      { %.4f, %.4f }, -- %s" % p for p in pts]
                lines.append("    },")
            lines.append("  },")

    text = "\n".join(["-- Suspects for SLLCM_Retired (tools/suspects.py, --yards %g). Paste the ones you agree with." % args.yards]
                     + summary + [""] + lines
                     + (["", "-- Unsure: two shared-only Data.lua points close together, nothing better nearby"] + sorted(set(unsure)) if unsure else []))
    OUT.write_text(text + "\n", encoding="utf-8", newline="\n")
    print("\n".join(summary))
    print("unsure pairs: %d" % len(set(unsure)))
    print("written to", OUT)


if __name__ == "__main__":
    main()
