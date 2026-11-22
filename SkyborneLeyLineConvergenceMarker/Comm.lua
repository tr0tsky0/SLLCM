-- Crowdsourced sightings: when the racial or a minimap scan confirms a node, broadcast it on a hidden channel with
-- the server time. Others learn the location and stamp it last seen (for spotting bad locations).
-- No phases: the 1.60.1 hotfix obfuscates creature GUIDs, so the layer can't be read or compared any more.
--
-- Messages (":" separated, no pipes):
--   R:v:fac:phase:mapID:x:y:t          one sighting (x, y as 0-9999). We send phase NO_PHASE; older clients sent
--                                      the layer, and read ours as a phase they're never in
--   S:v:fac:phase:mapID,x,y,t;...      older clients' reply to a Q (no longer sent or answered): read like R's
--   F:v:fac                            "what have you found that isn't in Data.lua?" (/sllcm share found, dev copy)
--   L:v:fac:mapID,x,y;...              reply to F: self-found, then shared locations, learned as shared ones.
--                                      Self-found only, sent unasked after login (ANNOUNCE_*), at most once per
--                                      ANNOUNCE_GAP
--   VQ:v:fac                           "which Data.lua nodes have you seen lately?" (/sllcm share vouch, dev copy)
--   V:v:fac:mapID,active,sum,bits;...  reply to VQ, per zone (see ns.VouchEntries). Never unasked; merged only
--                                      within VOUCH_WINDOW of a VQ, each zone once per sender.
-- Ignored: Q (older clients asking about their phase), and Skyborne Compass's per-phase "not there"s (XM / XS).

local ADDON, ns = ...

