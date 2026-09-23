-- Automation.lua
-- The prompts the client puts in front of you that you always answer the same
-- way, answered for you -- and the one you never mean to answer, made harder to
-- hit by accident:
--   * a repair-capable merchant  -> repair all (guild funds first if allowed) and
--                                   sell every grey
--   * a summon confirmation      -> accept it
--   * a resurrection offer       -> accept it
--   * the death popup            -> Release Spirit becomes press-and-hold
--
-- Was AutoRepair.lua, which only carried the merchant half. The saved table moved
-- with the rename, from DanUIDB.AutoRepair to DanUIDB.Automation; MigrateDB below
-- carries existing merchant settings across.

local db -- Local reference to DanUIDB.Automation

local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetContainerItemInfo = C_Container.GetContainerItemInfo
local UseContainerItem = C_Container.UseContainerItem
local Coin = C_CurrencyInfo.GetCoinTextureString
local ResurrectHasSickness = ResurrectHasSickness
local UnitAffectingCombat, UnitExists = UnitAffectingCombat, UnitExists
local IsEncounterInProgress, GetNumGroupMembers = IsEncounterInProgress, GetNumGroupMembers

function DUI_GetAutomationDefaults()
    return {
        enabled = true,
        -- Merchant. `merchantEnabled` is the old top-level `enabled`: it gates the
        -- whole merchant pass, selling included, which is what that flag meant back
        -- when the module was only this section.
        merchantEnabled = true,
        useGuildFunds = true,
        sellGreys = true,
        -- Summons
        acceptSummon = true,
        summonNotInCombat = true,
        -- Resurrection
        -- Always skips a battle res mid-fight and a sickened offer; both used to be
        -- ticks (resurrectNotInCombat / resurrectSkipSickness) and were made
        -- unconditional on 2026-09-22. DUI_InitAutomation clears the old keys.
        acceptResurrect = true,
        -- Release
        holdRelease = true,
        holdReleaseTime = 1.0,
    }
end

-- The module used to be AutoRepair and its top-level `enabled` meant "repair at a
-- merchant". It is the module's master switch now -- it has three unrelated
-- features under it -- so the merchant half takes that value and the master comes
-- on. Someone who had auto repair switched off keeps it off, and gains the summon
-- and release features rather than inheriting a module that is silently dead.
-- Delete this once no live install still has DanUIDB.AutoRepair.
local function MigrateDB()
    local old = DanUIDB.AutoRepair
    if old and not DanUIDB.Automation then
        DanUIDB.Automation = old
        old.merchantEnabled = old.enabled
        old.enabled = true
    end
    DanUIDB.AutoRepair = nil

    local pos = DanUIDB.ConfigPos
    if pos and pos.DUI_AutoRepairConfig then
        pos.DUI_AutomationConfig = pos.DUI_AutomationConfig or pos.DUI_AutoRepairConfig
        pos.DUI_AutoRepairConfig = nil
    end
end

-- ---- merchant ------------------------------------------------------------

local function DoRepair()
    local cost, canRepair = GetRepairAllCost()
    if not canRepair or cost <= 0 then return end

    if db.useGuildFunds and IsInGuild() and CanGuildBankRepair() then
        local withdraw = GetGuildBankWithdrawMoney()
        if withdraw == -1 or withdraw >= cost then
            RepairAllItems(true)
            -- GetGuildInfo can come back nil for a beat after login even with
            -- IsInGuild() true (the roster has not arrived yet), so the name is
            -- only worth reading here, and still needs a fallback.
            local guildName = GetGuildInfo("player")
            print("|cFF00FF00[DUI]|r Repaired with that sweet "
                .. (guildName or "guild") .. " money (" .. Coin(cost) .. ").")
            return
        end
    end

    if GetMoney() >= cost then
        RepairAllItems(false)
        print("|cFF00FF00[DUI]|r Repaired for " .. Coin(cost) .. ".")
    else
        print("|cFF00FF00[DUI]|r Not enough money to repair (" .. Coin(cost) .. ").")
    end
end

local function DoSellGreys()
    local total = 0
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            local info = GetContainerItemInfo(bag, slot)
            if info and info.quality == 0 and not info.hasNoValue then
                local sellPrice = select(11, C_Item.GetItemInfo(info.hyperlink)) or 0
                total = total + sellPrice * (info.stackCount or 1)
                UseContainerItem(bag, slot)
            end
        end
    end
    if total > 0 then
        print("|cFF00FF00[DUI]|r Sold grey items for " .. Coin(total) .. ".")
    end
