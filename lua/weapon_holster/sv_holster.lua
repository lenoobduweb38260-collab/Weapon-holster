--[[----------------------------------------------------------------------------
	sv_holster.lua — Server: persistence, networking, admin actions.

	Overrides are stored as one JSON file per weapon class under
	data/weapon_holster/. Vectors/Angles are flattened to plain number tables so
	the JSON round-trips cleanly. Hidden (excluded) weapons are stored in a
	single _excluded.txt file so a deleted weapon never comes back on its own.
------------------------------------------------------------------------------]]

WH = WH or {}

local DATA_DIR = "weapon_holster"
local EXCL_FILE = DATA_DIR .. "/_excluded.txt"

util.AddNetworkString("wh_sync")      -- server -> client : full state (overrides + excluded)
util.AddNetworkString("wh_save")      -- client -> server : save a placement
util.AddNetworkString("wh_reset")     -- client -> server : back to auto (drop override + unhide)
util.AddNetworkString("wh_hide")      -- client -> server : hide a weapon for good
util.AddNetworkString("wh_reset_all") -- client -> server : wipe ALL config
util.AddNetworkString("wh_setting")   -- client -> server : change a convar

--------------------------------------------------------------------------------
-- Permissions. Override WH.CanAdmin in your own file to plug in a permission
-- mod (ULX/serverguard/etc.); by default only super admins may edit.
--------------------------------------------------------------------------------
function WH.CanAdmin(ply)
	return IsValid(ply) and ply:IsSuperAdmin()
end

--------------------------------------------------------------------------------
-- Serialisation helpers (canonical entry <-> JSON-safe table)
--------------------------------------------------------------------------------
local function toStorage(entry)
	return {
		model = entry.model or "",
		bone  = entry.bone,
		pos   = { x = entry.pos.x, y = entry.pos.y, z = entry.pos.z },
		ang   = { p = entry.ang.p, y = entry.ang.y, r = entry.ang.r },
		scale = entry.scale or 1,
		slot  = entry.slot or "back",
		auto  = false,
	}
end

local function safeClass(class)
	return string.gsub(class, "[^%w_%-]", "")
end

--------------------------------------------------------------------------------
-- Disk I/O
--------------------------------------------------------------------------------
local function ensureDir()
	if not file.IsDir(DATA_DIR, "DATA") then
		file.CreateDir(DATA_DIR)
	end
end

local function saveToDisk(class, entry)
	ensureDir()
	local safe = safeClass(class)
	if safe == "" then return end
	file.Write(DATA_DIR .. "/" .. safe .. ".txt", util.TableToJSON(toStorage(entry), true))
end

local function deleteFromDisk(class)
	local path = DATA_DIR .. "/" .. safeClass(class) .. ".txt"
	if file.Exists(path, "DATA") then
		file.Delete(path)
	end
end

