# Weapon Holster — Reworked Edition

A modernised rework of the classic Garry's Mod weapon holster addon. Weapons a
player is carrying but not actively holding are shown holstered on their body —
rifles on the back, sidearms on the hip, grenades on the belt, and so on.

The original addon worked but was painful to configure: every weapon needed a
hand-written entry, the editor was a wall of sliders with no visual feedback,
and it only knew about a fixed list of weapon packs. This rework fixes all of
that.

## What's new

### 🔫 Automatic model detection
Weapon world models are pulled straight from each weapon at runtime
(`GetWeaponWorldModel`). You never type a model path again unless you *want* to
override it.

### 🧠 Automatic placement — adapts to any weapon pack
Placement is decided from the weapon's **hold type** (`pistol`, `smg`, `ar2`,
`shotgun`, `grenade`, `melee`, …), not its class name. That means **any** weapon
pack — CW 2.0, M9K, FA:S, ArcCW, TFA, your custom SWEPs — is holstered correctly
the moment it loads, with zero configuration.

Two placement styles, switchable live with one convar:

| Style | Long guns | Sidearms |
|-------|-----------|----------|
| `back` (default) | slung on the back | on the hip |
| `rp` | slung across the **torso** | chest holster |

### 🎨 New UI with a 3D orbit editor
Open the editor and you get a modern, resizable window:

* **Searchable weapon list** built automatically from every loaded pack, with
  `AUTO` / `CUSTOM` badges.
* **A 3D preview of your own player model that you can orbit around** — drag to
  rotate, scroll to zoom, right-drag to change height — so you can line the
  weapon up from every angle.
* **Position / angle / scale sliders** plus one-click **slot presets** (Back,
  Hip, Chest sling, Belt, …).
* Changes update the weapon on the **real in-world player instantly** while you
  edit.

### ⚙️ Cleaner configuration
Everything is driven by console variables (below) and per-weapon JSON files in
`data/weapon_holster/`. Old save files from the original addon are migrated
automatically.

## Usage

* Open the editor: `wh_menu` (or the legacy `weapon_holsters_editor`), or via
  **Utilities → Options → Weapon Holsters → Open Holster Editor**.
* Editing is restricted to **super admins**. Everyone else can open the menu
  read-only and toggle holsters for themselves.

## Console variables

| ConVar | Default | Realm | Description |
|--------|---------|-------|-------------|
| `wh_enabled` | `1` | server | Master switch for the whole system. |
| `wh_placement` | `back` | server | Auto placement style: `back` or `rp`. |
| `wh_auto_holster` | `1` | server | Auto-holster weapons with no saved config. |
| `wh_max_per_player` | `6` | server | Max holstered models drawn per player. |
| `cl_wh_enabled` | `1` | client | Show holsters on players (per client). |
| `cl_wh_drawdistance` | `1024` | client | Max draw distance (0 = unlimited). |

## Permissions

Only super admins may save placements or change server settings by default. To
plug in your own permission system (ULX, serverguard, …) override `WH.CanAdmin`:

```lua
function WH.CanAdmin(ply)
    return ply:IsSuperAdmin() or ply:GetUserGroup() == "developer"
end
```

## File layout

```
lua/
  autorun/weapon_holster_init.lua   -- loader (sets up every realm)
  weapon_holster/
    sh_config.lua                   -- convars, slot presets, hold-type rules
    sh_core.lua                     -- auto-detection, placement, data schema
    sv_holster.lua                  -- persistence + networking + admin actions
    cl_render.lua                   -- drawing holstered weapons on players
    cl_menu.lua                     -- the 3D orbit editor UI
```

## Credits

Original concept by Polyester Duck. Reworked edition: automatic detection,
automatic placement, and the 3D orbit editor.
