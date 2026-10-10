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
| Several lines per destination | **One row per destination and line**, so each line name opens its own line. This changed after the first test; it was "the biggest line plus \"+N\"", where the other lines couldn't be reached. |
| Refresh | **Live:** recounted every 2 seconds while the window is open, like the base terminals view. This changed after the spike; it was "snapshot plus a Refresh button". |

## Card layout

```
Waiting passengers
 Waiting · 1,240 people · 9 destinations
 ┌──────────────────────────────────────────────────────────┐
 │ Destination            Distance  Waiting  Line           │
 │ ⌖ ↗ Country Club        6.1 km     500    Red Line       │
 │ ⌖ ↗ Wenatchee           4.4 km     380    Red Line       │
 │ ⌖ ↗ Joplin              2.2 km     140    Bus 12         │
 │ ⌖ ↗ Country Club        6.1 km     112    Bus 4          │
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
  - **Line:** the line these people are waiting for. Clicking it opens the line window. Names longer than 17
    characters are shortened in the middle (`rank.shortenMiddle`), and the tooltip then shows the full name.
  - A destination served by several lines has one row per line. They share one arrow, and only the toggle of the row
    that was clicked lights up (`Selection.via`).
- **Sorting:** starts sorted by Waiting, descending. Headers re-sort.
  - **The order is frozen between header clicks.** The numbers update live, but rows keep their place; a new row (or
    one back after being hidden) slots in by its numbers at that moment. A header click re-sorts on the current
    numbers, then scrolls the window back up to the header line (`ensureVisible` on its node; the table's `scrollToRowKey` only scrolls inside the table).
  - Why: the table keeps its current row (the last row clicked, else the first) in view whenever it re-sorts. Re-sorting
    on every update made the window chase that row up and down the list.
- **Header:** "Waiting · N people · M destinations". The card recounts every 2 seconds
  (`engine_react_util.useStepStateTimer`) and re-renders only when the result changes.
  - **Stable rows:** each destination and line gets a row key once, so it keeps its row and cells across updates.
    The table's row keys only ever grow; rows nobody waits for right now are hidden with `fnUserFilter`, as the base
    Statistics tables do. (Changing the row keys rebuilds the table, and the window jumped to mid-table.)
  - **Live cells:** the cells poll the card's shared row map, which is refilled in place on every update.
  - **The arrow** stays until the player turns it off.
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

- **Rows:** one per destination and line, plus one "Unknown" row per line if needed. Each row is
  `{destination, name, distance, line, lineName, waiting}`.
- **Row order:** by waiting count, descending, then destination name, then line name. Unknown rows come last.
- **Totals:** `totalWaiting`, and `destinationCount` (distinct destinations, without Unknown).
- **`shortenMiddle(text, maxChars)`** shortens long names, keeping the start and a longer end (UTF-8 aware).

### UI script

- **The card:** `StationPlugin` and `hasPassengerLines`, registered by a new `station_plugin.res.lua` (order 45).
- **State:**
  - `useStepStateTimer` recounts every 2 seconds, inside a `pcall`, and logs an error only when it changes;
  - one `WaitingData` object holds the rows and the selection for the card's lifetime;
  - the selected arrow is kept by destination.
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
- **Timing:** 0.2–16 ms per count (16 ms on the first count of a session, then 1–3 ms; 3–5 ms in a later check). Live updates would be
  affordable, so after the spike the card switched from Refresh to updating every second.
- **Layout:** an unweighted column takes its widest content. Long line names squeezed Destination to nothing, and its
  buttons were drawn under Distance. The fix:
  - Destination and Line share the spare width at 7:6;
  - Waiting has an icon header (`symbol_person_multiple.tga`);
  - line names longer than 14 characters are shortened in the middle (`rank.shortenMiddle`).
- **CPU (2026-10-10):** with Country Club's window open, one game thread went from about 40% to 90%, but hiding the
  table (a probe toggle) changed nothing, so the base station window is the cost. The card still recounts every 2 s
  (not 1 s) and its cells poll on a 0.25 s timer instead of every frame.
- **Tooltips:** a `meta.tooltip` on a `BoxLayout` never shows. Pass it to `makeEntityWindowButton` (7th argument).

## Testing

- **Unit tests (`tests/rank_test.lua`):**
  - grouping per destination and line;
  - row order (waiting, then destination name, then line name), with Unknown last;
  - `shortenMiddle`, by characters, not bytes;
  - the totals;
  - an empty input.
- **In-game checklist:**
  - [ ] A passenger station shows the **Waiting passengers** card, expanded. A cargo-only station doesn't.
  - [ ] The total roughly matches the base window's waiting counts (it lags by up to a second).
  - [ ] Destination names open their windows, line names open the line, and Locate moves the camera.
  - [ ] A destination with several lines has a row per line, and each line name opens its own line.
  - [ ] A shortened line name shows its full name as a tooltip.
  - [ ] The numbers update by themselves about once a second, without flicker. Tooltips stay open while hovering, and
    the arrow stays.
  - [ ] Turning on the arrow in one of a destination's rows lights only that row's toggle.
  - [ ] Arrows go from the station to the destination, switch on the first click, and stay clear of the window.
  - [ ] The town card still works as before.

## Release

- **Revision:** Commuter Compass rev 2 (`just bump`).
- **Text:** update `modinfo.json`, `description.html` and the README to cover the town and station windows.
- **Screenshot:** one new shot of the station card on a busy station. Then upload, tag and push as usual.

## Out of scope

- A per-stop breakdown (the vanilla tooltip has it).
- Cargo waiting at stations.
- Travel times and routes.
