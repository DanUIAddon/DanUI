-- CombatAlerts.lua
-- Combat-related sound alerts. Two independent alerts share this module because
-- they are the same thing from the user's side -- "play a sound when X happens in
-- a fight" -- and were previously two panels a settings apart:
--   * BigWigs pull countdown, a last call before the pull
--   * a group member dying (ported from DeathNotification)

local LSM = LibStub:GetLibrary("LibSharedMedia-3.0")
local db -- Local reference to DanUIDB.CombatAlerts

-- Localized for the death watch: OnUnitUpdate runs on every UNIT_HEALTH, which in
-- a full raid is one of the busiest events the client fires.
local UnitIsDeadOrGhost, UnitIsFeignDeath = UnitIsDeadOrGhost, UnitIsFeignDeath
local GetTime, IsInGroup, IsInRaid = GetTime, IsInGroup, IsInRaid
local GetNumGroupMembers = GetNumGroupMembers

local pullEndTime = 0
local alertFired = false -- the trigger point has been passed for this countdown

local deadCache = {}
local nextDeathSoundAt = 0

-- Forward declaration: the init/apply pass below flips the death watch's events on
-- and off, and the function that does it is defined further down.
local SetDeathEventsRegistered

function DUI_GetCombatAlertsDefaults()
    return {
        enabled = true,
        -- BigWigs pull countdown
        pullTimerAlert = true,
        pullTimerValue = 12,
        pullTimerSound = "None",
        -- ...and the icon that can flash alongside it, at the same trigger point.
        pullTimerIcon = false,
        pullTimerIconInput = "",    -- spell name, spell ID, icon file ID, or texture path
        pullTimerIconSize = 128,
        pullTimerIconZoom = 0,      -- % of the texture cropped away, half off each edge
        pullTimerIconFlash = 0.35,  -- seconds per half-cycle of the pulse
        pullTimerIconStopOnCast = true,
        pullTimerIconPoint = "CENTER",
        pullTimerIconRelPoint = "CENTER",
        pullTimerIconX = 0,
        pullTimerIconY = 0,
        -- Group member death
        deathAlert = true,
        deathSound = "Quest Failed",
        deathThrottle = 0.5,
    }
end

local frame = CreateFrame("Frame")

-- ---------------------------------------------------------------------------
-- Pull timer icon
-- ---------------------------------------------------------------------------
-- The icon is a second face on the same alert, not a module of its own: it is shown
-- at the identical trigger point as the sound, for someone who wants the last call
-- in the middle of the screen as well as in their ears.

local pullIcon = CreateFrame("Frame", "DUI_PullAlertIcon", UIParent, "BackdropTemplate")
pullIcon:SetSize(128, 128)
pullIcon:SetPoint("CENTER")
pullIcon:SetFrameStrata("HIGH")
pullIcon:SetMovable(true)
pullIcon:SetClampedToScreen(true)
pullIcon:RegisterForDrag("LeftButton")
pullIcon:Hide()
pullIcon.tex = pullIcon:CreateTexture(nil, "ARTWORK")
pullIcon.tex:SetAllPoints()

pullIcon:SetScript("OnDragStart", function(self) if self:IsMovable() then self:StartMoving() end end)
pullIcon:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    if db then
        db.pullTimerIconPoint, db.pullTimerIconRelPoint = point, relPoint
        db.pullTimerIconX, db.pullTimerIconY = x, y
    end
end)

-- An animation over an OnUpdate: the client runs it, so a pulsing icon costs nothing
-- in Lua. BOUNCE on a single alpha animation is the whole flash -- it plays 1 -> low,
-- then back, forever, until Stop().
local pullIconFlash = pullIcon:CreateAnimationGroup()
pullIconFlash:SetLooping("BOUNCE")
local pullIconFade = pullIconFlash:CreateAnimation("Alpha")
pullIconFade:SetFromAlpha(1)
pullIconFade:SetToAlpha(0.15)
pullIconFade:SetDuration(0.35)

