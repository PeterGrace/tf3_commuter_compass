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
