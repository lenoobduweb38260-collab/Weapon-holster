--[[----------------------------------------------------------------------------
	Weapon Holster — Reworked Edition
	Original concept: Polyester Duck
	Reworked: modern UI with 3D orbit editor, automatic model detection,
	automatic placement (back / RP torso), auto-adapts to any weapon pack.

	This file is the single entry point. It wires every module up in the
	correct realm so the rest of the code never has to worry about load order.
------------------------------------------------------------------------------]]

WH = WH or {}
WH.Version = "2.0.0"
WH.Folder = "weapon_holster/"

local function shared(path)
	if SERVER then AddCSLuaFile(WH.Folder .. path) end
	include(WH.Folder .. path)
end

local function server(path)
	if SERVER then include(WH.Folder .. path) end
end

local function client(path)
	if SERVER then AddCSLuaFile(WH.Folder .. path) return end
	include(WH.Folder .. path)
end

-- Order matters: config + core define the tables everything else relies on.
shared("sh_config.lua")
shared("sh_core.lua")

server("sv_holster.lua")

client("cl_render.lua")
client("cl_menu.lua")

if SERVER then
	MsgN("[Weapon Holster] Loaded v" .. WH.Version .. " (reworked edition)")
end
