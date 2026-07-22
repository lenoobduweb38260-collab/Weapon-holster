--[[----------------------------------------------------------------------------
	sh_core.lua — Shared core logic.

	* WH.Overrides : per-class saved configs (networked from the server).
	* Auto entry generation : turns any weapon into a holster placement using
	  only its hold type + world model, so the addon adapts to every pack.
	* Data normalisation : understands both the new schema and the legacy
	  { Model, Bone, BoneOffset = { Vector, Angle } } format.
------------------------------------------------------------------------------]]

WH = WH or {}

-- Per-class saved overrides. Shape: WH.Overrides[class] = entry (see below).
WH.Overrides = WH.Overrides or {}

-- Runtime cache of generated auto entries so we don't rebuild every frame.
WH.AutoCache = WH.AutoCache or {}

--------------------------------------------------------------------------------
-- Bones a placement is allowed to attach to (used by the editor dropdown).
--------------------------------------------------------------------------------
WH.PlayerBones = {
	"ValveBiped.Bip01_Pelvis",
	"ValveBiped.Bip01_Spine",
	"ValveBiped.Bip01_Spine1",
	"ValveBiped.Bip01_Spine2",
	"ValveBiped.Bip01_Spine4",
	"ValveBiped.Bip01_Neck1",
	"ValveBiped.Bip01_Head1",
	"ValveBiped.Bip01_R_Clavicle",
	"ValveBiped.Bip01_R_UpperArm",
	"ValveBiped.Bip01_R_Forearm",
	"ValveBiped.Bip01_R_Hand",
	"ValveBiped.Bip01_R_Thigh",
	"ValveBiped.Bip01_R_Calf",
	"ValveBiped.Bip01_L_Clavicle",
	"ValveBiped.Bip01_L_UpperArm",
	"ValveBiped.Bip01_L_Forearm",
	"ValveBiped.Bip01_L_Hand",
	"ValveBiped.Bip01_L_Thigh",
	"ValveBiped.Bip01_L_Calf",
}

--------------------------------------------------------------------------------
-- Entry schema helpers
--------------------------------------------------------------------------------
-- Canonical entry:
--   { model = "" | "models/...", bone = "ValveBiped...", pos = Vector,
--     ang = Angle, scale = 1, slot = "back", auto = true/false }
-- model == "" means "use the weapon's own world model" (fully automatic).

function WH.NewEntry(data)
	data = data or {}
	return {
		model = data.model or "",
		bone  = data.bone  or "ValveBiped.Bip01_R_Clavicle",
		pos   = data.pos   or Vector(0, 0, 0),
		ang   = data.ang   or Angle(0, 0, 0),
		scale = data.scale or 1,
		slot  = data.slot  or "back",
		auto  = data.auto ~= false,
	}
end

-- Accepts new OR legacy tables and returns a clean canonical entry.
function WH.Normalize(tbl)
	if not istable(tbl) then return nil end

	-- Legacy format from the original addon.
	if tbl.BoneOffset and not tbl.pos then
		local off = tbl.BoneOffset
		return WH.NewEntry({
			model = tbl.Model or "",
			bone  = tbl.Bone or "ValveBiped.Bip01_R_Clavicle",
			pos   = isvector(off[1]) and off[1] or Vector(0, 0, 0),
			ang   = isangle(off[2]) and off[2] or Angle(0, 0, 0),
			scale = tbl.Scale or 1,
			slot  = tbl.Slot or "back",
			auto  = false,
		})
	end

	-- Already-new format (may arrive as plain tables over the network).
	return WH.NewEntry({
		model = tbl.model,
		bone  = tbl.bone,
		pos   = isvector(tbl.pos) and tbl.pos or Vector(tbl.pos and tbl.pos.x or 0, tbl.pos and tbl.pos.y or 0, tbl.pos and tbl.pos.z or 0),
		ang   = isangle(tbl.ang) and tbl.ang or Angle(tbl.ang and tbl.ang.p or 0, tbl.ang and tbl.ang.y or 0, tbl.ang and tbl.ang.r or 0),
		scale = tbl.scale,
		slot  = tbl.slot,
		auto  = tbl.auto,
	})
end

