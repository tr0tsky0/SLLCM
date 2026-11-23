-- Pins the leylines (Alliance) or elemental convergences (Horde) listed in Data.lua on the world
-- map, and keeps a personal list of the ones you find yourself.

local ADDON, ns = ...

local PIN = "LeyLineMarkerPinTemplate"
local MIN_DURATION = 60     
local MAX_MINUTES = 60          -- slider maximum: the buff never has more than this left, so nothing hides
local HIDE_STEPS = { 1, 5, 10, 15, 30, MAX_MINUTES } -- slider stops; a saved value between them still works as saved
local SAME_YARDS = 70            -- closer than this counts as the same location: the racial works from up to
                                 -- about 30 yd (24 yd yes, 30 no, 2026-11-17), so two casts at one node can be
                                 -- 60 yd apart; was 60 until then
local RETIRED_YARDS = 10         -- a retired point matches only this close: it's pasted from export, exact, and a
                                 -- copy can sit within SAME_YARDS of the real node it copies
local GROUP_YARDS = 200          -- nodes this close to a shown pin share it: standing there, the
                                 -- minimap (about 230 yd to its edge) shows them all
local PIN_PERCENT = 100          -- default for db.pinAlpha: pin opacity
local RACIAL_IDS = { [1259705] = true, [1259686] = true } -- Read Leyline (Alliance), Skysight (Horde)
local BUFF_IDS = { [1259691] = true, [1270893] = true } -- Attuned (Alliance), Charged (Horde): 60 min, from the racial on a node.
-- Not Energized (1270842, 5 s from the cast, seen 2026-11-04) or its Horde twin Elemental Blessing (1259688)

local FACTIONS = {
  Alliance = { key = "LeyLines", name = "Leyline", atlas = "MagePortalAlliance" },
  Horde = { key = "ElementalConvergences", name = "Elemental Convergence", atlas = "MagePortalAlliance" },
}

local db, Provider, hidden, UpdateBuffHide, events

local function Print(msg, ...)
  print("|cff66ccffSkyborne Marker:|r " .. format(msg, ...))
end

local function Faction()
  return FACTIONS[UnitFactionGroup("player")] or FACTIONS.Alliance
end

-- Only Skyborne can see leylines and convergences
local function IsSkyborne()
  return select(2, UnitRace("player")) == "Skyborne"
end

local function MapName(mapID)
  local info = C_Map.GetMapInfo(mapID)
  return info and info.name or ("map " .. mapID)
end

---------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------

-- a zone's size never changes: work it out once per session
local zoneSizes = {}
local function ZoneSizeYards(mapID)
  local size = zoneSizes[mapID]
  if size then return size[1], size[2] end
  local _, a = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
  local _, b = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(1, 1))
  if not a or not b then return end
  -- world axes are swapped relative to map axes
  size = { math.abs(b.y - a.y), math.abs(b.x - a.x) }
  zoneSizes[mapID] = size
  return size[1], size[2]
end

local function Near(mapID, x1, y1, x2, y2, yards)
  local w, h = ZoneSizeYards(mapID)
  if not w then return end
  local dx, dy, r = (x1 - x2) * w, (y1 - y2) * h, yards or SAME_YARDS
  return dx * dx + dy * dy < r * r
end

local EMPTY = {} -- read-only stand-in for a missing list, so lookups don't make a table each miss

local function FindNear(list, mapID, x, y, yards)
  for _, p in ipairs(list or EMPTY) do
    if Near(mapID, p[1], p[2], x, y, yards) then return p end
  end
end

---------------------------------------------------------------------------
-- Self-found locations: SkyborneMarkerDB.found[dataKey][mapID] = { {x, y}, ... }
---------------------------------------------------------------------------

-- quiet: no message for a node Data.lua already has (minimap scans pass by lots of those)
local function Record(mapID, x, y, quiet)
  local key = Faction().key
  local found = db.found[key]
  found[mapID] = found[mapID] or {}
  local where = format("%s %.1f, %.1f", MapName(mapID), x * 100, y * 100)

  if FindNear(found[mapID], mapID, x, y) then return end
  table.insert(found[mapID], { x, y })

  if not (quiet and FindNear(SLLCM_Data[key][mapID], mapID, x, y)) then Print("|cffffff00NEW|r %s", where) end
  if Provider then Provider:RefreshAllData() end
end

local function HasNodeBuff(since)
  for id in pairs(BUFF_IDS) do
    local aura = C_UnitAuras.GetPlayerAuraBySpellID(id)
    if aura and aura.duration >= MIN_DURATION and aura.expirationTime - aura.duration >= since then
      return true
    end
  end
end

local pending 

local function OnRacialCast()
  local mapID = C_Map.GetBestMapForUnit("player")
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return end
  local x, y, castTime, tries = pos.x, pos.y, GetTime() - 1, 0
  local serverTime = GetServerTime()
  local function Check()
    tries = tries + 1
    local ok, found = pcall(HasNodeBuff, castTime)
    if ok and found then
      Record(mapID, x, y)
      ns.OnConfirmed(mapID, x, y, serverTime)
    elseif ok and tries < 4 then
      C_Timer.After(0.5, Check)
    elseif not ok or InCombatLockdown() then
      -- auras unreadable or not reported in combat: look again when it ends
      pending = { mapID = mapID, x = x, y = y, castTime = castTime, serverTime = serverTime }
    end
  end
  C_Timer.After(0.2, Check)
end

local function CheckPending()
  local p = pending
  pending = nil
  if not p then return end
  local ok, found = pcall(HasNodeBuff, p.castTime)
  if ok and found then
    Record(p.mapID, p.x, p.y)
    ns.OnConfirmed(p.mapID, p.x, p.y, p.serverTime)
  elseif not ok then
    pending = p
  end
end

