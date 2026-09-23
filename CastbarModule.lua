-- CastbarModule.lua
-- Inspired by Quartz and adapted for DUI.
--
-- Three bars, one implementation: player, target and focus each get their own
-- frame, their own settings table and their own tab in the config panel. The unit
-- is the only thing that differs at runtime, so everything below is written
-- against a `bar` and reads its settings through CastbarDB(bar.unit) rather than
-- through a single file-level `db`.

local LSM = LibStub:GetLibrary("LibSharedMedia-3.0")
local db -- Local reference to DanUIDB.Castbar (the player's table; target/focus hang off it)

-- Localized for OnUpdate, which runs every frame for each of the three bars while
-- a cast is up -- the one place in this addon where a global table lookup is paid
-- hundreds of times a second.
local GetTime, floor = GetTime, math.floor

-- Order matters: it is the tab order, and the order bars are iterated in.
local UNITS = { "player", "target", "focus" }
local UNIT_LABEL = { player = "Player", target = "Target", focus = "Focus" }

-- Shared shape. The player's settings are the top level of DanUIDB.Castbar and the
-- other two are subtables of it, so a castbar profile -- which is a CopyTable of
-- that one table -- carries all three bars without the profile code learning
-- anything about units.
local function UnitBarDefaults(enabled, y)
    return {
        enabled = enabled,
        hideBlizz = true,
        border = "None",
        width = 250,
        height = 25,
        x = 0,
        y = y,
        point = "CENTER",
        relPoint = "CENTER",
        fontSize = 12,
        texture = "Blizzard",
        colorCasting = {1, 0.7, 0, 1},
        colorChanneling = {0.3, 0.3, 1, 1},
        colorSuccess = {0, 1, 0, 1},
        colorFail = {1, 0, 0, 1},
        alpha = 1,
        showTicks = true,
        tickColor = {1, 1, 1, 0.7},
        tickWidth = 2,
    }
end

function DUI_GetCastbarDefaults()
    local d = UnitBarDefaults(true, -200)
    -- Player only: the "Spell -> Target" suffix is fed by UNIT_SPELLCAST_SENT,
    -- which the client fires for the player and nobody else.
    d.showTarget = true
    -- Off by default: someone upgrading into this asked for a player castbar, not
    -- for two more bars to appear unannounced in the middle of their screen.
    d.target = UnitBarDefaults(false, -260)
    d.focus  = UnitBarDefaults(false, -320)
    return d
end

-- Backfill missing keys. A plain pairs() pass tops up the flat player keys but
-- would leave a target/focus table saved by an older build missing anything added
-- since, so those two are merged a level deeper by hand. Colour keys are arrays
-- and are deliberately not descended into: a saved {r,g,b} with no alpha is valid,
-- and merging index 4 in from the default is not a fix for anything.
local function FillCastbarDefaults(t)
    if not t then return t end
    for k, v in pairs(DUI_GetCastbarDefaults()) do
        if t[k] == nil then
            t[k] = (type(v) == "table") and CopyTable(v) or v
        elseif (k == "target" or k == "focus") and type(t[k]) == "table" then
            for sk, sv in pairs(v) do
                if t[k][sk] == nil then
                    t[k][sk] = (type(sv) == "table") and CopyTable(sv) or sv
                end
            end
        end
    end
    return t
end

-- The settings table for one unit. Nil until DanUIDB exists, which is why every
-- caller that can run before ADDON_LOADED checks the result.
local function CastbarDB(unit)
    if not db then return nil end
    if unit == "player" then return db end
    return db[unit]
end

-- ---- channel tick marks --------------------------------------------------
-- Retail exposes no API for how often a channel ticks: UnitChannelInfo hands back
-- the window, not the beats inside it. Quartz solved that with a hand-kept table
-- and there is still no better source, so this is one too.
--
-- Counts are base values. Talents that add ticks are not modelled, nor are the
-- haste breakpoints that hand a few channels a partial extra tick, and a spell
-- missing from the table simply draws no marks rather than guessing at one. Expect
-- to correct entries after a balance patch -- the table is a global so that can be
-- done from another addon or a /run without editing this file.
--
-- A value is normally a tick count, but may be a function(durationMs) for the
-- spells whose count is not fixed to their spell ID. Convoke is the reason that
-- exists; see the note on it below.
DUI_CastbarChannelTicks = DUI_CastbarChannelTicks or {
    -- Mage
    [5143]   = 5,  -- Arcane Missiles
    [12051]  = 4,  -- Evocation
    [205021] = 5,  -- Ray of Frost
    [314791] = 4,  -- Shifting Power
    -- Warlock
    [234153] = 5,  -- Drain Life
    [198590] = 5,  -- Drain Soul
    [755]    = 5,  -- Health Funnel
    [5740]   = 8,  -- Rain of Fire
    -- Priest
    [15407]  = 3,  -- Mind Flay
    [47540]  = 3,  -- Penance
    [64843]  = 4,  -- Divine Hymn
    [48045]  = 5,  -- Mind Sear
    [263165] = 4,  -- Void Torrent
    -- Druid
    [740]    = 4,  -- Tranquility
    -- Convoke the Spirits. Both versions are this one spell ID: Ashamane's
    -- Guidance (Feral) halves the cooldown and takes a quarter off the duration
    -- and the cast count, so the 2-minute version is 16 casts over 4s and the
    -- 1-minute version 12 over 3s. Only the channel's own length separates them.
    -- Convoke is not affected by haste, so those two lengths are exact and the
    -- midpoint is a safe split rather than something that drifts with gear.
    [391528] = function(ms) return (ms and ms >= 3500) and 16 or 12 end,
    -- Monk
    [117952] = 6,  -- Crackling Jade Lightning
    [113656] = 4,  -- Fists of Fury
    [115175] = 8,  -- Soothing Mist
    [191837] = 3,  -- Essence Font
    [443028] = 5,  -- Celestial Conduit (Conduit of the Celestials)
    -- Hunter
    [120360] = 10, -- Barrage
    [257044] = 7,  -- Rapid Fire
    -- Demon Hunter
    [198013] = 10, -- Eye Beam
    [258925] = 10, -- Fel Barrage
    -- Evoker (the empowered spells are measured from the client instead, below)
    [356995] = 4,  -- Disintegrate
}

-- ---- the bars ------------------------------------------------------------

local bars = {}   -- unit -> frame
local ForEachBar

local function CreateCastBar(unit, globalName)
    local bar = CreateFrame("StatusBar", globalName, UIParent, "BackdropTemplate")
    bar.unit = unit
    -- Per-bar cast state. It used to be a row of file-level locals, which is
    -- exactly the thing that cannot be shared by three bars.
    bar.st = {
        casting = false, channeling = false,
        startTime = 0, endTime = 0,
        currentTarget = nil, activeGUID = nil, holdTime = nil,
        tickFracs = {},   -- 0-1 positions along the bar of the active channel's beats
        ticks = {},       -- the textures drawing them, pooled and reused
        eventsOn = false,
        -- Last value written to bar.time, at the precision it is displayed at. The
        -- readout only changes 10x a second but OnUpdate runs every frame, so this
        -- is what lets the other ~130 frames skip the format and the relayout. See
        -- the same trick in CombatTime.lua and BreakTimer.lua.
        shownTenths = nil,
    }
    bar:SetSize(250, 25)
    bar:SetMinMaxValues(0, 1)
    bar:Hide()
    bar:SetMovable(true)
    bar:SetClampedToScreen(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function(self) if self:IsMovable() then self:StartMoving() end end)
    bar:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        local cfg = CastbarDB(self.unit)
        if not cfg then return end
        cfg.point, cfg.relPoint, cfg.x, cfg.y = point, relPoint, x, y
        if self.sliderY then self.sliderY:SetValue(y) end
        -- The live table is a copy of the profile, so mirror the move back into it.
        if DUI_OnCastbarChanged then DUI_OnCastbarChanged() end
    end)

    bar.text = bar:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
    bar.text:SetPoint("LEFT", 5, 0)

    bar.time = bar:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
    bar.time:SetPoint("RIGHT", -5, 0)

    bar.spark = bar:CreateTexture(nil, "OVERLAY")
    bar.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    bar.spark:SetBlendMode("ADD")
    bar.spark:SetSize(20, 50)

    bars[unit] = bar
    return bar
