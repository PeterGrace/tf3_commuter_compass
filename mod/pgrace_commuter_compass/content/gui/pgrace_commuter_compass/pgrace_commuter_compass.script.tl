local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local content_card = ug_require "::/gui/main/content_card.tl" as ContentCard
local line_react_util = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl" as LineReactUtil
local selector_react_util = ug_require "::/gui/main/selector_react_util.tl" as SelectorReactUtil
local color_util = ug_require "::/gui/main/color_util.tl" as ColorUtil
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local town_eow = ug_require "::/gui/entity_window/town/town_eow.script.tl" as TownEow
local station_group_eow = ug_require "::/gui/entity_window/station_group/station_group_eow.script.tl" as StationGroupEow
local commuters = ug_require "pgrace_commuter_compass::/gui/pgrace_commuter_compass/commuters.tl" as PgraceCommuterCompassCommuters
local rank = ug_require "pgrace_commuter_compass::/gui/pgrace_commuter_compass/rank.tl" as PgraceCommuterCompassRank
local waiting = ug_require "pgrace_commuter_compass::/gui/pgrace_commuter_compass/waiting.tl" as PgraceCommuterCompassWaiting

local layerColors = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/layers/layer_colors.gres")).data as LayerColors
local transparency = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/transparency.gres")).data as GResTransparency

local LOG_PREFIX = "[commuter_compass] "
local NEARBY_COUNT = 3
local FLOW_ACTION_KEY = "commuter_compass_flow"
-- Camera distance as a multiple of the gap between the towns (Cargo Compass uses 1.2), for a margin around both.
local CAMERA_DISTANCE_FACTOR = 1.6
local CAMERA_MIN_DISTANCE = 500
-- focusPosition caps the distance at the game's maximum zoom-out (about 4,055 m in testing).
local CAMERA_MAX_DISTANCE = 4000
-- How far to move the view toward screen-right, as a fraction of the camera distance, so the arrow is centred
-- in the map area left of the entity window (about the right quarter of a 16:9 screen).
local CAMERA_WINDOW_SHIFT = 0.27

-- The base town window's Destinations table icons (gui/entity_window/town/town.tl).
local WORK_ICON = "::/gui/entity_window/icons/building_industry.tga"
local SHOP_ICON = "::/gui/entity_window/icons/symbol_shopping_cart.tga"
local LINE_ICON = "::/gui/entity_window/icons/symbol_configure_line.tga"
local ARROW_ICON = "::/gui/entity_window/icons/symbol_arrow_up.tga"
local WAITING_ICON = "::/gui/entity_window/icons/symbol_person_multiple.tga"
-- Line names in the Waiting table are shortened in the middle to this many characters (the tooltip has them whole).
-- 14 fit with a " +N" suffix; without one there's room for a few more.
local LINE_NAME_MAX_CHARS = 17

