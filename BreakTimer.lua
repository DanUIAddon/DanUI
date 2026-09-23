-- BreakTimer.lua
-- On-screen display for the BigWigs break timer (/break).
--
-- BigWigs' Break plugin fires BigWigs_StartBreak / BigWigs_StopBreak, and it routes
-- DBM's break sync (the "BT" addon message) through the same path, so breaks started
-- by either addon land here. Timeline.lua deliberately excludes the break bar from the
-- encounter timeline so it is only ever shown once, here.
--
-- Raid leaders often send a long /pull (e.g. "/pull 300") as an informal break, so a
-- pull timer at or over `pullThreshold` is displayed as a break too.
--
-- Optionally (`readyCheckOnEnd`) the leader's client fires a ready check the moment a
-- real break expires, which is the thing that actually gets people back at the keyboard.

local LSM = LibStub:GetLibrary("LibSharedMedia-3.0")
local db -- Local reference to DanUIDB.BreakTimer

function DUI_GetBreakTimerDefaults()
    return {
        enabled = true,
        label = "Break Time!",
        point = "CENTER",
        relPoint = "CENTER",
        x = 0,
        y = 250,
        fontSize = 24,
        fontColor = {0.51, 0.65, 0.44, 1}, -- Default Sage Green
        -- A long /pull is commonly used as an informal break, so treat one as a break.
        usePullTimer = true,
        pullThreshold = 120, -- seconds; pull timers at least this long count as a break
        -- Fire a ready check the moment a break runs out. Off by default: it acts on
        -- the whole group, so it has to be asked for.
        readyCheckOnEnd = false,
        -- Set of LibSharedMedia sound names; one is picked at random per break.
        sounds = { ["Quest Failed"] = true },
    }
end

--------------------------------------------------------------------------------
-- Display frame
--------------------------------------------------------------------------------

local frame = CreateFrame("Frame", "DUI_BreakTimerFrame", UIParent, "BackdropTemplate")
frame:SetSize(200, 70)
frame:SetPoint("CENTER", 0, 250)
frame:Hide()
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self) if self:IsMovable() then self:StartMoving() end end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    if db then db.point, db.relPoint, db.x, db.y = point, relPoint, x, y end
end)

frame.label = frame:CreateFontString(nil, "OVERLAY", "DUI_FontLarge")
frame.label:SetPoint("TOP", 0, -8)

frame.time = frame:CreateFontString(nil, "OVERLAY", "DUI_FontLarge")
frame.time:SetPoint("TOP", frame.label, "BOTTOM", 0, -4)

frame.active = false

function DUI_UpdateBreakTimerAppearance()
    if not DanUIDB then return end
    DanUIDB.BreakTimer = DanUIDB.BreakTimer or DUI_GetBreakTimerDefaults()
    db = DanUIDB.BreakTimer

    local size = db.fontSize or 24
    -- Lowest strata: a break display should never sit on top of other UI. The one
    -- exception is while the config panel is open, where it has to be clickable to drag.
    local configOpen = DUI_IsConfigOpen("DUI_BreakTimerConfig")
    frame:SetFrameStrata(configOpen and "DIALOG" or "BACKGROUND")
    frame:ClearAllPoints()
    frame:SetPoint(db.point or "CENTER", UIParent, db.relPoint or db.point or "CENTER", db.x or 0, db.y or 250)

    frame.label:SetFont(DUI_FontPath, size, "OUTLINE")
    -- The countdown is the part you actually read across the room, so it runs larger.
    frame.time:SetFont(DUI_FontPath, size * 1.4, "OUTLINE")
    local color = db.fontColor or DUI_Theme.Accent
    frame.label:SetTextColor(unpack(color))
    frame.time:SetTextColor(unpack(color))
    frame.label:SetText(db.label or "Break Time!")

    -- Size off the widest thing the frame will ever hold ("59:59"), so the backdrop
    -- doesn't jitter as the digits change.
    local prev = frame.time:GetText()
    frame.time:SetText("59:59")
    local width = math.max(frame.label:GetStringWidth(), frame.time:GetStringWidth()) + 40
    frame:SetSize(math.max(width, 140), (size * 2.4) + 24)
    frame.time:SetText(prev or "")

    -- While the config is open the frame is always visible and draggable.
    if configOpen then
        frame:EnableMouse(true)
        frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        frame:SetBackdropColor(0, 0, 0, 0.5)
        frame:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
        if not frame.active then frame.time:SetText("5:00") end
        frame:Show()
    else
        frame:EnableMouse(false)
        frame:SetBackdrop(nil)
        if not frame.active or not db.enabled then frame:Hide() end
    end