end

CreateCastBar("player", "DUI_PlayerCastBar")
CreateCastBar("target", "DUI_TargetCastBar")
CreateCastBar("focus",  "DUI_FocusCastBar")

function ForEachBar(fn)
    for _, unit in ipairs(UNITS) do fn(bars[unit], unit) end
end

-- Hide every tick mark on a bar without destroying the textures: a channel every
-- few seconds would otherwise churn a handful of textures per cast forever.
local function HideTicks(bar)
    for _, t in ipairs(bar.st.ticks) do t:Hide() end
end

-- Place a mark at each fraction the active channel produced. Called from the
-- appearance pass too, so changing the bar's width or the tick colour repaints
-- marks that are already on screen.
local function LayoutTicks(bar)
    HideTicks(bar)
    local st, cfg = bar.st, CastbarDB(bar.unit)
    if not cfg or not cfg.showTicks or #st.tickFracs == 0 then return end
    local h = math.max(cfg.height - 2, 1)
    for i, frac in ipairs(st.tickFracs) do
        local t = st.ticks[i]
        if not t then
            -- Sublevel -1 keeps the marks under the spark: the spark is the thing
            -- that has to stay readable when it passes over one.
            t = bar:CreateTexture(nil, "OVERLAY", nil, -1)
            st.ticks[i] = t
        end
        t:SetColorTexture(cfg.tickColor[1], cfg.tickColor[2], cfg.tickColor[3], cfg.tickColor[4] or 1)
        t:SetSize(cfg.tickWidth, h)
        t:ClearAllPoints()
        t:SetPoint("CENTER", bar, "LEFT", frac * cfg.width, 0)
        t:Show()
    end
end

-- Work out where the marks go for the cast that is starting. Empowered casts are
-- the one channel the client is honest about -- each stage reports its own length
-- -- so those marks are exact rather than table-driven. Everything else falls back
-- to an even split of the spell's tick count, and an unknown spell gets none.
local function BuildTickFracs(bar, unit, spellID, isEmpowered, numStages, durationMs)
    local fracs = bar.st.tickFracs
    wipe(fracs)
    if isEmpowered and numStages and numStages > 0 and durationMs and durationMs > 0
       and GetUnitEmpowerStageDuration then
        local acc = 0
        for i = 0, numStages - 1 do
            acc = acc + (GetUnitEmpowerStageDuration(unit, i) or 0)
            -- Normalised against the channel window rather than the summed stages:
            -- an empowered cast holds at full charge after the last stage, so the
            -- stages are shorter than the bar and the final mark lands before the end.
            local f = acc / durationMs
            if f > 0 and f < 1 then fracs[#fracs + 1] = f end
        end
        return
    end
    local n = spellID and DUI_CastbarChannelTicks[spellID]
    -- A function entry is for the spells whose tick count is not fixed to their ID
    -- -- see Convoke in the table. It is handed the channel length in milliseconds.
    if type(n) == "function" then n = n(durationMs) end
    if type(n) ~= "number" or n < 2 then return end
    for i = 1, n - 1 do fracs[i] = i / n end
end

-- ---- Blizzard's own bars -------------------------------------------------
-- Blizzard's bar is silenced by stripping its events, and nothing here latches:
-- other cast bar addons hand the frame back by re-registering those events when
-- they drop their own claim on it (EllesmereUI does exactly that, out of a
-- PLAYER_ENTERING_WORLD handler), so the hide has to be re-asserted rather than
-- done once at load. Re-silencing late is also what gets us recorded as the
-- frame's owner: those addons hook UnregisterAllEvents to spot a claim they do not
-- own, and our ADDON_LOADED pass runs before their hooks exist, so only a later
-- pass registers with them.
-- Restoring is a /reload. CastingBarMixin:SetUnit early-returns when the frame
-- already holds the unit being passed, so it re-registers nothing; there is no way
-- back from Lua.
local BLIZZ_BAR = {
    player = "PlayerCastingBarFrame",
    target = "TargetFrameSpellBar",
    focus  = "FocusFrameSpellBar",
}
local blizzHidden = {}
local blizzHooked = {}

local function ToggleBlizzardBar(unit, hide)
    local frame = _G[BLIZZ_BAR[unit]]
    if not frame then return end
    if hide then
        blizzHidden[unit] = true
        if frame:IsEventRegistered("UNIT_SPELLCAST_START") or frame:IsShown() then
            frame:UnregisterAllEvents()
            frame:Hide()
        end
        -- The target and focus spell bars are re-shown by TargetFrame's own update
        -- path rather than only by their own events, so stripping the registrations
        -- is not enough on its own. The hook is installed once and gated on the
        -- flag, so turning the option back off leaves it inert instead of fighting
        -- whatever re-shows the frame next.
        if unit ~= "player" and not blizzHooked[unit] then
            blizzHooked[unit] = true
            frame:HookScript("OnShow", function(self)
                if blizzHidden[unit] then self:Hide() end
            end)
        end
    elseif blizzHidden[unit] then
        blizzHidden[unit] = false
        print("|cFF82A670[DUI]|r Type /reload to bring Blizzard's " .. unit .. " castbar back.")
    end
end

-- The re-assert driver. PLAYER_ENTERING_WORLD is when the addons sharing these
-- frames re-apply their own state, so ours goes on right after theirs: once
-- inline, and once on the next frame for the ones that defer their pass with a
-- C_Timer.After(0).
local blizzWatch = CreateFrame("Frame")
blizzWatch:RegisterEvent("PLAYER_ENTERING_WORLD")
blizzWatch:SetScript("OnEvent", function()
    local function reassert()
        for _, unit in ipairs(UNITS) do
            local cfg = CastbarDB(unit)
            if cfg and cfg.enabled and cfg.hideBlizz then ToggleBlizzardBar(unit, true) end
        end
    end
    reassert()
    C_Timer.After(0, reassert)
end)

-- Defined below, next to the event list; forward-declared so the appearance pass
-- (which owns the enabled state) can drive it.
local SetCastbarEventsRegistered

-- Which tab the config panel is showing. It is also which bar gets the drag
-- placeholder, so the bar you are editing is the one you can grab.
local activeCastbarUnit = "player"

-- ---- appearance ----------------------------------------------------------

local function UpdateOneBar(bar)
    local unit = bar.unit
    local cfg = CastbarDB(unit)
    if not cfg then return end

    bar:SetSize(cfg.width, cfg.height)
    bar:ClearAllPoints()
    bar:SetPoint(cfg.point, UIParent, cfg.relPoint or cfg.point, cfg.x, cfg.y)
    bar:SetAlpha(cfg.alpha)
    bar.text:SetFont(DUI_FontPath, cfg.fontSize, "")
    bar.time:SetFont(DUI_FontPath, cfg.fontSize, "")
    bar.spark:SetHeight(cfg.height * 2.2)

    bar:SetStatusBarTexture(LSM:Fetch("statusbar", cfg.texture) or "Interface\\Buttons\\WHITE8X8")

    local configOpen = DUI_IsConfigOpen("DUI_CastbarConfig")
    -- Only the tab on screen gets the placeholder. Showing all three at once put
    -- two bars the user was not editing in the middle of the screen, and one of
    -- them was usually a bar they had deliberately left disabled.
    if configOpen and unit == activeCastbarUnit and not bar.st.casting and not bar.st.channeling then
        bar:SetStatusBarColor(0.5, 0.5, 0.5, 0.5)
        bar.text:SetText("Drag " .. UNIT_LABEL[unit] .. " Bar to Move")
        bar.time:SetText("")
        bar.st.shownTenths = nil
        bar.spark:Hide()
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(1)
        wipe(bar.st.tickFracs)
        bar:Show()
    end

    local borderTex = cfg.border ~= "None" and LSM:Fetch("border", cfg.border)
    bar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = borderTex,
        tile = true, tileSize = 16, edgeSize = (borderTex and 12 or 0),
    })
    bar:SetBackdropColor(0, 0, 0, 0.5)

    LayoutTicks(bar)

    ToggleBlizzardBar(unit, cfg.enabled and cfg.hideBlizz)

    -- The per-bar toggle gates the event registrations themselves, so a disabled
    -- bar costs nothing per cast rather than waking a handler that returns.
    SetCastbarEventsRegistered(bar, cfg.enabled)
    if not cfg.enabled and not (configOpen and unit == activeCastbarUnit) then
        bar:Hide()
    end