local type Row = PgraceCommuterCompassRank.Row
local type Section = PgraceCommuterCompassRank.Section
local type Sections = PgraceCommuterCompassRank.Sections
local type WaitingRow = PgraceCommuterCompassRank.WaitingRow
local type WaitingTable = PgraceCommuterCompassRank.WaitingTable

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
	-- Waiting table only: the line of the row that set the arrow, so only that row's toggle lights up (a destination
	-- has a row per line, and they all share one arrow).
	via : Engine.Entity
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
		local towns = commuters.gather(townEntity)
		-- No row cap: the tables scroll and sort, and sorting a cut-off list would mislead.
		return rank.buildSections(towns, #towns, NEARBY_COUNT)
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

-- Moves the camera's look-at point toward screen-right, so the midpoint lands in the middle of the map area
-- left of the entity window. Screen-right comes from the camera's eye and centre; world2Screen confirms the sign.
local function shiftClearOfWindow(midpoint : Vec3f, distance : number) : Vec3f
	local camera = api.gui.camera
	local eye = camera.getEye()
	local center = camera.getCenter()
	local fx, fy = center.x - eye.x, center.y - eye.y
	local length = math.sqrt(fx * fx + fy * fy)
	if length < 1e-3 then
		return midpoint
	end
	local rx, ry = fy / length, -fx / length
	local probe = api.type.Vec3f.new(center.x + 100 * rx, center.y + 100 * ry, center.z)
	if camera.world2Screen(probe).x < camera.world2Screen(center).x then
		rx, ry = -rx, -ry
	end
	local shift = CAMERA_WINDOW_SHIFT * math.min(distance, CAMERA_MAX_DISTANCE)
	return api.type.Vec3f.new(midpoint.x + shift * rx, midpoint.y + shift * ry, midpoint.z)
end

local function frameCamera(from : Vec3f, to : Vec3f)
	local gap = rank.planarDistance(from.x, from.y, to.x, to.y)
	local distance = math.max(CAMERA_MIN_DISTANCE, gap * CAMERA_DISTANCE_FACTOR)
	local midpoint = api.type.Vec3f.new(0.5 * (from.x + to.x), 0.5 * (from.y + to.y), 0.5 * (from.z + to.z))
	local ok, target = pcall(shiftClearOfWindow, midpoint, distance)
	if not ok then
		debugPrint(LOG_PREFIX .. "camera shift failed: " .. tostring(target))
		target = midpoint
	end
	api.gui.camera.focusPosition(target as Vec3f, distance)
end

-- Binds a map action that draws one arrow and makes it the renderer's active owner override.
-- Unmounting clears the override and unbinds the action, handing the map back to the town window.
local FlowAction = react.RegisterRecipe("PgraceCommuterCompassFlowAction", function(params : FlowParams) : TreeNodeId
	local selection = params.selection
	local key = tostring(selection.from) .. ">" .. tostring(selection.to) .. (selection.animated and "+" or "-")
	local cacheRef : ReactRefT<FlowCache> = react.useRef(nil)
	local changed = cacheRef:get() == nil or cacheRef:get().key ~= key
	if changed then
		local from = waiting.positionOf(selection.from)
		local to = waiting.positionOf(selection.to)
		local action : function() : TreeNodeId = nil
		if from ~= nil and to ~= nil then
			action = selector_react_util.makeDefaultSelectorAction(params.gameCtx, makeFlowLayerConfig(from, to, selection.animated))
			frameCamera(from, to)
		else
			debugPrint(LOG_PREFIX .. "flow: no position for " .. key)
		end
		cacheRef:set({ key = key, action = action })
	end

	-- One action key per arrow: switching arrows while bound under a single key kept the old arrow on screen
	-- (the renderer only picked the new one up after a fresh mount).
	local selfRef = react.useAction(params.gameCtx.rendererComponent, cacheRef:get().action, FLOW_ACTION_KEY .. ":" .. key)

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

local function usesLines(row : Row) : boolean
	return (row.lineUsage or 0) > 0
end

local enum Direction
	"Out"
	"In"
	"Nearby"
end

local DIRECTION_INDEX : {Direction : integer} = { Out = 0, In = 1, Nearby = 2 }

-- Row keys are unique across the card's tables: town entity * 3 + section. With plain entity ids, two tables using
-- the same cell recipes got their cells mixed up (the Outbound table showed Inbound's numbers and selections).
local function rowKeyOf(entity : Engine.Entity, direction : Direction) : integer
	return entity * 3 + DIRECTION_INDEX[direction]
end

-- One object for the whole card, built once and handed to every table as `userParam`, so whichever table a cell
-- ends up attached to, it finds its row and section by row key. The data is fixed while the window is open; only
-- the selection changes, and cells poll it.
local record CardData
	here : Engine.Entity
	rows : {integer : Row}
	directions : {integer : Direction}
	selectionState : ReactStateT<Selection>
end

-- The arrow a row's toggle selects: passengers travel towards whoever they commute to.
local function flowFor(data : CardData, rowKey : integer) : Selection
	local row = data.rows[rowKey]
	local direction = data.directions[rowKey]
	if direction == "In" then
		return { from = row.entity, to = data.here, animated = usesLines(row) }
	end
	return { from = data.here, to = row.entity, animated = direction == "Out" and usesLines(row) }
end

local function isSelected(data : CardData, flow : Selection) : boolean
	local current = data.selectionState:old()
	return current ~= nil and current.from == flow.from and current.to == flow.to
end

-- Locate, arrow toggle, and the name (opens the town's window), as the base Destinations table's name cell.
local NameCell = react.RegisterRecipe("PgraceCommuterCompassNameCell", function(params : Builtin.TableCellParam) : TreeNodeId
	local data = params.userParam as CardData
	local row = data.rows[params.rowKey]
	if row == nil then
		-- Never expected; an empty cell beats crashing the whole UI.
		return builtin.BoxLayout{ children = {} }
	end
	local flow = flowFor(data, params.rowKey)
	-- Cells keep their first userParam, so the toggle polls the shared selection to follow other rows' clicks.
	local selectedState = engine_react_util.useStepState(function() : boolean
		return isSelected(data, flow)
	end)
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			line_react_util.LocateButton{ entity = row.entity },
			builtin.ToggleButton{
				meta = { tooltip = _("Show on the map") },
				content = builtin.ImageView{
					path = ARROW_ICON,
					scaling = builtin.type.ImageViewScaling.AutoFit,
				},
				value = selectedState:old() and 1 or 0,
				onValueChange = function(value : integer)
					if value == 1 then
						data.selectionState:set(flow)
					elseif isSelected(data, flow) then
						data.selectionState:set(nil)
					end
				end,
			},
			line_react_util.makeEntityWindowButton(row.name, row.entity),
		},
	}
end)

local function makeTextCell(name : string, textOf : function(Row) : string) : Recipe<Builtin.TableCellParam>
	return react.RegisterRecipe(name, function(params : Builtin.TableCellParam) : TreeNodeId
		local data = params.userParam as CardData
		local row = data.rows[params.rowKey]
		-- A recipe must return a layout; a bare TextView crashes the whole UI ("Recipe child must be a layout").
		return builtin.BoxLayout{
			children = {
				builtin.TextView{
					meta = { class = "font-scale-body" },
					text = row ~= nil and textOf(row) or "",
				},
			},
		}
	end)
end

local DistanceCell = makeTextCell("PgraceCommuterCompassDistanceCell", function(row : Row) : string
	return rank.formatDistance(row.distance)
end)
local WorkCell = makeTextCell("PgraceCommuterCompassWorkCell", function(row : Row) : string
	return tostring(row.work)
end)
local ShopCell = makeTextCell("PgraceCommuterCompassShopCell", function(row : Row) : string
	return tostring(row.shop)
end)
local LineUsageCell = makeTextCell("PgraceCommuterCompassLineUsageCell", function(row : Row) : string
	return rank.formatPercent(row.lineUsage)
end)

-- The base game's table: icons once in the header, aligned columns, sortable by clicking a header.
-- Starts sorted by distance (column 2), nearest first.
local function makeTable(section : Section, direction : Direction, data : CardData, showCounts : boolean) : TreeNodeId
	local rowKeys : {integer} = {}
	for i, row in ipairs(section.rows) do
		rowKeys[i] = rowKeyOf(row.entity, direction)
	end
	local function rowOf(rowKey : integer) : Row
		return data.rows[rowKey]
	end

	local columns : {TreeNodeId} = {
		builtin.ColumnDesc{
			name = _("Town"),
			recipe = NameCell,
			getCompareValue = function(rowKey : integer) : any
				return rowOf(rowKey).name
			end,
			weight = 1,
		},
		builtin.ColumnDesc{
			name = _("Distance"),
			recipe = DistanceCell,
			getCompareValue = function(rowKey : integer) : any
				return rowOf(rowKey).distance
			end,
		},
	}
	if showCounts then
		columns[#columns + 1] = builtin.ColumnDesc{
			tooltip = _("Work"),
			path = WORK_ICON,
			recipe = WorkCell,
			getCompareValue = function(rowKey : integer) : any
				return rowOf(rowKey).work
			end,
		}
		columns[#columns + 1] = builtin.ColumnDesc{
			tooltip = _("Shop"),
			path = SHOP_ICON,
			recipe = ShopCell,
			getCompareValue = function(rowKey : integer) : any
				return rowOf(rowKey).shop
			end,
		}
		columns[#columns + 1] = builtin.ColumnDesc{
			tooltip = _("Line usage"),
			path = LINE_ICON,
			recipe = LineUsageCell,
			getCompareValue = function(rowKey : integer) : any
				return rowOf(rowKey).lineUsage or 0
			end,
		}
	end

	return builtin.DataTable{
		columns = columns,
		rowKeys = rowKeys,
		userParam = data,
		initialSortColumn = { 2, true },
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
	direction : Direction
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

local function makeSection(spec : SectionSpec, data : CardData, fold : Fold) : TreeNodeId
	local header = makeSectionHeader(spec.title, fold)
	if not fold.expanded then
		return header
	end
	local body : TreeNodeId
	if #spec.section.rows == 0 then
		body = makeHint(spec.emptyText)
	else
		body = makeTable(spec.section, spec.direction, data, spec.showCounts)
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = { header, body } }
end

local function tripTitle(label : string, section : Section) : string
	return label
		.. " · " .. plural(section.townCount, _("town"), _("towns"))
		.. " · " .. plural(section.tripCount, _("trip"), _("trips"))
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
	-- Every section's rows, registered once (also for collapsed sections), so cells always find theirs.
	local cardData = react.useStateLazy(function() : CardData
		local data : CardData = { here = params.entityId, rows = {}, directions = {}, selectionState = selectionState }
		local sections = current.sections
		if sections ~= nil then
			local function register(section : Section, direction : Direction)
				for _, row in ipairs(section.rows) do
					local rowKey = rowKeyOf(row.entity, direction)
					data.rows[rowKey] = row
					data.directions[rowKey] = direction
				end
			end
			register(sections.outbound, "Out")
			register(sections.inbound, "In")
			register(sections.nearby, "Nearby")
		end
		return data
	end):old()

	local children : {TreeNodeId} = {}
	local function add(node : TreeNodeId)
		children[#children + 1] = node
	end

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
					title = tripTitle(_("Outbound"), sections.outbound),
					section = sections.outbound,
					emptyText = _("No commuters leave this town."),
					showCounts = true,
					direction = "Out",
				}, cardData, makeFold("out")))
				add(makeSection({
					title = tripTitle(_("Inbound"), sections.inbound),
					section = sections.inbound,
					emptyText = _("No commuters arrive from other towns."),
					showCounts = true,
					direction = "In",
				}, cardData, makeFold("in")))
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
					direction = "Nearby",
				}, cardData, makeFold("nearby")))
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

