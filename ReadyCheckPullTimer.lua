-- ReadyCheckPullTimer.lua
-- Logic for skinning the Ready Check prompt and auto-starting pull timers.

local db
local overlay
local ReadyFrame = CreateFrame("Frame")
local responses = {}

-- Layout constants. The window has two heights: compact when gear is fine, and one
-- row taller when the durability warning needs to appear.
-- 340 wide so the durability line still clears the repair button on its worst-case
-- string ("Durability 12% - 9 slots low") without clipping.
local WIN_W           = 340
local WIN_H_COMPACT   = 76
local WIN_H_FULL      = 100
local PAD             = 12
local BTN_H           = 24
local BTN_W           = (WIN_W - (PAD * 2) - 8) / 2
local HEADER_H        = 29
local DUR_ROW_H       = 18
local ICON_DURABILITY = "Interface\\Icons\\Ability_Repair"
local RC_DURATION     = 35
local DOT             = "\194\183" -- middle dot, kept as a UTF-8 escape

-- Auto-Hammer: the placeable repair bot, used straight out of the bags.
local REPAIR_ITEM_ID  = 132514
local REPAIR_BTN_W    = 80

function DUI_GetReadyCheckPullTimerDefaults()
    return {
        enabled = true,
        autoPull = true,
        pullDuration = 15,
        minDurability = 80,
        autoNagWarlocks = true,
    }
end

-- A pull timer already on the clock, tracked so a ready check finishing can't stomp
-- one that was sent by hand mid-check (someone calls ready in voice, lead sends /pull,
-- then the last stragglers tick ready and the auto-pull restarts the countdown).
--
-- START_PLAYER_COUNTDOWN is the one signal that catches every source: DanUI's own
-- C_PartyInfo.DoCountdown, the floating Pull button's /pull, and BigWigs' and DBM's
-- pull timers all route through the client countdown, and BigWigs only fires its own
-- BigWigs_StartPull off the back of this event (BigWigs_Plugins/Pull.lua,
-- Blizz_StartCountdown). Listening here needs no boss mod loaded.
local pullEndTime = 0

-- The countdown length comes back as a secret value inside M+ and encounters, where
-- it cannot be read. The pull is still running, so hold the guard for the longest
-- countdown BigWigs will send rather than assuming there isn't one.
local MAX_PULL = 60

local function IsSecret(v)
    return issecretvalue and issecretvalue(v)
end

local function PullTimerActive()
    return pullEndTime > GetTime()
end

local function CheckLowDurability(threshold)
    threshold = threshold or (db and db.minDurability) or 80
    local numLowSlots, totalDurability, numSlotsWithDurability = 0, 0, 0

    for slot = 1, 17 do
        local current, maximum = GetInventoryItemDurability(slot)
        if current and maximum and maximum > 0 then
            local durabilityPercent = (current / maximum) * 100
            totalDurability = totalDurability + durabilityPercent
            numSlotsWithDurability = numSlotsWithDurability + 1
            if durabilityPercent < threshold then
                numLowSlots = numLowSlots + 1
            end
        end
    end

    local averageDurability = numSlotsWithDurability > 0 and (totalDurability / numSlotsWithDurability) or 100
    return numLowSlots > 0, numLowSlots, averageDurability
end

-- Responses are tracked by name in `responses`; the header reports how many of the
-- group have answered, so the window states progress instead of only asking.
local function CountReady()
    local numMembers = GetNumGroupMembers()
    if numMembers == 0 then return 0, 0 end
    local ready = 0
    for i = 1, numMembers do
        local name = UnitName(GetUnitID(i, numMembers))
        if name and responses[name] then ready = ready + 1 end
    end
    return ready, numMembers
end

-- Countdown colour ramp: accent while there is time, amber under a third, red in the
-- final stretch. Drives the fuse, the clock and the border pulse from one place.
local function FuseColor(pct)
    if pct >= 0.33 then
        return DUI_Theme.Accent[1], DUI_Theme.Accent[2], DUI_Theme.Accent[3]
    elseif pct >= 0.15 then
        return 1, 0.65, 0.1
    end
    return 0.9, 0.2, 0.2
end

local function DurabilityHex(pct, threshold)
    if pct >= threshold then return "ff7ac74f" end
    if pct >= threshold - 20 then return "ffffa500" end
    return "ffff4444"
end

local function SavePosition(self)
    local point, _, _, x, y = self:GetPoint()
    if point and db then db.pos = { point = point, x = x, y = y } end
end

local function RestorePosition(self)
    self:ClearAllPoints()
    local p = db and db.pos
    if p then
        self:SetPoint(p.point, UIParent, p.point, p.x, p.y)
    else
        self:SetPoint("TOP", UIParent, "TOP", 0, -240)
    end
end