local function saveExcluded()
	ensureDir()
	local list = {}
	for class in pairs(WH.Excluded) do list[#list + 1] = class end
	file.Write(EXCL_FILE, util.TableToJSON(list, true))
end

local function loadAll()
	WH.Overrides = {}
	WH.Excluded = {}

	if not file.IsDir(DATA_DIR, "DATA") then
		ensureDir()
		return
	end

	-- Placements.
	for _, fname in ipairs(file.Find(DATA_DIR .. "/*.txt", "DATA")) do
		if fname ~= "_excluded.txt" then
			local class = string.sub(fname, 1, #fname - 4)
			local raw = file.Read(DATA_DIR .. "/" .. fname, "DATA")
			local tbl = raw and util.JSONToTable(raw)
			local entry = tbl and WH.Normalize(tbl)
			if entry then WH.Overrides[class] = entry end
		end
	end

	-- Hidden weapons.
	if file.Exists(EXCL_FILE, "DATA") then
		local list = util.JSONToTable(file.Read(EXCL_FILE, "DATA") or "") or {}
		for _, class in ipairs(list) do WH.Excluded[class] = true end
	end

	MsgN(string.format("[Weapon Holster] Loaded %d placement(s), %d hidden weapon(s).",
		table.Count(WH.Overrides), table.Count(WH.Excluded)))
end

hook.Add("Initialize", "WH_LoadOverrides", loadAll)

--------------------------------------------------------------------------------
-- Networking: keep it simple — broadcast the whole (small) state on any change.
--------------------------------------------------------------------------------
function WH.SyncFull(ply)
	net.Start("wh_sync")
	net.WriteTable(WH.Overrides)
	net.WriteTable(WH.Excluded)
	if IsValid(ply) then net.Send(ply) else net.Broadcast() end
end

hook.Add("PlayerInitialSpawn", "WH_SyncNewPlayer", function(ply)
	timer.Simple(1, function()
		if IsValid(ply) then WH.SyncFull(ply) end
	end)
end)

--------------------------------------------------------------------------------
-- Net receivers
--------------------------------------------------------------------------------
net.Receive("wh_save", function(_, ply)
	if not WH.CanAdmin(ply) then return end

	local class = net.ReadString()
	local tbl   = net.ReadTable()
	if class == "" then return end

	local entry = WH.Normalize(tbl)
	if not entry then return end
	entry.auto = false

	-- Configuring a weapon un-hides it.
	if WH.Excluded[class] then
		WH.Excluded[class] = nil
		saveExcluded()
	end

	WH.Overrides[class] = entry
	saveToDisk(class, entry)
	WH.SyncFull()

	MsgN("[Weapon Holster] " .. ply:Nick() .. " saved placement for " .. class)
end)

-- Reset to automatic: drop any override AND un-hide -> weapon holsters via auto.
net.Receive("wh_reset", function(_, ply)
	if not WH.CanAdmin(ply) then return end

	local class = net.ReadString()
	if class == "" then return end

	WH.Overrides[class] = nil
	deleteFromDisk(class)
	if WH.Excluded[class] then
		WH.Excluded[class] = nil
		saveExcluded()
	end
	WH.SyncFull()
end)

-- Hide for good: drop override + add to persistent exclusion list.
net.Receive("wh_hide", function(_, ply)
	if not WH.CanAdmin(ply) then return end

	local class = net.ReadString()
	if class == "" then return end

	WH.Overrides[class] = nil
	deleteFromDisk(class)
	WH.Excluded[class] = true
	saveExcluded()
	WH.SyncFull()

	MsgN("[Weapon Holster] " .. ply:Nick() .. " hid " .. class)
end)

-- Wipe EVERYTHING: all placements and all hidden weapons.
net.Receive("wh_reset_all", function(_, ply)
	if not WH.CanAdmin(ply) then return end

	if file.IsDir(DATA_DIR, "DATA") then
		for _, fname in ipairs(file.Find(DATA_DIR .. "/*.txt", "DATA")) do
			file.Delete(DATA_DIR .. "/" .. fname)
		end
	end
	WH.Overrides = {}
	WH.Excluded = {}
	WH.SyncFull()

	MsgN("[Weapon Holster] " .. ply:Nick() .. " wiped ALL config.")
end)

--------------------------------------------------------------------------------
-- Server-side convar editing (placement style, master switch, ...) from the UI
--------------------------------------------------------------------------------
local settingWhitelist = {
	["wh_enabled"]        = true,
	["wh_placement"]      = true,
	["wh_auto_holster"]   = true,
	["wh_max_per_player"] = true,
}

net.Receive("wh_setting", function(_, ply)
	if not WH.CanAdmin(ply) then return end
	if (ply.WH_NextSetting or 0) > CurTime() then return end
	ply.WH_NextSetting = CurTime() + 0.15

	local con = net.ReadString()
	local val = net.ReadString()
	if not settingWhitelist[con] then return end
	if not ConVarExists(con) then return end

	GetConVar(con):SetString(val)
	MsgN("[Weapon Holster] " .. ply:Nick() .. " set " .. con .. " = " .. val)
end)
