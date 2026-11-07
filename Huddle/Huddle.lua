-- Huddle: a dense Battle.net friends list for WoW Forever. One line per friend; the friends you can invite, on your
-- realm, of a class; sorted by level or name.
--
-- Forever uses retail's Social UI. Its friends list (SocialUIFrame.FriendsList) rebuilds itself through
-- C_BattleNet.SearchFriends, which HasRestrictions: once any addon code runs inside that refresh (a hook, a re-sorted
-- data provider, a resized card) the call is forbidden (ADDON_ACTION_FORBIDDEN, 2026-11-06). So Huddle never touches
-- Blizzard's list: it lays its own list over the list's area (Blizzard's made invisible with SetAlpha, nothing else),
-- reads the friends itself, and only reads Blizzard's search box.
local ADDON, ns = ...
local L = ns.L

local LAYOUT = {
	row = 18,            -- row height
	bar = 20,            -- one line of the bar on top
	header = 40,         -- the bar: filters and sorts, then the class icons
	pad = 2,             -- inset from Blizzard's list area
	dot = 10,            -- status icon
	dotX = 3,
	accountX = 16,       -- account name column
	accountShare = 0.36, -- share of the row width for the account name
	levelWidth = 18,     -- level column ("60"), right-aligned
	gap = 6,
	invite = 16,         -- invite button at the right
	classIcon = 16,      -- class filter icons
	classStep = 3,       -- space between them
	thumbWidth = 3,      -- scroll position line at the right edge
	wheelRows = 3,       -- rows per mouse wheel step
	refreshDelay = 0.5,  -- friend updates come in bursts: at most two rebuilds a second
	hoverRetry = 0.5,    -- while the mouse is over the list the rows keep their places; look again this often
}

local STATUS = {
	online = "Interface\\FriendsFrame\\StatusIcon-Online",
	afk = "Interface\\FriendsFrame\\StatusIcon-Away",
	dnd = "Interface\\FriendsFrame\\StatusIcon-DnD",
	offline = "Interface\\FriendsFrame\\StatusIcon-Offline",
}

-- Forever's classes, in class order: one fixed slot each
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

local GOLD, GREY = { 1, 0.82, 0 }, { 0.55, 0.55, 0.55 }

local P = L.Printer("Huddle", "66ccff")
local db
local view          -- SocialUIFrame.FriendsList (Blizzard's; read only, made invisible)
local list          -- our list
local rows, entries, classButtons = {}, {}, {}
local classes = {}  -- the class filter: this session only (one forgotten after a /reload hides nobody)
local classCount = {}
for _, class in ipairs(CLASSES) do classCount[class] = { shown = 0, invitable = 0 } end
local offset, queued, pending = 0, false, false
local search = ""
local counts = { offline = 0, invitable = 0, realm = 0 }
local Render, Rebuild

local function ClassName(class)
	return LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class] or class
end

-- ---------------------------------------------------------------- the friends

-- 1 invitable, your realm and faction; 2 invitable elsewhere; 3 online on Forever, not invitable;
-- 4 online elsewhere (app, another game); 5 offline
local function Tier(e, game, wow, faction, realm)
	if not game.isOnline then return 5 end
	if e.restriction == BattleNetFriendPartyInviteRestrictionType.None then
		if game.factionName == faction and game.realmID == realm then return 1 end
		return 2
	end
	if wow then return 3 end
	return 4
end

local function Status(account, game)
	if not game or not game.isOnline then return STATUS.offline end
	if account.isDND or game.isGameBusy then return STATUS.dnd end
	if account.isAFK or game.isGameAFK then return STATUS.afk end
	return STATUS.online
end

-- (re)reads one friend into e. Rows remember a friend by e.id (the Battle.net account): the index into the friends
-- list moves whenever someone logs on or off.
local function Update(e, index, account, faction, realm)
	local game = account.gameAccountInfo
	local wow = FriendsListUtil.IsPlayingSameWoWProject(game)
	local name = BNet_GetBNetAccountName(account) or account.battleTag or "?"
	e.id, e.account, e.game, e.name, e.key = account.bnetAccountID, account, game, name, name:lower()
	e.restriction = game.isOnline and FriendsListUtil.GetBattleNetFriendPartyInviteRestriction(index) or nil
	e.tier = Tier(e, game, wow, faction, realm)
	e.level = wow and game.characterLevel or nil
	e.class = wow and game.classFilename ~= "" and game.classFilename or nil
	e.char = wow and game.characterName and FriendsListUtil.GetFormattedCharacterName(account) or nil
	e.mine = e.tier ~= 5 and wow and game.realmID == realm or false
	e.inGroup = e.tier <= 3 and game.playerGuid ~= nil
		and L.Read(C_PartyInfo.IsGUIDInGroup, game.playerGuid) == true or false
	e.last = L.Value(account.lastOnlineTime) or 0
	e.haystack = { name, account.battleTag or "", game.characterName or "", account.note or "" }
	return e
end

-- the friend's index and account info now, or nil when they left the list
local function Fresh(e)
	local index = L.Read(BNGetFriendIndex, e.id)
	if not index then return nil end
	local account = C_BattleNet.GetFriendAccountInfo(index)
	if not account or account.bnetAccountID ~= e.id then return nil end
	return index, account
end

local function Matches(e)
	if search == "" then return true end
	local s = search:lower()
	for _, h in ipairs(e.haystack) do
		if h:lower():find(s, 1, true) then return true end
	end
	return false
end

-- both keep offline friends last (the most recently online first); ties go to the invite order (Tier), then the name
local function OfflineFirst(a, b)
	if a.last ~= b.last then return a.last > b.last end
	return a.key < b.key
end

local COMPARE = {
	level = function(a, b)
		local oa, ob = a.tier == 5, b.tier == 5
		if oa ~= ob then return ob end
		if oa then return OfflineFirst(a, b) end
		local la, lb = a.level or -1, b.level or -1
		if la ~= lb then
			if db.levelAsc and la >= 0 and lb >= 0 then return la < lb end
			return la > lb
		end
		if a.tier ~= b.tier then return a.tier < b.tier end
		return a.key < b.key
	end,
	name = function(a, b)
		local oa, ob = a.tier == 5, b.tier == 5
		if oa ~= ob then return ob end
		if a.key ~= b.key then return a.key < b.key end
		return a.tier < b.tier
	end,
}

function Rebuild()
	pending = false
	wipe(entries)
	counts.offline, counts.invitable, counts.realm = 0, 0, 0
	for _, c in pairs(classCount) do c.shown, c.invitable = 0, 0 end
	local faction, realm = UnitFactionGroup("player"), GetRealmID()
	local box = view and view.FilterBar and view.FilterBar.SearchBar
	search = box and box:GetText() or ""
	local filtering = next(classes) ~= nil
	for index = 1, BNGetNumFriends() do
		local account = C_BattleNet.GetFriendAccountInfo(index)
		if account and account.gameAccountInfo then
			local e = Update({}, index, account, faction, realm)
			local invitable = e.tier <= 2
			if e.tier == 5 then counts.offline = counts.offline + 1 end
			if invitable then counts.invitable = counts.invitable + 1 end
			if e.mine then counts.realm = counts.realm + 1 end
			local show = (e.tier ~= 5 or db.offline)
				and (invitable or not db.invitable)
				and (e.mine or not db.myRealm)
				and Matches(e)
			local c = e.class and classCount[e.class]
			if show and c then
				c.shown = c.shown + 1
				if invitable then c.invitable = c.invitable + 1 end
			end
			if show and filtering and not (e.class and classes[e.class]) then show = false end
			if show then entries[#entries + 1] = e end
		end
	end
	table.sort(entries, COMPARE[db.sortBy] or COMPARE.level)
end

-- the rows as they are, each friend read again (status, level, invite): nothing moves
local function RefreshInPlace()
	local faction, realm = UnitFactionGroup("player"), GetRealmID()
	for _, e in ipairs(entries) do
		local index, account = Fresh(e)
		if index then Update(e, index, account, faction, realm) end
	end
end

-- friend updates: a rebuild after the burst; while the mouse is over the list, the rows are only read again (no
-- friend moves under the cursor) and the rebuild waits until the mouse leaves
local function Flush()
	if not list:IsVisible() then queued, pending = false, false return end
	if list:IsMouseOver() then
		if pending then
			pending = false
			RefreshInPlace()
			Render()
		end
		L.After(LAYOUT.hoverRetry, Flush, "refresh")
		return
	end
	queued = false
	Rebuild()
	Render()
end

local function Queue()
	if not list or not list:IsVisible() then return end
	pending = true
	if queued then return end
	queued = true
	L.After(LAYOUT.refreshDelay, Flush, "refresh")
end

-- ---------------------------------------------------------------- actions

local function Invite(e)
	local index = Fresh(e)
	if not index then P(e.name .. " is no longer on your friends list.") return end
	local direct = FriendsListUtil.GetBattleNetFriendGameAccountInfoIfExactlyOneDirectInviteTargetExists(index)
	if direct and direct.playerGuid then
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
		FriendsListUtil.InviteOrRequestToJoin(direct.playerGuid, direct.gameAccountID)
	else
		P("more than one character online: right-click the name to pick one.")
	end
end

local function Whisper(e)
	local _, account = Fresh(e)
	if account and account.accountName then ChatFrameUtil.SendBNetTell(account.accountName) end
end

local function Menu(row, e)
	local account = e.account
	UnitPopup_OpenMenu(e.tier == 5 and "BN_FRIEND_OFFLINE" or "BN_FRIEND", {
		battleTag = account.battleTag,
		bnetIDAccount = account.bnetAccountID,
		friendsList = true,
		name = account.accountName,
		titleColor = FriendsListUtil.GetFriendNameColorForFriendType(account),
		hasMainTitleDivider = true,
		ownerFrame = row,
	})
end

-- Blizzard's reason a friend can't be invited ("not allied", "different region" ...)
local function Reason(e)
	local text = e.restriction and FriendsListUtil.GetBattleNetFriendPartyInviteRestrictionText(e.restriction)
	return (text and text ~= "") and text or "Can't invite"
end

-- what the invite button does right now: Invite, Suggest invite (in a group, not the leader), Request to join (they
-- are in a group) ... in Blizzard's words
local function InviteLabel(e)
	local index = Fresh(e)
	if not index then return "Invite" end
	local ok, info = pcall(FriendsListUtil.GetBattleNetFriendInviteInfo, index)   -- guard: reads the party state
	local label = ok and type(info) == "table" and info.inviteType
		and FriendsListUtil.GetBattleNetFriendInviteTypeLabel(info.inviteType)
	return (label and label ~= "") and label or "Invite"
end

local function Tooltip(row, e)
	local account, game = e.account, e.game
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip_AddColoredLine(GameTooltip, e.name, FRIENDS_BNET_NAME_COLOR)
	if e.tier ~= 5 then
		if e.char then
			GameTooltip_AddNormalLine(GameTooltip, game.characterName .. (game.realmName and (" - " .. game.realmName) or ""))
			GameTooltip_AddHighlightLine(GameTooltip, FRIENDS_LEVEL_TEMPLATE:format(game.characterLevel or 0, game.className or UNKNOWN))
			GameTooltip_AddHighlightLine(GameTooltip, (game.factionName or UNKNOWN) .. ", " .. (game.areaName or UNKNOWN))
		elseif game.richPresence and game.richPresence ~= "" then
			GameTooltip_AddHighlightLine(GameTooltip, game.richPresence)
		end
		if e.inGroup then GameTooltip_AddColoredLine(GameTooltip, "In your group", GREEN_FONT_COLOR)
		elseif e.tier == 3 then GameTooltip_AddColoredLine(GameTooltip, Reason(e), GRAY_FONT_COLOR) end
	else
		GameTooltip_AddColoredLine(GameTooltip, FriendsListUtil.GetLastOnlineText(account), GRAY_FONT_COLOR)
	end
	if account.note and account.note ~= "" then GameTooltip_AddNormalLine(GameTooltip, account.note) end
	GameTooltip_AddColoredLine(GameTooltip, "Click: whisper   Right-click: menu", GRAY_FONT_COLOR)
	GameTooltip:Show()
end

local function InviteTooltip(button, e)
	GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	if e.inGroup then GameTooltip_AddColoredLine(GameTooltip, "In your group", GREEN_FONT_COLOR)
	elseif e.tier <= 2 then GameTooltip_AddNormalLine(GameTooltip, InviteLabel(e))
	else GameTooltip_AddColoredLine(GameTooltip, Reason(e), GRAY_FONT_COLOR) end
	GameTooltip:Show()
end

-- ---------------------------------------------------------------- rows

local function Row(i)
	local LY = LAYOUT
	local row = CreateFrame("Button", nil, list)
	row:SetHeight(LY.row)
	row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(LY.header + (i - 1) * LY.row))
	row:SetPoint("RIGHT", list, "RIGHT", -(LY.thumbWidth + 2), 0)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	local stripe = row:CreateTexture(nil, "BACKGROUND")
	stripe:SetAllPoints()
	stripe:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.04 or 0)
	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.12)
	row.dot = row:CreateTexture(nil, "ARTWORK")
	row.dot:SetSize(LY.dot, LY.dot)
	row.dot:SetPoint("LEFT", LY.dotX, 0)
	row.account = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	row.account:SetJustifyH("LEFT")
	row.account:SetWordWrap(false)
	row.level = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	row.level:SetJustifyH("RIGHT")
	row.level:SetWidth(LY.levelWidth)
	row.char = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	row.char:SetJustifyH("LEFT")
	row.char:SetWordWrap(false)
	row.invite = CreateFrame("Button", nil, row)
	row.invite:SetSize(LY.invite, LY.invite)
	row.invite:SetPoint("RIGHT", -2, 0)
	row.invite.icon = row.invite:CreateTexture(nil, "ARTWORK")
	row.invite.icon:SetAllPoints()
	row.invite:SetMotionScriptsWhileDisabled(true)
	L.Script(row, "OnClick", function(self, button)
		local e = self.entry
		if not e then return end
		if button == "RightButton" then Menu(self, e) else Whisper(e) end
	end, "row")
	L.Script(row, "OnEnter", function(self) if self.entry then Tooltip(self, self.entry) end end, "row")
	L.Script(row, "OnLeave", function() GameTooltip:Hide() end, "row")
	L.Script(row.invite, "OnClick", function(self) local e = self:GetParent().entry if e then Invite(e) end end, "invite")
	L.Script(row.invite, "OnEnter", function(self)
		local e = self:GetParent().entry
		if e then InviteTooltip(self, e) end
	end, "invite")
	L.Script(row.invite, "OnLeave", function() GameTooltip:Hide() end, "invite")
	rows[i] = row
	return row
