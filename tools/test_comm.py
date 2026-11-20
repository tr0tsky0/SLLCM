"""Feeds channel messages to the real SkyborneLeyLineConvergenceMarker/Comm.lua (in lupa, WoW APIs mocked)
and checks sightings (R / S, no phases since 1.5.0), found locations (F / L), vouches and the channel handling.

    python tools/test_comm.py
"""
import sys
from pathlib import Path

import lupa

ROOT = Path(__file__).resolve().parent.parent
COMM = (ROOT / "SkyborneLeyLineConvergenceMarker" / "Comm.lua").read_text(encoding="utf-8")
WATCH = (ROOT / "SkyborneLeyLineConvergenceMarker" / "Watch.lua").read_text(encoding="utf-8")  # dev copy's commands
NOW = 1_800_000_000
ZONE, CONTINENT, PHASE = 1413, 1414, "3301"  # PHASE: an older client's layer in its R / S


def world(sharing=True, before_login=None, dev=True):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = L.globals()
    state = {"sent": [], "timers": [], "learned": [], "stamped": [], "retired": [],
             "vouches": [], "merged": [], "last_seen": None}
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
    ns = L.table_from({})
    ns.GetDB = lambda: db
    ns.Faction = lambda: L.table_from({"key": "LeyLines"})
    ns.Near = lambda m, x1, y1, x2, y2: abs(x1 - x2) < 0.02 and abs(y1 - y2) < 0.02
    ns.ZoneSizeYards = lambda m: (1000, 1000)  # Watch.lua saves zone sizes at login
    ns.LearnShared = lambda m, x, y: state["learned"].append((m, x, y))
    ns.StampSeen = lambda m, x, y, t: state["stamped"].append((m, round(x, 4), round(y, 4), t))
    ns.LastSeen = lambda m, x, y: state["last_seen"]
    ns.IsRetired = lambda k, m, x, y: (m, round(x, 4), round(y, 4)) in state["retired"]
    ns.VouchEntries = lambda: L.table_from(state["vouches"])
    ns.MergeVouch = lambda e: state["merged"].append(e) or (False if e.startswith("9") else True)
    ns.Print = lambda *a: None
    ns.Provider = L.table_from({"RefreshAllData": lambda self: None})

    L.eval("function(src, ns) assert(load(src, 'Comm.lua'))('SLLCM', ns) end")(COMM, ns)
    if dev:
        L.eval("function(src, ns) assert(load(src, 'Watch.lua'))('SLLCM', ns) end")(WATCH, ns)
    events = L.eval("_frames[#_frames]")
    fire = L.eval("function(f, ...) f.OnEvent(f, ...) end")
    if before_login:
        before_login(db, L)
    fire(events, "PLAYER_LOGIN")

    def hear(msg, sender="Other Player"):
        fire(events, "CHAT_MSG_ADDON", "SLLCM", msg, "CHANNEL", sender)

    def sight():  # our own racial confirms a node: an R goes out
        ns.OnConfirmed(ZONE, 0.5, 0.5, NOW)

    state["ns"], state["g"], state["sight"], state["L"] = ns, g, sight, L
    return hear, None, state, db


def R(t, x=5000, y=5000, m=ZONE):
    return "R:1:A:%s:%d:%d:%d:%d" % (PHASE, m, x, y, NOW - t)


