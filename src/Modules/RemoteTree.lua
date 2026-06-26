--[[
	Axon · Modules/RemoteTree
	A dedicated tree of every remote instance (RemoteEvent, RemoteFunction, BindableEvent, BindableFunction, UnreliableRemoteEvent)
	in the game, shown in its instance hierarchy. Virtualized like the Explorer and ScriptTree.
]]

local oldgame = oldgame or game
local game = workspace.Parent
local cloneref = cloneref

-- Common Locals
local Main,Lib,Apps,Settings -- Main Containers
local Explorer, Properties, ScriptViewer, ModelViewer, Notebook, RemoteTree -- Major Apps
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

local function initAfterMain(appTable)
	Explorer = appTable.Explorer
	Properties = appTable.Properties
	ScriptViewer = appTable.ScriptViewer
	ModelViewer = appTable.ModelViewer
	Notebook = appTable.Notebook
	RemoteTree = appTable.RemoteTree
end

local function main()
	local RemoteTree = {}

	-- Layout constants
	local ROW_H = 20
	local INDENT = 17
	local GUIDE = 8
	local ICON_OFF = 18
	local NAME_OFF = 36
	local LINE_COLOR = Color3.fromRGB(72, 72, 72)

	-- State
	local toolBar, treeFrame, scrollV
	local searchBox, countLabel
	local context, clickSys
	local listEntries = {}
	local tree = {}
	local nodeMap = {}
	local rootNode
	local expandedByObj = setmetatable({}, {__mode = "k"})
	local selectedNode
	local refreshDebounce, rebuildDebounce, scanningFlag
	local isa = game.IsA

	RemoteTree.Index = 0
	RemoteTree.Query = ""
	RemoteTree.RemoteCount = 0
	RemoteTree.Active = false
	RemoteTree.GuiElems = {}

	local ClassFire = {
		RemoteEvent = "FireServer",
		RemoteFunction = "InvokeServer",
		UnreliableRemoteEvent = "FireServer",
		BindableEvent = "Fire",
		BindableFunction = "Invoke",
	}

	getgenv().AxonRemoteBlocklist = getgenv().AxonRemoteBlocklist or {}
	local remote_blocklist = getgenv().AxonRemoteBlocklist

	local function isRemote(inst)
		return isa(inst, "RemoteEvent") or isa(inst, "RemoteFunction") or isa(inst, "BindableEvent") or isa(inst, "BindableFunction") or isa(inst, "UnreliableRemoteEvent")
	end

	RemoteTree.Build = function()
		local prevObj = selectedNode and selectedNode.Obj
		table.clear(nodeMap)
		rootNode = {Obj = game, Children = {}, IsRemote = false, Parent = nil}
		nodeMap[game] = rootNode

		local remotes = {}
		local getChildren = game.GetChildren
		local queue = {game}
		local start = os.clock()

		while #queue > 0 do
			local inst = table.remove(queue)
			local ch = getChildren(inst)
			for i = 1, #ch do
				local c = ch[i]
				if isRemote(c) then remotes[#remotes + 1] = c end
				table.insert(queue, c)
			end
			if os.clock() - start > 0.002 then
				task.wait()
				start = os.clock()
			end
		end

		local function getNode(inst)
			local n = nodeMap[inst]
			if n then return n end
			local par = inst.Parent
			local pnode = (par and getNode(par)) or rootNode
			n = {Obj = inst, Children = {}, IsRemote = isRemote(inst), Parent = pnode}
			nodeMap[inst] = n
			pnode.Children[#pnode.Children + 1] = n
			return n
		end

		start = os.clock()
		for i = 1, #remotes do
			if i % 100 == 0 and os.clock() - start > 0.002 then
				task.wait()
				start = os.clock()
			end
			pcall(getNode, remotes[i])
		end

		local function finalize(node, depth)
			node.Depth = depth
			local saved = expandedByObj[node.Obj]
			node.Expanded = (saved == nil) and true or saved

			local ch = node.Children
			table.sort(ch, function(a, b)
				if a.IsRemote ~= b.IsRemote then return b.IsRemote and not a.IsRemote end
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

		selectedNode = (prevObj and nodeMap[prevObj]) or nil

		RemoteTree.RemoteCount = #remotes
		if countLabel then
			countLabel.Text = #remotes .. (#remotes == 1 and " remote" or " remotes")
		end
	end

	RemoteTree.Flatten = function()
		table.clear(tree)
		if not rootNode then return end

		local query = RemoteTree.Query
		local searchSet
		if query and #query > 0 then
			searchSet = {}
			local lq = query:lower()
			local find = string.find
			for _, node in pairs(nodeMap) do
				if node.IsRemote and find(tostring(node.Obj):lower(), lq, 1, true) then
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

	RemoteTree.UpdateView = function()
		local maxNodes = math.max(math.ceil(treeFrame.AbsoluteSize.Y / ROW_H), 0)

		scrollV.VisibleSpace = maxNodes
		scrollV.TotalSpace = #tree
		scrollV.Gui.Visible = #tree > maxNodes

		local newSize = UDim2.new(1, scrollV.Gui.Visible and -16 or 0, 1, -23)
		if treeFrame.Size ~= newSize then
			treeFrame.Size = newSize
		end
		scrollV:Update()
		RemoteTree.Index = scrollV.Index
	end

	local function drawLines(entry, node)
		local guides = entry.Guides
		for i = 1, #guides do guides[i].Visible = false end
		entry.ElbowV.Visible = false
		entry.ElbowH.Visible = false

		local depth = node.Depth
		if depth < 1 then return end

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

		local px = (depth - 1) * INDENT + GUIDE
		entry.ElbowV.Position = UDim2.new(0, px, 0, 0)
		entry.ElbowV.Size = UDim2.new(0, 1, 0, node.VisibleIsLast and ROW_H / 2 or ROW_H)
		entry.ElbowV.Visible = true

		local endX = (node.IsRemote and (depth * INDENT + ICON_OFF) or (depth * INDENT + GUIDE))
		entry.ElbowH.Position = UDim2.new(0, px, 0, ROW_H / 2)
		entry.ElbowH.Size = UDim2.new(0, math.max(0, endX - px), 0, 1)
		entry.ElbowH.Visible = true
	end

	RemoteTree.NewEntry = function(index)
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

		entryGui.InputBegan:Connect(function(input)
			local node = tree[index + RemoteTree.Index]
			if not node or node == selectedNode then return end
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				entry.Highlight.BackgroundColor3 = Settings.Theme.Button
				entry.Highlight.BackgroundTransparency = 0
			end
		end)
		entryGui.InputEnded:Connect(function(input)
			local node = tree[index + RemoteTree.Index]
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				if node ~= selectedNode then entry.Highlight.BackgroundTransparency = 1 end
			end
		end)

		entry.Expand.MouseButton1Click:Connect(function()
			local node = tree[index + RemoteTree.Index]
			if not node or #node.Children == 0 then return end
			node.Expanded = not node.Expanded
			expandedByObj[node.Obj] = node.Expanded
			RemoteTree.Flatten()
			RemoteTree.UpdateView()
			RemoteTree.Refresh()
		end)

		entryGui.Parent = treeFrame
		return entry
	end

	RemoteTree.SetSelected = function(node)
		selectedNode = node
		RemoteTree.Refresh()
		if node and node.Obj and Explorer and Explorer.Selection and nodes then
			local expNode = nodes[node.Obj]
			if expNode then
				Explorer.Selection:Set(expNode)
			end
		end
	end

	RemoteTree.Refresh = function()
		local maxNodes = math.max(math.ceil(treeFrame.AbsoluteSize.Y / ROW_H), 0)
		local theme = Settings.Theme
		local miscIcons = Main.MiscIcons

		for i = 1, maxNodes do
			local entry = listEntries[i]
			if not entry then
				entry = RemoteTree.NewEntry(i)
				listEntries[i] = entry
				clickSys:Add(entry.Gui)
			end

			local node = tree[i + RemoteTree.Index]
			if node then
				local obj = node.Obj
				local depth = node.Depth

				entry.Gui.Visible = true
				entry.Name.Position = UDim2.new(0, depth * INDENT + NAME_OFF, 0, 0)
				entry.Name.Size = UDim2.new(1, -(depth * INDENT + NAME_OFF) - 2, 1, 0)
				
				local displayName = tostring(obj)
				if remote_blocklist[obj] then
					displayName = displayName .. " [BLOCKED]"
				end
				entry.Name.Text = displayName
				entry.Name.TextColor3 = node.IsRemote and theme.Text or Color3.fromRGB(150, 150, 150)
				entry.Name.TextTransparency = node.IsRemote and 0 or 0.15

				entry.Icon.Position = UDim2.new(0, depth * INDENT + ICON_OFF, 0, 2)
				pcall(function()
					(Explorer.MiscIcons or miscIcons):DisplayExplorerIcons(entry.Icon, obj.ClassName)
				end)
				entry.Icon.ImageTransparency = node.IsRemote and 0 or 0.35

				drawLines(entry, node)

				if node == selectedNode then
					entry.Highlight.BackgroundColor3 = theme.ListSelection
					entry.Highlight.BackgroundTransparency = 0
				elseif Lib.CheckMouseInGui(entry.Gui) then
					entry.Highlight.BackgroundColor3 = theme.Button
					entry.Highlight.BackgroundTransparency = 0
				else
					entry.Highlight.BackgroundTransparency = 1
				end

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

	RemoteTree.Rebuild = function()
		if scanningFlag then return end
		scanningFlag = true
		if countLabel then countLabel.Text = "Scanning..." end
		coroutine.wrap(function()
			RemoteTree.Build()
			RemoteTree.Flatten()
			RemoteTree.UpdateView()
			RemoteTree.Refresh()
			scanningFlag = false
		end)()
	end

	RemoteTree.PerformRebuild = function()
		if rebuildDebounce then return end
		rebuildDebounce = true
		Lib.FastWait(0.3)
		rebuildDebounce = false
		if RemoteTree.Active then RemoteTree.Rebuild() end
	end

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

	RemoteTree.PromptFire = function(obj)
		local win = RemoteTree.FirePromptWindow
		local isFunction = isa(obj, "RemoteFunction") or isa(obj, "BindableFunction")
		win:SetTitle(isFunction and "Invoke " .. obj.Name or "Fire " .. obj.Name)
		win.Elements.ErrorLabel.Text = ""
		win.Elements.InputBox.TextBox.Text = ""
		
		win.Elements.FireButton.Text = isFunction and "Invoke" or "Fire"

		if RemoteTree.FireConn then RemoteTree.FireConn:Disconnect() end
		RemoteTree.FireConn = win.Elements.FireButton.OnClick:Connect(function()
			local expr = win.Elements.InputBox.TextBox.Text
			local func, err = env.loadstring("return " .. expr)
			if not func then
				win.Elements.ErrorLabel.Text = "Compile error: " .. tostring(err)
				return
			end
			local results = {pcall(func)}
			if not results[1] then
				win.Elements.ErrorLabel.Text = "Execution error: " .. tostring(results[2])
				return
			end
			table.remove(results, 1)

			local method = ClassFire[obj.ClassName]
			local s, runErr = pcall(function()
				if isFunction then
					local returnVals = {obj[method](obj, unpack(results))}
					print("[RemoteTree] Invoked " .. obj:GetFullName() .. " returned: ", unpack(returnVals))
				else
					obj[method](obj, unpack(results))
					print("[RemoteTree] Fired " .. obj:GetFullName())
				end
			end)
			if not s then
				win.Elements.ErrorLabel.Text = "Invoke/Fire error: " .. tostring(runErr)
			else
				win:Close()
			end
		end)

		win:Show()
	end

	RemoteTree.InitContext = function()
		context = Lib.ContextMenu.new()

		context:Register("FIRE_REMOTE", {Name = "Fire/Invoke Remote", IconMap = Main.MiscIcons, Icon = "CallRemote", OnClick = function()
			if selectedNode and selectedNode.IsRemote then
				RemoteTree.PromptFire(selectedNode.Obj)
			end
		end})

		context:Register("BLOCK_REMOTE", {Name = "Block From Firing", IconMap = Main.MiscIcons, Icon = "Delete", OnClick = function()
			if not selectedNode or not selectedNode.IsRemote then return end
			local obj = selectedNode.Obj
			if not remote_blocklist[obj] then
				local functionToHook = ClassFire[obj.ClassName]
				remote_blocklist[obj] = true
				local old; old = env.hookmetamethod((oldgame or game), "__namecall", function(self, ...)
					if remote_blocklist[obj] and self == obj and getnamecallmethod() == functionToHook then
						return nil
					end
					return old(self,...)
				end)
				if Settings.RemoteBlockWriteAttribute then
					obj:SetAttribute("IsBlocked", true)
				end
				print("[RemoteTree] Blocked Remote: " .. obj:GetFullName())
				RemoteTree.Refresh()
			end
		end})

		context:Register("UNBLOCK_REMOTE", {Name = "Unblock", IconMap = Main.MiscIcons, Icon = "Play", OnClick = function()
			if not selectedNode or not selectedNode.IsRemote then return end
			local obj = selectedNode.Obj
			if remote_blocklist[obj] then
				remote_blocklist[obj] = nil
				if Settings.RemoteBlockWriteAttribute then
					obj:SetAttribute("IsBlocked", false)
				end
				print("[RemoteTree] Unblocked Remote: " .. obj:GetFullName())
				RemoteTree.Refresh()
			end
		end})

		context:Register("COPY_PATH", {Name = "Copy Path", IconMap = Main.MiscIcons, Icon = "Reference", OnClick = function()
			if selectedNode then env.setclipboard(Explorer.GetInstancePath(selectedNode.Obj)) end
		end})
		context:Register("SELECT_EXPLORER", {Name = "Select in Explorer", IconMap = Main.MiscIcons, Icon = "JumpToParent", OnClick = function()
			if selectedNode then selectInExplorer(selectedNode.Obj) end
		end})

		context:Register("EXPAND_ALL", {Name = "Expand All", OnClick = function()
			if selectedNode then setExpandedRecursive(selectedNode, true) RemoteTree.Flatten() RemoteTree.UpdateView() RemoteTree.Refresh() end
		end})
		context:Register("COLLAPSE_ALL", {Name = "Collapse All", OnClick = function()
			if selectedNode then setExpandedRecursive(selectedNode, false) RemoteTree.Flatten() RemoteTree.UpdateView() RemoteTree.Refresh() end
		end})
		context:Register("REFRESH", {Name = "Refresh", IconMap = Main.MiscIcons, Icon = "Reference", OnClick = function()
			RemoteTree.Rebuild()
		end})
	end

	RemoteTree.ShowContext = function(pos)
		if not selectedNode or nodeMap[selectedNode.Obj] ~= selectedNode then selectedNode = nil return end
		local node = selectedNode
		context:Clear()

		if node.IsRemote then
			context:AddRegistered("FIRE_REMOTE")
			if remote_blocklist[node.Obj] then
				context:AddRegistered("UNBLOCK_REMOTE")
			else
				context:AddRegistered("BLOCK_REMOTE")
			end
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

	RemoteTree.InitClickSystem = function()
		clickSys = Lib.ClickSystem.new()
		clickSys.AllowedButtons = {1, 2}

		clickSys.OnDown:Connect(function(item, combo, button)
			local ind
			for i = 1, #listEntries do if listEntries[i].Gui == item then ind = i break end end
			if not ind then return end
			local node = tree[ind + RemoteTree.Index]
			if not node then return end

			RemoteTree.SetSelected(node)

			if button == 1 and combo == 2 then
				if node.IsRemote then
					RemoteTree.PromptFire(node.Obj)
				elseif #node.Children > 0 then
					node.Expanded = not node.Expanded
					expandedByObj[node.Obj] = node.Expanded
					RemoteTree.Flatten()
					RemoteTree.UpdateView()
					RemoteTree.Refresh()
				end
			end
		end)

		clickSys.OnRelease:Connect(function(item, combo, button, position)
			if button == 2 then RemoteTree.ShowContext(position) end
		end)
	end

	RemoteTree.InitSearch = function()
		Lib.ViewportTextBox.convert(searchBox)
		searchBox:GetPropertyChangedSignal("Text"):Connect(function()
			RemoteTree.Query = searchBox.Text
			RemoteTree.Flatten()
			RemoteTree.UpdateView()
			RemoteTree.Refresh()
		end)
	end

	RemoteTree.SetupConnections = function()
		local function onAdded(obj)
			if isRemote(obj) and RemoteTree.Active then
				coroutine.wrap(RemoteTree.PerformRebuild)()
			end
		end
		local function onRemoving(obj)
			if isRemote(obj) and nodeMap[obj] and RemoteTree.Active then
				coroutine.wrap(RemoteTree.PerformRebuild)()
			end
		end
		game.DescendantAdded:Connect(function(o) pcall(onAdded, o) end)
		game.DescendantRemoving:Connect(function(o) pcall(onRemoving, o) end)
	end

	RemoteTree.InitPromptWindow = function()
		local win = Lib.Window.new()
		win.Alignable = false
		win.Resizable = false
		win:SetTitle("Fire/Invoke Remote")
		win:SetSize(320, 115)

		local label = Lib.Label.new()
		label.Text = "Arguments (Luau expression):"
		label.Position = UDim2.new(0, 10, 0, 10)
		label.Size = UDim2.new(1, -20, 0, 20)
		win:Add(label)

		local inputFrame = Lib.ViewportTextBox.new()
		inputFrame.Position = UDim2.new(0, 10, 0, 35)
		inputFrame.Size = UDim2.new(1, -20, 0, 20)
		win:Add(inputFrame, "InputBox")

		local errorLabel = Lib.Label.new()
		errorLabel.Text = ""
		errorLabel.Position = UDim2.new(0, 10, 1, -45)
		errorLabel.Size = UDim2.new(1, -20, 0, 20)
		errorLabel.TextColor3 = Settings.Theme.Important
		win:Add(errorLabel, "ErrorLabel")

		local cancelButton = Lib.Button.new()
		cancelButton.AnchorPoint = Vector2.new(1, 1)
		cancelButton.Text = "Cancel"
		cancelButton.Position = UDim2.new(0.5, -5, 1, -5)
		cancelButton.Size = UDim2.new(0.5, -10, 0, 20)
		cancelButton.OnClick:Connect(function() win:Close() end)
		win:Add(cancelButton)

		local fireButton = Lib.Button.new()
		fireButton.AnchorPoint = Vector2.new(0, 1)
		fireButton.Text = "Fire"
		fireButton.Position = UDim2.new(0.5, 5, 1, -5)
		fireButton.Size = UDim2.new(0.5, -10, 0, 20)
		win:Add(fireButton, "FireButton")

		RemoteTree.FirePromptWindow = win
	end

	RemoteTree.Init = function()
		local items = create({
			{1,"Folder",{Name="RemoteTreeItems",}},
			{2,"Frame",{BackgroundColor3=Color3.new(0.20392157137394,0.20392157137394,0.20392157137394),BorderSizePixel=0,Name="ToolBar",Parent={1},Size=UDim2.new(1,0,0,22),}},
			{3,"Frame",{BackgroundColor3=Color3.new(0.14901961386204,0.14901961386204,0.14901961386204),BorderColor3=Color3.new(0.1176470592618,0.1176470592618,0.1176470592618),BorderSizePixel=0,Name="SearchFrame",Parent={2},Position=UDim2.new(0,3,0,1),Size=UDim2.new(1,-95,0,18),}},
			{4,"TextBox",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,ClearTextOnFocus=false,Font=3,Name="SearchBox",Parent={3},PlaceholderColor3=Color3.new(0.39215689897537,0.39215689897537,0.39215689897537),PlaceholderText="Search remotes",Position=UDim2.new(0,4,0,0),Size=UDim2.new(1,-8,0,18),Text="",TextColor3=Color3.new(1,1,1),TextSize=14,TextXAlignment=0,}},
			{5,"UICorner",{CornerRadius=UDim.new(0,2),Parent={3},}},
			{6,"UIStroke",{Thickness=1.4,Parent={3},Color=Color3.fromRGB(42,42,42)}},
			{7,"TextLabel",{BackgroundTransparency=1,Font=3,Name="Count",Parent={2},Position=UDim2.new(1,-90,0,1),Size=UDim2.new(0,64,0,18),Text="0 remotes",TextColor3=Color3.new(0.6,0.6,0.6),TextSize=13,TextXAlignment=1,}},
			{8,"TextButton",{AutoButtonColor=false,BackgroundColor3=Color3.new(0.20392157137394,0.20392157137394,0.20392157137394),BorderSizePixel=0,Font=3,Name="Refresh",Parent={2},Position=UDim2.new(1,-20,0,1),Size=UDim2.new(0,18,0,18),Text="",TextColor3=Color3.new(1,1,1),TextSize=14,}},
			{9,"ImageLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Image="rbxassetid://5642310344",Parent={8},Position=UDim2.new(0,3,0,3),Size=UDim2.new(0,12,0,12),}},
			{10,"Frame",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,ClipsDescendants=true,Name="List",Parent={1},Position=UDim2.new(0,0,0,23),Size=UDim2.new(1,0,1,-23),}},
		})

		toolBar = items.ToolBar
		treeFrame = items.List
		searchBox = toolBar.SearchFrame.SearchBox
		countLabel = toolBar.Count
		RemoteTree.GuiElems.ToolBar = toolBar
		RemoteTree.GuiElems.TreeFrame = treeFrame

		scrollV = Lib.ScrollBar.new()
		scrollV.WheelIncrement = 3
		scrollV.Gui.Position = UDim2.new(1, -16, 0, 23)
		scrollV.Gui.Size = UDim2.new(0, 16, 1, -23)
		scrollV:SetScrollFrame(treeFrame)
		scrollV.Scrolled:Connect(function()
			RemoteTree.Index = scrollV.Index
			RemoteTree.Refresh()
		end)

		local page = createSimple("Frame", {Name = "RemoteTreePage", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, 0)})
		RemoteTree.Page = page
		RemoteTree.Window = Explorer.Window
		toolBar.Parent = page
		treeFrame.Parent = page
		scrollV.Gui.Parent = page

		toolBar.Refresh.MouseButton1Click:Connect(function() RemoteTree.Rebuild() end)

		RemoteTree.InitClickSystem()
		RemoteTree.InitContext()
		RemoteTree.InitSearch()
		RemoteTree.SetupConnections()
		RemoteTree.InitPromptWindow()

		Explorer.AddTab("Remote Tree", page, {
			OnShow = function() RemoteTree.Active = true RemoteTree.Rebuild() end,
			OnHide = function() RemoteTree.Active = false end,
			OnResize = function() if RemoteTree.Active then RemoteTree.UpdateView() RemoteTree.Refresh() end end,
		})

		RemoteTree.Build()
		RemoteTree.Flatten()
	end

	return RemoteTree
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
