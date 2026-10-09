# Commuter Compass: Design

**Date:** 2026-10-09
**Game:** Transport Fever 3 (native Linux build)
**Status:** Approved in brainstorming, awaiting spec review
**Sibling:** Cargo Compass (`../closest_consumer`), whose patterns and tooling this mod copies

## Goal

A Reddit user asked about Cargo Compass: "Any chance to expand it to the Towns panel for commuter distances between
towns?"

When the player opens a town's window, show which other towns exchange commuters with it, how far away they are, and
how many of those commuters ride the player's lines. Also show the nearest towns with no commuters at all, as
candidates for new connections.

The base game already has a "Destinations" table on the town window's Supplies tab (`TownDestinations` in
`gui/entity_window/town/town.tl`). It lists every town with Shop and Work counts and a Line Usage %, but it has no
distance, no inbound counts, and can't be sorted by distance. This mod adds that as its own card, the same way Cargo
Compass complemented the industry Consumers table.

## Decisions

| Question | Decision |
|---|---|
| Row content | Distance plus commuter counts: work, shop, and line usage % |
| Direction | Both, in separate **Outbound** and **Inbound** sections |
| Which towns per section | Outbound/Inbound: only towns with at least one commuter in that direction. A third section, **Nearby, no commuters**, shows the 3 nearest towns with zero commuters either way |
| Sorting | Straight-line distance, ascending; ties by name |
| Destinations counted | Towns only. Industries and the HQ (also in the base table) are ignored |
| Distance metric | Straight line on the map plane (x, y). The engine exposes no road/rail distance or travel time to mods |
| Refresh | Computed once when the window opens. Reopen the window to refresh |
| Integration | Own plugin card on `::TownEowExtensionPoint`. No base files overridden |
| Cosmetic | Yes: `cosmetic: true`, severities "None". Achievements stay enabled |
| Real trips per year | Out of scope. It would need a game script with saved state, which would make the mod non-cosmetic |

## Card layout

One card titled **Commuters**, at order 45 (after the base Charts at 40). Plugin cards show on every info tab, not
only Supplies.

```
┌ Commuters ───────────────────────────────────────┐
│ ▸ Outbound · 3 towns · 21 trips                  │
│ ▾ Inbound · 2 towns · 13 trips                   │
│    Town                 Distance   🏢   🛒   🚆   │
│    [⌖][➚] Riverton      4.2 km     4    7   45%  │
│    [⌖][➚] Oakford       7.9 km     0    2    0%  │
│ ▸ Nearby, no commuters · 3 towns                 │
└──────────────────────────────────────────────────┘
```

- **Sections:** each section header is a collapsible button with the combobox arrows
  (`::/gui/builtin/combobox/arrow_right.tga` / `arrow_down.tga`), as in Cargo Compass.
  - **Outbound:** towns where this town's residents work or shop. The header shows
    "Outbound · N towns · M trips".
  - **Inbound:** towns whose residents work or shop here. The header follows the same format.
  - **Nearby, no commuters:** the header shows "· N towns".
  - Every section starts collapsed. Expanded state lasts only while the window is open.
- **Trips, not commuters** (changed after the spike): the engine's usage count always equals work + shop, so it
  counts destinations, and a resident who both works and shops in a town counts twice. Headers say "trips".
- **Rows** (changed after the spike, which showed free-flowing rows looked cramped): each section is a
  `builtin.DataTable`, the widget behind the base Destinations table.
  - **Columns:**
    - Town: `LocateButton`, the arrow toggle, and the name (`makeEntityWindowButton`).
    - Distance.
    - Work, Shop and Line usage, with the base table's header icons and tooltips. Nearby has no count columns.
  - Every column sorts when its header is clicked. Tables start sorted by distance, nearest first.
  - No row cap, because a sorted cut-off list would mislead. The tables scroll.
  - Cells receive the section's data as `userParam`, which only reaches newly created cells. The arrow toggle
    therefore polls the shared selection with `engine_react_util.useStepState`.
  - Columns are left-aligned. The base `right-aligned` style class only applies inside the Statistics window.
