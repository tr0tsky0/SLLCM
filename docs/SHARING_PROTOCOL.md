# Leyline sharing protocol (version "1")

The contract between Skyborne Ley Line & Convergence Marker (SLLCM) and Mapzeroth (`LeyShare.lua`).
Both must stay wire-compatible. SLLCM's `SkyborneLeyLineConvergenceMarker/Comm.lua` is the reference
implementation; racial detection is `OnRacialCast` / `HasNodeBuff` in `SkyborneLeyLineConvergenceMarker.lua`.

## No phases (SLLCM 1.5.0+)
WoW: Forever's 1.60.1 hotfix obfuscates creature GUIDs (realm, server and spawn IDs), the same as Retail. Phase
matching between players needed the layer field to read the same for everyone on a layer, which is exactly what
the change is meant to stop (layer-hopping by invite), so it's gone. SLLCM 1.5.0 reads no GUIDs:
- A sighting is "this node location is real, seen at t": it teaches the location and stamps it last seen (for
  spotting bad locations, vouches and the pin tooltip's "Last seen ... ago"). No green-to-red colouring.
- R keeps its phase field, sent as `0`, so older clients still parse it. They store it under a phase they're never
  in, so it never colours their map, but they still learn the location and stamp it.
- Older clients' R and S are read the same way, whatever phase they carry. Q, XM and XS are ignored.
- No Q is sent and none is answered. Locations from before joining come through L (unasked at login, or an F).
- `crowdReports`, `crowdGone`, `crowdQueried` and `crowdPhase` are cleared from SkyborneMarkerDB at login.

## Channel and messages
- Prefix `SLLCM`. Channel `SLLCMShareA` (Alliance) / `SLLCMShareH` (Horde), joined with JoinTemporaryChannel.
- Fields are `:`-separated, with no pipes. x/y are integers 0-9999 (map coords x 10000). t = GetServerTime()
  when the node was seen. phase = digits only (`0` from 1.5.0). fac = `A` or `H`.
  - `R:1:fac:phase:mapID:x:y:t`: one sighting
  - `Q:1:fac:phase`: before 1.5.0, "what do you have for this phase?" Ignored now.
  - `S:1:fac:phase:mapID,x,y,t;mapID,x,y,t;...`: before 1.5.0, the reply to Q. Still read, never sent.
- Receivers ignore a sighting older than 90 minutes (older clients' S replies hold that long) and any t more than
  60 s in the future.
- Two sightings within 70 yd on the same map are the same node. SLLCM 1.4.0+; was 60 yd, raised because the racial
  works from up to about 30 yd, so two casts at one node can be 60 yd apart. Mapzeroth should follow.
- mapID should be a zone map. Receivers convert continent-map positions (Skyborne Compass was seen using Kalimdor,
  1414, in Oct 2026) to the zone at that spot (`C_Map.GetMapInfoAtPosition`, then world position to zone position)
  and drop them if no zone is there.
- Last-seen stamps are kept per faction (`SkyborneMarkerDB.seen[dataKey]`), so an alt of the other faction never
  uses them.

## Locations and vouches (F / L, VQ / V)
SLLCM only; Mapzeroth can ignore all four. No phase field (receivers that need one, Mapzeroth and older SLLCM,
drop these at their digits-only phase check).
- `F:1:fac`: "what have you found that isn't in Data.lua?" (`/sllcm share found`, dev copy only).
- `L:1:fac:mapID,x,y;...`: locations the sender's Data.lua lacks, max 15 per message. Receivers learn them as
  shared locations (`SkyborneMarkerDB.shared`), whether they asked or not.
- An F is answered once a session, after 4-20 s: self-found locations first, then shared ones (SLLCM 1.3.0+; before
  that self-found only). One L at a time, each built just before it goes, leaving out what any L heard so far had,
  so clients holding the same shared locations don't all send every one.
- Unasked L (SLLCM 1.3.0+), self-found only: due at login unless this client last sent an L under 20 h ago
  (`SkyborneMarkerDB.foundSentAt`). Sent 30-90 s after the channel is first heard (Forever's refusals), leaving
  out what L's heard had; not at all if this session already answered an F.
- `VQ:1:fac` (SLLCM 1.4.0+): "which Data.lua nodes have you seen lately?" (`/sllcm share vouch`, dev copy only).
- `V:1:fac:mapID,active,sum,bits;...` (SLLCM 1.4.0+): vouches, the answer to a VQ: once a session, 4-20 s after
  it. Never unasked, never for an F. For each zone the sender heard any sighting in:
  - `active`: days in the last 60 with any R / S / own sighting in the zone, base 36, capped at 35. A day runs
    from 10:00 UTC, so an American evening counts once (UTC midnight split it in two).
  - `sum`: checksum of the zone's Data.lua list (retired points taken out), 3 base 36 chars: start `h = #list`,
    then per point in order `h = (h * 131 + X * 10007 + Y) % 46656` (X, Y = round(coord x 10000)).
  - `bits`: one per node in list order, 6 a char (`A-Za-z0-9+/` = 0-63, low bit first), trailing `A`s cut.
    1 = the sender saw it with fewer than 5 of the zone's active days since.
  - Every answerer sends all of its own; nothing is left out for others' V's (each is separate evidence).
  - Receivers skip a zone whose `sum` differs from theirs (another release's list). Merged into
    `SkyborneMarkerDB.vouch`, kept 14 days; `/sllcm export` lists Data.lua nodes nobody vouched for in a zone
    with 5+ active days (ours or an answerer's) as suspect.

## Detection
- Racial casts (UNIT_SPELLCAST_SUCCEEDED, player): 1259705 Read Leyline (Alliance), 1259686 Skysight (Horde).
- On a node the cast grants a 15-min buff: 1259691 Energized (Alliance) / 1270893 Elemental Blessing (Horde).
  Off a node the buff lasts only 15-30 s. Confirm with C_UnitAuras.GetPlayerAuraBySpellID: duration >= 60 s
  and started at or after the cast. Retry a few times at 0.5 s.
- Auras are secret in combat: pcall the read; if it fails or you're in combat, re-check on PLAYER_REGEN_ENABLED.
- Use the player's position and GetServerTime() captured at cast time.
- Minimap scan (SLLCM `Scan.lua`, out of the tocs since 17 Nov 2026: minimap tooltip text is secret): the minimap's
  soft cursor is pointed at a grid of spots (`Minimap:SetUsingSoftCursor`, `Minimap:UpdateMouseoverAtPoint`,
  `C_TooltipInfo.GetMinimapMouseover`), 8-unit coarse pass, touching hits grouped into one blip, then a 2-unit fine
  pass over each blip ("Leyline" / "Elemental Convergence"). A blip only shows while the node is up, so a hit is a
  sighting.
- SLLCM exposes the global `SLLCM_ReportSighting(mapID, x, y[, gap])` (scans use it with gap 10 min; LeyLineTest
  hovers with the default 5 min). It's skipped if anyone's sighting stamped the node in the last `gap` seconds.

## "Not there" reports (XM / XS): ignored
Skyborne Compass sends these on the same channel: a known node its minimap scan passed with no blip there, as
`XM:1:fac:phase:mapID:x:y:t` (one) or `XS:1:fac:phase:mapID,x,y,t;...` (its reply to a Q). SLLCM 0.4.1-1.4.x used
them to end a sighting in that phase; with no phases they say nothing, so 1.5.0 ignores them. They never taught a
location.

## Forever specifics
- Megarealms: the channel reaches the whole faction on a ruleset.
- Senders arrive as "First Surname"; UnitName("player") returns them separately. Self-check both forms (the
  server echoes your own messages back).
- Channel throttle: about 10 at once, then about 0.8/s; retrying while refused keeps it refused. Send one every
  1.25 s; on result 3 or 8 pause 5 s.
- Join only once the channel list has settled (unchanged 3 s, max 30 s after login) so you don't take /1. Hide the
  channel from all chat frames at +1 s and +5 s. Rejoin check every 60 s, not in instances.
- CHAT_MSG_ADDON args can be secret: drop the message if any are.
- Custom-channel messages (like whispers) arrived a minute or more late in early Oct 2026. No workaround was made;
  by 2026-10-14 echoes came back within half a second.

## Known locations for other addons: `SLLCM_GetNodes(faction)`
- A global function (from 1.4.0) returning every location SLLCM knows for a faction: all of Data.lua, then the
  self-found (`db.found`) and learned-from-sightings (`db.shared`) ones that aren't within 70 yd of one already
  listed, the same set the map draws. Data.lua can hold points closer than 70 yd; a caller wanting one per node
  merges those itself. "Show only self-found locations" doesn't change it.
- `faction` is `"Alliance"` (leylines) or `"Horde"` (elemental convergences); anything else, or nil, means the
  player's faction.
- Returns `{ [mapID] = { { x, y }, ... } }`, zone map coordinates 0-1, a new table on each call (the caller may keep
  or change it). Before SLLCM's SavedVariables load it holds Data.lua's only.
- No phase or time. Mapzeroth uses it for its "Nearest Leyline / Elemental Convergence" pick; it has no node list
  of its own and offers the pick only while SLLCM is loaded. Check `SLLCM_GetNodes ~= nil` rather than the folder
  name.

## Mapzeroth rules
- Opt-in, one-time account-wide prompt; off until answered.
- Skyborne characters only join or send.
- If SLLCM is loaded, Mapzeroth stays silent. Up to SLLCM 1.4.x it read SLLCM's per-phase sightings from
  `SkyborneMarkerDB.crowdReports[fac]` and "not there"s from `crowdGone[fac]` to prefer a node seen in your phase;
  from 1.5.0 both are gone (nil), so that preference has nothing to go on and the pick is the nearest location.
- Mapzeroth's `no-phase` branch (2026-11-19) does the same: no GUID reading, own sightings sent as R with phase 0,
  nothing heard kept, no Q / S. The "Nearest" pick goes to the nearest of SLLCM's locations.
