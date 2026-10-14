-- RaidToolsModule.lua
-- Handles Invites (whisper keywords, guild-rank filter, Invite All Guild, invite from a
-- pasted list), Battle Res Tracker settings, Floating Button lock, and Pull Timer.
-- Raid difficulty scheduling lives in its own module, RaidAutomation.lua.

local db -- Local reference to DanUIDB.RaidTools
local AutoInviteKeywordsTable = {}
local MIN_RANK_INDEX = 3 -- Promotes GM (0) through rank index 3 (Officers/Leads).
local rosterTimer

function DUI_GetRaidToolsDefaults()
    return {
        enabled = true,
        autoInviteEnabled = false,
        autoInviteKeywords = "inv invite",
        -- A keyword as one word of a longer whisper ("inv pls"), not only the whole whisper.
        inviteMatchAnywhere = false,
        -- Whispers are honoured only from guild members at or above inviteMaxRank.
        inviteGuildOnly = false,
        -- 0-based guild rank index (0 = Guild Master), the lowest rank that gets an
        -- invite. Shared by Invite All Guild and the guild-only whisper filter; 6 is
        -- the "rankIndex < 7" Invite All Guild was hardcoded to.
        inviteMaxRank = 6,
        -- The last roster pasted into Invite From List, kept so a weekly list
        -- doesn't have to be pasted again.
        invitePasteList = "",
        battleResEnabled = true,
        battleResLocked = false,
        battleResSize = 40,
        floatingEnabled = true,
        lockButtons = false,
        pullTimer = 10,
        breakTimer = 5, -- minutes: BigWigs' /break counts in them, /pull in seconds
        floatingStrata = "TOOLTIP",
        floatingFontSize = 12,
        floatingHorizontal = false,
        -- Which buttons the floating bar carries. The keys are declared with the
        -- buttons themselves, in DUI_FloatingButtonDefs (FloatingButtons.lua);
        -- they are spelled out here because that file loads after this one.
        floatingShowPull = true,
        floatingShowReadyCheck = true,
        floatingShowInspect = true,
        floatingShowBreak = true,
    }
end

-- ---------------------------------------------------------------------------
-- Party -> raid conversion, and the invites waiting on it.
--
-- C_PartyInfo.ConvertToRaid() is a server round trip: it returns straight away
-- but IsInRaid() keeps answering false until the server confirms, so an invite
-- sent on the next line still goes out as a *party* invite and is refused
-- because the party is full. Invites are queued behind the conversion instead
-- and released once the group actually reports as a raid.
-- ---------------------------------------------------------------------------
local pendingInvites = {}
local pendingTries = 0
local pendingTimer
local converting = false

local FLUSH_INTERVAL = 0.2
local FLUSH_MAX_TRIES = 10 -- ~2s, then send anyway rather than swallow the invite

local function FlushPendingInvites()
    pendingTimer = nil
    pendingTries = pendingTries + 1
    -- Not a raid yet and still within the window: wait for the server.
    if not IsInRaid() and pendingTries < FLUSH_MAX_TRIES then
        pendingTimer = C_Timer.NewTimer(FLUSH_INTERVAL, FlushPendingInvites)
        return
    end
    -- Either the raid exists or the conversion never landed. Send regardless --
    -- a refused invite prints its own error, a dropped one looks like the
    -- addon ignored the whisper.
    converting = false
    pendingTries = 0
    for name in pairs(pendingInvites) do
        C_PartyInfo.InviteUnit(name)
    end
    wipe(pendingInvites)
end

-- Converts the group to a raid if that is both needed and possible, and reports
-- whether invites now have to wait for it. Solo there is nothing to convert --
-- the first invite forms the party itself -- and a non-leader may not convert.
local function RequestRaidConvert()
    if converting then return true end
    if IsInRaid() then return false end
    if not IsInGroup() or not UnitIsGroupLeader("player") then return false end

    C_PartyInfo.ConvertToRaid()
    converting = true
    pendingTries = 0
    if not pendingTimer then pendingTimer = C_Timer.NewTimer(FLUSH_INTERVAL, FlushPendingInvites) end
    return true
end

-- Invites `name`, holding the invite behind a pending conversion if there is one.
local function QueueInvite(name)
    if converting then
        pendingInvites[name] = true
    else
        C_PartyInfo.InviteUnit(name)
    end
end

local function UpdateAutoInviteKeywords()
    wipe(AutoInviteKeywordsTable)
    if db and db.autoInviteKeywords then
        for word in string.gmatch(db.autoInviteKeywords:lower(), "[^%s,;]+") do
            AutoInviteKeywordsTable[word] = true
        end
    end
