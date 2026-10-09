# Commuter Compass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Commuters" card to TF3's town window. It lists outbound and inbound commuter towns (distance, work,
shop, line usage %) plus the 3 nearest unconnected towns, and each row has a single map arrow.

**Architecture:** A cosmetic UI mod on `::TownEowExtensionPoint`, split into three modules:

- `rank.tl` is pure: sections, sorting, caps, totals and formatting. It is unit-tested in plain Lua.
- `commuters.tl` reads engine state: towns, positions and `getSourceToDestinationCount`.
- The script renders the card and binds one flow-arrow map action with `setActiveOwnerOverride`. That pattern is
  copied from Cargo Compass (`../closest_consumer`).

**Tech Stack:** Teal 0.24.8 (type-checked against the game's tealdefs), the TF3 React GUI (`react.lua`,
`builtin.lua`), plain-Lua tests, and `just`.

**Spec:** `docs/superpowers/specs/2026-10-09-commuter-compass-design.md`

**Branch:** `feature/commuter-compass`, which already exists and holds the spec.

---

## Background for the implementer

- **You cannot run the game.** The user runs every in-game test. `just check` (the type-check) is the main safety
  net, so run it after every edit to a `.tl` file.
- **Read `../AGENTS.md` first,** especially "Teal gotchas" and "Drawing on the map".
- **Reference implementation:** `../closest_consumer/mod/pgrace_closest_consumer/content/gui/closest_consumer/`.
  This plan copies its `FlowAction`, its fold state and its row patterns.
- **Global records:** the tealdefs in `mod/pgrace_commuter_compass/tealdef/gui/pgrace_commuter_compass/*.d.tl`
  declare global records. Register each one in `tealdef/pgrace_commuter_compass_def.d.tl`. `tools/build.py`, run by
  `just check`, copies them into `content/` and rewrites `_content.json`. **Never edit `content/**/*.d.tl` by hand.**
  `build.py` doesn't delete stale copies, so delete a removed `.d.tl` from both places.
- **The engine call:** `api.engine.util.town.getSourceToDestinationCount(source, {dest = true, ...}, landUse)` returns
  `{dest : {count, linesUseCount}}`, with `landUse` 1 = shop, 2 = work and 0 = usage. The base game's line usage %
  is `usage.linesUseCount / usage.count` (`gui/entity_window/town/town.tl` 296-303, 466-528 in the extracted base
  source).
- **Log prefix:** `[commuter_compass]`.

## File map

| File | Responsibility |
|---|---|
| `mod/pgrace_commuter_compass/tealdef/gui/pgrace_commuter_compass/rank.d.tl` | Create: `PgraceCommuterCompassRank` types and pure functions |
| `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/rank.tl` | Create: the pure implementation |
| `tests/rank_test.lua` | Create: unit tests for `rank.tl` |
| `mod/pgrace_commuter_compass/tealdef/gui/pgrace_commuter_compass/commuters.d.tl` | Create: `PgraceCommuterCompassCommuters` declarations |
| `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/commuters.tl` | Create: engine access |
| `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/town_plugin.res.lua` | Create: plugin registration |
| `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/pgrace_commuter_compass.script.tl` | Replace: card UI + `FlowAction` |
| `mod/pgrace_commuter_compass/tealdef/pgrace_commuter_compass_def.d.tl` | Modify: the registry |
| `util.tl`, `util.d.tl` (both copies), `industry_plugin.res.lua`, `tests/util_test.lua` | Delete: the template hello-world |
| `_metadata/modinfo.json`, `_metadata/description.html`, `README.md` | Modify: release text |

Two small additions to the spec's `rank` API, both pure and tested:

- `planarDistance` is shared by `commuters.tl`.
- `Sections.countsKnown` is false when the commuter API is missing, so the UI can show "Commuter data unavailable".

---

### Task 1: Replace the template scaffold with `rank.tl` formatting helpers

**Files:**
- Delete: `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/util.tl`,
  `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/util.d.tl`,
  `mod/pgrace_commuter_compass/tealdef/gui/pgrace_commuter_compass/util.d.tl`, `tests/util_test.lua`
- Create: `mod/pgrace_commuter_compass/tealdef/gui/pgrace_commuter_compass/rank.d.tl`
- Create: `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/rank.tl`
- Modify: `mod/pgrace_commuter_compass/tealdef/pgrace_commuter_compass_def.d.tl`
- Test: `tests/rank_test.lua`

The template script still `ug_require`s `util.tl` until Task 4 replaces it. So in this task, `just check` is
expected to fail **only** on `pgrace_commuter_compass.script.tl`. The tests must pass.

- [ ] **Step 1: Delete the hello-world pure module and its test**

```bash
git rm -q mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/util.tl \
  mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/util.d.tl \
  mod/pgrace_commuter_compass/tealdef/gui/pgrace_commuter_compass/util.d.tl \
  tests/util_test.lua
```

- [ ] **Step 2: Write the `rank` type definitions**

Create `mod/pgrace_commuter_compass/tealdef/gui/pgrace_commuter_compass/rank.d.tl`:

```teal
-- Pure helpers (no api.* calls), so tests/rank_test.lua can run them in plain Lua.
global record PgraceCommuterCompassRank
	-- Commuters from one town to another, as getSourceToDestinationCount reports them.
	record Counts
		work : integer
		shop : integer
		-- `count` and `linesUseCount` of the "usage" query (land use 0); line usage % = linesUseCount / usageCount.
		usageCount : integer
		linesUseCount : integer
	end

	-- Another town, seen from the clicked town.
	record TownData
		entity : Engine.Entity
		name : string
		-- Metres, straight line on the map plane.
		distance : number
		-- The clicked town's residents working or shopping in `entity`; nil when the game has no commuter data.
		outbound : Counts
		-- `entity`'s residents working or shopping in the clicked town; nil when the game has no commuter data.
		inbound : Counts
	end

	record Row
		entity : Engine.Entity
		name : string
		distance : number
		work : integer
		shop : integer
		-- 0..1, or nil when nobody is counted (usageCount 0).
		lineUsage : number
	end

	record Section
		-- Sorted by distance (ties by name), capped.
		rows : {Row}
		-- Towns in the section before the cap.
		townCount : integer
		-- Sum of work + shop over all towns in the section, before the cap.
		commuterCount : integer
	end

	record Sections
		outbound : Section
		inbound : Section
		-- The nearest towns with no commuters either way.
		nearby : Section
		-- False when any town came without counts (the game lacks the commuter API); then every town is "nearby".
		countsKnown : boolean
	end

	-- Straight-line distance on the map plane.
	planarDistance : function(ax : number, ay : number, bx : number, by : number) : number
	-- linesUseCount / usageCount, or nil when counts are nil or usageCount is 0.
	lineUsage : function(counts : Counts) : number
	-- Outbound/inbound: towns with work + shop > 0 in that direction, capped at `cap`.
	-- Nearby: towns with none either way, capped at `nearbyCount`. All sorted by distance, ties by name.
	buildSections : function(towns : {TownData}, cap : integer, nearbyCount : integer) : Sections
	-- "850 m" below one kilometre, otherwise "4.2 km".
	formatDistance : function(metres : number) : string
	-- "45%", or "-" for nil (as the base Destinations table).
	formatPercent : function(fraction : number) : string
end
```

