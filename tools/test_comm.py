"""Feeds channel messages to the real SkyborneLeyLineConvergenceMarker/Comm.lua (in lupa, WoW APIs mocked)
and checks how sightings (R / S) and Skyborne Compass's "not there" reports (XM / XS) combine.

    python tools/test_comm.py
"""
import sys
from pathlib import Path

import lupa

ROOT = Path(__file__).resolve().parent.parent
COMM = (ROOT / "SkyborneLeyLineConvergenceMarker" / "Comm.lua").read_text(encoding="utf-8")
NOW = 1_800_000_000
ZONE, CONTINENT, PHASE = 1413, 1414, "3301"


def world(sharing=True, queried=None):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = L.globals()
    state = {"sent": [], "timers": [], "learned": [], "lifetimes": []}
    L.execute("""
      _frames = {}
      function CreateFrame()
        local f = {}
        function f:RegisterEvent() end
        function f:SetScript(k, fn) self[k] = fn end
        _frames[#_frames + 1] = f
        return f
      end
      function strsplit(sep, s, limit)
        local out, start = {}, 1
        while true do
          if limit and #out == limit - 1 then out[#out + 1] = s:sub(start) break end
          local i = s:find(sep, start, true)
          if not i then out[#out + 1] = s:sub(start) break end
          out[#out + 1] = s:sub(start, i - 1)
          start = i + 1
        end
        return table.unpack(out)
      end
      function wipe(t) for k in pairs(t) do t[k] = nil end return t end
      format = string.format
      time, date = os.time, os.date
      Enum = { UIMapType = { Continent = 2, Zone = 3 } }
      function CreateVector2D(x, y) return { x = x, y = y } end
    """)
    g.GetServerTime = lambda: NOW
    g.GetTime = lambda: 100.0
    g.Ambiguate = lambda name, mode: name
    g.UnitName = lambda unit: ("Me", "")
    g.IsInInstance = lambda: False
    g.GetChannelName = lambda name: 5
    g.UnitGUID = lambda unit: "Creature-0-1-2-%s-123-1" % PHASE
    g.UnitExists = lambda unit: False
    g.WorldMapFrame = L.table_from({"IsShown": lambda self: False})
    g.SLLCM_Data = L.eval("{ LeyLines = { [1413] = { { 0.5, 0.5 } } } }")

    def map_info(m):
        if m == ZONE:
            return L.table_from({"mapID": ZONE, "mapType": 3})
        if m == CONTINENT:
            return L.table_from({"mapID": CONTINENT, "mapType": 2})
        return None

    g.C_Map = L.table_from({
        "GetMapInfo": map_info,
        "GetBestMapForUnit": lambda unit: ZONE,
        # the continent point used below sits on our zone node at 0.50, 0.50
        "GetMapInfoAtPosition": lambda m, x, y: map_info(ZONE),
        "GetWorldPosFromMapPos": lambda m, v: (1, L.table_from({"x": 1, "y": 2})),
        "GetMapPosFromWorldPos": lambda c, w, m: (m, L.table_from({"x": 0.5, "y": 0.5})),
    })
    g.C_Timer = L.table_from({
        "After": lambda secs, fn: state["timers"].append(fn),
        "NewTicker": lambda secs, fn: None,
    })

    def send(prefix, msg, kind, target):
        state["sent"].append(msg)
        return 0

    g.C_ChatInfo = L.table_from({"RegisterAddonMessagePrefix": lambda p: None, "SendAddonMessage": send})

    db = L.eval("{ crowd = true, found = { LeyLines = {} }, shared = { LeyLines = {} } }")
    db.crowd = sharing
    if queried:  # a /reload: the last world's saved Q times (see saved_queries) carry over
        db.crowdQueried = L.table_from({"A": L.table_from(queried)})
    ns = L.table_from({})
    ns.GetDB = lambda: db
    ns.Faction = lambda: L.table_from({"key": "LeyLines"})
    ns.Near = lambda m, x1, y1, x2, y2: abs(x1 - x2) < 0.02 and abs(y1 - y2) < 0.02
    ns.LearnShared = lambda m, x, y: state["learned"].append((m, x, y))
    ns.Print = lambda *a: None
    ns.Provider = L.table_from({"RefreshAllData": lambda self: None})
    ns.WatchGone = lambda m, r, t: state["lifetimes"].append((r.first, r.t, t))

    L.eval("function(src, ns) assert(load(src, 'Comm.lua'))('SLLCM', ns) end")(COMM, ns)
    events = L.eval("_frames[#_frames]")
    fire = L.eval("function(f, ...) f.OnEvent(f, ...) end")
    fire(events, "PLAYER_LOGIN")
    fire(events, "PLAYER_TARGET_CHANGED")  # learns the phase from the target's GUID

    def hear(msg, sender="Other Player"):
        fire(events, "CHAT_MSG_ADDON", "SLLCM", msg, "CHANNEL", sender)

    def at(m):
        seen = [(r.x, r.y, r.t) for r in ns.CrowdReports(m).values()]
        gone = [(r.x, r.y, r.t) for r in ns.CrowdGone(m).values()]
        return seen, gone

    def enter_phase(p):  # target an NPC in phase p (the first reading is tentative, so any other one replaces it)
        g.UnitGUID = lambda unit: "Creature-0-1-2-%s-%d-1" % (p, 100 + len(state["timers"]))
        fire(events, "PLAYER_TARGET_CHANGED")

    state["ns"], state["g"], state["enter_phase"], state["L"] = ns, g, enter_phase, L
    return hear, at, state, db