end

--------------------------------------------------------------------------------
-- Countdown
--------------------------------------------------------------------------------

local endTime = 0
local lastSec = -1
local BreakTimerOnUpdate -- defined below; attached only while a break is running
local ReadyCheckOnBreakEnd -- defined below; runs once when a break reaches zero
local breakSource -- "break", "pull" or "test": which kind of timer is on screen

-- `source` stops only a display started by that source, so cancelling a pull doesn't
-- clear a real break (and vice versa). Omit it to stop whatever is running.
local function StopBreak(source)
    if source and breakSource ~= source then return end
    frame.active = false
    breakSource = nil
    lastSec = -1
    -- While the config panel is open the frame stays shown so it can be dragged, and a
    -- shown frame keeps running its OnUpdate. Detaching here means the only time the
    -- tick costs anything is while a break is genuinely counting down.
    frame:SetScript("OnUpdate", nil)
    frame:UnregisterEvent("PLAYER_REGEN_DISABLED")
    if not DUI_IsConfigOpen("DUI_BreakTimerConfig") then
        frame:Hide()
    end
end

function BreakTimerOnUpdate(self)
    if not self.active then return end
    local remaining = endTime - GetTime()
    if remaining <= 0 then
        -- Read the source before StopBreak clears it: only a real break earns the
        -- ready check. A pull timer hitting zero means combat is starting, and the
        -- test button is not something the raid should hear about.
        local expired = breakSource
        StopBreak()
        if expired == "break" then ReadyCheckOnBreakEnd() end
        return
    end
    -- The m:ss text only changes once per second; skip formatting on the other frames.
    local sec = math.ceil(remaining)
    if sec ~= lastSec then
        lastSec = sec
        self.time:SetFormattedText("%d:%02d", math.floor(sec / 60), sec % 60)
    end
end

-- Reaching zero is the only reliable "the break expired" signal: BigWigs sends
-- BigWigs_StopBreak for an explicit `/break 0` and nothing at all when a break simply
-- runs out, so there is no message to listen for.
--
-- Every client in the raid sees the break end, so this is deliberately quiet about
-- refusing -- only the one or two people holding lead should actually pull the
-- trigger, and the rest should not be printing about it. Several assists firing at
-- once is harmless: the server runs one ready check and drops the rest.
function ReadyCheckOnBreakEnd()
    if not db or not db.enabled or not db.readyCheckOnEnd then return end
    if not IsInGroup() then return end
    if not UnitIsGroupLeader("player") and not UnitIsGroupAssistant("player") then return end
    -- The server refuses a ready check in either of these, and BigWigs will not have
    -- started a break during an encounter in the first place.
    if InCombatLockdown() or IsEncounterInProgress() then return end

    if C_PartyInfo and C_PartyInfo.DoReadyCheck then
        C_PartyInfo.DoReadyCheck()
    elseif DoReadyCheck then
        DoReadyCheck()
    end
end

