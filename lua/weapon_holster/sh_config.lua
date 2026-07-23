--[[----------------------------------------------------------------------------
	sh_config.lua — Shared configuration & auto-placement rules.

	Everything an admin might want to tweak without touching the UI lives here.
	The automatic placement system reads the "slot" tables below: a weapon's
	hold type is mapped to a named mount point (bone + offset), so ANY weapon
	pack works out of the box with zero per-weapon configuration.
------------------------------------------------------------------------------]]

WH = WH or {}
WH.Config = WH.Config or {}

--------------------------------------------------------------------------------
-- Console variables (the "config" the user asked to make less painful)
--------------------------------------------------------------------------------
-- Replicated master switch (server-controlled, archived).
if not ConVarExists("wh_enabled") then
	CreateConVar("wh_enabled", "1",
		{ FCVAR_REPLICATED, FCVAR_ARCHIVE, FCVAR_SERVER_CAN_EXECUTE },
		"Enable the Weapon Holster system (server side).")
end

-- Placement style, replicated so every client draws the same layout.
-- "back"  : long guns on the back, pistols on the hip  (default)
-- "rp"    : long guns slung across the torso, sidearms on a chest holster
if not ConVarExists("wh_placement") then
	CreateConVar("wh_placement", "back",
		{ FCVAR_REPLICATED, FCVAR_ARCHIVE, FCVAR_SERVER_CAN_EXECUTE },
		"Auto placement style: 'back' or 'rp' (torso).")
end

-- Should brand-new / unconfigured weapons be holstered automatically?
if not ConVarExists("wh_auto_holster") then
	CreateConVar("wh_auto_holster", "1",
		{ FCVAR_REPLICATED, FCVAR_ARCHIVE, FCVAR_SERVER_CAN_EXECUTE },
		"Automatically holster weapons that have no saved config.")
end

-- Max number of holstered weapons drawn per player (perf guard).
if not ConVarExists("wh_max_per_player") then
	CreateConVar("wh_max_per_player", "6",
		{ FCVAR_REPLICATED, FCVAR_ARCHIVE, FCVAR_SERVER_CAN_EXECUTE },
		"Maximum holstered weapons rendered per player.")
end

-- Client-only toggle so a player can hide holsters for themselves.
if CLIENT then
	CreateClientConVar("cl_wh_enabled", "1", true, false,
		"Show weapon holsters on players (client side).")
	-- Draw distance: skip far away players for performance.
	CreateClientConVar("cl_wh_drawdistance", "1024", true, false,
		"Max distance (units) to draw holstered weapons. 0 = unlimited.")
end

function WH.Enabled()
	return GetConVar("wh_enabled"):GetBool()
end

function WH.PlacementStyle()
	local s = GetConVar("wh_placement"):GetString()
	return (s == "rp") and "rp" or "back"
end

--------------------------------------------------------------------------------
-- Mount points (slots). Each is a bone + position + angle on the standard
-- ValveBiped citizen skeleton. Custom playermodels reuse the same bone names,
-- so these work almost universally.
--------------------------------------------------------------------------------
WH.Slots = {
	-- Long guns slung diagonally on the back.
	back = {
		label = "Dos (droite)",
		bone  = "ValveBiped.Bip01_R_Clavicle",
		pos   = Vector(13, 4, 5),
		ang   = Angle(90, 0, 100),
	},
	back_left = {
		label = "Dos (gauche)",
		bone  = "ValveBiped.Bip01_L_Clavicle",
		pos   = Vector(-13, 4, 5),
		ang   = Angle(90, 0, -100),
	},
	-- SMGs lower on the back / small of the back.
	back_low = {
		label = "Bas du dos",
		bone  = "ValveBiped.Bip01_Spine1",
		pos   = Vector(5, 0, -5),
		ang   = Angle(0, 0, 230),
	},
	-- Long gun slung across the FRONT torso (RP mode).
	chest_sling = {
		label = "Sangle torse",
		bone  = "ValveBiped.Bip01_Spine2",
		pos   = Vector(7, 1, 8),
		ang   = Angle(85, 15, 100),
	},
	-- Sidearm on the right hip.
	hip_right = {
		label = "Hanche droite",
		bone  = "ValveBiped.Bip01_Pelvis",
		pos   = Vector(1, -8, -4),
		ang   = Angle(5, 270, 0),
	},
	-- Sidearm on the left hip.
	hip_left = {
		label = "Hanche gauche",
		bone  = "ValveBiped.Bip01_Pelvis",
		pos   = Vector(1, 8, -4),
		ang   = Angle(5, 90, 0),
	},
	-- Chest holster (RP sidearm).
	chest_holster = {
		label = "Holster poitrine",
		bone  = "ValveBiped.Bip01_Spine2",
		pos   = Vector(9, -3, 2),
		ang   = Angle(0, 250, 20),
	},
	-- Grenades / equipment on the front belt.
	belt = {
		label = "Ceinture",
		bone  = "ValveBiped.Bip01_Pelvis",
		pos   = Vector(3, -5, 6),
		ang   = Angle(-95, 0, 0),
	},
	-- Melee weapon across the lower back.
	melee_back = {
		label = "Dos (mêlée)",
		bone  = "ValveBiped.Bip01_Spine1",
		pos   = Vector(3, 0, 0),
		ang   = Angle(0, 0, 45),
	},
}

-- Ordered slot list for UI dropdowns.
WH.SlotOrder = {
	"back", "back_left", "back_low", "chest_sling",
	"hip_right", "hip_left", "chest_holster", "belt", "melee_back",
}

--------------------------------------------------------------------------------
-- Hold type -> slot mapping. This is what makes the addon adapt to every pack:
-- we never look at the weapon's class name, only its behaviour (hold type),
-- which every SWEP defines. `false` = never holster this type.
--------------------------------------------------------------------------------
WH.HoldTypeSlots = {
	-- Default / "back" placement style.
	back = {
		pistol    = "hip_right",
		revolver  = "hip_right",
		duel      = "hip_right",
		smg       = "back_low",
		ar2       = "back",
		rifle     = "back",
		shotgun   = "back",
		crossbow  = "back",
		rpg       = "back_left",
		grenade   = "belt",
		slam      = "belt",
		melee     = "melee_back",
		melee2    = "melee_back",
		knife     = "hip_left",
		normal    = "back",
		fist      = false,
		physgun   = false,
		camera    = false,
		magic     = false,
		passive   = false,
	},

	-- "rp" style: long guns on the torso, sidearms on a chest rig.
	rp = {
		pistol    = "chest_holster",
		revolver  = "chest_holster",
		duel      = "chest_holster",
		smg       = "chest_sling",
		ar2       = "chest_sling",
		rifle     = "chest_sling",
		shotgun   = "chest_sling",
		crossbow  = "chest_sling",
		rpg       = "back_left",
		grenade   = "belt",
		slam      = "belt",
		melee     = "hip_left",
		melee2    = "hip_left",
		knife     = "hip_left",
		normal    = "chest_sling",
		fist      = false,
		physgun   = false,
		camera    = false,
		magic     = false,
		passive   = false,
	},
}

-- Weapon classes we never holster regardless of hold type (tools, hands, etc.).
WH.ClassBlacklist = {
	["gmod_tool"]     = true,
	["gmod_camera"]   = true,
	["weapon_physgun"]= true,
	["weapon_physcannon"] = true,
	["weapon_medkit"] = true,
	["none"]          = true,
	[""]              = true,
}
