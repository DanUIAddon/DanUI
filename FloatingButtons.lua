-- FloatingButtons.lua
-- Handles the Pull, Ready Check, Inspect and Break floating bar

local barBackdrop = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8", 
    tile = true, tileSize = 16, edgeSize = 1,
    insets = { left = 0, right = 0, top = 0, bottom = 0 }
}

local boxBackdrop = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    tile = true, tileSize = 16, edgeSize = 1,
    insets = { left = 0, right = 0, top = 0, bottom = 0 }
}

-- Uniform metrics for the action buttons. A ragged column of mismatched widths
-- was the main thing that made the bar look thrown together.
local BTN_W, BTN_H, BTN_GAP = 44, 20, 2
local BTN_BODY = {0.16, 0.16, 0.16, 0.92}
local CANCEL_W = 20

-- Config row, kept proportional to the action buttons.
local SMALL_W, SMALL_H, SMALL_GAP = 16, 14, 2
local SMALL_COUNT = 3 -- orientation / strata / text size

-- Padding inside the bar, and the breathing room above the bottom row.
local PAD, FOOTER_GAP = 6, 10

-- Labels are abbreviated to keep the bar narrow, so each button says what it is
-- on hover. detail may be a string or a function returning one.
local function AddTooltip(btn, title, detail)
    btn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title)
        local text = (type(detail) == "function") and detail() or detail
        if text then GameTooltip:AddLine(text, 0.8, 0.8, 0.8, true) end
        GameTooltip:Show()
    end)
    btn:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Style an action button in the DanUI house style: a dark neutral body, with the
-- accent showing up only as the hover glow and the press darken that
-- StyleAsTealTab provides. All of the buttons are identical, by preference.
local function StyleActionButton(btn)
    StyleAsTealTab(btn)
    btn:SetNormalFontObject(DUI_FontSmall)
    btn:SetHighlightFontObject(DUI_FontSmall)
    btn:SetPushedTextOffset(0, 0)
    -- The fixed dark body below is the point of this style, so keep the theme's
    -- button color off it -- StyleAsTealTab registers every button it touches.
    DUI_ExemptSecondary(btn)
    btn:SetBackdropColor(unpack(BTN_BODY))
    btn:SetBackdropBorderColor(0, 0, 0, 0.6)

    local fs = btn:GetFontString()
    if fs then
        fs:SetTextColor(0.95, 0.95, 0.95)
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetShadowOffset(1, -1)
    end
end

local FloatingBar, PullBtn, CancelBtn, RCBtn, InspectBtn, BreakBtn, StrataBtn, TextBtn, OrientBtn
local footerButtons = {} -- config row, shown only while the bar is unlocked

-- The action buttons, in the order they run along the bar. Each one can be
-- switched off from the Floating Buttons panel, so nothing below may assume a
-- fixed count: the bar is sized and anchored from whatever is left.
local BUTTON_DEFS = {
    { key = "pull",       dbKey = "floatingShowPull",       label = "Pull" },
    { key = "readyCheck", dbKey = "floatingShowReadyCheck", label = "Ready Check" },
    { key = "inspect",    dbKey = "floatingShowInspect",    label = "Inspect" },
    { key = "break",      dbKey = "floatingShowBreak",      label = "Break" },
}

local defsByKey = {}
for _, def in ipairs(BUTTON_DEFS) do defsByKey[def.key] = def end

-- The config panel over in RaidToolsModule.lua builds its tick list from this, so
-- the labels and DB keys are written once, here, beside the buttons they name.
-- That file loads first, but only reads this when the panel is opened.
DUI_FloatingButtonDefs = BUTTON_DEFS

-- A missing flag counts as shown: that is what every bar looked like before the
-- toggles existed, and it is what DUI_GetRaidToolsDefaults seeds.
local function IsButtonEnabled(def)
    local rt = DanUIDB and DanUIDB.RaidTools
    return not rt or rt[def.dbKey] ~= false
end