-- ---------------------------------------------------------------------------------------------------------------
-- Station window: Waiting passengers
-- ---------------------------------------------------------------------------------------------------------------

local record WaitingState
	waitingTable : WaitingTable
	failed : boolean
end

-- The card recounts on this timer while the window is open (the base terminals view updates about as often).
-- A count takes a few ms even at a busy hub.
local WAITING_UPDATE_SECONDS = 1.0

-- Last error logged, so a persistent failure isn't logged on every update.
local lastWaitingError : string = nil

local function computeWaiting(stationGroup : Engine.Entity) : WaitingState
	local ok, resultOrError = pcall(waiting.count, stationGroup)
	if ok then
		lastWaitingError = nil
		return { waitingTable = resultOrError as WaitingTable, failed = false }
	end
	local message = tostring(resultOrError)
	if message ~= lastWaitingError then
		lastWaitingError = message
		debugPrint(LOG_PREFIX .. "waiting: error for station " .. tostring(stationGroup) .. ": " .. message)
	end
	return { waitingTable = nil, failed = true }
end

-- One object for the card's lifetime, handed to the table as `userParam`. Cells keep their first userParam, so
-- every update refills `rows` in place and the cells poll it.
local record WaitingData
	here : Engine.Entity
	rows : {integer : WaitingRow}
	selectionState : ReactStateT<Selection>
	-- Row key per "destination:line", handed out once, so a destination and line keep their row (and cells) across
	-- updates.
	keys : {string : integer}
	nextKey : integer
