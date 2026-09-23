-- LowHealthReminder.lua
-- Ported from PleebPotReminder for the DUI framework

local LSM = LibStub:GetLibrary("LibSharedMedia-3.0")
local db -- Local reference to DanUIDB.LowHealthReminder

-- Defined below with the event list; forward-declared so the appearance pass
-- (which owns the enabled flag) can turn the registrations on and off.
local SetReminderEventsRegistered

local HEALTHSTONE_ID = 5512
local DEMONIC_HEALTHSTONE_ID = 224464
local POTION_IDS = { 241305, 241304, 211879 }

-- Health is a secret value in restricted content, so this module never reads it.
-- Blizzard's own low health warning (the red screen vignette) is driven engine-side
-- and its frame's shown state is a plain boolean we are allowed to inspect, so the
-- trigger point is whatever the client is configured to use. That is why there are
-- no healthstone/potion threshold sliders: there is one trigger and it is Blizzard's.
local function IsBlizzardLowHealth()
    return (LowHealthFrame and LowHealthFrame:IsShown()) and true or false
end

function DUI_GetLowHealthReminderDefaults()
    return {
        enabled = true,
        combatOnly = false,
        fontSize = 20,
        iconOnly = false,
        iconScale = 1.0,
        updatesPerSecond = 5,
        soundAlert = "None",
        x = 0,
        y = 150,
        point = "CENTER",
        relPoint = "CENTER",
    }
end

local frame = CreateFrame("Frame", "DUI_LowHealthReminder", UIParent, "BackdropTemplate")
frame:SetSize(200, 50)
frame:Hide()
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self) if self:IsMovable() then self:StartMoving() end end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    if db then
        db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
    end
end)

frame.hsText = frame:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
frame.hsText:SetPoint("TOP", 0, 0)

frame.potText = frame:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
frame.potText:SetPoint("TOP", frame.hsText, "BOTTOM", 0, -5)

local function BuildReminderString(label, icon)
    local baseSize = (db and db.fontSize) or 20
    if db and db.iconOnly then
        local iconSize = baseSize * (db and db.iconScale or 1)
        return string.format("|T%d:%d:%d:0:0:64:64:5:59:5:59|t", icon, iconSize, iconSize)
    end
    return string.format("%s |T%d:%d:%d:0:0:64:64:5:59:5:59|t", label, icon, baseSize, baseSize)
end

-- The reminder text is rebuilt on every update but is virtually always identical to
-- last tick's. string.format allocates a new string and SetText forces a FontString
-- relayout, so both are skipped unless one of the inputs actually changed. The
-- resolved icon is part of the key so a texture that was not yet cached at login
-- still refreshes once it loads.
--
-- Every call site must go through here: writing the FontString directly would
-- leave these fields stale and cause a later update to be wrongly skipped.
local function SetReminderText(fs, label, itemID)
    local icon      = C_Item.GetItemIconByID(itemID) or 134400
    local fontSize  = (db and db.fontSize) or 20
    local iconScale = (db and db.iconScale) or 1
    local iconOnly  = (db and db.iconOnly) or false
    if fs.rLabel == label and fs.rIcon == icon and fs.rFontSize == fontSize
        and fs.rIconScale == iconScale and fs.rIconOnly == iconOnly then
        return
    end
    fs.rLabel, fs.rIcon, fs.rFontSize, fs.rIconScale, fs.rIconOnly =
        label, icon, fontSize, iconScale, iconOnly
    fs:SetText(BuildReminderString(label, icon))
end

local cachedHSID, cachedPotID, cachedHSReady, cachedPotReady = HEALTHSTONE_ID, POTION_IDS[1], false, false
local lastSoundTime = 0
local nextUpdateTime = 0
local wasLow = false

local function RefreshItemCache()
    -- 1. Robust Healthstone Logic (Warlock detection + fallback)
    local primaryHS = HEALTHSTONE_ID
    if select(2, UnitClass("player")) == "WARLOCK" then
        primaryHS = (C_Item.GetItemCount(DEMONIC_HEALTHSTONE_ID) or 0) > 0 and DEMONIC_HEALTHSTONE_ID or HEALTHSTONE_ID
    end
    cachedHSID = primaryHS
    local startHS, durationHS = C_Item.GetItemCooldown(cachedHSID)
    cachedHSReady = (C_Item.GetItemCount(cachedHSID) or 0) > 0 and (startHS == 0 and durationHS == 0)

    -- 2. Potion Priority Logic (Scans list for best available)
    cachedPotID = POTION_IDS[1]
    cachedPotReady = false
    for _, id in ipairs(POTION_IDS) do
        if (C_Item.GetItemCount(id) or 0) > 0 then
            cachedPotID = id
            local startP, durationP = C_Item.GetItemCooldown(id)
            cachedPotReady = (startP == 0 and durationP == 0)
            break
        end
    end
end

-- Only one alert is ever in flight. Keeping the handle lets a new alert cut off a
-- long sound file that is still playing instead of layering the two.
local activeSoundHandle = nil

