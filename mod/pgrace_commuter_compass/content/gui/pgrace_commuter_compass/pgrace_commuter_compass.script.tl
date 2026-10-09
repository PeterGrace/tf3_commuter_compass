local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local content_card = ug_require "::/gui/main/content_card.tl" as ContentCard
local line_react_util = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl" as LineReactUtil
local selector_react_util = ug_require "::/gui/main/selector_react_util.tl" as SelectorReactUtil
local color_util = ug_require "::/gui/main/color_util.tl" as ColorUtil
local town_eow = ug_require "::/gui/entity_window/town/town_eow.script.tl" as TownEow
local commuters = ug_require "pgrace_commuter_compass::/gui/pgrace_commuter_compass/commuters.tl" as PgraceCommuterCompassCommuters
local rank = ug_require "pgrace_commuter_compass::/gui/pgrace_commuter_compass/rank.tl" as PgraceCommuterCompassRank

local layerColors = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/layers/layer_colors.gres")).data as LayerColors
local transparency = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/transparency.gres")).data as GResTransparency

local LOG_PREFIX = "[commuter_compass] "
local ROW_CAP = 10
local NEARBY_COUNT = 3
local FLOW_ACTION_KEY = "commuter_compass_flow"
local CAMERA_DISTANCE_FACTOR = 1.2
local CAMERA_MIN_DISTANCE = 500

-- The base town window's Destinations table icons (gui/entity_window/town/town.tl).
local WORK_ICON = "::/gui/entity_window/icons/building_industry.tga"
local SHOP_ICON = "::/gui/entity_window/icons/symbol_shopping_cart.tga"
local LINE_ICON = "::/gui/entity_window/icons/symbol_configure_line.tga"
local ARROW_ICON = "::/gui/entity_window/icons/symbol_arrow_up.tga"

local type Row = PgraceCommuterCompassRank.Row
local type Section = PgraceCommuterCompassRank.Section
local type Sections = PgraceCommuterCompassRank.Sections

local record ListParams
	entityId : Engine.Entity
	gameCtx : GameContext
end

-- The arrow shown on the map; nil when none is. Passengers travel `from` → `to`.
local record Selection
	from : Engine.Entity
	to : Engine.Entity
	-- Animated when some of these commuters ride the player's lines; faint and static otherwise.
	animated : boolean
end

local record FlowParams
	gameCtx : GameContext
	selection : Selection
end

-- The renderer API (gui/main/builtin.lua) has this, but it is missing from the type definitions.
-- The override takes precedence over the tool stack's active owner without replacing it, so clearing it with
-- `false` hands the map straight back to the town window's own action.
local record ActiveOwnerApi
	setActiveOwnerOverride : function(ReactRefWrap | boolean)
end

local record FlowCache
	key : string
	action : function() : TreeNodeId
end

local record ListState
	sections : Sections
	failed : boolean
end