- **Distance format:** the same as Cargo Compass: under 1000 m as `"850 m"`, otherwise as km with one decimal
  (`"4.2 km"`).
- **Empty states:**
  - Outbound with no towns: "No commuters leave this town."
  - Inbound with no towns: "No commuters arrive from other towns."
  - The Nearby section is left out when every other town exchanges commuters with this one.
  - A map with one town: no card at all (the plugin condition hides it). If no other town has a position, the card
    shows only "No other towns on this map".

## Arrows

- Each row's arrow toggle shows **one** cargo-flow arrow on the map and frames both towns with the camera. Only one
  arrow shows at a time, and the selection lives in the card's single list component.
- **Direction:**
  - Outbound: this town → X.
  - Inbound: X → this town.
  - Nearby: this town → X.
- **Style:**
  - Animated (`layerColors.CargoFlow.Consumers3D.Actual`, non-zero speed) when line usage in that direction is
    above 0.
  - Faint and static (`Potential`, `transparency.VeryLow`, speed 0) when nobody in that direction uses the
    player's lines.
  - Nearby: always faint.
- **Arrow contents:**
  - `cargoTypes = { api.res.cargoTypeRep.getPassengerCargoTypeId() }`.
  - `from`/`to` are town centres at the top of each town's bounding box.
- **Binding:** the same as Cargo Compass:
  - `react.useAction(gameCtx.rendererComponent, makeDefaultSelectorAction(gameCtx, layerConfig), key)`.
  - Then `setActiveOwnerOverride(selfRef)`, cast because it is missing from the tealdefs, and guarded with
    `hasExpired()` / `getIdentity()`.
  - On unmount, `setActiveOwnerOverride(false)` hands the map back to the town window's own overlay.
  - Never call `setActiveOwner`, and never push a tool onto the ToolStack.
- **Camera:** `api.gui.camera.focusPosition(midpoint, max(MIN_DISTANCE, gap * FACTOR))`, with Cargo Compass's
  tuned constants.

## Architecture

Mod ID: `pgrace_commuter_compass` (already initialised from the template). The display name is "Commuter Compass".

```
mod/pgrace_commuter_compass/
├── mod.json                                   # cosmetic: true, revision 1
├── _metadata/                                 # modinfo.json, description.html, screenshots
├── tealdef/
│   ├── pgrace_commuter_compass_def.d.tl       # registry
│   └── gui/pgrace_commuter_compass/*.d.tl     # PgraceCommuterCompassRank, PgraceCommuterCompassCommuters
└── content/gui/pgrace_commuter_compass/
    ├── town_plugin.res.lua                    # react-plugin ::TownEowExtensionPoint, order 45
    ├── pgrace_commuter_compass.script.tl      # card UI + FlowAction; rendering only
    ├── commuters.tl                           # reads game state (api.engine.*)
    └── rank.tl                                # pure: sections, sorting, caps, totals, formatting
```

The template's `industry_plugin.res.lua` and `util.tl` (the hello-world example) are removed. `rank.tl` replaces
`util.tl` as the pure, unit-tested module.

### `commuters.tl` (engine access)

```teal
record Counts
	work : integer
	shop : integer
	usageCount : integer       -- count from the "usage" query (land use 0)
	linesUseCount : integer    -- linesUseCount from the "usage" query
end
record TownData
	entity : Engine.Entity
	name : string
	distance : number          -- metres, straight line on the map plane
	outbound : Counts          -- this town's residents travelling to `entity`
	inbound : Counts           -- `entity`'s residents travelling to this town
end
gather : function(town : Engine.Entity) : {TownData}
getPosition3 : function(entity : Engine.Entity) : Vec3f   -- bbox centre, box top for z
```

