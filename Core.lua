-- Quest Mob Markers: a yellow ! on the nameplate of mobs you still need for a quest.
--
-- The game already knows which mobs are quest mobs: it says so in the unit
-- tooltip (quest title + your progress). This addon reads that same tooltip
-- for every visible nameplate, so no quest database is needed and the mark
-- disappears as soon as your objective for that mob is done.

local ADDON = ...
local QM = {}
_G.QuestMobMarkers = QM

local DEFAULTS = {
	enabled = true,
	showIcon = true,        -- the yellow !
	showProgress = true,    -- "3/8" next to it
	format = "count",       -- "count" = 3/8, "left" = how many still to go
	side = "LEFT",          -- LEFT / RIGHT / TOP of the health bar
	size = 22,              -- icon size
	textSize = 12,
	x = 0, y = 0,
	alpha = 1,
	r = 1, g = 0.82, b = 0, -- progress text colour
	hideInCombat = false,
	showParty = true,       -- progress of group members, in their own colour
	pr = 0.4, pg = 0.8, pb = 1,
}
QM.DEFAULTS = DEFAULTS
local db
local inCombat = false

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
-- Second result: the progress as { cur, max, pct = true|nil } when known.
local function LineOpen(line)
	if line.completed == true then return false end
	local cur, max = line.text:match("(%d+)%s*/%s*(%d+)")
	if cur then
		cur, max = tonumber(cur), tonumber(max)
		return cur < max, { cur = cur, max = max }
	end
	local pct = line.text:match("(%d+)%s*%%")
	if pct then
		pct = tonumber(pct)
		return pct < 100, { cur = pct, max = 100, pct = true }
	end
	if line.kind == "objective" then return true end
	return nil
end