---------------------------------------------------------------------------
-- Map pins
---------------------------------------------------------------------------

LeyLineMarkerPinMixin = CreateFromMixins(MapCanvasPinMixin)

function LeyLineMarkerPinMixin:OnLoad()
  self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
  self:SetScalingLimits(1, 1.0, 1.2)
  self.Icon:SetAtlas(Faction().atlas)
end

-- more: how many other nodes nearby this pin stands for
function LeyLineMarkerPinMixin:OnAcquired(x, y, more)
  self.x, self.y, self.more = x, y, more or 0
  self:SetPosition(x, y)
  self.Icon:SetAlpha((db and db.pinAlpha or PIN_PERCENT) / 100)
end

function LeyLineMarkerPinMixin:CheckMouseButtonPassthrough(...)
  if not InCombatLockdown() then
    MapCanvasPinMixin.CheckMouseButtonPassthrough(self, ...)
  end
end

function LeyLineMarkerPinMixin:OnMouseEnter()
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:SetText(Faction().name)
  GameTooltip:AddLine(format("%.1f, %.1f", self.x * 100, self.y * 100), 1, 1, 1)
  if self.more > 0 then
    GameTooltip:AddLine(format("+%d more within %d yd", self.more, GROUP_YARDS), 1, 1, 1)
  end
  -- anyone's sighting here, any phase: says the location is real, not that the node is up for you
  local t = ns.LastSeen(self:GetMap():GetMapID(), self.x, self.y)
  if t then
    local minutes = math.max(0, math.floor((GetServerTime() - t) / 60))
    local ago = minutes < 60 and format("%d min", minutes)
      or minutes < 48 * 60 and format("%d h", math.floor(minutes / 60))
      or format("%d days", math.floor(minutes / 1440))
    GameTooltip:AddLine("Last seen " .. ago .. " ago", 0.6, 0.6, 0.6)
  end
  GameTooltip:Show()
end

function LeyLineMarkerPinMixin:OnMouseLeave()
  GameTooltip:Hide()
end

Provider = CreateFromMixins(MapCanvasDataProviderMixin)

function Provider:RemoveAllData()
  self:GetMap():RemoveAllPinsByTemplate(PIN)
end

