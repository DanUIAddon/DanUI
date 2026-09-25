-- GuildBankRestock.lua
-- The reverse of the Guild Bank Sorter. Where the sorter tidies items *into*
-- tabs, this pulls a shopping list back *out* of the guild bank and into your
-- bags, on a weekly schedule.
--
-- Two things stop it firing at random:
--   * a schedule - it only runs when the bank is opened on one of the ticked
--     weekdays, inside a start/end window written in *server* time, and
--   * its own withdraw list, deliberately separate from the sorter's tab rules.
--     The two have nothing to say to each other: a sort rule decides where an
--     item lives, a restock entry decides how many of it you want on you.
--
-- Amounts are a top-up target, not a per-visit amount. "Flask of Alchemical
-- Chaos: 20" means "bring my bags up to 20", so opening the bank three times
-- inside the window does not hand you sixty flasks. That is what makes the
-- automatic run safe to repeat, and it is why the field is labelled "Keep".
--
-- Off by default. Nothing here asks for confirmation before pulling goods out of
-- a shared store, so it stays dormant until it is deliberately switched on.
--
-- Split back out of BankTools.lua, which had briefly carried this and the
-- warband gold sync behind one pair of tabs. They shared a trigger word and
-- nothing else. The other half is WarbankGold.lua.

local db -- Local reference to DanUIDB.GuildBankRestock

local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetContainerItemInfo = C_Container.GetContainerItemInfo
local PickupContainerItem  = C_Container.PickupContainerItem

-------------------------------------------------------------------------------
-- Saved variables
-------------------------------------------------------------------------------

function DUI_GetGuildBankRestockDefaults()
    return {
        enabled = false,
        autoRun = true,
        announce = true,
        -- A raid-night window by default, but every day starts unticked, so a
        -- freshly enabled module still does nothing until days are chosen.
        startHour = 19, startMinute = 0,
        endHour = 23, endMinute = 0,
        days = { [1] = false, [2] = false, [3] = false, [4] = false,
                 [5] = false, [6] = false, [7] = false },
        items = {}, -- { { itemID = 212283, count = 20 }, ... }
    }
end

-- Folds the restock half of the merged BankTools table across, then marks that
-- half taken. The two modules migrate independently and in either order, so the
-- shared source table is only dropped once both have had their share of it -
-- clearing it from here alone would leave the gold module with nothing to read.
--
-- The old master switch and the old per-half tick both had to be on for anything
-- to happen, so their AND is what the single new switch inherits.
--
-- There is no separate pre-merge fold to do here: this module's key is the same
-- GuildBankRestock it had before the merge, so a table that old simply *is* the
-- module's db and needs nothing done to it.
local function MigrateLegacyTables()
    local merged = DanUIDB.BankTools
    if type(merged) ~= "table" or merged.restockMigrated then return end

    db.enabled = (merged.enabled and merged.restockEnabled) and true or false
    for _, key in ipairs({ "autoRun", "announce", "startHour", "startMinute",
                           "endHour", "endMinute" }) do
        if merged[key] ~= nil then db[key] = merged[key] end
    end
    if type(merged.days) == "table" then db.days = merged.days end
    if type(merged.items) == "table" then db.items = merged.items end

    merged.restockMigrated = true
    if merged.goldMigrated then DanUIDB.BankTools = nil end
end

-- Split out of DUI_InitGuildBankRestock so opening the panel before login has run
-- the module's init still gets a populated db.
function DUI_InitGuildBankRestockDB()
    db = DUI_InitModuleDB("GuildBankRestock", DUI_GetGuildBankRestockDefaults)
    MigrateLegacyTables()

    -- Backfill the day table, which DUI_InitModuleDB only copies wholesale when
    -- it is absent entirely.
    local defaults = DUI_GetGuildBankRestockDefaults()
    db.days = db.days or {}
    for wday, v in pairs(defaults.days) do
        if db.days[wday] == nil then db.days[wday] = v end
    end
    db.items = db.items or {}
    return db
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function Announce(fmt, ...)
    print("|cFF00FF00[DUI]|r Restock: " .. string.format(fmt, ...))
end

-- The panel is built lazily on first open; these are the repaint hooks the logic
-- below calls into before that has happened.
local RefreshList = function() end
local RefreshStatus = function() end

