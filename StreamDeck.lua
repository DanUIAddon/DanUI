-- StreamDeck.lua
-- Keybindable DanUI actions for a Stream Deck (or any macro pad / keyboard).
--
-- An addon cannot talk to the Stream Deck software, and the deck cannot talk to the
-- game: the only channel is a key press. So every action here is a hidden button,
-- and DanUI binds a key to it with SetOverrideBindingClick. A Stream Deck key set
-- to "Hotkey" presses that key. The default keys below are the ones the bundled
-- DanUI Stream Deck profile sends, so the two must stay in step: change a default
-- here and the profile (built outside the addon) has to be rebuilt.
--
-- Override bindings are not saved by the client. They are re-applied at every
-- login from DanUIDB.StreamDeck.keys, which is why they live in this module rather
-- than in Esc > Keybindings. An override beats a normal binding on the same key,
-- so the panel shows what a key used to do, and chat says so once when that list
-- changes.
--
-- Two kinds of action:
--   * "macro"/"item"/"teleport" run through SecureActionButtonTemplate, because
--     using items and casting spells need a secure click. Their attributes can only be set
--     out of combat, so a change made mid-fight is held until combat ends.
--   * "lua" is a plain button with an OnClick. Ready check and the countdown are
--     not hardware-protected (ReadyCheckPullTimer.lua already calls them from
--     events), so they don't need the secure path.

local db

local InCombatLockdown = InCombatLockdown
local GetBindingAction, GetBindingText = GetBindingAction, GetBindingText
local SetOverrideBindingClick, ClearOverrideBindings = SetOverrideBindingClick, ClearOverrideBindings

local function Print(msg)
    print(DUI_AccentText("DanUI Stream Deck") .. ": " .. msg)
end

-- ---- action list --------------------------------------------------------------
-- Order is the panel's order. `key` is the default, written in the client's own
-- modifier order (ALT-CTRL-SHIFT), which is what GetBindingAction expects back.
-- F4 is skipped on purpose: Alt+F4 closes the game window, and Ctrl+Alt+Shift+F4
-- is close enough to it to not be worth finding out.

