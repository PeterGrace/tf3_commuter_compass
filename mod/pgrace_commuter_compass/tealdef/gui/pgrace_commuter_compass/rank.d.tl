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
		-- Sum of work + shop over all towns in the section, before the cap. These are trips (destinations), not people:
		-- a resident who both works and shops in a town counts twice, as in the engine's own "usage" count.
		tripCount : integer
	end

	record Sections
		outbound : Section
		inbound : Section
		-- The nearest towns with no commuters either way.
		nearby : Section
		-- False when any town came without counts (the game lacks the commuter API); then every town is "nearby".
		countsKnown : boolean
	end

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

	-- Straight-line distance on the map plane.
	planarDistance : function(ax : number, ay : number, bx : number, by : number) : number
	-- linesUseCount / usageCount, or nil when counts are nil or usageCount is 0.
	lineUsage : function(counts : Counts) : number
	-- Outbound/inbound: towns with work + shop > 0 in that direction, capped at `cap`.
	-- Nearby: towns with none either way, capped at `nearbyCount`. All sorted by distance, ties by name.
	buildSections : function(towns : {TownData}, cap : integer, nearbyCount : integer) : Sections
	-- "850 m" below one kilometre, otherwise "4.2 km".
	formatDistance : function(metres : number) : string
	-- "45%"; "<1%" for small non-zero shares (so a rider is never shown as "0%"); "-" for nil (as the base table).
	formatPercent : function(fraction : number) : string
	-- Groups waiters per destination; see WaitingTable for the order.
	groupWaiting : function(waiters : {Waiter}, info : WaitingInfo) : WaitingTable
	-- "Red Line", or "Red Line +2" when two other lines carry people too; "" without lines.
	-- With `maxChars`, the top line's name is shortened by shortenMiddle.
	formatLineLabel : function(row : WaitingRow, maxChars? : integer) : string
	-- At most `maxChars` characters (UTF-8 aware): the start, "…", and a longer end, since names like
	-- "Bus Passengers-CouClu-LO-1" differ at the end. Spaces next to the "…" are dropped.
	shortenMiddle : function(text : string, maxChars : integer) : string
end
