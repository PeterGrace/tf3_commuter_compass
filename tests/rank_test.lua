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

t.test("formatPercent: small non-zero shares read '<1%', never '0%'", function()
	t.eq(rank.formatPercent(0.0033), "<1%")
	t.eq(rank.formatPercent(0.0049), "<1%")
	t.eq(rank.formatPercent(0.005), "1%")
end)

t.test("lineUsage: linesUseCount / usageCount, nil when nothing is counted", function()
	t.eq(rank.lineUsage(nil), nil)
	t.eq(rank.lineUsage({ work = 0, shop = 0, usageCount = 0, linesUseCount = 0 }), nil)
	t.eq(rank.lineUsage({ work = 8, shop = 4, usageCount = 12, linesUseCount = 3 }), 0.25)
	t.eq(rank.lineUsage({ work = 1, shop = 0, usageCount = 1, linesUseCount = 0 }), 0)
end)

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