local function PlayAlertSound()
    if not db or not db.soundAlert or db.soundAlert == "None" then return end
    local path = LSM:Fetch("sound", db.soundAlert)
    if not path then return end

    if activeSoundHandle then
        StopSound(activeSoundHandle, 200)
        activeSoundHandle = nil
    end
    local willPlay, handle = PlaySoundFile(path, "Master")
    if willPlay and handle then
        activeSoundHandle = handle
    end
end

-- Live (non-config) refresh. Visibility is the AND of "Blizzard says we are low"
-- and "this consumable is actually in bags and off cooldown", so a reminder never
-- appears for something that cannot be pressed.
local function UpdateLiveState()
    if not db or not db.enabled then
        frame:Hide()
        wasLow = false
        return
    end
    if db.combatOnly and not InCombatLockdown() then
        frame:Hide()
        wasLow = false
        return
    end

    -- Nothing is drawn unless Blizzard's warning is up, so the bag and cooldown
    -- scan is only worth running then. The `wasLow` case keeps the frame's final
    -- pass (the one that clears the alphas) correct on the way back down.
    local isLow = IsBlizzardLowHealth()
    if not isLow and not wasLow then
        frame:Hide()
        return
    end
    RefreshItemCache()

    frame:Show()
    frame.hsText:SetAlpha((isLow and cachedHSReady) and 1 or 0)
    frame.potText:SetAlpha((isLow and cachedPotReady) and 1 or 0)
    SetReminderText(frame.hsText, "Use Healthstone", cachedHSID)
    SetReminderText(frame.potText, "Use Potion", cachedPotID)

    -- Sound fires on the transition into low health, not continuously, and only when
    -- there is something worth reacting to. The time floor debounces health hovering
    -- on the threshold and flickering Blizzard's warning on and off.
    if isLow and not wasLow and (cachedHSReady or cachedPotReady) then
        local now = GetTime()
        if now > lastSoundTime then
            PlayAlertSound()
            lastSoundTime = now + 5
        end
    end
    wasLow = isLow
end

function DUI_UpdateLowHealthReminderAppearance()
    if not DanUIDB then return end
    DanUIDB.LowHealthReminder = DanUIDB.LowHealthReminder or DUI_GetLowHealthReminderDefaults()
    db = DanUIDB.LowHealthReminder

    SetReminderEventsRegistered(db.enabled)

    frame:ClearAllPoints()
    frame:SetPoint(db.point, UIParent, db.relPoint or db.point, db.x, db.y)
    local font, _, outline = DUI_FontNormal:GetFont()
    frame.hsText:SetFont(font, db.fontSize, outline)
    frame.potText:SetFont(font, db.fontSize, outline)

    if DUI_IsConfigOpen("DUI_LowHealthReminderConfig") then
        -- Config open: force both lines visible so the frame can be dragged and styled.
        frame:EnableMouse(true)
        if frame.SetBackdrop then
            frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
            frame:SetBackdropColor(0, 0, 0, 0.5)
            if DUI_Theme then frame:SetBackdropBorderColor(unpack(DUI_Theme.Accent)) end
        end
        RefreshItemCache()
        SetReminderText(frame.hsText, "Healthstone", cachedHSID)
        SetReminderText(frame.potText, "Potion", cachedPotID)
        frame.hsText:SetAlpha(1)
        frame.potText:SetAlpha(1)
        frame:Show()
    else
        frame:EnableMouse(false)
        frame:SetBackdrop(nil)
        UpdateLiveState()
    end
end

frame:SetScript("OnEvent", function(self, event)
    if DUI_IsConfigOpen("DUI_LowHealthReminderConfig") then return end

    -- UNIT_HEALTH is only a safety net for the case where the hook onto Blizzard's
    -- warning frame could not be installed; the hook is what normally drives the
    -- show/hide, so this path stays throttled.
    if event == "UNIT_HEALTH" then
        local now = GetTime()
        if now < nextUpdateTime then return end
        nextUpdateTime = now + (1 / ((db and db.updatesPerSecond) or 5))
    end

    UpdateLiveState()
end)

-- BAG_UPDATE alone fires in bursts on every loot, vendor sale and consumable use, so
-- while the module is off these registrations were paying for a full RefreshItemCache
-- pass per burst to reach a guard that discards the result. The appearance pass owns
-- the enabled flag, so it turns the whole set on and off.
local reminderEventsOn = false
function SetReminderEventsRegistered(on)
    on = on and true or false
    if on == reminderEventsOn then return end
    reminderEventsOn = on
    if on then
        frame:RegisterUnitEvent("UNIT_HEALTH", "player")
        frame:RegisterEvent("BAG_UPDATE")
        frame:RegisterEvent("BAG_UPDATE_COOLDOWN")
        frame:RegisterEvent("PLAYER_ENTERING_WORLD")
        frame:RegisterEvent("PLAYER_REGEN_DISABLED")
        frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    else
        frame:UnregisterAllEvents()
        frame:Hide()
        wasLow = false
    end
end
SetReminderEventsRegistered(true)