end

function DUI_UpdateCastbarAppearance()
    if not DanUIDB then return end
    DanUIDB.Castbar = DanUIDB.Castbar or DUI_GetCastbarDefaults()
    db = DanUIDB.Castbar
    -- Cheap guard rather than an unconditional fill: this runs on every tick of a
    -- slider drag, and building a defaults table each time is churn for nothing.
    if not (db.target and db.focus) then FillCastbarDefaults(db) end
    ForEachBar(UpdateOneBar)
end

-- ---- the cast itself -----------------------------------------------------

local function OnUpdate(self)
    local st = self.st
    local cfg = CastbarDB(self.unit)
    if not cfg then return end
    local curr = GetTime()

    -- Use timestamp instead of C_Timer closures for better GC performance
    if not (st.casting or st.channeling) and st.holdTime then
        if curr > st.holdTime then
            st.holdTime = nil
            if not (DUI_IsConfigOpen("DUI_CastbarConfig") and self.unit == activeCastbarUnit) then
                self:Hide()
            end
        end
        return
    end

    if st.casting then
        local total = st.endTime - st.startTime
        if curr > st.endTime then
            self:SetValue(1)
            self.time:SetFormattedText("%.1f / %.1f", total, total)
            st.shownTenths = nil
            self:SetStatusBarColor(cfg.colorSuccess[1], cfg.colorSuccess[2], cfg.colorSuccess[3], cfg.colorSuccess[4])
            self.spark:Hide()
            st.casting = false
            st.holdTime = curr + 0.5
            return
        end
        local elapsed = curr - st.startTime
        local perc = elapsed / total
        if perc > 1 then perc = 1 end
        self:SetValue(perc)
        -- Only rewrite the readout when the tenth it displays actually changes.
        -- The text is formatted from `tenths` rather than from `elapsed`, so the
        -- string is a pure function of the key: format its own rounding and this
        -- one can never disagree and leave the readout a tenth stale. (They do
        -- disagree if you key off the raw value -- 0.15 is a hair under 0.15 as a
        -- double, so %.1f says "0.1" where floor(x*10+0.5) has already moved to 2.)
        local tenths = floor(elapsed * 10 + 0.5)
        if tenths ~= st.shownTenths then
            st.shownTenths = tenths
            self.time:SetFormattedText("%.1f / %.1f", tenths / 10, total)
        end
    elseif st.channeling then
        local remain = st.endTime - curr
        if remain <= 0 then
            st.channeling = false
            st.holdTime = curr + 0.5
            return
        end
        -- An empowered cast charges up instead of draining, and its marks are
        -- stage boundaries, so the bar has to fill towards them rather than away.
        local total = st.endTime - st.startTime
        local perc = st.empowered and ((curr - st.startTime) / total) or (remain / total)
        if perc < 0 then perc = 0 elseif perc > 1 then perc = 1 end
        self:SetValue(perc)
        local tenths = floor(remain * 10 + 0.5)
        if tenths ~= st.shownTenths then
            st.shownTenths = tenths
            self.time:SetFormattedText("%.1f", tenths / 10)
        end
    end
end

ForEachBar(function(bar) bar:SetScript("OnUpdate", OnUpdate) end)

