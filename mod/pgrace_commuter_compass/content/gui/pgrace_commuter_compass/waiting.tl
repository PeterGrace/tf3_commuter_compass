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
		local componentType = (api.type.ComponentType as any as {string : Engine.ComponentType})[name]
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