- [ ] **Step 3: Register it**

Replace the contents of `mod/pgrace_commuter_compass/tealdef/pgrace_commuter_compass_def.d.tl` with:

```teal
require "gui.pgrace_commuter_compass.rank"
```

- [ ] **Step 4: Write the failing tests for the helpers**

Create `tests/rank_test.lua`:

```lua
local t = ...
local rank = t.requireTl("gui/pgrace_commuter_compass/rank.tl")

t.test("planarDistance: straight line on the map plane", function()
	t.eq(rank.planarDistance(0, 0, 3, 4), 5)
	t.eq(rank.planarDistance(100, 100, 103, 104), 5)
	t.eq(rank.planarDistance(7, 7, 7, 7), 0)
end)

t.test("formatDistance: metres below 1 km", function()
	t.eq(rank.formatDistance(0), "0 m")
	t.eq(rank.formatDistance(850.4), "850 m")
	t.eq(rank.formatDistance(999.4), "999 m")
end)

t.test("formatDistance: kilometres with one decimal", function()
	t.eq(rank.formatDistance(999.6), "1.0 km")
	t.eq(rank.formatDistance(4210), "4.2 km")
	t.eq(rank.formatDistance(11349), "11.3 km")
end)

t.test("formatPercent: rounds to whole percent, '-' for nil", function()
	t.eq(rank.formatPercent(nil), "-")
	t.eq(rank.formatPercent(0), "0%")
	t.eq(rank.formatPercent(0.454), "45%")
	t.eq(rank.formatPercent(0.456), "46%")
	t.eq(rank.formatPercent(1), "100%")
end)

t.test("lineUsage: linesUseCount / usageCount, nil when nothing is counted", function()
	t.eq(rank.lineUsage(nil), nil)
	t.eq(rank.lineUsage({ work = 0, shop = 0, usageCount = 0, linesUseCount = 0 }), nil)
	t.eq(rank.lineUsage({ work = 8, shop = 4, usageCount = 12, linesUseCount = 3 }), 0.25)
	t.eq(rank.lineUsage({ work = 1, shop = 0, usageCount = 1, linesUseCount = 0 }), 0)
end)
```

- [ ] **Step 5: Run the tests and check that they fail**

Run: `just test`
Expected: FAIL. `requireTl` errors because `rank.tl` doesn't exist yet.

- [ ] **Step 6: Write the helpers**

Create `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/rank.tl`:

```teal
local rank : PgraceCommuterCompassRank = {}

function rank.planarDistance(ax : number, ay : number, bx : number, by : number) : number
	local dx = bx - ax
	local dy = by - ay
	return math.sqrt(dx * dx + dy * dy)
end

function rank.lineUsage(counts : PgraceCommuterCompassRank.Counts) : number
	if counts == nil or counts.usageCount <= 0 then
		return nil
	end
	return counts.linesUseCount / counts.usageCount
end

function rank.formatDistance(metres : number) : string
	local rounded = math.floor(metres + 0.5)
	if rounded < 1000 then
		return string.format("%d m", rounded)
	end
	return string.format("%.1f km", metres / 1000)
end

function rank.formatPercent(fraction : number) : string
	if fraction == nil then
		return "-"
	end
	return string.format("%d%%", math.floor(fraction * 100 + 0.5))
end

return rank
```

- [ ] **Step 7: Run the tests and check that they pass**

Run: `just test`
Expected: `5 passed, 0 failed`.

- [ ] **Step 8: Run the type-check**

Run: `just check`
Expected: `rank.tl` has no errors. The only errors are in `pgrace_commuter_compass.script.tl`, about
`util.tl` / `PgraceCommuterCompassUtil`, which Task 4 replaces. Any error that mentions `rank.tl` must be fixed now.

- [ ] **Step 9: Commit**

```bash
git add -A mod tests
git commit -m "feat: rank module with distance and percent formatting

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `rank.buildSections`

**Files:**
- Modify: `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/rank.tl`
- Test: `tests/rank_test.lua`

- [ ] **Step 1: Write the failing tests**

Append to `tests/rank_test.lua`:

```lua
local function counts(work, shop, usage, lines)
	return { work = work, shop = shop, usageCount = usage or (work + shop), linesUseCount = lines or 0 }
end

local NONE = counts(0, 0)

local function town(entity, name, distance, outbound, inbound)
	return { entity = entity, name = name, distance = distance, outbound = outbound or NONE, inbound = inbound or NONE }
end

local function entities(section)
	local result = {}
	for i, row in ipairs(section.rows) do
		result[i] = row.entity
	end
	return table.concat(result, ",")
end

t.test("buildSections: membership by direction, nearby = no commuters either way", function()
	local s = rank.buildSections({
		town(1, "OutOnly", 100, counts(2, 1)),
		town(2, "InOnly", 200, NONE, counts(0, 3)),
		town(3, "Both", 300, counts(1, 0), counts(1, 0)),
		town(4, "None", 400),
	}, 10, 3)
	t.eq(entities(s.outbound), "1,3")
	t.eq(entities(s.inbound), "2,3")
	t.eq(entities(s.nearby), "4")
	t.eq(s.countsKnown, true)
end)

t.test("buildSections: sorted by distance, ties by name, input unchanged", function()
	local towns = {
		town(1, "Far", 900, counts(1, 0)),
		town(2, "Zeta", 100, counts(1, 0)),
		town(3, "Alpha", 100, counts(1, 0)),
	}
	local s = rank.buildSections(towns, 10, 3)
	t.eq(entities(s.outbound), "3,2,1")
	t.eq(towns[1].entity, 1, "input left unchanged")
end)

t.test("buildSections: nearby keeps only the nearest few", function()
	local s = rank.buildSections({
		town(1, "a", 500), town(2, "b", 100), town(3, "c", 300), town(4, "d", 200), town(5, "e", 400),
	}, 10, 3)
	t.eq(entities(s.nearby), "2,4,3")
	t.eq(s.nearby.townCount, 5)
end)

