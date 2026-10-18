-- Records ley lines for adding to LeyLineMarker's Data.lua.
-- Sources: hovering the minimap blip (estimate, ~15-20 yd), and the racial giving its long
-- buff (confirmed: your own position). Saved in LeyLineTestDB[mapID] = { {x, y, c}, ... }.

local ADDON = ...

local RACIAL_IDS = { [1259705] = true, [1259686] = true } -- Read Ley Line, Skysight
local BUFF_IDS = { [1259691] = true, [1270893] = true }      -- Energized, Elemental Blessing
local BLIP_NAMES = { "Leyline", "Ley Line", "Elemental Convergence" } -- minimap tooltip text; English only
local SAME_YARDS = 60              -- closer than this counts as the same ley line
local MAX_SAMPLE_YARDS = 60       -- widest a minimap hover sample may spread before it is thrown away
local CONFIRM_MIN_DURATION = 600  -- the racial's buff lasts 15 min on a ley line, 15-30 s off one

local db

-- Data.lua table (in SLLCM_Data) for the player's faction; saved entries carry it as p[4]
local function FactionKey()
  return UnitFactionGroup("player") == "Horde" and "ElementalConvergences" or "LeyLines"
end

local function KeyOf(p) return p[4] or "LeyLines" end

local function Print(msg, ...)
  print("|cff66ccffLeyLineTest:|r " .. format(msg, ...))
end

local function MapName(mapID)
  local info = C_Map.GetMapInfo(mapID)
  return info and info.name or ("map " .. mapID)
end

---------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------

local function ZoneSizeYards(mapID)
  local _, a = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
  local _, b = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(1, 1))
  if not a or not b then return end
  -- world axes are swapped relative to map axes
  return math.abs(b.y - a.y), math.abs(b.x - a.x)
end

local function PlayerZonePos()
  local mapID = C_Map.GetBestMapForUnit("player")
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if pos then return mapID, pos.x, pos.y end
end

local function CursorOnMinimapToZone()
  local mapID, px, py = PlayerZonePos()
  if not mapID then return end
  local w, h = ZoneSizeYards(mapID)
  if not w then return end

  local s = Minimap:GetEffectiveScale()
  local cx, cy = GetCursorPosition()
  local mx, my = Minimap:GetCenter()
  local ypp = C_Minimap.GetViewRadius() / (Minimap:GetWidth() / 2)
  local dx, dy = (cx / s - mx) * ypp, (cy / s - my) * ypp  -- yards; +x east, +y north

  if GetCVar("rotateMinimap") == "1" then
    local f = GetPlayerFacing() or 0
    dx, dy = dx * math.cos(f) - dy * math.sin(f), dx * math.sin(f) + dy * math.cos(f)
  end

  return mapID, px + dx / w, py - dy / h
end

local function FindNear(list, mapID, x, y, key)
  local w, h = ZoneSizeYards(mapID)
  if not w then return end
  for _, p in ipairs(list or {}) do
    if (not key or KeyOf(p) == key) and math.sqrt(((p[1] - x) * w) ^ 2 + ((p[2] - y) * h) ^ 2) < SAME_YARDS then return p end
  end
end

local function Listed(key, mapID, x, y)
  return SLLCM_Data and SLLCM_Data[key] and FindNear(SLLCM_Data[key][mapID], mapID, x, y)
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------

local function Record(mapID, x, y, confirmed, how)
  local where = format("%s %.2f, %.2f", MapName(mapID), x * 100, y * 100)
  local key = FactionKey()
  local listed = Listed(key, mapID, x, y)
  local mine = FindNear(db[mapID], mapID, x, y, key)

  if mine then
    -- a confirmed reading replaces an estimate
    if confirmed and not mine[3] then
      mine[1], mine[2], mine[3] = x, y, true
      Print("confirmed %s (%s)", where, how)
    elseif how == "minimap" then
      Print("%s (minimap) - already recorded", where)
    end
    return
  end

  db[mapID] = db[mapID] or {}
  table.insert(db[mapID], { x, y, confirmed, key })
  if listed then
    Print("%s (%s) - already in Data.lua", where, how)
  else
    Print("|cffffff00NEW|r %s (%s)", where, how)
  end
