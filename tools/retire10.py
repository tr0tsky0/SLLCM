"""Retire every Data.lua point nobody vouched in a zone with 10+ crowd active days (any source).
Used for v1.7.0 (2026-11-26). Kept: points within PROTECT_YARDS of our own sighting (db.seen) or a found-list point.

Usage: python tools/retire10.py [--prev <Data.lua the players' vouches were made on>] [--write]

Vouch indices and checksums cover the Data.lua the released copy runs. If Data.lua has changed since that
release, pass it with --prev (e.g. `git show v1.6.1:SkyborneLeyLineConvergenceMarker/Data.lua > prev.lua`);
the default is the current Data.lua. Without --write it only prints counts.
"""
import math, re, sys, time
from pathlib import Path
import lupa

ROOT = Path(__file__).resolve().parent.parent / "SkyborneLeyLineConvergenceMarker"
DATA = ROOT / "Data.lua"
PREV = Path(sys.argv[sys.argv.index("--prev") + 1]) if "--prev" in sys.argv else DATA
SV = Path(r"D:\World of Warcraft\_forever_\WTF\Account\TR0TSKY\SavedVariables\SkyborneLeyLineConvergenceMarker-Dev.lua")
KEYS = ("LeyLines", "ElementalConvergences")
MIN_ACTIVE = 10
KEEP = 14 * 86400
PROTECT_YARDS = 35

L = lupa.LuaRuntime()
L.execute(SV.read_text(encoding="utf-8"))
db = L.globals().SkyborneMarkerDB


def conv(t):
    out = {}
    if t is None:
        return out
    for mid, lst in t.items():
        out[int(mid)] = [tuple(p.values()) for p in lst.values()]
    return out


def parse(text):
    """{key: {mid: (name, [(xs, ys, tag)])}} for SLLCM_Data and SLLCM_Retired, coords kept as text."""
    data_src, ret_src = text.split("SLLCM_Retired = {")
    res = []
    for src in (data_src, ret_src):
        out = {}
        for key in KEYS:
            m = re.search(key + r" = \{\n(.*?)\n  \},", src, re.S)
            zones = {}
            for mid, name, body in re.findall(r"    \[(\d+)\] = \{ -- ([^\n]*)\n(.*?)\n    \},", m.group(1), re.S):
                zones[int(mid)] = (name.strip(), [(x, y, (t or "own").strip()) for x, y, t in
                                                   re.findall(r"\{ ([\d.]+), ([\d.]+) \},?[ \t]*(?:-- ([^\n]*))?", body)])
            out[key] = zones
        res.append(out)
    return res


def zonesum(lst):
    h = len(lst)
    for x, y in lst:
        h = (h * 131 + int(x * 10000 + 0.5) * 10007 + int(y * 10000 + 0.5)) % 46656
    B = "0123456789abcdefghijklmnopqrstuvwxyz"
    s = ""
    for _ in range(3):
        s = B[h % 36] + s
        h //= 36
    return s


prev_data, prev_ret = parse(PREV.read_text(encoding="utf-8"))
cur_text = DATA.read_text(encoding="utf-8")
cur_data, cur_ret = parse(cur_text)
zs = {int(k): tuple(v.values()) for k, v in db.zoneSizes.items()}
now = int(time.time())

new = {k: {} for k in KEYS}
stats = {}
for key in KEYS:
    vk = db.vouch[key]
    seen_own = conv(db.seen[key])
    found = conv(db.found[key])
    for mid, (name, pts) in sorted(prev_data[key].items()):
        rp = [(float(x), float(y)) for x, y, _ in prev_ret[key].get(mid, ("", []))[1]]
        lst = [(float(x), float(y), xs, ys, t) for x, y, t in pts for xs, ys in [(x, y)]
               if not any(abs(float(x) - a) < 0.002 and abs(float(y) - b) < 0.002 for a, b in rp)]
        v = vk[mid] if vk else None
        if v is None or v.sum != zonesum([(p[0], p[1]) for p in lst]):
            continue
        active = v.active if now - v.activeAt <= KEEP else 0
        if active < MIN_ACTIVE:
            continue
        z = zs.get(mid)
        yd = lambda a, b: math.hypot((a[0] - b[0]) * z[0], (a[1] - b[1]) * z[1])
        cur_pts = [(float(x), float(y)) for x, y, _ in cur_data[key][mid][1]]
        for i, (x, y, xs, ys, tag) in enumerate(lst, 1):
            if v.seen[i] and now - v.seen[i] <= KEEP:
                continue
            src = "Wowhead" if "Wowhead" in tag else ("shared" if "shared" in tag else "own")
            if any(yd((x, y), p) <= PROTECT_YARDS for p in seen_own.get(mid, [])):
                stats[(key, src, "kept: own sighting")] = stats.get((key, src, "kept: own sighting"), 0) + 1
                continue
            if any(yd((x, y), p) <= PROTECT_YARDS for p in found.get(mid, [])):
                stats[(key, src, "kept: found")] = stats.get((key, src, "kept: found"), 0) + 1
                continue
            hit = [p for p in cur_pts if (p[0], p[1]) != (x, y) and yd((x, y), p) <= 10]
            if hit:
                print("WARN would also hide", key, mid, (x, y), hit)
            stats[(key, src, "retire")] = stats.get((key, src, "retire"), 0) + 1
            new[key].setdefault(mid, (name, []))[1].append(
                f"      {{ {xs}, {ys} }}, -- Data, {tag}; never vouched in {active} active days")

for k in sorted(stats):
    print(k, stats[k])
print({k: sum(len(l) for _, l in new[k].values()) for k in KEYS})

if "--write" in sys.argv:
    head, ret_src = cur_text.split("SLLCM_Retired = {")
    blocks = {}
    for key in KEYS:
        m = re.search(key + r" = \{\n(.*?)\n  \},", ret_src, re.S)
        zones = {}
        for mid, name, body in re.findall(r"    \[(\d+)\] = \{ -- ([^\n]*)\n(.*?)\n    \},", m.group(1), re.S):
            zones[int(mid)] = (name.strip(), body.split("\n"))
        for mid, (name, lines) in new[key].items():
            zones.setdefault(mid, (name, []))[1].extend(lines)
        body = "\n".join(f"    [{mid}] = {{ -- {zones[mid][0]}\n" + "\n".join(zones[mid][1]) + "\n    }," for mid in sorted(zones))
        ret_src = ret_src[:m.start(1)] + body + ret_src[m.end(1):]
    marker = "  -- 2026-11-21: shared copies under 150 yd from an own-find, Wowhead or vouched point, nobody vouched (crowd vouches, 6 active days)\n"
    assert marker in ret_src
    ret_src = ret_src.replace(marker, marker + "  -- 2026-11-26: every point nobody vouched in a zone with 10+ crowd active days, any source, unless seen by us or in a found list\n", 1)
    DATA.write_text(head + "SLLCM_Retired = {" + ret_src, encoding="utf-8", newline="\n")
    print("written")