1. **Towns:** every entity with a `TOWN` component, except the clicked town. Positions are the `BOUNDING_VOLUME`
   bbox centres, and towns without one are skipped. Names come from `api.engine.util.getEntityName`, with
   "Unnamed" as the fallback.
2. **Outbound:**
   - Build the map `{ [otherTown] = true }` over all other towns.
   - Call `api.engine.util.town.getSourceToDestinationCount(town, map, landUse)` with `landUse` 1 (shop),
     2 (work) and 0 (usage). These are the same arguments the base `TownDestinations` uses.
   - Read `[otherTown].count` and `[otherTown].linesUseCount`. A missing entry means 0.
3. **Inbound:** for each other town T, call `getSourceToDestinationCount(T, { [town] = true }, landUse)` for the same
   three land uses, and read `[town]`. That's 3 calls per town.
4. **Missing API:** if `getSourceToDestinationCount` is nil (after a game update), `gather` returns distances with
   nil counts. The card then shows a single Nearby-style list of the nearest towns, plus the hint
   "Commuter data unavailable".

### `rank.tl` (pure, unit-tested)

```teal
record Row
	entity : Engine.Entity
	name : string
	distance : number
	work : integer
	shop : integer
	lineUsage : number         -- 0..1, or nil when usageCount is 0
end
record Section
	rows : {Row}               -- sorted, capped
	townCount : integer        -- before the cap
	tripCount : integer        -- sum of work + shop (trips), before the cap
end
record Sections
	outbound : Section
	inbound : Section
	nearby : Section
end
buildSections : function(towns : {TownData}, cap : integer, nearbyCount : integer) : Sections
formatDistance : function(metres : number) : string
formatPercent : function(fraction : number) : string     -- "45%", or "-" for nil (as the base table)
```

The rules:

- A town goes in Outbound when `outbound.work + outbound.shop > 0`, and in Inbound by the same rule on `inbound`.
- A town goes in Nearby when it is in neither. Nearby takes the `nearbyCount` (3) nearest.
- Each list is sorted by distance, with ties broken by name, then capped at `cap` (10).
- `townCount` and `tripCount` are counted before the cap, so the header totals stay true even when the list
  is cut.
- `lineUsage = linesUseCount / usageCount` when `usageCount > 0`, otherwise nil.
- The arrow is animated when `lineUsage` is above 0.

### UI script

- `TownPlugin = react.RegisterPluginRecipe(town_eow.TownEowExtensionPoint, "PgraceCommuterCompassTown", fn)`.
- **Condition:** `hasOtherTowns`. It returns true when at least one other town exists, and also returns true on
  error.
- The card wraps `content_card.ContentCard` (title, `recipeAndParamPermanent`, `gameCtx`, `showOnRightSide`).
- The data is computed once with `react.useStateLazy(function() return pcall(...) end)`.
- The list recipe holds the expanded-sections table and the selected arrow `{from, to, animated}`. When an arrow is
  selected, it renders the `FlowAction` child.

## Error handling

- `gather` and `buildSections` run inside `pcall`. On failure the card shows "error (see log)", and
  `debugPrint("[commuter_compass] error ...")` records the error. The town window must never break because of
  this mod.
- A town with no bounding volume is skipped.
- A missing count entry is treated as 0.
- Missing APIs (`getSourceToDestinationCount`, `setActiveOwnerOverride`) degrade the feature instead of crashing.

## Spike (first in-game test)

A first build with temporary probes (`-- PROBE (remove before release)`, with the log prefix `[commuter_compass]`)
checks the following, all in one in-game session:

1. The card appears in the town window at the expected position.
2. The arrow override works from a town window, and closing the arrow or the window brings back the town's own
   overlay.
3. The passenger icon renders on the arrow, or the arrow at least looks right.
4. **Timing:** `os.clock()` around `gather`, logged with the town count, on the user's largest save.
   - If it takes more than about 50 ms, the inbound pass moves to when Inbound is first expanded, with a
     "loading…" placeholder.
   - If that is still too slow, the calls are spread over ticks the way the base game does.