local PREFIX = "SLLCM"
local CHANNEL_BASE = "SLLCMShare"  -- + A / H: one channel per faction
local VERSION = "1"
local NO_PHASE = "0"         -- the R's phase field: kept so older clients still parse it
local MAX_AGE = 90 * 60      -- a heard sighting older than this is ignored (older clients' S replies held this long)
local MAX_FOUND_PER_REPLY = 15 -- entries per L message, keeps it under 255 bytes
-- Our self-found locations Data.lua lacks go out unasked, as an L, this long after the channel is first heard this
-- session (plus up to ANNOUNCE_SPREAD at random), and not again until ANNOUNCE_GAP after we last sent them (an
-- answer to an F counts too). Only self-found, never shared ones, so nothing is passed on and on.
local ANNOUNCE_DELAY = 30
local ANNOUNCE_SPREAD = 60
local ANNOUNCE_GAP = 20 * 60 * 60
local FOUND_SPREAD = 16      -- an F is answered 4 s to 4 + this after it's heard
-- Forever's channel allowance is about 10 at once then ~0.8/s, and retrying while refused keeps it
-- refusing; a pause of a few seconds clears it
local SEND_GAP = 1.25
local THROTTLE_PAUSE = 5
local CHANNEL_RETRIES = 3    -- InvalidChannel just after joining (the join not through yet): retry this often
local WHO_WAIT = 4           -- a greyed-out channel: /chatwho it, and look again this many seconds later...
local FRESHEN_WAIT = 2       -- ...still listed: leave it, and join again this many seconds later...
local FRESHEN_QUICK = 2      -- ...the first this many of a session at most FRESHEN_QUICK_GAP apart (one at login
local FRESHEN_QUICK_GAP = 15 --    mustn't leave nothing for the first refused send)...
local FRESHEN_GAP = 120      -- ...the rest at most this often...
local FRESHEN_MAX = 6        -- ...this many times a session...
local FRESHEN_SLOW_GAP = 600 -- ...then at most this often for the rest of it: a block has cleared on the 6th, about
                             --    10 min in (Horde, 17 Nov), so stopping would miss it; a /reload only reset the count
local COUNT_GAP = 600        -- share debug on: how many are in our channel (/chatwho) is logged at most this often
local PAUSE_SECONDS = 600   -- refused: nothing is sent this long, then the next message goes as a probe
local ECHO_SECONDS = 15      -- the server echoes our channel messages back: none this long after a send, it was dropped
local RECHECK_SECONDS = 3    -- after a notice that we may be out of the channel, look again this much later
local JOIN_GAP = 5           -- a join is never sent again sooner than this (a notice and a rejoin racing)
local REORDER_SECONDS = 60   -- after joining, game channels arriving above ours get moved below it this long
local MAX_SWAPS = 10         -- channel swaps allowed per join (the game has about 10 channels)

local foundAnswered          -- an F is answered once a session, so repeated ones can't keep the channel busy
local foundAsked             -- we sent an F this session: say what the answers teach us
local vouchAnswered, vouchAsked -- the same for VQ
-- V's are merged only this long after a VQ went out or was heard (answers come 4-20 s after it), each zone once
-- per sender: an unasked or repeated V can't make bad nodes look vouched for
local VOUCH_WINDOW = 90
local vouchOpenAt, vouchFrom = nil, {}
local announcing             -- true: the unasked L is due, once the channel is first heard
local announceOpen           -- the unasked L is under way: not all of it echoed back yet. A refusal now re-arms it
local announceGen = 0        -- bumped by each Announce and each re-arm: an older run's timers stop
local announceOut = 0        -- its L's sent and not yet echoed
local announceSending        -- its L's still being built and sent
local queue, sending = {}, false
local channelRetries = 0     -- InvalidChannel retries spent on queue[1]
local pausedUntil            -- GetTime() until which nothing is sent: the server refused our messages on the channel
local pauseWarned            -- the player was told sharing is paused (and gets told when it works again)
local awaitingEcho           -- GetTime() of the oldest send whose echo hasn't come back yet
local freshened, freshenedAt = 0, nil -- revives (Freshen) this session, and when the last one went out
local freshening             -- a revive is under way: its own look comes WHO_WAIT later
local whoUntil               -- GetTime() until which a /chatwho list of our channel is ours, kept out of chat
local countAt                -- GetTime() of the last member count asked for (share debug)
local counted                -- members in the /chatwho answer coming in, nil when none is awaited
local countNames, countParts = {}, 0 -- that answer's distinct names, and how many CHAT_MSG_CHANNEL_LIST parts it came in
local lastJoinAt             -- GetTime() of the last join sent
local me = {}                -- our names as senders show them
local debug                  -- /sllcm share debug: print traffic
local reorderUntil           -- GetTime() until which our channel is kept numbered after the game's
local swapsLeft = 0          -- channel swaps still allowed in that time

-- debug lines carry the local time to a tenth of a second, to tell bursts from spread-out traffic. The clock
-- is time() pinned to GetTime() once, so the tenths stay in step with the seconds.
local clockBase = time() - GetTime()

-- Debug lines go to the dev copy's own window when it's on (DebugWindow.lua, /sllcm share debug window), so the
-- traffic stays out of chat; otherwise to chat like everything else.
local function Debug(msg, ...)
  if not debug then return end
  local now = clockBase + GetTime()
  local stamp = format("%s.%d", date("%H:%M:%S", math.floor(now)), math.floor(now * 10) % 10)
  if ns.DebugWindow and ns.DebugWindow.Add(format("|cff888888%s|r " .. msg, stamp, ...)) then return end
  ns.Print("|cff888888%s " .. msg .. "|r", stamp, ...)
end

-- /sllcm share found's lines ("asked", "found locations from ...": one per answer, dozens at a time) are a dev
-- tool's: in the debug window when it's on, whether or not debug is; in chat otherwise.
local function FoundPrint(msg, ...)
  if ns.DebugWindow and ns.DebugWindow.Add(format(msg, ...)) then return end
  ns.Print(msg, ...)
end

local function Enabled()
  local db = ns.GetDB()
  return db and db.crowd
end

local function FactionTag()
  return ns.Faction().key == "LeyLines" and "A" or "H"
end

-- Overflow channels (overflow-channels branch, 21 Nov 2026): a channel the server greys out for us (full, it seems:
-- a fresh one joined beside it is fine) sends us on to the next, SLLCMShareA, then SLLCMShareA2 ... SLLCMShareA<SLOTS>.
-- Each login starts at the first. Players in different ones don't hear each other.
local SLOTS = 4
local slot = 1

local function SlotName(n)
  return CHANNEL_BASE .. FactionTag() .. (n > 1 and n or "")
end

local function ChannelName()
  return SlotName(slot)
end

-- which of our channels a channel name is, or nil
local function SlotOf(name)
  if type(name) ~= "string" then return nil end
  name = name:lower()
  for n = 1, SLOTS do
    if name == SlotName(n):lower() then return n end
  end
end

-- nil for secret values (encounters, combat) and failed reads
local function Clean(v)
  if issecretvalue then
    local ok, secret = pcall(issecretvalue, v)
    if not ok or secret then return nil end
  end
  return v
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local function ChannelIndex()
  local id = GetChannelName(ChannelName())
  return type(id) == "number" and id > 0 and id or nil
end

-- A chat channel call with its errors caught. securecall keeps an error or taint inside fn from spreading back to
-- us; fn itself still runs as our (tainted) code, so it doesn't make the call secure. True if it ran.
local function ChatCall(fn, ...)
  if type(fn) ~= "function" then return false end
  if type(securecall) == "function" then return (pcall(securecall, fn, ...)) end
  return (pcall(fn, ...))
end

-- Forever greys custom channels out (GetChannelList's third value): still listed and numbered, but the server
-- refuses everything on it. Sends answer InvalidChannel, /leave NOT_ALLOWED_IN_CHANNEL, /chatwho INVALID_NAME, and
-- a relog brings it back as it was. Seen on 11 Nov 2026 on SLLCMShareA (Normal) while War Effort's channel and a
-- freshly joined one were fine there: it's the channel, not custom channels as a whole. /chatwho cleared it: the
-- server answered INVALID_NAME, the client dropped the channel, and a fresh join carried again.
local function GreyedOut(name)
  local list = { pcall(GetChannelList) }
  if not list[1] then return false end
  name = (name or ChannelName()):lower()
  for i = 2, #list, 3 do
    local n = Clean(list[i + 1])
    if type(n) == "string" and n:lower() == name then return Clean(list[i + 2]) == true end
  end
  return false
end

local Join -- (below, with the channel)

-- Revive the channel: /chatwho it, which on a greyed-out one answers INVALID_NAME and the client drops it, then join
-- fresh. (/leave on a greyed-out channel is refused, NOT_ALLOWED_IN_CHANNEL, so leaving alone never cleared it.)
-- Still listed after that: leave it and join again. Rate-limited (quick, then every FRESHEN_GAP up to FRESHEN_MAX,
-- then every FRESHEN_SLOW_GAP); true if it went out.
-- Greyed out: on to the next overflow channel at once, and from the last back to the first at the revive pace.
-- The greyed one is /chatwho'd so the client drops it (it can't be left), and we join the next straight away.
local function MoveTo(n, why)
  local old = ChannelName()
  slot = n
  Debug("channel %s %s, moving to %s", old, why, ChannelName())
  whoUntil = GetTime() + WHO_WAIT + 2
  ChatCall(ListChannelByName, old)
  lastJoinAt = nil
  Join()
  return true
end

local function Freshen(why)
  if why == "greyed out" and slot < SLOTS then return MoveTo(slot + 1, why) end
  local now = GetTime()
  local gap = freshened < FRESHEN_QUICK and FRESHEN_QUICK_GAP or freshened < FRESHEN_MAX and FRESHEN_GAP
    or FRESHEN_SLOW_GAP
  if freshenedAt and now - freshenedAt < gap then
    Debug("channel %s, rejoin not allowed yet (%d done, next in %d s)", why, freshened,
      math.ceil(gap - (now - freshenedAt)))
    return false
  end
  freshened, freshenedAt = freshened + 1, now
  if why == "greyed out" and SLOTS > 1 then
    Debug("all %d channels tried (%d rounds this session), back to the first", SLOTS, freshened)
    return MoveTo(1, why)
  end
  freshening = true
  Debug("channel %s, asking the server about it (%d this session%s)", why, freshened,
    freshened > FRESHEN_MAX and ", slow retries" or "")
  whoUntil = now + WHO_WAIT + 2
  ChatCall(ListChannelByName, ChannelName())
  C_Timer.After(WHO_WAIT, function()
    freshening = nil
    if not Enabled() then return end
    if not ChannelIndex() then
      Debug("channel dropped by the client, joining fresh")
      Join()
    elseif GreyedOut() or why ~= "greyed out" then
      Debug("channel still listed, leaving and rejoining")
      ChatCall(LeaveChannelByName, ChannelName())
      C_Timer.After(FRESHEN_WAIT, function() Join(true) end)
    end
  end)
  return true
end

-- share debug: log how many are in our channel (a /chatwho, its answer kept out of chat; CHAT_MSG_CHANNEL_LIST
-- counts the names). Never on a greyed-out channel: there the /chatwho answers INVALID_NAME and the client drops
-- the channel, which is Freshen's to do. Looking for a member cap: do busy nights stop at the same count?
local function CountMembers(why)
  if not debug or freshening or not ChannelIndex() or GreyedOut() then return end
  local now = GetTime()
  countAt, counted, whoUntil = now, 0, now + WHO_WAIT + 2
  countNames, countParts = {}, 0
  ChatCall(ListChannelByName, ChannelName())
  C_Timer.After(WHO_WAIT, function()
    if not counted then return end
    local distinct = 0
    for _ in pairs(countNames) do distinct = distinct + 1 end
    Debug("channel %s: %s (%s)", ChannelName(), counted > 0
      and format("%d names, %d distinct, in %d part(s)", counted, distinct, countParts) or "no member list", why)
    counted = nil
  end)
end

-- the F or VQ we were asked to send didn't go out
local function FoundDropped(msg, why)
  local what = msg and (msg:sub(1, 2) == "F:" and "found" or msg:sub(1, 3) == "VQ:" and "vouch")
  if what then
    FoundPrint("%s: not sent (%s); try /sllcm share %s again once sharing works", what, why, what)
  end
end

local function Paused()
  return pausedUntil and GetTime() < pausedUntil
end

-- Our own R's that a pause stopped (sent unheard before the refusal, queued, or sent while paused): the newest
-- MAX_HELD go out once the channel carries again, so a sighting during a pause isn't lost. Receivers keep one up to
-- MAX_AGE old; older ones are dropped here.
local MAX_HELD = 5
local held, unheard = {}, {} -- unheard: our R's sent since the channel was last heard
local function Hold(msg)
  if msg:sub(1, 2) ~= "R:" then return end
  for _, m in ipairs(held) do
    if m == msg then return end
  end
  if #held >= MAX_HELD then table.remove(held, 1) end
  held[#held + 1] = msg
end

-- a VQ went out or was heard: answers are taken for VOUCH_WINDOW (a fresh window forgets who answered)
local function OpenVouchWindow()
  local now = GetTime()
  if not (vouchOpenAt and now - vouchOpenAt < VOUCH_WINDOW) then wipe(vouchFrom) end
  vouchOpenAt = now
end

-- Forever's servers refuse addon messages on custom channels (since launch, 4 Nov 2026; QuestTogether, ForeverLFG
-- and War Effort see it too): a send returns Success, then NOT_ALLOWED_IN_CHANNEL comes, and no echo. Nothing we do
-- client side changes that, so we stop sending for PAUSE_SECONDS and the next message after is the probe. Only a
-- message heard on the channel (our echo or anyone's) proves it carries again; a Success return proves nothing.
local function Refused(why)
  awaitingEcho = nil
  pausedUntil = GetTime() + PAUSE_SECONDS
  Debug("channel refused (%s), pausing %d s, dropping %d queued", why, PAUSE_SECONDS, #queue)
  for _, msg in ipairs(unheard) do Hold(msg) end
  wipe(unheard)
  for _, msg in ipairs(queue) do
    FoundDropped(msg, "sharing paused")
    Hold(msg)
  end
  wipe(queue)
  -- the unasked L not all through (still waiting, queued, or sent without an echo): send it again once heard
  if announceOpen then
    announceOpen, announceSending, announceOut, announcing = nil, nil, 0, true
    announceGen = announceGen + 1
    Debug("unasked found locations not through, due again once the channel is heard")
  end
  if not pauseWarned then
    pauseWarned = true
    ns.Print("sharing is paused: WoW: Forever's servers are refusing addon messages on the sharing channel right now "
      .. "(a server restriction, not this addon). It keeps checking on its own.")
  end
end

local Announce -- (below, with the F / L handling)
local SendHeld -- (below, after Send)

-- Something came in on the channel: it carries.
local function Heard()
  awaitingEcho, pausedUntil = nil, nil
  wipe(unheard)
  SendHeld()
  if announcing == true then Announce() end
  if not (countAt and GetTime() - countAt < COUNT_GAP) then CountMembers("channel carries") end
  if pauseWarned then
    pauseWarned = nil
    ns.Print("sharing is working again.")
  end
end

local RESULT = Enum.SendAddonMessageResult or {}
local SUCCESS = RESULT.Success or 0
local INVALID_CHANNEL = RESULT.InvalidChannel or 7
local THROTTLED = { [RESULT.AddonMessageThrottle or 3] = true, [RESULT.ChannelThrottle or 8] = true }

local function Drain()
  local msg = queue[1]
  local id = ChannelIndex()
  if not msg or not id then
    sending = false
    return
  end
  local ok, r = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "CHANNEL", id)
  -- older clients return a boolean, newer ones Enum.SendAddonMessageResult
  if ok and (r == nil or r == true or r == SUCCESS) then
    table.remove(queue, 1)
    channelRetries = 0
    Debug(">> %s %s", ChannelName():sub(#CHANNEL_BASE + 1), msg)
    if msg:sub(1, 2) == "R:" then
      if #unheard >= MAX_HELD then table.remove(unheard, 1) end
      unheard[#unheard + 1] = msg
    end
    if msg:sub(1, 2) == "F:" then FoundPrint("found: asked; answers come in over the next 15 s or so") end
    if msg:sub(1, 3) == "VQ:" then
      OpenVouchWindow()
      FoundPrint("vouch: asked; answers come in over the next 15 s or so")
    end
    -- taken, not delivered: wait for the echo
    if not awaitingEcho then
      local sentAt = GetTime()
      awaitingEcho = sentAt
      C_Timer.After(ECHO_SECONDS, function()
        if awaitingEcho == sentAt then Refused("no echo") end
      end)
    end
    C_Timer.After(SEND_GAP, Drain)
  elseif ok and THROTTLED[r] then
    Debug("throttled, pausing")
    C_Timer.After(THROTTLE_PAUSE, Drain)
  elseif ok and r == INVALID_CHANNEL and channelRetries < CHANNEL_RETRIES then
    channelRetries = channelRetries + 1
    Debug("channel not ready (retry %d): %s", channelRetries, msg)
    C_Timer.After(THROTTLE_PAUSE, Drain)
  elseif ok and r == INVALID_CHANNEL and Freshen(GreyedOut() and "greyed out" or "refused") then
    -- the client still lists the channel, so joining again does nothing: revive it, then try this one again
    channelRetries = 0
    C_Timer.After(WHO_WAIT + FRESHEN_WAIT + THROTTLE_PAUSE, Drain)
  elseif ok and r == INVALID_CHANNEL then
    -- still invalid after rejoining
    channelRetries, sending = 0, false
    Refused("invalid channel")
  else
    table.remove(queue, 1)
    channelRetries = 0
    Debug("send failed (%s): %s", tostring(r), msg)
    FoundDropped(msg, "send failed")
    C_Timer.After(SEND_GAP, Drain)
  end
end

local function Send(msg)
  if not Enabled() then return end
  if Paused() then
    Hold(msg)
    return
  end
  if #held > 0 then SendHeld() end -- the pause ran out with nothing heard: held ones go first
  queue[#queue + 1] = msg
  if not sending then
    sending = true
    Drain()
  end
end

SendHeld = function()
  if #held == 0 or not Enabled() or Paused() then return end
  local msgs, now = held, GetServerTime()
  held = {}
  for _, msg in ipairs(msgs) do
    local t = tonumber(msg:match(":(%d+)$"))
    if t and now - t < MAX_AGE - 60 then Send(msg) end
  end
end

---------------------------------------------------------------------------
-- Sightings
---------------------------------------------------------------------------

-- Sightings belong on zone maps. Another addon on the channel has been seen sending continent coordinates
-- (Kalimdor, 1414): move those to the zone at that spot. nil if there's no zone there.
local function OnZoneMap(mapID, x, y)
  local info = C_Map.GetMapInfo(mapID)
  if not info then return end
  if info.mapType ~= Enum.UIMapType.Continent then return mapID, x, y end
  local zone = C_Map.GetMapInfoAtPosition(mapID, x, y)
  if not (zone and zone.mapType == Enum.UIMapType.Zone) then return end
  local continent, world = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(x, y))
  if not world then return end
  local _, pos = C_Map.GetMapPosFromWorldPos(continent, world, zone.mapID)
  if pos then return zone.mapID, pos.x, pos.y end
end

-- A heard position on a zone map, fresh enough to keep; nil if not
local function Valid(mapID, x, y, t)
  local now = GetServerTime()
  if not (x >= 0 and x <= 1 and y >= 0 and y <= 1) then return end
  mapID, x, y = OnZoneMap(mapID, x, y)
  if not (mapID and x >= 0 and x <= 1 and y >= 0 and y <= 1) then return end
  if t > now + 60 or now - t > MAX_AGE then return end
  return mapID, x, y
end

-- New locations learned from one sender in a session, at most: a buggy or hostile client can't fill everyone's
-- map. Honest senders stay far below it (an unasked L is its own finds Data.lua lacks).
local MAX_LEARN_PER_SENDER = 100
local learnedFrom = {}
local function Learn(mapID, x, y, sender)
  local n = sender and learnedFrom[sender] or 0
  if n >= MAX_LEARN_PER_SENDER then return end
  local new = ns.LearnShared(mapID, x, y)
  if new and sender then
    learnedFrom[sender] = n + 1
    if n + 1 == MAX_LEARN_PER_SENDER then
      Debug("%s: %d new locations this session, no more learned from them", sender, MAX_LEARN_PER_SENDER)
    end
  end
  return new
end

-- A sighting, ours or heard (sender: who from): stamped last seen, and its location learned if new
local function Add(mapID, x, y, t, mine, sender)
  mapID, x, y = Valid(mapID, x, y, t)
  if not mapID then return end
  if ns.Watch then ns.Watch(mapID, x, y, t, mine) end -- dev copy only
  ns.StampSeen(mapID, x, y, t)
  if Learn(mapID, x, y, sender) and WorldMapFrame:IsShown() and WorldMapFrame:GetMapID() == mapID then
    ns.Provider:RefreshAllData()
  end
end

-- Our own sighting: kept whether sharing is on or not (Send does nothing while it's off)
function ns.OnConfirmed(mapID, x, y, t)
  Add(mapID, x, y, t, true)
  Send(format("R:%s:%s:%s:%d:%d:%d:%d", VERSION, FactionTag(), NO_PHASE, mapID,
    math.floor(x * 10000 + 0.5), math.floor(y * 10000 + 0.5), t))
end

-- A node seen some way other than the racial: its minimap blip (Scan.lua, LeyLineTest hovers). Skipped when
-- anyone's sighting stamped it in the last gap seconds (default REPEAT_GAP), so passing the same blip doesn't flood.
local REPEAT_GAP = 5 * 60
function SLLCM_ReportSighting(mapID, x, y, gap)
  local now = GetServerTime()
  local last = ns.LastSeen(mapID, x, y)
  if last and now - last < (gap or REPEAT_GAP) then return end
  ns.OnConfirmed(mapID, x, y, now)
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

-- in an L heard while ours waited, or a part of ours already sent: covered = { mapID, x, y, ... }
local function Covered(covered, mapID, x, y)
  for i = 1, #covered, 3 do
    if covered[i] == mapID and ns.Near(mapID, covered[i + 1], covered[i + 2], x, y) then return true end
  end
end

local function Cover(covered, mapID, x, y)
  local n = #covered
  covered[n + 1], covered[n + 2], covered[n + 3] = mapID, x, y
end

-- Up to MAX_FOUND_PER_REPLY of our locations that aren't in Data.lua and that no L heard so far (covered) had,
-- self-found first, then (withShared) ones learned from others; each one taken goes on covered too
local function FoundPart(covered, withShared)
  local key, db = ns.Faction().key, ns.GetDB()
  local entries = {}
  for _, source in ipairs(withShared and { db.found[key], db.shared[key] } or { db.found[key] }) do
    for foundMap, list in pairs(source) do
      for _, p in ipairs(list) do
        if #entries >= MAX_FOUND_PER_REPLY then return entries end
        -- some spots record on the continent map: compare and send on the zone, as the answers we heard were
        local mapID, x, y = OnZoneMap(foundMap, p[1], p[2])
        local known = not mapID or Covered(covered, mapID, x, y) or ns.IsRetired(key, mapID, x, y)
        for _, d in ipairs(mapID and SLLCM_Data[key][mapID] or {}) do
          known = known or ns.Near(mapID, d[1], d[2], x, y)
        end
        if not known then
          entries[#entries + 1] = format("%d,%d,%d", mapID,
            math.floor(x * 10000 + 0.5), math.floor(y * 10000 + 0.5))
          Cover(covered, mapID, x, y)
        end
      end
    end
  end
  return entries
end

-- One L at a time, each built just before it goes: what other L's had by then is left out,
-- so clients holding the same shared locations don't all send every one. covered stays in foundCovers, learning
-- what L's come in, until we're done. why: for debug.
-- db.foundSentAt is stamped when an L of ours echoes back (see CHAT_MSG_ADDON), not when it's sent: a refused one
-- doesn't hold the next login's back. check: asked before each part, false stops it. announce: the unasked L.
local foundCovers = {}
local function SendFound(covered, why, withShared, check, announce, sent)
  sent = sent or 0
  if check and not check() then foundCovers[covered] = nil return end
  local entries = Enabled() and not Paused() and FoundPart(covered, withShared) or {}
  if #entries == 0 then
    foundCovers[covered] = nil
    Debug("%s: %d location(s) sent", why, sent)
    if announce then
      announceSending = nil
      -- paused or off: left open, so the refusal that paused it re-arms it
      if announceOut == 0 and Enabled() and not Paused() then announceOpen = nil end
    end
    return
  end
  if announce then announceOut = announceOut + 1 end
  Send(format("L:%s:%s:%s", VERSION, FactionTag(), table.concat(entries, ";")))
  C_Timer.After(SEND_GAP, function() SendFound(covered, why, withShared, check, announce, sent + #entries) end)
end

local function StartFound(wait, why, withShared, check, announce)
  local covered = {}
  foundCovers[covered] = true
  C_Timer.After(wait, function() SendFound(covered, why, withShared, check, announce) end)
end

-- The unasked L, self-found only: due at login (see PLAYER_LOGIN), sent ANNOUNCE_DELAY+ after the channel is first
-- heard. Left out if an F was answered by then: that sent the same and more. Due again if refused before it's all
-- echoed back (see Refused).
Announce = function()
  announcing = nil
  announceGen = announceGen + 1
  local gen = announceGen
  announceOpen, announceSending, announceOut = true, true, 0
  local wait = ANNOUNCE_DELAY + math.random() * ANNOUNCE_SPREAD
  Debug("unasked found locations due in %d s", math.floor(wait))
  StartFound(wait, "unasked found locations", false, function()
    if gen ~= announceGen then return false end -- re-armed meanwhile: a later run sends it
    if foundAnswered then
      Debug("unasked found locations not sent: an F answer this session sent them")
      announceOpen, announceSending = nil, nil
      return false
    end
    return true
  end, true)
end

-- An L of ours came back: it went out
local function FoundEchoed()
  ns.GetDB().foundSentAt = GetServerTime()
  if announceOpen and announceOut > 0 then
    announceOut = announceOut - 1
    if announceOut == 0 and not announceSending then
      announceOpen = nil
      Debug("unasked found locations: all echoed back")
    end
  end
end

-- Our vouches, every zone we have any, packed into as few V's as fit. Nothing is left out for others' V's:
-- each answerer's verdict is its own evidence.
local VOUCH_ROOM = 240 - #"V:1:A:"
local function SendVouches()
  if not (Enabled() and not Paused()) then return end
  local parts, n = {}, 0
  local function Flush()
    if #parts == 0 then return end
    Send(format("V:%s:%s:%s", VERSION, FactionTag(), table.concat(parts, ";")))
    parts, n = {}, 0
  end
  local entries = ns.VouchEntries()
  for _, e in ipairs(entries) do
    if n + #e + 1 > VOUCH_ROOM then Flush() end
    parts[#parts + 1], n = e, n + #e + 1
  end
  Flush()
  Debug("answering VQ: vouches for %d zone(s)", #entries)
end

local function OnFoundMessage(kind, list, sender)
  if kind == "F" then
    -- self-found and shared locations: with many clients holding the same shared ones, the waits spread wider
    -- than an S answer's, so the first answers' L's are heard before most others start
    if foundAnswered then return end
    foundAnswered = true
    StartFound(4 + math.random() * FOUND_SPREAD, "answering F", true)
  elseif kind == "VQ" then
    OpenVouchWindow()
    if vouchAnswered then return end
    vouchAnswered = true
    C_Timer.After(4 + math.random() * FOUND_SPREAD, SendVouches)
  elseif kind == "V" and list then
    if not (vouchOpenAt and GetTime() - vouchOpenAt < VOUCH_WINDOW) then
      Debug("V from %s ignored: no VQ lately", sender)
      return
    end
    -- an answer can span several V's, each zone in one of them: a zone repeated by a sender is skipped
    local zones = vouchFrom[sender] or {}
    vouchFrom[sender] = zones
    local used, other, repeated = 0, 0, 0
    for entry in list:gmatch("[^;]+") do
      local zone = entry:match("^(%d+),")
      if zone and zones[zone] then
        repeated = repeated + 1
      else
        if zone then zones[zone] = true end
        local ok = ns.MergeVouch(entry)
        if ok then used = used + 1 elseif ok == false then other = other + 1 end
      end
    end
    if repeated > 0 then Debug("V from %s: %d zone(s) already answered, skipped", sender, repeated) end
    if vouchAsked then FoundPrint("vouches from %s: %d zone(s), %d skipped (other release)", sender, used, other) end
  elseif kind == "L" and list then
    local learned = 0
    for entry in list:gmatch("[^;]+") do
      local mapID, x, y = strsplit(",", entry)
      mapID, x, y = tonumber(mapID), tonumber(x), tonumber(y)
      if mapID and x and y and x >= 0 and x <= 10000 and y >= 0 and y <= 10000 then
        mapID, x, y = OnZoneMap(mapID, x / 10000, y / 10000)
        if mapID then
          if Learn(mapID, x, y, sender) then learned = learned + 1 end
          for covered in pairs(foundCovers) do Cover(covered, mapID, x, y) end
        end
      end
    end
    if foundAsked then FoundPrint("found locations from %s: %d new", sender, learned) end
    if learned > 0 and WorldMapFrame:IsShown() then ns.Provider:RefreshAllData() end
  end
end

-- debug only: which of our channels a message came in on, as its tail ("A", "H2"); "?" if unknown
local function ChannelTag(name)
  name = type(name) == "string" and name:match("^" .. CHANNEL_BASE .. "(.+)$")
  return name or "?"
end

-- debug only: senders of Q / XM / XS (ignored since 1.5.0), each logged once a session instead of every message
local oldSenders = {}

local function OnMessage(text, sender, chan)
  local kind, v, fac, p, rest = strsplit(":", text, 5)
  if kind == "Q" or kind == "XM" or kind == "XS" then
    if debug and not oldSenders[sender] then
      oldSenders[sender] = true
      Debug("<< %s %s: %s (old client; its Q / XM / XS no longer logged)", ChannelTag(chan), sender, text)
    end
    return
  end
  Debug("<< %s %s: %s", ChannelTag(chan), sender, text)
  if v ~= VERSION or fac ~= FactionTag() then return end
  if kind == "F" or kind == "L" or kind == "VQ" or kind == "V" then -- no phase field
    return OnFoundMessage(kind, p, sender)
  end
  -- R and S still carry a phase (ours NO_PHASE, older clients' their layer): read, then ignored
  if not (p and p:match("^%d+$")) or not rest then return end

  if kind == "R" then
    local mapID, x, y, t = strsplit(":", rest)
    mapID, x, y, t = tonumber(mapID), tonumber(x), tonumber(y), tonumber(t)
    if mapID and x and y and t then Add(mapID, x / 10000, y / 10000, t, nil, sender) end
  elseif kind == "S" then
    for entry in rest:gmatch("[^;]+") do
      local mapID, x, y, t = strsplit(",", entry)
      mapID, x, y, t = tonumber(mapID), tonumber(x), tonumber(y), tonumber(t)
      if mapID and x and y and t then Add(mapID, x / 10000, y / 10000, t, nil, sender) end
    end
  end
end

---------------------------------------------------------------------------
-- Channel
---------------------------------------------------------------------------

local function HideFromChat(name)
  name = name or ChannelName()
  for i = 1, NUM_CHAT_WINDOWS or 10 do
    local frame = _G["ChatFrame" .. i]
    if frame and frame.RemoveChannel then
      ChatCall(frame.RemoveChannel, frame, name)
    elseif frame and ChatFrame_RemoveChannel then
      ChatCall(ChatFrame_RemoveChannel, frame, name)
    end
  end
end

-- channel names shown in any chat window, lowercased
local function ShownChannels()
  local shown = {}
  if not GetChatWindowChannels then return shown end
  for i = 1, NUM_CHAT_WINDOWS or 10 do
    local list = { GetChatWindowChannels(i) } -- name, zone for each channel
    for j = 1, #list, 2 do
      if type(list[j]) == "string" then shown[list[j]:lower()] = true end
    end
  end
  return shown
end

-- the numbers of the channels people chat in, lowest first: the game's own (General, Trade, Services...)
-- and custom ones shown in a chat window. A custom channel shown nowhere is an addon's, as ours is: we
-- never move one, so an addon doing the same as us can't swap back and forth with ours.
local function ChatChannelNumbers()
  local out = {}
  if not (GetNumDisplayChannels and GetChannelDisplayInfo) then return out end
  local shown = ShownChannels()
  for i = 1, GetNumDisplayChannels() or 0 do
    local name, header, _, number, _, _, category = GetChannelDisplayInfo(i)
    local chat = category == "CHANNEL_CATEGORY_WORLD"
      or (category == "CHANNEL_CATEGORY_CUSTOM" and type(name) == "string" and shown[name:lower()])
    if not header and type(number) == "number" and number > 0 and chat then
      out[#out + 1] = number
    end
  end
  table.sort(out)
  return out
end

-- Move our channel past every chat channel numbered above it, one swap at a time, so General, Trade, a
-- player's own channels and the rest keep /1, /2, /3. A new channel takes the lowest free number, so
-- joining before they come in (a slow login, a rejoin racing them after a loading screen) takes /1. Each
-- swap moves ours up and a chat channel down, so it stops; the budget is for an addon that rearranges
-- channels itself, or one that leaves its own channel showing in chat.
local function KeepChannelLast()
  local swap = C_ChatInfo and C_ChatInfo.SwapChatChannelsByChannelIndex
  local ours = ChannelIndex()
  if not swap or not ours then return end
  for _, n in ipairs(ChatChannelNumbers()) do
    if n > ours then
      if swapsLeft <= 0 or not ChatCall(swap, ours, n) then return end
      swapsLeft = swapsLeft - 1
      ours = n
    end
  end
end

-- force: join even though the client lists the channel (just left, the client may not have caught up)
Join = function(force)
  if not Enabled() or Clean(IsInInstance()) then return end
  if ChannelIndex() and not force then
    if GreyedOut() then Freshen("greyed out") end
    return
  end
  local now = GetTime()
  if lastJoinAt and now - lastJoinAt < JOIN_GAP then return end
  local why = force and "rejoin" or nil
  if not force then
    -- GetChannelName has missed a channel we were on and hearing (11 Nov, 60 s ticker): trust the channel list
    local list, name = { pcall(GetChannelList) }, ChannelName():lower()
    local names = {}
    for i = 2, #list, 3 do
      local n = Clean(list[i + 1])
      if type(n) == "string" and n:lower() == name then
        Debug("not joining: GetChannelName gave %s, but the channel list has it as %s",
          tostring(Clean(GetChannelName(ChannelName()))), tostring(Clean(list[i])))
        return
      end
      names[#names + 1] = tostring(Clean(list[i])) .. "." .. tostring(n)
    end
    -- the 11 Nov joins while we were hearing the channel: what the client showed then
    why = format("GetChannelName gave %s; list: %s%s", tostring(Clean(GetChannelName(ChannelName()))),
      #names > 0 and table.concat(names, " ") or "empty", list[1] and "" or " (GetChannelList failed)")
  end
  lastJoinAt = now
  reorderUntil, swapsLeft = now + REORDER_SECONDS, MAX_SWAPS
  ChatCall(JoinTemporaryChannel, ChannelName())
  Debug("joining %s (%s)", ChannelName(), why)
  -- the chat frames pick the channel up a moment after joining
  C_Timer.After(1, HideFromChat)
  -- by then a join the server turned away shows greyed out: on to the next channel
  local joined = slot
  C_Timer.After(5, function()
    HideFromChat()
    if Enabled() and slot == joined and not freshening and ChannelIndex() and GreyedOut() then
      Freshen("greyed out")
    end
  end)
end

-- The server's word on our channel, hidden from chat with the channel. NOT_ALLOWED_IN_CHANNEL is the server
-- refusing a message we sent (see Refused): rejoining doesn't help. The rest mean we may be out of it, or in a
-- greyed-out one: look again a moment later and rejoin, or leave and rejoin. (Leaving it ourselves sends YOU_LEFT
-- too: with sharing off, or the Freshen join already sent, nothing more happens.)
local RECHECK_NOTICES = { YOU_LEFT = true, INVALID_NAME = true, SUSPENDED = true, NOT_MEMBER = true }
local recheckPending
local function OnChannelNotice(notice)
  Debug("channel notice: %s", tostring(notice))
  if notice == "NOT_ALLOWED_IN_CHANNEL" and Enabled() then
    if not Paused() then Refused(notice) end
    return
  end
  if not RECHECK_NOTICES[notice] or recheckPending or not Enabled() then return end
  recheckPending = true
  C_Timer.After(RECHECK_SECONDS, function()
    recheckPending = nil
    if not Enabled() then return end
    if not ChannelIndex() then
      Join()
    elseif GreyedOut() and not freshening then -- a revive under way looks again itself
      Freshen("greyed out")
    end
  end)
end

-- At login, wait for the game's own channels (General, Trade...) to come in first: a new channel takes
-- the lowest free number, and taking /1 would send a player's "/1 hello" into ours.
local function Count(ok, ...)
  return ok and select("#", ...) or 0
end

-- Dev copy: in every overflow channel at once, so share found / vouch reach the whole faction. Ours (slot) is run
-- as everyone's is; the others are joined beside it, and each greyed-out one is /chatwho'd (the client drops it) and
-- joined again every DEV_SWEEP until the server lets us in. Players never go past SLOTS, so these are all there are.
local DEV = ADDON:find("%-Dev$") ~= nil
local DEV_SWEEP = 120

-- the channel numbers of our other overflow channels we're properly in (listed, not greyed out)
local function DevOthers()
  local out = {}
  if not DEV then return out end
  for n = 1, SLOTS do
    if n ~= slot then
      local id = Clean(GetChannelName(SlotName(n)))
      if type(id) == "number" and id > 0 and not GreyedOut(SlotName(n)) then out[SlotName(n)] = id end
    end
  end
  return out
end

local function DevSweep()
  if not (DEV and Enabled()) or Clean(IsInInstance()) then return end
  for n = 1, SLOTS do
    local name = SlotName(n)
    if n ~= slot then
      local id = Clean(GetChannelName(name))
      if not (type(id) == "number" and id > 0) then
        Debug("dev: joining %s too", name)
        ChatCall(JoinTemporaryChannel, name)
        C_Timer.After(1, function() HideFromChat(name) end)
        C_Timer.After(5, function() HideFromChat(name) end)
      elseif GreyedOut(name) then
        Debug("dev: %s greyed out, dropping it and trying again", name)
        whoUntil = GetTime() + WHO_WAIT + 2
        ChatCall(ListChannelByName, name)
        C_Timer.After(FRESHEN_WAIT, function()
          if Enabled() and slot ~= n and Clean(GetChannelName(name)) == 0 then
            ChatCall(JoinTemporaryChannel, name)
            C_Timer.After(1, function() HideFromChat(name) end)
            C_Timer.After(5, function() HideFromChat(name) end)
          end
        end)
      end
    end
  end
end

local function JoinWhenSettled()
  local start, changedAt, last = GetTime(), GetTime(), -1
  local ticker
  ticker = C_Timer.NewTicker(1, function()
    local now, count = GetTime(), Count(pcall(GetChannelList))
    if count ~= last then last, changedAt = count, now end
    -- quiet for a moment once the first channel is in: an empty list for a few seconds is the login
    if (count > 0 and now - changedAt >= 3) or now - start >= 30 then
      ticker:Cancel()
      -- after a /reload we may still be in one of our channels: carry on in the lowest that isn't greyed out
      -- (a fresh login has none, and starts at the first)
      local list, best = { pcall(GetChannelList) }, nil
      for i = 2, #list, 3 do
        local n = SlotOf(Clean(list[i + 1]))
        if n and Clean(list[i + 2]) ~= true and (not best or n < best) then best = n end
      end
      slot = best or 1
      if best and best > 1 then Debug("still in %s from before the reload, staying", ChannelName()) end
      -- still on it from before a /reload, perhaps as /1; with sharing off the channel is left alone
      if Enabled() then
        swapsLeft = MAX_SWAPS
        KeepChannelLast()
      end
      Join()
      -- rejoin if kicked, /left by the player or lost to a client hiccup
      -- (not NewTicker(60, Join): the ticker is passed in, and Join takes it as force)
      C_Timer.NewTicker(60, function() Join() end)
      if DEV then
        C_Timer.After(10, DevSweep) -- once ours has settled where it's going
        C_Timer.NewTicker(DEV_SWEEP, function() DevSweep() end)
      end
    end
  end)
end

function ns.SetCrowdEnabled(on)
  -- a fresh start either way: turning sharing back on is how a player says "try again now" (and still hears
  -- "working again" if it was paused)
  pausedUntil, awaitingEcho, freshened, freshenedAt, freshening, lastJoinAt = nil, nil, 0, nil, nil, nil
  if not on then
    pauseWarned = nil
    wipe(held)
    wipe(unheard)
  end
  if on then
    if not ChannelIndex() then slot = 1 end -- not in one: start again from the first
    Join()
  else
    if ChannelIndex() then ChatCall(LeaveChannelByName, ChannelName()) end
    for name in pairs(DevOthers()) do ChatCall(LeaveChannelByName, name) end -- dev copy's others
  end
  ns.Provider:RefreshAllData()
end

-- Dev requests (Watch.lua's /sllcm share found | vouch): F asks for locations Data.lua lacks, VQ for vouches.
-- "asked" is said when it actually goes out (Drain), "not sent" if it's dropped.
function ns.Ask(kind)
  local what = kind == "F" and "found" or "vouch"
  local others = DevOthers() -- dev copy: our other overflow channels, asked straight away
  if not (Enabled() and (ChannelIndex() or next(others))) then
    FoundPrint("%s: sharing is off or the channel isn't joined", what)
  elseif kind == "F" and ns.GetDB().selfOnly then
    FoundPrint("found: \"show only self-found\" is on, so answers wouldn't be learned")
  elseif (Paused() or not ChannelIndex()) and not next(others) then
    FoundPrint("%s: not sent, sharing is paused (the server is refusing the channel); it keeps checking on its own", what)
  else
    if kind == "F" then foundAsked = true else vouchAsked = true end
    local msg = format("%s:%s:%s", kind, VERSION, FactionTag())
    for name, id in pairs(others) do
      local ok, r = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "CHANNEL", id)
      FoundPrint("%s: asked in %s (%s)", what, name, ok and tostring(r) or "error")
      if kind == "VQ" then OpenVouchWindow() end
    end
    if ChannelIndex() and not Paused() then
      Send(msg)
      if #queue > 0 then FoundPrint("%s: asking in %s...", what, ChannelName()) end
    else
      FoundPrint("%s: not asked in %s (%s)", what, ChannelName(), ChannelIndex() and "paused" or "not joined")
    end
  end
end

-- For Watch.lua's /sllcm share test: a fake sighting, through our own path without touching the channel
-- (receive false) or through the message parser as if another player sent it. Returns the message.
function ns.TestSighting(receive, mapID, x, y)
  local msg = format("R:%s:%s:%s:%d:%d:%d:%d", VERSION, FactionTag(), NO_PHASE, mapID,
    math.floor(x * 10000 + 0.5), math.floor(y * 10000 + 0.5), GetServerTime())
  if receive then OnMessage(msg, "Tester") else Add(mapID, x, y, GetServerTime(), true) end
  return msg
end

-- Shared locations of this faction, forgotten
function ns.TestClear()
  ns.GetDB().shared[ns.Faction().key] = {}
  ns.Provider:RefreshAllData()
end

function ns.ShareCommand(arg)
  if ns.DevShareCommand and ns.DevShareCommand(arg) then return end -- dev copy: found, vouch, test
  if arg == "debug" then
    debug = not debug
    ns.GetDB().shareDebug = debug
    ns.Print("share debug %s", debug and "on" or "off")
    if debug then CountMembers("debug turned on") end
    return
  elseif arg == "debug window" then
    if ns.DebugWindow then ns.DebugWindow.Toggle() else ns.Print("debug window: only in the dev copy") end
    return
  elseif arg == "reset" then
    -- back to a first-run state: sharing off, and the popup asks again on the next /reload
    local db = ns.GetDB()
    db.crowdAsked, db.crowd = nil, false
    ns.SetCrowdEnabled(false)
    ns.Print("sharing reset: off, and you'll be asked again after /reload")
    return
  end
  ns.Print("sharing %s, channel %s %s%s, %d queued",
    Enabled() and "on" or "off", ChannelName(), tostring(ChannelIndex() or "not joined"),
    (GreyedOut() and " (greyed out)" or "") .. (Paused() and " (paused: server refusing)" or ""), #queue)
  ns.Print("/sllcm share debug - print messages sent and received; /sllcm share reset - ask again")
  if ns.DevShareCommand then ns.DevShareCommand("help") end
end

-- Freshen's /chatwho is ours, not the player's: keep its answer about our channel (the member list, or the
-- "invalid channel name" notice) out of chat for a few seconds after it goes out. A /chatwho of their own later shows.
local function OursToHide(_, _, ...)
  if not (whoUntil and GetTime() < whoUntil) then return false end
  local base = Clean(select(9, ...))
  return SlotOf(base) ~= nil -- any of ours: a move /chatwho's the one it leaves behind
end
if ChatFrame_AddMessageEventFilter then
  ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_LIST", OursToHide)
  ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE_USER", OursToHide)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("CHANNEL_UI_UPDATE")
events:RegisterEvent("CHAT_MSG_CHANNEL_LIST")
events:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
events:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE_USER")
events:SetScript("OnEvent", function(_, event, ...)
  if event == "CHAT_MSG_ADDON" then
    local prefix, text, kind, sender, target, _, localID, chanName = ...
    prefix, text, kind, sender = Clean(prefix), Clean(text), Clean(kind), Clean(sender)
    -- the channel's name, for the debug line: the event's name field, else the target, else its local number
    local chan = Clean(chanName)
    if type(chan) ~= "string" or chan == "" then chan = Clean(target) end
    if (type(chan) ~= "string" or chan == "") and type(Clean(localID)) == "number" then
      chan = select(2, GetChannelName(localID))
    end
    if prefix ~= PREFIX or type(text) ~= "string" or type(sender) ~= "string" or not Enabled() then return end
    if kind == "CHANNEL" then Heard() end -- ours back or anyone's: the channel carries
    sender = Ambiguate(sender, "none")
    -- the server echoes our own back
    if not me[sender] then OnMessage(text, sender, chan)
    elseif kind == "CHANNEL" and text:sub(1, 2) == "L:" then FoundEchoed() end
  elseif event == "CHAT_MSG_CHANNEL_LIST" then -- a /chatwho answer: names, comma separated, maybe in parts
    local text, _, _, _, _, _, _, _, baseName = ...
    text, baseName = Clean(text), Clean(baseName)
    if counted and type(text) == "string" and type(baseName) == "string"
      and baseName:lower() == ChannelName():lower() then
      countParts = countParts + 1
      for name in text:gmatch("[^,]+") do
        counted = counted + 1
        countNames[strtrim(name)] = true
      end
    end
  elseif event == "CHANNEL_UI_UPDATE" then -- a channel joined or left (our own swaps fire it too)
    if reorderUntil and GetTime() < reorderUntil then KeepChannelLast() end
  elseif event == "CHAT_MSG_CHANNEL_NOTICE" or event == "CHAT_MSG_CHANNEL_NOTICE_USER" then
    local notice, _, _, _, _, _, _, _, baseName = ...
    notice, baseName = Clean(notice), Clean(baseName)
    if type(baseName) == "string" and baseName:lower() == ChannelName():lower() then OnChannelNotice(notice) end
  elseif event == "PLAYER_LOGIN" then
    local db = ns.GetDB()
    -- debug output remembers its setting; on by default in the dev copy (loaded as "...-Dev")
    if db.shareDebug == nil then db.shareDebug = ADDON:find("%-Dev$") ~= nil end
    debug = db.shareDebug
    if ns.DebugWindow then ns.DebugWindow.Restore() end
    -- per-phase sightings, "not there"s, Q times and the saved phase from before phases went (1.5.0)
    db.crowdReports, db.crowdGone, db.crowdQueried, db.crowdPhase = nil, nil, nil, nil
    -- on Forever, UnitName gives first name and surname apart, and senders show as "First Surname"
    local name, surname = UnitName("player")
    me[name] = true
    if surname and surname ~= "" then me[name .. " " .. surname] = true end
    -- our self-found locations go out unasked once the channel is heard, unless they went out lately
    if not (db.foundSentAt and GetServerTime() - db.foundSentAt < ANNOUNCE_GAP) then announcing = true end
    JoinWhenSettled()
  end
end)

C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