local ACTIONS = {
    -- Raid
    { id = "readyCheck", group = "Raid", label = "Ready Check",  kind = "lua", key = "ALT-CTRL-SHIFT-F1",
      tip = "Starts a ready check. DanUI's RC & Pull module then auto-pulls as usual." },
    { id = "pull10",     group = "Raid", label = "Pull 10",      kind = "lua", key = "ALT-CTRL-SHIFT-F2",
      tip = "10 second pull timer. In a Heroic raid with RC & Pull's random pull timer on, it rolls a random length instead." },
    { id = "pull20",     group = "Raid", label = "Pull 20",      kind = "lua", key = "ALT-CTRL-SHIFT-F3",
      tip = "20 second pull timer. Follows the random Heroic pull timer the same way." },
    { id = "cancelPull", group = "Raid", label = "Cancel Pull",  kind = "lua", key = "ALT-CTRL-SHIFT-F5",
      tip = "Cancels a running pull timer." },
    { id = "break",      group = "Raid", label = "Break",        kind = "lua", key = "ALT-CTRL-SHIFT-F6",
      tip = "Starts a break timer (BigWigs /break). The length is the one set in Floating Buttons." },
    -- Consumables: the item is whatever the player drops on the slot, because the
    -- item IDs change every season and with every crafted quality rank.
    { id = "flask",    group = "Consumables", label = "Flask",          kind = "item", key = "CTRL-SHIFT-F11" },
    { id = "food",     group = "Consumables", label = "Food",           kind = "item", key = "CTRL-SHIFT-F12" },
    { id = "rune",     group = "Consumables", label = "Augment Rune",   kind = "item", key = "CTRL-NUMPAD1" },
    -- /use 16 puts the oil on the main hand, which is the cursor-targeting step
    -- a weapon enhancement otherwise waits for.
    { id = "oil",      group = "Consumables", label = "Weapon Oil",     kind = "item", key = "CTRL-NUMPAD2", weapon = true,
      tip = "Applies the oil or whetstone to your main-hand weapon." },

    -- Travel. The mount key dismounts when mounted, so one key does both.
    { id = "mount",  group = "Travel", label = "Mount", kind = "macro", key = "ALT-CTRL-SHIFT-F9",
      macro = "/dismount [mounted]\n/run if not IsMounted() then C_MountJournal.SummonByID(0) end",
      tip = "Summons a random favourite mount, or dismounts you." },
    { id = "hearth", group = "Travel", label = "Hearthstone", kind = "item", key = "ALT-CTRL-SHIFT-F10", defaultItem = 6948,
      tip = "Uses your Hearthstone. Drop a hearthstone toy on the slot to use that instead." },

    -- Mythic+ teleports. Which dungeon a slot is changes every season, so the slots
    -- are filled at login from the season's map table (see ResolveTeleports), in
    -- alphabetical order of the dungeon name with a leading "The" ignored. The deck
    -- profile's labels follow that same order.
    { id = "mplus1", group = "Mythic+ Teleports", label = "M+ Teleport 1", kind = "teleport", slot = 1, key = "CTRL-SHIFT-F1" },
    { id = "mplus2", group = "Mythic+ Teleports", label = "M+ Teleport 2", kind = "teleport", slot = 2, key = "CTRL-SHIFT-F2" },
    { id = "mplus3", group = "Mythic+ Teleports", label = "M+ Teleport 3", kind = "teleport", slot = 3, key = "CTRL-SHIFT-F3" },
    { id = "mplus4", group = "Mythic+ Teleports", label = "M+ Teleport 4", kind = "teleport", slot = 4, key = "CTRL-SHIFT-F5" },
    { id = "mplus5", group = "Mythic+ Teleports", label = "M+ Teleport 5", kind = "teleport", slot = 5, key = "CTRL-SHIFT-F6" },
    { id = "mplus6", group = "Mythic+ Teleports", label = "M+ Teleport 6", kind = "teleport", slot = 6, key = "CTRL-SHIFT-F7" },
    { id = "mplus7", group = "Mythic+ Teleports", label = "M+ Teleport 7", kind = "teleport", slot = 7, key = "CTRL-SHIFT-F8" },
    { id = "mplus8", group = "Mythic+ Teleports", label = "M+ Teleport 8", kind = "teleport", slot = 8, key = "CTRL-SHIFT-F9" },

    -- DanUI windows
    { id = "toggleDanUI", group = "DanUI", label = "DanUI Window", kind = "lua", key = "ALT-CTRL-SHIFT-F11",
      tip = "Opens or closes the /dan window." },
    { id = "toggleCraft", group = "DanUI", label = "Craft Planner Window", kind = "lua", key = "ALT-CTRL-SHIFT-F12",
      tip = "Opens or closes the Craft Planner next-step window (/dancraft)." },
}

local ACTION_BY_ID = {}
for _, a in ipairs(ACTIONS) do ACTION_BY_ID[a.id] = a end

-- keys / items are filled per action in EnsureDB rather than here, because
-- DUI_InitModuleDB only backfills top-level keys: an action added in a later
-- version would otherwise never get its default key.
function DUI_GetStreamDeckDefaults()
    return {
        enabled = true,
        keys = {},   -- id -> binding string, or false once the player clears it
        items = {},  -- id -> itemID
        warned = "", -- the conflict list last printed, so it is said once
    }
end