end

-- ---- summons -------------------------------------------------------------

-- C_SummonInfo.ConfirmSummon() is not protected, so accepting from addon code
-- behaves exactly like clicking the popup -- but confirming does not dismiss the
-- popup, so it has to be hidden by hand or it sits there with a dead button.
local function AcceptSummon()
    if not db or not db.enabled or not db.acceptSummon then return end
    -- UnitAffectingCombat, not InCombatLockdown: the question is "are you in a
    -- fight", not "is the client refusing secure calls". ConfirmSummon is not a
    -- secure call, so the lockdown state has nothing to say about it.
    if db.summonNotInCombat and UnitAffectingCombat("player") then return end

    local summoner = C_SummonInfo.GetSummonConfirmSummoner()
    local area = C_SummonInfo.GetSummonConfirmAreaName()
    C_SummonInfo.ConfirmSummon()
    StaticPopup_Hide("CONFIRM_SUMMON")
    print("|cFF00FF00[DUI]|r Accepted summon from " .. (summoner or "?")
        .. " (" .. (area or "?") .. ").")
end

-- ---- resurrection --------------------------------------------------------

-- Which of the three the client raises depends on ResurrectHasTimer /
-- ResurrectHasSickness, and like the summon confirm, accepting does not take the
-- popup down with it. Hiding all three is cheaper than working out which is up.
local RESURRECT_POPUPS = { "RESURRECT", "RESURRECT_NO_SICKNESS", "RESURRECT_NO_TIMER" }

-- "Am I being battle-ressed mid-pull?" cannot be answered with
-- UnitAffectingCombat("player"), the way the summon section asks it: a dead player
-- has already dropped combat, so the player's own flag reads false for exactly the
-- case this gate exists to catch. The fight a battle res belongs to is the *group's*,
-- so ask the group -- an encounter in progress covers bosses, and a roster scan
-- covers trash, M+ and the open world.
--
-- The scan is up to 40 UnitAffectingCombat calls, but only ever on a resurrect
-- offer, which is about as rare an event as this addon handles.
local function GroupInCombat()
    if IsEncounterInProgress() then return true end
    if UnitAffectingCombat("player") then return true end

    local numMembers = GetNumGroupMembers()
    for i = 1, numMembers do
        local unit = GetUnitID(i, numMembers)
        -- A dead member's combat flag is already false, so they cost a call and
        -- answer no on their own; no need to test for it separately.
        if UnitExists(unit) and UnitAffectingCombat(unit) then return true end
    end
    return false
end

-- The offerer's name comes from the event payload rather than ResurrectGetOfferer()
-- so this is one call shorter and cannot disagree with the popup that is showing.
local function DoAcceptResurrect(offerer)
    if not db or not db.enabled or not db.acceptResurrect then return end
    if GroupInCombat() then return end
    -- The one offer worth reading before taking is a sickened one -- accepting locks
    -- in ten minutes of it when running back or waiting for a real res costs less.
    -- Nil-guarded because nothing else in the install calls it and there is no way
    -- to verify the global short of a /reload.
    if ResurrectHasSickness and ResurrectHasSickness() then
        return
    end

    AcceptResurrect()
    for i = 1, #RESURRECT_POPUPS do StaticPopup_Hide(RESURRECT_POPUPS[i]) end
    print("|cFF00FF00[DUI]|r Accepted resurrection from " .. (offerer or "?") .. ".")
end

-- ---- hold to release -----------------------------------------------------

-- The death popup's first button is Release Spirit, and it sits exactly where a
-- dozen harmless popups put "Accept". Answering it by reflex mid-wipe costs a
-- corpse run and throws away a battle res, so DUI covers that button with a
-- press-and-hold: a click does nothing at all, holding for holdReleaseTime
-- releases.
--
-- Blizzard's button is left completely alone -- nothing is disabled, rescripted
-- or reparented. An overlay frame with EnableMouse sits on top of it and eats the
-- click, and when the hold completes it calls StaticPopup_OnClick(dialog, 1),
-- which is the same path a real click takes. Soulstone and spectator release keep
-- working because the dialog's own OnAccept is what still runs, and switching the
-- feature off is one Hide().

local overlay, holdStart

local function CancelHold()
    holdStart = nil
    if overlay then overlay.fill:Hide() end
end

