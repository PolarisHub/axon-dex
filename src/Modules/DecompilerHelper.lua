--[[
	Axon · Modules/DecompilerHelper
	Advanced Decompiler Assistant & Code Refactoring Suite
	
	Features:
	- Safe Lexical Tokenizer (preserves 100% whitespace & comments)
	- Token-Bound Local Symbol Renaming (no substring collision bugs)
	- Multi-Tab Split Sidebar GUI inside Notepad
	- Inter-script & Intra-script XREF (Cross-Reference) Finder
	- Function Body Extractor & Copy tool
	- Garbage Collector Closure Hook & Call Console
	- Constant & Literal Explorer
]]

local oldgame = oldgame or game
local game = workspace.Parent
local cloneref = cloneref

-- Common Containers
local Main, Lib, Apps, Settings
local Explorer, Properties, ScriptViewer, DecompilerHelper
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
	DecompilerHelper = appTable.DecompilerHelper
end

local function main()
	local DecompilerHelper = {}
	DecompilerHelper.Window = nil
	DecompilerHelper.Panel = nil
	DecompilerHelper.Active = false
	DecompilerHelper.OwnerScript = nil

	-- Layout constants
	local ROW_H = 18
	local TAB_H = 24
	local LINE_COLOR = Color3.fromRGB(60, 60, 60)

	-- Core Panel UI variables
	local sidePanel, tabFrame, contentFrame, statusText
	local currentTab = "XREFs"
	local activeWord = ""
	local activeLineIndex = 1
	local activeCodeFrame = nil

	-- Search Query
	local searchBox, query = nil, ""

	-- Tab 1: XREFs state
	local xrefList = {}
	local xrefScroll, xrefListFrame

	-- Tab 2: Call & Hook state
	local callConsoleFrame
	local targetGCClosure = nil
	local upvalsList = {}
	local upvalsScroll, upvalsListFrame
	local callArgInput, executeBtn, hookBtn, hookStatusLabel

	-- Tab 3: Constants state
	local constantsList = {}
	local constScroll, constListFrame

	-- Tab 4: Deobfuscator / Actions state
	local actionListFrame

	-- Style tokens
	local TYPE_COLORS = {
		Keyword = Color3.fromRGB(197, 134, 192),    -- Violet
		Identifier = Color3.fromRGB(220, 220, 220), -- White
		String = Color3.fromRGB(206, 145, 120),     -- Orange
		Number = Color3.fromRGB(181, 206, 168),     -- Light Green
		Operator = Color3.fromRGB(180, 180, 180),   -- Gray
		Comment = Color3.fromRGB(106, 153, 85),     -- Green
		Highlight = Color3.fromRGB(86, 156, 214),   -- Blue
	}

	-- Keywords dictionary
	local KEYWORDS = {
		["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
		["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
		["function"] = true, ["if"] = true, ["in"] = true, ["local"] = true,
		["nil"] = true, ["not"] = true, ["or"] = true, ["repeat"] = true,
		["return"] = true, ["then"] = true, ["true"] = true, ["until"] = true,
		["while"] = true, ["class"] = true, ["export"] = true, ["type"] = true,
		["typeof"] = true, ["self"] = true
	}

	-------------------------------------------------------------
	-- SECTION 1: LEXICAL TOKENIZER
	-------------------------------------------------------------
	local function tokenize(source)
		local tokens = {}
		local pos = 1
		local len = #source
		local sub = string.sub
		local byte = string.byte
		local find = string.find

		local function readString(quote)
			local start = pos
			pos = pos + 1
			while pos <= len do
				local char = sub(source, pos, pos)
				if char == "\\" then
					pos = pos + 2 -- skip escaped
				elseif char == quote then
					pos = pos + 1
					return sub(source, start, pos - 1)
				else
					pos = pos + 1
				end
			end
			return sub(source, start, len)
		end

		local function readLongString(eqCount)
			local start = pos
			pos = pos + 2 + eqCount
			local closing = "]" .. string.rep("=", eqCount) .. "]"
			local _, endPos = find(source, closing, pos, true)
			if endPos then
				pos = endPos + 1
				return sub(source, start, pos - 1)
			else
				pos = len + 1
				return sub(source, start, len)
			end
		end

		local function readComment()
			local start = pos
			pos = pos + 2
			-- check for long comment
			if sub(source, pos, pos) == "[" then
				local eqCount = 0
				local p = pos + 1
				while sub(source, p, p) == "=" do
					eqCount = eqCount + 1
					p = p + 1
				end
				if sub(source, p, p) == "[" then
					return readLongString(eqCount)
				end
			end
			-- standard single line comment
			local nextNL = find(source, "\n", pos, true)
			if nextNL then
				pos = nextNL
				return sub(source, start, pos - 1)
			else
				pos = len + 1
				return sub(source, start, len)
			end
		end

		while pos <= len do
			local char = sub(source, pos, pos)
			local b = byte(char)

			-- 1. Whitespace
			if char == " " or char == "\t" or char == "\n" or char == "\r" then
				local start = pos
				pos = pos + 1
				while pos <= len do
					local c = sub(source, pos, pos)
					if c == " " or c == "\t" or c == "\n" or c == "\r" then
						pos = pos + 1
					else
						break
					end
				end
				tokens[#tokens + 1] = {
					Type = "Whitespace",
					Value = sub(source, start, pos - 1)
				}

			-- 2. Comments
			elseif char == "-" and sub(source, pos + 1, pos + 1) == "-" then
				local content = readComment()
				tokens[#tokens + 1] = {
					Type = "Comment",
					Value = content
				}

			-- 3. Strings
			elseif char == '"' or char == "'" then
				local content = readString(char)
				tokens[#tokens + 1] = {
					Type = "String",
					Value = content
				}
			elseif char == "[" and sub(source, pos + 1, pos + 1) == "[" then
				local content = readLongString(0)
				tokens[#tokens + 1] = {
					Type = "String",
					Value = content
				}
			elseif char == "[" and sub(source, pos + 1, pos + 1) == "=" then
				local eqCount = 0
				local p = pos + 1
				while sub(source, p, p) == "=" do
					eqCount = eqCount + 1
					p = p + 1
				end
				if sub(source, p, p) == "[" then
					local content = readLongString(eqCount)
					tokens[#tokens + 1] = {
						Type = "String",
						Value = content
					}
				else
					tokens[#tokens + 1] = {
						Type = "Operator",
						Value = char
					}
					pos = pos + 1
				end

			-- 4. Identifiers & Keywords
			elseif (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or char == "_" then
				local start = pos
				pos = pos + 1
				while pos <= len do
					local c = sub(source, pos, pos)
					local cb = byte(c)
					if cb and ((cb >= 65 and cb <= 90) or (cb >= 97 and cb <= 122) or (cb >= 48 and cb <= 57) or c == "_") then
						pos = pos + 1
					else
						break
					end
				end
				local val = sub(source, start, pos - 1)
				tokens[#tokens + 1] = {
					Type = KEYWORDS[val] and "Keyword" or "Identifier",
					Value = val
				}

			-- 5. Numbers
			elseif (b >= 48 and b <= 57) or (char == "." and byte(sub(source, pos + 1, pos + 1)) and byte(sub(source, pos + 1, pos + 1)) >= 48 and byte(sub(source, pos + 1, pos + 1)) <= 57) then
				local start = pos
				pos = pos + 1
				local isHex = false
				if char == "0" and (sub(source, pos, pos) == "x" or sub(source, pos, pos) == "X") then
					isHex = true
					pos = pos + 1
				end
				while pos <= len do
					local c = sub(source, pos, pos)
					local cb = byte(c)
					if not cb then break end
					if isHex then
						if (cb >= 48 and cb <= 57) or (cb >= 65 and cb <= 70) or (cb >= 97 and cb <= 102) then
							pos = pos + 1
						else
							break
						end
					else
						if (cb >= 48 and cb <= 57) or c == "." or c == "e" or c == "E" or c == "+" or c == "-" then
							pos = pos + 1
						else
							break
						end
					end
				end
				tokens[#tokens + 1] = {
					Type = "Number",
					Value = sub(source, start, pos - 1)
				}

			-- 6. Operators
			else
				tokens[#tokens + 1] = {
					Type = "Operator",
					Value = char
				}
				pos = pos + 1
			end
		end
		return tokens
	end

	local function rebuildSource(tokens)
		local t = {}
		for i = 1, #tokens do
			t[i] = tokens[i].Value
		end
		return table.concat(t, "")
	end

	-------------------------------------------------------------
	-- SECTION 2: CORE REFACTORING TOOLS
	-------------------------------------------------------------
	
	-- Safe Token-Bound Variable / Symbol Renamer
	DecompilerHelper.RenameSymbol = function(oldWord, codeFrame)
		if oldWord == "" or not codeFrame then return end
		if KEYWORDS[oldWord] then
			warn("[DecompilerHelper] Cannot rename reserved Lua keyword.")
			return
		end

		-- Prompt user for a new name using standard Roblox GUI prompts
		local newWord = nil
		local done = false
		local function promptName()
			local screenGui = create({
				{1, "ScreenGui", {Name = "RenamePrompt", ZIndexBehavior = 1}},
				{2, "Frame", {Active = true, BackgroundColor3 = Settings.Theme.Main2, BorderSizePixel = 0, Name = "Main", Parent = 1, Position = UDim2.new(0.5, -150, 0.5, -50), Size = UDim2.new(0, 300, 0, 100)}},
				{3, "UICorner", {CornerRadius = UDim.new(0, 6), Parent = 2}},
				{4, "UIStroke", {Color = Settings.Theme.Outline1, Parent = 2}},
				{5, "TextLabel", {BackgroundTransparency = 1, Font = Enum.Font.SourceSansBold, Position = UDim2.new(0, 10, 0, 5), Size = UDim2.new(1, -20, 0, 20), Text = "Rename Symbol: " .. oldWord, TextColor3 = Settings.Theme.Text, TextSize = 14, TextXAlignment = 0, Parent = 2}},
				{6, "TextBox", {BackgroundColor3 = Settings.Theme.TextBox, Font = Enum.Font.Code, Position = UDim2.new(0, 10, 0, 30), Size = UDim2.new(1, -20, 0, 24), Text = oldWord, TextColor3 = Settings.Theme.Text, TextSize = 13, Parent = 2}},
				{7, "TextButton", {BackgroundColor3 = Settings.Theme.Button, Font = Enum.Font.SourceSansBold, Position = UDim2.new(0.5, -60, 0, 65), Size = UDim2.new(0, 50, 0, 24), Text = "Rename", TextColor3 = Settings.Theme.Text, TextSize = 13, Parent = 2}},
				{8, "TextButton", {BackgroundColor3 = Settings.Theme.Button, Font = Enum.Font.SourceSansBold, Position = UDim2.new(0.5, 10, 0, 65), Size = UDim2.new(0, 50, 0, 24), Text = "Cancel", TextColor3 = Settings.Theme.Text, TextSize = 13, Parent = 2}},
			})
			createSimple("UICorner", {CornerRadius = UDim.new(0, 4), Parent = screenGui.Main.TextBox})
			createSimple("UIStroke", {Color = Settings.Theme.Outline2, Parent = screenGui.Main.TextBox})
			createSimple("UICorner", {CornerRadius = UDim.new(0, 4), Parent = screenGui.Main.TextButton})
			createSimple("UICorner", {CornerRadius = UDim.new(0, 4), Parent = screenGui.Main:GetChildren()[8]})

			local textBox = screenGui.Main.TextBox
			textBox:CaptureFocus()

			screenGui.Main.TextButton.MouseButton1Click:Connect(function()
				local t = textBox.Text:gsub("%s", "")
				if t ~= "" and t ~= oldWord then
					newWord = t
				end
				screenGui:Destroy()
				done = true
			end)

			screenGui.Main:GetChildren()[8].MouseButton1Click:Connect(function()
				screenGui:Destroy()
				done = true
			end)

			Lib.ShowGui(screenGui)
		end

		promptName()
		while not done do task.wait() end

		if not newWord then return end

		-- Run tokenizer
		local source = codeFrame:GetText()
		local tokens = tokenize(source)

		local count = 0
		for i = 1, #tokens do
			local t = tokens[i]
			if t.Type == "Identifier" and t.Value == oldWord then
				t.Value = newWord
				count = count + 1
			end
		end

		if count > 0 then
			local newSource = rebuildSource(tokens)
			codeFrame:SetText(newSource)
			warn(("[DecompilerHelper] Renamed %d occurrences of '%s' to '%s'."):format(count, oldWord, newWord))
			
			-- Refresh XREF list if currently shown
			if currentTab == "XREFs" and activeWord == oldWord then
				DecompilerHelper.ShowXRefs(newWord, activeLineIndex, codeFrame)
			end
		end
	end

	-- Bound-Safe Function Body Extractor
	DecompilerHelper.ExtractFunctionBody = function(funcName, codeFrame)
		if funcName == "" or not codeFrame then return end
		local source = codeFrame:GetText()
		local tokens = tokenize(source)

		-- Search for the start of the function definition
		local startTokenIdx = nil
		local matchedName = false

		for i = 1, #tokens do
			local t = tokens[i]
			if t.Type == "Keyword" and t.Value == "function" then
				-- Look forward to find name
				local nextIdx = i + 1
				while nextIdx <= #tokens and tokens[nextIdx].Type == "Whitespace" do
					nextIdx = nextIdx + 1
				end
				if nextIdx <= #tokens and tokens[nextIdx].Value == funcName then
					startTokenIdx = i
					matchedName = true
					break
				end
			elseif t.Type == "Identifier" and t.Value == funcName then
				-- Look forward for '=' and 'function' or look backward
				local nextIdx = i + 1
				while nextIdx <= #tokens and tokens[nextIdx].Type == "Whitespace" do
					nextIdx = nextIdx + 1
				end
				if nextIdx <= #tokens and tokens[nextIdx].Value == "=" then
					local funcIdx = nextIdx + 1
					while funcIdx <= #tokens and tokens[funcIdx].Type == "Whitespace" do
						funcIdx = funcIdx + 1
					end
					if funcIdx <= #tokens and tokens[funcIdx].Type == "Keyword" and tokens[funcIdx].Value == "function" then
						startTokenIdx = funcIdx
						matchedName = true
						break
					end
				end
			end
		end

		if not startTokenIdx then
			warn("[DecompilerHelper] Could not find function start index for: " .. funcName)
			return
		end

		-- Parse block depth to find matching 'end'
		local depth = 1
		local endTokenIdx = nil
		local blockOpeners = {
			["if"] = true, ["while"] = true, ["for"] = true, ["do"] = true, ["function"] = true
		}

		for idx = startTokenIdx + 1, #tokens do
			local t = tokens[idx]
			if t.Type == "Keyword" then
				if blockOpeners[t.Value] then
					depth = depth + 1
				elseif t.Value == "end" then
					depth = depth - 1
					if depth == 0 then
						endTokenIdx = idx
						break
					end
				end
			end
		end

		if startTokenIdx and endTokenIdx then
			local funcTokens = {}
			for i = startTokenIdx, endTokenIdx do
				funcTokens[#funcTokens + 1] = tokens[i]
			end
			local funcSource = rebuildSource(funcTokens)
			pcall(setclipboard or writeclipboard, funcSource)
			warn(("[DecompilerHelper] Extracted body of function '%s' to clipboard."):format(funcName))
		else
			warn("[DecompilerHelper] Unbalanced code block. Could not find corresponding 'end' for: " .. funcName)
		end
	end

	-------------------------------------------------------------
	-- SECTION 2.5: LEXICAL LUA CODE BEAUTIFIER ENGINE (~600 lines)
	-------------------------------------------------------------
	local function findFunctionTokenBounds(funcName, tokens)
		local startTokenIdx = nil
		for i = 1, #tokens do
			local t = tokens[i]
			if t.Type == "Keyword" and t.Value == "function" then
				local nextIdx = i + 1
				while nextIdx <= #tokens and tokens[nextIdx].Type == "Whitespace" do
					nextIdx = nextIdx + 1
				end
				if nextIdx <= #tokens and tokens[nextIdx].Value == funcName then
					startTokenIdx = i
					break
				end
			elseif t.Type == "Identifier" and t.Value == funcName then
				local nextIdx = i + 1
				while nextIdx <= #tokens and tokens[nextIdx].Type == "Whitespace" do
					nextIdx = nextIdx + 1
				end
				if nextIdx <= #tokens and tokens[nextIdx].Value == "=" then
					local funcIdx = nextIdx + 1
					while funcIdx <= #tokens and tokens[funcIdx].Type == "Whitespace" do
						funcIdx = funcIdx + 1
					end
					if funcIdx <= #tokens and tokens[funcIdx].Type == "Keyword" and tokens[funcIdx].Value == "function" then
						startTokenIdx = funcIdx
						break
					end
				end
			end
		end

		if not startTokenIdx then return nil, nil end

		local depth = 1
		local endTokenIdx = nil
		local blockOpeners = {
			["if"] = true, ["while"] = true, ["for"] = true, ["do"] = true, ["function"] = true
		}

		for idx = startTokenIdx + 1, #tokens do
			local t = tokens[idx]
			if t.Type == "Keyword" then
				if blockOpeners[t.Value] then
					depth = depth + 1
				elseif t.Value == "end" then
					depth = depth - 1
					if depth == 0 then
						endTokenIdx = idx
						break
					end
				end
			end
		end

		return startTokenIdx, endTokenIdx
	end

	local function beautifyTokens(subTokens, baseIndentStr)
		-- Formatting Configuration Options
		local OPT_INDENT_CHAR = "    " -- 4 spaces
		local OPT_SPACE_AROUND_OPS = true
		local OPT_SPACE_AFTER_COMMA = true
		local OPT_REMOVE_SEMICOLONS = true
		local OPT_MAX_LINE_LENGTH = 100
		local OPT_MAX_CONSECUTIVE_BLANKS = 1

		-- Token Stream Helper Class
		local Stream = {}
		Stream.__index = Stream
		function Stream.new(tList)
			local self = setmetatable({}, Stream)
			self.Tokens = {}
			for i = 1, #tList do
				if tList[i].Type ~= "Whitespace" then
					self.Tokens[#self.Tokens + 1] = tList[i]
				end
			end
			self.Index = 1
			self.Total = #self.Tokens
			return self
		end
		function Stream:peek(offset)
			offset = offset or 0
			local idx = self.Index + offset
			if idx > 0 and idx <= self.Total then
				return self.Tokens[idx]
			end
			return nil
		end
		function Stream:next()
			local tok = self:peek()
			self.Index = self.Index + 1
			return tok
		end
		function Stream:eof()
			return self.Index > self.Total
		end

		local stream = Stream.new(subTokens)

		-- Classification Helpers
		local BINARY_OPS = {
			["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["%"] = true, ["^"] = true,
			["="] = true, ["=="] = true, ["~="] = true, ["<="] = true, [">="] = true,
			["<"] = true, [">"] = true, [".."] = true, ["and"] = true, ["or"] = true
		}

		local function isUnaryOp(tok, prevTok)
			if not tok then return false end
			local val = tok.Value
			if val == "-" or val == "not" or val == "#" then
				if not prevTok then return true end
				local pVal = prevTok.Value
				local pType = prevTok.Type
				if BINARY_OPS[pVal] or pType == "Keyword" or pVal == "(" or pVal == "[" or pVal == "{" or pVal == "," or pVal == ";" then
					return true
				end
			end
			return false
		end

		-- Format Buffer
		local buffer = {}
		local indentLevel = 0
		local lineHasContent = false

		local function write(str)
			buffer[#buffer + 1] = str
			lineHasContent = true
		end

		local function writeIndent()
			write(baseIndentStr .. string.rep(OPT_INDENT_CHAR, indentLevel))
		end

		local function writeNewline()
			write("\n")
			lineHasContent = false
		end

		-- Parse tokens into statements for block structures
		local statements = {}
		local currentStmt = {}
		local parenDepth, braceDepth, bracketDepth = 0, 0, 0

		-- Keywords that always start a new statement
		local STMT_STARTERS = {
			["local"] = true, ["function"] = true, ["if"] = true, ["while"] = true,
			["for"] = true, ["repeat"] = true, ["return"] = true, ["break"] = true,
			["else"] = true, ["elseif"] = true, ["end"] = true, ["until"] = true
		}

		while not stream:eof() do
			local tok = stream:next()
			if tok.Value == "(" then parenDepth = parenDepth + 1
			elseif tok.Value == ")" then parenDepth = math.max(0, parenDepth - 1)
			elseif tok.Value == "{" then braceDepth = braceDepth + 1
			elseif tok.Value == "}" then braceDepth = math.max(0, braceDepth - 1)
			elseif tok.Value == "[" then bracketDepth = bracketDepth + 1
			elseif tok.Value == "]" then bracketDepth = math.max(0, bracketDepth - 1)
			end

			local isAtDepth0 = (parenDepth == 0 and braceDepth == 0 and bracketDepth == 0)
			if isAtDepth0 and #currentStmt > 0 then
				if tok.Value == ";" then
					if not OPT_REMOVE_SEMICOLONS then
						currentStmt[#currentStmt + 1] = tok
					end
					statements[#statements + 1] = currentStmt
					currentStmt = {}
					tok = nil
				elseif STMT_STARTERS[tok.Value] then
					statements[#statements + 1] = currentStmt
					currentStmt = {}
				end
			end

			if tok then
				currentStmt[#currentStmt + 1] = tok
			end
		end
		if #currentStmt > 0 then
			statements[#statements + 1] = currentStmt
		end

		-- Indentation state counters
		local OPENERS = {
			["do"] = true, ["then"] = true, ["repeat"] = true, ["function"] = true
		}
		local CLOSERS = {
			["end"] = true, ["until"] = true, ["else"] = true, ["elseif"] = true
		}

		-- Main formatting loop over statements
		local consecutiveBlanks = 0

		for sIdx = 1, #statements do
			local stmt = statements[sIdx]
			if #stmt == 0 then continue end

			-- Identify first token behavior (closers decrease indent before writing)
			local firstTok = stmt[1]
			local isCloser = CLOSERS[firstTok.Value]
			if isCloser then
				indentLevel = math.max(0, indentLevel - 1)
			end

			-- Blank line management
			if sIdx > 1 then
				local prevStmt = statements[sIdx - 1]
				if firstTok.Type == "Comment" or (prevStmt[1] and prevStmt[1].Type == "Comment") then
					if consecutiveBlanks < OPT_MAX_CONSECUTIVE_BLANKS then
						writeNewline()
						consecutiveBlanks = consecutiveBlanks + 1
					end
				else
					consecutiveBlanks = 0
				end
			end

			-- Write Statement line
			writeIndent()

			-- Inner token loop for spacing rules
			local stmtBraceDepth = 0
			local stmtParenDepth = 0

			for tIdx = 1, #stmt do
				local tok = stmt[tIdx]
				local prevTok = stmt[tIdx - 1]
				local nextTok = stmt[tIdx + 1]

				-- Handle nested multi-line tables
				if tok.Value == "{" then
					stmtBraceDepth = stmtBraceDepth + 1
					write("{")
					local isComplexTable = false
					local checkIdx = tIdx + 1
					local nestedCount = 0
					while checkIdx <= #stmt do
						local checkTok = stmt[checkIdx]
						if checkTok.Value == "}" then break end
						if checkTok.Value == "{" or checkTok.Value == "," then
							nestedCount = nestedCount + 1
						end
						checkIdx = checkIdx + 1
					end
					if nestedCount > 3 or string.len(rebuildSource(stmt)) > OPT_MAX_LINE_LENGTH then
						isComplexTable = true
					end

					if isComplexTable then
						indentLevel = indentLevel + 1
						writeNewline()
						writeIndent()
					end
				elseif tok.Value == "}" then
					stmtBraceDepth = math.max(0, stmtBraceDepth - 1)
					if prevTok and prevTok.Value ~= "{" then
						if indentLevel > 0 and prevTok.Value == "," or prevTok.Value == ";" then
							indentLevel = math.max(0, indentLevel - 1)
							writeNewline()
							writeIndent()
						end
					end
					write("}")
				elseif tok.Value == "," then
					write(",")
					if OPT_SPACE_AFTER_COMMA and nextTok and nextTok.Value ~= "}" then
						write(" ")
					end
				elseif tok.Value == ";" then
					write(";")
					if nextTok then write(" ") end
				else
					-- Standard spacing evaluation
					if prevTok and prevTok.Value ~= "{" and prevTok.Value ~= "," and prevTok.Value ~= ";" then
						local spacing = ""

						-- Dot/Colon accessors
						if tok.Value == "." or tok.Value == ":" or prevTok.Value == "." or prevTok.Value == ":" then
							spacing = ""
						-- Index access bracket spacing
						elseif tok.Value == "[" or prevTok.Value == "[" then
							spacing = ""
						elseif tok.Value == "]" or prevTok.Value == "]" then
							spacing = ""
						-- Function call spacing
						elseif tok.Value == "(" then
							if prevTok.Type == "Identifier" or prevTok.Value == ")" or prevTok.Value == "]" then
								spacing = ""
							else
								spacing = " "
							end
						-- Parentheses padding
						elseif tok.Value == ")" or prevTok.Value == "(" then
							spacing = ""
						-- Unary sign context
						elseif isUnaryOp(tok, prevTok) then
							spacing = " "
						-- Binary operators spacing
						elseif BINARY_OPS[tok.Value] or BINARY_OPS[prevTok.Value] then
							if OPT_SPACE_AROUND_OPS then
								spacing = " "
							end
						-- Keyword boundaries
						elseif prevTok.Type == "Keyword" or tok.Type == "Keyword" then
							spacing = " "
						end

						write(spacing)
					end

					write(tok.Value)
				end
			end

			writeNewline()

			-- Calculate trailing indentation shifts (openers increase indent)
			local stmtNetIndent = 0
			for tIdx = 1, #stmt do
				local tok = stmt[tIdx]
				if OPENERS[tok.Value] then
					stmtNetIndent = stmtNetIndent + 1
				elseif tok.Value == "end" then
					stmtNetIndent = math.max(0, stmtNetIndent - 1)
				end
			end

			indentLevel = indentLevel + stmtNetIndent

			if firstTok.Value == "else" or firstTok.Value == "elseif" then
				indentLevel = indentLevel + 1
			end
		end

		-- Clean up duplicate blank lines at line ends and return final text
		local rawFormatted = table.concat(buffer, "")
		local cleanedLines = {}
		local lines = string.split(rawFormatted, "\n")
		local lastLineWasEmpty = false

		for i = 1, #lines do
			local line = lines[i]:gsub("%s*$", "")
			if line == "" then
				if not lastLineWasEmpty then
					cleanedLines[#cleanedLines + 1] = line
					lastLineWasEmpty = true
				end
			else
				cleanedLines[#cleanedLines + 1] = line
				lastLineWasEmpty = false
			end
		end

		return table.concat(cleanedLines, "\n")
	end

	DecompilerHelper.BeautifyCode = function(codeFrame)
		if not codeFrame then return end
		local source = codeFrame:GetText()
		local tokens = tokenize(source)
		local formatted = beautifyTokens(tokens, "")
		codeFrame:SetText(formatted)
		warn("[DecompilerHelper] Source code formatted successfully.")
	end

	DecompilerHelper.BeautifyFunction = function(funcName, codeFrame)
		if funcName == "" or not codeFrame then return end
		local source = codeFrame:GetText()
		local tokens = tokenize(source)

		local startIdx, endIdx = findFunctionTokenBounds(funcName, tokens)
		if not startIdx or not endIdx then
			warn("[DecompilerHelper] Could not locate function body in the active editor for: " .. funcName)
			return
		end

		local funcTokens = {}
		for i = startIdx, endIdx do
			funcTokens[#funcTokens + 1] = tokens[i]
		end

		-- Determine base indentation level preceding the function definition
		local baseIndentStr = ""
		local pIdx = startIdx - 1
		if pIdx > 0 and tokens[pIdx].Type == "Whitespace" then
			local ws = tokens[pIdx].Value
			local lastNL = ws:match("\n([^\n]*)$")
			if lastNL then
				baseIndentStr = lastNL
			else
				baseIndentStr = ws
			end
		end

		local formattedFuncText = beautifyTokens(funcTokens, baseIndentStr)

		-- Construct the new tokens list replacing the function range with a single formatted string token
		local newTokens = {}
		for idx = 1, startIdx - 1 do
			newTokens[#newTokens + 1] = tokens[idx]
		end
		newTokens[#newTokens + 1] = {
			Type = "Whitespace",
			Value = formattedFuncText
		}
		for idx = endIdx + 1, #tokens do
			newTokens[#newTokens + 1] = tokens[idx]
		end

		local finalSource = rebuildSource(newTokens)
		codeFrame:SetText(finalSource)
		warn(("[DecompilerHelper] Function '%s' formatted successfully."):format(funcName))
	end

	-------------------------------------------------------------
	-- SECTION 3: INTERACTIVE CALL CONSOLE & CLOSURE SEARCH
	-------------------------------------------------------------
	local function updateUpvaluesList()
		if not targetGCClosure then return end
		table.clear(upvalsList)

		local getupvalues = (debug and debug.getupvalues) or getupvalues or getupvals
		local s, upvals = pcall(getupvalues, targetGCClosure)
		if s and upvals then
			for k, v in next, upvals do
				upvalsList[#upvalsList + 1] = {
					Index = k,
					Value = v,
					Type = typeof(v)
				}
			end
		end

		upvalsScroll.TotalSpace = #upvalsList
		upvalsScroll:Update()

		-- render rows
		local maxRows = math.max(math.ceil(upvalsListFrame.AbsoluteSize.Y / ROW_H), 0)
		for i = 1, maxRows do
			local idx = i + upvalsScroll.Index
			local item = upvalsList[idx]
			local rowName = "UpvalRow_" .. i
			local label = upvalsListFrame:FindFirstChild(rowName)
			if not label then
				label = createSimple("TextButton", {
					Name = rowName,
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
					Font = Enum.Font.Code,
					TextSize = 12,
					TextXAlignment = 0,
					Size = UDim2.new(1, 0, 0, ROW_H),
					Position = UDim2.new(0, 5, 0, (i - 1) * ROW_H),
					Parent = upvalsListFrame
				})
			end

			if item then
				local displayVal = tostring(item.Value)
				if item.Type == "string" then
					displayVal = '"' .. displayVal .. '"'
				end
				label.Text = ("[%d] upval_%d = %s (%s)"):format(item.Index, item.Index, displayVal, item.Type)
				label.TextColor3 = TYPE_COLORS[item.Type] or Color3.fromRGB(200, 200, 200)
				label.Visible = true
			else
				label.Visible = false
			end
		end
	end

	local function setupGCClosureConsole(funcName)
		targetGCClosure = nil
		local scr = DecompilerHelper.OwnerScript
		if not scr then return end

		local getgc = getgc or get_gc_objects
		local getinfo = (debug and (debug.getinfo or debug.info)) or getinfo
		if getgc then
			local gc = getgc()
			for i = 1, #gc do
				local val = gc[i]
				if typeof(val) == "function" then
					local s, envTable = pcall(getfenv, val)
					if s and envTable.script == scr then
						local s2, inf = pcall(getinfo, val)
						if s2 and inf and inf.name == funcName then
							targetGCClosure = val
							break
						end
					end
				end
			end
		end

		if targetGCClosure then
			hookStatusLabel.Text = ("Active closure found in memory: %s"):format(tostring(targetGCClosure))
			hookStatusLabel.TextColor3 = Color3.fromRGB(150, 220, 150)
			callArgInput.PlaceholderText = "arg1, arg2, ... (JSON / Lua types)"
			executeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
			hookBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
		else
			hookStatusLabel.Text = "No active closure found in GC context."
			hookStatusLabel.TextColor3 = Color3.fromRGB(220, 150, 150)
			callArgInput.PlaceholderText = "Not connected"
			executeBtn.TextColor3 = Color3.fromRGB(100, 100, 100)
			hookBtn.TextColor3 = Color3.fromRGB(100, 100, 100)
		end

		updateUpvaluesList()
	end

	local function callGCFunction()
		if not targetGCClosure then return end
		local rawArgs = callArgInput.Text
		local chunk = "return {" .. rawArgs .. "}"
		local s, loadFunc = pcall(loadstring, chunk)
		if not s or not loadFunc then
			warn("[DecompilerHelper] Failed to parse call arguments.")
			return
		end

		local s2, args = pcall(loadFunc)
		if not s2 or type(args) ~= "table" then
			warn("[DecompilerHelper] Arguments syntax error.")
			return
		end

		task.spawn(function()
			local ok, ret = xpcall(function()
				return {targetGCClosure(unpack(args))}
			end, function(e) return tostring(e) .. "\n" .. debug.traceback() end)

			if ok then
				local form = {}
				for k, v in ipairs(ret) do
					form[k] = tostring(v) .. " (" .. typeof(v) .. ")"
				end
				print(("[DecompilerHelper] Called %s. Return values: [%s]"):format(activeWord, table.concat(form, ", ")))
			else
				warn("[DecompilerHelper] Runtime execution error:\n" .. tostring(ret))
			end
		end)
	end

	local function hookGCFunction()
		if not targetGCClosure then return end
		local hook = hookfunction or replaceclosure
		if not hook then
			warn("[DecompilerHelper] Executor does not support hookfunction.")
			return
		end

		local original
		original = hook(targetGCClosure, function(...)
			local args = {...}
			local form = {}
			for k, v in ipairs(args) do
				form[k] = tostring(v) .. " (" .. typeof(v) .. ")"
			end
			print(("[DecompilerHelper] HOOK FIRE: %s called with args: [%s]"):format(activeWord, table.concat(form, ", ")))
			return original(...)
		end)
		warn("[DecompilerHelper] Hooked function: " .. activeWord)
	end

	-------------------------------------------------------------
	-- SECTION 4: TABS RENDERING
	-------------------------------------------------------------
	
	-- Tab 1: XREFs Browser
	DecompilerHelper.ShowXRefs = function(word, lineIndex, codeFrame)
		activeWord = word
		activeLineIndex = lineIndex
		activeCodeFrame = codeFrame
		DecompilerHelper.OwnerScript = codeFrame.OwnerScript

		table.clear(xrefList)

		-- Lex current code frame
		local source = codeFrame:GetText()
		local lines = string.split(source, "\n")

		local lq = query:lower()

		for idx, text in ipairs(lines) do
			if text:find("%f[%w_]" .. word .. "%f[^%w_]") then
				local matchLine = text:match("^%s*(.-)%s*$")
				if lq == "" or string.find(matchLine:lower(), lq, 1, true) ~= nil then
					xrefList[#xrefList + 1] = {
						Line = idx,
						Text = matchLine
					}
				end
			end
		end

		xrefScroll.TotalSpace = #xrefList
		xrefScroll:Update()

		-- render rows
		local maxRows = math.max(math.ceil(xrefListFrame.AbsoluteSize.Y / ROW_H), 0)
		for i = 1, maxRows do
			local idx = i + xrefScroll.Index
			local item = xrefList[idx]
			local rowName = "XRefRow_" .. i
			local rowBtn = xrefListFrame:FindFirstChild(rowName)
			if not rowBtn then
				rowBtn = createSimple("TextButton", {
					Name = rowName,
					BackgroundColor3 = Settings.Theme.Button,
					BorderSizePixel = 0,
					Font = Enum.Font.Code,
					TextSize = 12,
					TextXAlignment = 0,
					Size = UDim2.new(1, -6, 0, ROW_H - 2),
					Position = UDim2.new(0, 3, 0, (i - 1) * ROW_H),
					Parent = xrefListFrame
				})
				createSimple("UICorner", {CornerRadius = UDim.new(0, 3), Parent = rowBtn})

				rowBtn.MouseButton1Click:Connect(function()
					local targetIdx = i + xrefScroll.Index
					local xref = xrefList[targetIdx]
					if xref and activeCodeFrame then
						activeCodeFrame:MoveCursor(0, xref.Line - 1)
					end
				end)
			end

			if item then
				rowBtn.Text = ("  Line %d: %s"):format(item.Line, item.Text)
				rowBtn.TextColor3 = Settings.Theme.Text
				rowBtn.Visible = true
			else
				rowBtn.Visible = false
			end
		end

		statusText.Text = ("Word: '%s' | References: %d"):format(word, #xrefList)
	end

	-- Tab 3: Constant Literal Explorer
	local function updateConstantsExplorer()
		if not activeCodeFrame then return end
		table.clear(constantsList)

		local source = activeCodeFrame:GetText()
		local tokens = tokenize(source)

		local counts = {}
		for i = 1, #tokens do
			local t = tokens[i]
			if t.Type == "String" or t.Type == "Number" then
				counts[t.Value] = (counts[t.Value] or 0) + 1
			end
		end

		local lq = query:lower()

		for val, count in next, counts do
			if lq == "" or string.find(val:lower(), lq, 1, true) ~= nil then
				constantsList[#constantsList + 1] = {
					Value = val,
					Count = count,
					Type = tonumber(val) and "Number" or "String"
				}
			end
		end

		table.sort(constantsList, function(a, b)
			return a.Count > b.Count
		end)

		constScroll.TotalSpace = #constantsList
		constScroll:Update()

		local maxRows = math.max(math.ceil(constListFrame.AbsoluteSize.Y / ROW_H), 0)
		for i = 1, maxRows do
			local idx = i + constScroll.Index
			local item = constantsList[idx]
			local rowName = "ConstRow_" .. i
			local rowBtn = constListFrame:FindFirstChild(rowName)
			if not rowBtn then
				rowBtn = createSimple("TextButton", {
					Name = rowName,
					BackgroundColor3 = Settings.Theme.Button,
					BorderSizePixel = 0,
					Font = Enum.Font.Code,
					TextSize = 12,
					TextXAlignment = 0,
					Size = UDim2.new(1, -6, 0, ROW_H - 2),
					Position = UDim2.new(0, 3, 0, (i - 1) * ROW_H),
					Parent = constListFrame
				})
				createSimple("UICorner", {CornerRadius = UDim.new(0, 3), Parent = rowBtn})

				rowBtn.MouseButton1Click:Connect(function()
					local targetIdx = i + constScroll.Index
					local const = constantsList[targetIdx]
					if const and activeCodeFrame then
						-- Trigger xref search for constant
						DecompilerHelper.SelectTab("XREFs")
						DecompilerHelper.ShowXRefs(const.Value, activeLineIndex, activeCodeFrame)
					end
				end)
			end

			if item then
				local displayVal = item.Value
				if item.Type == "String" then
					displayVal = '"' .. displayVal .. '"'
				end
				rowBtn.Text = ("  %-10s : %s (%d references)"):format(item.Type, displayVal, item.Count)
				rowBtn.TextColor3 = TYPE_COLORS[item.Type] or Settings.Theme.Text
				rowBtn.Visible = true
			else
				rowBtn.Visible = false
			end
		end
	end

	-- Tab 4: Actions (Deobfuscator and extract helper)
	local function updateActionsList()
		local actions = {
			{
				Name = "Format Source Code",
				Desc = "Standardizes script indents, operator spacing, and block nesting structures",
				Func = function() DecompilerHelper.BeautifyCode(activeCodeFrame) end
			},
			{
				Name = "Rename Local Variable",
				Desc = "Renames the selected symbol safely using the tokenizer",
				Func = function() DecompilerHelper.RenameSymbol(activeWord, activeCodeFrame) end
			},
			{
				Name = "Extract Function Body",
				Desc = "Copies the complete block of the selected function",
				Func = function() DecompilerHelper.ExtractFunctionBody(activeWord, activeCodeFrame) end
			},
			{
				Name = "Auto-Deobfuscate Names",
				Desc = "Standardizes obfuscated variables (like v1, v2, etc.) to sequentials",
				Func = function()
					if not activeCodeFrame then return end
					local source = activeCodeFrame:GetText()
					local tokens = tokenize(source)

					local nameMap = {}
					local idx = 1
					for i = 1, #tokens do
						local t = tokens[i]
						if t.Type == "Identifier" and (t.Value:match("^v_%d+$") or t.Value:match("^v%d+$")) then
							if not nameMap[t.Value] then
								nameMap[t.Value] = "local_var_" .. idx
								idx = idx + 1
							end
							t.Value = nameMap[t.Value]
						end
					end

					local newSource = rebuildSource(tokens)
					activeCodeFrame:SetText(newSource)
					warn("[DecompilerHelper] Deobfuscator renamed: " .. (idx - 1) .. " identifiers.")
				end
			}
		}

		for idx, act in ipairs(actions) do
			local frameName = "ActionFrame_" .. idx
			local frame = actionListFrame:FindFirstChild(frameName)
			if not frame then
				frame = createSimple("Frame", {
					Name = frameName,
					BackgroundColor3 = Settings.Theme.Main2,
					Size = UDim2.new(1, -10, 0, 48),
					Position = UDim2.new(0, 5, 0, (idx - 1) * 52 + 5),
					Parent = actionListFrame
				})
				createSimple("UICorner", {CornerRadius = UDim.new(0, 4), Parent = frame})
				createSimple("UIStroke", {Color = Settings.Theme.Outline1, Parent = frame})

				local title = createSimple("TextLabel", {
					BackgroundTransparency = 1,
					Font = Enum.Font.SourceSansBold,
					TextSize = 13,
					TextColor3 = Settings.Theme.Text,
					TextXAlignment = 0,
					Position = UDim2.new(0, 8, 0, 4),
					Size = UDim2.new(1, -70, 0, 18),
					Parent = frame
				})
				local desc = createSimple("TextLabel", {
					BackgroundTransparency = 1,
					Font = Enum.Font.SourceSans,
					TextSize = 11,
					TextColor3 = Settings.Theme.PlaceholderText,
					TextWrapped = true,
					TextXAlignment = 0,
					Position = UDim2.new(0, 8, 0, 22),
					Size = UDim2.new(1, -70, 0, 22),
					Parent = frame
				})
				local btn = createSimple("TextButton", {
					BackgroundColor3 = Settings.Theme.ListSelection,
					Font = Enum.Font.SourceSansBold,
					Text = "Run",
					TextColor3 = Settings.Theme.Highlight,
					TextSize = 12,
					Position = UDim2.new(1, -58, 0.5, -12),
					Size = UDim2.new(0, 50, 0, 24),
					Parent = frame
				})
				createSimple("UICorner", {CornerRadius = UDim.new(0, 4), Parent = btn})

				btn.MouseButton1Click:Connect(act.Func)
			end

			local titleLabel = frame:GetChildren()[3]
			local descLabel = frame:GetChildren()[4]
			titleLabel.Text = act.Name
			descLabel.Text = act.Desc
		end
	end

	-------------------------------------------------------------
	-- TAB NAVIGATION & MANAGER
	-------------------------------------------------------------
	DecompilerHelper.SelectTab = function(tabName)
		currentTab = tabName
		for _, child in next, tabFrame:GetChildren() do
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

		contentFrame.XRefsPage.Visible = (tabName == "XREFs")
		contentFrame.ConsolePage.Visible = (tabName == "CallConsole")
		contentFrame.ConstantsPage.Visible = (tabName == "Constants")
		contentFrame.ActionsPage.Visible = (tabName == "Actions")

		searchBox.Visible = (tabName == "XREFs" or tabName == "Constants")

		if tabName == "XREFs" then
			DecompilerHelper.ShowXRefs(activeWord, activeLineIndex, activeCodeFrame)
		elseif tabName == "CallConsole" then
			setupGCClosureConsole(activeWord)
		elseif tabName == "Constants" then
			updateConstantsExplorer()
		elseif tabName == "Actions" then
			updateActionsList()
		end
	end

	-------------------------------------------------------------
	-- INITIALIZATION
	-------------------------------------------------------------
	DecompilerHelper.Init = function(parentContentFrame)
		local parent = parentContentFrame or (ScriptViewer and ScriptViewer.Window and ScriptViewer.Window.GuiElems.Content)
		if not parent then return end
		-- sidePanel will occupy the right 35% of the Notepad Content frame
		sidePanel = createSimple("Frame", {
			Name = "DecompilerHelperPanel",
			BackgroundColor3 = Settings.Theme.Main1,
			BorderSizePixel = 0,
			Position = UDim2.new(0.65, 0, 0, 20),
			Size = UDim2.new(0.35, 0, 1, -20),
			Visible = false,
			Parent = parent
		})
		DecompilerHelper.Panel = sidePanel

		local border = createSimple("Frame", {
			BackgroundColor3 = Settings.Theme.Outline1,
			BorderSizePixel = 0,
			Size = UDim2.new(0, 1, 1, 0),
			Parent = sidePanel
		})

		-- 1. Helper Header
		local header = createSimple("Frame", {
			Name = "Header",
			BackgroundColor3 = Settings.Theme.Main2,
			BorderSizePixel = 0,
			Position = UDim2.new(0, 1, 0, 0),
			Size = UDim2.new(1, -1, 0, 24),
			Parent = sidePanel
		})
		createSimple("TextLabel", {
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSansBold,
			Position = UDim2.new(0, 6, 0, 0),
			Size = UDim2.new(1, -30, 1, 0),
			Text = "Decompiler Assistant",
			TextColor3 = Settings.Theme.Text,
			TextSize = 13,
			TextXAlignment = 0,
			Parent = header
		})
		local closeBtn = createSimple("TextButton", {
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSansBold,
			Position = UDim2.new(1, -22, 0, 2),
			Size = UDim2.new(0, 20, 0, 20),
			Text = "X",
			TextColor3 = Settings.Theme.Text,
			TextSize = 13,
			Parent = header
		})
		closeBtn.MouseButton1Click:Connect(function()
			DecompilerHelper.Toggle(false)
		end)

		-- 2. Tabs Frame
		tabFrame = createSimple("Frame", {
			Name = "Tabs",
			BackgroundColor3 = Settings.Theme.Main2,
			BorderSizePixel = 0,
			Position = UDim2.new(0, 1, 0, 24),
			Size = UDim2.new(1, -1, 0, TAB_H),
			Parent = sidePanel
		})
		createSimple("Frame", {
			BackgroundColor3 = Settings.Theme.Outline1,
			BorderSizePixel = 0,
			Position = UDim2.new(0, 0, 1, -1),
			Size = UDim2.new(1, 0, 0, 1),
			Parent = tabFrame
		})

		local tabs = {"XREFs", "CallConsole", "Constants", "Actions"}
		for idx, name in ipairs(tabs) do
			local tabBtn = createSimple("TextButton", {
				Name = name,
				BackgroundColor3 = Settings.Theme.Button,
				BorderSizePixel = 0,
				Size = UDim2.new(0.25, 0, 1, -1),
				Position = UDim2.new(0.25 * (idx - 1), 0, 0, 0),
				Font = Enum.Font.SourceSansBold,
				Text = name == "CallConsole" and "Call" or name,
				TextColor3 = Settings.Theme.Text,
				TextSize = 12,
				Parent = tabFrame
			})
			tabBtn.MouseButton1Click:Connect(function()
				DecompilerHelper.SelectTab(name)
			end)
		end

		-- 3. Search Bar Frame
		local searchFrame = createSimple("Frame", {
			Name = "SearchFrame",
			BackgroundColor3 = Settings.Theme.TextBox,
			BorderSizePixel = 0,
			Position = UDim2.new(0, 4, 0, 24 + TAB_H + 3),
			Size = UDim2.new(1, -8, 0, 20),
			Parent = sidePanel
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 2), Parent = searchFrame})
		local searchStroke = createSimple("UIStroke", {Thickness = 1.2, Color = Settings.Theme.Outline3, Parent = searchFrame})

		searchBox = createSimple("TextBox", {
			BackgroundTransparency = 1,
			ClearTextOnFocus = false,
			Font = Enum.Font.SourceSans,
			PlaceholderColor3 = Settings.Theme.PlaceholderText,
			PlaceholderText = "Search list...",
			Position = UDim2.new(0, 4, 0, 0),
			Size = UDim2.new(1, -8, 0, 20),
			Text = "",
			TextColor3 = Settings.Theme.Text,
			TextSize = 13,
			TextXAlignment = 0,
			Parent = searchFrame
		})
		Lib.ViewportTextBox.convert(searchBox)
		searchBox:GetPropertyChangedSignal("Text"):Connect(function()
			query = searchBox.Text
			if currentTab == "XREFs" then
				DecompilerHelper.ShowXRefs(activeWord, activeLineIndex, activeCodeFrame)
			elseif currentTab == "Constants" then
				updateConstantsExplorer()
			end
		end)

		-- 4. Content Area
		contentFrame = createSimple("Frame", {
			Name = "ContentFrame",
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 1, 0, 24 + TAB_H + 26),
			Size = UDim2.new(1, -1, 1, -24 - TAB_H - 46),
			Parent = sidePanel
		})

		-- Tab 1 Content: XREFs Page
		local xrefsPage = createSimple("Frame", {
			Name = "XRefsPage",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 1, 0),
			Parent = contentFrame
		})
		xrefListFrame = createSimple("Frame", {
			Name = "XRefList",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -16, 1, 0),
			ClipsDescendants = true,
			Parent = xrefsPage
		})
		xrefScroll = Lib.ScrollBar.new()
		xrefScroll.WheelIncrement = 3
		xrefScroll.Gui.Position = UDim2.new(1, -16, 0, 0)
		xrefScroll.Gui.Size = UDim2.new(0, 16, 1, 0)
		xrefScroll:SetScrollFrame(xrefListFrame)
		xrefScroll.Gui.Parent = xrefsPage
		xrefScroll.Scrolled:Connect(function()
			DecompilerHelper.ShowXRefs(activeWord, activeLineIndex, activeCodeFrame)
		end)

		-- Tab 2 Content: GC Call Page
		local consolePage = createSimple("Frame", {
			Name = "ConsolePage",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 1, 0),
			Visible = false,
			Parent = contentFrame
		})
		
		hookStatusLabel = createSimple("TextLabel", {
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSansBold,
			Position = UDim2.new(0, 5, 0, 3),
			Size = UDim2.new(1, -10, 0, 18),
			Text = "Scanning environment memory...",
			TextColor3 = Settings.Theme.Text,
			TextSize = 12,
			TextXAlignment = 0,
			Parent = consolePage
		})

		-- Upvalues list container
		local upvalsHeader = createSimple("Frame", {
			BackgroundColor3 = Settings.Theme.Main2,
			BorderSizePixel = 0,
			Position = UDim2.new(0, 4, 0, 24),
			Size = UDim2.new(1, -8, 0, 18),
			Parent = consolePage
		})
		createSimple("TextLabel", {
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSansBold,
			Position = UDim2.new(0, 5, 0, 0),
			Size = UDim2.new(1, -10, 1, 0),
			Text = "Upvalues List",
			TextColor3 = Settings.Theme.Text,
			TextSize = 11,
			TextXAlignment = 0,
			Parent = upvalsHeader
		})

		upvalsListFrame = createSimple("Frame", {
			Name = "UpvalList",
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 4, 0, 44),
			Size = UDim2.new(1, -24, 0.45, -44),
			ClipsDescendants = true,
			Parent = consolePage
		})
		upvalsScroll = Lib.ScrollBar.new()
		upvalsScroll.WheelIncrement = 2
		upvalsScroll.Gui.Position = UDim2.new(1, -16, 0, 44)
		upvalsScroll.Gui.Size = UDim2.new(0, 16, 0.45, -44)
		upvalsScroll:SetScrollFrame(upvalsListFrame)
		upvalsScroll.Gui.Parent = consolePage
		upvalsScroll.Scrolled:Connect(updateUpvaluesList)

		-- Call Execution Console Box
		callConsoleFrame = createSimple("Frame", {
			Name = "ConsoleBox",
			BackgroundColor3 = Settings.Theme.TextBox,
			Position = UDim2.new(0, 4, 0.45, 6),
			Size = UDim2.new(1, -8, 0.55, -12),
			Parent = consolePage
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 4), Parent = callConsoleFrame})
		createSimple("UIStroke", {Color = Settings.Theme.Outline1, Parent = callConsoleFrame})

		callArgInput = createSimple("TextBox", {
			BackgroundColor3 = Settings.Theme.Main1,
			ClearTextOnFocus = false,
			Font = Enum.Font.Code,
			Position = UDim2.new(0, 5, 0, 6),
			Size = UDim2.new(1, -10, 0, 22),
			Text = "",
			TextColor3 = Settings.Theme.Text,
			TextSize = 12,
			TextXAlignment = 0,
			Parent = callConsoleFrame
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 3), Parent = callArgInput})
		createSimple("UIStroke", {Color = Settings.Theme.Outline2, Parent = callArgInput})

		executeBtn = createSimple("TextButton", {
			BackgroundColor3 = Settings.Theme.Button,
			Font = Enum.Font.SourceSansBold,
			Position = UDim2.new(0, 5, 0, 34),
			Size = UDim2.new(0.5, -8, 0, 24),
			Text = "Call Closure",
			TextColor3 = Settings.Theme.Text,
			TextSize = 12,
			Parent = callConsoleFrame
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 3), Parent = executeBtn})
		executeBtn.MouseButton1Click:Connect(callGCFunction)

		hookBtn = createSimple("TextButton", {
			BackgroundColor3 = Settings.Theme.Button,
			Font = Enum.Font.SourceSansBold,
			Position = UDim2.new(0.5, 3, 0, 34),
			Size = UDim2.new(0.5, -8, 0, 24),
			Text = "Hook Calls",
			TextColor3 = Settings.Theme.Text,
			TextSize = 12,
			Parent = callConsoleFrame
		})
		createSimple("UICorner", {CornerRadius = UDim.new(0, 3), Parent = hookBtn})
		hookBtn.MouseButton1Click:Connect(hookGCFunction)

		-- Tab 3 Content: Constants Page
		local constPage = createSimple("Frame", {
			Name = "ConstantsPage",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 1, 0),
			Visible = false,
			Parent = contentFrame
		})
		constListFrame = createSimple("Frame", {
			Name = "ConstList",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -16, 1, 0),
			ClipsDescendants = true,
			Parent = constPage
		})
		constScroll = Lib.ScrollBar.new()
		constScroll.WheelIncrement = 3
		constScroll.Gui.Position = UDim2.new(1, -16, 0, 0)
		constScroll.Gui.Size = UDim2.new(0, 16, 1, 0)
		constScroll:SetScrollFrame(constListFrame)
		constScroll.Gui.Parent = constPage
		constScroll.Scrolled:Connect(updateConstantsExplorer)

		-- Tab 4 Content: Actions Page
		local actsPage = createSimple("Frame", {
			Name = "ActionsPage",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 1, 0),
			Visible = false,
			Parent = contentFrame
		})
		actionListFrame = createSimple("Frame", {
			Name = "ActionList",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 1, 0),
			Parent = actsPage
		})

		-- Status footer
		statusText = createSimple("TextLabel", {
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSans,
			Position = UDim2.new(0, 6, 1, -20),
			Size = UDim2.new(1, -12, 0, 20),
			Text = "Ready",
			TextColor3 = Settings.Theme.PlaceholderText,
			TextSize = 12,
			TextXAlignment = 0,
			Parent = sidePanel
		})
		createSimple("Frame", {
			BackgroundColor3 = Settings.Theme.Outline1,
			BorderSizePixel = 0,
			Position = UDim2.new(0, 0, 0, 0),
			Size = UDim2.new(1, 0, 0, 1),
			Parent = statusText.Parent:FindFirstChild("StatusText") or statusText
		})

		-- Resize listener
		sidePanel:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if sidePanel.Visible then
				if currentTab == "XREFs" then
					DecompilerHelper.ShowXRefs(activeWord, activeLineIndex, activeCodeFrame)
				elseif currentTab == "CallConsole" then
					updateUpvaluesList()
				elseif currentTab == "Constants" then
					updateConstantsExplorer()
				end
			end
		end)
	end

	DecompilerHelper.Toggle = function(visible)
		DecompilerHelper.Active = visible
		if not sidePanel then return end

		sidePanel.Visible = visible
		
		-- Split pane resizing logic inside Notepad
		if ScriptViewer and ScriptViewer.codeFrame then
			local cFrame = ScriptViewer.codeFrame.Frame
			if visible then
				cFrame.Size = UDim2.new(0.65, 0, 1, -40)
			else
				cFrame.Size = UDim2.new(1, 0, 1, -40)
			end
		end

		if visible then
			DecompilerHelper.SelectTab(currentTab)
		end
	end

	return DecompilerHelper
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
