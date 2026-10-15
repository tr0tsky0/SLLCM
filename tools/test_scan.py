"""Simulates Scan.lua against a fake minimap and checks found nodes land where they really are.

Runs the real SkyborneLeyLineConvergenceMarker/Scan.lua in lupa with mocked WoW APIs. The fake minimap
draws blips with its own forward model (world -> minimap), written independently of Scan.lua's
inverse, including a rotating minimap where the player's facing is up instead of north.

    python tools/test_scan.py
"""
import math
import sys
from pathlib import Path

import lupa

ROOT = Path(__file__).resolve().parent.parent
SCAN = (ROOT / "SkyborneLeyLineConvergenceMarker" / "Scan.lua").read_text(encoding="utf-8")

ZONE_W, ZONE_H = 3000.0, 2000.0  # yards
VIEW_RADIUS = 233.0              # yards from centre to edge
MM_SIZE, MM_LEFT, MM_BOTTOM, MM_SCALE = 140.0, 1000.0, 500.0, 0.8
BLIP_SIZES = (6.0, 12.0)         # blip tooltip area half-widths to try, minimap units (in game it's 10+)
YPP = VIEW_RADIUS / (MM_SIZE / 2)  # yards per minimap unit
TOLERANCE = math.sqrt(2) * YPP     # yards, a scan: the 2-unit fine grid is off by up to 1 unit per axis
HOVER_TOLERANCE = max(BLIP_SIZES) * YPP  # yards: a resting cursor is anywhere on the blip


def project(node, player, facing, rotate, wrong_way=False):
    """World -> minimap local units, the way the game draws it. GetPlayerFacing is radians
    counter-clockwise from north; with rotation on, the facing direction is up."""
    east = (node[0] - player[0]) * ZONE_W
    north = -(node[1] - player[1]) * ZONE_H  # map y grows southward
    if rotate:
        f = -facing if wrong_way else facing
        fwd = (-math.sin(f), math.cos(f))   # facing direction in (east, north)
        right = (math.cos(f), math.sin(f))  # 90 degrees clockwise of it
        sx, sy = east * right[0] + north * right[1], east * fwd[0] + north * fwd[1]
    else:
        sx, sy = east, north
    ypp = VIEW_RADIUS / (MM_SIZE / 2)
    return MM_SIZE / 2 + sx / ypp, MM_SIZE / 2 + sy / ypp


def simulate(nodes, player, facing, rotate, controller=False, pointer=None, wrong_way=False, blip_half=6.0):
    """Returns the zone positions Scan.lua reports. Without a controller it runs one full scan;
    with one, the controller's SoftCursor sits at `pointer` (minimap units) for a few watch ticks."""
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = L.globals()
    found, tickers, state = [], {}, {"point": None}
    blips = [project(n, player, facing, rotate, wrong_way) for n in nodes]

    def tooltip_lines(pt):
        lines = []
        if pt is None:
            return lines
        lx, ly = pt
        for bx, by in blips:
            if abs(lx - bx) <= blip_half and abs(ly - by) <= blip_half:
                lines.append("|cffffffffLey Line|r")
        if abs(lx - 30) < 5 and abs(ly - 30) < 5:
            lines.append("Copper Vein")  # something else on the minimap
        return lines

    L.execute("""
      _frames = {}
      function CreateFrame()
        local f = { shown = true }
        function f:SetScript(k, fn) self[k] = fn end
        function f:Show() self.shown = true end
        function f:Hide() self.shown = false end
        _frames[#_frames + 1] = f
        return f
      end
    """)

    def update_mouseover(_, x, y):
        state["point"] = (x / MM_SCALE - MM_LEFT, y / MM_SCALE - MM_BOTTOM)

    def minimap_mouseover():
        # with a controller the game points the minimap's mouseover at its own cursor
        lines = tooltip_lines(pointer if controller else state["point"])
        return L.table_from({"lines": L.table_from([L.table_from({"leftText": t}) for t in lines])})

    mm = L.table_from({})
    mm.SetUsingSoftCursor = lambda self, on: None
    mm.UpdateMouseoverAtPoint = update_mouseover
    mm.GetEffectiveScale = lambda self: MM_SCALE
    mm.GetLeft = lambda self: MM_LEFT
    mm.GetBottom = lambda self: MM_BOTTOM
    mm.GetSize = lambda self: (MM_SIZE, MM_SIZE)
    mm.IsVisible = lambda self: True
    mm.IsMouseOver = lambda self: False
    mm.GetZoom = lambda self: 0
    g.Minimap = mm

    g.C_TooltipInfo = L.table_from({"GetMinimapMouseover": minimap_mouseover})
    g.C_Minimap = L.table_from({"GetViewRadius": lambda: VIEW_RADIUS})
    g.C_Map = L.table_from({
        "GetBestMapForUnit": lambda unit: 1436,
        "GetPlayerMapPosition": lambda m, unit: L.table_from({"x": player[0], "y": player[1]}),
    })
    g.C_Timer = L.table_from({"NewTicker": lambda secs, fn: tickers.__setitem__(secs, fn)})
    g.GetCVar = lambda k: "1" if (k == "rotateMinimap" and rotate) else "0"
    g.GetCVarBool = lambda k: k == "GamePadEnable"  # on for keyboard players too: must not matter
    g.InputUtil = L.table_from({"IsGamepadUIEnabled": lambda: controller})
    g.GetPlayerFacing = lambda: facing
    g.GetTime = lambda: 0.0
    g.InCombatLockdown = lambda: False
    g.IsInInstance = lambda: False
    g.GameTooltip = L.table_from({"IsShown": lambda self: False})

    if pointer is not None:
        # the controller's SoftCursor, in a UI scale different from the minimap's
        cs = 0.64
        sc = L.table_from({})
        sc.IsShown = lambda self: True
        sc.GetEffectiveScale = lambda self: cs
        sc.GetCenter = lambda self: ((MM_LEFT + pointer[0]) * MM_SCALE / cs,
                                     (MM_BOTTOM + pointer[1]) * MM_SCALE / cs)
        g.SoftCursor = sc

    ns = L.table_from({})
    ns.ZoneSizeYards = lambda m: (ZONE_W, ZONE_H)
    ns.ScanEnabled = lambda: True
    ns.OnMinimapNode = lambda m, x, y: found.append((x, y))

    L.eval("function(src, ns) assert(load(src, 'Scan.lua'))('SLLCM', ns) end")(SCAN, ns)
    frame = L.eval("_frames[1]")

    if controller:
        for _ in range(3):
            tickers[0.1]()          # Watch: the cursor rests on the blip
        g.SoftCursor.IsShown = lambda self: False
        tickers[0.1]()              # cursor gone: the sample is recorded
    else:
        tickers[2]()                # MaybeScan starts a scan
        for _ in range(500):
            if not frame.shown:
                break
            frame.OnUpdate(frame)
    return found


