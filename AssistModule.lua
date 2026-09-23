-- AssistModule.lua
-- Handles the auto-assist list functionality

local db -- Local reference to DanUIDB.AssistModule

function DUI_GetAssistDefaults()
    return {
        enabled = true,
        assistList = {},
    }
end

-- Configuration UI Frame (formerly AssistTab)
local config = CreateFrame("Frame", "DUI_AssistConfig", UIParent, "BackdropTemplate")
config:SetFrameStrata("TOOLTIP")
-- Built to the docking pane's size like every factory-built panel, so it fills
-- the pane instead of sitting in the corner of it.
config:SetSize(DUI_PANEL_W, DUI_PANEL_H)
config:SetPoint("CENTER")
config:SetMovable(true); config:EnableMouse(true); config:RegisterForDrag("LeftButton")
config:SetClampedToScreen(true)
config:SetScript("OnDragStart", config.StartMoving); config:SetScript("OnDragStop", config.StopMovingOrSizing)
config:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
config:SetBackdropColor(unpack(DUI_Theme.MainBG)); config:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
DUI_RegisterAccent(config, "border")
DUI_RegisterMainBG(config, "bg")
config:Hide()

local CloseBtn = CreateFrame("Button", nil, config, "BackdropTemplate")
CloseBtn:SetSize(20, 20); CloseBtn:SetPoint("TOPRIGHT", -5, -5)
StyleAsCloseButton(CloseBtn)
CloseBtn:SetScript("OnClick", function() config:Hide() end)
config.closeBtn = CloseBtn -- hidden by the launcher while this panel is docked

tinsert(UISpecialFrames, "DUI_AssistConfig")

config:HookScript("OnShow", function(self)
    -- OnShow is queued, not run inside Show(), so this lands after the launcher
    -- has already parented and positioned the panel in its docking pane. The
    -- hand-rolled anchor that used to stand here ignored that and dragged the
    -- panel back out beside the window; DUI_RestoreConfigPosition is the same
    -- default spot, but it leaves the docked panel alone. Same reason for the
    -- IsShown check: the launcher's index warm-up shows and hides every panel in
    -- one frame, and this hook still runs afterwards.
    if not self:IsShown() then return end
    DUI_RestoreConfigPosition(self)
    if DUI_AssistBtn_Tools then DUI_AssistBtn_Tools:SetBackdropBorderColor(unpack(DUI_Theme.Accent)) end
    DUI_RefreshAssistList()
end)
config:HookScript("OnHide", function(self)
    if DUI_AssistBtn_Tools then DUI_AssistBtn_Tools:SetBackdropBorderColor(0, 0, 0, 1) end
    if DUI_HideScrollDropdown then DUI_HideScrollDropdown() end
end)

config.title = config:CreateFontString(nil, "OVERLAY", "DUI_FontLarge")
config.title:SetPoint("TOP", 0, -10); config.title:SetText("Auto-Assist List")
-- This panel is hand-rolled (not built by DUI_CreateConfigFrame), so add the shared
-- title-bar chrome and drop shadow explicitly to match the factory-built panels.
DUI_AddTitleChrome(config)
DUI_AddDropShadow(config)

-- Hand-rolled panel, but the same layout cursor every factory-built one uses, so
-- it gets the standard header rhythm and a section card behind the entry row.
local L = DUI_CreateLayout(config)

L:Header("Add a name")

local InputBox = CreateFrame("EditBox", "DUI_AssistInputBox", config, "BackdropTemplate")
-- Fills the row, leaving room for the Add button anchored to its right.
InputBox:SetSize(config:GetWidth() - DUI_LAYOUT.INDENT - 20 - 91, 30)
InputBox:SetPoint("TOPLEFT", DUI_LAYOUT.INDENT, L:Y()); InputBox:SetAutoFocus(false)
InputBox:SetFontObject(DUI_FontNormal); InputBox:SetBackdrop(DUI_EditBackdrop)
InputBox:SetBackdropColor(0, 0, 0, 0.5); InputBox:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
DUI_RegisterAccent(InputBox, "border")
InputBox:SetTextInsets(5, 5, 0, 0)
InputBox:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(1, 1, 0, 1) end)
InputBox:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(unpack(DUI_Theme.Accent)) end)
InputBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end); InputBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local AddBtn = CreateFrame("Button", nil, config, "BackdropTemplate")
AddBtn:SetSize(80, 25); AddBtn:SetText("Add"); AddBtn:SetPoint("LEFT", InputBox, "RIGHT", 6, 0)
StyleAsTealTab(AddBtn)
L:Advance(38)

