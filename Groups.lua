-- Groups.lua
local strtrim = strtrim
local RAID_CLASS_COLORS = RAID_CLASS_COLORS

-- This module had no saved variables of its own: it is a tool you open, and every
-- setting it touches (SplitParts, SplitLayout, SplitGroups) lives at the top level
-- of DanUIDB. The launcher gives every module an enable checkbox, so it needs a
-- table of its own to keep that flag in.
function DUI_EnsureRaidArrangerDB()
    if not DanUIDB then DanUIDB = {} end
    DanUIDB.RaidArranger = DanUIDB.RaidArranger or {}
    if DanUIDB.RaidArranger.enabled == nil then DanUIDB.RaidArranger.enabled = true end
    return DanUIDB.RaidArranger
end

local popout = CreateFrame("Frame", "DUI_GroupsPopout", UIParent, "BackdropTemplate")
-- Opens at the docking pane's size. The height is recomputed in the group-count
-- logic below, which never goes under the pane either.
popout:SetSize(DUI_PANEL_W, DUI_PANEL_H)
popout:SetPoint("CENTER")
popout:SetMovable(true)
popout:SetClampedToScreen(true)
popout:EnableMouse(true)
popout:RegisterForDrag("LeftButton")
popout:SetScript("OnDragStart", function()
    if DUI_MainFrame then
        DUI_MainFrame:StartMoving()
    end
end)
popout:SetScript("OnDragStop", function()
    if DUI_MainFrame then
        DUI_MainFrame:StopMovingOrSizing()
    end
end)
popout:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8", 
    tile = true, tileSize = 256, edgeSize = 2, 
    insets = { left = 0, right = 0, top = 0, bottom = 0 }
})
popout:SetBackdropColor(unpack(DUI_Theme.MainBG)) 
popout:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
DUI_RegisterAccent(popout, "border")
DUI_RegisterMainBG(popout, "bg")
popout:SetFrameStrata("TOOLTIP")
popout:Hide()

table.insert(UISpecialFrames, "DUI_GroupsPopout")

local GroupContainers = {}
local Edits = {} -- Declare Edits here so UpdateGroupsVisibility can see it

-- Layout metrics, shared by the grid builder further down and the height math in
-- UpdateGroupsVisibility. They are tuned so that six groups *plus* the button row
-- come to exactly DUI_PANEL_H: the launcher's pane only grows a scrollbar when the
-- docked panel is taller than it (DUI_CreateScrollArea's Update tests
-- `maxScroll > 0`), so landing on the number exactly is the difference between a
-- 30-man raid you can see whole and one you have to scroll. Touch any of these and
-- HeightForRows(3) has to still come out at DUI_PANEL_H.
local TOP_INSET    = 56   -- title divider (-32) down to the first row's group label
-- Each group's five boxes sit on a card, so the two columns need a gutter wide
-- enough for two card edges plus air between them: 8px of padding either side of a
-- 230px box makes a 246px card, and 256 pitch leaves 10px between the pair. The two
-- cards then come to 502px, centred in the 560px pane with 29px either side.
local COL_X        = 37   -- left margin of column 0 (its card starts 8px further left)
local COL_PITCH    = 256  -- 230px name boxes, 8px card padding, 10px between cards
local BOX_W, BOX_H = 230, 24
local BOX_PITCH    = 27   -- box to box inside one group
local GROUP_H      = 4 * BOX_PITCH + BOX_H  -- 132: top of box 1 to bottom of box 5
local ROW_PITCH    = 165  -- group row to group row; the 33px slack carries the label
local BTN_Y, BTN_H = 25, 25 -- the button row's bottom margin and its height
local BTN_GAP      = 12   -- last name box down to the top of the buttons

local function HeightForRows(rows)
    return TOP_INSET + (rows - 1) * ROW_PITCH + GROUP_H + BTN_GAP + BTN_H + BTN_Y
end

