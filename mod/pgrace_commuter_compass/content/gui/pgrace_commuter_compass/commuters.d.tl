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