end

-- The whole whisper is a keyword, or (inviteMatchAnywhere) any one word of it is.
-- Words split on spaces and sentence punctuation, so "inv pls!" matches "inv".
local function WhisperMatches(msg)
    msg = strtrim(msg:lower())
    if AutoInviteKeywordsTable[msg] then return true end
    if not db.inviteMatchAnywhere then return false end
    for word in msg:gmatch("[^%s,;%.!%?]+") do
        if AutoInviteKeywordsTable[word] then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Guild ranks
-- ---------------------------------------------------------------------------

-- GuildControlGetRankName is 1-based; every rank index this file stores is the
-- 0-based one GetGuildRosterInfo returns.
local function RankName(index)
    local name = GuildControlGetRankName and GuildControlGetRankName(index + 1)
    if name and name ~= "" then return name end
    return "Rank " .. (index + 1)
end

local function RankCutoffText()
    local idx = db.inviteMaxRank or 6
    local n = IsInGuild() and GuildControlGetNumRanks and GuildControlGetNumRanks() or 0
    -- A cutoff below the guild's lowest rank lets everyone in; say that rather
    -- than naming a rank that doesn't exist.
    if n > 0 and idx >= n - 1 then return "Everyone" end
    if idx == 0 then return RankName(0) .. " only" end
    return RankName(idx) .. " and above"
end

-- Realm-qualified and lowercased, so a whisper sender, a roster entry and a typed
-- name compare equal however each was written.
local function NameKey(name)
    if not name or name == "" then return nil end
    if not name:find("-", 1, true) then
        local realm = GetNormalizedRealmName()
        if realm then name = name .. "-" .. realm end
    end
    return name:lower()
end

-- The sender's 0-based guild rank, or nil if they aren't in the guild - or the
-- roster hasn't loaded, which reads the same. A walk per whisper is fine: it runs
-- only while the guild-only filter is on and a keyword has already matched.
local function GuildRankOf(name)
    local key = NameKey(name)
    if not (key and IsInGuild()) then return nil end
    for i = 1, GetNumGuildMembers() do
        local member, _, rankIndex = GetGuildRosterInfo(i)
        if member and NameKey(member) == key then return rankIndex end
    end
end

-- Refusals are printed once per sender per session: a raider spamming "inv" at a
-- filter that won't let them in shouldn't fill the chat frame, but a silent
-- refusal looks exactly like the addon not working.
local refusedNotice = {}

local function WhisperAllowed(sender)
    if not db.inviteGuildOnly then return true end
    local rank = GuildRankOf(sender)
    if rank and rank <= (db.inviteMaxRank or 6) then return true end
    if not refusedNotice[sender] then
        refusedNotice[sender] = true
        if rank then
            print(string.format("|cFF00FF00[DUI]|r Not inviting %s: guild rank %s is below the cutoff (%s).",
                sender, RankName(rank), RankCutoffText()))
        else
            print(string.format("|cFF00FF00[DUI]|r Not inviting %s: not in your guild (Invites is set to guild members only).", sender))
        end
    end
    -- An empty roster is the likely cause of a wrong "not in your guild"; ask for
    -- it so the next whisper is judged against real data.
    if not rank and C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
    return false
end

-- ---------------------------------------------------------------------------
-- Invite from a pasted list
-- ---------------------------------------------------------------------------

-- Words a spreadsheet header or a Discord sign-up post puts on a line of its own.
-- Without this they would be invited as character names and each one would print
-- "player not found".
local LIST_STOPWORDS = {
    tank = true, tanks = true, healer = true, healers = true, heal = true, heals = true,
    dps = true, melee = true, ranged = true, bench = true, name = true, names = true,
    role = true, roles = true, class = true, roster = true, player = true, players = true,
}

-- Pulls character names out of whatever was pasted: one per line, or separated by
-- commas, semicolons or tabs (a spreadsheet column or row). Each piece loses any
-- leading clutter (a Discord @, list numbering, bullets) and anything after the
-- first space ("Dan (Mage)", "Dan - tank"). Bytes 128-255 count as letters so
-- accented names survive. Realms are kept when given; realm names are written
-- without spaces, the way the client itself writes them (Name-Area52).
--
-- Multi-byte clutter is peeled off separately, since its bytes look like letters:
-- U+2000-U+2BFF (bullets, dashes, arrows, symbols: lead byte 226), the emoji
-- variation selector (239 184 x) and any 4-byte character (emoji, lead 240-244).
-- Accented Latin, Cyrillic and CJK names use none of those lead bytes.
local CLUTTER_HEAD = { "^[^%a\128-\255]+", "^\226[\128-\191][\128-\191]", "^\239\184[\128-\191]", "^[\240-\244][\128-\191][\128-\191][\128-\191]" }
-- ASCII punctuation spelled out rather than %p: %p follows the C locale, and under
-- a non-C one it matches bytes 128-255 too, which chops multi-byte letters off
-- the end of a name.
local CLUTTER_TAIL = { "[!-/:-@%[-`{-~]+$","\226[\128-\191][\128-\191]$", "\239\184[\128-\191]$", "[\240-\244][\128-\191][\128-\191][\128-\191]$" }