local function StartCast(bar, spell, startMs, endMs, isChannel, spellID, isEmpowered, numStages)
    local cfg = CastbarDB(bar.unit)
    if not cfg or not cfg.enabled then return end
    local st = bar.st
    st.startTime = startMs / 1000
    st.endTime = endMs / 1000
    st.casting = not isChannel
    st.channeling = isChannel and true or false
    st.empowered = isEmpowered and true or false
    st.holdTime = nil
    st.shownTenths = nil

    if isChannel then
        BuildTickFracs(bar, bar.unit, spellID, isEmpowered, numStages, endMs - startMs)
    else
        wipe(st.tickFracs)
    end
    LayoutTicks(bar)

    -- showTarget is a player-only key: nothing tells us who a target or focus is
    -- casting at.
    local suffix = (cfg.showTarget and st.currentTarget) and (" -> " .. st.currentTarget) or ""
    bar.text:SetText(spell .. suffix)
    bar:SetStatusBarColor(unpack(isChannel and cfg.colorChanneling or cfg.colorCasting))
    bar:Show()
    -- Riding the fill texture's edge means the spark follows SetValue on its own;
    -- OnUpdate used to re-anchor it every frame on every bar. Done per cast rather
    -- than once, since the appearance pass can swap the bar's texture.
    bar.spark:ClearAllPoints()
    bar.spark:SetPoint("CENTER", bar:GetStatusBarTexture(), "RIGHT", 0, 0)
    bar.spark:Show()
end

-- Drop everything the bar is tracking. Used when a unit is swapped out from under
-- the bar and when its events are torn down.
local function ResetBar(bar)
    local st = bar.st
    st.casting, st.channeling, st.empowered = false, false, false
    st.holdTime, st.activeGUID, st.currentTarget = nil, nil, nil
    wipe(st.tickFracs)
    HideTicks(bar)
    if not (DUI_IsConfigOpen("DUI_CastbarConfig") and bar.unit == activeCastbarUnit) then
        bar:Hide()
    end
end

-- Pick up a cast already in flight. The player never needs this -- we see its
-- START event -- but target and focus change under the bar constantly, and without
-- a scan the bar stays blank until whoever was just targeted starts something new.
local function ScanUnit(bar)
    ResetBar(bar)
    local unit = bar.unit
    local cfg = CastbarDB(unit)
    if not cfg or not cfg.enabled or not UnitExists(unit) then return end

    local name, _, _, sMs, eMs, _, castID, _, spellID = UnitCastingInfo(unit)
    if name and sMs then
        bar.st.activeGUID = castID
        StartCast(bar, name, sMs, eMs, false, spellID)
        return
    end
    local isEmp, stages
    name, _, _, sMs, eMs, _, _, spellID, isEmp, stages = UnitChannelInfo(unit)
    if name and sMs then
        -- UnitChannelInfo reports no cast GUID, so there is nothing to match the
        -- eventual STOP against; the handler treats a nil GUID as "match anything
        -- on this bar", which is the right answer when we never had one.
        bar.st.activeGUID = nil
        StartCast(bar, name, sMs, eMs, true, spellID, isEmp, stages)
    end
end

-- RegisterUnitEvent, not RegisterEvent: UNIT_SPELLCAST_* fires for every unit the
-- client can see, so in a raid or a pack of nameplates the broadcast form woke this
-- handler hundreds of times a second only to fail the unit test. The filter is
-- applied at the C level, so those casts never reach Lua at all.
local CASTBAR_EVENTS = {
    "UNIT_SPELLCAST_START",
    "UNIT_SPELLCAST_STOP",
    "UNIT_SPELLCAST_DELAYED",
    "UNIT_SPELLCAST_CHANNEL_START",
    "UNIT_SPELLCAST_CHANNEL_STOP",
    "UNIT_SPELLCAST_CHANNEL_UPDATE",
    "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED",
    -- Empowered casts (Evoker) are a channel to look at but not to the event
    -- system: they fire their own EMPOWER_* set and never CHANNEL_START, so
    -- without these three the bar stayed blank for every empowered spell.
    "UNIT_SPELLCAST_EMPOWER_START",
    "UNIT_SPELLCAST_EMPOWER_STOP",
    "UNIT_SPELLCAST_EMPOWER_UPDATE",
}
-- Player only: the client fires SENT for the player's own casts and nobody else's,
-- which is why "Show Target Name" is a player-tab option.
local PLAYER_ONLY_EVENTS = { "UNIT_SPELLCAST_SENT" }
-- Not unit events: these say the token now points at somebody else, so the bar has
-- to be torn down and re-scanned.
local SWAP_EVENT = { target = "PLAYER_TARGET_CHANGED", focus = "PLAYER_FOCUS_CHANGED" }

function SetCastbarEventsRegistered(bar, on)
    on = on and true or false
    if on == bar.st.eventsOn then return end
    bar.st.eventsOn = on
    if on then
        for _, e in ipairs(CASTBAR_EVENTS) do bar:RegisterUnitEvent(e, bar.unit) end
        if bar.unit == "player" then
            for _, e in ipairs(PLAYER_ONLY_EVENTS) do bar:RegisterUnitEvent(e, bar.unit) end
        else
            bar:RegisterEvent(SWAP_EVENT[bar.unit])
            -- Enabled mid-session: adopt whatever the unit is doing right now
            -- instead of waiting for its next cast.
            ScanUnit(bar)
        end
    else
        bar:UnregisterAllEvents()
        ResetBar(bar)
    end
end

-- Touching a secret value throws, so a self-comparison under pcall is the probe for
-- whether one is safe to use. File-scope, not a closure per call, matching ReadyCheck.
local function ProbeReadable(v) return v == v end

-- Is the unit still doing the thing this bar is drawing?
--
-- Channel events carry no cast GUID (UnitChannelInfo reports none either, which is
-- why ScanUnit leaves activeGUID nil for one), so during a channel `guidMatches`
-- answers true for *any* cast GUID that arrives. Mashing a keybind mid-channel sends
-- UNIT_SPELLCAST_FAILED for the press that could not start, and with nothing to match
-- against, the FAILED branch used to take that as the channel itself failing and tear
-- the bar down mid-cast. The GUID cannot tell the two apart -- and the spell ID cannot
-- either, since the key being mashed is usually the one already channeling -- so the
-- client is asked directly: if it still has a cast or channel for this unit, the
-- failure belonged to the keypress and not to the bar.
local function StillActive(bar, unit)
    local st = bar.st
    if st.channeling then return UnitChannelInfo(unit) ~= nil end
    if st.casting then return UnitCastingInfo(unit) ~= nil end
    return false
end

