--[[----------------------------------------------------------------------------
	cl_render.lua — Client: draw holstered weapons on players.

	Uses clientside models parented (logically) to a player's bones. Models are
	auto-detected from the live weapon when no explicit model is saved, so any
	weapon pack renders correctly with no configuration.

	While the editor is open, WH.Preview lets slider changes update the weapon
	on the real in-world player in real time.
------------------------------------------------------------------------------]]

WH = WH or {}

-- WH.Slotted[ply] = { [class] = { ent = CSModel, model = "models/..." } }
WH.Slotted = WH.Slotted or {}

-- Live preview override set by the editor: { class = "...", entry = <entry> }.
WH.Preview = WH.Preview or nil

--------------------------------------------------------------------------------
-- Receive synced overrides from the server
--------------------------------------------------------------------------------
net.Receive("wh_sync", function()
	local tbl  = net.ReadTable()
	local excl = net.ReadTable()

	WH.Overrides = {}
	for class, data in pairs(tbl) do
		local entry = WH.Normalize(data)
		if entry then WH.Overrides[class] = entry end
	end

	WH.Excluded = {}
	for class, v in pairs(excl or {}) do
		if v then WH.Excluded[class] = true end
	end

	WH.ClearAutoCache()
end)

-- Rebuild auto placements when the admin flips the placement style.
cvars.AddChangeCallback("wh_placement", function()
	WH.ClearAutoCache()
end, "WH_PlacementChanged")

--------------------------------------------------------------------------------
-- Master enable check (server switch + client toggle)
--------------------------------------------------------------------------------
local function drawingEnabled()
	return WH.Enabled() and GetConVar("cl_wh_enabled"):GetBool()
end

--------------------------------------------------------------------------------
-- Placement resolution for rendering (preview beats saved/auto)
--------------------------------------------------------------------------------
local function resolveForRender(class, wep)
	if WH.Preview and WH.Preview.class == class then
		return WH.Preview.entry
	end
	return WH.GetPlacement(class, wep)
end

--------------------------------------------------------------------------------
-- Clientside model lifecycle
--------------------------------------------------------------------------------
local function clearPlayer(ply)
	local set = WH.Slotted[ply]
	if not set then return end
	for _, data in pairs(set) do
		if IsValid(data.ent) then data.ent:Remove() end
	end
	WH.Slotted[ply] = nil
end

-- Remove every clientside model (e.g. when the system is disabled).
function WH.ClearAll()
	for ply in pairs(WH.Slotted) do
		clearPlayer(ply)
	end
	WH.Slotted = {}
end

cvars.AddChangeCallback("cl_wh_enabled", function(_, _, new)
	if new == "0" then WH.ClearAll() end
end, "WH_ClientToggle")

local function ensureModel(ply, class, wantModel)
	WH.Slotted[ply] = WH.Slotted[ply] or {}
	local set = WH.Slotted[ply]
	local data = set[class]

	-- Recreate if missing or the resolved model changed (auto-detect switch).
	if not data or not IsValid(data.ent) or data.model ~= wantModel then
		if data and IsValid(data.ent) then data.ent:Remove() end
		local ent = ClientsideModel(wantModel, RENDERGROUP_OPAQUE)
		if not IsValid(ent) then return nil end
		ent:SetNoDraw(true)
		set[class] = { ent = ent, model = wantModel }
		data = set[class]
	end

	return data.ent
end

--------------------------------------------------------------------------------
-- Per-frame sync: keep the clientside model set matching each player's weapons
--------------------------------------------------------------------------------
local function shouldHolster(ply, class, wep, active)
	if wep == active then return false end            -- currently held
	if not resolveForRender(class, wep) then return false end
	return true
end

-- Models are (re)created here in Think — NEVER inside a render hook, which can
-- crash the game. PostPlayerDraw only draws models that already exist.
hook.Add("Think", "WH_SyncModels", function()
	if not drawingEnabled() then
		if next(WH.Slotted) then WH.ClearAll() end
		return
	end

	local maxPer = GetConVar("wh_max_per_player"):GetInt()

	for _, ply in ipairs(player.GetAll()) do
		if IsValid(ply) and ply:Alive() and not ply:GetNoDraw() then
			local active = ply:GetActiveWeapon()
			local wanted = {}
			local count  = 0

			for _, wep in ipairs(ply:GetWeapons()) do
				if IsValid(wep) then
					local class = wep:GetClass()
					if count < maxPer and shouldHolster(ply, class, wep, active) then
						local entry = resolveForRender(class, wep)
						local model = (entry.model ~= "" and entry.model) or WH.ResolveModel(class, wep)
						ensureModel(ply, class, model)
						wanted[class] = true
						count = count + 1
					end
				end
			end

			-- Drop models for weapons the player no longer holsters.
			local set = WH.Slotted[ply]
			if set then
				for class, data in pairs(set) do
					if not wanted[class] then
						if IsValid(data.ent) then data.ent:Remove() end
						set[class] = nil
					end
				end
			end
		else
			clearPlayer(ply)
		end
	end

	-- Clean up disconnected players.
	for ply in pairs(WH.Slotted) do
		if not IsValid(ply) then clearPlayer(ply) end
	end
end)

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------
local function calcOffset(pos, ang, off)
	return pos + ang:Right() * off.x + ang:Forward() * off.y + ang:Up() * off.z
end

hook.Add("PostPlayerDraw", "WH_DrawHolsters", function(ply)
	if not drawingEnabled() then return end
	if not IsValid(ply) or not ply:Alive() then return end

	-- Distance culling.
	local maxDist = GetConVar("cl_wh_drawdistance"):GetFloat()
	if maxDist > 0 then
		local d = EyePos():DistToSqr(ply:GetPos())
		if d > maxDist * maxDist then return end
	end

	local set = WH.Slotted[ply]
	if not set then return end

	for class, data in pairs(set) do
		local ent = data.ent
		if IsValid(ent) then
			local wep = ply:GetWeapon(class)
			local entry = resolveForRender(class, IsValid(wep) and wep or nil)
			if entry then
				local boneId = ply:LookupBone(entry.bone)
				local matrix = boneId and ply:GetBoneMatrix(boneId)
				if matrix then
					local pos = matrix:GetTranslation()
					local ang = matrix:GetAngles()

					pos = calcOffset(pos, ang, entry.pos)
					ang:RotateAroundAxis(ang:Forward(), entry.ang.p)
					ang:RotateAroundAxis(ang:Up(),      entry.ang.y)
					ang:RotateAroundAxis(ang:Right(),   entry.ang.r)

					ent:SetRenderOrigin(pos)
					ent:SetRenderAngles(ang)
					ent:SetModelScale(entry.scale or 1, 0)
					ent:DrawModel()
					ent:SetRenderOrigin()
					ent:SetRenderAngles()
				end
			end
		end
	end
end)

-- Tidy up on shutdown / map change.
hook.Add("ShutDown", "WH_Cleanup", function() WH.ClearAll() end)
