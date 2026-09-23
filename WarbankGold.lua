-- WarbankGold.lua
-- Reconciles this character's purse against a target every time the personal
-- bank opens: anything over the target is deposited into the warband bank,
-- anything short is withdrawn back out of it.
--
-- One account-wide default covers every character; a per-character override
-- (keyed "Name-Realm") wins over it for the alts that want more or less.
--
-- Off by default. Nothing here asks for confirmation before moving real gold, so
-- it stays dormant until it is deliberately switched on.
--
-- Split back out of BankTools.lua, which had briefly carried this and the guild
-- bank restock behind one pair of tabs. They shared a trigger word and nothing
-- else: separate events, separate banks, separate reasons to be switched on. The
-- other half is GuildBankRestock.lua.

local db -- Local reference to DanUIDB.WarbankGold

-------------------------------------------------------------------------------
-- Saved variables
-------------------------------------------------------------------------------

function DUI_GetWarbankGoldDefaults()
    return {
        enabled = false,
        defaultGold = 5000,
        overrides = {},   -- ["Name-Realm"] = gold
    }
end

-- Folds the gold half of the merged BankTools table across, then marks that half
-- taken. The two modules migrate independently and in either order, so the shared
-- source table is only dropped once both have had their share of it - clearing it
-- from here alone would leave the restock module with nothing to read.
--
-- The old master switch and the old per-half tick both had to be on for anything
-- to happen, so their AND is what the single new switch inherits.
local function MigrateLegacyTables()
    -- Pre-merge table, for an install that never ran the BankTools version.
    local old = DanUIDB.WarbankTools
    if type(old) == "table" then
        db.enabled = old.enabled and true or false
        if type(old.defaultGold) == "number" then db.defaultGold = old.defaultGold end
        if type(old.overrides) == "table" then db.overrides = old.overrides end
        DanUIDB.WarbankTools = nil
    end

    local merged = DanUIDB.BankTools
    if type(merged) == "table" and not merged.goldMigrated then
        db.enabled = (merged.enabled and merged.goldEnabled) and true or false
        if type(merged.defaultGold) == "number" then db.defaultGold = merged.defaultGold end
        if type(merged.overrides) == "table" then db.overrides = merged.overrides end
        merged.goldMigrated = true
        if merged.restockMigrated then DanUIDB.BankTools = nil end
    end
end

-- Split out of DUI_InitWarbankGold so opening the panel before login has run the
-- module's init still gets a populated db.
function DUI_InitWarbankGoldDB()
    db = DUI_InitModuleDB("WarbankGold", DUI_GetWarbankGoldDefaults)
    MigrateLegacyTables()
    db.overrides = db.overrides or {}
    return db
end

-------------------------------------------------------------------------------
-- Reconciling the purse against a target
-------------------------------------------------------------------------------

local function Print(text)
    print("|cFF00FF00[DUI]|r Gold: " .. text)
end

-- The panel is built lazily on first open; this is the repaint hook the logic
-- below calls into before that has happened.
local Refresh = function() end

local COPPER_PER_GOLD = 10000
-- Sub-gold drift is ignored, so a character that is a few silver off target does
-- not fire a transfer on every single bank visit.
local TOLERANCE = 1 * COPPER_PER_GOLD
local MAX_GOLD = 99999999

local Coin = C_CurrencyInfo.GetCoinTextureString

-- Money is not a secret value today, but arithmetic on one taints the addon for
-- the rest of the session, so every read is checked before it is used.
local function IsSecret(v)
    return issecretvalue and issecretvalue(v)
end

local function AccountBankType()
    return Enum and Enum.BankType and Enum.BankType.Account
end

local function CharKey()
    local name = UnitName("player")
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
    if not name or not realm or realm == "" then return nil end
    return name .. "-" .. realm
end

local function FormatGold(g)
    return (BreakUpLargeNumbers and BreakUpLargeNumbers(g) or tostring(g)) .. "g"
end