end

local function waitingRowKey(data : WaitingData, row : WaitingRow) : integer
	local id = tostring(row.destination or 0) .. ":" .. tostring(row.line)
	local key = data.keys[id]
	if key == nil then
		data.nextKey = data.nextKey + 1
		key = data.nextKey
		data.keys[id] = key
	end
	return key
end

local function waitingFlow(data : WaitingData, row : WaitingRow) : Selection
	return { from = data.here, to = row.destination, animated = true, via = row.line }
end

-- Locate, arrow toggle, and the name (opens the destination's window). Unknown rows are plain text.
-- A row key always means the same destination and line, so only the selection needs polling here.
local WaitingNameCell = react.RegisterRecipe("PgraceCommuterCompassWaitingNameCell", function(params : Builtin.TableCellParam) : TreeNodeId
	local data = params.userParam as WaitingData
	local row = data.rows[params.rowKey]
	if row == nil then
		return builtin.BoxLayout{ children = {} }
	end
	if row.destination == nil then
		return builtin.BoxLayout{ children = { builtin.TextView{ meta = { class = "font-scale-body" }, text = row.name } } }
	end
	local flow = waitingFlow(data, row)
	local function selected() : boolean
		local current = data.selectionState:old()
		return current ~= nil and current.from == flow.from and current.to == flow.to and current.via == flow.via
	end
	local selectedState = engine_react_util.useStepState(selected)
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			line_react_util.LocateButton{ entity = row.destination },
			builtin.ToggleButton{
				meta = { tooltip = _("Show on the map") },
				content = builtin.ImageView{ path = ARROW_ICON, scaling = builtin.type.ImageViewScaling.AutoFit },
				value = selectedState:old() and 1 or 0,
				onValueChange = function(value : integer)
					if value == 1 then
						data.selectionState:set(flow)
					elseif selected() then
						data.selectionState:set(nil)
					end
				end,
			},
			line_react_util.makeEntityWindowButton(row.name, row.destination),
		},
	}