local SLOTS_PER_TAB = MAX_GUILDBANK_SLOTS_PER_TAB or 98

-- Seconds between the per-tab queries in the planning pass, and between the
-- withdrawals themselves. Matched to the sorter's pacing: the guild bank is
-- server-authoritative and a burst of moves gets silently dropped.
local QUERY_WAIT, WITHDRAW_WAIT = 0.5, 1.0

-- date/calendar weekday is 1 = Sunday .. 7 = Saturday, and the schedule is keyed
-- by it. The config lists Monday first, which is how a raid week actually reads.
local DAY_NAMES = {
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
}
local DAY_SHORT = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local DAY_ORDER = { 2, 3, 4, 5, 6, 7, 1 } -- Monday first

-- ---------------------------------------------------------------------------
-- Schedule
-- ---------------------------------------------------------------------------

-- Realm ("server") time, because that is what the window is written in.
-- Returns weekday (1 = Sunday) and minutes since midnight.
local function ServerNow()
    local t = C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime
        and C_DateAndTime.GetCurrentCalendarTime()
    if t and t.hour and t.weekday then
        return t.weekday, t.hour * 60 + (t.minute or 0)
    end
    -- GetGameTime is realm time too but carries no weekday, so the local calendar
    -- day stands in. That only disagrees for a player whose own clock sits the
    -- other side of midnight from the realm's.
    local h, m = GetGameTime()
    return date("*t").wday, (h or 0) * 60 + (m or 0)
end

local function FormatClock(minutes)
    return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

local function WindowBounds()
    return db.startHour * 60 + db.startMinute, db.endHour * 60 + db.endMinute
end

-- True when now falls on a ticked day inside the window. A window whose end is at
-- or before its start wraps midnight, and the late half still belongs to the day
-- it opened on: a Tuesday 20:00-02:00 window is still "Tuesday" at 01:00 on the
-- Wednesday morning, which is how a raid night actually reads.
local function InWindow()
    local wday, now = ServerNow()
    local from, to = WindowBounds()
    if from == to then return false end -- zero-length window is "never"
    if from < to then
        return db.days[wday] == true and now >= from and now < to
    end
    if now >= from then return db.days[wday] == true end
    if now < to then
        local opened = (wday == 1) and 7 or (wday - 1)
        return db.days[opened] == true
    end
    return false
end

local function AnyDayTicked()
    for wday = 1, 7 do
        if db.days[wday] then return true end
    end
    return false
end

-- The panel's one-line answer to "would it run right now?". Spelling the realm's
-- own clock out is the point: the whole feature hinges on server time, which is
-- not the time in the player's taskbar.
local function StatusText()
    local wday, now = ServerNow()
    local from, to = WindowBounds()
    local line = string.format("Now %s %s server time. Window %s-%s%s.",
        DAY_NAMES[wday], FormatClock(now), FormatClock(from), FormatClock(to),
        (to <= from) and " (into the next day)" or "")
    if not db.enabled then
        return line .. " Restock is off - tick it on this module's row in the main window."
    end
    if not AnyDayTicked() then
        return line .. " No days picked, so nothing will run."
    end
    return line .. (InWindow() and " Inside the window." or " Outside the window.")
end

-- ---------------------------------------------------------------------------
-- Bank and bag helpers
-- ---------------------------------------------------------------------------

local function ItemName(itemID)
    local name, link = C_Item.GetItemInfo(itemID)
    return link or name or ("item " .. tostring(itemID))
end

local function TabName(tab)
    local name = GetGuildBankTabInfo(tab)
    return (name and name ~= "" and name) or ("Tab " .. tostring(tab))
end

-- GUILDBANKFRAME_OPENED and _CLOSED are still *registerable* on 12.1 - the names
-- exist, so RegisterEvent succeeds - but they are no longer fired. Opening the
-- guild bank produces only GUILDBANK_UPDATE_TABS, once per tab, followed by
-- GUILDBANKBAGSLOTS_CHANGED. So the frame is the source of truth and there is no
-- open/close latch to go stale: this is asked fresh every time it matters.
-- GuildBankFrame lives in the load-on-demand Blizzard_GuildBankUI, so it is nil
-- until the bank has been opened once, which reads as "closed" correctly.
local function IsGuildBankOpen()
    return (GuildBankFrame and GuildBankFrame:IsShown()) and true or false
