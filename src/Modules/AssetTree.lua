--[[
	Axon · Modules/AssetTree
	A dedicated window/tab listing every asset used in the game.
	Categorized, virtualized, searchable, and previewable.
]]

local oldgame = oldgame or game
local game = workspace.Parent
local cloneref = cloneref

-- Common Locals
local Main, Lib, Apps, Settings -- Main Containers
local Explorer, Properties, ScriptViewer, ModelViewer, Notebook, AssetTree -- Major Apps
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
	ModelViewer = appTable.ModelViewer
	Notebook = appTable.Notebook
	AssetTree = appTable.AssetTree
end

local function main()
	local AssetTree = {}
	AssetTree.GuiElems = {}
	AssetTree.Active = false
	AssetTree.Index = 0
	AssetTree.Query = ""

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
	local clickSys, context
	local listEntries = {}
	local tree = {} -- flat list of currently-visible nodes
	local scanData = {} -- category -> list of assets
	local expandedByObj = setmetatable({}, {__mode = "k"})
	local selectedNode

	-- Asset categories setup
	local categories = {
		{ Key = "Images", Name = "Images & Textures", Class = "Decal" },
		{ Key = "Sounds", Name = "Sounds & Audio", Class = "Sound" },
		{ Key = "Meshes", Name = "Meshes & Models", Class = "MeshPart" },
		{ Key = "Animations", Name = "Animations", Class = "Animation" },
		{ Key = "Videos", Name = "Videos", Class = "VideoFrame" },
		{ Key = "Other", Name = "Other Assets", Class = "Folder" }
	}

	local function safeGet(obj, prop)
		local s, v = pcall(function() return obj[prop] end)
		return s and v or nil
	end

	local function parseAssetId(val)
		if typeof(val) == "string" then
			local id = val:match("rbxassetid://(%d+)") or val:match("asset/%?id=(%d+)") or val:match("id=(%d+)")
			if id then return id end
			local num = val:match("^(%d+)$")
			if num then return num end
		elseif typeof(val) == "number" then
			return tostring(val)
		end
		return nil
	end

	local function determineCategory(obj)
		if obj:IsA("Decal") or obj:IsA("Texture") or obj:IsA("ImageLabel") or obj:IsA("ImageButton") or obj:IsA("Sky") or obj:IsA("ShirtTemplate") or obj:IsA("PantsTemplate") or obj:IsA("ShirtGraphic") then
			return "Images"
		elseif obj:IsA("Sound") then
			return "Sounds"
		elseif obj:IsA("MeshPart") or obj:IsA("SpecialMesh") then
			return "Meshes"
		elseif obj:IsA("Animation") then
			return "Animations"
		elseif obj:IsA("VideoFrame") then
			return "Videos"
		end
		return "Other"
	end

	local function getAssetUrls(obj)
		local urls = {}
		if obj:IsA("Decal") or obj:IsA("Texture") then
			table.insert(urls, safeGet(obj, "Texture"))
		elseif obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
			table.insert(urls, safeGet(obj, "Image"))
		elseif obj:IsA("Sky") then
			table.insert(urls, safeGet(obj, "SkyboxBk"))
			table.insert(urls, safeGet(obj, "SkyboxDn"))
			table.insert(urls, safeGet(obj, "SkyboxFt"))
			table.insert(urls, safeGet(obj, "SkyboxLf"))
			table.insert(urls, safeGet(obj, "SkyboxRt"))
			table.insert(urls, safeGet(obj, "SkyboxUp"))
		elseif obj:IsA("MeshPart") then
			table.insert(urls, safeGet(obj, "MeshId"))
			table.insert(urls, safeGet(obj, "TextureID"))
		elseif obj:IsA("SpecialMesh") then
			table.insert(urls, safeGet(obj, "MeshId"))
			table.insert(urls, safeGet(obj, "TextureId"))
		elseif obj:IsA("Sound") then
			table.insert(urls, safeGet(obj, "SoundId"))
		elseif obj:IsA("Animation") then
			table.insert(urls, safeGet(obj, "AnimationId"))
		elseif obj:IsA("Shirt") or obj:IsA("Pants") or obj:IsA("ShirtGraphic") then
			table.insert(urls, safeGet(obj, "ShirtTemplate") or safeGet(obj, "PantsTemplate") or safeGet(obj, "Graphic"))
		elseif obj:IsA("VideoFrame") then
			table.insert(urls, safeGet(obj, "Video"))
		elseif obj:IsA("PackageLink") then
			table.insert(urls, safeGet(obj, "PackageId"))
		end
		return urls
	end
	local scanQueue = {game}
	local scannedInstances = setmetatable({}, {__mode = "k"})
	local totalScannedCount = 0
	local bgScanRunning = false

	local function scanSingleInstance(inst)
		if scannedInstances[inst] then return end
		scannedInstances[inst] = true

		local urls = getAssetUrls(inst)
		for _, url in ipairs(urls) do
			if url then
				local assetId = parseAssetId(url)
				if assetId then
					local catKey = determineCategory(inst)
					local catAssets = scanData[catKey]
					if not catAssets then
						catAssets = {}
						scanData[catKey] = catAssets
					end
					local assetInfo = catAssets[assetId]
					if not assetInfo then
						assetInfo = { AssetId = assetId, Objects = {} }
						catAssets[assetId] = assetInfo
					end
					local found = false
					for i = 1, #assetInfo.Objects do
						if assetInfo.Objects[i] == inst then
							found = true
							break
						end
					end
					if not found then
						table.insert(assetInfo.Objects, inst)
					end
				end
			end
		end
	end

	local function startBackgroundScan()
		if bgScanRunning then return end
		bgScanRunning = true
		coroutine.wrap(function()
			local head = 1
			while head <= #scanQueue do
				if not AssetTree.Active then
					bgScanRunning = false
					return
				end

				local inst = scanQueue[head]
				head = head + 1

				scanSingleInstance(inst)

				local children = inst:GetChildren()
				for i = 1, #children do
					table.insert(scanQueue, children[i])
				end

				totalScannedCount = totalScannedCount + 1
				if totalScannedCount % 50 == 0 then
					task.wait()
					if AssetTree.Active then
						AssetTree.Flatten()
						AssetTree.UpdateView()
						AssetTree.Refresh()
					end
				end
			end
			bgScanRunning = false
		end)()
	end

	AssetTree.Scan = function()
		startBackgroundScan()
	end

	AssetTree.Build = function()
		expandedByObj = expandedByObj or {}
	end

	local function matchQuery(text)
		if AssetTree.Query == "" then return true end
		return string.find(string.lower(text), string.lower(AssetTree.Query), 1, true) ~= nil
	end

	AssetTree.Flatten = function()
		table.clear(tree)

		for _, cat in ipairs(categories) do
			local catAssets = scanData[cat.Key] or {}
			local catNode = {
				Name = cat.Name,
				Depth = 0,
				Expanded = expandedByObj[cat.Key] or false,
				IsCategory = true,
				AssetType = cat.Key,
				Children = {}
			}

			local visibleAssets = 0
			for assetId, assetInfo in pairs(catAssets) do
				local assetNode = {
					Name = "Asset: " .. assetId,
					Depth = 1,
					Expanded = expandedByObj[assetId] or false,
					IsAsset = true,
					AssetId = assetId,
					AssetType = cat.Key,
					Parent = catNode,
					Children = {}
				}

				local visibleObjs = 0
				for _, obj in ipairs(assetInfo.Objects) do
					local objPath = obj:GetFullName()
					if matchQuery(assetId) or matchQuery(objPath) or matchQuery(cat.Name) then
						local instNode = {
							Name = obj.Name,
							Depth = 2,
							IsInstance = true,
							Obj = obj,
							AssetId = assetId,
							AssetType = cat.Key,
							Parent = assetNode,
							Children = {}
						}
						table.insert(assetNode.Children, instNode)
						visibleObjs = visibleObjs + 1
					end
				end

				if visibleObjs > 0 or matchQuery(assetId) then
					table.insert(catNode.Children, assetNode)
					visibleAssets = visibleAssets + 1
				end
			end

			if visibleAssets > 0 or matchQuery(cat.Name) then
				table.insert(tree, catNode)
				local function addExpanded(node)
					if node.Expanded then
						for _, child in ipairs(node.Children) do
							table.insert(tree, child)
							addExpanded(child)
						end
					end
				end
				addExpanded(catNode)
			end
		end

		-- Set last-child states for guidelines drawing
		for i, node in ipairs(tree) do
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
		countLabel.Text = tostring(#tree) .. " items"
	end

	AssetTree.UpdateView = function()
		local maxNodes = math.max(math.ceil(treeFrame.AbsoluteSize.Y / ROW_H), 0)

		scrollV.VisibleSpace = maxNodes
		scrollV.TotalSpace = #tree
		scrollV.Gui.Visible = #tree > maxNodes

		local newSize = UDim2.new(1, scrollV.Gui.Visible and -16 or 0, 1, -23)
		if treeFrame.Size ~= newSize then
			treeFrame.Size = newSize
		end
		scrollV:Update()
		AssetTree.Index = scrollV.Index

		for i = 1, maxNodes do
			if not listEntries[i] then
				listEntries[i] = AssetTree.NewEntry(i)
			end
		end
		for i = maxNodes + 1, #listEntries do
			if listEntries[i] then
				listEntries[i].Gui.Visible = false
			end
		end
	end

	local function drawLines(entry, node)
		for _, line in ipairs(entry.Guides) do line.Visible = false end
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

	AssetTree.NewEntry = function(index)
		local entryGui = createSimple("TextButton", {
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Font = Enum.Font.SourceSans,
			Text = "",
			TextSize = 14,
			Size = UDim2.new(1, 0, 0, ROW_H),
			ClipsDescendants = true
		})

		local highlight = createSimple("Frame", {
			Name = "Highlight",
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = entryGui
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
			Font = Enum.Font.SourceSans,
			TextSize = 14,
			TextColor3 = Color3.new(1, 1, 1),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = entryGui
		})

		local entry = {
			Gui = entryGui,
			Highlight = highlight,
			Expand = expand,
			Icon = icon,
			Name = nameLabel,
			Guides = {}
		}

		entryGui.Position = UDim2.new(0, 0, 0, ROW_H * (index - 1))

		-- Hover highlight
		entryGui.InputBegan:Connect(function(input)
			local node = tree[index + AssetTree.Index]
			if not node or node == selectedNode then return end
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				entry.Highlight.BackgroundColor3 = Settings.Theme.Button
				entry.Highlight.BackgroundTransparency = 0
			end
		end)
		entryGui.InputEnded:Connect(function(input)
			local node = tree[index + AssetTree.Index]
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				if node ~= selectedNode then entry.Highlight.BackgroundTransparency = 1 end
			end
		end)

		-- Expand / collapse click
		entry.Expand.MouseButton1Click:Connect(function()
			local node = tree[index + AssetTree.Index]
			if not node or #node.Children == 0 then return end
			node.Expanded = not node.Expanded
			expandedByObj[node.IsCategory and node.AssetType or node.AssetId] = node.Expanded
			AssetTree.Flatten()
			AssetTree.UpdateView()
			AssetTree.Refresh()
		end)

		if clickSys then
			clickSys:Add(entryGui)
		end

		entryGui.Parent = treeFrame
		return entry
	end

	local function getNodeClassName(node)
		if node.IsCategory then
			if node.AssetType == "Images" then return "Decal"
			elseif node.AssetType == "Sounds" then return "Sound"
			elseif node.AssetType == "Meshes" then return "MeshPart"
			elseif node.AssetType == "Animations" then return "Animation"
			elseif node.AssetType == "Videos" then return "VideoFrame"
			else return "Folder"
			end
		elseif node.IsAsset then
			if node.AssetType == "Images" then return "ImageLabel"
			elseif node.AssetType == "Sounds" then return "Sound"
			elseif node.AssetType == "Meshes" then return "SpecialMesh"
			elseif node.AssetType == "Animations" then return "Animation"
			elseif node.AssetType == "Videos" then return "VideoFrame"
			else return "Configuration"
			end
		elseif node.IsInstance then
			return node.Obj.ClassName
		end
		return "Folder"
	end

	AssetTree.SetSelected = function(node)
		selectedNode = node
		AssetTree.Refresh()

		if node then
			if node.IsInstance and node.Obj then
				node.Class = node.Obj.ClassName
			end
			if Explorer and Explorer.Selection then
				Explorer.Selection:Set(node)
			end
		end
	end

	AssetTree.Refresh = function()
		local maxNodes = math.max(math.ceil(treeFrame.AbsoluteSize.Y / ROW_H), 0)
		local theme = Settings.Theme
		local miscIcons = Main.MiscIcons

		for i = 1, maxNodes do
			local entry = listEntries[i]
			if not entry then
				entry = AssetTree.NewEntry(i)
				listEntries[i] = entry
			end

			local node = tree[i + AssetTree.Index]
			if node then
				local depth = node.Depth
				entry.Gui.Visible = true

				entry.Name.Position = UDim2.new(0, depth * INDENT + NAME_OFF, 0, 0)
				entry.Name.Size = UDim2.new(1, -(depth * INDENT + NAME_OFF) - 2, 1, 0)
				entry.Name.Text = node.Name
				entry.Name.TextColor3 = node.IsInstance and theme.Text or Color3.fromRGB(150, 150, 150)
				entry.Name.TextTransparency = node.IsInstance and 0 or 0.15

				entry.Icon.Position = UDim2.new(0, depth * INDENT + ICON_OFF, 0, 2)
				pcall(function()
					local className = getNodeClassName(node)
					local displayIcons = Explorer.MiscIcons or miscIcons
					displayIcons:DisplayExplorerIcons(entry.Icon, className)
				end)

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
	end

	AssetTree.InitClickSystem = function()
		clickSys = Lib.ClickSystem.new()
		clickSys.AllowedButtons = {1, 2}

		clickSys.OnDown:Connect(function(item, combo, button)
			local ind
			for i = 1, #listEntries do if listEntries[i].Gui == item then ind = i break end end
			if not ind then return end
			local node = tree[ind + AssetTree.Index]
			if not node then return end

			AssetTree.SetSelected(node)

			if button == 1 and combo == 2 then
				if #node.Children > 0 then
					node.Expanded = not node.Expanded
					expandedByObj[node.IsCategory and node.AssetType or node.AssetId] = node.Expanded
					AssetTree.Flatten()
					AssetTree.UpdateView()
					AssetTree.Refresh()
				end
			end
		end)

		clickSys.OnRelease:Connect(function(item, combo, button, position)
			if button == 2 then AssetTree.ShowContext(position) end
		end)
	end

	AssetTree.ShowContext = function(position)
		if not selectedNode then return end
		context:Clear()

		if selectedNode.AssetId then
			context:Add({
				Name = "Copy Asset ID",
				IconMap = Explorer.ClassIcons,
				Icon = 34,
				OnClick = function()
					pcall(setclipboard or writeclipboard, selectedNode.AssetId)
				end
			})
			context:Add({
				Name = "Open in Browser",
				IconMap = Explorer.ClassIcons,
				Icon = 64,
				OnClick = function()
					pcall(openviewport or print, "https://www.roblox.com/library/" .. selectedNode.AssetId)
				end
			})
		end

		if selectedNode.IsInstance and selectedNode.Obj then
			context:Add({
				Name = "Select in Explorer",
				IconMap = Explorer.ClassIcons,
				Icon = 2,
				OnClick = function()
					if nodes and nodes[selectedNode.Obj] then
						Explorer.Selection:Set(nodes[selectedNode.Obj])
					end
				end
			})
		end

		local mouse = Main.Mouse
		context:Show(position and position.X or mouse.X, position and position.Y or mouse.Y)
	end

	AssetTree.InitContext = function()
		context = Lib.ContextMenu.new()
	end

	AssetTree.InitSearch = function()
		Lib.ViewportTextBox.convert(searchBox)
		searchBox:GetPropertyChangedSignal("Text"):Connect(function()
			AssetTree.Query = searchBox.Text
			AssetTree.Flatten()
			AssetTree.UpdateView()
			AssetTree.Refresh()
		end)
	end

	AssetTree.SetupConnections = function()
		-- Manual refresh preferred for performance
	end

	AssetTree.Rebuild = function()
		table.clear(scanQueue)
		table.insert(scanQueue, game)
		table.clear(scannedInstances)
		for _, cat in ipairs(categories) do
			scanData[cat.Key] = {}
		end
		totalScannedCount = 0
		bgScanRunning = false
		startBackgroundScan()
	end

	AssetTree.Init = function()
		local items = create({
			{1,"Folder",{Name="AssetTreeItems",}},
			{2,"Frame",{BackgroundColor3=Color3.fromRGB(35,37,45),BorderSizePixel=0,Name="ToolBar",Parent={1},Size=UDim2.new(1,0,0,22),}},
			{3,"Frame",{BackgroundColor3=Color3.fromRGB(30,30,35),BorderColor3=Color3.fromRGB(42,42,42),BorderSizePixel=0,Name="SearchFrame",Parent={2},Position=UDim2.new(0,3,0,1),Size=UDim2.new(1,-95,0,18),}},
			{4,"TextBox",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,ClearTextOnFocus=false,Font=3,Name="SearchBox",Parent={3},PlaceholderColor3=Color3.fromRGB(120,120,125),PlaceholderText="Search assets",Position=UDim2.new(0,4,0,0),Size=UDim2.new(1,-8,0,18),Text="",TextColor3=Color3.fromRGB(240,240,245),TextSize=14,TextXAlignment=0,}},
			{5,"UICorner",{CornerRadius=UDim.new(0,2),Parent={3},}},
			{6,"UIStroke",{Thickness=1.4,Parent={3},Color=Color3.fromRGB(42,42,42)}},
			{7,"TextLabel",{BackgroundTransparency=1,Font=3,Name="Count",Parent={2},Position=UDim2.new(1,-90,0,1),Size=UDim2.new(0,64,0,18),Text="0 assets",TextColor3=Color3.fromRGB(120,120,125),TextSize=13,TextXAlignment=1,}},
			{8,"TextButton",{AutoButtonColor=false,BackgroundColor3=Color3.fromRGB(35,37,45),BorderSizePixel=0,Font=3,Name="Refresh",Parent={2},Position=UDim2.new(1,-20,0,1),Size=UDim2.new(0,18,0,18),Text="",TextColor3=Color3.fromRGB(240,240,245),TextSize=14,}},
			{9,"ImageLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Image="rbxassetid://5642310344",Parent={8},Position=UDim2.new(0,3,0,3),Size=UDim2.new(0,12,0,12),}},
			{10,"Frame",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,ClipsDescendants=true,Name="List",Parent={1},Position=UDim2.new(0,0,0,23),Size=UDim2.new(1,0,1,-23),}},
		})

		toolBar = items.ToolBar
		treeFrame = items.List
		searchBox = toolBar.SearchFrame.SearchBox
		countLabel = toolBar.Count

		AssetTree.GuiElems.ToolBar = toolBar
		AssetTree.GuiElems.TreeFrame = treeFrame

		scrollV = Lib.ScrollBar.new()
		scrollV.WheelIncrement = 3
		scrollV.Gui.Position = UDim2.new(1, -16, 0, 23)
		scrollV.Gui.Size = UDim2.new(0, 16, 1, -23)
		scrollV:SetScrollFrame(treeFrame)
		scrollV.Scrolled:Connect(function()
			AssetTree.Index = scrollV.Index
			AssetTree.Refresh()
		end)

		local page = createSimple("Frame", {Name = "AssetTreePage", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, 0)})
		AssetTree.Page = page
		AssetTree.Window = Explorer.Window
		toolBar.Parent = page
		treeFrame.Parent = page
		scrollV.Gui.Parent = page

		toolBar.Refresh.MouseButton1Click:Connect(function() AssetTree.Rebuild() end)

		AssetTree.InitClickSystem()
		AssetTree.InitContext()
		AssetTree.InitSearch()
		AssetTree.SetupConnections()

		Explorer.AddTab("Asset Tree", page, {
			OnShow = function() AssetTree.Active = true AssetTree.Rebuild() end,
			OnHide = function() AssetTree.Active = false end,
			OnResize = function() if AssetTree.Active then AssetTree.UpdateView() AssetTree.Refresh() end end,
		})

		AssetTree.Build()
		AssetTree.Flatten()
	end

	return AssetTree
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