end)

-- A text cell that follows its row's latest numbers.
local function waitingText(name : string, textOf : function(WaitingRow) : string) : Recipe<Builtin.TableCellParam>
	return react.RegisterRecipe(name, function(params : Builtin.TableCellParam) : TreeNodeId
		local data = params.userParam as WaitingData
		local textState = engine_react_util.useStepState(function() : string
			local row = data.rows[params.rowKey]
			return row ~= nil and textOf(row) or ""
		end)
		-- A recipe must return a layout; a bare TextView crashes the whole UI.
		return builtin.BoxLayout{
			children = { builtin.TextView{ meta = { class = "font-scale-body" }, text = textState:old() } },
		}
	end)
end

local WaitingDistanceCell = waitingText("PgraceCommuterCompassWaitingDistanceCell", function(row : WaitingRow) : string
	return row.distance ~= nil and rank.formatDistance(row.distance) or "-"
end)
local WaitingCountCell = waitingText("PgraceCommuterCompassWaitingCountCell", function(row : WaitingRow) : string
	return tostring(row.waiting)
end)

local record LineCellState
	label : string
	-- The full name when the label is shortened.
	tooltip : string
	line : Engine.Entity
end

-- The line's name, shortened in the middle when long; it opens the line window.
local WaitingLineCell = react.RegisterRecipe("PgraceCommuterCompassWaitingLineCell", function(params : Builtin.TableCellParam) : TreeNodeId
	local data = params.userParam as WaitingData
	local cellState = engine_react_util.useStepState(function() : LineCellState
		local row = data.rows[params.rowKey]
		if row == nil then
			return { label = "", tooltip = nil, line = nil }
		end
		local label = rank.shortenMiddle(row.lineName, LINE_NAME_MAX_CHARS)
		return { label = label, tooltip = label ~= row.lineName and row.lineName or nil, line = row.line }
	end)
	local current = cellState:old()
	if current.line == nil then
		return builtin.BoxLayout{ children = {} }
	end
	-- A tooltip must go on the button itself; on a BoxLayout it never shows.
	return builtin.BoxLayout{
		children = {
			line_react_util.makeEntityWindowButton(current.label, current.line, nil, nil, nil, nil, current.tooltip),
		},
	}
end)

