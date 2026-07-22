--[[----------------------------------------------------------------------------
	sv_holster.lua — Server: persistence, networking, admin actions.

	Overrides are stored as one JSON file per weapon class under
	data/weapon_holster/. Vectors/Angles are flattened to plain number tables
	so the JSON round-trips cleanly (the old addon relied on undefined
	Vector serialisation behaviour).
------------------------------------------------------------------------------]]

WH = WH or {}

local DATA_DIR = "weapon_holster"

util.AddNetworkString("wh_sync")      -- server -> client : full override table
util.AddNetworkString("wh_update")    -- server -> client : single class changed
util.AddNetworkString("wh_save")      -- client -> server : save a placement
util.AddNetworkString("wh_delete")    -- client -> server : delete a placement
util.AddNetworkString("wh_reset_all") -- client -> server : wipe all overrides
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
	local safe = string.gsub(class, "[^%w_%-]", "")
	if safe == "" then return end
	file.Write(DATA_DIR .. "/" .. safe .. ".txt", util.TableToJSON(toStorage(entry), true))
end

local function deleteFromDisk(class)
	local safe = string.gsub(class, "[^%w_%-]", "")
	local path = DATA_DIR .. "/" .. safe .. ".txt"
	if file.Exists(path, "DATA") then
		file.Delete(path)
	end
end

local function loadAll()
	WH.Overrides = {}
	if not file.IsDir(DATA_DIR, "DATA") then
		ensureDir()
		return
	end

	local files = file.Find(DATA_DIR .. "/*.txt", "DATA")
	for _, fname in ipairs(files) do
		local class = string.sub(fname, 1, #fname - 4)
		local raw = file.Read(DATA_DIR .. "/" .. fname, "DATA")
		local tbl = raw and util.JSONToTable(raw)
		local entry = tbl and WH.Normalize(tbl)
		if entry then
			WH.Overrides[class] = entry
		end
	end

	MsgN("[Weapon Holster] Loaded " .. table.Count(WH.Overrides) .. " saved placement(s).")
end

hook.Add("Initialize", "WH_LoadOverrides", loadAll)

--------------------------------------------------------------------------------
-- Networking overrides to clients
--------------------------------------------------------------------------------
function WH.SyncFull(ply)
	net.Start("wh_sync")
	net.WriteTable(WH.Overrides)
	if IsValid(ply) then net.Send(ply) else net.Broadcast() end
end

local function broadcastUpdate(class, entry)
	net.Start("wh_update")
	net.WriteString(class)
	net.WriteBool(entry ~= nil)
	if entry then net.WriteTable(entry) end
	net.Broadcast()
end

hook.Add("PlayerInitialSpawn", "WH_SyncNewPlayer", function(ply)
	-- Small delay so the client has finished loading Lua.
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

	WH.Overrides[class] = entry
	saveToDisk(class, entry)
	broadcastUpdate(class, entry)

	MsgN("[Weapon Holster] " .. ply:Nick() .. " saved placement for " .. class)
end)

net.Receive("wh_delete", function(_, ply)
	if not WH.CanAdmin(ply) then return end

	local class = net.ReadString()
	if class == "" then return end

	WH.Overrides[class] = nil
	deleteFromDisk(class)
	broadcastUpdate(class, nil)
end)

net.Receive("wh_reset_all", function(_, ply)
	if not WH.CanAdmin(ply) then return end

	if file.IsDir(DATA_DIR, "DATA") then
		for _, fname in ipairs(file.Find(DATA_DIR .. "/*.txt", "DATA")) do
			file.Delete(DATA_DIR .. "/" .. fname)
		end
	end
	WH.Overrides = {}
	WH.SyncFull()

	MsgN("[Weapon Holster] " .. ply:Nick() .. " reset ALL placements.")
end)

--------------------------------------------------------------------------------
-- Server-side convar editing (placement style, master switch, ...) from the UI
--------------------------------------------------------------------------------
local settingWhitelist = {
	["wh_enabled"]      = true,
	["wh_placement"]    = true,
	["wh_auto_holster"] = true,
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