-- Does this tooltip say I still need this unit for a quest?
-- Also returns the progress of every unfinished objective of mine that has a
-- number (one mob can count for several quests), as a list or nil.
local function LinesNeedUnit(lines)
	local myName = UnitName("player")
	local inQuest, mine, sawMe = false, true, false
	local myLines, otherLines, anyOpen, otherOpen = 0, 0, false, false
	local need = false
	local progress, otherProgress = {}, {}
	local others = {}       -- unfinished progress of group members, one per player
	local blockOthers = {}  -- the same, for the quest being read
	local currentOther      -- whose lines are being read (nil = mine / unknown)

	-- The name on a "whose progress is this" line, however the client writes
	-- it: "Name", "Name-Realm" or "Name:".
	local function PlayerOn(text)
		local name = text:match("^([^%-:]+)")
		name = name and name:match("^%s*(.-)%s*$")
		if name == myName then return name, true end
		if groupNames[name] then return name, false end
		return nil
	end

	local function CloseQuest()
		if not inQuest then return end
		if otherOpen and not sawMe and not anyOpen and myLines == 0 then
			-- Only other names were listed, so the tooltip did not say which
			-- lines are mine. Better a mark too many than none at all.
			need = true
			for _, p in ipairs(otherProgress) do progress[#progress + 1] = p end
		else
			if anyOpen or (myLines == 0 and otherLines == 0) then need = true end
			for _, o in ipairs(blockOthers) do others[#others + 1] = o end
		end
		blockOthers = {}
	end

	for _, line in ipairs(lines) do
		local kind = line.kind
		local isMe, playerName
		if kind == "player" then
			local name, me = PlayerOn(line.text)
			isMe = name ~= nil and me
			playerName = name or line.text
		elseif not kind then
			if questTitles[line.text] then
				kind = "title"
			elseif inQuest and LineOpen(line) == nil then
				local name, me = PlayerOn(line.text)
				if name then kind, isMe, playerName = "player", me, name end
			end
		end

		if kind == "title" then
			CloseQuest()
			inQuest, mine, sawMe = true, true, false
			myLines, otherLines, anyOpen, otherOpen = 0, 0, false, false
			otherProgress, currentOther = {}, nil
		elseif kind == "player" then
			mine = isMe
			if isMe then sawMe = true end
			currentOther = (not isMe) and { name = playerName } or nil
		elseif inQuest then
			local open, prog = LineOpen(line)
			if open ~= nil then
				if mine then
					myLines = myLines + 1
					if open then
						anyOpen = true
						if prog then progress[#progress + 1] = prog end
					end
				else
					otherLines = otherLines + 1
					if open then
						otherOpen = true
						if prog then otherProgress[#otherProgress + 1] = prog end
						if prog and currentOther and not currentOther.cur then
							currentOther.cur, currentOther.max, currentOther.pct = prog.cur, prog.max, prog.pct
							blockOthers[#blockOthers + 1] = currentOther
						end
					end
				end
			end
		end
	end
	CloseQuest()
	return need, (#progress > 0) and progress or nil, others
end

-- Returns: needed (bool), how it was detected, list of my progress or nil,
-- list of group members' progress.
local function UnitIsQuestMob(unit)
	local isPlayer = UnitIsPlayer(unit)
	if not IsSecret(isPlayer) and isPlayer then return false end

	local lines, method = TooltipLines(unit)
	if lines then
		local need, progress, others = LinesNeedUnit(lines)
		return need, method, progress, others
	end

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

local GAP = 2 -- pixels between the health bar and the mark

local function FormatProgress(progress)
	local cur, max = progress.cur, progress.max
	if db.format == "left" then
		return (max - cur) .. (progress.pct and "%" or "")
	end
	if progress.pct then return cur .. "%" end
	return cur .. "/" .. max
end

-- All my open objectives for this mob: "3/8 0/4".
local function ProgressText(progress)
	if not (db.showProgress and progress and #progress > 0) then return "" end
	local parts = {}
	for i, p in ipairs(progress) do parts[i] = FormatProgress(p) end
	return table.concat(parts, "\n")
end

-- The progress of every group member that still needs the mob: "1/8 4/8".
local function PartyText(others)
	if not (db.showParty and others and #others > 0) then return "" end
	local parts = {}
	for i, o in ipairs(others) do parts[i] = FormatProgress(o) end
	return table.concat(parts, "\n")
end

-- A mark is the ! plus the progress text. Also used for the preview in the
-- settings window, so it takes any parent.
function QM.CreateMark(parent)
	local mark = CreateFrame("Frame", nil, parent)
	mark:SetFrameLevel(parent:GetFrameLevel() + 10)
	mark.icon = mark:CreateTexture(nil, "OVERLAY")
	mark.icon:SetAllPoints()
	local loaded = mark.icon:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
	if loaded == false then
		-- Texture missing in this client: draw the ! as text instead.
		mark.icon:Hide()
		mark.icon = mark:CreateFontString(nil, "OVERLAY")
		mark.icon:SetPoint("CENTER")
		mark.iconIsText = true
	end
	mark.text = mark:CreateFontString(nil, "OVERLAY")
	mark.party = mark:CreateFontString(nil, "OVERLAY")
	mark:Hide()
	return mark
end

-- Lay a mark out against the health bar (or whatever stands in for it).
-- progress: mine (nil when I don't need the mob or it has no number).
-- others: unfinished progress of group members. partyOnly: only they need it.
function QM.RenderMark(mark, anchor, progress, others, partyOnly)
	local side = db.side
	mark:ClearAllPoints()
	mark:SetSize(db.size, db.size)
	mark:SetAlpha(db.alpha)
	if side == "RIGHT" then
		mark:SetPoint("LEFT", anchor, "RIGHT", GAP + db.x, db.y)
	elseif side == "TOP" then
		mark:SetPoint("BOTTOM", anchor, "TOP", db.x, 14 + db.y)
	else
		mark:SetPoint("RIGHT", anchor, "LEFT", -GAP + db.x, db.y)
	end

	local label = partyOnly and "" or ProgressText(progress)
	local partyLabel = PartyText(others)
	-- With nothing to write the ! always shows, or the mob would get no mark.
	local showIcon = db.showIcon or (label == "" and partyLabel == "")
	local icon = mark.icon
	if mark.iconIsText then
		icon:SetFont(STANDARD_TEXT_FONT, db.size, "OUTLINE")
		icon:SetText("!")
		if partyOnly then icon:SetTextColor(db.pr, db.pg, db.pb) else icon:SetTextColor(1, 0.82, 0) end
	else
		-- A mob only the group still needs gets the ! in the party colour.
		if icon.SetDesaturated then icon:SetDesaturated(partyOnly and true or false) end
		if partyOnly then icon:SetVertexColor(db.pr, db.pg, db.pb) else icon:SetVertexColor(1, 1, 1) end
	end
	if showIcon then icon:Show() else icon:Hide() end

	local toLeft = (side == "LEFT")
	local text = mark.text
	text:SetFont(STANDARD_TEXT_FONT, db.textSize, "OUTLINE")
	text:SetTextColor(db.r, db.g, db.b)
	-- Several numbers go under each other, lined up against the !.
	text:SetJustifyH(toLeft and "RIGHT" or "LEFT")
	text:SetText(label)
	text:ClearAllPoints()
	if toLeft then
		text:SetPoint("RIGHT", mark, showIcon and "LEFT" or "RIGHT", showIcon and -1 or 0, 0)
	else
		text:SetPoint("LEFT", mark, showIcon and "RIGHT" or "LEFT", showIcon and 1 or 0, 0)
	end

	local party = mark.party
	party:SetFont(STANDARD_TEXT_FONT, db.textSize, "OUTLINE")
	party:SetTextColor(db.pr, db.pg, db.pb)
	party:SetJustifyH(toLeft and "RIGHT" or "LEFT")
	party:SetText(partyLabel)
	party:ClearAllPoints()
	local gap = (label ~= "") and 4 or 0
	if toLeft then
		party:SetPoint("RIGHT", text, "LEFT", -gap, 0)
	else
		party:SetPoint("LEFT", text, "RIGHT", gap, 0)
	end
end

local function UpdateUnit(unit)
	local plate = C_NamePlate.GetNamePlateForUnit(unit)
	if not plate then return end
	local need, progress, others = false, nil, nil
	if db.enabled and not (db.hideInCombat and inCombat) then
		local _
		need, _, progress, others = UnitIsQuestMob(unit)
	end
	-- Not needed by me, but a group member still does.
	local partyOnly = not need and db.showParty and others ~= nil and #others > 0
	if need or partyOnly then
		local mark = marks[plate]
		if not mark then
			mark = QM.CreateMark(plate)
			marks[plate] = mark
		end
		local uf = plate.UnitFrame
		local bar = uf and (uf.healthBar or uf.HealthBarsContainer or uf.healthbar)
		QM.RenderMark(mark, bar or plate, progress, others, partyOnly)
		mark:Show()
	elseif marks[plate] then
		marks[plate]:Hide()
	end
end

local function UpdateAll()
	for unit in pairs(units) do UpdateUnit(unit) end
end

-- Called by the settings window after every change.
function QM.Apply()
	UpdateAll()
	if QM.RefreshPreview then QM.RefreshPreview() end
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
		QM.db = db
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
		Register("PLAYER_REGEN_DISABLED")
		Register("PLAYER_REGEN_ENABLED")
	elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
		inCombat = (event == "PLAYER_REGEN_DISABLED")
		if db.hideInCombat then UpdateAll() end
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
	local names = {}
	for name in pairs(groupNames) do names[#names + 1] = name end
	Print(("me: %s, group: %s"):format(tostring(UnitName("player")), #names > 0 and table.concat(names, ", ") or "none"))
	if not UnitExists("target") then
		Print("target a mob and run /qmm debug again to see what its tooltip says.")
		return
	end
	local need, method, progress, others = UnitIsQuestMob("target")
	Print(("target: quest mob = %s (via %s)"):format(tostring(need), tostring(method)))
	for _, p in ipairs(progress or {}) do
		Print(("  mine: %d/%d"):format(p.cur, p.max))
	end
	for _, o in ipairs(others or {}) do
		Print(("  %s: %d/%d"):format(tostring(o.name), o.cur, o.max))
	end
	local lines = TooltipLines("target")
	for i, line in ipairs(lines or {}) do
		Print(("  %d [%s] %s"):format(i, line.kind or (questTitles[line.text] and "title?" or "-"), line.text))
	end
end

SLASH_QUESTMOBMARKERS1 = "/qmm"
SLASH_QUESTMOBMARKERS2 = "/questmobmarkers"
SlashCmdList.QUESTMOBMARKERS = function(msg)
	local cmd, rest = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "" then
		if QM.ToggleOptions then QM.ToggleOptions() end
		return
	elseif cmd == "on" or cmd == "off" then
		db.enabled = (cmd == "on")
		Print(db.enabled and "on." or "off.")
	elseif cmd == "size" and tonumber(rest) then
		db.size = math.max(8, math.min(64, tonumber(rest)))
		Print("size " .. db.size .. ".")
	elseif cmd == "pos" then
		local x, y = rest:match("^(-?%d+)%s+(-?%d+)$")
		if not x then Print("usage: /qmm pos <x> <y>   (default 0 0)") return end
		db.x, db.y = tonumber(x), tonumber(y)
		Print(("position %d, %d."):format(db.x, db.y))
	elseif cmd == "debug" then
		Debug()
		return
	else
		Print("/qmm (settings)  -  /qmm on | off  -  /qmm size <8-64>  -  /qmm pos <x> <y>  -  /qmm debug")
		return
	end
	QM.Apply()
end