local function Peel(s, patterns)
    local before
    repeat
        before = s
        for _, p in ipairs(patterns) do s = s:gsub(p, "") end
    until s == before
    return s
end

local function ParseNameList(text)
    local names, seen = {}, {}
    for raw in (text or ""):gmatch("[^\r\n,;\t]+") do
        local piece = Peel(raw, CLUTTER_HEAD)
        local name = piece:match("^[%a\128-\255][^%s]*")
        if name then
            name = Peel(name, CLUTTER_TAIL)
            local base = name:match("^[^%-]+")
            -- Character names never contain digits, which also drops times,
            -- item levels and anything else numeric a sign-up post carries.
            -- [0-9], not %d: some locales count superscript-digit bytes as %d,
            -- and those bytes turn up inside Cyrillic letters.
            if base and not base:find("[0-9]") and not LIST_STOPWORDS[base:lower()] then
                local key = NameKey(name)
                if key and not seen[key] then
                    seen[key] = true
                    names[#names + 1] = name
                end
            end
        end
    end
    return names
end

local function AlreadyGrouped(name)
    local key = NameKey(name)
    if key == NameKey(UnitName("player")) then return true end
    local unitName = Ambiguate(name, "none")
    return UnitInRaid(unitName) or UnitInParty(unitName)
end

-- Solo, a party holds only four invites, and there is no group yet to convert.
-- The rest of a long list waits here until someone accepts: then the party is
-- converted and they go out through the same queue the whispers use.
local heldInvites = {}
local holdTimer
local holdFrame = CreateFrame("Frame")

local HOLD_TIMEOUT = 120

local function ClearHeldInvites()
    holdFrame:UnregisterEvent("GROUP_ROSTER_UPDATE")
    if holdTimer then holdTimer:Cancel(); holdTimer = nil end
    wipe(heldInvites)
end

holdFrame:SetScript("OnEvent", function()
    -- GetNumGroupMembers >= 2: someone has actually accepted, so there is a party
    -- to convert rather than just invites hanging off us.
    if not (IsInGroup() and GetNumGroupMembers() >= 2 and UnitIsGroupLeader("player")) then return end
    local names = { unpack(heldInvites) }
    ClearHeldInvites()
    RequestRaidConvert()
    for _, n in ipairs(names) do QueueInvite(n) end
    print(string.format("|cFF00FF00[DUI]|r Party formed - inviting the other %d.", #names))
end)

local function HoldUntilGrouped(names)
    ClearHeldInvites()
    for _, n in ipairs(names) do heldInvites[#heldInvites + 1] = n end
    holdFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    holdTimer = C_Timer.NewTimer(HOLD_TIMEOUT, function()
        holdTimer = nil
        local n = #heldInvites
        ClearHeldInvites()
        print(string.format("|cFF00FF00[DUI]|r Nobody accepted within %d seconds; %d name%s from the list were not invited. Press Invite List again.",
            HOLD_TIMEOUT, n, n == 1 and "" or "s"))
    end)
end

-- Invites a list of names: four now and the rest held when solo, through the
-- raid-conversion queue otherwise. Shared by Invite List and Invite All Guild.
-- `what` names the source in the chat lines. Returns how many were invited or queued.
local function InviteNames(names, what)
    local todo = {}
    for _, n in ipairs(names) do
        if not AlreadyGrouped(n) then todo[#todo + 1] = n end
    end
    if #todo == 0 then
        print(string.format("|cFF00FF00[DUI]|r Nobody to invite - %s is empty or already in the group.", what))
        return 0
    end
    if IsInGroup() and not (UnitIsGroupLeader("player") or (IsInRaid() and UnitIsGroupAssistant("player"))) then
        print("|cFF00FF00[DUI]|r Inviting needs group lead (or assist, in a raid).")
        return 0
    end

    if not IsInGroup() and #todo > 4 then
        for i = 1, 4 do C_PartyInfo.InviteUnit(todo[i]) end
        HoldUntilGrouped({ unpack(todo, 5) })
        print(string.format("|cFF00FF00[DUI]|r Invited 4; the other %d go out once someone accepts and the party becomes a raid.", #todo - 4))
        return #todo
    end

    -- GetNumGroupMembers counts the player; a party can't hold more than five.
    if GetNumGroupMembers() + #todo > 5 then RequestRaidConvert() end
    for _, n in ipairs(todo) do QueueInvite(n) end
    print(string.format("|cFF00FF00[DUI]|r Inviting %d from %s.", #todo, what))
    return #todo
end

local function InviteNameList(text)
    return InviteNames(ParseNameList(text), "the list")
end

-- The Auto-Assist List row owns every promotion this file makes, the guild-rank
-- half included: it is the only switch in the main window that says "promote
-- people", and the rank rule used to run with nothing able to turn it off.
-- A missing table reads as on: it is the module's default, and this can run
-- before DUI_InitAssistModule has created the table on a fresh install.
local function AssistEnabled()
    local assistDB = DanUIDB and DanUIDB.AssistModule
    return not assistDB or assistDB.enabled ~= false
end

function DUI_ProcessRosterPromotions()
    if not AssistEnabled() then return end
    if not IsInRaid() or not UnitIsGroupLeader("player") then return end
    local numMembers = GetNumGroupMembers()
    local myGuildName = GetGuildInfo("player")

    if not myGuildName then
        -- If the player's own guild info isn't loaded, we can't verify others.
        -- This often happens immediately after a loading screen.
        return 
    end

    for i = 1, numMembers do
        local fn, rank = GetRaidRosterInfo(i)
        if fn and rank == 0 then
            local shortName = Ambiguate(fn, "short")
            local unit = GetUnitID(i, numMembers)
            
            -- Notify the user if data is missing for a specific unit
            if not UnitExists(unit) then break end

            local unitGuildName, _, gr = GetGuildInfo(unit)
            local promotedByRank = (myGuildName and unitGuildName and myGuildName == unitGuildName and gr and gr <= MIN_RANK_INDEX)
            -- AssistEnabled() above has already gated the whole pass.
            local assistDB = DanUIDB.AssistModule
            local promotedByManual = assistDB and assistDB.assistList
                and (assistDB.assistList[fn] or assistDB.assistList[shortName])

            if promotedByRank or promotedByManual then
                PromoteToAssistant(fn)
                if promotedByRank then
                    print(string.format("|cFF00FF00[DUI]|r Promoting %s (Guild Rank Index: %d)", fn, gr))
                else
                    print(string.format("|cFF00FF00[DUI]|r Promoting %s (Manual Assist List)", fn))
                end
            elseif unitGuildName and myGuildName == unitGuildName and gr and gr > MIN_RANK_INDEX then
                -- Optional: Debug message to see why someone isn't promoted
                -- print(string.format("|cFF00FF00[DUI]|r %s is in guild but rank %d is too high.", fn, gr))
            end
        end
    end
end


-- ---------------------------------------------------------------------------
-- Configuration UIs
-- The old single "Raid Tools Settings" panel is split into three focused Tools-tab
-- popouts: Invites, Battle Res Tracker, and Floating Buttons. All three share the
-- same DanUIDB.RaidTools table, just surfacing different keys.
-- ---------------------------------------------------------------------------

local function EnsureRaidToolsDB()
    if not DanUIDB.RaidTools then DanUIDB.RaidTools = DUI_GetRaidToolsDefaults() end
    db = DanUIDB.RaidTools
    -- Backfill any defaults missing from an older saved table (e.g. battleResSize).
    for k, v in pairs(DUI_GetRaidToolsDefaults()) do
        if db[k] == nil then db[k] = v end
    end
    return db
end

-- ---- Invites --------------------------------------------------------------
local invitesConfig = DUI_CreateConfigFrame("DUI_InvitesConfig", "Invites", 320, 240, "DUI_InvitesBtn")

function DUI_OpenInvitesConfig()
    EnsureRaidToolsDB()

    if not invitesConfig.init then
        local L = DUI_CreateLayout(invitesConfig, 45)
        local InviteBtn = CreateFrame("Button", "DUI_InviteAllButton", invitesConfig, "BackdropTemplate")
        InviteBtn:SetSize(140, 25); InviteBtn:SetPoint("TOP", 0, -45); InviteBtn:SetText("Invite All Guild")
        StyleAsTealTab(InviteBtn)
        DUI_AddTooltip(InviteBtn, "Invite All Guild",
            { body = "Invites every online guild member at or above the rank set under Guild Rank, converting to a raid first if needed.",
              note = "Sends one invite per member -- there is no confirmation." })
        L:Gap(33)
        InviteBtn:SetScript("OnClick", function()
            -- The row's tick gates the on-demand button too, the same rule the
            -- Guild Bank Sorter and Raid Arranger follow.
            if not db.autoInviteEnabled then
                print("|cFF00FF00[DUI]|r Invites is switched off in the module list.")
                return
            end
            if not IsInGuild() then return end
            local names = {}
            for i = 1, GetNumGuildMembers() do
                local name, _, rankIndex, _, _, _, _, _, online = GetGuildRosterInfo(i)
                if name and online and rankIndex <= (db.inviteMaxRank or 6) then
                    names[#names + 1] = name
                end
            end
            InviteNames(names, "the guild (at that rank cutoff)")
        end)

        L:Header("Guild Rank")
        local rankBtn = L:Dropdown("Lowest rank invited", {
            tooltip = { body = "The lowest guild rank Invite All Guild invites, and the lowest a whisperer may be when Guild Members Only is ticked.",
                        note = "Ranks run from Guild Master at the top down to the guild's newest rank." },
        })
        rankBtn:SetScript("OnClick", function(self)
            local n = IsInGuild() and GuildControlGetNumRanks and GuildControlGetNumRanks() or 0
            if n == 0 then
                print("|cFF00FF00[DUI]|r You're not in a guild, or its ranks haven't loaded yet.")
                return
            end
            local items = {}
            for i = 0, n - 1 do
                items[#items + 1] = { value = i, text = (i == 0) and (RankName(0) .. " only") or (RankName(i) .. " and above") }
            end
            DUI_ShowScrollDropdown(self, items, function(val)
                db.inviteMaxRank = val
                self:SetValue(RankCutoffText())
            end, db.inviteMaxRank)
        end)
        invitesConfig.rankBtn = rankBtn
        invitesConfig.guildOnlyCheck = L:Checkbox("Whispers: guild members only", db, "inviteGuildOnly", nil,
            { body = "Only invites a whisperer who is in your guild at or above the rank above. Anyone else is told nothing; you get one chat line per refused name.",
              note = "Invite From List ignores this - a list you paste is invited as written." })

        L:Header("Whisper Keywords")
        local AutoInviteInput = CreateFrame("EditBox", nil, invitesConfig, "BackdropTemplate")
        AutoInviteInput:SetSize(L:ContentWidth(), 25); AutoInviteInput:SetPoint("TOPLEFT", 40, L:Y())
        AutoInviteInput:SetAutoFocus(false); AutoInviteInput:SetFontObject(DUI_FontNormal)
        AutoInviteInput:SetBackdrop(DUI_EditBackdrop); AutoInviteInput:SetBackdropColor(0, 0, 0, 0.5); AutoInviteInput:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
        DUI_RegisterAccent(AutoInviteInput, "border")
        AutoInviteInput:SetTextInsets(5, 5, 0, 0); AutoInviteInput:SetText(db.autoInviteKeywords or "")
        AutoInviteInput:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(1, 1, 0, 1) end)
        AutoInviteInput:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(unpack(DUI_Theme.Accent)) end)
        AutoInviteInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end); AutoInviteInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        AutoInviteInput:SetScript("OnTextChanged", function(self, isUser)
            if isUser then db.autoInviteKeywords = self:GetText(); UpdateAutoInviteKeywords() end
        end)
        invitesConfig.keywordInput = AutoInviteInput
        DUI_AddTooltip(AutoInviteInput, "Whisper Keywords",
            { body = "Space- or comma-separated words. A whisper that is exactly one of them triggers an invite.",
              note = "Tick Match Anywhere below to also accept a keyword inside a longer whisper." })
        -- Advance, not Gap: Gap doesn't stretch the section card over the box.
        L:Advance(32)
        invitesConfig.anywhereCheck = L:Checkbox("Match a keyword anywhere in the whisper", db, "inviteMatchAnywhere", nil,
            { body = "Also invites when a keyword is one word of a longer whisper, so \"inv pls\" or \"can I get an invite?\" counts.",
              note = "Whole words only: \"inv\" doesn't match \"invested\"." })

        -- The "Auto-invite on matching whisper" checkbox that stood here is now
        -- the module's own checkbox on the launcher rail, alongside every other
        -- module's, rather than a second switch buried one click deeper.
        L:Text("Whisper any of these keywords to be invited automatically. A full party is converted to a raid first, so the sixth whisper still gets in. Auto-invite follows this module's checkbox in the module list.")

        L:Header("Invite From List")
        L:Text("Paste names one per line, or separated by commas or tabs: a spreadsheet column or a Discord sign-up post. Mentions, numbering and anything after the name (\"Dan (Mage)\") are dropped. Anyone already in the group is skipped.")

        -- A multi-line edit box in a scroll frame. The box grows with its text and
        -- the scroll frame keeps the caret in view, so a 30-name paste stays usable.
        local PASTE_H = 120
        local pasteBox = CreateFrame("Frame", nil, invitesConfig, "BackdropTemplate")
        pasteBox:SetSize(L:ContentWidth(), PASTE_H)
        DUI_StyleAsListBox(pasteBox)
        local sf = CreateFrame("ScrollFrame", nil, pasteBox)
        sf:SetPoint("TOPLEFT", 6, -6); sf:SetPoint("BOTTOMRIGHT", -6, 6)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true); eb:SetAutoFocus(false); eb:SetFontObject(DUI_FontNormal)
        eb:SetWidth(L:ContentWidth() - 12)
        eb:SetTextInsets(2, 2, 2, 2)
        sf:SetScrollChild(eb)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        eb:SetScript("OnCursorChanged", function(_, _, y, _, h)
            y = -y
            local top, view = sf:GetVerticalScroll(), sf:GetHeight()
            if y < top then
                sf:SetVerticalScroll(y)
            elseif y + h > top + view then
                sf:SetVerticalScroll(y + h - view)
            end
        end)
        sf:EnableMouseWheel(true)
        sf:SetScript("OnMouseWheel", function(self, delta)
            self:SetVerticalScroll(math.max(0, math.min(self:GetVerticalScrollRange(), self:GetVerticalScroll() - delta * 20)))
        end)
        -- The edit box is only as tall as its text; a click in the empty space
        -- below it should still land in the box.
        pasteBox:EnableMouse(true)
        pasteBox:SetScript("OnMouseDown", function() eb:SetFocus() end)
        L:Place(pasteBox)

        local countText
        local function UpdateCount()
            local n = #ParseNameList(eb:GetText())
            countText:SetText(n == 0 and "No names found" or string.format("%d name%s found", n, n == 1 and "" or "s"))
        end
        eb:SetScript("OnTextChanged", function(self, isUser)
            if isUser then db.invitePasteList = self:GetText() end
            UpdateCount()
        end)

        local listBtn = CreateFrame("Button", nil, invitesConfig, "BackdropTemplate")
        listBtn:SetSize(120, 25); listBtn:SetPoint("TOPLEFT", 40, L:Y()); listBtn:SetText("Invite List")
        StyleAsTealTab(listBtn)
        DUI_AddTooltip(listBtn, "Invite List",
            { body = "Invites every name in the box who isn't already in the group, converting to a raid when the list won't fit in a party.",
              note = "Solo, four go out at once and the rest follow as soon as someone accepts." })
        listBtn:SetScript("OnClick", function()
            if not db.autoInviteEnabled then
                print("|cFF00FF00[DUI]|r Invites is switched off in the module list.")
                return
            end
            eb:ClearFocus()
            InviteNameList(eb:GetText())
        end)

        local clearBtn = CreateFrame("Button", nil, invitesConfig, "BackdropTemplate")
        clearBtn:SetSize(70, 25); clearBtn:SetPoint("LEFT", listBtn, "RIGHT", 8, 0); clearBtn:SetText("Clear")
        StyleAsTealTab(clearBtn)
        DUI_AddTooltip(clearBtn, "Clear", "Empties the box.")
        clearBtn:SetScript("OnClick", function()
            db.invitePasteList = ""
            eb:SetText("")
            eb:ClearFocus()
        end)

        countText = invitesConfig:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
        countText:SetPoint("LEFT", clearBtn, "RIGHT", 12, 0)
        countText:SetTextColor(0.85, 0.85, 0.85)
        L:Advance(DUI_LAYOUT.ROW + 6)
        invitesConfig.pasteEdit = eb

        L:FitHeight()
        invitesConfig.init = true
    end
    -- Re-sync widgets to the current saved values whenever the panel opens.
    -- Rank names come from the server, so the roster is asked for here; the
    -- dropdown re-reads them each time it opens.
    if IsInGuild() and C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
    invitesConfig.keywordInput:SetText(db.autoInviteKeywords or "")
    invitesConfig.rankBtn:SetValue(RankCutoffText())
    invitesConfig.guildOnlyCheck:SetChecked(db.inviteGuildOnly)
    invitesConfig.anywhereCheck:SetChecked(db.inviteMatchAnywhere)
    invitesConfig.pasteEdit:SetText(db.invitePasteList or "")
    invitesConfig:Show()
end

-- ---- Battle Res Tracker ---------------------------------------------------
local brConfig = DUI_CreateConfigFrame("DUI_BattleResTrackerConfig", "Battle Res Tracker", 320, 255, "DUI_BattleResBtn")

function DUI_OpenBattleResTrackerConfig()
    EnsureRaidToolsDB()

    if not brConfig.init then
        local L = DUI_CreateLayout(brConfig)
        L:Header("Pooled Battle Res Charges")
        -- "Enable tracker" moved out to this module's checkbox on the launcher
        -- rail; DUI_BattleResApplyEnabled below is what the rail calls.
        brConfig.lockCheck = L:Checkbox("Lock position", db, "battleResLocked", function()
            if ToggleBRTracker then ToggleBRTracker(db.battleResEnabled) end
        end, { body = "Stops the icon being dragged.", note = "Unlock it to move it, then lock it again." })

        brConfig.sizeSlider = L:Slider("DUI_BR_Size", "Icon Size", 20, 100, 1, db, "battleResSize", function(v)
            db.battleResSize = math.floor(v + 0.5) -- the frame is sized from this, so keep it whole
            if DUI_UpdateBattleResSize then DUI_UpdateBattleResSize() end
        end, { value = db.battleResSize, tooltip = "Size of the battle-res icon in pixels." })

        L:Gap()
        L:Text("Shows remaining raid / Mythic+ combat-res charges and the recharge timer. Unlock to drag it into place.")

        L:FitHeight()
        brConfig.init = true
    end
    brConfig.lockCheck:SetChecked(db.battleResLocked)
    brConfig.sizeSlider:SetValue(db.battleResSize)
    brConfig:Show()
end

-- Applied when the launcher rail flips this module's checkbox. Both flags live in
-- the shared DanUIDB.RaidTools table, so the rail addresses them by field name.
function DUI_BattleResApplyEnabled(enabled)
    if ToggleBRTracker then ToggleBRTracker(enabled) end -- global from BattleRes.lua
end

function DUI_FloatingButtonsApplyEnabled()
    -- UpdateFloatingBar reads the flag itself and hides the bar when it is off.
    if UpdateFloatingBar then UpdateFloatingBar() end
end

-- ---- Floating Buttons -----------------------------------------------------
local fbConfig = DUI_CreateConfigFrame("DUI_FloatingButtonsConfig", "Floating Buttons", 320, 240, "DUI_FloatingButtonsBtn")

-- A labelled numeric field, built as one row so L:Place keeps it inside its
-- column. The two timers were hand-anchored at x=40 of the panel, which is the
-- left column's indent and nothing else's -- they could not move right.
local function NumberField(L, label, key, tooltipTitle, tooltip)
    local row = CreateFrame("Frame", nil, fbConfig)
    row:SetSize(L:ContentWidth(DUI_LAYOUT.INDENT), 25)

    local caption = row:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
    caption:SetPoint("LEFT")
    caption:SetText(label)

    local input = CreateFrame("EditBox", nil, row, "BackdropTemplate")
    input:SetSize(40, 25); input:SetPoint("LEFT", caption, "RIGHT", 10, 0)
    input:SetAutoFocus(false); input:SetNumeric(true); input:SetFontObject(DUI_FontNormal)
    input:SetBackdrop(DUI_EditBackdrop); input:SetBackdropColor(0, 0, 0, 0.5); input:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(input, "border")
    input:SetTextInsets(5, 5, 0, 0); input:SetText(tostring(db[key] or 0))
    input:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(1, 1, 0, 1) end)
    input:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(unpack(DUI_Theme.Accent)) end)
    input:SetScript("OnEnterPressed", function(self) self:ClearFocus() end); input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    input:SetScript("OnTextChanged", function(self, isUser)
        if isUser then local val = tonumber(self:GetText()); if val then db[key] = val end end
    end)
    DUI_AddTooltip(input, tooltipTitle, tooltip)

    L:Place(row, { band = true })
    return input
end

function DUI_OpenFloatingButtonsConfig()
    EnsureRaidToolsDB()

    if not fbConfig.init then
        local L = DUI_CreateLayout(fbConfig)
        -- The tick list sits beside the bar's own settings rather than under
        -- them: stacked, four more checkboxes pushed the timers off the pane.
        L:Columns(2)

        L:Header("Floating Bar")
        fbConfig.lockCheck = L:Checkbox("Lock floating buttons", db, "lockButtons", function()
            if UpdateFloatingBar then UpdateFloatingBar() end
        end, { body = "Hides the bar's background and its orientation / strata / text-size row, leaving just the buttons.",
               note = "Unlock it to drag the bar or change those settings." })

        L:Header("Timers")
        fbConfig.pullInput = NumberField(L, "Pull (seconds):", "pullTimer", "Default Pull Length",
            { body = "Seconds used by a left-click on the bar's Pull button.",
              note = "Right-click always pulls in 5." })
        fbConfig.breakInput = NumberField(L, "Break (minutes):", "breakTimer", "Default Break Length",
            { body = "Minutes used by a left-click on the bar's Break button; right-click cancels a running break.",
              note = "BigWigs' /break takes 1 to 60 minutes and needs lead or assist. It also drives DanUI's own break display." })

        L:Column(2)
        L:Header("Buttons")
        -- Built from the bar's own list so a button added there shows up here
        -- without this panel being edited.
        fbConfig.buttonChecks = {}
        for _, def in ipairs(DUI_FloatingButtonDefs or {}) do
            fbConfig.buttonChecks[def.dbKey] = L:Checkbox(def.label, db, def.dbKey, function()
                if UpdateFloatingBar then UpdateFloatingBar() end
            end, { body = "Shows the " .. def.label .. " button on the floating bar.",
                   note = "The bar resizes and re-centres around whatever is left." })
        end
        L:Text("Untick them all and the bar hides completely. Changes made in combat apply when you leave it.")

        L:EndColumns()
        L:FitHeight()
        fbConfig.init = true
    end
    -- Re-sync widgets to the current saved values whenever the panel opens.
    fbConfig.lockCheck:SetChecked(db.lockButtons)
    fbConfig.pullInput:SetText(tostring(db.pullTimer))
    fbConfig.breakInput:SetText(tostring(db.breakTimer or 5))
    for dbKey, cb in pairs(fbConfig.buttonChecks) do
        cb:SetChecked(db[dbKey] ~= false)
    end
    fbConfig:Show()
end


-- One frame, two owners: the whisper belongs to the Invites row, the roster
-- events to the Auto-Assist List row. Each is registered only while its row is
-- ticked, so a module switched off is not woken by every whisper or roster change.
local eventFrame = CreateFrame("Frame")

local function SyncRaidToolsEvents()
    if not db then return end
    if db.autoInviteEnabled then
        eventFrame:RegisterEvent("CHAT_MSG_WHISPER")
    else
        eventFrame:UnregisterEvent("CHAT_MSG_WHISPER")
        -- Invites parked behind a raid conversion would otherwise still go out.
        if pendingTimer then pendingTimer:Cancel(); pendingTimer = nil end
        wipe(pendingInvites)
        converting, pendingTries = false, 0
        -- So would the rest of a pasted list waiting for the party to form.
        ClearHeldInvites()
    end
    if AssistEnabled() then
        eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
        eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    else
        eventFrame:UnregisterEvent("GROUP_ROSTER_UPDATE")
        eventFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
        if rosterTimer then rosterTimer:Cancel(); rosterTimer = nil end
    end
end

-- Apply hooks for the two rows on the main window's rail.
DUI_InvitesApplyEnabled = SyncRaidToolsEvents
DUI_AssistApplyEnabled = SyncRaidToolsEvents

function DUI_InitRaidToolsModule()
    -- Backfills too: an existing table predates the invite filter keys, and the
    -- whisper handler reads them before the Invites panel is ever opened.
    EnsureRaidToolsDB()

    UpdateAutoInviteKeywords()

    SyncRaidToolsEvents()
    eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2)
        if event == "CHAT_MSG_WHISPER" then
            if not db.autoInviteEnabled then return end
            local sender = arg2
            if WhisperMatches(arg1) and WhisperAllowed(sender) then
                -- GetNumGroupMembers() counts the player, so 5 is a full party
                -- and the sender is the sixth: convert first, then invite once
                -- the raid is actually up (QueueInvite holds it until then).
                if GetNumGroupMembers() >= 5 then RequestRaidConvert() end
                QueueInvite(sender)
            end
        elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
            -- Throttle roster promotions to wait for API data to settle
            if rosterTimer then rosterTimer:Cancel() end
            rosterTimer = C_Timer.NewTimer(0.5, DUI_ProcessRosterPromotions)
        end
    end)

    -- Perform an initial promotion check on addon load/reload
    C_Timer.After(1.0, DUI_ProcessRosterPromotions) -- Add a small delay to allow all data to load
end