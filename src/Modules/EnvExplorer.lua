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

	-- State
	local window, currentTab
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

	-- Tab 3: Threads Monitor variables
	local threadsList = {}
	local selectedThread
	local threadScroll, threadListFrame

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

	local function formatValue(val, valType)
		if valType == "string" then
			return '"' .. tostring(val) .. '"'
		elseif valType == "nil" then
			return "nil"
		elseif valType == "table" then
			return "Table: " .. tostring(val)
		elseif valType == "function" then
			local name = "anonymous"
			pcall(function()
				local inf = debug.getinfo(val)
				name = inf.name ~= "" and inf.name or ("anonymous_line_%d"):format(inf.linedefined or 0)
			end)
			return ("Function: %s (%s)"):format(name, tostring(val))
		elseif valType == "userdata" or typeof(val) == "Instance" then
			local str = tostring(val)
			local name = str
			pcall(function()
				if typeof(val) == "Instance" then
					name = val:GetFullName()
				else
					local getraw = getrawmetatable or getmetatable
					local mt = getraw(val)
					if mt then
						if mt.__type then
							name = tostring(mt.__type) .. " (" .. str .. ")"
						elseif mt.__tostring then
							name = tostring(val)
						end
					end
				end
			end)
			return name
		else
			return tostring(val)
		end
	end

	local function getTableSummary(tbl)
		local counts = {}
		local total = 0
		local success = pcall(function()
			for k, v in next, tbl do
				total = total + 1
				if total > 200 then break end
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
			return " (" .. table.concat(parts, ", ") .. ")"
		else
			return " (empty)"
		end
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
			pcall(function()
				for k, v in next, node.Value do
					count = count + 1
					if count > 200 then
						tList[#tList + 1] = {
							Name = "... (truncated)",
							Type = "Metadata",
							Depth = depth,
							Parent = node,
							Children = {},
							Value = "Truncated",
							ValueType = "string"
						}
						break
					end
					local vType = typeof(v)
					local tbValText = ""
					if vType == "table" then
						tbValText = getTableSummary(v)
					end
					local childNode = {
						Name = tostring(k) .. ":" .. tbValText,
						Type = "TableMember",
						Depth = depth,
						Expanded = false,
						Parent = node,
						Children = {},
						Key = k,
						Value = v,
						ValueType = vType
					}
					childNode.Path = node.Path .. "/" .. tostring(k)
					tList[#tList + 1] = childNode
				end
			end)
			node.Children = tList
		elseif type(node.Value) == "function" then
			-- Load function metadata/upvalues/constants
			local depth = node.Depth + 1
			local children = {}

			local getupvalues = (debug and debug.getupvalues) or getupvalues or getupvals
			local getconstants = (debug and debug.getconstants) or getconstants or getconsts
			local getinfo = (debug and (debug.getinfo or debug.info)) or getinfo
			local getprotos = (debug and debug.getprotos) or getprotos

			-- 1. Upvalues
			local s, upvals = pcall(getupvalues, node.Value)
			if s and upvals and #upvals > 0 then
				local upsNode = {
					Name = "Upvalues (" .. #upvals .. ")",
					Type = "UpvaluesFolder",
					Depth = depth,
					Expanded = false,
					Parent = node,
					Children = {}
				}
				upsNode.Path = node.Path .. "/Upvalues"
				for idx, val in next, upvals do
					local vType = typeof(val)
					local summary = vType == "table" and getTableSummary(val) or ""
					local upNode = {
						Name = ("[%d] upval_%d%s"):format(idx, idx, summary),
						Type = "Upvalue",
						Depth = depth + 1,
						Index = idx,
						Parent = upsNode,
						Children = {},
						Value = val,
						ValueType = vType,
						Func = node.Value
					}
					upNode.Path = upsNode.Path .. "/" .. idx
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
					Expanded = false,
					Parent = node,
					Children = {}
				}
				constsNode.Path = node.Path .. "/Constants"
				for idx, val in next, consts do
					local vType = typeof(val)
					local summary = vType == "table" and getTableSummary(val) or ""
					local conNode = {
						Name = ("[%d]%s"):format(idx, summary),
						Type = "Constant",
						Depth = depth + 1,
						Index = idx,
						Parent = constsNode,
						Children = {},
						Value = val,
						ValueType = vType,
						Func = node.Value
					}
					conNode.Path = constsNode.Path .. "/" .. idx
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
						Expanded = false,
						Parent = node,
						Children = {}
					}
					protosNode.Path = node.Path .. "/Prototypes"
					for idx, pFunc in next, protos do
						local pName = "anonymous"
						pcall(function()
							local inf = getinfo(pFunc)
							pName = inf.name ~= "" and inf.name or ("anonymous_line_%d"):format(inf.linedefined or 0)
						end)
						local pNode = {
							Name = ("[%d] %s"):format(idx, pName),
							Type = "Function",
							Func = pFunc,
							Depth = depth + 1,
							Parent = protosNode,
							Children = {},
							Value = pFunc,
							ValueType = "function"
						}
						pNode.Path = protosNode.Path .. "/" .. idx
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

		local function addExpanded(node)
			if node.Expanded then
				loadNodeChildren(node)
				for i = 1, #node.Children do
					local child = node.Children[i]
					tree[#tree + 1] = child
					addExpanded(child)
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
				if matchQuery(node.Name) or node.Expanded then
					tree[#tree + 1] = node
					addExpanded(node)
				end
			end
		else
			-- Registry explorer
			local reg = (debug and debug.getregistry) or getreg
			if reg then
				local regVal = reg()
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
					local nameSize = service.TextService:GetTextSize(node.Name, 13, Enum.Font.Code, Vector2.new(9999, ROW_H)).X
					entry.Name.Size = UDim2.new(0, nameSize + 4, 1, 0)

					entry.ValueLabel.Position = UDim2.new(0, depth * INDENT + NAME_OFF + nameSize + 8, 0, 0)
					entry.ValueLabel.Size = UDim2.new(1, -(depth * INDENT + NAME_OFF + nameSize + 8) - 4, 1, 0)
					entry.ValueLabel.Text = formatValue(node.Value, node.ValueType)
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
				elseif node.ValueType == "table" then iconKey = "Honey"
				elseif node.Type == "Metadata" then iconKey = "ExploreData"
				end
				miscIcons:DisplayByKey(entry.Icon, iconKey)
				entry.Icon.ImageTransparency = (node.ValueType == "function" or node.Type == "Upvalue") and 0 or 0.35

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
		local nameSize = service.TextService:GetTextSize(node.Name, 13, Enum.Font.Code, Vector2.new(9999, ROW_H)).X
		local xPos = node.Depth * INDENT + NAME_OFF + nameSize + 8

		editBox.Position = UDim2.new(0, xPos, 0, entry.Gui.Position.Y.Offset + 2)
		editBox.Size = UDim2.new(1, -xPos - 30, 0, 16)
		editBox.Visible = true
		editBox:CaptureFocus()

		confirmBtn.Position = UDim2.new(1, -26, 0, entry.Gui.Position.Y.Offset)
		confirmBtn.Size = UDim2.new(0, 20, 0, 20)
		confirmBtn.Visible = true
	end

	local function showExplorerContextMenu(position)
		if not selectedNode then return end
		context:Clear()

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
					pcall(setclipboard or writeclipboard, tostring(selectedNode.Value))
				end
			})
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
				Name = "Decompile Function",
				IconMap = Main.MiscIcons,
				Icon = "ViewScript",
				OnClick = function()
					local scr = selectedNode.FuncScript
					if scr then
						ScriptViewer.ViewScript(scr)
					else
						-- fallback: try to decompile function object directly if supported
						local s, src = pcall(env.decompile, selectedNode.Value)
						if s and src then
							ScriptViewer.Window:Show()
							ScriptViewer.codeFrame:SetText(src)
						else
							warn("[EnvExplorer] Cannot decompile this function closure.")
						end
					end
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

			selectedNode = node
			updateExplorerView()

			if button == 1 and combo == 2 then
				local isEditable = (node.Type == "Upvalue" or node.Type == "Constant" or node.Type == "TableMember") and (node.ValueType == "number" or node.ValueType == "boolean" or node.ValueType == "string" or node.ValueType == "Vector3" or node.ValueType == "Color3")
				if isEditable then
					setEditingNode(node, ind)
				else
					node.Expanded = not node.Expanded
					expandedByPath[node.Path] = node.Expanded
					flattenTree()
					updateExplorerView()
				end
			end
		end)

		clickSys.OnRelease:Connect(function(item, combo, button, position)
			if button == 2 then showExplorerContextMenu(position) end
		end)
	end

	-- Tab 3: Threads Monitor Logic
	local function refreshThreadsList()
		table.clear(threadsList)
		-- Walk the registry / threads list if supported
		local reg = (debug and debug.getregistry) or getreg
		if reg then
			local count = 0
			pcall(function()
				for _, v in next, reg() do
					if typeof(v) == "thread" then
						count = count + 1
						local status = coroutine.status(v)
						local stack = "No call stack available."
						pcall(function()
							stack = debug.traceback(v)
						end)

						threadsList[#threadsList + 1] = {
							Thread = v,
							Name = "Thread #" .. count .. " (" .. tostring(v) .. ")",
							Status = status,
							Stack = stack
						}
					end
				end
			end)
		end

		table.sort(threadsList, function(a, b)
			return a.Status < b.Status
		end)

		threadScroll.TotalSpace = #threadsList
		threadScroll:Update()

		-- render thread frames
		local maxRows = math.max(math.ceil(threadListFrame.AbsoluteSize.Y / 30), 0)
		for i = 1, maxRows do
			local idx = i + threadScroll.Index
			local tData = threadsList[idx]
			local frameName = "ThreadRow_" .. i
			local rowFrame = threadListFrame:FindFirstChild(frameName)
			if not rowFrame then
				rowFrame = createSimple("TextButton", {
					Name = frameName,
					BackgroundColor3 = Settings.Theme.Main1,
					BorderSizePixel = 0,
					Size = UDim2.new(1, 0, 0, 28),
					Position = UDim2.new(0, 0, 0, (i - 1) * 30),
					Font = Enum.Font.Code,
					TextSize = 13,
					TextXAlignment = Enum.TextXAlignment.Left,
					Parent = threadListFrame
				})
				local stroke = createSimple("UIStroke", {
					Color = Settings.Theme.Outline1,
					Thickness = 1,
					Parent = rowFrame
				})
				createSimple("UICorner", {
					CornerRadius = UDim.new(0, 4),
					Parent = rowFrame
				})

				rowFrame.MouseButton1Click:Connect(function()
					local tIdx = i + threadScroll.Index
					local activeT = threadsList[tIdx]
					if activeT then
						selectedThread = activeT
						refreshThreadsList()
					end
				end)
			end

			if tData then
				rowFrame.Text = ("  %s | Status: %s"):format(tData.Name, tData.Status)
				if tData == selectedThread then
					rowFrame.BackgroundColor3 = Settings.Theme.ListSelection
					rowFrame.TextColor3 = Settings.Theme.Highlight
				else
					rowFrame.BackgroundColor3 = Settings.Theme.Main1
					rowFrame.TextColor3 = Settings.Theme.Text
				end
				rowFrame.Visible = true
			else
				rowFrame.Visible = false
			end
		end

		-- update status text / details
		if selectedThread then
			statusText.Text = "Thread Stack: " .. selectedThread.Name
		else
			statusText.Text = ("Scanned %d active threads."):format(#threadsList)
		end
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
	local function selectTab(tabName)
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
			refreshThreadsList()
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
			Size = UDim2.new(1, -6, 0, 20),
			Parent = explorerPage
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 2), Parent = searchFrame})
		local searchStroke = createSimple("UIStroke", {Thickness = 1.4, Color = Settings.Theme.Outline3, Parent = searchFrame})

		searchBox = createSimple("TextBox", {
			BackgroundTransparency = 1,
			ClearTextOnFocus = false,
			Font = Enum.Font.SourceSans,
			PlaceholderColor3 = Settings.Theme.PlaceholderText,
			PlaceholderText = "Search fields / keys...",
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
			Size = UDim2.new(1, 0, 0, 24),
			Parent = threadsPage
		})
		createSimple("TextLabel", {
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSansBold,
			Position = UDim2.new(0, 5, 0, 0),
			Size = UDim2.new(1, -10, 1, 0),
			Text = "Active Coroutine Threads",
			TextColor3 = Settings.Theme.Text,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = threadHeader
		})

		local threadRefreshBtn = createSimple("TextButton", {
			Name = "RefreshThreads",
			BackgroundColor3 = Settings.Theme.Button,
			BorderSizePixel = 0,
			Position = UDim2.new(1, -64, 0, 2),
			Size = UDim2.new(0, 60, 1, -4),
			Font = Enum.Font.SourceSans,
			Text = "Scan GC",
			TextColor3 = Settings.Theme.Text,
			TextSize = 12,
			Parent = threadHeader
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 2), Parent = threadRefreshBtn})
		threadRefreshBtn.MouseButton1Click:Connect(refreshThreadsList)

		threadListFrame = createSimple("Frame", {
			Name = "ThreadList",
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 4, 0, 28),
			Size = UDim2.new(1, -24, 0.45, -28),
			ClipsDescendants = true,
			Parent = threadsPage
		})

		threadScroll = Lib.ScrollBar.new()
		threadScroll.WheelIncrement = 2
		threadScroll.Gui.Position = UDim2.new(1, -16, 0, 28)
		threadScroll.Gui.Size = UDim2.new(0, 16, 0.45, -28)
		threadScroll:SetScrollFrame(threadListFrame)
		threadScroll.Gui.Parent = threadsPage
		threadScroll.Scrolled:Connect(refreshThreadsList)

		-- Details Box for Call Stack
		local stackBox = createSimple("ScrollingFrame", {
			Name = "StackBox",
			BackgroundColor3 = Settings.Theme.TextBox,
			BorderSizePixel = 0,
			Position = UDim2.new(0, 4, 0.45, 4),
			Size = UDim2.new(1, -8, 0.55, -8),
			CanvasSize = UDim2.new(0, 0, 2, 0),
			Parent = threadsPage
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 4), Parent = stackBox})
		createSimple("UIStroke", {Color = Settings.Theme.Outline1, Parent = stackBox})

		local stackText = createSimple("TextLabel", {
			BackgroundTransparency = 1,
			Font = Enum.Font.Code,
			Position = UDim2.new(0, 5, 0, 5),
			Size = UDim2.new(1, -10, 1, -10),
			Text = "Select a thread to view its traceback.",
			TextColor3 = Color3.fromRGB(220, 220, 220),
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Parent = stackBox
		})

		-- page thread click listener updates details text
		threadListFrame.ChildAdded:Connect(function()
			task.spawn(function()
				while threadsPage.Visible do
					if selectedThread then
						stackText.Text = selectedThread.Stack
					end
					task.wait(0.2)
				end
			end)
		end)

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
					refreshThreadsList()
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