def saved_queries(db):
    return dict(db.crowdQueried.A.items())


def R(t, x=5000, y=5000, m=ZONE):
    return "R:1:A:%s:%d:%d:%d:%d" % (PHASE, m, x, y, NOW - t)


def XM(t, x=5000, y=5000, m=ZONE):
    return "XM:1:A:%s:%d:%d:%d:%d" % (PHASE, m, x, y, NOW - t)


def main():
    results = []

    def check(name, ok, detail=""):
        results.append(ok)
        print("%-4s %s%s" % ("ok" if ok else "FAIL", name, (": " + detail) if not ok else ""))

    hear, at, state, _ = world()
    hear(R(600))
    hear(XM(300))
    seen, gone = at(ZONE)
    check("newer XM ends a sighting", not seen and len(gone) == 1, "seen=%s gone=%s" % (seen, gone))
    check("...and logs its lifetime", state["lifetimes"] == [(NOW - 600, NOW - 600, NOW - 300)], str(state["lifetimes"]))

    hear(R(100))
    seen, gone = at(ZONE)
    check("newer R brings it back", len(seen) == 1 and not gone, "seen=%s gone=%s" % (seen, gone))

    hear, at, state, _ = world()
    hear(XM(300))
    hear(R(600))
    seen, gone = at(ZONE)
    check("older R doesn't undo a newer XM", not seen and len(gone) == 1, "seen=%s gone=%s" % (seen, gone))
    check("...but its location is still learned", len(state["learned"]) == 1, str(state["learned"]))

    hear, at, state, _ = world()
    hear(R(300))
    hear(XM(600))
    seen, gone = at(ZONE)
    check("older XM doesn't end a newer sighting", len(seen) == 1 and not gone, "seen=%s gone=%s" % (seen, gone))

    hear, at, state, _ = world()
    hear(XM(300))
    check("XM never teaches a location", not state["learned"], str(state["learned"]))

    hear, at, state, _ = world()
    hear(XM(300, x=5000, y=5000, m=CONTINENT))
    seen, gone = at(ZONE)
    check("continent XM lands on the zone", len(gone) == 1, "gone=%s" % gone)

    hear, at, state, _ = world()
    hear("XS:1:A:%s:%d,5000,5000,%d;%d,7000,7000,%d" % (PHASE, ZONE, NOW - 300, ZONE, NOW - 200))
    seen, gone = at(ZONE)
    check("XS entries are stored as not there", len(gone) == 2 and not seen, "seen=%s gone=%s" % (seen, gone))

    # we hold a sighting for the phase, a Q comes, then someone's XS: our S must still go out
    hear, at, state, _ = world()
    hear(R(300))
    hear("Q:1:A:%s" % PHASE)
    hear("XS:1:A:%s:%d,7000,7000,%d" % (PHASE, ZONE, NOW - 200))
    for fn in list(state["timers"]):
        fn()
    replies = [m for m in state["sent"] if m.startswith("S:")]
    check("an XS doesn't silence our S reply", len(replies) == 1, str(state["sent"]))
    check("...and our S carries no not-there", replies and "7000" not in replies[0], str(replies))

    hear, at, state, _ = world()
    hear(R(300))
    hear("Q:1:A:%s" % PHASE)
    hear("S:1:A:%s:%d,5000,5000,%d" % (PHASE, ZONE, NOW - 300))
    for fn in list(state["timers"]):
        fn()
    check("another S still silences ours", not [m for m in state["sent"] if m.startswith("S:")], str(state["sent"]))

    hear, at, state, db = world()
    hear(R(600))
    hear(XM(300))
    reports = db.crowdReports.A[ZONE]
    check("Mapzeroth's view (crowdReports) drops the ended sighting", reports is None or len(reports) == 0,
          str(reports and list(reports.values())))

    # sharing off: our own sighting is kept and shown, nothing is sent, others' held from before don't show
    hear, at, state, db = world(sharing=True)
    hear(R(600, x=7000, y=7000))  # someone else's, heard while sharing was on
    db.crowd = False
    state["ns"].OnConfirmed(ZONE, 0.5, 0.5, NOW - 60)
    for fn in list(state["timers"]):
        fn()
    seen, gone = at(ZONE)
    check("sharing off: own sighting kept and shown", seen == [(0.5, 0.5, NOW - 60)], "seen=%s" % seen)
    check("sharing off: nothing sent", not state["sent"], str(state["sent"]))

    # someone else's Q for a phase does for ours (we hear its answers); so does one from just before a /reload
    def questions(state):
        return [m for m in state["sent"] if m.startswith("Q:")]

    hear, at, state, db = world()
    state["ns"].SetCrowdEnabled(True)  # on the channel: Query may ask
    state["enter_phase"]("4000")
    check("a new phase is asked about", questions(state) == ["Q:1:A:4000"], str(state["sent"]))
    hear("Q:1:A:4100")
    state["enter_phase"]("4100")
    check("a phase someone else just asked about isn't", questions(state) == ["Q:1:A:4000"], str(state["sent"]))

    hear, at, state, db = world(queried=saved_queries(db))  # /reload
    state["g"].GetServerTime = lambda: NOW + 240
    state["ns"].SetCrowdEnabled(True)
    state["enter_phase"]("4100")
    state["enter_phase"]("4000")
    check("nor either of them after a /reload 4 min later", not questions(state), str(state["sent"]))

    hear, at, state, db = world(queried=saved_queries(db))
    state["g"].GetServerTime = lambda: NOW + 360
    state["ns"].SetCrowdEnabled(True)
    state["enter_phase"]("4100")
    check("but 6 min after the Q it is", questions(state) == ["Q:1:A:4100"], str(state["sent"]))

    # an F answer: self-found locations recorded on the continent map go out on the zone, and are checked
    # against Data.lua and the L answers heard meanwhile there (the mock puts any continent point at 0.50, 0.50)
    for name, has_data, heard, want in [
        ("a continent-recorded find goes out on the zone", False, None, ["L:1:A:%d,5000,5000" % ZONE]),
        ("...not if Data.lua has it there", True, None, []),
        ("...nor if an L heard meanwhile had it on the zone", False, "L:1:A:%d,5000,5000" % ZONE, []),
    ]:
        hear, at, state, db = world()
        if not has_data:
            state["g"].SLLCM_Data = state["L"].eval("{ LeyLines = {} }")
        db.found.LeyLines[CONTINENT] = state["L"].eval("{ { 0.3, 0.7 } }")
        hear("F:1:A", sender="Asker")
        if heard:
            hear(heard)
        for fn in list(state["timers"]):
            fn()
        sent = [m for m in state["sent"] if m.startswith("L:")]
        check(name, sent == want, str(sent))

    # the channel: greyed out (still listed, every send refused), then a notice that we left it
    # who_drops: the server answers our /chatwho with INVALID_NAME and the client drops the channel (11 Nov)
    def channel_world(greyed=True, listed=True, who_drops=False):
        hear, at, state, db = world()
        g, L = state["g"], state["L"]
        calls, printed = [], []
        state["calls"], state["printed"], state["result"] = calls, printed, 7
        state["greyed"], state["listed"], state["now"] = greyed, listed, 100.0
        g.GetTime = lambda: state["now"]
        g.GetChannelList = lambda: (1, "General", False, 5, "SLLCMShareA", state["greyed"])
        g.GetChannelName = lambda name: 5 if state["listed"] else 0
        lua_fn = L.eval("function(f) return function(...) return f(...) end end")  # ChatCall wants Lua functions

        def who(name):
            calls.append("who")
            if who_drops:
                state["listed"] = False

        def join(name):
            calls.append("join")
            state["listed"], state["greyed"] = True, False

        g.ListChannelByName = lua_fn(who)
        g.LeaveChannelByName = lua_fn(lambda name: calls.append("leave"))
        g.JoinTemporaryChannel = lua_fn(join)

        def send(prefix, msg, kind, target):
            state["sent"].append(msg)
            return state["result"]
        g.C_ChatInfo = L.table_from({"RegisterAddonMessagePrefix": lambda p: None, "SendAddonMessage": send})
        state["ns"].Print = lambda fmt, *a: printed.append(fmt % a if a else fmt)
        return hear, state

    def run_timers(state, limit=50):
        while state["timers"] and limit > 0:
            state["timers"].pop(0)()
            limit -= 1

    hear, state = channel_world(greyed=True)
    state["ns"].SetCrowdEnabled(True)
    run_timers(state)
    check("a greyed-out channel found on joining is /chatwho'd, then left and rejoined",
          state["calls"] == ["who", "leave", "join"], str(state["calls"]))

    hear, state = channel_world(greyed=True, who_drops=True)
    state["ns"].SetCrowdEnabled(True)
    notice_args = ("INVALID_NAME", "", "", "5. SLLCMShareA", "", "", 0, 5, "SLLCMShareA")
    L = state["L"]
    L.eval("function(f, ...) f.OnEvent(f, ...) end")(L.eval("_frames[#_frames]"), "CHAT_MSG_CHANNEL_NOTICE_USER",
                                                      *notice_args)  # the server's answer to the /chatwho
    run_timers(state)
    check("...dropped by the client after the /chatwho: joined fresh, no leave", state["calls"] == ["who", "join"],
          str(state["calls"]))

    # a revive at login, then sends refused 20 s later: a second one is still allowed, a third that soon isn't
    hear, state = channel_world(greyed=True)
    hear("Q:1:A:%s" % PHASE)  # someone just asked about our phase: nothing to send after the login revive
    state["ns"].SetCrowdEnabled(True)
    run_timers(state)
    state["greyed"], state["now"] = True, 120.0
    state["enter_phase"]("4000")
    run_timers(state)
    check("a revive at login leaves one for the first refused send", state["calls"].count("who") == 2,
          str(state["calls"]))
    check("...but not a third so soon", any("pausing" in p for p in state["printed"]) or
          any("paused" in p for p in state["printed"]), str(state["printed"]))

    # /sllcm share found says "asked" only once the F is out, and "not sent" if it's dropped
    hear, state = channel_world(greyed=False)
    state["result"] = 0
    state["ns"].SetCrowdEnabled(True)
    state["ns"].ShareCommand("found")
    check("share found: \"asked\" once the F goes out", any(p.startswith("found: asked") for p in state["printed"])
          and "F:1:A" in state["sent"], str(state["printed"]))

    hear, state = channel_world(greyed=True)
    state["ns"].SetCrowdEnabled(True)
    run_timers(state)
    state["greyed"] = True  # still greyed after the revive, and none allowed yet
    state["ns"].ShareCommand("found")
    run_timers(state)
    check("...not \"asked\" when it's refused", not any(p.startswith("found: asked") for p in state["printed"]),
          str(state["printed"]))
    check("...but \"not sent\"", any(p.startswith("found: not sent") for p in state["printed"]),
          str(state["printed"]))
    state["ns"].ShareCommand("found")
    check("...and while paused it says so at once", state["printed"][-1].startswith("found: not sent, sharing is paused"),
          str(state["printed"][-1:]))

    hear, state = channel_world(greyed=False)
    state["ns"].SetCrowdEnabled(True)  # listed and not greyed out: nothing to do, but Query may ask now
    state["enter_phase"]("4000")  # a Q goes out, and is refused
    run_timers(state)
    calls = state["calls"]
    check("refused sends revive the channel", calls == ["who", "leave", "join"], str(calls))
    check("...refused again: sharing pauses and says so",
          any("paused" in p for p in state["printed"]), str(state["printed"]))
    check("...and never says to relog", not any("relog" in p.lower() or "log out" in p.lower()
                                                 for p in state["printed"]), str(state["printed"]))
    sent = len(state["sent"])
    state["enter_phase"]("4100")
    run_timers(state)
    check("...nothing is sent while paused", len(state["sent"]) == sent, str(state["sent"][sent:]))
    state["result"] = 0
    state["ns"].SetCrowdEnabled(True)  # turning sharing on again: try now
    state["enter_phase"]("4200")
    check("...turning sharing on again sends at once", state["sent"][-1:] == ["Q:1:A:4200"], str(state["sent"]))
    check("...a Success return alone isn't \"working again\"",
          not any("working again" in p for p in state["printed"]), str(state["printed"]))
    hear("Q:1:A:4200", sender="Me")  # our echo
    run_timers(state)
    check("...our echo is", any("working again" in p for p in state["printed"]), str(state["printed"]))

    # Forever's refusal: the send returns Success, then NOT_ALLOWED_IN_CHANNEL, no echo
    def refused_world():
        hear, state = channel_world(greyed=False)
        state["result"] = 0
        state["ns"].SetCrowdEnabled(True)
        return hear, state

    hear, state = refused_world()
    state["enter_phase"]("4000")
    L = state["L"]
    L.eval("function(f, ...) f.OnEvent(f, ...) end")(L.eval("_frames[#_frames]"), "CHAT_MSG_CHANNEL_NOTICE",
                                                      "NOT_ALLOWED_IN_CHANNEL", "", "", "5. SLLCMShareA", "", "", 0, 5,
                                                      "SLLCMShareA")
    run_timers(state)
    check("NOT_ALLOWED_IN_CHANNEL after a send pauses sharing", any("paused" in p for p in state["printed"]),
          str(state["printed"]))
    check("...without leaving or rejoining", not state["calls"], str(state["calls"]))
    sent = len(state["sent"])
    state["enter_phase"]("4100")
    check("...and nothing more is sent", len(state["sent"]) == sent, str(state["sent"][sent:]))

    hear, state = refused_world()
    state["enter_phase"]("4000")
    run_timers(state)  # the echo wait runs out
    check("no echo after a Success send pauses sharing", any("paused" in p for p in state["printed"]),
          str(state["printed"]))

    hear, state = refused_world()
    state["enter_phase"]("4000")
    hear("Q:1:A:4000", sender="Me")
    run_timers(state)
    check("...an echo in time doesn't", not state["printed"], str(state["printed"]))

    def notice(state, what, base):
        L = state["L"]
        L.eval("function(f, ...) f.OnEvent(f, ...) end")(L.eval("_frames[#_frames]"), "CHAT_MSG_CHANNEL_NOTICE",
                                                          what, "", "", "5. " + base, "", "", 0, 5, base)
        run_timers(state)

    hear, state = channel_world(greyed=False, listed=False)
    state["result"] = 0  # the Q after rejoining goes out
    notice(state, "YOU_LEFT", "SLLCMShareA")
    check("YOU_LEFT on our channel rejoins it", state["calls"] == ["join"], str(state["calls"]))

    hear, state = channel_world(greyed=False, listed=False)
    notice(state, "YOU_LEFT", "General")
    check("...not on someone else's", not state["calls"], str(state["calls"]))

    hear, state = channel_world(greyed=False, listed=False)
    state["ns"].GetDB().crowd = False
    notice(state, "YOU_LEFT", "SLLCMShareA")
    check("...nor with sharing off", not state["calls"], str(state["calls"]))

    hear, state = channel_world(greyed=True, listed=True)
    notice(state, "INVALID_NAME", "SLLCMShareA")
    check("INVALID_NAME on a greyed-out channel revives it", state["calls"] == ["who", "leave", "join"],
          str(state["calls"]))

    ok = all(results)
    print("all passed" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