end

---------------------------------------------------------------------------
-- Minimap hover. The tooltip appears when the cursor enters the blip, so we track the bounding
-- box of cursor readings while it stays up and record the centre. Sweeping across the blip, or
-- letting it slide under a parked cursor on a taxi, gets close to the blip centre.
---------------------------------------------------------------------------

local sample

local function IsLeyLineTooltip()
  -- Skyborne Marker reads the minimap itself (scan, or controller pointer): it records and shares those
  if SLLCM_MinimapDetection and SLLCM_MinimapDetection() then return end
  if not Minimap:IsMouseOver() then return end
  -- any line: other minimap objects (quest blips) can share the tooltip
  for i = 1, GameTooltip:NumLines() do
    local line = _G["GameTooltipTextLeft" .. i]
    local text = line and line:GetText()
    if text then
      for _, name in ipairs(BLIP_NAMES) do
        if text:find(name, 1, true) then return true end
      end
    end
  end
end

local function Sample()
  local mapID, x, y = CursorOnMinimapToZone()
  if not mapID then return end
  if not sample then
    sample = { mapID = mapID, x0 = x, x1 = x, y0 = y, y1 = y }
  elseif mapID == sample.mapID then
    sample.x0, sample.x1 = math.min(sample.x0, x), math.max(sample.x1, x)
    sample.y0, sample.y1 = math.min(sample.y0, y), math.max(sample.y1, y)
  end
end

local function FinishSample()
  if not sample then return end
  local s = sample
  sample = nil
  -- a box much bigger than the blip means we moved or the tooltip lingered: the centre is meaningless
  local w, h = ZoneSizeYards(s.mapID)
  if w and (((s.x1 - s.x0) * w > MAX_SAMPLE_YARDS) or ((s.y1 - s.y0) * h > MAX_SAMPLE_YARDS)) then
    Print("minimap sample discarded (spread too wide)")
    return
  end
  local x, y = (s.x0 + s.x1) / 2, (s.y0 + s.y1) / 2
  Record(s.mapID, x, y, false, "minimap")
  -- the blip only shows while the node is up in our phase: share it as a sighting (no-op unless
  -- Skyborne Marker is loaded with sharing on)
  if SLLCM_ReportSighting then SLLCM_ReportSighting(s.mapID, x, y) end
end

GameTooltip:HookScript("OnShow", function()
  FinishSample()
  if IsLeyLineTooltip() then Sample() end
end)

-- also starts a sample: a tooltip rebuilt while showing doesn't fire OnShow again
GameTooltip:HookScript("OnUpdate", function()
  if not sample and not GameTooltip:IsShown() then return end
  if IsLeyLineTooltip() then Sample() else FinishSample() end
end)

GameTooltip:HookScript("OnHide", FinishSample)

---------------------------------------------------------------------------
-- Racial: on a node it grants Energized (Alliance) / Elemental Blessing (Horde) for 15 min.
---------------------------------------------------------------------------

local function HasNewNodeBuff(since)
  for id in pairs(BUFF_IDS) do
    local aura = C_UnitAuras.GetPlayerAuraBySpellID(id)
    if aura and aura.duration >= CONFIRM_MIN_DURATION and aura.expirationTime - aura.duration >= since then
      return true
    end
  end
  return false
end

local function OnRacialCast()
  local mapID, x, y = PlayerZonePos()
  if not mapID then return end
  local castTime = GetTime() - 1
  local tries = 0
  local function Check()
    tries = tries + 1
    -- errors if auras are secret right now (e.g. in combat); skip that cast
    local ok, found = pcall(HasNewNodeBuff, castTime)
    if not ok then return end
    if found then
      Record(mapID, x, y, true, "racial")
    elseif tries < 4 then
      C_Timer.After(0.5, Check)
    end
  end
  C_Timer.After(0.2, Check)