-- The wordiest thing ResolveIconTexture can return. The config panel lays its status
-- line out against this once, so the line has room for any of them (see the panel).
local ICON_STATUS_UNKNOWN_NAME =
    "No spell by that name. Names only resolve for spells this client knows -- use the spell ID for anyone else's."
-- Appended when "stop when I cast it" is on but the icon is a picture with no spell
-- behind it. Silence there would read as a broken option rather than an impossible one.
local ICON_STATUS_NO_SPELL =
    " There is no spell behind this icon, so nothing can stop the flash early."

-- Turns what the user typed into something SetTexture accepts, plus a line of plain
-- English for the panel's status text. The three inputs that are actually to hand --
-- a spell name, a spell ID, an icon file ID -- can't be told apart by shape: spell IDs
-- and texture file IDs share one number range. A bare number is therefore tried as a
-- spell first and only falls back to a file ID; "spell:" / "icon:" force either way.
--
-- Returns nil plus the reason when nothing resolved, and the caller decides what to do
-- about it: the panel shows a desaturated question mark, a live pull shows nothing
-- rather than flashing a placeholder at the raid.
--
-- The third return is the spell ID behind the icon, when there was one. That is what
-- makes "stop when I cast it" possible at all: an icon file ID or a texture path names
-- a picture and nothing else, so there is no cast to watch for.
local function ResolveIconTexture(input)
    input = input and strtrim(input) or ""
    if input == "" then return nil, "No icon set." end

    local kind, rest = input:match("^(%a+):(.+)$")
    kind = kind and kind:lower()
    if kind ~= "spell" and kind ~= "icon" then kind, rest = nil, input end

    -- Backslashes rule out both the "kind:" prefixes and a spell name, so anything
    -- carrying one is a raw texture path being passed straight through.
    if not kind and (rest:find("\\", 1, true) or rest:find("/", 1, true)) then
        return rest, "Texture path."
    end

    local num = tonumber(rest)
    if num then
        if kind ~= "icon" then
            local tex = C_Spell.GetSpellTexture(num)
            if tex then return tex, "Spell " .. num .. ".", num end
            if kind == "spell" then return nil, "No spell with ID " .. num .. "." end
        end
        -- Nothing validates a file ID short of drawing it, so this is reported as
        -- resolved either way; a wrong one shows as a blank square.
        return num, "Icon file ID " .. num .. "."
    end

    if kind == "icon" then return nil, "An icon file ID has to be a number." end

    local info = C_Spell.GetSpellInfo(rest)
    if info and info.iconID then
        -- The ID is reported, not just the picture: it is what the cast watch matches
        -- against, and seeing it is how you tell you got the spell you meant.
        return info.iconID, "Spell by name (" .. (info.spellID or "?") .. ").", info.spellID
    end
    return nil, ICON_STATUS_UNKNOWN_NAME
end

-- Crops the border off an icon by pulling its texture coordinates in. The stored
-- value is the percentage of the texture thrown away, so half of it comes off each
-- edge; ~8% is the point where a standard spell icon loses its grey frame. Clamped
-- because coords that cross over draw the icon inside out.
local function ApplyIconZoom(tex, zoom)
    local inset = math.min(math.max(tonumber(zoom) or 0, 0), 40) / 200
    tex:SetTexCoord(inset, 1 - inset, inset, 1 - inset)
end

-- Forward-declared: the cast watch's handler hides the icon, and is installed above
-- the function that does it.
local HidePullIcon

local iconTexture          -- what ResolveIconTexture made of db.pullTimerIconInput
local iconSpellID          -- the spell behind it, when the input named one
local iconActive = false   -- a pull (or the Test button) currently owns the frame
local castSatisfied = false -- the watched spell was cast during this countdown

