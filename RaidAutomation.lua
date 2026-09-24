-- RaidAutomation.lua
-- Raid-night housekeeping: sets the raid difficulty on the days you raid.
--
-- Was AutoRaidDiff.lua, which only carried the difficulty schedule. The saved
-- table moved with the rename, from DanUIDB.AutoRaidDiff to
-- DanUIDB.RaidAutomation; MigrateDB below carries an existing schedule across.
--
-- The schedule is applied once per raid group: after you form (or take lead of) a
-- raid, DUI sets the difficulty for today and then leaves it alone, so manually
-- changing it afterwards sticks. Leaving the raid re-arms it for the next one.
--
-- The Mythic raid group filter used to live here and is gone as of 12.1. Driving
-- Blizzard's filter meant calling CRF_SetFilterGroup / CompactRaidFrameContainer:
-- TryUpdate() from addon code, which rebuilds every CompactUnitFrame - including
-- CompactPartyFrame's - through CompactUnitFrame_SetUpFrame while tainted by us.
-- SetUpFrame re-installs the frames' own script handlers, so from that point on
-- Blizzard's update loop runs tainted by DanUI, and every secret value it touches
-- inside an instance (health colour, range alpha, temp max HP loss) throws. There
-- is no untainted entry point for the filter; see the errors in !BugGrabber for
-- session 1450 if this is ever tempting again.
-- Hide empty groups with the raid manager's own checkboxes instead.

local db -- Local reference to DanUIDB.RaidAutomation

local OFF = 0

-- Raid difficulty IDs accepted by SetRaidDifficultyID. LFR is deliberately absent:
-- it is chosen through the group finder, not set on a formed raid.
local DIFFICULTIES = { 14, 15, 16 }

-- date("*t").wday is 1 = Sunday .. 7 = Saturday, and the schedule is keyed by it.
-- The config lists Monday first, which is how a raid week actually reads.
local DAY_ORDER = { 2, 3, 4, 5, 6, 7, 1 }

-- Indexed by wday. Blizzard's CALENDAR_WEEKDAY_NAMES would be localized, but it
-- lives in the load-on-demand Calendar addon and is nil at our load time; the rest
-- of DanUI is hardcoded English anyway.
local DAY_NAMES = {
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
}

local FALLBACK_DIFF_NAMES = { [14] = "Normal", [15] = "Heroic", [16] = "Mythic" }

-- GetDifficultyInfo gives the localized name; fall back if the ID is unknown to
-- this client so the dropdown never renders blank rows.
local function DifficultyName(id)
    if id == OFF then return "Off" end
    local name = GetDifficultyInfo(id)
    return name or FALLBACK_DIFF_NAMES[id] or tostring(id)
end

function DUI_GetRaidAutomationDefaults()
    return {
        enabled = true,
        announce = true,
        -- Seeded with the schedule that used to be hardcoded in RaidToolsModule.
        days = {
            [1] = OFF, -- Sunday
            [2] = OFF, -- Monday
            [3] = 16,  -- Tuesday   - Mythic
            [4] = 15,  -- Wednesday - Heroic
            [5] = 16,  -- Thursday  - Mythic
            [6] = OFF, -- Friday
            [7] = OFF, -- Saturday
        },
    }
end

-- ---------------------------------------------------------------------------
-- Difficulty schedule
-- ---------------------------------------------------------------------------

local applied = false -- latched for the life of the current raid group
local applyTimer

local function TryApplyDifficulty()
    if not db or not db.enabled then return end

    -- Out of a raid: re-arm so the next group you form gets its own pass.
    if not IsInRaid() then
        applied = false
        return
    end

    -- In a raid but not leading. Don't re-arm - if lead is passed to us later,
    -- PARTY_LEADER_CHANGED brings us back here with the latch still open.
    if not UnitIsGroupLeader("player") then return end
    if applied then return end

    -- Evaluating counts as the group's one pass, whether or not a change follows.
    applied = true

    local wday = date("*t").wday
    local target = (db.days and db.days[wday]) or OFF
    if target == OFF then return end
    if GetRaidDifficultyID() == target then return end

    SetRaidDifficultyID(target)
    if db.announce then
        print(string.format("|cFF00FF00[DUI]|r %s raid night: difficulty set to %s.",
            DAY_NAMES[wday], DifficultyName(target)))
    end
end

-- The roster and leader flags are not settled the instant these events fire, so
-- coalesce the burst that forming a raid or zoning produces into one pass.
local function ScheduleUpdate()
    if applyTimer then applyTimer:Cancel() end
    applyTimer = C_Timer.NewTimer(0.5, TryApplyDifficulty)
end

-- ---------------------------------------------------------------------------
-- Configuration UI
-- ---------------------------------------------------------------------------

local config = DUI_CreateConfigFrame("DUI_RaidAutomationConfig", "Raid Automation", 320, 460, "DUI_RaidAutomationBtn")

local ROW_HEIGHT = 26

