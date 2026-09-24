-- RaidToolsModule.lua
-- Handles Auto-Invite, Battle Res Tracker settings, Floating Button lock, and Pull Timer.
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
            { body = "Invites every online guild member of rank 6 or better, converting to a raid first if needed.",
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
            RequestRaidConvert()
            for i = 1, GetNumGuildMembers() do
                local name, _, rankIndex, _, _, _, _, _, online = GetGuildRosterInfo(i)
                if name and online and rankIndex < 7 then
                    QueueInvite(name)
                end
            end
        end)

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
            "Space- or comma-separated words. A whisper containing any of them triggers an invite.")
        L:Gap(32)

        -- The "Auto-invite on matching whisper" checkbox that stood here is now
        -- the module's own checkbox on the launcher rail, alongside every other
        -- module's, rather than a second switch buried one click deeper.
        L:Gap()
        L:Text("Whisper any of these keywords (space or comma separated) to be invited automatically. A full party is converted to a raid first, so the sixth whisper still gets in. Auto-invite follows this module's checkbox in the module list.")

        L:FitHeight()
        invitesConfig.init = true
    end
    -- Re-sync widgets to the current saved values whenever the panel opens.
    invitesConfig.keywordInput:SetText(db.autoInviteKeywords or "")
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
    if not DanUIDB.RaidTools then DanUIDB.RaidTools = DUI_GetRaidToolsDefaults() end
    db = DanUIDB.RaidTools

    UpdateAutoInviteKeywords()

    SyncRaidToolsEvents()
    eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2)
        if event == "CHAT_MSG_WHISPER" then
            if not db.autoInviteEnabled then return end
            local msg, sender = strtrim(arg1:lower()), arg2
            if AutoInviteKeywordsTable[msg] then
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