--------------------------------------------------------------------------------
-- Resolving a weapon's world model automatically.
--------------------------------------------------------------------------------
-- Priority: live weapon world model > SWEP table WorldModel > generic fallback.
function WH.ResolveModel(class, wep)
	if IsValid(wep) and wep.GetWeaponWorldModel then
		local m = wep:GetWeaponWorldModel()
		if isstring(m) and m ~= "" then return m end
	end

	local swep = weapons.GetStored(class) or weapons.Get(class)
	if swep and isstring(swep.WorldModel) and swep.WorldModel ~= "" then
		return swep.WorldModel
	end

	return "models/weapons/w_rif_ak47.mdl"
end

-- Resolve a weapon's hold type (behaviour), used for auto placement.
function WH.ResolveHoldType(class, wep)
	if IsValid(wep) and wep.GetHoldType then
		local ht = wep:GetHoldType()
		if isstring(ht) and ht ~= "" then return ht end
	end

	local swep = weapons.GetStored(class) or weapons.Get(class)
	if swep and isstring(swep.HoldType) and swep.HoldType ~= "" then
		return swep.HoldType
	end

	return "normal"
end

--------------------------------------------------------------------------------
-- Automatic placement: hold type -> slot -> entry.
--------------------------------------------------------------------------------
-- Returns nil when the weapon should not be holstered (tools, hands, etc.).
function WH.BuildAutoEntry(class, wep)
	if WH.ClassBlacklist[class] then return nil end

	local style   = WH.PlacementStyle()
	local holdtype = WH.ResolveHoldType(class, wep)
	local slotName = WH.HoldTypeSlots[style][holdtype]

	-- Unknown hold type -> fall back to the generic "normal" rule.
	if slotName == nil then
		slotName = WH.HoldTypeSlots[style].normal
	end

	if slotName == false then return nil end

	local slot = WH.Slots[slotName]
	if not slot then return nil end

	return WH.NewEntry({
		model = "", -- empty = auto-detect from the live weapon
		bone  = slot.bone,
		pos   = Vector(slot.pos),
		ang   = Angle(slot.ang),
		scale = 1,
		slot  = slotName,
		auto  = true,
	})
end

--------------------------------------------------------------------------------
-- Public resolver: the single source of truth for "where does this weapon go?"
--------------------------------------------------------------------------------
-- Returns an entry (canonical) or nil if the weapon must not be holstered.
-- `wep` is optional but greatly improves model/hold-type detection.
function WH.GetPlacement(class, wep)
	-- 1) Admin-saved override always wins.
	local override = WH.Overrides[class]
	if override then
		return override
	end

	-- 2) Auto placement (if enabled).
	if not GetConVar("wh_auto_holster"):GetBool() then
		return nil
	end

	-- Cache auto entries per class + placement style so we don't rebuild them.
	local key = class .. "|" .. WH.PlacementStyle()
	local cached = WH.AutoCache[key]
	if cached ~= nil then
		-- `false` is stored to remember "never holster".
		if cached == false then return nil end
		return cached
	end

	local entry = WH.BuildAutoEntry(class, wep)
	WH.AutoCache[key] = entry == nil and false or entry
	return entry
end

-- Wipe the auto cache (call when placement style changes).
function WH.ClearAutoCache()
	WH.AutoCache = {}
end

-- Friendly display name for a weapon class.
function WH.PrettyName(class)
	local swep = weapons.GetStored(class) or weapons.Get(class)
	if swep and swep.PrintName and swep.PrintName ~= "" then
		return swep.PrintName
	end
	if WH.HL2Weps and WH.HL2Weps[class] then
		return WH.HL2Weps[class]
	end
	return class
end

-- Legacy HL2 pretty-name table kept for display fallback.
WH.HL2Weps = {
	["weapon_pistol"]     = "Pistol",
	["weapon_357"]        = "357",
	["weapon_frag"]       = "Frag Grenade",
	["weapon_slam"]       = "SLAM",
	["weapon_crowbar"]    = "Crowbar",
	["weapon_stunstick"]  = "Stunstick",
	["weapon_shotgun"]    = "Shotgun",
	["weapon_rpg"]        = "RPG Launcher",
	["weapon_smg1"]       = "SMG",
	["weapon_ar2"]        = "AR2",
	["weapon_crossbow"]   = "Crossbow",
	["weapon_physcannon"] = "Gravity Gun",
	["weapon_physgun"]    = "Physics Gun",
}