local function EnsureDB()
    if not DanUIDB then return nil end
    db = DUI_InitModuleDB("StreamDeck", DUI_GetStreamDeckDefaults)
    for _, a in ipairs(ACTIONS) do
        if db.keys[a.id] == nil then db.keys[a.id] = a.key end
        if db.items[a.id] == nil and a.defaultItem then db.items[a.id] = a.defaultItem end
    end
    -- Actions that were removed (Stack/Spread, markers, potions, 2026-11-05) keep
    -- nothing behind: a stale entry would otherwise hold its key in SetKey's
    -- "one key, one action" sweep.
    for id in pairs(db.keys) do
        if not ACTION_BY_ID[id] then db.keys[id] = nil end
    end
    for id in pairs(db.items) do
        if not ACTION_BY_ID[id] then db.items[id] = nil end
    end
    return db
end

-- ---- what the lua actions do ---------------------------------------------------

local function CanLead()
    return not IsInGroup() or UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
end

-- Mirrors StartAutoPull in ReadyCheckPullTimer.lua: a Heroic raid (difficulty 15)
-- with the random pull option on rolls the length from the player's range, so a
-- key press and the auto-pull follow the same rule.
local function PullLength(base)
    local rc = DanUIDB and DanUIDB.ReadyCheckPullTimer
    if rc and rc.enabled ~= false and rc.randomHeroicPull and select(3, GetInstanceInfo()) == 15 then
        local lo = math.floor((tonumber(rc.randomPullMin) or 10) + 0.5)
        local hi = math.floor((tonumber(rc.randomPullMax) or 20) + 0.5)
        if lo > hi then lo, hi = hi, lo end
        return math.random(lo, hi), true
    end
    return base, false
end

local function Countdown(seconds)
    if IsInGroup() and not CanLead() then
        Print("you need lead or assist to start a pull timer.")
        return
    end
    if C_PartyInfo and C_PartyInfo.DoCountdown then
        C_PartyInfo.DoCountdown(seconds)
    end
end

local function SendSlash(text)
    local editBox = ChatEdit_ChooseBoxForSend()
    editBox:SetText(text)
    ChatEdit_SendText(editBox)
end

local LUA_ACTIONS = {
    readyCheck = function()
        if not IsInGroup() then Print("you're not in a group.") return end
        if not CanLead() then Print("you need lead or assist to start a ready check.") return end
        if C_PartyInfo and C_PartyInfo.DoReadyCheck then C_PartyInfo.DoReadyCheck() else DoReadyCheck() end
    end,
    pull10 = function()
        local s, random = PullLength(10)
        if random then Print("random Heroic pull: " .. s .. "s.") end
        Countdown(s)
    end,
    pull20 = function()
        local s, random = PullLength(20)
        if random then Print("random Heroic pull: " .. s .. "s.") end
        Countdown(s)
    end,
    cancelPull = function() Countdown(0) end,
    ["break"] = function()
        -- Same route as the floating Break button: /break is BigWigs' command and
        -- counts in minutes, and it is what feeds DanUI's own break display.
        local saved = DanUIDB and DanUIDB.RaidTools and tonumber(DanUIDB.RaidTools.breakTimer)
        local minutes = saved and math.min(math.max(math.floor(saved), 1), 60) or 5
        SendSlash("/break " .. minutes)
    end,
    -- Both windows hold secure buttons, so showing or hiding them is blocked in
    -- combat (see CLAUDE.md, "A secure button makes its whole ancestry protected").
    toggleDanUI = function()
        if InCombatLockdown() then Print("the DanUI window can't be opened or closed in combat.") return end
        if SlashCmdList.DAN then SlashCmdList.DAN("") end
    end,
    toggleCraft = function()
        if InCombatLockdown() then Print("the Craft Planner window can't be opened or closed in combat.") return end
        if SlashCmdList.DUICRAFT then SlashCmdList.DUICRAFT("") end
    end,
}

-- ---- the hidden buttons ------------------------------------------------------
-- Hidden is fine: a CLICK binding calls the button's Click directly, it does not
-- go through the mouse. Parented to UIParent rather than a holder frame of ours so
-- that nothing DanUI shows or hides becomes protected because of them.

local buttons = {}
local owner = CreateFrame("Frame", "DUI_StreamDeckOwner", UIParent)