end

local function BagCount(itemID)
    return (C_Item.GetItemCount and C_Item.GetItemCount(itemID)) or 0
end

local function MaxStack(itemID)
    return select(8, C_Item.GetItemInfo(itemID))
end

-- Where a split-off stack should land. A partial stack of the same item is the
-- best target - it merges and costs no slot - and any bag can hold one, the
-- reagent bag included, since the item is demonstrably already allowed in there.
-- Failing that, the first free slot in a normal bag; the reagent bag is skipped
-- for those, because it refuses anything that is not a reagent.
local function FindBagDestination(itemID, amount)
    local stack = MaxStack(itemID)
    local emptyBag, emptySlot
    for bag = 0, (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS) do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            local info = GetContainerItemInfo(bag, slot)
            if not info then
                if not emptyBag and bag <= NUM_BAG_SLOTS then
                    emptyBag, emptySlot = bag, slot
                end
            elseif info.itemID == itemID and stack
                and (info.stackCount or 0) + amount <= stack then
                return bag, slot
            end
        end
    end
    return emptyBag, emptySlot
end

-- ---------------------------------------------------------------------------
-- Withdrawing
-- ---------------------------------------------------------------------------

local ranThisGuildVisit = false -- latched so one bank visit gets one automatic pass
local running = false
local queue = {}
local ticker
-- Whether this pass narrates itself. Follows the Announce setting, but a run
-- started from the panel button always reports back: the user asked for it and
-- deserves to be told what happened, silent mode or not.
local verbose = false

-- Lets the sorter refuse to start while a restock is mid-flight; the two would
-- otherwise fight over the cursor.
function DUI_GuildBankRestockIsBusy() return running end

local function Finish(reason)
    running = false
    if ticker then ticker:Cancel(); ticker = nil end
    wipe(queue)
    if reason and verbose then Announce("%s.", reason) end
end

local function delay(seconds)
    local co = coroutine.running()
    C_Timer.After(seconds, function()
        local ok, err = coroutine.resume(co)
        if not ok then
            Finish()
            Announce("|cFFFF0000failed:|r %s", tostring(err))
        end
    end)
    coroutine.yield()
end

local function Withdraw(job)
    if not job.amount then
        -- Whole stack: the client picks the bag slot, merges what it can and
        -- handles the reagent bag by itself, so there is nothing to place.
        AutoStoreGuildBankItem(job.tab, job.slot)
        return true
    end

    local bag, slot = FindBagDestination(job.itemID, job.amount)
    if not bag then
        Announce("no free bag space for %s.", ItemName(job.itemID))
        return false
    end

    ClearCursor()
    SplitGuildBankItem(job.tab, job.slot, job.amount)
    -- Only place if the split actually loaded the cursor. On a locked or
    -- already-emptied slot it does not, and PickupContainerItem would then lift
    -- the destination item *out* of the bag instead of dropping into it.
    if CursorHasItem() then
        PickupContainerItem(bag, slot)
    end
    ClearCursor()
    return true
end

local function StartWithdrawing()
    local moved = 0
    ticker = C_Timer.NewTicker(WITHDRAW_WAIT, function()
        if not IsGuildBankOpen() then
            Finish("stopped, the guild bank was closed")
            return
        end
        local job = tremove(queue, 1)
        if job then
            if Withdraw(job) then moved = moved + 1 end
            QueryGuildBankTab(job.tab)
        end
        if #queue == 0 then
            Finish(string.format("done, %d withdrawal%s", moved, moved == 1 and "" or "s"))
        end
    end)
end