local function CreateOverlay()
    local f = CreateFrame("Frame", "DUI_HoldReleaseOverlay", UIParent, "BackdropTemplate")
    f:EnableMouse(true)
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    f:SetBackdropColor(0, 0, 0, 0.9)
    f:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(f, "border")

    -- Grows left to right as the hold runs. Its own SetAlpha is what keeps it a
    -- wash rather than a solid block: the accent registry owns the vertex colour
    -- and would overwrite any alpha baked into that.
    f.fill = f:CreateTexture(nil, "ARTWORK")
    f.fill:SetTexture("Interface\\Buttons\\WHITE8X8")
    f.fill:SetPoint("TOPLEFT", 1, -1)
    f.fill:SetPoint("BOTTOMLEFT", 1, 1)
    f.fill:SetVertexColor(unpack(DUI_Theme.Accent))
    f.fill:SetAlpha(0.35)
    f.fill:Hide()
    DUI_RegisterAccent(f.fill, "vertex")

    f.text = f:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    f.text:SetPoint("CENTER")
    f.text:SetText("Hold to Release")

    f:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        holdStart = GetTime()
        self.fill:SetWidth(1)
        self.fill:Show()
    end)

    f:SetScript("OnUpdate", function(self)
        local dialog = self.dialog
        -- The four StaticPopup frames are pooled, and one can be handed to another
        -- dialog while this overlay is still parked on it. Watching `which` catches
        -- every path that reuses a frame; hooking the ones that hide it does not.
        if not dialog or not dialog:IsShown() or dialog.which ~= "DEATH" then
            self:Hide()
            return
        end
        if not holdStart then return end
        -- A release button Blizzard has greyed out would ignore a real click, so the
        -- hold has nothing to fire either. Checked here rather than at attach time
        -- because the dialog enables and disables it as its own timer runs.
        if self.button and self.button.IsEnabled and not self.button:IsEnabled() then
            CancelHold()
            return
        end
        -- OnMouseUp only fires when the button comes up over this frame, so holding,
        -- dragging off and letting go there would otherwise leave the hold running.
        if not IsMouseButtonDown("LeftButton") then
            CancelHold()
            return
        end
        local pct = (GetTime() - holdStart) / math.max(db.holdReleaseTime or 1, 0.1)
        if pct >= 1 then
            CancelHold()
            self:Hide()
            StaticPopup_OnClick(dialog, 1)
            return
        end
        self.fill:SetWidth(math.max((self:GetWidth() - 2) * pct, 1))
    end)

    f:SetScript("OnLeave", CancelHold)
    f:SetScript("OnHide", CancelHold)
    return f
end

-- Parks the overlay on the visible death popup's release button. Safe to call at
-- any time: with no death popup on screen it does nothing, which is what lets the
-- config panel use it to re-arm the feature while you are already lying there.
--
-- Button 1 of the DEATH dialog is Release Spirit and stays that way -- a soulstone
-- or a self-res option fills in button 2, it does not displace the release -- so
-- the index is safe to hardcode. It is the same index Blizzard's own auto-release
-- path clicks when the popup's timer runs out.
local function AttachOverlay()
    if not db or not db.enabled or not db.holdRelease then return end
    local name = StaticPopup_Visible("DEATH")
    local dialog = name and _G[name]
    local button = dialog and (dialog.button1 or _G[name .. "Button1"])
    if not button then return end

    overlay = overlay or CreateOverlay()
    overlay.dialog = dialog
    overlay.button = button
    -- SetParent resets strata to inherited, so both of these have to follow it.
    overlay:SetParent(dialog)
    overlay:SetFrameStrata(dialog:GetFrameStrata())
    overlay:SetFrameLevel(button:GetFrameLevel() + 5)
    overlay:ClearAllPoints()
    overlay:SetAllPoints(button)
    CancelHold()
    overlay:Show()
end

-- StaticPopup_Show is the only entry point that puts the death dialog on screen,
-- including the one you get for logging in dead. Hooked at file scope rather than
-- from the init so a death before ADDON_LOADED finishes still gets the overlay;
-- the db guard inside AttachOverlay covers the window where there is no db yet.
hooksecurefunc("StaticPopup_Show", function(which)
    if which == "DEATH" then AttachOverlay() end
end)

-- ---- events --------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if not db or not db.enabled then return end
    if event == "MERCHANT_SHOW" then
        if not db.merchantEnabled then return end
        DoRepair()
        if db.sellGreys then DoSellGreys() end
    elseif event == "CONFIRM_SUMMON" then
        AcceptSummon()
    elseif event == "RESURRECT_REQUEST" then
        DoAcceptResurrect(arg1)
    end