-- Re-resolved at every point of use, not trusted from the last apply pass: the first
-- apply runs at ADDON_LOADED, before the spellbook exists, so a spell *name* resolves
-- to nil there and would stay nil all session -- the sound fires, the icon silently
-- doesn't. Cheap enough to do per pull.
local function RefreshIconTexture()
    if not db then return end
    local tex, _, spellID = ResolveIconTexture(db.pullTimerIconInput)
    iconTexture, iconSpellID = tex, spellID
end

-- The reminder is only a reminder until the thing is done, so the icon watches for
-- its own spell being cast and gets out of the way. UNIT_SPELLCAST_SUCCEEDED rather
-- than the combat log: CLEU registration is taint-gated on this client, and this is
-- the player's own cast, which the unit-filtered form delivers at the C level.
--
-- The watch runs for the whole countdown, not just while the icon is up, so casting
-- the spell *before* the trigger point means the icon never appears at all.
local function SetCastWatch(on)
    local want = on and db and db.enabled and db.pullTimerIcon
        and db.pullTimerIconStopOnCast and iconSpellID ~= nil and not castSatisfied
    if want then
        pullIcon:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    else
        pullIcon:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    end
end

-- A talent, an override or a rank casts under an ID of its own while showing the same
-- name and icon, so an ID match alone would miss the cast the user just made. Names
-- are compared as the fallback for exactly that case.
local function CastMatchesIcon(spellID)
    if not iconSpellID or not spellID then return false end
    if spellID == iconSpellID then return true end
    local castName = C_Spell.GetSpellName(spellID)
    return castName ~= nil and castName == C_Spell.GetSpellName(iconSpellID)
end

local function ShowPullIcon()
    if not iconTexture then RefreshIconTexture() end
    if not iconTexture or castSatisfied then return end
    iconActive = true
    pullIcon.tex:SetTexture(iconTexture)
    pullIcon.tex:SetDesaturated(false)
    pullIcon:SetBackdrop(nil)
    pullIcon:EnableMouse(false)
    pullIcon:SetAlpha(1)
    pullIcon:Show()
    pullIconFlash:Play()
end

pullIcon:SetScript("OnEvent", function(self, event, unit, castGUID, spellID)
    if event ~= "UNIT_SPELLCAST_SUCCEEDED" or not CastMatchesIcon(spellID) then return end
    -- Latched rather than only hiding: the cast can land before the trigger point,
    -- and this is what keeps the icon from appearing afterwards.
    castSatisfied = true
    HidePullIcon()
end)

function HidePullIcon()
    -- Before the iconActive test, not after: a cast that beat the trigger point leaves
    -- the watch running with nothing on screen to hide.
    SetCastWatch(false)
    if not iconActive then return end
    iconActive = false
    pullIconFlash:Stop()
    pullIcon:SetAlpha(1)
    pullIcon:Hide()
    -- Hands the frame back to the config panel's drag preview, if that is what it
    -- was doing before the alert borrowed it.
    DUI_UpdatePullAlertIcon()
end

function DUI_UpdatePullAlertIcon()
    if not DanUIDB then return end
    db = DUI_InitModuleDB("CombatAlerts", DUI_GetCombatAlertsDefaults)

    RefreshIconTexture()
    -- Re-evaluated on every apply pass, so ticking the option (or changing the icon to
    -- one with no spell behind it) takes effect mid-countdown.
    SetCastWatch(pullEndTime ~= 0 or iconActive)

    local size = db.pullTimerIconSize or 128
    pullIcon:SetSize(size, size)
    pullIcon:ClearAllPoints()
    pullIcon:SetPoint(db.pullTimerIconPoint or "CENTER", UIParent,
        db.pullTimerIconRelPoint or "CENTER", db.pullTimerIconX or 0, db.pullTimerIconY or 0)
    pullIconFade:SetDuration(db.pullTimerIconFlash or 0.35)
    ApplyIconZoom(pullIcon.tex, db.pullTimerIconZoom)

    -- Size and position are applied above even mid-flash, so a slider dragged during
    -- the Test preview tracks; the rest of this decides who owns the frame, and a
    -- live alert always wins.
    if iconActive then return end

    -- Dragged in place rather than positioned by sliders, and dragged as the real
    -- frame, so what is set up is exactly what the pull shows. Mouse is enabled only
    -- while the panel is open -- at any other time this must not eat clicks in the
    -- middle of the screen. DUI_IsConfigOpen, not IsShown: the panel is a child of
    -- the main window when docked (see DanUI.lua).
    if DUI_IsConfigOpen("DUI_CombatAlertsConfig") and db.enabled and db.pullTimerIcon then
        pullIcon.tex:SetTexture(iconTexture or "Interface\\Icons\\INV_Misc_QuestionMark")
        pullIcon.tex:SetDesaturated(iconTexture == nil)
        pullIcon:EnableMouse(true)
        pullIcon:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        pullIcon:SetBackdropColor(0, 0, 0, 0.3)
        pullIcon:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
        pullIcon:Show()
    else
        pullIcon:EnableMouse(false)
        pullIcon:SetBackdrop(nil)
        pullIcon:Hide()
    end
