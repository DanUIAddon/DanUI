-- BattleRes.lua
-- Tracks pooled Battle Resurrection charges in Raids and Mythic+

local SPELL_ID_BREZ = 20484 -- Generic Battle Res ID for charge tracking
local db -- Local reference to DanUIDB.RaidTools

local DEFAULT_BR_SIZE = 40

local frame = CreateFrame("Frame", "DUI_BattleResFrame", UIParent)
frame:SetSize(DEFAULT_BR_SIZE, DEFAULT_BR_SIZE)
frame:SetPoint("CENTER", 200, 0)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetClampedToScreen(true)
frame:Hide()

-- Add Cooldown sweep (from MRT logic)
frame.cooldown = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
frame.cooldown:SetAllPoints()
frame.cooldown:SetReverse(true)
frame.cooldown:SetHideCountdownNumbers(true)
frame.cooldown:SetAlpha(0.6)

frame.icon = frame:CreateTexture(nil, "ARTWORK")
frame.icon:SetAllPoints()
local brezTex = C_Spell.GetSpellTexture(SPELL_ID_BREZ)
frame.icon:SetTexture(brezTex or 136080)
frame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

frame.text = frame:CreateFontString(nil, "OVERLAY", "DUI_FontBR")
frame.text:SetPoint("TOPRIGHT", frame.icon, "TOPRIGHT", 2, 0)
frame.text:SetText("0")

frame.timer = frame:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
frame.timer:SetPoint("TOP", frame.icon, "BOTTOM", 0, -2)
frame.timer:SetTextColor(1, 1, 1)

frame:SetScript("OnDragStart", function(self)
    if DanUIDB.RaidTools and not DanUIDB.RaidTools.battleResLocked then
        self:StartMoving()
    end
end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
end)

-- Recreating this closure per refresh, and reformatting the m:ss on every frame of a
-- ten-minute battle-res cooldown, was the module's whole steady-state cost. The script
-- is now a single hoisted function reading state off the frame, and it only touches the
-- FontString when the displayed second actually changes.
local UpdateCharges -- forward declaration: the tick restarts the refresh when it expires

local function BattleResOnUpdate(self, elapsed)
    local timeRem = self.brDuration - (GetTime() - self.brStart)
    if timeRem <= 0 then
        self.timer:SetText("")
        self.brLastSec = nil
        self:SetScript("OnUpdate", nil)
        UpdateCharges()
        return
    end
    local sec = math.ceil(timeRem)
    if sec ~= self.brLastSec then
        self.brLastSec = sec
        self.timer:SetFormattedText("%d:%02d", math.floor(sec / 60), sec % 60)
    end
end

function UpdateCharges()
    db = DanUIDB.RaidTools
    -- The post-combat C_Timer and the recharge OnUpdate can both land here after the
    -- tracker was switched off, and everything below ends in frame:Show().
    if not frame.brEnabled and not frame.isTesting then
        frame:Hide()
        return
    end
    local chargeInfo = C_Spell.GetSpellCharges(20484)
    
    -- If no charges are available (not in a raid/M+ encounter), hide the frame
    if not chargeInfo or (chargeInfo.currentCharges == 0 and chargeInfo.maxCharges == 0) then
        if not frame.isTesting and not (db and not db.battleResLocked) then
            frame:Hide()
            return
        end
    end

    local charges = chargeInfo and chargeInfo.currentCharges or 0
    local maxCharges = chargeInfo and chargeInfo.maxCharges or 0
    local chargeStart = chargeInfo and chargeInfo.cooldownStartTime or 0
    local chargeDuration = chargeInfo and chargeInfo.cooldownDuration or 0

    -- SPELL_UPDATE_CHARGES is not per spell: it fires whenever *any* of the player's
    -- charge spells moves, which for most classes is several times a pull. The pool
    -- itself rarely changed, and repainting it restarted the cooldown swipe and the
    -- m:ss readout for nothing. Skipped only while the frame is already up and the
    -- test preview is not; the preview paints over the text, so it clears the cache
    -- (see ToggleBRTracker) and the first real pass after it repaints in full.
    if frame:IsShown() and not frame.isTesting
        and charges == frame.brCharges and maxCharges == frame.brMax
        and chargeStart == frame.brSigStart and chargeDuration == frame.brSigDuration then
        return
    end
    frame.brCharges, frame.brMax = charges, maxCharges
    frame.brSigStart, frame.brSigDuration = chargeStart, chargeDuration

    frame.text:SetText(charges)
    if charges == 0 then
        frame.text:SetTextColor(1, 0, 0) -- Red if 0
    else
        frame.text:SetTextColor(1, 1, 1)
    end
    
    if charges < maxCharges and chargeStart > 0 then
        frame.cooldown:SetCooldown(chargeStart, chargeDuration)
        frame.brStart, frame.brDuration, frame.brLastSec = chargeStart, chargeDuration, nil
        frame:SetScript("OnUpdate", BattleResOnUpdate)
    else
        frame.cooldown:SetCooldown(0, 0)
        frame.timer:SetText("")
        frame.brLastSec = nil
        frame:SetScript("OnUpdate", nil)
    end
    
    frame:Show()
end

frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_DISABLED" or event == "ENCOUNTER_START" then
        UpdateCharges()
    elseif event == "PLAYER_REGEN_ENABLED" or event == "ENCOUNTER_END" then
        -- Keep visible for 10 seconds after combat then hide if not in a group
        C_Timer.After(10, function()
            if not InCombatLockdown() then
                UpdateCharges() -- Re-check if we should still be showing
            end
        end)
    elseif event == "SPELL_UPDATE_CHARGES" then
        UpdateCharges()
    end
end)

-- Global bridge to resize the tracker icon from the config slider.
function DUI_UpdateBattleResSize()
    db = DanUIDB.RaidTools
    local size = (db and db.battleResSize) or DEFAULT_BR_SIZE
    frame:SetSize(size, size)
end

-- Global bridge function called by RaidToolsModule and DanUI.lua
function ToggleBRTracker(enabled)
    DUI_UpdateBattleResSize()
    db = DanUIDB.RaidTools
    if enabled == "TEST" then
        -- Manual toggle for positioning
        frame.isTesting = true
        frame.brCharges = nil -- UpdateCharges' repaint cache no longer matches the text
        frame.text:SetText("3")
        frame:Show()
    elseif enabled then
        frame.isTesting = false
        frame.brEnabled = true
        -- Charge tracking only needs SPELL_UPDATE_CHARGES. SPELL_UPDATE_COOLDOWN
        -- fires on nearly every GCD in combat and would rebuild the frame each time.
        frame:RegisterEvent("SPELL_UPDATE_CHARGES")
        frame:RegisterEvent("PLAYER_REGEN_DISABLED")
        frame:RegisterEvent("PLAYER_REGEN_ENABLED")
        frame:RegisterEvent("ENCOUNTER_START")
        frame:RegisterEvent("ENCOUNTER_END")
        
        -- Force update to check if we should show immediately
        UpdateCharges()
    else
        frame.isTesting = false
        frame.brEnabled = false
        frame:UnregisterAllEvents()
        frame:SetScript("OnUpdate", nil)
        frame:Hide()
    end
end