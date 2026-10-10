# Commuter Compass: Waiting Passengers (station card) Design

Date: 2026-10-09. Status: approved in brainstorming, awaiting spec review.

## Goal

The user has a station with a growing crowd and can't tell where those people want to go. The base station window
only shows, per line stop, a tooltip with the *next stop* on that line ("Destinations: [3] Joplin Station 42"). It
shows neither the final destination nor a station-wide overview.

Add a **Waiting passengers** card to the station window: the people waiting at this station, grouped by their final
destination (a town or an industry), with the line most of them are waiting for. This ships inside Commuter Compass as
rev 2.

## Decisions

| Question | Decision |
| --- | --- |
| What "where they go" means | The **final destination**: the town (or industry) that the person's target belongs to. |
| Which mod | Inside **Commuter Compass**, as a second card. It reuses the table, formatting, arrow and camera code. |
| Destinations that aren't towns | **Industries get their own rows.** Targets that can't be placed are counted as "Unknown". |
| Several lines per destination | **The biggest line, plus "+N"** for the others. The tooltip has the full split. |
| Refresh | **Snapshot** when the window opens, plus a **Refresh** button. No live updates. |

## Card layout

```
Waiting passengers
 Waiting · 1,240 people · 9 destinations       [⟳ Refresh]
 ┌──────────────────────────────────────────────────────────┐
 │ Destination            Distance  Waiting  Line           │
 │ ⌖ ↗ Country Club        6.1 km     612    Red Line +1    │
 │ ⌖ ↗ Wenatchee           4.4 km     380    Red Line       │
 │ ⌖ ↗ Joplin              2.2 km     140    Bus 12         │
 │ ⌖ ↗ Coal mine           2.9 km     108    Bus 12         │
 └──────────────────────────────────────────────────────────┘
```

- **The card:**
  - A `content_card.ContentCard` titled "Waiting passengers", on `::StationGroupEowExtensionPoint`.
  - Expanded by default: it's one table, and a crowded station is the reason to open the window.
- **The table:** a `builtin.DataTable`, as in the town card. The columns are:
  - **Destination:** Locate button (⌖), arrow toggle (↗), and the name, which opens the destination's window
    (`makeEntityWindowButton`). The "Unknown" row has no buttons.
  - **Distance:** straight-line distance from the station, through `rank.formatDistance`. Shows "-" for Unknown.
  - **Waiting:** the number of people.
  - **Line:** the line with the most people for this destination, plus " +N" when N other lines also carry people for
    it. Clicking the line name opens the line window. The tooltip lists every line with its count, largest first.
- **Sorting:** starts sorted by Waiting, descending. Headers re-sort.
- **Header:** "Waiting · N people · M destinations", and a **Refresh** button that recounts in place. If the selected
  arrow's destination is still listed after a refresh, the arrow stays.
- **Special states:**
  - An empty station shows "Nobody is waiting here."
  - A failed count shows "error (see log)".
- **Condition:** `hasPassengerLines` returns true when one of the player's lines stops at the station group. It also
  returns true on error.

## Arrows

- **Shared code:** the same `FlowAction` (one `useAction` key per arrow) and `frameCamera` (shifted clear of the window)
  as the town card.
- **Direction:** the arrow goes from the station to the destination. It's always animated (the Actual style), because
  these people are already using the player's lines.
- **The station's position:** the centre of the bounding box of the first station's construction
  (`streetConnectorSystem.getConstructionEntityForStation`), because a station group likely has no bounding volume of
  its own. A destination's position uses the existing `getPosition3`, and for an industry, its construction.

## Architecture

### `waiting.tl` (engine access, new)

`gather(stationGroup) : {Waiter}`, where each `Waiter` is `{ line : Entity, destination : Entity | nil, kind : "town"
| "industry" | "unknown" }`.

1. **Stations:** `STATION_GROUP.stations`. For each station, go through its terminals and call
   `lineSystem.getLineStopsForTerminal(station, terminalIndex)`, which gives `{line, stopIndex}` pairs. Keep lines that
   `entity_util.isOwnedByPlayer` accepts.
2. **People:** for each unique `(line, stopIndex)`, call
   `simEntityAtTerminalSystem.getLineStopSimEntities(line, stopIndex, passengerCargoTypeId)`. Skip duplicates with a
   `seen` set.
3. **Each person:** the line from `SIM_ENTITY_AT_TERMINAL.line`, and the target from `SIM_PERSON.targetOrAtEntity`.
4. **Resolve the target** with a lookup built once per gather:
   - each town's `TOWN.townBuildings` maps a building to its town, plus each building's `construction`, in case the
     target is the construction;
   - an industry's construction maps to itself;
   - a target found in neither lookup is "unknown".

   The probe settles what the target actually is (see Spike).
5. **Positions:** `stationPosition(stationGroup)` and the destination position, for distances and the arrow.