end

-- Exposed for the config's Test button: the real thing, flashed for five seconds, so
-- size and flash speed can be judged against the actual screen rather than the panel.
function DUI_TestPullAlertIcon()
    DUI_UpdatePullAlertIcon()
    if not iconTexture then return false end
    -- Cleared so a test right after a real pull still shows something, and watched so
    -- the cast half can be tried out too: cast the spell and the preview should stop.
    castSatisfied = false
    SetCastWatch(true)
    ShowPullIcon()
    C_Timer.After(5, function()
        -- A pull timer that started during the preview has taken the icon over on its
        -- own terms; leave it counting rather than hiding it early.
        if pullEndTime == 0 then HidePullIcon() end
    end)
    return true
end

-- ---------------------------------------------------------------------------
-- Pull timer alert
-- ---------------------------------------------------------------------------

-- The sound and the icon are ticked separately, so the countdown is watched when
-- either one is wanted.
local function PullAlertActive()
    return db and db.enabled and (db.pullTimerAlert or db.pullTimerIcon) and true or false
end

-- Only attached to the frame while a pull timer is counting down (see StartPullWatch),
-- so there's no per-frame cost during the vast majority of play when nothing is pending.
local function PullWatchOnUpdate(self, elapsed)
    if not PullAlertActive() or pullEndTime == 0 then
        self:SetScript("OnUpdate", nil)
        HidePullIcon()
        return
    end

    local remaining = pullEndTime - GetTime()

    if remaining <= db.pullTimerValue and not alertFired then
        alertFired = true
        if db.pullTimerAlert and db.pullTimerSound and db.pullTimerSound ~= "None" then
            local path = LSM:Fetch("sound", db.pullTimerSound)
            if path then PlaySoundFile(path, "Master") end
        end
        if db.pullTimerIcon then ShowPullIcon() end
    end

    if remaining <= 0 then
        pullEndTime = 0
        self:SetScript("OnUpdate", nil)
        HidePullIcon()
    end
end

