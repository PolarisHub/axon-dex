--[[
	Axon · Modules/FunctionDumper
	Interactive side-panel (VS Code style) listing functions in a script.
	Explore, search, filter, and edit upvalues in real-time.
]]

local oldgame = oldgame or game
local game = workspace.Parent
local cloneref = cloneref

-- Common Locals
local Main, Lib, Apps, Settings -- Main Containers
local Explorer, Properties, ScriptViewer, FunctionDumper -- Major Apps
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
	FunctionDumper = appTable.FunctionDumper
end

local function main()
	local FunctionDumper = {}
	FunctionDumper.GuiElems = {}
	FunctionDumper.Active = false
	FunctionDumper.Index = 0
	FunctionDumper.Query = ""

	-- Layout constants
	local ROW_H = 20
	local INDENT = 17
	local GUIDE = 8
	local ICON_OFF = 18
	local NAME_OFF = 36
	local LINE_COLOR = Color3.fromRGB(72, 72, 72)

	-- State
	local window, toolBar, listFrame, scrollV
	local searchBox, statusLabel
	local clickSys, context
	local listEntries = {}
	local tree = {} -- currently visible flat tree nodes
	local allFunctions = {} -- scanned root function nodes
	local expandedByPath = {} -- persistent expand state by node path
	local selectedNode
	local editingNode
	local editBox
	local scanThread
	local currentScanId = 0
	local targetScript

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
		UDim2 = Color3.fromRGB(156, 220, 254),        -- Light Blue
		UDim = Color3.fromRGB(156, 220, 254),         -- Light Blue
		Vector2 = Color3.fromRGB(156, 220, 254),      -- Light Blue
		BrickColor = Color3.fromRGB(206, 145, 120),   -- Orange
		thread = Color3.fromRGB(120, 120, 120),       -- Gray
	}

	local function getTypeColor(valType)
		return TYPE_COLORS[valType] or Color3.fromRGB(200, 200, 200)
	end

	local function getPath(node)
		local parts = {}
		local curr = node
		while curr do
			table.insert(parts, 1, tostring(curr.Name))
			curr = curr.Parent
		end
		return table.concat(parts, "/")
	end

	local function formatValue(val, valType)
		if valType == "string" then
			return '"' .. tostring(val) .. '"'
		elseif valType == "nil" then
			return "nil"
		elseif valType == "table" then
			return "Table: " .. tostring(val)
		elseif valType == "function" then
			return "Function: " .. tostring(val)
		else
			return tostring(val)
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
			return nil
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

	local function loadNodeChildren(node)
		if node.ChildrenLoaded then return end
		node.ChildrenLoaded = true

		local getupvalues = (debug and debug.getupvalues) or getupvalues or getupvals
		local getconstants = (debug and debug.getconstants) or getconstants or getconsts
		local getinfo = (debug and (debug.getinfo or debug.info)) or getinfo

		if node.Type == "Function" then
			local func = node.Func
			local depth = node.Depth + 1

			-- 1. Upvalues Folder
			local upsList = {}
			local s, upvals = pcall(getupvalues, func)
			if s and upvals and #upvals > 0 then
				local upvaluesFolder = {
					Name = "Upvalues (" .. #upvals .. ")",
					Type = "UpvaluesFolder",
					Depth = depth,
					Expanded = expandedByPath[node.Path .. "/Upvalues"] or false,
					Parent = node,
					Children = {},
					Func = func
				}
				upvaluesFolder.Path = node.Path .. "/Upvalues"

				for idx, val in next, upvals do
					local vType = typeof(val)
					local name = "upval_" .. tostring(idx)
					pcall(function()
						-- retrieve local name if debug.info supports it
						local info = getinfo(func)
					end)
					local upNode = {
						Name = ("[%d] %s"):format(idx, name),
						Type = "Upvalue",
						Depth = depth + 1,
						Expanded = false,
						Parent = upvaluesFolder,
						Children = {},
						Index = idx,
						Value = val,
						ValueType = vType,
						Func = func
					}
					upNode.Path = upvaluesFolder.Path .. "/" .. idx
					upsList[#upsList + 1] = upNode
				end
				upvaluesFolder.Children = upsList
				node.Children[#node.Children + 1] = upvaluesFolder
			end

			-- 2. Constants Folder
			local constsList = {}
			local s2, consts = pcall(getconstants, func)
			if s2 and consts and #consts > 0 then
				local constantsFolder = {
					Name = "Constants (" .. #consts .. ")",
					Type = "ConstantsFolder",
					Depth = depth,
					Expanded = expandedByPath[node.Path .. "/Constants"] or false,
					Parent = node,
					Children = {}
				}
				constantsFolder.Path = node.Path .. "/Constants"

				for idx, val in next, consts do
					local vType = typeof(val)
					local conNode = {
						Name = ("[%d]"):format(idx),
						Type = "Constant",
						Depth = depth + 1,
						Expanded = false,
						Parent = constantsFolder,
						Children = {},
						Index = idx,
						Value = val,
						ValueType = vType
					}
					conNode.Path = constantsFolder.Path .. "/" .. idx
					constsList[#constsList + 1] = conNode
				end
				constantsFolder.Children = constsList
				node.Children[#node.Children + 1] = constantsFolder
			end

			-- 3. Metadata Folder
			local metaList = {}
			local s3, info = pcall(getinfo, func)
			if s3 and info then
				local metaFolder = {
					Name = "Metadata",
					Type = "MetadataFolder",
					Depth = depth,
					Expanded = expandedByPath[node.Path .. "/Metadata"] or false,
					Parent = node,
					Children = {}
				}
				metaFolder.Path = node.Path .. "/Metadata"

				local metaKeys = {"name", "source", "short_src", "linedefined", "lastlinedefined", "what", "nups", "numparams", "is_vararg"}
				for _, key in next, metaKeys do
					if info[key] ~= nil then
						local val = info[key]
						local vType = typeof(val)
						local metaNode = {
							Name = key .. ":",
							Type = "Metadata",
							Depth = depth + 1,
							Parent = metaFolder,
							Children = {},
							Value = val,
							ValueType = vType
						}
						metaNode.Path = metaFolder.Path .. "/" .. key
						metaList[#metaList + 1] = metaNode
					end
				end
				metaFolder.Children = metaList
				node.Children[#node.Children + 1] = metaFolder
			end

		elseif node.Type == "Upvalue" or node.Type == "Constant" or node.Type == "TableValue" then
			-- If it's a function, treat it like a function
			if node.ValueType == "function" then
				node.Func = node.Value
				node.Type = "Function"
				node.ChildrenLoaded = false
				loadNodeChildren(node)

			-- If it's a table, expand its key-values
			elseif node.ValueType == "table" then
				local tList = {}
				local depth = node.Depth + 1
				local count = 0
				for k, v in next, node.Value do
					count = count + 1
					if count > 200 then
						-- Avoid freezing on giant tables (e.g. _G / registry)
						tList[#tList + 1] = {
							Name = "... (table too large)",
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
					local tbVal = {
						Name = tostring(k) .. ":",
						Type = "TableValue",
						Depth = depth,
						Expanded = false,
						Parent = node,
						Children = {},
						Value = v,
						ValueType = vType
					}
					tbVal.Path = node.Path .. "/" .. tostring(k)
					tList[#tList + 1] = tbVal
				end
				node.Children = tList
			end
		end
	end

	FunctionDumper.Flatten = function()
		table.clear(tree)

		local lq = FunctionDumper.Query:lower()
		local matchQuery = function(name)
			if lq == "" then return true end
			return string.find(name:lower(), lq, 1, true) ~= nil
		end

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

		for i = 1, #allFunctions do
			local funcNode = allFunctions[i]
			if matchQuery(funcNode.Name) then
				tree[#tree + 1] = funcNode
				addExpanded(funcNode)
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
		statusLabel.Text = ("Scanned: %d functions | Showing: %d items"):format(#allFunctions, #tree)
	end

	FunctionDumper.UpdateView = function()
		local maxNodes = math.max(math.ceil(listFrame.AbsoluteSize.Y / ROW_H), 0)

		scrollV.VisibleSpace = maxNodes
		scrollV.TotalSpace = #tree
		scrollV.Gui.Visible = #tree > maxNodes

		local newSize = UDim2.new(1, scrollV.Gui.Visible and -16 or 0, 1, -27)
		if listFrame.Size ~= newSize then
			listFrame.Size = newSize
		end
		scrollV:Update()
		FunctionDumper.Index = scrollV.Index

		for i = 1, maxNodes do
			if not listEntries[i] then
				listEntries[i] = FunctionDumper.NewEntry(i)
			end
		end
		for i = maxNodes + 1, #listEntries do
			if listEntries[i] then
				listEntries[i].Gui.Visible = false
			end
		end
	end

	local function drawLines(entry, node)
		for _, line in next, entry.Guides do line.Visible = false end
		local depth = node.Depth
		if depth == 0 then return end

		local lineIdx = 1
		local function getLine()
			local line = entry.Guides[lineIdx]
			if not line then
				line = createSimple("Frame", {
					BackgroundColor3 = LINE_COLOR,
					BorderSizePixel = 0,
					Parent = entry.Gui
				})
				entry.Guides[lineIdx] = line
			end
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

	FunctionDumper.NewEntry = function(index)
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
			Size = UDim2.new(0, 10, 0, 10),
			Position = UDim2.new(0, 3, 0, 5),
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

		-- Hover highlight
		entryGui.InputBegan:Connect(function(input)
			local node = tree[index + FunctionDumper.Index]
			if not node or node == selectedNode then return end
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				entry.Highlight.BackgroundColor3 = Settings.Theme.Button
				entry.Highlight.BackgroundTransparency = 0.5
			end
		end)
		entryGui.InputEnded:Connect(function(input)
			local node = tree[index + FunctionDumper.Index]
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				if node ~= selectedNode then entry.Highlight.BackgroundTransparency = 1 end
			end
		end)

		-- Expand / collapse click
		entry.Expand.MouseButton1Click:Connect(function()
			local node = tree[index + FunctionDumper.Index]
			if not node then return end
			node.Expanded = not node.Expanded
			expandedByPath[node.Path] = node.Expanded
			FunctionDumper.Flatten()
			FunctionDumper.UpdateView()
			FunctionDumper.Refresh()
		end)

		if clickSys then
			clickSys:Add(entryGui)
		end

		entryGui.Parent = listFrame
		return entry
	end

	FunctionDumper.SetSelected = function(node)
		selectedNode = node
		FunctionDumper.Refresh()
	end

	FunctionDumper.SetEditingNode = function(node, idx)
		editingNode = node
		local entry = listEntries[idx]
		if not entry then return end

		editBox.Text = tostring(node.Value)
		local xPos = node.Depth * INDENT + NAME_OFF + 100
		editBox.Position = UDim2.new(0, xPos, 0, entry.Gui.Position.Y.Offset + 2)
		editBox.Size = UDim2.new(1, -xPos - 8, 0, 16)
		editBox.Visible = true
		editBox:CaptureFocus()
	end

	FunctionDumper.Refresh = function()
		local maxNodes = math.max(math.ceil(listFrame.AbsoluteSize.Y / ROW_H), 0)
		local theme = Settings.Theme
		local miscIcons = Main.MiscIcons

		-- Sync editBox visibility
		local editingVisible = false

		for i = 1, maxNodes do
			local entry = listEntries[i]
			if not entry then
				entry = FunctionDumper.NewEntry(i)
				listEntries[i] = entry
				clickSys:Add(entry.Gui)
			end

			local node = tree[i + FunctionDumper.Index]
			if node then
				local depth = node.Depth
				entry.Gui.Visible = true

				-- Layout placements
				entry.Name.Position = UDim2.new(0, depth * INDENT + NAME_OFF, 0, 0)
				entry.Name.Text = node.Name

				-- Format type indicators
				if node.Type == "Function" then
					entry.Name.TextColor3 = theme.Text
					entry.Name.Size = UDim2.new(1, -(depth * INDENT + NAME_OFF) - 2, 1, 0)
					entry.ValueLabel.Visible = false
				elseif node.Type == "Upvalue" or node.Type == "Constant" or node.Type == "TableValue" or node.Type == "Metadata" then
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
						editBox.Size = UDim2.new(1, -xPos - 8, 0, 16)
						editingVisible = true
					end
				else -- Folder nodes
					entry.Name.TextColor3 = Color3.fromRGB(180, 180, 180)
					entry.Name.Size = UDim2.new(1, -(depth * INDENT + NAME_OFF) - 2, 1, 0)
					entry.ValueLabel.Visible = false
				end

				-- Display proper Icons
				entry.Icon.Position = UDim2.new(0, depth * INDENT + ICON_OFF, 0, 2)
				local iconKey = "Empty"
				if node.Type == "Function" then iconKey = "ViewScript"
				elseif node.Type == "UpvaluesFolder" or node.Type == "ConstantsFolder" or node.Type == "MetadataFolder" then iconKey = "Group"
				elseif node.Type == "Upvalue" then iconKey = "Reference"
				elseif node.Type == "Constant" then iconKey = "SelectChildren"
				elseif node.Type == "Metadata" then iconKey = "ExploreData"
				elseif node.ValueType == "table" then iconKey = "Honey"
				elseif node.ValueType == "function" then iconKey = "CallFunction"
				end
				miscIcons:DisplayByKey(entry.Icon, iconKey)
				entry.Icon.ImageTransparency = (node.Type == "Function" or node.Type == "Upvalue") and 0 or 0.35

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
				local canExpand = false
				if node.Type == "Function" then
					canExpand = true
				elseif node.Type == "UpvaluesFolder" or node.Type == "ConstantsFolder" or node.Type == "MetadataFolder" then
					canExpand = true
				elseif node.ValueType == "table" or node.ValueType == "function" then
					canExpand = true
				end

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

		for i = maxNodes + 1, #listEntries do
			if listEntries[i] then
				listEntries[i].Gui.Visible = false
			end
		end

		editBox.Visible = editingVisible
	end

	FunctionDumper.ShowContext = function(position)
		if not selectedNode then return end
		context:Clear()

		local isEditable = selectedNode.Type == "Upvalue" and (selectedNode.ValueType == "number" or selectedNode.ValueType == "boolean" or selectedNode.ValueType == "string" or selectedNode.ValueType == "Vector3" or selectedNode.ValueType == "Color3")
		if isEditable then
			context:Add({
				Name = "Edit Upvalue",
				IconMap = Main.MiscIcons,
				Icon = "Rename",
				OnClick = function()
					-- Find index
					local idx = table.find(tree, selectedNode)
					if idx then
						FunctionDumper.SetEditingNode(selectedNode, idx - FunctionDumper.Index)
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
		end

		context:Add({
			Name = "Copy Path",
			IconMap = Main.MiscIcons,
			Icon = "Reference",
			OnClick = function()
				pcall(setclipboard or writeclipboard, selectedNode.Path)
			end
		})

		-- Search parent function to View Script definition
		local fNode = selectedNode
		while fNode and fNode.Type ~= "Function" do
			fNode = fNode.Parent
		end
		if fNode and fNode.Func then
			context:Add({
				Name = "Go to Script",
				IconMap = Main.MiscIcons,
				Icon = "JumpToParent",
				OnClick = function()
					if targetScript then
						ScriptViewer.ViewScript(targetScript)
					end
				end
			})
		end

		local mouse = Main.Mouse
		context:Show(position and position.X or mouse.X, position and position.Y or mouse.Y)
	end

	FunctionDumper.InitClickSystem = function()
		clickSys = Lib.ClickSystem.new()
		clickSys.AllowedButtons = {1, 2}

		clickSys.OnDown:Connect(function(item, combo, button)
			local ind
			for i = 1, #listEntries do if listEntries[i].Gui == item then ind = i break end end
			if not ind then return end
			local node = tree[ind + FunctionDumper.Index]
			if not node then return end

			FunctionDumper.SetSelected(node)

			-- Double click to edit or expand
			if button == 1 and combo == 2 then
				local isEditable = node.Type == "Upvalue" and (node.ValueType == "number" or node.ValueType == "boolean" or node.ValueType == "string" or node.ValueType == "Vector3" or node.ValueType == "Color3")
				if isEditable then
					FunctionDumper.SetEditingNode(node, ind)
				else
					node.Expanded = not node.Expanded
					expandedByPath[node.Path] = node.Expanded
					FunctionDumper.Flatten()
					FunctionDumper.UpdateView()
					FunctionDumper.Refresh()
				end
			end
		end)

		clickSys.OnRelease:Connect(function(item, combo, button, position)
			if button == 2 then FunctionDumper.ShowContext(position) end
		end)
	end

	FunctionDumper.InitSearch = function()
		Lib.ViewportTextBox.convert(searchBox)
		searchBox:GetPropertyChangedSignal("Text"):Connect(function()
			FunctionDumper.Query = searchBox.Text
			FunctionDumper.Flatten()
			FunctionDumper.UpdateView()
			FunctionDumper.Refresh()
		end)

		local stroke = searchBox.Parent:FindFirstChild("UIStroke")
		if stroke then
			searchBox.Focused:Connect(function()
				stroke.Color = Settings.Theme.Highlight
			end)
			searchBox.FocusLost:Connect(function()
				stroke.Color = Settings.Theme.Outline3
			end)
		end
	end

	FunctionDumper.InitEditBox = function()
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
			ZIndex = 3
		})
		
		local stroke = createSimple("UIStroke", {
			Color = Settings.Theme.Highlight,
			Thickness = 1.4,
			Parent = editBox
		})
		
		local corner = createSimple("UICorner", {
			CornerRadius = UDim.new(0, 2),
			Parent = editBox
		})

		editBox.Parent = listFrame

		editBox.FocusLost:Connect(function(enterPressed)
			if not editingNode then return end
			if enterPressed then
				local newValue = parseValue(editBox.Text, editingNode.ValueType)
				if newValue ~= nil then
					local fNode = editingNode
					while fNode and fNode.Type ~= "Function" do
						fNode = fNode.Parent
					end
					if fNode and fNode.Func then
						local success, err = pcall(function()
							debug.setupvalue(fNode.Func, editingNode.Index, newValue)
						end)
						if success then
							editingNode.Value = newValue
						else
							warn("[Axon Dumper] Failed to modify upvalue: " .. tostring(err))
						end
					end
				end
			end
			editBox.Visible = false
			editingNode = nil
			FunctionDumper.Refresh()
		end)

		editBox.Focused:Connect(function()
			editBox.SelectionStart = 1
			editBox.CursorPosition = #editBox.Text + 1
		end)
	end

	FunctionDumper.Dump = function(scr)
		if not scr then return end
		targetScript = scr
		window:SetTitle("Dumped: " .. tostring(scr.Name))
		window:Show({Align = "left", Pos = 1, Size = 0.3})

		if scanThread then
			pcall(coroutine.close, scanThread)
			scanThread = nil
		end

		currentScanId = currentScanId + 1
		local myScanId = currentScanId

		statusLabel.Text = "Scanning GC..."
		table.clear(allFunctions)
		tree = {}
		FunctionDumper.Flatten()
		FunctionDumper.UpdateView()
		FunctionDumper.Refresh()

		scanThread = coroutine.create(function()
			local gc = env.getgc()
			local start = tick()
			local getinfo = (debug and (debug.getinfo or debug.info)) or getinfo

			for i = 1, #gc do
				if myScanId ~= currentScanId then return end

				local val = gc[i]
				if typeof(val) == "function" then
					local s, envTable = pcall(getfenv, val)
					if s and envTable.script == scr then
						local name = "anonymous"
						pcall(function()
							local inf = getinfo(val)
							name = inf.name ~= "" and inf.name or ("anonymous_line_%d"):format(inf.linedefined or 0)
						end)

						local funcNode = {
							Name = name,
							Type = "Function",
							Func = val,
							Depth = 0,
							Expanded = false,
							Children = {},
							ChildrenLoaded = false,
							Parent = nil,
						}
						funcNode.Path = name .. "_" .. tostring(#allFunctions + 1)
						allFunctions[#allFunctions + 1] = funcNode
					end
				end

				if tick() - start > 0.015 then
					statusLabel.Text = ("Scanning GC... %d%%"):format(math.floor((i / #gc) * 100))
					task.wait()
					start = tick()
				end
			end

			table.sort(allFunctions, function(a, b)
				return a.Name:lower() < b.Name:lower()
			end)

			statusLabel.Text = "Scan Complete."
			FunctionDumper.Flatten()
			FunctionDumper.UpdateView()
			FunctionDumper.Refresh()
			scanThread = nil
		end)
		coroutine.resume(scanThread)
	end

	FunctionDumper.Init = function()
		local items = create({
			{1,"Folder",{Name="FunctionDumperItems",}},
			{2,"Frame",{BackgroundColor3=Settings.Theme.Main2,BorderSizePixel=0,Name="ToolBar",Parent={1},Size=UDim2.new(1,0,0,26),}},
			{3,"Frame",{BackgroundColor3=Settings.Theme.TextBox,BorderSizePixel=0,Name="SearchFrame",Parent={2},Position=UDim2.new(0,3,0,3),Size=UDim2.new(1,-6,0,20),}},
			{4,"TextBox",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,ClearTextOnFocus=false,Font=3,Name="SearchBox",Parent={3},PlaceholderColor3=Settings.Theme.PlaceholderText,PlaceholderText="Filter functions...",Position=UDim2.new(0,4,0,0),Size=UDim2.new(1,-8,0,20),Text="",TextColor3=Settings.Theme.Text,TextSize=14,TextXAlignment=0,}},
			{5,"UICorner",{CornerRadius=UDim.new(0,2),Parent={3},}},
			{6,"UIStroke",{Thickness=1.4,Parent={3},Color=Settings.Theme.Outline3}},
			{7,"Frame",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,ClipsDescendants=true,Name="List",Parent={1},Position=UDim2.new(0,0,0,27),Size=UDim2.new(1,0,1,-47),}},
			{8,"Frame",{BackgroundColor3=Settings.Theme.Outline1,BorderSizePixel=0,Name="Line",Parent={2},Position=UDim2.new(0,0,1,-1),Size=UDim2.new(1,0,0,1),}},
			{9,"Frame",{BackgroundColor3=Settings.Theme.Main2,BorderSizePixel=0,Name="StatusBar",Parent={1},Position=UDim2.new(0,0,1,-20),Size=UDim2.new(1,0,0,20),}},
			{10,"TextLabel",{BackgroundTransparency=1,Font=3,Name="StatusText",Parent={9},Position=UDim2.new(0,5,0,0),Size=UDim2.new(1,-10,1,0),Text="No script loaded",TextColor3=Settings.Theme.PlaceholderText,TextSize=12,TextXAlignment=0,}},
			{11,"Frame",{BackgroundColor3=Settings.Theme.Outline1,BorderSizePixel=0,Name="StatusLine",Parent={9},Position=UDim2.new(0,0,0,0),Size=UDim2.new(1,0,0,1),}}
		})

		toolBar = items.ToolBar
		listFrame = items.List
		searchBox = toolBar.SearchFrame.SearchBox
		statusLabel = items.StatusBar.StatusText

		FunctionDumper.GuiElems.ToolBar = toolBar
		FunctionDumper.GuiElems.ListFrame = listFrame

		scrollV = Lib.ScrollBar.new()
		scrollV.WheelIncrement = 3
		scrollV.Gui.Position = UDim2.new(1, -16, 0, 27)
		scrollV.Gui.Size = UDim2.new(0, 16, 1, -47)
		scrollV:SetScrollFrame(listFrame)
		scrollV.Scrolled:Connect(function()
			FunctionDumper.Index = scrollV.Index
			FunctionDumper.Refresh()
		end)

		window = Lib.Window.new()
		window:SetTitle("Function Dumper")
		window:Resize(320, 450)
		FunctionDumper.Window = window

		toolBar.Parent = window.GuiElems.Content
		listFrame.Parent = window.GuiElems.Content
		items.StatusBar.Parent = window.GuiElems.Content
		scrollV.Gui.Parent = window.GuiElems.Content

		-- Window event connections
		window.GuiElems.Main:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if window:IsContentVisible() then
				FunctionDumper.UpdateView()
				FunctionDumper.Refresh()
			end
		end)
		window.OnActivate:Connect(function()
			FunctionDumper.UpdateView()
			FunctionDumper.Refresh()
		end)
		window.OnRestore:Connect(function()
			FunctionDumper.UpdateView()
			FunctionDumper.Refresh()
		end)

		context = Lib.ContextMenu.new()

		FunctionDumper.InitClickSystem()
		FunctionDumper.InitSearch()
		FunctionDumper.InitEditBox()
	end

	return FunctionDumper
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