-- Every hide except the one at PLAYER_REGEN_DISABLED goes through here. The window
-- parents the secure repair-bot button, which makes the window protected as well, and a
-- protected hide under the lockdown is blocked whatever the frame's current state -- so
-- the check happens before the call, not after. Nothing can leave the window visible in
-- combat: ShowOverlay refuses there, and PLAYER_REGEN_DISABLED hides it on the way in.
-- That one stays a direct call, because it fires just before the lockdown applies and is
-- the last moment the hide is allowed.
local function HideOverlay()
    if overlay and overlay:IsShown() and not InCombatLockdown() then
        overlay:Hide()
    end
end

-- Shows the durability row (and grows the window) only when gear actually needs
-- attention, so the usual case stays a compact two-line box.
local function SetDurabilityState(self, avg, numLow, threshold)
    local show = numLow > 0
    if show then
        self.durRow.text:SetFormattedText("|cff9a9a9aDurability|r |c%s%d%%|r  |cff5a5a5a%s|r  |cffff4444%d slot%s low|r",
            DurabilityHex(avg, threshold), avg, DOT, numLow, numLow == 1 and "" or "s")
    end
    -- durRow parents the repair-bot holder, so it sits in the secure button's ancestry
    -- and both of these are protected calls once the lockdown is on. The text above is
    -- not, so the readout keeps updating either way; the layout change is simply
    -- deferred, and the window is hidden at PLAYER_REGEN_DISABLED regardless.
    if self.durShown ~= show and not InCombatLockdown() then
        self.durShown = show
        self.durRow:SetShown(show)
        self:SetHeight(show and WIN_H_FULL or WIN_H_COMPACT)
    end
end

