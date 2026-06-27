--[[
	Axon
	A remake of Dex++ (by Axon), itself a remake of Dex v3 (by Moon).

	Public entry point. Load the whole suite with a single loadstring:

		loadstring(game:HttpGet("https://raw.githubusercontent.com/PolarisHub/axon-dex/main/loader.lua"))()

	This file does nothing on its own except set up a tiny module loader that
	fetches the rest of the source from GitHub at runtime, so the codebase can
	live in many files while still being launched by one loadstring.
]]

local Config = {
	Owner  = "PolarisHub",
	Repo   = "axon-dex",
	Branch = "main",

	-- When true, a cache-buster is appended to every request so GitHub's CDN
	-- always serves the latest commit. Handy while iterating; flip to false
	-- for release builds to let the CDN cache do its job.
	DevMode = true,
}

local BaseUrl = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(
	Config.Owner, Config.Repo, Config.Branch
)

-- Resolve a global environment table across executors.
local genv = (getgenv and getgenv()) or _G

local crcTable
local function hashText32(text)
	if type(text) ~= "string" or not bit32 then
		return tostring(type(text) == "string" and #text or 0)
	end

	if not crcTable then
		local bxor, band, rshift = bit32.bxor, bit32.band, bit32.rshift
		crcTable = {}
		for byte = 0, 255 do
			local crc = byte
			for _ = 1, 8 do
				if band(crc, 1) ~= 0 then
					crc = bxor(0xEDB88320, rshift(crc, 1))
				else
					crc = rshift(crc, 1)
				end
			end
			crcTable[byte] = crc
		end
	end

	local bxor, band, rshift = bit32.bxor, bit32.band, bit32.rshift
	local crc = 0xFFFFFFFF
	for i = 1, #text do
		crc = bxor(rshift(crc, 8), crcTable[band(bxor(crc, text:byte(i)), 0xFF)])
	end
	return ("%08x"):format(bxor(crc, 0xFFFFFFFF))
end

-- Prefer a real HTTP request function so we can read non-200 responses, fall
-- back to the classic game:HttpGet.
local function httpGet(url)
	local request = (syn and syn.request)
		or (http and http.request)
		or http_request
		or (fluxus and fluxus.request)
		or request

	if request then
		local ok, res = pcall(request, { Url = url, Method = "GET" })
		if ok and res and res.Body then
			local status = tonumber(res.StatusCode or res.status_code or res.Status)
			if status and (status < 200 or status >= 300) then
				error(("HTTP %d while fetching %s"):format(status, url), 0)
			end
			return res.Body
		end
	end

	return game:HttpGet(url)
end

local cache = {}
local loading = {}

-- Dev logging: prints to the executor/F9 console so a frozen load reveals
-- exactly which file failed, its byte length (catches truncated HttpGet on
-- big files), and a real traceback instead of a silent freeze.
local function log(...)
	if Config.DevMode then
		print("[Axon]", ...)
	end
end

-- import("src/Modules/Lib") -> fetches BaseUrl .. "src/Modules/Lib.lua",
-- compiles it, runs it once, and memoises the return value.
local function import(path)
	if cache[path] then
		return cache[path]
	end

	local activeLoad = loading[path]
	if activeLoad then
		while not activeLoad.Done do
			task.wait()
		end
		if activeLoad.Ok then
			return activeLoad.Result
		end
		error(activeLoad.Error, 0)
	end

	activeLoad = {Done = false, Ok = false}
	loading[path] = activeLoad

	local function fail(message)
		activeLoad.Done = true
		activeLoad.Ok = false
		activeLoad.Error = message
		loading[path] = nil
		error(message, 0)
	end

	local url = BaseUrl .. path .. ".lua"
	if Config.DevMode then
		url = url .. "?cb=" .. tostring(tick())
	end

	log("fetch  →", path)
	local okFetch, source = pcall(httpGet, url)
	if not okFetch then
		fail(("Axon: failed to download '%s': %s"):format(path, tostring(source)))
	end
	if type(source) ~= "string" or #source == 0 then
		fail(("Axon: failed to download '%s' (empty response)"):format(path))
	end
	log(("fetched   %s  (%d bytes, crc32=%s)"):format(path, #source, hashText32(source)))

	local chunk, err = loadstring(source, "=" .. path)
	if not chunk then
		warn(("[Axon] COMPILE ERROR in %s:\n%s"):format(path, tostring(err)))
		fail(("Axon: failed to compile '%s': %s"):format(path, tostring(err)))
	end

	local ok, result = xpcall(chunk, function(e)
		return tostring(e) .. "\n" .. debug.traceback()
	end)
	if not ok then
		warn(("[Axon] ERROR running %s:\n%s"):format(path, tostring(result)))
		fail(("Axon: error running '%s'"):format(path))
	end

	log("loaded ✓ ", path)
	cache[path] = result ~= nil and result or true
	activeLoad.Done = true
	activeLoad.Ok = true
	activeLoad.Result = cache[path]
	loading[path] = nil
	return cache[path]
end

genv.Axon = {
	Owner   = Config.Owner,
	Repo    = Config.Repo,
	Branch  = Config.Branch,
	BaseUrl = BaseUrl,
	DevMode = Config.DevMode,
	Import  = import,
	HttpGet = httpGet,
	HashText32 = hashText32,
}

-- Hand off to the bootstrap, which builds the rest of the suite.
return import("src/init")
