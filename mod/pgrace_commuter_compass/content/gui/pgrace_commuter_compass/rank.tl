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
	-- Rounding would show "0%" while the arrow is animated; any rider at all reads "<1%".
	if fraction > 0 and fraction < 0.005 then
		return "<1%"
	end
	return string.format("%d%%", math.floor(fraction * 100 + 0.5))
end

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
	local section : Section = { rows = {}, townCount = #towns, tripCount = 0 }
	for i, town in ipairs(towns) do
		local counts = countsOf(town)
		section.tripCount = section.tripCount + commutersOf(counts)
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

return rank
