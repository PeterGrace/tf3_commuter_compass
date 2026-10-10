# Waiting Passengers (station card) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** add a "Waiting passengers" card to the station window. It lists the people waiting at the station, grouped by
final destination (town or industry), with the line most of them wait for, a Refresh button and the existing map arrow.

**Architecture:** the town card's layering:
- `waiting.tl` (new) reads game state: line stops, people, targets, positions;
- `rank.tl` gets a pure, unit-tested `groupWaiting` and `formatLineLabel`;
- the UI script gets a second plugin, `StationPlugin`, sharing `FlowAction` and `frameCamera` with the town card.

The first in-game run is a spike with probes, which pins down what `SIM_PERSON.targetOrAtEntity` actually is.

**Tech Stack:** TF3 modding in Teal 0.24.8, type-checked against the game's tealdefs (`just check`). Plain-Lua tests
(`just test`). In-game verification is done by the user.

**Spec:** `docs/superpowers/specs/2026-10-09-station-waiting-design.md`

**Paths:** `M` = `mod/pgrace_commuter_compass`, `C` = `$M/content/gui/pgrace_commuter_compass`,
`T` = `$M/tealdef/gui/pgrace_commuter_compass`. `.d.tl` files are edited in `T`; `just check` mirrors them into `C`.

---

## File structure

| File | Change | Responsibility |
| --- | --- | --- |
| `T/rank.d.tl` | modify | Add types `Waiter`, `LineCount`, `WaitingRow`, `WaitingTable`, `WaitingInfo`, and functions `groupWaiting`, `formatLineLabel`. |
| `C/rank.tl` | modify | Implement them (pure). |
| `tests/rank_test.lua` | modify | Tests for both. |
| `T/waiting.d.tl` | create | `PgraceCommuterCompassWaiting` type. |
| `C/waiting.tl` | create | Line stops at a station group, the waiting people, target → destination, positions, `count`. |
| `M/tealdef/pgrace_commuter_compass_def.d.tl` | modify | `require "gui.pgrace_commuter_compass.waiting"`. |
| `C/station_plugin.res.lua` | create | Registers the card on `::StationGroupEowExtensionPoint`. |
| `C/pgrace_commuter_compass.script.tl` | modify | `FlowAction` positions via `waiting.positionOf`; `WaitingList`, cells, `StationPlugin`, `hasPassengerLines`. |
| `README.md`, `$M/_metadata/*` | modify | Docs and release text. |

---

### Task 1: Branch

- [ ] **Step 1:** `git switch -c feat/station-waiting`.
- [ ] **Step 2:** `just verify`. Expected: 0 errors, 13 passed, release check OK.

### Task 2: `groupWaiting`: types and failing tests

**Files:** modify `T/rank.d.tl` and `tests/rank_test.lua`.

- [ ] **Step 1: Add the types** to `T/rank.d.tl`, before the function list (after `record Sections ... end`):

```teal
	-- One person waiting at the station, as waiting.tl reads them.
	record Waiter
		-- The line the person is waiting for.
		line : Engine.Entity
		-- Their final destination (a town or an industry); nil when the target couldn't be placed.
		destination : Engine.Entity
	end

	record LineCount
		line : Engine.Entity
		name : string
		count : integer
	end

	record WaitingRow
		-- nil for the "Unknown" row.
		destination : Engine.Entity
		name : string
		-- Metres from the station; nil when unknown.
		distance : number
		waiting : integer
		-- Every line with people for this destination, by count (largest first), ties by name.
		lines : {LineCount}
	end

	record WaitingTable
		-- By waiting (largest first), ties by name; the Unknown row, if any, last.
		rows : {WaitingRow}
		totalWaiting : integer
		-- Rows except Unknown.
		destinationCount : integer
	end

	-- Names and distances for groupWaiting, looked up by waiting.tl.
	record WaitingInfo
		destinationName : {Engine.Entity : string}
		destinationDistance : {Engine.Entity : number}
		lineName : {Engine.Entity : string}
		-- Label of the row for waiters without a destination.
		unknownName : string
	end
```

Then add to the function list, after `formatPercent`:

```teal
	-- Groups waiters per destination; see WaitingTable for the order.
	groupWaiting : function(waiters : {Waiter}, info : WaitingInfo) : WaitingTable
	-- "Red Line", or "Red Line +2" when two other lines carry people too; "" without lines.
	formatLineLabel : function(row : WaitingRow) : string
```

- [ ] **Step 2: Append the tests** to `tests/rank_test.lua`:

```lua
local function info()
	return {
		destinationName = { [10] = "Country Club", [11] = "Wenatchee", [12] = "Coal mine", [13] = "Abbey" },
		destinationDistance = { [10] = 6100, [11] = 4400, [12] = 2900, [13] = 1000 },
		lineName = { [1] = "Red Line", [2] = "Bus 4", [3] = "Bus 12" },
		unknownName = "Unknown",
	}
end

local function waiters(spec)
	-- spec: { {line, destination, count}, ... }; destination false = unknown
	local list = {}
	for _, s in ipairs(spec) do
		for _ = 1, s[3] do
			list[#list + 1] = { line = s[1], destination = s[2] or nil }
		end
	end
	return list
end

local function names(tbl)
	local out = {}
	for i, row in ipairs(tbl.rows) do
		out[i] = row.name .. "=" .. row.waiting
	end
	return table.concat(out, ",")
end

t.test("groupWaiting: one row per destination, sorted by waiting then name", function()
	local tbl = rank.groupWaiting(waiters({ { 1, 10, 5 }, { 3, 12, 2 }, { 1, 11, 2 }, { 2, 10, 1 } }), info())
	t.eq(names(tbl), "Country Club=6,Coal mine=2,Wenatchee=2")
	t.eq(tbl.totalWaiting, 10)
	t.eq(tbl.destinationCount, 3)
	t.eq(tbl.rows[1].distance, 6100)
	t.eq(tbl.rows[1].destination, 10)
end)

t.test("groupWaiting: lines per row by count, ties by name, counts add up", function()
	local tbl = rank.groupWaiting(waiters({ { 1, 10, 3 }, { 2, 10, 5 }, { 3, 10, 3 } }), info())
	local row = tbl.rows[1]
	t.eq(#row.lines, 3)
	t.eq(row.lines[1].name, "Bus 4")
	t.eq(row.lines[1].count, 5)
	t.eq(row.lines[2].name, "Bus 12")
	t.eq(row.lines[3].name, "Red Line")
	t.eq(row.lines[1].count + row.lines[2].count + row.lines[3].count, row.waiting)
end)

t.test("groupWaiting: unknown destinations are one row, last, not a destination", function()
	local tbl = rank.groupWaiting(waiters({ { 1, false, 9 }, { 1, 13, 1 } }), info())
	t.eq(names(tbl), "Abbey=1,Unknown=9")
	t.eq(tbl.rows[2].destination, nil)
	t.eq(tbl.rows[2].distance, nil)
	t.eq(tbl.totalWaiting, 10)
	t.eq(tbl.destinationCount, 1)
end)

t.test("groupWaiting: empty station", function()
	local tbl = rank.groupWaiting({}, info())
	t.eq(#tbl.rows, 0)
	t.eq(tbl.totalWaiting, 0)
	t.eq(tbl.destinationCount, 0)
end)

t.test("groupWaiting: missing names fall back to the entity id", function()
	local tbl = rank.groupWaiting(waiters({ { 7, 99, 1 } }), info())
	t.eq(tbl.rows[1].name, "99")
	t.eq(tbl.rows[1].lines[1].name, "7")
end)

t.test("formatLineLabel: top line, plus the number of other lines", function()
	t.eq(rank.formatLineLabel({ lines = {} }), "")
	t.eq(rank.formatLineLabel({ lines = { { name = "Red Line", count = 5 } } }), "Red Line")
	t.eq(rank.formatLineLabel({ lines = { { name = "Red Line", count = 5 }, { name = "Bus 4", count = 1 }, { name = "Bus 12", count = 1 } } }), "Red Line +2")
end)
```

- [ ] **Step 3:** `just test`. Expected: the new tests FAIL with "attempt to call a nil value (field 'groupWaiting')", and the old 13 pass.

### Task 3: `groupWaiting` and `formatLineLabel` implementation

**Files:** modify `C/rank.tl`, before `return rank`.

- [ ] **Step 1: Implement:**

