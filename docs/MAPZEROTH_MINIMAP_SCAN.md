# Handoff: minimap node detection for Mapzeroth's LeyShare

SLLCM now finds leyline / elemental convergence blips on the minimap by itself, with no racial cast and no mouseover, and shares each one as an ordinary `R` sighting. Mapzeroth-Rebuild's `LeyShare.lua` should do the same **only when SLLCM isn't loaded**. When SLLCM is loaded it already does this and Mapzeroth stays silent, as it does today.

Nothing on the wire changes. Protocol version "1", R/Q/S as before. `SHARING_PROTOCOL.md` has been updated.

## Reference implementation (read these first)

- `C:\Users\shaun\Documents\Claude\WoW Addons\Ley Line Marker\SkyborneLeyLineConvergenceMarker\Scan.lua`: the whole feature, about 250 lines.
- `C:\Users\shaun\Documents\Claude\WoW Addons\Ley Line Marker\tools\test_scan.py`: a lupa simulation with a fake minimap, covering a rotating minimap and the controller path.
- `C:\Users\shaun\Documents\Claude\WoW Addons\Ley Line Marker\docs\SHARING_PROTOCOL.md`: the "Detection" section.

The technique came from the Skyborne Compass author's description. Port it from SLLCM's Scan.lua, not from their addon.

## How it works