end

local function Draw(row, e, width)
	local LY = LAYOUT
	row.entry = e
	local account, game = e.account, e.game
	local offline = e.tier == 5
	row.dot:SetTexture(Status(account, game))
	local star = account.isFavorite and (CreateAtlasMarkup("friends-icon-favorites", 10, 10) .. " ") or ""
	local nameColor = offline and FRIENDS_GRAY_COLOR or FriendsListUtil.GetFriendNameColorForFriendType(account)
	row.account:SetText(star .. nameColor:WrapTextInColorCode(e.name))
	local accountWidth = width * LY.accountShare
	row.account:ClearAllPoints()
	row.account:SetPoint("LEFT", row, "LEFT", LY.accountX, 0)
	row.account:SetWidth(accountWidth)
	row.level:ClearAllPoints()
	row.level:SetPoint("LEFT", row, "LEFT", LY.accountX + accountWidth + LY.gap, 0)
	row.level:SetText(e.level and (offline and FRIENDS_GRAY_COLOR or HIGHLIGHT_FONT_COLOR):WrapTextInColorCode(tostring(e.level)) or "")
	row.char:ClearAllPoints()
	row.char:SetPoint("LEFT", row.level, "RIGHT", LY.gap, 0)
	row.char:SetPoint("RIGHT", row.invite, "LEFT", -LY.gap, 0)
	local text = ""
	if e.char then
		local color = (not offline) and e.class and C_ClassColor.GetClassColor(e.class) or FRIENDS_GRAY_COLOR
		text = color:WrapTextInColorCode(e.char)
	elseif not offline and game.richPresence and game.richPresence ~= "" then
		text = FRIENDS_GRAY_COLOR:WrapTextInColorCode(game.richPresence)
	elseif offline then
		text = FRIENDS_GRAY_COLOR:WrapTextInColorCode(FriendsListUtil.GetLastOnlineText(account) or "")
	end
	row.char:SetText(text)
	-- the invite slot: a check (in your group), the invite icon (you can), greyed (you can't, the tooltip says why),
	-- nothing (offline, not on Forever)
	local invite = row.invite
	if e.tier >= 4 then
		invite.state = nil
		invite:Hide()
	else
		local state = e.inGroup and "group" or (e.tier <= 2 and "invite" or "cannot")
		invite.state = state
		invite:SetEnabled(state == "invite")
		invite.icon:SetAtlas(state == "group" and "common-icon-checkmark"
			or state == "invite" and "friends-icon-friendsavailable" or "friends-icon-friendsavailable-dis")
		invite:Show()
	end
	row:Show()
end

-- ---------------------------------------------------------------- the bar

local function Label(button, text, on)
	button.text:SetText(text)
	local c = on and GOLD or GREY
	button.text:SetTextColor(c[1], c[2], c[3])
end

-- a bar button as wide as its widest text (`widest`), so nothing on the bar moves when a count or a label changes
local function BarButton(onClick, tip, widest)
	local b = CreateFrame("Button", nil, list.bar)
	b:SetHeight(LAYOUT.bar)
	b.text = b:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	b.text:SetPoint("CENTER")
	b.text:SetText(widest)
	b:SetWidth(b.text:GetStringWidth() + 8)
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.1)
	L.Script(b, "OnClick", onClick, "bar")
	L.Script(b, "OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip_AddNormalLine(GameTooltip, tip)
		GameTooltip:Show()
	end, "bar")
	L.Script(b, "OnLeave", function() GameTooltip:Hide() end, "bar")
	return b
