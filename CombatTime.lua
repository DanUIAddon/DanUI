-- CombatTime.lua
-- Inspired by BigWigs CombatTimer and adapted for DUI

local LSM = LibStub:GetLibrary("LibSharedMedia-3.0")
local db -- Local reference to DanUIDB.CombatTime

-- Defined below with the event list; forward-declared so the appearance pass
-- (which owns the enabled flag) can turn the registrations on and off.
local SetCombatTimeEventsRegistered

function DUI_GetCombatTimeDefaults()
    return {
        enabled = true,
        width = 100,
        height = 30,
        x = 0,
        y = 200,
        point = "CENTER",
        relPoint = "CENTER",
        fontSize = 18,
        fontColor = {0.51, 0.65, 0.44, 1}, -- Default Sage Green
        strata = "MEDIUM",
        showOutCombat = true,
    }
end

local timer = CreateFrame("Frame", "DUI_CombatTimer", UIParent, "BackdropTemplate")
timer:SetSize(100, 30)
timer:SetPoint("CENTER", 0, 200)
timer:Hide()
timer:SetMovable(true)
timer:SetClampedToScreen(true)
timer:RegisterForDrag("LeftButton")
timer:SetScript("OnDragStart", function(self) if self:IsMovable() then self:StartMoving() end end)
timer:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    if db then
        db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
        if DUI_CT_Y then DUI_CT_Y:SetValue(y) end
    end
end)

timer.text = timer:CreateFontString(nil, "OVERLAY", "DUI_FontLarge")
timer.text:SetPoint("CENTER")

function DUI_UpdateCombatTimeAppearance()
    if not DanUIDB then return end
    DanUIDB.CombatTime = DanUIDB.CombatTime or DUI_GetCombatTimeDefaults()
    db = DanUIDB.CombatTime
    
    timer:SetSize(db.width, db.height)
    timer:SetFrameStrata(db.strata or "MEDIUM")
    timer:SetPoint(db.point, UIParent, db.relPoint or db.point, db.x, db.y)
    timer.text:SetFont(DUI_FontPath, db.fontSize, "OUTLINE")
    timer.text:SetTextColor(unpack(db.fontColor or DUI_Theme.Accent))

    if DUI_IsConfigOpen("DUI_CombatTimeConfig") then
        timer:EnableMouse(true)
        timer:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        timer:SetBackdropColor(0, 0, 0, 0.5)
        timer:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
        timer:Show()
    else
        timer:EnableMouse(false)
        timer:SetBackdrop(nil)
    end

    if not timer.active and (timer.text:GetText() == "" or timer.text:GetText() == nil) then
        timer.text:SetText("0:00")
    end

    SetCombatTimeEventsRegistered(db.enabled)
    if db.enabled then timer:Show() else timer:Hide() end
end

local startTime = 0
local lastSec = -1
timer.active = false

local function OnUpdate(self, elapsed)
    -- The m:ss text only changes once per second, so skip the string
    -- formatting on the other ~59 frames each second.
    local sec = math.floor(GetTime() - startTime)
    if sec ~= lastSec then
        lastSec = sec
        self.text:SetFormattedText("%d:%02d", math.floor(sec/60), sec%60)
    end
end

-- The frame stays shown out of combat so the "0:00" readout is visible, and a shown
-- frame runs its OnUpdate every single frame. Attaching the script only while the
-- clock is actually counting takes that from an always-on per-frame call down to zero.
local function StartTimer(force)
    if timer.active and not force then return end
    startTime = GetTime()
    lastSec = -1
    timer.active = true
    timer:Show()
    timer:SetScript("OnUpdate", OnUpdate)
end

local function StopTimer()
    timer.active = false
    timer:SetScript("OnUpdate", nil)
end

-- Combat events are only worth listening to while the module is on; the appearance
-- pass owns the flag, so it drives registration too (see DUI_UpdateCombatTimeAppearance).
local COMBAT_TIME_EVENTS = {
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
    "ENCOUNTER_START",
    "ENCOUNTER_END",
}

local combatTimeEventsOn = false
function SetCombatTimeEventsRegistered(on)
    on = on and true or false
    if on == combatTimeEventsOn then return end
    combatTimeEventsOn = on
    if on then
        for _, e in ipairs(COMBAT_TIME_EVENTS) do timer:RegisterEvent(e) end
    else
        timer:UnregisterAllEvents()
        StopTimer()
    end
end

timer:SetScript("OnEvent", function(self, event)
    if not db.enabled then return end
    if event == "PLAYER_REGEN_DISABLED" then
        StartTimer()
    elseif event == "ENCOUNTER_START" then
        StartTimer(true) -- Force reset to sync with boss encounter start
    elseif event == "PLAYER_REGEN_ENABLED" then
        if not IsEncounterInProgress() then
            StopTimer()
        end
    elseif event == "ENCOUNTER_END" then
        StopTimer()
    end
end)

-- Configuration UI
local config = DUI_CreateConfigFrame("DUI_CombatTimeConfig", "Combat Timer Settings", 320, 400, "DUI_CombatTimeBtn", {
    onShow = function() DUI_UpdateCombatTimeAppearance() end,
    onHide = function() DUI_UpdateCombatTimeAppearance() end,
})

function DUI_OpenCombatTimeConfig()
    if not DanUIDB.CombatTime then DanUIDB.CombatTime = DUI_GetCombatTimeDefaults() end
    db = DanUIDB.CombatTime

    -- Update UI to match current DB values when opened
    if config.strataBtn then config.strataBtn:SetValue(db.strata or "MEDIUM") end

    if not config.init then
        local L = DUI_CreateLayout(config)
        L:Header("Layout")
        L:Slider("DUI_CT_Width", "Width", 50, 400, 5, db, "width", DUI_UpdateCombatTimeAppearance,
            { value = db.width, tooltip = "Width of the timer's clickable area. Only matters while this panel is open and the frame is draggable." })
        L:Slider("DUI_CT_Height", "Height", 10, 100, 1, db, "height", DUI_UpdateCombatTimeAppearance,
            { value = db.height, tooltip = "Height of the timer's clickable area." })
        L:Slider("DUI_CT_Font", "Font Size", 10, 50, 1, db, "fontSize", DUI_UpdateCombatTimeAppearance,
            { value = db.fontSize, tooltip = "Size of the m:ss text itself." })

        L:Header("Options")
        L:ColorButton("Font Color", db, "fontColor", DUI_UpdateCombatTimeAppearance,
            "Colour of the timer text.")

        local strataBtn = L:Dropdown("Strata", {
            tooltip = { body = "Which layer the timer draws on, deciding what it can appear in front of.",
                        note = "Raise it if another addon covers the timer." },
        })
        strataBtn:SetValue(db.strata or "MEDIUM")
        config.strataBtn = strataBtn
        strataBtn:SetScript("OnClick", function(self)
            local levels = {}
            for _, l in ipairs({"BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP"}) do
                table.insert(levels, {text = l, value = l})
            end
            DUI_ShowScrollDropdown(self, levels, function(val)
                db.strata = val
                self:SetValue(val)
                DUI_UpdateCombatTimeAppearance()
            end, db.strata or "MEDIUM")
        end)

        L:Gap()
        L:Text("Drag the timer on screen to reposition it while this panel is open.")

        L:FitHeight()

        config.init = true
    end
    config:Show()
    DUI_UpdateCombatTimeAppearance()
end