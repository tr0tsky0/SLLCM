"""Retired nodes, last-seen stamps and vouches (SkyborneLeyLineConvergenceMarker.lua), run under lupa.

Usage: python tools/test_nodes.py
"""
import sys
from pathlib import Path

import lupa

ROOT = Path(__file__).resolve().parent.parent / "SkyborneLeyLineConvergenceMarker"
NOW = 1800000000
DAY = 86400

MOCKS = r"""
timers, texts, frames = {}, {}, {}
function dummy()
  return setmetatable({}, { __index = function(_, k)
    if k == "SetText" then return function(self, s) texts[#texts + 1] = s end end
    return dummy()
  end, __call = function() return dummy() end })
end
function CreateFrame()
  local f, s = dummy(), {}
  rawset(f, "SetScript", function(self, k, fn) s[k] = fn end)
  rawset(f, "_s", s)
  frames[#frames + 1] = f
  return f
end
function CreateFromMixins() return {} end
MapCanvasPinMixin, MapCanvasDataProviderMixin = {}, {}
WorldMapFrame = { AddDataProvider = function() end, IsShown = function() return false end }
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
-- every map 1000 yd square
C_Map = { GetWorldPosFromMapPos = function(m, v) return 1, { x = v.x * 1000, y = v.y * 1000 } end,
  GetMapInfo = function(m) return { name = "Zone" .. m } end }
function CreateVector2D(x, y) return { x = x, y = y } end
function UnitFactionGroup() return "Alliance" end
function strsplit(sep, s)
  local out = {}
  for part in (s .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = part end
  return table.unpack(out)
end
format, date, tinsert = string.format, os.date, table.insert
UISpecialFrames, StaticPopupDialogs, SlashCmdList = {}, {}, {}
Settings, MinimalSliderWithSteppersMixin = dummy(), dummy()
"""

# zone 1: Data A..H (B retired), shared C2, shared D2 (retired); a retired copy 65 yd east of A
DATA = """
SLLCM_Data = { LeyLines = { [1] = {
  { 0.1, 0.1 }, { 0.5, 0.5 }, { 0.2, 0.1 }, { 0.3, 0.1 }, { 0.4, 0.1 }, { 0.6, 0.1 }, { 0.7, 0.1 }, { 0.8, 0.1 },
} }, ElementalConvergences = {} }
SLLCM_Retired = { LeyLines = { [1] = { { 0.5, 0.5 }, { 0.9, 0.9 }, { 0.165, 0.1 } } }, ElementalConvergences = {} }
SkyborneMarkerDB = { shared = { LeyLines = { [1] = { { 0.3, 0.3 }, { 0.9, 0.9 } } } } }
"""


def world(data=DATA):
    L = lupa.LuaRuntime()
    L.execute(MOCKS)
    g = L.globals()
    g.GetServerTime = lambda: NOW
    ns = L.eval("{}")
    ns.RegisterAboutPage = lambda c: None
    ns.CrowdReports = lambda m: L.eval("{}")
    L.execute(data)
    src = (ROOT / "SkyborneLeyLineConvergenceMarker.lua").read_text(encoding="utf-8")
    L.eval("function(src, ns) assert(load(src))('SLLCM', ns) end")(src, ns)
    L.eval("function() frames[#frames]._s.OnEvent(frames[#frames], 'ADDON_LOADED', 'SLLCM') end")()
    L.execute("for _, fn in ipairs(timers) do fn() end")

    def export():
        L.eval("function() SlashCmdList.LEYLINEMARKER('export') end")()
        return L.eval("texts[#texts]") or ""
    return L, ns, export


