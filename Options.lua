-- Quest Mob Markers: settings window (/qmm), with a live preview.

local QM = _G.QuestMobMarkers

local panel, preview
local widgets = {}

local SIDES = { "LEFT", "RIGHT", "TOP" }
local SIDE_NAMES = { LEFT = "Left of the bar", RIGHT = "Right of the bar", TOP = "Above the bar" }
local FORMATS = { "count", "left" }
local FORMAT_NAMES = { count = "Progress (3/8)", left = "Still to go (5)" }

local PREVIEW_PROGRESS = { cur = 3, max = 8 }
local PREVIEW_OTHERS = { { name = "Friend", cur = 1, max = 8 } }

function QM.RefreshPreview()
	if not (preview and panel and panel:IsShown()) then return end
	if QM.db.enabled then
		QM.RenderMark(preview.mark, preview.bar, PREVIEW_PROGRESS, PREVIEW_OTHERS, false)
		preview.mark:Show()
	else
		preview.mark:Hide()
	end
end

local function RefreshPanel()
	for _, w in pairs(widgets) do w:Refresh() end
	QM.RefreshPreview()
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------

local function MakeCheck(label, key, x, y)
	local c = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	c:SetPoint("TOPLEFT", x, y)
	local fs = c.Text or c.text or c:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	fs:ClearAllPoints()
	fs:SetPoint("LEFT", c, "RIGHT", 2, 0)
	fs:SetText(label)
	c:SetScript("OnClick", function(self)
		QM.db[key] = self:GetChecked() and true or false
		QM.Apply()
	end)
	c.Refresh = function(self) self:SetChecked(QM.db[key]) end
	widgets[key] = c
	return c
end

local function MakeSlider(label, key, minV, maxV, step, fmt, y)
	local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	fs:SetPoint("TOPLEFT", 16, y)

	local s = CreateFrame("Slider", nil, panel)
	s:SetOrientation("HORIZONTAL")
	s:SetPoint("TOPLEFT", 16, y - 16)
	s:SetSize(288, 16)
	s:SetMinMaxValues(minV, maxV)
	s:SetValueStep(step)
	if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
	s:EnableMouseWheel(true)

	local bg = s:CreateTexture(nil, "BACKGROUND")
	bg:SetPoint("LEFT"); bg:SetPoint("RIGHT")
	bg:SetHeight(6)
	bg:SetColorTexture(0.2, 0.2, 0.2, 1)
	s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")

	local function UpdateLabel(v)
		fs:SetText(label .. ": " .. string.format(fmt, v))
	end
	s:SetScript("OnValueChanged", function(self, v)
		v = math.floor(v / step + 0.5) * step
		if QM.db[key] == v then UpdateLabel(v) return end
		QM.db[key] = v
		UpdateLabel(v)
		QM.Apply()
	end)
	s:SetScript("OnMouseWheel", function(self, d)
		self:SetValue(self:GetValue() + d * step)
	end)
	s.Refresh = function(self)
		self:SetValue(QM.db[key])
		UpdateLabel(QM.db[key])
	end
	widgets[key] = s
	return s
end

