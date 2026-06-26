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
			return res.Body
		end
	end

	return game:HttpGet(url)
end

local cache = {}

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

	local url = BaseUrl .. path .. ".lua"
	if Config.DevMode then
		url = url .. "?cb=" .. tostring(tick())
	end

	log("fetch  →", path)
	local source = httpGet(url)
	if type(source) ~= "string" or #source == 0 then
		error(("Axon: failed to download '%s' (empty response)"):format(path), 0)
	end
	log(("fetched   %s  (%d bytes)"):format(path, #source))

	local chunk, err = loadstring(source, "=" .. path)
	if not chunk then
		warn(("[Axon] COMPILE ERROR in %s:\n%s"):format(path, tostring(err)))
		error(("Axon: failed to compile '%s': %s"):format(path, tostring(err)), 0)
	end

	local ok, result = xpcall(chunk, function(e)
		return tostring(e) .. "\n" .. debug.traceback()
	end)
	if not ok then
		warn(("[Axon] ERROR running %s:\n%s"):format(path, tostring(result)))
		error(("Axon: error running '%s'"):format(path), 0)
	end

	log("loaded ✓ ", path)
	cache[path] = result ~= nil and result or true
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
}

-- Hand off to the bootstrap, which builds the rest of the suite.
return import("src/init")