local function CreateReadyOverlay()
    if overlay then return overlay end

    overlay = CreateFrame("Frame", "DUI_ReadyCheckOverlay", UIParent, "BackdropTemplate")
    overlay:SetSize(WIN_W, WIN_H_COMPACT)
    overlay:SetFrameStrata("TOOLTIP")
    overlay:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        tile = false, edgeSize = 1,
    })
    overlay:SetBackdropColor(unpack(DUI_Theme.MainBG))
    overlay:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(overlay, "border")
    DUI_RegisterMainBG(overlay, "bg")
    DUI_AddDropShadow(overlay, 6, 0.35)

    -- Anchored to UIParent, not to Blizzard's ReadyCheckFrame (which this module
    -- hides), and draggable so a chosen spot survives a reload.
    overlay:SetMovable(true); overlay:EnableMouse(true); overlay:RegisterForDrag("LeftButton")
    overlay:SetClampedToScreen(true)
    overlay:SetScript("OnDragStart", overlay.StartMoving)
    overlay:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition(self) end)

    -- Header: dark strip, label and response count on the left, countdown as the
    -- hero number on the right.
    local strip = overlay:CreateTexture(nil, "BORDER")
    strip:SetTexture("Interface\\Buttons\\WHITE8X8")
    strip:SetVertexColor(0, 0, 0, 0.25)
    strip:SetPoint("TOPLEFT", 1, -1); strip:SetPoint("TOPRIGHT", -1, -1); strip:SetHeight(HEADER_H)

    local label = overlay:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    label:SetFont(DUI_FontPath, 11, "")
    label:SetPoint("LEFT", overlay, "TOPLEFT", PAD, -16)
    label:SetText("READY CHECK")
    label:SetTextColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(label, "text")

    overlay.countText = overlay:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    overlay.countText:SetFont(DUI_FontPath, 11, "")
    overlay.countText:SetPoint("LEFT", label, "RIGHT", 8, 0)

    overlay.timeText = overlay:CreateFontString(nil, "OVERLAY", "DUI_FontLarge")
    overlay.timeText:SetPoint("RIGHT", overlay, "TOPRIGHT", -PAD, -16)
    overlay.timeText:SetJustifyH("RIGHT")

    -- The countdown is a thin "fuse" flush under the header, doubling as the header
    -- divider. No text inside it -- the clock above carries that.
    local bar = CreateFrame("StatusBar", nil, overlay)
    bar:SetPoint("TOPLEFT", 1, -(HEADER_H + 1)); bar:SetPoint("TOPRIGHT", -1, -(HEADER_H + 1))
    bar:SetHeight(3)
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    bar:SetStatusBarColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(bar:GetStatusBarTexture(), "vertex")
    bar:SetMinMaxValues(0, RC_DURATION)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints(); track:SetColorTexture(0, 0, 0, 0.45)
    overlay.bar = bar

    -- Durability row: icon-led, left-aligned, hidden entirely when gear is fine.
    local durRow = CreateFrame("Frame", nil, overlay)
    durRow:SetPoint("TOPLEFT", PAD, -40); durRow:SetPoint("TOPRIGHT", -PAD, -40); durRow:SetHeight(DUR_ROW_H)
    local durIcon = durRow:CreateTexture(nil, "OVERLAY")
    durIcon:SetSize(14, 14); durIcon:SetPoint("LEFT", 0, 0)
    durIcon:SetTexture(ICON_DURABILITY); durIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- The repair bot lives in a plain holder frame. Toggling the holder is what shows
    -- and hides the button, because the button itself is secure (protected) and cannot
    -- be shown, hidden, moved or re-configured once combat starts.
    local repairHolder = CreateFrame("Frame", nil, durRow)
    repairHolder:SetSize(REPAIR_BTN_W, DUR_ROW_H); repairHolder:SetPoint("RIGHT", 0, 0)
    repairHolder:Hide()
    overlay.repairHolder = repairHolder

    durRow.text = durRow:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    durRow.text:SetPoint("LEFT", durIcon, "RIGHT", 6, 0)
    durRow.text:SetPoint("RIGHT", repairHolder, "LEFT", -8, 0)
    durRow.text:SetJustifyH("LEFT"); durRow.text:SetWordWrap(false)
    durRow:Hide()
    overlay.durRow = durRow
    overlay.durShown = false

    -- Secure because it uses an item. Every protected call on it (creation, attributes,
    -- anchoring) happens here, at load, and never again -- see DUI_InitReadyCheckPullTimer,
    -- which builds the window up front so this can't land mid-combat.
    local repairBtn = CreateFrame("Button", "DUI_ReadyCheckRepairButton", repairHolder,
        "SecureActionButtonTemplate, BackdropTemplate")
    repairBtn:SetAllPoints(repairHolder)
    StyleAsTealTab(repairBtn)
    repairBtn:SetAttribute("type", "macro")
    repairBtn:SetAttribute("macrotext1", "/use item:" .. REPAIR_ITEM_ID)
    repairBtn:RegisterForClicks("AnyUp", "AnyDown")

    local repairIcon = repairBtn:CreateTexture(nil, "ARTWORK")
    repairIcon:SetSize(12, 12); repairIcon:SetPoint("LEFT", 4, 0)
    repairIcon:SetTexture(C_Item.GetItemIconByID(REPAIR_ITEM_ID) or ICON_DURABILITY)
    repairIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    repairBtn.label = repairBtn:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    repairBtn.label:SetPoint("LEFT", repairIcon, "RIGHT", 4, 0)
    repairBtn.label:SetText("Repair Bot")

    -- Cooldown swipe, so a bot still on cooldown reads as unavailable rather than broken.
    repairBtn.cd = CreateFrame("Cooldown", nil, repairBtn, "CooldownFrameTemplate")
    repairBtn.cd:SetAllPoints(repairBtn)
    repairBtn.cd:SetDrawEdge(false)
    repairBtn.cd:SetHideCountdownNumbers(true)

    -- The window sits in the TOOLTIP strata, so GameTooltip needs lifting above it.
    repairBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetFrameStrata("TOOLTIP")
        GameTooltip:SetFrameLevel(overlay:GetFrameLevel() + 50)
        GameTooltip:SetItemByID(REPAIR_ITEM_ID)
        GameTooltip:Show()
    end)
    repairBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    overlay.repairBtn = repairBtn

    -- The window is built at login so the secure button's protected setup can't land
    -- mid-combat, but CreateFrame hands back a *shown* frame -- park it off screen
    -- until an actual ready check (or a preview) calls ShowOverlay.
    RestorePosition(overlay)
    overlay:Hide()

    -- Split full-width. Ready is the primary action (accent fill); Not Ready reads as
    -- the destructive one, so the two are never confused at a glance.
    overlay.readyBtn = CreateFrame("Button", nil, overlay, "BackdropTemplate")
    overlay.readyBtn:SetSize(BTN_W, BTN_H)
    overlay.readyBtn:SetPoint("BOTTOMRIGHT", -PAD, 10)
    StyleAsTealTab(overlay.readyBtn)
    -- Accent-filled, not button-colored: StyleAsTealTab enrolled it in the
    -- button-color registry, and it belongs to the accent one instead.
    DUI_ExemptSecondary(overlay.readyBtn)
    overlay.readyBtn:SetBackdropColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(overlay.readyBtn, "bg")
    overlay.readyBtn:SetText("Ready")
    if overlay.readyBtn:GetFontString() then overlay.readyBtn:GetFontString():SetTextColor(1, 1, 1) end
    -- Always dismiss, then pass the click through. Answering normally closes the window
    -- via READY_CHECK_CONFIRM, but that event never arrives for a preview or a stale
    -- window, and a prompt you can't dismiss is worse than one that closes early.
    overlay.readyBtn:SetScript("OnClick", function()
        if not overlay.preview and ReadyCheckFrameYesButton then ReadyCheckFrameYesButton:Click() end
        HideOverlay()
    end)

    overlay.notReadyBtn = CreateFrame("Button", nil, overlay, "BackdropTemplate")
    overlay.notReadyBtn:SetSize(BTN_W, BTN_H)
    overlay.notReadyBtn:SetPoint("BOTTOMLEFT", PAD, 10)
    StyleAsDangerButton(overlay.notReadyBtn)
    overlay.notReadyBtn:SetBackdropColor(0.45, 0.14, 0.14, 1)
    overlay.notReadyBtn:SetText("Not Ready")
    overlay.notReadyBtn:SetScript("OnClick", function()
        if not overlay.preview and ReadyCheckFrameNoButton then ReadyCheckFrameNoButton:Click() end
        HideOverlay()
    end)

    overlay:SetScript("OnUpdate", function(self, elapsed)
        local p = self.preview
        local total = (p and p.total) or RC_DURATION
        local remaining = self.endTime and math.max(self.endTime - GetTime(), 0) or 0
        local pct = total > 0 and (remaining / total) or 0
        local r, g, b = FuseColor(pct)

        self.bar:SetValue(remaining)
        self.bar:SetStatusBarColor(r, g, b)
        -- The readout is a tenth of a second, so it changes 10x a second while this
        -- runs every frame. Skipping the format and the FontString relayout on the
        -- frames in between is the same guard CombatTime and the castbar use.
        local tenths = math.floor(remaining * 10 + 0.5)
        if tenths ~= self.shownTenths then
            self.shownTenths = tenths
            -- Formatted from the key, not from `remaining`, so the string cannot
            -- disagree with the key that gates it. See CastbarModule's OnUpdate.
            self.timeText:SetFormattedText("%.1fs", tenths / 10)
        end
        self.timeText:SetTextColor(r, g, b)

        -- Final-stretch pulse on the border, so a window sitting at the edge of the
        -- eye still gets noticed before the check expires.
        -- The resting accent border is only written on the way out of a pulse (or the
        -- first frame), not every frame. An accent change mid-check still lands via
        -- the next pulse ending, and the window is up for 35s at most.
        if remaining <= 5 then
            self:SetBackdropBorderColor(r, g, b, 0.55 + 0.45 * math.abs(math.sin(GetTime() * 4)))
            self.borderPulsing = true
        elseif self.borderPulsing ~= false then
            self.borderPulsing = false
            self:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
        end

        self.timer = (self.timer or 0) + elapsed
        if self.timer > 0.5 or self.dirty then
            self.timer, self.dirty = 0, nil
            local threshold = (db and db.minDurability) or 80

            local avg, numLow
            if p then
                avg, numLow = p.durability, p.lowSlots
            else
                local _, low, average = CheckLowDurability(threshold)
                avg, numLow = math.floor(average), low
            end
            SetDurabilityState(self, avg, numLow, threshold)

            -- Offer the repair bot only when gear is worn and one is actually carried.
            -- Toggling the holder rather than the secure button is what keeps this out
            -- of the button's own protection -- but the holder is still the button's
            -- *parent*, so it inherits the protection anyway and SetShown on it is
            -- blocked under the lockdown. The window is hidden at PLAYER_REGEN_DISABLED,
            -- yet this OnUpdate can still run in the frame combat starts, which is
            -- exactly where it threw ADDON_ACTION_BLOCKED. Only touched when the state
            -- actually changes, so a protected call is not made twice a second either.
            local hasBot
            if p then hasBot = p.repair else hasBot = (C_Item.GetItemCount(REPAIR_ITEM_ID) or 0) > 0 end
            local wantBot = (numLow > 0 and hasBot) and true or false
            if wantBot ~= self.repairHolder:IsShown() and not InCombatLockdown() then
                self.repairHolder:SetShown(wantBot)
            end
            if self.repairHolder:IsShown() then
                local start, duration = C_Item.GetItemCooldown(REPAIR_ITEM_ID)
                self.repairBtn.cd:SetCooldown(start or 0, duration or 0)
            end

            local ready, members
            if p then ready, members = p.ready, p.members else ready, members = CountReady() end
            if members > 0 then
                self.countText:SetFormattedText("|cff5a5a5a%s|r  |cff9a9a9a%d/%d ready|r", DOT, ready, members)
            else
                self.countText:SetText("")
            end
        end
    end)

    return overlay