-- A button that steps through a fixed list of choices.
local function MakeCycle(label, key, values, names, x, y)
	local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(label)
	local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	b:SetPoint("TOPLEFT", x - 2, y - 14)
	b:SetSize(140, 22)
	b:SetScript("OnClick", function(self)
		local idx = 1
		for i, v in ipairs(values) do if v == QM.db[key] then idx = i end end
		QM.db[key] = values[(idx % #values) + 1]
		self:Refresh()
		QM.Apply()
	end)
	b.Refresh = function(self) self:SetText(names[QM.db[key]] or tostring(QM.db[key])) end
	widgets[key] = b
	return b
end

local function OpenColorPicker(swatch, rk, gk, bk)
	local db = QM.db
	local oldR, oldG, oldB = db[rk], db[gk], db[bk]
	local function OnChange()
		db[rk], db[gk], db[bk] = ColorPickerFrame:GetColorRGB()
		swatch:Refresh()
		QM.Apply()
	end
	local function OnCancel()
		db[rk], db[gk], db[bk] = oldR, oldG, oldB
		swatch:Refresh()
		QM.Apply()
	end
	if ColorPickerFrame.SetupColorPickerAndShow then
		ColorPickerFrame:SetupColorPickerAndShow({
			r = oldR, g = oldG, b = oldB,
			hasOpacity = false,
			swatchFunc = OnChange,
			cancelFunc = OnCancel,
		})
	else
		ColorPickerFrame.hasOpacity = false
		ColorPickerFrame.func = OnChange
		ColorPickerFrame.cancelFunc = OnCancel
		ColorPickerFrame.previousValues = { oldR, oldG, oldB }
		ColorPickerFrame:SetColorRGB(oldR, oldG, oldB)
		ColorPickerFrame:Hide()
		ColorPickerFrame:Show()
	end
end

local function MakeSwatch(label, rk, gk, bk, x, y)
	local swatch = CreateFrame("Button", nil, panel)
	swatch:SetPoint("TOPLEFT", x, y)
	swatch:SetSize(22, 22)
	local border = swatch:CreateTexture(nil, "BACKGROUND")
	border:SetAllPoints()
	border:SetColorTexture(0.6, 0.6, 0.6, 1)
	local fill = swatch:CreateTexture(nil, "ARTWORK")
	fill:SetPoint("TOPLEFT", 2, -2)
	fill:SetPoint("BOTTOMRIGHT", -2, 2)
	local fs = swatch:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	fs:SetPoint("LEFT", swatch, "RIGHT", 6, 0)
	fs:SetText(label)
	swatch:SetScript("OnClick", function(self) OpenColorPicker(self, rk, gk, bk) end)
	swatch.Refresh = function() fill:SetColorTexture(QM.db[rk], QM.db[gk], QM.db[bk], 1) end
	widgets["swatch_" .. rk] = swatch
	return swatch
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------

local function BuildPreview()
	preview = CreateFrame("Frame", nil, panel)
	preview:SetPoint("TOPLEFT", 16, -40)
	preview:SetPoint("TOPRIGHT", -16, -40)
	preview:SetHeight(84)
	local bg = preview:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.12, 0.16, 0.12, 1)

	-- A stand-in nameplate: name + red health bar.
	local bar = CreateFrame("Frame", nil, preview)
	bar:SetSize(110, 11)
	bar:SetPoint("CENTER", 0, -8)
	local border = bar:CreateTexture(nil, "BACKGROUND")
	border:SetPoint("TOPLEFT", -1, 1)
	border:SetPoint("BOTTOMRIGHT", 1, -1)
	border:SetColorTexture(0, 0, 0, 1)
	local fill = bar:CreateTexture(nil, "ARTWORK")
	fill:SetAllPoints()
	fill:SetColorTexture(0.8, 0.1, 0.1, 1)
	local name = bar:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	name:SetPoint("BOTTOM", bar, "TOP", 0, 3)
	name:SetTextColor(1, 0.3, 0.3)
	name:SetText("Quest Mob")

	preview.bar = bar
	preview.mark = QM.CreateMark(preview)
end

local function BuildPanel()
	panel = CreateFrame("Frame", "QuestMobMarkersFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	panel:SetSize(320, 558)
	panel:SetPoint("CENTER")
	panel:SetFrameStrata("DIALOG")
	panel:SetMovable(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", panel.StartMoving)
	panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
	panel:SetClampedToScreen(true)
	if panel.SetBackdrop then
		panel:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 14,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		panel:SetBackdropColor(0.05, 0.05, 0.08, 0.92)
	end
	tinsert(UISpecialFrames, "QuestMobMarkersFrame") -- close with Escape

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -12)
	title:SetText("Quest Mob Markers")

	local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -2, -2)

	BuildPreview()

	MakeCheck("Enabled", "enabled", 12, -132)
	MakeCheck("Hide in combat", "hideInCombat", 160, -132)
	MakeCheck("Show the !", "showIcon", 12, -160)
	MakeCheck("Show progress", "showProgress", 160, -160)
	MakeCheck("Show group progress", "showParty", 12, -188)

	MakeCycle("Position", "side", SIDES, SIDE_NAMES, 16, -226)
	MakeCycle("Progress shows", "format", FORMATS, FORMAT_NAMES, 164, -226)

	MakeSlider("Icon size", "size", 8, 64, 1, "%d px", -278)
	MakeSlider("Text size", "textSize", 6, 32, 1, "%d px", -320)
	MakeSlider("Move sideways", "x", -100, 100, 1, "%d px", -362)
	MakeSlider("Move up / down", "y", -100, 100, 1, "%d px", -404)
	MakeSlider("Opacity", "alpha", 0.2, 1, 0.05, "%.2f", -446)

	MakeSwatch("Text colour", "r", "g", "b", 16, -490)
	MakeSwatch("Group colour", "pr", "pg", "pb", 164, -490)

	local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetPoint("BOTTOMRIGHT", -14, 14)
	reset:SetSize(110, 22)
	reset:SetText("Defaults")
	reset:SetScript("OnClick", function()
		for k, v in pairs(QM.DEFAULTS) do QM.db[k] = v end
		RefreshPanel()
		QM.Apply()
	end)

	panel:SetScript("OnShow", RefreshPanel)
	panel:Hide()
end

function QM.ToggleOptions()
	if not QM.db then return end
	if not panel then BuildPanel() end
	if panel:IsShown() then panel:Hide() else panel:Show() end
end
