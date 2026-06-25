--[[
	Axon · Modules/Lib
	Container for shared functions and UI widget classes (windows, scrollbars,
	context menus, code editor, pickers, etc).
]]

local oldgame = oldgame or game
local game = workspace.Parent
local cloneref = cloneref

-- Common Locals
local Main,Lib,Apps,Settings -- Main Containers
local Explorer, Properties, ScriptViewer, Notebook -- Major Apps
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
	Notebook = Apps.Notebook
end

local function main()
	local Lib = {}

	local renderStepped = service.RunService.RenderStepped
	local signalWait = renderStepped.wait
	local PH = newproxy() -- Placeholder, must be replaced in constructor
	local SIGNAL = newproxy()

	-- Usually for classes that work with a Roblox Object
	local function initObj(props,mt)
		local type = type
		local function copy(t)
			local res = {}
			for i,v in pairs(t) do
				if v == SIGNAL then
					res[i] = Lib.Signal.new()
				elseif type(v) == "table" then
					res[i] = copy(v)
				else
					res[i] = v
				end
			end
			return res
		end

		local newObj = copy(props)
		return setmetatable(newObj,mt)
	end

	local function getGuiMT(props,funcs)
		return {__index = function(self,ind) if not props[ind] then return funcs[ind] or self.Gui[ind] end end,
		__newindex = function(self,ind,val) if not props[ind] then self.Gui[ind] = val else rawset(self,ind,val) end end}
	end

	-- Functions

	Lib.FormatLuaString = (function()
		local string = string
		local gsub = string.gsub
		local format = string.format
		local char = string.char
		local cleanTable = {['"'] = '\\"', ['\\'] = '\\\\'}
		for i = 0,31 do
			cleanTable[char(i)] = "\\"..format("%03d",i)
		end
		for i = 127,255 do
			cleanTable[char(i)] = "\\"..format("%03d",i)
		end

		return function(str)
			return gsub(str,"[\"\\\0-\31\127-\255]",cleanTable)
		end
	end)()

	Lib.CheckMouseInGui = function(gui)
		if gui == nil then return false end
		local mouse = Main.Mouse
		local guiPosition = gui.AbsolutePosition
		local guiSize = gui.AbsoluteSize

		return mouse.X >= guiPosition.X and mouse.X < guiPosition.X + guiSize.X and mouse.Y >= guiPosition.Y and mouse.Y < guiPosition.Y + guiSize.Y
	end

	Lib.IsShiftDown = function()
		return service.UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or service.UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	end

	Lib.IsCtrlDown = function()
		return service.UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or service.UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
	end

	Lib.CreateArrow = function(size,num,dir)
		local max = num
		local arrowFrame = createSimple("Frame",{
			BackgroundTransparency = 1,
			Name = "Arrow",
			Size = UDim2.new(0,size,0,size)
		})
		if dir == "up" then
			for i = 1,num do
				local newLine = createSimple("Frame",{
					BackgroundColor3 = Color3.new(220/255,220/255,220/255),
					BorderSizePixel = 0,
					Position = UDim2.new(0,math.floor(size/2)-(i-1),0,math.floor(size/2)+i-math.floor(max/2)-1),
					Size = UDim2.new(0,i+(i-1),0,1),
					Parent = arrowFrame
				})
			end
			return arrowFrame
		elseif dir == "down" then
			for i = 1,num do
				local newLine = createSimple("Frame",{
					BackgroundColor3 = Color3.new(220/255,220/255,220/255),
					BorderSizePixel = 0,
					Position = UDim2.new(0,math.floor(size/2)-(i-1),0,math.floor(size/2)-i+math.floor(max/2)+1),
					Size = UDim2.new(0,i+(i-1),0,1),
					Parent = arrowFrame
				})
			end
			return arrowFrame
		elseif dir == "left" then
			for i = 1,num do
				local newLine = createSimple("Frame",{
					BackgroundColor3 = Color3.new(220/255,220/255,220/255),
					BorderSizePixel = 0,
					Position = UDim2.new(0,math.floor(size/2)+i-math.floor(max/2)-1,0,math.floor(size/2)-(i-1)),
					Size = UDim2.new(0,1,0,i+(i-1)),
					Parent = arrowFrame
				})
			end
			return arrowFrame
		elseif dir == "right" then
			for i = 1,num do
				local newLine = createSimple("Frame",{
					BackgroundColor3 = Color3.new(220/255,220/255,220/255),
					BorderSizePixel = 0,
					Position = UDim2.new(0,math.floor(size/2)-i+math.floor(max/2)+1,0,math.floor(size/2)-(i-1)),
					Size = UDim2.new(0,1,0,i+(i-1)),
					Parent = arrowFrame
				})
			end
			return arrowFrame
		end
		error("r u ok")
	end

	Lib.ParseXML = (function()
		local func = function()
			-- Only exists to parse RMD
			-- from https://github.com/jonathanpoelen/xmlparser

			local string, print, pairs = string, print, pairs

			-- http://lua-users.org/wiki/StringTrim
			local trim = function(s)
				local from = s:match"^%s*()"
				return from > #s and "" or s:match(".*%S", from)
			end

			local gtchar = string.byte('>', 1)
			local slashchar = string.byte('/', 1)
			local D = string.byte('D', 1)
			local E = string.byte('E', 1)

			function parse(s, evalEntities)
				-- remove comments
				s = s:gsub('<!%-%-(.-)%-%->', '')

				local entities, tentities = {}

				if evalEntities then
					local pos = s:find('<[_%w]')
					if pos then
						s:sub(1, pos):gsub('<!ENTITY%s+([_%w]+)%s+(.)(.-)%2', function(name, q, entity)
							entities[#entities+1] = {name=name, value=entity}
						end)
						tentities = createEntityTable(entities)
						s = replaceEntities(s:sub(pos), tentities)
					end
				end

				local t, l = {}, {}

				local addtext = function(txt)
					txt = txt:match'^%s*(.*%S)' or ''
					if #txt ~= 0 then
						t[#t+1] = {text=txt}
					end
				end

				s:gsub('<([?!/]?)([-:_%w]+)%s*(/?>?)([^<]*)', function(type, name, closed, txt)
					-- open
					if #type == 0 then
						local a = {}
						if #closed == 0 then
							local len = 0
							for all,aname,_,value,starttxt in string.gmatch(txt, "(.-([-_%w]+)%s*=%s*(.)(.-)%3%s*(/?>?))") do
								len = len + #all
								a[aname] = value
								if #starttxt ~= 0 then
									txt = txt:sub(len+1)
									closed = starttxt
									break
								end
							end
						end
						t[#t+1] = {tag=name, attrs=a, children={}}

						if closed:byte(1) ~= slashchar then
							l[#l+1] = t
							t = t[#t].children
						end

						addtext(txt)
						-- close
					elseif '/' == type then
						t = l[#l]
						l[#l] = nil

						addtext(txt)
						-- ENTITY
					elseif '!' == type then
						if E == name:byte(1) then
							txt:gsub('([_%w]+)%s+(.)(.-)%2', function(name, q, entity)
								entities[#entities+1] = {name=name, value=entity}
							end, 1)
						end
						-- elseif '?' == type then
						--	 print('?	' .. name .. ' // ' .. attrs .. '$$')
						-- elseif '-' == type then
						--	 print('comment	' .. name .. ' // ' .. attrs .. '$$')
						-- else
						--	 print('o	' .. #p .. ' // ' .. name .. ' // ' .. attrs .. '$$')
					end
				end)

				return {children=t, entities=entities, tentities=tentities}
			end

			function parseText(txt)
				return parse(txt)
			end

			function defaultEntityTable()
				return { quot='"', apos='\'', lt='<', gt='>', amp='&', tab='\t', nbsp=' ', }
			end

			function replaceEntities(s, entities)
				return s:gsub('&([^;]+);', entities)
			end

			function createEntityTable(docEntities, resultEntities)
				entities = resultEntities or defaultEntityTable()
				for _,e in pairs(docEntities) do
					e.value = replaceEntities(e.value, entities)
					entities[e.name] = e.value
				end
				return entities
			end

			return parseText
		end
		local newEnv = setmetatable({},{__index = getfenv()})
		setfenv(func,newEnv)
		return func()
	end)()

	Lib.FastWait = function(s)
		if not s then return signalWait(renderStepped) end
		local start = tick()
		while tick() - start < s do signalWait(renderStepped) end
	end

	Lib.ButtonAnim = function(button,data)
		local holding = false
		local disabled = false
		local mode = data and data.Mode or 1
		local control = {}

		if mode == 2 then
			local lerpTo = data.LerpTo or Color3.new(0,0,0)
			local delta = data.LerpDelta or 0.2
			control.StartColor = data.StartColor or button.BackgroundColor3
			control.PressColor = data.PressColor or control.StartColor:lerp(lerpTo,delta)
			control.HoverColor = data.HoverColor or control.StartColor:lerp(control.PressColor,0.6)
			control.OutlineColor = data.OutlineColor
		end

		button.InputBegan:Connect(function(input)
			if disabled then return end

			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				if not holding then
					if mode == 1 then
						button.BackgroundTransparency = 0.4
					elseif mode == 2 then
						button.BackgroundColor3 = control.HoverColor
					end
				end
			elseif input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				holding = true
				if mode == 1 then
					button.BackgroundTransparency = 0
				elseif mode == 2 then
					button.BackgroundColor3 = control.PressColor
					if control.OutlineColor then button.BorderColor3 = control.PressColor end
				end
			end
		end)

		button.InputEnded:Connect(function(input)
			if disabled then return end

			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				if not holding then
					if mode == 1 then
						button.BackgroundTransparency = 1
					elseif mode == 2 then
						button.BackgroundColor3 = control.StartColor
					end
				end
			elseif input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				holding = false
				if mode == 1 then
					button.BackgroundTransparency = Lib.CheckMouseInGui(button) and 0.4 or 1
				elseif mode == 2 then
					button.BackgroundColor3 = Lib.CheckMouseInGui(button) and control.HoverColor or control.StartColor
					if control.OutlineColor then button.BorderColor3 = control.OutlineColor end
				end
			end
		end)

		control.Disable = function()
			disabled = true
			holding = false

			if mode == 1 then
				button.BackgroundTransparency = 1
			elseif mode == 2 then
				button.BackgroundColor3 = control.StartColor
			end
		end

		control.Enable = function()
			disabled = false
		end

		return control
	end

	Lib.FindAndRemove = function(t,item)
		local pos = table.find(t,item)
		if pos then table.remove(t,pos) end
	end

	Lib.AttachTo = function(obj,data)
		local target,posOffX,posOffY,sizeOffX,sizeOffY,resize,con
		local disabled = false

		local function update()
			if not obj or not target then return end

			local targetPos = target.AbsolutePosition
			local targetSize = target.AbsoluteSize
			obj.Position = UDim2.new(0,targetPos.X + posOffX,0,targetPos.Y + posOffY)
			if resize then obj.Size = UDim2.new(0,targetSize.X + sizeOffX,0,targetSize.Y + sizeOffY) end
		end

		local function setup(o,data)
			obj = o
			data = data or {}
			target = data.Target
			posOffX = data.PosOffX or 0
			posOffY = data.PosOffY or 0
			sizeOffX = data.SizeOffX or 0
			sizeOffY = data.SizeOffY or 0
			resize = data.Resize or false

			if con then con:Disconnect() con = nil end
			if target then
				con = target.Changed:Connect(function(prop)
					if not disabled and prop == "AbsolutePosition" or prop == "AbsoluteSize" then
						update()
					end
				end)
			end

			update()
		end
		setup(obj,data)

		return {
			SetData = function(obj,data)
				setup(obj,data)
			end,
			Enable = function()
				disabled = false
				update()
			end,
			Disable = function()
				disabled = true
			end,
			Destroy = function()
				con:Disconnect()
				con = nil
			end,
		}
	end

	Lib.ProtectedGuis = {}

	Lib.ShowGui = Main.SecureGui

	Lib.ColorToBytes = function(col)
		local round = math.round
		return string.format("%d, %d, %d",round(col.r*255),round(col.g*255),round(col.b*255))
	end

	Lib.ReadFile = function(filename)
		if not env.readfile then return end

		local s,contents = pcall(env.readfile,filename)
		if s and contents then return contents end
	end

	Lib.DeferFunc = function(f,...)
		signalWait(renderStepped)
		return f(...)
	end

	Lib.LoadCustomAsset = function(filepath)
		if not env.getcustomasset or not env.isfile or not env.isfile(filepath) then return end

		return env.getcustomasset(filepath)
	end

	Lib.FetchCustomAsset = function(url,filepath)
		if not env.writefile then return end

		local s,data = pcall(oldgame.HttpGet,game,url)
		if not s then return end

		env.writefile(filepath,data)
		return Lib.LoadCustomAsset(filepath)
	end

	local currentfilename, currentextension, currentclickhandler
	currentclickhandler = function() end
	Lib.SaveAsPrompt = function(filename, codeToSave, ext)
		local win = ScriptViewer.SaveAsWindow
		if not win then
			win = Lib.Window.new()
			win.Alignable = false
			win.Resizable = false
			win:SetTitle("Save As")
			win:SetSize(300,95)

			local saveButton = Lib.Button.new()
			local nameLabel = Lib.Label.new()
			nameLabel.Text = "Name"
			nameLabel.Position = UDim2.new(0,30,0,10)
			nameLabel.Size = UDim2.new(0,40,0,20)
			win:Add(nameLabel)

			local nameBox = Lib.ViewportTextBox.new()
			nameBox.Position = UDim2.new(0,75,0,10)
			nameBox.Size = UDim2.new(0,220,0,20)
			win:Add(nameBox,"NameBox")

			--nameBox.TextBox.Text = filename or ""

			nameBox.TextBox:GetPropertyChangedSignal("Text"):Connect(function()
				saveButton:SetDisabled(#nameBox:GetText() == 0)
			end)

			local errorLabel = Lib.Label.new()
			errorLabel.Text = ""
			errorLabel.Position = UDim2.new(0,5,1,-45)
			errorLabel.Size = UDim2.new(1,-10,0,20)
			errorLabel.TextColor3 = Settings.Theme.Important
			win.ErrorLabel = errorLabel
			win:Add(errorLabel,"Error")

			local cancelButton = Lib.Button.new()
			cancelButton.AnchorPoint = Vector2.new(1,1)
			cancelButton.Text = "Cancel"
			cancelButton.Position = UDim2.new(1,-5,1,-5)
			cancelButton.Size = UDim2.new(0.5,-10,0,20)
			cancelButton.OnClick:Connect(function()
				win:Close()
			end)
			win:Add(cancelButton)

			saveButton.Text = "Save"
			saveButton.AnchorPoint = Vector2.new(0,1)
			saveButton.Position = UDim2.new(0,5,1,-5)
			saveButton.Size = UDim2.new(0.5,-5,0,20)
			saveButton.OnClick:Connect(function()
				currentclickhandler()
			end)

			win:Add(saveButton,"SaveButton")

			ScriptViewer.SaveAsWindow = win
		end

		currentclickhandler = function()
			if type(codeToSave) == "string" then
				filename = (win.Elements.NameBox.TextBox.Text ~= "" and win.Elements.NameBox.TextBox.Text) or filename
				currentextension = ext or filename:match("%.([^%.]+)$") or "txt"
				filename = filename:gsub("%.[^.]+$", "") .. "." .. currentextension

				local codeText = codeToSave or ""
				if env.writefile then
					local s, msg = pcall(env.writefile, filename, codeText)
					if not s then
						win.Elements.Error.Text = "Error: " .. msg
						task.spawn(error, msg)
						task.wait(1)
					end
				else
					win.Elements.Error.Text = "Your executor does not support 'writefile'"
					task.wait(1)
				end
			elseif type(codeToSave) == "function" then
				filename = (win.Elements.NameBox.TextBox.Text ~= "" and win.Elements.NameBox.TextBox.Text) or filename
				currentextension = ext or filename:match("%.([^%.]+)$") or "txt"
				filename = filename:gsub("%.[^.]+$", "") .. "." .. currentextension

				local s, msg = pcall(codeToSave,filename) -- callback
				if not s then
					win.Elements.Error.Text = "Error: " .. msg
					task.spawn(error, msg)
					Lib.FastWait(1)
				end
			end
			win:Close()
		end

		win:SetTitle("Save As")
		win.Elements.Error.Text = ""
		win.Elements.NameBox:SetText(filename or "")

		win.Elements.SaveButton:SetDisabled(win.Elements.NameBox:GetText() == 0)

		win:Show()
	end

	-- Classes

	Lib.Signal = (function()
		local funcs = {}

		local disconnect = function(con)
			local pos = table.find(con.Signal.Connections,con)
			if pos then table.remove(con.Signal.Connections,pos) end
		end

		funcs.Connect = function(self,func)
			if type(func) ~= "function" then error("Attempt to connect a non-function") end
			local con = {
				Signal = self,
				Func = func,
				Disconnect = disconnect
			}
			self.Connections[#self.Connections+1] = con
			return con
		end

		funcs.Fire = function(self,...)
			for i,v in next,self.Connections do
				xpcall(coroutine.wrap(v.Func),function(e) warn(e.."\n"..debug.traceback()) end,...)
			end
		end

		local mt = {
			__index = funcs,
			__tostring = function(self)
				return "Signal: " .. tostring(#self.Connections) .. " Connections"
			end
		}

		local function new()
			local obj = {}
			obj.Connections = {}

			return setmetatable(obj,mt)
		end

		return {new = new}
	end)()

	Lib.Set = (function()
		local funcs = {}

		funcs.Add = function(self,obj)
			if self.Map[obj] then return end

			local list = self.List
			list[#list+1] = obj
			self.Map[obj] = true
			self.Changed:Fire()
		end

		funcs.AddTable = function(self,t)
			local changed
			local list,map = self.List,self.Map
			for i = 1,#t do
				local elem = t[i]
				if not map[elem] then
					list[#list+1] = elem
					map[elem] = true
					changed = true
				end
			end
			if changed then self.Changed:Fire() end
		end

		funcs.Remove = function(self,obj)
			if not self.Map[obj] then return end

			local list = self.List
			local pos = table.find(list,obj)
			if pos then table.remove(list,pos) end
			self.Map[obj] = nil
			self.Changed:Fire()
		end

		funcs.RemoveTable = function(self,t)
			local changed
			local list,map = self.List,self.Map
			local removeSet = {}
			for i = 1,#t do
				local elem = t[i]
				map[elem] = nil
				removeSet[elem] = true
			end

			for i = #list,1,-1 do
				local elem = list[i]
				if removeSet[elem] then
					table.remove(list,i)
					changed = true
				end
			end
			if changed then self.Changed:Fire() end
		end

		funcs.Set = function(self,obj)
			if #self.List == 1 and self.List[1] == obj then return end

			self.List = {obj}
			self.Map = {[obj] = true}
			self.Changed:Fire()
		end

		funcs.SetTable = function(self,t)
			local newList,newMap = {},{}
			self.List,self.Map = newList,newMap
			table.move(t,1,#t,1,newList)
			for i = 1,#t do
				newMap[t[i]] = true
			end
			self.Changed:Fire()
		end

		funcs.Clear = function(self)
			if #self.List == 0 then return end
			self.List = {}
			self.Map = {}
			self.Changed:Fire()
		end

		local mt = {__index = funcs}

		local function new()
			local obj = setmetatable({
				List = {},
				Map = {},
				Changed = Lib.Signal.new()
			},mt)

			return obj
		end

		return {new = new}
	end)()

	Lib.IconMap = (function()
		local funcs = {}
		local IconList = {}

		IconList.Old = {
			MapId = 483448923,
			IconSize = 16,
			Witdh = 16,
			Height = 16,
			Icons = {
				["Accessory"] = 32;
				["Accoutrement"] = 32;
				["AdService"] = 73;
				["Animation"] = 60;
				["AnimationController"] = 60;
				["AnimationTrack"] = 60;
				["Animator"] = 60;
				["ArcHandles"] = 56;
				["AssetService"] = 72;
				["Attachment"] = 34;
				["Backpack"] = 20;
				["BadgeService"] = 75;
				["BallSocketConstraint"] = 89;
				["BillboardGui"] = 64;
				["BinaryStringValue"] = 4;
				["BindableEvent"] = 67;
				["BindableFunction"] = 66;
				["BlockMesh"] = 8;
				["BloomEffect"] = 90;
				["BlurEffect"] = 90;
				["BodyAngularVelocity"] = 14;
				["BodyForce"] = 14;
				["BodyGyro"] = 14;
				["BodyPosition"] = 14;
				["BodyThrust"] = 14;
				["BodyVelocity"] = 14;
				["BoolValue"] = 4;
				["BoxHandleAdornment"] = 54;
				["BrickColorValue"] = 4;
				["Camera"] = 5;
				["CFrameValue"] = 4;
				["CharacterMesh"] = 60;
				["Chat"] = 33;
				["ClickDetector"] = 41;
				["CollectionService"] = 30;
				["Color3Value"] = 4;
				["ColorCorrectionEffect"] = 90;
				["ConeHandleAdornment"] = 54;
				["Configuration"] = 58;
				["ContentProvider"] = 72;
				["ContextActionService"] = 41;
				["CoreGui"] = 46;
				["CoreScript"] = 18;
				["CornerWedgePart"] = 1;
				["CustomEvent"] = 4;
				["CustomEventReceiver"] = 4;
				["CylinderHandleAdornment"] = 54;
				["CylinderMesh"] = 8;
				["CylindricalConstraint"] = 89;
				["Debris"] = 30;
				["Decal"] = 7;
				["Dialog"] = 62;
				["DialogChoice"] = 63;
				["DoubleConstrainedValue"] = 4;
				["Explosion"] = 36;
				["FileMesh"] = 8;
				["Fire"] = 61;
				["Flag"] = 38;
				["FlagStand"] = 39;
				["FloorWire"] = 4;
				["Folder"] = 70;
				["ForceField"] = 37;
				["Frame"] = 48;
				["GamePassService"] = 19;
				["Glue"] = 34;
				["GuiButton"] = 52;
				["GuiMain"] = 47;
				["GuiService"] = 47;
				["Handles"] = 53;
				["HapticService"] = 84;
				["Hat"] = 45;
				["HingeConstraint"] = 89;
				["Hint"] = 33;
				["HopperBin"] = 22;
				["HttpService"] = 76;
				["Humanoid"] = 9;
				["ImageButton"] = 52;
				["ImageLabel"] = 49;
				["InsertService"] = 72;
				["IntConstrainedValue"] = 4;
				["IntValue"] = 4;
				["JointInstance"] = 34;
				["JointsService"] = 34;
				["Keyframe"] = 60;
				["KeyframeSequence"] = 60;
				["KeyframeSequenceProvider"] = 60;
				["Lighting"] = 13;
				["LineHandleAdornment"] = 54;
				["LocalScript"] = 18;
				["LogService"] = 87;
				["MarketplaceService"] = 46;
				["Message"] = 33;
				["Model"] = 2;
				["ModuleScript"] = 71;
				["Motor"] = 34;
				["Motor6D"] = 34;
				["MoveToConstraint"] = 89;
				["NegateOperation"] = 78;
				["NetworkClient"] = 16;
				["NetworkReplicator"] = 29;
				["NetworkServer"] = 15;
				["NumberValue"] = 4;
				["ObjectValue"] = 4;
				["Pants"] = 44;
				["ParallelRampPart"] = 1;
				["Part"] = 1;
				["ParticleEmitter"] = 69;
				["PartPairLasso"] = 57;
				["PathfindingService"] = 37;
				["Platform"] = 35;
				["Player"] = 12;
				["PlayerGui"] = 46;
				["Players"] = 21;
				["PlayerScripts"] = 82;
				["PointLight"] = 13;
				["PointsService"] = 83;
				["Pose"] = 60;
				["PrismaticConstraint"] = 89;
				["PrismPart"] = 1;
				["PyramidPart"] = 1;
				["RayValue"] = 4;
				["ReflectionMetadata"] = 86;
				["ReflectionMetadataCallbacks"] = 86;
				["ReflectionMetadataClass"] = 86;
				["ReflectionMetadataClasses"] = 86;
				["ReflectionMetadataEnum"] = 86;
				["ReflectionMetadataEnumItem"] = 86;
				["ReflectionMetadataEnums"] = 86;
				["ReflectionMetadataEvents"] = 86;
				["ReflectionMetadataFunctions"] = 86;
				["ReflectionMetadataMember"] = 86;
				["ReflectionMetadataProperties"] = 86;
				["ReflectionMetadataYieldFunctions"] = 86;
				["RemoteEvent"] = 80;
				["RemoteFunction"] = 79;
				["ReplicatedFirst"] = 72;
				["ReplicatedStorage"] = 72;
				["RightAngleRampPart"] = 1;
				["RocketPropulsion"] = 14;
				["RodConstraint"] = 89;
				["RopeConstraint"] = 89;
				["Rotate"] = 34;
				["RotateP"] = 34;
				["RotateV"] = 34;
				["RunService"] = 66;
				["ScreenGui"] = 47;
				["Script"] = 6;
				["ScrollingFrame"] = 48;
				["Seat"] = 35;
				["Selection"] = 55;
				["SelectionBox"] = 54;
				["SelectionPartLasso"] = 57;
				["SelectionPointLasso"] = 57;
				["SelectionSphere"] = 54;
				["ServerScriptService"] = 0;
				["ServerStorage"] = 74;
				["Shirt"] = 43;
				["ShirtGraphic"] = 40;
				["SkateboardPlatform"] = 35;
				["Sky"] = 28;
				["SlidingBallConstraint"] = 89;
				["Smoke"] = 59;
				["Snap"] = 34;
				["Sound"] = 11;
				["SoundService"] = 31;
				["Sparkles"] = 42;
				["SpawnLocation"] = 25;
				["SpecialMesh"] = 8;
				["SphereHandleAdornment"] = 54;
				["SpotLight"] = 13;
				["SpringConstraint"] = 89;
				["StarterCharacterScripts"] = 82;
				["StarterGear"] = 20;
				["StarterGui"] = 46;
				["StarterPack"] = 20;
				["StarterPlayer"] = 88;
				["StarterPlayerScripts"] = 82;
				["Status"] = 2;
				["StringValue"] = 4;
				["SunRaysEffect"] = 90;
				["SurfaceGui"] = 64;
				["SurfaceLight"] = 13;
				["SurfaceSelection"] = 55;
				["Team"] = 24;
				["Teams"] = 23;
				["TeleportService"] = 81;
				["Terrain"] = 65;
				["TerrainRegion"] = 65;
				["TestService"] = 68;
				["TextBox"] = 51;
				["TextButton"] = 51;
				["TextLabel"] = 50;
				["Texture"] = 10;
				["TextureTrail"] = 4;
				["Tool"] = 17;
				["TouchTransmitter"] = 37;
				["TrussPart"] = 1;
				["UnionOperation"] = 77;
				["UserInputService"] = 84;
				["Vector3Value"] = 4;
				["VehicleSeat"] = 35;
				["VelocityMotor"] = 34;
				["WedgePart"] = 1;
				["Weld"] = 34;
				["Workspace"] = 19;
			}
		}

		IconList.Vanilla3 = {
			MapId = (114851699900089),
			IconSize = 32,
			Witdh = 25,
			Height = 25,
			Icons = {
				Accessory = 1,
				Accoutrement = 2,
				Actor = 3,
				AdGui = 4,
				AdPortal = 5,
				AdService = 6,
				AdvancedDragger = 7,
				AirController = 8,
				AlignOrientation = 9,
				AlignPosition = 10,
				AnalysticsService = 11,
				AnalysticsSettings = 12,
				AnalyticsService = 13,
				AngularVelocity = 14,
				Animation = 15,
				AnimationClip = 16,
				AnimationClipProvider = 17,
				AnimationController = 18,
				AnimationFromVideoCreatorService = 19,
				AnimationFromVideoCreatorStudioService = 20,
				AnimationRigData = 21,
				AnimationStreamTrack = 22,
				AnimationTrack = 23,
				Animator = 24,
				AppStorageService = 25,
				AppUpdateService = 26,
				ArcHandles = 27,
				AssetCounterService = 28,
				AssetDeliveryProxy = 29,
				AssetImportService = 30,
				AssetImportSession = 31,
				AssetManagerService = 32,
				AssetService = 33,
				AssetSoundEffect = 34,
				Atmosphere = 35,
				Attachment = 36,
				AvatarEditorService = 37,
				AvatarImportService = 38,
				Backpack = 39,
				BackpackItem = 40,
				BadgeService = 41,
				BallSocketConstraint = 42,
				BasePart = 43,
				BasePlayerGui = 44,
				BaseScript = 45,
				BaseWrap = 46,
				Beam = 47,
				BevelMesh = 48,
				BillboardGui = 49,
				BinaryStringValue = 50,
				BindableEvent = 51,
				BindableFunction = 52,
				BlockMesh = 53,
				BloomEffect = 54,
				BlurEffect = 55,
				BodyAngularVelocity = 56,
				BodyColors = 57,
				BodyForce = 58,
				BodyGyro = 59,
				BodyMover = 60,
				BodyPosition = 61,
				BodyThrust = 62,
				BodyVelocity = 63,
				Bone = 64,
				BoolValue = 65,
				BoxHandleAdornment = 66,
				Breakpoint = 67,
				BreakpointManager = 68,
				BrickColorValue = 69,
				BrowserService = 70,
				BubbleChatConfiguration = 71,
				BulkImportService = 72,
				CacheableContentProvider = 73,
				CalloutService = 74,
				Camera = 75,
				CanvasGroup = 76,
				CatalogPages = 77,
				CFrameValue = 78,
				ChangeHistoryService = 79,
				ChannelSelectorSoundEffect = 80,
				CharacterAppearance = 81,
				CharacterMesh = 82,
				Chat = 83,
				ChatInputBarConfiguration = 84,
				ChatWindowConfiguration = 85,
				ChorusSoundEffect = 86,
				ClickDetector = 87,
				ClientReplicator = 88,
				ClimbController = 89,
				Clothing = 90,
				Clouds = 91,
				ClusterPacketCache = 92,
				CollectionService = 93,
				Color3Value = 94,
				ColorCorrectionEffect = 95,
				CommandInstance = 96,
				CommandService = 97,
				CompressorSoundEffect = 98,
				ConeHandleAdornment = 99,
				Configuration = 100,
				ConfigureServerService = 101,
				Constraint = 102,
				ContentProvider = 103,
				ContextActionService = 104,
				Controller = 105,
				ControllerBase = 106,
				ControllerManager = 107,
				ControllerService = 108,
				CookiesService = 109,
				CoreGui = 110,
				CorePackages = 111,
				CoreScript = 112,
				CoreScriptSyncService = 113,
				CornerWedgePart = 114,
				CrossDMScriptChangeListener = 115,
				CSGDictionaryService = 116,
				CurveAnimation = 117,
				CustomEvent = 118,
				CustomEventReceiver = 119,
				CustomSoundEffect = 120,
				CylinderHandleAdornment = 121,
				CylinderMesh = 122,
				CylindricalConstraint = 123,
				DataModel = 124,
				DataModelMesh = 125,
				DataModelPatchService = 126,
				DataModelSession = 127,
				DataStore = 128,
				DataStoreIncrementOptions = 129,
				DataStoreInfo = 130,
				DataStoreKey = 131,
				DataStoreKeyInfo = 132,
				DataStoreKeyPages = 133,
				DataStoreListingPages = 134,
				DataStoreObjectVersionInfo = 135,
				DataStoreOptions = 136,
				DataStorePages = 137,
				DataStoreService = 138,
				DataStoreSetOptions = 139,
				DataStoreVersionPages = 140,
				Debris = 141,
				DebuggablePluginWatcher = 142,
				DebuggerBreakpoint = 143,
				DebuggerConnection = 144,
				DebuggerConnectionManager = 145,
				DebuggerLuaResponse = 146,
				DebuggerManager = 147,
				DebuggerUIService = 148,
				DebuggerVariable = 149,
				DebuggerWatch = 150,
				DebugSettings = 151,
				Decal = 152,
				DepthOfFieldEffect = 153,
				DeviceIdService = 154,
				Dialog = 155,
				DialogChoice = 156,
				DistortionSoundEffect = 157,
				DockWidgetPluginGui = 158,
				DoubleConstrainedValue = 159,
				DraftsService = 160,
				Dragger = 161,
				DraggerService = 162,
				DynamicRotate = 163,
				EchoSoundEffect = 164,
				EmotesPages = 165,
				EqualizerSoundEffect = 166,
				EulerRotationCurve = 167,
				EventIngestService = 168,
				Explosion = 169,
				FaceAnimatorService = 170,
				FaceControls = 171,
				FaceInstance = 172,
				FacialAnimationRecordingService = 173,
				FacialAnimationStreamingService = 174,
				Feature = 175,
				File = 176,
				FileMesh = 177,
				Fire = 178,
				Flag = 179,
				FlagStand = 180,
				FlagStandService = 181,
				FlangeSoundEffect = 182,
				FloatCurve = 183,
				FloorWire = 184,
				FlyweightService = 185,
				Folder = 186,
				ForceField = 187,
				FormFactorPart = 188,
				Frame = 189,
				FriendPages = 190,
				FriendService = 191,
				FunctionalTest = 192,
				GamepadService = 193,
				GamePassService = 194,
				GameSettings = 195,
				GenericSettings = 196,
				Geometry = 197,
				GetTextBoundsParams = 198,
				GlobalDataStore = 199,
				GlobalSettings = 200,
				Glue = 201,
				GoogleAnalyticsConfiguration = 202,
				GroundController = 203,
				GroupService = 204,
				GuiBase = 205,
				GuiBase2d = 206,
				GuiBase3d = 207,
				GuiButton = 208,
				GuidRegistryService = 209,
				GuiLabel = 210,
				GuiMain = 211,
				GuiObject = 212,
				GuiService = 213,
				HandleAdornment = 214,
				Handles = 215,
				HandlesBase = 216,
				HapticService = 217,
				Hat = 218,
				HeightmapImporterService = 219,
				HiddenSurfaceRemovalAsset = 220,
				Highlight = 221,
				HingeConstraint = 222,
				Hint = 223,
				Hole = 224,
				Hopper = 225,
				HopperBin = 226,
				HSRDataContentProvider = 227,
				HttpRbxApiService = 228,
				HttpRequest = 229,
				HttpService = 230,
				Humanoid = 231,
				HumanoidController = 232,
				HumanoidDescription = 233,
				IKControl = 234,
				ILegacyStudioBridge = 235,
				ImageButton = 236,
				ImageHandleAdornment = 237,
				ImageLabel = 238,
				ImporterAnimationSettings = 239,
				ImporterBaseSettings = 240,
				ImporterFacsSettings = 241,
				ImporterGroupSettings = 242,
				ImporterJointSettings = 243,
				ImporterMaterialSettings = 244,
				ImporterMeshSettings = 245,
				ImporterRootSettings = 246,
				IncrementalPatchBuilder = 247,
				InputObject = 248,
				InsertService = 249,
				Instance = 250,
				InstanceAdornment = 251,
				IntConstrainedValue = 252,
				IntValue = 253,
				InventoryPages = 254,
				IXPService = 255,
				JointInstance = 256,
				JointsService = 257,
				KeyboardService = 258,
				Keyframe = 259,
				KeyframeMarker = 260,
				KeyframeSequence = 261,
				KeyframeSequenceProvider = 262,
				LanguageService = 263,
				LayerCollector = 264,
				LegacyStudioBridge = 265,
				Light = 266,
				Lighting = 267,
				LinearVelocity = 268,
				LineForce = 269,
				LineHandleAdornment = 270,
				LocalDebuggerConnection = 271,
				LocalizationService = 272,
				LocalizationTable = 273,
				LocalScript = 274,
				LocalStorageService = 275,
				LodDataEntity = 276,
				LodDataService = 277,
				LoginService = 278,
				LogService = 279,
				LSPFileSyncService = 280,
				LuaSettings = 281,
				LuaSourceContainer = 282,
				LuauScriptAnalyzerService = 283,
				LuaWebService = 284,
				ManualGlue = 285,
				ManualSurfaceJointInstance = 286,
				ManualWeld = 287,
				MarkerCurve = 288,
				MarketplaceService = 289,
				MaterialService = 290,
				MaterialVariant = 291,
				MemoryStoreQueue = 292,
				MemoryStoreService = 293,
				MemoryStoreSortedMap = 294,
				MemStorageConnection = 295,
				MemStorageService = 296,
				MeshContentProvider = 297,
				MeshPart = 298,
				Message = 299,
				MessageBusConnection = 300,
				MessageBusService = 301,
				MessagingService = 302,
				MetaBreakpoint = 303,
				MetaBreakpointContext = 304,
				MetaBreakpointManager = 305,
				Model = 306,
				ModuleScript = 307,
				Motor = 308,
				Motor6D = 309,
				MotorFeature = 310,
				Mouse = 311,
				MouseService = 312,
				MultipleDocumentInterfaceInstance = 313,
				NegateOperation = 314,
				NetworkClient = 315,
				NetworkMarker = 316,
				NetworkPeer = 317,
				NetworkReplicator = 318,
				NetworkServer = 319,
				NetworkSettings = 320,
				NoCollisionConstraint = 321,
				NonReplicatedCSGDictionaryService = 322,
				NotificationService = 323,
				NumberPose = 324,
				NumberValue = 325,
				ObjectValue = 326,
				OrderedDataStore = 327,
				OutfitPages = 328,
				PackageLink = 329,
				PackageService = 330,
				PackageUIService = 331,
				Pages = 332,
				Pants = 333,
				ParabolaAdornment = 334,
				Part = 335,
				PartAdornment = 336,
				ParticleEmitter = 337,
				PartOperation = 338,
				PartOperationAsset = 339,
				PatchMapping = 340,
				Path = 341,
				PathfindingLink = 342,
				PathfindingModifier = 343,
				PathfindingService = 344,
				PausedState = 345,
				PausedStateBreakpoint = 346,
				PausedStateException = 347,
				PermissionsService = 348,
				PhysicsService = 349,
				PhysicsSettings = 350,
				PitchShiftSoundEffect = 351,
				Plane = 352,
				PlaneConstraint = 353,
				Platform = 354,
				Player = 355,
				PlayerEmulatorService = 356,
				PlayerGui = 357,
				PlayerMouse = 358,
				Players = 359,
				PlayerScripts = 360,
				Plugin = 361,
				PluginAction = 362,
				PluginDebugService = 363,
				PluginDragEvent = 364,
				PluginGui = 365,
				PluginGuiService = 366,
				PluginManagementService = 367,
				PluginManager = 368,
				PluginManagerInterface = 369,
				PluginMenu = 370,
				PluginMouse = 371,
				PluginPolicyService = 372,
				PluginToolbar = 373,
				PluginToolbarButton = 374,
				PointLight = 375,
				PointsService = 376,
				PolicyService = 377,
				Pose = 378,
				PoseBase = 379,
				PostEffect = 380,
				PrismaticConstraint = 381,
				ProcessInstancePhysicsService = 382,
				ProximityPrompt = 383,
				ProximityPromptService = 384,
				PublishService = 385,
				PVAdornment = 386,
				PVInstance = 387,
				QWidgetPluginGui = 388,
				RayValue = 389,
				RbxAnalyticsService = 390,
				ReflectionMetadata = 391,
				ReflectionMetadataCallbacks = 392,
				ReflectionMetadataClass = 393,
				ReflectionMetadataClasses = 394,
				ReflectionMetadataEnum = 395,
				ReflectionMetadataEnumItem = 396,
				ReflectionMetadataEnums = 397,
				ReflectionMetadataEvents = 398,
				ReflectionMetadataFunctions = 399,
				ReflectionMetadataItem = 400,
				ReflectionMetadataMember = 401,
				ReflectionMetadataProperties = 402,
				ReflectionMetadataYieldFunctions = 403,
				RemoteDebuggerServer = 404,
				RemoteEvent = 405,
				RemoteFunction = 406,
				RenderingTest = 407,
				RenderSettings = 408,
				ReplicatedFirst = 409,
				ReplicatedStorage = 410,
				ReverbSoundEffect = 411,
				RigidConstraint = 412,
				RobloxPluginGuiService = 413,
				RobloxReplicatedStorage = 414,
				RocketPropulsion = 415,
				RodConstraint = 416,
				RopeConstraint = 417,
				Rotate = 418,
				RotateP = 419,
				RotateV = 420,
				RotationCurve = 421,
				RtMessagingService = 422,
				RunningAverageItemDouble = 423,
				RunningAverageItemInt = 424,
				RunningAverageTimeIntervalItem = 425,
				RunService = 426,
				RuntimeScriptService = 427,
				ScreenGui = 428,
				ScreenshotHud = 429,
				Script = 430,
				ScriptChangeService = 431,
				ScriptCloneWatcher = 432,
				ScriptCloneWatcherHelper = 433,
				ScriptContext = 434,
				ScriptDebugger = 435,
				ScriptDocument = 436,
				ScriptEditorService = 437,
				ScriptRegistrationService = 438,
				ScriptService = 439,
				ScrollingFrame = 440,
				Seat = 441,
				Selection = 442,
				SelectionBox = 443,
				SelectionLasso = 444,
				SelectionPartLasso = 445,
				SelectionPointLasso = 446,
				SelectionSphere = 447,
				ServerReplicator = 448,
				ServerScriptService = 449,
				ServerStorage = 450,
				ServiceProvider = 451,
				SessionService = 452,
				Shirt = 453,
				ShirtGraphic = 454,
				SkateboardController = 455,
				SkateboardPlatform = 456,
				Skin = 457,
				Sky = 458,
				SlidingBallConstraint = 459,
				Smoke = 460,
				Snap = 461,
				SnippetService = 462,
				SocialService = 463,
				SolidModelContentProvider = 464,
				Sound = 465,
				SoundEffect = 466,
				SoundGroup = 467,
				SoundService = 468,
				Sparkles = 469,
				SpawnerService = 470,
				SpawnLocation = 471,
				Speaker = 472,
				SpecialMesh = 473,
				SphereHandleAdornment = 474,
				SpotLight = 475,
				SpringConstraint = 476,
				StackFrame = 477,
				StandalonePluginScripts = 478,
				StandardPages = 479,
				StarterCharacterScripts = 480,
				StarterGear = 481,
				StarterGui = 482,
				StarterPack = 483,
				StarterPlayer = 484,
				StarterPlayerScripts = 485,
				Stats = 486,
				StatsItem = 487,
				Status = 488,
				StopWatchReporter = 489,
				StringValue = 490,
				Studio = 491,
				StudioAssetService = 492,
				StudioData = 493,
				StudioDeviceEmulatorService = 494,
				StudioHighDpiService = 495,
				StudioPublishService = 496,
				StudioScriptDebugEventListener = 497,
				StudioService = 498,
				StudioTheme = 499,
				SunRaysEffect = 500,
				SurfaceAppearance = 501,
				SurfaceGui = 502,
				SurfaceGuiBase = 503,
				SurfaceLight = 504,
				SurfaceSelection = 505,
				SwimController = 506,
				TaskScheduler = 507,
				Team = 508,
				TeamCreateService = 509,
				Teams = 510,
				TeleportAsyncResult = 511,
				TeleportOptions = 512,
				TeleportService = 513,
				TemporaryCageMeshProvider = 514,
				TemporaryScriptService = 515,
				Terrain = 516,
				TerrainDetail = 517,
				TerrainRegion = 518,
				TestService = 519,
				TextBox = 520,
				TextBoxService = 521,
				TextButton = 522,
				TextChannel = 523,
				TextChatCommand = 524,
				TextChatConfigurations = 525,
				TextChatMessage = 526,
				TextChatMessageProperties = 527,
				TextChatService = 528,
				TextFilterResult = 529,
				TextLabel = 530,
				TextService = 531,
				TextSource = 532,
				Texture = 533,
				ThirdPartyUserService = 534,
				ThreadState = 535,
				TimerService = 536,
				ToastNotificationService = 537,
				Tool = 538,
				ToolboxService = 539,
				Torque = 540,
				TorsionSpringConstraint = 541,
				TotalCountTimeIntervalItem = 542,
				TouchInputService = 543,
				TouchTransmitter = 544,
				TracerService = 545,
				TrackerStreamAnimation = 546,
				Trail = 547,
				Translator = 548,
				TremoloSoundEffect = 549,
				TriangleMeshPart = 550,
				TrussPart = 551,
				Tween = 552,
				TweenBase = 553,
				TweenService = 554,
				UGCValidationService = 555,
				UIAspectRatioConstraint = 556,
				UIBase = 557,
				UIComponent = 558,
				UIConstraint = 559,
				UICorner = 560,
				UIGradient = 561,
				UIGridLayout = 562,
				UIGridStyleLayout = 563,
				UILayout = 564,
				UIListLayout = 565,
				UIPadding = 566,
				UIPageLayout = 567,
				UIScale = 568,
				UISizeConstraint = 569,
				UIStroke = 570,
				UITableLayout = 571,
				UITextSizeConstraint = 572,
				UnionOperation = 573,
				UniversalConstraint = 574,
				UnvalidatedAssetService = 575,
				UserGameSettings = 576,
				UserInputService = 577,
				UserService = 578,
				UserSettings = 579,
				UserStorageService = 580,
				ValueBase = 581,
				Vector3Curve = 582,
				Vector3Value = 583,
				VectorForce = 584,
				VehicleController = 585,
				VehicleSeat = 586,
				VelocityMotor = 587,
				VersionControlService = 588,
				VideoCaptureService = 589,
				VideoFrame = 590,
				ViewportFrame = 591,
				VirtualInputManager = 592,
				VirtualUser = 593,
				VisibilityService = 594,
				Visit = 595,
				VoiceChannel = 596,
				VoiceChatInternal = 597,
				VoiceChatService = 598,
				VoiceSource = 599,
				VRService = 600,
				WedgePart = 601,
				Weld = 602,
				WeldConstraint = 603,
				WireframeHandleAdornment = 604,
				Workspace = 605,
				WorldModel = 606,
				WorldRoot = 607,
				WrapLayer = 608,
				WrapTarget = 609,
			}
		}

		IconList.NewDark = {
			MapId = 135148380892747,
			Icons = {
				Accessory = 1,
				Actor = 2,
				AdGui = 3,
				AdPortal = 4,
				AirController = 5,
				AlignOrientation = 6,
				AlignPosition = 7,
				AngularVelocity = 8,
				Animation = 9,
				AnimationConstraint = 10,
				AnimationController = 11,
				AnimationFromVideoCreatorService = 12,
				Animator = 13,
				ArcHandles = 14,
				Atmosphere = 15,
				Attachment = 16,
				AudioAnalyzer = 17,
				AudioChannelMixer = 18,
				AudioChannelSplitter = 19,
				AudioChorus = 20,
				AudioCompressor = 21,
				AudioDeviceInput = 22,
				AudioDeviceOutput = 23,
				AudioDistortion = 24,
				AudioEcho = 25,
				AudioEmitter = 26,
				AudioEqualizer = 27,
				AudioFader = 28,
				AudioFilter = 29,
				AudioFlanger = 30,
				AudioGate = 31,
				AudioLimiter = 32,
				AudioListener = 33,
				AudioPitchShifter = 34,
				AudioPlayer = 35,
				AudioRecorder = 36,
				AudioReverb = 37,
				AudioTextToSpeech = 38,
				AuroraScript = 39,
				AvatarEditorService = 40,
				AvatarSettings = 41,
				Backpack = 42,
				BallSocketConstraint = 43,
				BasePlate = 44,
				Beam = 45,
				BillboardGui = 46,
				BindableEvent = 47,
				BindableFunction = 48,
				BlockMesh = 49,
				BloomEffect = 50,
				BlurEffect = 51,
				BodyAngularVelocity = 52,
				BodyColors = 53,
				BodyForce = 54,
				BodyGyro = 55,
				BodyPosition = 56,
				BodyThrust = 57,
				BodyVelocity = 58,
				Bone = 59,
				BoolValue = 60,
				BoxHandleAdornment = 61,
				Breakpoint = 62,
				BrickColorValue = 63,
				BubbleChatConfiguration = 64,
				Buggaroo = 65,
				Camera = 66,
				CanvasGroup = 67,
				CFrameValue = 68,
				ChannelTabsConfiguration = 69,
				CharacterControllerManager = 70,
				CharacterMesh = 71,
				Chat = 72,
				ChatInputBarConfiguration = 73,
				ChatWindowConfiguration = 74,
				ChorusSoundEffect = 75,
				Class = 76,
				Cleanup = 77,
				ClickDetector = 78,
				ClientReplicator = 79,
				ClimbController = 80,
				Clouds = 81,
				Color = 82,
				ColorCorrectionEffect = 83,
				CompressorSoundEffect = 84,
				ConeHandleAdornment = 85,
				Configuration = 86,
				Constant = 87,
				Constructor = 88,
				Controller = 89,
				CoreGui = 90,
				CornerWedgePart = 91,
				CylinderHandleAdornment = 92,
				CylindricalConstraint = 93,
				Decal = 94,
				DepthOfFieldEffect = 95,
				Dialog = 96,
				DialogChoice = 97,
				DistortionSoundEffect = 98,
				DragDetector = 99,
				EchoSoundEffect = 100,
				EditableImage = 101,
				EditableMesh = 102,
				Enum = 103,
				EnumMember = 104,
				EqualizerSoundEffect = 105,
				Event = 106,
				Explosion = 107,
				FaceControls = 108,
				Field = 109,
				File = 110,
				Fire = 111,
				FlangeSoundEffect = 112,
				Folder = 113,
				ForceField = 114,
				Frame = 115,
				Function = 116,
				GameSettings = 117,
				GroundController = 118,
				Handles = 119,
				HapticEffect = 120,
				HapticService = 121,
				HeightmapImporterService = 122,
				Highlight = 123,
				HingeConstraint = 124,
				Humanoid = 125,
				HumanoidDescription = 126,
				IKControl = 127,
				ImageButton = 128,
				ImageHandleAdornment = 129,
				ImageLabel = 130,
				InputAction = 131,
				InputBinding = 132,
				InputContext = 133,
				Interface = 134,
				IntersectOperation = 135,
				Keyword = 136,
				Lighting = 137,
				LinearVelocity = 138,
				LineForce = 139,
				LineHandleAdornment = 140,
				LocalFile = 141,
				LocalizationService = 142,
				LocalizationTable = 143,
				LocalScript = 144,
				MaterialService = 145,
				MaterialVariant = 146,
				MemoryStoreService = 147,
				MeshPart = 148,
				Meshparts = 149,
				MessagingService = 150,
				Method = 151,
				Model = 152,
				Modelgroups = 153,
				Module = 154,
				ModuleScript = 155,
				Motor6D = 156,
				NegateOperation = 157,
				NetworkClient = 158,
				NoCollisionConstraint = 159,
				Operator = 160,
				PackageLink = 161,
				Pants = 162,
				Part = 163,
				ParticleEmitter = 164,
				Path2D = 165,
				PathfindingLink = 166,
				PathfindingModifier = 167,
				PathfindingService = 168,
				PitchShiftSoundEffect = 169,
				Place = 170,
				Placeholder = 171,
				Plane = 172,
				PlaneConstraint = 173,
				Player = 174,
				Players = 175,
				PluginGuiService = 176,
				PointLight = 177,
				PrismaticConstraint = 178,
				Property = 179,
				ProximityPrompt = 180,
				PublishService = 181,
				Reference = 182,
				RemoteEvent = 183,
				RemoteFunction = 184,
				RenderingTest = 185,
				ReplicatedFirst = 186,
				ReplicatedScriptService = 187,
				ReplicatedStorage = 188,
				ReverbSoundEffect = 189,
				RigidConstraint = 190,
				RobloxPluginGuiService = 191,
				RocketPropulsion = 192,
				RodConstraint = 193,
				RopeConstraint = 194,
				Rotate = 195,
				ScreenGui = 196,
				Script = 197,
				ScrollingFrame = 198,
				Seat = 199,
				Selected_Workspace = 200,
				SelectionBox = 201,
				SelectionSphere = 202,
				ServerScriptService = 203,
				ServerStorage = 204,
				Service = 205,
				Shirt = 206,
				ShirtGraphic = 207,
				SkinnedMeshPart = 208,
				Sky = 209,
				Smoke = 210,
				Snap = 211,
				Snippet = 212,
				SocialService = 213,
				Sound = 214,
				SoundEffect = 215,
				SoundGroup = 216,
				SoundService = 217,
				Sparkles = 218,
				SpawnLocation = 219,
				SpecialMesh = 220,
				SphereHandleAdornment = 221,
				SpotLight = 222,
				SpringConstraint = 223,
				StandalonePluginScripts = 224,
				StarterCharacterScripts = 225,
				StarterGui = 226,
				StarterPack = 227,
				StarterPlayer = 228,
				StarterPlayerScripts = 229,
				Struct = 230,
				StyleDerive = 231,
				StyleLink = 232,
				StyleRule = 233,
				StyleSheet = 234,
				SunRaysEffect = 235,
				SurfaceAppearance = 236,
				SurfaceGui = 237,
				SurfaceLight = 238,
				SurfaceSelection = 239,
				SwimController = 240,
				TaskScheduler = 241,
				Team = 242,
				Teams = 243,
				Terrain = 244,
				TerrainDetail = 245,
				TestService = 246,
				TextBox = 247,
				TextBoxService = 248,
				TextButton = 249,
				TextChannel = 250,
				TextChatCommand = 251,
				TextChatService = 252,
				TextLabel = 253,
				TextString = 254,
				Texture = 255,
				Tool = 256,
				Torque = 257,
				TorsionSpringConstraint = 258,
				Trail = 259,
				TremoloSoundEffect = 260,
				TrussPart = 261,
				TypeParameter = 262,
				UGCValidationService = 263,
				UIAspectRatioConstraint = 264,
				UICorner = 265,
				UIDragDetector = 266,
				UIFlexItem = 267,
				UIGradient = 268,
				UIGridLayout = 269,
				UIListLayout = 270,
				UIPadding = 271,
				UIPageLayout = 272,
				UIScale = 273,
				UISizeConstraint = 274,
				UIStroke = 275,
				UITableLayout = 276,
				UITextSizeConstraint = 277,
				UnionOperation = 278,
				Unit = 279,
				UniversalConstraint = 280,
				UnreliableRemoteEvent = 281,
				UpdateAvailable = 282,
				UserService = 283,
				Value = 284,
				Variable = 285,
				VectorForce = 286,
				VehicleSeat = 287,
				VideoDisplay = 288,
				VideoFrame = 289,
				VideoPlayer = 290,
				ViewportFrame = 291,
				VirtualUser = 292,
				VoiceChannel = 293,
				Voicechat = 294,
				VoiceChatService = 295,
				VRService = 296,
				WedgePart = 297,
				Weld = 298,
				WeldConstraint = 299,
				Wire = 300,
				WireframeHandleAdornment = 301,
				Workspace = 302,
				WorldModel = 303,
				WrapDeformer = 304,
				WrapLayer = 305,
				WrapTarget = 306,

				Color3Value = 284,
				IntValue = 284,
				NumberValue = 284,
				ObjectValue = 284,
				RayValue = 284,
				StringValue = 284,
				Vector3Value = 284,
			},
			IconSize = 32,
			Witdh = 18,
			Height = 18,
		}

		IconList.NewLight = {
			MapId = "",
			Icons = {
				Class = "rbxasset://studio_svg_textures/Shared/InsertableObjects/Light/Standard/",
			},
			IconSize = 16,
			Witdh = 18,
			Height = 18,
		}

		if Settings.ClassIcon and IconList[Settings.ClassIcon] then
			funcs.ExplorerIcons = {
				["MapId"] = IconList[Settings.ClassIcon].MapId,
				["Icons"] = IconList[Settings.ClassIcon].Icons,
				["IconSize"] = IconList[Settings.ClassIcon].IconSize,
				["Witdh"] = IconList[Settings.ClassIcon].Witdh,
				["Height"] = IconList[Settings.ClassIcon].Height}
		else
			funcs.ExplorerIcons = { ["MapId"] = IconList.Old.MapId, ["Icons"] = IconList.Old.Icons, ["IconSize"] = IconList.Old.IconSize }
		end



		funcs.GetLabel = function(self)
			local label = Instance.new("ImageLabel")
			self:SetupLabel(label)
			return label
		end

		funcs.SetupLabel = function(self,obj)
			obj.BackgroundTransparency = 1
			obj.ImageRectOffset = Vector2.new(0, 0)
			obj.ImageRectSize = Vector2.new(self.IconSizeX, self.IconSizeY)
			obj.ScaleType = Enum.ScaleType.Crop
			obj.Size = UDim2.new(0, self.IconSizeX, 0, self.IconSizeY)
		end

		funcs.Display = function(self,obj,index)
			obj.Image = self.MapId
			obj.ImageRectSize = Vector2.new(self.IconSizeX, self.IconSizeY)
			if not self.NumX then
				obj.ImageRectOffset = Vector2.new(self.IconSizeX*index, 0)
			else
				obj.ImageRectOffset = Vector2.new(self.IconSizeX*(index % self.NumX), self.IconSizeY*math.floor(index / self.NumX))
			end
		end

		funcs.DisplayByKey = function(self, obj, key)
			if self.IndexDict[key] then
				self:Display(obj, self.IndexDict[key])
			else
				local rmdEntry = RMD.Classes[obj.ClassName]
				Explorer.ClassIcons:Display(obj, rmdEntry and rmdEntry.ExplorerImageIndex or 0)
			end
		end

		funcs.IconDehash = function(self, _id)
			return math.floor(_id / 14 % 14), math.floor(_id % 14)
		end

		local ClassNameNoImage = {}
		funcs.GetExplorerIcon = function(self, obj, index)
			if Settings.ClassIcon == "Vanilla3" then
				obj.Size = UDim2.fromOffset(16, 16)

				index = (self.ExplorerIcons.Icons[index] or 250) - 1
				obj.ImageRectOffset = Vector2.new(funcs.ExplorerIcons.IconSize * (index % funcs.ExplorerIcons.Height), funcs.ExplorerIcons.IconSize * math.floor(index / funcs.ExplorerIcons.Height))
				obj.ImageRectSize = Vector2.new(funcs.ExplorerIcons.IconSize, funcs.ExplorerIcons.IconSize)
			elseif Settings.ClassIcon == "Old" then
				index = (self.ExplorerIcons.Icons[index] or 0)
				local row, col = self:IconDehash(index)
				local MapSize = Vector2.new(256, 256)
				local pad, border = 2, 1

				obj.Position = UDim2.new(-col - (pad * (col + 1) + border) / funcs.ExplorerIcons.IconSize, 0, -row - (pad * (row + 1) + border) / funcs.ExplorerIcons.IconSize, 0)
				obj.Size = UDim2.new(MapSize.X / funcs.ExplorerIcons.IconSize, 0, MapSize.Y / funcs.ExplorerIcons.IconSize, 0)
			elseif Settings.ClassIcon == "NewLight" or Settings.ClassIcon == "NewDark" then
				local isService = string.find(index, "Service") and game:GetService(index)

				obj.Size = UDim2.fromOffset(16, 16)
				index = (self.ExplorerIcons.Icons[index] or (isService and self.ExplorerIcons.Icons.Service) or self.ExplorerIcons.Icons.Placeholder) - 1
				obj.ImageRectOffset = Vector2.new(funcs.ExplorerIcons.IconSize * (index % funcs.ExplorerIcons.Height), funcs.ExplorerIcons.IconSize * math.floor(index / funcs.ExplorerIcons.Height))
				obj.ImageRectSize = Vector2.new(funcs.ExplorerIcons.IconSize, funcs.ExplorerIcons.IconSize)
			else
				index = (self.ExplorerIcons.Icons[index] or 0)
				local row, col = self:IconDehash(index)
				local MapSize = Vector2.new(256, 256)
				local pad, border = 2, 1

				obj.Position = UDim2.new(-col - (pad * (col + 1) + border) / funcs.ExplorerIcons.IconSize, 0, -row - (pad * (row + 1) + border) / funcs.ExplorerIcons.IconSize, 0)
				obj.Size = UDim2.new(MapSize.X / funcs.ExplorerIcons.IconSize, 0, MapSize.Y / funcs.ExplorerIcons.IconSize, 0)
			end

		end

		funcs.DisplayExplorerIcons = function(self, Frame, index)
			if Frame:FindFirstChild("IconMap") then
				self:GetExplorerIcon(Frame.IconMap, index)
			else
				Frame.ClipsDescendants = true

				local obj = Instance.new("ImageLabel", Frame)
				obj.BackgroundTransparency = 1
				obj.Image = ("http://www.roblox.com/asset/?id=" .. (self.ExplorerIcons.MapId))
				obj.Name = "IconMap"
				self:GetExplorerIcon(obj, index)
			end
		end

		funcs.SetDict = function(self,dict)
			self.IndexDict = dict
		end

		local mt = {}
		mt.__index = funcs

		local function new(mapId,mapSizeX,mapSizeY,iconSizeX,iconSizeY)
			local obj = setmetatable({
				MapId = mapId,
				MapSizeX = mapSizeX,
				MapSizeY = mapSizeY,
				IconSizeX = iconSizeX,
				IconSizeY = iconSizeY,
				NumX = mapSizeX/iconSizeX,
				IndexDict = {}
			}, mt)
			return obj
		end

		local function newLinear(mapId,iconSizeX,iconSizeY)
			local obj = setmetatable({
				MapId = mapId,
				IconSizeX = iconSizeX,
				IconSizeY = iconSizeY,
				IndexDict = {}
			},mt)
			return obj
		end

		local function getIconDataFromName(name)
			return IconList[name] or error("Name not found")
		end

		return {new = new, newLinear = newLinear, getIconDataFromName = getIconDataFromName}
	end)()

	Lib.ScrollBar = (function()
		local funcs = {}
		local user = service.UserInputService
		local mouse = plr:GetMouse()
		local checkMouseInGui = Lib.CheckMouseInGui
		local createArrow = Lib.CreateArrow

		local function drawThumb(self)
			local total = self.TotalSpace
			local visible = self.VisibleSpace
			local index = self.Index
			local scrollThumb = self.GuiElems.ScrollThumb
			local scrollThumbFrame = self.GuiElems.ScrollThumbFrame

			if not (self:CanScrollUp()	or self:CanScrollDown()) then
				scrollThumb.Visible = false
			else
				scrollThumb.Visible = true
			end

			if self.Horizontal then
				scrollThumb.Size = UDim2.new(visible/total,0,1,0)
				if scrollThumb.AbsoluteSize.X < 16 then
					scrollThumb.Size = UDim2.new(0,16,1,0)
				end
				local fs = scrollThumbFrame.AbsoluteSize.X
				local bs = scrollThumb.AbsoluteSize.X
				scrollThumb.Position = UDim2.new(self:GetScrollPercent()*(fs-bs)/fs,0,0,0)
			else
				scrollThumb.Size = UDim2.new(1,0,visible/total,0)
				if scrollThumb.AbsoluteSize.Y < 16 then
					scrollThumb.Size = UDim2.new(1,0,0,16)
				end
				local fs = scrollThumbFrame.AbsoluteSize.Y
				local bs = scrollThumb.AbsoluteSize.Y
				scrollThumb.Position = UDim2.new(0,0,self:GetScrollPercent()*(fs-bs)/fs,0)
			end
		end

		local function createFrame(self)
			local newFrame = createSimple("Frame",{Style=0,Active=true,AnchorPoint=Vector2.new(0,0),BackgroundColor3=Color3.new(0.35294118523598,0.35294118523598,0.35294118523598),BackgroundTransparency=0,BorderColor3=Color3.new(0.10588236153126,0.16470588743687,0.20784315466881),BorderSizePixel=0,ClipsDescendants=false,Draggable=false,Position=UDim2.new(1,-16,0,0),Rotation=0,Selectable=false,Size=UDim2.new(0,16,1,0),SizeConstraint=0,Visible=true,ZIndex=1,Name="ScrollBar",})
			local button1, button2

			if self.Horizontal then
				newFrame.Size = UDim2.new(1,0,0,16)
				button1 = createSimple("ImageButton",{
					Parent = newFrame,
					Name = "Left",
					Size = UDim2.new(0,16,0,16),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
					AutoButtonColor = false
				})
				createArrow(16,4,"left").Parent = button1
				button2 = createSimple("ImageButton",{
					Parent = newFrame,
					Name = "Right",
					Position = UDim2.new(1,-16,0,0),
					Size = UDim2.new(0,16,0,16),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
					AutoButtonColor = false
				})
				createArrow(16,4,"right").Parent = button2
			else
				newFrame.Size = UDim2.new(0,16,1,0)
				button1 = createSimple("ImageButton",{
					Parent = newFrame,
					Name = "Up",
					Size = UDim2.new(0,16,0,16),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
					AutoButtonColor = false
				})
				createArrow(16,4,"up").Parent = button1
				button2 = createSimple("ImageButton",{
					Parent = newFrame,
					Name = "Down",
					Position = UDim2.new(0,0,1,-16),
					Size = UDim2.new(0,16,0,16),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
					AutoButtonColor = false
				})
				createArrow(16,4,"down").Parent = button2
			end

			local scrollThumbFrame = createSimple("ImageButton", {
				BackgroundTransparency = 1,
				Parent = newFrame
			})
			if self.Horizontal then
				scrollThumbFrame.Position = UDim2.new(0,16,0,0)
				scrollThumbFrame.Size = UDim2.new(1,-32,1,0)
			else
				scrollThumbFrame.Position = UDim2.new(0,0,0,16)
				scrollThumbFrame.Size = UDim2.new(1,0,1,-32)
			end

			local scrollThumb = createSimple("Frame", {
				BackgroundColor3 = Color3.new(120/255, 120/255, 120/255),
				BorderSizePixel = 0,
				Parent = scrollThumbFrame
			})

			local markerFrame = createSimple("Frame", {
				BackgroundTransparency = 1,
				Name = "Markers",
				Size = UDim2.new(1, 0, 1, 0),
				Parent = scrollThumbFrame
			})

			local buttonPress = false
			local thumbPress = false
			local thumbFramePress = false

			local function handleButtonPress(button, scrollDirection)
				if self:CanScroll(scrollDirection) then
					button.BackgroundTransparency = 0.5
					self:ScrollToDirection(scrollDirection)
					self.Scrolled:Fire()
					local buttonTick = tick()
					local releaseEvent
					releaseEvent = user.InputEnded:Connect(function(input)
						if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
							releaseEvent:Disconnect()
							button.BackgroundTransparency = checkMouseInGui(button) and 0.8 or 1
							buttonPress = false
						end
					end)
					while buttonPress do
						if tick() - buttonTick >= 0.25 and self:CanScroll(scrollDirection) then
							self:ScrollToDirection(scrollDirection)
							self.Scrolled:Fire()
						end
						task.wait()
					end
				end
			end

			button1.MouseButton1Down:Connect(function(input)
				buttonPress = true
				handleButtonPress(button1, "Up")
			end)

			button1.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					button1.BackgroundTransparency = 1
				end
			end)

			button2.MouseButton1Down:Connect(function(input)
				buttonPress = true
				handleButtonPress(button2, "Down")
			end)

			button2.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					button2.BackgroundTransparency = 1
				end
			end)

			scrollThumb.InputBegan:Connect(function(input)
				if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
					local dir = self.Horizontal and "X" or "Y"
					local lastThumbPos = nil
					thumbPress = true
					scrollThumb.BackgroundTransparency = 0
					local mouseOffset = mouse[dir] - scrollThumb.AbsolutePosition[dir]
					local releaseEvent
					local mouseEvent

					releaseEvent = user.InputEnded:Connect(function(input)
						if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
							releaseEvent:Disconnect()
							if mouseEvent then mouseEvent:Disconnect() end
							scrollThumb.BackgroundTransparency = 0.2
							thumbPress = false
						end
					end)

					mouseEvent = user.InputChanged:Connect(function(input)
						if (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) and thumbPress then
							local thumbFrameSize = scrollThumbFrame.AbsoluteSize[dir] - scrollThumb.AbsoluteSize[dir]
							local pos = mouse[dir] - scrollThumbFrame.AbsolutePosition[dir] - mouseOffset
							if pos > thumbFrameSize then pos = thumbFrameSize
							elseif pos < 0 then pos = 0 end
							if lastThumbPos ~= pos then
								lastThumbPos = pos
								self:ScrollTo(math.floor(0.5 + pos / thumbFrameSize * (self.TotalSpace - self.VisibleSpace)))
							end
						end
					end)
				end
			end)

			scrollThumb.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
					scrollThumb.BackgroundTransparency = 0
				end
			end)

			scrollThumbFrame.InputBegan:Connect(function(input)
				if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) and not checkMouseInGui(scrollThumb) then
					local dir = self.Horizontal and "X" or "Y"
					local scrollDir = (mouse[dir] >= scrollThumb.AbsolutePosition[dir] + scrollThumb.AbsoluteSize[dir]) and 1 or 0
					local function doTick()
						local scrollSize = self.VisibleSpace - 1
						if scrollDir == 0 and mouse[dir] < scrollThumb.AbsolutePosition[dir] then
							self:ScrollTo(self.Index - scrollSize)
						elseif scrollDir == 1 and mouse[dir] >= scrollThumb.AbsolutePosition[dir] + scrollThumb.AbsoluteSize[dir] then
							self:ScrollTo(self.Index + scrollSize)
						end
					end

					thumbPress = false
					thumbFramePress = true
					doTick()
					local thumbFrameTick = tick()
					local releaseEvent
					releaseEvent = user.InputEnded:Connect(function(input)
						if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
							releaseEvent:Disconnect()
							thumbFramePress = false
						end
					end)

					while thumbFramePress do
						if tick() - thumbFrameTick >= 0.3 and checkMouseInGui(scrollThumbFrame) then
							doTick()
						end
						task.wait()
					end
				end
			end)

			newFrame.MouseWheelForward:Connect(function()
				self:ScrollTo(self.Index - self.WheelIncrement)
			end)

			newFrame.MouseWheelBackward:Connect(function()
				self:ScrollTo(self.Index + self.WheelIncrement)
			end)

			self.GuiElems.ScrollThumb = scrollThumb
			self.GuiElems.ScrollThumbFrame = scrollThumbFrame
			self.GuiElems.Button1 = button1
			self.GuiElems.Button2 = button2
			self.GuiElems.MarkerFrame = markerFrame

			return newFrame
		end

		funcs.Update = function(self,nocallback)
			local total = self.TotalSpace
			local visible = self.VisibleSpace
			local index = self.Index
			local button1 = self.GuiElems.Button1
			local button2 = self.GuiElems.Button2

			self.Index = math.clamp(self.Index, 0, math.max(0, total - visible))

			if self.LastTotalSpace ~= self.TotalSpace then
				self.LastTotalSpace = self.TotalSpace
				self:UpdateMarkers()
			end

			if self:CanScrollUp() then
				for i,v in pairs(button1.Arrow:GetChildren()) do
					v.BackgroundTransparency = 0
				end
			else
				button1.BackgroundTransparency = 1
				for i,v in pairs(button1.Arrow:GetChildren()) do
					v.BackgroundTransparency = 0.5
				end
			end
			if self:CanScrollDown() then
				for i,v in pairs(button2.Arrow:GetChildren()) do
					v.BackgroundTransparency = 0
				end
			else
				button2.BackgroundTransparency = 1
				for i,v in pairs(button2.Arrow:GetChildren()) do
					v.BackgroundTransparency = 0.5
				end
			end

			drawThumb(self)
		end

		funcs.UpdateMarkers = function(self)
			local markerFrame = self.GuiElems.MarkerFrame
			markerFrame:ClearAllChildren()

			for i,v in pairs(self.Markers) do
				if i < self.TotalSpace then
					createSimple("Frame", {
						BackgroundTransparency = 0,
						BackgroundColor3 = v,
						BorderSizePixel = 0,
						Position = self.Horizontal and UDim2.new(i/self.TotalSpace,0,1,-6) or UDim2.new(1,-6,i/self.TotalSpace,0),
						Size = self.Horizontal and UDim2.new(0,1,0,6) or UDim2.new(0,6,0,1),
						Name = "Marker"..tostring(i),
						Parent = markerFrame
					})
				end
			end
		end

		funcs.AddMarker = function(self,ind,color)
			self.Markers[ind] = color or Color3.new(0,0,0)
		end
		funcs.ScrollTo = function(self, ind, nocallback)
			self.Index = ind
			self:Update()
			if not nocallback then
				self.Scrolled:Fire()
			end
		end
		funcs.ScrollUp = function(self)
			self.Index = self.Index - self.Increment
			self:Update()
		end
		funcs.CanScroll = function(self, direction)
			if direction == "Up" then
				return self:CanScrollUp()
			elseif direction == "Down" then
				return self:CanScrollDown()
			end
			return false
		end
		funcs.ScrollDown = function(self)
			self.Index = self.Index + self.Increment
			self:Update()
		end
		funcs.CanScrollUp = function(self)
			return self.Index > 0
		end
		funcs.CanScrollDown = function(self)
			return self.Index + self.VisibleSpace < self.TotalSpace
		end
		funcs.GetScrollPercent = function(self)
			return self.Index/(self.TotalSpace-self.VisibleSpace)
		end
		funcs.SetScrollPercent = function(self,perc)
			self.Index = math.floor(perc*(self.TotalSpace-self.VisibleSpace))
			self:Update()
		end
		funcs.ScrollToDirection = function(self, Direaction)
			if Direaction == "Up" then
				self:ScrollUp()
			elseif Direaction == "Down" then
				self:ScrollDown()
			end
		end

		funcs.Texture = function(self,data)
			self.ThumbColor = data.ThumbColor or Color3.new(0,0,0)
			self.ThumbSelectColor = data.ThumbSelectColor or Color3.new(0,0,0)
			self.GuiElems.ScrollThumb.BackgroundColor3 = data.ThumbColor or Color3.new(0,0,0)
			self.Gui.BackgroundColor3 = data.FrameColor or Color3.new(0,0,0)
			self.GuiElems.Button1.BackgroundColor3 = data.ButtonColor or Color3.new(0,0,0)
			self.GuiElems.Button2.BackgroundColor3 = data.ButtonColor or Color3.new(0,0,0)
			for i,v in pairs(self.GuiElems.Button1.Arrow:GetChildren()) do
				v.BackgroundColor3 = data.ArrowColor or Color3.new(0,0,0)
			end
			for i,v in pairs(self.GuiElems.Button2.Arrow:GetChildren()) do
				v.BackgroundColor3 = data.ArrowColor or Color3.new(0,0,0)
			end
		end

		funcs.SetScrollFrame = function(self,frame)
			if self.ScrollUpEvent then self.ScrollUpEvent:Disconnect() self.ScrollUpEvent = nil end
			if self.ScrollDownEvent then self.ScrollDownEvent:Disconnect() self.ScrollDownEvent = nil end
			self.ScrollUpEvent = frame.MouseWheelForward:Connect(function() self:ScrollTo(self.Index - self.WheelIncrement) end)
			self.ScrollDownEvent = frame.MouseWheelBackward:Connect(function() self:ScrollTo(self.Index + self.WheelIncrement) end)
		end

		local mt = {}
		mt.__index = funcs

		local function new(hor)
			local obj = setmetatable({
				Index = 0,
				VisibleSpace = 0,
				TotalSpace = 0,
				Increment = 1,
				WheelIncrement = 1,
				Markers = {},
				GuiElems = {},
				Horizontal = hor,
				LastTotalSpace = 0,
				Scrolled = Lib.Signal.new()
			},mt)
			obj.Gui = createFrame(obj)
			obj:Texture({
				ThumbColor = Color3.fromRGB(60,60,60),
				ThumbSelectColor = Color3.fromRGB(75,75,75),
				ArrowColor = Color3.new(1,1,1),
				FrameColor = Color3.fromRGB(40,40,40),
				ButtonColor = Color3.fromRGB(75,75,75)
			})
			return obj
		end

		return {new = new}
	end)()

	--[[AXON_LIB_PART_4]]
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