for _, a in ipairs(ACTIONS) do
    local name = "DUI_SD_" .. a.id
    local b
    if a.kind == "lua" then
        b = CreateFrame("Button", name, UIParent)
        b:RegisterForClicks("AnyUp")
        local fn = LUA_ACTIONS[a.id]
        b:SetScript("OnClick", function()
            if db and db.enabled and fn then fn() end
        end)
    else
        b = CreateFrame("Button", name, UIParent, "SecureActionButtonTemplate")
        -- Both edges, so the secure template can honour ActionButtonUseKeyDown the
        -- way it does for action bars (same as DUI_RCButton in FloatingButtons.lua).
        b:RegisterForClicks("AnyUp", "AnyDown")
        if a.kind == "macro" then
            b:SetAttribute("type", "macro")
            b:SetAttribute("macrotext", a.macro)
        end
    end
    b:Hide()
    buttons[a.id] = b
end

local function IsToy(itemID)
    return itemID and C_ToyBox and C_ToyBox.GetToyInfo and C_ToyBox.GetToyInfo(itemID) ~= nil
end

-- An empty slot still gets a macro, so pressing it says what's missing instead of
-- doing nothing.
local function ConfigureItemButton(a)
    local b = buttons[a.id]
    local itemID = db and db.items[a.id]
    if not itemID then
        b:SetAttribute("type", "macro")
        b:SetAttribute("toy", nil)
        b:SetAttribute("macrotext", "/run print('DanUI Stream Deck: no item set for " .. a.label
            .. ". Drop one on its slot in /dan > Stream Deck.')")
    elseif IsToy(itemID) then
        b:SetAttribute("type", "toy")
        b:SetAttribute("toy", itemID)
        b:SetAttribute("macrotext", nil)
    else
        b:SetAttribute("type", "macro")
        b:SetAttribute("toy", nil)
        local text = "/use item:" .. itemID
        if a.weapon then text = text .. "\n/use 16" end
        b:SetAttribute("macrotext", text)
    end
end

-- ---- Mythic+ teleports -------------------------------------------------------------
-- No API maps a dungeon to its teleport. The teleports sit in the spellbook's
-- "Hero's Path" flyouts, and each one's description names its dungeon ("Teleport to
-- the entrance to the Ruby Life Pools."), so the season's dungeon names are matched
-- against those descriptions. Nothing here is hardcoded per season.

local teleports = {} -- slot -> { name, icon, spellID, known }
local resolveTimer

local function Normalize(text)
    text = (text or ""):lower():gsub("^the ", "")
    return (text:gsub("[^%w]", ""))
end