local function OnCastbarEvent(self, event, unit, ...)
    if event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_FOCUS_CHANGED" then
        ScanUnit(self)
        return
    end
    if unit ~= self.unit then return end

    -- Diagnostic for "the bar vanishes when I mash a keybind mid-channel", which
    -- leaves no error behind and so cannot be read off the client any other way.
    -- Enable with /run DUI_CastbarDebug = true. Deliberately does not print the
    -- payload: on SENT the first arg is a secret target name and touching it throws.
    if DUI_CastbarDebug and self.unit == "player" then
        print(format("|cff33ff99DUI_CB|r %s cast=%s chan=%s | client: casting=%s channeling=%s",
            event, tostring(self.st.casting), tostring(self.st.channeling),
            tostring(UnitCastingInfo(unit) ~= nil), tostring(UnitChannelInfo(unit) ~= nil)))
    end

    local st = self.st
    local cfg = CastbarDB(self.unit)
    if not cfg then return end

    -- SENT is answered before anything else looks at the payload, because its first
    -- arg is the *target name* and not a cast GUID. On 12.1 that name arrives as a
    -- secret value, and comparing one while our execution is tainted is a hard error
    -- -- which is exactly what the guidMatches line below would do to it. Returning
    -- here keeps the secret out of every comparison in this handler.
    if event == "UNIT_SPELLCAST_SENT" then
        local target = ...
        -- Same probe idiom as ReadyCheck's ProbeReadable: a secret string cannot be
        -- compared or concatenated, so an unreadable name is dropped and the bar just
        -- shows the spell with no " -> target" suffix rather than erroring in
        -- StartCast when it builds that suffix.
        st.currentTarget = pcall(ProbeReadable, target) and target or nil
        return
    end

    local arg1 = ... -- castGUID for every event that reaches here

    -- A nil activeGUID means we adopted a cast we never saw start, so there is no
    -- GUID to match it against and any stop for this unit is ours.
    local guidMatches = (st.activeGUID == nil) or (st.activeGUID == arg1)

    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START"
           or event == "UNIT_SPELLCAST_EMPOWER_START" then
        -- UnitChannelInfo is what reports an empowered cast too, stages and all,
        -- so an empower start is read down the channel path.
        local isChannel = (event ~= "UNIT_SPELLCAST_START")
        st.activeGUID = arg1
        local name, _, _, sMs, eMs, spellID, isEmp, stages
        if isChannel then
            name, _, _, sMs, eMs, _, _, spellID, isEmp, stages = UnitChannelInfo(unit)
        else
            name, _, _, sMs, eMs, _, _, _, spellID = UnitCastingInfo(unit)
        end
        if name and sMs then
            StartCast(self, name, sMs, eMs, isChannel, spellID, isEmp, stages)
        else
            -- The start event can land a frame ahead of Unit*Info being populated.
            -- This used to silently do nothing, which leaves the bar hidden for the
            -- whole cast -- and if the press that caused it also clipped a channel,
            -- looks exactly like the bar vanishing mid-channel. Re-read next frame.
            if DUI_CastbarDebug and self.unit == "player" then
                print("|cff33ff99DUI_CB|r " .. event .. ": Unit*Info empty, rescanning next frame")
            end
            C_Timer.After(0, function()
                local s2 = self.st
                if not (s2.casting or s2.channeling) then ScanUnit(self) end
            end)
        end
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP"
           or event == "UNIT_SPELLCAST_EMPOWER_STOP" then
        -- The casting/channeling test is what makes the relaxed GUID match safe: a
        -- stray stop arriving after the bar has already finished cannot re-enter
        -- the hold-and-fade below.
        --
        -- StillActive is here for the same reason it is on FAILED below: a channel
        -- carries no cast GUID, so guidMatches cannot tell a stop that belongs to
        -- this channel from one belonging to the keypress that was just refused. At
        -- a real end the client has already cleared the cast by the time STOP
        -- arrives, so this only bites when the channel is genuinely still running.
        if (st.casting or st.channeling) and guidMatches and not StillActive(self, unit) then
            st.activeGUID = nil
            local wasCasting = st.casting
            st.casting, st.channeling = false, false
            self:SetStatusBarColor(unpack(cfg.colorSuccess))
            self:SetValue(wasCasting and 1 or 0)
            if wasCasting then
                self.time:SetFormattedText("%.1f / %.1f", st.endTime - st.startTime, st.endTime - st.startTime)
            else
                self.time:SetText("0.0")
            end
            st.shownTenths = nil
            self.spark:Hide()
            st.holdTime = GetTime() + 0.5
        end
    elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
        -- StillActive is the guard against a mashed keybind killing a live channel;
        -- see its comment. Erring towards ignoring a failure is the cheap direction:
        -- a real one that slips through still ends when the bar drains and fades on
        -- its own clock, it just does not flash the fail colour first.
        if (st.casting or st.channeling) and guidMatches and not StillActive(self, unit) then
            st.activeGUID = nil
            st.casting, st.channeling = false, false
            self:SetStatusBarColor(unpack(cfg.colorFail))
            st.holdTime = GetTime() + 0.5
        end
    elseif event == "UNIT_SPELLCAST_DELAYED" or event == "UNIT_SPELLCAST_CHANNEL_UPDATE"
           or event == "UNIT_SPELLCAST_EMPOWER_UPDATE" then
        if guidMatches then
            local _, _, _, sMs, eMs = UnitCastingInfo(unit)
            if not sMs then _, _, _, sMs, eMs = UnitChannelInfo(unit) end
            -- Tick marks are stored as fractions of the bar, so a channel that is
            -- extended or clipped keeps its marks in the right places for free.
            if sMs then st.startTime, st.endTime = sMs / 1000, eMs / 1000 end
        end
    end
end

ForEachBar(function(bar) bar:SetScript("OnEvent", OnCastbarEvent) end)

-- Configuration UI
-- Height is DUI_PANEL_H, not a number of its own: it is a *minimum*, and the 615
-- that used to sit here outlived the single-column layout below. It kept the frame
-- 35px taller than the docking pane, so the Test Cast button -- pinned to the
-- frame's bottom edge -- hung off the end of the pane and had to be scrolled to.
-- The tab panes size themselves now and the frame is grown to the tallest of them.
local config = DUI_CreateConfigFrame("DUI_CastbarConfig", "Castbar Customization", 320, DUI_PANEL_H, "DUI_CastbarBtn", {
    onShow = function()
        DUI_UpdateCastbarAppearance()
    end,
    onHide = function()
        ForEachBar(function(bar)
            bar:EnableMouse(false)
            if not (bar.st.casting or bar.st.channeling) then bar:Hide() end
        end)
    end,
})

-- ---- Castbar profiles ----------------------------------------------------
-- The profiles themselves live account-wide in CastbarProfiles, but which one
-- is active is stored per character in CastbarCharProfile, so alts can share a
-- profile without being forced onto the same one.
-- DanUIDB.Castbar is the live working copy the config widgets bind to. We
-- mutate it in place (never reassign its identity) so bound widgets stay valid,
-- and mirror every change back into the active profile. Since target and focus
-- are subtables of it, a profile covers all three bars.

local charKey
local function CastbarCharKey()
    if not charKey then
        local name = UnitName("player")
        if not name or name == "" then return nil end
        charKey = name .. "-" .. (GetNormalizedRealmName() or GetRealmName() or "")
    end
    return charKey
end