local function UpdateGroupsVisibility()
    local num = GetNumGroupMembers()
    local groupsToShow = 4
    if num > 30 then
        groupsToShow = 8
    elseif num > 20 then
        groupsToShow = 6
    end

    -- Auto-expand if groups have text (e.g. after a split or manual entry)
    if groupsToShow < 8 then
        for idx = 31, 40 do
            if Edits[idx] and strtrim(Edits[idx]:GetText()) ~= "" then -- Line 48
                groupsToShow = 8; break
            end
        end
    end
    if groupsToShow < 6 then
        for idx = 21, 30 do
            if Edits[idx] and strtrim(Edits[idx]:GetText()) ~= "" then
                groupsToShow = 6; break
            end
        end
    end

    for i = 1, 8 do
        local isVisible = (i <= groupsToShow)
        for _, element in ipairs(GroupContainers[i]) do
            element:SetShown(isVisible)
        end
    end

    -- Two groups per row, so 4/6/8 groups are 2/3/4 rows. Floored at the pane's
    -- height so a four-group raid does not leave the panel as a short box in the
    -- top of an otherwise empty pane; six lands on it exactly and does not scroll.
    -- Eight is still taller than the pane and scrolls.
    local newHeight = HeightForRows(math.ceil(groupsToShow / 2))
    popout:SetHeight(math.max(newHeight, DUI_PANEL_H))
end

popout.Title = popout:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
popout.Title:SetPoint("TOP", 0, -12)
popout.Title:SetText("Raid Arranger")
-- Hand-rolled panel (not built by DUI_CreateConfigFrame): add the shared title-bar
-- chrome and drop shadow explicitly so it matches the factory-built panels.
DUI_AddTitleChrome(popout)
DUI_AddDropShadow(popout)

-- Styled Close Button (Matching MainFrame)
local CloseBtn = CreateFrame("Button", nil, popout, "BackdropTemplate")
CloseBtn:SetSize(20, 20)
CloseBtn:SetPoint("TOPRIGHT", -5, -5)
StyleAsCloseButton(CloseBtn)
CloseBtn:SetScript("OnClick", function() popout:Hide() end)
popout.closeBtn = CloseBtn -- hidden by the launcher while this panel is docked

local parent = popout
local TargetRoster = nil -- Declare these here
local isProcessing = false -- Declare these here
local pendingRosterUpdate = false -- Declare these here

-- Utility: Get current roster into the boxes
local function SnapshotRoster()
    if not IsInRaid() then print("|cFF00FF00[DUI]|r Not in a raid."); return end
    local roster = {}
    for i = 1, 8 do roster[i] = {} end
    
    for i = 1, GetNumGroupMembers() do
        local name, _, subgroup = GetRaidRosterInfo(i)
        if name then
            table.insert(roster[subgroup], Ambiguate(name, "short"))
        end
    end
    
    for g = 1, 8 do
        for p = 1, 5 do
            local idx = (g - 1) * 5 + p
            if Edits[idx] then -- Defensive check
                Edits[idx]:SetText(roster[g][p] or "")
                Edits[idx]:SetCursorPosition(0)
            end
        end
    end
end

-- Core Logic: Process moves
local function ProcessRoster()
    if not TargetRoster or InCombatLockdown() then 
        if DUI_PushBtn then -- Defensive check
            DUI_PushBtn:SetText("Push")
        end
        isProcessing = false
        return 
    end
    
    local currentSubgroups, nameToID, groupSizes = {}, {}, {}
    for i = 1, 8 do groupSizes[i] = 0 end

    for i = 1, GetNumGroupMembers() do
        local name, _, subgroup = GetRaidRosterInfo(i)
        if name then
            local shortName = Ambiguate(name, "short")
            -- Check if user entered shortname in boxes
            if not TargetRoster[name] and TargetRoster[shortName] then name = shortName end
            
            currentSubgroups[name] = subgroup
            nameToID[name] = i
            groupSizes[subgroup] = groupSizes[subgroup] + 1
        end
    end

    for name, targetGroup in pairs(TargetRoster) do
        local currentGroup = currentSubgroups[name]
        if currentGroup and currentGroup ~= targetGroup then
            if groupSizes[targetGroup] < 5 then
                SetRaidSubgroup(nameToID[name], targetGroup)
                return -- Exit and wait for GROUP_ROSTER_UPDATE
            else
                -- Group is full, need to find a swap candidate
                for name2, targetGroup2 in pairs(TargetRoster) do
                    if currentSubgroups[name2] == targetGroup and TargetRoster[name2] ~= targetGroup then
                        SwapRaidSubgroup(nameToID[name], nameToID[name2])
                        return 
                    end
                end
            end
            -- If we reached here, someone is in the wrong group but there's no space or swap candidate
            print("|cFF00FF00[DUI]|r Group arrangement stalled. Ensure groups aren't overfilled.")
            if DUI_PushBtn then -- Defensive check
                DUI_PushBtn:SetText("Push")
            end
            TargetRoster = nil
            isProcessing = false
            return
        end
    end

    -- No moves required
    print("|cFF00FF00[DUI]|r Groups arranged successfully.")
    TargetRoster = nil
    isProcessing = false
    if DUI_PushBtn then -- Defensive check
        DUI_PushBtn:SetText("Push")
    end