**Scan (keyboard/mouse players)**
- `Minimap:SetUsingSoftCursor(true)` lets addon code point the minimap's controller cursor anywhere.
- `Minimap:UpdateMouseoverAtPoint(sx, sy)` takes screen pixels: `sx = (Minimap:GetLeft() + lx) * Minimap:GetEffectiveScale()`, and `sy` the same with `GetBottom()`.
- `C_TooltipInfo.GetMinimapMouseover()` returns the tooltip at that point. Check each `lines[i].leftText` after stripping `|c........`, `|r`, `|T..|t` and `|A..|a`. One tooltip can list several dots, so search with `find(name, 1, true)` for "Leyline" / "Elemental Convergence".
- Always switch the soft cursor back off after each frame's batch, inside a `pcall`, so an error can't leave it on.
- **Coarse pass:** a grid 8 minimap units apart, centred on the minimap and clipped to a circle (the whole square if `GetMinimapShape() == "SQUARE"`), 60 points per frame. Keep every hit, with its grid indexes.
- **Group hits into blips:** coarse hits that touch on the grid, diagonals included, are one blip. A blip's tooltip area is much wider than the coarse step: on a 226-unit square minimap at 0.64 scale it covered 20+ units. An earlier version fine-scanned ±8 around each coarse hit separately, and one node standing right next to the player came out as four results about 10 yd from it, at the corners; the first of those was what got shared.
- **Fine pass:** per blip, a 2-unit grid over the box of its coarse hits, widened by one coarse step (8) on every side. The blip centre is the centroid of the fine points that hit. 150 fine points per frame.
- **Minimap point to zone position:** `ypp = C_Minimap.GetViewRadius() / (width / 2)`, `dx = (lx - w/2) * ypp`, `dy = (ly - h/2) * ypp`. If `GetCVar("rotateMinimap") == "1"`, rotate by `f = GetPlayerFacing()`: `dx, dy = dx*cos f - dy*sin f, dx*sin f + dy*cos f`. Then `x = px + dx / zoneWidthYards`, `y = py - dy / zoneHeightYards`. Zone size in yards comes from `C_Map.GetWorldPosFromMapPos` at (0,0) and (1,1); world axes are swapped. LeyShare already has `worldPos`, so reuse that if it fits.
- **When to scan:** check every 2 s. Scan after moving 30 yd, after a minimap zoom or zone change, or after 60 s standing still.
- **Never scan:** in combat, in an instance, with the minimap hidden, or with the real mouse over the minimap. Abort a scan in progress if any of these happen or the zone changes.
- **Accuracy:** within about 5 yd at default zoom (the 2-unit grid's resolution). **Verified in SLLCM in game (2026-10-14):** a racial-confirmed node came out about 1 yd off from 182 yd away, with the minimap both fixed and rotating, on a square minimap.
- **Debugging tip:** SLLCM's `ns.ScanCommand` (in Scan.lua) prints the API checks, the reasons a scan wouldn't run, the minimap's size/scale/shape, and one scan's results, including every tooltip line seen. A similar dev-only report in Mapzeroth makes in-game problems quick to find; it found both bugs above.

**Controller players**
- If `InputUtil.IsGamepadUIEnabled()` is true or the global `SoftCursor` frame is shown, don't scan: the game owns the minimap soft cursor. Do **not** use the `GamePadEnable` CVar: it was on for a player who has never used a controller, and blocked the scan.
- Instead, every 0.1 s, find the pointer on the minimap: the mouse (`Minimap:IsMouseOver()`, `GetCursorPosition()`) or the global `SoftCursor` frame. For `SoftCursor`, take `GetCenter()` × its effective scale ÷ the minimap's effective scale, then subtract the minimap's left/bottom, and use it only if it's inside the minimap.
- If the tooltip names a node, keep a bounding box of the zone positions while it stays up. When it goes, take the box's centre, unless the box is more than 60 yd wide, which means the player moved or the tooltip lingered.
- The tooltip is `GetMinimapMouseover()` first, falling back to `GameTooltip`'s left lines. Wrap the read in `pcall`, since text can be secret in combat.
- Accuracy is about 20 yd.
- This path is **untested in game**. It assumes the gamepad UI drives the minimap mouseover from `SoftCursor`. If that's wrong, it simply never fires.

## What a hit does in Mapzeroth

- Treat it like a racial confirmation: `LeyShare:OnConfirmed(mapID, x, y, GetServerTime())`. That already handles a phase that isn't known yet (`waiting`).
- **Gate:** run only when `LeyShare:Networking()` is true (sharing on, Skyborne, SLLCM not loaded). Mapzeroth has no self-found list, so with sharing off there's nothing to do.
- **Don't flood the channel:** skip the broadcast if the node already has a sighting from anyone, in the current phase, within the last 10 minutes (60 yd counts as the same node). This is SLLCM's `SLLCM_ReportSighting(mapID, x, y, gap)` with a 10-minute gap. A scanner passes the same node every 30 yd or 60 s, and the whole faction's megarealm hears every `R`.
- Add an option to turn it off, on by default. SLLCM calls it "Detect nodes on the minimap".
- Nothing prints, as with the rest of LeyShare.

## Separate follow-up: "not there" reports (XM / XS)

Skyborne Compass also sends `XM` / `XS`: a known node its scan passed in minimap range with no blip, in that phase. SLLCM 0.4.1 receives them (never sends them); see `SHARING_PROTOCOL.md`, section "Not there" reports, and `Comm.lua` `AddGone`, tested by `tools/test_comm.py`. This is separate from the scan; do it after.
- When SLLCM is loaded: nothing to do for sightings. A newer `XM` already removes the sighting from `crowdReports`. Optionally read `SkyborneMarkerDB.crowdGone[fac]` to know a node is gone rather than just unseen.
- When SLLCM isn't loaded: handle them the same way. The newest report per node and phase wins. An `XM` never teaches a location, and an `XS` doesn't cancel your own `S` answer to a `Q`.
- For routing, "Nearest Leyline / Convergence" should skip a node whose newest report in the player's phase is "not there".

## Testing

- Port `tools/test_scan.py` into Mapzeroth's `tests/`, or copy its approach: mock the WoW APIs in lupa, draw blips with an independent world-to-minimap model, and check the results against the true node positions.
- Cover rotation off; rotation on at several headings (0, 45, 90, 135, 180, 230, 300 degrees); a "rotated the wrong way" case that must fail; and the controller cursor.
- **In game:** with rotation on and facing east, fly past a known node and check that the sighting lands on it, with share debug on.
- Node names are English only, as in SLLCM. If Mapzeroth's Locales/NodeNames have localized "Leyline" / "Elemental Convergence" strings, use those.
