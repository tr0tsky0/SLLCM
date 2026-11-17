-- Dev only (loaded by the -Dev toc): watch other players' sightings for Data.lua points we're unsure of.
-- LearnShared drops sightings near a Data.lua point, so a confirming one would otherwise go unnoticed.
-- Hits are kept in SkyborneMarkerDB.watchHits; /sllcm watch lists them.
-- Also logs node lifetimes: a sighting ended by a later "not there" (XM / XS) in the same phase, kept in
-- SkyborneMarkerDB.lifetimes; /sllcm watch life lists them.
-- And the dev-only /sllcm share subcommands (found, vouch, test): see ns.DevShareCommand.

local _, ns = ...

-- [dataKey][mapID] = { { x, y, note }, ... }
local WATCH = {
  ElementalConvergences = {
    [1413] = { -- The Barrens
      { 0.3990, 0.1390, "gone from Wowhead 2026-10-13" },
      { 0.5460, 0.1490, "gone from Wowhead 2026-10-13" },
    },
  },
}
local MAX_TIMES = 20 -- sighting times kept per point
local MAX_LIFETIMES = 100

-- r: the sighting a "not there" at time t just ended. The node was up at least from r.first to r.t, and was
-- gone by t.
function ns.WatchGone(mapID, r, t)
  local db = ns.GetDB()
  db.lifetimes = db.lifetimes or {}
  local list = db.lifetimes
  list[#list + 1] = { key = ns.Faction().key, mapID = mapID, x = r.x, y = r.y, phase = r.phase,
    first = r.first or r.t, last = r.t, gone = t }
  if #list > MAX_LIFETIMES then table.remove(list, 1) end
end

local function Hits()
  local db = ns.GetDB()
  db.watchHits = db.watchHits or {}
  return db.watchHits
end

-- A sighting (anyone's, any phase) near a watched point. The same sighting comes again in replies,
-- so hits are counted by sighting time.
function ns.Watch(mapID, x, y, t, mine)
  local key = ns.Faction().key
  for _, w in ipairs(WATCH[key] and WATCH[key][mapID] or {}) do
    if ns.Near(mapID, w[1], w[2], x, y) then
      local id = format("%s:%d:%.4f,%.4f", key, mapID, w[1], w[2])
      local hits = Hits()
      local h = hits[id] or { times = {} }
      hits[id] = h
      for _, seen in ipairs(h.times) do
        if seen == t then return end
      end
      if #h.times < MAX_TIMES then h.times[#h.times + 1] = t end
      h.count = (h.count or 0) + 1
      h.first = math.min(h.first or t, t)
      h.last = math.max(h.last or t, t)
      h.x, h.y = x, y -- the latest reported position
      h.mine = h.mine or mine
      return
    end
  end
end

-- /sllcm share's dev-only subcommands (Comm.lua's ShareCommand asks here first). true if arg was one of ours.
--   found: ask the channel for locations Data.lua lacks (F); vouch: for which Data.lua nodes they've seen (VQ)
--   test send | receive | new | clear: fake sightings, never sent. send / receive: at the known node nearest you,
--   through our own path or the message parser; new: a receive at your position, learned as a shared location.
function ns.DevShareCommand(arg)
  if arg == "help" then
    ns.Print("dev: /sllcm share found | vouch - ask the channel; /sllcm share test send | receive | new | clear")
  elseif arg == "found" then
    ns.Ask("F")
  elseif arg == "vouch" then
    ns.Ask("VQ")
  elseif arg == "test clear" then
    ns.TestClear()
    ns.Print("test: shared locations and all sightings cleared")
  elseif arg == "test send" or arg == "test receive" or arg == "test new" then
    local mapID = C_Map.GetBestMapForUnit("player")
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    local x, y
    if pos and arg == "test new" then
      x, y = pos.x, pos.y
    elseif pos then
      x, y = ns.NearestKnown(mapID, pos.x, pos.y)
    end
    if not x then
      ns.Print("test: no known node on this map")
      return true
    end
    local msg = ns.TestSighting(arg ~= "test send", mapID, x, y)
    if not msg then
      ns.Print("test: phase unknown, mouse over an NPC first")
    else
      ns.Print(arg == "test send" and "test send (not sent to the channel): %s" or "test receive: %s", msg)
    end
  else
    return false
  end
  return true
end

-- /sllcm watch mark | dist: for measuring the racial's range. mark saves where you stand (on the node's blip);
-- dist says how far you are from it in yards, and from the nearest known node.
local mark
local function Here()
  local mapID = C_Map.GetBestMapForUnit("player")
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if pos then return mapID, pos.x, pos.y end
end
local function Yards(mapID, x1, y1, x2, y2)
  local w, h = ns.ZoneSizeYards(mapID)
  return w and math.sqrt(((x1 - x2) * w) ^ 2 + ((y1 - y2) * h) ^ 2)
end

function ns.WatchCommand(arg)
  if arg == "mark" or arg == "dist" then
    local mapID, x, y = Here()
    if not mapID then
      ns.Print("watch: no map position here")
    elseif arg == "mark" then
      mark = { mapID = mapID, x = x, y = y }
      ns.Print("watch: mark at %d %.2f, %.2f", mapID, x * 100, y * 100)
    else
      if mark and mark.mapID == mapID then
        ns.Print("watch: %.0f yd from mark", Yards(mapID, x, y, mark.x, mark.y) or -1)
      else
        ns.Print("watch: no mark on this map (/sllcm watch mark)")
      end
      local nx, ny = ns.NearestKnown(mapID, x, y)
      if nx then
        ns.Print("watch: nearest known node %.2f, %.2f, %.0f yd", nx * 100, ny * 100, Yards(mapID, x, y, nx, ny) or -1)
      end
    end
    return
  elseif arg == "life" then
    local list = ns.GetDB().lifetimes or {}
    for _, l in ipairs(list) do
      local info = C_Map.GetMapInfo(l.mapID)
      ns.Print("%s %.2f, %.2f phase %s: up %d+ min (seen %s to %s), gone by %d min after last seen",
        info and info.name or l.mapID, l.x * 100, l.y * 100, l.phase, math.floor((l.last - l.first) / 60),
        date("%H:%M", l.first), date("%H:%M", l.last), math.floor((l.gone - l.last) / 60))
    end
    ns.Print("%d lifetime(s) logged", #list)
    return
  elseif arg == "clear" then
    ns.GetDB().watchHits = {}
    ns.Print("watch hits cleared")
    return
  end
  local hits, any = Hits(), false
  for key, maps in pairs(WATCH) do
    for mapID, points in pairs(maps) do
      local info = C_Map.GetMapInfo(mapID)
      for _, w in ipairs(points) do
        local h = hits[format("%s:%d:%.4f,%.4f", key, mapID, w[1], w[2])]
        local where = format("%s %.1f, %.1f", info and info.name or mapID, w[1] * 100, w[2] * 100)
        if h then
          any = true
          ns.Print("|cff00ff00CONFIRMED|r %s: %d sighting(s), %s to %s, last at %.1f, %.1f%s", where, h.count,
            date("%Y-%m-%d %H:%M", h.first), date("%Y-%m-%d %H:%M", h.last), h.x * 100, h.y * 100,
            h.mine and " (incl. yours)" or "")
        else
          ns.Print("|cff888888waiting|r %s (%s)", where, w[3])
        end
      end
    end
  end
  if not any then ns.Print("watch: no sightings yet") end
end