def main():
    results = []

    def check(name, ok, detail=""):
        results.append(ok)
        print("%-4s %s%s" % ("ok" if ok else "FAIL", name, (": " + detail) if not ok else ""))

    # sightings, no phases: our own goes out at once with phase 0, and is stamped and learned
    hear, _, state, db = world()
    state["sight"]()
    check("own sighting goes out at once, phase 0", state["sent"] == ["R:1:A:0:%d:5000:5000:%d" % (ZONE, NOW)],
          str(state["sent"]))
    check("...stamped last seen", state["stamped"] == [(ZONE, 0.5, 0.5, NOW)], str(state["stamped"]))
    check("...and learned", state["learned"] == [(ZONE, 0.5, 0.5)], str(state["learned"]))

    hear, _, state, db = world(sharing=False)
    state["sight"]()
    check("sharing off: own sighting stamped", len(state["stamped"]) == 1, str(state["stamped"]))
    check("sharing off: nothing sent", not state["sent"], str(state["sent"]))

    # an older client's R and S carry its layer: read the same as ours, whatever the phase
    hear, _, state, db = world()
    hear(R(300, x=7000, y=6000))
    hear("R:1:A:0:%d:2000:2000:%d" % (ZONE, NOW - 60))
    check("heard R's are stamped, any phase", state["stamped"] == [(ZONE, 0.7, 0.6, NOW - 300),
                                                                   (ZONE, 0.2, 0.2, NOW - 60)], str(state["stamped"]))
    check("...and learned", len(state["learned"]) == 2, str(state["learned"]))
    hear, _, state, db = world()
    hear("S:1:A:%s:%d,5000,5000,%d;%d,7000,7000,%d" % (PHASE, ZONE, NOW - 300, ZONE, NOW - 200))
    check("an older client's S: every entry stamped", len(state["stamped"]) == 2, str(state["stamped"]))
    hear, _, state, db = world()
    hear(R(2 * 3600))
    check("a sighting over 90 min old is ignored", not state["stamped"], str(state["stamped"]))
    hear, _, state, db = world()
    hear(R(300, m=CONTINENT))
    check("a continent R lands on the zone", state["stamped"] == [(ZONE, 0.5, 0.5, NOW - 300)], str(state["stamped"]))
    hear, _, state, db = world()
    hear("R:1:H:%s:%d:5000:5000:%d" % (PHASE, ZONE, NOW))
    check("the other faction's R is ignored", not state["stamped"], str(state["stamped"]))

    # what older clients send that means nothing now
    hear, _, state, db = world()
    hear("Q:1:A:%s" % PHASE)
    hear("XM:1:A:%s:%d:5000:5000:%d" % (PHASE, ZONE, NOW - 60))
    hear("XS:1:A:%s:%d,5000,5000,%d" % (PHASE, ZONE, NOW - 60))
    for fn in list(state["timers"]):
        fn()
    check("a Q is never answered", not state["sent"], str(state["sent"]))
    check("XM / XS are ignored", not state["stamped"] and not state["learned"],
          "stamped=%s learned=%s" % (state["stamped"], state["learned"]))

    # saved per-phase data from before 1.5.0 goes at login
    def old_saved(db, L):
        db.crowdReports = L.eval("{ A = { [1413] = { { phase = '1', x = 0.5, y = 0.5, t = 1 } } } }")
        db.crowdGone, db.crowdQueried = L.eval("{}"), L.eval("{}")
        db.crowdPhase = L.eval("{ phase = '1', mapID = 1413, at = 1 }")
    hear, _, state, db = world(before_login=old_saved)
    check("old per-phase saved data is cleared at login",
          db.crowdReports is None and db.crowdGone is None and db.crowdQueried is None and db.crowdPhase is None)

    # a blip report (LeyLineTest, Scan.lua) is skipped when anyone stamped the node lately
    hear, _, state, db = world()
    state["last_seen"] = NOW - 60
    state["g"].SLLCM_ReportSighting(ZONE, 0.5, 0.5)
    check("blip report skipped within 5 min of a sighting", not state["sent"], str(state["sent"]))
    state["last_seen"] = NOW - 600
    state["g"].SLLCM_ReportSighting(ZONE, 0.5, 0.5)
    check("...but sent after", len(state["sent"]) == 1, str(state["sent"]))

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

    # last seen: every heard sighting is stamped; a retired find isn't passed on
    hear, at, state, db = world()
    hear(R(300, x=7000, y=6000))
    check("a heard R stamps last seen", state["stamped"] == [(ZONE, 0.7, 0.6, NOW - 300)], str(state["stamped"]))
    hear, at, state, db = world()
    state["g"].SLLCM_Data = state["L"].eval("{ LeyLines = {} }")
    db.found.LeyLines[ZONE] = state["L"].eval("{ { 0.2, 0.2 }, { 0.3, 0.3 } }")
    state["retired"].append((ZONE, 0.2, 0.2))
    hear("F:1:A", sender="Asker")
    for fn in list(state["timers"]):
        fn()
    sent = [m for m in state["sent"] if m.startswith("L:")]
    check("a retired find isn't sent in an F answer", sent == ["L:1:A:%d,3000,3000" % ZONE], str(sent))

    # vouches: answering a VQ sends all of ours, packed under 255 bytes; a heard V is merged entry by entry
    hear, at, state, db = world()
    state["vouches"].extend("%d,9,abc,%s" % (1400 + i, "Q" * 12) for i in range(30))
    hear("F:1:A", sender="Asker")
    for fn in list(state["timers"]):
        fn()
    check("an F alone brings no V", not [m for m in state["sent"] if m.startswith("V:")], str(state["sent"]))
    hear("VQ:1:A", sender="Asker")
    for _ in range(100):  # with the channel echoing, so nothing pauses
        if not state["timers"]:
            break
        state["timers"].pop(0)()
        hear("Z:1:A")
    vs = [m for m in state["sent"] if m.startswith("V:")]
    got = [e for m in vs for e in m[len("V:1:A:"):].split(";")]
    check("an F is answered with every vouch", got == state["vouches"], "%d of 30" % len(got))
    check("...in V's under 255 bytes", len(vs) > 1 and all(len(m) <= 255 for m in vs), str([len(m) for m in vs]))
    state["merged"].clear()
    for m in vs:
        hear(m, sender="Answerer")
    check("an answer split over %d V's is merged whole" % len(vs), state["merged"] == state["vouches"],
          "%d of 30" % len(state["merged"]))
    hear, at, state, db = world()
    hear("V:1:A:1413,5,abc,Q")
    check("an unasked V is ignored", not state["merged"], str(state["merged"]))
    hear("VQ:1:A", sender="Asker")
    hear("V:1:A:1413,5,abc,Q;9999,5,abc,Q")
    check("a V after a VQ is merged entry by entry", state["merged"] == ["1413,5,abc,Q", "9999,5,abc,Q"],
          str(state["merged"]))
    state["merged"].clear()
    hear("V:1:A:1414,5,abc,Q;1413,5,abc,Q")
    check("...a sender's later part is merged, its repeated zone skipped", state["merged"] == ["1414,5,abc,Q"],
          str(state["merged"]))
    state["merged"].clear()
    hear("V:1:A:1413,5,abc,Q")
    check("...a repeated V merges nothing", not state["merged"], str(state["merged"]))
    hear("V:1:A:1413,5,abc,Q", sender="Third Player")
    check("...another sender's is merged too", state["merged"] == ["1413,5,abc,Q"], str(state["merged"]))
    state["merged"].clear()
    hear("V:1:H:1413,5,abc,Q", sender="Fourth Player")
    check("...not the other faction's", not state["merged"], str(state["merged"]))
    state["g"].GetTime = lambda: 100.0 + 91
    hear("V:1:A:1413,5,abc,Q", sender="Late Player")
    check("...nor one after the window", not state["merged"], str(state["merged"]))

    # one sender teaches at most 100 new locations a session; a second sender still teaches
    hear, at, state, db = world()
    state["ns"].LearnShared = lambda m, x, y: state["learned"].append((m, x, y)) or True
    for i in range(12):
        hear("L:1:A:" + ";".join("%d,%d,%d" % (ZONE, 100 + i * 15 + j, 100) for j in range(15)))
    check("one sender: 100 new locations, then no more", len(state["learned"]) == 100, str(len(state["learned"])))
    hear(R(60, x=9000, y=9000), sender="Someone Else")
    check("...another sender is still heard", len(state["learned"]) == 101, str(len(state["learned"])))
    hear, at, state, db = world()
    hear("VQ:1:A", sender="Asker")
    for fn in list(state["timers"]):
        fn()
    check("no vouches: no V", not [m for m in state["sent"] if m.startswith("V:")], str(state["sent"]))

    # the asking commands are the dev copy's (Watch.lua); the release copy has no found / vouch / test
    hear, at, state, db = world()
    state["ns"].SetCrowdEnabled(True)
    state["ns"].ShareCommand("vouch")
    check("dev: share vouch sends a VQ", "VQ:1:A" in state["sent"], str(state["sent"]))
    hear, at, state, db = world(dev=False)
    state["ns"].SetCrowdEnabled(True)
    for cmd in ("found", "vouch", "test send", "test clear"):
        state["ns"].ShareCommand(cmd)
    check("release: no found / vouch / test", not [m for m in state["sent"] if m[:2] in ("F:", "VQ")],
          str(state["sent"]))

    # unasked L after login: self-found locations Data.lua lacks, once the channel is heard, at most every 20 h
    def find_far(db, L):  # a self-found node Data.lua (0.50, 0.50) doesn't have
        db.found.LeyLines[ZONE] = L.eval("{ { 0.2, 0.2 } }")
    want = ["L:1:A:%d,2000,2000" % ZONE]

    def lsent(state):
        return [m for m in state["sent"] if m.startswith("L:")]

    for name, sent_ago, heard, want_l in [
        ("unasked: our find goes out once the channel is heard", None, [R(60)], want),
        ("...nothing before anything is heard", None, [], []),
        ("...not again within 20 h of the last", 3600, [R(60)], []),
        ("...but after that, yes", 21 * 3600, [R(60)], want),
        ("...not if an L heard meanwhile had it", None, [R(60), "L:1:A:%d,2000,2000" % ZONE], []),
        ("...and only once with an F answered meanwhile", None, [R(60), "F:1:A"], want),
    ]:
        def before(db, L, ago=sent_ago):
            find_far(db, L)
            if ago:
                db.foundSentAt = NOW - ago
        hear, at, state, db = world(before_login=before)
        for msg in heard:
            hear(msg)
        for fn in list(state["timers"]):
            fn()
        check(name, lsent(state) == want_l, str(lsent(state)))
        if want_l:
            check("...no send time until it echoes back", db.foundSentAt != NOW, str(db.foundSentAt))
            for msg in lsent(state):
                hear(msg, sender="Me")
            check("...and the send time is kept once it does", db.foundSentAt == NOW, str(db.foundSentAt))

    # shared locations: in F answers (after our own finds), never in the unasked L
    def with_shared(n):
        def before(db, L):
            find_far(db, L)
            db.shared.LeyLines[ZONE] = L.eval("{ %s }" % ", ".join(
                "{ %.2f, 0.8 }" % (0.05 + i * 0.03) for i in range(n)))
        return before

    def run_all(state, limit=100):  # with the channel echoing: something heard after each step, so no pause
        while state["timers"] and limit > 0:
            state["timers"].pop(0)()
            hear("Z:1:A")
            limit -= 1

    def entries(msgs):
        return [e for m in msgs for e in m.split(":", 3)[3].split(";")]

    hear, at, state, db = world(before_login=with_shared(2))
    hear(R(60))
    run_all(state)
    check("unasked L leaves shared locations out", lsent(state) == want, str(lsent(state)))

    hear, at, state, db = world(before_login=with_shared(2))
    hear("F:1:A", sender="Asker")
    run_all(state)
    got = entries(lsent(state))
    check("F answer: own find first, then shared ones",
          got == ["%d,2000,2000" % ZONE, "%d,500,8000" % ZONE, "%d,800,8000" % ZONE], str(got))

    # 20 shared: the first L takes 15 (our find + 14); one heard before the second part covers 2 of the other 6
    hear, at, state, db = world(before_login=with_shared(20))
    hear("F:1:A", sender="Asker")
    while not lsent(state):  # the waits (the unasked L's, skipped, then the F answer's): the first part goes
        state["timers"].pop(0)()
    first = entries(lsent(state))
    hear("L:1:A:%d,5300,8000;%d,5600,8000" % (ZONE, ZONE))
    run_all(state)
    rest = entries(lsent(state))[len(first):]
    check("F answer goes in parts of 15", len(first) == 15, str(first))
    check("...a later part leaves out what an L heard meanwhile had", len(rest) == 4
          and "%d,5300,8000" % ZONE not in rest and "%d,5600,8000" % ZONE not in rest, str(rest))
    check("...and nothing is sent twice", len(set(first + rest)) == len(first + rest), str(first + rest))

    # the channel: greyed out (still listed, every send refused), then a notice that we left it
    # who_drops: the server answers our /chatwho with INVALID_NAME and the client drops the channel (11 Nov)
    def channel_world(greyed=True, listed=True, who_drops=False):
        hear, at, state, db = world()
        g, L = state["g"], state["L"]
        calls, printed = [], []
        state["calls"], state["printed"], state["result"] = calls, printed, 7
        state["greyed"], state["listed"], state["now"] = greyed, listed, 100.0
        g.GetTime = lambda: state["now"]
        g.GetChannelList = lambda: ((1, "General", False, 5, "SLLCMShareA", state["greyed"]) if state["listed"]
                                    else (1, "General", False))
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
    state["ns"].SetCrowdEnabled(True)
    run_timers(state)
    state["greyed"], state["now"] = True, 120.0
    state["sight"]()
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
    state["ns"].SetCrowdEnabled(True)  # listed and not greyed out: nothing to do
    state["sight"]()  # an R goes out, and is refused
    run_timers(state)
    calls = state["calls"]
    check("refused sends revive the channel", calls == ["who", "leave", "join"], str(calls))
    check("...refused again: sharing pauses and says so",
          any("paused" in p for p in state["printed"]), str(state["printed"]))
    check("...and never says to relog", not any("relog" in p.lower() or "log out" in p.lower()
                                                 for p in state["printed"]), str(state["printed"]))
    sent = len(state["sent"])
    state["sight"]()
    run_timers(state)
    check("...nothing is sent while paused", len(state["sent"]) == sent, str(state["sent"][sent:]))
    state["result"] = 0
    state["ns"].SetCrowdEnabled(True)  # turning sharing on again: try now
    state["sight"]()
    check("...turning sharing on again sends at once", state["sent"][-1:] == ["R:1:A:0:%d:5000:5000:%d" % (ZONE, NOW)], str(state["sent"]))
    check("...a Success return alone isn't \"working again\"",
          not any("working again" in p for p in state["printed"]), str(state["printed"]))
    hear(state["sent"][-1], sender="Me")  # our echo
    run_timers(state)
    check("...our echo is", any("working again" in p for p in state["printed"]), str(state["printed"]))

    # Forever's refusal: the send returns Success, then NOT_ALLOWED_IN_CHANNEL, no echo
    def refused_world():
        hear, state = channel_world(greyed=False)
        state["result"] = 0
        state["ns"].SetCrowdEnabled(True)
        return hear, state

    hear, state = refused_world()
    state["sight"]()
    L = state["L"]
    L.eval("function(f, ...) f.OnEvent(f, ...) end")(L.eval("_frames[#_frames]"), "CHAT_MSG_CHANNEL_NOTICE",
                                                      "NOT_ALLOWED_IN_CHANNEL", "", "", "5. SLLCMShareA", "", "", 0, 5,
                                                      "SLLCMShareA")
    run_timers(state)
    check("NOT_ALLOWED_IN_CHANNEL after a send pauses sharing", any("paused" in p for p in state["printed"]),
          str(state["printed"]))
    check("...without leaving or rejoining", not state["calls"], str(state["calls"]))
    sent = len(state["sent"])
    state["sight"]()
    check("...and nothing more is sent", len(state["sent"]) == sent, str(state["sent"][sent:]))
    own = "R:1:A:0:%d:5000:5000:%d" % (ZONE, NOW)
    hear("Z:1:A", sender="Someone")  # the channel carries again
    check("...the refused sighting goes out once the channel is heard, just once", state["sent"][sent:] == [own],
          str(state["sent"][sent:]))

    hear, state = refused_world()
    state["sight"]()
    run_timers(state)  # no echo: paused
    sent = len(state["sent"])
    state["g"].GetServerTime = lambda: NOW + 2 * 3600
    hear("Z:1:A", sender="Someone")
    check("...but not once it's too old for anyone to keep", len(state["sent"]) == sent, str(state["sent"][sent:]))

    hear, state = refused_world()
    state["sight"]()
    run_timers(state)  # the echo wait runs out
    check("no echo after a Success send pauses sharing", any("paused" in p for p in state["printed"]),
          str(state["printed"]))

    hear, state = refused_world()
    state["sight"]()
    hear(state["sent"][-1], sender="Me")
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

    hear, state = channel_world(greyed=False, listed=True)
    state["g"].GetChannelName = lambda name: 0  # missed it, but the channel list has it
    state["ns"].SetCrowdEnabled(True)
    run_timers(state)
    check("no join when only GetChannelName misses the channel", "join" not in state["calls"], str(state["calls"]))

    # a channel that stays greyed out: 6 revives at the usual pace, then still one every 10 min, never none
    hear, state = channel_world(greyed=True, listed=True)
    state["ns"].SetCrowdEnabled(True)
    run_timers(state)

    def poke(after):
        state["now"] += after
        state["greyed"] = True
        notice(state, "SUSPENDED", "SLLCMShareA")
        return state["calls"].count("who")

    for _ in range(5):
        poke(130)
    check("a stuck channel gets 6 revives", state["calls"].count("who") == 6, str(state["calls"].count("who")))
    check("...then none 2 min later", poke(130) == 6, str(state["calls"].count("who")))
    check("...but another 10 min after the 6th", poke(480) == 7, str(state["calls"].count("who")))
    check("...and every 10 min after that", poke(300) == 7 and poke(310) == 8, str(state["calls"].count("who")))

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

    # debug lines: to the dev copy's debug window when it takes them (on), else chat (ns.Print)
    for label, has_window, takes in [("the debug window when it's on", True, True),
                                     ("chat when it's off", True, False),
                                     ("chat in the release copy (no window)", False, None)]:
        hear, at, state, db = world()
        L = state["L"]
        printed, window = [], []
        state["ns"].Print = lambda fmt, *a: printed.append(fmt % a if a else fmt)
        if has_window:
            state["ns"].DebugWindow = L.table_from({"Add": lambda text: window.append(text) or takes})
        state["ns"].ShareCommand("debug")  # on
        printed.clear()
        hear("R:1:A:0:%d:4000:4000:%d" % (ZONE, NOW))  # "<< Other Player: R:...4000..."
        lines = window if takes else printed
        check("debug lines go to " + label, any("4000" in p for p in lines) and
              not any("4000" in p for p in (printed if takes else [])), "window=%s printed=%s" % (window, printed))

    # share found's lines are a dev tool's: in the debug window when it's on, even with debug off
    hear, at, state, db = world()
    printed, window = [], []
    state["ns"].Print = lambda fmt, *a: printed.append(fmt % a if a else fmt)
    state["ns"].DebugWindow = state["L"].table_from({"Add": lambda text: window.append(text) or True})
    state["ns"].ShareCommand("found")
    check("share found's lines go to the debug window", any(w.startswith("found: asked") for w in window)
          and not any(p.startswith("found") for p in printed), "window=%s printed=%s" % (window, printed))

    ok = all(results)
    print("all passed" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