end

local function Changed()
	offset = 0
	Rebuild()
	Render()
end

local function SetSort(mode)
	if mode == "level" and db.sortBy == "level" then db.levelAsc = not db.levelAsc end
	db.sortBy = mode
	Changed()
end

local function ClassButton(class, i)
	local LY = LAYOUT
	local b = CreateFrame("Button", nil, list.bar)
	b:SetSize(LY.classIcon, LY.classIcon)
	b:SetPoint("LEFT", list.bar, "TOPLEFT", 4 + (i - 1) * (LY.classIcon + LY.classStep), -(LY.bar + LY.bar / 2))
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetAllPoints()
	b.icon:SetAtlas("classicon-" .. class:lower())
	L.Script(b, "OnClick", function(_, button)
		if button == "RightButton" then wipe(classes)
		else classes[class] = (not classes[class]) or nil end
		Changed()
	end, "class")
	L.Script(b, "OnEnter", function(self)
		local c = classCount[class]
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip_AddNormalLine(GameTooltip, ("%s: %d %s, %d invitable"):format(ClassName(class), c.shown,
			c.shown == 1 and "friend" or "friends", c.invitable))
		GameTooltip_AddColoredLine(GameTooltip, "Click: show only these (more than one class works)", GRAY_FONT_COLOR)
		GameTooltip_AddColoredLine(GameTooltip, "Right-click: all classes", GRAY_FONT_COLOR)
		GameTooltip:Show()
	end, "class")
	L.Script(b, "OnLeave", function() GameTooltip:Hide() end, "class")
	classButtons[class] = b
	return b
