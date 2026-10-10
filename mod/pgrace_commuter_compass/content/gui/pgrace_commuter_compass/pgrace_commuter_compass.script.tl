local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local content_card = ug_require "::/gui/main/content_card.tl" as ContentCard
local line_react_util = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl" as LineReactUtil
local selector_react_util = ug_require "::/gui/main/selector_react_util.tl" as SelectorReactUtil
local color_util = ug_require "::/gui/main/color_util.tl" as ColorUtil
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local town_eow = ug_require "::/gui/entity_window/town/town_eow.script.tl" as TownEow
local callout_react_util = ug_require "::/gui/main/callout_react_util.tl" as CalloutReactUtil
local styleutil = ug_require "::/gui/main/styleutil.tl" as StyleUtil
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
-- The cargo-flow arrow is drawn as an arc this high (as a share of its length); the distance label sits on its top.
-- Measured by eye; it matched both short and long arrows.
local ARROW_ARC_HEIGHT = 0.06

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

-- Distances and counts in the player's language and units ("2,2 km" in German, miles if chosen). The game's
-- formatters, with our plain ones as the fallback should a call fail.
local function formatDistance(metres : number) : string
	local ok, text = pcall(api.util.formatLength, metres)
	if ok and text ~= nil then
		return text as string
	end
	return rank.formatDistance(metres)
end

local function formatCount(count : integer) : string
	local ok, text = pcall(api.util.lang.formatInt, count)
	if ok and text ~= nil then
		return text as string
	end
	return tostring(count)
end

-- "45%", or as the player's language writes it (German: "45 %").
local function formatPercent(fraction : number) : string
	local text = rank.formatPercent(fraction)
	if text:sub(-1) ~= "%" then
		return text
	end
	local number = text:sub(1, -2)
	return (_("{percent}%"):gsub("{percent}", function() : string return number end))
end

local record ArrowLabelParams is IRecipeParamWithMeta
	text : string
end

local ArrowLabel = react.RegisterRecipe("PgraceCommuterCompassArrowLabel", function(params : ArrowLabelParams) : TreeNodeId
	return builtin.BoxLayout{
		children = { builtin.TextView{ meta = { class = "font-scale-body" }, text = params.text } },
	}
end)

local record ArrowLabelLayerParams
	from : Vec3f
	to : Vec3f
	text : string
end

