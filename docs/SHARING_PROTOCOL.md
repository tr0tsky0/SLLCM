# Leyline sharing protocol (version "1")

The contract between Skyborne Ley Line & Convergence Marker (SLLCM) and Mapzeroth (`LeyShare.lua`).
Both must stay wire-compatible. SLLCM's `SkyborneLeyLineConvergenceMarker/Comm.lua` is the reference
implementation; racial detection is `OnRacialCast` / `HasNodeBuff` in `SkyborneLeyLineConvergenceMarker.lua`.

## Channel and messages
- Prefix `SLLCM`. Channel `SLLCMShareA` (Alliance) / `SLLCMShareH` (Horde), joined with JoinTemporaryChannel.
- Fields are `:`-separated, with no pipes. x/y are integers 0-9999 (map coords x 10000). t = GetServerTime()
  when the node was seen. phase = digits only. fac = `A` or `H`.
  - `R:1:fac:phase:mapID:x:y:t`: one sighting
  - `Q:1:fac:phase`: "what do you have for this phase?"
  - `S:1:fac:phase:mapID,x,y,t;mapID,x,y,t;...`: reply to Q, max 9 entries per message
- A sighting lives 90 minutes (TTL; was 1 hour until a node was seen up 58+ min), then is dropped. Receivers ignore older ones and any t more than 60 s in the future.
- Two sightings within 60 yd in the same phase and map are the same node (keep the newer t).
- mapID should be a zone map. Receivers convert continent-map positions (Skyborne Compass was seen using Kalimdor,
  1414, in Oct 2026) to the zone at that spot (`C_Map.GetMapInfoAtPosition`, then world position to zone position)
  and drop them if no zone is there.
- Sightings are stored per faction, so an alt of the other faction never shows or answers with them.

## Asking (Q)
Every client hears every R and S on the channel, whatever its phase, and keeps them. So once on the
channel, a client has everything said there; a Q only helps with sightings made before it joined.
- Send a Q when a phase is learned in a zone with known nodes for the faction.
- At most once per phase per session.
- None after the first TTL (90 min) on the channel.
- Not for a phase someone else sent a Q for this session: we heard its answers too. (2026-10-18; the log showed
  clients asking about a phase moments after another one had.)
- Not for a phase with a Q (ours or heard) in the last 5 min before a /reload or relog: the time of each is saved
  (SLLCM `SkyborneMarkerDB.crowdQueried[fac][phase]`, Mapzeroth `MapzerothRebuildDB.sightingQueries[fac][phase]`).
  Sightings sent during the reload itself are missed, the same trade as restoring the phase.

## Answering (S)
- Only if holding sightings for that phase.
- Holding one of its own sightings for the phase (a "mine" flag on sightings this client broadcast
  itself, OR-ed when sightings merge): wait 1-3 s (random). Otherwise wait 4-12 s.
