function data()
	return {
		type = "react-plugin ::StationGroupEowExtensionPoint",
		data = {
			filePath = "pgrace_commuter_compass::/gui/pgrace_commuter_compass/pgrace_commuter_compass.script@StationPlugin",
			condition = "pgrace_commuter_compass::/gui/pgrace_commuter_compass/pgrace_commuter_compass.script@hasPassengerLines",
			order = 45,
		}
	}
end
