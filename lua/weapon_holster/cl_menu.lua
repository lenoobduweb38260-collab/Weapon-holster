--[[----------------------------------------------------------------------------
	cl_menu.lua — Client: modern holster editor.

	A single resizable window with:
	  * a searchable weapon list (auto-detected from every loaded pack),
	  * a 3D preview you can ORBIT around (drag to rotate, wheel to zoom) that
	    shows the weapon on your own player model and updates live,
	  * position / angle / scale sliders with one-click slot presets,
	  * admin-only global settings (placement style, master switch).

	Slider changes update the real in-world model instantly via WH.Preview.
------------------------------------------------------------------------------]]

WH = WH or {}
WH.Menu = WH.Menu or {}

--------------------------------------------------------------------------------
-- Theme
--------------------------------------------------------------------------------
local COL = {
	bg      = Color(22, 24, 29),
	bar     = Color(30, 33, 40),
	panel   = Color(34, 37, 45),
	panel2  = Color(42, 46, 56),
	hover   = Color(52, 57, 69),
	accent  = Color(64, 150, 255),
	accentD = Color(40, 110, 200),
	text    = Color(230, 232, 237),
	textDim = Color(150, 156, 168),
	good    = Color(92, 198, 132),
	bad     = Color(226, 92, 92),
	badge   = Color(64, 150, 255, 40),
	badgeA  = Color(92, 198, 132, 45),
}

local function RoundBox(x, y, w, h, col, r)
	draw.RoundedBox(r or 6, x, y, w, h, col)
end

local calcOffset = function(pos, ang, off)
	return pos + ang:Right() * off.x + ang:Forward() * off.y + ang:Up() * off.z
end