local function StartPullWatch()
    -- A fresh countdown: whatever was cast during the last one says nothing about
    -- this one. The cast watch starts here rather than at the trigger point, so a
    -- spell cast early in the countdown suppresses the icon before it ever shows.
    -- Resolved here too, so the cast watch below has the spell ID to match against
    -- (see RefreshIconTexture for why the load-time value can't be trusted).
    castSatisfied = false
    RefreshIconTexture()
    SetCastWatch(true)
    frame:SetScript("OnUpdate", PullWatchOnUpdate)
end

-- ---------------------------------------------------------------------------
-- Death alert
-- ---------------------------------------------------------------------------

-- Hash lookup rather than two pattern matches, for the same per-event cost reason
-- the API locals above exist.
local function IsGroupUnit(unit)
    return unit ~= nil and DUI_GROUP_UNIT_SET[unit] == true
end

local function RefreshRosterCache()
    -- Create a temporary new cache to handle joined/left members
    local newCache = {}

    -- Always track the player specifically, regardless of group status
    newCache["player"] = UnitIsDeadOrGhost("player")

    if IsInGroup() then
        local num = GetNumGroupMembers()
        for i = 1, num do
            -- GetUnitID hands back interned tokens from DanUI.lua's table, so this no
            -- longer builds 40 throwaway strings per roster change.
            local unit = GetUnitID(i, num)
            -- Preserve existing state if we were already tracking them to avoid race conditions
            newCache[unit] = (deadCache[unit] ~= nil) and deadCache[unit] or UnitIsDeadOrGhost(unit)
        end
    end

    -- Update the main cache
    for unit, state in pairs(newCache) do
        deadCache[unit] = state
    end
end

local function OnUnitUpdate(unit)
    if not db or not db.enabled or not db.deathAlert then return end
    if not unit or not IsGroupUnit(unit) then return end

    -- Check if dead or ghost (Direct UnitHealth comparison causes "secret number" taint errors)
    local isDead = UnitIsDeadOrGhost(unit)

    -- Filter out Feign Death (UnitIsDead returns true for Hunters feigning)
    if isDead and UnitIsFeignDeath(unit) then isDead = false end

    local wasDead = deadCache[unit]

    -- If we haven't seen this unit before, just initialize and exit
    if wasDead == nil then
        deadCache[unit] = isDead
        return
    end

    -- Transition from Alive to Dead
    if not wasDead and isDead then
        local now = GetTime()
        if now >= nextDeathSoundAt then
            local path = db.deathSound and db.deathSound ~= "None" and LSM:Fetch("sound", db.deathSound)
            if path then
                PlaySoundFile(path, "Master")
                nextDeathSoundAt = now + (db.deathThrottle or 0.5)
            end
        end
    end
    deadCache[unit] = isDead
end

-- Its own frame rather than sharing `frame`: that one carries the pull-timer
-- OnUpdate and the BigWigs message registrations, and the death watch has to be
-- able to drop every event it owns without disturbing those.
local deathFrame = CreateFrame("Frame")
deathFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        RefreshRosterCache()
    elseif event == "PLAYER_DEAD" then
        OnUnitUpdate("player")
    end
end)

-- UNIT_HEALTH/UNIT_FLAGS fire for every unit in the world (nameplates, passersby,
-- the enemy raid), so they are filtered to the group at the C level. This used to
-- be one RegisterUnitEvent call with all 45 tokens, which the client truncates to
-- the first two: in a raid, no member's death was ever heard. See
-- DUI_CreateGroupUnitWatcher.
local deathUnitWatcher = DUI_CreateGroupUnitWatcher({ "UNIT_HEALTH", "UNIT_FLAGS" }, function(_, _, unit)
    OnUnitUpdate(unit)
end)

function SetDeathEventsRegistered(on)
    if on then
        deathFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
        deathFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
        deathFrame:RegisterEvent("PLAYER_DEAD")
        deathUnitWatcher:SetRegistered(true)
        RefreshRosterCache()
    else
        deathFrame:UnregisterAllEvents()
        deathUnitWatcher:SetRegistered(false)
    end
end

-- ---------------------------------------------------------------------------

local bigWigsHooked = false