-- Hook Blizzard's warning frame for an exact edge trigger. It may not exist yet at
-- file load, so this is retried from PLAYER_ENTERING_WORLD until it takes.
local hooked = false
local function TryHookLowHealthFrame()
    if hooked or not LowHealthFrame or not LowHealthFrame.HookScript then return end
    hooked = true
    local function OnBlizzardWarningToggled()
        if DUI_IsConfigOpen("DUI_LowHealthReminderConfig") then return end
        UpdateLiveState()
    end
    LowHealthFrame:HookScript("OnShow", OnBlizzardWarningToggled)
    LowHealthFrame:HookScript("OnHide", OnBlizzardWarningToggled)
end

local hookFrame = CreateFrame("Frame")
hookFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
hookFrame:SetScript("OnEvent", TryHookLowHealthFrame)
TryHookLowHealthFrame()

-- Configuration UI
local config = DUI_CreateConfigFrame("DUI_LowHealthReminderConfig", "Low Health Reminder", 320, 400, "DUI_LowHealthReminderBtn", {
    onShow = function() DUI_UpdateLowHealthReminderAppearance() end,
    onHide = function() DUI_UpdateLowHealthReminderAppearance() end,
})

function DUI_OpenLowHealthReminderConfig()
    if not DanUIDB.LowHealthReminder then DanUIDB.LowHealthReminder = DUI_GetLowHealthReminderDefaults() end
    db = DanUIDB.LowHealthReminder

    -- Backfill missing defaults to prevent SetValue(nil) errors
    local defaults = DUI_GetLowHealthReminderDefaults()
    for k, v in pairs(defaults) do
        if db[k] == nil then db[k] = v end
    end

    -- Update UI to match current DB values when opened
    if config.soundBtn then config.soundBtn:SetValue(db.soundAlert or "None") end

    if not config.init then
        local L = DUI_CreateLayout(config)
        L:Text("Triggers on the game's own low health warning, so it behaves the same in raids and dungeons. A line only appears if that consumable is in your bags and off cooldown.",
            { indent = 20 })

        L:Header("Visuals")
        L:Slider("DUI_LHR_Size", "Font Size", 10, 50, 1, db, "fontSize", DUI_UpdateLowHealthReminderAppearance,
            { value = db.fontSize, tooltip = "Size of the reminder text and, with it, the inline item icons." })
        L:Slider("DUI_LHR_Scale", "Icon Scale", 0.5, 3.0, 0.1, db, "iconScale", DUI_UpdateLowHealthReminderAppearance,
            { fmt = "%.1fx", value = db.iconScale, tooltip = "Multiplies the icon size in Icon Only mode. Has no effect while text is shown." })
        L:Slider("DUI_LHR_Update", "Checks Per Sec", 1, 20, 1, db, "updatesPerSecond", nil,
            { fmt = "%d/s", value = db.updatesPerSecond or 5,
              tooltip = { body = "How often the fallback health check runs.",
                          note = "Only used if the hook onto Blizzard's warning frame failed; leaving it low costs nothing." } })

        L:Header("Options")
        L:Checkbox("Only in Combat", db, "combatOnly", DUI_UpdateLowHealthReminderAppearance,
            "Suppresses the reminder outside combat, so it cannot fire while you are eating or questing at low health.")
        L:Checkbox("Icon Only Mode", db, "iconOnly", DUI_UpdateLowHealthReminderAppearance,
            "Drops the \"Use Healthstone\" / \"Use Potion\" wording and shows just the item icons.")

        -- In the cursor flow rather than pinned to the bottom-left: sound names run
        -- long, and a wide enough field down there collided with Reset Position.
        local soundBtn = L:Dropdown("Sound", {
            tooltip = { body = "Plays once when the game's low health warning appears, if a healthstone or potion is ready.",
                        note = "Re-arms after 5 seconds." },
        })
        soundBtn:SetValue(db.soundAlert or "None")
        config.soundBtn = soundBtn

        soundBtn:SetScript("OnClick", function(self)
            local items = {{text = "None", value = "None"}}
            for _, s in ipairs(LSM:List("sound")) do table.insert(items, {text = s, value = s}) end
            DUI_ShowScrollDropdown(self, items, function(val)
                db.soundAlert = val
                self:SetValue(val)
                if val ~= "None" then
                    local path = LSM:Fetch("sound", val)
                    if path then PlaySoundFile(path, "Master") end
                end
            end, db.soundAlert)
        end)

        local resetBtn = CreateFrame("Button", nil, config, "BackdropTemplate")
        resetBtn:SetSize(120, 25); resetBtn:SetPoint("BOTTOMRIGHT", -20, 20); resetBtn:SetText("Reset Position")
        StyleAsTealTab(resetBtn)
        DUI_AddTooltip(resetBtn, "Reset Position", "Puts the reminder back at the middle of the screen.")
        resetBtn:SetScript("OnClick", function()
            db.point, db.relPoint, db.x, db.y = "CENTER", "CENTER", 0, 150
            DUI_UpdateLowHealthReminderAppearance()
        end)

        L:FitHeight(45) -- room for the sound / reset row pinned to the bottom
        config.init = true
    end
    config:Show()
    DUI_UpdateLowHealthReminderAppearance()
end