local function PlayRandomBreakSound()
    if not db or not db.sounds then return end
    local pool = {}
    for name, on in pairs(db.sounds) do
        if on and LSM:Fetch("sound", name, true) then
            pool[#pool + 1] = name
        end
    end
    if #pool == 0 then return end
    local path = LSM:Fetch("sound", pool[math.random(#pool)], true)
    if path then PlaySoundFile(path, "Master") end
end

local function StartBreak(seconds, source)
    if not db or not db.enabled then return end
    local duration = tonumber(seconds)
    if not duration or duration <= 0 then return end

    endTime = GetTime() + duration
    lastSec = -1
    breakSource = source or "break"
    frame.active = true
    frame:SetScript("OnUpdate", BreakTimerOnUpdate)
    -- Combat means the break is over, whatever the clock says. Registered only while a
    -- break is on screen, so it costs nothing the rest of the time.
    frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    frame:Show()
    PlayRandomBreakSound()
end

-- Entering combat ends any break display outright. Goes through StopBreak() with no
-- source, so it clears breaks, pulls and the test alike, and never reaches
-- ReadyCheckOnBreakEnd -- a ready check is the wrong thing to fire as combat starts.
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_DISABLED" then StopBreak() end
end)

-- Exposed for the config's Test button. Its own source, "test", so previewing the
-- display from the config panel cannot fire the end-of-break ready check at the raid.
function DUI_TestBreakTimer(seconds)
    DUI_UpdateBreakTimerAppearance()
    StartBreak(seconds or 15, "test")
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

-- BigWigs_StartBreak(module, seconds, nick, isDBM, reboot, barText, icon)
-- `reboot` is true when BigWigs restores a break that was running across a reload.
local function BW_BreakStarted(event, module, seconds)
    StartBreak(seconds, "break")
end

local function BW_BreakStopped()
    StopBreak("break")
end

-- BigWigs_StartPull(module, seconds, nick, barText, icon)
-- BigWigs has already discarded pulls sent from another zone or during an encounter.
local function BW_PullStarted(event, module, seconds)
    if not db or not db.usePullTimer then return end
    local duration = tonumber(seconds)
    if not duration or duration < (db.pullThreshold or 120) then return end
    StartBreak(duration, "pull")
end

-- Also fires with "COMBAT" when the pull is cut short by combat starting.
local function BW_PullStopped()
    StopBreak("pull")
end

-- Timeline.lua asks this before putting a pull countdown on the encounter timeline: a
-- pull this module has taken over as a break shouldn't also appear there, where the
-- timeline would clamp it to its visible window and show a misleading length.
function DUI_BreakTimerHandlesPull(seconds)
    local bdb = DanUIDB and DanUIDB.BreakTimer
    if not bdb or not bdb.enabled or not bdb.usePullTimer then return false end
    local duration = tonumber(seconds)
    return duration ~= nil and duration >= (bdb.pullThreshold or 120)
end

function DUI_BreakTimerApplyEnabled(enabled)
    if not enabled then StopBreak() end
    DUI_UpdateBreakTimerAppearance()
end

function DUI_InitBreakTimer()
    db = DUI_InitModuleDB("BreakTimer", DUI_GetBreakTimerDefaults)
    if type(db.sounds) ~= "table" then db.sounds = { ["Quest Failed"] = true } end
    db.strata = nil -- removed setting; strata is now fixed (see DUI_UpdateBreakTimerAppearance)

    if C_AddOns.IsAddOnLoaded("BigWigs") and BigWigsLoader then
        local obj = {}
        BigWigsLoader.RegisterMessage(obj, "BigWigs_StartBreak", BW_BreakStarted)
        BigWigsLoader.RegisterMessage(obj, "BigWigs_StopBreak", BW_BreakStopped)
        BigWigsLoader.RegisterMessage(obj, "BigWigs_StartPull", BW_PullStarted)
        BigWigsLoader.RegisterMessage(obj, "BigWigs_StopPull", BW_PullStopped)
    end

    DUI_UpdateBreakTimerAppearance()
end

--------------------------------------------------------------------------------
-- Configuration UI
--------------------------------------------------------------------------------

-- Taller than the content strictly needs: the sound list stretches to the bottom
-- edge, so the extra height goes into showing more sounds at once.
local config = DUI_CreateConfigFrame("DUI_BreakTimerConfig", "Break Timer", 320, 580, "DUI_BreakTimerBtn", {
    onShow = function() DUI_UpdateBreakTimerAppearance() end,
    onHide = function() DUI_UpdateBreakTimerAppearance() end,
})

local function RefreshSoundList()
    local list = config.list
    if not list or not db then return end

    local sounds = LSM:List("sound")
    local rowHeight = 20

    for i = 1, math.max(#sounds, #list.rows) do
        if i <= #sounds then
            local row = list.rows[i]
            if not row then
                row = CreateFrame("Button", nil, list.content, "BackdropTemplate")
                -- Anchored to both sides rather than given a fixed 260 width, so a
                -- row fills whatever the list is: the sound names sat in a narrow
                -- strip with the rest of the box empty beside them.
                row:SetHeight(rowHeight)
                row:SetPoint("TOPLEFT", 0, -((i - 1) * rowHeight))
                row:SetPoint("TOPRIGHT", 0, -((i - 1) * rowHeight))

                local cb = CreateFrame("CheckButton", nil, row, "ChatConfigCheckButtonTemplate, BackdropTemplate")
                StyleAsPlainCheckbox(cb, 16)
                cb:SetPoint("LEFT", 2, 0)
                cb.Text:SetText("")
                cb:SetScript("OnClick", function(self)
                    db.sounds[row.soundName] = self:GetChecked() and true or nil
                end)
                row.cb = cb

                local txt = row:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
                txt:SetPoint("LEFT", cb, "RIGHT", 6, 0)
                txt:SetPoint("RIGHT", -4, 0)
                txt:SetJustifyH("LEFT")
                row.txt = txt

                -- Clicking the name previews the sound without changing the selection.
                row:SetScript("OnClick", function(self)
                    local path = LSM:Fetch("sound", self.soundName, true)
                    if path then PlaySoundFile(path, "Master") end
                end)
                row:SetScript("OnEnter", function(self) self.txt:SetTextColor(unpack(DUI_Theme.Accent)) end)
                row:SetScript("OnLeave", function(self) self.txt:SetTextColor(1, 1, 1) end)

                list.rows[i] = row
            end
            row.soundName = sounds[i]
            row.txt:SetText(sounds[i])
            row.txt:SetTextColor(1, 1, 1)
            row.cb:SetChecked(db.sounds[sounds[i]] and true or false)
            row:Show()
        elseif list.rows[i] then
            list.rows[i]:Hide()
        end
    end

    list:SetContentHeight(#sounds * rowHeight)
end

function DUI_OpenBreakTimerConfig()
    db = DUI_InitModuleDB("BreakTimer", DUI_GetBreakTimerDefaults)
    if type(db.sounds) ~= "table" then db.sounds = {} end

    if not config.init then
        local L = DUI_CreateLayout(config)
        -- Display and Pull Timers sit side by side so the sound list below them
        -- gets the rest of the pane: stacked, the two short sections ate 300px of
        -- a 580px panel and left the list a 200px slot.
        L:Columns(2)
        L:Header("Display")
        L:Slider("DUI_BT_Font", "Font Size", 10, 60, 1, db, "fontSize", DUI_UpdateBreakTimerAppearance,
            { value = db.fontSize, tooltip = "Size of the break label; the countdown itself is drawn larger again." })
        L:ColorButton("Text Color", db, "fontColor", DUI_UpdateBreakTimerAppearance,
            "Colour of the break label and countdown.")

        L:Text("Drag the timer on screen to reposition it while this panel is open.")

        L:Header("When It Ends")
        L:Checkbox("Ready check when the break expires", db, "readyCheckOnEnd", nil,
            { body = "Starts a ready check the instant the countdown reaches zero, so the raid comes back to a prompt instead of waiting on someone to call it.",
              note = "Needs lead or assist, and only fires for a real break -- not a pull timer taken over as one, a cancelled break, or the Test button." })

        L:Column(2)
        L:Header("Pull Timers")
        L:Checkbox("Treat long pull timers as breaks", db, "usePullTimer", nil,
            { body = "A long /pull is usually an informal break, so it is shown here instead of as a pull countdown.",
              note = "The threshold below decides what counts as long." })
        L:Slider("DUI_BT_PullThreshold", "Minimum pull length", 60, 600, 15, db, "pullThreshold", nil,
            { fmt = "%ds", value = db.pullThreshold or 120,
              tooltip = "Pull timers at least this long are displayed as a break." })

        L:EndColumns()
        L:Header("Sounds", { card = false })
        L:Text("One ticked sound is picked at random each break. Click a name to preview it.")

        -- Scrollable, multi-select list of every sound LibSharedMedia knows about.
        local listContainer = CreateFrame("Frame", nil, config, "BackdropTemplate")
        -- Left and right edges match the section cards above, so the list lines up
        -- with them rather than sitting 4px proud of the block it belongs to.
        listContainer:SetPoint("TOPLEFT", 16, L:Y())
        listContainer:SetPoint("BOTTOMRIGHT", -12, 44)
        DUI_StyleAsListBox(listContainer)

        local sf = CreateFrame("ScrollFrame", nil, listContainer)
        sf:SetPoint("TOPLEFT", 6, -6); sf:SetPoint("BOTTOMRIGHT", -18, 6)
        local content = CreateFrame("Frame", nil, sf)
        -- Sized from the container rather than the old hardcoded 260: the list
        -- now spans the panel, and a 260px child would leave its rows hugging the
        -- left of a 500px box.
        content:SetSize(config:GetWidth() - 56, 1); sf:SetScrollChild(content)

        local sb = CreateFrame("Slider", nil, listContainer, "BackdropTemplate")
        sb:SetPoint("TOPRIGHT", -4, -6); sb:SetPoint("BOTTOMRIGHT", -4, 6); sb:SetWidth(10)
        sb:SetBackdrop(DUI_EditBackdrop); sb:SetBackdropColor(0, 0, 0, 0.5)
        sb:SetThumbTexture("Interface\\Buttons\\WHITE8X8"); sb:GetThumbTexture():SetSize(8, 30)
        sb:GetThumbTexture():SetVertexColor(unpack(DUI_Theme.Accent))
        DUI_RegisterAccent(sb:GetThumbTexture(), "vertex")
        sb:SetMinMaxValues(0, 1); sb:SetValueStep(1); sb:SetObeyStepOnDrag(true)
        sb:SetScript("OnValueChanged", function(self, val) sf:SetVerticalScroll(val) end)
        sf:EnableMouseWheel(true)
        sf:SetScript("OnMouseWheel", function(_, delta) sb:SetValue(sb:GetValue() - delta * 20) end)

        listContainer.content, listContainer.rows = content, {}
        function listContainer:SetContentHeight(h)
            h = math.max(h, 1)
            content:SetHeight(h)
            sb:SetMinMaxValues(0, math.max(0, h - sf:GetHeight()))
        end
        config.list = listContainer

        local testBtn = CreateFrame("Button", nil, config, "BackdropTemplate")
        testBtn:SetSize(140, 25); testBtn:SetPoint("BOTTOMLEFT", 16, 12)
        testBtn:SetText("Test (15s)"); StyleAsTealTab(testBtn)
        testBtn:SetScript("OnClick", function() DUI_TestBreakTimer(15) end)

        local clearBtn = CreateFrame("Button", nil, config, "BackdropTemplate")
        clearBtn:SetSize(140, 25); clearBtn:SetPoint("BOTTOMRIGHT", -16, 12)
        clearBtn:SetText("Untick All"); StyleAsTealTab(clearBtn)
        clearBtn:SetScript("OnClick", function()
            wipe(db.sounds)
            RefreshSoundList()
        end)

        config.init = true
    end

    RefreshSoundList()
    config:Show()
    DUI_UpdateBreakTimerAppearance()
end