function DUI_InitCombatAlerts()
    -- Through DUI_InitModuleDB rather than an all-or-nothing default: an install that
    -- predates the pull icon has a CombatAlerts table already, and the nil-only
    -- backfill is what gets the icon's keys into it.
    db = DUI_InitModuleDB("CombatAlerts", DUI_GetCombatAlertsDefaults)

    -- One-shot migration from the old standalone Death Sound module, whose panel
    -- was folded into this one. Clearing the old table is what makes it one-shot;
    -- it has to overwrite, because DUI_InitModuleDB has already seeded the new
    -- keys with defaults by the time this runs.
    local old = DanUIDB.DeathSound
    if old then
        if old.enabled ~= nil then db.deathAlert = old.enabled end
        if old.soundAlert then db.deathSound = old.soundAlert end
        if old.throttle then db.deathThrottle = old.throttle end
        DanUIDB.DeathSound = nil
    end

    SetDeathEventsRegistered(db.enabled and db.deathAlert)
    -- Switched off mid-countdown or mid-Test: take the watch and the icon down now,
    -- rather than on the watch's next frame or the Test's 5s timer.
    if not PullAlertActive() then
        pullEndTime = 0
        frame:SetScript("OnUpdate", nil)
        HidePullIcon()
    end
    DUI_UpdatePullAlertIcon()

    -- Hook BigWigs if available. We use the dedicated pull messages, which carry the
    -- countdown length as a plain number. (Parsing BigWigs_StartBar text is unsafe on
    -- the current client: the bar text is a "secret" value and inspecting it from
    -- addon code throws a secret-value / ADDON_ACTION_FORBIDDEN error.)
    -- Guarded, because this function is now the module's apply pass too and re-runs
    -- every time the enable checkbox is toggled; registering the same message twice
    -- would fire the handler twice per pull.
    if BigWigsLoader and not bigWigsHooked then
        bigWigsHooked = true
        BigWigsLoader.RegisterMessage(frame, "BigWigs_StartPull", function(_, _, seconds)
            if not PullAlertActive() then return end
            local duration = tonumber(seconds)
            if duration and duration > 0 then
                pullEndTime = GetTime() + duration
                alertFired = false
                StartPullWatch()
            end
        end)
        BigWigsLoader.RegisterMessage(frame, "BigWigs_StopPull", function()
            pullEndTime = 0
            HidePullIcon()
        end)
    end
end

-- Configuration UI
-- onShow/onHide put the pull icon's drag placeholder on screen only while the panel
-- is up, the same contract Combat Timer and Break Timer use.
local config = DUI_CreateConfigFrame("DUI_CombatAlertsConfig", "Combat Alerts", 320, 260, "DUI_CombatAlertsBtn", {
    onShow = function() DUI_UpdatePullAlertIcon() end,
    onHide = function() DUI_UpdatePullAlertIcon() end,
})

-- Both alerts want the identical sound control, down to the preview-on-pick
-- behaviour; only the None entry and the tooltip differ.
local function BuildSoundDropdown(L, key, tooltip, allowNone)
    local btn = L:Dropdown("Sound", { tooltip = tooltip })
    btn:SetValue(db[key] or "None")
    btn:SetScript("OnClick", function(self)
        local items = allowNone and { { text = "None", value = "None" } } or {}
        for _, s in ipairs(LSM:List("sound")) do table.insert(items, { text = s, value = s }) end
        DUI_ShowScrollDropdown(self, items, function(val)
            db[key] = val
            self:SetValue(val)
            if val ~= "None" then local path = LSM:Fetch("sound", val); if path then PlaySoundFile(path, "Master") end end
        end, db[key])
    end)
    return btn
end