end

-- Single entry point for putting the window on screen. `preset` is nil for a real
-- ready check and a table of stand-in values for the /duirctest previews.
-- Returns nil when it refused, so a caller can leave Blizzard's own prompt alone
-- rather than hiding it in favour of a window that never appeared.
local function ShowOverlay(preset)
    -- The window parents the secure repair-bot button, so Show and SetPoint on it are
    -- both protected once the lockdown is on -- the same reason it is hidden at
    -- PLAYER_REGEN_DISABLED. A check that arrives in combat cannot be answered through
    -- our overlay anyway, so this refuses instead of throwing ADDON_ACTION_BLOCKED.
    if InCombatLockdown() then return nil end

    local ov = CreateReadyOverlay()
    ov.preview = preset
    local total     = (preset and preset.total) or RC_DURATION
    local remaining = (preset and preset.time) or total
    ov.startTime = GetTime()
    ov.endTime   = ov.startTime + remaining
    ov.bar:SetMinMaxValues(0, total)
    ov.bar:SetValue(remaining)
    ov.shownTenths = nil
    ov.borderPulsing = nil -- repaint the resting border on the first frame
    ov.dirty = true
    RestorePosition(ov)
    ov:Show()
    UIFrameFadeIn(ov, 0.15, 0, 1)
    return ov