def main():
    results = []

    def check(name, ok, detail=""):
        results.append(ok)
        print("%-4s %s%s" % ("ok" if ok else "FAIL", name, (": " + detail) if not ok else ""))

    # retiring
    L, ns, export = world()
    data = L.eval("SLLCM_Data.LeyLines[1]")
    check("retired point taken out of Data", len(data) == 7 and data[2][1] == 0.2, str(len(data)))
    sh = L.eval("SkyborneMarkerDB.shared.LeyLines[1]")
    check("retired shared location purged", len(sh) == 1 and sh[1][1] == 0.3)
    check("retired not learned again", not ns.LearnShared(1, 0.9, 0.9))
    check("new location still learned", ns.LearnShared(1, 0.7, 0.7) is True)

    # local stamps: 6 active days; A seen on the last of them, new E daily, C never, retired D once
    for d in range(6, 0, -1):
        ns.StampSeen(1, 0.7, 0.7, NOW - d * DAY)
    ns.StampSeen(1, 0.1, 0.1, NOW - 1 * DAY + 10)
    ns.StampSeen(1, 0.9, 0.9, NOW - 2 * DAY)
    check("stamps merge per spot", len(L.eval("SkyborneMarkerDB.seen.LeyLines[1]")) == 3)
    text = export()
    check("never-seen shared C is suspect", "{ 0.3000, 0.3000 }, -- shared, last seen never, 6 days" in text, text)
    check("A, seen lately, isn't", "{ 0.1000, 0.1000 }, --" not in text, text)
    check("E, seen daily, isn't", "{ 0.7000, 0.7000 }, --" not in text, text)
    check("retired D seen is listed", "{ 0.9000, 0.9000 }, -- last seen" in text, text)
    check("a retired copy 65 yd from A leaves A in Data", data[1][1] == 0.1, str(data[1][1]))
    check("...and A's sightings don't make the copy look seen", "0.1650" not in text, text)

    # days run from 10:00 UTC: an American evening (19:00 to 03:00 UTC) is one day
    L2, ns2, _ = world()
    evening = NOW - NOW % DAY - 5 * DAY + 19 * 3600
    ns2.StampSeen(2, 0.5, 0.5, evening)
    ns2.StampSeen(2, 0.6, 0.6, evening + 8 * 3600)
    check("an evening across UTC midnight is one active day",
          len(list(L2.eval("SkyborneMarkerDB.activeDays.LeyLines[2]").keys())) == 1)
    # days saved under UTC midnights are rebuilt from the stamps, once
    L3, ns3, _ = world(DATA.replace("SkyborneMarkerDB = {", """SkyborneMarkerDB = {
      seen = { LeyLines = { [2] = { { 0.5, 0.5, %d }, { 0.6, 0.6, %d } } } },
      activeDays = { LeyLines = { [2] = { [1] = true, [2] = true, [3] = true } } },""" % (evening, evening + 8 * 3600)))
    days3 = list(L3.eval("SkyborneMarkerDB.activeDays.LeyLines[2]").keys())
    check("old UTC days rebuilt from stamps", len(days3) == 1 and L3.eval("SkyborneMarkerDB.dayStart") == 36000,
          str(days3))

    # vouches: an answerer that saw Data nodes 1 (A) and 8 (H, needs a second char) lately, zone active 6 days
    La, nsa, _ = world()
    for d in range(6, 0, -1):
        nsa.StampSeen(1, 0.7, 0.7, NOW - d * DAY)
    nsa.StampSeen(1, 0.1, 0.1, NOW - DAY + 10)
    nsa.StampSeen(1, 0.8, 0.1, NOW - DAY + 10)
    entries = list(nsa.VouchEntries().values())
    check("one V entry per active zone", len(entries) == 1 and entries[0].startswith("1,6,"), str(entries))
    bits = entries[0].split(",")[3] if entries else ""
    check("...with a bit per node", bits == "BB", bits)

    Lb, nsb, exportb = world()  # the asker: heard nothing itself
    check("a matching zone is merged", nsb.MergeVouch(entries[0]) is True)
    text = exportb()
    check("crowd: unvouched Data nodes are suspect",
          all("{ %.4f, 0.1000 }, -- Data, last seen never, 0 days, crowd 6 days, 1 answers" % x in text
              for x in (0.2, 0.3, 0.4, 0.6, 0.7)), text)
    check("crowd: vouched A and H aren't", "{ 0.1000, 0.1000 }" not in text and "{ 0.8000, 0.1000 }" not in text, text)
    check("crowd: shared C isn't judged by vouches", "0.3000, 0.3000 }, --" not in text, text)

    Lc, nsc, _ = world(DATA.replace("{ 0.8, 0.1 },", "{ 0.8, 0.1 }, { 0.85, 0.2 },"))  # a newer release
    check("another release's zone is skipped", nsc.MergeVouch(entries[0]) is False)
    check("a quiet zone vouches nothing", not list(world()[1].VouchEntries().values()))

    print("all passed" if all(results) else "FAILED")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
