# Changelog

## Unreleased

### Added
- **Send your finds in.** `/sllcm export` now gives you a link with your new finds already in it: press Ctrl+C, paste it into your browser and press Submit, and they go into the next update. No GitHub account? Paste the same link on the Discord. If every node you've found is already in the addon, it tells you you're up to date.
- **A reminder at login** once you've found 5 nodes the addon doesn't know yet, and again each time you find 5 more.

## 1.6.0

### Changed
- **Overflow sharing channels.** A sharing channel holds about 200 players, and a full one shows as greyed out. When that happens the addon now moves on to the next channel (SLLCMShareA2, A3, A4, or H2 to H4 for Horde) and shares there instead of waiting for room.
- **571 bad locations removed.** Player reports that landed near a real node but that no player has ever seen in about 6 days of crowd checks: 292 Leylines and 279 Elemental Convergences.

## 1.5.0

### Changed
- **Sharing no longer uses phases.** WoW: Forever's 1.60.1 hotfix hides the layer from addons, so sightings now share where a node is and when it was last seen. Pins no longer turn green and fade to red; instead the pin tooltip shows when the node was last seen.
- **Pin opacity.** The new **Pin opacity** setting (10-100%) applies to every pin. It replaces the slider for pins nobody had seen.

### Fixed
- **Your sightings survive a sharing pause.** A sighting made while the sharing channel isn't working is kept (the newest 5) and sent once the channel is back.
- **Learned locations tidy themselves.** A location you learned from other players is dropped if nobody has seen or reported it in 60 days, and one player can teach you at most 100 new locations a session.
- **Fewer problems in combat.** The addon no longer reads your buffs during a fight, and opening the settings in combat opens them once combat ends.
- **The world map opens faster.** Pins aren't rebuilt while the map is closed.

## 1.4.1

### Fixed
- **The sharing channel keeps trying.** When the channel was greyed out, the addon gave up after 6 tries until a `/reload`. It now keeps trying every 10 minutes for the rest of the session.
- **Found locations at login.** The locations you share at login are sent again if the channel refused them the first time.

## 1.4.0

### Added
- **88 new Leylines** reported by players.
- **For addon authors:** `SLLCM_GetNodes(faction)` returns every location the addon knows for a faction. Mapzeroth uses it for "Nearest Leyline" and "Nearest Elemental Convergence".

### Changed
- **74 duplicate locations removed.** Shared copies of nodes already on the map (closer than 70 yd) that nobody had seen are gone.
- **Two sightings within 70 yd are the same node** (was 60 yd). The racial works from up to about 30 yd away, so two casts at one node can be 60 yd apart.
- **Minimap scanning is off.** A Forever update made the minimap's tooltip text unreadable to addons.

## 1.3.0

### Added
- **789 new nodes** from player-found locations and Wowhead.
- **Found locations are shared at login.** Locations you found that aren't in the addon's list go out to other players once a day, so everyone's map fills in without anyone asking.

### Fixed
- **Pets and companions** no longer confuse which phase you're in.
- **Minimap hover checks** skip tooltip text the game hides from addons instead of erroring.

## 1.2.0

### Added
- **830 new nodes** from player-found locations and Wowhead.
- **Mount Hyjal and Shen'dralas** are named on their pins.

### Fixed
- **The sharing channel recovers.** A greyed-out sharing channel is revived instead of staying off until you log out, and Forever's channel refusals are treated as a pause.

## 1.1.0

### Added
- **4 nodes from Wowhead** (Dun Morogh, Elwynn Forest, Zephras Isle).
- **Unsighted opacity**: a slider for pins nobody has seen lately.
- **Hide time**: the "hide nodes you've used" setting can now be set up to 60 minutes.

### Fixed
- **Node buff detection** and **rejoining the sharing channel**.

## 1.0.0

Forever launch release.

### Added
- **70 nodes** gathered on both factions at the end of the beta.

### Changed
- **Tidier world map.** Unsighted nodes within 200 yd of a shown pin fold into it; seen nodes keep their own pins.

### Fixed
- **Shares sent too early** (before the channel was joined) are retried instead of dropped.
- **Locations recorded on a continent map** are converted to the zone before they're shared.

## 0.5.0

### Added
- **50 nodes** from the beta, Wowhead and a CurseForge report.
- **Share found locations.** Players can ask each other for locations missing from the addon's list.

### Fixed
- **Sharing replies** no longer let an older report override a newer sighting of the same node, and replies are spread out so the channel isn't flooded.

## 0.4.1

### Changed
- **Renamed** to Skyborne Leyline & Convergence Marker, and "ley line" is now spelt "Leyline" to match the game.

### Added
- **About page** in the settings, with a Discord invite button.
- **25 nodes** from shared and own sightings.

### Fixed
- **Minimap detection** matches the minimap's new "Leyline" tooltip text.
- **Sharing after a `/reload`** starts straight away when you're already in the channel.

Versions before 0.4.1 aren't tagged in git.