-- Characters that have never picked a profile inherit the old account-wide
-- choice, so nothing visibly changes on the first login after this upgrade.
function DUI_GetCastbarActiveProfile()
    local key = CastbarCharKey()
    local sel = key and DanUIDB.CastbarCharProfile and DanUIDB.CastbarCharProfile[key]
    return sel or DanUIDB.CastbarActiveProfile or "Default"
end

function DUI_SetCastbarActiveProfile(name)
    local key = CastbarCharKey()
    if not key then return end
    DanUIDB.CastbarCharProfile = DanUIDB.CastbarCharProfile or {}
    DanUIDB.CastbarCharProfile[key] = name
end

-- Defined with the panel below, but the profile switch calls it.
local RefreshCastbarConfig

local function OnCastbarChanged()
    DUI_UpdateCastbarAppearance()
    local name = DUI_GetCastbarActiveProfile()
    if name and DanUIDB.CastbarProfiles then
        DanUIDB.CastbarProfiles[name] = CopyTable(DanUIDB.Castbar)
    end
end
DUI_OnCastbarChanged = OnCastbarChanged -- main-window enable toggle hooks in here

-- Copy a profile's values into the live table without touching the selection.
-- Snapshot first: the live table can still be the same table as the profile
-- right after the pre-profile migration, and wiping it would eat the source.
local function ApplyCastbarProfile(name)
    local src = DanUIDB.CastbarProfiles[name]
    if not src then return end
    src = CopyTable(src)
    DanUIDB.Castbar = DanUIDB.Castbar or {}
    local live = DanUIDB.Castbar

    -- The target and focus subtables keep their identity across a profile switch
    -- for the same reason the live table itself does: the widgets on those two tabs
    -- captured them when they were built, and handing them a fresh table would
    -- leave every one of them writing into an orphan.
    local kept = { target = live.target, focus = live.focus }
    wipe(live)
    for k, v in pairs(src) do live[k] = v end
    for _, k in ipairs({ "target", "focus" }) do
        if kept[k] then
            local incoming = live[k]
            wipe(kept[k])
            if type(incoming) == "table" then
                for sk, sv in pairs(incoming) do kept[k][sk] = sv end
            end
            live[k] = kept[k]
        end
    end
    FillCastbarDefaults(live)

    db = live
    if RefreshCastbarConfig then RefreshCastbarConfig() end
    DUI_UpdateCastbarAppearance()
end

-- Load this character's selected profile. Called once from the login handler.
function DUI_LoadCastbarProfile()
    local name = DUI_GetCastbarActiveProfile()
    if not DanUIDB.CastbarProfiles[name] then
        name = "Default"
        DUI_SetCastbarActiveProfile(name)
    end
    ApplyCastbarProfile(name)
end

-- UnitName isn't guaranteed at ADDON_LOADED; if the character key couldn't be
-- resolved back then we picked the fallback profile, so redo it once at login.
local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    if not charKey and DanUIDB and DanUIDB.CastbarProfiles then DUI_LoadCastbarProfile() end
end)

local function SwitchCastbarProfile(name)
    if not DanUIDB.CastbarProfiles[name] then return end
    DUI_SetCastbarActiveProfile(name)
    ApplyCastbarProfile(name)
end

local function CreateCastbarProfile(name, fromCurrent)
    name = name and strtrim(name) or ""
    if name == "" or DanUIDB.CastbarProfiles[name] then return end
    DanUIDB.CastbarProfiles[name] = fromCurrent and CopyTable(DanUIDB.Castbar) or DUI_GetCastbarDefaults()
    SwitchCastbarProfile(name)
end

StaticPopupDialogs["DUI_CASTBAR_NEWPROFILE"] = {
    text = "New castbar profile name:", button1 = "Create", button2 = CANCEL,
    hasEditBox = true, whileDead = true, hideOnEscape = true, timeout = 0,
    OnAccept = function(self) CreateCastbarProfile(self.editBox:GetText(), false) end,
    EditBoxOnEnterPressed = function(self) CreateCastbarProfile(self:GetText(), false); self:GetParent():Hide() end,
}
StaticPopupDialogs["DUI_CASTBAR_COPYPROFILE"] = {
    text = "Copy current settings to new profile:", button1 = "Copy", button2 = CANCEL,
    hasEditBox = true, whileDead = true, hideOnEscape = true, timeout = 0,
    OnAccept = function(self) CreateCastbarProfile(self.editBox:GetText(), true) end,
    EditBoxOnEnterPressed = function(self) CreateCastbarProfile(self:GetText(), true); self:GetParent():Hide() end,
}
StaticPopupDialogs["DUI_CASTBAR_DELPROFILE"] = {
    text = "Delete castbar profile '%s'?", button1 = YES, button2 = NO,
    whileDead = true, hideOnEscape = true, timeout = 0,
    OnAccept = function()
        local name = DUI_GetCastbarActiveProfile()
        if name ~= "Default" then
            DanUIDB.CastbarProfiles[name] = nil
            -- Alts still pointing at it fall back to Default on their next login.
            SwitchCastbarProfile("Default")
        end
    end,
}

-- ---- panel ---------------------------------------------------------------
-- One pane per bar, built from the same function and swapped by the tab strip.
-- Panes rather than one rebound set of widgets because the factories capture their
-- db table when they are built: there is no rebinding a checkbox after the fact.

local panes = {}        -- unit -> table of widget references, plus .frame
local castbarTabs = {}

-- Re-sync every config widget to the currently active profile's values. Runs over
-- all three panes: a profile switch changes all of them, not just the visible tab.
function RefreshCastbarConfig()
    if not config.init then return end
    for _, unit in ipairs(UNITS) do
        local p, cfg = panes[unit], CastbarDB(unit)
        if p and cfg then
            if p.sldWidth  then p.sldWidth:SetValue(cfg.width) end
            if p.sldHeight then p.sldHeight:SetValue(cfg.height) end
            if p.sldY      then p.sldY:SetValue(cfg.y) end
            if p.sldFont   then p.sldFont:SetValue(cfg.fontSize) end
            if p.sldTick   then p.sldTick:SetValue(cfg.tickWidth) end
            if p.cbEnabled    then p.cbEnabled:SetChecked(cfg.enabled) end
            if p.cbHideBlizz  then p.cbHideBlizz:SetChecked(cfg.hideBlizz) end
            if p.cbShowTarget then p.cbShowTarget:SetChecked(cfg.showTarget) end
            if p.cbTicks      then p.cbTicks:SetChecked(cfg.showTicks) end
            if p.colCasting    then p.colCasting:SetBackdropColor(unpack(cfg.colorCasting)) end
            if p.colChanneling then p.colChanneling:SetBackdropColor(unpack(cfg.colorChanneling)) end
            if p.colTick       then p.colTick:SetBackdropColor(unpack(cfg.tickColor)) end
            if p.texBtn then p.texBtn:SetValue(cfg.texture) end
            if p.brdBtn then p.brdBtn:SetValue(cfg.border) end
        end
    end
    if config.profileBtn then config.profileBtn:SetValue(DUI_GetCastbarActiveProfile()) end
