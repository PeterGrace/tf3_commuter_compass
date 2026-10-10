-- Reads game state for the Waiting passengers card. Verified in-game, not unit-tested.
global record PgraceCommuterCompassWaiting
	-- True when one of the player's lines stops at a passenger station of the group.
	hasPassengerLines : function(stationGroup : Engine.Entity) : boolean
	-- Arrow and camera position of a town, industry or station group; nil if unknown.
	positionOf : function(entity : Engine.Entity) : Vec3f
	-- Everyone waiting at the station group, grouped by destination.
	count : function(stationGroup : Engine.Entity) : PgraceCommuterCompassRank.WaitingTable
end