-- Builds the withdraw queue, and returns a reason string if there is nothing to
-- do. Has to run inside a coroutine: a tab's contents are only readable once
-- QueryGuildBankTab has round-tripped to the server.
local function Plan()
    -- Shortfalls first, so an already-stocked list costs no queries at all.
    local wanted, anyWanted = {}, false
    for _, entry in ipairs(db.items) do
        local short = entry.count - BagCount(entry.itemID)
        if short > 0 then
            wanted[entry.itemID] = (wanted[entry.itemID] or 0) + short
            anyWanted = true
        end
    end
    if not anyWanted then return "bags are already stocked" end

    local tabs = GetNumGuildBankTabs() or 0
    for tab = 1, tabs do
        if not IsGuildBankOpen() then return "stopped, the guild bank was closed" end
        if select(3, GetGuildBankTabInfo(tab)) then -- isViewable
            QueryGuildBankTab(tab)
            delay(QUERY_WAIT)
        end
    end
    if not IsGuildBankOpen() then return "stopped, the guild bank was closed" end

    for tab = 1, tabs do
        local _, _, isViewable, _, _, remaining = GetGuildBankTabInfo(tab)
        -- A zero remaining count means this tab is spent for the day, or the rank
        -- cannot withdraw from it at all. Anything else is left to the server to
        -- enforce rather than clamped here: the units the limit is counted in are
        -- not worth guessing at, and over-asking only costs a failed move.
        local spent = (type(remaining) == "number" and remaining == 0)
        if isViewable and not spent then
            for slot = 1, SLOTS_PER_TAB do
                local link = GetGuildBankItemLink(tab, slot)
                local itemID = link and tonumber(link:match("item:(%d+)"))
                local short = itemID and wanted[itemID]
                if short and short > 0 then
                    local _, available = GetGuildBankItemInfo(tab, slot)
                    available = available or 0
                    if available > 0 then
                        local take = math.min(short, available)
                        queue[#queue + 1] = {
                            tab = tab, slot = slot, itemID = itemID, count = take,
                            -- A nil amount means "take the whole stack", which
                            -- lets AutoStoreGuildBankItem do the placing.
                            amount = (take < available) and take or nil,
                        }
                        wanted[itemID] = short - take
                    end
                end
            end
        end
    end

    if verbose then
        for itemID, still in pairs(wanted) do
            if still > 0 then
                Announce("bank is %d short of %s.", still, ItemName(itemID))
            end
        end
    end

    if #queue == 0 then return "nothing available to withdraw" end
    if verbose then
        for _, job in ipairs(queue) do
            Announce("taking %d x %s from %s.", job.count, ItemName(job.itemID), TabName(job.tab))
        end
    end
end

local function PlanAndRun()
    local reason = Plan()
    -- Plan yields across server round trips; anything that called Finish in the
    -- meantime (switched off, bank closed) has already ended this run.
    if not running then return end
    if reason or #queue == 0 then
        Finish(reason or "nothing to withdraw")
    else
        StartWithdrawing()
    end
end

-- manual: run from the panel button, which bypasses the tick box and the
-- schedule. The scheduled path honours both, and fires at most once per visit.
local function RunRestock(manual)
    if not db then return end -- login has not reached the module's init yet
    if running then
        if manual then Announce("already running.") end
        return
    end
    if not IsGuildBankOpen() then
        if manual then Announce("the guild bank is not open.") end
        return
    end
    if DUI_GuildBankSortIsBusy and DUI_GuildBankSortIsBusy() then
        if manual then Announce("the sorter is still working - try again when it finishes.") end
        return
    end
    if not manual then
        if not db.enabled or not db.autoRun then return end
        if ranThisGuildVisit or not InWindow() then return end
        ranThisGuildVisit = true
    end
    if #db.items == 0 then
        if manual then Announce("the withdraw list is empty.") end
        return
    end

    running = true
    verbose = manual or db.announce
    wipe(queue)
    local co = coroutine.create(PlanAndRun)
    local ok, err = coroutine.resume(co)
    if not ok then
        Finish()
        Announce("|cFFFF0000failed:|r %s", tostring(err))
    end
end

-------------------------------------------------------------------------------
-- Configuration UI
-------------------------------------------------------------------------------

-- Matches the docking pane exactly: every DUI panel is built to DUI_PANEL_W, and
-- the widgets below lay out in panel coordinates.
local PANEL_W = DUI_PANEL_W
local ITEM_LIST_HEIGHT, ITEM_ROW_HEIGHT = 108, 22

local config = DUI_CreateConfigFrame("DUI_GuildBankRestockConfig", "Guild Bank Restock",
    PANEL_W, DUI_PANEL_H, "DUI_GuildBankRestockBtn")

local statusLine
local itemRows = {}