-- The buttons actually on the bar, in bar order.
local function EnabledDefs()
    local list = {}
    for _, def in ipairs(BUTTON_DEFS) do
        if IsButtonEnabled(def) then list[#list + 1] = def end
    end
    return list
end

-- Cancel-button lifetime.
--
-- BigWigs sends BigWigs_StopPull only when a pull is *cancelled*: an explicit
-- /pull 0, or combat cutting the countdown short. A pull that simply runs down to
-- zero sends nothing at all -- BigWigs_Plugins/Pull.lua, printPull(): at
-- timeLeft == 0 it cancels its own repeating timer and plays the end sound, and
-- that is the whole branch. So a button shown on StartPull and hidden only on
-- StopPull sticks on screen after every pull that was allowed to finish, which is
-- most of them. Reaching zero on our own clock is the only expiry signal there is
-- -- the same hole BreakTimer.lua works around for /break.
local pullHideTimer

-- The countdown length comes back as a secret value inside M+ and encounters, where
-- it cannot be read. The pull is still running, so hold the button for the longest
-- countdown BigWigs will send rather than assuming there is nothing to cancel.
local MAX_PULL = 60

-- Dispatch skew, so the X never vanishes while the countdown still reads 1.
local PULL_GRACE = 0.5

local function IsSecret(v)
    return issecretvalue and issecretvalue(v)
end

local function HideCancel()
    if pullHideTimer then
        pullHideTimer:Cancel()
        pullHideTimer = nil
    end
    if CancelBtn then CancelBtn:Hide() end
end

local function ShowCancel(seconds)
    -- Nothing to cancel from a bar the Pull button has been taken off.
    if not CancelBtn or not IsButtonEnabled(defsByKey.pull) then return end
    HideCancel() -- a second pull replaces the first one's expiry timer
    CancelBtn:Show()
    local duration = (not IsSecret(seconds)) and tonumber(seconds) or nil
    pullHideTimer = C_Timer.NewTimer((duration or MAX_PULL) + PULL_GRACE, function()
        pullHideTimer = nil
        if CancelBtn then CancelBtn:Hide() end
    end)
end

-- Frame strata choices offered by the "S" menu on the bar, in draw order.
local STRATA_OPTIONS = {
    { text = "Background",       value = "BACKGROUND" },
    { text = "Low",              value = "LOW" },
    { text = "Medium",           value = "MEDIUM" },
    { text = "High",             value = "HIGH" },
    { text = "Dialog",           value = "DIALOG" },
    { text = "Fullscreen",       value = "FULLSCREEN" },
    { text = "Fullscreen Dialog", value = "FULLSCREEN_DIALOG" },
    { text = "Tooltip",          value = "TOOLTIP" },
}

local function GetStrata()
    local saved = DanUIDB and DanUIDB.RaidTools and DanUIDB.RaidTools.floatingStrata
    for _, option in ipairs(STRATA_OPTIONS) do
        if option.value == saved then return saved end
    end
    return "TOOLTIP"
end

-- Text size options. The bar is laid out in one unit system, so a size change is
-- applied as a frame scale: labels and the buttons around them grow together.
local BASE_FONT_SIZE = 12
local FONT_SIZE_OPTIONS = {
    { text = "10 (Smallest)", value = 10 },
    { text = "11",            value = 11 },
    { text = "12 (Default)",  value = 12 },
    { text = "14",            value = 14 },
    { text = "16",            value = 16 },
    { text = "18 (Largest)",  value = 18 },
}

local function GetFontSize()
    local saved = DanUIDB and DanUIDB.RaidTools and DanUIDB.RaidTools.floatingFontSize
    for _, option in ipairs(FONT_SIZE_OPTIONS) do
        if option.value == saved then return saved end
    end
    return BASE_FONT_SIZE
end

-- BigWigs' /break counts in minutes, where /pull counts in seconds. The length
-- lives beside pullTimer in RaidTools and is edited in the same panel.
--
-- BigWigs accepts 1 to 60 and silently prints its usage line for anything else
-- (Plugins/Break.lua), so the value is clamped here rather than sent as typed.
local BREAK_DEFAULT_MINUTES, BREAK_MIN, BREAK_MAX = 5, 1, 60
local function GetBreakMinutes()
    local saved = DanUIDB and DanUIDB.RaidTools and tonumber(DanUIDB.RaidTools.breakTimer)
    if not saved then return BREAK_DEFAULT_MINUTES end
    return math.min(math.max(math.floor(saved), BREAK_MIN), BREAK_MAX)
end

-- The scroll dropdown is shared across modules, so only close it if it is ours.
local function HideBarMenus()
    local picker = _G.DUI_GenericPicker
    if not (picker and picker:IsShown()) then return end
    if picker.lastAnchor == StrataBtn or picker.lastAnchor == TextBtn then
        DUI_HideScrollDropdown()
    end
end

local function IsHorizontal()
    return DanUIDB and DanUIDB.RaidTools and DanUIDB.RaidTools.floatingHorizontal or false
end

-- Width of the visible action buttons as a group, laid out in a row or a column.
local function GetGroupWidth(horizontal, count)
    if not horizontal then return BTN_W end
    return count * BTN_W + math.max(count - 1, 0) * BTN_GAP
end

-- The bar is exactly its contents: the visible action buttons plus the config
-- row, both centred. The cancel button is deliberately not counted -- it is
-- hidden except during a pull, and reserving a permanent gutter for it left the
-- box looking off-centre around everything else.
local function GetBarSize(horizontal, count)
    -- A bar with every button switched off is hidden, not sized down to nothing.
    count = math.max(count or 0, 1)
    local actionH = horizontal and BTN_H or (count * BTN_H + (count - 1) * BTN_GAP)
    local contentW = PAD + GetGroupWidth(horizontal, count) + PAD
    local footerW = PAD + (SMALL_COUNT * SMALL_W) + ((SMALL_COUNT - 1) * SMALL_GAP) + PAD
    return math.max(contentW, footerW), PAD + actionH + FOOTER_GAP + SMALL_H + PAD
end

-- Lays out whichever buttons are switched on. This is also what applies a
-- visibility change, so ticking a box in the config panel only has to call
-- UpdateFloatingBar.
local function ApplyOrientation(horizontal)
    -- Re-anchoring the secure Ready Check button is out of combat only, same as
    -- the strata and scale changes below.
    if not FloatingBar or not PullBtn or InCombatLockdown() then return end

    local visible = EnabledDefs()
    FloatingBar:SetSize(GetBarSize(horizontal, #visible))

    for _, def in ipairs(BUTTON_DEFS) do
        if def.btn then def.btn:SetShown(IsButtonEnabled(def)) end
    end

    -- Each button hangs off the previous one: to its right, or beneath it. The
    -- head of the run is offset half the group's extra width, which centres the
    -- whole run in the bar whatever it is made of.
    local anchor = horizontal and "TOPRIGHT" or "BOTTOMLEFT"
    local xOff = horizontal and BTN_GAP or 0
    local yOff = horizontal and 0 or -BTN_GAP

    local prev
    for _, def in ipairs(visible) do
        def.btn:ClearAllPoints()
        if prev then
            def.btn:SetPoint("TOPLEFT", prev, anchor, xOff, yOff)
        else
            def.btn:SetPoint("TOP", FloatingBar, "TOP", -(GetGroupWidth(horizontal, #visible) - BTN_W) / 2, -PAD)
        end
        prev = def.btn
    end

    -- Cancel belongs to Pull: it hangs off the head of the run, and goes away
    -- with the button whose timer it cancels.
    CancelBtn:ClearAllPoints()
    CancelBtn:SetPoint("RIGHT", visible[1] and visible[1].btn or FloatingBar, "LEFT", -BTN_GAP, 0)
    if not IsButtonEnabled(defsByKey.pull) then HideCancel() end

    if OrientBtn then OrientBtn:SetText(horizontal and "H" or "V") end
end

local function ApplyStrata(strata)
    -- The bar parents a secure button (Ready Check), so restacking it is only safe
    -- out of combat. UpdateFloatingBar re-applies this on PLAYER_REGEN_ENABLED.
    if not FloatingBar or InCombatLockdown() then return end
    FloatingBar:SetFrameStrata(strata)
end

local function ApplyFontSize(size)
    -- Rescaling moves the secure Ready Check button, so it is out of combat only,
    -- same as the strata change above.
    if not FloatingBar or InCombatLockdown() then return end
    local scale = size / BASE_FONT_SIZE
    local current = FloatingBar:GetScale()
    if math.abs(current - scale) < 0.001 then return end

    -- Anchor offsets are expressed in the frame's own units, so they shift when
    -- the scale changes. Rescale them to keep the bar where the user dragged it.
    local point, relativeTo, relativePoint, x, y = FloatingBar:GetPoint()
    FloatingBar:SetScale(scale)
    if point then
        local ratio = current / scale
        FloatingBar:ClearAllPoints()
        FloatingBar:SetPoint(point, relativeTo or FloatingBar:GetParent(), relativePoint, x * ratio, y * ratio)
    end
end

function UpdateFloatingBar()
    if InCombatLockdown() or not FloatingBar then return end
    -- Master switch, driven by this module's checkbox on the launcher rail. Off
    -- means the bar never appears, whatever the group/window state below says.
    if DanUIDB and DanUIDB.RaidTools and DanUIDB.RaidTools.floatingEnabled == false then
        FloatingBar:Hide()
        HideBarMenus()
        return
    end
    -- Every button switched off is a request for no bar: an empty box wearing
    -- nothing but its config row is not something to leave on screen.
    if #EnabledDefs() == 0 then
        FloatingBar:Hide()
        HideBarMenus()
        return
    end
    if IsInGroup() or IsInRaid() or (DUI_MainFrame and DUI_MainFrame:IsShown()) then
        FloatingBar:Show() 
        -- Adjust transparency based on lock status
        if DanUIDB and DanUIDB.RaidTools then
            local db = DanUIDB.RaidTools
            ApplyOrientation(IsHorizontal())
            ApplyStrata(GetStrata())
            ApplyFontSize(GetFontSize())

            -- Locked: invisible backdrop and no config row. Unlocked: 50% body
            -- plus the strata / text-size buttons.
            local unlocked = not db.lockButtons
            FloatingBar:SetBackdropColor(0, 0, 0, unlocked and 0.5 or 0)
            FloatingBar:SetBackdropBorderColor(0, 0, 0, unlocked and 1 or 0)
            for _, btn in ipairs(footerButtons) do
                btn:SetShown(unlocked)
            end
            if not unlocked then HideBarMenus() end
        end
    else
        FloatingBar:Hide()
        HideBarMenus()
    end
end

function DUI_InitFloatingButtons()
    FloatingBar = CreateFrame("Frame", "DUI_FloatingBar_Frame", UIParent, "BackdropTemplate")
    -- ApplyOrientation resizes the bar to match the layout, but it bails in
    -- combat, so start at the right size for a reload mid-fight.
    FloatingBar:SetSize(GetBarSize(IsHorizontal(), #EnabledDefs()))
    FloatingBar:SetScale(GetFontSize() / BASE_FONT_SIZE)
    FloatingBar:SetPoint("TOP", 0, -100)
    FloatingBar:SetMovable(true)
    FloatingBar:SetClampedToScreen(true)
    FloatingBar:EnableMouse(true)
    FloatingBar:RegisterForDrag("LeftButton")
    FloatingBar:SetScript("OnDragStart", function(self)
        if DanUIDB.RaidTools and not DanUIDB.RaidTools.lockButtons then
            self:StartMoving()
        end
    end)
    FloatingBar:SetScript("OnDragStop", FloatingBar.StopMovingOrSizing)
    FloatingBar:Hide()
    FloatingBar:SetFrameStrata(GetStrata())
    FloatingBar:SetBackdrop(boxBackdrop)
    FloatingBar:SetBackdropColor(0, 0, 0, 0)
    FloatingBar:SetBackdropBorderColor(0, 0, 0, 0)

    PullBtn = CreateFrame("Button", "DUI_PullButton", FloatingBar, "BackdropTemplate")
    PullBtn:SetSize(BTN_W, BTN_H)
    PullBtn:SetText("Pull")
    StyleActionButton(PullBtn)
    AddTooltip(PullBtn, "Pull Timer", function()
        local seconds = DanUIDB.RaidTools and DanUIDB.RaidTools.pullTimer or 10
        return "Left-click: pull in " .. seconds .. "s.  Right-click: pull in 5s."
    end)

    PullBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    PullBtn:SetScript("OnClick", function(self, button)
        local seconds = (button == "RightButton") and 5 or (DanUIDB.RaidTools and DanUIDB.RaidTools.pullTimer or 10)
        local editBox = ChatEdit_ChooseBoxForSend()
        editBox:SetText("/pull " .. seconds)
        ChatEdit_SendText(editBox)
    end)

    CancelBtn = CreateFrame("Button", "DUI_CancelPullButton", FloatingBar, "BackdropTemplate")
    CancelBtn:SetSize(CANCEL_W, BTN_H)
    CancelBtn:SetText("X")
    StyleAsDangerButton(CancelBtn)
    CancelBtn:SetBackdropBorderColor(0, 0, 0, 0.6)
    local cancelFS = CancelBtn:GetFontString()
    cancelFS:SetTextColor(0.95, 0.95, 0.95)
    cancelFS:SetShadowColor(0, 0, 0, 1)
    cancelFS:SetShadowOffset(1, -1)
    CancelBtn:SetScript("OnClick", function()
        -- Drop the expiry timer with the button: without BigWigs loaded no
        -- StopPull arrives to do it, and a stale one would hide the *next*
        -- pull's button partway through its countdown.
        HideCancel()
        local editBox = ChatEdit_ChooseBoxForSend()
        editBox:SetText("/pull 0")
        ChatEdit_SendText(editBox)
    end)
    CancelBtn:Hide()

    -- Show/Hide the cancel button while a pull timer is active. We listen to the
    -- dedicated pull messages rather than parsing BigWigs_StartBar text: on the
    -- current client the bar text is a "secret" value, and comparing/searching it
    -- from addon code throws (ADDON_ACTION_FORBIDDEN / secret-value error).
    if BigWigsLoader then
        -- BigWigs_StartPull(module, seconds, nick, barText, icon)
        BigWigsLoader.RegisterMessage(CancelBtn, "BigWigs_StartPull", function(_, _, seconds)
            ShowCancel(seconds)
        end)
        -- Also fires with "COMBAT" when combat cuts the countdown short.
        BigWigsLoader.RegisterMessage(CancelBtn, "BigWigs_StopPull", HideCancel)
    end

    RCBtn = CreateFrame("Button", "DUI_RCButton", FloatingBar, "SecureActionButtonTemplate, BackdropTemplate")
    RCBtn:SetSize(BTN_W, BTN_H)
    RCBtn:SetText("RC")
    StyleActionButton(RCBtn)
    AddTooltip(RCBtn, "Ready Check", "Starts a ready check for the group.")
    RCBtn:SetAttribute("type", "macro")
    RCBtn:SetAttribute("macrotext1", "/readycheck")
    RCBtn:RegisterForClicks("AnyUp", "AnyDown")

    InspectBtn = CreateFrame("Button", "DUI_InspectButton", FloatingBar, "BackdropTemplate")
    InspectBtn:SetSize(BTN_W, BTN_H)
    InspectBtn:SetText("")
    StyleActionButton(InspectBtn)
    AddTooltip(InspectBtn, "Raid Inspection", "Toggles the inspection window.")

    -- Magnifying glass in place of a label. The modern atlas is preferred; the
    -- old search-box art is the fallback if this client does not have it.
    local inspectIcon = InspectBtn:CreateTexture(nil, "OVERLAY")
    inspectIcon:SetSize(12, 12)
    inspectIcon:SetPoint("CENTER")
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("common-search-magnifyingglass") then
        inspectIcon:SetAtlas("common-search-magnifyingglass")
    else
        inspectIcon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    end
    inspectIcon:SetVertexColor(0.95, 0.95, 0.95)

    InspectBtn:SetScript("OnClick", function()
        if DUI_ReadyCheckFrame and DUI_ReadyCheckFrame:IsShown() then
            DUI_ReadyCheckFrame:Hide()
        elseif DUI_ReadyCheckFrame then
            DUI_ReadyCheckFrame.Title:SetText("Raid Inspection")
            DUI_ReadyCheckFrame:Show()
            if UpdateRCWindow then UpdateRCWindow() end
        end
    end)

    BreakBtn = CreateFrame("Button", "DUI_BreakButton", FloatingBar, "BackdropTemplate")
    BreakBtn:SetSize(BTN_W, BTN_H)
    BreakBtn:SetText("Break")
    StyleActionButton(BreakBtn)
    AddTooltip(BreakBtn, "Break Timer", function()
        return "Left-click: break for " .. GetBreakMinutes() .. " min.  Right-click: cancel it."
            .. "  Set the length in the Floating Buttons panel."
    end)
    BreakBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    BreakBtn:SetScript("OnClick", function(self, button)
        -- /break is BigWigs' command and counts in minutes, unlike /pull; 0 cancels.
        -- It is also what feeds DanUI's own break display over in BreakTimer.lua.
        local minutes = (button == "RightButton") and 0 or GetBreakMinutes()
        local editBox = ChatEdit_ChooseBoxForSend()
        editBox:SetText("/break " .. minutes)
        ChatEdit_SendText(editBox)
    end)

    defsByKey.pull.btn = PullBtn
    defsByKey.readyCheck.btn = RCBtn
    defsByKey.inspect.btn = InspectBtn
    defsByKey["break"].btn = BreakBtn

    -- Bottom row: frame strata and text size, centred as a group of SMALL_COUNT
    -- so it tracks the bar width instead of fixed offsets.
    local function CreateSmallBtn(text, index)
        local step = SMALL_W + SMALL_GAP
        local xOff = (index - (SMALL_COUNT + 1) / 2) * step
        local btn = CreateFrame("Button", nil, FloatingBar, "BackdropTemplate")
        btn:SetSize(SMALL_W, SMALL_H)
        btn:SetPoint("BOTTOM", xOff, PAD)
        btn:SetText(text)
        btn:SetBackdrop(barBackdrop)
        btn:SetBackdropColor(0.2, 0.2, 0.2, 1)
        btn:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
        btn:SetNormalFontObject(DUI_FontSmall)
        btn:SetHighlightFontObject(DUI_FontSmall)
        footerButtons[#footerButtons + 1] = btn
        return btn
    end

    -- A footer button that opens one of the shared scroll dropdowns, saves the
    -- pick to the RaidTools DB and applies it live.
    --
    -- These sit beside the H/V button, which is a plain toggle, and at 16x14 there
    -- is no room to tell them apart by shape. A caret in the corner marks the ones
    -- that open a list -- the same signal the config panels' dropdowns use, shrunk
    -- to fit.
    local function CreateMenuBtn(text, index, title, hint, options, get, apply, dbKey)
        local btn = CreateSmallBtn(text, index)

        local caret = btn:CreateTexture(nil, "OVERLAY")
        caret:SetSize(4, 4)
        caret:SetPoint("BOTTOMRIGHT", -1, 1)
        -- A white texture tinted by vertex colour, not SetColorTexture, so the
        -- accent registry can recolour it live.
        caret:SetTexture("Interface\\Buttons\\WHITE8X8")
        caret:SetVertexColor(unpack(DUI_Theme.Accent))
        DUI_RegisterAccent(caret, "vertex")

        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(title)
            GameTooltip:AddLine("Current: " .. tostring(get()), 0.8, 0.8, 0.8)
            GameTooltip:AddLine(hint, 0.6, 0.6, 0.6, true)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        btn:SetScript("OnClick", function(self)
            if not DUI_ShowScrollDropdown or not DanUIDB.RaidTools then return end
            DUI_ShowScrollDropdown(self, options, function(val)
                DanUIDB.RaidTools[dbKey] = val
                apply(val)
            end, get())
        end)
        return btn
    end

    OrientBtn = CreateSmallBtn(IsHorizontal() and "H" or "V", 1)
    OrientBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Layout")
        GameTooltip:AddLine("Current: " .. (IsHorizontal() and "Horizontal" or "Vertical"), 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Click to switch between a row and a column of buttons.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    OrientBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    OrientBtn:SetScript("OnClick", function()
        if not DanUIDB.RaidTools then return end
        DanUIDB.RaidTools.floatingHorizontal = not IsHorizontal()
        ApplyOrientation(IsHorizontal())
    end)

    StrataBtn = CreateMenuBtn("S", 2, "Frame Strata",
        "Click to choose how far in front of other frames the bar draws.",
        STRATA_OPTIONS, GetStrata, ApplyStrata, "floatingStrata")

    TextBtn = CreateMenuBtn("T", 3, "Text Size",
        "Click to resize the labels. The buttons scale to match.",
        FONT_SIZE_OPTIONS, GetFontSize, ApplyFontSize, "floatingFontSize")

    ApplyOrientation(IsHorizontal())

    _G.DUI_FloatingBar = FloatingBar
    _G.UpdateFloatingBar = UpdateFloatingBar
    UpdateFloatingBar()
end

function DUI_HideFloatingBar()
    if FloatingBar then FloatingBar:Hide() end
    HideBarMenus()
end