--------------------------------------------------------------------------------
-- Small styled widgets
--------------------------------------------------------------------------------
local function StyledButton(parent, text, col)
	local b = vgui.Create("DButton", parent)
	b:SetText("")
	b.Col = col or COL.panel2
	function b:Paint(w, h)
		local c = self.Col
		if self:IsHovered() then c = COL.hover end
		if not self:IsEnabled() then c = COL.panel end
		RoundBox(0, 0, w, h, c, 5)
		draw.SimpleText(text, "WH_Font", w / 2, h / 2,
			self:IsEnabled() and COL.text or COL.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
	return b
end

local function SectionLabel(parent, text)
	local l = vgui.Create("DLabel", parent)
	l:SetText(string.upper(text))
	l:SetFont("WH_FontSmall")
	l:SetTextColor(COL.textDim)
	l:Dock(TOP)
	l:DockMargin(2, 8, 2, 2)
	l:SetTall(16)
	return l
end

-- Compact labelled slider that writes straight into a target table field.
local function SliderRow(parent, text, min, max, decimals, getf, setf)
	local row = vgui.Create("DPanel", parent)
	row:Dock(TOP)
	row:DockMargin(0, 2, 0, 2)
	row:SetTall(38)
	row.Paint = function() end

	local s = vgui.Create("DNumSlider", row)
	s:Dock(FILL)
	s:SetText(text)
	s:SetMin(min)
	s:SetMax(max)
	s:SetDecimals(decimals)
	s.Label:SetFont("WH_FontSmall")
	s.Label:SetTextColor(COL.text)
	s:SetValue(getf() or 0)

	s.OnValueChanged = function(_, val)
		setf(val)
	end
	row.Slider = s
	return s
end

--------------------------------------------------------------------------------
-- Fonts
--------------------------------------------------------------------------------
surface.CreateFont("WH_Title",     { font = "Roboto", size = 22, weight = 600 })
surface.CreateFont("WH_Font",      { font = "Roboto", size = 17, weight = 500 })
surface.CreateFont("WH_FontSmall", { font = "Roboto", size = 14, weight = 500 })
surface.CreateFont("WH_FontBadge", { font = "Roboto", size = 12, weight = 600 })

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local M = WH.Menu
M.currentClass = nil
M.currentEntry = nil
M.previewModel = nil

local function isAdmin()
	return LocalPlayer():IsSuperAdmin()
end

-- Resolve the model string to show in the preview for the current entry.
local function refreshPreviewModel()
	local e = M.currentEntry
	if not e then M.previewModel = nil return end
	if e.model ~= "" then
		M.previewModel = e.model
	else
		local wep = LocalPlayer():GetWeapon(M.currentClass)
		M.previewModel = WH.ResolveModel(M.currentClass, IsValid(wep) and wep or nil)
	end
end

-- Point the live in-world preview at the current edit so dragging updates it.
local function pushLivePreview()
	if M.currentClass and M.currentEntry then
		WH.Preview = { class = M.currentClass, entry = M.currentEntry }
	end
end

--------------------------------------------------------------------------------
-- 3D orbit preview panel
--------------------------------------------------------------------------------
local function BuildPreview(parent)
	local mdl = vgui.Create("DModelPanel", parent)
	mdl:Dock(FILL)
	mdl:DockMargin(0, 0, 0, 0)
	mdl:SetModel(LocalPlayer():GetModel())
	mdl:SetFOV(50)

	mdl.camYaw    = -35
	mdl.camPitch  = 8
	mdl.camDist   = 115
	mdl.camTarget = Vector(0, 0, 38)
	mdl.idleSeq   = nil

	-- Disable the built-in auto-spin; drive our own orbit camera.
	function mdl:LayoutEntity(ent)
		if not self.idleSeq then
			self.idleSeq = ent:LookupSequence("idle_all_01")
			if self.idleSeq < 0 then self.idleSeq = ent:LookupSequence("idle") end
			if self.idleSeq < 0 then self.idleSeq = 0 end
		end
		ent:SetSequence(self.idleSeq)
		self:RunAnimation()

		local dir = Angle(self.camPitch, self.camYaw, 0):Forward()
		self:SetCamPos(self.camTarget - dir * self.camDist)
		self:SetLookAt(self.camTarget)
	end

	-- Orbit controls.
	function mdl:OnMousePressed(code)
		self.Drag = code
		self.LastX, self.LastY = gui.MousePos()
		self:MouseCapture(true)
	end
	function mdl:OnMouseReleased()
		self.Drag = nil
		self:MouseCapture(false)
	end
	function mdl:Think()
		-- Keep the preview weapon model in sync (created here, NOT during render).
		if M.previewModel then
			if not IsValid(self.WeaponEnt) or self.WeaponEnt:GetModel() ~= M.previewModel then
				if IsValid(self.WeaponEnt) then self.WeaponEnt:Remove() end
				self.WeaponEnt = ClientsideModel(M.previewModel, RENDERGROUP_OPAQUE)
				if IsValid(self.WeaponEnt) then self.WeaponEnt:SetNoDraw(true) end
			end
		elseif IsValid(self.WeaponEnt) then
			self.WeaponEnt:Remove()
		end

		if self.Drag then
			local mx, my = gui.MousePos()
			local dx, dy = mx - self.LastX, my - self.LastY
			self.LastX, self.LastY = mx, my
			if self.Drag == MOUSE_RIGHT then
				self.camTarget = self.camTarget + Vector(0, 0, -dy * 0.3)
			else
				self.camYaw   = self.camYaw - dx * 0.5
				self.camPitch = math.Clamp(self.camPitch + dy * 0.5, -85, 85)
			end
		end
	end
	function mdl:OnMouseWheeled(delta)
		self.camDist = math.Clamp(self.camDist - delta * 9, 35, 220)
	end

	-- Draw the holstered weapon on the previewed player each frame.
	function mdl:PostDrawModel(ent)
		local e = M.currentEntry
		if not e or not M.previewModel then return end

		local wentity = self.WeaponEnt
		if not IsValid(wentity) then return end

		ent:SetupBones()
		local boneId = ent:LookupBone(e.bone)
		if not boneId then return end
		local matrix = ent:GetBoneMatrix(boneId)
		if not matrix then return end

		local pos = matrix:GetTranslation()
		local ang = matrix:GetAngles()
		pos = calcOffset(pos, ang, e.pos)
		ang:RotateAroundAxis(ang:Forward(), e.ang.p)
		ang:RotateAroundAxis(ang:Up(),      e.ang.y)
		ang:RotateAroundAxis(ang:Right(),   e.ang.r)

		wentity:SetRenderOrigin(pos)
		wentity:SetRenderAngles(ang)
		wentity:SetModelScale(e.scale or 1, 0)
		wentity:DrawModel()
		wentity:SetRenderOrigin()
		wentity:SetRenderAngles()
	end

	function mdl:OnRemove()
		if IsValid(self.WeaponEnt) then self.WeaponEnt:Remove() end
	end

	-- Hint overlay.
	mdl.PaintOver = function(self, w, h)
		draw.SimpleText("Drag: rotate   •   Wheel: zoom   •   Right-drag: height",
			"WH_FontSmall", w / 2, h - 14, COL.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	return mdl
end

--------------------------------------------------------------------------------
-- Weapon list row
--------------------------------------------------------------------------------
local function BuildRow(parent, class, onClick)
	local row = parent:Add("DButton")
	row:Dock(TOP)
	row:DockMargin(0, 0, 0, 3)
	row:SetTall(40)
	row:SetText("")

	function row:Paint(w, h)
		local custom = WH.Overrides[class] ~= nil
		local sel = (M.currentClass == class)
		local bg = sel and COL.accentD or (self:IsHovered() and COL.hover or COL.panel2)
		RoundBox(0, 0, w, h, bg, 5)

		draw.SimpleText(WH.PrettyName(class), "WH_Font", 10, 8, COL.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		draw.SimpleText(class, "WH_FontSmall", 10, 23, COL.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

		-- Custom / Auto badge.
		local txt = custom and "CUSTOM" or "AUTO"
		local col = custom and COL.good or COL.accent
		surface.SetFont("WH_FontBadge")
		local tw = surface.GetTextSize(txt)
		local bw = tw + 14
		RoundBox(w - bw - 8, h / 2 - 9, bw, 18, custom and COL.badgeA or COL.badge, 9)
		draw.SimpleText(txt, "WH_FontBadge", w - bw / 2 - 8, h / 2, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	row.DoClick = function() onClick(class) end
	row.Class = class
	return row
end

--------------------------------------------------------------------------------
-- Main window
--------------------------------------------------------------------------------
function M.Open()
	if IsValid(M.Frame) then M.Frame:Close() return end

	local admin = isAdmin()

	local frame = vgui.Create("DFrame")
	M.Frame = frame
	local W, H = math.min(1120, ScrW() - 80), math.min(680, ScrH() - 80)
	frame:SetSize(W, H)
	frame:Center()
	frame:SetTitle("")
	frame:SetDraggable(true)
	frame:SetSizable(true)
	frame:MakePopup()
	frame:ShowCloseButton(false)

	function frame:Paint(w, h)
		RoundBox(0, 0, w, h, COL.bg, 8)
		RoundBox(0, 0, w, 44, COL.bar, 8)
		draw.RoundedBoxEx(0, 0, 30, w, 14, COL.bar, false, false, false, false)
		draw.SimpleText("WEAPON HOLSTER", "WH_Title", 16, 22, COL.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("v" .. WH.Version, "WH_FontSmall", 16 + surface.GetTextSize("WEAPON HOLSTER") + 178, 24, COL.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local close = StyledButton(frame, "✕", COL.bar)
	close:SetSize(30, 26)
	close.DoClick = function() frame:Close() end
	frame.PerformLayout = function(self, w, h)
		if IsValid(close) then close:SetPos(w - 38, 9) end
	end

	frame.OnClose = function()
		WH.Preview = nil
		M.currentClass = nil
		M.currentEntry = nil
	end

	-- Settings bar docked to the bottom FIRST so the body FILL avoids it.
	local bottom = vgui.Create("DPanel", frame)
	bottom:Dock(BOTTOM)
	bottom:DockMargin(8, 0, 8, 8)
	bottom:SetTall(38)
	bottom.Paint = function(_, w, h) RoundBox(0, 0, w, h, COL.panel, 6) end

	-- Body container below the title bar.
	local body = vgui.Create("DPanel", frame)
	body:Dock(FILL)
	body:DockMargin(8, 48, 8, 8)
	body.Paint = function() end

	----------------------------------------------------------------------------
	-- LEFT column : search + weapon list + quick add
	----------------------------------------------------------------------------
	local left = vgui.Create("DPanel", body)
	left:Dock(LEFT)
	left:SetWide(300)
	left:DockMargin(0, 0, 8, 0)
	left.Paint = function(_, w, h) RoundBox(0, 0, w, h, COL.panel, 6) end

	local search = vgui.Create("DTextEntry", left)
	search:Dock(TOP)
	search:DockMargin(8, 8, 8, 4)
	search:SetTall(28)
	search:SetPlaceholderText("Search weapons…")
	search:SetUpdateOnType(true)

	local showAll = vgui.Create("DCheckBoxLabel", left)
	showAll:Dock(TOP)
	showAll:DockMargin(10, 2, 8, 4)
	showAll:SetText("Show every registered weapon")
	showAll:SetTextColor(COL.textDim)
	showAll:SetValue(false)

	local scroll = vgui.Create("DScrollPanel", left)
	scroll:Dock(FILL)
	scroll:DockMargin(8, 4, 4, 8)

	local function selectWeapon(class) end -- forward declare

	local function repopulate()
		scroll:Clear()
		local q = string.lower(string.Trim(search:GetValue() or ""))

		-- Build the candidate set.
		local set = {}
		for class in pairs(WH.Overrides) do set[class] = true end
		for _, wep in ipairs(LocalPlayer():GetWeapons()) do
			if IsValid(wep) then set[wep:GetClass()] = true end
		end
		if showAll:GetChecked() or q ~= "" then
			for _, sw in ipairs(weapons.GetList()) do
				if sw.ClassName then set[sw.ClassName] = true end
			end
		end

		-- Filter + sort.
		local list = {}
		for class in pairs(set) do
			if not WH.ClassBlacklist[class] then
				local name = string.lower(WH.PrettyName(class))
				if q == "" or string.find(name, q, 1, true) or string.find(string.lower(class), q, 1, true) then
					list[#list + 1] = class
				end
			end
		end
		table.sort(list, function(a, b) return WH.PrettyName(a) < WH.PrettyName(b) end)

		for _, class in ipairs(list) do
			BuildRow(scroll, class, function(c) selectWeapon(c) end)
		end

		if #list == 0 then
			local l = scroll:Add("DLabel")
			l:Dock(TOP)
			l:SetTall(30)
			l:SetContentAlignment(5)
			l:SetTextColor(COL.textDim)
			l:SetText("No weapons found.")
		end
	end

	search.OnValueChange = repopulate
	showAll.OnChange = repopulate

	-- Quick action: edit the weapon currently in hands.
	local quick = StyledButton(left, "Edit held weapon", COL.accentD)
	quick:Dock(BOTTOM)
	quick:DockMargin(8, 4, 8, 8)
	quick:SetTall(30)
	quick.DoClick = function()
		local wep = LocalPlayer():GetActiveWeapon()
		if IsValid(wep) then
			search:SetValue("")
			selectWeapon(wep:GetClass())
			repopulate()
		end
	end

	----------------------------------------------------------------------------
	-- CENTER : 3D orbit preview
	----------------------------------------------------------------------------
	local center = vgui.Create("DPanel", body)
	center:Dock(FILL)
	center:DockMargin(0, 0, 8, 0)
	center.Paint = function(_, w, h) RoundBox(0, 0, w, h, COL.panel, 6) end

	local previewHolder = vgui.Create("DPanel", center)
	previewHolder:Dock(FILL)
	previewHolder:DockMargin(6, 6, 6, 6)
	previewHolder.Paint = function(_, w, h) RoundBox(0, 0, w, h, Color(15, 16, 20), 6) end

	local preview = BuildPreview(previewHolder)

	local emptyHint = vgui.Create("DLabel", previewHolder)
	emptyHint:Dock(FILL)
	emptyHint:SetContentAlignment(5)
	emptyHint:SetTextColor(COL.textDim)
	emptyHint:SetFont("WH_Font")
	emptyHint:SetText("← Select a weapon to position it")
	emptyHint:SetMouseInputEnabled(false)

	----------------------------------------------------------------------------
	-- RIGHT : property editor
	----------------------------------------------------------------------------
	local right = vgui.Create("DPanel", body)
	right:Dock(RIGHT)
	right:SetWide(310)
	right.Paint = function(_, w, h) RoundBox(0, 0, w, h, COL.panel, 6) end

	local rscroll = vgui.Create("DScrollPanel", right)
	rscroll:Dock(FILL)
	rscroll:DockMargin(10, 10, 6, 10)

	-- Title of the selected weapon.
	local selTitle = rscroll:Add("DLabel")
	selTitle:Dock(TOP)
	selTitle:SetTall(24)
	selTitle:SetFont("WH_Title")
	selTitle:SetTextColor(COL.text)
	selTitle:SetText("No weapon selected")

	local editorPanel = rscroll:Add("DPanel")
	editorPanel:Dock(TOP)
	editorPanel:DockMargin(0, 4, 0, 0)
	editorPanel:SetTall(640)
	editorPanel.Paint = function() end
	editorPanel:SetVisible(false)

	-- Slot preset dropdown.
	SectionLabel(editorPanel, "Slot preset")
	local slotBox = vgui.Create("DComboBox", editorPanel)
	slotBox:Dock(TOP)
	slotBox:DockMargin(0, 0, 0, 2)
	slotBox:SetTall(26)
	slotBox:SetTextColor(COL.text)
	for _, slotName in ipairs(WH.SlotOrder) do
		slotBox:AddChoice(WH.Slots[slotName].label, slotName)
	end

	-- Bone dropdown.
	SectionLabel(editorPanel, "Bone")
	local boneBox = vgui.Create("DComboBox", editorPanel)
	boneBox:Dock(TOP)
	boneBox:DockMargin(0, 0, 0, 2)
	boneBox:SetTall(26)
	boneBox:SetTextColor(COL.text)
	for _, b in ipairs(WH.PlayerBones) do
		boneBox:AddChoice(b, b)
	end

	-- Model field + auto toggle.
	SectionLabel(editorPanel, "Model  (empty = auto-detect)")
	local modelEntry = vgui.Create("DTextEntry", editorPanel)
	modelEntry:Dock(TOP)
	modelEntry:DockMargin(0, 0, 0, 2)
	modelEntry:SetTall(24)
	modelEntry:SetPlaceholderText("auto")

	-- Position / angle / scale sliders. Setters guard against a nil entry
	-- because DNumSlider:SetValue fires OnValueChanged during construction.
	SectionLabel(editorPanel, "Position")
	local sPosX = SliderRow(editorPanel, "X", -25, 25, 2,
		function() return M.currentEntry and M.currentEntry.pos.x end,
		function(v) if M.currentEntry then M.currentEntry.pos.x = v end end)
	local sPosY = SliderRow(editorPanel, "Y", -25, 25, 2,
		function() return M.currentEntry and M.currentEntry.pos.y end,
		function(v) if M.currentEntry then M.currentEntry.pos.y = v end end)
	local sPosZ = SliderRow(editorPanel, "Z", -25, 25, 2,
		function() return M.currentEntry and M.currentEntry.pos.z end,
		function(v) if M.currentEntry then M.currentEntry.pos.z = v end end)

	SectionLabel(editorPanel, "Angle")
	local sAngP = SliderRow(editorPanel, "Pitch", -180, 180, 1,
		function() return M.currentEntry and M.currentEntry.ang.p end,
		function(v) if M.currentEntry then M.currentEntry.ang.p = v end end)
	local sAngY = SliderRow(editorPanel, "Yaw", -180, 180, 1,
		function() return M.currentEntry and M.currentEntry.ang.y end,
		function(v) if M.currentEntry then M.currentEntry.ang.y = v end end)
	local sAngR = SliderRow(editorPanel, "Roll", -180, 180, 1,
		function() return M.currentEntry and M.currentEntry.ang.r end,
		function(v) if M.currentEntry then M.currentEntry.ang.r = v end end)

	SectionLabel(editorPanel, "Scale")
	local sScale = SliderRow(editorPanel, "Scale", 0.2, 3, 2,
		function() return M.currentEntry and M.currentEntry.scale end,
		function(v) if M.currentEntry then M.currentEntry.scale = v end end)

	-- Action buttons.
	local btnApply = StyledButton(editorPanel, "Apply & Save", COL.accentD)
	btnApply:Dock(TOP)
	btnApply:DockMargin(0, 12, 0, 4)
	btnApply:SetTall(32)

	local btnReset = StyledButton(editorPanel, "Reset to auto", COL.panel2)
	btnReset:Dock(TOP)
	btnReset:DockMargin(0, 0, 0, 4)
	btnReset:SetTall(28)

	local btnDelete = StyledButton(editorPanel, "Delete override", COL.panel2)
	btnDelete:Dock(TOP)
	btnDelete:DockMargin(0, 0, 0, 4)
	btnDelete:SetTall(28)
	btnDelete.Col = COL.panel2

	if not admin then
		btnApply:SetEnabled(false)
		btnReset:SetEnabled(false)
		btnDelete:SetEnabled(false)
	end

	----------------------------------------------------------------------------
	-- Loading an entry into the editor controls
	----------------------------------------------------------------------------
	local function syncControls()
		local e = M.currentEntry
		if not e then return end
		slotBox:SetValue(WH.Slots[e.slot] and WH.Slots[e.slot].label or "Custom")
		boneBox:SetValue(e.bone)
		modelEntry:SetText(e.model or "")
		sPosX:SetValue(e.pos.x); sPosY:SetValue(e.pos.y); sPosZ:SetValue(e.pos.z)
		sAngP:SetValue(e.ang.p); sAngY:SetValue(e.ang.y); sAngR:SetValue(e.ang.r)
		sScale:SetValue(e.scale or 1)
	end

	-- Deep copy so edits don't touch live data until Apply.
	local function cloneEntry(src)
		return WH.NewEntry({
			model = src.model,
			bone  = src.bone,
			pos   = Vector(src.pos),
			ang   = Angle(src.ang),
			scale = src.scale,
			slot  = src.slot,
			auto  = src.auto,
		})
	end

	function selectWeapon(class)
		M.currentClass = class
		local base = WH.Overrides[class] or WH.BuildAutoEntry(class) or WH.NewEntry()
		M.currentEntry = cloneEntry(base)

		refreshPreviewModel()
		pushLivePreview()
		syncControls()

		selTitle:SetText(WH.PrettyName(class))
		editorPanel:SetVisible(true)
		emptyHint:SetVisible(false)
	end

	slotBox.OnSelect = function(_, _, _, slotName)
		local slot = WH.Slots[slotName]
		local e = M.currentEntry
		if not slot or not e then return end
		e.slot = slotName
		e.bone = slot.bone
		e.pos  = Vector(slot.pos)
		e.ang  = Angle(slot.ang)
		syncControls()
	end

	boneBox.OnSelect = function(_, _, _, bone)
		if M.currentEntry then M.currentEntry.bone = bone end
	end

	modelEntry.OnValueChange = function(_, val)
		if M.currentEntry then
			M.currentEntry.model = string.Trim(val)
			refreshPreviewModel()
		end
	end

	btnApply.DoClick = function()
		if not M.currentEntry or not M.currentClass then return end
		M.currentEntry.auto = false
		WH.Overrides[M.currentClass] = cloneEntry(M.currentEntry)

		net.Start("wh_save")
		net.WriteString(M.currentClass)
		net.WriteTable(M.currentEntry)
		net.SendToServer()

		surface.PlaySound("buttons/button14.wav")
		repopulate()
	end

	btnReset.DoClick = function()
		if not M.currentClass then return end
		net.Start("wh_delete")
		net.WriteString(M.currentClass)
		net.SendToServer()

		WH.Overrides[M.currentClass] = nil
		WH.ClearAutoCache()
		local auto = WH.BuildAutoEntry(M.currentClass) or WH.NewEntry()
		M.currentEntry = cloneEntry(auto)
		refreshPreviewModel()
		pushLivePreview()
		syncControls()
		repopulate()
	end

	btnDelete.DoClick = function()
		if not M.currentClass then return end
		net.Start("wh_delete")
		net.WriteString(M.currentClass)
		net.SendToServer()
		WH.Overrides[M.currentClass] = nil
		WH.ClearAutoCache()
		WH.Preview = nil
		M.currentClass = nil
		M.currentEntry = nil
		editorPanel:SetVisible(false)
		emptyHint:SetVisible(true)
		selTitle:SetText("No weapon selected")
		repopulate()
	end

	----------------------------------------------------------------------------
	-- BOTTOM : settings bar (panel already created + docked above)
	----------------------------------------------------------------------------
	-- Client toggle (everyone).
	local cTgl = vgui.Create("DCheckBoxLabel", bottom)
	cTgl:Dock(LEFT)
	cTgl:DockMargin(12, 11, 0, 0)
	cTgl:SetText("Show holsters (me)")
	cTgl:SetTextColor(COL.text)
	cTgl:SetConVar("cl_wh_enabled")

	if admin then
		-- Placement style.
		local styleLbl = vgui.Create("DLabel", bottom)
		styleLbl:Dock(LEFT)
		styleLbl:DockMargin(24, 0, 6, 0)
		styleLbl:SetText("Placement:")
		styleLbl:SetTextColor(COL.textDim)
		styleLbl:SizeToContents()
		styleLbl:CenterVertical()

		local styleBox = vgui.Create("DComboBox", bottom)
		styleBox:Dock(LEFT)
		styleBox:DockMargin(0, 7, 0, 7)
		styleBox:SetWide(150)
		styleBox:SetTextColor(COL.text)
		styleBox:AddChoice("Back / hip", "back")
		styleBox:AddChoice("RP (torso)", "rp")
		styleBox:SetValue(WH.PlacementStyle() == "rp" and "RP (torso)" or "Back / hip")
		styleBox.OnSelect = function(_, _, _, val)
			net.Start("wh_setting")
			net.WriteString("wh_placement")
			net.WriteString(val)
			net.SendToServer()
		end

		-- Master enable.
		local mTgl = vgui.Create("DCheckBoxLabel", bottom)
		mTgl:Dock(LEFT)
		mTgl:DockMargin(24, 11, 0, 0)
		mTgl:SetText("System enabled (server)")
		mTgl:SetTextColor(COL.text)
		mTgl:SetChecked(WH.Enabled())
		mTgl.OnChange = function(_, v)
			net.Start("wh_setting")
			net.WriteString("wh_enabled")
			net.WriteString(v and "1" or "0")
			net.SendToServer()
		end
	end

	local credit = vgui.Create("DLabel", bottom)
	credit:Dock(RIGHT)
	credit:DockMargin(0, 0, 12, 0)
	credit:SetText(admin and "Super Admin" or "Read-only (not admin)")
	credit:SetTextColor(admin and COL.good or COL.textDim)
	credit:SizeToContents()
	credit:CenterVertical()

	repopulate()
end

function M.Close()
	if IsValid(M.Frame) then M.Frame:Close() end
end

function M.Toggle()
	if IsValid(M.Frame) then M.Frame:Close() else M.Open() end
end

--------------------------------------------------------------------------------
-- Access points
--------------------------------------------------------------------------------
concommand.Add("weapon_holsters_editor", M.Toggle)  -- legacy name kept
concommand.Add("wh_menu", M.Toggle)

-- Spawnmenu tool option.
hook.Add("PopulateToolMenu", "WH_ToolMenu", function()
	spawnmenu.AddToolMenuOption("Options", "Player", "wh_editor",
		"Weapon Holsters", "", "", function(panel)
			panel:ClearControls()
			panel:CheckBox("Show holsters on players (me)", "cl_wh_enabled")
			panel:NumSlider("Draw distance", "cl_wh_drawdistance", 0, 4096, 0)
			local b = panel:Button("Open Holster Editor", "wh_menu")
			b:SetTall(40)
		end)
end)