def dist_yards(a, b):
    return math.hypot((a[0] - b[0]) * ZONE_W, (a[1] - b[1]) * ZONE_H)


def check(name, nodes, found, expect_ok=True, tolerance=TOLERANCE):
    errors = []
    ok = len(found) == len(nodes)
    for n in nodes:
        d = min((dist_yards(n, f) for f in found), default=float("inf"))
        errors.append(d)
        ok = ok and d <= tolerance
    status = "ok" if ok == expect_ok else "FAIL"
    detail = ", ".join("%.1f yd" % e for e in errors)
    print("%-4s %s: %d/%d found, error %s%s" % (status, name, len(found), len(nodes), detail,
                                                "" if expect_ok else " (expected to miss)"))
    return ok == expect_ok


def main():
    player = (0.5, 0.5)
    # three nodes within view: NE, SW, and nearly due west (map y grows south)
    nodes = [(0.5 + 120 / ZONE_W, 0.5 - 80 / ZONE_H),
             (0.5 - 60 / ZONE_W, 0.5 + 150 / ZONE_H),
             (0.5 - 190 / ZONE_W, 0.5 + 10 / ZONE_H)]
    good = True

    for half in BLIP_SIZES:
        good &= check("blip %g: rotation off" % half, nodes, simulate(nodes, player, 1.0, rotate=False, blip_half=half))
        for deg in (0, 45, 90, 135, 180, 230, 300):
            f = math.radians(deg)
            good &= check("blip %g: rotating, facing %d deg" % (half, deg), nodes,
                          simulate(nodes, player, f, rotate=True, blip_half=half))
    # standing on a node: the case that split into four in game (Redridge, 2026-10-14)
    good &= check("blip 12: standing on it", [player], simulate([player], player, 0.0, rotate=False, blip_half=12.0))

    # the test can tell a wrong rotation apart: rotating the drawing the other way must miss
    good &= check("sanity: drawn rotated the wrong way", nodes,
                  simulate(nodes, player, math.radians(70), rotate=True, wrong_way=True), expect_ok=False)

    # controller: no scan; the SoftCursor resting on one blip records it
    for deg in (0, 160):
        f = math.radians(deg)
        target = nodes[0]
        bx, by = project(target, player, f, rotate=True)
        found = simulate(nodes, player, f, rotate=True, controller=True, pointer=(bx + 2, by - 1))
        good &= check("controller cursor, facing %d deg" % deg, [target], found, tolerance=HOVER_TOLERANCE)

    print("all passed" if good else "FAILED")
    sys.exit(0 if good else 1)


if __name__ == "__main__":
    main()