```teal
local type Waiter = PgraceCommuterCompassRank.Waiter
local type LineCount = PgraceCommuterCompassRank.LineCount
local type WaitingRow = PgraceCommuterCompassRank.WaitingRow

local function byCountThenName(a : LineCount, b : LineCount) : boolean
	if a.count ~= b.count then
		return a.count > b.count
	end
	return a.name < b.name
end

local function byWaitingThenName(a : WaitingRow, b : WaitingRow) : boolean
	if a.waiting ~= b.waiting then
		return a.waiting > b.waiting
	end
	return a.name < b.name
end

-- One row out of a {line: count} bucket.
local function waitingRow(destination : Engine.Entity, name : string, distance : number, bucket : {Engine.Entity : integer},
		lineName : {Engine.Entity : string}) : WaitingRow
	local row : WaitingRow = { destination = destination, name = name, distance = distance, waiting = 0, lines = {} }
	for line, count in pairs(bucket) do
		row.lines[#row.lines + 1] = { line = line, name = lineName[line] or tostring(line), count = count }
		row.waiting = row.waiting + count
	end
	table.sort(row.lines, byCountThenName)
	return row
end

function rank.groupWaiting(waiters : {Waiter}, info : PgraceCommuterCompassRank.WaitingInfo) : PgraceCommuterCompassRank.WaitingTable
	local buckets : {Engine.Entity : {Engine.Entity : integer}} = {}
	local unknown : {Engine.Entity : integer} = nil
	for _, waiter in ipairs(waiters) do
		local bucket : {Engine.Entity : integer}
		if waiter.destination == nil then
			unknown = unknown or {}
			bucket = unknown
		else
			bucket = buckets[waiter.destination]
			if bucket == nil then
				bucket = {}
				buckets[waiter.destination] = bucket
			end
		end
		bucket[waiter.line] = (bucket[waiter.line] or 0) + 1
	end

	local rows : {WaitingRow} = {}
	for destination, bucket in pairs(buckets) do
		local name = info.destinationName[destination] or tostring(destination)
		rows[#rows + 1] = waitingRow(destination, name, info.destinationDistance[destination], bucket, info.lineName)
	end
	table.sort(rows, byWaitingThenName)
	local destinationCount = #rows
	if unknown ~= nil then
		rows[#rows + 1] = waitingRow(nil, info.unknownName, nil, unknown, info.lineName)
	end

	local total = 0
	for _, row in ipairs(rows) do
		total = total + row.waiting
	end
	return { rows = rows, totalWaiting = total, destinationCount = destinationCount }
end

function rank.formatLineLabel(row : WaitingRow) : string
	if #row.lines == 0 then
		return ""
	end
	if #row.lines == 1 then
		return row.lines[1].name
	end
	return row.lines[1].name .. " +" .. tostring(#row.lines - 1)
end
```

- [ ] **Step 2:** `just test`. Expected: 19 passed, 0 failed.
- [ ] **Step 3:** `just check`. Expected: 0 errors.
- [ ] **Step 4: Commit:** `feat: group waiting passengers by destination (pure)`.

### Task 4: `waiting.tl`: engine access, with spike probes

**Files:**
- create `T/waiting.d.tl` and `C/waiting.tl`;
- modify `M/tealdef/pgrace_commuter_compass_def.d.tl`.

- [ ] **Step 1: Write `T/waiting.d.tl`:**

```teal
-- Reads game state for the Waiting passengers card. Verified in-game, not unit-tested.
global record PgraceCommuterCompassWaiting
	-- True when one of the player's lines stops at a passenger station of the group.
	hasPassengerLines : function(stationGroup : Engine.Entity) : boolean
	-- Arrow and camera position of a town, industry or station group; nil if unknown.
	positionOf : function(entity : Engine.Entity) : Vec3f
	-- Everyone waiting at the station group, grouped by destination.
	count : function(stationGroup : Engine.Entity) : PgraceCommuterCompassRank.WaitingTable
end
```

- [ ] **Step 2:** add `require "gui.pgrace_commuter_compass.waiting"` to `M/tealdef/pgrace_commuter_compass_def.d.tl`, after the commuters line.

- [ ] **Step 3: Write `C/waiting.tl`:**

