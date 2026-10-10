local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = { }

	local a = ssu.makeAdder(result)

	-- The arrow label's floating layout fills the screen, so the label can be placed anywhere on it (as the game's
	-- "R::CalloutContainer FloatingLayout" rule does for callouts). Without it the layout shrinks to the label and sits
	-- at the left edge.
	a("R::PgraceCommuterCompassArrowLabelLayer FloatingLayout", {
		gravity = { -1.0, -1.0 },
	})

	return result
end
