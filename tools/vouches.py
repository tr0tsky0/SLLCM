import re, time
from pathlib import Path
import lupa

ROOT = Path(r"C:\Users\shaun\Documents\Claude\WoW Addons\Ley Line Marker\SkyborneLeyLineConvergenceMarker")
SV = Path(r"D:\World of Warcraft\_forever_\WTF\Account\TR0TSKY\SavedVariables\SkyborneLeyLineConvergenceMarker-Dev.lua")
L = lupa.LuaRuntime()
L.execute(SV.read_text(encoding="utf-8"))
L.execute((ROOT / "Data.lua").read_text(encoding="utf-8"))
db = L.globals().SkyborneMarkerDB
data = L.globals().SLLCM_Data

# Data.lua tags per point, in list order
src = (ROOT / "Data.lua").read_text(encoding="utf-8").split("SLLCM_Retired")[0]
tags = {}
for key in ("LeyLines", "ElementalConvergences"):
    block = re.search(key + r"\s*=\s*\{(.*?)\n  \},", src, re.S).group(1)
    for mid, name, body in re.findall(r"\[(\d+)\] = \{ -- ([^\n]*)\n(.*?)\n    \}", block, re.S):
        tags[(key, int(mid))] = (name.strip(), [t or "own" for _, _, t in re.findall(r"\{ ([\d.]+), ([\d.]+) \},?[ \t]*(?:-- ([^\n]*))?", body)])

def zonesum(lst):
    h = len(lst)
    for p in lst:
        h = (h * 131 + int(p[0] * 10000 + 0.5) * 10007 + int(p[1] * 10000 + 0.5)) % 46656
    s = ""
    B = "0123456789abcdefghijklmnopqrstuvwxyz"
    for _ in range(3):
        s = B[h % 36] + s; h //= 36
    return s

now = int(time.time())
KEEP = 14 * 86400
for key in ("LeyLines", "ElementalConvergences"):
    vk = db.vouch[key]
    total = vouched = susp = nodata = 0
    print(f"== {key}")
    rows = []
    for mid in sorted(data[key].keys()):
        name, tg0 = tags.get((key, mid), ("?", []))
        ret = L.globals().SLLCM_Retired[key]
        rl = ret[mid] if ret else None
        rpts = [(rl[i][1], rl[i][2]) for i in range(1, len(rl) + 1)] if rl else []
        lst, tg = [], []
        for i in range(1, len(data[key][mid]) + 1):
            x, y = data[key][mid][i][1], data[key][mid][i][2]
            if any(abs(x - a) < 0.002 and abs(y - b) < 0.002 for a, b in rpts): continue
            lst.append((x, y)); tg.append(tg0[i-1] if i-1 < len(tg0) else "?")
        v = vk[mid] if vk else None
        total += len(lst)
        if v is None:
            nodata += len(lst); rows.append(f"  [{mid}] {name}: {len(lst)} nodes, no vouches"); continue
        if v.sum != zonesum(lst):
            nodata += len(lst); rows.append(f"  [{mid}] {name}: checksum mismatch"); continue
        seen = {i for i in range(1, len(lst) + 1) if v.seen[i] and now - v.seen[i] <= KEEP}
        active = v.active if now - v.activeAt <= KEEP else 0
        vouched += len(seen)
        un = [i for i in range(1, len(lst) + 1) if i not in seen]
        flag = active >= 5
        if flag: susp += len(un)
        last = max([v.seen[i] for i in seen] or [0])
        rows.append(f"  [{mid}] {name}: {len(seen)}/{len(lst)} vouched, active {active}, answers {v.answers}, newest {time.strftime('%m-%d %H:%M', time.localtime(last)) if last else '-'}")
        for i in un:
            rows.append(f"      {'SUSPECT' if flag else 'unvouched'} #{i} {{ {lst[i-1][0]:.4f}, {lst[i-1][1]:.4f} }} -- {tg[i-1] if i-1 < len(tg) else '?'}")
    print(f"  nodes {total}, vouched {vouched}, suspects (zone active 5+) {susp}, no usable vouch data {nodata}")
    print("\n".join(rows))

# vouch rate by source tag, zones with active 5+
from collections import Counter
for key in ("LeyLines", "ElementalConvergences"):
    c = Counter(); vk = db.vouch[key]
    for mid in data[key].keys():
        name, tg0 = tags.get((key, mid), ("?", []))
        ret = L.globals().SLLCM_Retired[key]; rl = ret[mid] if ret else None
        rpts = [(rl[i][1], rl[i][2]) for i in range(1, len(rl) + 1)] if rl else []
        lst, tg = [], []
        for i in range(1, len(data[key][mid]) + 1):
            x, y = data[key][mid][i][1], data[key][mid][i][2]
            if any(abs(x - a) < 0.002 and abs(y - b) < 0.002 for a, b in rpts): continue
            lst.append((x, y)); tg.append(tg0[i-1])
        v = vk[mid] if vk else None
        if v is None or v.sum != zonesum(lst) or v.active < 5: continue
        for i, t in enumerate(tg, 1):
            src = "Wowhead" if "Wowhead" in t else ("shared" if "shared" in t else "own")
            c[(src, bool(v.seen[i]))] += 1
    print(key, {s: f"{c[(s,True)]}/{c[(s,True)]+c[(s,False)]}" for s in ("own", "Wowhead", "shared")})

# unvouched shared nodes: nearest vouched-or-good point in yards
import math
zs = db.zoneSizes
buckets = Counter(); actives = Counter(); out = []
for key in ("LeyLines", "ElementalConvergences"):
    vk = db.vouch[key]
    for mid in sorted(data[key].keys()):
        name, tg0 = tags.get((key, mid), ("?", []))
        ret = L.globals().SLLCM_Retired[key]; rl = ret[mid] if ret else None
        rpts = [(rl[i][1], rl[i][2]) for i in range(1, len(rl) + 1)] if rl else []
        lst, tg = [], []
        for i in range(1, len(data[key][mid]) + 1):
            x, y = data[key][mid][i][1], data[key][mid][i][2]
            if any(abs(x - a) < 0.002 and abs(y - b) < 0.002 for a, b in rpts): continue
            lst.append((x, y)); tg.append(tg0[i-1])
        v = vk[mid] if vk else None
        if v is None or v.sum != zonesum(lst): continue
        actives[(key, v.active)] += 1
        if v.active < 5: continue
        z = zs[mid] if zs else None
        if not z: continue
        w, h = z[1], z[2]
        for i, t in enumerate(tg, 1):
            if "shared" not in t or "Wowhead" in t or v.seen[i]: continue
            x, y = lst[i-1]
            best = min([math.hypot((x-a)*w, (y-b)*h) for j, (a, b) in enumerate(lst, 1) if j != i and (v.seen[j] or "shared" not in tg[j-1] or "Wowhead" in tg[j-1])] or [9999])
            b = "<70" if best < 70 else "<150" if best < 150 else "<300" if best < 300 else "300+"
            buckets[(key, b)] += 1
print(sorted(actives.items()))
print(sorted(buckets.items()))