end

-- Global bridge for DanUI.lua to call
RG_Update = function()
    -- Only while the panel is on screen: this runs on every roster change, and a
    -- hidden panel is brought up to date by its own OnShow hook below anyway.
    -- IsVisible, not IsShown - a docked panel keeps its shown flag when the main
    -- window closes (see DUI_IsConfigOpen).
    if next(Edits) and popout:IsVisible() then UpdateGroupsVisibility() end
    if isProcessing and not InCombatLockdown() and not pendingRosterUpdate then
        pendingRosterUpdate = true
        C_Timer.After(0.6, function()
            pendingRosterUpdate = false
            if isProcessing then ProcessRoster() end
        end)
    end
end

local function ClearRoster()
    for i = 1, 40 do
        if Edits[i] then -- Defensive check
            Edits[i]:SetText("")
            Edits[i]:SetCursorPosition(0)
        end
    end
    UpdateGroupsVisibility()
end

local function StopPush()
    isProcessing = false
    TargetRoster = nil
    if DUI_PushBtn then -- Defensive check
        DUI_PushBtn:SetText("Push")
    end
    print("|cFF00FF00[DUI]|r Group arrangement stopped.")
end

-- Apply hook for the main window's rail. A push moves one player per roster
-- update, so without this, unticking the row mid-arrange left it moving people
-- until the roster matched.
function DUI_RaidArrangerApplyEnabled(enabled)
    if not enabled and isProcessing then StopPush() end
end

local function PushChanges()
    if isProcessing then
        StopPush()
        return
    end

    -- Like the Guild Bank Sorter, this module runs nothing in the background:
    -- rearranging the raid is its only effect, so that is what its checkbox on
    -- the launcher rail switches off. Stopping an in-flight push is left above,
    -- so turning the module off mid-arrange cannot strand it.
    DUI_EnsureRaidArrangerDB()
    if DanUIDB.RaidArranger.enabled == false then
        print("|cFF00FF00[DUI]|r Raid Arranger is switched off in the module list.")
        return
    end

    TargetRoster = {}
    for i = 1, 40 do
        if Edits[i] then -- Defensive check
            local name = strtrim(Edits[i]:GetText())
            if name ~= "" then
                local group = math.floor((i - 1) / 5) + 1
                TargetRoster[name] = group
            end
        end
    end
    isProcessing = true
    if DUI_PushBtn then -- Defensive check
        DUI_PushBtn:SetText("Stop")
    end
    ProcessRoster()
end

-- Combined Visual and State Update Logic
local function UpdateEditBoxVisuals(self)
    local name = strtrim(self:GetText())

    if name == "" then
        self.roleIcon:Hide()
        self:SetTextColor(1, 1, 1)
        return
    end

    local role = UnitGroupRolesAssigned(name)
    local _, class = UnitClass(name)

    local icon = role == "TANK" and "groupfinder-icon-role-large-tank" or
                 role == "HEALER" and "groupfinder-icon-role-large-heal" or
                 role == "DAMAGER" and "groupfinder-icon-role-large-dps"
    
    if icon then
        self.roleIcon:SetAtlas(icon)
        self.roleIcon:Show()
    else
        self.roleIcon:Hide()
    end

    if class then
        local color = RAID_CLASS_COLORS[class]
        self:SetTextColor(color.r, color.g, color.b)
    else
        self:SetTextColor(1, 1, 1)
    end