end

local function CheckEveryoneReady()
    local numMembers = GetNumGroupMembers()
    if numMembers == 0 then return true end

    for i = 1, numMembers do
        local unit = GetUnitID(i, numMembers)
        if UnitExists(unit) then
            local status = GetReadyCheckStatus(unit)
            if status ~= "ready" then
                return false
            end
        end
    end
    return true
end

local function StartAutoPull()
    print("|cFF00FF00[DUI]|r Attempting to start auto pull...")
    if not UnitIsGroupLeader("player") and not UnitIsGroupAssistant("player") then
        print("|cFF00FF00[DUI]|r Auto-pull aborted: You are not the Leader or Assistant.")
        return
    end
    -- Never restart a countdown that is already running: a pull sent by hand during
    -- the ready check is the deliberate one, and a second DoCountdown would replace it
    -- with a fresh (longer) timer the raid has already stopped listening for.
    if PullTimerActive() then
        print(string.format("|cFF00FF00[DUI]|r Everyone is ready, but a pull timer is already running (%.0fs left) - leaving it alone.",
            pullEndTime - GetTime()))
        return
    end
    -- The pull already happened: the countdown ran out into combat, or someone ninja
    -- pulled while the check was up. A new timer then is noise at best.
    if InCombatLockdown() or IsEncounterInProgress() then
        print("|cFF00FF00[DUI]|r Auto-pull aborted: combat has already started.")
        return
    end
    local duration = db.pullDuration or 15

    -- Use standard countdown API (supported by most boss mods and the game client)
    if C_PartyInfo and C_PartyInfo.DoCountdown then
        C_PartyInfo.DoCountdown(duration)
    else
        local editBox = ChatEdit_ChooseBoxForSend()
        editBox:SetText("/pull " .. duration)
        ChatEdit_SendText(editBox)
    end
    print("|cFF00FF00[DUI]|r Everyone is ready! Starting " .. duration .. "s pull timer.")
end

-- The master toggle drives registration rather than an early return in the handler,
-- so a disabled module is genuinely inert instead of merely quiet.
local readyCheckEventsOn = false

-- ---- Soulstone nag --------------------------------------------------------
-- A ready check is the moment the question "has every warlock put a stone out" is
-- actually being asked, so it is where the ready check window's Soulstone chip can be
-- pulled without anyone clicking it. The whispering lives in ReadyCheck.lua, next to
-- the scan that works out who is still owed one; this half only decides whether this
-- client is the one that should be sending anything.
--
-- Every client in the group sees READY_CHECK, and a whisper -- unlike a ready check or
-- a pull timer -- is not deduplicated by the server: ten raiders running DanUI with
-- this on would send the same warlock ten copies. It used to be settled by letting
-- only the player who *started* the check nag, which meant a check run by anyone
-- without DanUI (or with it off) whispered nobody.
--
-- Now every DanUI client with the setting on claims the job over an addon message the
-- moment the check goes out, and when the 2s delay below is up each one runs the same
-- election over the same claims: the initiator wins if they claimed, otherwise the
-- lowest Name-Realm. Every client reaches the same answer without a reply round, so
-- there is still exactly one sender.
local lastNag = 0
local NAG_COOLDOWN = 60
local NAG_DELAY = 2
local NAG_PREFIX = "DanUI"
local NAG_MSG = "NAG1:"      -- versioned so a later format can't be misread as this one
local CLAIM_WINDOW = 6       -- a claim older than this belongs to a previous ready check

local claims = {}            -- Name-Realm -> { t = GetTime(), init = bool }

-- A failed register only loses the election's input; the send below notices that and
-- falls back to the initiator rule, so this is not worth erroring over.
if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    pcall(C_ChatInfo.RegisterAddonMessagePrefix, NAG_PREFIX)
end

local function StartedByPlayer(initiator)
    if not initiator then return false end
    -- READY_CHECK hands back a plain name, and a group member's name is itself a valid
    -- unit token, so UnitIsUnit resolves that and a raid token alike. It answers nil
    -- rather than false for a name it can't place, which is what the fallback is for.
    local ok, isPlayer = pcall(UnitIsUnit, initiator, "player")
    if ok and isPlayer ~= nil then return isPlayer end
    return Ambiguate(initiator, "short") == UnitName("player")
end

-- CHAT_MSG_ADDON names the sender "Name-Realm", but a same-realm name can arrive bare
-- elsewhere; normalise both sides so the election compares like with like.
local function FullName(name)
    if not name or IsSecret(name) then return nil end
    if not strfind(name, "-", 1, true) then name = name .. "-" .. (GetNormalizedRealmName() or "") end
    return name
end

local function MyFullName() return FullName(UnitName("player")) end

-- Instance groups (LFR, a queued dungeon) talk on INSTANCE_CHAT, not RAID/PARTY.
local function GroupChannel()
    if IsInGroup(LE_PARTY_CATEGORY_HOME) then return IsInRaid() and "RAID" or "PARTY" end
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
end

