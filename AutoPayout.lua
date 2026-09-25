-- AutoPayout.lua
-------------------------------------------------------------------------------
-- Auto Payout module for Dan UI.
--
-- Reskin of Oppzippy's "Auto Payout" (MIT). The payout engine lives in
-- AutoPayoutLogic.lua; this file provides the DUI-themed UI (Setup / Progress /
-- History / Settings tabs) and the orchestration that used to live in Core.lua.
-------------------------------------------------------------------------------

---@class addon
local addon = select(2, ...)

local M = {}                 -- module state
local db                     -- DanUIDB.AutoPayout

-- Working UI values for the Setup tab
local setupSubject, setupPaste, setupUnit

-------------------------------------------------------------------------------
-- Defaults / DB
-------------------------------------------------------------------------------
function DUI_GetAutoPayoutDefaults()
    return {
        enabled = true,
        defaultSubject = "Payout",
        defaultUnit = COPPER_PER_GOLD,
        debug = false,
        history = {},
        maxHistorySize = 20,
        maxPayoutSizeInGold = 1000000,
        maxPayoutSplits = 9,
        autoShow = false,
    }
end

local function EnsureDB()
    if not DanUIDB then DanUIDB = {} end
    if not DanUIDB.AutoPayout then DanUIDB.AutoPayout = DUI_GetAutoPayoutDefaults() end
    db = DanUIDB.AutoPayout
    for k, v in pairs(DUI_GetAutoPayoutDefaults()) do
        if db[k] == nil then db[k] = v end
    end
    db.history = db.history or {}
end

-------------------------------------------------------------------------------
-- Unit helpers
-------------------------------------------------------------------------------
local function UnitItems()
    return {
        { value = COPPER_PER_GOLD * 1000, text = C_CurrencyInfo.GetCoinTextureString(COPPER_PER_GOLD * 1000) },
        { value = COPPER_PER_GOLD,        text = C_CurrencyInfo.GetCoinTextureString(COPPER_PER_GOLD) },
        { value = COPPER_PER_SILVER,      text = C_CurrencyInfo.GetCoinTextureString(COPPER_PER_SILVER) },
        { value = 1,                      text = C_CurrencyInfo.GetCoinTextureString(1) },
    }
end

-------------------------------------------------------------------------------
-- Themed widget helpers
-------------------------------------------------------------------------------
-- Scrollable themed container with a thin accent slider (mouse-wheel enabled).
local function CreateScrollBox(parent, x, y, w, h)
    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    container:SetSize(w, h)
    container:SetPoint("TOPLEFT", x, y)
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

-- Themed multi-line edit box. readonly boxes revert edits so text stays copyable.
local function CreateMultiLineEdit(parent, x, y, w, h, readonly)
    local box = CreateScrollBox(parent, x, y, w, h)
    local eb = CreateFrame("EditBox", nil, box.content)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject(DUI_FontNormal)
    eb:SetWidth(w - 24)
    eb:SetPoint("TOPLEFT")
    eb:SetTextInsets(2, 2, 2, 2)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnTextChanged", function(self)
        if readonly and self:GetText() ~= (box.readonlyText or "") then
            self:SetText(box.readonlyText or "")
        end
        box:SetContentHeight(self:GetHeight())
    end)
    box.editBox = eb
    function box:SetReadonlyText(text)
        self.readonlyText = text or ""
        eb:SetText(self.readonlyText)
    end
    return box
end

-- Themed dropdown button that opens the shared DUI scroll dropdown.
-- Wraps the shared dropdown control so this panel's menus match the rest of the
-- suite (caret, hover accent) instead of looking like a bare edit box. `.text` is
-- kept as an alias so the existing call sites that assign to it keep working.
local function CreateDropdownButton(parent, x, y, w, tooltip)
    local btn = DUI_CreateDropdown(parent, nil, { width = w, height = 26, justify = "LEFT", tooltip = tooltip })
    btn:SetPoint("TOPLEFT", x, y)
    btn.text = btn.value
    return btn
end

-- Themed single-line edit box.
local function CreateEditBox(parent, x, y, w)
    local eb = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    eb:SetSize(w, 25)
    eb:SetPoint("TOPLEFT", x, y)
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