end

popout.Edits = Edits

-- UI: Create the 8 Group Grids
for i = 1, 8 do
    GroupContainers[i] = {}
    local col = (i - 1) % 2
    local row = math.floor((i - 1) / 2)
    -- 240px column pitch rather than 220: the panel is the pane's full width now,
    -- and the name boxes were sized for a 500px window.
    local xBase = COL_X + (col * COL_PITCH)
    local yBase = -TOP_INSET - (row * ROW_PITCH)

    local label = parent:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
    table.insert(GroupContainers[i], label)
    label:SetFont(DUI_FontPath, 16, "")
    label:SetPoint("BOTTOM", parent, "TOPLEFT", xBase + BOX_W / 2, yBase + 2)
    label:SetText("Group " .. i)
    label:SetTextColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(label, "text")

    -- The same section card every config panel draws, one per group, with the
    -- accent "Group N" label above it exactly as a section header sits above its
    -- own card. Created before the boxes, but that is not what orders them: a
    -- card is textures in BACKGROUND and the boxes are frames, which always draw
    -- over their parent's textures.
    local cardTop = -yBase - 8
    local card = DUI_CreateCard(parent, xBase - 8, cardTop, xBase + BOX_W + 8,
        cardTop + GROUP_H + 16)
    -- Joins the group's element list so UpdateGroupsVisibility hides it along with
    -- the boxes when the raid does not fill this many groups.
    if card then table.insert(GroupContainers[i], card) end

    for j = 1, 5 do
        local idx = (i - 1) * 5 + j
        local eb = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
        table.insert(GroupContainers[i], eb)
        eb:SetSize(BOX_W, BOX_H)
        eb:SetPoint("TOPLEFT", xBase, yBase - (j - 1) * BOX_PITCH)
        eb.originalPoint = { "TOPLEFT", xBase, yBase - (j - 1) * BOX_PITCH }
        eb:SetAutoFocus(false)
        eb:SetFontObject(DUI_FontNormal)
        eb:SetJustifyH("LEFT")
        eb:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
        eb:SetBackdropColor(0, 0, 0, 0.5)
        eb:SetBackdropBorderColor(unpack(DUI_Theme.Secondary))
        DUI_RegisterSecondary(eb, "border")
        eb:SetTextInsets(22, 5, 0, 0) -- Room for icon
        Edits[idx] = eb

        eb.roleIcon = eb:CreateTexture(nil, "OVERLAY")
        eb.roleIcon:SetSize(16, 16)
        eb.roleIcon:SetPoint("LEFT", 4, 0)
        eb.roleIcon:Hide()

        -- Navigation and Focus logic
        eb:SetScript("OnTabPressed", function()
            local nextIdx = IsShiftKeyDown() and idx - 1 or idx + 1
            if nextIdx > 40 then nextIdx = 1 elseif nextIdx < 1 then nextIdx = 40 end -- Wrap around
            Edits[nextIdx]:SetFocus()
        end)
        eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

        -- Visual feedback for drag-and-drop / hover
        eb:SetScript("OnEnter", function(self) 
            self:SetBackdropBorderColor(unpack(DUI_Theme.Accent)) 
        end)
        eb:SetScript("OnLeave", function(self) 
            if not self:HasFocus() then
                self:SetBackdropBorderColor(unpack(DUI_Theme.Secondary))
            end
        end)

        -- Class coloring logic
        eb:SetScript("OnTextChanged", UpdateEditBoxVisuals)

        -- Drag and Drop logic
        eb:SetMovable(true)
        eb:RegisterForDrag("LeftButton")
        eb:SetScript("OnDragStart", function(self) self:StartMoving() end)
        eb:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            local target
            for k = 1, 40 do
                if Edits[k]:IsMouseOver() and Edits[k] ~= self then
                    target = Edits[k]
                    break
                end
            end
            if target then
                local t1, t2 = self:GetText(), target:GetText()
                self:SetText(t2)
                target:SetText(t1)
                self:SetCursorPosition(0)
                target:SetCursorPosition(0)
            end
            self:ClearAllPoints()
            self:SetPoint(unpack(self.originalPoint))
        end)
    end