local function BuildDifficultyItems()
    local items = { { text = "Off", value = OFF } }
    for _, id in ipairs(DIFFICULTIES) do
        items[#items + 1] = { text = DifficultyName(id), value = id }
    end
    return items
end

local function RefreshRows()
    if config.rows then
        for _, row in ipairs(config.rows) do
            row.btn:SetValue(DifficultyName(db.days[row.wday] or OFF))
        end
    end
end

function DUI_OpenRaidAutomationConfig()
    if not db then DUI_InitRaidAutomationDB() end

    if not config.init then
        local L = DUI_CreateLayout(config)
        L:Header("Raid difficulty")
        -- No "Enable" tick in here: the module's flag is the one on its row in the
        -- main window, and a second box bound to the same key only ever gave the
        -- user two places to look and one of them out of date.
        config.announceCheck = L:Checkbox("Announce in chat", db, "announce", nil,
            "Prints a line when the raid difficulty is changed.")

        L:Header("Difficulty by day")

        -- All seven day rows share one full-width column: a single run of days
        -- reads as the week it is, and the dropdowns line up on one edge.
        config.rows = {}
        for i, wday in ipairs(DAY_ORDER) do
            local y = L:Y()

            local label = config:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
            label:SetPoint("TOPLEFT", L.x + 40, y - 3)
            label:SetText(DAY_NAMES[wday])

            local btn = DUI_CreateDropdown(config, nil, {
                width = L:ContentWidth(120), height = 22,
                tooltip = "Difficulty applied on " .. DAY_NAMES[wday] .. ". \"Off\" leaves that day alone.",
            })
            btn:SetPoint("TOPLEFT", L.x + 120, y)
            btn.wday = wday
            btn:SetValue(DifficultyName(db.days[wday] or OFF))
            btn:SetScript("OnClick", function(self)
                DUI_ShowScrollDropdown(self, BuildDifficultyItems(), function(val)
                    db.days[self.wday] = val
                    self:SetValue(DifficultyName(val))
                    -- A schedule edit re-arms the latch, so a change made while
                    -- already in a raid takes effect on the next roster update.
                    applied = false
                end, db.days[self.wday] or OFF)
            end)

            L:Gap(ROW_HEIGHT)
            config.rows[i] = { wday = wday, label = label, btn = btn }
        end

        L:Gap()
        L:Text("Applied once when you form or take lead of a raid. Changing the difficulty yourself afterwards is left alone.")

        L:FitHeight()
        config.init = true
    end

    config.announceCheck:SetChecked(db.announce)
    RefreshRows()
    config:Show()
end

-- ---------------------------------------------------------------------------

-- Pre-rename saved variables. AutoRaidDiff's table is moved across wholesale so an
-- existing schedule - and the panel's parked position - survives the rename.
local function MigrateDB()
    if DanUIDB.AutoRaidDiff and not DanUIDB.RaidAutomation then
        DanUIDB.RaidAutomation = DanUIDB.AutoRaidDiff
    end
    DanUIDB.AutoRaidDiff = nil

    local pos = DanUIDB.ConfigPos
    if pos and pos.DUI_AutoRaidDiffConfig then
        pos.DUI_RaidAutomationConfig = pos.DUI_RaidAutomationConfig or pos.DUI_AutoRaidDiffConfig
        pos.DUI_AutoRaidDiffConfig = nil
    end
end

-- Split out of DUI_InitRaidAutomation so opening the panel before login has run
-- the module's init still gets a populated db.
function DUI_InitRaidAutomationDB()
    MigrateDB()
    db = DUI_InitModuleDB("RaidAutomation", DUI_GetRaidAutomationDefaults)

    -- Backfill anything the saved table is missing (e.g. after a defaults change,
    -- or a schedule carried over from an older DUI).
    local defaults = DUI_GetRaidAutomationDefaults()
    db.days = db.days or {}
    for wday, v in pairs(defaults.days) do
        if db.days[wday] == nil then db.days[wday] = v end
    end

    -- Left over from the group filter removed in 12.1. Dropped so a saved table
    -- from an older DUI does not keep carrying settings nothing reads.
    db.groupFilter, db.hideGroups = nil, nil
    return db
end

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", ScheduleUpdate)

-- Registered only while the row is ticked, so an off module is not woken by every
-- roster change just to reach TryApplyDifficulty's own flag check.
local function SetEventsRegistered(on)
    if on then
        eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
        eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
        eventFrame:RegisterEvent("PARTY_LEADER_CHANGED")
        -- Difficulty can be switched from inside the instance too.
        eventFrame:RegisterEvent("PLAYER_DIFFICULTY_CHANGED")
    else
        eventFrame:UnregisterAllEvents()
        if applyTimer then applyTimer:Cancel(); applyTimer = nil end
    end
end

-- Apply hook for the main window's rail. Switching on re-arms the latch and runs a
-- pass, so ticking it while already leading tonight's raid takes effect now.
function DUI_RaidAutomationApplyEnabled(enabled)
    SetEventsRegistered(enabled)
    if enabled then
        applied = false
        ScheduleUpdate()
    end
end

function DUI_InitRaidAutomation()
    DUI_InitRaidAutomationDB()
    SetEventsRegistered(db.enabled)

    -- Covers a /reload taken while already leading a raid or standing in one.
    C_Timer.After(1.0, TryApplyDifficulty)
end
