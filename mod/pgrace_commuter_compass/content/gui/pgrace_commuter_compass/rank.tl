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

-- Integer plural rules from CLDR, for the languages TF3 ships.
local function slavicCategory(count : integer, oneNeedsTensCheck : boolean) : string
	local lastDigit, lastTwo = count % 10, count % 100
	if count == 1 or (oneNeedsTensCheck and lastDigit == 1 and lastTwo ~= 11) then
		return "one"
	end
	if lastDigit >= 2 and lastDigit <= 4 and not (lastTwo >= 12 and lastTwo <= 14) then
		return "few"
	end
	return "many"
end

function rank.pluralCategory(language : string, count : integer) : string
	local lang = (language or "en"):sub(1, 2)
	if lang == "ja" or lang == "ko" or lang == "zh" then
		return "other"
	end
	if lang == "ru" then
		return slavicCategory(count, true)
	end
	if lang == "pl" then
		return slavicCategory(count, false)
	end
	if lang == "fr" or lang == "pt" then
		return (count == 0 or count == 1) and "one" or "other"
	end
	return count == 1 and "one" or "other"
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

local type Waiter = PgraceCommuterCompassRank.Waiter
local type WaitingRow = PgraceCommuterCompassRank.WaitingRow

local function byWaitingThenNames(a : WaitingRow, b : WaitingRow) : boolean
	if a.waiting ~= b.waiting then
		return a.waiting > b.waiting
	end
	if a.name ~= b.name then
		return a.name < b.name
	end
	return a.lineName < b.lineName
end

-- {destination: {line: count}} into sorted rows; `destination` is nil for the Unknown bucket.
local function rowsOf(destination : Engine.Entity, bucket : {Engine.Entity : integer}, info : PgraceCommuterCompassRank.WaitingInfo,
		into : {WaitingRow})
	for line, count in pairs(bucket) do
		local row : WaitingRow = {
			destination = destination,
			name = info.unknownName,
			line = line,
			lineName = info.lineName[line] or tostring(line),
			waiting = count,
		}
		if destination ~= nil then
			row.name = info.destinationName[destination] or tostring(destination)
			row.distance = info.destinationDistance[destination]
		end
		into[#into + 1] = row
	end
end

function rank.groupWaiting(waiters : {Waiter}, info : PgraceCommuterCompassRank.WaitingInfo) : PgraceCommuterCompassRank.WaitingTable
	local buckets : {Engine.Entity : {Engine.Entity : integer}} = {}
	local unknown : {Engine.Entity : integer} = {}
	local total = 0
	for _, waiter in ipairs(waiters) do
		local bucket = unknown
		if waiter.destination ~= nil then
			bucket = buckets[waiter.destination]
			if bucket == nil then
				bucket = {}
				buckets[waiter.destination] = bucket
			end
		end
		bucket[waiter.line] = (bucket[waiter.line] or 0) + 1
		total = total + 1
	end

	local rows : {WaitingRow} = {}
	local destinationCount = 0
	for destination, bucket in pairs(buckets) do
		destinationCount = destinationCount + 1
		rowsOf(destination, bucket, info, rows)
	end
	table.sort(rows, byWaitingThenNames)
	local unknownRows : {WaitingRow} = {}
	rowsOf(nil, unknown, info, unknownRows)
	table.sort(unknownRows, byWaitingThenNames)
	for _, row in ipairs(unknownRows) do
		rows[#rows + 1] = row
	end
	return { rows = rows, totalWaiting = total, destinationCount = destinationCount }
end

-- UTF-8 characters of `text`, one string each.
local function characters(text : string) : {string}
	local result : {string} = {}
	for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		result[#result + 1] = char
	end
	return result
end

function rank.shortenMiddle(text : string, maxChars : integer) : string
	local chars = characters(text)
	if #chars <= maxChars then
		return text
	end
	local headCount = math.floor((maxChars - 1) / 3)
	local tailCount = maxChars - 1 - headCount
	local head = table.concat(chars, "", 1, headCount):gsub("%s+$", "")
	local tail = table.concat(chars, "", #chars - tailCount + 1, #chars):gsub("^%s+", "")
	return head .. "…" .. tail
end

return rank