-- No card: the list draws its own border and runs to the bottom of the panel, so a
-- card would wrap the header and nothing else.
L:Header("Promoted on join", { card = false })

local ListBox = CreateFrame("Frame", nil, config, "BackdropTemplate")
-- Takes everything between the input row and the button at the bottom, rather
-- than a fixed 270x160 box with empty panel around it. Its left and right edges
-- are the section card's, so the list lines up with the block above it.
ListBox:SetPoint("TOPLEFT", 16, L:Y()); ListBox:SetPoint("BOTTOMRIGHT", -12, 52)
DUI_StyleAsListBox(ListBox)

local ListContainer = CreateFrame("Frame", nil, ListBox)
ListContainer:SetAllPoints()

local rows = {}
local function CreateRow(i)
    local row = CreateFrame("Frame", nil, ListContainer)
    -- Width comes from the two anchors set in DUI_RefreshAssistList, so a row
    -- spans the list however wide the list is.
    row:SetHeight(20)
    local delBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
    delBtn:SetSize(16, 16); delBtn:SetPoint("LEFT", 0, 0)
    delBtn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    delBtn:SetBackdropColor(unpack(DUI_Theme.Accent)); delBtn:SetBackdropBorderColor(0, 0, 0, 1)
    DUI_RegisterAccent(delBtn, "bg")
    local delX = delBtn:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    delX:SetPoint("CENTER"); delX:SetText("X"); delX:SetTextColor(1, 1, 1)
    local text = row:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    text:SetPoint("LEFT", delBtn, "RIGHT", 5, 0)
    return { frame = row, delBtn = delBtn, text = text }
end

function DUI_RefreshAssistList()
    for _, row in ipairs(rows) do row.frame:Hide() end
    local count, offset = 0, -5
    if db and db.assistList then
        for name in pairs(db.assistList) do
            count = count + 1
            if not rows[count] then rows[count] = CreateRow(count) end
            local row = rows[count]
            row.frame:ClearAllPoints()
            row.frame:SetPoint("TOPLEFT", 10, offset)
            row.frame:SetPoint("TOPRIGHT", -10, offset)
            row.text:SetText(name)
            row.delBtn:SetScript("OnClick", function() db.assistList[name] = nil; DUI_RefreshAssistList() end)
            row.frame:Show()
            offset = offset - 20
        end
    end
end

AddBtn:SetScript("OnClick", function()
    local name = InputBox:GetText()
    if name and name ~= "" then
        name = name:gsub("^%l", string.upper)
        db.assistList[name] = true
        InputBox:SetText(""); InputBox:ClearFocus(); DUI_RefreshAssistList()
    end
end)

local ForcePromoteBtn = CreateFrame("Button", nil, config, "BackdropTemplate")
ForcePromoteBtn:SetSize(160, 25); ForcePromoteBtn:SetPoint("BOTTOM", config, "BOTTOM", 0, 14)
ForcePromoteBtn:SetText("Force Promote Check")
StyleAsTealTab(ForcePromoteBtn)
ForcePromoteBtn:SetScript("OnClick", function()
    if DUI_ProcessRosterPromotions then
        DUI_ProcessRosterPromotions()
        print("|cFF00FF00[DUI]|r Manual promotion check initiated.")
    end
end)

function DUI_InitAssistModule()
    if not DanUIDB.AssistModule then DanUIDB.AssistModule = DUI_GetAssistDefaults() end
    db = DanUIDB.AssistModule
end

function DUI_OpenAssistConfig()
    if not DanUIDB.AssistModule then DanUIDB.AssistModule = DUI_GetAssistDefaults() end
    db = DanUIDB.AssistModule
    config:Show()
end