end

-- Only the active tab wears the accent, so this is registered as an "fn" entry:
-- the repaint is state-dependent and the registry cannot work it out from a colour.
local function PaintCastbarTabs()
    for _, t in ipairs(castbarTabs) do
        if t.unit == activeCastbarUnit then
            t:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
        else
            t:SetBackdropBorderColor(0, 0, 0, 1)
        end
    end
end

local function SetActiveCastbarUnit(unit)
    activeCastbarUnit = unit
    for _, u in ipairs(UNITS) do
        if panes[u] then panes[u].frame:SetShown(u == unit) end
        -- Mouse only on the bar being edited: three grabbable bars stacked in the
        -- middle of the screen made it far too easy to drag the wrong one.
        if bars[u] then bars[u]:EnableMouse(u == unit) end
    end
    PaintCastbarTabs()
    DUI_UpdateCastbarAppearance()
end

-- Build one unit's tab contents. Identical for all three bars apart from the
-- player-only "Show Target Name" row and the labels. Returns the height it needed.
local function BuildCastbarPane(unit, top)
    local cfg = CastbarDB(unit)
    local label = UNIT_LABEL[unit]
    local p = {}
    panes[unit] = p

    local pane = CreateFrame("Frame", nil, config)
    -- Explicit width and a single anchor: LayoutMixin:Columns divides
    -- frame:GetWidth() to place its columns, and a width derived from two anchors
    -- is not resolved on the frame's first layout pass.
    pane:SetSize(config:GetWidth(), 1)
    pane:SetPoint("TOPLEFT", config, "TOPLEFT", 0, -top)
    pane:Hide()
    p.frame = pane

    -- startY 8, not the default: DUI_LAYOUT.TOP clears a panel's title chrome, and
    -- a pane sits well below that already.
    local L = DUI_CreateLayout(pane, 8)
    L:Columns(2)

    L:Header("Size & Position")
    p.sldWidth = L:Slider("DUI_CB_" .. label .. "_Width", "Width", 100, 600, 5, cfg, "width", OnCastbarChanged,
        { value = cfg.width, tooltip = "Width of the castbar in pixels." })
    p.sldHeight = L:Slider("DUI_CB_" .. label .. "_Height", "Height", 10, 100, 1, cfg, "height", OnCastbarChanged,
        { value = cfg.height, tooltip = "Height of the castbar in pixels." })
    p.sldY = L:Slider("DUI_CB_" .. label .. "_Y", "Vertical Position", -600, 600, 1, cfg, "y", OnCastbarChanged,
        { value = cfg.y, tooltip = { body = "Distance above or below screen centre.",
                                     note = "Dragging the bar itself updates this." } })
    -- The drag handler pushes the new Y straight into this slider.
    bars[unit].sliderY = p.sldY
    p.sldFont = L:Slider("DUI_CB_" .. label .. "_Font", "Font Size", 8, 30, 1, cfg, "fontSize", OnCastbarChanged,
        { value = cfg.fontSize, tooltip = "Size of the spell name and cast timer." })

    L:Header("Channel Ticks")
    p.cbTicks = L:Checkbox("Show Channel Ticks", cfg, "showTicks", OnCastbarChanged,
        { body = "Marks each beat of a channelled spell along the bar, so you can see where the next tick lands.",
          note = "The client publishes no tick counts, so these come from a table of known channels -- an unlisted spell draws no marks. Evoker empowered casts are measured from the client and are exact." })
    p.colTick = L:ColorButton("Tick Color", cfg, "tickColor", OnCastbarChanged,
        "Colour of the channel tick marks.")
    p.sldTick = L:Slider("DUI_CB_" .. label .. "_TickWidth", "Tick Width", 1, 6, 1, cfg, "tickWidth", OnCastbarChanged,
        { value = cfg.tickWidth, tooltip = "Thickness of each tick mark in pixels." })

    L:Column(2)
    L:Header("Options")
    p.cbEnabled = L:Checkbox("Enable " .. label .. " Castbar", cfg, "enabled", function()
        OnCastbarChanged()
        -- Keeps the main window's Castbar row in step when the player bar is the
        -- one being switched: the row is docked beside this panel, so a stale tick
        -- there is visible rather than theoretical.
        if unit == "player" and DUI_SyncUIEnableChecks then DUI_SyncUIEnableChecks() end
    end, "Off means this bar is never shown, and its cast events are not even registered.")
    p.cbHideBlizz = L:Checkbox("Hide Blizzard Castbar", cfg, "hideBlizz", OnCastbarChanged,
        { body = "Hides Blizzard's own " .. unit .. " castbar so the two do not overlap.",
          note = "Unhiding it takes effect after a /reload." })
    if unit == "player" then
        p.cbShowTarget = L:Checkbox("Show Target Name", cfg, "showTarget", OnCastbarChanged,
            { body = "Appends the spell's target to the bar text, when the cast has one.",
              note = "Player only: the client reports a cast's target for your own casts and nobody else's." })
    end

    p.colCasting = L:ColorButton("Casting Color", cfg, "colorCasting", OnCastbarChanged,
        "Bar colour while casting a normal spell.")
    p.colChanneling = L:ColorButton("Channeling Color", cfg, "colorChanneling", OnCastbarChanged,
        "Bar colour while channelling, where the bar drains instead of filling.")

    L:Header("Texture & Border")
    p.texBtn = L:Dropdown("Texture", { tooltip = "Status bar texture, from anything LibSharedMedia knows about." })
    p.texBtn:SetValue(cfg.texture)
    p.texBtn:SetScript("OnClick", function(self)
        local items = {}
        for _, texName in ipairs(LSM:List("statusbar")) do table.insert(items, { text = texName, value = texName }) end
        DUI_ShowScrollDropdown(self, items, function(val)
            CastbarDB(unit).texture = val; self:SetValue(val); OnCastbarChanged()
        end, CastbarDB(unit).texture)
    end)

    p.brdBtn = L:Dropdown("Border", { tooltip = "Border art drawn around the bar. \"None\" leaves it flush." })
    p.brdBtn:SetValue(cfg.border)
    p.brdBtn:SetScript("OnClick", function(self)
        local items = { { text = "None", value = "None" } }
        for _, bName in ipairs(LSM:List("border")) do table.insert(items, { text = bName, value = bName }) end
        DUI_ShowScrollDropdown(self, items, function(val)
            CastbarDB(unit).border = val; self:SetValue(val); OnCastbarChanged()
        end, CastbarDB(unit).border)
    end)

    local paneH = L:FitHeight(45) -- room for the test buttons pinned to the bottom

    -- Two test buttons, not one: channel ticks only draw on a channel, so without
    -- the second there is no way to see the tick options work from the panel.
    local castBtn = CreateFrame("Button", nil, pane, "BackdropTemplate")
    castBtn:SetSize(100, 25)
    castBtn:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -20, 20)
    castBtn:SetText("Test Cast")
    StyleAsTealTab(castBtn)
    DUI_AddTooltip(castBtn, "Test Cast", "Runs a three-second dummy cast so you can see the current settings on the bar.")
    castBtn:SetScript("OnClick", function()
        local bar = bars[unit]
        local now = GetTime() * 1000
        bar.st.currentTarget = "Target Dummy"
        StartCast(bar, "Test Spell", now, now + 3000, false)
    end)

    local chanBtn = CreateFrame("Button", nil, pane, "BackdropTemplate")
    chanBtn:SetSize(110, 25)
    chanBtn:SetPoint("RIGHT", castBtn, "LEFT", -6, 0)
    chanBtn:SetText("Test Channel")
    StyleAsTealTab(chanBtn)
    DUI_AddTooltip(chanBtn, "Test Channel",
        { body = "Runs a three-second dummy channel, drawn as a five-tick spell.",
          note = "The only way to see the tick options without waiting for a real channel." })
    chanBtn:SetScript("OnClick", function()
        local bar = bars[unit]
        local now = GetTime() * 1000
        bar.st.currentTarget = "Target Dummy"
        StartCast(bar, "Test Channel", now, now + 3000, true)
        -- StartCast was given no spell ID and so cleared the marks; put a five-tick
        -- channel back so the tick settings have something to draw on.
        wipe(bar.st.tickFracs)
        for i = 1, 4 do bar.st.tickFracs[i] = i / 5 end
        LayoutTicks(bar)
    end)

    return paneH
