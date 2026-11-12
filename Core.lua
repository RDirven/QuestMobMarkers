-- Quest Mob Markers: a yellow ! on the nameplate of mobs you still need for a quest.
--
-- The game already knows which mobs are quest mobs: it says so in the unit
-- tooltip (quest title + your progress). This addon reads that same tooltip
-- for every visible nameplate, so no quest database is needed and the mark
-- disappears as soon as your objective for that mob is done.

local ADDON = ...
local QM = {}
_G.QuestMobMarkers = QM

local DEFAULTS = { enabled = true, size = 22, x = -2, y = 0 }
local db

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Quest Mob Markers|r: " .. tostring(msg))
end

local function IsSecret(v)
	return issecretvalue ~= nil and issecretvalue(v)
end

-- Plain, trimmed text of a tooltip line; nil when unusable.
local function Clean(text)
	if type(text) ~= "string" or IsSecret(text) then return nil end
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	text = text:match("^%s*(.-)%s*$")
	if text == "" then return nil end
	return text
end

---------------------------------------------------------------------------
-- Quest log titles (to recognise the quest title line in a tooltip)
---------------------------------------------------------------------------

local questTitles = {}

local function RebuildQuestTitles()
	wipe(questTitles)
	if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
		for i = 1, C_QuestLog.GetNumQuestLogEntries() do
			local info = C_QuestLog.GetInfo(i)
			if info and not info.isHeader then
				local title = Clean(info.title)
				if title then questTitles[title] = true end
			end
		end
	elseif GetNumQuestLogEntries and GetQuestLogTitle then
		for i = 1, GetNumQuestLogEntries() do
			local title, _, _, isHeader = GetQuestLogTitle(i)
			if not isHeader then
				title = Clean(title)
				if title then questTitles[title] = true end
			end
		end
	end
end

---------------------------------------------------------------------------
-- Reading the unit tooltip
---------------------------------------------------------------------------

local LineType = Enum and Enum.TooltipDataLineType or {}
local scanTip