-- The caption over each box on the Setup / Progress tabs. These name a section of
-- the panel, which everywhere else in DanUI means an accent header -- as plain
-- white text they were the last thing making this tab read like a different addon
-- bolted on. Registered for recolour and indexed for the launcher search, both of
-- which come free from the shared constructor.
local function CreateLabel(parent, x, y, text)
    local h = DUI_CreateHeader(parent, text, y)
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", x, y)
    return h
end

-- A field's own name, sitting next to its control rather than over a section.
-- White, so it reads as a label and not as another header.
local function CreateFieldLabel(parent, x, y, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    fs:SetTextColor(1, 1, 1)
    return fs
end

local function CreateActionButton(parent, x, y, w, text, onClick)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(w, 25)
    btn:SetPoint("TOPLEFT", x, y)
    btn:SetText(text)
    StyleAsTealTab(btn)
    btn:SetScript("OnClick", onClick)
    return btn
end

-------------------------------------------------------------------------------
-- Orchestration (ported from Core.lua)
-------------------------------------------------------------------------------
local function ResetState()
    if M.payoutExecutor then
        M.payoutExecutor:Destroy()
        M.payoutExecutor = nil
    end
    M.payoutQueue = nil
end

local function SplitPayments(payments)
    local splitter = addon.PayoutSplitterPrototype.Create(
        db.maxPayoutSizeInGold * COPPER_PER_GOLD,
        db.maxPayoutSplits
    )
    return splitter:SplitPayments(payments)
end

-- Parse the paste box into payments, scaling copper by the selected unit.
local function GetPayments()
    local csv = addon.PayoutQueuePrototype.ParseCSV(setupPaste)
    local unit = setupUnit or db.defaultUnit
    local payments = {}
    for i, payment in ipairs(csv) do
        payments[i] = {
            player = payment.player,
            copper = payment.copper * unit,
        }
    end
    return payments
end

-- Build the CSV of payouts that have not yet been sent (unit-scaled back down).
local function GetUnpaidCSV()
    if not M.payoutQueue then return "" end
    local unit = M.payoutUnit or db.defaultUnit
    local t = {}
    for payout in M.payoutQueue:IteratePayouts() do
        if not payout.isPaid then
            t[#t + 1] = { payout.player, payout.copper / unit }
        end
    end
    return addon.CSV.ToCSV(t)
end

local function WipeOldHistory()
    for i = db.maxHistorySize + 1, #db.history do
        db.history[i] = nil
    end
end

-------------------------------------------------------------------------------
-- Config frame
-------------------------------------------------------------------------------
-- Standard DUI chrome (backdrop, close button, title bar, drop shadow, main-window
-- anchoring, button highlight, Esc-to-close, accent + config-registry membership).
local config = DUI_CreateConfigFrame("DUI_AutoPayoutConfig", "Auto Payout", 560, 500, "DUI_AutoPayoutBtn_Tools")

local statusText = config:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
statusText:SetPoint("BOTTOMLEFT", 16, 12)
statusText:SetPoint("BOTTOMRIGHT", -16, 12)
statusText:SetJustifyH("LEFT")
statusText:SetTextColor(unpack(DUI_Theme.Accent))
DUI_RegisterAccent(statusText, "text")
local function SetStatus(text) statusText:SetText(text or "") end

-- Inner tab content frames
local setupTab = CreateFrame("Frame", nil, config); setupTab:SetPoint("TOPLEFT", 0, -70); setupTab:SetPoint("BOTTOMRIGHT", 0, 30); setupTab:Hide()
local progressTab = CreateFrame("Frame", nil, config); progressTab:SetPoint("TOPLEFT", 0, -70); progressTab:SetPoint("BOTTOMRIGHT", 0, 30); progressTab:Hide()
local historyTab = CreateFrame("Frame", nil, config); historyTab:SetPoint("TOPLEFT", 0, -70); historyTab:SetPoint("BOTTOMRIGHT", 0, 30); historyTab:Hide()
local settingsTab = CreateFrame("Frame", nil, config); settingsTab:SetPoint("TOPLEFT", 0, -70); settingsTab:SetPoint("BOTTOMRIGHT", 0, 30); settingsTab:Hide()

local innerTabs = {}
-- Only the open tab wears the accent, so this cannot be a plain "border" accent
-- registration -- it is registered as "fn" below and re-run on an accent change.
local function PaintInnerTabs(name)
    for tabName, btn in pairs(innerTabs) do
        btn:SetBackdropBorderColor(tabName == name and DUI_Theme.Accent[1] or 0,
            tabName == name and DUI_Theme.Accent[2] or 0,
            tabName == name and DUI_Theme.Accent[3] or 0, 1)
    end
end
DUI_RegisterAccent(config, "fn", function() PaintInnerTabs(M.currentTab) end)

local function SelectInnerTab(name)
    setupTab:Hide(); progressTab:Hide(); historyTab:Hide(); settingsTab:Hide()
    PaintInnerTabs(name)
    M.currentTab = name
    SetStatus("")
    if name == "setup" then setupTab:Show()
    elseif name == "progress" then progressTab:Show(); M.RenderProgress()
    elseif name == "history" then historyTab:Show(); M.RenderHistory()
    elseif name == "settings" then settingsTab:Show() end
end

local function CreateInnerTab(name, label, x)
    local btn = CreateFrame("Button", nil, config, "BackdropTemplate")
    btn:SetSize(120, 24)
    btn:SetPoint("TOPLEFT", x, -40)
    btn:SetText(label)
    StyleAsTealTab(btn)
    btn:SetScript("OnClick", function() SelectInnerTab(name) end)
    innerTabs[name] = btn
    return btn
end
CreateInnerTab("setup", "Setup", 16)
CreateInnerTab("progress", "Progress", 140)
CreateInnerTab("history", "History", 264)
CreateInnerTab("settings", "Settings", 388)

-------------------------------------------------------------------------------
-- Setup tab
-------------------------------------------------------------------------------
local nextButton, subjectBox, pasteBox, unitButton

local function ValidateSetup()
    local ok, result = pcall(function() return addon.PayoutQueuePrototype.ParseCSV(setupPaste) end)
    if ok then
        local valid = #result > 0
        nextButton:SetEnabled(valid)
        nextButton:SetAlpha(valid and 1 or 0.4)
        SetStatus("")
    else
        nextButton:SetEnabled(false)
        nextButton:SetAlpha(0.4)
        SetStatus(type(result) == "table" and result.message or tostring(result))
    end
end

do
    CreateLabel(setupTab, 16, -6, "Subject")
    subjectBox = CreateEditBox(setupTab, 16, -26, 300)
    subjectBox:SetScript("OnEnterPressed", function(self)
        local text = self:GetText()
        if #text == 0 then
            setupSubject = nil
            self:SetText(db.defaultSubject)
        else
            setupSubject = text
        end
        self:ClearFocus()
    end)

    CreateLabel(setupTab, 16, -60, "Payout CSV  (player,amount per line)")
    pasteBox = CreateMultiLineEdit(setupTab, 16, -80, 532, 300, false)
    pasteBox.editBox:SetScript("OnTextChanged", function(self)
        setupPaste = self:GetText()
        pasteBox:SetContentHeight(self:GetHeight())
        ValidateSetup()
    end)

    CreateLabel(setupTab, 16, -392, "Unit")
    unitButton = CreateDropdownButton(setupTab, 60, -388, 150,
        "Denomination the amounts in the pasted CSV are expressed in.")
    unitButton:SetScript("OnClick", function(self)
        DUI_ShowScrollDropdown(self, UnitItems(), function(value, text)
            setupUnit = value
            self.text:SetText(text)
        end, setupUnit or db.defaultUnit)
    end)

    nextButton = CreateActionButton(setupTab, 230, -388, 120, "Next", function()
        M.OnNext()
    end)
end

-------------------------------------------------------------------------------
-- Progress tab
-------------------------------------------------------------------------------
local startButton, doneButton, progressList, unsentBox
local DEFAULT_IMAGE = "Interface\\RAIDFRAME\\ReadyCheck-Waiting"
local PAID_IMAGE    = "Interface\\RAIDFRAME\\ReadyCheck-Ready"
local UNPAID_IMAGE  = "Interface\\RAIDFRAME\\ReadyCheck-NotReady"

do
    startButton = CreateActionButton(progressTab, 16, -6, 255, "Start", function()
        M.OnStartStop()
    end)
    doneButton = CreateActionButton(progressTab, 289, -6, 255, "Done", function()
        M.OnDone()
    end)

    CreateLabel(progressTab, 16, -40, "Payouts")
    progressList = CreateScrollBox(progressTab, 16, -60, 532, 298)
    progressList.rows = {}

    CreateLabel(progressTab, 16, -366, "Unsent Mail")
    unsentBox = CreateMultiLineEdit(progressTab, 16, -386, 532, 90, true)
end

function M.SetStartButtonState(isRunning)
    M.isPayoutInProgress = isRunning
    startButton:SetText(isRunning and "Pause" or "Start")
    SetStatus(isRunning and "Payout in progress. Please keep the mailbox open." or "")
end

function M.UpdateUnsentCSV()
    M.unsentCSV = GetUnpaidCSV()
    if unsentBox then unsentBox:SetReadonlyText(M.unsentCSV) end
    if db.history[1] then db.history[1].output = M.unsentCSV end
end

function M.RenderProgress()
    for _, row in ipairs(progressList.rows) do row:Hide() end
    if not M.payoutQueue then
        progressList:SetContentHeight(1)
        M.UpdateUnsentCSV()
        return
    end
    local i = 0
    for payout in M.payoutQueue:IteratePayouts() do
        i = i + 1
        local row = progressList.rows[i]
        if not row then
            row = CreateFrame("Frame", nil, progressList.content)
            row:SetSize(500, 22)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(16, 16)
            row.icon:SetPoint("LEFT", 2, 0)
            row.label = row:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
            row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
            row.label:SetTextColor(1, 1, 1)
            progressList.rows[i] = row
        end
        row:SetPoint("TOPLEFT", 0, -((i - 1) * 22))
        row:SetWidth(progressList.content:GetWidth())
        if type(payout.isPaid) == "boolean" then
            row.icon:SetTexture(payout.isPaid and PAID_IMAGE or UNPAID_IMAGE)
        else
            row.icon:SetTexture(DEFAULT_IMAGE)
        end
        row.label:SetText(string.format("%s  -  %s", payout.player, C_CurrencyInfo.GetCoinTextureString(payout.copper)))
        row:Show()
    end
    progressList:SetContentHeight(i * 22)
    M.UpdateUnsentCSV()
end

function M.OnStartStop()
    if not M.isPayoutInProgress then
        if MailFrame and MailFrame:IsVisible() then
            M.SetStartButtonState(true)
            M.StartPayout()
        else
            print("|cff77DD77DUI_AutoPayout:|r You must be at a mailbox to start the payout.")
        end
    else
        M.SetStartButtonState(false)
        M.StopPayout()
    end
end

function M.StartPayout()
    if M.doneTicker then return end -- don't restart while stopping
    if not M.payoutQueue then return end
    -- The module's checkbox on the launcher rail. Sending gold is the one thing
    -- this module actually does, so switching it off has to stop exactly this.
    if db and db.enabled == false then
        print("|cFF00FF00[DUI]|r AutoPayout is switched off in the module list.")
        return
    end
    if not M.payoutExecutor then
        M.payoutExecutor = addon.PayoutExecutorPrototype.Create(M.payoutQueue)
        M.payoutExecutor.onMailSent = function(payout)
            M.RenderProgress()
            M.UpdateUnsentCSV()
        end
        M.payoutExecutor.onMailFailed = function(payout)
            M.RenderProgress()
        end
        M.payoutExecutor.onStopPayout = function()
            M.SetStartButtonState(false)
            M.UpdateUnsentCSV()
        end
    end
    M.payoutExecutor:Start()
end

function M.StopPayout()
    if M.payoutExecutor then M.payoutExecutor:Stop() end
end

-- Apply hook for the main window's rail. Start already refuses while the row is off;
-- this pauses a payout that was mid-send when it was unticked. A pause, not a reset:
-- the queue and progress stay, so ticking it back on and pressing Start resumes.
function DUI_AutoPayoutApplyEnabled(enabled)
    if not enabled and M.isPayoutInProgress then M.StopPayout() end
end

function M.OnDone()
    if M.payoutExecutor then M.payoutExecutor:Halt() end
    -- Flush any pending mail into history before resetting.
    if not M.doneTicker then
        M.doneTicker = C_Timer.NewTicker(0, function()
            if not C_Mail.IsCommandPending() then
                if db.history[1] then db.history[1].output = GetUnpaidCSV() end
                ResetState()
                M.doneTicker:Cancel()
                M.doneTicker = nil
                if config:IsShown() then SelectInnerTab("setup") end
            end
        end)
    end
end

-------------------------------------------------------------------------------
-- Setup -> Progress transition
-------------------------------------------------------------------------------
function M.OnNext()
    local ok, err = pcall(function()
        local payments = SplitPayments(GetPayments())
        M.payoutQueue = addon.PayoutQueuePrototype.Create(payments, setupSubject or db.defaultSubject)
    end)
    if not ok then
        print("|cff77DD77DUI_AutoPayout:|r Error parsing payments: " .. tostring(type(err) == "table" and err.message or err))
        return
    end
    M.payoutUnit = setupUnit or db.defaultUnit

    -- Save a history record (input == output until mails are sent).
    local csv = setupPaste or ""
    WipeOldHistory()
    table.insert(db.history, 1, {
        timestamp = GetServerTime(),
        unit = M.payoutUnit,
        sender = { name = UnitName("player"), realm = GetRealmName() },
        input = csv,
        output = csv,
    })

    M.SetStartButtonState(false)
    SelectInnerTab("progress")
end

-------------------------------------------------------------------------------
-- History tab
-------------------------------------------------------------------------------
local historyList
do
    historyList = CreateScrollBox(historyTab, 16, -6, 528, 462)
    historyList.records = {}
end

function M.RenderHistory()
    for _, rec in ipairs(historyList.records) do rec:Hide() end
    local y = 0
    for i, record in ipairs(db.history) do
        local rec = historyList.records[i]
        if not rec then
            rec = CreateFrame("Frame", nil, historyList.content, "BackdropTemplate")
            rec:SetBackdrop(DUI_EditBackdrop)
            rec:SetBackdropColor(0, 0, 0, 0.3)
            rec:SetBackdropBorderColor(unpack(DUI_Theme.Secondary))
            DUI_RegisterSecondary(rec, "border")
            rec.title = rec:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
            rec.title:SetPoint("TOPLEFT", 8, -6)
            rec.title:SetTextColor(unpack(DUI_Theme.Accent))
            DUI_RegisterAccent(rec.title, "text")
            rec.info = rec:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
            rec.info:SetPoint("TOPLEFT", 8, -26)
            rec.info:SetPoint("RIGHT", -8, 0)
            rec.info:SetJustifyH("LEFT")
            rec.info:SetJustifyV("TOP")
            historyList.records[i] = rec
        end
        rec:SetWidth(historyList.content:GetWidth())
        rec.title:SetText(date("%Y-%m-%d %I:%M%p", record.timestamp))
        local output = record.output or ""
        local lineCount = 1
        for _ in output:gmatch("[^\r\n]+") do lineCount = lineCount + 1 end
        rec.info:SetText(string.format("Unit: %s\n%s",
            C_CurrencyInfo.GetCoinTextureString(record.unit or COPPER_PER_GOLD),
            output ~= "" and ("Remaining:\n" .. output) or "All sent."))
        local recHeight = 40 + (lineCount * 12)
        rec:SetHeight(recHeight)
        rec:SetPoint("TOPLEFT", 0, -y)
        rec:Show()
        y = y + recHeight + 8
    end
    historyList:SetContentHeight(y)
end

-------------------------------------------------------------------------------
-- Settings tab
-------------------------------------------------------------------------------
local settingsUnitButton
-- DUI_CreateCheckbox/DUI_CreateSlider write into dbTable[key] internally, but our
-- real DB (db) isn't populated until ADDON_LOADED. Give them a throwaway table and
-- persist the real value in the onUpdate callback (which only fires post-init).
local settingsScratch = {}
do
    -- The one tab that is a plain settings list, so it is built by the layout
    -- cursor and gets the same headers and section cards as every other module's
    -- panel. The tab frames are pinned to their config's corners and have no size
    -- of their own at file scope, hence the explicit width.
    local L = DUI_CreateLayout(settingsTab, 6, config:GetWidth())

    L:Header("Defaults")
    settingsTab.autoShow = L:Checkbox("Automatically show when opening mailbox",
        settingsScratch, "autoShow", function(checked) db.autoShow = checked end,
        "Opens Auto Payout by itself whenever you open a mailbox.")

    CreateFieldLabel(settingsTab, DUI_LAYOUT.INDENT, L:Y(), "Default Subject")
    L:Advance(20)
    local defSubject = CreateEditBox(settingsTab, DUI_LAYOUT.INDENT, L:Y(), 300)
    defSubject:SetScript("OnEnterPressed", function(self)
        db.defaultSubject = self:GetText()
        self:ClearFocus()
    end)
    settingsTab.defSubject = defSubject
    L:Advance(31)

    -- The dropdown is 26px tall against the label's 14, so the label starts a few
    -- pixels lower to sit on the control's centre line.
    CreateFieldLabel(settingsTab, DUI_LAYOUT.INDENT, L:Y() - 6, "Default Unit")
    settingsUnitButton = CreateDropdownButton(settingsTab, DUI_LAYOUT.INDENT + 110, L:Y(), 150,
        "Denomination new payouts start on. The Setup tab can still override it per payout.")
    settingsUnitButton:SetScript("OnClick", function(self)
        DUI_ShowScrollDropdown(self, UnitItems(), function(value, text)
            db.defaultUnit = value
            self.text:SetText(text)
        end, db.defaultUnit)
    end)
    L:Advance(32)

    L:Header("Limits")
    L:Slider("DUI_AutoPayoutMaxHistory", "Maximum History Size", 0, 100, 1,
        settingsScratch, "maxHistorySize", function(value)
            db.maxHistorySize = math.floor(value + 0.5)
        end, { tooltip = "How many completed payouts are kept on the History tab. 0 keeps none." })

    L:Slider("DUI_AutoPayoutMaxSize", "Maximum Payout Size", 1000, 9999999, 1000,
        settingsScratch, "maxPayoutSizeInGold", function(value)
            db.maxPayoutSizeInGold = math.floor(value + 0.5)
        end, { fmt = function(v) return BreakUpLargeNumbers(math.floor(v + 0.5)) .. "g" end,
               tooltip = { body = "Safety cap. A payout totalling more than this is refused.",
                           note = "Guards against a mistyped amount in the pasted CSV." } })

    L:Slider("DUI_AutoPayoutMaxSplits", "Maximum Payout Splits", 0, 20, 1,
        settingsScratch, "maxPayoutSplits", function(value)
            db.maxPayoutSplits = math.floor(value + 0.5)
        end, { tooltip = "Largest number of separate mails one recipient's payment may be broken into." })
end

-- Push saved values into settings widgets.
local function RefreshSettingsWidgets()
    settingsTab.autoShow:SetChecked(db.autoShow)
    settingsTab.defSubject:SetText(db.defaultSubject or "")
    settingsUnitButton.text:SetText(C_CurrencyInfo.GetCoinTextureString(db.defaultUnit or COPPER_PER_GOLD))
    _G["DUI_AutoPayoutMaxHistory"]:SetValue(db.maxHistorySize)
    _G["DUI_AutoPayoutMaxSize"]:SetValue(db.maxPayoutSizeInGold)
    _G["DUI_AutoPayoutMaxSplits"]:SetValue(db.maxPayoutSplits)
end

-------------------------------------------------------------------------------
-- Open / init
-------------------------------------------------------------------------------
local function RefreshSetupWidgets()
    subjectBox:SetText(setupSubject or db.defaultSubject or "")
    if setupPaste then pasteBox.editBox:SetText(setupPaste) end
    unitButton.text:SetText(C_CurrencyInfo.GetCoinTextureString(setupUnit or db.defaultUnit or COPPER_PER_GOLD))
    ValidateSetup()
end

function DUI_OpenAutoPayoutConfig()
    EnsureDB()
    RefreshSettingsWidgets()
    RefreshSetupWidgets()
    config:Show()
    -- Land on Progress if a payout is mid-flight, otherwise Setup.
    SelectInnerTab(M.payoutQueue and "progress" or "setup")
end

function DUI_InitAutoPayout()
    EnsureDB()
    setupUnit = db.defaultUnit

    -- Guard: if the player sends an unrelated mail mid-payout, drop the executor.
    hooksecurefunc("SendMail", function(recipient, subject, body)
        if M.payoutExecutor then
            local nextMail = M.payoutExecutor:GetNextMail()
            if not nextMail or recipient ~= nextMail.player or subject ~= nextMail.subject or body ~= "" then
                M.payoutExecutor:Destroy()
                M.payoutExecutor = nil
            end
        end
    end)

    local mailFrame = CreateFrame("Frame")
    mailFrame:RegisterEvent("MAIL_SHOW")
    mailFrame:SetScript("OnEvent", function()
        if db.enabled ~= false and db.autoShow and not config:IsShown() then
            DUI_OpenAutoPayoutConfig()
        end
    end)
end

SLASH_DUIPAYOUT1 = "/duipayout"
SlashCmdList["DUIPAYOUT"] = function()
    if config:IsShown() then config:Hide() else DUI_OpenAutoPayoutConfig() end
end