-- Accepts "12000", "12,000" or "12 000"; rejects anything that is not a
-- non-negative number. Returns nil on a bad string so the caller can leave the
-- saved value alone rather than writing a zero over it.
local function ParseGold(text)
    if not text then return nil end
    text = text:gsub("[%s,]", "")
    if text == "" then return nil end
    local n = tonumber(text)
    if not n or n < 0 then return nil end
    return math.min(math.floor(n), MAX_GOLD)
end

local function TargetGoldFor(key)
    if not db then return 0 end
    local o = key and db.overrides and db.overrides[key]
    if type(o) == "number" then return o end
    return db.defaultGold or 0
end

local bankOpen, ranThisBankVisit = false, false
local lastStatus  -- shown in the config panel; deliberately not saved

local function Status(text, announce)
    lastStatus = text
    if announce then Print(text) end
    Refresh()
end

-- manual = triggered by the panel's Sync Now button, which reports every outcome
-- (including "nothing to do") instead of staying quiet, and ignores the tick box.
local function Reconcile(manual)
    if not db then return end
    if not manual and not db.enabled then return end

    local bankType = AccountBankType()
    if not (C_Bank and bankType) then
        Status("Warband bank API unavailable on this client.", manual)
        return
    end
    if C_Bank.FetchBankLockedReason and C_Bank.FetchBankLockedReason(bankType) ~= nil then
        Status("The warband bank is not available on this character.", manual)
        return
    end

    local money = GetMoney()
    local banked = (C_Bank.FetchDepositedMoney and C_Bank.FetchDepositedMoney(bankType)) or 0
    if IsSecret(money) or IsSecret(banked) then return end

    local key = CharKey()
    local target = TargetGoldFor(key) * COPPER_PER_GOLD
    local delta = money - target

    if delta >= TOLERANCE then
        if not (C_Bank.CanDepositMoney and C_Bank.CanDepositMoney(bankType)) then
            Status("Cannot deposit into the warband bank right now.", manual)
            return
        end
        C_Bank.DepositMoney(bankType, delta)
        Status("Deposited " .. Coin(delta) .. " into the warband bank.", true)

    elseif delta <= -TOLERANCE then
        local want = -delta
        local amount = math.min(want, banked)
        if amount < TOLERANCE then
            Status("Warband bank is empty - nothing to withdraw.", manual)
            return
        end
        if not (C_Bank.CanWithdrawMoney and C_Bank.CanWithdrawMoney(bankType)) then
            Status("Cannot withdraw from the warband bank right now.", manual)
            return
        end
        C_Bank.WithdrawMoney(bankType, amount)
        if amount < want then
            Status("Withdrew " .. Coin(amount) .. " - all the warband bank had, still "
                .. Coin(want - amount) .. " short of target.", true)
        else
            Status("Withdrew " .. Coin(amount) .. " from the warband bank.", true)
        end

    else
        Status("Already at target (" .. Coin(target) .. ").", manual)
    end
end

-------------------------------------------------------------------------------
-- Themed widget helpers
-------------------------------------------------------------------------------

local function CreateEditBox(parent, w, h)
    local eb = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    eb:SetSize(w, h or 24)
    eb:SetAutoFocus(false)
    eb:SetFontObject(DUI_FontNormal)
    eb:SetBackdrop(DUI_EditBackdrop)
    eb:SetBackdropColor(0, 0, 0, 0.5)
    eb:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(eb, "border")
    eb:SetTextInsets(5, 5, 0, 0)
    eb:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(1, 1, 0, 1) end)
    eb:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(unpack(DUI_Theme.Accent)) end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return eb
end

local function CreateActionButton(parent, w, text, onClick)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(w, 24)
    btn:SetText(text)
    StyleAsTealTab(btn)
    btn:SetScript("OnClick", onClick)
    return btn
end