function Provider:RefreshAllData()
  self:RemoveAllData()
  -- the map refreshes every provider when it opens (MapCanvasMixin:OnShow), so a hidden one needs no pins yet
  if not self:GetMap():IsShown() then return end
  if db and not db.showNonSkyborne and not IsSkyborne() then return end
  if hidden then return end
  local key = Faction().key
  local mapID = self:GetMap():GetMapID()
  local mine = db and db.found[key][mapID]
  local pins = {} -- { x, y }, drawn grouped at the end

  if not (db and db.selfOnly) then
    for _, p in ipairs(SLLCM_Data[key][mapID] or EMPTY) do
      pins[#pins + 1] = p
    end
    -- self-found points not already in the list
    for _, p in ipairs(mine or EMPTY) do
      if not FindNear(SLLCM_Data[key][mapID], mapID, p[1], p[2]) then
        pins[#pins + 1] = p
      end
    end
    -- points learned from other players' sightings, not in either
    for _, p in ipairs(db and db.shared[key][mapID] or EMPTY) do
      if not FindNear(SLLCM_Data[key][mapID], mapID, p[1], p[2]) and not FindNear(mine, mapID, p[1], p[2]) then
        pins[#pins + 1] = p
      end
    end
  else
    for _, p in ipairs(mine or EMPTY) do
      pins[#pins + 1] = p
    end
  end

  -- nodes within GROUP_YARDS of a shown pin are folded into it
  local folded = {}
  for i, p in ipairs(pins) do
    if not folded[i] then
      local more = 0
      for j = i + 1, #pins do
        local q = pins[j]
        if not folded[j] and Near(mapID, p[1], p[2], q[1], q[2], GROUP_YARDS) then
          folded[j], more = true, more + 1
        end
      end
      self:GetMap():AcquirePin(PIN, p[1], p[2], more)
    end
  end
end

WorldMapFrame:AddDataProvider(Provider)
ns.Print = Print

ns.Provider, ns.Faction, ns.Near = Provider, Faction, Near
ns.ZoneSizeYards = ZoneSizeYards
ns.GetDB = function() return db end

-- Scan.lua: minimap scanning runs only on Skyborne, while the setting is on. Scan.lua is out of both tocs since
-- 17 Nov 2026: Forever hides minimap tooltip text from addons (secret) since about 13 Nov, so it found nothing.
-- To bring it back: list it in the tocs again and restore the "Detect nodes on the minimap" checkbox.
function ns.ScanEnabled()
  return db and db.minimapScan and IsSkyborne()
end

-- A blip found by Scan.lua: the node is up right now
local SCAN_REPORT_GAP = 10 * 60
function ns.OnMinimapNode(mapID, x, y)
  Record(mapID, x, y, true)
  SLLCM_ReportSighting(mapID, x, y, SCAN_REPORT_GAP)
end

---------------------------------------------------------------------------
-- Retired locations (SLLCM_Retired in Data.lua): bad reports. Taken out of SLLCM_Data and db.shared at login,
-- never learned again and never sent in an L. Self-found ones stay on your own map (you saw them) but aren't
-- passed on. A live sighting there still shows: that's evidence, and export lists it for un-retiring.
-- Matched within RETIRED_YARDS only, so retiring a copy never takes the real node beside it.
---------------------------------------------------------------------------

local function IsRetired(key, mapID, x, y)
  local maps = SLLCM_Retired and SLLCM_Retired[key]
  return FindNear(maps and maps[mapID], mapID, x, y, RETIRED_YARDS) ~= nil
end
ns.IsRetired = IsRetired

-- Drop retired points from Data.lua's lists, and shared locations that Data.lua now has or that are retired
local function PruneKnown()
  for key, maps in pairs(SLLCM_Retired or {}) do
    for mapID, retired in pairs(maps) do
      local list = SLLCM_Data[key] and SLLCM_Data[key][mapID]
      for i = #(list or {}), 1, -1 do
        if FindNear(retired, mapID, list[i][1], list[i][2], RETIRED_YARDS) then table.remove(list, i) end
      end
    end
  end
  for key, maps in pairs(db.shared) do
    for mapID, list in pairs(maps) do
      for i = #list, 1, -1 do
        local x, y = list[i][1], list[i][2]
        if FindNear(SLLCM_Data[key] and SLLCM_Data[key][mapID], mapID, x, y) or IsRetired(key, mapID, x, y) then
          table.remove(list, i)
        end
      end
      if #list == 0 then maps[mapID] = nil end
    end
  end
  if WorldMapFrame:IsShown() then Provider:RefreshAllData() end
end

---------------------------------------------------------------------------
-- Last seen, to find bad locations: SkyborneMarkerDB.seen[dataKey][mapID] = { {x, y, t}, ... }, the newest
-- sighting (R, S or our own) at each spot, and .activeDays[dataKey][mapID] = { [day] = true }, the days
-- the zone had any sighting. A node is suspect once its zone has had SUSPECT_DAYS active days since it was
-- last seen: a zone nobody visits says nothing about its nodes. Both forget after KEEP_DAYS.
---------------------------------------------------------------------------

local DAY = 86400
local DAY_START = 10 * 3600 -- days run from 10:00 UTC (2-3 AM in the US), not midnight, which split an
                            -- American evening into two (2026-11-16)
local KEEP_DAYS = 60
local SUSPECT_DAYS = 5
local VOUCH_KEEP = 14 * DAY -- vouches heard from others (below) count this long

local function Day(t)
  return math.floor((t - DAY_START) / DAY)
end

function ns.StampSeen(mapID, x, y, t)
  if not (db and ZoneSizeYards(mapID)) then return end
  local key = Faction().key
  local seen, days = db.seen[key], db.activeDays[key]
  seen[mapID] = seen[mapID] or {}
  local s = FindNear(seen[mapID], mapID, x, y)
  if not s then
    table.insert(seen[mapID], { x, y, t })
  elseif t > s[3] then
    s[3] = t
  end
  days[mapID] = days[mapID] or {}
  days[mapID][Day(t)] = true
end

-- the newest sighting near a spot (ours or heard), nil if none in KEEP_DAYS
function ns.LastSeen(mapID, x, y)
  local s = db and FindNear(db.seen[Faction().key][mapID], mapID, x, y)
  return s and s[3]
end

local function PruneSeen()
  local now = GetServerTime()
  -- days saved before DAY_START (UTC midnight days) can't be converted: rebuild them from the stamps, once
  if db.dayStart ~= DAY_START then
    for key, maps in pairs(db.seen) do
      local days = {}
      for mapID, list in pairs(maps) do
        days[mapID] = {}
        for _, s in ipairs(list) do days[mapID][Day(s[3])] = true end
      end
      db.activeDays[key] = days
    end
    db.dayStart = DAY_START
  end
  for _, maps in pairs(db.seen) do
    for mapID, list in pairs(maps) do
      for i = #list, 1, -1 do
        if now - list[i][3] > KEEP_DAYS * DAY then table.remove(list, i) end
      end
      if #list == 0 then maps[mapID] = nil end
    end
  end
  -- learned locations (db.shared) nobody has sighted or sent in KEEP_DAYS go, so a bad or made-up one doesn't
  -- stay on the map for good. Ones saved before they carried a time start from now.
  for key, maps in pairs(db.shared) do
    for mapID, list in pairs(maps) do
      for i = #list, 1, -1 do
        local p = list[i]
        p[3] = p[3] or now
        local s = FindNear(db.seen[key] and db.seen[key][mapID], mapID, p[1], p[2])
        if now - math.max(p[3], s and s[3] or 0) > KEEP_DAYS * DAY then table.remove(list, i) end
      end
      if #list == 0 then maps[mapID] = nil end
    end
  end
  local oldest = Day(now) - KEEP_DAYS
  for _, maps in pairs(db.activeDays) do
    for mapID, days in pairs(maps) do
      for day in pairs(days) do
        if day < oldest then days[day] = nil end
      end
      if not next(days) then maps[mapID] = nil end
    end
  end
  -- vouches (below): a zone goes once nothing in it is newer than VOUCH_KEEP
  for _, maps in pairs(db.vouch) do
    for mapID, v in pairs(maps) do
      local newest = v.activeAt or 0
      for i, t in pairs(v.seen or {}) do
        if now - t > VOUCH_KEEP then v.seen[i] = nil elseif t > newest then newest = t end
      end
      if now - newest > VOUCH_KEEP then maps[mapID] = nil end
    end
  end
end

-- last sighting time near a spot (nil: none in KEEP_DAYS), and the zone's active days since then
local function SeenState(key, mapID, x, y)
  local s = FindNear(db.seen[key][mapID], mapID, x, y)
  local since, n = s and Day(s[3]) or -1, 0
  for day in pairs(db.activeDays[key][mapID] or {}) do
    if day > since then n = n + 1 end
  end
  return s and s[3], n
end

---------------------------------------------------------------------------
-- Vouches (V, in answers to an F): each answerer's own verdict on every Data.lua node, from its stamps above.
-- Per zone: mapID, its active days (base 36, max 35), a checksum of the zone's Data.lua list (3 base 36 chars) and
-- one bit per node in list order, 1 = seen within SUSPECT_DAYS active days (6 bits a char, trailing zeros cut).
-- A checksum that differs from ours is another release's list: that zone is skipped. Kept in
-- SkyborneMarkerDB.vouch[dataKey][mapID] = { sum, active, activeAt, answers, seen = { [i] = t } }, for VOUCH_KEEP.
---------------------------------------------------------------------------

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function Base36(n, width)
  local s = ""
  for _ = 1, width do
    local d = n % 36
    s = B36:sub(d + 1, d + 1) .. s
    n = (n - d) / 36
  end
  return s
end

-- order matters: any insert, removal or move changes it
local function ZoneSum(list)
  local h = #list
  for _, p in ipairs(list) do
    h = (h * 131 + math.floor(p[1] * 10000 + 0.5) * 10007 + math.floor(p[2] * 10000 + 0.5)) % 46656
  end
  return Base36(h, 3)
end

-- This client's zones as V entries ("mapID,active,sum,bits"), only zones it has heard sightings in
function ns.VouchEntries()
  local key, out = Faction().key, {}
  for mapID, list in pairs(SLLCM_Data[key]) do
    local active = 0
    for _ in pairs(db.activeDays[key][mapID] or {}) do active = active + 1 end
    if #list > 0 and active > 0 then
      local chars = {}
      for c = 1, math.ceil(#list / 6) do
        local v = 0
        for b = 0, 5 do
          local p = list[(c - 1) * 6 + b + 1]
          if p then
            local t, days = SeenState(key, mapID, p[1], p[2])
            if t and days < SUSPECT_DAYS then v = v + 2 ^ b end
          end
        end
        chars[c] = B64:sub(v + 1, v + 1)
      end
      local bits = table.concat(chars):gsub("A+$", "")
      out[#out + 1] = format("%d,%s,%s,%s", mapID, Base36(math.min(active, 35), 1), ZoneSum(list), bits)
    end
  end
  return out
end

-- One heard V entry. Returns true if used, false if the zone's list differs from ours (another release).
function ns.MergeVouch(entry)
  local mapID, active, sum, bits = strsplit(",", entry)
  mapID, active = tonumber(mapID), tonumber(active or "", 36)
  local key = Faction().key
  local list = mapID and SLLCM_Data[key][mapID]
  if not (list and active and sum and bits) then return end
  if ZoneSum(list) ~= sum then return false end
  local now, maps = GetServerTime(), db.vouch[key]
  local v = maps[mapID]
  if not v or v.sum ~= sum then
    v = { sum = sum, active = 0, activeAt = 0, answers = 0, seen = {} }
    maps[mapID] = v
  end
  v.answers = v.answers + 1
  if active >= v.active or now - v.activeAt > VOUCH_KEEP then v.active, v.activeAt = active, now end
  for c = 1, #bits do
    local n = (B64:find(bits:sub(c, c), 1, true) or 1) - 1
    for b = 0, 5 do
      if n % 2 == 1 then v.seen[(c - 1) * 6 + b + 1] = now end
      n = math.floor(n / 2)
    end
  end
  return true
end

-- The crowd's view of Data.lua node i: vouched (someone saw it lately), and the zone's busiest answerer's active days
-- sums: optional cache of ZoneSum by mapID, for a caller asking about every node of a zone
local function CrowdState(key, mapID, i, sums)
  local v = db.vouch[key][mapID]
  local list = SLLCM_Data[key][mapID]
  if not (v and list) then return false, 0 end
  local sum = sums and sums[mapID] or ZoneSum(list)
  if sums then sums[mapID] = sum end
  if v.sum ~= sum then return false, 0 end
  local now = GetServerTime()
  return now - (v.seen[i] or 0) <= VOUCH_KEEP, now - v.activeAt <= VOUCH_KEEP and v.active or 0, v.answers
end

-- The shown node nearest a map position, for /sllcm share test and watch dist: self-found only, or with
-- Data.lua and shared
function ns.NearestKnown(mapID, x, y)
  local key = Faction().key
  local lists = db.selfOnly and { db.found[key][mapID] or {} }
    or { SLLCM_Data[key][mapID] or {}, db.found[key][mapID] or {}, db.shared[key][mapID] or {} }
  local best, bx, by
  for _, list in ipairs(lists) do
    for _, p in ipairs(list) do
      local d = (p[1] - x) ^ 2 + (p[2] - y) ^ 2
      if not best or d < best then best, bx, by = d, p[1], p[2] end
    end
  end
  return bx, by
end

-- Locations learned from other players' sightings: SkyborneMarkerDB.shared[dataKey][mapID] = { {x, y, t}, ... },
-- t the server time it was last heard (sighted or in an L); PruneSeen drops one not heard or sighted in KEEP_DAYS.
-- Kept apart from db.found so "self-found only" stays self-found; not learned at all while it's on.
-- true if the location was new.
function ns.LearnShared(mapID, x, y)
  if not db or db.selfOnly then return end
  local key = Faction().key
  local shared = db.shared[key]
  if FindNear(SLLCM_Data[key][mapID], mapID, x, y) or FindNear(db.found[key][mapID], mapID, x, y)
    or IsRetired(key, mapID, x, y) then return end
  local known = FindNear(shared[mapID], mapID, x, y)
  if known then
    known[3] = GetServerTime()
    return
  end
  shared[mapID] = shared[mapID] or {}
  table.insert(shared[mapID], { x, y, GetServerTime() })
  return true
end

-- For other addons (Mapzeroth): every known location of a faction's nodes, whatever "self-found only" is set to.
-- All of Data.lua, then the self-found and learned-from-others ones not already there (as the map shows them).
-- faction: "Alliance" or "Horde" (leylines or convergences); anything else means the player's own faction.
-- Returns { [mapID] = { { x, y }, ... } } (0-1 zone coordinates), a new table on each call.
function SLLCM_GetNodes(faction)
  local key = (FACTIONS[faction] or Faction()).key
  local out = {}
  local function Add(maps, all)
    for mapID, list in pairs(maps or {}) do
      local mine = out[mapID] or {}
      for _, p in ipairs(list) do
        if type(p[1]) == "number" and type(p[2]) == "number" and (all or not FindNear(mine, mapID, p[1], p[2])) then
          mine[#mine + 1] = { p[1], p[2] }
        end
      end
      if #mine > 0 then out[mapID] = mine end
    end
  end
  Add(SLLCM_Data[key], true)
  if db then
    Add(db.found[key])
    Add(db.shared[key])
  end
  return out
end

---------------------------------------------------------------------------
-- Hide pins while the node buff has more than db.hideMinutes left
---------------------------------------------------------------------------

local function BuffRemaining()
  for id in pairs(BUFF_IDS) do
    local aura = C_UnitAuras.GetPlayerAuraBySpellID(id)
    if aura and aura.duration >= MIN_DURATION then return aura.expirationTime - GetTime() end
  end
end

local timerToken, scheduledFor = 0, nil

function UpdateBuffHide()
  -- auras are secret in combat: keep the current state, PLAYER_REGEN_ENABLED looks again
  if not db or InCombatLockdown() then return end
  local ok, remaining = pcall(BuffRemaining)
  if not ok then return end -- auras unreadable (combat): keep the current state

  local limit = db.hideMinutes * 60
  local nowHidden = db.hideMinutes < MAX_MINUTES and remaining ~= nil and remaining > limit

  -- one timer, to re-check when the buff drops to the limit
  if nowHidden then
    local target = GetTime() + remaining - limit + 0.5
    if not scheduledFor or math.abs(target - scheduledFor) > 1 then
      timerToken, scheduledFor = timerToken + 1, target
      local token = timerToken
      C_Timer.After(target - GetTime(), function()
        if token == timerToken then UpdateBuffHide() end
      end)
    end
  else
    timerToken, scheduledFor = timerToken + 1, nil
  end

  if nowHidden ~= hidden then
    hidden = nowHidden
    Provider:RefreshAllData()
  end
end

-- UNIT_AURA only matters while the hide setting is on
local function SyncAuraEvent()
  if db.hideMinutes < MAX_MINUTES then
    events:RegisterUnitEvent("UNIT_AURA", "player") -- used only as a trigger; the payload is secret
  else
    events:UnregisterEvent("UNIT_AURA")
  end
end

---------------------------------------------------------------------------
-- Settings page
---------------------------------------------------------------------------

local category, crowdSetting

-- shared by the settings checkbox and the first-run popup
local SHARE_TEXT = "When one of your Skyborne characters finds an Elemental Convergence or Leyline with its racial, "
  .. "its location is sent to other users of the addon, so new locations show up on their map. You will get "
  .. "theirs as well."

-- the details behind it: the settings checkbox's tooltip and the popup's "How it works" link
local HOW_TITLE = "How sharing works"
local HOW_TEXT = "Sharing uses WoW's built-in addon messages on a hidden chat channel for your faction. Everything "
  .. "goes through Blizzard's own servers: no outside server, no web traffic.\n\n"
  .. "A sighting sends only the map, position and time seen, for example:\n"
  .. "R:1:H:0:1413:5496:3462:1791831931\n\n"
  .. "Nothing about your character, gear or account is sent. New node locations learned from others are kept.\n\n"
  .. "Turning sharing off leaves the channel, so nothing is sent or received."

local function ShowHowItWorks(owner)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:SetText(HOW_TITLE)
  GameTooltip:AddLine(HOW_TEXT, 1, 1, 1, true)
  GameTooltip:Show()
end

local function InitSettings()
  category = Settings.RegisterVerticalLayoutCategory("Skyborne Leyline & Convergence Marker")
  local setting = Settings.RegisterAddOnSetting(category, "LEYLINEMARKER_SELF_ONLY", "selfOnly", db,
    Settings.VarType.Boolean, "Show only self-found locations", false)
  setting:SetValueChangedCallback(function() Provider:RefreshAllData() end)
  Settings.CreateCheckbox(category, setting,
    "When checked, the map shows only the locations you have found yourself. When unchecked, it shows every known location.")

  local other = Settings.RegisterAddOnSetting(category, "LEYLINEMARKER_NON_SKYBORNE", "showNonSkyborne", db,
    Settings.VarType.Boolean, "Show on non-Skyborne characters", false)
  other:SetValueChangedCallback(function() Provider:RefreshAllData() end)
  Settings.CreateCheckbox(category, other,
    "Only Skyborne can see leylines and elemental convergences, so pins are hidden on other characters. Check this to show them anyway.")

  crowdSetting = Settings.RegisterAddOnSetting(category, "LEYLINEMARKER_CROWD", "crowd", db,
    Settings.VarType.Boolean, "Share sightings with other users", false)
  crowdSetting:SetValueChangedCallback(function(_, value)
    db.crowdAsked = true
    ns.SetCrowdEnabled(value)
  end)
  Settings.CreateCheckbox(category, crowdSetting, SHARE_TEXT .. "\n\n" .. HOW_TITLE .. "\n" .. HOW_TEXT)

  local alpha = Settings.RegisterAddOnSetting(category, "LEYLINEMARKER_PIN_ALPHA", "pinAlpha", db,
    Settings.VarType.Number, "Pin opacity", PIN_PERCENT)
  alpha:SetValueChangedCallback(function() Provider:RefreshAllData() end)
  local alphaOptions = Settings.CreateSliderOptions(10, 100, 5)
  alphaOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(v)
    return format("%d%%", v)
  end)
  Settings.CreateSlider(category, alpha, alphaOptions, "How visible the pins on the map are.")

  -- The slider moves through HIDE_STEPS by index; db.hideMinutes keeps minutes. A saved value between stops
  -- shows as the nearest stop and stays as saved until the slider is moved.
  local function StepOf(minutes)
    local best = #HIDE_STEPS
    for i, m in ipairs(HIDE_STEPS) do
      if math.abs(m - minutes) < math.abs(HIDE_STEPS[best] - minutes) then best = i end
    end
    return best
  end
  local hide = Settings.RegisterProxySetting(category, "LEYLINEMARKER_HIDE_MINUTES", Settings.VarType.Number,
    "Hide pins while buff has more than", #HIDE_STEPS,
    function() return StepOf(db.hideMinutes) end,
    function(i)
      local minutes = HIDE_STEPS[i]
      if minutes and StepOf(db.hideMinutes) ~= i then
        db.hideMinutes = minutes
        UpdateBuffHide()
        SyncAuraEvent()
      end
    end)
  local options = Settings.CreateSliderOptions(1, #HIDE_STEPS, 1)
  options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(i)
    local minutes = HIDE_STEPS[i] or MAX_MINUTES
    return minutes >= MAX_MINUTES and "Always show" or format("%d min", minutes)
  end)
  Settings.CreateSlider(category, hide, options,
    "Hides the pins while your leyline or convergence buff has more than this many minutes left, so you only see them when you need to find one. Set to Always show to never hide them.")
  ns.RegisterAboutPage(category)   -- version, Discord and the author's other addons
  Settings.RegisterAddOnCategory(category)
end

---------------------------------------------------------------------------
-- First-run question: sharing stays off until the player chooses
---------------------------------------------------------------------------

local howLink

StaticPopupDialogs.SKYBORNE_MARKER_SHARE = {
  text = "|cff66ccffSkyborne Leyline & Convergence Marker|r\n\n"
    .. "Share sightings with other players using this addon?\n\n"
    .. SHARE_TEXT .. "\n\n"
    .. "You can change this later in Addon Settings or with /sllcm.\n\n", -- blank line: the "How it works" link
  button1 = "Enable",
  button2 = "Leave Disabled",
  -- popup frames are shared between dialogs: the link is moved onto whichever one shows us, and hidden after
  OnShow = function(self)
    local link = howLink
    if not link then
      link = CreateFrame("Button")
      link:SetHeight(18)
      link:SetNormalFontObject(GameFontHighlightSmall)
      link:SetText("|cff66ccffHow it works|r")
      link:SetScript("OnEnter", ShowHowItWorks)
      link:SetScript("OnClick", ShowHowItWorks)
      link:SetScript("OnLeave", GameTooltip_Hide)
      howLink = link
    end
    link:SetParent(self)
    -- on the blank line just above the buttons, spanning both (so the text is centred between them)
    link:ClearAllPoints()
    local container = self.ButtonContainer
    local b1 = self.button1 or (container and container.Button1)
    local b2 = self.button2 or (container and container.Button2)
    if b1 and b2 then
      link:SetPoint("BOTTOMLEFT", b1, "TOPLEFT", 0, 2)
      link:SetPoint("BOTTOMRIGHT", b2, "TOPRIGHT", 0, 2)
    else
      link:SetSize(110, 18)
      link:SetPoint("BOTTOM", 0, 42)
    end
    link:SetFrameLevel(self:GetFrameLevel() + 5)
    link:Show()
  end,
  OnHide = function()
    if howLink then howLink:Hide() end
  end,
  OnAccept = function()
    db.crowdAsked = true
    crowdSetting:SetValue(true)
  end,
  OnCancel = function()
    db.crowdAsked = true
    if db.crowd then crowdSetting:SetValue(false) end
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = false,
  preferredIndex = 3,
}

local function AskToShare()
  if db.crowdAsked then return end
  StaticPopup_Show("SKYBORNE_MARKER_SHARE")
end

---------------------------------------------------------------------------
-- Export window
---------------------------------------------------------------------------

local exportFrame
local REPORT_URL = "https://github.com/tr0tsky0/SLLCM/issues/new?template=nodes.yml"
local URL_MAX = 5000 -- GitHub took a 6000-character field value and failed from 7000 (500, then 414), 22 Nov 2026
local NUDGE_STEP = 5 -- login reminder once this many new finds are waiting, then again each time it grows this much

local function Version()
  local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  return get(ADDON, "Version") or "?"
end

-- Self-found locations that Data.lua doesn't have yet and that aren't retired, what's worth sending in:
-- { [mapID] = { p, ... } } and how many
local function NewFinds()
  local key, byMap, n = Faction().key, {}, 0
  for mapID, list in pairs(db.found[key]) do
    for _, p in ipairs(ZoneSizeYards(mapID) and list or EMPTY) do -- no size yet: can't compare, don't count
      if not FindNear(SLLCM_Data[key][mapID], mapID, p[1], p[2]) and not IsRetired(key, mapID, p[1], p[2]) then
        byMap[mapID] = byMap[mapID] or {}
        table.insert(byMap[mapID], p)
        n = n + 1
      end
    end
  end
  return byMap, n
end

-- The form link with the new finds filled in (the form's "export" field), or nil when there are none or
-- they don't fit. Compact so it fits: a header line, then a line per zone, "mapID_XXXXYYYY.XXXXYYYY",
-- each coordinate 4 digits (x 10000). Only letters, digits and - _ . ~ go into a link as themselves; every
-- other character takes 3, hence _ and . rather than : and spaces.
local function PrefilledURL()
  local byMap, n = NewFinds()
  if n == 0 then return end
  local ids = {}
  for mapID in pairs(byMap) do ids[#ids + 1] = mapID end
  table.sort(ids)
  local function D(v) return format("%04d", math.max(0, math.min(9999, math.floor(v * 10000 + 0.5)))) end
  local lines = { format("SLLCM %s %s %s", Version(), Faction().key, date("!%Y-%m-%d")) }
  for _, mapID in ipairs(ids) do
    local pts = {}
    for _, p in ipairs(byMap[mapID]) do pts[#pts + 1] = D(p[1]) .. D(p[2]) end
    lines[#lines + 1] = mapID .. "_" .. table.concat(pts, ".")
  end
  local value = table.concat(lines, "\n"):gsub("[^%w%-_%.~]", function(c) return format("%%%02X", c:byte()) end)
  local url = REPORT_URL .. "&export=" .. value
  if #url <= URL_MAX then return url, n end
end
ns.PrefilledURL = PrefilledURL

-- A chat line at login when new finds pile up. db.nudgedAt follows the count down when an update takes them in.
local function NudgeExport()
  if not IsSkyborne() then return end
  local _, n = NewFinds()
  local last = math.min(db.nudgedAt or 0, n)
  db.nudgedAt = last
  if n >= last + NUDGE_STEP then
    db.nudgedAt = n
    Print("you've found %d %ss that aren't in the addon yet. Type |cffffff00/sllcm export|r to send them in.",
      n, Faction().name)
  end
end

-- Self-found, then learned from other players (skipping any that are in Data.lua or self-found by now)
local function BuildExport()
  local key = Faction().key
  local lines, count = { format("-- SLLCM %s, %s, %s", Version(), key, date("!%Y-%m-%d")) }, 0

  local function Section(title, source, skip)
    local ids = {}
    for mapID in pairs(source) do ids[#ids + 1] = mapID end
    table.sort(ids)
    local header = false
    for _, mapID in ipairs(ids) do
      local points = {}
      for _, p in ipairs(source[mapID]) do
        if not (skip and skip(mapID, p)) then points[#points + 1] = p end
      end
      if #points > 0 then
        if not header then
          lines[#lines + 1] = "-- " .. key .. ", " .. title
          header = true
        end
        lines[#lines + 1] = format("[%d] = { -- %s", mapID, MapName(mapID))
        for _, p in ipairs(points) do
          lines[#lines + 1] = format("  { %.4f, %.4f },", p[1], p[2])
          count = count + 1
        end
        lines[#lines + 1] = "},"
      end
    end
  end

  Section("self-found", db.found[key])
  Section("from other players", db.shared[key], function(mapID, p)
    return FindNear(SLLCM_Data[key][mapID], mapID, p[1], p[2]) or FindNear(db.found[key][mapID], mapID, p[1], p[2])
  end)

  -- Candidates for SLLCM_Retired, and retired points seen again. Lines: { x, y }, -- source, last seen, active days
  local function When(t) return t and date("!%Y-%m-%d", t) or "never" end
  local function Status(title, collect)
    local byMap, ids = {}, {}
    collect(function(mapID, p, what)
      if not byMap[mapID] then byMap[mapID], ids[#ids + 1] = {}, mapID end
      table.insert(byMap[mapID], format("  { %.4f, %.4f }, -- %s", p[1], p[2], what))
      count = count + 1
    end)
    if #ids == 0 then return end
    table.sort(ids)
    lines[#lines + 1] = "-- " .. key .. ", " .. title
    for _, mapID in ipairs(ids) do
      lines[#lines + 1] = format("[%d] = { -- %s", mapID, MapName(mapID))
      for _, l in ipairs(byMap[mapID]) do lines[#lines + 1] = l end
      lines[#lines + 1] = "},"
    end
  end
  -- Suspect: nobody (us, or for Data.lua nodes any vouching answerer) saw it lately, while we or an answerer
  -- had its zone active SUSPECT_DAYS+ days. Comment: source, our last sighting and active days since, then the
  -- crowd's: its busiest answerer's active days there and how many answers covered the zone.
  Status(format("suspect: zone active %d+ days since last seen", SUSPECT_DAYS), function(add)
    local sources = { { "Data", SLLCM_Data[key] }, { "self-found", db.found[key] }, { "shared", db.shared[key] } }
    local sums = {}
    for s, source in ipairs(sources) do
      for mapID, list in pairs(source[2]) do
        for i, p in ipairs(list) do
          local dup = false -- shown once: the map draws a later list's point only if no earlier list has it
          for j = 1, s - 1 do dup = dup or FindNear(sources[j][2][mapID], mapID, p[1], p[2]) ~= nil end
          local t, days = SeenState(key, mapID, p[1], p[2])
          local vouched, crowdDays, answers = false, 0, nil
          if s == 1 then vouched, crowdDays, answers = CrowdState(key, mapID, i, sums) end
          local seenLately = t and days < SUSPECT_DAYS
          if not dup and not seenLately and not vouched and math.max(days, crowdDays) >= SUSPECT_DAYS then
            add(mapID, p, format("%s, last seen %s, %d days%s", source[1], When(t), days,
              answers and format(", crowd %d days, %d answers", crowdDays, answers) or ""))
          end
        end
      end
    end
  end)
  -- a sighting counts for a retired point only if it's nearer to it than to any Data.lua node: a retired copy
  -- beside a real node mustn't look seen whenever the real one is
  Status("retired but seen", function(add)
    local function Dist(mapID, x1, y1, x2, y2)
      local w, h = ZoneSizeYards(mapID)
      return w and math.sqrt(((x1 - x2) * w) ^ 2 + ((y1 - y2) * h) ^ 2) or math.huge
    end
    for mapID, list in pairs(SLLCM_Retired and SLLCM_Retired[key] or {}) do
      for _, p in ipairs(list) do
        local last
        for _, s in ipairs(db.seen[key][mapID] or {}) do
          local d = Dist(mapID, p[1], p[2], s[1], s[2])
          local closer = false
          for _, q in ipairs(SLLCM_Data[key][mapID] or {}) do
            closer = closer or Dist(mapID, q[1], q[2], s[1], s[2]) < d
          end
          if d < SAME_YARDS and not closer and (not last or s[3] > last) then last = s[3] end
        end
        if last then add(mapID, p, "last seen " .. When(last)) end
      end
    end
  end)
  return table.concat(lines, "\n"), count
end

local function ShowExport()
  if not exportFrame then
    local f = CreateFrame("Frame", "LeyLineMarkerExport", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(420, 420)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f.TitleText:SetText("Skyborne Marker - Export")
    tinsert(UISpecialFrames, f:GetName())

    -- WoW can't open a link or write the clipboard: the address sits in a box for Ctrl+C
    local how = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    how:SetPoint("TOPLEFT", 14, -32)
    how:SetPoint("RIGHT", -14, 0)
    how:SetJustifyH("LEFT")
    f.how = how
    local link = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    link:SetPoint("TOPLEFT", how, "BOTTOMLEFT", 6, -6)
    link:SetPoint("RIGHT", -14, 0)
    link:SetHeight(20)
    link:SetAutoFocus(false)
    link:SetMaxLetters(0)
    link:SetFontObject(ChatFontNormal)
    link:SetScript("OnTextChanged", function(self, user) if user then self:SetText(f.url) self:HighlightText() end end)
    link:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    link:SetScript("OnEscapePressed", function() f:Hide() end)
    f.link = link

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", link, "BOTTOMLEFT", -8, -8)
    scroll:SetPoint("BOTTOMRIGHT", -32, 12)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(370)
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    edit:SetScript("OnKeyDown", function(_, key)
      if key == "C" and IsControlKeyDown() then C_Timer.After(0, function() f:Hide() end) end
    end)
    scroll:SetScrollChild(edit)
    f.edit = edit
    exportFrame = f
  end
  local text, count = BuildExport()
  if count == 0 then
    Print("nothing found yet.")
    return
  end
  local f = exportFrame
  local url, n = PrefilledURL()
  if url then
    f.how:SetText(format("To send in your %d new finds, copy this link (Ctrl+C) into your browser: it opens a "
      .. "GitHub form with them filled in. No GitHub account? Post the text below on the Discord.", n))
  else
    f.how:SetText("To send these in: copy this link into your browser, then copy the text below (Ctrl+C) "
      .. "into the form. A GitHub account is needed; or post the text on the Discord.")
  end
  f.url = url or REPORT_URL
  f.link:SetText(f.url)
  f.link:SetCursorPosition(0)
  f.edit:SetText(text)
  f:Show()
  if url then
    f.link:SetFocus()
    f.link:HighlightText()
    return
  end
  exportFrame.edit:SetFocus()
  exportFrame.edit:HighlightText()
end

---------------------------------------------------------------------------
-- Slash commands and events
---------------------------------------------------------------------------

local settingsAfterCombat -- /sllcm in combat: open the settings when it ends

SLASH_LEYLINEMARKER1 = "/sllcm"
SlashCmdList.LEYLINEMARKER = function(msg)
  local cmd, rest = msg:lower():match("^%s*(%S*)%s*(.-)%s*$")
  if cmd == "export" then
    ShowExport()
  elseif cmd == "share" then
    ns.ShareCommand(rest)
  elseif cmd == "scan" and ns.ScanCommand then
    ns.ScanCommand()
  elseif cmd == "watch" and ns.WatchCommand then
    ns.WatchCommand(rest)
  else
    -- opening Settings from addon code in combat risks a blocked action (not confirmed on Forever): wait it out
    if InCombatLockdown() then
      settingsAfterCombat = true
      Print("settings open when combat ends")
    else
      Settings.OpenToCategory(category:GetID())
    end
    Print("/sllcm export - send your found locations to the author")
  end
end

events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player") -- UNIT_AURA: SyncAuraEvent
events:SetScript("OnEvent", function(_, event, arg1, arg2, spellID)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    SkyborneMarkerDB = SkyborneMarkerDB or {}
    db = SkyborneMarkerDB
    for _, field in ipairs({ "found", "shared", "seen", "activeDays", "vouch" }) do
      db[field] = db[field] or {}
      for _, f in pairs(FACTIONS) do
        db[field][f.key] = db[field][f.key] or {}
      end
    end
    -- zone sizes (for distances) aren't always ready this early
    C_Timer.After(5, function()
      PruneKnown()
      PruneSeen()
    end)
    if db.selfOnly == nil then db.selfOnly = false end
    if db.showNonSkyborne == nil then db.showNonSkyborne = false end
    if db.hideMinutes == nil then db.hideMinutes = MAX_MINUTES end
    if db.crowd == nil then db.crowd = false end
    if db.minimapScan == nil then db.minimapScan = true end
    -- unsighted-pin opacity went with phases (1.5.0): one opacity for every pin now, starting solid (the old
    -- default, 40%, was for pins beside solid sighted ones)
    if db.pinAlpha == nil then db.pinAlpha = PIN_PERCENT end
    db.unseenAlpha, db.hideUnseen = nil, nil
    SyncAuraEvent()
    InitSettings()
  -- a spell flagged always-secret gives a secret spellID even for the player: never a table key
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" and db and not (issecretvalue and issecretvalue(spellID))
    and RACIAL_IDS[spellID] then
    OnRacialCast()
  elseif event == "PLAYER_REGEN_ENABLED" then
    CheckPending()
    UpdateBuffHide()
    if settingsAfterCombat then
      settingsAfterCombat = nil
      Settings.OpenToCategory(category:GetID())
    end
  elseif event == "PLAYER_ENTERING_WORLD" then
    UpdateBuffHide()
    if arg1 or arg2 then -- login or /reload, not zoning
      C_Timer.After(5, AskToShare)
      C_Timer.After(15, NudgeExport) -- after PruneKnown (5 s), when zone sizes are ready for the distance checks
    end
  elseif event == "UNIT_AURA" and db and (hidden or db.hideMinutes < MAX_MINUTES) then
    UpdateBuffHide()
  end
end)