```teal
local commuters = ug_require "pgrace_commuter_compass::/gui/pgrace_commuter_compass/commuters.tl" as PgraceCommuterCompassCommuters
local rank = ug_require "pgrace_commuter_compass::/gui/pgrace_commuter_compass/rank.tl" as PgraceCommuterCompassRank
local entity_util = ug_require "::/scripts/entity_util.tl" as EntityUtil

local waiting : PgraceCommuterCompassWaiting = {}

local LOG_PREFIX = "[commuter_compass] "

local type Waiter = PgraceCommuterCompassRank.Waiter

local record LineStop
	line : Engine.Entity
	stop : integer
end

local function stationsOf(stationGroup : Engine.Entity) : {Engine.Entity}
	local group = api.engine.getComponent(stationGroup, api.type.ComponentType.STATION_GROUP) as Engine.Component.StationGroup
	if group == nil then
		return {}
	end
	return group.stations
end

-- The player's line stops at the group's passenger terminals, each once.
local function playerLineStops(stationGroup : Engine.Entity) : {LineStop}
	local result : {LineStop} = {}
	local seen : {string : boolean} = {}
	for _, station in ipairs(stationsOf(stationGroup)) do
		local component = api.engine.getComponent(station, api.type.ComponentType.STATION) as Engine.Component.Station
		if component ~= nil and api.engine.util.station.isStationOfType(station, false) then
			for terminal = 1, #component.terminals do
				for _, pair in ipairs(api.engine.system.lineSystem.getLineStopsForTerminal(station, terminal - 1)) do
					local line = pair[1] as Engine.Entity
					local stop = pair[2] as integer
					local key = tostring(line) .. ":" .. tostring(stop)
					if not seen[key] and entity_util.isOwnedByPlayer(line) then
						seen[key] = true
						result[#result + 1] = { line = line, stop = stop }
					end
				end
			end
		end
	end
	return result
end

function waiting.hasPassengerLines(stationGroup : Engine.Entity) : boolean
	return #playerLineStops(stationGroup) > 0
end

local function stationGroupPosition(stationGroup : Engine.Entity) : Vec3f
	for _, station in ipairs(stationsOf(stationGroup)) do
		local construction = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station)
		local position = (construction ~= nil and api.engine.entityExists(construction)) and commuters.getPosition3(construction) or nil
		position = position or commuters.getPosition3(station)
		if position ~= nil then
			return position
		end
	end
	return nil
end

function waiting.positionOf(entity : Engine.Entity) : Vec3f
	if api.engine.getComponent(entity, api.type.ComponentType.STATION_GROUP) ~= nil then
		return stationGroupPosition(entity)
	end
	local position = commuters.getPosition3(entity)
	if position == nil then
		local industry = api.engine.getComponent(entity, api.type.ComponentType.INDUSTRY) as Engine.Component.Industry
		if industry ~= nil then
			position = commuters.getPosition3(industry.construction)
		end
	end
	return position
end

local function townOfBuilding(building : Engine.Entity) : Engine.Entity
	local townBuilding = api.engine.getComponent(building, api.type.ComponentType.TOWN_BUILDING) as Engine.Component.TownBuilding
	return townBuilding ~= nil and townBuilding.town or nil
end

-- A person's target → their destination: the town of a town building, or an industry; nil if neither.
-- `capacities` maps person-capacity entities to town buildings (fetched once per count, only if needed).
local function resolve(target : Engine.Entity, capacities : function() : {Engine.Entity : Engine.Entity}) : Engine.Entity
	if target == nil or not api.engine.entityExists(target) then
		return nil
	end
	local town = townOfBuilding(target)
	if town ~= nil then
		return town
	end
	if api.engine.getComponent(target, api.type.ComponentType.INDUSTRY) ~= nil then
		return target
	end
	if api.engine.getComponent(target, api.type.ComponentType.TOWN) ~= nil then
		return target
	end
	local building = capacities()[target]
	if building ~= nil then
		return townOfBuilding(building)
	end
	local construction = api.engine.getComponent(target, api.type.ComponentType.CONSTRUCTION) as Engine.Component.Construction
	if construction ~= nil then
		if #construction.townBuildings > 0 then
			return townOfBuilding(construction.townBuildings[1])
		end
		if #construction.industries > 0 then
			return construction.industries[1]
		end
	end
	return nil
end

local PROBE_COMPONENTS : {string} = { "TOWN_BUILDING", "INDUSTRY", "CONSTRUCTION", "PERSON_CAPACITY", "TOWN" } -- PROBE (remove before release)

local function probeTarget(target : Engine.Entity, destination : Engine.Entity) -- PROBE (remove before release)
	local has : {string} = {}
	for _, name in ipairs(PROBE_COMPONENTS) do
		local componentType = (api.type.ComponentType as {string : any})[name] as ComponentType
		if api.engine.getComponent(target, componentType) ~= nil then
			has[#has + 1] = name
		end
	end
	debugPrint(LOG_PREFIX .. string.format("probe target %s (%s): components [%s] -> destination %s (%s)",
		tostring(target), tostring(api.engine.util.getEntityName(target)), table.concat(has, ","),
		tostring(destination), destination ~= nil and tostring(api.engine.util.getEntityName(destination)) or "-"))
end

local function gather(stationGroup : Engine.Entity) : {Waiter}
	local passenger = api.res.cargoTypeRep.getPassengerCargoTypeId()
	local capacityMap : {Engine.Entity : Engine.Entity} = nil
	local function capacities() : {Engine.Entity : Engine.Entity}
		capacityMap = capacityMap or api.engine.system.townBuildingSystem.getPersonCapacity2townBuildingMap() or {}
		return capacityMap
	end

	local result : {Waiter} = {}
	local seen : {Engine.Entity : boolean} = {}
	local engineCount = 0 -- PROBE (remove before release)
	local probed = 0 -- PROBE (remove before release)
	for _, lineStop in ipairs(playerLineStops(stationGroup)) do
		engineCount = engineCount + api.engine.system.simEntityAtTerminalSystem.getLineStopSimEntitiesCount(lineStop.line, lineStop.stop, passenger) -- PROBE
		for _, person in ipairs(api.engine.system.simEntityAtTerminalSystem.getLineStopSimEntities(lineStop.line, lineStop.stop, passenger)) do
			if not seen[person] then
				seen[person] = true
				local atTerminal = api.engine.getComponent(person, api.type.ComponentType.SIM_ENTITY_AT_TERMINAL) as Engine.Component.SimEntityAtTerminal
				local simPerson = api.engine.getComponent(person, api.type.ComponentType.SIM_PERSON) as Engine.Component.SimPerson
				if atTerminal ~= nil and simPerson ~= nil then
					local destination = resolve(simPerson.targetOrAtEntity, capacities)
					if probed < 5 then -- PROBE (remove before release)
						probed = probed + 1
						probeTarget(simPerson.targetOrAtEntity, destination)
					end
					result[#result + 1] = { line = atTerminal.line, destination = destination }
				end
			end
		end
	end
	debugPrint(LOG_PREFIX .. string.format("probe waiting: %d people read, engine count %d over %d line stops", -- PROBE
		#result, engineCount, #playerLineStops(stationGroup)))
	return result
end

local function nameOf(entity : Engine.Entity) : string
	local name = api.engine.util.getEntityName(entity)
	if name == nil or name == "" then
		return _("Unnamed")
	end
	return name
end

function waiting.count(stationGroup : Engine.Entity) : PgraceCommuterCompassRank.WaitingTable
	local started = os.clock() -- PROBE (remove before release)
	local waiters = gather(stationGroup)
	local here = waiting.positionOf(stationGroup)
	local info : PgraceCommuterCompassRank.WaitingInfo = {
		destinationName = {},
		destinationDistance = {},
		lineName = {},
		unknownName = _("Unknown"),
	}
	for _, waiter in ipairs(waiters) do
		if info.lineName[waiter.line] == nil then
			info.lineName[waiter.line] = nameOf(waiter.line)
		end
		local destination = waiter.destination
		if destination ~= nil and info.destinationName[destination] == nil then
			info.destinationName[destination] = nameOf(destination)
			local there = waiting.positionOf(destination)
			if here ~= nil and there ~= nil then
				info.destinationDistance[destination] = rank.planarDistance(here.x, here.y, there.x, there.y)
			end
		end
	end
	local result = rank.groupWaiting(waiters, info)
	debugPrint(LOG_PREFIX .. string.format("probe count: %s, %d waiting, %d destinations, %.1f ms", -- PROBE
		nameOf(stationGroup), result.totalWaiting, result.destinationCount, (os.clock() - started) * 1000))
	return result
end

return waiting
```