- Send only the nodes that no S for that phase heard during the wait already had (same node = 60 yd, as for
  merging; a newer t alone isn't worth sending). If nothing is left, send nothing. So a first answer that holds
  only some of the phase's nodes (its sender came online later) doesn't hide the rest. (SLLCM 0.4.1+; before
  that, any S during the wait cancelled the answer.)
- One pending answer per phase, not a single global one.

## Locations (F / L)
SLLCM only; Mapzeroth can ignore both. No phase field.
- `F:1:fac`: "what have you found that isn't in Data.lua?" (`/sllcm share found`, a dev tool).
- `L:1:fac:mapID,x,y;...`: locations the sender's Data.lua lacks, max 15 per message. Receivers learn them as
  shared locations (`SkyborneMarkerDB.shared`), whether they asked or not.
- An F is answered once a session, after 4-20 s: self-found locations first, then shared ones (SLLCM 1.3.0+; before
  that self-found only). One L at a time, each built just before it goes (as S answers are), leaving out what any L
  heard so far had, so clients holding the same shared locations don't all send every one.
- Unasked L (SLLCM 1.3.0+), self-found only: due at login unless this client last sent an L under 20 h ago
  (`SkyborneMarkerDB.foundSentAt`). Sent 30-90 s after the channel is first heard (Forever's refusals), leaving
  out what L's heard had; not at all if this session already answered an F.

## Detection
- Racial casts (UNIT_SPELLCAST_SUCCEEDED, player): 1259705 Read Leyline (Alliance), 1259686 Skysight (Horde).
- On a node the cast grants a 15-min buff: 1259691 Energized (Alliance) / 1270893 Elemental Blessing (Horde).
  Off a node the buff lasts only 15-30 s. Confirm with C_UnitAuras.GetPlayerAuraBySpellID: duration >= 60 s
  and started at or after the cast. Retry a few times at 0.5 s.
- Auras are secret in combat: pcall the read; if it fails or you're in combat, re-check on PLAYER_REGEN_ENABLED.
- Use the player's position and GetServerTime() captured at cast time.
- Minimap scan (SLLCM `Scan.lua`): the minimap's soft cursor is pointed at a grid of spots
  (`Minimap:SetUsingSoftCursor`, `Minimap:UpdateMouseoverAtPoint`, `C_TooltipInfo.GetMinimapMouseover`), 8-unit coarse
  pass, touching hits grouped into one blip, then a 2-unit fine pass over each blip ("Leyline" / "Elemental Convergence"). Runs every 2 s check after moving
  30 yd, a zoom/zone change, or 60 s; never in combat, instances, with a controller enabled, or with the mouse on the
  minimap. A blip only shows while the node is up in your phase, so a hit is a sighting.
- SLLCM exposes the global `SLLCM_ReportSighting(mapID, x, y[, gap])` (scans use it with gap 10 min; LeyLineTest
  hovers with the default 5 min). It's skipped if the node has a sighting in this phase from the last `gap` seconds.

## "Not there" reports (XM / XS): heard, never sent
Skyborne Compass sends these on the same channel. Confirmed from its code (2026-10-14): after a minimap scan, a node it
knows (built-in or learned from the channel) between 10 yd and 80% of the minimap's reach from the player, with no blip
there, is sent once (not again for 5 min) as
  - `XM:1:fac:phase:mapID:x:y:t`: that node isn't up in that phase at t
  - `XS:1:fac:phase:mapID,x,y,t;...`: its reply to a Q with the ones it holds for the phase, sent apart from the S
mapID can be a continent when the node is outside the sender's zone (converted as above).

SLLCM (0.4.1+) receives them but never sends them:
- Per node and phase the newest report wins. A newer XM removes the sighting from `crowdReports` (so Mapzeroth, which reads
  that, stops counting it as seen) and is kept in `SkyborneMarkerDB.crowdGone[fac][mapID]` (same entry shape), dropped
  after TTL. A newer R / S removes it again; an older one is ignored (its location is still learned).
- An XM never teaches a new location. An XS doesn't cancel our pending S answer to a Q; only an S does.
- The pin shows greyed with "Not there in your phase N min ago".

## Phase
- zoneUID = 5th field of Creature/Vehicle GUIDs (Creature-0-server-instance-zoneUID-npcID-spawn).
  Read from NAME_PLATE_UNIT_ADDED, target, mouseover, plus a nameplate rescan every 60 s.
- The first reading is used tentatively. Once confirmed, changing it needs 2 different NPC IDs agreeing.
- Reset only on a real zone change (ZONE_CHANGED_NEW_AREA / PLAYER_ENTERING_WORLD also fire on /reload).
- UnitGUID can be a secret value: pcall it and check with issecretvalue.
- A sighting made before the phase is known waits and is sent once the phase is learned in the same zone.

## Forever specifics
- Megarealms: the channel reaches the whole faction on a ruleset.
- Senders arrive as "First Surname"; UnitName("player") returns them separately. Self-check both forms (the
  server echoes your own messages back).
- Channel throttle: about 10 at once, then about 0.8/s; retrying while refused keeps it refused. Send one every
  1.25 s; on result 3 or 8 pause 5 s.
- Join only once the channel list has settled (unchanged 3 s, max 30 s after login) so you don't take /1. Hide the
  channel from all chat frames at +1 s and +5 s. Rejoin check every 60 s, not in instances.
- CHAT_MSG_ADDON args can be secret: drop the message if any are.
- Custom-channel messages (like whispers) arrived a minute or more late in early Oct 2026, so several clients could
  answer the same Q. No workaround was made; by 2026-10-14 echoes came back within half a second.

## Mapzeroth rules
- Opt-in, one-time account-wide prompt; off until answered.
- Skyborne characters only join or send.
- If SLLCM is loaded, Mapzeroth stays silent and reads SLLCM's sightings from `SkyborneMarkerDB.crowdReports[fac]`
  (0.3.0 used a single list `crowdReports[mapID]`). From 0.4.1 its "not there"s are in `SkyborneMarkerDB.crowdGone[fac]`.
- From 0.4.1 SLLCM keeps its own sightings (racial, minimap scan) in `crowdReports` with `mine = true` even while its
  sharing is off; nothing is sent then. So Mapzeroth gets the player's own sightings either way. With sharing off,
  entries without `mine` are leftovers heard while it was on (they still expire at TTL); SLLCM itself shows only `mine`
  ones then.