-- Scrollable themed container with a thin accent slider (mouse-wheel enabled).
local function CreateScrollBox(parent, w, h)
    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    container:SetSize(w, h)
    DUI_StyleAsListBox(container)

    local sf = CreateFrame("ScrollFrame", nil, container)
    sf:SetPoint("TOPLEFT", 6, -6)
    sf:SetPoint("BOTTOMRIGHT", -18, 6)

    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(w - 24, 1)
    sf:SetScrollChild(content)

    local sb = CreateFrame("Slider", nil, container, "BackdropTemplate")
    sb:SetPoint("TOPRIGHT", -4, -6)
    sb:SetPoint("BOTTOMRIGHT", -4, 6)
    sb:SetWidth(10)
    sb:SetBackdrop(DUI_EditBackdrop)
    sb:SetBackdropColor(0, 0, 0, 0.5)
    sb:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
    sb:GetThumbTexture():SetSize(8, 30)
    sb:GetThumbTexture():SetVertexColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(sb:GetThumbTexture(), "vertex")
    sb:SetMinMaxValues(0, 1)
    sb:SetValueStep(1)
    sb:SetObeyStepOnDrag(true)
    sb:SetScript("OnValueChanged", function(self, val) sf:SetVerticalScroll(val) end)

    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(_, delta) sb:SetValue(sb:GetValue() - delta * 20) end)

    container.sf, container.content, container.sb = sf, content, sb
    function container:SetContentHeight(hh)
        hh = math.max(hh, 1)
        content:SetHeight(hh)
        sb:SetMinMaxValues(0, math.max(0, hh - sf:GetHeight()))
    end
    return container
end

-------------------------------------------------------------------------------
-- Configuration UI
-------------------------------------------------------------------------------

-- Matches the docking pane exactly: every DUI panel is built to DUI_PANEL_W, and
-- the widgets below lay out in panel coordinates.
local PANEL_W = DUI_PANEL_W

-- The list spans the panel less the standard indent either side.
local LIST_W, LIST_H, ROW_H = PANEL_W - DUI_LAYOUT.INDENT * 2, 132, 22

local config = DUI_CreateConfigFrame("DUI_WarbankGoldConfig", "Warbank Gold", PANEL_W, DUI_PANEL_H,
    "DUI_WarbankGoldBtn")

local defaultBox, charLabel, charBox, overrideList, statusText
local overrideRows = {}

local function CommitOverride(key, box)
    local g = ParseGold(box:GetText())
    if g and key and db.overrides then db.overrides[key] = g end
    Refresh()
end

local function AcquireOverrideRow(i)
    if overrideRows[i] then return overrideRows[i] end
    local row = CreateFrame("Frame", nil, overrideList.content)
    row:SetSize(LIST_W - 24, ROW_H)

    local del = CreateFrame("Button", nil, row, "BackdropTemplate")
    del:SetSize(16, 16)
    del:SetPoint("LEFT", 0, 0)
    del:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    del:SetBackdropColor(unpack(DUI_Theme.Accent))
    del:SetBackdropBorderColor(0, 0, 0, 1)
    DUI_RegisterAccent(del, "bg")
    local delX = del:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    delX:SetPoint("CENTER"); delX:SetText("X"); delX:SetTextColor(1, 1, 1)
    del:SetScript("OnClick", function(self)
        if db.overrides then db.overrides[self:GetParent().key] = nil end
        Refresh()
    end)
    DUI_AddTooltip(del, "Remove override", "This character falls back to the account-wide default.")

    local suffix = row:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    suffix:SetPoint("RIGHT", 0, 0)
    suffix:SetText("g")
    suffix:SetTextColor(0.6, 0.6, 0.6)

    local box = CreateEditBox(row, 76, 18)
    box:SetPoint("RIGHT", suffix, "LEFT", -4, 0)
    box:HookScript("OnEnterPressed", function(self) CommitOverride(self:GetParent().key, self) end)
    box:HookScript("OnEditFocusLost", function(self) CommitOverride(self:GetParent().key, self) end)

    -- Stretched between the delete button and the amount so a long Name-Realm
    -- truncates instead of running under the edit box.
    local name = row:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    name:SetPoint("LEFT", del, "RIGHT", 6, 0)
    name:SetPoint("RIGHT", box, "LEFT", -6, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)

    row.nameText, row.box = name, box
    overrideRows[i] = row
    return row
