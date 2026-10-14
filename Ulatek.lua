-- Ulatek.lua
-- Sound cues for the Ula'tek wave-direction calls (encounter 3492).
--
-- Compatible with Northern Sky Raid Tools' "Ula'tek Left" / "Ula'tek Right" macros,
-- but written from scratch: NSRT is All Rights Reserved and none of its code is used.
-- What is shared is the convention, which is a fact about how raids run the fight:
--   /yell <anything>  = Left
--   /raid <anything>  = Right   (CHAT_MSG_RAID, or CHAT_MSG_RAID_LEADER from the lead)
--
-- The direction comes from the *event name*, never the message. During an encounter
-- chat text and sender arrive as secret values on 12.x, so neither can be compared.
-- The channel is the only readable signal there is, which is why the macros use two
-- different channels in the first place. The OnEvent handler below deliberately
-- never touches its payload.
--
-- Because any raid chat reads as "Right", the chat events are only registered inside
-- short windows around the moments a call is expected, the same windows NSRT uses,
-- so stray chat during the rest of the fight can't fire a cue.

local LSM = LibStub:GetLibrary("LibSharedMedia-3.0")
local GetTime, PlaySoundFile, C_Timer = GetTime, PlaySoundFile, C_Timer
local InCombatLockdown = InCombatLockdown

local db

local ENCOUNTER_ID = 3492
local DIFF_HEROIC, DIFF_MYTHIC, DIFF_MYTHIC_FLEX = 15, 16, 233

-- Mythic call windows, seconds from ENCOUNTER_START, each open WINDOW_PAD either side.
-- The waves and the submerge are fixed in time on Mythic; NSRT's early-transition
-- correction only shifts things after ~165s, so none of these drift.
local WINDOW_PAD = 6
local MYTHIC_WINDOWS = {
    { name = "First Wave",  time = 56 },
    { name = "Submerge",    time = 79.4 },
    { name = "Second Wave", time = 113 },
}
-- NSRT reads yell/raid/raid warning as the transition soak pattern in this span, on
-- every difficulty. "Listen All Fight" closes here so those presses aren't cues.
local TRANSITION_FROM, TRANSITION_TO = 325, 340

-- Two callers, or one caller double-tapping, would otherwise stack the clip. A
-- *different* direction inside this time still plays: that is a correction.
local DEDUPE = 1.0
local TEST_LISTEN = 30

-- Northern Sky registers its own spoken Left/Right clips with LSM. DanUI loads first,
-- so these can't be checked at ADDON_LOADED; PlayDirection falls back to text-to-speech
-- at play time when the picked name isn't registered (NSRT not installed).
local NSRT_LEFT, NSRT_RIGHT = "|cFF4BAAC8Left|r", "|cFF4BAAC8Right|r"
local TTS_VALUE = "TTS"

function DUI_GetUlatekDefaults()
    return {
        enabled = false,        -- off by default: only useful to raids running the macros
        leftSound = NSRT_LEFT,
        rightSound = NSRT_RIGHT,
        submergeSound = true,   -- also cue the submerge call, not only the two waves
        wholeFight = false,     -- listen for the whole pull, any difficulty
    }
end

local function DB()
    db = db or (DanUIDB and DUI_InitModuleDB("Ulatek", DUI_GetUlatekDefaults))
    return db or DUI_GetUlatekDefaults()
end

-- ---- playback ---------------------------------------------------------------

local function SpeakDirection(text)
    if not (C_VoiceChat and C_VoiceChat.SpeakText) then return false end
    local voices = C_VoiceChat.GetTtsVoices and C_VoiceChat.GetTtsVoices()
    local voiceID = voices and voices[1] and voices[1].voiceID or 0
    local rate = C_TTSSettings and C_TTSSettings.GetSpeechRate and C_TTSSettings.GetSpeechRate() or 0
    -- Overlap on: a correction called a second later shouldn't queue behind the first.
    C_VoiceChat.SpeakText(voiceID, text, rate, 100, true)
    return true
end

local missingNoticeShown = {}