local function HourItems()
    local t = {}
    for h = 0, 23 do t[#t + 1] = { value = h, text = string.format("%02d", h) } end
    return t
end

local function MinuteItems()
    local t = {}
    for m = 0, 55, 5 do t[#t + 1] = { value = m, text = string.format("%02d", m) } end
    return t
end

-- One "From HH : MM" row. Both dropdowns write straight into db and repaint the
-- status line, so the panel always agrees with what the schedule will really do.
local function BuildTimeRow(parent, y, label, hourKey, minuteKey)
    local fs = parent:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
    fs:SetPoint("TOPLEFT", 40, y - 4)
    fs:SetText(label)

    local function picker(x, key, items, tip)
        local d = DUI_CreateDropdown(parent, nil, { width = 56, height = 22, justify = "CENTER", tooltip = tip })
        d:SetPoint("TOPLEFT", x, y)
        d:SetValue(string.format("%02d", db[key]))
        d:SetScript("OnClick", function(self)
            DUI_ShowScrollDropdown(self, items(), function(v)
                db[key] = v
                self:SetValue(string.format("%02d", v))
                RefreshStatus()
            end, db[key])
        end)
        return d
    end

    local hour = picker(110, hourKey, HourItems, "Hour, in server time.")
    local colon = parent:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
    colon:SetPoint("TOPLEFT", 172, y - 4)
    colon:SetText(":")
    local minute = picker(184, minuteKey, MinuteItems, "Minute, in server time.")
    return hour, minute
end

-- A compact weekday strip. Seven checkboxes cost four rows and read as a list of
-- unrelated options; one row of toggles reads as the single setting it is.
local function BuildDayStrip(parent, y)
    local buttons = {}
    for i, wday in ipairs(DAY_ORDER) do
        local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
        b:SetSize(50, 24)
        b:SetPoint("TOPLEFT", 40 + (i - 1) * 54, y)
        b:SetBackdrop(DUI_EditBackdrop)
        b:SetBackdropColor(0, 0, 0, 0.5)

        local fs = b:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
        fs:SetPoint("CENTER")
        fs:SetText(DAY_SHORT[wday])
        b.wday, b.text = wday, fs

        function b:Repaint()
            local on = db.days[self.wday] and true or false
            self:SetBackdropBorderColor(unpack(on and DUI_Theme.Accent or DUI_Theme.Secondary))
            self.text:SetTextColor(unpack(on and DUI_Theme.Accent or { 0.6, 0.6, 0.6 }))
        end

        b:SetScript("OnClick", function(self)
            db.days[self.wday] = not db.days[self.wday]
            self:Repaint()
            RefreshStatus()
        end)
        -- "fn" rather than "border": which colour this wears depends on whether
        -- the day is picked, so a blind recolour would light every day up.
        DUI_RegisterAccent(b, "fn", function() b:Repaint() end)
        DUI_AddTooltip(b, DAY_NAMES[wday],
            "Restock when the guild bank is opened on " .. DAY_NAMES[wday] .. ".")
        buttons[wday] = b
    end
    return buttons
end

local function ParseItemID(text)
    if not text or text == "" then return nil end
    return tonumber(text:match("item:(%d+)")) or tonumber(text:match("^%s*(%d+)%s*$"))
end

local function FindEntry(itemID)
    for i, entry in ipairs(db.items) do
        if entry.itemID == itemID then return i, entry end
    end
end

local function AddOrUpdateItem(itemID, count)
    local _, entry = FindEntry(itemID)
    if entry then
        entry.count = count
    else
        tinsert(db.items, { itemID = itemID, count = count })
    end
end

local function RemoveItem(itemID)
    local i = FindEntry(itemID)
    if i then tremove(db.items, i) end
end

local function BuildPanel()
    local L = DUI_CreateLayout(config)

    L:Header("Restock")
    -- No enable tick in here: the module's flag is the one on its row in the main
    -- window. The status line below reports it instead, so the panel still says
    -- whether anything is going to happen without owning a second copy of it.
    config.autoCheck = L:Checkbox("Run when the guild bank opens", db, "autoRun", nil,
        "Runs once per bank visit, if the visit falls inside the schedule below. Untick to leave it to the Restock Now button.")
    config.announceCheck = L:Checkbox("Announce in chat", db, "announce", nil,
        "Prints what is being withdrawn, and anything the bank came up short of.")
    L:Text("Off by default - this pulls items out of a shared store without asking.")

    L:Header("Schedule (server time)")
    config.fromHour, config.fromMinute = BuildTimeRow(config, L:Y(), "From", "startHour", "startMinute")
    L:Gap(DUI_LAYOUT.ROW)
    config.toHour, config.toMinute = BuildTimeRow(config, L:Y(), "To", "endHour", "endMinute")
    L:Gap(DUI_LAYOUT.ROW + 6)

    config.dayButtons = BuildDayStrip(config, L:Y())
    L:Gap(DUI_LAYOUT.ROW + 4)

    -- Seeded with the live status so the paragraph is measured at the height it
    -- will actually occupy; the spare gap covers it gaining a wrapped line when
    -- the window or the day list changes under it.
    statusLine = L:Text(StatusText())
    L:Gap(22)

    L:Header("Withdraw list")

    local idLabel = config:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
    idLabel:SetPoint("TOPLEFT", 40, L:Y() - 4)
    idLabel:SetText("Item")

    local idInput = CreateFrame("EditBox", "DUI_GuildBankRestockItemInput", config, "BackdropTemplate")
    idInput:SetSize(120, 24)
    idInput:SetPoint("TOPLEFT", 80, L:Y())
    idInput:SetAutoFocus(false)
    idInput:SetFontObject(DUI_FontNormal)
    idInput:SetBackdrop(DUI_EditBackdrop)
    idInput:SetBackdropColor(0, 0, 0, 0.5)
    idInput:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(idInput, "border")
    idInput:SetTextInsets(5, 5, 0, 0)
    idInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    idInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    -- Deliberately not numeric-only, unlike the sorter's box: that lets an item be
    -- shift-clicked straight in from a bag or a chat link.
    DUI_AddTooltip(idInput, "Item", "An item ID, or an item link shift-clicked in from your bags.")

    local keepLabel = config:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
    keepLabel:SetPoint("TOPLEFT", 210, L:Y() - 4)
    keepLabel:SetText("Keep")

    local keepInput = CreateFrame("EditBox", "DUI_GuildBankRestockKeepInput", config, "BackdropTemplate")
    keepInput:SetSize(48, 24)
    keepInput:SetPoint("TOPLEFT", 252, L:Y())
    keepInput:SetAutoFocus(false)
    keepInput:SetNumeric(true)
    keepInput:SetFontObject(DUI_FontNormal)
    keepInput:SetBackdrop(DUI_EditBackdrop)
    keepInput:SetBackdropColor(0, 0, 0, 0.5)
    keepInput:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(keepInput, "border")
    keepInput:SetTextInsets(5, 5, 0, 0)
    keepInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    keepInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    DUI_AddTooltip(keepInput, "Keep",
        "How many to keep in your bags. The restock tops you up to this number rather than withdrawing it every visit.")

    local addBtn = CreateFrame("Button", nil, config, "BackdropTemplate")
    addBtn:SetSize(90, 24)
    addBtn:SetPoint("TOPLEFT", 312, L:Y())
    addBtn:SetText("Add")
    StyleAsTealTab(addBtn)
    addBtn:SetScript("OnClick", function()
        local itemID = ParseItemID(idInput:GetText())
        local count = tonumber(keepInput:GetText())
        if not itemID or not count or count < 1 then
            Announce("enter an item (ID or link) and a count of at least 1.")
            return
        end
        AddOrUpdateItem(itemID, count)
        idInput:SetText("")
        keepInput:SetText("")
        RefreshList()
    end)
    L:Gap(DUI_LAYOUT.ROW + 4)

    local area = CreateFrame("Frame", nil, config, "BackdropTemplate")
    area:SetPoint("TOPLEFT", 40, L:Y())
    area:SetSize(380, ITEM_LIST_HEIGHT)
    DUI_StyleAsListBox(area)

    local scroll = CreateFrame("ScrollFrame", nil, area)
    scroll:SetPoint("TOPLEFT", 5, -5)
    scroll:SetPoint("BOTTOMRIGHT", -20, 5)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    local bar = CreateFrame("Slider", nil, area, "BackdropTemplate")
    bar:SetPoint("TOPRIGHT", -5, -5); bar:SetPoint("BOTTOMRIGHT", -5, 5); bar:SetWidth(12)
    bar:SetBackdrop(DUI_EditBackdrop); bar:SetBackdropColor(0, 0, 0, 0.5)
    bar:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
    bar:GetThumbTexture():SetSize(10, 40)
    bar:GetThumbTexture():SetVertexColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(bar:GetThumbTexture(), "vertex")
    bar:SetMinMaxValues(0, 1); bar:SetValueStep(1); bar:SetObeyStepOnDrag(true)
    bar:SetScript("OnValueChanged", function(_, value) scroll:SetVerticalScroll(value) end)
    area:EnableMouseWheel(true)
    area:SetScript("OnMouseWheel", function(_, delta) bar:SetValue(bar:GetValue() - delta * 20) end)

    config.listContent, config.listBar, config.listScroll = content, bar, scroll
    L:Gap(ITEM_LIST_HEIGHT + 10)

    local runBtn = CreateFrame("Button", nil, config, "BackdropTemplate")
    runBtn:SetSize(140, 25)
    runBtn:SetPoint("TOPLEFT", 40, L:Y())
    runBtn:SetText("Restock Now")
    StyleAsTealTab(runBtn)
    runBtn:SetScript("OnClick", function() RunRestock(true) end)
    DUI_AddTooltip(runBtn, "Restock Now",
        { body = "Withdraws the list straight away, ignoring the tick box and the schedule.",
          note = "The guild bank has to be open." })
    L:Gap(DUI_LAYOUT.ROW + 4)

    L:Text("Counts are targets, not amounts: the restock only takes what you are short of, so a repeated bank visit does not stack them up.")

    L:FitHeight()
end

RefreshStatus = function()
    if not (config.init and db) then return end
    statusLine:SetText(StatusText())
end

RefreshList = function()
    if not (config.init and db) then return end
    for _, row in ipairs(itemRows) do row:Hide() end

    for i, entry in ipairs(db.items) do
        local row = itemRows[i]
        if not row then
            row = CreateFrame("Frame", nil, config.listContent)
            row:SetSize(350, 20)
            row.label = row:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
            row.label:SetPoint("LEFT", 4, 0)
            row.label:SetWidth(310)
            row.label:SetJustifyH("LEFT")
            row.label:SetWordWrap(false)
            row.remove = CreateFrame("Button", nil, row, "BackdropTemplate")
            row.remove:SetSize(20, 20)
            row.remove:SetPoint("RIGHT", -4, 0)
            row.remove:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
            row.remove:SetBackdropColor(0.6, 0.18, 0.18, 1) -- red = destructive
            row.remove:SetBackdropBorderColor(0, 0, 0, 1)
            local x = row.remove:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
            x:SetPoint("CENTER"); x:SetText("X"); x:SetTextColor(1, 1, 1)
            row.remove:SetScript("OnClick", function(self)
                RemoveItem(self:GetParent().itemID)
                RefreshList()
            end)
            itemRows[i] = row
        end
        row:SetPoint("TOPLEFT", config.listContent, "TOPLEFT", 6, -((i - 1) * ITEM_ROW_HEIGHT) - 4)
        -- The name may not be cached yet; the item-info listener repaints the row
        -- when the client resolves it.
        if not C_Item.GetItemInfo(entry.itemID) and C_Item.RequestLoadItemData then
            pcall(C_Item.RequestLoadItemData, entry.itemID)
        end
        row.itemID = entry.itemID
        row.label:SetText(string.format("%s  |cff999999keep %d|r  |cff777777(have %d)|r",
            ItemName(entry.itemID), entry.count, BagCount(entry.itemID)))
        row:Show()
    end

    local height = math.max(#db.items * ITEM_ROW_HEIGHT + 8, ITEM_LIST_HEIGHT)
    config.listContent:SetHeight(height)
    local maxScroll = math.max(0, height - ITEM_LIST_HEIGHT)
    config.listBar:SetMinMaxValues(0, maxScroll)
    if maxScroll > 0 then
        config.listBar:Show()
    else
        config.listBar:Hide()
        config.listScroll:SetVerticalScroll(0)
    end
end

function DUI_OpenGuildBankRestockConfig()
    if not db then DUI_InitGuildBankRestockDB() end

    if not config.init then
        BuildPanel()
        config.init = true
    end

    config.autoCheck:SetChecked(db.autoRun)
    config.announceCheck:SetChecked(db.announce)
    for _, b in pairs(config.dayButtons) do b:Repaint() end
    config.fromHour:SetValue(string.format("%02d", db.startHour))
    config.fromMinute:SetValue(string.format("%02d", db.startMinute))
    config.toHour:SetValue(string.format("%02d", db.endHour))
    config.toMinute:SetValue(string.format("%02d", db.endMinute))

    RefreshStatus()
    RefreshList()
    config:Show()
end

-- Called by the main window's enable checkbox, so the panel's own tick agrees
-- with a switch flipped from out there.
function DUI_GuildBankRestockApplyEnabled()
    -- A withdraw in flight is a ticker that keeps pulling items; switching the
    -- module off has to stop it, not just the next scheduled run.
    if not db.enabled and running then Finish("stopped, the module was switched off") end
    RefreshStatus()
end

-- Item names arrive asynchronously, and the "have" column is a live bag count.
-- Both events are chatty, so they are only listened to while the panel is up.
-- The first open after login sends one GET_ITEM_INFO_RECEIVED per uncached item in
-- a burst, and each used to rebuild the whole list; they share one rebuild at the
-- end of the frame now.
local listRefreshQueued = false
local function FlushListRefresh()
    listRefreshQueued = false
    if config:IsShown() then RefreshList() end
end

local listener = CreateFrame("Frame")
listener:SetScript("OnEvent", function(_, event, itemID)
    if not db or listRefreshQueued then return end
    if event == "GET_ITEM_INFO_RECEIVED" and not (itemID and FindEntry(itemID)) then return end
    listRefreshQueued = true
    C_Timer.After(0, FlushListRefresh)
end)

-- The status line is a clock reading, so it goes stale on a panel left open.
local statusTicker

config:HookScript("OnShow", function()
    -- OnShow is queued rather than run inside Show(), so the launcher's index
    -- warm-up -- which shows and hides every panel in one frame to make it build
    -- -- still lands here with the panel already gone. Without this the listener
    -- and the ticker below would be started for a closed panel and never stopped.
    if not config:IsShown() then return end
    listener:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    listener:RegisterEvent("BAG_UPDATE_DELAYED")
    if not statusTicker then
        statusTicker = C_Timer.NewTicker(20, function() RefreshStatus() end)
    end
end)
config:HookScript("OnHide", function()
    listener:UnregisterAllEvents()
    if statusTicker then statusTicker:Cancel(); statusTicker = nil end
end)

DUI_GuildBankRestockConfig = config

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------

-- Opening the guild bank fires GUILDBANK_UPDATE_TABS once per tab, so coalesce
-- the burst into a single pass and give the tab data a moment to land before the
-- planning queries start.
local autoTimer
local function ScheduleRestockRun()
    if autoTimer then autoTimer:Cancel() end
    autoTimer = C_Timer.NewTimer(1.0, function() RunRestock(false) end)
end

-- With no open/close event to listen to (see IsGuildBankOpen), the frame's own
-- OnShow/OnHide are what mark the start and end of a visit. Blizzard_GuildBankUI
-- is load-on-demand, so this is attempted at login, when that addon loads, and
-- again on the first tab update - whichever gets there first wins, and the rest
-- are no-ops.
local hooked = false
local function HookGuildBankFrame()
    if hooked or not GuildBankFrame then return end
    hooked = true
    GuildBankFrame:HookScript("OnShow", function()
        ranThisGuildVisit = false
        ScheduleRestockRun()
    end)
    GuildBankFrame:HookScript("OnHide", function()
        ranThisGuildVisit = false
        if running then Finish("stopped, the guild bank was closed") end
    end)
end

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == "Blizzard_GuildBankUI" then
            HookGuildBankFrame()
            eventFrame:UnregisterEvent("ADDON_LOADED") -- nothing left to wait for
        end

    elseif event == "GUILDBANK_UPDATE_TABS" then
        -- Belt for the hook: if OnShow was somehow missed, a tab update while the
        -- frame is up still starts the visit. ranThisGuildVisit keeps it to one pass.
        HookGuildBankFrame()
        if IsGuildBankOpen() then ScheduleRestockRun() end
    end
end)

function DUI_InitGuildBankRestock()
    DUI_InitGuildBankRestockDB()
    HookGuildBankFrame() -- covers a /reload taken with the guild bank already open

    eventFrame:RegisterEvent("ADDON_LOADED")
    eventFrame:RegisterEvent("GUILDBANK_UPDATE_TABS")
end