end

-- Never overwrites a box the user is currently typing into, so a bank sync
-- landing mid-edit does not eat what they were halfway through entering.
local function SetBoxText(box, text)
    if box:HasFocus() then return end
    box:SetText(text)
end

local function BuildPanel()
    local L = DUI_CreateLayout(config)

    L:Header("Gold Sync")
    -- No enable tick in here: the module's flag is the one on its row in the main
    -- window. The status line at the bottom of the panel reports it instead, so
    -- the panel never carries a second copy of the switch to disagree with.
    L:Text("Opening the bank tops this character up to the target from the warband bank, "
        .. "or deposits whatever it holds above it. Applies to every character without an override. "
        .. "Off by default - it moves real gold with no confirmation.")

    local defRow = CreateFrame("Frame", nil, config)
    defRow:SetSize(300, 24)
    local defLabel = defRow:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
    defLabel:SetPoint("LEFT", 0, 0)
    defLabel:SetText("Keep on hand")
    defLabel:SetTextColor(1, 1, 1)
    defaultBox = CreateEditBox(defRow, 90)
    defaultBox:SetPoint("LEFT", defLabel, "RIGHT", 8, 0)
    local defSuffix = defRow:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    defSuffix:SetPoint("LEFT", defaultBox, "RIGHT", 4, 0)
    defSuffix:SetText("gold"); defSuffix:SetTextColor(0.6, 0.6, 0.6)
    local function CommitDefault(self)
        local g = ParseGold(self:GetText())
        if g then db.defaultGold = g end
        Refresh()
    end
    defaultBox:HookScript("OnEnterPressed", CommitDefault)
    defaultBox:HookScript("OnEditFocusLost", CommitDefault)
    DUI_AddTooltip(defaultBox, "Default target",
        "The amount of gold every character is left holding after a bank visit.")
    L:Place(defRow, { indent = 25, step = 32 })

    L:Header("This Character")
    charLabel = config:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    charLabel:SetWidth(PANEL_W - 50)
    charLabel:SetJustifyH("LEFT")
    charLabel:SetTextColor(0.75, 0.75, 0.75)
    L:Place(charLabel, { indent = 25, step = 22 })

    local charRow = CreateFrame("Frame", nil, config)
    charRow:SetSize(330, 24)
    charBox = CreateEditBox(charRow, 76)
    charBox:SetPoint("LEFT", 0, 0)
    local charSuffix = charRow:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    charSuffix:SetPoint("LEFT", charBox, "RIGHT", 4, 0)
    charSuffix:SetText("gold"); charSuffix:SetTextColor(0.6, 0.6, 0.6)

    local setBtn = CreateActionButton(charRow, 96, "Set Override", function()
        local key, g = CharKey(), ParseGold(charBox:GetText())
        if key and g then
            db.overrides = db.overrides or {}
            db.overrides[key] = g
        end
        Refresh()
    end)
    setBtn:SetPoint("LEFT", charSuffix, "RIGHT", 8, 0)
    DUI_AddTooltip(setBtn, "Set Override",
        "Pins this character to the amount in the box, ignoring the default.")

    local clearBtn = CreateActionButton(charRow, 90, "Use Default", function()
        local key = CharKey()
        if key and db.overrides then db.overrides[key] = nil end
        Refresh()
    end)
    clearBtn:SetPoint("LEFT", setBtn, "RIGHT", 5, 0)
    DUI_AddTooltip(clearBtn, "Use Default",
        "Drops this character's override so it follows the account-wide default again.")
    L:Place(charRow, { indent = 25, step = 34 })

    L:Header("Character Overrides")
    overrideList = CreateScrollBox(config, LIST_W, LIST_H)
    overrideList.empty = overrideList.content:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    overrideList.empty:SetPoint("TOPLEFT", 2, -4)
    overrideList.empty:SetText("No overrides - every character uses the default.")
    overrideList.empty:SetTextColor(0.5, 0.5, 0.5)
    L:Place(overrideList, { indent = 22, step = LIST_H + 6 })
    L:Text("Edit an amount and press Enter to save it, or use X to drop the override.")

    L:Gap()
    local syncBtn = CreateActionButton(config, 110, "Sync Now", function()
        if not bankOpen then
            Status("Open your bank first - gold can only move while the bank is open.", true)
            return
        end
        Reconcile(true)
    end)
    DUI_AddTooltip(syncBtn, "Sync Now",
        { body = "Reconciles this character straight away, ignoring the tick box.",
          note = "Your bank has to be open." })
    L:Place(syncBtn, { indent = 25, step = 30 })

    statusText = config:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    statusText:SetWidth(PANEL_W - 50)
    statusText:SetJustifyH("LEFT")
    statusText:SetTextColor(0.6, 0.6, 0.6)
    L:Place(statusText, { indent = 25, step = 34 })

    L:FitHeight()
