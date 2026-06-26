--[[
	Axon · Modules/ScriptSearch
	A dedicated panel to search inside the source code of all scripts in the game.
	Provides line previews, highlighting, progress, and double-click to view.
]]

local oldgame = oldgame or game
local game = workspace.Parent
local isa = game.IsA

-- Common Locals
local Main, Lib, Apps, Settings
local Explorer, Properties, ScriptViewer, ScriptSearch
local API, RMD, env, service, plr, create, createSimple

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
	ScriptSearch = appTable.ScriptSearch
end

local function main()
	local ScriptSearch = {}
	ScriptSearch.Index = 0
	ScriptSearch.Active = false
	ScriptSearch.GuiElems = {}

	local toolBar, listFrame, scrollV
	local searchBox, searchBtn, stopBtn, statusLabel
	local clickSys
	local results = {}
	local listEntries = {}
	local scanThread = nil
	local selectedEntry = nil
	local ROW_H = 34

	ScriptSearch.NewEntry = function(index)
		local entryGui = createSimple("TextButton", {
			AutoButtonColor = false,
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, ROW_H),
			Text = ""
		})

		local highlight = createSimple("Frame", {
			Name = "Highlight",
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = entryGui
		})

		local icon = createSimple("ImageLabel", {
			Name = "Icon",
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 16, 0, 16),
			Position = UDim2.new(0, 4, 0, 9),
			Parent = entryGui
		})

		local pathLabel = createSimple("TextLabel", {
			Name = "PathLabel",
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSansBold,
			TextSize = 13,
			TextColor3 = Color3.fromRGB(180, 180, 185),
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.new(0, 24, 0, 1),
			Size = UDim2.new(1, -28, 0, 16),
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = entryGui
		})

		local codeLabel = createSimple("TextLabel", {
			Name = "CodeLabel",
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSansItalic,
			TextSize = 13,
			TextColor3 = Color3.fromRGB(240, 240, 245),
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.new(0, 24, 0, 16),
			Size = UDim2.new(1, -28, 0, 16),
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = entryGui
		})

		entryGui.Position = UDim2.new(0, 0, 0, ROW_H * (index - 1))

		-- Hover highlight
		entryGui.InputBegan:Connect(function(input)
			local node = results[index + ScriptSearch.Index]
			if not node or node == selectedEntry then return end
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				highlight.BackgroundColor3 = Settings.Theme.Button
				highlight.BackgroundTransparency = 0
			end
		end)
		entryGui.InputEnded:Connect(function(input)
			local node = results[index + ScriptSearch.Index]
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				if node ~= selectedEntry then highlight.BackgroundTransparency = 1 end
			end
		end)

		entryGui.Parent = listFrame
		return {
			Gui = entryGui,
			Highlight = highlight,
			Icon = icon,
			Path = pathLabel,
			Code = codeLabel
		}
	end

	ScriptSearch.SetSelected = function(node)
		selectedEntry = node
		ScriptSearch.Refresh()
		if node and node.Obj and Explorer and Explorer.Selection then
			node.Class = node.Obj.ClassName
			Explorer.Selection:Set(node)
		end
	end

	ScriptSearch.Refresh = function()
		local maxNodes = math.max(math.ceil(listFrame.AbsoluteSize.Y / ROW_H), 0)
		local theme = Settings.Theme
		local miscIcons = Main.MiscIcons

		for i = 1, maxNodes do
			local entry = listEntries[i]
			if not entry then
				entry = ScriptSearch.NewEntry(i)
				listEntries[i] = entry
				clickSys:Add(entry.Gui)
			end

			local node = results[i + ScriptSearch.Index]
			if node then
				entry.Gui.Visible = true
				entry.Path.Text = ("%s : Line %d"):format(node.Obj.Name, node.Line)
				entry.Code.Text = node.Content
				
				pcall(function()
					local displayIcons = Explorer.MiscIcons or miscIcons
					displayIcons:DisplayExplorerIcons(entry.Icon, node.Obj.ClassName)
				end)

				if node == selectedEntry then
					entry.Highlight.BackgroundColor3 = theme.ListSelection
					entry.Highlight.BackgroundTransparency = 0
				elseif Lib.CheckMouseInGui(entry.Gui) then
					entry.Highlight.BackgroundColor3 = theme.Button
					entry.Highlight.BackgroundTransparency = 0
				else
					entry.Highlight.BackgroundTransparency = 1
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

	ScriptSearch.UpdateView = function()
		local maxNodes = math.max(math.ceil(listFrame.AbsoluteSize.Y / ROW_H), 0)
		scrollV.VisibleSpace = maxNodes
		scrollV.TotalSpace = #results
		scrollV.Gui.Visible = #results > maxNodes
		scrollV:Update()
		ScriptSearch.Index = scrollV.Index
	end

	ScriptSearch.Search = function(query)
		if not query or #query == 0 then return end
		if scanThread then
			coroutine.close(scanThread)
			scanThread = nil
		end

		table.clear(results)
		ScriptSearch.Index = 0
		scrollV.Index = 0
		ScriptSearch.Refresh()

		if listFrame then
			Lib.ShowLoading(listFrame, "Searching scripts...")
		end

		statusLabel.Text = "Collecting scripts..."
		searchBtn.Visible = false
		stopBtn.Visible = true

		local scripts = {}
		local queue = {game}
		local head = 1
		local start = os.clock()

		while head <= #queue do
			local inst = queue[head]
			head = head + 1
			local ch = inst:GetChildren()
			for i = 1, #ch do
				local c = ch[i]
				if isa(c, "LuaSourceContainer") then
					table.insert(scripts, c)
				end
				if #c:GetChildren() > 0 then
					table.insert(queue, c)
				end
			end
			if os.clock() - start > 0.015 then
				task.wait()
				start = os.clock()
			end
		end

		statusLabel.Text = ("Found %d scripts. Grepping..."):format(#scripts)

		scanThread = coroutine.create(function()
			local lq = query:lower()
			local scanned = 0
			local grepStart = os.clock()
			for idx = 1, #scripts do
				local scr = scripts[idx]
				scanned = scanned + 1
				statusLabel.Text = ("Grep: %d/%d (%d matches)"):format(scanned, #scripts, #results)

				local success, source = pcall(env.decompile, scr)
				if success and type(source) == "string" then
					local lineNum = 0
					for line in source:gmatch("([^\n\r]*)[\n\r]?") do
						lineNum = lineNum + 1
						if string.find(line:lower(), lq, 1, true) then
							local cleanContent = line:gsub("^%s+", ""):gsub("%s+$", "")
							table.insert(results, {
								Obj = scr,
								Line = lineNum,
								Content = cleanContent,
								Path = scr:GetFullName()
							})
							ScriptSearch.UpdateView()
							ScriptSearch.Refresh()
						end
					end
				end

				if os.clock() - grepStart > 0.015 then
					task.wait()
					grepStart = os.clock()
				end
			end

			statusLabel.Text = ("Search complete: %d matches"):format(#results)
			searchBtn.Visible = true
			stopBtn.Visible = false
			scanThread = nil
			if listFrame then
				Lib.HideLoading(listFrame)
			end
		end)
		coroutine.resume(scanThread)
	end

	ScriptSearch.Stop = function()
		if scanThread then
			coroutine.close(scanThread)
			scanThread = nil
		end
		statusLabel.Text = "Search stopped."
		searchBtn.Visible = true
		stopBtn.Visible = false
		if listFrame then
			Lib.HideLoading(listFrame)
		end
	end

	ScriptSearch.InitClickSystem = function()
		clickSys = Lib.ClickSystem.new()
		clickSys.AllowedButtons = {1, 2}

		clickSys.OnDown:Connect(function(item, combo, button)
			local ind
			for i = 1, #listEntries do if listEntries[i].Gui == item then ind = i break end end
			if not ind then return end
			local node = results[ind + ScriptSearch.Index]
			if not node then return end

			ScriptSearch.SetSelected(node)

			if button == 1 and combo == 2 then
				if node.Obj then
					ScriptViewer.ViewScript(node.Obj, node.Line)
				end
			end
		end)
	end

	ScriptSearch.Init = function()
		local items = create({
			{1,"Folder",{Name="ScriptSearchItems",}},
			{2,"Frame",{BackgroundColor3=Settings.Theme.Main2,BorderSizePixel=0,Name="ToolBar",Parent={1},Size=UDim2.new(1,0,0,26),}},
			{3,"Frame",{BackgroundColor3=Settings.Theme.TextBox,BorderSizePixel=0,Name="SearchFrame",Parent={2},Position=UDim2.new(0,3,0,3),Size=UDim2.new(1,-185,0,20),}},
			{4,"TextBox",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,ClearTextOnFocus=false,Font=3,Name="SearchBox",Parent={3},PlaceholderColor3=Settings.Theme.PlaceholderText,PlaceholderText="Search text in scripts...",Position=UDim2.new(0,4,0,0),Size=UDim2.new(1,-8,0,20),Text="",TextColor3=Settings.Theme.Text,TextSize=14,TextXAlignment=0,}},
			{5,"UICorner",{CornerRadius=UDim.new(0,2),Parent={3},}},
			{6,"UIStroke",{Thickness=1.4,Parent={3},Color=Settings.Theme.Outline3}},
			{7,"TextLabel",{BackgroundTransparency=1,Font=3,Name="Status",Parent={2},Position=UDim2.new(1,-175,0,3),Size=UDim2.new(0,100,0,20),Text="Ready",TextColor3=Settings.Theme.PlaceholderText,TextSize=11,TextXAlignment=0,}},
			{8,"TextButton",{AutoButtonColor=false,BackgroundColor3=Settings.Theme.Highlight,BorderSizePixel=0,Font=4,Name="SearchBtn",Parent={2},Position=UDim2.new(1,-70,0,3),Size=UDim2.new(0,65,0,20),Text="Search",TextColor3=Color3.new(1,1,1),TextSize=13,}},
			{9,"UICorner",{CornerRadius=UDim.new(0,2),Parent={8},}},
			{10,"TextButton",{AutoButtonColor=false,BackgroundColor3=Color3.fromRGB(245,60,60),BorderSizePixel=0,Font=4,Name="StopBtn",Parent={2},Position=UDim2.new(1,-70,0,3),Size=UDim2.new(0,65,0,20),Text="Stop",TextColor3=Color3.new(1,1,1),TextSize=13,Visible=false,}},
			{11,"UICorner",{CornerRadius=UDim.new(0,2),Parent={10},}},
			{12,"Frame",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,ClipsDescendants=true,Name="List",Parent={1},Position=UDim2.new(0,0,0,27),Size=UDim2.new(1,0,1,-27),}},
			{13,"Frame",{BackgroundColor3=Settings.Theme.Outline1,BorderSizePixel=0,Name="Line",Parent={2},Position=UDim2.new(0,0,1,-1),Size=UDim2.new(1,0,0,1),}},
		})

		toolBar = items.ToolBar
		listFrame = items.List
		searchBox = toolBar.SearchFrame.SearchBox
		searchBtn = toolBar.SearchBtn
		stopBtn = toolBar.StopBtn
		statusLabel = toolBar.Status

		ScriptSearch.GuiElems.ToolBar = toolBar
		ScriptSearch.GuiElems.ListFrame = listFrame

		scrollV = Lib.ScrollBar.new()
		scrollV.WheelIncrement = 3
		scrollV.Gui.Position = UDim2.new(1, -16, 0, 27)
		scrollV.Gui.Size = UDim2.new(0, 16, 1, -27)
		scrollV:SetScrollFrame(listFrame)
		scrollV.Scrolled:Connect(function()
			ScriptSearch.Index = scrollV.Index
			ScriptSearch.Refresh()
		end)

		local page = createSimple("Frame", {Name = "ScriptSearchPage", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, 0)})
		ScriptSearch.Page = page
		ScriptSearch.Window = Explorer.Window
		toolBar.Parent = page
		listFrame.Parent = page
		scrollV.Gui.Parent = page

		searchBtn.MouseButton1Click:Connect(function()
			ScriptSearch.Search(searchBox.Text)
		end)

		stopBtn.MouseButton1Click:Connect(function()
			ScriptSearch.Stop()
		end)

		-- Trigger search on Enter
		searchBox.FocusLost:Connect(function(enterPressed)
			if enterPressed then
				ScriptSearch.Search(searchBox.Text)
			end
		end)

		ScriptSearch.InitClickSystem()

		Explorer.AddTab("Script Search", page, {
			OnShow = function()
				ScriptSearch.Active = true
				ScriptSearch.UpdateView()
				ScriptSearch.Refresh()
			end,
			OnHide = function()
				ScriptSearch.Active = false
				ScriptSearch.Stop()
			end,
			OnResize = function()
				if ScriptSearch.Active then
					ScriptSearch.UpdateView()
					ScriptSearch.Refresh()
				end
			end
		})
	end

	return ScriptSearch
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