-- The arrow's distance, drawn at the top of its arc. A full-screen layer of the arrow's own map action (as the town
-- window draws its layer legend), so it comes and goes with the arrow and other popups can't displace it.
local ArrowLabelLayer = react.RegisterRecipe("PgraceCommuterCompassArrowLabelLayer", function(params : ArrowLabelLayerParams) : TreeNodeId
	react.setMouseTransparent(true)
	react.setDisableFocusable(true)
	local a, b = params.from, params.to
	local lift = ARROW_ARC_HEIGHT * rank.planarDistance(a.x, a.y, b.x, b.y)
	local top = api.type.Vec3f.new(0.5 * (a.x + b.x), 0.5 * (a.y + b.y), 0.5 * (a.z + b.z) + lift)
	-- Where the label goes, in fractions of the screen; nil while unknown or behind the camera.
	local positionState : ReactStateT<Vec2f> = react.useState(nil)
	react.onStep(function()
		-- world2Screen is restricted during the react step ("API is currently restricted"), so it runs in a join on
		-- the main thread, as the base mission task list does with api.gui.byId.
		react.enqueueJoin(function()
			local ok, point = pcall(api.gui.camera.world2Screen, top)
			local sizeOk, size = pcall(api.gui.camera.getSize)
			if not ok or not sizeOk or point == nil or size == nil then
				return
			end
			local pixel, viewport = point as Vec2i, size as Vec2i
			if viewport.x <= 0 or viewport.y <= 0 then
				return
			end
			-- world2Screen gives viewport pixels; the floating layout places things in fractions of the screen.
			local h, v = pixel.x / viewport.x, pixel.y / viewport.y
			local old = positionState:old()
			if old == nil or old.x ~= h or old.y ~= v then
				positionState:set(api.type.Vec2f.new(h, v))
			end
		end, "PgraceCommuterCompassArrowLabelLayer")
	end)
	local position = positionState:old()
	if position == nil or position.x < 0 or position.x > 1 or position.y < 0 or position.y > 1 then
		return builtin.FloatingLayout{ children = {} }
	end
	-- arrow_label.css.lua makes this floating layout fill the screen (gravity -1, -1), as the game's stylesheet does
	-- for the callout container; then h and v place the label anywhere on it.
	return builtin.FloatingLayout{
		children = {
			builtin.FloatingLayoutChild{
				h = position.x,
				v = position.y,
				-- Keeps the label on screen near the edges, as the callout container does. (The tealdef types this field
				-- as boolean, but the game passes the enum.)
				overflowMode = builtin.type.FloatingLayoutOverflowMode.KeepInside as any as boolean,
				item = callout_react_util.DefaultCalloutWrapper{
					meta = { styleSheet = styleutil.makeStyle{ anchorPoint = api.type.Vec2f.new(0.5, 0.5) } },
					recipe = ArrowLabel,
					recipeParam = { text = params.text } as ArrowLabelParams,
				},
			},
		},
	}
end)

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
			local distance = rank.planarDistance(from.x, from.y, to.x, to.y)
			action = selector_react_util.makeDefaultSelectorAction(params.gameCtx, makeFlowLayerConfig(from, to, selection.animated),
				nil, function() : TreeNodeId
					return builtin.FullScreenComponent{
						recipe = ArrowLabelLayer,
						param = { from = from, to = to, text = formatDistance(distance) } as ArrowLabelLayerParams,
					}
				end)
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
	-- After a header click in a section's table: that section, and frames left until its header is scrolled into
	-- view. A re-sorting table keeps its current row (the last row clicked, else the first) in view, which scrolls the
	-- window to mid-list.
	scrollSection : Direction
	scrollSteps : integer
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
	return formatDistance(row.distance)