local function SeasonDungeons()
    local list = {}
    local maps = C_ChallengeMode and C_ChallengeMode.GetMapTable and C_ChallengeMode.GetMapTable()
    for _, mapID in ipairs(maps or {}) do
        local name, _, _, texture = C_ChallengeMode.GetMapUIInfo(mapID)
        if name then list[#list + 1] = { name = name, icon = texture, sortKey = Normalize(name) } end
    end
    table.sort(list, function(x, y) return x.sortKey < y.sortKey end)
    return list
end

-- Every spell in every flyout, with its description normalised for matching. A
-- description not yet in the client cache comes back empty; those are asked for
-- and the whole pass runs again when they arrive (SPELL_DATA_LOAD_RESULT).
local function FlyoutSpells()
    local spells, missing = {}, false
    if not (GetNumFlyouts and GetFlyoutID and GetFlyoutInfo and GetFlyoutSlotInfo) then return spells end
    for i = 1, GetNumFlyouts() do
        local flyoutID = GetFlyoutID(i)
        local _, _, numSlots = GetFlyoutInfo(flyoutID)
        for s = 1, numSlots or 0 do
            local spellID, _, isKnown, spellName = GetFlyoutSlotInfo(flyoutID, s)
            if spellID then
                local desc = C_Spell and C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(spellID) or ""
                if desc == "" then
                    missing = true
                    if C_Spell and C_Spell.RequestLoadSpellData then C_Spell.RequestLoadSpellData(spellID) end
                end
                spells[#spells + 1] = { id = spellID, known = isKnown, text = Normalize(desc) .. "|" .. Normalize(spellName) }
            end
        end
    end
    return spells, missing
end

local function ConfigureTeleportButton(a)
    local b = buttons[a.id]
    local t = teleports[a.slot]
    if t and t.spellID and t.known then
        b:SetAttribute("type", "spell")
        b:SetAttribute("spell", t.spellID)
        b:SetAttribute("macrotext", nil)
        return
    end
    local why
    if not t then
        why = "no dungeon in slot " .. a.slot .. " this season."
    elseif not t.spellID then
        why = "couldn't find the teleport for " .. t.name .. "."
    else
        why = "you don't have the teleport for " .. t.name .. " yet (time it at +10)."
    end
    b:SetAttribute("type", "macro")
    b:SetAttribute("spell", nil)
    b:SetAttribute("macrotext", "/run print(\"DanUI Stream Deck: " .. why:gsub('"', "") .. "\")")
end

-- ---- applying the keys ---------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local pendingApply = false

local function QueueAfterCombat()
    pendingApply = true
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
end

local function BindingName(action)
    if not action or action == "" then return nil end
    local label = _G["BINDING_NAME_" .. action]
    if label then return label end
    -- CLICK bindings belong to another addon's button; name the button.
    local button = action:match("^CLICK ([^:]+)")
    return button or action
end

-- Which normal binding a key would hide. GetBindingAction without the override
-- flag reads the player's own bindings, so our overrides don't count as a clash.
local function ConflictFor(key)
    if not key then return nil end
    return BindingName(GetBindingAction(key))
end

local function ReportConflicts()
    local lines = {}
    for _, a in ipairs(ACTIONS) do
        local key = db.keys[a.id]
        local clash = key and ConflictFor(key)
        if clash then lines[#lines + 1] = GetBindingText(key) .. " (was " .. clash .. ") -> " .. a.label end
    end
    local sig = table.concat(lines, "; ")
    if sig ~= "" and sig ~= db.warned then
        Print("these keys now run DanUI actions instead of their usual bind: " .. sig
            .. ". Change them in /dan > Stream Deck.")
    end
    db.warned = sig
end

local function ApplyBindings()
    if not db then return end
    if InCombatLockdown() then QueueAfterCombat() return end
    pendingApply = false
    for _, a in ipairs(ACTIONS) do
        if a.kind == "item" then ConfigureItemButton(a)
        elseif a.kind == "teleport" then ConfigureTeleportButton(a) end
    end
    ClearOverrideBindings(owner)
    if not db.enabled then return end
    for _, a in ipairs(ACTIONS) do
        local key = db.keys[a.id]
        if key then SetOverrideBindingClick(owner, false, key, buttons[a.id]:GetName(), "LeftButton") end
    end
end

local RefreshPanel -- forward: the panel is built on first open

local function ResolveTeleports()
    resolveTimer = nil
    local dungeons = SeasonDungeons()
    if #dungeons == 0 then
        -- The season's map table loads on request; CHALLENGE_MODE_MAPS_UPDATE
        -- brings us back here.
        if C_MythicPlus and C_MythicPlus.RequestMapInfo then C_MythicPlus.RequestMapInfo() end
        return
    end
    local spells = FlyoutSpells()
    wipe(teleports)
    for i, d in ipairs(dungeons) do
        local key = Normalize(d.name)
        local t = { name = d.name, icon = d.icon }
        for _, sp in ipairs(spells) do
            -- A dungeon back from an old season can have its teleport in two
            -- flyouts; a copy the player actually knows wins.
            if key ~= "" and sp.text:find(key, 1, true) then
                local known = sp.known or (IsPlayerSpell and IsPlayerSpell(sp.id)) or false
                if not t.spellID or (known and not t.known) then
                    t.spellID, t.known = sp.id, known
                end
                if known then break end
            end
        end
        teleports[i] = t
    end
    ApplyBindings()
    if RefreshPanel then RefreshPanel() end
end

-- SPELLS_CHANGED and SPELL_DATA_LOAD_RESULT arrive in bursts; one pass a second
-- after the last of them is plenty.
local function QueueResolve()
    if resolveTimer then resolveTimer:Cancel() end
    resolveTimer = C_Timer.NewTimer(1, ResolveTeleports)
end

-- Rail hook (DanUI.lua's DUI_MODULE_GROUPS). Off clears every key, so they go back
-- to whatever they did before.
function DUI_StreamDeckApplyEnabled(enabled)
    if not EnsureDB() then return end
    ApplyBindings()
    if enabled and not InCombatLockdown() then ReportConflicts() end
end

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("UPDATE_BINDINGS")
eventFrame:RegisterEvent("CHALLENGE_MODE_MAPS_UPDATE")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("SPELL_DATA_LOAD_RESULT")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= "DanUI" then return end
        self:UnregisterEvent("ADDON_LOADED")
        EnsureDB()
    elseif event == "PLAYER_LOGIN" then
        EnsureDB()
        ApplyBindings()
        if db and db.enabled then ReportConflicts() end
        QueueResolve()
    elseif event == "PLAYER_REGEN_ENABLED" then
        self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        if pendingApply then ApplyBindings() end
        if RefreshPanel then RefreshPanel() end
    elseif event == "UPDATE_BINDINGS" then
        -- The player changed a normal bind; the "was ..." notes may be stale.
        if RefreshPanel then RefreshPanel() end
    elseif event == "CHALLENGE_MODE_MAPS_UPDATE" or event == "SPELLS_CHANGED" or event == "SPELL_DATA_LOAD_RESULT" then
        -- Before login the spellbook isn't there yet; PLAYER_LOGIN queues the first pass.
        if IsLoggedIn() then QueueResolve() end
    end
end)

-- ---- settings panel --------------------------------------------------------------

local config = DUI_CreateConfigFrame("DUI_StreamDeckConfig", "Stream Deck", 560, 400, nil)
local rows = {}
local capturing -- the row waiting for a key press

local MODIFIER_KEYS = {
    LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
    LMETA = true, RMETA = true, UNKNOWN = true,
}

local function KeyLabel(key)
    if not key then return "|cff808080Not set|r" end
    return GetBindingText(key)
end

local function StopCapture()
    if not capturing then return end
    local row = capturing
    capturing = nil
    row.keyBtn:EnableKeyboard(false)
    row.keyBtn:SetScript("OnKeyDown", nil)
    if RefreshPanel then RefreshPanel() end
end

local function SetKey(id, key)
    -- One key, one action: taking a key from another DanUI action clears it there.
    if key then
        for otherID, k in pairs(db.keys) do
            if otherID ~= id and k == key then db.keys[otherID] = false end
        end
    end
    db.keys[id] = key or false
    ApplyBindings()
end

local function StartCapture(row)
    if InCombatLockdown() then Print("keys can't be changed in combat.") return end
    StopCapture()
    capturing = row
    row.keyBtn:SetText(DUI_AccentText("Press a key..."))
    row.keyBtn:EnableKeyboard(true)
    row.keyBtn:SetPropagateKeyboardInput(false)
    row.keyBtn:SetScript("OnKeyDown", function(self, key)
        if MODIFIER_KEYS[key] then return end
        if key == "ESCAPE" then StopCapture() return end
        local combo = (IsAltKeyDown() and "ALT-" or "") .. (IsControlKeyDown() and "CTRL-" or "")
            .. (IsShiftKeyDown() and "SHIFT-" or "") .. key
        local id = row.action.id
        StopCapture()
        if InCombatLockdown() then Print("keys can't be changed in combat.") return end
        SetKey(id, combo)
        RefreshPanel()
    end)
end

local function ItemSlotSet(row, itemID)
    if InCombatLockdown() then Print("items can't be changed in combat.") return end
    db.items[row.action.id] = itemID
    ApplyBindings()
    RefreshPanel()
end

local function AcceptCursorItem(row)
    local kind, id = GetCursorInfo()
    if kind == "item" or kind == "toy" then
        ClearCursor()
        ItemSlotSet(row, tonumber(id))
        return true
    end
end

local function BuildRow(parent, a)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(480, 24)
    row.action = a

    row.label = row:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    row.label:SetPoint("LEFT", 0, 0)
    row.label:SetWidth(150)
    row.label:SetJustifyH("LEFT")
    row.label:SetText(a.label)

    local x = 160
    if a.kind == "item" then
        local slot = CreateFrame("Button", nil, row, "BackdropTemplate")
        slot:SetSize(22, 22)
        slot:SetPoint("LEFT", x, 0)
        slot:SetBackdrop(DUI_EditBackdrop)
        slot:SetBackdropColor(0, 0, 0, 0.5)
        slot:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
        DUI_RegisterAccent(slot, "border")
        slot.icon = slot:CreateTexture(nil, "ARTWORK")
        slot.icon:SetPoint("TOPLEFT", 2, -2)
        slot.icon:SetPoint("BOTTOMRIGHT", -2, 2)
        slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        slot:SetScript("OnReceiveDrag", function() AcceptCursorItem(row) end)
        slot:SetScript("OnClick", function(_, button)
            if button == "RightButton" then
                ItemSlotSet(row, a.defaultItem)
            else
                AcceptCursorItem(row)
            end
        end)
        slot:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local itemID = db.items[a.id]
            if itemID then
                GameTooltip:SetItemByID(itemID)
            else
                GameTooltip:SetText(a.label)
            end
            GameTooltip:AddLine("Drag an item from your bags (or a toy) onto this slot.", 0.7, 0.7, 0.7, true)
            GameTooltip:AddLine(a.defaultItem and "Right-click: back to the default." or "Right-click: clear.", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.slot = slot

        row.itemName = row:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
        row.itemName:SetPoint("LEFT", slot, "RIGHT", 6, 0)
        row.itemName:SetWidth(110)
        row.itemName:SetJustifyH("LEFT")
        row.itemName:SetWordWrap(false)
    end

    local keyBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
    keyBtn:SetSize(150, 22)
    keyBtn:SetPoint("LEFT", 300, 0)
    StyleAsTealTab(keyBtn)
    keyBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    keyBtn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            StopCapture()
            if InCombatLockdown() then Print("keys can't be changed in combat.") return end
            SetKey(a.id, nil)
            RefreshPanel()
        elseif capturing == row then
            StopCapture()
        else
            StartCapture(row)
        end
    end)
    DUI_AddTooltip(keyBtn, a.label, {
        body = (a.tip and (a.tip .. "\n\n") or "") .. "Click, then press the key you want. Right-click to clear. Esc cancels.",
    })
    row.keyBtn = keyBtn

    row.note = row:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    row.note:SetPoint("LEFT", keyBtn, "RIGHT", 6, 0)
    row.note:SetWidth(80)
    row.note:SetJustifyH("LEFT")
    row.note:SetWordWrap(false)
    row.note:SetTextColor(0.9, 0.6, 0.3)
    -- The full "was ..." text is often longer than the column, so it is on hover too.
    row.noteHit = CreateFrame("Frame", nil, row)
    row.noteHit:SetAllPoints(row.note)
    row.noteHit:SetScript("OnEnter", function(self)
        if not row.conflict then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Replaces a normal keybind")
        GameTooltip:AddLine("While DanUI's Stream Deck module is on, this key runs " .. a.label
            .. " instead of: " .. row.conflict, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row.noteHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

    DUI_IndexSearchEntry(parent, a.label, keyBtn, a.tip)
    return row
end

RefreshPanel = function()
    if not db or not config.init or not config:IsShown() then return end
    for _, row in ipairs(rows) do
        local a = row.action
        local key = db.keys[a.id] or nil
        if a.kind == "teleport" then
            local t = teleports[a.slot]
            if not t then
                row.label:SetText("|cff808080Slot " .. a.slot .. ": no dungeon|r")
            elseif not t.spellID then
                row.label:SetText(t.name .. " |cffe08040(not found)|r")
            elseif not t.known then
                row.label:SetText(t.name .. " |cff808080(not earned)|r")
            else
                row.label:SetText(t.name)
            end
        end
        if capturing ~= row then row.keyBtn:SetText(KeyLabel(key)) end
        row.conflict = key and ConflictFor(key) or nil
        row.note:SetText(row.conflict and ("was " .. row.conflict) or "")
        if row.slot then
            local itemID = db.items[a.id]
            if itemID then
                local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
                row.slot.icon:SetTexture(icon or 134400)
                -- Names of items not yet in the client cache come back nil; ask for
                -- the item and repaint when it arrives.
                local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
                if not name and Item and Item.CreateFromItemID then
                    Item:CreateFromItemID(itemID):ContinueOnItemLoad(function() RefreshPanel() end)
                end
                row.itemName:SetText(name or ("item " .. itemID))
                row.itemName:SetTextColor(0.85, 0.85, 0.85)
            else
                row.slot.icon:SetTexture(nil)
                row.itemName:SetText("drop an item here")
                row.itemName:SetTextColor(0.5, 0.5, 0.5)
            end
        end
    end
end

local function ResetToDefaults()
    if InCombatLockdown() then Print("keys can't be changed in combat.") return end
    for _, a in ipairs(ACTIONS) do db.keys[a.id] = a.key end
    ApplyBindings()
    ReportConflicts()
    RefreshPanel()
    Print("keys reset to the ones the DanUI Stream Deck profile uses.")
end

function DUI_OpenStreamDeckConfig()
    if not EnsureDB() then return end
    if not config.init then
        local L = DUI_CreateLayout(config)
        L:Header("How it works")
        L:Text("Each action below has a key. A Stream Deck button set to press that key runs the action, and the DanUI Stream Deck profile already uses these defaults. "
            .. "The keys only work while this module is ticked, and they take priority over normal keybinds on the same key.")
        L:Text("Click a key to change it, right-click to clear it. Keys and items can't be changed in combat.")

        local group
        for _, a in ipairs(ACTIONS) do
            if a.group ~= group then
                group = a.group
                L:Header(group)
                if group == "Mythic+ Teleports" then
                    L:Text("This season's dungeons in alphabetical order, filled in automatically. A teleport you haven't earned yet just says so in chat.")
                elseif group == "Consumables" then
                    L:Text("Drag the item you use from your bags onto each slot. Different quality ranks are different items, so drop the one you actually carry.")
                end
            end
            local row = BuildRow(config, a)
            rows[#rows + 1] = row
            L:Place(row, { step = 26 })
        end

        L:Header("Defaults")
        local reset = CreateFrame("Button", nil, config, "BackdropTemplate")
        reset:SetSize(200, 22)
        L:Place(reset)
        reset:SetText("Reset Keys to Profile Defaults")
        StyleAsTealTab(reset)
        DUI_AddTooltip(reset, "Reset Keys", "Puts every key back to the one the DanUI Stream Deck profile sends. Items are kept.")
        reset:SetScript("OnClick", ResetToDefaults)

        L:FitHeight()
        config:HookScript("OnShow", function() RefreshPanel() end)
        config:HookScript("OnHide", StopCapture)
        config.init = true
    end
    config:Show()
    RefreshPanel()
end