-- Starts sorted by Waiting (column 3), largest first.
local function makeWaitingTable(rowKeys : {integer}, data : WaitingData) : TreeNodeId
	-- Rows are refilled on every update; a key the table still holds from before sorts as an empty row.
	local EMPTY_ROW : WaitingRow = { name = "", lineName = "", waiting = 0 }
	local function rowOf(rowKey : integer) : WaitingRow
		return data.rows[rowKey] or EMPTY_ROW
	end
	return builtin.DataTable{
		columns = {
			builtin.ColumnDesc{
				name = _("Destination"),
				recipe = WaitingNameCell,
				getCompareValue = function(rowKey : integer) : any
					return rowOf(rowKey).name
				end,
				-- Slightly more than Line: just enough for names like "South Valley" beside the two buttons.
				weight = 7,
			},
			builtin.ColumnDesc{
				name = _("Distance"),
				recipe = WaitingDistanceCell,
				getCompareValue = function(rowKey : integer) : any
					return rowOf(rowKey).distance or math.huge
				end,
			},
			builtin.ColumnDesc{
				-- An icon header (as the base Destinations table) keeps the column as narrow as its numbers.
				tooltip = _("Waiting"),
				path = WAITING_ICON,
				recipe = WaitingCountCell,
				getCompareValue = function(rowKey : integer) : any
					return rowOf(rowKey).waiting
				end,
			},
			builtin.ColumnDesc{
				name = _("Line"),
				recipe = WaitingLineCell,
				getCompareValue = function(rowKey : integer) : any
					return rowOf(rowKey).lineName
				end,
				-- Without a weight the column takes its widest content; long line names ("Bus Passengers-CouClu-LO-1")
				-- then squeezed Destination to nothing and its buttons were drawn under Distance.
				weight = 6,
			},
		},
		rowKeys = rowKeys,
		userParam = data,
		initialSortColumn = { 3, false },
	}
end

local WaitingList = react.RegisterRecipe("PgraceCommuterCompassWaitingList", function(params : ListParams) : TreeNodeId
	local state = engine_react_util.useStepStateTimer(function() : WaitingState
		return computeWaiting(params.entityId)
	end, WAITING_UPDATE_SECONDS)
	local selectionState = react.useStateLazy(function() : Selection
		return nil
	end)
	local data = react.useStateLazy(function() : WaitingData
		return { here = params.entityId, rows = {}, selectionState = selectionState, keys = {}, nextKey = 0 }
	end):old()
	local current = state:old()

	local children : {TreeNodeId} = {}
	local function add(node : TreeNodeId)
		children[#children + 1] = node
	end

	if current.failed then
		add(makeHint(_("Commuter Compass: error (see log)")))
	else
		local tbl = current.waitingTable
		add(builtin.TextView{
			text = _("Waiting") .. " · " .. plural(tbl.totalWaiting, _("person"), _("people"))
				.. " · " .. plural(tbl.destinationCount, _("destination"), _("destinations")),
		})
		-- Refill in place: cells read rows from this same object.
		for key in pairs(data.rows) do
			data.rows[key] = nil
		end
		local rowKeys : {integer} = {}
		for i, row in ipairs(tbl.rows) do
			rowKeys[i] = waitingRowKey(data, row)
			data.rows[rowKeys[i]] = row
		end
		if #rowKeys == 0 then
			add(makeHint(_("Nobody is waiting here.")))
		else
			add(makeWaitingTable(rowKeys, data))
		end
	end
	-- The arrow stays until the player turns it off, even if its destination drops out of the list for a moment.
	if selectionState:old() ~= nil then
		add(FlowAction{ gameCtx = params.gameCtx, selection = selectionState:old() })
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
end)

local StationPlugin = react.RegisterPluginRecipe(station_group_eow.StationGroupEowExtensionPoint, "PgraceCommuterCompassStationPlugin", function(params : StationGroupEow.StationGroupWidgetPluginParams) : TreeNodeId
	return builtin.BoxLayout{
		child = content_card.ContentCard{
			title = _("Waiting passengers"),
			initialCalloutTextPermanent = "",
			recipeAndParamPermanent = content_card.makeRecipeAndParam(WaitingList, { entityId = params.entityId, gameCtx = params.gameCtx } as ListParams),
			gameCtx = params.gameCtx,
			showOnRightSide = params.showCalloutOnRightSide,
		},
	}
end)

-- Hides the card on cargo-only stations and stations none of the player's lines serve. Shows on error.
local function hasPassengerLines(params : StationGroupEow.StationGroupWidgetPluginParams) : boolean
	local ok, resultOrError = pcall(waiting.hasPassengerLines, params.entityId)
	return not ok or resultOrError as boolean
end

debugPrint(LOG_PREFIX .. "script loaded")

return {
	TownPlugin = TownPlugin,
	hasOtherTowns = hasOtherTowns,
	StationPlugin = StationPlugin,
	hasPassengerLines = hasPassengerLines,
}