- [ ] **Step 4:** `just check`. Expected: `build: 7 content files`, 0 errors.
  - If `api.type.ComponentType as {string : any}` is rejected, cast through `any` first:
    `(api.type.ComponentType as any as {string : ComponentType})[name]`.
  - If `getPersonCapacity2townBuildingMap` can't be found on `townBuildingSystem`, check its name in
    `api/tealdef/api/engine/system.d.tl` (around line 105) and the system's field name (around line 651).
- [ ] **Step 5: Commit:** `feat: read waiting passengers at a station group (with spike probes)`.

### Task 5: Station card UI

**Files:**
- create `C/station_plugin.res.lua`;
- modify `C/pgrace_commuter_compass.script.tl`.

- [ ] **Step 1: Write `C/station_plugin.res.lua`:**

```lua
function data()
	return {
		type = "react-plugin ::StationGroupEowExtensionPoint",
		data = {
			filePath = "pgrace_commuter_compass::/gui/pgrace_commuter_compass/pgrace_commuter_compass.script@StationPlugin",
			condition = "pgrace_commuter_compass::/gui/pgrace_commuter_compass/pgrace_commuter_compass.script@hasPassengerLines",
			order = 45,
		}
	}
end
```

- [ ] **Step 2: Script header changes:**
  - after the `town_eow` require add
    `local station_group_eow = ug_require "::/gui/entity_window/station_group/station_group_eow.script.tl" as StationGroupEow`;
  - after the `rank` require add
    `local waiting = ug_require "pgrace_commuter_compass::/gui/pgrace_commuter_compass/waiting.tl" as PgraceCommuterCompassWaiting`;
  - after `ARROW_ICON` add `local REFRESH_ICON = "::/gui/entity_window/icons/symbol_arrows_refresh.tga"`;
  - after the `type Sections` line add `local type WaitingRow = PgraceCommuterCompassRank.WaitingRow` and
    `local type WaitingTable = PgraceCommuterCompassRank.WaitingTable`.

- [ ] **Step 3: Arrow positions:** in `FlowAction`, change both `commuters.getPosition3(...)` calls to `waiting.positionOf(...)`.
  Towns resolve exactly as before, and station groups and industries now work too.

- [ ] **Step 4: Add the station card**, between `TownPlugin`/`hasOtherTowns` and the `debugPrint(... "script loaded")`:

```teal
-- ---------------------------------------------------------------------------------------------------------------
-- Station window: Waiting passengers
-- ---------------------------------------------------------------------------------------------------------------

local record WaitingState
	waitingTable : WaitingTable
	failed : boolean
	-- Bumped by every count, so each refresh gets fresh row keys (and therefore fresh cells with fresh userParam).
	generation : integer
end

-- Row keys stay unique across refreshes: generation * ROWS_PER_GENERATION + row index.
local ROWS_PER_GENERATION = 100000

local function computeWaiting(stationGroup : Engine.Entity, generation : integer) : WaitingState
	local ok, resultOrError = pcall(waiting.count, stationGroup)
	if ok then
		return { waitingTable = resultOrError as WaitingTable, failed = false, generation = generation }
	end
	debugPrint(LOG_PREFIX .. "waiting: error for station " .. tostring(stationGroup) .. ": " .. tostring(resultOrError))
	return { waitingTable = nil, failed = true, generation = generation }
end

local record WaitingData
	here : Engine.Entity
	rows : {integer : WaitingRow}
	selectionState : ReactStateT<Selection>
end

local function waitingFlow(data : WaitingData, row : WaitingRow) : Selection
	return { from = data.here, to = row.destination, animated = true }
end

-- Locate, arrow toggle, and the name (opens the destination's window). The Unknown row is plain text.
local WaitingNameCell = react.RegisterRecipe("PgraceCommuterCompassWaitingNameCell", function(params : Builtin.TableCellParam) : TreeNodeId
	local data = params.userParam as WaitingData
	local row = data.rows[params.rowKey]
	if row == nil then
		return builtin.BoxLayout{ children = {} }
	end
	if row.destination == nil then
		return builtin.BoxLayout{ children = { builtin.TextView{ meta = { class = "font-scale-body" }, text = row.name } } }
	end
	local flow = waitingFlow(data, row)
	local function selected() : boolean
		local current = data.selectionState:old()
		return current ~= nil and current.from == flow.from and current.to == flow.to
	end
	local selectedState = engine_react_util.useStepState(selected)
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			line_react_util.LocateButton{ entity = row.destination },
			builtin.ToggleButton{
				meta = { tooltip = _("Show on the map") },
				content = builtin.ImageView{ path = ARROW_ICON, scaling = builtin.type.ImageViewScaling.AutoFit },
				value = selectedState:old() and 1 or 0,
				onValueChange = function(value : integer)
					if value == 1 then
						data.selectionState:set(flow)
					elseif selected() then
						data.selectionState:set(nil)
					end
				end,
			},
			line_react_util.makeEntityWindowButton(row.name, row.destination),
		},
	}
end)

local function waitingText(name : string, textOf : function(WaitingRow) : string) : Recipe<Builtin.TableCellParam>
	return react.RegisterRecipe(name, function(params : Builtin.TableCellParam) : TreeNodeId
		local row = (params.userParam as WaitingData).rows[params.rowKey]
		-- A recipe must return a layout; a bare TextView crashes the whole UI.
		return builtin.BoxLayout{
			children = { builtin.TextView{ meta = { class = "font-scale-body" }, text = row ~= nil and textOf(row) or "" } },
		}
	end)
end

local WaitingDistanceCell = waitingText("PgraceCommuterCompassWaitingDistanceCell", function(row : WaitingRow) : string
	return row.distance ~= nil and rank.formatDistance(row.distance) or "-"
end)
local WaitingCountCell = waitingText("PgraceCommuterCompassWaitingCountCell", function(row : WaitingRow) : string
	return tostring(row.waiting)
end)

-- The top line's name opens the line window; the tooltip lists every line with its count.
local WaitingLineCell = react.RegisterRecipe("PgraceCommuterCompassWaitingLineCell", function(params : Builtin.TableCellParam) : TreeNodeId
	local row = (params.userParam as WaitingData).rows[params.rowKey]
	if row == nil or #row.lines == 0 then
		return builtin.BoxLayout{ children = {} }
	end
	local tooltip : {string} = {}
	for _, line in ipairs(row.lines) do
		tooltip[#tooltip + 1] = line.name .. ": " .. tostring(line.count)
	end
	return builtin.BoxLayout{
		meta = { tooltip = table.concat(tooltip, "\n") },
		children = { line_react_util.makeEntityWindowButton(rank.formatLineLabel(row), row.lines[1].line) },
	}
end)

-- Starts sorted by Waiting (column 3), largest first.
local function makeWaitingTable(rowKeys : {integer}, data : WaitingData) : TreeNodeId
	local function rowOf(rowKey : integer) : WaitingRow
		return data.rows[rowKey]
	end
	return builtin.DataTable{
		columns = {
			builtin.ColumnDesc{
				name = _("Destination"),
				recipe = WaitingNameCell,
				getCompareValue = function(rowKey : integer) : any
					return rowOf(rowKey).name
				end,
				weight = 1,
			},
			builtin.ColumnDesc{
				name = _("Distance"),
				recipe = WaitingDistanceCell,
				getCompareValue = function(rowKey : integer) : any
					return rowOf(rowKey).distance or math.huge
				end,
			},
			builtin.ColumnDesc{
				name = _("Waiting"),
				recipe = WaitingCountCell,
				getCompareValue = function(rowKey : integer) : any
					return rowOf(rowKey).waiting
				end,
			},
			builtin.ColumnDesc{
				name = _("Line"),
				recipe = WaitingLineCell,
				getCompareValue = function(rowKey : integer) : any
					return rank.formatLineLabel(rowOf(rowKey))
				end,
			},
		},
		rowKeys = rowKeys,
		userParam = data,
		initialSortColumn = { 3, false },
	}
end

local WaitingList = react.RegisterRecipe("PgraceCommuterCompassWaitingList", function(params : ListParams) : TreeNodeId
	local state = react.useStateLazy(function() : WaitingState
		return computeWaiting(params.entityId, 1)
	end)
	local selectionState = react.useStateLazy(function() : Selection
		return nil
	end)
	local current = state:old()

	local function refresh()
		local next = computeWaiting(params.entityId, current.generation + 1)
		-- Keep the arrow only while its destination is still listed.
		local selection = selectionState:old()
		if selection ~= nil then
			local stillListed = false
			for _, row in ipairs(next.waitingTable ~= nil and next.waitingTable.rows or {}) do
				if row.destination == selection.to then
					stillListed = true
				end
			end
			if not stillListed then
				selectionState:set(nil)
			end
		end
		state:set(next)
	end

	local children : {TreeNodeId} = {}
	local function add(node : TreeNodeId)
		children[#children + 1] = node
	end

	local title : string
	if current.failed then
		title = _("Commuter Compass: error (see log)")
	else
		title = _("Waiting") .. " · " .. plural(current.waitingTable.totalWaiting, _("person"), _("people"))
			.. " · " .. plural(current.waitingTable.destinationCount, _("destination"), _("destinations"))
	end
	add(builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			builtin.TextView{ text = title },
			builtin.Button{
				meta = { tooltip = _("Refresh") },
				content = builtin.ImageView{ path = REFRESH_ICON, scaling = builtin.type.ImageViewScaling.AutoFit },
				onClick = refresh,
			},
		},
	})

	if not current.failed then
		local tbl = current.waitingTable
		if #tbl.rows == 0 then
			add(makeHint(_("Nobody is waiting here.")))
		else
			local data : WaitingData = { here = params.entityId, rows = {}, selectionState = selectionState }
			local rowKeys : {integer} = {}
			for i, row in ipairs(tbl.rows) do
				local rowKey = current.generation * ROWS_PER_GENERATION + i
				rowKeys[i] = rowKey
				data.rows[rowKey] = row
			end
			add(makeWaitingTable(rowKeys, data))
		end
	end
	if selectionState:old() ~= nil then
		add(FlowAction{ gameCtx = params.gameCtx, selection = selectionState:old() })
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
end)

local StationPlugin = react.RegisterPluginRecipe(station_group_eow.StationGroupEowExtensionPoint, "PgraceCommuterCompassStationPlugin", function(params : StationGroupEow.StationGroupWidgetPluginParams) : TreeNodeId
	return builtin.BoxLayout{
		child = content_card.ContentCard{
			title = _("Waiting passengers"),
			initialCalloutTextPermanent = "",
			recipeAndParamPermanent = content_card.makeRecipeAndParam(WaitingList, { entityId = params.entityId, gameCtx = params.gameCtx } as ListParams),
			gameCtx = params.gameCtx,
			showOnRightSide = params.showCalloutOnRightSide,
		},
	}
end)

-- Hides the card on cargo-only stations and stations none of the player's lines serve. Shows on error.
local function hasPassengerLines(params : StationGroupEow.StationGroupWidgetPluginParams) : boolean
	local ok, resultOrError = pcall(waiting.hasPassengerLines, params.entityId)
	return not ok or resultOrError as boolean
end
```

  Then extend the returned table with `StationPlugin = StationPlugin` and `hasPassengerLines = hasPassengerLines`.

  Notes for the implementer:
  - `plural`, `makeHint`, `FlowAction`, `Selection` and `ListParams` already exist above in the script. Define the new
    code after them.
  - `WaitingData` is rebuilt on every render, while cells keep the `userParam` of their first render. That's fine:
    a refresh changes the generation, so every row key is new and every cell is created fresh. Between refreshes the
    rows never change, and only the selection does, which the name cell polls.