end)

function DUI_InitAutomation()
    MigrateDB()
    db = DUI_InitModuleDB("Automation", DUI_GetAutomationDefaults)
    -- Nothing reads these any more; see the defaults.
    db.resurrectNotInCombat = nil
    db.resurrectSkipSickness = nil
    -- All three events are rare, so a single always-on registration (gated on db
    -- inside the handler) is cheaper than churning registration on every toggle.
    eventFrame:RegisterEvent("MERCHANT_SHOW")
    eventFrame:RegisterEvent("CONFIRM_SUMMON")
    eventFrame:RegisterEvent("RESURRECT_REQUEST")
end

-- The module's apply pass. Only the release overlay has state that outlives an
-- event -- the other two sections are read fresh each time they fire -- so this
-- puts it on or takes it off to match the current settings.
function DUI_AutomationApplyEnabled()
    db = DUI_InitModuleDB("Automation", DUI_GetAutomationDefaults)
    if db.enabled and db.holdRelease then
        AttachOverlay()
    elseif overlay then
        overlay:Hide()
    end
end

-- Configuration UI
local config = DUI_CreateConfigFrame("DUI_AutomationConfig", "Automation", 320, 400, "DUI_AutomationBtn")

function DUI_OpenAutomationConfig()
    db = DUI_InitModuleDB("Automation", DUI_GetAutomationDefaults)

    if not config.init then
        local L = DUI_CreateLayout(config)

        L:Header("At a Merchant")
        config.merchantCheck = L:Checkbox("Enable auto repair / sell", db, "merchantEnabled", nil,
            "Repairs your gear the moment you open a merchant that can repair, with no confirmation.")
        config.guildCheck = L:Checkbox("Use guild funds first", db, "useGuildFunds", nil,
            { body = "Pays from the guild bank's repair allowance when you have one, falling back to your own gold.",
              note = "Nothing happens if your rank has no repair permission." })
        config.sellCheck = L:Checkbox("Sell grey (junk) items", db, "sellGreys", nil,
            "Sells every poor-quality item in your bags at the same time.")
        L:Text("Runs automatically whenever you open a repair-capable merchant.")

        L:Header("Summons")
        config.summonCheck = L:Checkbox("Accept summons automatically", db, "acceptSummon", nil,
            { body = "Confirms a summon the moment it arrives and closes the popup, so a meeting stone or warlock pulls you straight through.",
              note = "The summon still has to be accepted within the usual two minutes." })
        config.summonCombatCheck = L:Checkbox("Not while in combat", db, "summonNotInCombat", nil,
            "Leaves the popup alone if you are in a fight, so nothing yanks you out of one. Click it yourself, or step out of combat and take the next summon.")

        L:Header("Resurrection")
        config.resCheck = L:Checkbox("Accept resurrections automatically", db, "acceptResurrect", nil,
            { body = "Takes a resurrection offered to you the moment it arrives and closes the popup.",
              note = "Never while the group is fighting (a battle res is yours to take), and never one that would give you resurrection sickness." })

        L:Header("Release Spirit")
        config.holdCheck = L:Checkbox("Hold the release button", db, "holdRelease",
            DUI_AutomationApplyEnabled,
            { body = "Covers Release Spirit on the death popup with a hold-to-confirm button. A click does nothing; holding it releases.",
              note = "The popup's own release timer is unaffected -- it still releases you on its own when it runs out." })
        config.holdSlider = L:Slider("DUI_AutomationHoldSlider", "Hold time", 0.3, 3.0, 0.1,
            db, "holdReleaseTime", nil,
            { fmt = "%.1fs", value = db.holdReleaseTime,
              tooltip = "How long the release button has to be held down before it fires." })

        L:FitHeight()

        config.init = true
    end
    config.merchantCheck:SetChecked(db.merchantEnabled)
    config.guildCheck:SetChecked(db.useGuildFunds)
    config.sellCheck:SetChecked(db.sellGreys)
    config.summonCheck:SetChecked(db.acceptSummon)
    config.summonCombatCheck:SetChecked(db.summonNotInCombat)
    config.resCheck:SetChecked(db.acceptResurrect)
    config.holdCheck:SetChecked(db.holdRelease)
    config.holdSlider:SetValue(db.holdReleaseTime)
    config:Show()
end