end

function DUI_OpenCastbarConfig()
    db = DUI_InitModuleDB("Castbar", DUI_GetCastbarDefaults)
    FillCastbarDefaults(db)

    if not config.init then
        -- The profile block stays full width above the tabs: a profile covers all
        -- three bars, so putting it inside one of their tabs would read as though
        -- it belonged to that bar alone.
        local L = DUI_CreateLayout(config)
        L:Header("Profile")
        local profileBtn = L:Dropdown("Profile", {
            width = 150,
            tooltip = { body = "Which saved castbar profile this character uses.",
                        note = "A profile covers all three bars. Profiles are shared account-wide; the selection is per character." },
        })
        profileBtn:SetValue(DUI_GetCastbarActiveProfile())
        config.profileBtn = profileBtn
        profileBtn:SetScript("OnClick", function(self)
            local items = {}
            for name in pairs(DanUIDB.CastbarProfiles) do table.insert(items, { text = name, value = name }) end
            table.sort(items, function(a, b) return a.text < b.text end)
            DUI_ShowScrollDropdown(self, items, function(val) SwitchCastbarProfile(val) end, DUI_GetCastbarActiveProfile())
        end)

        local newBtn = CreateFrame("Button", nil, config, "BackdropTemplate")
        newBtn:SetSize(56, 24); newBtn:SetPoint("LEFT", profileBtn, "RIGHT", 6, 0); newBtn:SetText("New")
        StyleAsTealTab(newBtn)
        DUI_AddTooltip(newBtn, "New Profile", "Creates a profile at the default settings and switches to it.")
        newBtn:SetScript("OnClick", function() StaticPopup_Show("DUI_CASTBAR_NEWPROFILE") end)

        local copyBtn = CreateFrame("Button", nil, config, "BackdropTemplate")
        copyBtn:SetSize(56, 24); copyBtn:SetPoint("LEFT", newBtn, "RIGHT", 6, 0); copyBtn:SetText("Copy")
        StyleAsTealTab(copyBtn)
        DUI_AddTooltip(copyBtn, "Copy Profile", "Creates a new profile holding the settings currently on screen.")
        copyBtn:SetScript("OnClick", function() StaticPopup_Show("DUI_CASTBAR_COPYPROFILE") end)

        local delBtn = CreateFrame("Button", nil, config, "BackdropTemplate")
        delBtn:SetSize(150, 22)
        L:Place(delBtn)
        delBtn:SetText("Delete Profile")
        StyleAsDangerButton(delBtn)
        DUI_AddTooltip(delBtn, "Delete Profile",
            { body = "Deletes the active profile and falls back to Default.", note = "Default itself cannot be deleted." })
        delBtn:SetScript("OnClick", function() StaticPopup_Show("DUI_CASTBAR_DELPROFILE", DUI_GetCastbarActiveProfile()) end)

        -- ---- tab strip --------------------------------------------------
        L:Gap(6)
        local stripY = L:Height()
        local TAB_W, TAB_H = 92, 24
        for i, unit in ipairs(UNITS) do
            local t = CreateFrame("Button", nil, config, "BackdropTemplate")
            t.unit = unit
            t:SetSize(TAB_W, TAB_H)
            t:SetPoint("TOPLEFT", config, "TOPLEFT", 20 + (i - 1) * (TAB_W + 6), -stripY)
            t:SetText(UNIT_LABEL[unit])
            StyleAsTealTab(t)
            DUI_AddTooltip(t, UNIT_LABEL[unit] .. " Castbar",
                "Settings for the " .. unit .. " castbar. Each bar is positioned and enabled on its own.")
            t:SetScript("OnClick", function(self) SetActiveCastbarUnit(self.unit) end)
            castbarTabs[i] = t
        end
        -- One registration for the strip, not one per tab: the repaint walks all
        -- three anyway, and registering each would run it three times per recolour.
        DUI_RegisterAccent(castbarTabs[1], "fn", PaintCastbarTabs)

        -- ---- panes ------------------------------------------------------
        -- Built back to front. All three panes carry the same option labels, and
        -- the search index keeps one entry per label pointing at the last widget
        -- registered under it -- so building the player pane last is what makes a
        -- search for "Width" flash a control that is actually on screen, rather
        -- than the identical one sitting behind a tab nobody has opened.
        local paneTop = stripY + TAB_H + 10
        local tallest = 0
        for i = #UNITS, 1, -1 do
            local h = BuildCastbarPane(UNITS[i], paneTop)
            if h > tallest then tallest = h end
        end
        -- Every pane is given the height of the tallest, so the test buttons sit on
        -- the same line whichever tab is open and the panel does not resize under
        -- the cursor when tabs are switched.
        for _, unit in ipairs(UNITS) do panes[unit].frame:SetHeight(tallest) end
        config:SetHeight(math.max(DUI_PANEL_H, paneTop + tallest))

        config.init = true
    end

    RefreshCastbarConfig()
    config:Show()
    SetActiveCastbarUnit(activeCastbarUnit)
end