- [ ] **Step 5:** `just check`. Expected: `build: 8 content files`, 0 errors. Resolve type errors in the new code only.
  - If `meta` isn't accepted on `BoxLayout`, put the tooltip on a wrapping `builtin.Button`-less TextView, or drop it
    and note that in the spec.
  - If `ReactStateT:set(nil)` is rejected for a non-optional type, follow how `CommuterList` does it.
- [ ] **Step 6:** `just verify`. Expected: 0 errors, 19 passed, release check OK.
- [ ] **Step 7: Commit:** `feat: Waiting passengers card in the station window`.

### Task 6: In-game spike (user)

- [ ] **Step 1: Ask the user to restart TF3, then:**
  1. Open the crowded station. The **Waiting passengers** card should show, with a table.
  2. Click **Refresh** once.
  3. Turn on the arrow for the top row, then another row.
  4. Open a cargo-only station, if there is one. The card should be absent.
  5. Open a town window. The Commuters card should work as before.
- [ ] **Step 2: Read the log:**
  `grep -h "\[commuter_compass\]" ~/.local/share/Steam/userdata/12818001/3493540/local/crash_dump/stdout.txt | tail -40`
  - `probe target` lines: which components the target has. If many end up with destination `nil`, fix `resolve`'s
    order or add the missing case (for example a `SIM_BUILDING`-like component), and re-run.
  - `probe waiting`: compare "people read" with "engine count". If they differ a lot, duplicates or waiting-hall
    people are being counted differently. Compare both with the station window's own waiting numbers.
  - `probe count`: the ms per count. Over about 50 ms on a busy hub is worth noting (the Refresh button stays).
