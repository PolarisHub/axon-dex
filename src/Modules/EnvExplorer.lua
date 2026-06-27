--[[
	Axon · Modules/EnvExplorer
	Developer Utilities Suite:
	- Globals Explorer (_G, shared, getgenv())
	- Lua Registry Inspector (debug.getregistry())
	- Running Threads & Callstack Monitor
	- Luau Bytecode Disassembler
]]

local oldgame = oldgame or game
local game = workspace.Parent
local cloneref = cloneref

-- Common Locals
local Main, Lib, Apps, Settings -- Main Containers
local Explorer, Properties, ScriptViewer, EnvExplorer -- Major Apps
local API, RMD, env, service, plr, create, createSimple -- Main Locals

local function initDeps(data)
	Main = data.Main
	Lib = data.Lib
	Apps = data.Apps
	Settings = data.Settings

	API = data.API
	RMD = data.RMD
	env = data.env
	service = data.service
	plr = data.plr
	create = data.create
	createSimple = data.createSimple
end

local function initAfterMain(appTable)
	Explorer = appTable.Explorer
	Properties = appTable.Properties
	ScriptViewer = appTable.ScriptViewer
	EnvExplorer = appTable.EnvExplorer
end

local function main()
	local EnvExplorer = {}
	EnvExplorer.GuiElems = {}
	EnvExplorer.Window = nil
	EnvExplorer.Active = false

	-- Layout constants
	local ROW_H = 20
	local INDENT = 17
	local GUIDE = 8
	local ICON_OFF = 18
	local NAME_OFF = 36
	local LINE_COLOR = Color3.fromRGB(72, 72, 72)
	local INITIAL_CHILD_LIMIT = 300
	local CHILD_PAGE_SIZE = 300
	local MAX_SUMMARY_SCAN = 80
	local MAX_TEXT_VALUE = 260

	-- State
	local window, currentTab, selectTab
	local tabsFrame, contentFrame, statusBar, statusText
	local listEntries = {}

	-- Tab 1 & 2: Tree explorer variables
	local tree = {}
	local expandedByPath = {}
	local selectedNode
	local editingNode, editBox, confirmBtn
	local activeExplorerType = "Globals" -- "Globals" or "Registry"
	local scrollV, listFrame, searchBox, query = "", nil, nil, ""
	local clickSys, context
	local childLimitsByPath = {}
	local summaryCache = setmetatable({}, {__mode = "k"})
	local textWidthCache = {}

	-- Tab 3: Threads Monitor variables
	local threadsList = {}
	local threadView = {}
	local threadRows = {}
	local selectedThread
	local threadScroll, threadListFrame, threadStackBox, threadStackText, threadSearchBox
	local threadContext
	local threadFilter = ""
	local threadFilterLabel = ""
	local threadPredicate
	local threadTargetSet
	local threadLocateToken = 0
	local threadScanToken = 0
	local threadScanning = false

	-- Tab 4: Disassembler variables
	local disassembleScript
	local disassemblyLines = {}
	local disScroll, disListFrame, disStatusLabel

	-- Color theme for value types
	local TYPE_COLORS = {
		number = Color3.fromRGB(86, 156, 214),      -- Blue
		string = Color3.fromRGB(206, 145, 120),      -- Orange
		boolean = Color3.fromRGB(197, 134, 192),     -- Violet
		["nil"] = Color3.fromRGB(120, 120, 120),       -- Gray
		table = Color3.fromRGB(220, 220, 170),       -- Yellow
		["function"] = Color3.fromRGB(218, 112, 214),  -- Purple
		userdata = Color3.fromRGB(78, 201, 176),     -- Teal
		Vector3 = Color3.fromRGB(156, 220, 254),      -- Light Blue
		Color3 = Color3.fromRGB(156, 220, 254),       -- Light Blue
		Instance = Color3.fromRGB(156, 220, 254),     -- Light Blue
		CFrame = Color3.fromRGB(220, 220, 170),       -- Yellow
		thread = Color3.fromRGB(130, 200, 130),       -- Green
		opcode = Color3.fromRGB(215, 186, 125),       -- Gold
		number_hex = Color3.fromRGB(180, 220, 180),   -- Light green hex
	}

	local function getTypeColor(valType)
		return TYPE_COLORS[valType] or Color3.fromRGB(200, 200, 200)
	end

	local function setStatus(text)
		if statusText then
			statusText.Text = text
		end
	end

	local function safeToString(val, maxLen)
		local ok, result = pcall(tostring, val)
		if not ok then
			result = "<tostring error>"
		end
		result = result or "nil"
		if maxLen and #result > maxLen then
			return result:sub(1, math.max(1, maxLen - 3)) .. "..."
		end
		return result
	end

	local function getTextWidth(text, fontSize)
		local cacheKey = tostring(fontSize) .. "\0" .. text
		local cached = textWidthCache[cacheKey]
		if cached then return cached end
		cached = service.TextService:GetTextSize(text, fontSize, Enum.Font.Code, Vector2.new(9999, ROW_H)).X
		textWidthCache[cacheKey] = cached
		return cached
	end

	local function formatValue(val, valType)
		if valType == "string" then
			return '"' .. safeToString(val, MAX_TEXT_VALUE) .. '"'
		elseif valType == "nil" then
			return "nil"
		elseif valType == "table" then
			return "Table: " .. safeToString(val, MAX_TEXT_VALUE)
		elseif valType == "function" then
			local name = "anonymous"
			pcall(function()
				local inf = debug.getinfo(val)
				name = inf.name ~= "" and inf.name or ("anonymous_line_%d"):format(inf.linedefined or 0)
			end)
			return ("Function: %s (%s)"):format(name, safeToString(val, 120))
		elseif valType == "userdata" or typeof(val) == "Instance" then
			local str = safeToString(val, MAX_TEXT_VALUE)
			local name = str
			pcall(function()
				if typeof(val) == "Instance" then
					name = safeToString(val:GetFullName(), MAX_TEXT_VALUE)
				else
					local getraw = getrawmetatable or getmetatable
					local mt = getraw(val)
					if mt then
						if mt.__type then
							name = safeToString(mt.__type, 80) .. " (" .. str .. ")"
						elseif mt.__tostring then
							name = safeToString(val, MAX_TEXT_VALUE)
						end
					end
				end
			end)
			return name
		else
			return safeToString(val, MAX_TEXT_VALUE)
		end
	end

	local function getTableSummary(tbl)
		local cached = summaryCache[tbl]
		if cached then return cached end

		local counts = {}
		local total = 0
		local truncated = false
		local success = pcall(function()
			for k, v in next, tbl do
				total = total + 1
				if total > MAX_SUMMARY_SCAN then
					truncated = true
					break
				end
				local t = typeof(v)
				counts[t] = (counts[t] or 0) + 1
			end
		end)
		if not success or total == 0 then return "" end

		local parts = {}
		local order = {"function", "table", "number", "string", "boolean"}
		for _, t in ipairs(order) do
			if counts[t] and counts[t] > 0 then
				local label = t
				if t == "function" then label = "Func"
				elseif t == "table" then label = "Table"
				elseif t == "number" then label = "Num"
				elseif t == "string" then label = "Str"
				elseif t == "boolean" then label = "Bool"
				end
				parts[#parts + 1] = ("%d %s"):format(counts[t], label)
				counts[t] = nil
			end
		end
		for t, cnt in next, counts do
			parts[#parts + 1] = ("%d %s"):format(cnt, t)
		end

		if #parts > 0 then
			cached = " (" .. (truncated and (tostring(MAX_SUMMARY_SCAN) .. "+ sampled: ") or "") .. table.concat(parts, ", ") .. ")"
		else
			cached = " (empty)"
		end
		summaryCache[tbl] = cached
		return cached
	end

	local function getNodeValueText(node)
		if not node.ValueText then
			node.ValueText = formatValue(node.Value, node.ValueType)
		end
		return node.ValueText
	end

	local function clearCaches()
		summaryCache = setmetatable({}, {__mode = "k"})
		textWidthCache = {}
	end

	local function getFunctionInfo(func)
		local info = {}
		local scriptObj
		local getinfo = (debug and (debug.getinfo or debug.info)) or getinfo
		if getinfo then
			pcall(function()
				local result = getinfo(func)
				if type(result) == "table" then
					info = result
				end
			end)
		end
		pcall(function()
			local fenv = getfenv and getfenv(func)
			if fenv then
				scriptObj = rawget(fenv, "script") or fenv.script
			end
		end)
		return info, scriptObj
	end

	local function getFunctionDisplayName(func)
		local info = getFunctionInfo(func)
		local name = info.name
		if name and name ~= "" then
			return name
		end
		if info.linedefined and info.linedefined >= 0 then
			return ("anonymous_line_%d"):format(info.linedefined)
		end
		return "anonymous"
	end

	local function buildFunctionReport(func, label)
		local info, scriptObj = getFunctionInfo(func)
		local lines = {}
		lines[#lines + 1] = "-- Axon Function Inspector"
		lines[#lines + 1] = "-- Name: " .. (label or getFunctionDisplayName(func))
		lines[#lines + 1] = "-- Object: " .. safeToString(func, 180)
		if typeof(scriptObj) == "Instance" then
			lines[#lines + 1] = "-- Script: " .. safeToString(scriptObj:GetFullName(), 220)
		end
		if info.source then lines[#lines + 1] = "-- Source: " .. safeToString(info.source, 220) end
		if info.short_src then lines[#lines + 1] = "-- Short Source: " .. safeToString(info.short_src, 220) end
		if info.linedefined then lines[#lines + 1] = "-- Defined Line: " .. tostring(info.linedefined) end
		if info.lastlinedefined then lines[#lines + 1] = "-- Last Line: " .. tostring(info.lastlinedefined) end
		if info.numparams then lines[#lines + 1] = "-- Params: " .. tostring(info.numparams) end
		if info.isvararg ~= nil then lines[#lines + 1] = "-- Vararg: " .. tostring(info.isvararg) end
		if info.what then lines[#lines + 1] = "-- What: " .. safeToString(info.what, 80) end

		local getupvalues = (debug and debug.getupvalues) or getupvalues or getupvals
		local getconstants = (debug and debug.getconstants) or getconstants or getconsts
		local getprotos = (debug and debug.getprotos) or getprotos

		if getupvalues then
			local ok, upvalues = pcall(getupvalues, func)
			if ok and upvalues then
				lines[#lines + 1] = ""
				lines[#lines + 1] = "-- Upvalues (" .. tostring(#upvalues) .. ")"
				for i = 1, math.min(#upvalues, 250) do
					local value = upvalues[i]
					lines[#lines + 1] = ("[%d] <%s> %s"):format(i, typeof(value), formatValue(value, typeof(value)))
				end
				if #upvalues > 250 then
					lines[#lines + 1] = ("-- ... %d more upvalues"):format(#upvalues - 250)
				end
			end
		end

		if getconstants then
			local ok, constants = pcall(getconstants, func)
			if ok and constants then
				lines[#lines + 1] = ""
				lines[#lines + 1] = "-- Constants (" .. tostring(#constants) .. ")"
				for i = 1, math.min(#constants, 250) do
					local value = constants[i]
					lines[#lines + 1] = ("[%d] <%s> %s"):format(i, typeof(value), formatValue(value, typeof(value)))
				end
				if #constants > 250 then
					lines[#lines + 1] = ("-- ... %d more constants"):format(#constants - 250)
				end
			end
		end

		if getprotos then
			local ok, protos = pcall(getprotos, func)
			if ok and protos then
				lines[#lines + 1] = ""
				lines[#lines + 1] = "-- Prototypes: " .. tostring(#protos)
			end
		end

		return table.concat(lines, "\n")
	end

	local function parseValue(valStr, targetType)
		if targetType == "number" then
			return tonumber(valStr)
		elseif targetType == "boolean" then
			local lower = valStr:lower()
			if lower == "true" then return true
			elseif lower == "false" then return false
			end
		elseif targetType == "string" then
			return valStr
		elseif targetType == "Vector3" then
			local x, y, z = valStr:match("([^,]+)%s*,%s*([^,]+)%s*,%s*([^,]+)")
			if x and y and z then
				return Vector3.new(tonumber(x), tonumber(y), tonumber(z))
			end
		elseif targetType == "Color3" then
			local r, g, b = valStr:match("([^,]+)%s*,%s*([^,]+)%s*,%s*([^,]+)")
			if r and g and b then
				return Color3.fromRGB(tonumber(r), tonumber(g), tonumber(b))
			end
		end
		return nil
	end

	-- Tree Node Loading
	local function loadNodeChildren(node)
		if node.ChildrenLoaded then return end
		node.ChildrenLoaded = true

		if type(node.Value) == "table" then
			local tList = {}
			local depth = node.Depth + 1
			local count = 0
			local limit = childLimitsByPath[node.Path] or INITIAL_CHILD_LIMIT
			local truncated = false
			pcall(function()
				for k, v in next, node.Value do
					count = count + 1
					if count > limit then
						truncated = true
						break
					end
					local vType = typeof(v)
					local tbValText = ""
					if vType == "table" then
						tbValText = getTableSummary(v)
					end
					local keyText = safeToString(k, 90)
					local childPath = node.Path .. "/" .. keyText
					local childNode = {
						Name = "[" .. keyText .. "]" .. tbValText,
						Type = "TableMember",
						Depth = depth,
						Expanded = expandedByPath[childPath] or false,
						Parent = node,
						Children = {},
						Key = k,
						Value = v,
						ValueType = vType
					}
					childNode.Path = childPath
					tList[#tList + 1] = childNode
				end
			end)
			if truncated then
				tList[#tList + 1] = {
					Name = ("... load %d more (showing %d+)"):format(CHILD_PAGE_SIZE, limit),
					Type = "LoadMore",
					Depth = depth,
					Parent = node,
					Children = {},
					Value = "Click to load more entries safely",
					ValueType = "string",
					LoadParentPath = node.Path,
					NextLimit = limit + CHILD_PAGE_SIZE,
					Path = node.Path .. "/__load_more_" .. tostring(limit)
				}
			end
			node.Children = tList
		elseif type(node.Value) == "function" then
			-- Load function metadata/upvalues/constants
			local depth = node.Depth + 1
			local children = {}

			local getupvalues = (debug and debug.getupvalues) or getupvalues or getupvals
			local getconstants = (debug and debug.getconstants) or getconstants or getconsts
			local getprotos = (debug and debug.getprotos) or getprotos

			local info, scriptObj = getFunctionInfo(node.Value)
			local infoText = "Info"
			if info.linedefined then
				infoText = infoText .. (" | line %s"):format(tostring(info.linedefined))
			end
			if info.numparams then
				infoText = infoText .. (" | %s params"):format(tostring(info.numparams))
			end
			if typeof(scriptObj) == "Instance" then
				infoText = infoText .. " | " .. safeToString(scriptObj.Name, 60)
			end
			children[#children + 1] = {
				Name = infoText,
				Type = "Metadata",
				Depth = depth,
				Parent = node,
				Children = {},
				Value = safeToString(node.Value, 180),
				ValueType = "string",
				Path = node.Path .. "/Info"
			}

			-- 1. Upvalues
			local s, upvals = pcall(getupvalues, node.Value)
			if s and upvals and #upvals > 0 then
				local upsNode = {
					Name = "Upvalues (" .. #upvals .. ")",
					Type = "UpvaluesFolder",
					Depth = depth,
					Parent = node,
					Children = {}
				}
				upsNode.Path = node.Path .. "/Upvalues"
				upsNode.Expanded = expandedByPath[upsNode.Path] or false
				for idx, val in next, upvals do
					local vType = typeof(val)
					local summary = vType == "table" and getTableSummary(val) or ""
					local upPath = upsNode.Path .. "/" .. idx
					local upNode = {
						Name = ("[%d] upval_%d%s"):format(idx, idx, summary),
						Type = "Upvalue",
						Depth = depth + 1,
						Expanded = expandedByPath[upPath] or false,
						Index = idx,
						Parent = upsNode,
						Children = {},
						Value = val,
						ValueType = vType,
						Func = node.Value
					}
					upNode.Path = upPath
					upsNode.Children[#upsNode.Children + 1] = upNode
				end
				children[#children + 1] = upsNode
			end

			-- 2. Constants
			local s2, consts = pcall(getconstants, node.Value)
			if s2 and consts and #consts > 0 then
				local constsNode = {
					Name = "Constants (" .. #consts .. ")",
					Type = "ConstantsFolder",
					Depth = depth,
					Parent = node,
					Children = {}
				}
				constsNode.Path = node.Path .. "/Constants"
				constsNode.Expanded = expandedByPath[constsNode.Path] or false
				for idx, val in next, consts do
					local vType = typeof(val)
					local summary = vType == "table" and getTableSummary(val) or ""
					local conPath = constsNode.Path .. "/" .. idx
					local conNode = {
						Name = ("[%d]%s"):format(idx, summary),
						Type = "Constant",
						Depth = depth + 1,
						Expanded = expandedByPath[conPath] or false,
						Index = idx,
						Parent = constsNode,
						Children = {},
						Value = val,
						ValueType = vType,
						Func = node.Value
					}
					conNode.Path = conPath
					constsNode.Children[#constsNode.Children + 1] = conNode
				end
				children[#children + 1] = constsNode
			end

			-- 3. Protos
			if getprotos then
				local s3, protos = pcall(getprotos, node.Value)
				if s3 and protos and #protos > 0 then
					local protosNode = {
						Name = "Prototypes (" .. #protos .. ")",
						Type = "PrototypesFolder",
						Depth = depth,
						Parent = node,
						Children = {}
					}
					protosNode.Path = node.Path .. "/Prototypes"
					protosNode.Expanded = expandedByPath[protosNode.Path] or false
					for idx, pFunc in next, protos do
						local pName = getFunctionDisplayName(pFunc)
						local protoPath = protosNode.Path .. "/" .. idx
						local pNode = {
							Name = ("[%d] %s"):format(idx, pName),
							Type = "Function",
							Func = pFunc,
							Depth = depth + 1,
							Expanded = expandedByPath[protoPath] or false,
							Parent = protosNode,
							Children = {},
							Value = pFunc,
							ValueType = "function"
						}
						pNode.Path = protoPath
						protosNode.Children[#protosNode.Children + 1] = pNode
					end
					children[#children + 1] = protosNode
				end
			end

			node.Children = children
		end
	end

	local function flattenTree()
		table.clear(tree)
		local lq = query:lower()

		local function nodeMatches(node)
			if lq == "" then return true end
			if string.find(node.Name:lower(), lq, 1, true) then return true end
			if node.Value ~= nil then
				return string.find(getNodeValueText(node):lower(), lq, 1, true) ~= nil
			end
			return false
		end

		local function addExpanded(node)
			if node.Expanded then
				loadNodeChildren(node)
				for i = 1, #node.Children do
					local child = node.Children[i]
					if lq == "" or nodeMatches(child) or child.Expanded then
						tree[#tree + 1] = child
						addExpanded(child)
					end
				end
			end
		end

		local function matchQuery(name)
			if lq == "" then return true end
			return string.find(name:lower(), lq, 1, true) ~= nil
		end

		if activeExplorerType == "Globals" then
			-- Walk Globals root nodes
			local globalsList = {
				{Name = "getgenv()", Val = getgenv()},
				{Name = "_G", Val = _G},
				{Name = "shared", Val = shared}
			}
			for _, r in ipairs(globalsList) do
				local node = {
					Name = r.Name .. getTableSummary(r.Val),
					Type = "RootFolder",
					Depth = 0,
					Expanded = expandedByPath[r.Name] or false,
					Children = {},
					Value = r.Val,
					ValueType = "table",
					Path = r.Name
				}
				if lq == "" or matchQuery(node.Name) or node.Expanded then
					tree[#tree + 1] = node
					addExpanded(node)
				end
			end
		else
			-- Registry explorer
			local reg = (debug and debug.getregistry) or getreg
			if reg then
				local ok, regVal = pcall(reg)
				if ok and type(regVal) == "table" then
					local rootNode = {
						Name = "Registry (" .. #regVal .. ")" .. getTableSummary(regVal),
						Type = "RootFolder",
						Depth = 0,
						Expanded = expandedByPath["Registry"] or false,
						Children = {},
						Value = regVal,
						ValueType = "table",
						Path = "Registry"
					}
					tree[#tree + 1] = rootNode
					addExpanded(rootNode)
				else
					tree[#tree + 1] = {
						Name = "Registry (failed to read)",
						Type = "Metadata",
						Depth = 0,
						Children = {},
						Value = safeToString(regVal, MAX_TEXT_VALUE),
						ValueType = "string",
						Path = "Error"
					}
				end
			else
				tree[#tree + 1] = {
					Name = "Registry (not supported by executor)",
					Type = "Metadata",
					Depth = 0,
					Children = {},
					Value = "Unsupported",
					ValueType = "string",
					Path = "Error"
				}
			end
		end

		-- Set last-child states for guidelines drawing
		for i = 1, #tree do
			local node = tree[i]
			node.VisibleIsLast = false
			local parent = node.Parent
			if parent then
				local idx = table.find(parent.Children, node)
				if idx == #parent.Children then
					node.VisibleIsLast = true
				end
			end
		end

		scrollV.TotalSpace = #tree
		scrollV:Update()
		statusText.Text = ("Showing %d items | Explorer: %s"):format(#tree, activeExplorerType)
	end

	-- Explorer GUI View
	local function drawLines(entry, node)
		for _, line in next, entry.Guides do line.Visible = false end
		local depth = node.Depth
		if depth == 0 then return end

		local lineIdx = 1
		local function getLine()
			local line = entry.Guides[lineIdx]
			if not line then
				line = createSimple("Frame", {
					BackgroundColor3 = Settings.Theme.Outline2 or LINE_COLOR,
					BorderSizePixel = 0,
					Parent = entry.Gui
				})
				entry.Guides[lineIdx] = line
			end
			line.BackgroundColor3 = Settings.Theme.Outline2 or LINE_COLOR
			lineIdx = lineIdx + 1
			return line
		end

		local function drawVertical(xOffset)
			local l = getLine()
			l.Position = UDim2.new(0, xOffset, 0, 0)
			l.Size = UDim2.new(0, 1, 1, 0)
			l.Visible = true
		end

		local function drawElbow(xOffset, isLast)
			local lH = getLine()
			lH.Position = UDim2.new(0, xOffset, 0, ROW_H / 2)
			lH.Size = UDim2.new(0, INDENT - GUIDE - 2, 0, 1)
			lH.Visible = true

			local lV = getLine()
			lV.Position = UDim2.new(0, xOffset, 0, 0)
			lV.Size = UDim2.new(0, 1, 0, isLast and (ROW_H / 2) or ROW_H)
			lV.Visible = true
		end

		drawElbow(depth * INDENT + GUIDE, node.VisibleIsLast)

		local ancestor = node
		for d = depth - 1, 1, -1 do
			ancestor = ancestor.Parent
			if ancestor and not ancestor.VisibleIsLast then
				drawVertical(d * INDENT + GUIDE)
			end
		end
	end

	local function updateExplorerView()
		local maxNodes = math.max(math.ceil(listFrame.AbsoluteSize.Y / ROW_H), 0)

		scrollV.VisibleSpace = maxNodes
		scrollV.TotalSpace = #tree
		scrollV.Gui.Visible = #tree > maxNodes

		local newSize = UDim2.new(1, scrollV.Gui.Visible and -16 or 0, 1, -27)
		if listFrame.Size ~= newSize then
			listFrame.Size = newSize
		end
		scrollV:Update()
		local indexOffset = scrollV.Index

		for i = 1, maxNodes do
			if not listEntries[i] then
				listEntries[i] = EnvExplorer.NewEntry(i)
			end
		end
		for i = maxNodes + 1, #listEntries do
			if listEntries[i] then
				listEntries[i].Gui.Visible = false
			end
		end

		local theme = Settings.Theme
		local miscIcons = Main.MiscIcons
		local editingVisible = false

		for i = 1, maxNodes do
			local entry = listEntries[i]
			local node = tree[i + indexOffset]
			if node then
				local depth = node.Depth
				entry.Gui.Visible = true

				-- Layout placements
				entry.Name.Position = UDim2.new(0, depth * INDENT + NAME_OFF, 0, 0)
				entry.Name.Text = node.Name

				if node.Type == "RootFolder" or node.Type == "UpvaluesFolder" or node.Type == "ConstantsFolder" or node.Type == "PrototypesFolder" then
					entry.Name.TextColor3 = Color3.fromRGB(180, 180, 180)
					entry.Name.Size = UDim2.new(1, -(depth * INDENT + NAME_OFF) - 2, 1, 0)
					entry.ValueLabel.Visible = false
				else
					entry.Name.TextColor3 = Color3.fromRGB(150, 150, 150)
					local nameSize = node.NameWidth or getTextWidth(node.Name, 13)
					node.NameWidth = nameSize
					entry.Name.Size = UDim2.new(0, nameSize + 4, 1, 0)

					entry.ValueLabel.Position = UDim2.new(0, depth * INDENT + NAME_OFF + nameSize + 8, 0, 0)
					entry.ValueLabel.Size = UDim2.new(1, -(depth * INDENT + NAME_OFF + nameSize + 8) - 4, 1, 0)
					entry.ValueLabel.Text = getNodeValueText(node)
					entry.ValueLabel.TextColor3 = getTypeColor(node.ValueType)
					entry.ValueLabel.Visible = true

					-- Position editbox if editing this node
					if editingNode == node then
						local xPos = depth * INDENT + NAME_OFF + nameSize + 8
						editBox.Position = UDim2.new(0, xPos, 0, entry.Gui.Position.Y.Offset + 2)
						editBox.Size = UDim2.new(1, -xPos - 30, 0, 16)

						confirmBtn.Position = UDim2.new(1, -26, 0, entry.Gui.Position.Y.Offset)
						confirmBtn.Size = UDim2.new(0, 20, 0, 20)
						editingVisible = true
					end
				end

				-- Display proper Icons
				entry.Icon.Position = UDim2.new(0, depth * INDENT + ICON_OFF, 0, 2)
				local iconKey = "Empty"
				if node.ValueType == "function" then iconKey = "CallFunction"
				elseif node.Type == "RootFolder" or node.Type == "UpvaluesFolder" or node.Type == "ConstantsFolder" or node.Type == "PrototypesFolder" then iconKey = "Group"
				elseif node.Type == "Upvalue" then iconKey = "Reference"
				elseif node.Type == "Constant" then iconKey = "SelectChildren"
				elseif node.Type == "LoadMore" then iconKey = "Expand"
				elseif node.ValueType == "table" then iconKey = "Honey"
				elseif node.Type == "Metadata" then iconKey = "ExploreData"
				end
				miscIcons:DisplayByKey(entry.Icon, iconKey)
				entry.Icon.ImageTransparency = (node.ValueType == "function" or node.Type == "Upvalue" or node.Type == "LoadMore") and 0 or 0.35

				drawLines(entry, node)

				-- Select highlights
				local activeBar = entry.Highlight:FindFirstChild("ActiveBar")
				if node == selectedNode then
					entry.Highlight.BackgroundColor3 = theme.ListSelection
					entry.Highlight.BackgroundTransparency = 0.25
					if activeBar then activeBar.Visible = true end
				elseif Lib.CheckMouseInGui(entry.Gui) then
					entry.Highlight.BackgroundColor3 = theme.Button
					entry.Highlight.BackgroundTransparency = 0.5
					if activeBar then activeBar.Visible = false end
				else
					entry.Highlight.BackgroundTransparency = 1
					if activeBar then activeBar.Visible = false end
				end

				-- Expand Arrow visibility
				local canExpand = (node.ValueType == "table" or node.ValueType == "function" or node.Type == "UpvaluesFolder" or node.Type == "ConstantsFolder" or node.Type == "PrototypesFolder")
				if canExpand then
					entry.Expand.Position = UDim2.new(0, depth * INDENT, 0, 2)
					if Lib.CheckMouseInGui(entry.Expand) then
						miscIcons:DisplayByKey(entry.Expand.Icon, node.Expanded and "Collapse_Over" or "Expand_Over")
					else
						miscIcons:DisplayByKey(entry.Expand.Icon, node.Expanded and "Collapse" or "Expand")
					end
					entry.Expand.Visible = true
				else
					entry.Expand.Visible = false
				end
			else
				entry.Gui.Visible = false
			end
		end

		editBox.Visible = editingVisible
		confirmBtn.Visible = editingVisible
	end

	local refreshExplorerTree, collapseExplorerTree, loadMoreChildren, openTextInScriptViewer, openFunctionSource, locateThreadsForFunction, locateRunningThreads

	EnvExplorer.NewEntry = function(index)
		local entryGui = createSimple("TextButton", {
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Font = Enum.Font.Code,
			Text = "",
			TextSize = 13,
			Size = UDim2.new(1, 0, 0, ROW_H),
			ClipsDescendants = true
		})

		local highlight = createSimple("Frame", {
			Name = "Highlight",
			Size = UDim2.new(1, -6, 1, -2),
			Position = UDim2.new(0, 3, 0, 1),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = entryGui
		})
		createSimple("UICorner", {
			CornerRadius = UDim.new(0, 3),
			Parent = highlight
		})
		local activeBar = createSimple("Frame", {
			Name = "ActiveBar",
			Size = UDim2.new(0, 3, 1, -4),
			Position = UDim2.new(0, 1, 0, 2),
			BackgroundColor3 = Settings.Theme.Highlight,
			BorderSizePixel = 0,
			Visible = false,
			Parent = highlight
		})
		createSimple("UICorner", {
			CornerRadius = UDim.new(0, 1.5),
			Parent = activeBar
		})

		local expand = createSimple("TextButton", {
			Name = "Expand",
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 16, 0, ROW_H),
			Text = "",
			Parent = entryGui,
			Visible = false
		})
		local expandIcon = createSimple("ImageLabel", {
			Name = "Icon",
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 12, 0, 12),
			Position = UDim2.new(0, 2, 0, 4),
			Parent = expand
		})

		local icon = createSimple("ImageLabel", {
			Name = "Icon",
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 16, 0, 16),
			Position = UDim2.new(0, 0, 0, 2),
			Parent = entryGui
		})

		local nameLabel = createSimple("TextLabel", {
			Name = "EntryName",
			BackgroundTransparency = 1,
			Font = Enum.Font.Code,
			TextSize = 13,
			TextColor3 = Color3.new(1, 1, 1),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = entryGui
		})

		local valueLabel = createSimple("TextLabel", {
			Name = "EntryValue",
			BackgroundTransparency = 1,
			Font = Enum.Font.Code,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = entryGui
		})

		local entry = {
			Gui = entryGui,
			Highlight = highlight,
			Expand = expand,
			Icon = icon,
			Name = nameLabel,
			ValueLabel = valueLabel,
			Guides = {}
		}

		entryGui.Position = UDim2.new(0, 0, 0, ROW_H * (index - 1))

		entryGui.InputBegan:Connect(function(input)
			local node = tree[index + scrollV.Index]
			if not node or node == selectedNode then return end
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				entry.Highlight.BackgroundColor3 = Settings.Theme.Button
				entry.Highlight.BackgroundTransparency = 0.5
			end
		end)
		entryGui.InputEnded:Connect(function(input)
			local node = tree[index + scrollV.Index]
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				if node ~= selectedNode then entry.Highlight.BackgroundTransparency = 1 end
			end
		end)

		entry.Expand.MouseButton1Click:Connect(function()
			local node = tree[index + scrollV.Index]
			if not node then return end
			if node.Type == "LoadMore" then
				loadMoreChildren(node)
				return
			end
			local canExpand = (node.ValueType == "table" or node.ValueType == "function" or node.Type == "UpvaluesFolder" or node.Type == "ConstantsFolder" or node.Type == "PrototypesFolder")
			if not canExpand then return end
			node.Expanded = not node.Expanded
			expandedByPath[node.Path] = node.Expanded
			flattenTree()
			updateExplorerView()
		end)

		if clickSys then clickSys:Add(entryGui) end
		entryGui.Parent = listFrame
		return entry
	end

	local function setEditingNode(node, idx)
		editingNode = node
		local entry = listEntries[idx]
		if not entry then return end

		editBox.Text = tostring(node.Value)
		local nameSize = node.NameWidth or getTextWidth(node.Name, 13)
		node.NameWidth = nameSize
		local xPos = node.Depth * INDENT + NAME_OFF + nameSize + 8

		editBox.Position = UDim2.new(0, xPos, 0, entry.Gui.Position.Y.Offset + 2)
		editBox.Size = UDim2.new(1, -xPos - 30, 0, 16)
		editBox.Visible = true
		editBox:CaptureFocus()

		confirmBtn.Position = UDim2.new(1, -26, 0, entry.Gui.Position.Y.Offset)
		confirmBtn.Size = UDim2.new(0, 20, 0, 20)
		confirmBtn.Visible = true
	end

	function refreshExplorerTree()
		clearCaches()
		selectedNode = nil
		editingNode = nil
		if editBox then editBox.Visible = false end
		if confirmBtn then confirmBtn.Visible = false end
		flattenTree()
		updateExplorerView()
	end

	function collapseExplorerTree()
		table.clear(expandedByPath)
		table.clear(childLimitsByPath)
		clearCaches()
		selectedNode = nil
		editingNode = nil
		if scrollV then scrollV:ScrollTo(0, true) end
		flattenTree()
		updateExplorerView()
	end

	function loadMoreChildren(node)
		if not node then return end
		local targetPath = node.LoadParentPath or node.Path
		childLimitsByPath[targetPath] = node.NextLimit or ((childLimitsByPath[targetPath] or INITIAL_CHILD_LIMIT) + CHILD_PAGE_SIZE)
		setStatus(("Loading more entries for %s..."):format(targetPath))
		flattenTree()
		updateExplorerView()
	end

	function openTextInScriptViewer(text)
		if not ScriptViewer or not ScriptViewer.Window or not ScriptViewer.codeFrame then return false end
		ScriptViewer.Window:Show()
		ScriptViewer.codeFrame.OwnerScript = nil
		ScriptViewer.codeFrame:SetText(text)
		return true
	end

	function openFunctionSource(func)
		local info, scriptObj = getFunctionInfo(func)
		if typeof(scriptObj) == "Instance" and ScriptViewer and ScriptViewer.ViewScript then
			local line = tonumber(info.linedefined) or nil
			ScriptViewer.ViewScript(scriptObj, line)
			return true
		end

		local decompile = env and env.decompile
		if decompile then
			local ok, src = pcall(decompile, func)
			if ok and src then
				return openTextInScriptViewer(src)
			end
		end
		return false
	end

	local function showExplorerContextMenu(position)
		if not selectedNode then return end
		context:Clear()

		if selectedNode.Type == "LoadMore" then
			context:Add({
				Name = "Load More Entries",
				IconMap = Main.MiscIcons,
				Icon = "Expand",
				OnClick = function()
					loadMoreChildren(selectedNode)
				end
			})
			local mouse = Main.Mouse
			context:Show(position and position.X or mouse.X, position and position.Y or mouse.Y)
			return
		end

		local canExpand = (selectedNode.ValueType == "table" or selectedNode.ValueType == "function" or selectedNode.Type == "UpvaluesFolder" or selectedNode.Type == "ConstantsFolder" or selectedNode.Type == "PrototypesFolder")
		if canExpand then
			context:Add({
				Name = selectedNode.Expanded and "Collapse" or "Expand",
				IconMap = Main.MiscIcons,
				Icon = selectedNode.Expanded and "Collapse" or "Expand",
				OnClick = function()
					selectedNode.Expanded = not selectedNode.Expanded
					expandedByPath[selectedNode.Path] = selectedNode.Expanded
					flattenTree()
					updateExplorerView()
				end
			})
		end

		if selectedNode.ValueType == "table" then
			context:Add({
				Name = ("Increase Child Limit (+%d)"):format(CHILD_PAGE_SIZE),
				IconMap = Main.MiscIcons,
				Icon = "Expand",
				OnClick = function()
					loadMoreChildren(selectedNode)
				end
			})
		end

		local isEditable = (selectedNode.Type == "Upvalue" or selectedNode.Type == "Constant" or selectedNode.Type == "TableMember") and (selectedNode.ValueType == "number" or selectedNode.ValueType == "boolean" or selectedNode.ValueType == "string" or selectedNode.ValueType == "Vector3" or selectedNode.ValueType == "Color3")
		if isEditable then
			local labelName = "Edit Value"
			if selectedNode.Type == "Upvalue" then labelName = "Edit Upvalue"
			elseif selectedNode.Type == "Constant" then labelName = "Edit Constant"
			elseif selectedNode.Type == "TableMember" then labelName = "Edit Table Member"
			end
			context:Add({
				Name = labelName,
				IconMap = Main.MiscIcons,
				Icon = "Rename",
				OnClick = function()
					local idx = table.find(tree, selectedNode)
					if idx then
						setEditingNode(selectedNode, idx - scrollV.Index)
					end
				end
			})
		end

		if selectedNode.Value ~= nil then
			context:Add({
				Name = "Copy Value",
				IconMap = Main.MiscIcons,
				Icon = "Copy",
				OnClick = function()
					pcall(setclipboard or writeclipboard, safeToString(selectedNode.Value))
				end
			})
			context:Add({
				Name = "Copy Type",
				IconMap = Main.MiscIcons,
				Icon = "ExploreData",
				OnClick = function()
					pcall(setclipboard or writeclipboard, safeToString(selectedNode.ValueType))
				end
			})
			if selectedNode.Type == "TableMember" then
				context:Add({
					Name = "Copy Key",
					IconMap = Main.MiscIcons,
					Icon = "Copy",
					OnClick = function()
						pcall(setclipboard or writeclipboard, safeToString(selectedNode.Key))
					end
				})
			end
			context:Add({
				Name = "Copy Path",
				IconMap = Main.MiscIcons,
				Icon = "Reference",
				OnClick = function()
					pcall(setclipboard or writeclipboard, selectedNode.Path)
				end
			})
		end

		if selectedNode.ValueType == "function" then
			context:Add({
				Name = "Locate Threads",
				IconMap = Main.MiscIcons,
				Icon = "Reference",
				OnClick = function()
					locateThreadsForFunction(selectedNode.Value, false)
				end
			})
			context:Add({
				Name = "Locate Running Threads",
				IconMap = Main.MiscIcons,
				Icon = "Play",
				OnClick = function()
					locateThreadsForFunction(selectedNode.Value, true)
				end
			})
			context:Add({
				Name = "Open Source Script",
				IconMap = Main.MiscIcons,
				Icon = "ViewScript",
				OnClick = function()
					if not openFunctionSource(selectedNode.Value) then
						openTextInScriptViewer(buildFunctionReport(selectedNode.Value, selectedNode.Name))
						warn("[EnvExplorer] Could not open source directly; opened function report instead.")
					end
				end
			})
			context:Add({
				Name = "Open Function Report",
				IconMap = Main.MiscIcons,
				Icon = "ExploreData",
				OnClick = function()
					openTextInScriptViewer(buildFunctionReport(selectedNode.Value, selectedNode.Name))
				end
			})
			context:Add({
				Name = "Copy Function Report",
				IconMap = Main.MiscIcons,
				Icon = "Copy",
				OnClick = function()
					pcall(setclipboard or writeclipboard, buildFunctionReport(selectedNode.Value, selectedNode.Name))
				end
			})
		end

		local mouse = Main.Mouse
		context:Show(position and position.X or mouse.X, position and position.Y or mouse.Y)
	end

	local function initExplorerClickSystem()
		clickSys = Lib.ClickSystem.new()
		clickSys.AllowedButtons = {1, 2}

		clickSys.OnDown:Connect(function(item, combo, button)
			local ind
			for i = 1, #listEntries do if listEntries[i].Gui == item then ind = i break end end
			if not ind then return end
			local node = tree[ind + scrollV.Index]
			if not node then return end

			if button == 1 and node.Type == "LoadMore" then
				selectedNode = node.Parent or node
				loadMoreChildren(node)
				return
			end

			selectedNode = node
			updateExplorerView()

			if button == 1 and combo == 2 then
				local isEditable = (node.Type == "Upvalue" or node.Type == "Constant" or node.Type == "TableMember") and (node.ValueType == "number" or node.ValueType == "boolean" or node.ValueType == "string" or node.ValueType == "Vector3" or node.ValueType == "Color3")
				if isEditable then
					setEditingNode(node, ind)
				else
					local canExpand = (node.ValueType == "table" or node.ValueType == "function" or node.Type == "UpvaluesFolder" or node.Type == "ConstantsFolder" or node.Type == "PrototypesFolder")
					if canExpand then
						node.Expanded = not node.Expanded
						expandedByPath[node.Path] = node.Expanded
						flattenTree()
						updateExplorerView()
					elseif node.ValueType == "function" then
						openFunctionSource(node.Value)
					end
				end
			end
		end)

		clickSys.OnRelease:Connect(function(item, combo, button, position)
			if button == 2 then showExplorerContextMenu(position) end
		end)
	end

	-- Tab 3: Threads Monitor Logic
	local renderThreadsList, updateThreadStackView, refreshThreadsList

	local function getThreadStatusColor(status)
		if status == "running" then
			return Color3.fromRGB(120, 210, 120)
		elseif status == "suspended" then
			return Color3.fromRGB(215, 186, 125)
		elseif status == "dead" then
			return Color3.fromRGB(170, 90, 90)
		end
		return Color3.fromRGB(150, 180, 220)
	end

	local function isScriptLike(obj)
		if typeof(obj) ~= "Instance" then return false end
		local ok, result = pcall(function()
			return obj:IsA("LuaSourceContainer")
		end)
		if ok then return result end
		return obj:IsA("LocalScript") or obj:IsA("ModuleScript") or obj:IsA("Script")
	end

	local function getScriptFromFunction(func)
		if typeof(func) ~= "function" then return nil end
		local _, scriptObj = getFunctionInfo(func)
		if isScriptLike(scriptObj) then
			return scriptObj
		end
		return nil
	end

	local function parseThreadTraceback(stack)
		if type(stack) ~= "string" then return nil, nil end
		for lineText in stack:gmatch("[^\n]+") do
			local source, line = lineText:match("Script '([^']+)', Line (%d+)")
			if source and line then
				return source, tonumber(line)
			end
			source, line = lineText:match("^%s*(.-):(%d+):")
			if source and source ~= "" and line then
				return source, tonumber(line)
			end
		end
		return nil, nil
	end

	local function getThreadStack(tData)
		if not tData then return "Select a thread to view its traceback." end
		if not tData.Stack then
			local traceback = debug and debug.traceback
			local ok, stack = false, nil
			if traceback then
				ok, stack = pcall(traceback, tData.Thread)
			end
			tData.Stack = (ok and stack and stack ~= "") and stack or "No call stack available for this thread."
		end
		return tData.Stack
	end

	local function getThreadLocation(tData)
		if not tData then return {} end
		if tData.Location then return tData.Location end

		local location = {}
		local debugInfo = debug and debug.info
		if debugInfo then
			for level = 0, 40 do
				local ok, source, line, name, func = pcall(debugInfo, tData.Thread, level, "slnf")
				if ok and (source ~= nil or line ~= nil or name ~= nil or func ~= nil) then
					if not location.Source and type(source) == "string" and source ~= "" then
						location.Source = source
					end
					if not location.Line and type(line) == "number" and line > 0 then
						location.Line = line
					end
					if not location.Name and type(name) == "string" and name ~= "" then
						location.Name = name
					end
					if not location.Script and typeof(func) == "function" then
						location.Function = func
						location.Script = getScriptFromFunction(func)
					end
					if location.Script and location.Line then
						break
					end
				end
			end
		end

		if not location.Source or not location.Line then
			local source, line = parseThreadTraceback(getThreadStack(tData))
			location.Source = location.Source or source
			location.Line = location.Line or line
		end

		tData.Location = location
		tData.SearchText = (tData.Name .. " " .. safeToString(tData.Status) .. " " .. safeToString(location.Source) .. " " .. safeToString(location.Line)):lower()
		return location
	end

	local function getThreadLocationText(tData)
		local location = getThreadLocation(tData)
		local source = "unknown source"
		if isScriptLike(location.Script) then
			source = safeToString(location.Script:GetFullName(), 180)
		elseif location.Source then
			source = safeToString(location.Source, 180)
		end
		if location.Line then
			return ("%s:%d"):format(source, location.Line)
		end
		return source
	end

	local function normalizeSourceText(source)
		if type(source) ~= "string" then return nil end
		source = source:gsub("^@", "")
		source = source:gsub("^game%.", "")
		source = source:gsub("^oldgame%.", "")
		source = source:gsub("^Script '([^']+)'$", "%1")
		source = source:gsub("^%s+", ""):gsub("%s+$", "")
		if source == "" or source:find("^%[string") then return nil end
		return source
	end

	local function sourceTextMatches(a, b)
		a = normalizeSourceText(a)
		b = normalizeSourceText(b)
		if not a or not b then return false end
		return a == b or a:sub(-#b) == b or b:sub(-#a) == a
	end

	local function lineInTargetRange(line, target)
		line = tonumber(line)
		if not line or line <= 0 then return false end
		local firstLine = tonumber(target.Line)
		local lastLine = tonumber(target.LastLine)
		if not firstLine or firstLine <= 0 then return true end
		if not lastLine or lastLine < firstLine then lastLine = firstLine end
		return line >= firstLine and line <= lastLine
	end

	local function isRunningThreadStatus(status)
		return status ~= "dead"
	end

	local function buildFunctionThreadTarget(func, label)
		if typeof(func) ~= "function" then return nil end
		local info, scriptObj = getFunctionInfo(func)
		local name = label or getFunctionDisplayName(func)
		local source = normalizeSourceText(info.source or info.short_src)
		local scriptPath
		if isScriptLike(scriptObj) then
			scriptPath = safeToString(scriptObj:GetFullName(), 260)
			source = source or normalizeSourceText(scriptPath)
		end
		return {
			Func = func,
			Name = name,
			Script = scriptObj,
			ScriptPath = scriptPath,
			Source = source,
			Line = tonumber(info.linedefined),
			LastLine = tonumber(info.lastlinedefined)
		}
	end

	local function threadMatchesFunction(tData, target, runningOnly)
		if not tData or not target then return false end
		if runningOnly and not isRunningThreadStatus(tData.Status) then return false end

		local debugInfo = debug and debug.info
		if debugInfo then
			for level = 0, 60 do
				local ok, source, line, name, func = pcall(debugInfo, tData.Thread, level, "slnf")
				if not ok then break end
				if source == nil and line == nil and name == nil and func == nil then break end
				if func == target.Func then
					return true
				end
				if typeof(func) == "function" then
					local scriptObj = getScriptFromFunction(func)
					if target.Script and scriptObj == target.Script and lineInTargetRange(line, target) then
						return true
					end
				end
				if lineInTargetRange(line, target) then
					if target.ScriptPath and sourceTextMatches(source, target.ScriptPath) then
						return true
					end
					if target.Source and sourceTextMatches(source, target.Source) then
						return true
					end
				end
			end
		end

		local location = getThreadLocation(tData)
		if lineInTargetRange(location.Line, target) then
			if target.Script and location.Script == target.Script then
				return true
			end
			if target.ScriptPath and sourceTextMatches(location.Source, target.ScriptPath) then
				return true
			end
			if target.Source and sourceTextMatches(location.Source, target.Source) then
				return true
			end
		end
		return false
	end

	local function clearThreadTargetFilter()
		threadPredicate = nil
		threadTargetSet = nil
		threadFilterLabel = ""
		threadLocateToken = threadLocateToken + 1
		if threadSearchBox then
			threadSearchBox.PlaceholderText = "Filter status / id..."
		end
	end

	local function applyThreadTargetFilter(label, targetSet)
		threadFilterLabel = label or ""
		threadTargetSet = targetSet
		threadPredicate = targetSet and function(tData)
			return targetSet[tData.Thread] == true
		end or nil
		threadFilter = ""
		if threadSearchBox then
			threadSearchBox.PlaceholderText = threadFilterLabel ~= "" and threadFilterLabel or "Filter status / id..."
			if threadSearchBox.Text ~= "" then
				threadSearchBox.Text = ""
			end
		end
		if EnvExplorer.Window then
			EnvExplorer.Window:Show()
		end
		if selectTab then
			selectTab("Threads")
		end
		if renderThreadsList then
			renderThreadsList()
		end
	end

	function locateThreadsForFunction(func, runningOnly)
		local target = buildFunctionThreadTarget(func)
		if not target then return end

		threadLocateToken = threadLocateToken + 1
		local locateToken = threadLocateToken
		local targetSet = {}
		local label = ("%s: %s"):format(runningOnly and "Running threads" or "Threads", target.Name)
		selectedThread = nil
		applyThreadTargetFilter(label, targetSet)
		setStatus("Locating " .. label .. "...")

		if #threadsList == 0 and not threadScanning then
			refreshThreadsList()
		end

		task.spawn(function()
			while threadScanning do
				if locateToken ~= threadLocateToken then return end
				task.wait(0.05)
			end

			local matches = 0
			selectedThread = nil
			for i = 1, #threadsList do
				if locateToken ~= threadLocateToken then return end
				local tData = threadsList[i]
				if threadMatchesFunction(tData, target, runningOnly) then
					targetSet[tData.Thread] = true
					matches = matches + 1
					selectedThread = selectedThread or tData
				end
				if i % 12 == 0 then
					setStatus(("Locating %s... %d/%d (%d matches)"):format(target.Name, i, #threadsList, matches))
					if renderThreadsList then renderThreadsList() end
					task.wait()
				end
			end

			if locateToken ~= threadLocateToken then return end
			if renderThreadsList then renderThreadsList() end
			setStatus(("Located %d %s for %s."):format(matches, runningOnly and "running threads" or "threads", target.Name))
		end)
	end

	function locateRunningThreads()
		threadLocateToken = threadLocateToken + 1
		local targetSet = {}
		selectedThread = nil
		applyThreadTargetFilter("Running threads", targetSet)
		for i = 1, #threadsList do
			local tData = threadsList[i]
			if isRunningThreadStatus(tData.Status) then
				targetSet[tData.Thread] = true
			end
		end
		if renderThreadsList then renderThreadsList() end
	end

	local function findScriptBySource(source)
		source = normalizeSourceText(source)
		if not source then return nil end

		local roots = {game, oldgame}
		local seenRoots = {}
		for _, root in ipairs(roots) do
			if typeof(root) == "Instance" and not seenRoots[root] then
				seenRoots[root] = true
				local ok, descendants = pcall(function()
					return root:GetDescendants()
				end)
				if ok and descendants then
					for i = 1, #descendants do
						local obj = descendants[i]
						if isScriptLike(obj) then
							local fullName = safeToString(obj:GetFullName(), 260)
							if fullName == source or ("game." .. fullName) == source or fullName:sub(-#source) == source then
								return obj
							end
						end
						if i % 500 == 0 then
							task.wait()
						end
					end
				end
			end
		end
		return nil
	end

	local function openThreadScriptAtLine(tData)
		if not tData then return end
		task.spawn(function()
			setStatus("Resolving thread script...")
			local location = getThreadLocation(tData)
			local scriptObj = location.Script
			if not isScriptLike(scriptObj) and location.Source then
				scriptObj = findScriptBySource(location.Source)
				location.Script = scriptObj
			end

			if isScriptLike(scriptObj) and ScriptViewer and ScriptViewer.ViewScript then
				local line = tonumber(location.Line) or 1
				if ScriptViewer.codeFrame and ScriptViewer.codeFrame.OwnerScript == scriptObj and ScriptViewer.Window then
					local targetLine = math.max(line - 1, 0)
					ScriptViewer.Window:Show()
					if ScriptViewer.codeFrame.ScrollToLineCentred then
						ScriptViewer.codeFrame:ScrollToLineCentred(targetLine)
					elseif ScriptViewer.codeFrame.ScrollV then
						ScriptViewer.codeFrame.ScrollV:ScrollTo(targetLine)
					end
					if ScriptViewer.codeFrame.MoveCursor then
						ScriptViewer.codeFrame:MoveCursor(0, targetLine)
					end
				else
					ScriptViewer.ViewScript(scriptObj, line)
				end
				setStatus(("Opening %s:%d"):format(safeToString(scriptObj.Name, 80), line))
			else
				openTextInScriptViewer(("-- Unable to resolve script for thread.\n-- Location: %s\n\n%s"):format(getThreadLocationText(tData), getThreadStack(tData)))
				warn("[EnvExplorer] Could not resolve a script instance for this thread.")
			end
		end)
	end

	local function closeThread(tData)
		if not tData then return end
		local thread = tData.Thread
		if thread == coroutine.running() then
			warn("[EnvExplorer] Refusing to close the currently running thread.")
			return
		end

		local ok, err = false, "No supported close/cancel function"
		if task and task.cancel then
			ok, err = pcall(task.cancel, thread)
		end
		if not ok and coroutine.close then
			ok, err = pcall(coroutine.close, thread)
		end

		if ok then
			local okStatus, status = pcall(coroutine.status, thread)
			tData.Status = okStatus and status or "closed"
			tData.Stack = "Thread closed/cancelled."
			tData.SearchText = (tData.Name .. " " .. tData.Status):lower()
			setStatus("Closed thread: " .. tData.Name)
			if renderThreadsList then renderThreadsList() end
		else
			warn("[EnvExplorer] Failed to close thread: " .. safeToString(err, 180))
			setStatus("Failed to close selected thread.")
		end
	end

	local function showThreadContextMenu(tData, x, y)
		if not tData then return end
		selectedThread = tData
		updateThreadStackView()
		if renderThreadsList then renderThreadsList() end

		if not threadContext then
			threadContext = Lib.ContextMenu.new()
		end
		threadContext:Clear()
		threadContext:Add({
			Name = "Decompile + Go to Line",
			IconMap = Main.MiscIcons,
			Icon = "ViewScript",
			OnClick = function()
				openThreadScriptAtLine(tData)
			end
		})
		threadContext:Add({
			Name = "Copy Stack",
			IconMap = Main.MiscIcons,
			Icon = "Copy",
			OnClick = function()
				pcall(setclipboard or writeclipboard, getThreadStack(tData))
			end
		})
		threadContext:Add({
			Name = "Copy Location",
			IconMap = Main.MiscIcons,
			Icon = "Reference",
			OnClick = function()
				pcall(setclipboard or writeclipboard, getThreadLocationText(tData))
			end
		})
		threadContext:Add({
			Name = "Close Thread",
			IconMap = Main.MiscIcons,
			Icon = "Delete",
			OnClick = function()
				closeThread(tData)
			end
		})
		local mouse = Main.Mouse
		threadContext:Show(x or mouse.X, y or mouse.Y)
	end

	function updateThreadStackView()
		if not threadStackText then return end
		if selectedThread then
			threadStackText.Text = ("-- Location: %s\n-- Status: %s\n\n%s"):format(getThreadLocationText(selectedThread), safeToString(selectedThread.Status), getThreadStack(selectedThread))
		else
			threadStackText.Text = getThreadStack(selectedThread)
		end
		if selectedThread then
			setStatus("Thread Stack: " .. selectedThread.Name)
		elseif threadScanning then
			setStatus("Scanning registry for threads...")
		elseif threadFilterLabel ~= "" then
			setStatus(("Showing %d/%d threads | %s"):format(#threadView, #threadsList, threadFilterLabel))
		else
			setStatus(("Scanned %d threads."):format(#threadsList))
		end
		if threadStackBox then
			task.defer(function()
				if threadStackText and threadStackBox then
					local height = math.max(threadStackText.TextBounds.Y + 14, threadStackBox.AbsoluteSize.Y - 10)
					threadStackText.Size = UDim2.new(1, -10, 0, height)
					threadStackBox.CanvasSize = UDim2.new(0, 0, 0, height + 10)
				end
			end)
		end
	end

	local function rebuildThreadView()
		table.clear(threadView)
		local filter = threadFilter:lower()
		local predicate = threadPredicate
		for i = 1, #threadsList do
			local tData = threadsList[i]
			local passesText = filter == "" or tData.SearchText:find(filter, 1, true)
			local passesTarget = not predicate or predicate(tData)
			if passesText and passesTarget then
				threadView[#threadView + 1] = tData
			end
		end
	end

	function renderThreadsList()
		if not threadScroll or not threadListFrame then return end
		rebuildThreadView()

		local maxRows = math.max(math.ceil(threadListFrame.AbsoluteSize.Y / 30), 0)
		threadScroll.VisibleSpace = maxRows
		threadScroll.TotalSpace = #threadView
		threadScroll.Gui.Visible = #threadView > maxRows
		threadScroll:Update()

		for i = 1, maxRows do
			local idx = i + threadScroll.Index
			local tData = threadView[idx]
			local rowFrame = threadRows[i]
			if not rowFrame then
				rowFrame = createSimple("TextButton", {
					Name = "ThreadRow_" .. i,
					AutoButtonColor = false,
					BackgroundColor3 = Settings.Theme.Main1,
					BorderSizePixel = 0,
					Size = UDim2.new(1, 0, 0, 28),
					Position = UDim2.new(0, 0, 0, (i - 1) * 30),
					Text = "",
					Parent = threadListFrame
				})
				createSimple("UICorner", {CornerRadius = UDim.new(0, 4), Parent = rowFrame})
				createSimple("UIStroke", {Color = Settings.Theme.Outline1, Thickness = 1, Parent = rowFrame})
				createSimple("Frame", {
					Name = "ActiveBar",
					BackgroundColor3 = Settings.Theme.Highlight,
					BorderSizePixel = 0,
					Position = UDim2.new(0, 0, 0, 3),
					Size = UDim2.new(0, 3, 1, -6),
					Visible = false,
					Parent = rowFrame
				})
				createSimple("TextLabel", {
					Name = "NameLabel",
					BackgroundTransparency = 1,
					Font = Enum.Font.Code,
					Position = UDim2.new(0, 8, 0, 0),
					Size = UDim2.new(1, -98, 1, 0),
					TextColor3 = Settings.Theme.Text,
					TextSize = 13,
					TextXAlignment = Enum.TextXAlignment.Left,
					Parent = rowFrame
				})
				createSimple("TextLabel", {
					Name = "StatusLabel",
					BackgroundTransparency = 1,
					Font = Enum.Font.SourceSansBold,
					Position = UDim2.new(1, -86, 0, 0),
					Size = UDim2.new(0, 80, 1, 0),
					TextSize = 12,
					TextXAlignment = Enum.TextXAlignment.Right,
					Parent = rowFrame
				})
				rowFrame.MouseButton1Click:Connect(function()
					local viewIndex = rowFrame:GetAttribute("ThreadIndex")
					local activeT = viewIndex and threadView[viewIndex]
					if activeT then
						selectedThread = activeT
						updateThreadStackView()
						renderThreadsList()
					end
				end)
				rowFrame.MouseButton2Click:Connect(function(x, y)
					local viewIndex = rowFrame:GetAttribute("ThreadIndex")
					local activeT = viewIndex and threadView[viewIndex]
					if activeT then
						showThreadContextMenu(activeT, x, y)
					end
				end)
				threadRows[i] = rowFrame
			end

			if tData then
				rowFrame:SetAttribute("ThreadIndex", idx)
				rowFrame.NameLabel.Text = tData.Location and (tData.Name .. "  @ " .. getThreadLocationText(tData)) or tData.Name
				rowFrame.StatusLabel.Text = tData.Status
				rowFrame.StatusLabel.TextColor3 = getThreadStatusColor(tData.Status)
				if tData == selectedThread then
					rowFrame.BackgroundColor3 = Settings.Theme.ListSelection
					rowFrame.ActiveBar.Visible = true
					rowFrame.NameLabel.TextColor3 = Settings.Theme.Highlight
				else
					rowFrame.BackgroundColor3 = Settings.Theme.Main1
					rowFrame.ActiveBar.Visible = false
					rowFrame.NameLabel.TextColor3 = Settings.Theme.Text
				end
				rowFrame.Visible = true
			else
				rowFrame:SetAttribute("ThreadIndex", nil)
				rowFrame.Visible = false
			end
		end

		for i = maxRows + 1, #threadRows do
			threadRows[i].Visible = false
		end
		updateThreadStackView()
	end

	function refreshThreadsList()
		threadScanToken = threadScanToken + 1
		local scanToken = threadScanToken
		threadScanning = true
		selectedThread = nil
		table.clear(threadsList)
		table.clear(threadView)
		renderThreadsList()

		task.spawn(function()
			local reg = (debug and debug.getregistry) or getreg
			if not reg then
				threadScanning = false
				setStatus("Thread registry unsupported by executor.")
				updateThreadStackView()
				return
			end

			local ok, registry = pcall(reg)
			if not ok or type(registry) ~= "table" then
				threadScanning = false
				setStatus("Failed to read registry for threads.")
				updateThreadStackView()
				return
			end

			local seen = {}
			local scanned = 0
			local count = 0
			for _, value in next, registry do
				scanned = scanned + 1
				if typeof(value) == "thread" and not seen[value] then
					seen[value] = true
					count = count + 1
					local okStatus, status = pcall(coroutine.status, value)
					status = okStatus and status or "unknown"
					local threadName = ("Thread #%d (%s)"):format(count, safeToString(value, 80))
					threadsList[#threadsList + 1] = {
						Thread = value,
						Name = threadName,
						Status = status,
						SearchText = (threadName .. " " .. status):lower()
					}
				end
				if scanned % 500 == 0 then
					if scanToken ~= threadScanToken then return end
					setStatus(("Scanning registry... %d entries, %d threads"):format(scanned, #threadsList))
					task.wait()
				end
			end

			if scanToken ~= threadScanToken then return end
			table.sort(threadsList, function(a, b)
				if a.Status == b.Status then
					return a.Name < b.Name
				end
				return a.Status < b.Status
			end)
			threadScanning = false
			renderThreadsList()
			setStatus(("Scanned %d threads from registry."):format(#threadsList))
		end)
	end

	-- Tab 4: Bytecode Disassembler Logic
	-- A highly optimized, compact varint reader & Luau instruction decoder
	local function disassemble(bytecode)
		local bit = bit32
		local band, bor, lshift, extract = bit.band, bit.bor, bit.lshift, bit.extract
		local lines = {}
		local stream = {str = bytecode, pos = 1}
		function stream:readByte()
			local b = self.str:byte(self.pos)
			self.pos = self.pos + 1
			return b or 0
		end
		function stream:readVarInt()
			local result = 0
			local shift = 0
			while true do
				local b = self:readByte()
				result = bor(result, lshift(band(b, 0x7F), shift))
				if band(b, 0x80) == 0 then break end
				shift = shift + 7
			end
			return result
		end
		function stream:readInt32()
			local pos = self.pos
			local b1, b2, b3, b4 = self.str:byte(pos, pos + 3)
			self.pos = pos + 4
			return bor(b1 or 0, lshift(b2 or 0, 8), lshift(b3 or 0, 16), lshift(b4 or 0, 24))
		end

		local version = stream:readByte()
		if version == 0 then
			return {"-- Bytecode error: bytecode is empty or compilation failed."}
		end

		local stringCount = stream:readVarInt()
		local stringTable = {}
		for i = 1, stringCount do
			local len = stream:readVarInt()
			local s = stream.str:sub(stream.pos, stream.pos + len - 1)
			stream.pos = stream.pos + len
			stringTable[i] = s
		end

		local protoCount = stream:readVarInt()
		lines[#lines + 1] = ("-- Luau Bytecode Version: %d | String Table: %d items | Prototypes: %d"):format(version, stringCount, protoCount)
		lines[#lines + 1] = ""

		local OP_NAMES = {
			[0] = "NOP", "BREAK", "LOADNIL", "LOADBOOL", "LOADNUMBER", "LOADK", "MOVE",
			"GETGLOBAL", "SETGLOBAL", "GETUPVAL", "SETUPVAL", "CLOSEUPVALS", "GETIMPORT",
			"GETTABLE", "SETTABLE", "GETTABLEKS", "SETTABLEKS", "GETTABLEN", "SETTABLEN",
			"NEWCLOSURE", "NAMECALL", "CALL", "RETURN", "JUMP", "JUMPIF", "JUMPIFNOT",
			"JUMPIFEQ", "JUMPIFNOTEQ", "JUMPIFLT", "JUMPIFNOTLT", "JUMPIFLE", "JUMPIFNOTLE",
			"LOOP", "FORPREP", "FORLOOP", "SETLIST", "CLOSEOUT", "CONCAT", "ADD", "SUB",
			"MUL", "DIV", "MOD", "POW", "UNM", "LEN", "NOT", "AND", "OR", "XOR",
			"SUBK", "MULK", "DIVK", "MODK", "POWK", "ADDK", "SUBK_R", "MULK_R", "DIVK_R",
			"MODK_R", "POWK_R", "GETVARARGS", "DUPCLOSURE", "PREPVARARGS", "LOADKX"
		}

		for pIdx = 1, protoCount do
			local maxstacksize = stream:readByte()
			local numparams = stream:readByte()
			local numupvalues = stream:readByte()
			local isvararg = stream:readByte()

			local sizecode = stream:readVarInt()
			local code = {}
			for i = 1, sizecode do
				code[i] = stream:readInt32()
			end

			local sizeconstants = stream:readVarInt()
			local constants = {}
			for i = 1, sizeconstants do
				local cType = stream:readByte()
				if cType == 0 then
					constants[i] = "nil"
				elseif cType == 1 then
					constants[i] = stream:readByte() == 1
				elseif cType == 2 then
					-- double: read bytes
					stream.pos = stream.pos + 8
					constants[i] = "<double>"
				elseif cType == 3 then
					local sIdx = stream:readVarInt()
					constants[i] = stringTable[sIdx] or ""
				elseif cType == 4 then
					stream.pos = stream.pos + 4
					constants[i] = "<import>"
				elseif cType == 5 then
					constants[i] = "<table>"
				elseif cType == 6 then
					constants[i] = "proto_" .. stream:readVarInt()
				end
			end

			local sizeprotos = stream:readVarInt()
			local protos = {}
			for i = 1, sizeprotos do
				protos[i] = stream:readVarInt()
			end

			-- Lineinfo & Debuginfo reading (skip debug symbols for brevity)
			local lineinfo = stream:readVarInt()
			if lineinfo > 0 then
				stream.pos = stream.pos + sizecode -- skip line info bytes
			end

			lines[#lines + 1] = ("-- Proto #%d (Params: %d, Upvalues: %d, Stack: %d)"):format(pIdx - 1, numparams, numupvalues, maxstacksize)
			local pc = 0
			while pc < sizecode do
				local inst = code[pc + 1]
				local op = extract(inst, 0, 8)
				local a = extract(inst, 8, 8)
				local b = extract(inst, 16, 8)
				local c = extract(inst, 24, 8)
				local opName = OP_NAMES[op] or ("OP_0x%02X"):format(op)

				local disassembly = ("  [%04d]  %-14s  R%d, R%d, R%d"):format(pc, opName, a, b, c)

				-- Resolve constants & imports to make instructions readable
				if opName == "LOADK" or opName == "GETGLOBAL" or opName == "SETGLOBAL" then
					local bx = extract(inst, 16, 16)
					local kVal = constants[bx + 1] or ""
					disassembly = disassembly .. ("  ; K[%d] (%s)"):format(bx, tostring(kVal))
				elseif opName == "GETIMPORT" then
					disassembly = disassembly .. "  ; IMPORT"
				elseif opName == "NEWCLOSURE" then
					local bx = extract(inst, 16, 16)
					disassembly = disassembly .. ("  ; Proto #%d"):format(bx)
				end

				lines[#lines + 1] = disassembly
				pc = pc + 1
			end
			lines[#lines + 1] = ""
		end

		return lines
	end

	local function updateDisassemblyView()
		local maxRows = math.max(math.ceil(disListFrame.AbsoluteSize.Y / 18), 0)
		disScroll.TotalSpace = #disassemblyLines
		disScroll:Update()

		for i = 1, maxRows do
			local idx = i + disScroll.Index
			local text = disassemblyLines[idx]
			local labelName = "DisLine_" .. i
			local label = disListFrame:FindFirstChild(labelName)
			if not label then
				label = createSimple("TextLabel", {
					Name = labelName,
					BackgroundTransparency = 1,
					Size = UDim2.new(1, 0, 0, 16),
					Position = UDim2.new(0, 5, 0, (i - 1) * 18),
					Font = Enum.Font.Code,
					TextSize = 13,
					TextColor3 = Settings.Theme.Syntax.Text,
					TextXAlignment = Enum.TextXAlignment.Left,
					Parent = disListFrame
				})
			end

			if text then
				label.Text = text
				if text:find("^%s*%-%-") then
					label.TextColor3 = Settings.Theme.Syntax.Comment
				elseif text:find("%[%d+%]") then
					label.TextColor3 = TYPE_COLORS.opcode
				else
					label.TextColor3 = Settings.Theme.Syntax.Text
				end
				label.Visible = true
			else
				label.Visible = false
			end
		end
	end

	EnvExplorer.Disassemble = function(scr)
		if not scr then return end
		disassembleScript = scr
		disStatusLabel.Text = "Reading Bytecode..."
		task.spawn(function()
			local s, bytecode = pcall(env.getscriptbytecode or getscriptbytecode, scr)
			if s and bytecode then
				disassemblyLines = disassemble(bytecode)
				disStatusLabel.Text = ("Disassembled: %s (%d instructions)"):format(scr.Name, #disassemblyLines)
			else
				disassemblyLines = {
					"-- Disassembly failed.",
					"-- Reason: " .. tostring(bytecode or "getscriptbytecode returned nil or unsupported by executor")
				}
				disStatusLabel.Text = "Disassembly Error."
			end
			updateDisassemblyView()
		end)
	end

	-- Window / Tabs UI Setup
	function selectTab(tabName)
		currentTab = tabName
		for _, child in next, tabsFrame:GetChildren() do
			if child:IsA("TextButton") then
				if child.Name == tabName then
					child.BackgroundColor3 = Settings.Theme.ListSelection
					child.TextColor3 = Settings.Theme.Highlight
				else
					child.BackgroundColor3 = Settings.Theme.Button
					child.TextColor3 = Settings.Theme.Text
				end
			end
		end

		-- Toggle page frames
		contentFrame.ExplorerPage.Visible = (tabName == "Globals" or tabName == "Registry")
		contentFrame.ThreadsPage.Visible = (tabName == "Threads")
		contentFrame.DisassemblerPage.Visible = (tabName == "Disassembler")

		if tabName == "Globals" or tabName == "Registry" then
			activeExplorerType = tabName
			flattenTree()
			updateExplorerView()
		elseif tabName == "Threads" then
			if #threadsList == 0 and not threadScanning then
				refreshThreadsList()
			else
				renderThreadsList()
			end
		elseif tabName == "Disassembler" then
			updateDisassemblyView()
		end
	end

	EnvExplorer.SelectTab = selectTab

	EnvExplorer.Init = function()
		window = Lib.Window.new()
		window:SetTitle("Env Explorer & Utilities")
		window:Resize(380, 480)
		EnvExplorer.Window = window

		local cHolder = window.GuiElems.Content

		-- 1. Tab Bar
		tabsFrame = createSimple("Frame", {
			Name = "Tabs",
			BackgroundColor3 = Settings.Theme.Main2,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 26),
			Parent = cHolder
		})
		createSimple("Frame", {
			BackgroundColor3 = Settings.Theme.Outline1,
			BorderSizePixel = 0,
			Position = UDim2.new(0, 0, 1, -1),
			Size = UDim2.new(1, 0, 0, 1),
			Parent = tabsFrame
		})

		local tabs = {"Globals", "Registry", "Threads", "Disassembler"}
		for idx, name in ipairs(tabs) do
			local tabBtn = createSimple("TextButton", {
				Name = name,
				BackgroundColor3 = Settings.Theme.Button,
				BorderSizePixel = 0,
				Size = UDim2.new(0.25, 0, 1, -1),
				Position = UDim2.new(0.25 * (idx - 1), 0, 0, 0),
				Font = Enum.Font.SourceSansBold,
				Text = name,
				TextColor3 = Settings.Theme.Text,
				TextSize = 13,
				Parent = tabsFrame
			})
			tabBtn.MouseButton1Click:Connect(function()
				selectTab(name)
			end)
		end

		-- 2. Content Frame
		contentFrame = createSimple("Frame", {
			Name = "ContentFrame",
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 0, 0, 26),
			Size = UDim2.new(1, 0, 1, -46),
			Parent = cHolder
		})

		-- 3. Status Bar
		statusBar = createSimple("Frame", {
			Name = "StatusBar",
			BackgroundColor3 = Settings.Theme.Main2,
			BorderSizePixel = 0,
			Position = UDim2.new(0, 0, 1, -20),
			Size = UDim2.new(1, 0, 0, 20),
			Parent = cHolder
		})
		createSimple("Frame", {
			BackgroundColor3 = Settings.Theme.Outline1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 1),
			Parent = statusBar
		})
		statusText = createSimple("TextLabel", {
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSans,
			Position = UDim2.new(0, 5, 0, 0),
			Size = UDim2.new(1, -10, 1, 0),
			Text = "Ready",
			TextColor3 = Settings.Theme.PlaceholderText,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = statusBar
		})

		-- Page 1: Explorer Page (Tree View)
		local explorerPage = createSimple("Frame", {
			Name = "ExplorerPage",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 1, 0),
			Parent = contentFrame
		})

		local searchFrame = createSimple("Frame", {
			Name = "SearchFrame",
			BackgroundColor3 = Settings.Theme.TextBox,
			BorderSizePixel = 0,
			Position = UDim2.new(0, 3, 0, 3),
			Size = UDim2.new(1, -116, 0, 20),
			Parent = explorerPage
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 2), Parent = searchFrame})
		local searchStroke = createSimple("UIStroke", {Thickness = 1.4, Color = Settings.Theme.Outline3, Parent = searchFrame})

		searchBox = createSimple("TextBox", {
			BackgroundTransparency = 1,
			ClearTextOnFocus = false,
			Font = Enum.Font.SourceSans,
			PlaceholderColor3 = Settings.Theme.PlaceholderText,
			PlaceholderText = "Filter expanded keys / values...",
			Position = UDim2.new(0, 4, 0, 0),
			Size = UDim2.new(1, -8, 0, 20),
			Text = "",
			TextColor3 = Settings.Theme.Text,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = searchFrame
		})
		Lib.ViewportTextBox.convert(searchBox)
		searchBox:GetPropertyChangedSignal("Text"):Connect(function()
			query = searchBox.Text
			flattenTree()
			updateExplorerView()
		end)
		searchBox.Focused:Connect(function() searchStroke.Color = Settings.Theme.Highlight end)
		searchBox.FocusLost:Connect(function() searchStroke.Color = Settings.Theme.Outline3 end)

		local refreshBtn = createSimple("TextButton", {
			Name = "RefreshExplorer",
			BackgroundColor3 = Settings.Theme.Button,
			BorderSizePixel = 0,
			Font = Enum.Font.SourceSans,
			Position = UDim2.new(1, -109, 0, 3),
			Size = UDim2.new(0, 52, 0, 20),
			Text = "Refresh",
			TextColor3 = Settings.Theme.Text,
			TextSize = 12,
			Parent = explorerPage
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 2), Parent = refreshBtn})
		refreshBtn.MouseButton1Click:Connect(function()
			refreshExplorerTree()
		end)

		local collapseBtn = createSimple("TextButton", {
			Name = "CollapseExplorer",
			BackgroundColor3 = Settings.Theme.Button,
			BorderSizePixel = 0,
			Font = Enum.Font.SourceSans,
			Position = UDim2.new(1, -55, 0, 3),
			Size = UDim2.new(0, 52, 0, 20),
			Text = "Collapse",
			TextColor3 = Settings.Theme.Text,
			TextSize = 12,
			Parent = explorerPage
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 2), Parent = collapseBtn})
		collapseBtn.MouseButton1Click:Connect(function()
			collapseExplorerTree()
		end)

		listFrame = createSimple("Frame", {
			Name = "List",
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 0, 0, 27),
			Size = UDim2.new(1, 0, 1, -27),
			ClipsDescendants = true,
			Parent = explorerPage
		})

		scrollV = Lib.ScrollBar.new()
		scrollV.WheelIncrement = 3
		scrollV.Gui.Position = UDim2.new(1, -16, 0, 27)
		scrollV.Gui.Size = UDim2.new(0, 16, 1, -27)
		scrollV:SetScrollFrame(listFrame)
		scrollV.Gui.Parent = explorerPage
		scrollV.Scrolled:Connect(updateExplorerView)

		-- Inline TextBox setup
		editBox = createSimple("TextBox", {
			BackgroundColor3 = Settings.Theme.TextBox,
			ClearTextOnFocus = false,
			Font = Enum.Font.Code,
			Name = "EditBox",
			PlaceholderColor3 = Settings.Theme.PlaceholderText,
			Position = UDim2.new(0, 0, 0, 0),
			Size = UDim2.new(0, 100, 0, 16),
			Text = "",
			TextColor3 = Settings.Theme.Text,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			Visible = false,
			ZIndex = 3,
			Parent = listFrame
		})
		createSimple("UIStroke", {Color = Settings.Theme.Highlight, Thickness = 1.4, Parent = editBox})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 2), Parent = editBox})

		confirmBtn = createSimple("TextButton", {
			BackgroundColor3 = Settings.Theme.Button,
			BorderSizePixel = 0,
			Font = Enum.Font.SourceSansBold,
			Text = "",
			Visible = false,
			ZIndex = 4,
			Parent = listFrame
		})
		local btnStroke = createSimple("UIStroke", {Color = Settings.Theme.Outline2, Thickness = 1.4, Parent = confirmBtn})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 2), Parent = confirmBtn})
		local btnIcon = createSimple("ImageLabel", {
			Name = "Icon",
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 12, 0, 12),
			Position = UDim2.new(0.5, -6, 0.5, -6),
			Parent = confirmBtn
		})
		Main.MiscIcons:DisplayByKey(btnIcon, "Rename")

		confirmBtn.MouseButton1Click:Connect(function()
			if editBox.Visible then editBox:ReleaseFocus(true) end
		end)
		confirmBtn.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				btnStroke.Color = Settings.Theme.Highlight
			end
		end)
		confirmBtn.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				btnStroke.Color = Settings.Theme.Outline2
			end
		end)

		editBox.FocusLost:Connect(function(enterPressed)
			if not editingNode then return end
			if enterPressed then
				local newValue = parseValue(editBox.Text, editingNode.ValueType)
				if newValue ~= nil then
					local success, err
					if editingNode.Type == "Upvalue" then
						success, err = pcall(function()
							debug.setupvalue(editingNode.Func, editingNode.Index, newValue)
						end)
					elseif editingNode.Type == "Constant" then
						local setconstant = (debug and debug.setconstant) or setconstant or setconst
						if setconstant then
							success, err = pcall(setconstant, editingNode.Func, editingNode.Index, newValue)
						else
							success, err = false, "Unsupported by executor"
						end
					elseif editingNode.Type == "TableMember" then
						local pathKeys = {}
						local curr = editingNode
						while curr and curr.Type == "TableMember" do
							table.insert(pathKeys, 1, curr.Key)
							curr = curr.Parent
						end
						if curr and type(curr.Value) == "table" then
							local targetTbl = curr.Value
							for i = 1, #pathKeys - 1 do
								targetTbl = targetTbl[pathKeys[i]]
								if type(targetTbl) ~= "table" then
									targetTbl = nil
									break
								end
							end
							if targetTbl then
								targetTbl[pathKeys[#pathKeys]] = newValue
								success = true
							end
						end
					end

					if success then
						editingNode.Value = newValue
					else
						warn("[EnvExplorer] Failed to modify value: " .. tostring(err))
					end
				end
			end
			editBox.Visible = false
			editingNode = nil
			updateExplorerView()
		end)

		-- Page 2: Threads Monitor Page
		local threadsPage = createSimple("Frame", {
			Name = "ThreadsPage",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 1, 0),
			Visible = false,
			Parent = contentFrame
		})

		local threadHeader = createSimple("Frame", {
			Name = "ThreadHeader",
			BackgroundColor3 = Settings.Theme.Main2,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 30),
			Parent = threadsPage
		})
		createSimple("TextLabel", {
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSansBold,
			Position = UDim2.new(0, 5, 0, 0),
			Size = UDim2.new(0, 118, 1, 0),
			Text = "Threads",
			TextColor3 = Settings.Theme.Text,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = threadHeader
		})

		local threadSearchFrame = createSimple("Frame", {
			Name = "ThreadSearchFrame",
			BackgroundColor3 = Settings.Theme.TextBox,
			BorderSizePixel = 0,
			Position = UDim2.new(0, 86, 0, 5),
			Size = UDim2.new(1, -224, 0, 20),
			Parent = threadHeader
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 2), Parent = threadSearchFrame})
		createSimple("UIStroke", {Color = Settings.Theme.Outline3, Thickness = 1.2, Parent = threadSearchFrame})
		threadSearchBox = createSimple("TextBox", {
			Name = "ThreadSearch",
			BackgroundTransparency = 1,
			ClearTextOnFocus = false,
			Font = Enum.Font.SourceSans,
			PlaceholderColor3 = Settings.Theme.PlaceholderText,
			PlaceholderText = "Filter status / id...",
			Position = UDim2.new(0, 4, 0, 0),
			Size = UDim2.new(1, -8, 1, 0),
			Text = "",
			TextColor3 = Settings.Theme.Text,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = threadSearchFrame
		})
		Lib.ViewportTextBox.convert(threadSearchBox)
		threadSearchBox:GetPropertyChangedSignal("Text"):Connect(function()
			threadFilter = threadSearchBox.Text or ""
			renderThreadsList()
		end)

		local threadRefreshBtn = createSimple("TextButton", {
			Name = "RefreshThreads",
			BackgroundColor3 = Settings.Theme.Button,
			BorderSizePixel = 0,
			Position = UDim2.new(1, -134, 0, 5),
			Size = UDim2.new(0, 62, 0, 20),
			Font = Enum.Font.SourceSans,
			Text = "Scan",
			TextColor3 = Settings.Theme.Text,
			TextSize = 12,
			Parent = threadHeader
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 2), Parent = threadRefreshBtn})
		threadRefreshBtn.MouseButton1Click:Connect(function()
			clearThreadTargetFilter()
			refreshThreadsList()
		end)

		local threadCopyBtn = createSimple("TextButton", {
			Name = "CopyThreadStack",
			BackgroundColor3 = Settings.Theme.Button,
			BorderSizePixel = 0,
			Position = UDim2.new(1, -68, 0, 5),
			Size = UDim2.new(0, 64, 0, 20),
			Font = Enum.Font.SourceSans,
			Text = "Copy Stack",
			TextColor3 = Settings.Theme.Text,
			TextSize = 12,
			Parent = threadHeader
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 2), Parent = threadCopyBtn})
		threadCopyBtn.MouseButton1Click:Connect(function()
			if selectedThread then
				pcall(setclipboard or writeclipboard, getThreadStack(selectedThread))
			end
		end)

		threadListFrame = createSimple("Frame", {
			Name = "ThreadList",
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 4, 0, 34),
			Size = UDim2.new(1, -24, 0.45, -34),
			ClipsDescendants = true,
			Parent = threadsPage
		})

		threadScroll = Lib.ScrollBar.new()
		threadScroll.WheelIncrement = 2
		threadScroll.Gui.Position = UDim2.new(1, -16, 0, 34)
		threadScroll.Gui.Size = UDim2.new(0, 16, 0.45, -34)
		threadScroll:SetScrollFrame(threadListFrame)
		threadScroll.Gui.Parent = threadsPage
		threadScroll.Scrolled:Connect(renderThreadsList)

		local threadActionFrame = createSimple("Frame", {
			Name = "ThreadActions",
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 4, 0.45, 4),
			Size = UDim2.new(1, -8, 0, 24),
			Parent = threadsPage
		})

		local openThreadBtn = createSimple("TextButton", {
			Name = "OpenThreadLine",
			BackgroundColor3 = Settings.Theme.Button,
			BorderSizePixel = 0,
			Font = Enum.Font.SourceSans,
			Position = UDim2.new(0, 0, 0, 1),
			Size = UDim2.new(0.45, -3, 1, -2),
			Text = "Decompile @ Line",
			TextColor3 = Settings.Theme.Text,
			TextSize = 12,
			Parent = threadActionFrame
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 2), Parent = openThreadBtn})
		openThreadBtn.MouseButton1Click:Connect(function()
			openThreadScriptAtLine(selectedThread)
		end)

		local copyThreadLocationBtn = createSimple("TextButton", {
			Name = "CopyThreadLocation",
			BackgroundColor3 = Settings.Theme.Button,
			BorderSizePixel = 0,
			Font = Enum.Font.SourceSans,
			Position = UDim2.new(0.45, 3, 0, 1),
			Size = UDim2.new(0.27, -4, 1, -2),
			Text = "Copy Loc",
			TextColor3 = Settings.Theme.Text,
			TextSize = 12,
			Parent = threadActionFrame
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 2), Parent = copyThreadLocationBtn})
		copyThreadLocationBtn.MouseButton1Click:Connect(function()
			if selectedThread then
				pcall(setclipboard or writeclipboard, getThreadLocationText(selectedThread))
			end
		end)

		local closeThreadBtn = createSimple("TextButton", {
			Name = "CloseThread",
			BackgroundColor3 = Color3.fromRGB(105, 45, 45),
			BorderSizePixel = 0,
			Font = Enum.Font.SourceSansBold,
			Position = UDim2.new(0.72, 3, 0, 1),
			Size = UDim2.new(0.28, -3, 1, -2),
			Text = "Close Thread",
			TextColor3 = Settings.Theme.Text,
			TextSize = 12,
			Parent = threadActionFrame
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 2), Parent = closeThreadBtn})
		closeThreadBtn.MouseButton1Click:Connect(function()
			closeThread(selectedThread)
		end)

		-- Details Box for Call Stack
		threadStackBox = createSimple("ScrollingFrame", {
			Name = "StackBox",
			BackgroundColor3 = Settings.Theme.TextBox,
			BorderSizePixel = 0,
			Position = UDim2.new(0, 4, 0.45, 32),
			Size = UDim2.new(1, -8, 0.55, -36),
			CanvasSize = UDim2.new(0, 0, 0, 0),
			ScrollBarThickness = 6,
			Parent = threadsPage
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 4), Parent = threadStackBox})
		createSimple("UIStroke", {Color = Settings.Theme.Outline1, Parent = threadStackBox})

		threadStackText = createSimple("TextLabel", {
			BackgroundTransparency = 1,
			Font = Enum.Font.Code,
			Position = UDim2.new(0, 5, 0, 5),
			Size = UDim2.new(1, -10, 0, 100),
			Text = "Select a thread to view its traceback.",
			TextColor3 = Color3.fromRGB(220, 220, 220),
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Parent = threadStackBox
		})

		-- Page 3: Disassembler Page
		local disPage = createSimple("Frame", {
			Name = "DisassemblerPage",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 1, 0),
			Visible = false,
			Parent = contentFrame
		})

		local disHeader = createSimple("Frame", {
			Name = "DisassemblerHeader",
			BackgroundColor3 = Settings.Theme.Main2,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 24),
			Parent = disPage
		})
		disStatusLabel = createSimple("TextLabel", {
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSansBold,
			Position = UDim2.new(0, 5, 0, 0),
			Size = UDim2.new(1, -10, 1, 0),
			Text = "No script loaded for disassembly.",
			TextColor3 = Settings.Theme.Text,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = disHeader
		})

		disListFrame = createSimple("Frame", {
			Name = "DisassemblyList",
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 0, 0, 26),
			Size = UDim2.new(1, -16, 1, -26),
			ClipsDescendants = true,
			Parent = disPage
		})

		disScroll = Lib.ScrollBar.new()
		disScroll.WheelIncrement = 3
		disScroll.Gui.Position = UDim2.new(1, -16, 0, 26)
		disScroll.Gui.Size = UDim2.new(0, 16, 1, -26)
		disScroll:SetScrollFrame(disListFrame)
		disScroll.Gui.Parent = disPage
		disScroll.Scrolled:Connect(updateDisassemblyView)

		-- Window sizing update events
		window.GuiElems.Main:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if window:IsContentVisible() then
				if currentTab == "Globals" or currentTab == "Registry" then
					updateExplorerView()
				elseif currentTab == "Threads" then
					renderThreadsList()
				elseif currentTab == "Disassembler" then
					updateDisassemblyView()
				end
			end
		end)

		context = Lib.ContextMenu.new()
		initExplorerClickSystem()

		-- Select Globals tab by default
		selectTab("Globals")
	end

	return EnvExplorer
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