end

local function RenderBar()
	local bar = list.bar
	Label(bar.invitable, "Invitable " .. counts.invitable, db.invitable)
	Label(bar.realm, "My realm " .. counts.realm, db.myRealm)
	Label(bar.offline, "Offline " .. counts.offline, db.offline)
	Label(bar.level, db.sortBy == "level" and (db.levelAsc and "Level 1-60" or "Level 60-1") or "Level", db.sortBy == "level")
	Label(bar.name, "Name", db.sortBy == "name")
	-- class slots: lit when the class has friends in view, dim when not; while filtering, the picked ones lit
	local filtering = next(classes) ~= nil
	for _, class in ipairs(CLASSES) do
		local b = classButtons[class]
		local lit
		if filtering then lit = classes[class] == true else lit = classCount[class].shown > 0 end
		b.lit = lit
		b.icon:SetDesaturated(not lit)
		b:SetAlpha(lit and 1 or (filtering and 0.35 or 0.2))
	end
	bar.all:SetShown(filtering)
	Label(bar.all, "All", false)
end

local function EmptyText()
	if L.Read(BNConnected) == false then return "Battle.net is not connected." end
	local why = {}
	if db.invitable then why[#why + 1] = "Invitable" end
	if db.myRealm then why[#why + 1] = "My realm" end
	for _, class in ipairs(CLASSES) do if classes[class] then why[#why + 1] = ClassName(class) end end
	if search ~= "" then why[#why + 1] = '"' .. search .. '"' end
	if #why > 0 then return "No friends match: " .. table.concat(why, ", ") end
	if not db.offline and counts.offline > 0 then return "No friends online (Offline " .. counts.offline .. ")" end
	return "No friends yet."
end

-- ---------------------------------------------------------------- render

function Render()
	if not list then return end
	local LY = LAYOUT
	local height = list:GetHeight() - LY.header
	local visible = math.max(math.floor(height / LY.row), 1)
	local maxOffset = math.max(#entries - visible, 0)
	if offset > maxOffset then offset = maxOffset end
	local width = list:GetWidth() - LY.thumbWidth - 2 - LY.accountX - LY.invite - 2
	for i = 1, visible do
		local row = rows[i] or Row(i)
		local e = entries[offset + i]
		if e then Draw(row, e, width) else row.entry = nil row:Hide() end
	end
	for i = visible + 1, #rows do rows[i].entry = nil rows[i]:Hide() end
	-- scroll position line
	local thumb = list.thumb
	if #entries > visible then
		local size = math.max(height * visible / #entries, 12)
		thumb:SetHeight(size)
		thumb:ClearAllPoints()
		thumb:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, -(LY.header + (height - size) * offset / maxOffset))
		thumb:Show()
	else
		thumb:Hide()
	end
	list.empty:SetShown(#entries == 0)
	if #entries == 0 then list.empty:SetText(EmptyText()) end
	RenderBar()
end

-- ---------------------------------------------------------------- setup

local function Build()
	local LY = LAYOUT
	list = CreateFrame("Frame", nil, view)
	ns.list, ns.rows, ns.entries, ns.classButtons, ns.classes = list, rows, entries, classButtons, classes -- for the harness
	list:SetPoint("TOPLEFT", view.ScrollBox, "TOPLEFT", LY.pad, -LY.pad)
	list:SetPoint("BOTTOMRIGHT", view.ScrollBar, "BOTTOMRIGHT", 0, LY.pad)
	list:SetFrameLevel(math.max(view.ScrollBox:GetFrameLevel(), view.ScrollBar:GetFrameLevel()) + 30)
	list:EnableMouse(true)
	list:EnableMouseWheel(true)

	local bar = CreateFrame("Frame", nil, list)
	bar:SetPoint("TOPLEFT")
	bar:SetPoint("TOPRIGHT")
	bar:SetHeight(LY.header)
	local line = bar:CreateTexture(nil, "ARTWORK")
	line:SetPoint("BOTTOMLEFT")
	line:SetPoint("BOTTOMRIGHT")
	line:SetHeight(1)
	line:SetColorTexture(1, 1, 1, 0.15)
	list.bar = bar
	local function Toggle(key) return function() db[key] = not db[key] Changed() end end
	-- line 1, left: filters (each shows how many friends it would show); right: sorts
	bar.invitable = BarButton(Toggle("invitable"), "Only friends you can invite to your group", "Invitable 888")
	bar.realm = BarButton(Toggle("myRealm"), "Only friends on your realm", "My realm 888")
	bar.offline = BarButton(Toggle("offline"), "Show offline friends too (the most recently online first)", "Offline 888")
	bar.level = BarButton(function() SetSort("level") end, "Sort by level; click again to flip", "Level 60-1")
	bar.name = BarButton(function() SetSort("name") end, "Sort by name", "Name")
	bar.invitable:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
	bar.realm:SetPoint("LEFT", bar.invitable, "RIGHT", 2, 0)
	bar.offline:SetPoint("LEFT", bar.realm, "RIGHT", 2, 0)
	bar.name:SetPoint("TOPRIGHT", bar, "TOPRIGHT", -2, 0)
	bar.level:SetPoint("RIGHT", bar.name, "LEFT", -2, 0)
	-- line 2: one slot per class, then All while a class is picked
	for i, class in ipairs(CLASSES) do ClassButton(class, i) end
	bar.all = BarButton(function() wipe(classes) Changed() end, "Show all classes again", "All")
	bar.all:SetPoint("LEFT", classButtons[CLASSES[#CLASSES]], "RIGHT", 6, 0)
	bar.all:Hide()

	list.thumb = list:CreateTexture(nil, "ARTWORK")
	list.thumb:SetWidth(LY.thumbWidth)
	list.thumb:SetColorTexture(1, 0.82, 0, 0.6)
	list.empty = list:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	list.empty:SetPoint("TOP", 0, -(LY.header + 12))

	-- Blizzard's Filter button (status, tags) does not reach this list: unseen, and a cover takes its clicks
	local dropdown = view.FilterBar and view.FilterBar.SearchFilterDropdown
	if dropdown then
		local cover = CreateFrame("Frame", nil, list)
		cover:SetAllPoints(dropdown)
		cover:SetFrameLevel(dropdown:GetFrameLevel() + 10)
		cover:EnableMouse(true)
		L.Script(cover, "OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip_AddNormalLine(GameTooltip, "Huddle filters with the bar below; /huddle off gives Blizzard's list back")
			GameTooltip:Show()
		end, "cover")
		L.Script(cover, "OnLeave", function() GameTooltip:Hide() end, "cover")
		list.cover = cover
	end
	local function Conceal(alpha)
		view.ScrollBox:SetAlpha(alpha)
		view.ScrollBar:SetAlpha(alpha)
		if dropdown then dropdown:SetAlpha(alpha) end
	end

	L.Script(list, "OnMouseWheel", function(_, delta)
		offset = math.max(offset - delta * LY.wheelRows, 0)
		Render()
	end, "wheel")
	L.Script(list, "OnSizeChanged", function() if list:IsVisible() then Render() end end, "size")
	L.Script(list, "OnShow", function()
		-- Blizzard's list stays, unseen and untouched, under ours
		Conceal(0)
		Rebuild() Render()
	end, "show")
	L.Script(list, "OnHide", function() Conceal(1) end, "hide")
	if list:IsVisible() then Conceal(0) Rebuild() Render() end
end

local function Setup()
	if view or not db.enabled then return end
	view = SocialUIFrame and SocialUIFrame.FriendsList
	if not (view and view.ScrollBox and view.ScrollBar and FriendsListUtil and C_BattleNet) then
		P("Blizzard's friends list is not where Huddle expects it (a patch?): Huddle is off, Blizzard's list stays.")
		view = nil
		return
	end
	Build()
	local box = view.FilterBar and view.FilterBar.SearchBar
	if box then L.HookScript(box, "OnTextChanged", function() offset = 0 Queue() end, "search") end
end

for _, event in ipairs({ "BN_FRIEND_INFO_CHANGED", "BN_FRIEND_LIST_SIZE_CHANGED", "BN_CONNECTED", "BN_DISCONNECTED",
	"GROUP_ROSTER_UPDATE" }) do
	L.On(event, Queue, "friends")
end

local DEFAULTS = {
	version = 1, enabled = true, sortBy = "level", levelAsc = false, offline = false, invitable = false, myRealm = false,
}

L.OnLoad(function()
	HuddleDB = L.Fill(type(HuddleDB) == "table" and HuddleDB or {}, DEFAULTS)
	db = HuddleDB
	L.WhenLoaded("Blizzard_FriendsFrame", function() L.WhenLoaded("Blizzard_SocialUI", Setup) end)
end)

SLASH_HUDDLE1 = "/huddle"
SlashCmdList.HUDDLE = L.Safe("slash", function(msg)
	local cmd = (msg or ""):lower():match("^%s*(%S*)")
	if cmd == "on" then db.enabled = true P("on after /reload.")
	elseif cmd == "off" then db.enabled = false P("off after /reload (Blizzard's list back).")
	else P("/huddle on | off (the list is in the Social window, Friends tab)") end
end)