- [ ] **Step 3:** fix anything the spike shows, `just verify`, commit (`fix: ...`), and repeat steps 1–2 if needed.

### Task 7: Remove probes, record findings

- [ ] **Step 1:** remove every line marked `PROBE` from `C/waiting.tl`, including `probeTarget`, `PROBE_COMPONENTS`,
  `engineCount`, `probed`, and the `started` and `os.clock` timing. Afterwards
  `grep -n "PROBE\|probe" $C/waiting.tl` should print nothing.
- [ ] **Step 2:** add a "Findings (spike, <date>)" section to the spec: what targets are, how waiting-hall people are
  counted, the timing.
- [ ] **Step 3:** in `../AGENTS.md`, under "Game data facts", add a "Passengers waiting at stations" bullet: the API
  calls, what `targetOrAtEntity` is, and building → town via `TOWN_BUILDING.town`.
- [ ] **Step 4:** `just verify`. Commit: `chore: remove waiting spike probes; record findings`.

### Task 8: Full in-game checklist (user)

- [ ] **Step 1:** ask the user to restart TF3 and run the spec's checklist:
  - [ ] A passenger station shows the **Waiting passengers** card. A cargo-only station doesn't.
  - [ ] The total roughly matches the base window's waiting counts.
  - [ ] Destination names open their windows, line names open the line, and Locate moves the camera.
  - [ ] The line tooltip lists every line, and its counts add up to the row's Waiting.
  - [ ] Refresh updates the numbers and keeps the selected arrow.
  - [ ] Arrows go from the station to the destination, switch on the first click, and stay clear of the window.
  - [ ] The town card still works as before.
- [ ] **Step 2:** fix, verify and commit, until it passes.

### Task 9: Docs and release text

**Files:** modify `README.md`, `$M/_metadata/description.html` and `$M/_metadata/modinfo.json`.

- [ ] **Step 1: README:**
  - In the intro, add a paragraph on the station card.
  - In the layout block, add `waiting.tl` and `station_plugin.res.lua`.
  - In the checklist, add the Task 8 items.
  - In Known limitations, add: "The Waiting table's Unknown row sorts with the others when you click a header."
- [ ] **Step 2: `description.html`:**
  - In the intro, say the mod adds cards to **town and station windows**.
  - Under Features, add a "**Waiting passengers** (station window)" item: final destinations, the top line plus
    "+N", Refresh, and the arrow from the station.
  - Under How to use, add "Open a station's window" steps.
  - Under Good to know, add "Waiting counts are a snapshot; click Refresh to update."
- [ ] **Step 3: `modinfo.json`:**
  - `summary` (≤100 chars): "Town and station window cards: where commuters and waiting passengers are headed, and how far."
  - `description`: add a sentence on the station card.
- [ ] **Step 4:** `just verify`. Commit: `docs: describe the Waiting passengers card`.

### Task 10: Merge, screenshot, release (with the user)

- [ ] **Step 1: Merge locally:** `git switch main && git merge --ff-only feat/station-waiting && just verify && git branch -d feat/station-waiting`.
- [ ] **Step 2: Screenshot:**
  - The user takes one shot of the card on a busy station, with an arrow showing. The agent checks it (reads the PNG,
    runs `just release-check`).
  - Pick the next free number (`4.png`) and commit it on its own: `docs: station card screenshot`.
- [ ] **Step 3: Revision:** `just bump` (to revision 2). Commit: `chore: bump revision to 2`.
- [ ] **Step 4: Release:** `just release`. The user uploads from Mod Hub → My Mods ("The existing mod on mod.io will be
  updated"). Commit anything the upload changed. With the user's go-ahead, run `just mark-uploaded` and
  `git push origin main`.