t.test("buildSections: cap limits rows, totals count every town", function()
	local towns = {}
	for i = 1, 12 do
		towns[i] = town(i, "t" .. string.format("%02d", i), i * 100, counts(2, 1))
	end
	local s = rank.buildSections(towns, 10, 3)
	t.eq(#s.outbound.rows, 10)
	t.eq(s.outbound.rows[10].entity, 10)
	t.eq(s.outbound.townCount, 12)
	t.eq(s.outbound.commuterCount, 36)
end)

t.test("buildSections: rows carry the counts of their own direction", function()
	local s = rank.buildSections({
		town(1, "x", 100, counts(8, 4, 12, 3), counts(1, 2, 3, 0)),
	}, 10, 3)
	local out = s.outbound.rows[1]
	t.eq(out.work, 8)
	t.eq(out.shop, 4)
	t.eq(out.lineUsage, 0.25)
	t.eq(out.distance, 100)
	t.eq(out.name, "x")
	local inb = s.inbound.rows[1]
	t.eq(inb.work, 1)
	t.eq(inb.shop, 2)
	t.eq(inb.lineUsage, 0)
	t.eq(s.inbound.commuterCount, 3)
end)

t.test("buildSections: empty sections", function()
	local s = rank.buildSections({}, 10, 3)
	t.eq(#s.outbound.rows, 0)
	t.eq(s.outbound.townCount, 0)
	t.eq(s.outbound.commuterCount, 0)
	t.eq(#s.nearby.rows, 0)
	t.eq(s.countsKnown, true)
end)

t.test("buildSections: missing counts put every town in nearby", function()
	local s = rank.buildSections({
		{ entity = 1, name = "a", distance = 300 },
		{ entity = 2, name = "b", distance = 100 },
	}, 10, 3)
	t.eq(s.countsKnown, false)
	t.eq(#s.outbound.rows, 0)
	t.eq(#s.inbound.rows, 0)
	t.eq(entities(s.nearby), "2,1")
	t.eq(s.nearby.rows[1].lineUsage, nil)
	t.eq(s.nearby.rows[1].work, 0)
end)
```

- [ ] **Step 2: Run the tests and check that they fail**

Run: `just test`
Expected: the 7 new `buildSections` tests FAIL with "attempt to call a nil value (field 'buildSections')". The
5 earlier tests still pass.

- [ ] **Step 3: Write `buildSections`**

In `rank.tl`, insert this before `return rank`:

```teal
local type Counts = PgraceCommuterCompassRank.Counts
local type TownData = PgraceCommuterCompassRank.TownData
local type Row = PgraceCommuterCompassRank.Row
local type Section = PgraceCommuterCompassRank.Section

local function commutersOf(counts : Counts) : integer
	if counts == nil then
		return 0
	end
	return counts.work + counts.shop
end

local function byDistance(a : TownData, b : TownData) : boolean
	if a.distance ~= b.distance then
		return a.distance < b.distance
	end
	return a.name < b.name
end

local function toRow(town : TownData, counts : Counts) : Row
	return {
		entity = town.entity,
		name = town.name,
		distance = town.distance,
		work = counts ~= nil and counts.work or 0,
		shop = counts ~= nil and counts.shop or 0,
		lineUsage = rank.lineUsage(counts),
	}
end

-- `towns` is already sorted. Totals cover every town; rows stop at `limit`.
local function makeSection(towns : {TownData}, countsOf : function(TownData) : Counts, limit : integer) : Section
	local section : Section = { rows = {}, townCount = #towns, commuterCount = 0 }
	for i, town in ipairs(towns) do
		local counts = countsOf(town)
		section.commuterCount = section.commuterCount + commutersOf(counts)
		if i <= limit then
			section.rows[i] = toRow(town, counts)
		end
	end
	return section
end

local function outboundOf(town : TownData) : Counts
	return town.outbound
end

local function inboundOf(town : TownData) : Counts
	return town.inbound
end

function rank.buildSections(towns : {TownData}, cap : integer, nearbyCount : integer) : PgraceCommuterCompassRank.Sections
	local sorted : {TownData} = {}
	for i, town in ipairs(towns) do
		sorted[i] = town
	end
	table.sort(sorted, byDistance)

	local outbound : {TownData} = {}
	local inbound : {TownData} = {}
	local nearby : {TownData} = {}
	local countsKnown = true
	for _, town in ipairs(sorted) do
		if town.outbound == nil or town.inbound == nil then
			countsKnown = false
		end
		local goesOut = commutersOf(town.outbound) > 0
		local comesIn = commutersOf(town.inbound) > 0
		if goesOut then
			outbound[#outbound + 1] = town
		end
		if comesIn then
			inbound[#inbound + 1] = town
		end
		if not goesOut and not comesIn then
			nearby[#nearby + 1] = town
		end
	end

	return {
		outbound = makeSection(outbound, outboundOf, cap),
		inbound = makeSection(inbound, inboundOf, cap),
		nearby = makeSection(nearby, outboundOf, nearbyCount),
		countsKnown = countsKnown,
	}
end
```

- [ ] **Step 4: Run the tests and check that they pass**

Run: `just test`
Expected: `12 passed, 0 failed`.

- [ ] **Step 5: Run the type-check**

Run: `just check`
Expected: no errors in `rank.tl`. The only errors left are the known ones in the template script.

- [ ] **Step 6: Commit**

```bash
git add mod tests
git commit -m "feat: build outbound, inbound and nearby sections

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `commuters.tl`, the engine access

**Files:**
- Create: `mod/pgrace_commuter_compass/tealdef/gui/pgrace_commuter_compass/commuters.d.tl`
- Create: `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/commuters.tl`
- Modify: `mod/pgrace_commuter_compass/tealdef/pgrace_commuter_compass_def.d.tl`

This module has no unit tests, because every line touches `api.engine`. It is verified by the type-check now and in
game in Task 6.

- [ ] **Step 1: Write the declarations**

Create `mod/pgrace_commuter_compass/tealdef/gui/pgrace_commuter_compass/commuters.d.tl`:

```teal
-- Reads game state for the Commuters card. Verified in-game, not unit-tested.
global record PgraceCommuterCompassCommuters
	-- Bounding-box centre (x, y) at the box top (z), as the base windows compute flow endpoints; nil if unknown.
	getPosition3 : function(entity : Engine.Entity) : Vec3f
	-- False when the game no longer provides getSourceToDestinationCount; gather then returns towns without counts.
	hasCommuterData : function() : boolean
	-- Number of TOWN entities on the map.
	countTowns : function() : integer
	-- Every other town that has a position: name, straight-line distance and, when available, commuter counts in
	-- both directions. Unsorted.
	gather : function(town : Engine.Entity) : {PgraceCommuterCompassRank.TownData}
end
```

- [ ] **Step 2: Register it**

Replace the contents of `mod/pgrace_commuter_compass/tealdef/pgrace_commuter_compass_def.d.tl` with:

```teal
require "gui.pgrace_commuter_compass.rank"
require "gui.pgrace_commuter_compass.commuters"
```

- [ ] **Step 3: Write the module**

Create `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/commuters.tl`:

```teal
local rank = ug_require "pgrace_commuter_compass::/gui/pgrace_commuter_compass/rank.tl" as PgraceCommuterCompassRank

local commuters : PgraceCommuterCompassCommuters = {}

-- selectLandUse values of getSourceToDestinationCount, as the base town window passes them.
local LAND_USE_USAGE = 0
local LAND_USE_SHOP = 1
local LAND_USE_WORK = 2

local type Counts = PgraceCommuterCompassRank.Counts
local type TownData = PgraceCommuterCompassRank.TownData
local type CountMap = {Engine.Entity : UtilTown.DestinationUseCount}

local function getBoundingVolume(entity : Engine.Entity) : Engine.Component.BoundingVolume
	return api.engine.getComponent(entity, api.type.ComponentType.BOUNDING_VOLUME)
end

-- Centre of the bounding volume on the map plane, as the base town window computes it.
local function getPosition(entity : Engine.Entity) : number, number
	local bv = getBoundingVolume(entity)
	if bv == nil then
		return nil, nil
	end
	return 0.5 * (bv.bbox.min.x + bv.bbox.max.x), 0.5 * (bv.bbox.min.y + bv.bbox.max.y)
end

function commuters.getPosition3(entity : Engine.Entity) : Vec3f
	local bv = getBoundingVolume(entity)
	if bv == nil then
		return nil
	end
	return api.type.Vec3f.new(0.5 * (bv.bbox.min.x + bv.bbox.max.x), 0.5 * (bv.bbox.min.y + bv.bbox.max.y), bv.bbox.max.z)
end

local function getName(entity : Engine.Entity) : string
	local name = api.engine.util.getEntityName(entity)
	if name == nil or name == "" then
		return _("Unnamed")
	end
	return name
end

function commuters.hasCommuterData() : boolean
	local town = api.engine.util.town
	return town ~= nil and town.getSourceToDestinationCount ~= nil
end

function commuters.countTowns() : integer
	local count = 0
	api.engine.forEachEntityWithComponent(function(_entity : Engine.Entity)
		count = count + 1
	end, api.type.ComponentType.TOWN)
	return count
end

local function query(source : Engine.Entity, destinations : {Engine.Entity : boolean}, landUse : integer) : CountMap
	return api.engine.util.town.getSourceToDestinationCount(source, destinations, landUse) or {}
end

-- Counts for `destination` out of the three per-land-use answers; a missing entry means nobody.
local function countsFor(shop : CountMap, work : CountMap, usage : CountMap, destination : Engine.Entity) : Counts
	local s = shop[destination]
	local w = work[destination]
	local u = usage[destination]
	return {
		work = w ~= nil and w.count or 0,
		shop = s ~= nil and s.count or 0,
		usageCount = u ~= nil and u.count or 0,
		linesUseCount = u ~= nil and u.linesUseCount or 0,
	}
end

-- `source`'s residents in each destination, for all three land uses.
local function queryAll(source : Engine.Entity, destinations : {Engine.Entity : boolean}) : CountMap, CountMap, CountMap
	return query(source, destinations, LAND_USE_SHOP), query(source, destinations, LAND_USE_WORK), query(source, destinations, LAND_USE_USAGE)
end

function commuters.gather(town : Engine.Entity) : {TownData}
	local result : {TownData} = {}
	local sx, sy = getPosition(town)
	if sx == nil then
		return result
	end

	local others : {Engine.Entity} = {}
	api.engine.forEachEntityWithComponent(function(entity : Engine.Entity)
		if entity ~= town then
			others[#others + 1] = entity
		end
	end, api.type.ComponentType.TOWN)

	local withCounts = commuters.hasCommuterData()
	local outShop, outWork, outUsage : CountMap, CountMap, CountMap
	local toThisTown : {Engine.Entity : boolean} = {}
	if withCounts then
		local toOthers : {Engine.Entity : boolean} = {}
		for _, other in ipairs(others) do
			toOthers[other] = true
		end
		outShop, outWork, outUsage = queryAll(town, toOthers)
		toThisTown[town] = true
	end

	for _, other in ipairs(others) do
		local x, y = getPosition(other)
		if x ~= nil then
			local data : TownData = {
				entity = other,
				name = getName(other),
				distance = rank.planarDistance(sx, sy, x, y),
			}
			if withCounts then
				data.outbound = countsFor(outShop, outWork, outUsage, other)
				local inShop, inWork, inUsage = queryAll(other, toThisTown)
				data.inbound = countsFor(inShop, inWork, inUsage, town)
			end
			result[#result + 1] = data
		end
	end
	return result
end

return commuters
```

- [ ] **Step 4: Run the type-check**

Run: `just check`
Expected: no errors in `commuters.tl` or `rank.tl`. The template script still errors until Task 4.

If Teal rejects `api.engine.util.town ~= nil` or the `getSourceToDestinationCount ~= nil` comparison, cast before
comparing: `(api.engine.util.town as any) ~= nil`. If Teal rejects the
`local outShop, outWork, outUsage : CountMap, CountMap, CountMap` declaration, declare the three on separate lines,
each `: CountMap = nil`.

- [ ] **Step 5: Run the tests**

Run: `just test`
Expected: `12 passed, 0 failed`. Nothing changed here, so this just confirms nothing broke.

- [ ] **Step 6: Commit**

```bash
git add mod
git commit -m "feat: gather towns, distances and commuter counts both ways

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The town-window card with sections, rows and a flow arrow

**Files:**
- Delete: `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/industry_plugin.res.lua`
- Create: `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/town_plugin.res.lua`
- Replace: `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/pgrace_commuter_compass.script.tl`

- [ ] **Step 1: Swap the plugin registration**

```bash
git rm -q mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/industry_plugin.res.lua
```

Create `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/town_plugin.res.lua`:

```lua
function data()
	return {
		type = "react-plugin ::TownEowExtensionPoint",
		data = {
			filePath = "pgrace_commuter_compass::/gui/pgrace_commuter_compass/pgrace_commuter_compass.script@TownPlugin",
			condition = "pgrace_commuter_compass::/gui/pgrace_commuter_compass/pgrace_commuter_compass.script@hasOtherTowns",
			order = 45,
		}
	}
end
```

- [ ] **Step 2: Write the UI script**

Replace the whole of `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/pgrace_commuter_compass.script.tl`
with:

```teal
local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local content_card = ug_require "::/gui/main/content_card.tl" as ContentCard
local line_react_util = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl" as LineReactUtil
local selector_react_util = ug_require "::/gui/main/selector_react_util.tl" as SelectorReactUtil
local color_util = ug_require "::/gui/main/color_util.tl" as ColorUtil
local town_eow = ug_require "::/gui/entity_window/town/town_eow.script.tl" as TownEow
local commuters = ug_require "pgrace_commuter_compass::/gui/pgrace_commuter_compass/commuters.tl" as PgraceCommuterCompassCommuters
local rank = ug_require "pgrace_commuter_compass::/gui/pgrace_commuter_compass/rank.tl" as PgraceCommuterCompassRank

local layerColors = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/layers/layer_colors.gres")).data as LayerColors
local transparency = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/transparency.gres")).data as GResTransparency

local LOG_PREFIX = "[commuter_compass] "
local ROW_CAP = 10
local NEARBY_COUNT = 3
local FLOW_ACTION_KEY = "commuter_compass_flow"
local CAMERA_DISTANCE_FACTOR = 1.2
local CAMERA_MIN_DISTANCE = 500

-- The base town window's Destinations table icons (gui/entity_window/town/town.tl).
local WORK_ICON = "::/gui/entity_window/icons/building_industry.tga"
local SHOP_ICON = "::/gui/entity_window/icons/symbol_shopping_cart.tga"
local LINE_ICON = "::/gui/entity_window/icons/symbol_configure_line.tga"
local ARROW_ICON = "::/gui/entity_window/icons/symbol_arrow_up.tga"

local type Row = PgraceCommuterCompassRank.Row
local type Section = PgraceCommuterCompassRank.Section
local type Sections = PgraceCommuterCompassRank.Sections

local record ListParams
	entityId : Engine.Entity
	gameCtx : GameContext
end

-- The arrow shown on the map; nil when none is. Passengers travel `from` → `to`.
local record Selection
	from : Engine.Entity
	to : Engine.Entity
	-- Animated when some of these commuters ride the player's lines; faint and static otherwise.
	animated : boolean
end

local record FlowParams
	gameCtx : GameContext
	selection : Selection
end

-- The renderer API (gui/main/builtin.lua) has this, but it is missing from the type definitions.
-- The override takes precedence over the tool stack's active owner without replacing it, so clearing it with
-- `false` hands the map straight back to the town window's own action.
local record ActiveOwnerApi
	setActiveOwnerOverride : function(ReactRefWrap | boolean)
end

local record FlowCache
	key : string
	action : function() : TreeNodeId
end

local record ListState
	sections : Sections
	failed : boolean
end

local function computeState(townEntity : Engine.Entity) : ListState
	local ok, resultOrError = pcall(function() : Sections
		local towns = commuters.gather(townEntity)
		return rank.buildSections(towns, ROW_CAP, NEARBY_COUNT)
	end)
	if ok then
		return { sections = resultOrError as Sections, failed = false }
	end
	debugPrint(LOG_PREFIX .. "error for town " .. tostring(townEntity) .. ": " .. tostring(resultOrError))
	return { sections = nil, failed = true }
end

local function makeHint(text : string) : TreeNodeId
	return builtin.TextView{ meta = { class = "font-scale-annotation" }, text = text }
end

-- Styled like Cargo Compass's arrows: the base cargo-flow colours, with the passenger icon.
local function makeFlowLayerConfig(from : Vec3f, to : Vec3f, animated : boolean) : LayerConfig
	local colors = layerColors.CargoFlow.Consumers3D
	local flow = api.type.LayerConfig.CargoFlowRenderableConfig.FlowData.new()
	flow.from = from
	flow.to = to
	flow.speed = animated and 40.0 or 0.0
	flow.arrowColors = animated
		and color_util.toArray4(colors.Actual)
		or color_util.toArray4WithTransparency(colors.Potential, transparency.VeryLow)
	flow.cargoIconAlpha = animated and 1.0 or 0.6
	flow.cargoTypes = { api.res.cargoTypeRep.getPassengerCargoTypeId() }
	local cargoFlow = api.type.LayerConfig.CargoFlowRenderableConfig.new()
	cargoFlow.flowData = { flow }
	local layerConfig = api.type.LayerConfig.new()
	layerConfig.cargoFlowRenderableConfig = cargoFlow
	return layerConfig
end

local function frameCamera(from : Vec3f, to : Vec3f)
	local gap = rank.planarDistance(from.x, from.y, to.x, to.y)
	local distance = math.max(CAMERA_MIN_DISTANCE, gap * CAMERA_DISTANCE_FACTOR)
	local midpoint = api.type.Vec3f.new(0.5 * (from.x + to.x), 0.5 * (from.y + to.y), 0.5 * (from.z + to.z))
	api.gui.camera.focusPosition(midpoint, distance)
end

-- Binds a map action that draws one arrow and makes it the renderer's active owner override.
-- Unmounting clears the override and unbinds the action, handing the map back to the town window.
local FlowAction = react.RegisterRecipe("PgraceCommuterCompassFlowAction", function(params : FlowParams) : TreeNodeId
	local selection = params.selection
	local key = tostring(selection.from) .. ">" .. tostring(selection.to) .. (selection.animated and "+" or "-")
	local cacheRef : ReactRefT<FlowCache> = react.useRef(nil)
	local changed = cacheRef:get() == nil or cacheRef:get().key ~= key
	if changed then
		local from = commuters.getPosition3(selection.from)
		local to = commuters.getPosition3(selection.to)
		local action : function() : TreeNodeId = nil
		if from ~= nil and to ~= nil then
			action = selector_react_util.makeDefaultSelectorAction(params.gameCtx, makeFlowLayerConfig(from, to, selection.animated))
			frameCamera(from, to)
		else
			debugPrint(LOG_PREFIX .. "flow: no position for " .. key)
		end
		cacheRef:set({ key = key, action = action })
	end

	local selfRef = react.useAction(params.gameCtx.rendererComponent, cacheRef:get().action, FLOW_ACTION_KEY)

	local function setOverride(owner : ReactRefWrap | boolean) : boolean
		if params.gameCtx.rendererComponent:hasExpired() then
			return false
		end
		local rc = params.gameCtx.rendererComponent:get()
		if rc == nil or not rc:getIdentity() then
			return false
		end
		-- Not part of the documented API: degrade to "no arrow" rather than erroring if a game update removes it.
		local rcApi = rc:getApi() as any as ActiveOwnerApi
		if rcApi.setActiveOwnerOverride == nil then
			return false
		end
		rcApi.setActiveOwnerOverride(owner)
		return true
	end

	local function activate()
		setOverride(selfRef)
	end

	react.onMount(activate)
	if changed and cacheRef:get().action ~= nil and selfRef:get() ~= nil then
		activate()
	end
	react.onUnmount(function()
		setOverride(false)
	end)

	return builtin.BoxLayout{ children = {} }
end)

local function makeStat(icon : string, text : string, tooltip : string) : TreeNodeId
	return builtin.BoxLayout{
		meta = { tooltip = tooltip },
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			builtin.ImageView{ path = icon },
			builtin.TextView{ text = text },
		},
	}
end

-- One row: locate, arrow toggle, name (opens the town's window), distance, then the counts when `showCounts`.
local function makeRow(row : Row, flow : Selection, showCounts : boolean, selectionState : ReactStateT<Selection>) : TreeNodeId
	local current = selectionState:old()
	local isSelected = current ~= nil and current.from == flow.from and current.to == flow.to
	local children : {TreeNodeId} = {
		line_react_util.LocateButton{ entity = row.entity },
		builtin.ToggleButton{
			meta = { tooltip = _("Show on the map") },
			content = builtin.ImageView{
				path = ARROW_ICON,
				scaling = builtin.type.ImageViewScaling.AutoFit,
			},
			value = isSelected and 1 or 0,
			onValueChange = function(value : integer)
				if value == 1 then
					selectionState:set(flow)
				else
					selectionState:set(nil)
				end
			end,
		},
		line_react_util.makeEntityWindowButton(row.name, row.entity),
		builtin.TextView{ text = rank.formatDistance(row.distance) },
	}
	if showCounts then
		children[#children + 1] = makeStat(WORK_ICON, tostring(row.work), _("Work"))
		children[#children + 1] = makeStat(SHOP_ICON, tostring(row.shop), _("Shop"))
		children[#children + 1] = makeStat(LINE_ICON, rank.formatPercent(row.lineUsage), _("Line usage"))
	end
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = children,
	}
end

-- Expand/collapse state of one section, and how to flip it.
local record Fold
	expanded : boolean
	toggle : function()
end

local record SectionSpec
	title : string
	section : Section
	emptyText : string
	showCounts : boolean
	-- The arrow a row's toggle selects.
	flowOf : function(Row) : Selection
end

local function plural(count : integer, one : string, many : string) : string
	return tostring(count) .. " " .. (count == 1 and one or many)
end

-- Clickable header with the game's combobox arrows (as in collapsible_checkbox_list).
local function makeSectionHeader(title : string, fold : Fold) : TreeNodeId
	return builtin.Button{
		content = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				builtin.ImageView{
					path = fold.expanded and "::/gui/builtin/combobox/arrow_down.tga" or "::/gui/builtin/combobox/arrow_right.tga",
				},
				builtin.TextView{ text = title },
			},
		},
		onClick = fold.toggle,
	}
end

local function makeSection(spec : SectionSpec, fold : Fold, selectionState : ReactStateT<Selection>) : TreeNodeId
	local header = makeSectionHeader(spec.title, fold)
	if not fold.expanded then
		return header
	end
	local children : {TreeNodeId} = { header }
	if #spec.section.rows == 0 then
		children[#children + 1] = makeHint(spec.emptyText)
	else
		for _, row in ipairs(spec.section.rows) do
			children[#children + 1] = makeRow(row, spec.flowOf(row), spec.showCounts, selectionState)
		end
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
end

local function commuterTitle(label : string, section : Section) : string
	return label
		.. " · " .. plural(section.townCount, _("town"), _("towns"))
		.. " · " .. plural(section.commuterCount, _("commuter"), _("commuters"))
end

local function usesLines(row : Row) : boolean
	return (row.lineUsage or 0) > 0
end

-- All sections live in one list, so one selection state allows at most one arrow per window.
local CommuterList = react.RegisterRecipe("PgraceCommuterCompassList", function(params : ListParams) : TreeNodeId
	local state = react.useStateLazy(function() : ListState
		return computeState(params.entityId)
	end)
	local current = state:old()
	local selectionState = react.useStateLazy(function() : Selection
		return nil
	end)
	-- Sections the player opened; every section starts collapsed.
	local foldState = react.useStateLazy(function() : {string : boolean}
		return {}
	end)
	local function makeFold(key : string) : Fold
		local expanded = foldState:old()[key] == true
		return {
			expanded = expanded,
			toggle = function()
				local next : {string : boolean} = {}
				for k, v in pairs(foldState:old()) do
					next[k] = v
				end
				next[key] = not expanded
				foldState:set(next)
			end,
		}
	end

	local children : {TreeNodeId} = {}
	local function add(node : TreeNodeId)
		children[#children + 1] = node
	end
	local here = params.entityId

	if current.failed then
		add(makeHint(_("Commuter Compass: error (see log)")))
	else
		local sections = current.sections
		local noTowns = sections.outbound.townCount == 0 and sections.inbound.townCount == 0 and sections.nearby.townCount == 0
		if noTowns then
			add(makeHint(_("No other towns on this map")))
		else
			if sections.countsKnown then
				add(makeSection({
					title = commuterTitle(_("Outbound"), sections.outbound),
					section = sections.outbound,
					emptyText = _("No commuters leave this town."),
					showCounts = true,
					flowOf = function(row : Row) : Selection
						return { from = here, to = row.entity, animated = usesLines(row) }
					end,
				}, makeFold("out"), selectionState))
				add(makeSection({
					title = commuterTitle(_("Inbound"), sections.inbound),
					section = sections.inbound,
					emptyText = _("No commuters arrive from other towns."),
					showCounts = true,
					flowOf = function(row : Row) : Selection
						return { from = row.entity, to = here, animated = usesLines(row) }
					end,
				}, makeFold("in"), selectionState))
			else
				add(makeHint(_("Commuter data unavailable")))
			end
			if #sections.nearby.rows > 0 then
				add(makeSection({
					title = _("Nearby, no commuters") .. " · " .. plural(#sections.nearby.rows, _("town"), _("towns")),
					section = sections.nearby,
					emptyText = "",
					showCounts = false,
					flowOf = function(row : Row) : Selection
						return { from = here, to = row.entity, animated = false }
					end,
				}, makeFold("nearby"), selectionState))
			end
		end
	end
	if selectionState:old() ~= nil then
		add(FlowAction{ gameCtx = params.gameCtx, selection = selectionState:old() })
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
end)

local TownPlugin = react.RegisterPluginRecipe(town_eow.TownEowExtensionPoint, "PgraceCommuterCompassTownPlugin", function(params : TownEow.TownWidgetPluginParams) : TreeNodeId
	return builtin.BoxLayout{
		child = content_card.ContentCard{
			title = _("Commuters"),
			initialCalloutTextPermanent = "",
			recipeAndParamPermanent = content_card.makeRecipeAndParam(CommuterList, { entityId = params.entityId, gameCtx = params.gameCtx } as ListParams),
			gameCtx = params.gameCtx,
			showOnRightSide = params.showCalloutOnRightSide,
		},
	}
end)

-- Hides the card on a single-town map. On error the card shows, so it can report the problem.
local function hasOtherTowns(_params : TownEow.TownWidgetPluginParams) : boolean
	local ok, countOrError = pcall(commuters.countTowns)
	return not ok or (countOrError as integer) > 1
end

debugPrint(LOG_PREFIX .. "script loaded")

return {
	TownPlugin = TownPlugin,
	hasOtherTowns = hasOtherTowns,
}
```

- [ ] **Step 3: Run the type-check**

Run: `just check`
Expected: no errors in any file.

Likely fixes if it complains (fix the cause; don't silence it with `as any`):
- **`meta = { tooltip = ... }` rejected on `builtin.BoxLayout`:** move the tooltip into each child `TextView`'s
  `meta` instead.
- **Function-literal fields rejected in a `SectionSpec` table literal:** declare the spec as
  `local spec : SectionSpec = {...}` first, then pass it.
- **A `local type` alias not accepted:** use the full `PgraceCommuterCompassRank.X` names.

- [ ] **Step 4: Run the full verification**

Run: `just verify`
Expected: the type-check is clean, `12 passed, 0 failed`, and the release check reports OK. The "no cover image"
warning is expected for now.

Confirm that `_content.json` now lists `town_plugin.res.lua`, `commuters.tl`, `commuters.d.tl`, `rank.tl` and
`rank.d.tl`, and no longer lists `util.*` or `industry_plugin.res.lua`:

Run: `cat mod/pgrace_commuter_compass/_content.json`

- [ ] **Step 5: Commit**

```bash
git add -A mod
git commit -m "feat: Commuters card in the town window with one flow arrow

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Spike probes and the first in-game test (user checkpoint)

**Files:**
- Modify: `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/pgrace_commuter_compass.script.tl`
  (`computeState`)

- [ ] **Step 1: Add the timing and count probes**

In `pgrace_commuter_compass.script.tl`, replace the body of `computeState`'s pcall'd function:

```teal
	local ok, resultOrError = pcall(function() : Sections
		local towns = commuters.gather(townEntity)
		return rank.buildSections(towns, ROW_CAP, NEARBY_COUNT)
	end)
```

with:

```teal
	local ok, resultOrError = pcall(function() : Sections
		local started = os.clock() -- PROBE (remove before release)
		local towns = commuters.gather(townEntity)
		-- PROBE (remove before release)
		debugPrint(LOG_PREFIX .. string.format("probe gather: %s, %d other towns, %.1f ms", api.engine.util.getEntityName(townEntity), #towns, (os.clock() - started) * 1000))
		for _, other in ipairs(towns) do
			if other.outbound ~= nil and other.inbound ~= nil then
				local o = other.outbound
				local i = other.inbound
				debugPrint(LOG_PREFIX .. string.format("probe %s: out work %d shop %d usage %d lines %d | in work %d shop %d usage %d lines %d",
					other.name, o.work, o.shop, o.usageCount, o.linesUseCount, i.work, i.shop, i.usageCount, i.linesUseCount))
			end
		end
		-- END PROBE
		return rank.buildSections(towns, ROW_CAP, NEARBY_COUNT)
	end)
```

If `os` turns out not to be available in the game's GUI Lua, the pcall fails and the card shows the error hint. The
log then says so, and the fix is to drop the timing.

- [ ] **Step 2: Verify and install**

Run: `just verify && just install`
Expected: verify passes, and `install` reports the symlink in the staging area.

- [ ] **Step 3: Commit**

```bash
git add mod
git commit -m "debug: probe commuter gather timing and counts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 4: Ask the user for the in-game test. STOP and wait for the reply.**

Send the user this checklist:

> Please start TF3 and load your **largest** save with **Commuter Compass** enabled. Then:
> 1. Open a big town's window. Is a **Commuters** card there, after the charts? Are all its sections collapsed?
> 2. Expand Outbound. Switch the town window to the **Supplies** tab and set its Statistics table to Destinations
>    (the person icon). Do the Work and Shop counts and the Line Usage % match ours for 2–3 towns?
> 3. Expand Inbound. Open one of the towns listed there. Is the first town in *its* Outbound, with the same counts?
> 4. Expand Nearby. Are there 3 towns, and do they look like the nearest unconnected ones?
> 5. Click an arrow toggle on an Outbound row:
>    - Is there one arrow from this town to that one?
>    - Is the camera framing both towns?
>    - Is there a passenger icon on the arrow?
>    - Is it animated when Line usage is above 0%?
>    Then try an Inbound row (the arrow should point here) and a Nearby row (faint).
> 6. Toggle the arrow off. Is the town's normal overlay back? Show an arrow again and close the window. Is the map
>    normal?
> 7. Do the work, shop and line icons look the right size? A screenshot helps.
> 8. Open 2–3 more towns, then tell me you're done.

- [ ] **Step 5: Read the probe output**

```bash
grep -h "\[commuter_compass\]" ~/.local/share/Steam/userdata/*/3493540/local/crash_dump/stdout.txt | tail -60
```

Record these in the spec under a new "Findings (spike)" section:

- the gather time in ms against the town count;
- whether `usageCount` equals work + shop, or is something else;
- whether the counts matched the base table.

- [ ] **Step 6: Decision gate on timing**

- **If every `probe gather` time is ≤ 50 ms:** carry on to Task 6.
- **If any is above 50 ms:** stop. Report the numbers to the user and propose computing Inbound only when its
  section is first expanded, as the spec's fallback. That change gets its own short plan before Task 6.

  Visual problems from steps 5–7 of the checklist (icon sizes, arrow look) are fixed here with small commits
  (`fix: ...`). Re-run `just verify` after each fix, and ask the user to re-check only the affected items.

---

### Task 6: Remove the probes

**Files:**
- Modify: `mod/pgrace_commuter_compass/content/gui/pgrace_commuter_compass/pgrace_commuter_compass.script.tl`

- [ ] **Step 1: Restore `computeState`'s pcall'd function to its probe-free form**

Replace everything from `local started = os.clock() -- PROBE (remove before release)` through `-- END PROBE` so the
function reads exactly:

```teal
	local ok, resultOrError = pcall(function() : Sections
		local towns = commuters.gather(townEntity)
		return rank.buildSections(towns, ROW_CAP, NEARBY_COUNT)
	end)
```

- [ ] **Step 2: Confirm that no probes remain**

Run: `grep -rn "PROBE\|probe" mod/ || echo "no probes"`
Expected: `no probes`.

- [ ] **Step 3: Verify and commit**

Run: `just verify`
Expected: everything passes.

```bash
git add mod docs
git commit -m "chore: remove spike probes; record spike findings in the spec

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Release text (modinfo, description, README)

**Files:**
- Modify: `mod/pgrace_commuter_compass/_metadata/modinfo.json`
- Modify: `mod/pgrace_commuter_compass/_metadata/description.html`
- Modify: `README.md`

- [ ] **Step 1: Write `modinfo.json`**

Replace the contents of `mod/pgrace_commuter_compass/_metadata/modinfo.json` with:

```json
{
    "authors": [
        {
            "name": "Peter Grace",
            "role": "CREATOR"
        }
    ],
    "name": "Commuter Compass",
    "summary": "Town window card: which towns your commuters travel to and from, how far, and how many ride your lines.",
    "description": "Adds a Commuters card to the town window. Outbound lists the towns where this town's residents work or shop; Inbound lists the towns whose residents work or shop here. Each row shows the straight-line distance, work and shop counts, and how many of those commuters use your lines. A third list shows the three nearest towns with no commuters either way. Every row can show one arrow on the map. A sibling of Cargo Compass. Cosmetic: achievements stay enabled.",
    "tags": [
        "Script Mod"
    ],
    "url": ""
}
```

Check that the summary is at most 100 characters:

Run: `python3 -c "import json; s=json.load(open('mod/pgrace_commuter_compass/_metadata/modinfo.json'))['summary']; print(len(s))"`
Expected: a number ≤ 100. If it's over, shorten it to: `"Town window card: towns your commuters travel to
and from, with distances and line usage."`

- [ ] **Step 2: Write `description.html`**

Replace the contents of `mod/pgrace_commuter_compass/_metadata/description.html` with:

```html
<h2>Commuter Compass</h2>
<p>Where do your towns' commuters go, how far is it, and are they riding your lines? Commuter Compass adds a <b>Commuters</b> card to every town window. It's a sibling of Cargo Compass.</p>
<hr>
<h3>Features</h3>
<ul>
<li><b>Outbound:</b> the towns where this town's residents work or shop, nearest first.</li>
<li><b>Inbound:</b> the towns whose residents work or shop here.</li>
<li>Each row shows the straight-line distance, the work and shop counts, and the share of those commuters who use your lines.</li>
<li><b>Nearby, no commuters:</b> the three nearest towns with no commuters either way. These are good candidates for a new connection.</li>
<li><b>Map arrow:</b> show one arrow between the two towns, framed by the camera. It's animated when some commuters already ride your lines, and faint when none do.</li>
<li>Each row has the game's Locate button, and clicking a town's name opens its window.</li>
</ul>
<h3>How to use</h3>
<ol>
<li>Open any town's window.</li>
<li>Expand Outbound, Inbound or Nearby in the Commuters card.</li>
<li>Click a row's arrow button to show it on the map. Click it again, or close the window, to hide it.</li>
</ol>
<h3>Good to know</h3>
<ul>
<li>The counts are the residents' current work and shopping destinations, the same numbers as the game's Destinations table on the Supplies tab. They are not trips per year.</li>
<li>Distances are straight-line, not along roads or tracks.</li>
<li>The data is read when the window opens. Reopen the window to refresh it.</li>
<li>This is a cosmetic mod. It doesn't change the simulation, so achievements stay available, and you can add it to or remove it from existing saves.</li>
</ul>
```

- [ ] **Step 3: Rewrite the README**

Replace the contents of `README.md` with:

````markdown
# Commuter Compass (Transport Fever 3 mod)

Adds a **Commuters** card to the town window. **Outbound** lists the towns where this town's residents work or
shop. **Inbound** lists the towns whose residents work or shop here. Each row shows the straight-line distance, the
work and shop counts, and the line usage % (the share of those commuters riding the player's lines). **Nearby, no
commuters** lists the three nearest towns with no commuters either way. Lists are sorted by distance, capped at 10
rows, and start collapsed.

Each row has the game's Locate button, a clickable name that opens the town's window, and an arrow toggle. The
toggle shows one passenger-flow arrow on the map and frames both towns. The arrow is animated when line usage is
above 0, and faint otherwise.

The counts come from `api.engine.util.town.getSourceToDestinationCount`, the same source as the base game's
Destinations table on the Supplies tab. They are a snapshot of residents' destinations, not trips per year.

- Mod ID: `pgrace_commuter_compass`
- Cosmetic: yes. It doesn't affect the simulation, so achievements stay enabled.
- Design: [docs/superpowers/specs/2026-10-09-commuter-compass-design.md](docs/superpowers/specs/2026-10-09-commuter-compass-design.md)
- Sibling: Cargo Compass (`../closest_consumer`)

Agent and modding notes for all mods live in `../AGENTS.md`.

## Layout

```
mod/pgrace_commuter_compass/          # the mod folder TF3 loads
├── mod.json, _metadata/              # modinfo.json, description.html, screenshots
├── tealdef/                          # Teal type definitions (canonical; build.py mirrors them into content/)
└── content/gui/pgrace_commuter_compass/
    ├── town_plugin.res.lua           # registers the card in the town window
    ├── pgrace_commuter_compass.script.tl  # UI and the map arrow
    ├── commuters.tl                  # reads game state: towns, positions, commuter counts
    └── rank.tl                       # pure: sections, sorting, formatting (unit-tested)
tools/                                # type check, tests, install, release checks
tests/                                # unit tests for rank.tl
```

## Dev loop

```bash
just check      # type-check against the game's API definitions
just test       # unit tests
just verify     # check + test + release-check
just install    # symlink into TF3's staging area (just install-copy to copy)
```

Restart TF3 after code changes. The log is
`~/.local/share/Steam/userdata/*/3493540/local/crash_dump/stdout.txt`; our lines start with `[commuter_compass]`.

## In-game checklist

- [ ] A town window shows the **Commuters** card after the charts, with every section collapsed.
- [ ] The Outbound work and shop counts and the line usage % match the base Destinations table (Supplies tab).
- [ ] Town B in A's Outbound lists A in its Inbound, with the same counts.
- [ ] Nearby lists the 3 nearest towns with no commuters, sorted by distance.
- [ ] Locate moves the camera, and the name opens that town's window.
- [ ] The arrow is animated when line usage is above 0, and faint at 0% and on Nearby rows.
- [ ] Outbound arrows point away from the town, and Inbound arrows point towards it.
- [ ] Only one arrow shows at a time. Toggling it off, or closing the window, restores the town's normal overlay.
- [ ] Map clicks still select things while an arrow is shown.
- [ ] Section headers show the correct totals.

## Releasing

1. Screenshots go in `mod/pgrace_commuter_compass/_metadata/`. `0.png` is the cover, and `1.png`, … are the gallery
   (1920x1080, at most 8 MB).
2. For an update: `just bump` and commit.
3. `just release` (revision check + verify).
4. Upload from **Mod Hub > My Mods** in TF3.
5. Commit what the upload changed (the first one creates `_metadata/mod.io_fileid.txt`), then `just mark-uploaded`
   and push `main`.

## Known limitations

- Towns only. Industries and the HQ as work destinations (shown in the base table) are ignored.
- No road or rail distance, and no travel times. The engine doesn't expose them to mods.
- If you pin the window while an arrow is showing and then open another window, our arrow keeps the map until you
  toggle it off or close the pinned window. This is the same as in Cargo Compass.
````

- [ ] **Step 4: Verify and commit**

Run: `just verify`
Expected: everything passes. The only warning is "no cover image".

```bash
git add README.md mod/pgrace_commuter_compass/_metadata/modinfo.json mod/pgrace_commuter_compass/_metadata/description.html
git commit -m "docs: mod description, summary and README

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Final in-game check and merge (user checkpoint)

- [ ] **Step 1: Ask the user for the final in-game pass. STOP and wait for the reply.**

> The probes are gone and the text is done. Please restart TF3 and run through the **In-game checklist** in
> `README.md`. Tell me which items fail, if any.

- [ ] **Step 2: Fix any failures**

Fix each failure with its own `fix:` commit and `just verify`, then ask the user to re-check those items.

- [ ] **Step 3: Merge to `main` locally** (the user's process: feature branch → in-game test → local merge)

Use superpowers:finishing-a-development-branch. Expect the user to choose a local merge. **Do not push** unless
asked. Screenshots and the first upload come later, from the user, through the README's Releasing steps.