end

Refresh = function()
    if not (config.init and db) then return end

    SetBoxText(defaultBox, tostring(db.defaultGold or 0))

    local key = CharKey()
    if key then
        local o = db.overrides and db.overrides[key]
        if type(o) == "number" then
            charLabel:SetText(DUI_AccentText(key) .. "  override: " .. FormatGold(o))
        else
            charLabel:SetText(DUI_AccentText(key) .. "  using the default (" .. FormatGold(db.defaultGold or 0) .. ")")
        end
        SetBoxText(charBox, tostring(TargetGoldFor(key)))
    else
        charLabel:SetText("Character unknown.")
        SetBoxText(charBox, "")
    end

    -- Sorted so the list does not shuffle between openings.
    local keys = {}
    for k, v in pairs(db.overrides or {}) do
        if type(v) == "number" then keys[#keys + 1] = k end
    end
    table.sort(keys)

    for _, row in ipairs(overrideRows) do row:Hide() end
    for i, k in ipairs(keys) do
        local row = AcquireOverrideRow(i)
        row.key = k
        row.nameText:SetText(k)
        -- The character you are on is highlighted white; the rest sit back in grey.
        local shade = (k == key) and 1 or 0.75
        row.nameText:SetTextColor(shade, shade, shade)
        SetBoxText(row.box, tostring(db.overrides[k]))
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        row:Show()
    end
    overrideList:SetContentHeight(#keys * ROW_H + 4)
    overrideList.empty:SetShown(#keys == 0)

    statusText:SetText(db.enabled
        and (lastStatus or "Waiting for you to open the bank.")
        or "Gold sync is off - tick it on this module's row in the main window.")
end

function DUI_OpenWarbankGoldConfig()
    if not db then DUI_InitWarbankGoldDB() end

    if not config.init then
        BuildPanel()
        config.init = true
    end

    Refresh()
    config:Show()
end

-- Called by the main window's enable checkbox: the switch is spelled out in the
-- status line, so flipping it from out there has to repaint the panel.
function DUI_WarbankGoldApplyEnabled()
    Refresh()
end

DUI_WarbankGoldConfig = config

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------

-- The personal bank, unlike the guild bank, still fires its own open/close events
-- on 12.1, so no frame hook is needed here. BANKFRAME_OPENED is rare enough that
-- a single always-on registration gated inside the handler is cheaper than
-- churning registration every time the tick box moves.
local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "BANKFRAME_OPENED" then
        bankOpen = true
        if ranThisBankVisit then return end
        ranThisBankVisit = true
        -- Warband bank state settles a moment after the event; re-check that the
        -- window is still open before moving anyone's gold.
        C_Timer.After(0.5, function()
            if bankOpen then Reconcile(false) end
        end)

    elseif event == "BANKFRAME_CLOSED" then
        bankOpen, ranThisBankVisit = false, false
    end
end)

function DUI_InitWarbankGold()
    DUI_InitWarbankGoldDB()
    eventFrame:RegisterEvent("BANKFRAME_OPENED")
    eventFrame:RegisterEvent("BANKFRAME_CLOSED")
end
