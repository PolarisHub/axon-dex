--[[
	Axon · Modules/ScriptTree
	A dedicated tree of every script (LuaSourceContainer) in the game, shown in
	its instance hierarchy with proper connector lines, class icons, a search
	filter and a script-focused right-click menu. Virtualized like the Explorer.
]]

local oldgame = oldgame or game
local game = workspace.Parent
local cloneref = cloneref

-- Common Locals
local Main,Lib,Apps,Settings -- Main Containers
local Explorer, Properties, ScriptViewer, ModelViewer, Notebook -- Major Apps
local API,RMD,env,service,plr,create,createSimple -- Main Locals

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

local function initAfterMain()
	Explorer = Apps.Explorer
	Properties = Apps.Properties
	ScriptViewer = Apps.ScriptViewer
	ModelViewer = Apps.ModelViewer
	Notebook = Apps.Notebook
end

local function main()
	local ScriptTree = {}

	-- Layout constants
	local ROW_H = 20      -- height of each row
	local INDENT = 17     -- horizontal pixels added per depth level
	local GUIDE = 8       -- x of the vertical connector inside an indent cell
	local ICON_OFF = 18   -- icon x offset within a node's own indent cell
	local NAME_OFF = 36   -- name x offset within a node's own indent cell
	local LINE_COLOR = Color3.fromRGB(72, 72, 72)

	-- State
	local toolBar, treeFrame, scrollV
	local searchBox, countLabel
	local context, clickSys
	local listEntries = {}
	local tree = {}            -- flat list of currently-visible nodes
	local nodeMap = {}         -- instance -> node
	local rootNode             -- the game node (depth 0)
	local expandedByObj = setmetatable({}, {__mode = "k"}) -- persists expand state across rebuilds
	local selectedNode
	local refreshDebounce, rebuildDebounce, scanningFlag
	local isa = game.IsA

	ScriptTree.Index = 0
	ScriptTree.Query = ""
	ScriptTree.ScriptCount = 0
	ScriptTree.Active = false
	ScriptTree.GuiElems = {}

	-- Builds nodeMap/rootNode from a fresh scan of every LuaSourceContainer.
	ScriptTree.Build = function()
		local prevObj = selectedNode and selectedNode.Obj
		table.clear(nodeMap)
		rootNode = {Obj = game, Children = {}, IsScript = false, Parent = nil}
		nodeMap[game] = rootNode

		local scripts = {}
		local getChildren = game.GetChildren
		local queue = {game}
		local start = os.clock()

		while #queue > 0 do
			local inst = table.remove(queue)
			local ch = getChildren(inst)
			for i = 1, #ch do
				local c = ch[i]
				if isa(c, "LuaSourceContainer") then scripts[#scripts + 1] = c end
				table.insert(queue, c)
			end
			if os.clock() - start > 0.002 then
				task.wait()
				start = os.clock()
			end
		end

		-- Build the ancestor chain only along paths that contain scripts.
		local function getNode(inst)
			local n = nodeMap[inst]
			if n then return n end
			local par = inst.Parent
			local pnode = (par and getNode(par)) or rootNode
			n = {Obj = inst, Children = {}, IsScript = isa(inst, "LuaSourceContainer"), Parent = pnode}
			nodeMap[inst] = n
			pnode.Children[#pnode.Children + 1] = n
			return n
		end

		start = os.clock()
		for i = 1, #scripts do
			if i % 100 == 0 and os.clock() - start > 0.002 then
				task.wait()
				start = os.clock()
			end
			pcall(getNode, scripts[i])
		end

		-- Assign depth, sort children (containers first then scripts, alpha),
		-- mark IsLast, and restore expand state.
		local function finalize(node, depth)
			node.Depth = depth
			local saved = expandedByObj[node.Obj]
			node.Expanded = (saved == nil) and true or saved

			local ch = node.Children
			table.sort(ch, function(a, b)
				if a.IsScript ~= b.IsScript then return b.IsScript and not a.IsScript end
				return tostring(a.Obj):lower() < tostring(b.Obj):lower()
			end)
			for i = 1, #ch do
				ch[i].IsLast = (i == #ch)
				finalize(ch[i], depth + 1)
			end
		end
		finalize(rootNode, 0)
		rootNode.IsLast = true
		rootNode.Expanded = (expandedByObj[game] == nil) and true or expandedByObj[game]

		-- Re-resolve the selection onto the freshly-built nodes (or drop it if
		-- the selected instance no longer exists).
		selectedNode = (prevObj and nodeMap[prevObj]) or nil

		ScriptTree.ScriptCount = #scripts
		if countLabel then
			countLabel.Text = #scripts .. (#scripts == 1 and " script" or " scripts")
		end
	end

	-- Flattens the node tree into `tree` honoring expansion and the search query.
	ScriptTree.Flatten = function()
		table.clear(tree)
		if not rootNode then return end

		local query = ScriptTree.Query
		local searchSet
		if query and #query > 0 then
			searchSet = {}
			local lq = query:lower()
			local find = string.find
			for _, node in pairs(nodeMap) do
				if node.IsScript and find(tostring(node.Obj):lower(), lq, 1, true) then
					local a = node
					while a and not searchSet[a] do
						searchSet[a] = true
						a = a.Parent
					end
				end
			end
		end

		rootNode.VisibleIsLast = true
		tree[#tree + 1] = rootNode
		local function recur(node)
			if #node.Children == 0 then return end
			local expand = searchSet ~= nil or node.Expanded
			if not expand then return end
			-- find the last child that will actually be emitted (search can hide some)
			local lastEmitted
			for i = 1, #node.Children do
				local c = node.Children[i]
				if not searchSet or searchSet[c] then lastEmitted = c end
			end
			for i = 1, #node.Children do
				local c = node.Children[i]
				if not searchSet or searchSet[c] then
					c.VisibleIsLast = (c == lastEmitted)
					tree[#tree + 1] = c
					recur(c)
				end
			end
		end
		recur(rootNode)
	end

	ScriptTree.UpdateView = function()
		local maxNodes = math.max(math.ceil(treeFrame.AbsoluteSize.Y / ROW_H), 0)

		scrollV.VisibleSpace = maxNodes
		scrollV.TotalSpace = #tree
		scrollV.Gui.Visible = #tree > maxNodes

		local newSize = UDim2.new(1, scrollV.Gui.Visible and -16 or 0, 1, -23)
		if treeFrame.Size ~= newSize then
			treeFrame.Size = newSize
		end
		scrollV:Update()
		ScriptTree.Index = scrollV.Index
	end

	-- Draws the ├ └ │ connector lines for a single row.
	local function drawLines(entry, node)
		local guides = entry.Guides
		for i = 1, #guides do guides[i].Visible = false end
		entry.ElbowV.Visible = false
		entry.ElbowH.Visible = false

		local depth = node.Depth
		if depth < 1 then return end -- root row: no lines

		-- Continuation verticals for ancestors above the parent.
		local guideCount = 0
		local child_a = node
		local a = node.Parent
		while a do
			local d = a.Depth
			if d >= 1 and d <= depth - 2 then
				if not child_a.VisibleIsLast then
					guideCount = guideCount + 1
					local g = guides[guideCount]
					if not g then
						g = Instance.new("Frame")
						g.BorderSizePixel = 0
						g.BackgroundColor3 = LINE_COLOR
						g.ZIndex = 2
						g.Parent = entry.Lines
						guides[guideCount] = g
					end
					g.Position = UDim2.new(0, d * INDENT + GUIDE, 0, 0)
					g.Size = UDim2.new(0, 1, 1, 0)
					g.Visible = true
				end
			end
			child_a = a
			a = a.Parent
		end

		-- Elbow connecting this node to its parent's vertical.
		local px = (depth - 1) * INDENT + GUIDE
		entry.ElbowV.Position = UDim2.new(0, px, 0, 0)
		entry.ElbowV.Size = UDim2.new(0, 1, 0, node.VisibleIsLast and ROW_H / 2 or ROW_H)
		entry.ElbowV.Visible = true

		local endX = (node.IsScript and (depth * INDENT + ICON_OFF) or (depth * INDENT + GUIDE))
		entry.ElbowH.Position = UDim2.new(0, px, 0, ROW_H / 2)
		entry.ElbowH.Size = UDim2.new(0, math.max(0, endX - px), 0, 1)
		entry.ElbowH.Visible = true
	end

	ScriptTree.NewEntry = function(index)
		local entryGui = create({
			{1,"TextButton",{AutoButtonColor=false,BackgroundColor3=Color3.new(0,0,0),BackgroundTransparency=1,BorderSizePixel=0,Font=3,Name="Entry",Size=UDim2.new(1,0,0,ROW_H),Text="",TextSize=14,}},
			{2,"Frame",{BackgroundColor3=Color3.new(0.04313725605607,0.35294118523598,0.68627452850342),BackgroundTransparency=1,BorderSizePixel=0,Name="Highlight",Parent={1},Size=UDim2.new(1,0,1,0),}},
			{3,"Frame",{BackgroundTransparency=1,Name="Lines",Parent={1},Size=UDim2.new(1,0,1,0),}},
			{4,"TextButton",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,ClipsDescendants=true,Font=3,Name="Expand",Parent={1},Size=UDim2.new(0,16,0,16),Position=UDim2.new(0,0,0,2),Text="",TextSize=14,Visible=false,}},
			{5,"ImageLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Image="rbxassetid://5642383285",ImageRectOffset=Vector2.new(144,16),ImageRectSize=Vector2.new(16,16),Name="Icon",Parent={4},ScaleType=4,Size=UDim2.new(0,16,0,16),}},
			{6,"ImageLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,ClipsDescendants=true,Name="Icon",Parent={1},Position=UDim2.new(0,18,0,2),ScaleType=4,Size=UDim2.new(0,16,0,16),}},
			{7,"TextLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Font=3,Name="EntryName",Parent={1},Position=UDim2.new(0,36,0,0),Size=UDim2.new(1,-36,1,0),Text="",TextColor3=Color3.new(0.86274516582489,0.86274516582489,0.86274516582489),TextSize=14,TextTruncate=2,TextXAlignment=0,}},
		})
		entryGui.Highlight.ZIndex = 1
		entryGui.Lines.ZIndex = 1

		local elbowV = Instance.new("Frame")
		elbowV.BorderSizePixel = 0
		elbowV.BackgroundColor3 = LINE_COLOR
		elbowV.ZIndex = 2
		elbowV.Visible = false
		elbowV.Parent = entryGui.Lines

		local elbowH = elbowV:Clone()
		elbowH.Parent = entryGui.Lines

		local entry = {
			Gui = entryGui,
			Highlight = entryGui.Highlight,
			Lines = entryGui.Lines,
			Expand = entryGui.Expand,
			Icon = entryGui.Icon,
			Name = entryGui.EntryName,
			ElbowV = elbowV,
			ElbowH = elbowH,
			Guides = {},
		}

		entryGui.Position = UDim2.new(0, 0, 0, ROW_H * (index - 1))

		-- Hover highlight
		entryGui.InputBegan:Connect(function(input)
			local node = tree[index + ScriptTree.Index]
			if not node or node == selectedNode then return end
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				entry.Highlight.BackgroundColor3 = Settings.Theme.Button
				entry.Highlight.BackgroundTransparency = 0
			end
		end)
		entryGui.InputEnded:Connect(function(input)
			local node = tree[index + ScriptTree.Index]
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				if node ~= selectedNode then entry.Highlight.BackgroundTransparency = 1 end
			end
		end)

		-- Expand / collapse
		entry.Expand.MouseButton1Click:Connect(function()
			local node = tree[index + ScriptTree.Index]
			if not node or #node.Children == 0 then return end
			node.Expanded = not node.Expanded
			expandedByObj[node.Obj] = node.Expanded
			ScriptTree.Flatten()
			ScriptTree.UpdateView()
			ScriptTree.Refresh()
		end)

		entryGui.Parent = treeFrame
		return entry
	end

	ScriptTree.SetSelected = function(node)
		selectedNode = node
		ScriptTree.Refresh()
		if node and node.Obj and Explorer and Explorer.Selection and nodes then
			local expNode = nodes[node.Obj]
			if expNode then
				Explorer.Selection:Set(expNode)
			end
		end
	end

	ScriptTree.Refresh = function()
		local maxNodes = math.max(math.ceil(treeFrame.AbsoluteSize.Y / ROW_H), 0)
		local theme = Settings.Theme
		local miscIcons = Main.MiscIcons

		for i = 1, maxNodes do
			local entry = listEntries[i]
			if not entry then
				entry = ScriptTree.NewEntry(i)
				listEntries[i] = entry
				clickSys:Add(entry.Gui)
			end

			local node = tree[i + ScriptTree.Index]
			if node then
				local obj = node.Obj
				local depth = node.Depth

				entry.Gui.Visible = true
				entry.Name.Position = UDim2.new(0, depth * INDENT + NAME_OFF, 0, 0)
				entry.Name.Size = UDim2.new(1, -(depth * INDENT + NAME_OFF) - 2, 1, 0)
				entry.Name.Text = tostring(obj)
				-- scripts pop, containers are dimmed
				entry.Name.TextColor3 = node.IsScript and theme.Text or Color3.fromRGB(150, 150, 150)
				entry.Name.TextTransparency = node.IsScript and 0 or 0.15

				-- icon
				entry.Icon.Position = UDim2.new(0, depth * INDENT + ICON_OFF, 0, 2)
				pcall(function()
					(Explorer.MiscIcons or miscIcons):DisplayExplorerIcons(entry.Icon, obj.ClassName)
				end)
				entry.Icon.ImageTransparency = node.IsScript and 0 or 0.35

				-- connector lines
				drawLines(entry, node)

				-- selection / hover highlight
				if node == selectedNode then
					entry.Highlight.BackgroundColor3 = theme.ListSelection
					entry.Highlight.BackgroundTransparency = 0
				elseif Lib.CheckMouseInGui(entry.Gui) then
					entry.Highlight.BackgroundColor3 = theme.Button
					entry.Highlight.BackgroundTransparency = 0
				else
					entry.Highlight.BackgroundTransparency = 1
				end

				-- expand arrow
				if #node.Children > 0 then
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
			clickSys:Remove(listEntries[i].Gui)
			listEntries[i].Gui:Destroy()
			listEntries[i] = nil
		end
	end

	ScriptTree.Rebuild = function()
		if scanningFlag then return end
		scanningFlag = true
		if countLabel then countLabel.Text = "Scanning..." end
		coroutine.wrap(function()
			ScriptTree.Build()
			ScriptTree.Flatten()
			ScriptTree.UpdateView()
			ScriptTree.Refresh()
			scanningFlag = false
		end)()
	end

	ScriptTree.PerformRebuild = function()
		if rebuildDebounce then return end
		rebuildDebounce = true
		Lib.FastWait(0.3)
		rebuildDebounce = false
		if ScriptTree.Active then ScriptTree.Rebuild() end
	end

	-- Expand / collapse an entire subtree
	local function setExpandedRecursive(node, val)
		expandedByObj[node.Obj] = val
		node.Expanded = val
		for i = 1, #node.Children do
			if #node.Children[i].Children > 0 then
				setExpandedRecursive(node.Children[i], val)
			end
		end
	end

	local function selectInExplorer(obj)
		local node = nodes and nodes[obj]
		if node and Explorer and Explorer.Selection then
			Explorer.Selection:Set(node)
			Explorer.ViewNode(node)
			Explorer.Window:Show()
		end
	end

	ScriptTree.InitContext = function()
		context = Lib.ContextMenu.new()

		context:Register("VIEW", {Name = "View Script", IconMap = Main.MiscIcons, Icon = "ViewScript", DisabledIcon = "Empty", OnClick = function()
			if selectedNode and selectedNode.IsScript then ScriptViewer.ViewScript(selectedNode.Obj) end
		end})
		context:Register("COPY_SOURCE", {Name = "Copy Source", IconMap = Main.MiscIcons, Icon = "Copy", DisabledIcon = "Copy_Disabled", OnClick = function()
			if not selectedNode or not selectedNode.IsScript then return end
			local s, src = pcall(env.decompile, selectedNode.Obj)
			if s and src then env.setclipboard(src) end
		end})
		context:Register("SAVE_SCRIPT", {Name = "Save Script", IconMap = Main.MiscIcons, Icon = "Save", DisabledIcon = "Empty", OnClick = function()
			local obj = selectedNode and selectedNode.Obj
			if not obj then return end
			local s, src = pcall(env.decompile, obj)
			if not s or not src then src = "-- Axon: failed to decompile "..obj.ClassName end
			local fileName = ("%s_%s_%i_Source.txt"):format(env.parsefile(obj.Name), obj.ClassName, game.PlaceId)
			Lib.SaveAsPrompt(fileName, src)
		end})
		context:Register("SAVE_BYTECODE", {Name = "Save Bytecode", IconMap = Main.MiscIcons, Icon = "Save", DisabledIcon = "Empty", OnClick = function()
			local obj = selectedNode and selectedNode.Obj
			if not obj then return end
			local s, bc = pcall(env.getscriptbytecode, obj)
			if s and type(bc) == "string" then
				local fileName = ("%s_%s_%i_Bytecode.txt"):format(env.parsefile(obj.Name), obj.ClassName, game.PlaceId)
				Lib.SaveAsPrompt(fileName, bc)
			end
		end})
		context:Register("DUMP", {Name = "Dump Functions", IconMap = Main.MiscIcons, Icon = "SelectChildren", DisabledIcon = "Empty", OnClick = function()
			if selectedNode and selectedNode.IsScript then ScriptViewer.DumpFunctions(selectedNode.Obj) end
		end})

		context:Register("COPY_PATH", {Name = "Copy Path", IconMap = Main.MiscIcons, Icon = "Reference", OnClick = function()
			if selectedNode then env.setclipboard(Explorer.GetInstancePath(selectedNode.Obj)) end
		end})
		context:Register("SELECT_EXPLORER", {Name = "Select in Explorer", IconMap = Main.MiscIcons, Icon = "JumpToParent", OnClick = function()
			if selectedNode then selectInExplorer(selectedNode.Obj) end
		end})

		context:Register("EXPAND_ALL", {Name = "Expand All", OnClick = function()
			if selectedNode then setExpandedRecursive(selectedNode, true) ScriptTree.Flatten() ScriptTree.UpdateView() ScriptTree.Refresh() end
		end})
		context:Register("COLLAPSE_ALL", {Name = "Collapse All", OnClick = function()
			if selectedNode then setExpandedRecursive(selectedNode, false) ScriptTree.Flatten() ScriptTree.UpdateView() ScriptTree.Refresh() end
		end})
		context:Register("REFRESH", {Name = "Refresh", IconMap = Main.MiscIcons, Icon = "Reference", OnClick = function()
			ScriptTree.Rebuild()
		end})
	end

	ScriptTree.ShowContext = function(pos)
		-- a stale selection (e.g. instance destroyed since last build) is treated as none
		if not selectedNode or nodeMap[selectedNode.Obj] ~= selectedNode then selectedNode = nil return end
		local node = selectedNode
		context:Clear()

		if node.IsScript then
			local okCap, canDecompile = pcall(function() return env.isViableDecompileScript(node.Obj) and env.isdecompile() end)
			if not okCap then canDecompile = false end
			context:AddRegistered("VIEW", not canDecompile)
			context:AddRegistered("COPY_SOURCE", not canDecompile or env.setclipboard == nil)
			context:AddRegistered("SAVE_SCRIPT", not canDecompile or env.writefile == nil)
			context:AddRegistered("SAVE_BYTECODE", env.getscriptbytecode == nil or env.writefile == nil)
			context:AddRegistered("DUMP", not canDecompile or env.getgc == nil)
			context:AddDivider()
			context:AddRegistered("COPY_PATH", env.setclipboard == nil)
			context:AddRegistered("SELECT_EXPLORER")
		else
			context:AddRegistered("EXPAND_ALL")
			context:AddRegistered("COLLAPSE_ALL")
			context:AddDivider()
			context:AddRegistered("COPY_PATH", env.setclipboard == nil)
			context:AddRegistered("SELECT_EXPLORER")
		end

		context:AddDivider()
		context:AddRegistered("REFRESH")

		local mouse = Main.Mouse
		context:Show(pos and pos.X or mouse.X, pos and pos.Y or mouse.Y)
	end

	ScriptTree.InitClickSystem = function()
		clickSys = Lib.ClickSystem.new()
		clickSys.AllowedButtons = {1, 2}

		clickSys.OnDown:Connect(function(item, combo, button)
			local ind
			for i = 1, #listEntries do if listEntries[i].Gui == item then ind = i break end end
			if not ind then return end
			local node = tree[ind + ScriptTree.Index]
			if not node then return end

			ScriptTree.SetSelected(node)

			if button == 1 and combo == 2 then
				if node.IsScript then
					ScriptViewer.ViewScript(node.Obj)
				elseif #node.Children > 0 then
					node.Expanded = not node.Expanded
					expandedByObj[node.Obj] = node.Expanded
					ScriptTree.Flatten()
					ScriptTree.UpdateView()
					ScriptTree.Refresh()
				end
			end
		end)

		clickSys.OnRelease:Connect(function(item, combo, button, position)
			if button == 2 then ScriptTree.ShowContext(position) end
		end)
	end

	ScriptTree.InitSearch = function()
		Lib.ViewportTextBox.convert(searchBox)
		searchBox:GetPropertyChangedSignal("Text"):Connect(function()
			ScriptTree.Query = searchBox.Text
			ScriptTree.Flatten()
			ScriptTree.UpdateView()
			ScriptTree.Refresh()
		end)
	end

	ScriptTree.SetupConnections = function()
		local function onAdded(obj)
			if isa(obj, "LuaSourceContainer") and ScriptTree.Active then
				coroutine.wrap(ScriptTree.PerformRebuild)()
			end
		end
		local function onRemoving(obj)
			if isa(obj, "LuaSourceContainer") and nodeMap[obj] and ScriptTree.Active then
				coroutine.wrap(ScriptTree.PerformRebuild)()
			end
		end
		game.DescendantAdded:Connect(function(o) pcall(onAdded, o) end)
		game.DescendantRemoving:Connect(function(o) pcall(onRemoving, o) end)
	end

	ScriptTree.Init = function()
		local items = create({
			{1,"Folder",{Name="ScriptTreeItems",}},
			{2,"Frame",{BackgroundColor3=Color3.new(0.20392157137394,0.20392157137394,0.20392157137394),BorderSizePixel=0,Name="ToolBar",Parent={1},Size=UDim2.new(1,0,0,22),}},
			{3,"Frame",{BackgroundColor3=Color3.new(0.14901961386204,0.14901961386204,0.14901961386204),BorderColor3=Color3.new(0.1176470592618,0.1176470592618,0.1176470592618),BorderSizePixel=0,Name="SearchFrame",Parent={2},Position=UDim2.new(0,3,0,1),Size=UDim2.new(1,-95,0,18),}},
			{4,"TextBox",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,ClearTextOnFocus=false,Font=3,Name="SearchBox",Parent={3},PlaceholderColor3=Color3.new(0.39215689897537,0.39215689897537,0.39215689897537),PlaceholderText="Search scripts",Position=UDim2.new(0,4,0,0),Size=UDim2.new(1,-8,0,18),Text="",TextColor3=Color3.new(1,1,1),TextSize=14,TextXAlignment=0,}},
			{5,"UICorner",{CornerRadius=UDim.new(0,2),Parent={3},}},
			{6,"UIStroke",{Thickness=1.4,Parent={3},Color=Color3.fromRGB(42,42,42)}},
			{7,"TextLabel",{BackgroundTransparency=1,Font=3,Name="Count",Parent={2},Position=UDim2.new(1,-90,0,1),Size=UDim2.new(0,64,0,18),Text="0 scripts",TextColor3=Color3.new(0.6,0.6,0.6),TextSize=13,TextXAlignment=1,}},
			{8,"TextButton",{AutoButtonColor=false,BackgroundColor3=Color3.new(0.20392157137394,0.20392157137394,0.20392157137394),BorderSizePixel=0,Font=3,Name="Refresh",Parent={2},Position=UDim2.new(1,-20,0,1),Size=UDim2.new(0,18,0,18),Text="",TextColor3=Color3.new(1,1,1),TextSize=14,}},
			{9,"ImageLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Image="rbxassetid://5642310344",Parent={8},Position=UDim2.new(0,3,0,3),Size=UDim2.new(0,12,0,12),}},
			{10,"Frame",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,ClipsDescendants=true,Name="List",Parent={1},Position=UDim2.new(0,0,0,23),Size=UDim2.new(1,0,1,-23),}},
		})

		toolBar = items.ToolBar
		treeFrame = items.List
		searchBox = toolBar.SearchFrame.SearchBox
		countLabel = toolBar.Count
		ScriptTree.GuiElems.ToolBar = toolBar
		ScriptTree.GuiElems.TreeFrame = treeFrame

		scrollV = Lib.ScrollBar.new()
		scrollV.WheelIncrement = 3
		scrollV.Gui.Position = UDim2.new(1, -16, 0, 23)
		scrollV.Gui.Size = UDim2.new(0, 16, 1, -23)
		scrollV:SetScrollFrame(treeFrame)
		scrollV.Scrolled:Connect(function()
			ScriptTree.Index = scrollV.Index
			ScriptTree.Refresh()
		end)

		-- Hosted as a tab inside the Explorer window instead of its own window.
		local page = createSimple("Frame", {Name = "ScriptTreePage", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, 0)})
		ScriptTree.Page = page
		ScriptTree.Window = Explorer.Window
		toolBar.Parent = page
		treeFrame.Parent = page
		scrollV.Gui.Parent = page

		toolBar.Refresh.MouseButton1Click:Connect(function() ScriptTree.Rebuild() end)

		ScriptTree.InitClickSystem()
		ScriptTree.InitContext()
		ScriptTree.InitSearch()
		ScriptTree.SetupConnections()

		Explorer.AddTab("Script Tree", page, {
			OnShow = function() ScriptTree.Active = true ScriptTree.Rebuild() end,
			OnHide = function() ScriptTree.Active = false end,
			OnResize = function() if ScriptTree.Active then ScriptTree.UpdateView() ScriptTree.Refresh() end end,
		})

		-- Initial build (so it's populated the first time the tab is opened)
		ScriptTree.Build()
		ScriptTree.Flatten()
	end

	return ScriptTree
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