local function computeState(townEntity : Engine.Entity) : ListState
	local ok, resultOrError = pcall(function() : Sections
		local started = os.clock() -- PROBE (remove before release)
		local towns = commuters.gather(townEntity)
		-- PROBE (remove before release)
		debugPrint(LOG_PREFIX .. string.format("probe gather: %s, %d other towns, %.1f ms", api.engine.util.getEntityName(townEntity), #towns, (os.clock() - started) * 1000))
		for _, other in ipairs(towns) do
			if other.outbound ~= nil and other.inbound ~= nil then
				local o = other.outbound
				local i = other.inbound
				debugPrint(LOG_PREFIX .. string.format("probe %s: out work %d shop %d usage %d lines %d | in work %d shop %d usage %d lines %d",
					other.name, o.work, o.shop, o.usageCount, o.linesUseCount, i.work, i.shop, i.usageCount, i.linesUseCount))
			end
		end
		-- END PROBE
		return rank.buildSections(towns, ROW_CAP, NEARBY_COUNT)
	end)
	if ok then
		return { sections = resultOrError as Sections, failed = false }
	end
	debugPrint(LOG_PREFIX .. "error for town " .. tostring(townEntity) .. ": " .. tostring(resultOrError))
	return { sections = nil, failed = true }
end

local function makeHint(text : string) : TreeNodeId
	return builtin.TextView{ meta = { class = "font-scale-annotation" }, text = text }
end

-- Styled like Cargo Compass's arrows: the base cargo-flow colours, with the passenger icon.
local function makeFlowLayerConfig(from : Vec3f, to : Vec3f, animated : boolean) : LayerConfig
	local colors = layerColors.CargoFlow.Consumers3D
	local flow = api.type.LayerConfig.CargoFlowRenderableConfig.FlowData.new()
	flow.from = from
	flow.to = to
	flow.speed = animated and 40.0 or 0.0
	flow.arrowColors = animated
		and color_util.toArray4(colors.Actual)
		or color_util.toArray4WithTransparency(colors.Potential, transparency.VeryLow)
	flow.cargoIconAlpha = animated and 1.0 or 0.6
	flow.cargoTypes = { api.res.cargoTypeRep.getPassengerCargoTypeId() }
	local cargoFlow = api.type.LayerConfig.CargoFlowRenderableConfig.new()
	cargoFlow.flowData = { flow }
	local layerConfig = api.type.LayerConfig.new()
	layerConfig.cargoFlowRenderableConfig = cargoFlow
	return layerConfig
end

local function frameCamera(from : Vec3f, to : Vec3f)
	local gap = rank.planarDistance(from.x, from.y, to.x, to.y)
	local distance = math.max(CAMERA_MIN_DISTANCE, gap * CAMERA_DISTANCE_FACTOR)
	local midpoint = api.type.Vec3f.new(0.5 * (from.x + to.x), 0.5 * (from.y + to.y), 0.5 * (from.z + to.z))
	api.gui.camera.focusPosition(midpoint, distance)
end

-- Binds a map action that draws one arrow and makes it the renderer's active owner override.
-- Unmounting clears the override and unbinds the action, handing the map back to the town window.
local FlowAction = react.RegisterRecipe("PgraceCommuterCompassFlowAction", function(params : FlowParams) : TreeNodeId
	local selection = params.selection
	local key = tostring(selection.from) .. ">" .. tostring(selection.to) .. (selection.animated and "+" or "-")
	local cacheRef : ReactRefT<FlowCache> = react.useRef(nil)
	local changed = cacheRef:get() == nil or cacheRef:get().key ~= key
	if changed then
		local from = commuters.getPosition3(selection.from)
		local to = commuters.getPosition3(selection.to)
		local action : function() : TreeNodeId = nil
		if from ~= nil and to ~= nil then
			action = selector_react_util.makeDefaultSelectorAction(params.gameCtx, makeFlowLayerConfig(from, to, selection.animated))
			frameCamera(from, to)
		else
			debugPrint(LOG_PREFIX .. "flow: no position for " .. key)
		end
		cacheRef:set({ key = key, action = action })
	end

	local selfRef = react.useAction(params.gameCtx.rendererComponent, cacheRef:get().action, FLOW_ACTION_KEY)

	local function setOverride(owner : ReactRefWrap | boolean) : boolean
		if params.gameCtx.rendererComponent:hasExpired() then
			return false
		end
		local rc = params.gameCtx.rendererComponent:get()
		if rc == nil or not rc:getIdentity() then
			return false
		end
		-- Not part of the documented API: degrade to "no arrow" rather than erroring if a game update removes it.
		local rcApi = rc:getApi() as any as ActiveOwnerApi
		if rcApi.setActiveOwnerOverride == nil then
			return false
		end
		rcApi.setActiveOwnerOverride(owner)
		return true
	end

	local function activate()
		setOverride(selfRef)
	end

	react.onMount(activate)
	if changed and cacheRef:get().action ~= nil and selfRef:get() ~= nil then
		activate()
	end
	react.onUnmount(function()
		setOverride(false)
	end)

	return builtin.BoxLayout{ children = {} }
end)

local function makeStat(icon : string, text : string, tooltip : string) : TreeNodeId
	return builtin.BoxLayout{
		meta = { tooltip = tooltip },
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			builtin.ImageView{ path = icon },
			builtin.TextView{ text = text },
		},
	}
end

-- One row: locate, arrow toggle, name (opens the town's window), distance, then the counts when `showCounts`.
local function makeRow(row : Row, flow : Selection, showCounts : boolean, selectionState : ReactStateT<Selection>) : TreeNodeId
	local current = selectionState:old()
	local isSelected = current ~= nil and current.from == flow.from and current.to == flow.to
	local children : {TreeNodeId} = {
		line_react_util.LocateButton{ entity = row.entity },
		builtin.ToggleButton{
			meta = { tooltip = _("Show on the map") },
			content = builtin.ImageView{
				path = ARROW_ICON,
				scaling = builtin.type.ImageViewScaling.AutoFit,
			},
			value = isSelected and 1 or 0,
			onValueChange = function(value : integer)
				if value == 1 then
					selectionState:set(flow)
				else
					selectionState:set(nil)
				end
			end,
		},
		line_react_util.makeEntityWindowButton(row.name, row.entity),
		builtin.TextView{ text = rank.formatDistance(row.distance) },
	}
	if showCounts then
		children[#children + 1] = makeStat(WORK_ICON, tostring(row.work), _("Work"))
		children[#children + 1] = makeStat(SHOP_ICON, tostring(row.shop), _("Shop"))
		children[#children + 1] = makeStat(LINE_ICON, rank.formatPercent(row.lineUsage), _("Line usage"))
	end
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = children,
	}
end

-- Expand/collapse state of one section, and how to flip it.
local record Fold
	expanded : boolean
	toggle : function()
end

local record SectionSpec
	title : string
	section : Section
	emptyText : string
	showCounts : boolean
	-- The arrow a row's toggle selects.
	flowOf : function(Row) : Selection
end

local function plural(count : integer, one : string, many : string) : string
	return tostring(count) .. " " .. (count == 1 and one or many)
end

-- Clickable header with the game's combobox arrows (as in collapsible_checkbox_list).
local function makeSectionHeader(title : string, fold : Fold) : TreeNodeId
	return builtin.Button{
		content = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				builtin.ImageView{
					path = fold.expanded and "::/gui/builtin/combobox/arrow_down.tga" or "::/gui/builtin/combobox/arrow_right.tga",
				},
				builtin.TextView{ text = title },
			},
		},
		onClick = fold.toggle,
	}
end

local function makeSection(spec : SectionSpec, fold : Fold, selectionState : ReactStateT<Selection>) : TreeNodeId
	local header = makeSectionHeader(spec.title, fold)
	if not fold.expanded then
		return header
	end
	local children : {TreeNodeId} = { header }
	if #spec.section.rows == 0 then
		children[#children + 1] = makeHint(spec.emptyText)
	else
		for _, row in ipairs(spec.section.rows) do
			children[#children + 1] = makeRow(row, spec.flowOf(row), spec.showCounts, selectionState)
		end
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
end

local function commuterTitle(label : string, section : Section) : string
	return label
		.. " · " .. plural(section.townCount, _("town"), _("towns"))
		.. " · " .. plural(section.commuterCount, _("commuter"), _("commuters"))
end

local function usesLines(row : Row) : boolean
	return (row.lineUsage or 0) > 0
end

-- All sections live in one list, so one selection state allows at most one arrow per window.
local CommuterList = react.RegisterRecipe("PgraceCommuterCompassList", function(params : ListParams) : TreeNodeId
	local state = react.useStateLazy(function() : ListState
		return computeState(params.entityId)
	end)
	local current = state:old()
	local selectionState = react.useStateLazy(function() : Selection
		return nil
	end)
	-- Sections the player opened; every section starts collapsed.
	local foldState = react.useStateLazy(function() : {string : boolean}
		return {}
	end)
	local function makeFold(key : string) : Fold
		local expanded = foldState:old()[key] == true
		return {
			expanded = expanded,
			toggle = function()
				local next : {string : boolean} = {}
				for k, v in pairs(foldState:old()) do
					next[k] = v
				end
				next[key] = not expanded
				foldState:set(next)
			end,
		}
	end

	local children : {TreeNodeId} = {}
	local function add(node : TreeNodeId)
		children[#children + 1] = node
	end
	local here = params.entityId

	if current.failed then
		add(makeHint(_("Commuter Compass: error (see log)")))
	else
		local sections = current.sections
		local noTowns = sections.outbound.townCount == 0 and sections.inbound.townCount == 0 and sections.nearby.townCount == 0
		if noTowns then
			add(makeHint(_("No other towns on this map")))
		else
			if sections.countsKnown then
				add(makeSection({
					title = commuterTitle(_("Outbound"), sections.outbound),
					section = sections.outbound,
					emptyText = _("No commuters leave this town."),
					showCounts = true,
					flowOf = function(row : Row) : Selection
						return { from = here, to = row.entity, animated = usesLines(row) }
					end,
				}, makeFold("out"), selectionState))
				add(makeSection({
					title = commuterTitle(_("Inbound"), sections.inbound),
					section = sections.inbound,
					emptyText = _("No commuters arrive from other towns."),
					showCounts = true,
					flowOf = function(row : Row) : Selection
						return { from = row.entity, to = here, animated = usesLines(row) }
					end,
				}, makeFold("in"), selectionState))
			else
				add(makeHint(_("Commuter data unavailable")))
			end
			if #sections.nearby.rows > 0 then
				-- Without commuter data every town lands here, so don't claim they have no commuters.
				local nearbyLabel = sections.countsKnown and _("Nearby, no commuters") or _("Nearest towns")
				add(makeSection({
					title = nearbyLabel .. " · " .. plural(#sections.nearby.rows, _("town"), _("towns")),
					section = sections.nearby,
					emptyText = "",
					showCounts = false,
					flowOf = function(row : Row) : Selection
						return { from = here, to = row.entity, animated = false }
					end,
				}, makeFold("nearby"), selectionState))
			end
		end
	end
	if selectionState:old() ~= nil then
		add(FlowAction{ gameCtx = params.gameCtx, selection = selectionState:old() })
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
end)

local TownPlugin = react.RegisterPluginRecipe(town_eow.TownEowExtensionPoint, "PgraceCommuterCompassTownPlugin", function(params : TownEow.TownWidgetPluginParams) : TreeNodeId
	return builtin.BoxLayout{
		child = content_card.ContentCard{
			title = _("Commuters"),
			initialCalloutTextPermanent = "",
			recipeAndParamPermanent = content_card.makeRecipeAndParam(CommuterList, { entityId = params.entityId, gameCtx = params.gameCtx } as ListParams),
			gameCtx = params.gameCtx,
			showOnRightSide = params.showCalloutOnRightSide,
		},
	}
end)

-- Hides the card on a single-town map. On error the card shows, so it can report the problem.
local function hasOtherTowns(_params : TownEow.TownWidgetPluginParams) : boolean
	local ok, countOrError = pcall(commuters.countTowns)
	return not ok or (countOrError as integer) > 1
end

debugPrint(LOG_PREFIX .. "script loaded")

return {
	TownPlugin = TownPlugin,
	hasOtherTowns = hasOtherTowns,
}