-- Returns a list of { text, kind, completed } or nil when no tooltip could be
-- read at all. kind is "title" / "objective" / "player" when the client tells
-- us, otherwise nil.
local function TooltipLines(unit)
	local lines = {}

	if C_TooltipInfo and C_TooltipInfo.GetUnit then
		local ok, data = pcall(C_TooltipInfo.GetUnit, unit)
		if ok and type(data) == "table" and type(data.lines) == "table" then
			for i, line in ipairs(data.lines) do
				if i > 1 then
					local text = Clean(line.leftText)
					if text then
						local kind
						local t = line.type
						if t ~= nil and not IsSecret(t) then
							if t == LineType.QuestTitle then kind = "title"
							elseif t == LineType.QuestObjective then kind = "objective"
							elseif t == LineType.QuestPlayer then kind = "player" end
						end
						local completed = line.completed
						if IsSecret(completed) then completed = nil end
						lines[#lines + 1] = { text = text, kind = kind, completed = completed }
					end
				end
			end
			return lines, "C_TooltipInfo"
		end
	end

	if not scanTip then
		scanTip = CreateFrame("GameTooltip", "QuestMobMarkersScanTip", nil, "GameTooltipTemplate")
	end
	scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
	scanTip:ClearLines()
	local ok = pcall(scanTip.SetUnit, scanTip, unit)
	if not ok then return nil end
	for i = 2, scanTip:NumLines() do
		local fs = _G["QuestMobMarkersScanTipTextLeft" .. i]
		local text = fs and Clean(fs:GetText())
		if text then lines[#lines + 1] = { text = text } end
	end
	scanTip:Hide()
	return lines, "GameTooltip"
end

-- Names of the other people in my group: in a group the tooltip lists every
-- member's progress under their name, and only mine should count.
local groupNames = {}

local function RebuildGroupNames()
	wipe(groupNames)
	if not (IsInGroup and IsInGroup()) then return end
	local raid = IsInRaid and IsInRaid()
	local n = GetNumGroupMembers and GetNumGroupMembers() or 0
	for i = 1, n do
		local name = UnitName((raid and "raid" or "party") .. i)
		if type(name) == "string" and not IsSecret(name) then groupNames[name] = true end
	end
end

-- true = still to do, false = done, nil = this line shows no progress.
local function LineOpen(line)
	if line.completed == true then return false end
	local cur, max = line.text:match("(%d+)%s*/%s*(%d+)")
	if cur then return tonumber(cur) < tonumber(max) end
	local pct = line.text:match("(%d+)%s*%%")
	if pct then return tonumber(pct) < 100 end
	if line.kind == "objective" then return true end
	return nil
end

-- Does this tooltip say I still need this unit for a quest?
local function LinesNeedUnit(lines)
	local myName = UnitName("player")
	local inQuest, mine = false, true
	local myLines, otherLines, anyOpen = 0, 0, false
	local need = false

	local function CloseQuest()
		if inQuest and (anyOpen or (myLines == 0 and otherLines == 0)) then need = true end
	end

	for _, line in ipairs(lines) do
		local kind = line.kind
		if not kind then
			if questTitles[line.text] then kind = "title"
			elseif inQuest and (line.text == myName or groupNames[line.text]) then kind = "player" end
		end

		if kind == "title" then
			CloseQuest()
			inQuest, mine = true, true
			myLines, otherLines, anyOpen = 0, 0, false
		elseif kind == "player" then
			mine = (line.text == myName)
		elseif inQuest then
			local open = LineOpen(line)
			if open ~= nil then
				if mine then
					myLines = myLines + 1
					if open then anyOpen = true end
				else
					otherLines = otherLines + 1
				end
			end
		end
	end
	CloseQuest()
	return need
end

local function UnitIsQuestMob(unit)
	local isPlayer = UnitIsPlayer(unit)
	if not IsSecret(isPlayer) and isPlayer then return false end

	local lines, method = TooltipLines(unit)
	if lines then return LinesNeedUnit(lines), method end

	-- No readable tooltip: ask the game directly if this client can.
	if C_QuestLog and C_QuestLog.UnitIsRelatedToActiveQuest then
		local ok, related = pcall(C_QuestLog.UnitIsRelatedToActiveQuest, unit)
		if ok and not IsSecret(related) then return related and true or false, "UnitIsRelatedToActiveQuest" end
	end
	return false, "none"
end

---------------------------------------------------------------------------
-- The mark on the nameplate
---------------------------------------------------------------------------

local marks = {}   -- nameplate frame -> mark frame
local units = {}   -- unit token -> true, for every visible nameplate

local function ApplyLayout(mark, plate)
	local uf = plate.UnitFrame
	local bar = uf and (uf.healthBar or uf.HealthBarsContainer or uf.healthbar)
	mark:ClearAllPoints()
	mark:SetSize(db.size, db.size)
	mark:SetPoint("RIGHT", bar or plate, "LEFT", db.x, db.y)
end

local function GetMark(plate)
	local mark = marks[plate]
	if mark then return mark end

	mark = CreateFrame("Frame", nil, plate)
	mark:SetFrameStrata("HIGH")
	mark.icon = mark:CreateTexture(nil, "OVERLAY")
	mark.icon:SetAllPoints()
	local loaded = mark.icon:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
	if loaded == false then
		-- Texture missing in this client: draw the ! as text instead.
		mark.icon:Hide()
		mark.text = mark:CreateFontString(nil, "OVERLAY")
		mark.text:SetFont(STANDARD_TEXT_FONT, 24, "OUTLINE")
		mark.text:SetTextColor(1, 0.82, 0)
		mark.text:SetText("!")
		mark.text:SetPoint("CENTER")
	end
	mark:Hide()
	marks[plate] = mark
	return mark
end

local function UpdateUnit(unit)
	local plate = C_NamePlate.GetNamePlateForUnit(unit)
	if not plate then return end
	local show = db.enabled and UnitIsQuestMob(unit)
	if show then
		local mark = GetMark(plate)
		ApplyLayout(mark, plate)
		mark:Show()
	elseif marks[plate] then
		marks[plate]:Hide()
	end
end

local function UpdateAll()
	for unit in pairs(units) do UpdateUnit(unit) end
end

-- Quest events come in bursts; refresh once, a moment later.
local pending = false
local function QueueUpdate()
	if pending then return end
	pending = true
	C_Timer.After(0.2, function()
		pending = false
		RebuildQuestTitles()
		RebuildGroupNames()
		UpdateAll()
	end)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local frame = CreateFrame("Frame")

local function Register(event)
	pcall(frame.RegisterEvent, frame, event)
end

frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then return end
		QuestMobMarkersDB = QuestMobMarkersDB or {}
		db = QuestMobMarkersDB
		for k, v in pairs(DEFAULTS) do
			if db[k] == nil then db[k] = v end
		end
		frame:UnregisterEvent("ADDON_LOADED")
		if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then
			Print("this client has no nameplate API, the addon can't work here.")
			return
		end
		Register("NAME_PLATE_UNIT_ADDED")
		Register("NAME_PLATE_UNIT_REMOVED")
		Register("PLAYER_ENTERING_WORLD")
		Register("QUEST_LOG_UPDATE")
		Register("UNIT_QUEST_LOG_CHANGED")
		Register("QUEST_ACCEPTED")
		Register("QUEST_REMOVED")
		Register("QUEST_TURNED_IN")
		Register("GROUP_ROSTER_UPDATE")
	elseif event == "NAME_PLATE_UNIT_ADDED" then
		units[arg1] = true
		UpdateUnit(arg1)
		-- The tooltip of a mob that just came into view can still be empty.
		C_Timer.After(0.5, function()
			if units[arg1] then UpdateUnit(arg1) end
		end)
	elseif event == "NAME_PLATE_UNIT_REMOVED" then
		units[arg1] = nil
		local plate = C_NamePlate.GetNamePlateForUnit(arg1)
		if plate and marks[plate] then marks[plate]:Hide() end
	else
		QueueUpdate()
	end
end)

---------------------------------------------------------------------------
-- /qmm
---------------------------------------------------------------------------

local function Debug()
	RebuildQuestTitles()
	RebuildGroupNames()
	local nTitles, nPlates = 0, 0
	for _ in pairs(questTitles) do nTitles = nTitles + 1 end
	for _ in pairs(units) do nPlates = nPlates + 1 end
	Print(("%d quests in log, %d nameplates visible."):format(nTitles, nPlates))
	Print(("C_TooltipInfo: %s, UnitIsRelatedToActiveQuest: %s"):format(
		tostring(C_TooltipInfo ~= nil and C_TooltipInfo.GetUnit ~= nil),
		tostring(C_QuestLog ~= nil and C_QuestLog.UnitIsRelatedToActiveQuest ~= nil)))
	if not UnitExists("target") then
		Print("target a mob and run /qmm debug again to see what its tooltip says.")
		return
	end
	local need, method = UnitIsQuestMob("target")
	Print(("target: quest mob = %s (via %s)"):format(tostring(need), tostring(method)))
	local lines = TooltipLines("target")
	for i, line in ipairs(lines or {}) do
		Print(("  %d [%s] %s"):format(i, line.kind or (questTitles[line.text] and "title?" or "-"), line.text))
	end
end

SLASH_QUESTMOBMARKERS1 = "/qmm"
SLASH_QUESTMOBMARKERS2 = "/questmobmarkers"
SlashCmdList.QUESTMOBMARKERS = function(msg)
	local cmd, rest = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "on" or cmd == "off" then
		db.enabled = (cmd == "on")
		Print(db.enabled and "on." or "off.")
	elseif cmd == "size" and tonumber(rest) then
		db.size = math.max(8, math.min(64, tonumber(rest)))
		Print("size " .. db.size .. ".")
	elseif cmd == "pos" then
		local x, y = rest:match("^(-?%d+)%s+(-?%d+)$")
		if not x then Print("usage: /qmm pos <x> <y>   (default -2 0)") return end
		db.x, db.y = tonumber(x), tonumber(y)
		Print(("position %d, %d."):format(db.x, db.y))
	elseif cmd == "debug" then
		Debug()
		return
	else
		Print("/qmm on | off  -  /qmm size <8-64>  -  /qmm pos <x> <y>  -  /qmm debug")
		return
	end
	UpdateAll()
end