-- direction is "Left" or "Right".
local function PlayDirection(direction)
    local t = DB()
    local pick = direction == "Left" and t.leftSound or t.rightSound
    if pick == "None" then return end
    if pick ~= TTS_VALUE then
        local path = pick and LSM:Fetch("sound", pick, true)
        if path and PlaySoundFile(path, "Master") then return end
        -- Said once per sound per session, not per call: the condition holds all night.
        if pick and not missingNoticeShown[pick] then
            missingNoticeShown[pick] = true
            print(DUI_AccentText("DanUI") .. ": Ula'tek " .. direction .. " sound '" .. tostring(pick)
                .. "|r' isn't available (is Northern Sky loaded?) - speaking it instead.")
        end
    end
    SpeakDirection(direction)
end

-- ---- listening --------------------------------------------------------------

local encounterFrame = CreateFrame("Frame")
local chatFrame = CreateFrame("Frame")
local CHAT_EVENTS = { "CHAT_MSG_YELL", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER" }

local listening = false
local currentWindow       -- name of the open window, for /duiula and the submerge rule
local timers = {}
local generation = 0      -- bumped on every encounter start/end; stale timers bail
local lastDir, lastAt = nil, 0
local wrongDiffNoticeShown = false

local function SetListening(on, windowName)
    currentWindow = on and windowName or nil
    if on == listening then return end
    listening = on
    for _, e in ipairs(CHAT_EVENTS) do
        if on then chatFrame:RegisterEvent(e) else chatFrame:UnregisterEvent(e) end
    end
end

local function CancelTimers()
    for i = #timers, 1, -1 do
        timers[i]:Cancel()
        timers[i] = nil
    end
end

local function StopListening()
    generation = generation + 1
    CancelTimers()
    SetListening(false)
end

-- Runs fn after `delay`, unless the encounter that scheduled it has since ended.
local function At(delay, fn)
    local gen = generation
    timers[#timers + 1] = C_Timer.NewTimer(math.max(delay, 0), function()
        if gen == generation then fn() end
    end)
end

-- The payload (message, sender, ...) is never read: it is secret during the encounter
-- and comparing it would throw. The event name alone carries the direction.
chatFrame:SetScript("OnEvent", function(_, event)
    if not listening or not DB().enabled then return end
    if currentWindow == "Submerge" and not DB().submergeSound then return end
    local direction = (event == "CHAT_MSG_YELL") and "Left" or "Right"
    local now = GetTime()
    if direction == lastDir and now - lastAt < DEDUPE then return end
    lastDir, lastAt = direction, now
    PlayDirection(direction)
end)

local function ArmEncounter(difficultyID)
    StopListening()
    local t = DB()
    local mythic = difficultyID == DIFF_MYTHIC or difficultyID == DIFF_MYTHIC_FLEX

    if t.wholeFight then
        SetListening(true, "Whole Fight")
        At(TRANSITION_FROM, function() SetListening(false) end)
        At(TRANSITION_TO, function() SetListening(true, "Whole Fight") end)
        return
    end

    if not mythic then
        -- Silent declines read as bugs, so say it once. Heroic has no fixed submerge
        -- timing to build windows from; whole-fight mode is the way to get it there.
        if difficultyID == DIFF_HEROIC and not wrongDiffNoticeShown then
            wrongDiffNoticeShown = true
            print(DUI_AccentText("DanUI") .. ": Ula'tek wave calls only listen on Mythic. Tick "
                .. "\"Listen All Fight\" in the Ula'tek panel to use them here.")
        end
        return
    end

    for _, w in ipairs(MYTHIC_WINDOWS) do
        At(w.time - WINDOW_PAD, function() SetListening(true, w.name) end)
        At(w.time + WINDOW_PAD, function()
            if currentWindow == w.name then SetListening(false) end
        end)
    end
end

encounterFrame:SetScript("OnEvent", function(_, event, encounterID, _, difficultyID)
    if event == "ENCOUNTER_START" then
        if encounterID == ENCOUNTER_ID and DB().enabled then
            ArmEncounter(difficultyID)
        end
    elseif event == "ENCOUNTER_END" then
        StopListening()
    end
end)

local encounterEventsOn = false
local function SetUlatekEventsRegistered(on)
    on = on and true or false
    if on == encounterEventsOn then return end
    encounterEventsOn = on
    if on then
        encounterFrame:RegisterEvent("ENCOUNTER_START")
        encounterFrame:RegisterEvent("ENCOUNTER_END")
    else
        encounterFrame:UnregisterAllEvents()
        StopListening()
    end
end

-- A listening window opened by hand, so the real chat path can be checked in a raid
-- without pulling the boss. Ends early on any ENCOUNTER_END like a real window.
local function ListenNow()
    if not DB().enabled then
        print(DUI_AccentText("DanUI") .. ": Ula'tek is switched off - tick its row first.")
        return
    end
    -- StopListening would cancel a live pull's windows along with any earlier test.
    if IsEncounterInProgress() then
        print(DUI_AccentText("DanUI") .. ": not during an encounter - the real windows are running.")
        return
    end
    StopListening()
    SetListening(true, "Test")
    At(TEST_LISTEN, function()
        SetListening(false)
        print(DUI_AccentText("DanUI") .. ": Ula'tek test listen finished.")
    end)
    print(DUI_AccentText("DanUI") .. ": listening for " .. TEST_LISTEN .. "s - /yell plays Left, "
        .. "/raid plays Right. Needs a raid group for /raid.")
end

-- ---- module hooks -----------------------------------------------------------

function DUI_InitUlatek()
    db = DUI_InitModuleDB("Ulatek", DUI_GetUlatekDefaults)
    SetUlatekEventsRegistered(db.enabled)
end

-- Rail apply hook. Off mid-pull closes any open window immediately.
function DUI_UlatekApplyEnabled(on)
    SetUlatekEventsRegistered(on)
end

-- ---- macros -----------------------------------------------------------------

-- Same names and icons as Northern Sky's "Create Macros" button, so pressing either
-- one updates the same pair rather than leaving duplicates on the macro page.
local MACROS = {
    { name = "Ula'tek Left",  icon = 450906, body = "/yell Left" },
    { name = "Ula'tek Right", icon = 450908, body = "/raid Right" },
}

local function CreateUlatekMacros()
    if InCombatLockdown() then
        print(DUI_AccentText("DanUI") .. ": can't edit macros in combat.")
        return
    end
    local made, updated = 0, 0
    for _, m in ipairs(MACROS) do
        if GetMacroInfo(m.name) then
            EditMacro(m.name, m.name, m.icon, m.body)
            updated = updated + 1
        else
            local numAccount = GetNumMacros()
            if numAccount >= (MAX_ACCOUNT_MACROS or 120) then
                print(DUI_AccentText("DanUI") .. ": general macro page is full - couldn't create '" .. m.name .. "'.")
            else
                CreateMacro(m.name, m.icon, m.body)
                made = made + 1
            end
        end
    end
    print(DUI_AccentText("DanUI") .. string.format(": Ula'tek macros - %d created, %d updated (General tab).", made, updated))
end

-- ---- /duiula ----------------------------------------------------------------

local function SoundStatus(pick)
    if pick == "None" then return "|cffFFA500none|r" end
    if pick == TTS_VALUE then return "text-to-speech" end
    if LSM:Fetch("sound", pick, true) then return tostring(pick) .. "|r" end
    return tostring(pick) .. "|r |cffFFA500(not registered - will speak instead)|r"
end

SLASH_DUIULATEK1 = "/duiula"
SLASH_DUIULATEK2 = "/duiulatek"
SlashCmdList.DUIULATEK = function(msg)
    msg = strtrim(strlower(msg or ""))
    if msg == "test" or msg == "listen" then return ListenNow() end
    if msg == "left" or msg == "right" then
        return PlayDirection(msg == "left" and "Left" or "Right")
    end
    local t = DB()
    print(DUI_AccentText("[DUI]") .. " Ula'tek wave calls - |cffffffff/duiula test|r listens for "
        .. TEST_LISTEN .. "s, |cffffffff/duiula left|r / |cffffffffright|r plays a cue.")
    print("  Module: " .. (t.enabled and "|cff00FF00enabled|r" or "|cffFFA500disabled|r"))
    print("  Mode: " .. (t.wholeFight and "whole fight, any difficulty (except " .. TRANSITION_FROM .. "-" .. TRANSITION_TO .. "s)"
        or "Mythic windows only (56s / 79.4s / 113s, +/-" .. WINDOW_PAD .. "s)"))
    print("  Left: " .. SoundStatus(t.leftSound) .. "   Right: " .. SoundStatus(t.rightSound))
    print("  Submerge call: " .. (t.submergeSound and "cued" or "|cffFFA500ignored|r"))
    print("  Listening now: " .. (listening and ("|cff00FF00yes|r (" .. tostring(currentWindow) .. ")") or "no"))
end

-- ---- config panel -----------------------------------------------------------

local config = DUI_CreateConfigFrame("DUI_UlatekConfig", "Ula'tek", 320, 300, "DUI_UlatekBtn")

local function PanelButton(L, text, tip, onClick)
    local b = CreateFrame("Button", nil, config, "BackdropTemplate")
    b:SetSize(150, 22)
    L:Place(b)
    b:SetText(text)
    StyleAsTealTab(b)
    DUI_AddTooltip(b, text, tip)
    b:SetScript("OnClick", onClick)
    return b
end

-- Picking a sound previews it, same as Combat Alerts. The TTS entry is the fallback
-- that works with no soundpack at all.
local function ShownName(v) return v == TTS_VALUE and "Text to Speech" or (v or "None") end

local function SoundDropdown(L, key, direction, tooltip)
    local btn = L:Dropdown(direction .. " Sound", { tooltip = tooltip })
    btn:SetValue(ShownName(db[key]))
    btn:SetScript("OnClick", function(self)
        local items = {
            { text = "None", value = "None" },
            { text = "Text to Speech", value = TTS_VALUE },
        }
        for _, s in ipairs(LSM:List("sound")) do
            if s ~= "None" then items[#items + 1] = { text = s, value = s } end
        end
        DUI_ShowScrollDropdown(self, items, function(val)
            db[key] = val
            self:SetValue(ShownName(val))
            PlayDirection(direction)
        end, db[key])
    end)
    return btn
end

function DUI_OpenUlatekConfig()
    db = DUI_InitModuleDB("Ulatek", DUI_GetUlatekDefaults)

    if config.leftBtn then config.leftBtn:SetValue(ShownName(db.leftSound)) end
    if config.rightBtn then config.rightBtn:SetValue(ShownName(db.rightSound)) end

    if not config.init then
        local L = DUI_CreateLayout(config)

        L:Header("Wave Calls")
        L:Text("Plays a sound when the wave direction is called with Northern Sky's Ula'tek macros: "
            .. "/yell is Left, /raid is Right. Only the chat channel is used - message text is hidden "
            .. "from addons during the fight.")
        config.leftBtn = SoundDropdown(L, "leftSound", "Left",
            { body = "Played when someone /yells during a call window. Picking one previews it.",
              note = "Defaults to Northern Sky's own Left clip. Without Northern Sky it is spoken instead." })
        config.rightBtn = SoundDropdown(L, "rightSound", "Right",
            { body = "Played when someone types in raid chat during a call window. Picking one previews it.",
              note = "Defaults to Northern Sky's own Right clip. Without Northern Sky it is spoken instead." })
        L:Checkbox("Cue the Submerge Call", db, "submergeSound", nil,
            "Also plays the sound for the call at the submerge (~79s), not only the two waves. Northern Sky shows nothing for that call by itself - it folds it into the second wave's text.")

        L:Header("Listening")
        L:Checkbox("Listen All Fight", db, "wholeFight", nil, {
            body = "Listens for the whole pull on any difficulty, instead of only around the Mythic waves and submerge.",
            note = "Any raid chat then plays the Right sound. Skips " .. TRANSITION_FROM .. "-" .. TRANSITION_TO
                .. "s, where the same macros call the transition soak pattern.",
        })
        L:Text("Default: Mythic only, from 6s before to 6s after the first wave (56s), the submerge (79.4s) and the second wave (113s) - the same windows Northern Sky uses.")

        L:Header("Macros & Testing")
        PanelButton(L, "Create Macros",
            "Creates or updates 'Ula'tek Left' (/yell Left) and 'Ula'tek Right' (/raid Right) on the General macro tab. Same names as Northern Sky's, so no duplicates.",
            CreateUlatekMacros)
        PanelButton(L, "Listen Now (" .. TEST_LISTEN .. "s)",
            "Opens a " .. TEST_LISTEN .. "-second listening window right now, so the macros can be tried in a raid group without pulling.",
            ListenNow)
        L:Text("/duiula shows what the module will do and why.")

        L:FitHeight()
        config.init = true
    end
    config:Show()
end