5. **Counts:** the outbound work and shop counts and the line usage % match the base Destinations table on the
   Supplies tab for the same town.

## Findings (spike, 2026-10-09)

Measured on the user's largest save (54 towns, about 12,750 people), with probes since removed.

- **Timing:** `gather` for a town takes 9–11 ms on a healthy system, and 39–172 ms for Ferry Pass (it varies with the
  simulation load). The 58–60 ms first readings came from a session where the whole PC was about 3× slow. It's a
  single pause when a window opens, so **no cache**. If one is ever needed, module state in `commuters.tl` does persist
  between window opens (the probe call counter kept rising), so a module-level town-by-town matrix would work.
- **Counts:** `usage.count` always equals work + shop, so the engine counts destinations (trips). A resident who both
  works and shops in a town counts twice. Headers say "trips".
- **Inbound:** B's Inbound entry for A matches A's Outbound entry for B, and both match the base Destinations table.
- **Layout:** free-flowing rows looked cramped, so each section became a `builtin.DataTable` (see Card layout).
- **Crash:** a table cell recipe that returned a bare `TextView` took down the whole UI ("Recipe child must be a
  layout"). Every recipe now returns a `BoxLayout`. Recorded in `../AGENTS.md`.
- **Switching arrows:** with one `useAction` key for every arrow, switching from one arrow to another left the old
  arrow on screen, while the camera still framed the new one. A fresh mount always worked. Fix: the action key
  includes the selection (`commuter_compass_flow:<from>><to>±`). Cargo Compass uses a single key the same way and may
  have the same latent bug.
- **Overlay hand-back:** toggling off, closing the window, folding sections, and opening another town (whose window
  takes the map) all behave correctly.

## Testing

- `just check`: type-check against the game's tealdefs.
- `just test`: unit tests for `rank.tl`:
  - section membership (outbound only, inbound only, both, neither);
  - Nearby takes exactly the 3 nearest towns from "neither";
  - the cap of 10, with totals counted before the cap;
  - sorting by distance with name ties;
  - line usage maths, nil when `usageCount` is 0, and `formatPercent`'s "-";
  - `formatDistance` boundaries.
- `just verify` before every in-game test request.
- **In-game checklist** (after the spike):
  - [ ] The card appears on a town window, titled "Commuters", with all sections collapsed.
  - [ ] Outbound towns and counts match the base Destinations table.
  - [ ] Inbound: open town B, which Outbound lists for A. A should be in B's Inbound with the same counts.
  - [ ] Nearby lists the 3 nearest towns with no commuters, sorted by distance.
  - [ ] Locate moves the camera, and the name opens that town's window.
  - [ ] An arrow on a row with line usage above 0 is animated. With 0% it is faint. Nearby arrows are faint.
  - [ ] An Outbound arrow points away from this town, and an Inbound arrow points towards it.
  - [ ] Only one arrow shows at a time. Toggling it off, or closing the window, restores the town's normal overlay.
  - [ ] Map clicks still select things while an arrow is shown.
  - [ ] Section headers show the correct totals.

## Release

- This is a new mod.io entry. The first upload writes `_metadata/mod.io_fileid.txt`.
- `modinfo.json`:
  - name "Commuter Compass";
  - a summary of at most 100 characters;
  - tag "Script Mod";
  - the description mentions Cargo Compass as its sibling.
- Screenshots: 1920x1080. `0.png` is the cover, showing the card with an arrow on the map.
- The flow is the usual one: `just bump` (not needed for revision 1), `just release`, upload from Mod Hub → My
  Mods, then `just mark-uploaded`.

## Out of scope

- Industries and the HQ as commuter destinations.
- Road or rail distance, and travel times.
- Real trip counts per year, which would need a game script with saved state.
- Live refresh while the window is open.
- Showing several arrows at once, or a whole-network view.
- Plugins on station or line windows.
