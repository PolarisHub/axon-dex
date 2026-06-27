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
	local editBox, confirmBtn
	local scanThread
	local currentScanId = 0
	local targetScript
	local resolvedNames = {}
	local functionCallConn
	local lastCallTarget
	local blockRefreshQueued = false

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

	local stateRoot
	pcall(function()
		stateRoot = (env and env.getgenv and env.getgenv()) or (getgenv and getgenv())
	end)
	stateRoot = stateRoot or _G
	stateRoot.AxonFunctionBlockState = stateRoot.AxonFunctionBlockState or {
		Blocks = {},
		BlockActions = 0,
		UnblockActions = 0,
		TotalBlockedCalls = 0
	}
	local functionBlockState = stateRoot.AxonFunctionBlockState
	functionBlockState.Blocks = functionBlockState.Blocks or {}
	functionBlockState.BlockActions = functionBlockState.BlockActions or 0
	functionBlockState.UnblockActions = functionBlockState.UnblockActions or 0
	functionBlockState.TotalBlockedCalls = functionBlockState.TotalBlockedCalls or 0

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

	local function trim(str)
		return tostring(str or ""):match("^%s*(.-)%s*$")
	end

	local function safeToString(val, maxLen)
		local ok, text = pcall(tostring, val)
		if not ok then
			text = "<tostring failed>"
		end
		if maxLen and #text > maxLen then
			return text:sub(1, maxLen) .. "..."
		end
		return text
	end

	local function formatValue(val, valType)
		if valType == "string" then
			return '"' .. safeToString(val, 500) .. '"'
		elseif valType == "nil" then
			return "nil"
		elseif valType == "table" then
			return "Table: " .. safeToString(val, 200)
		elseif valType == "function" then
			local name = "anonymous"
			local getinfo = (debug and (debug.getinfo or debug.info)) or getinfo
			pcall(function()
				local inf = getinfo(val)
				name = inf.name ~= "" and inf.name or ("anonymous_line_%d"):format(inf.linedefined or 0)
			end)
			if resolvedNames[val] then
				name = resolvedNames[val] .. " (" .. name .. ")"
			end
			return ("Function: %s (%s)"):format(name, safeToString(val, 160))
		elseif valType == "userdata" or typeof(val) == "Instance" then
			local str = safeToString(val, 200)
			local name = str
			pcall(function()
				if typeof(val) == "Instance" then
					name = val:GetFullName()
				else
					local mt = getmetatable(val)
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
			return safeToString(val, 500)
		end
	end

	local function getTableSummary(tbl)
		local counts = {}
		local total = 0
		local success, err = pcall(function()
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

	local function getEditableType(node)
		local editableType = node and (node.EditableType or node.Type)
		if editableType == "Upvalue" or editableType == "Constant" or editableType == "TableValue" then
			return editableType
		end
	end

	local function isEditableNode(node)
		return getEditableType(node) ~= nil
	end

	local function parseNumberList(text, expected)
		local values = {}
		for piece in tostring(text):gmatch("[^,]+") do
			local numberValue = tonumber(trim(piece))
			if numberValue == nil then
				return nil
			end
			values[#values + 1] = numberValue
		end
		if #values ~= expected then
			return nil
		end
		return values
	end

	local function parseExpression(expr)
		local loader = (env and env.loadstring) or loadstring
		if not loader then
			return false, "loadstring is not available"
		end

		local chunk, compileErr = loader("return " .. expr)
		if not chunk then
			chunk, compileErr = loader(expr)
		end
		if not chunk then
			return false, compileErr or "compile failed"
		end

		local ok, result = pcall(chunk)
		if not ok then
			return false, result
		end
		return true, result
	end

	local function isExpressionEdit(text, targetType)
		local trimmed = trim(text)
		return trimmed:sub(1, 1) == "="
			or (targetType == "table" and trimmed:sub(1, 1) == "{")
			or (targetType == "function" and trimmed:sub(1, 8) == "function")
	end

	local function parseValue(valStr, targetType, allowExpressions)
		if allowExpressions == nil then allowExpressions = true end
		local raw = tostring(valStr or "")
		local trimmed = trim(raw)

		if trimmed:sub(1, 1) == "=" then
			if not allowExpressions then
				return false, "expression runs on confirm"
			end
			return parseExpression(trimmed:sub(2))
		end

		if targetType ~= "string" and trimmed == "nil" then
			return true, nil
		end

		if targetType == "number" then
			local numberValue = tonumber(trimmed)
			if numberValue ~= nil then
				return true, numberValue
			end
			return false, "expected number"
		elseif targetType == "boolean" then
			local lower = trimmed:lower()
			if lower == "true" then return true, true end
			if lower == "false" then return true, false end
			return false, "expected true or false"
		elseif targetType == "string" then
			return true, raw
		elseif targetType == "nil" then
			if trimmed == "nil" or trimmed == "" then
				return true, nil
			end
			return false, "expected nil or =expression"
		elseif targetType == "Vector3" then
			local values = parseNumberList(trimmed, 3)
			if values then
				return true, Vector3.new(values[1], values[2], values[3])
			end
			return false, "expected x, y, z or =Vector3.new(...)"
		elseif targetType == "Vector2" then
			local values = parseNumberList(trimmed, 2)
			if values then
				return true, Vector2.new(values[1], values[2])
			end
			return false, "expected x, y or =Vector2.new(...)"
		elseif targetType == "Color3" then
			local values = parseNumberList(trimmed, 3)
			if values then
				return true, Color3.fromRGB(values[1], values[2], values[3])
			end
			return false, "expected r, g, b or =Color3.new(...)"
		elseif targetType == "UDim" then
			local values = parseNumberList(trimmed, 2)
			if values then
				return true, UDim.new(values[1], values[2])
			end
			return false, "expected scale, offset or =UDim.new(...)"
		elseif targetType == "UDim2" then
			local values = parseNumberList(trimmed, 4)
			if values then
				return true, UDim2.new(values[1], values[2], values[3], values[4])
			end
			return false, "expected sx, ox, sy, oy or =UDim2.new(...)"
		elseif targetType == "BrickColor" then
			if trimmed ~= "" then
				local ok, brickColor = pcall(BrickColor.new, tonumber(trimmed) or trimmed)
				if ok then
					return true, brickColor
				end
			end
			return false, "expected BrickColor name/number or =BrickColor.new(...)"
		elseif targetType == "table" and trimmed:sub(1, 1) == "{" then
			if not allowExpressions then
				return false, "table literal runs on confirm"
			end
			local ok, result = parseExpression(trimmed)
			if ok and type(result) == "table" then
				return true, result
			end
			return false, ok and "expression did not return table" or result
		elseif targetType == "function" and trimmed:sub(1, 8) == "function" then
			if not allowExpressions then
				return false, "function literal runs on confirm"
			end
			local ok, result = parseExpression(trimmed)
			if ok and typeof(result) == "function" then
				return true, result
			end
			return false, ok and "expression did not return function" or result
		end

		return false, "use =expression to replace this " .. tostring(targetType)
	end

	local function valueToEditText(value, valueType)
		if valueType == "string" then
			return tostring(value or "")
		elseif valueType == "number" or valueType == "boolean" or valueType == "nil" then
			return tostring(value)
		elseif valueType == "Vector3" then
			return ("%s, %s, %s"):format(value.X, value.Y, value.Z)
		elseif valueType == "Vector2" then
			return ("%s, %s"):format(value.X, value.Y)
		elseif valueType == "Color3" then
			return ("%d, %d, %d"):format(math.floor(value.R * 255 + 0.5), math.floor(value.G * 255 + 0.5), math.floor(value.B * 255 + 0.5))
		elseif valueType == "UDim" then
			return ("%s, %s"):format(value.Scale, value.Offset)
		elseif valueType == "UDim2" then
			return ("%s, %s, %s, %s"):format(value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset)
		elseif valueType == "BrickColor" then
			return tostring(value)
		end
		return ""
	end

	local function getEditPlaceholder(valueType)
		if valueType == "table" then
			return "Use ={ key = value } or edit child keys"
		elseif valueType == "function" then
			return "Use =function(...) ... end"
		elseif valueType == "Instance" then
			return "Use =game.Workspace.Part"
		elseif valueType == "string" then
			return "Text value; use =nil to set nil"
		end
		return "Value, nil, or =expression"
	end

	local function rebuildNodeName(node)
		local editableType = getEditableType(node)
		if not editableType then return end

		local suffix = ""
		if node.ValueType == "table" and type(node.Value) == "table" then
			suffix = getTableSummary(node.Value)
		end

		if editableType == "Upvalue" then
			local label = node.LabelName or ("upval_" .. tostring(node.Index))
			node.Name = ("[%d] %s%s"):format(node.Index or 0, label, suffix)
		elseif editableType == "Constant" then
			node.Name = ("[%d]%s"):format(node.Index or 0, suffix)
		elseif editableType == "TableValue" then
			node.Name = safeToString(node.Key, 90) .. ":" .. suffix
		end
	end

	local function getNodeFunction(node)
		if not node then return nil end
		if node.ValueType == "function" and typeof(node.Value) == "function" then
			return node.Value
		end
		if node.Type == "Function" and typeof(node.Func) == "function" then
			return node.Func
		end
	end

	local function getFunctionInfoSafe(func)
		local getinfo = (debug and debug.getinfo) or getinfo
		if getinfo then
			local ok, info = pcall(getinfo, func)
			if ok and type(info) == "table" then
				return info
			end
		end

		local info = {}
		if debug and debug.info then
			local okName, name = pcall(debug.info, func, "n")
			if okName then info.name = name end
			local okSource, source = pcall(debug.info, func, "s")
			if okSource then info.source = source end
			local okLine, lineDefined = pcall(debug.info, func, "l")
			if okLine then info.linedefined = lineDefined end
			local okArity, numparams, isVararg = pcall(debug.info, func, "a")
			if okArity then
				info.numparams = numparams
				info.is_vararg = isVararg
			end
		end
		return info
	end

	local function getFunctionBlockEntry(func, createEntry)
		if typeof(func) ~= "function" then return nil end
		local entry = functionBlockState.Blocks[func]
		if not entry and createEntry then
			entry = {
				Func = func,
				Blocked = false,
				Hooked = false,
				BlockedCalls = 0
			}
			functionBlockState.Blocks[func] = entry
		end
		return entry
	end

	local function getFunctionBlockTotals()
		local active = 0
		local hooked = 0
		local blockedCalls = functionBlockState.TotalBlockedCalls or 0
		for _, entry in next, functionBlockState.Blocks do
			if entry.Hooked then
				hooked = hooked + 1
			end
			if entry.Blocked then
				active = active + 1
			end
		end
		return active, hooked, blockedCalls, functionBlockState.BlockActions or 0, functionBlockState.UnblockActions or 0
	end

	local function buildStatusText()
		local text = ("Scanned: %d functions | Showing: %d items"):format(#allFunctions, #tree)
		local active, hooked, blockedCalls, blockActions, unblockActions = getFunctionBlockTotals()
		if hooked > 0 or blockActions > 0 or unblockActions > 0 or blockedCalls > 0 then
			text = text .. (" | Active blocks: %d | Blocked calls: %d | Block/Unblock: %d/%d"):format(active, blockedCalls, blockActions, unblockActions)
		end
		return text
	end

	local function requestBlockRefresh()
		if blockRefreshQueued then return end
		blockRefreshQueued = true
		local defer = task and task.defer
		local runLater = defer or function(fn)
			coroutine.wrap(fn)()
		end
		runLater(function()
			blockRefreshQueued = false
			if statusLabel then
				statusLabel.Text = buildStatusText()
			end
			if window and window.IsContentVisible and window:IsContentVisible() and FunctionDumper.Refresh then
				FunctionDumper.Refresh()
			end
		end)
	end

	local function getFunctionDisplayName(func, node)
		if node and node.Name then
			return safeToString(node.Name, 80)
		end
		local info = getFunctionInfoSafe(func)
		if info.name and info.name ~= "" then
			return safeToString(info.name, 80)
		end
		if info.linedefined and tonumber(info.linedefined) then
			return ("anonymous_line_%d"):format(info.linedefined)
		end
		return safeToString(func, 80)
	end

	local function getArgumentPlaceholder(func)
		local info = getFunctionInfoSafe(func)
		local count = tonumber(info.numparams) or 0
		local parts = {}
		for i = 1, count do
			parts[#parts + 1] = "args" .. tostring(i)
		end
		if #parts == 0 then
			return info.is_vararg and "args1, args2, ..." or "no args"
		end
		if info.is_vararg then
			parts[#parts + 1] = "..."
		end
		return table.concat(parts, ", ")
	end

	local function parseArgumentList(text)
		local expr = trim(text)
		if expr == "" then
			return true, {}
		end

		local loader = (env and env.loadstring) or loadstring
		if not loader then
			return false, "loadstring is not available"
		end

		local chunk, compileErr = loader("return " .. expr)
		if not chunk then
			return false, "Compile error: " .. tostring(compileErr)
		end

		local results = {pcall(chunk)}
		if not results[1] then
			return false, "Execution error: " .. tostring(results[2])
		end
		table.remove(results, 1)
		return true, results
	end

	local function formatReturnValues(values)
		if #values == 0 then
			return "no returns"
		end

		local parts = {}
		local maxValues = math.min(#values, 5)
		for i = 1, maxValues do
			local value = values[i]
			parts[#parts + 1] = ("<%s> %s"):format(typeof(value), formatValue(value, typeof(value)))
		end
		if #values > maxValues then
			parts[#parts + 1] = ("... %d more"):format(#values - maxValues)
		end
		return table.concat(parts, ", ")
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
					local upValText = ""
					if vType == "table" then
						upValText = getTableSummary(val)
					end
					local upNode = {
						Name = ("[%d] %s%s"):format(idx, name, upValText),
						Type = "Upvalue",
						Depth = depth + 1,
						Expanded = false,
						Parent = upvaluesFolder,
						Children = {},
						Index = idx,
						Value = val,
						ValueType = vType,
						Func = func,
						OwnerFunc = func,
						EditableType = "Upvalue",
						LabelName = name
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
					Children = {},
					Func = func
				}
				constantsFolder.Path = node.Path .. "/Constants"

				for idx, val in next, consts do
					local vType = typeof(val)
					local conValText = ""
					if vType == "table" then
						conValText = getTableSummary(val)
					end
					local conNode = {
						Name = ("[%d]%s"):format(idx, conValText),
						Type = "Constant",
						Depth = depth + 1,
						Expanded = false,
						Parent = constantsFolder,
						Children = {},
						Index = idx,
						Value = val,
						ValueType = vType,
						Func = func,
						OwnerFunc = func,
						EditableType = "Constant"
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

			-- 4. Prototypes Folder
			local protosList = {}
			local getprotos = (debug and debug.getprotos) or getprotos
			if getprotos then
				local s4, protos = pcall(getprotos, func)
				if s4 and protos and #protos > 0 then
					local protosFolder = {
						Name = "Prototypes (" .. #protos .. ")",
						Type = "PrototypesFolder",
						Depth = depth,
						Expanded = expandedByPath[node.Path .. "/Prototypes"] or false,
						Parent = node,
						Children = {}
					}
					protosFolder.Path = node.Path .. "/Prototypes"

					for idx, pFunc in next, protos do
						local pName = resolvedNames[pFunc]
						local rawName = "anonymous"
						pcall(function()
							local inf = getinfo(pFunc)
							rawName = inf.name ~= "" and inf.name or ("anonymous_line_%d"):format(inf.linedefined or 0)
						end)

						if pName then
							pName = ("%s (%s)"):format(pName, rawName)
						else
							pName = rawName
						end

						local pNode = {
							Name = ("[%d] %s"):format(idx, pName),
							Type = "Function",
							Func = pFunc,
							Depth = depth + 1,
							Expanded = false,
							Children = {},
							ChildrenLoaded = false,
							Parent = protosFolder
						}
						pNode.Path = protosFolder.Path .. "/" .. idx
						protosList[#protosList + 1] = pNode
					end
					protosFolder.Children = protosList
					node.Children[#node.Children + 1] = protosFolder
				end
			end

		elseif node.Type == "Upvalue" or node.Type == "Constant" or node.Type == "TableValue" then
			-- If it's a function, treat it like a function
			if node.ValueType == "function" then
				node.EditableType = node.EditableType or node.Type
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
					local tbValText = ""
					if vType == "table" then
						tbValText = getTableSummary(v)
					end
					local tbVal = {
						Name = safeToString(k, 90) .. ":" .. tbValText,
						Type = "TableValue",
						Depth = depth,
						Expanded = false,
						Parent = node,
						Children = {},
						Value = v,
						ValueType = vType,
						Key = k,
						OwnerFunc = node.OwnerFunc or node.Func,
						EditableType = "TableValue"
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
		statusLabel.Text = buildStatusText()
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

	local function getOwnerFunction(node)
		local curr = node
		while curr do
			if curr.OwnerFunc then
				return curr.OwnerFunc
			end
			if (curr.Type == "Upvalue" or curr.Type == "Constant") and curr.Func then
				return curr.Func
			end
			curr = curr.Parent
		end
	end

	local function getTableWriteTarget(node)
		local pathKeys = {}
		local curr = node
		while curr and getEditableType(curr) == "TableValue" do
			if curr.Key == nil then
				return nil, nil, "missing table key metadata"
			end
			table.insert(pathKeys, 1, curr.Key)
			curr = curr.Parent
		end

		if not curr or type(curr.Value) ~= "table" then
			return nil, nil, "root node is not a table"
		end

		local targetTbl = curr.Value
		for i = 1, #pathKeys - 1 do
			targetTbl = targetTbl[pathKeys[i]]
			if type(targetTbl) ~= "table" then
				return nil, nil, "could not trace parent table path"
			end
		end

		return targetTbl, pathKeys[#pathKeys]
	end

	local function syncEditedNode(node, newValue)
		local editableType = getEditableType(node)
		node.Value = newValue
		node.ValueType = typeof(newValue)
		node.Children = {}
		node.ChildrenLoaded = false
		rebuildNodeName(node)

		if editableType then
			if node.ValueType == "function" then
				node.EditableType = editableType
				node.Type = "Function"
				node.Func = newValue
			else
				node.Type = editableType
				node.Func = node.OwnerFunc
			end
		end

		local curr = node.Parent
		while curr do
			rebuildNodeName(curr)
			curr = curr.Parent
		end
	end

	FunctionDumper.ApplyNodeEdit = function(node, newValue)
		local editableType = getEditableType(node)
		if not editableType then
			return false, "node is not editable"
		end

		local success, err
		if editableType == "Upvalue" then
			local ownerFunc = getOwnerFunction(node)
			local setupvalue = (debug and debug.setupvalue) or setupvalue or setupval
			if ownerFunc and setupvalue then
				success, err = pcall(setupvalue, ownerFunc, node.Index, newValue)
			else
				success, err = false, "debug.setupvalue is not supported by your executor"
			end
		elseif editableType == "Constant" then
			local ownerFunc = getOwnerFunction(node)
			local setconstant = (debug and debug.setconstant) or setconstant or setconst
			if ownerFunc and setconstant then
				success, err = pcall(setconstant, ownerFunc, node.Index, newValue)
			else
				success, err = false, "debug.setconstant is not supported by your executor"
			end
		elseif editableType == "TableValue" then
			local targetTbl, key, tableErr = getTableWriteTarget(node)
			if targetTbl ~= nil and key ~= nil then
				success, err = pcall(function()
					targetTbl[key] = newValue
				end)
			else
				success, err = false, tableErr or "could not find table key"
			end
		end

		if success then
			local parent = node.Parent
			syncEditedNode(node, newValue)
			if editableType == "TableValue" and newValue == nil and parent then
				parent.ChildrenLoaded = false
				parent.Children = {}
			end
			selectedNode = node
			FunctionDumper.Flatten()
			FunctionDumper.UpdateView()
			FunctionDumper.Refresh()
			if statusLabel then
				statusLabel.Text = ("Edited %s -> <%s> %s"):format(editableType, typeof(newValue), formatValue(newValue, typeof(newValue)))
			end
			return true
		end

		warn("[Axon Dumper] Failed to modify: " .. tostring(err))
		if statusLabel then
			statusLabel.Text = "Edit failed: " .. tostring(err)
		end
		return false, err
	end

	FunctionDumper.BlockFunction = function(func, node)
		if typeof(func) ~= "function" then
			return false, "selected node is not a function"
		end

		local hook = (env and (env.hookfunction or env.replaceclosure)) or hookfunction or replaceclosure
		if not hook then
			local err = "hookfunction/replaceclosure is not supported by your executor"
			if statusLabel then statusLabel.Text = "Block failed: " .. err end
			warn("[Axon Dumper] " .. err)
			return false, err
		end

		local entry = getFunctionBlockEntry(func, true)
		if not entry.Hooked then
			local replacement = function(...)
				if entry.Blocked then
					entry.BlockedCalls = (entry.BlockedCalls or 0) + 1
					functionBlockState.TotalBlockedCalls = (functionBlockState.TotalBlockedCalls or 0) + 1
					requestBlockRefresh()
					return nil
				end
				if typeof(entry.Original) == "function" then
					return entry.Original(...)
				end
				return nil
			end

			local replacementClosure = replacement
			local newClosure = (env and env.newcclosure) or newcclosure
			if newClosure then
				local closureOk, wrapped = pcall(newClosure, replacement)
				if closureOk and typeof(wrapped) == "function" then
					replacementClosure = wrapped
				end
			end

			local hookOk, originalOrErr = pcall(hook, func, replacementClosure)
			if not hookOk then
				if statusLabel then statusLabel.Text = "Block failed: " .. tostring(originalOrErr) end
				warn("[Axon Dumper] Failed to hook function: " .. tostring(originalOrErr))
				return false, originalOrErr
			end

			if typeof(originalOrErr) == "function" then
				entry.Original = originalOrErr
			end
			entry.Hooked = true
			entry.Name = getFunctionDisplayName(func, node)
		end

		if not entry.Blocked then
			entry.Blocked = true
			functionBlockState.BlockActions = (functionBlockState.BlockActions or 0) + 1
		end

		if statusLabel then
			local active, _, blockedCalls, blockActions, unblockActions = getFunctionBlockTotals()
			statusLabel.Text = ("Blocked: %s | Active: %d | Blocked calls: %d | Block/Unblock: %d/%d"):format(getFunctionDisplayName(func, node), active, blockedCalls, blockActions, unblockActions)
		end
		FunctionDumper.Refresh()
		return true
	end

	FunctionDumper.UnblockFunction = function(func, node)
		local entry = getFunctionBlockEntry(func, false)
		if not entry then
			return false, "function is not blocked"
		end

		if entry.Blocked then
			entry.Blocked = false
			functionBlockState.UnblockActions = (functionBlockState.UnblockActions or 0) + 1
		end

		if statusLabel then
			local active, _, blockedCalls, blockActions, unblockActions = getFunctionBlockTotals()
			statusLabel.Text = ("Unblocked: %s | Active: %d | Blocked calls: %d | Block/Unblock: %d/%d"):format(getFunctionDisplayName(func, node), active, blockedCalls, blockActions, unblockActions)
		end
		FunctionDumper.Refresh()
		return true
	end

	FunctionDumper.PromptCallFunction = function(func, node)
		if typeof(func) ~= "function" then return end
		local win = FunctionDumper.CallPromptWindow
		if not win then return end

		lastCallTarget = {Func = func, Node = node}
		local placeholder = getArgumentPlaceholder(func)
		win:SetTitle("Call " .. getFunctionDisplayName(func, node))
		win.Elements.ErrorLabel.Text = ""
		win.Elements.InputBox:SetText("")
		win.Elements.InputBox.TextBox.PlaceholderText = placeholder
		win.Elements.InputBox.TextBox.PlaceholderColor3 = Settings.Theme.PlaceholderText

		if functionCallConn then
			functionCallConn:Disconnect()
			functionCallConn = nil
		end

		functionCallConn = win.Elements.CallButton.OnClick:Connect(function()
			if not lastCallTarget or typeof(lastCallTarget.Func) ~= "function" then
				win.Elements.ErrorLabel.Text = "No function selected"
				return
			end

			local okArgs, argsOrErr = parseArgumentList(win.Elements.InputBox:GetText())
			if not okArgs then
				win.Elements.ErrorLabel.Text = tostring(argsOrErr)
				return
			end

			local args = argsOrErr
			local unpackValues = unpack or table.unpack
			local results = {pcall(lastCallTarget.Func, unpackValues(args))}
			if not results[1] then
				win.Elements.ErrorLabel.Text = "Call error: " .. tostring(results[2])
				return
			end
			table.remove(results, 1)

			local resultText = formatReturnValues(results)
			print("[FunctionDumper] Call returned: " .. resultText)
			if statusLabel then
				statusLabel.Text = ("Call returned %d value(s): %s"):format(#results, resultText)
			end
			win:Close()
		end)

		win:Show()
		pcall(function()
			win.Elements.InputBox.TextBox:CaptureFocus()
		end)
	end

	FunctionDumper.SetEditingNode = function(node, idx)
		editingNode = node
		local entry = listEntries[idx]
		if not entry then return end

		editBox.Text = valueToEditText(node.Value, node.ValueType)
		editBox.PlaceholderText = getEditPlaceholder(node.ValueType)
		if statusLabel then
			statusLabel.Text = ("Editing <%s>. Press Enter/check to apply; use =expression for complex values."):format(node.ValueType)
		end
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
				local nodeFunc = getNodeFunction(node)
				local blockEntry = nodeFunc and getFunctionBlockEntry(nodeFunc, false)
				local isBlocked = blockEntry and blockEntry.Blocked
				entry.Gui.Visible = true

				-- Layout placements
				entry.Name.Position = UDim2.new(0, depth * INDENT + NAME_OFF, 0, 0)
				entry.Name.Text = node.Name

				-- Format type indicators
				if node.Type == "Function" then
					entry.Name.TextColor3 = isBlocked and Color3.fromRGB(255, 95, 95) or theme.Text
					if isBlocked then
						local nameSize = service.TextService:GetTextSize(node.Name, 13, Enum.Font.Code, Vector2.new(9999, ROW_H)).X
						entry.Name.Size = UDim2.new(0, nameSize + 4, 1, 0)
						entry.ValueLabel.Position = UDim2.new(0, depth * INDENT + NAME_OFF + nameSize + 8, 0, 0)
						entry.ValueLabel.Size = UDim2.new(1, -(depth * INDENT + NAME_OFF + nameSize + 8) - 4, 1, 0)
						entry.ValueLabel.Text = ("BLOCKED (%d)"):format(blockEntry.BlockedCalls or 0)
						entry.ValueLabel.TextColor3 = Color3.fromRGB(255, 95, 95)
						entry.ValueLabel.Visible = true
					else
						entry.Name.Size = UDim2.new(1, -(depth * INDENT + NAME_OFF) - 2, 1, 0)
						entry.ValueLabel.Visible = false
					end
				elseif node.Type == "Upvalue" or node.Type == "Constant" or node.Type == "TableValue" or node.Type == "Metadata" then
					entry.Name.TextColor3 = isBlocked and Color3.fromRGB(255, 95, 95) or Color3.fromRGB(150, 150, 150)
					local nameSize = service.TextService:GetTextSize(node.Name, 13, Enum.Font.Code, Vector2.new(9999, ROW_H)).X
					entry.Name.Size = UDim2.new(0, nameSize + 4, 1, 0)

					entry.ValueLabel.Position = UDim2.new(0, depth * INDENT + NAME_OFF + nameSize + 8, 0, 0)
					entry.ValueLabel.Size = UDim2.new(1, -(depth * INDENT + NAME_OFF + nameSize + 8) - 4, 1, 0)
					if isBlocked then
						entry.ValueLabel.Text = ("BLOCKED (%d) "):format(blockEntry.BlockedCalls or 0) .. formatValue(node.Value, node.ValueType)
						entry.ValueLabel.TextColor3 = Color3.fromRGB(255, 95, 95)
					else
						entry.ValueLabel.Text = formatValue(node.Value, node.ValueType)
						entry.ValueLabel.TextColor3 = getTypeColor(node.ValueType)
					end
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
				else -- Folder nodes
					entry.Name.TextColor3 = Color3.fromRGB(180, 180, 180)
					entry.Name.Size = UDim2.new(1, -(depth * INDENT + NAME_OFF) - 2, 1, 0)
					entry.ValueLabel.Visible = false
				end

				-- Display proper Icons
				entry.Icon.Position = UDim2.new(0, depth * INDENT + ICON_OFF, 0, 2)
				local iconKey = "Empty"
				if node.Type == "Function" then iconKey = "ViewScript"
				elseif node.Type == "UpvaluesFolder" or node.Type == "ConstantsFolder" or node.Type == "MetadataFolder" or node.Type == "PrototypesFolder" then iconKey = "Group"
				elseif node.Type == "Upvalue" then iconKey = "Reference"
				elseif node.Type == "Constant" then iconKey = "SelectChildren"
				elseif node.Type == "Metadata" then iconKey = "ExploreData"
				elseif node.ValueType == "table" then iconKey = "Honey"
				elseif node.ValueType == "function" then iconKey = "CallFunction"
				end
				miscIcons:DisplayByKey(entry.Icon, iconKey)
				entry.Icon.ImageTransparency = (node.Type == "Function" or node.Type == "Upvalue") and 0 or 0.35
				entry.Icon.ImageColor3 = isBlocked and Color3.fromRGB(255, 95, 95) or Color3.new(1, 1, 1)

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
				elseif isBlocked then
					entry.Highlight.BackgroundColor3 = Color3.fromRGB(95, 20, 20)
					entry.Highlight.BackgroundTransparency = 0.58
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
		confirmBtn.Visible = editingVisible
	end

	FunctionDumper.ShowContext = function(position)
		if not selectedNode then return end
		context:Clear()

		local selectedFunc = getNodeFunction(selectedNode)
		if selectedFunc then
			context:Add({
				Name = "Call / Fire Function",
				IconMap = Main.MiscIcons,
				Icon = "CallFunction",
				OnClick = function()
					FunctionDumper.PromptCallFunction(selectedFunc, selectedNode)
				end
			})

			local blockEntry = getFunctionBlockEntry(selectedFunc, false)
			if blockEntry and blockEntry.Blocked then
				context:Add({
					Name = ("Unblock Function Calls (%d blocked)"):format(blockEntry.BlockedCalls or 0),
					IconMap = Main.MiscIcons,
					Icon = "Play",
					OnClick = function()
						FunctionDumper.UnblockFunction(selectedFunc, selectedNode)
					end
				})
			else
				context:Add({
					Name = "Block Function Calls",
					IconMap = Main.MiscIcons,
					Icon = "Delete",
					OnClick = function()
						FunctionDumper.BlockFunction(selectedFunc, selectedNode)
					end
				})
			end
			context:AddDivider()
		end

		if isEditableNode(selectedNode) then
			local labelName = "Edit Value"
			local editableType = getEditableType(selectedNode)
			if editableType == "Upvalue" then labelName = "Edit Upvalue"
			elseif editableType == "Constant" then labelName = "Edit Constant"
			elseif editableType == "TableValue" then labelName = "Edit Table Member"
			end
			context:Add({
				Name = labelName,
				IconMap = Main.MiscIcons,
				Icon = "Rename",
				OnClick = function()
					local idx = table.find(tree, selectedNode)
					if idx then
						FunctionDumper.SetEditingNode(selectedNode, idx - FunctionDumper.Index)
					end
				end
			})
			context:Add({
				Name = "Set nil",
				IconMap = Main.MiscIcons,
				Icon = "Delete",
				OnClick = function()
					FunctionDumper.ApplyNodeEdit(selectedNode, nil)
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
			local getinfo = (debug and (debug.getinfo or debug.info)) or getinfo
			local lineDefined = 1
			pcall(function()
				local info = getinfo(fNode.Func)
				if info and info.linedefined and info.linedefined > 0 then
					lineDefined = info.linedefined
				end
			end)

			context:Add({
				Name = "Go to Definition",
				IconMap = Main.MiscIcons,
				Icon = "Play",
				OnClick = function()
					if targetScript then
						ScriptViewer.ViewScript(targetScript, lineDefined)
					end
				end
			})
			context:Add({
				Name = "Decompile Script",
				IconMap = Main.MiscIcons,
				Icon = "ViewScript",
				OnClick = function()
					if targetScript then
						ScriptViewer.ViewScript(targetScript)
					end
				end
			})
			context:Add({
				Name = "Go to Script",
				IconMap = Main.MiscIcons,
				Icon = "JumpToParent",
				OnClick = function()
					if targetScript and nodes[targetScript] then
						selection:Set(nodes[targetScript])
						Explorer.ViewNode(nodes[targetScript])
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
				if isEditableNode(node) and node.ValueType ~= "table" and node.ValueType ~= "function" then
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

		confirmBtn = createSimple("TextButton", {
			BackgroundColor3 = Settings.Theme.Button,
			BorderSizePixel = 0,
			Font = Enum.Font.SourceSansBold,
			Text = "",
			Visible = false,
			ZIndex = 4
		})
		local btnStroke = createSimple("UIStroke", {
			Color = Settings.Theme.Outline2,
			Thickness = 1.4,
			Parent = confirmBtn
		})
		local btnCorner = createSimple("UICorner", {
			CornerRadius = UDim.new(0, 2),
			Parent = confirmBtn
		})
		local btnIcon = createSimple("ImageLabel", {
			Name = "Icon",
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 12, 0, 12),
			Position = UDim2.new(0.5, -6, 0.5, -6),
			Parent = confirmBtn
		})
		Main.MiscIcons:DisplayByKey(btnIcon, "Rename")
		confirmBtn.Parent = listFrame

		confirmBtn.MouseButton1Click:Connect(function()
			if editBox.Visible then
				editBox:ReleaseFocus(true)
			end
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

		local function updateEditPreview()
			if not editingNode or not editBox.Visible then return end
			local valueType = editingNode.ValueType
			if isExpressionEdit(editBox.Text, valueType) then
				editBox.TextColor3 = Settings.Theme.Text
				if statusLabel then
					statusLabel.Text = ("Editing <%s>. Expression will run when confirmed."):format(valueType)
				end
				return
			end

			local ok, valueOrErr = parseValue(editBox.Text, valueType, false)
			if ok then
				editBox.TextColor3 = Settings.Theme.Text
				if statusLabel then
					statusLabel.Text = ("Preview <%s>: %s"):format(typeof(valueOrErr), formatValue(valueOrErr, typeof(valueOrErr)))
				end
			else
				editBox.TextColor3 = Color3.fromRGB(255, 120, 120)
				if statusLabel then
					statusLabel.Text = "Edit parse error: " .. tostring(valueOrErr)
				end
			end
		end

		editBox:GetPropertyChangedSignal("Text"):Connect(updateEditPreview)

		editBox.FocusLost:Connect(function(enterPressed)
			if not editingNode then return end
			local node = editingNode
			if enterPressed then
				local ok, newValueOrErr = parseValue(editBox.Text, node.ValueType, true)
				if ok then
					FunctionDumper.ApplyNodeEdit(node, newValueOrErr)
				else
					warn("[Axon Dumper] Failed to parse edit: " .. tostring(newValueOrErr))
					if statusLabel then
						statusLabel.Text = "Edit parse error: " .. tostring(newValueOrErr)
					end
				end
			end
			editBox.TextColor3 = Settings.Theme.Text
			editBox.Visible = false
			confirmBtn.Visible = false
			editingNode = nil
			FunctionDumper.Refresh()
		end)

		editBox.Focused:Connect(function()
			editBox.SelectionStart = 1
			editBox.CursorPosition = #editBox.Text + 1
		end)
	end

	FunctionDumper.InitCallPromptWindow = function()
		local win = Lib.Window.new()
		win.Alignable = false
		win.Resizable = false
		win:SetTitle("Call Function")
		win:SetSize(360, 125)

		local label = Lib.Label.new()
		label.Text = "Arguments (Luau return list):"
		label.Position = UDim2.new(0, 10, 0, 10)
		label.Size = UDim2.new(1, -20, 0, 20)
		win:Add(label)

		local inputFrame = Lib.ViewportTextBox.new()
		inputFrame.Position = UDim2.new(0, 10, 0, 35)
		inputFrame.Size = UDim2.new(1, -20, 0, 20)
		inputFrame.TextBox.PlaceholderColor3 = Settings.Theme.PlaceholderText
		inputFrame.TextBox.PlaceholderText = "args1, args2"
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
		cancelButton.OnClick:Connect(function()
			win:Close()
		end)
		win:Add(cancelButton)

		local callButton = Lib.Button.new()
		callButton.AnchorPoint = Vector2.new(0, 1)
		callButton.Text = "Call"
		callButton.Position = UDim2.new(0.5, 5, 1, -5)
		callButton.Size = UDim2.new(0.5, -10, 0, 20)
		win:Add(callButton, "CallButton")

		FunctionDumper.CallPromptWindow = win
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
		table.clear(resolvedNames)
		tree = {}
		FunctionDumper.Flatten()
		FunctionDumper.UpdateView()
		FunctionDumper.Refresh()

		scanThread = coroutine.create(function()
			local gc = env.getgc()
			local start = tick()
			local getinfo = (debug and (debug.getinfo or debug.info)) or getinfo
			local getupvalues = (debug and debug.getupvalues) or getupvalues or getupvals
			local getprotos = (debug and debug.getprotos) or getprotos

			-- Pre-scan name resolution mapping
			local function scanFuncNames(f)
				if myScanId ~= currentScanId then return end
				-- Walk upvalues
				local s, ups = pcall(getupvalues, f)
				if s and ups then
					for k, v in next, ups do
						if typeof(v) == "function" then
							if not resolvedNames[v] then
								local name = "upval_" .. tostring(k)
								pcall(function()
									-- Try to get real variable name of upvalue if getinfo provides it
									local inf = getinfo(f)
								end)
								resolvedNames[v] = name
								scanFuncNames(v)
							end
						elseif typeof(v) == "table" then
							local count = 0
							for tk, tv in next, v do
								count = count + 1
								if count > 50 then break end
								if typeof(tv) == "function" then
									if not resolvedNames[tv] then
										resolvedNames[tv] = tostring(tk)
										scanFuncNames(tv)
									end
								end
							end
						end
					end
				end
				-- Walk protos
				if getprotos then
					local s2, pts = pcall(getprotos, f)
					if s2 and pts then
						for idx, pf in next, pts do
							if not resolvedNames[pf] then
								local pName = "proto_" .. idx
								resolvedNames[pf] = pName
								scanFuncNames(pf)
							end
						end
					end
				end
			end

			-- Find functions belonging to script first
			local scriptFuncs = {}
			for i = 1, #gc do
				if myScanId ~= currentScanId then return end
				local val = gc[i]
				if typeof(val) == "function" then
					local s, envTable = pcall(getfenv, val)
					if s and envTable.script == scr then
						scriptFuncs[#scriptFuncs + 1] = val
					end
				end

				if tick() - start > 0.015 then
					statusLabel.Text = ("Pre-scanning GC... %d%%"):format(math.floor((i / #gc) * 50))
					task.wait()
					start = tick()
				end
			end

			-- Resolve names
			for i = 1, #scriptFuncs do
				if myScanId ~= currentScanId then return end
				scanFuncNames(scriptFuncs[i])
				if tick() - start > 0.015 then
					statusLabel.Text = ("Resolving names... %d%%"):format(math.floor((i / #scriptFuncs) * 30) + 50)
					task.wait()
					start = tick()
				end
			end

			-- Build tree nodes
			for i = 1, #scriptFuncs do
				if myScanId ~= currentScanId then return end
				local val = scriptFuncs[i]
				local pName = resolvedNames[val]
				local rawName = "anonymous"
				pcall(function()
					local inf = getinfo(val)
					rawName = inf.name ~= "" and inf.name or ("anonymous_line_%d"):format(inf.linedefined or 0)
				end)

				local name = rawName
				if pName then
					name = ("%s (%s)"):format(pName, rawName)
				end

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

				if tick() - start > 0.015 then
					statusLabel.Text = ("Populating Tree... %d%%"):format(math.floor((i / #scriptFuncs) * 20) + 80)
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
		FunctionDumper.InitCallPromptWindow()
	end

	FunctionDumper.SelectFunction = function(targetFunc)
		for i = 1, #allFunctions do
			local node = allFunctions[i]
			if node.Func == targetFunc then
				FunctionDumper.SetSelected(node)
				local parent = node.Parent
				while parent do
					parent.Expanded = true
					parent = parent.Parent
				end
				FunctionDumper.Flatten()
				FunctionDumper.UpdateView()
				FunctionDumper.Refresh()

				local idx = table.find(tree, node)
				if idx then
					scrollV:ScrollTo(idx - 1)
				end
				break
			end
		end
	end

	return FunctionDumper
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