end

-- Row of four 90px buttons across a DUI_PANEL_W (560) panel. Push is pinned to
-- BOTTOMRIGHT -40, so the other three have to be spaced to meet it: 560 - 2*40
-- margins - 4*90 buttons = 120 of slack, 40 per gap. Hence 40/170/300, with
-- Push's own left edge landing on 430.
local btnCurrent = CreateFrame("Button", nil, parent, "BackdropTemplate")
btnCurrent:SetSize(90, BTN_H); btnCurrent:SetPoint("BOTTOMLEFT", 40, BTN_Y); btnCurrent:SetText("Current")
StyleAsTealTab(btnCurrent); btnCurrent:SetScript("OnClick", SnapshotRoster)

local btnSplit = CreateFrame("Button", nil, parent, "BackdropTemplate")
btnSplit:SetSize(90, BTN_H); btnSplit:SetPoint("BOTTOMLEFT", 170, BTN_Y); btnSplit:SetText("Split")
StyleAsTealTab(btnSplit)
btnSplit:RegisterForClicks("LeftButtonUp", "RightButtonUp")
btnSplit:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        if MenuUtil then
            MenuUtil.CreateContextMenu(self, function(owner, root)
                root:CreateTitle(DUI_AccentText("Split Strategy"))
                root:CreateCheckbox("Auto (Balanced Groups)", function() return DanUIDB.SplitParts == "auto" or DanUIDB.SplitParts == nil end, function() DanUIDB.SplitParts = "auto"; print("|cFF82A670[DUI]|r Strategy: Auto (balanced groups)") end)
                root:CreateCheckbox("2 Teams", function() return DanUIDB.SplitParts == 2 end, function() DanUIDB.SplitParts = 2; print("|cFF82A670[DUI]|r Strategy: 2 Teams") end)
                root:CreateCheckbox("4 Teams", function() return DanUIDB.SplitParts == 4 end, function() DanUIDB.SplitParts = 4; print("|cFF82A670[DUI]|r Strategy: 4 Teams") end)
                root:CreateCheckbox("8 Teams", function() return DanUIDB.SplitParts == 8 end, function() DanUIDB.SplitParts = 8; print("|cFF82A670[DUI]|r Strategy: 8 Teams") end)
                root:CreateDivider()
                root:CreateTitle(DUI_AccentText("Group Layout"))
                root:CreateCheckbox("Blocks (1,2,3 | 4,5,6)", function() return (DanUIDB.SplitLayout or "block") == "block" end, function() DanUIDB.SplitLayout = "block"; print("|cFF82A670[DUI]|r Layout: Blocks (1,2,3 | 4,5,6)") end)
                root:CreateCheckbox("Alternating (1,3,5 | 2,4,6)", function() return DanUIDB.SplitLayout == "interleave" end, function() DanUIDB.SplitLayout = "interleave"; print("|cFF82A670[DUI]|r Layout: Alternating (1,3,5 | 2,4,6)") end)
                root:CreateDivider()
                root:CreateTitle(DUI_AccentText("Active Groups"))
                for i = 1, 8 do
                    root:CreateCheckbox("Group "..i, function() return DanUIDB.SplitGroups[i] end, function() DanUIDB.SplitGroups[i] = not DanUIDB.SplitGroups[i] end)
                end
            end)
        else
            local menu = {
                { text = DUI_AccentText("Split Strategy"), isTitle = true, notCheckable = true },
                { text = "Auto (Balanced Groups)", checked = function() return DanUIDB.SplitParts == "auto" or DanUIDB.SplitParts == nil end, func = function() DanUIDB.SplitParts = "auto" end, isNotRadio = false },
                { text = "2 Teams", checked = function() return DanUIDB.SplitParts == 2 end, func = function() DanUIDB.SplitParts = 2 end, isNotRadio = false },
                { text = "4 Teams", checked = function() return DanUIDB.SplitParts == 4 end, func = function() DanUIDB.SplitParts = 4 end, isNotRadio = false },
                { text = "8 Teams", checked = function() return DanUIDB.SplitParts == 8 end, func = function() DanUIDB.SplitParts = 8 end, isNotRadio = false },
                { text = "", isTitle = true, notCheckable = true },
                { text = DUI_AccentText("Group Layout"), isTitle = true, notCheckable = true },
                { text = "Blocks (1,2,3 | 4,5,6)", checked = function() return (DanUIDB.SplitLayout or "block") == "block" end, func = function() DanUIDB.SplitLayout = "block" end, isNotRadio = false },
                { text = "Alternating (1,3,5 | 2,4,6)", checked = function() return DanUIDB.SplitLayout == "interleave" end, func = function() DanUIDB.SplitLayout = "interleave" end, isNotRadio = false },
                { text = "", isTitle = true, notCheckable = true },
                { text = DUI_AccentText("Active Groups"), isTitle = true, notCheckable = true },
            }
            for i = 1, 8 do
                table.insert(menu, { text = "Group "..i, checked = function() return DanUIDB.SplitGroups[i] end, func = function() DanUIDB.SplitGroups[i] = not DanUIDB.SplitGroups[i] end, isNotRadio = true, keepShownOnClick = true })
            end
            local menuFrame = CreateFrame("Frame", "DUI_SplitMenu", self, "UIDropDownMenuTemplate")
            EasyMenu(menu, menuFrame, "cursor", 0, 0, "MENU")
        end
    else
        if DUI_SplitRoster then 
            DUI_SplitRoster()
            UpdateGroupsVisibility()
        end
    end