end

---------------------------------------------------------------------------
-- Slash commands and events
---------------------------------------------------------------------------

SLASH_LEYLINETEST1 = "/llt"
SlashCmdList.LEYLINETEST = function(msg)
  local cmd, rest = msg:lower():match("^%s*(%S*)%s*(.*)")
  if cmd == "here" then
    local mapID, x, y = PlayerZonePos()
    if mapID then Record(mapID, x, y, true, "manual") end
    return
  elseif cmd == "pos" then
    local mapID, x, y = PlayerZonePos()
    if mapID then Print("you: %s (%d) %.2f, %.2f", MapName(mapID), mapID, x * 100, y * 100) end
    return
  elseif cmd == "add" then
    -- /llt add mapID, x, y  (x, y as shown in game, e.g. 51.1, 67.5; 0-1 values also work)
    local mapID, x, y = rest:match("^(%d+)[,%s]+([%d.]+)[,%s]+([%d.]+)")
    mapID, x, y = tonumber(mapID), tonumber(x), tonumber(y)
    if not (mapID and x and y and C_Map.GetMapInfo(mapID)) then
      Print("usage: /llt add mapID, x, y   e.g. /llt add 1436, 51.1, 67.5")
      return
    end
    if x > 1 or y > 1 then x, y = x / 100, y / 100 end
    Record(mapID, x, y, true, "added")
    return
  elseif cmd == "pois" or cmd == "vignettes" then
    -- has Blizzard exposed ley lines / convergences to an API yet?
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return end
    local rows = {}
    local function add(id, name, atlas, pos)
      local x, y = pos and pos:GetXY()
      local hit = ((name or "") .. " " .. (atlas or "")):lower()
      hit = hit:find("ley") or hit:find("converg")
      rows[#rows + 1] = format("%s%s %s [%s] %s", hit and "|cffffff00!!|r " or "", tostring(id),
        tostring(name), tostring(atlas), x and format("%.1f, %.1f", x * 100, y * 100) or "?")
    end
    if cmd == "pois" then
      if not C_AreaPoiInfo then return Print("C_AreaPoiInfo doesn't exist on this client") end
      for _, id in ipairs(C_AreaPoiInfo.GetAreaPOIForMap(mapID) or {}) do
        local i = C_AreaPoiInfo.GetAreaPOIInfo(mapID, id)
        if i then add(id, i.name, i.atlasName, i.position) end
      end
    else
      if not C_VignetteInfo then return Print("C_VignetteInfo doesn't exist on this client") end
      for _, guid in ipairs(C_VignetteInfo.GetVignettes() or {}) do
        local i = C_VignetteInfo.GetVignetteInfo(guid)
        if i then add(i.vignetteID, i.name, i.atlasName, C_VignetteInfo.GetVignettePosition(guid, mapID)) end
      end
    end
    for _, row in ipairs(rows) do Print(row) end
    Print("%d %s in %s%s", #rows, cmd, MapName(mapID),
      cmd == "vignettes" and " (nearby only, roughly minimap range)" or "")
    return
  end
  local count = 0
  for mapID, list in pairs(db) do
    for _, p in ipairs(list) do
      local key = KeyOf(p)
      if not Listed(key, mapID, p[1], p[2]) then
        Print("%s %.2f, %.2f%s%s", MapName(mapID), p[1] * 100, p[2] * 100,
          key == "LeyLines" and "" or " [convergence]", p[3] and "" or " (estimate)")
        count = count + 1
      end
    end
  end
  Print("%d not yet in Data.lua. Also: /llt here, /llt add mapID, x, y, /llt pos, /llt pois, /llt vignettes", count)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
events:SetScript("OnEvent", function(_, event, arg1, _, spellID)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    LeyLineTestDB = LeyLineTestDB or {}
    db = LeyLineTestDB
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" and RACIAL_IDS[spellID] then
    OnRacialCast()
  end
end)