function DUI_OpenCombatAlertsConfig()
    db = DUI_InitModuleDB("CombatAlerts", DUI_GetCombatAlertsDefaults)

    if config.pullSoundBtn then config.pullSoundBtn:SetValue(db.pullTimerSound or "None") end
    if config.iconInput then config.iconInput:SetText(db.pullTimerIconInput or "") end
    if config.deathSoundBtn then config.deathSoundBtn:SetValue(db.deathSound or "None") end

    if not config.init then
        local L = DUI_CreateLayout(config)

        L:Header("BigWigs Pull Alert")
        L:Checkbox("Enable Sound Alert", db, "pullTimerAlert", nil,
            "Plays a sound partway through a BigWigs pull countdown, as a last call before the pull.")

        local valLabel = config:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
        valLabel:SetPoint("TOPLEFT", 40, L:Y() - 4)
        valLabel:SetText("Trigger at (seconds):")
        local valInput = CreateFrame("EditBox", nil, config, "BackdropTemplate")
        valInput:SetSize(50, 25); valInput:SetPoint("LEFT", valLabel, "RIGHT", 10, 0)
        valInput:SetAutoFocus(false); valInput:SetNumeric(true); valInput:SetFontObject(DUI_FontNormal)
        valInput:SetBackdrop(DUI_EditBackdrop); valInput:SetBackdropColor(0, 0, 0, 0.5); valInput:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
        DUI_RegisterAccent(valInput, "border")
        valInput:SetTextInsets(5, 5, 0, 0); valInput:SetText(tostring(db.pullTimerValue))
        valInput:SetScript("OnTextChanged", function(self, isUser) if isUser then local v = tonumber(self:GetText()); if v then db.pullTimerValue = v end end end)
        valInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end); valInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        DUI_AddTooltip(valInput, "Trigger at",
            "Seconds remaining on the pull countdown when the sound fires. 12 means the alert lands twelve seconds before the pull.")
        L:Gap(32)

        config.pullSoundBtn = BuildSoundDropdown(L, "pullTimerSound",
            "Sound played when the countdown reaches the trigger point. Picking one previews it.", true)

        L:Checkbox("Flash an Icon", db, "pullTimerIcon", DUI_UpdatePullAlertIcon,
            "Flashes an icon in the middle of the screen at the same moment as the sound, and hides it at the pull.")

        local iconLabel = config:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
        iconLabel:SetPoint("TOPLEFT", 40, L:Y() - 4)
        iconLabel:SetText("Icon:")

        local iconInput = CreateFrame("EditBox", nil, config, "BackdropTemplate")
        iconInput:SetSize(200, 25); iconInput:SetPoint("LEFT", iconLabel, "RIGHT", 10, 0)
        iconInput:SetAutoFocus(false); iconInput:SetFontObject(DUI_FontNormal)
        iconInput:SetBackdrop(DUI_EditBackdrop); iconInput:SetBackdropColor(0, 0, 0, 0.5); iconInput:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
        DUI_RegisterAccent(iconInput, "border")
        iconInput:SetTextInsets(5, 5, 0, 0); iconInput:SetText(db.pullTimerIconInput or "")
        config.iconInput = iconInput

        -- What the input currently resolves to, drawn at the size it will be shown.
        local preview = config:CreateTexture(nil, "ARTWORK")
        preview:SetSize(24, 24); preview:SetPoint("LEFT", iconInput, "RIGHT", 10, 0)

        local function RefreshIconPreview()
            local tex, status, spellID = ResolveIconTexture(db.pullTimerIconInput)
            if db.pullTimerIconStopOnCast and not spellID and strtrim(db.pullTimerIconInput or "") ~= "" then
                status = status .. ICON_STATUS_NO_SPELL
            end
            preview:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
            -- Greyed out is the whole "this didn't resolve" signal at a glance; the
            -- status line underneath says why.
            preview:SetDesaturated(tex == nil)
            ApplyIconZoom(preview, db.pullTimerIconZoom)
            if config.iconStatus then config.iconStatus:SetText(status) end
            DUI_UpdatePullAlertIcon()
        end
        config.RefreshIconPreview = RefreshIconPreview

        iconInput:SetScript("OnTextChanged", function(self, isUser)
            if not isUser then return end
            db.pullTimerIconInput = self:GetText()
            RefreshIconPreview()
        end)
        iconInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        iconInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        DUI_AddTooltip(iconInput, "Icon", {
            body = "A spell name, a spell ID, or an icon file ID. Spell names only work for spells this character knows -- for anything else, use the ID.",
            note = "Spell IDs and icon file IDs are the same kind of number, so a bare number is looked up as a spell first. Prefix with spell: or icon: to force one.",
        })
        L:Gap(32)

        -- Built with the longest message it can ever carry, not with "": the cursor
        -- measures this paragraph once, when the panel is created, and everything
        -- below is anchored off that. Seeded empty, a later two-line status would be
        -- drawn straight over the Icon Size slider.
        config.iconStatus = L:Text(ICON_STATUS_UNKNOWN_NAME .. ICON_STATUS_NO_SPELL)

        L:Slider("DUI_CA_IconSize", "Icon Size", 32, 320, 4, db, "pullTimerIconSize", DUI_UpdatePullAlertIcon,
            { fmt = "%dpx", value = db.pullTimerIconSize,
              tooltip = "How large the icon is drawn." })
        -- Through the panel's refresh rather than the appearance pass directly: the
        -- crop has to land on the panel's own 24px preview as well, and that function
        -- runs the appearance pass itself.
        L:Slider("DUI_CA_IconZoom", "Icon Zoom", 0, 40, 1, db, "pullTimerIconZoom", RefreshIconPreview,
            { fmt = "%d%%", value = db.pullTimerIconZoom,
              tooltip = "Crops the edges of the icon inwards. Around 8% trims the grey border off a standard spell icon; higher fills the square with the artwork." })
        L:Slider("DUI_CA_IconFlash", "Flash Speed", 0.1, 1, 0.05, db, "pullTimerIconFlash", DUI_UpdatePullAlertIcon,
            { fmt = "%.2fs", value = db.pullTimerIconFlash,
              tooltip = "Seconds the icon takes to fade out, and the same again to fade back in. Lower is a faster pulse." })

        -- Through RefreshIconPreview, not the appearance pass: ticking this changes what
        -- the status line above has to say about the icon currently set.
        L:Checkbox("Stop When I Cast It", db, "pullTimerIconStopOnCast", RefreshIconPreview,
            "Hides the icon the moment you cast its spell, and keeps it from appearing at all if you cast during the countdown. Only possible when the icon was named by spell rather than by icon ID.")

        L:Gap()
        L:Text("Requires BigWigs. The alert uses BigWigs' pull message, so it fires for any pull timer started in the group. Drag the icon on screen to reposition it while this panel is open.")

        L:Header("Death Alert")
        L:Checkbox("Enable Sound Alert", db, "deathAlert", function()
            -- Drops the UNIT_HEALTH/UNIT_FLAGS registrations outright when unticked,
            -- rather than leaving them firing into an early return.
            SetDeathEventsRegistered(db.enabled and db.deathAlert)
        end, "Plays a sound when a member of your group dies.")

        config.deathSoundBtn = BuildSoundDropdown(L, "deathSound",
            "Sound played when a group member dies. Picking one previews it.", false)

        L:Text("Minimum time between death sounds.")
        L:Slider("DUI_CA_DeathThrottle", "Throttle", 0, 5, 0.1, db, "deathThrottle", nil,
            { fmt = "%.1fs", value = db.deathThrottle,
              tooltip = "Stops a wipe from firing the sound once per player. Set to 0 to hear every death." })

        -- Room reserved for the Test button pinned to the bottom edge.
        L:FitHeight(40)

        local testBtn = CreateFrame("Button", nil, config, "BackdropTemplate")
        testBtn:SetSize(140, 25); testBtn:SetPoint("BOTTOMLEFT", 16, 12)
        testBtn:SetText("Test Icon (5s)"); StyleAsTealTab(testBtn)
        testBtn:SetScript("OnClick", function()
            -- Says so rather than doing nothing: an unresolved icon is the one failure
            -- the panel can't show, because there is nothing to put on screen.
            if not DUI_TestPullAlertIcon() then
                print(DUI_AccentText("DanUI:") .. " no icon to flash -- check the Icon field.")
            end
        end)
        DUI_AddTooltip(testBtn, "Test Icon",
            "Flashes the icon for five seconds, at the size and speed set above, so it can be judged against the real screen. No sound, and nothing is sent to the group.")

        config.init = true
    end

    if config.RefreshIconPreview then config.RefreshIconPreview() end
    config:Show()
    DUI_UpdatePullAlertIcon()
end