end)

local btnClear = CreateFrame("Button", nil, parent, "BackdropTemplate")
btnClear:SetSize(90, BTN_H); btnClear:SetPoint("BOTTOMLEFT", 300, BTN_Y); btnClear:SetText("Clear")
StyleAsTealTab(btnClear); btnClear:SetScript("OnClick", ClearRoster)

local btnPush = CreateFrame("Button", "DUI_PushBtn", parent, "BackdropTemplate")
btnPush:SetSize(90, BTN_H); btnPush:SetPoint("BOTTOMRIGHT", -40, BTN_Y); btnPush:SetText("Push")
StyleAsTealTab(btnPush); btnPush:SetScript("OnClick", PushChanges)

-- Define the hooks here, after Edits is fully populated
popout:HookScript("OnShow", function()
    -- OnShow is queued, not run inside Show(), so this lands after the launcher
    -- has already parented and positioned the panel in its docking pane, and
    -- after the index warm-up has shown and hidden it again in a single frame.
    -- Bail on the second case, and let DUI_RestoreConfigPosition -- same default
    -- spot, but it leaves a docked panel where it is -- handle the first.
    if not popout:IsShown() then return end
    if DUI_RaidGroupsPopoutBtn then DUI_RaidGroupsPopoutBtn:SetBackdropBorderColor(unpack(DUI_Theme.Accent)) end
    if DUI_RaidGroupsBtn_Tools then DUI_RaidGroupsBtn_Tools:SetBackdropBorderColor(unpack(DUI_Theme.Accent)) end

    DUI_RestoreConfigPosition(popout)
    UpdateGroupsVisibility()
end)

popout:HookScript("OnHide", function()
    if DUI_RaidGroupsPopoutBtn then DUI_RaidGroupsPopoutBtn:SetBackdropBorderColor(0, 0, 0, 1) end
    if DUI_RaidGroupsBtn_Tools then DUI_RaidGroupsBtn_Tools:SetBackdropBorderColor(0, 0, 0, 1) end
end)

-- Initial call to UpdateGroupsVisibility after all UI elements are created and hooks are set
if next(Edits) then UpdateGroupsVisibility() end