end)
local WorkCell = makeTextCell("PgraceCommuterCompassWorkCell", function(row : Row) : string
	return formatCount(row.work)
end)
local ShopCell = makeTextCell("PgraceCommuterCompassShopCell", function(row : Row) : string
	return formatCount(row.shop)
end)
local LineUsageCell = makeTextCell("PgraceCommuterCompassLineUsageCell", function(row : Row) : string
	return formatPercent(row.lineUsage)
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
		onSortColumnChange = function(_column : integer, _ascending : boolean)
			data.scrollSection = direction
			data.scrollSteps = 3
		end,
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

-- A count with its noun, in the form the player's language uses for that count. Each form is its own key
-- ("{count} towns|one", "|few", "|many", "|other"); a language translates only the forms its plural rule uses
-- (tools/release_check.py knows which). Mods get no plural-aware gettext, so the rule is ours (rank.pluralCategory).
local record PluralForms
	one : string
	few : string
	many : string
	other : string
end

local function currentLanguage() : string
	local ok, code = pcall(function() : string
		return app.getUserProfile():getLanguage().code
	end)
	return ok and code as string or "en"
end

local function countText(count : integer, forms : PluralForms) : string
	local category = rank.pluralCategory(currentLanguage(), count)
	local template = (forms as {string : string})[category] or forms.other
	local number = formatCount(count)
	return (template:gsub("{count}", function() : string return number end))
end

local function townsText(count : integer) : string
	return countText(count, {
		one = _("{count} towns|one"), few = _("{count} towns|few"),
		many = _("{count} towns|many"), other = _("{count} towns|other"),
	})
end

-- Clickable header with the game's combobox arrows (as in collapsible_checkbox_list).
local function makeSectionHeader(title : string, fold : Fold, ref : RefFill) : TreeNodeId
	return builtin.Button(ref, {
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
	})
end

local function makeSection(spec : SectionSpec, data : CardData, fold : Fold, headerRef : RefFill) : TreeNodeId
	local header = makeSectionHeader(spec.title, fold, headerRef)
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
		.. " · " .. townsText(section.townCount)
		.. " · " .. countText(section.tripCount, {
			one = _("{count} trips|one"), few = _("{count} trips|few"),
			many = _("{count} trips|many"), other = _("{count} trips|other"),
		})
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
		local data : CardData = {
			here = params.entityId, rows = {}, directions = {}, selectionState = selectionState, scrollSteps = 0,
		}
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
	local headerRefs = {
		Out = react.useNodeRef(builtin.Button),
		In = react.useNodeRef(builtin.Button),
		Nearby = react.useNodeRef(builtin.Button),
	}
	-- After a sort, scroll the window back up to that section's header, a few frames later so the table has re-sorted.
	-- (The table's own scrollToRowKey only scrolls inside the table, not the window.)
	react.onStep(function()
		if cardData.scrollSteps <= 0 then
			return
		end
		cardData.scrollSteps = cardData.scrollSteps - 1
		if cardData.scrollSteps == 0 then
			local headerRef = headerRefs[cardData.scrollSection]
			local node = headerRef and headerRef:get()
			if node ~= nil then
				node:ensureVisible()
			end
		end
	end)

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
				}, cardData, makeFold("out"), react.ref(headerRefs.Out)))
				add(makeSection({
					title = tripTitle(_("Inbound"), sections.inbound),
					section = sections.inbound,
					emptyText = _("No commuters arrive from other towns."),
					showCounts = true,
					direction = "In",
				}, cardData, makeFold("in"), react.ref(headerRefs.In)))
			else
				add(makeHint(_("Commuter data unavailable")))
			end
			if #sections.nearby.rows > 0 then
				-- Without commuter data every town lands here, so don't claim they have no commuters.
				local nearbyLabel = sections.countsKnown and _("Nearby, no commuters") or _("Nearest towns")
				add(makeSection({
					title = nearbyLabel .. " · " .. townsText(#sections.nearby.rows),
					section = sections.nearby,
					emptyText = "",
					showCounts = false,
					direction = "Nearby",
				}, cardData, makeFold("nearby"), react.ref(headerRefs.Nearby)))
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

-- The card recounts on this timer while the window is open. A count takes a few ms even at a busy hub.
local WAITING_UPDATE_SECONDS = 2.0
-- The cells check the shared rows on this timer rather than every frame: a busy station has a few hundred cells.
local WAITING_CELL_POLL_SECONDS = 0.25

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

local record LineCellState
	label : string
	-- The full name when the label is shortened.
	tooltip : string
	line : Engine.Entity
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
	-- Every row key handed out, in order. The table gets this list and hides the rows nobody waits for now
	-- (`fnUserFilter`): changing the table's row keys rebuilds it, and the window then jumps to mid-table.
	rowKeys : {integer}
	-- The latest row for every key handed out, kept while the row is hidden. A key always means the same destination
	-- and line, so the name cell (which doesn't poll) reads this.
	known : {integer : WaitingRow}
	-- The line cell's label per row key, shortened once rather than on every poll.
	lineLabels : {integer : LineCellState}
	-- The rows as they were at the last sort; the table sorts on these. The table keeps the clicked row in view, so
	-- re-sorting on live counts made the window chase that row up and down. Refreshed on a header click.
	sortRows : {integer : WaitingRow}
	-- Frames left until the header is scrolled into view after a header click (0: nothing pending).
	scrollSteps : integer
	-- The current sort, to tell a header click from the table reporting its initial sort.
	sortColumn : integer
	sortAscending : boolean
end

-- A column's sort value.
local WAITING_SORT_VALUES : {function(WaitingRow) : any} = {
	function(row : WaitingRow) : any return row.name end,
	function(row : WaitingRow) : any return row.distance or math.huge end,
	function(row : WaitingRow) : any return row.waiting end,
	function(row : WaitingRow) : any return row.lineName end,
}

local function waitingRowKey(data : WaitingData, row : WaitingRow) : integer
	local id = tostring(row.destination or 0) .. ":" .. tostring(row.line)
	local key = data.keys[id]
	if key == nil then
		data.nextKey = data.nextKey + 1
		key = data.nextKey
		data.keys[id] = key
		-- A new list, so the table sees the change.
		local rowKeys : {integer} = {}
		for i, k in ipairs(data.rowKeys) do
			rowKeys[i] = k
		end
		rowKeys[#rowKeys + 1] = key
		data.rowKeys = rowKeys
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
	local row = data.known[params.rowKey]
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
	local selectedState = engine_react_util.useStepStateTimer(selected, WAITING_CELL_POLL_SECONDS)
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
		local textState = engine_react_util.useStepStateTimer(function() : string
			local row = data.rows[params.rowKey]
			return row ~= nil and textOf(row) or ""
		end, WAITING_CELL_POLL_SECONDS)
		-- A recipe must return a layout; a bare TextView crashes the whole UI.
		return builtin.BoxLayout{
			children = { builtin.TextView{ meta = { class = "font-scale-body" }, text = textState:old() } },
		}
	end)
end

local WaitingDistanceCell = waitingText("PgraceCommuterCompassWaitingDistanceCell", function(row : WaitingRow) : string
	return row.distanceText or "-"
end)
local WaitingCountCell = waitingText("PgraceCommuterCompassWaitingCountCell", function(row : WaitingRow) : string
	return row.waitingText or ""
end)

-- The line's name, shortened in the middle when long; it opens the line window.
local WaitingLineCell = react.RegisterRecipe("PgraceCommuterCompassWaitingLineCell", function(params : Builtin.TableCellParam) : TreeNodeId
	local data = params.userParam as WaitingData
	local NO_LINE : LineCellState = { label = "", tooltip = nil, line = nil }
	local cellState = engine_react_util.useStepStateTimer(function() : LineCellState
		return data.lineLabels[params.rowKey] or NO_LINE
	end, WAITING_CELL_POLL_SECONDS)
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

-- Sorts on the rows saved at the last sort (`data.sortRows`), so live counts don't reorder it.
local function makeWaitingTable(data : WaitingData, onSort : function(integer, boolean)) : TreeNodeId
	-- Rows are refilled on every update; a key the table still holds from before sorts as an empty row.
	local EMPTY_ROW : WaitingRow = { name = "", lineName = "", waiting = 0 }
	local function rowOf(rowKey : integer) : WaitingRow
		return data.sortRows[rowKey] or EMPTY_ROW
	end
	return builtin.DataTable{
		columns = {
			builtin.ColumnDesc{
				name = _("Destination"),
				recipe = WaitingNameCell,
				getCompareValue = function(rowKey : integer) : any
					return WAITING_SORT_VALUES[1](rowOf(rowKey))
				end,
				-- Slightly more than Line: just enough for names like "South Valley" beside the two buttons.
				weight = 7,
			},
			builtin.ColumnDesc{
				name = _("Distance"),
				recipe = WaitingDistanceCell,
				getCompareValue = function(rowKey : integer) : any
					return WAITING_SORT_VALUES[2](rowOf(rowKey))
				end,
			},
			builtin.ColumnDesc{
				-- An icon header (as the base Destinations table) keeps the column as narrow as its numbers.
				tooltip = _("Waiting"),
				path = WAITING_ICON,
				recipe = WaitingCountCell,
				getCompareValue = function(rowKey : integer) : any
					return WAITING_SORT_VALUES[3](rowOf(rowKey))
				end,
			},
			builtin.ColumnDesc{
				name = _("Line"),
				recipe = WaitingLineCell,
				getCompareValue = function(rowKey : integer) : any
					return WAITING_SORT_VALUES[4](rowOf(rowKey))
				end,
				-- Without a weight the column takes its widest content; long line names ("Bus Passengers-CouClu-LO-1")
				-- then squeezed Destination to nothing and its buttons were drawn under Distance.
				weight = 6,
			},
		},
		rowKeys = data.rowKeys,
		userParam = data,
		initialSortColumn = { data.sortColumn, data.sortAscending },
		fnUserFilter = function(rowKey : integer) : boolean
			return data.rows[rowKey] ~= nil
		end,
		onSortColumnChange = onSort,
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
		return {
			here = params.entityId, rows = {}, selectionState = selectionState, keys = {}, nextKey = 0, rowKeys = {},
			known = {}, lineLabels = {}, sortRows = {}, scrollSteps = 0,
			-- Starts sorted by Waiting (column 3), largest first.
			sortColumn = 3, sortAscending = false,
		}
	end):old()
	local current = state:old()
	local headerRef = react.useNodeRef(builtin.TextView)
	-- Bumped on a header click, so the table re-sorts on the fresh sort values right away.
	local sortVersion = react.useStateLazy(function() : integer
		return 0
	end)

	local function onSort(column : integer, ascending : boolean)
		if column == data.sortColumn and ascending == data.sortAscending then
			return
		end
		data.sortColumn, data.sortAscending = column, ascending
		for key, row in pairs(data.known) do
			data.sortRows[key] = row
		end
		data.scrollSteps = 3
		sortVersion:set(sortVersion:old() + 1)
	end

	-- The table keeps its current row in view when it re-sorts, which scrolls the window to mid-list. A few frames
	-- later, scroll the window back up to the header line. (The table's own scrollToRowKey only scrolls inside the
	-- table, not the window.)
	react.onStep(function()
		if data.scrollSteps <= 0 then
			return
		end
		data.scrollSteps = data.scrollSteps - 1
		if data.scrollSteps == 0 then
			local node = headerRef:get()
			if node ~= nil then
				node:ensureVisible()
			end
		end
	end)

	local children : {TreeNodeId} = {}
	local function add(node : TreeNodeId)
		children[#children + 1] = node
	end

	if current.failed then
		add(makeHint(_("Commuter Compass: error (see log)")))
	else
		local tbl = current.waitingTable
		add(builtin.TextView(react.ref(headerRef), {
			text = _("Waiting") .. " · " .. countText(tbl.totalWaiting, {
					one = _("{count} people|one"), few = _("{count} people|few"),
					many = _("{count} people|many"), other = _("{count} people|other"),
				})
				.. " · " .. countText(tbl.destinationCount, {
					one = _("{count} destinations|one"), few = _("{count} destinations|few"),
					many = _("{count} destinations|many"), other = _("{count} destinations|other"),
				}),
		}))
		-- Refill in place: cells read rows from this same object.
		local wasShown : {integer : boolean} = {}
		for key in pairs(data.rows) do
			wasShown[key] = true
			data.rows[key] = nil
		end
		for __, row in ipairs(tbl.rows) do
			local key = waitingRowKey(data, row)
			-- Formatted here, not in the cells: they poll on the react step, where some game APIs are restricted.
			row.distanceText = row.distance ~= nil and formatDistance(row.distance) or nil
			row.waitingText = formatCount(row.waiting)
			data.rows[key] = row
			-- A new row, or one back after being hidden, sorts by its current numbers; shown rows keep their place.
			if data.sortRows[key] == nil or data.known[key] == nil or not wasShown[key] then
				data.sortRows[key] = row
			end
			data.known[key] = row
			local label = data.lineLabels[key]
			if label == nil or (label.tooltip or label.label) ~= row.lineName then
				local short = rank.shortenMiddle(row.lineName, LINE_NAME_MAX_CHARS)
				data.lineLabels[key] = {
					label = short, tooltip = short ~= row.lineName and row.lineName or nil, line = row.line,
				}
			end
		end
		if #tbl.rows == 0 then
			add(makeHint(_("Nobody is waiting here.")))
		else
			add(makeWaitingTable(data, onSort))
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
