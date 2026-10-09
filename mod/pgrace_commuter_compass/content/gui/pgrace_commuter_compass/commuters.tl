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
		debugPrint("[commuter_compass] town " .. tostring(town) .. " has no bounding volume")
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