-- Older clients returned a boolean; current ones return Enum.SendAddonMessageResult.
local function SendClaim(init)
    local channel = GroupChannel()
    if not channel or not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return false end
    local ok, res = pcall(C_ChatInfo.SendAddonMessage, NAG_PREFIX, NAG_MSG .. (init and "1" or "0"), channel)
    if not ok then return false end
    return res == nil or res == true or res == 0
end

local function OnClaim(text, sender)
    if IsSecret(text) or type(text) ~= "string" or strsub(text, 1, #NAG_MSG) ~= NAG_MSG then return end
    sender = FullName(sender)
    -- Our own claim is recorded locally when it is sent, so the echo is dropped rather
    -- than relied on: if it never arrived we would lose an election we had won.
    if not sender or sender == MyFullName() then return end
    claims[sender] = { t = GetTime(), init = strsub(text, #NAG_MSG + 1, #NAG_MSG + 1) == "1" }
end

-- The initiator first, then the lowest name. Deterministic over the same set, which is
-- the whole point: nobody has to be told they won.
local function ElectedSender()
    local now, best, bestInit = GetTime(), nil, false
    for name, c in pairs(claims) do
        if now - c.t <= CLAIM_WINDOW then
            if not best or (c.init and not bestInit) or (c.init == bestInit and name < best) then
                best, bestInit = name, c.init
            end
        end
    end
    return best
end

local function MaybeNagWarlocks(initiator)
    if not DUI_AutoNagWarlocks or not IsInGroup() then return end

    local init = StartedByPlayer(initiator)
    local me = MyFullName()
    if me then claims[me] = { t = GetTime(), init = init } end
    -- No working addon channel means no election, and guessing would let every client
    -- that can't talk whisper at once. Degrade to the old rule: the initiator alone.
    local commsOk = me and SendClaim(init)

    -- Held a beat rather than run on the event itself: the ready check window paints on
    -- this same event, a warlock already casting as the check goes out gets to finish,
    -- any /duirc preview on screen has been replaced by a live scan by the time this
    -- fires -- and the other clients' claims have had time to arrive.
    C_Timer.After(NAG_DELAY, function()
        if commsOk then
            if ElectedSender() ~= me then return end
        elseif not init then
            return
        end

        -- A second ready check right after the first ("are we ready *now*") is normal,
        -- and whispering the same warlock again twenty seconds later reads as nagging
        -- rather than reminding. Applied only by the elected sender, and after the
        -- election rather than before the claim: a throttled client that dropped out of
        -- the running would hand the job to the next name, who would whisper anyway.
        local now = GetTime()
        if now - lastNag < NAG_COOLDOWN then return end
        lastNag = now
        DUI_AutoNagWarlocks()
    end)
end

local function SetReadyCheckEventsRegistered(on)
    on = on and true or false
    if on == readyCheckEventsOn then return end
    readyCheckEventsOn = on
    if on then
        ReadyFrame:RegisterEvent("READY_CHECK")
        ReadyFrame:RegisterEvent("READY_CHECK_FINISHED")
        ReadyFrame:RegisterEvent("READY_CHECK_CONFIRM")
        -- Tracked only so auto-pull can tell whether a countdown is already running.
        ReadyFrame:RegisterEvent("START_PLAYER_COUNTDOWN")
        ReadyFrame:RegisterEvent("CANCEL_PLAYER_COUNTDOWN")
        -- Combat means the pull happened; a prompt still up is in the way.
        ReadyFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
        -- Other clients' claims on the Soulstone nag (see MaybeNagWarlocks).
        ReadyFrame:RegisterEvent("CHAT_MSG_ADDON")
    else
        ReadyFrame:UnregisterAllEvents()
        HideOverlay()
    end
end

-- Apply hook for the UI-tab master enable checkbox.
function DUI_ReadyCheckPullTimerApplyEnabled(enabled)
    if db then db.enabled = enabled and true or false end
    SetReadyCheckEventsRegistered(enabled)
end

ReadyFrame:SetScript("OnEvent", function(self, event, ...)
    if not db or not db.enabled then return end

    if event == "READY_CHECK" then
        local initiator = ...
        wipe(responses)
        if initiator then responses[initiator] = true end -- Initiator is ready by default

        -- Blizzard's prompt is only hidden when ours actually took its place; in
        -- combat it stays, so the check can still be answered.
        if ShowOverlay() and ReadyCheckFrame then ReadyCheckFrame:Hide() end

        if db.autoNagWarlocks then MaybeNagWarlocks(initiator) end

    elseif event == "READY_CHECK_FINISHED" then
        HideOverlay()

        if db.autoPull then
            local allReady = true
            local numMembers = GetNumGroupMembers()
            for i = 1, numMembers do
                local unit = GetUnitID(i, numMembers)
                local name = UnitName(unit)
                if name and not responses[name] then
                    allReady = false
                    break
                end
            end

            if allReady then
                StartAutoPull()
            else
                print("|cFF00FF00[DUI]|r Ready check finished, but not everyone was ready.")
            end
        end

    elseif event == "READY_CHECK_CONFIRM" then
        local unit, isReady = ...
        local name = UnitName(unit)
        if name then
            responses[name] = isReady
        end
        if UnitIsUnit(unit, "player") then
            HideOverlay()
        end

    elseif event == "START_PLAYER_COUNTDOWN" then
        local _, timeRemaining = ...
        local timeleft = (not IsSecret(timeRemaining)) and tonumber(timeRemaining) or nil
        pullEndTime = GetTime() + (timeleft or MAX_PULL)

    elseif event == "CANCEL_PLAYER_COUNTDOWN" then
        -- Fires for an explicit /pull 0 and when combat cuts the countdown short.
        pullEndTime = 0

    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Hidden here, not on a later combat check: the window parents the secure
        -- repair-bot button, which makes it protected too, and PLAYER_REGEN_DISABLED
        -- fires just *before* lockdown starts -- the last moment Hide is still allowed.
        -- Blizzard's prompt goes with it, so its OnShow hook can't bring ours back.
        if overlay then overlay:Hide() end
        if ReadyCheckFrame and ReadyCheckFrame:IsShown() then ReadyCheckFrame:Hide() end

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, text, _, sender = ...
        if prefix == NAG_PREFIX then OnClaim(text, sender) end
    end
end)

function DUI_InitReadyCheckPullTimer()
    db = DUI_InitModuleDB("ReadyCheckPullTimer", DUI_GetReadyCheckPullTimerDefaults)

    -- autoNagWarlocks shipped off for one build on 2026-09-15 and the reload that
    -- picked up the default flip persists that false *before* the new default is read,
    -- so DUI_InitModuleDB's nil-only backfill would never reach an install that had
    -- seen the first version. One-shot, and safe only because the off state it
    -- overwrites was never chosen by anyone -- the setting was hours old.
    -- Delete this block once no live DanUIDB is missing autoNagWarlocksDefaulted.
    if not db.autoNagWarlocksDefaulted then
        db.autoNagWarlocksDefaulted = true
        db.autoNagWarlocks = true
    end

    -- CHAT_MSG_SYSTEM used to be registered here with no branch to handle it, so
    -- every system message in the game woke this handler for nothing.
    SetReadyCheckEventsRegistered(db.enabled)

    -- Built now rather than on the first ready check: the window owns a secure button
    -- for the repair bot, and creating it (or setting its attributes) is a protected
    -- action that would be blocked if the first check arrived mid-pull.
    CreateReadyOverlay()

    -- Hook Blizzard's frame to ensure ours shows when it does. READY_CHECK usually
    -- gets there first, so only open a window that isn't already up -- otherwise the
    -- hook would restart the countdown a frame after the event started it.
    if ReadyCheckFrame then
        ReadyCheckFrame:HookScript("OnShow", function()
            if db and db.enabled then
                local shown = (overlay and overlay:IsShown()) or ShowOverlay()
                if shown then ReadyCheckFrame:Hide() end
            end
        end)
    end
end

-- Preview presets for /duirctest: each one renders the window in a state that is
-- otherwise awkward to reproduce on demand (worn gear, a nearly-expired timer).
local PREVIEWS = {
    ready    = { desc = "healthy gear, plenty of time",  total = 35, time = 34.3, durability = 100, lowSlots = 0, ready = 18, members = 20, repair = true },
    low      = { desc = "low durability, bot in bags",   total = 35, time = 22.0, durability = 64,  lowSlots = 3, ready = 12, members = 20, repair = true },
    norepair = { desc = "low durability, no bot carried",total = 35, time = 22.0, durability = 64,  lowSlots = 3, ready = 12, members = 20, repair = false },
    warn     = { desc = "amber timer, one worn slot",    total = 35, time = 9.0,  durability = 78,  lowSlots = 1, ready = 17, members = 20, repair = true },
    critical = { desc = "final seconds, gear wrecked",   total = 35, time = 4.5,  durability = 12,  lowSlots = 9, ready = 19, members = 20, repair = true },
    solo     = { desc = "no group, nothing to report",   total = 35, time = 30.0, durability = 100, lowSlots = 0, ready = 0,  members = 0,  repair = true },
}
local PREVIEW_ORDER = { "ready", "low", "norepair", "warn", "critical", "solo" }
local previewIndex = 0

function DUI_PreviewReadyCheck(arg)
    local name = strlower(strtrim(arg or ""))

    if name == "off" or name == "hide" then
        if overlay then overlay.preview = nil; HideOverlay() end
        return
    end

    if name == "next" or name == "cycle" then
        previewIndex = (previewIndex % #PREVIEW_ORDER) + 1
        name = PREVIEW_ORDER[previewIndex]
    end

    local preset = PREVIEWS[name]
    if not preset then
        print("|cFF00FF00[DUI]|r Ready check preview - usage: /duirctest <state>")
        for i, key in ipairs(PREVIEW_ORDER) do
            print(string.format("  |cff9a9a9a%d.|r |cffffffff%s|r - %s", i, key, PREVIEWS[key].desc))
        end
        print("  |cffffffffnext|r - step through the list, |cffffffffoff|r - close the preview")
        return
    end

    -- The preview can run before the module has initialised (e.g. straight after a
    -- reload), so make sure settings exist before reading the durability threshold.
    db = db or DUI_InitModuleDB("ReadyCheckPullTimer", DUI_GetReadyCheckPullTimerDefaults)
    if not ShowOverlay(preset) then
        -- Says which gate stopped it rather than printing a preview line for a window
        -- that is not on screen.
        print("|cFF00FF00[DUI]|r Preview unavailable in combat - the window parents a secure button and cannot be shown under the lockdown.")
        return
    end
    print(string.format("|cFF00FF00[DUI]|r Preview: |cffffffff%s|r (%s). Drag to reposition; /duirctest off to close.", name, preset.desc))
end

SLASH_DUIRCTEST1 = "/duirctest"
SlashCmdList["DUIRCTEST"] = DUI_PreviewReadyCheck

-- /duinag - why did (or didn't) the last ready check whisper anyone. Reports this
-- file's gates, then hands off to the scan's own dry run. Nothing is ever sent.
-- `/duinag on|off` flips the setting, which is quicker than opening the panel and is
-- the way out if a stale off ever survives the migration in DUI_InitReadyCheckPullTimer.
SLASH_DUINAG1 = "/duinag"
SlashCmdList["DUINAG"] = function(msg)
    db = db or DUI_InitModuleDB("ReadyCheckPullTimer", DUI_GetReadyCheckPullTimerDefaults)
    local arg = strlower(strtrim(msg or ""))

    if arg == "on" or arg == "off" then
        db.autoNagWarlocks = (arg == "on")
        print("|cFF00FF00[DUI]|r Soulstone nag on ready check: " ..
            (db.autoNagWarlocks and "|cff00FF00on|r" or "|cffFFA500off|r"))
        return
    end

    print("|cFF00FF00[DUI]|r Soulstone nag - |cffffffff/duinag on|r or |cffffffff/duinag off|r to switch it.")
    print("  RC & Pull module: " .. (db.enabled and "|cff00FF00enabled|r" or "|cffFFA500disabled|r - the nag rides this flag"))
    print("  Whisper on ready check: " .. (db.autoNagWarlocks and "|cff00FF00on|r" or "|cffFFA500off|r"))
    print("  In a group: " .. (IsInGroup() and "|cff00FF00yes|r" or "|cffFFA500no|r"))
    local wait = NAG_COOLDOWN - (GetTime() - lastNag)
    if lastNag > 0 and wait > 0 then
        print(string.format("  Throttle: |cffFFA500%ds left|r before another ready check would whisper", math.ceil(wait)))
    end
    print("  |cff9a9a9aAny ready check counts. One DanUI client sends: whoever started it if they run DanUI with this on, otherwise the first by name.|r")

    if DUI_ReportWarlockNag then DUI_ReportWarlockNag() end
end

local config = DUI_CreateConfigFrame("DUI_RCPTConfig", "Ready Check & Pull", 320, 250, "DUI_RCPTBtn")

function DUI_OpenReadyCheckPullTimerConfig()
    db = DUI_InitModuleDB("ReadyCheckPullTimer", DUI_GetReadyCheckPullTimerDefaults)

    if not config.init then
        local L = DUI_CreateLayout(config)
        L:Header("Module Settings")
        L:Checkbox("Auto Pull on Ready", db, "autoPull",  nil,
            { body = "Starts a pull timer automatically once everyone has answered the ready check.",
              note = "Only fires when every member answered ready, and never while a pull timer is already counting down." })

        L:Checkbox("Whisper Unstoned Warlocks", db, "autoNagWarlocks", nil,
            { body = "When a ready check starts, whispers every warlock who has not put a Soulstone out yet.",
              note = "Sends real whispers with no confirmation. Works on anyone's ready check; when several people run DanUI only one of them whispers (whoever started the check, else the first by name). At most once a minute, and stays quiet if Soulstone buffs can't be read at that moment rather than guessing. Works in raid instances - it reads the same data as the Soulstone column on the ready check window. /duinag reports what it would do without sending anything." })

        L:Slider("DUI_RCPT_Duration", "Pull Duration", 5, 30, 1, db, "pullDuration", nil,
            { fmt = "%ds", value = db.pullDuration, tooltip = "Length of the pull timer started by Auto Pull." })

        L:Slider("DUI_RCPT_DurThreshold", "Durability Warning", 10, 100, 5, db, "minDurability", nil,
            { fmt = "%d%%", value = db.minDurability,
              tooltip = "Gear at or below this durability is called out on the ready check window." })

        L:Gap()
        L:Text("Replaces Blizzard's ready check popup with a compact window showing the countdown, who has answered, and any low-durability gear.")

        L:FitHeight()
        config.init = true
    end
    config:Show()
end