### `rank.tl` (pure, extended)

`groupWaiting(waiters, info) : WaitingTable`. `info` maps a destination to `{name, distance}`, and a line to its name.

- **Rows:** one per destination, plus one "Unknown" row if needed. Each row is
  `{destination, name, distance, waiting, topLine, topLineCount, otherLineCount, lines : {{line, name, count}}}`.
- **Lines inside a row:** sorted by count, descending, with ties broken by name. `topLine` is the first of them.
- **Row order:** by waiting count, descending, then by name. The Unknown row always comes last.
- **Totals:** `totalWaiting` and `destinationCount`. The Unknown row doesn't count as a destination.
- **`formatLineLabel(row)`** gives "Red Line" or "Red Line +1".

### UI script

- **The card:** `StationPlugin` and `hasPassengerLines`, registered by a new `station_plugin.res.lua` (order 45).
- **State:**
  - `useState` holds a refresh counter;
  - the data is computed when the counter changes, inside a `pcall`, and logs the gather time;
  - the selected arrow is kept by destination, so it survives a refresh.
- **Cells:** reuse the town card's cell helpers where the shapes match. Each cell recipe returns a BoxLayout.

## Error handling

- **Counting:** `pcall` around gather and group; on failure the card shows "error (see log)" and logs
  `[commuter_compass] waiting: <error>`.
- **Missing positions:** distance is nil and shows "-". The arrow toggle is still there, and logs "no position".
- **Missing components:** an entity without the expected component (a person who boarded mid-count) is skipped.

## Spike (first in-game test)

Temporary probes, marked `-- PROBE (remove before release)`, log:

1. **Targets:** for the first 5 people, `targetOrAtEntity`, which components it has (TOWN_BUILDING, CONSTRUCTION,
   SIM_BUILDING, INDUSTRY, ...), and its name.
2. **Counts:** per line stop, the count from `getLineStopSimEntitiesCount`, and the total, to compare with the base
   window's waiting numbers. This shows whether the waiting-hall overflow is included.
3. **Timing:** gather time in ms, and the number of people.

The destination resolution (step 4) gets finalized from these results. The findings go into this spec.

## Findings (spike, 2026-10-09)

Country Club Station, a busy bus hub with 9 player line stops and 246–313 people waiting:

- **Targets:** every sampled `SIM_PERSON.targetOrAtEntity` was a **town building**: residential, commercial or
  industrial ("Industrial Building" is a town building in the industrial district, not an industry). Each has
  `TOWN_BUILDING` and `PERSON_CAPACITY`, and `TOWN_BUILDING.town` gives the town. The other `resolve` cases (industry,
  person capacity, construction) stay as fallbacks. No sample hit them, and no person ended up Unknown.
- **Counts:** the people read always equalled `getLineStopSimEntitiesCount` summed over the line stops (3/3, 313/313,
  276/276, 246/246). The waiting hall needs no separate handling.
- **Timing:** 0.2–16 ms per count (16 ms on the first count of a session, then 1–3 ms). Live updates would be
  affordable, but the snapshot plus Refresh stays.
- **Layout:** an unweighted column takes its widest content. Long line names squeezed Destination to nothing, and its
  buttons were drawn under Distance. The fix:
  - Destination and Line share the spare width at 7:6;
  - Waiting has an icon header (`symbol_person_multiple.tga`);
  - line names longer than 14 characters are shortened in the middle (`rank.shortenMiddle`).
- **Tooltips:** a `meta.tooltip` on a `BoxLayout` never shows. Pass it to `makeEntityWindowButton` (7th argument).

## Testing

- **Unit tests (`tests/rank_test.lua`):**
  - grouping per destination;
  - the top line, with ties broken by name, and "+N";
  - the lines in a row are sorted, and their counts add up to `waiting`;
  - row order, with Unknown last;
  - the totals;
  - an empty input.
- **In-game checklist:**
  - [ ] A passenger station shows the **Waiting passengers** card, expanded. A cargo-only station doesn't.
  - [ ] The total roughly matches the base window's waiting counts (the snapshot can lag slightly).
  - [ ] Destination names open their windows, line names open the line, and Locate moves the camera.
  - [ ] The line tooltip lists every line, and its counts add up to the row's Waiting.
  - [ ] Refresh updates the numbers and keeps the selected arrow.
  - [ ] Arrows go from the station to the destination, switch on the first click, and stay clear of the window.
  - [ ] The town card still works as before.

## Release

- **Revision:** Commuter Compass rev 2 (`just bump`).
- **Text:** update `modinfo.json`, `description.html` and the README to cover the town and station windows.
- **Screenshot:** one new shot of the station card on a busy station. Then upload, tag and push as usual.

## Out of scope

- Live updating.
- A per-stop breakdown (the vanilla tooltip has it).
- Cargo waiting at stations.
- Travel times and routes.
