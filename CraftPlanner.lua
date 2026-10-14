-- CraftPlanner.lua
-- One batch of crafts spread over several characters, fed from the warband bank.
--
-- The loop it exists for: nine raid cauldrons, two kinds, each made by a different
-- character. Every character is registered once (open the profession, select the
-- recipe, "Add Open Recipe"). After that a raid week is:
--   1. Start Run on any character - progress resets and an Auctionator shopping
--      list is built for every craft still to do, minus what is already owned.
--      Any character that will be short of concentration is named.
--   2. Buy it, then Open Warbank (or visit a bank): the bought reagents move into
--      the warband bank, which every character can craft from.
--   3. On each assigned character, /dan opens straight onto this panel; Craft
--      opens the recipe, then crafts it. Opening a bank moves the result in too.
--
-- Reagent tiers: each reagent in the plan can be pinned to a quality tier (the
-- Reagents section). A pinned reagent is searched at that tier, only that tier
-- counts as owned, and Craft hands CraftRecipe that tier for its slot. A reagent
-- left on "Any" keeps the old behaviour - every tier counts, the list names none,
-- and the craft uses whatever Blizzard's own form allocated.
--
-- The plan is account-wide (DanUIDB), which is the point - one character's Start
-- Run is every character's to-do list.

local db -- Local reference to DanUIDB.CraftPlanner

-- Defined with the event list; forward-declared so everything that changes what
-- this character has to do (the rail's switch, a run starting, a craft landing)
-- can re-sync which events are worth hearing.
local SyncEvents

local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetContainerItemInfo = C_Container.GetContainerItemInfo
local PickupContainerItem  = C_Container.PickupContainerItem
local SplitContainerItem   = C_Container.SplitContainerItem
local GetItemCount         = C_Item.GetItemCount
local GetServerTime        = GetServerTime

-- Auctionator's API wants an addon name as the caller ID; it is only used in the
-- error text it raises.
local AUCTIONATOR_CALLER = "DanUI"

-- Warband Bank Distance Inhibitor: opens the warband bank anywhere, as an
-- AccountBanker interaction - which the auto-deposit already listens for, so
-- casting it is the whole "go to a bank" step.
local WARBANK_SPELL_ID = 460905

-- Seconds between item moves in a deposit. Bank moves are server-authoritative,
-- and a burst of them in one frame risks some being silently dropped.
local MOVE_WAIT = 0.12

-------------------------------------------------------------------------------
-- Saved variables
-------------------------------------------------------------------------------

function DUI_GetCraftPlannerDefaults()
    return {
        enabled = true,
        autoDeposit = true,     -- crafted results, on any bank opening
        depositReagents = true, -- bought reagents the run still needs, same trigger
        loginReminder = true,
        listName = "DanUI Crafting",
        runActive = false,
        -- { char = "Name-Realm", recipeID, name, skillLineID (base, for
        --   OpenTradeSkill), childSkillLineID (expansion, for concentration),
        --   profName, count, done, toDeposit, concentrate, concCost,
        --   outputs = { itemID, ... }, reagents = { { ids, qty, slot }, ... } }
        entries = {},
        -- Reagent tier pins, keyed by the reagent's first (lowest) tier itemID:
        -- the value is an index into that reagent's tier list. Absent = any tier.
        tiers = {},
        -- Last concentration reading per character and expansion profession:
        -- conc["Name-Realm"][childSkillLineID] = { amount, max, cycleMS, time }.
        conc = {},
    }
end

-- Session caches that hang off the plan; declared here so the DB init can reset them.
local myKey, myEntries -- see CharKey / MyEntries

function DUI_InitCraftPlannerDB()
    db = DUI_InitModuleDB("CraftPlanner", DUI_GetCraftPlannerDefaults)
    db.entries = db.entries or {}
    db.tiers = db.tiers or {}
    db.conc = db.conc or {}
    myEntries = nil
    return db
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function Announce(fmt, ...)
    print("|cFF00FF00[DUI]|r Crafting: " .. string.format(fmt, ...))
end

-- Repaint hooks for the panel, which is built on first open.
local RefreshPanel = function() end
-- Shows or hides the secure Open Warbank button to match the panel (see below).
local SyncWarbankButton = function() end

-- Realm-qualified, so two alts of the same name on different realms stay apart.
-- UnitFullName can leave the realm nil this early in a session, hence the
-- fallback - and why the key is only cached once it has a realm in it.
local function CharKey()
    if myKey then return myKey end
    local name, realm = UnitFullName("player")
    if not name then return nil end
    if not realm or realm == "" then realm = GetNormalizedRealmName() end
    if not realm then return name end
    myKey = name .. "-" .. realm
    return myKey
end

local function ShortName(key)
    return (key and key:match("^[^%-]+")) or "?"
end

local function ItemName(itemID)
    local name = C_Item.GetItemInfo(itemID)
    if not name and C_Item.RequestLoadItemData then pcall(C_Item.RequestLoadItemData, itemID) end
    return name or ("item " .. tostring(itemID))
end

local function FormatDuration(seconds)
    seconds = math.max(0, math.floor(seconds))
    local h, m = math.floor(seconds / 3600), math.floor((seconds % 3600) / 60)
    if h >= 24 then return string.format("%dd %dh", math.floor(h / 24), h % 24) end
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm", math.max(m, 1))
end

-- Everything this character can craft from or deposit: bags, own bank (cached away
-- from the banker) and the warband bank. The same reagent in another alt's bags is
-- not counted - there is no API for it, and the workflow puts everything in the
-- warband bank anyway (the reagent deposit moves this character's share there).
local function OwnedCount(itemID)
    return GetItemCount(itemID, true, false, true, true) or 0
end

local function WarbankCount(itemID)
    return (GetItemCount(itemID, false, false, false, true) or 0) - (GetItemCount(itemID) or 0)
end

-- The reagents a recipe always consumes, one row per slot: { ids, qty, slot }.
-- A slot with quality tiers lists every tier's itemID, lowest first. A *required*
-- selectable slot (a Spark, say) is included by its first option, which is the one
-- the shopping list asks for; optional and finishing reagents are not part of the
-- plan. Currency reagents carry no itemID and are skipped. `slot` is the
-- dataSlotIndex, which is what a tier pin is handed to CraftRecipe against.
local function RecipeReagents(recipeID)
    local out = {}
    local schem = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
    if not (schem and schem.reagentSlotSchematics) then return out end
    for _, slot in ipairs(schem.reagentSlotSchematics) do
        local basic = slot.reagentType == Enum.CraftingReagentType.Basic
        local first = slot.reagents and slot.reagents[1]
        if (basic or slot.required) and first and first.itemID then
            local ids = {}
            if basic then
                for _, r in ipairs(slot.reagents) do
                    if r.itemID then ids[#ids + 1] = r.itemID end
                end
            else
                ids[1] = first.itemID
            end
            out[#out + 1] = { ids = ids, qty = slot.quantityRequired or 1, slot = slot.dataSlotIndex }
        end
    end
    return out
end

-- Every itemID the recipe can produce. Quality crafts make a different item per
-- tier, which is why a craft result is matched against the whole set.
local function RecipeOutputs(recipeID)
    local ids = {}
    local q = C_TradeSkillUI.GetRecipeQualityItemIDs and C_TradeSkillUI.GetRecipeQualityItemIDs(recipeID)
    if type(q) == "table" then
        for _, id in ipairs(q) do ids[#ids + 1] = id end
    end
    if #ids == 0 then
        local data = C_TradeSkillUI.GetRecipeOutputItemData(recipeID)
        if data and data.itemID then ids[1] = data.itemID end
    end
    return ids
end

-- The expansion profession a recipe belongs to (Midnight Alchemy), which is what
-- owns the concentration currency. pcall'd: the call is not documented as safe
-- for a recipe the character doesn't know.
local function RecipeChildSkillLine(recipeID)
    if not C_TradeSkillUI.GetTradeSkillLineForRecipe then return nil end
    local ok, id = pcall(C_TradeSkillUI.GetTradeSkillLineForRecipe, recipeID)
    return ok and id and id ~= 0 and id or nil
end

local function Outputs(entry)
    if not entry.outputs or #entry.outputs == 0 then entry.outputs = RecipeOutputs(entry.recipeID) end
    return entry.outputs
end

-- Against the saved reagent copy (entry.reagents, filled by ReagentsFor below).
local function IsReagentOf(entry, itemID)
    for _, r in ipairs(entry.reagents or {}) do
        for _, id in ipairs(r.ids or {}) do
            if id == itemID then return true end
        end
    end
    return false
end

-- Drops any reagent of the recipe from its output list. Crediting used to fall back
-- to a stale "last plan recipe tried", so a Stabilized Derivate crafted for a cauldron
-- was counted as the cauldron and then learned as one of its outputs (reported live).
-- After that it matched every derivate craft, and the deposit pass would have moved
-- the run's own reagents. Something a recipe consumes is never its product.
local function PruneOutputs(entry)
    local outs = entry.outputs
    if not outs then return end
    for i = #outs, 1, -1 do
        if IsReagentOf(entry, outs[i]) then tremove(outs, i) end
    end
end

local function OutputsContain(entry, itemID)
    if IsReagentOf(entry, itemID) then return false end
    for _, id in ipairs(Outputs(entry)) do
        if id == itemID then return true end
    end
    return false
end

local function Remaining(entry) return math.max((entry.count or 1) - (entry.done or 0), 0) end

-- This character's entries, in plan order. Cached: it is read on every event and
-- repaint, and only changes when the plan is edited (InvalidateMine). Not cached
-- until the character key has its realm, or it could be built against the wrong key.
local function MyEntries()
    if myEntries then return myEntries end
    local key, mine = CharKey(), {}
    for _, e in ipairs(db.entries) do
        if e.char == key then mine[#mine + 1] = e end
    end
    if myKey then myEntries = mine end
    return mine
end

local function InvalidateMine() myEntries = nil end

local function NextToCraft()
    for _, e in ipairs(MyEntries()) do
        if Remaining(e) > 0 then return e end
    end
end

local function HasWork()
    if not (db and db.enabled and db.runActive) then return false end
    for _, e in ipairs(MyEntries()) do
        if Remaining(e) > 0 or (e.toDeposit or 0) > 0 then return true end
    end
    return false
end

-- Reagent rows for an entry. A recipe's reagents never change, so one live read per
-- session is kept (sessionReagents). The live read can come back empty on a
-- character that doesn't know the recipe - exactly the character the shopping list
-- gets built on - so the crafter's own reading is also saved on the entry (at Add
-- time and every login) and an empty read falls back to that. An empty read is not
-- retried for a minute, so a panel repaint on a non-crafter doesn't keep asking.
-- nil = no data either way.
local sessionReagents, reagentMiss = {}, {}
local function ReagentsFor(entry)
    local id = entry.recipeID
    local rows = sessionReagents[id]
    if not rows and (not reagentMiss[id] or GetTime() - reagentMiss[id] > 60) then
        local live = RecipeReagents(id)
        if #live > 0 then
            sessionReagents[id], reagentMiss[id] = live, nil
            rows = live
        else
            reagentMiss[id] = GetTime()
        end
    end
    if rows then
        entry.reagents = rows
        return rows
    end
    if entry.reagents and #entry.reagents > 0 then return entry.reagents end
    return nil
end

local function ForgetReagents(recipeID) sessionReagents[recipeID], reagentMiss[recipeID] = nil, nil end

-------------------------------------------------------------------------------
-- Reagent tiers
-------------------------------------------------------------------------------

-- The pinned tier index for a reagent row's ids, or nil for "any tier". A pin is
-- ignored on a reagent that has only one tier.
local function TierIndex(ids)
    local t = db.tiers[ids[1]]
    if t and #ids > 1 and ids[t] then return t end
end

-- The quality number for a reagent tier (what Auctionator's `tier` filter and the
-- "Q2" labels mean), falling back to its position in the list.
local function TierQuality(ids, idx)
    local q = C_TradeSkillUI.GetItemReagentQualityByItemInfo
        and C_TradeSkillUI.GetItemReagentQualityByItemInfo(ids[idx])
    return (type(q) == "number" and q > 0) and q or idx
end

-- How many of a reagent count: only the pinned tier when there is one, else all.
local function HaveOf(ids, counter)
    local t = TierIndex(ids)
    if t then return counter(ids[t]) end
    local n = 0
    for _, id in ipairs(ids) do n = n + counter(id) end
    return n
end

-- Adds every planned reagent up into one row per reagent: { ids, qty }, keyed by
-- the first tier's itemID. forRun counts only crafts still to do in the run;
-- otherwise the full plan. noData lists entries with no reagent data at all.
local function AggregateReagents(forRun)
    local need, order, noData = {}, {}, {}
    for _, e in ipairs(db.entries) do
        local n = forRun and Remaining(e) or (e.count or 1)
        if n > 0 then
            local reagents = ReagentsFor(e)
            if not reagents then
                noData[#noData + 1] = e
            else
                for _, r in ipairs(reagents) do
                    local key = r.ids[1]
                    local row = need[key]
                    if not row then
                        row = { ids = r.ids, qty = 0 }
                        need[key] = row
                        order[#order + 1] = key
                    end
                    row.qty = row.qty + r.qty * n
                end
            end
        end
    end
    return need, order, noData
end

-- Reagents still missing for `entry`'s remaining crafts, as { {itemID, count} }.
local function MissingFor(entry)
    local missing = {}
    local n = Remaining(entry)
    if n == 0 then return missing end
    for _, r in ipairs(ReagentsFor(entry) or {}) do
        local short = r.qty * n - HaveOf(r.ids, OwnedCount)
        if short > 0 then
            missing[#missing + 1] = { itemID = r.ids[TierIndex(r.ids) or 1], count = short }
        end
    end
    return missing
end

local function RunProgress()
    local crafted, total, waiting = 0, 0, 0
    for _, e in ipairs(db.entries) do
        total = total + (e.count or 1)
        crafted = crafted + math.min(e.done or 0, e.count or 1)
        waiting = waiting + (e.toDeposit or 0)
    end
    return crafted, total, waiting
end

-- Ends the run once every craft is made and nothing is waiting to be deposited.
local function CheckRunComplete()
    if not db.runActive then return end
    local crafted, total, waiting = RunProgress()
    if total > 0 and crafted >= total and waiting == 0 then
        db.runActive = false
        Announce("every craft in the plan is done and banked.")
        SyncEvents()
    end
end

-------------------------------------------------------------------------------
-- Concentration across characters
-------------------------------------------------------------------------------

-- Stores this character's concentration for one expansion profession. Concentration
-- is only readable on the character itself, so every character records its own
-- (login, profession opened, after a craft) and the others project from that.
local function RecordConcentration(childID)
    if not (childID and C_TradeSkillUI.GetConcentrationCurrencyID) then return end
    local key = CharKey()
    local currencyID = C_TradeSkillUI.GetConcentrationCurrencyID(childID)
    if not (key and currencyID and currencyID ~= 0) then return end
    local cur = C_CurrencyInfo.GetCurrencyInfo(currencyID)
    if not (cur and cur.maxQuantity and cur.maxQuantity > 0) then return end
    db.conc[key] = db.conc[key] or {}
    db.conc[key][childID] = {
        amount = cur.quantity or 0, max = cur.maxQuantity,
        cycleMS = cur.rechargingCycleDurationMS, time = GetServerTime(),
    }
end

-- Fills in each of this character's entries' expansion profession (older entries
-- predate the field) and records the concentration for every one of them.
local function RecordMyConcentration()
    local seen = {}
    for _, e in ipairs(MyEntries()) do
        e.childSkillLineID = e.childSkillLineID or RecipeChildSkillLine(e.recipeID)
        local id = e.childSkillLineID
        if id and not seen[id] then
            seen[id] = true
            RecordConcentration(id)
        end
    end
end

-- A character's concentration now, projected from its last reading at one point
-- per recharge cycle (the same model CraftSim uses). Returns amount, the stored
-- reading (for max and cycle), or nil when that character never recorded one.
local function ProjectedConcentration(charKey, childID)
    local c = db.conc[charKey] and db.conc[charKey][childID]
    if not c then return nil end
    local amount = c.amount
    if c.cycleMS and c.cycleMS > 0 then
        amount = amount + (GetServerTime() - (c.time or 0)) / (c.cycleMS / 1000)
    end
    return math.floor(math.min(c.max, amount)), c
end

-- One line per character and profession whose concentration won't cover its
-- planned crafts. Problems only: a covered character says nothing. Uses each
-- entry's last measured cost (concCost), which is per craft and depends on skill
-- and reagent tiers, so it is refreshed whenever the recipe is on screen.
local function ConcentrationReport()
    local groups, order = {}, {}
    for _, e in ipairs(db.entries) do
        local n = db.runActive and Remaining(e) or (e.count or 1)
        if e.concentrate and n > 0 then
            local gkey = e.char .. ":" .. tostring(e.childSkillLineID)
            local g = groups[gkey]
            if not g then
                g = { char = e.char, child = e.childSkillLineID, need = 0, unknown = {} }
                groups[gkey] = g
                order[#order + 1] = gkey
            end
            if e.concCost then
                g.need = g.need + e.concCost * n
            else
                g.unknown[#g.unknown + 1] = e.name
            end
        end
    end

    -- Unrecorded characters share one line: on a fresh plan that is every alt at
    -- once, and a line each pushed the panel's report far past its space.
    local lines, unrecorded, seen = {}, {}, {}
    for _, gkey in ipairs(order) do
        local g = groups[gkey]
        local who = ShortName(g.char)
        local have, c = nil, nil
        if g.child then have, c = ProjectedConcentration(g.char, g.child) end
        if not have then
            if not seen[who] then
                seen[who] = true
                unrecorded[#unrecorded + 1] = who
            end
        else
            if #g.unknown > 0 then
                lines[#lines + 1] = string.format("|cffffd100%s: cost of %s unknown - open the recipe on %s once.|r",
                    who, table.concat(g.unknown, ", "), who)
            end
            if g.need > have then
                local wait = (c.cycleMS and c.cycleMS > 0) and (g.need - have) * c.cycleMS / 1000 or nil
                lines[#lines + 1] = string.format("|cffff8080%s: needs %d concentration, has ~%d%s.|r", who, g.need, have,
                    (g.need > c.max) and string.format(" (max is %d - lower the count)", c.max)
                    or (wait and string.format(" (enough in %s)", FormatDuration(wait)) or ""))
            end
        end
    end
    if #unrecorded == 1 then
        table.insert(lines, 1, string.format("|cffffd100%s: concentration not recorded yet - log in on %s once.|r",
            unrecorded[1], unrecorded[1]))
    elseif #unrecorded > 1 then
        table.insert(lines, 1, string.format("|cffffd100Concentration not recorded yet for %s - log in on each once.|r",
            table.concat(unrecorded, ", ")))
    end
    return lines
end

-------------------------------------------------------------------------------
-- Shopping list
-------------------------------------------------------------------------------

local function AuctionatorReady()
    return Auctionator and Auctionator.API and Auctionator.API.v1
        and Auctionator.API.v1.CreateShoppingList and Auctionator.API.v1.ConvertToSearchString
end

-- Sums every unfinished craft's reagents, subtracts what this character can
-- already reach, and publishes the rest as one Auctionator list (replacing any
-- earlier list of the same name). Item names have to be loaded before they can be
-- written into a search, so the publish waits on a ContinuableContainer.
--
-- The whole sum is printed as it goes: need / have / buy per reagent, and any craft
-- that had no reagent data at all by name. A short list used to be silent, so a
-- wrong total looked the same as a right one.
local function BuildShoppingList()
    local need, order, noData = AggregateReagents(true)

    for _, e in ipairs(noData) do
        Announce("|cffff8080no reagent data for %s (%s)|r - it is NOT in the list. Log in on %s once (or re-add it there) and Rebuild List.",
            e.name or "?", ShortName(e.char), ShortName(e.char))
    end
    if #order == 0 then
        Announce("no reagents to add up.")
        return
    end

    local shopping, rows = {}, {}
    local container = ContinuableContainer:Create()
    for _, key in ipairs(order) do
        local row = need[key]
        local t = TierIndex(row.ids)
        local have = HaveOf(row.ids, OwnedCount)
        local buy = math.max(row.qty - have, 0)
        local itemID = row.ids[t or 1]
        rows[#rows + 1] = { itemID = itemID, need = row.qty, have = have, buy = buy,
            tier = t and TierQuality(row.ids, t) }
        container:AddContinuable(Item:CreateFromItemID(itemID))
        if buy > 0 then shopping[#shopping + 1] = rows[#rows] end
    end

    container:ContinueOnLoad(function()
        Announce("reagents for the remaining crafts (have = bags + bank + warband bank):")
        for _, r in ipairs(rows) do
            Announce("  %s%s: need %d, have %d, %s", ItemName(r.itemID),
                r.tier and (" Q" .. r.tier) or "", r.need, r.have,
                r.buy > 0 and string.format("|cffffd100buy %d|r", r.buy) or "|cff80ff80covered|r")
        end
        if #shopping == 0 then
            Announce("nothing to buy - every reagent for the remaining crafts is already on hand.")
            return
        end

        local terms, bound = {}, {}
        for _, s in ipairs(shopping) do
            local name, _, _, _, _, _, _, _, _, _, _, _, _, bindType = C_Item.GetItemInfo(s.itemID)
            if bindType == 1 then
                -- Bind on pickup can't be on the auction house; say so rather than
                -- leaving a search that can never fill.
                bound[#bound + 1] = s
            elseif name and AuctionatorReady() then
                -- A pinned reagent searches its tier; "Any" names none, and the
                -- choice is made at the auction house.
                terms[#terms + 1] = Auctionator.API.v1.ConvertToSearchString(AUCTIONATOR_CALLER,
                    { searchString = name, isExact = true, quantity = s.buy, tier = s.tier })
            end
        end

        for _, s in ipairs(bound) do
            Announce("|cffff8080%dx %s|r is bind-on-pickup - craft or farm it, it won't be on the AH.",
                s.buy, ItemName(s.itemID))
        end

        if not AuctionatorReady() then
            Announce("Auctionator isn't loaded - the buy amounts above are the list.")
            return
        end
        if #terms == 0 then return end
        local ok, err = pcall(Auctionator.API.v1.CreateShoppingList, AUCTIONATOR_CALLER, db.listName, terms)
        if ok then
            Announce("Auctionator list \"%s\" made with %d item%s. Buy it, then Open Warbank to put it in.",
                db.listName, #terms, #terms == 1 and "" or "s")
        else
            Announce("|cffff0000couldn't make the Auctionator list:|r %s", tostring(err))
        end
    end)
end

local function StartRun()
    if #db.entries == 0 then
        Announce("the plan is empty - add a recipe on each crafting character first.")
        return
    end
    for _, e in ipairs(db.entries) do
        e.done, e.toDeposit = 0, 0
    end
    db.runActive = true
    local _, total = RunProgress()
    Announce("run started: %d craft%s across the plan.", total, total == 1 and "" or "s")
    for _, line in ipairs(ConcentrationReport()) do Announce("%s", line) end
    BuildShoppingList()
    SyncEvents()
    RefreshPanel()
end

-------------------------------------------------------------------------------
-- Crafting
-------------------------------------------------------------------------------

-- Blizzard_Professions is load-on-demand, so ProfessionsFrame is nil until a
-- profession has been opened once this session.
local function ShownSchematicForm()
    local pf = ProfessionsFrame
    local form = pf and pf:IsShown() and pf.CraftingPage and pf.CraftingPage.SchematicForm
    if form and form:IsVisible() then return form end
end

local function ShownRecipeInfo()
    local form = ShownSchematicForm()
    return form and form:GetRecipeInfo(), form
end

-- Selecting a recipe needs its profession open first. OpenTradeSkill is a server
-- round trip, so the recipe is selected when TRADE_SKILL_SHOW reports back.
local pendingOpenRecipe
local function OpenRecipe(entry)
    local info = ShownRecipeInfo()
    if info then
        C_TradeSkillUI.OpenRecipe(entry.recipeID)
        return
    end
    pendingOpenRecipe = entry.recipeID
    C_TradeSkillUI.OpenTradeSkill(entry.skillLineID)
end

-- The reagent table a craft of `entry` is made with: Blizzard's form allocation
-- (quality reagents, plus any optional or finishing reagents picked there), with
-- every tier-pinned slot swapped for its pinned tier. Only quality slots appear in
-- this table at all - plain reagents are implicit - so a pin replaces that slot's
-- rows rather than adding one. A cached row without a slot index (saved before it
-- was recorded) can't be pinned and is left to Blizzard. Also returns the pinned
-- reagents this character is short of for `count` crafts.
local function CraftReagents(entry, tx, count)
    local tbl = tx:CreateCraftingReagentInfoTbl()
    local short = {}
    for _, r in ipairs(ReagentsFor(entry) or {}) do
        local t = TierIndex(r.ids)
        if t and r.slot then
            for i = #tbl, 1, -1 do
                if tbl[i].dataSlotIndex == r.slot then tremove(tbl, i) end
            end
            tbl[#tbl + 1] = { reagent = { itemID = r.ids[t] }, quantity = r.qty, dataSlotIndex = r.slot }
            local have = OwnedCount(r.ids[t])
            if have < r.qty * count then
                short[#short + 1] = string.format("%d Q%d %s (have %d)", r.qty * count,
                    TierQuality(r.ids, t), ItemName(r.ids[t]), have)
            end
        end
    end
    return tbl, short
end

-- Concentration for a craft of `recipeID` with reagent table `tbl`: what one craft
-- costs, and what this character has. Needs the profession open - the cost depends
-- on skill and reagent tiers, and the currency belongs to the expansion's child
-- profession (Midnight Alchemy), not the base one. The cost is asked for with
-- concentration *off*, the way CraftSim does it: with it on, the operation reports
-- the post-concentration state instead of the price. Records the reading for the
-- cross-character check.
-- Returns cost, have, childID, or nil plus why there is no cost:
--   "maxed"     - already makes the top quality, so there is nothing to spend it on
--   "noquality" - not a quality craft; concentration doesn't apply
--   "unread"    - the client gave no usable answer. Not the same as "can't": a
--                 reagent table the client rejects (an allocation the form hasn't
--                 finished, a stale pinned slot) returns nil, and reading that as
--                 "can't" crafted a run without concentration it had (reported live).
-- A rejected table is retried with Blizzard's own allocation before giving up.
local function ConcentrationFor(recipeID, tx, tbl)
    local guid = tx:GetAllocationItemGUID()
    local op = C_TradeSkillUI.GetCraftingOperationInfo(recipeID, tbl, guid, false)
    if not op then
        op = C_TradeSkillUI.GetCraftingOperationInfo(recipeID, tx:CreateCraftingReagentInfoTbl(), guid, false)
    end
    local childID = C_TradeSkillUI.GetProfessionChildSkillLineID and C_TradeSkillUI.GetProfessionChildSkillLineID()
    if not childID or childID == 0 then
        local child = C_TradeSkillUI.GetChildProfessionInfo()
        childID = child and child.professionID
    end
    RecordConcentration(childID)
    if not op then return nil, nil, childID, "unread" end
    local cost = op.concentrationCost or 0
    if cost <= 0 then
        if op.isQualityCraft == false then return nil, nil, childID, "noquality" end
        local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
        local q = op.craftingQuality or op.quality
        if q and info and info.maxQuality and info.maxQuality > 0 and q >= info.maxQuality then
            return nil, nil, childID, "maxed"
        end
        return nil, nil, childID, "unread"
    end
    -- The operation names its own currency; the child-profession lookup is the
    -- fallback for a client that leaves the field out.
    local currencyID = op.concentrationCurrencyID
    if not currencyID or currencyID == 0 then
        currencyID = childID and C_TradeSkillUI.GetConcentrationCurrencyID(childID)
    end
    local cur = currencyID and currencyID ~= 0 and C_CurrencyInfo.GetCurrencyInfo(currencyID)
    return cost, cur and cur.quantity or 0, childID
end

-- The recipe of the craft in progress, from TRADE_SKILL_CRAFT_BEGIN, which fires for
-- every craft (this button, Blizzard's Create, recipes outside the plan). It used to
-- be the last *plan* recipe tried, set before CraftRecipe and never cleared, so a
-- Craft click that failed for want of a reagent left it pointing at the cauldron,
-- and crafting that reagent next was credited as the cauldron (reported live).
local craftingSpell

local function Craft()
    if not db.enabled then
        Announce("Craft Planner is off - tick it on its row in the main window.")
        return
    end
    if InCombatLockdown() then return end
    if not db.runActive then
        Announce("no run in progress - Start Run first.")
        return
    end
    local entry = NextToCraft()
    if not entry then
        Announce("nothing left to craft on this character.")
        return
    end

    local info, form = ShownRecipeInfo()
    if not info or info.recipeID ~= entry.recipeID then
        OpenRecipe(entry)
        Announce("opened %s - press Craft again to make it.", entry.name)
        return
    end
    if info.isEnchantingRecipe then
        -- Enchants go through CraftEnchant with a vellum target; Blizzard's own
        -- button handles that, and the result is still tracked from here.
        Announce("enchants have to be made with Blizzard's own Create button.")
        return
    end

    local tx = form:GetTransaction()
    local count = Remaining(entry)
    local tbl, short = CraftReagents(entry, tx, count)
    if #short > 0 then
        Announce("|cffff8080not enough of the pinned tier:|r %s. Change the tier under Reagents, or buy more.",
            table.concat(short, ", "))
        return
    end

    -- Concentration comes from the plan, not from Blizzard's checkbox: it is part of
    -- what this character was set up to make, and the checkbox resets whenever the
    -- window reopens. Running short refuses rather than quietly crafting without it
    -- - a cauldron a tier lower is not what the run asked for.
    local apply = entry.concentrate and true or false
    local cost, have, childID, why = ConcentrationFor(entry.recipeID, tx, tbl)
    entry.childSkillLineID = childID or entry.childSkillLineID
    -- 0 for a craft that will never spend any, so the cross-character report counts
    -- it as covered; an unread cost keeps the last good one.
    if cost then
        entry.concCost = cost
    elseif why ~= "unread" then
        entry.concCost = 0
    end
    if apply then
        if why == "maxed" then
            Announce("%s already comes out at top quality - no concentration needed.", entry.name)
            apply = false
        elseif why == "noquality" then
            Announce("%s has no quality tiers, so concentration doesn't apply - crafting without it.", entry.name)
            apply = false
        elseif why == "unread" then
            -- The plan asked for it and the client wouldn't say otherwise, so it is
            -- sent with concentration; the server refuses it outright if it can't.
            Announce("couldn't read the concentration cost of %s - crafting with it, as the plan says.", entry.name)
        elseif cost * count > have then
            Announce("|cffff8080not enough concentration|r for %dx %s: needs %d, you have %d. Untick Conc on its row to craft without it.",
                count, entry.name, cost * count, have)
            return
        end
    end
    if apply ~= tx:IsApplyingConcentration() then
        -- Only a heads-up: the quality preview in Blizzard's window is computed for
        -- its own checkbox, so it will disagree with what is about to be made.
        Announce("crafting %s concentration, as the plan says. Blizzard's checkbox is set the other way.",
            apply and "with" or "without")
    end
    C_TradeSkillUI.CraftRecipe(entry.recipeID, count, tbl, nil, nil, apply)
end

-- Credits a finished craft to the matching entry. Fires for crafts made from
-- Blizzard's window too, so the plan stays right whichever button was pressed.
local function OnCraftResult(result)
    if not (db.runActive and type(result) == "table" and result.itemID) then return end
    local hit
    if craftingSpell then
        -- The craft in progress decides. A recipe outside the plan (a reagent made
        -- for one of its crafts) credits nothing, whatever it produced.
        for _, e in ipairs(MyEntries()) do
            if Remaining(e) > 0 and e.recipeID == craftingSpell then hit = e; break end
        end
    else
        -- No begin heard (the craft group came on mid-craft): the output list is
        -- all there is to go on.
        for _, e in ipairs(MyEntries()) do
            if Remaining(e) > 0 and OutputsContain(e, result.itemID) then hit = e; break end
        end
    end
    if not hit then return end

    -- An item the output list didn't know (a new quality tier, say) is learned so
    -- the deposit pass can find it - only when the recipe itself confirmed the
    -- match, and never one of its own reagents.
    if craftingSpell and not OutputsContain(hit, result.itemID) and not IsReagentOf(hit, result.itemID) then
        tinsert(Outputs(hit), result.itemID)
    end
    hit.done = (hit.done or 0) + 1
    hit.toDeposit = (hit.toDeposit or 0) + (result.quantity or 1)
    -- The spend just changed this character's concentration; keep the record live.
    RecordConcentration(hit.childSkillLineID)
    if Remaining(hit) == 0 then
        Announce("%s done. Open Warbank (or visit a bank) to put it in the warband bank.", hit.name)
        SyncEvents() -- no crafts left here means the craft watch can go
    end
    RefreshPanel()
end

-------------------------------------------------------------------------------
-- Depositing
-------------------------------------------------------------------------------

local function BagRange(prefix, max)
    local list = {}
    for i = 1, max do
        local id = Enum.BagIndex and Enum.BagIndex[prefix .. i]
        if id then list[#list + 1] = id end
    end
    return list
end

local ACCOUNT_BAGS = BagRange("AccountBankTab_", 8)
local CHARACTER_BANK_BAGS = BagRange("CharacterBankTab_", 9)

local BAGS = {}
for bag = 0, (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS) do BAGS[#BAGS + 1] = bag end

-- Any banker gives access to the warband tabs (EllesmereUIBags shows and fills
-- both at once), so this asks the interaction manager, not BankFrame's active
-- tab - EUI replaces BankFrame, and the portable warband bank is its own type.
-- Only a real banker opens this character's own bank as well.
local function AtBanker()
    local pim = C_PlayerInteractionManager
    return (pim and pim.IsInteractingWithNpcOfType
        and pim.IsInteractingWithNpcOfType(Enum.PlayerInteractionType.Banker)) and true or false
end

local function AtBank()
    local pim = C_PlayerInteractionManager
    if not (pim and pim.IsInteractingWithNpcOfType) then return false end
    return AtBanker() or pim.IsInteractingWithNpcOfType(Enum.PlayerInteractionType.AccountBanker)
end

local function WarbankUsable()
    if not (C_Bank and Enum.BankType) then return false end
    if C_Bank.FetchBankLockedReason and C_Bank.FetchBankLockedReason(Enum.BankType.Account) ~= nil then
        return false
    end
    return AtBank()
end

-- A stack of the same item with room first (it merges and costs no slot), else
-- the first empty warband slot. `plan` holds what earlier moves in this pass will
-- add to each slot, since the server hasn't applied them yet when the next one is
-- planned: without it two moves pick the same empty slot, or overfill one stack.
local function WarbankDestination(itemID, amount, plan)
    local stack = select(8, C_Item.GetItemInfo(itemID)) or 1
    local emptyBag, emptySlot
    for _, bag in ipairs(ACCOUNT_BAGS) do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            local key = bag * 1000 + slot
            local p = plan[key]
            local info = GetContainerItemInfo(bag, slot)
            local holds = (info and info.itemID) or (p and p.itemID)
            if not holds then
                if not emptyBag then emptyBag, emptySlot = bag, slot end
            elseif holds == itemID and not (info and info.isLocked)
                and (info and info.stackCount or 0) + (p and p.add or 0) + amount <= stack then
                plan[key] = { itemID = itemID, add = (p and p.add or 0) + amount }
                return bag, slot
            end
        end
    end
    if emptyBag then plan[emptyBag * 1000 + emptySlot] = { itemID = itemID, add = amount } end
    return emptyBag, emptySlot
end

-- Plans moves of up to `want` items whose ID is in `ids` from `bags` into the
-- warband bank. `used` stops two queues claiming the same source slot.
local function QueueMoves(jobs, plan, used, bags, ids, want, manual)
    for _, bag in ipairs(bags) do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            if want <= 0 then return end
            local skey = bag * 1000 + slot
            local info = not used[skey] and GetContainerItemInfo(bag, slot)
            if info and not info.isLocked and tContains(ids, info.itemID) then
                local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
                local allowed = not C_Bank.IsItemAllowedInBankType
                    or C_Bank.IsItemAllowedInBankType(Enum.BankType.Account, loc)
                if allowed then
                    local amount = math.min(info.stackCount or 1, want)
                    local dBag, dSlot = WarbankDestination(info.itemID, amount, plan)
                    if dBag then
                        used[skey] = true
                        jobs[#jobs + 1] = { bag = bag, slot = slot, amount = amount,
                            whole = amount >= (info.stackCount or 1), dBag = dBag, dSlot = dSlot }
                        want = want - amount
                    end
                elseif manual then
                    Announce("%s can't go in the warband bank (soulbound).", ItemName(info.itemID))
                end
            end
        end
    end
end

local depositing = false

-- One pass that moves two things into the warband bank:
--   * what this character crafted for the run (entry.toDeposit), from the bags;
--   * bought reagents the run still needs, from the bags and - at a real banker -
--     this character's own bank, up to the run's need minus what the warband
--     bank already holds. A pinned reagent moves only its pinned tier.
-- Moves are spaced MOVE_WAIT apart, then the warband counts are compared a second
-- after the last one, and only what actually arrived is credited. A refused move
-- (a soulbound result, a full bank) leaves the item waiting for the next visit.
local function Deposit(manual)
    if depositing or not db then return end
    if not db.enabled then
        if manual then Announce("Craft Planner is off - tick it on its row in the main window.") end
        return
    end
    if not db.runActive then
        if manual then Announce("no run in progress.") end
        return
    end
    if not WarbankUsable() then
        if manual then Announce("open a bank first - the warband bank has to be reachable.") end
        return
    end

    local jobs, plan, used = {}, {}, {}
    local outBefore, reagentBefore = {}, {}

    if manual or db.autoDeposit then
        for _, e in ipairs(MyEntries()) do
            local want = e.toDeposit or 0
            if want > 0 then
                local outs = Outputs(e)
                for _, id in ipairs(outs) do outBefore[id] = outBefore[id] or WarbankCount(id) end
                QueueMoves(jobs, plan, used, BAGS, outs, want, manual)
            end
        end
    end

    if manual or db.depositReagents then
        local sources = BAGS
        if AtBanker() then
            sources = {}
            for _, b in ipairs(BAGS) do sources[#sources + 1] = b end
            for _, b in ipairs(CHARACTER_BANK_BAGS) do sources[#sources + 1] = b end
        end
        local need, order = AggregateReagents(true)
        for _, key in ipairs(order) do
            local row = need[key]
            local want = row.qty - HaveOf(row.ids, WarbankCount)
            if want > 0 then
                local t = TierIndex(row.ids)
                local ids = t and { row.ids[t] } or row.ids
                for _, id in ipairs(ids) do reagentBefore[id] = reagentBefore[id] or WarbankCount(id) end
                QueueMoves(jobs, plan, used, sources, ids, want, manual)
            end
        end
    end

    if #jobs == 0 then
        if manual then Announce("nothing waiting to go in - no crafted items or needed reagents outside the warband bank.") end
        return
    end

    local function Settle()
        depositing = false
        local moved = 0
        for _, e in ipairs(MyEntries()) do
            if (e.toDeposit or 0) > 0 then
                local arrived = 0
                for _, id in ipairs(Outputs(e)) do
                    if outBefore[id] then
                        arrived = arrived + math.max(WarbankCount(id) - outBefore[id], 0)
                        outBefore[id] = nil -- credit an item to one entry only
                    end
                end
                local credit = math.min(arrived, e.toDeposit)
                e.toDeposit = e.toDeposit - credit
                moved = moved + credit
            end
        end
        local reagents = 0
        for id, before in pairs(reagentBefore) do
            reagents = reagents + math.max(WarbankCount(id) - before, 0)
        end
        if moved > 0 then
            Announce("put %d crafted item%s in the warband bank.", moved, moved == 1 and "" or "s")
        end
        if reagents > 0 then
            Announce("put %d reagent%s in the warband bank.", reagents, reagents == 1 and "" or "s")
        end
        if moved == 0 and reagents == 0 and manual then
            Announce("the warband bank didn't take anything - is it full?")
        end
        CheckRunComplete()
        SyncEvents()
        RefreshPanel()
    end

    depositing = true
    local i = 0
    local ticker
    ticker = C_Timer.NewTicker(MOVE_WAIT, function()
        i = i + 1
        local j = jobs[i]
        if not j or not WarbankUsable() then
            ticker:Cancel()
            if j then Announce("stopped - the bank closed.") end
            C_Timer.After(1, Settle)
            return
        end
        ClearCursor()
        if j.whole then
            PickupContainerItem(j.bag, j.slot)
        else
            SplitContainerItem(j.bag, j.slot, j.amount)
        end
        -- Only drop if the pick-up actually loaded the cursor; otherwise the drop
        -- would lift whatever is in the destination slot instead.
        if CursorHasItem() then PickupContainerItem(j.dBag, j.dSlot) end
        ClearCursor()
    end)
end

-------------------------------------------------------------------------------
-- Plan editing
-------------------------------------------------------------------------------

-- Concentration starts as whatever Blizzard's checkbox says when the recipe is
-- added - the moment the user is looking at it. The Conc toggle on the row changes
-- it afterwards. The per-craft concentration cost is measured here too, so the
-- cross-character check has a number before the first craft.
local function AddOpenRecipe(count)
    local info, form = ShownRecipeInfo()
    if not info then
        Announce("open your profession and select the recipe first.")
        return
    end
    if not info.learned then
        Announce("this character doesn't know %s.", info.name or "that recipe")
        return
    end
    -- OpenTradeSkill wants the base profession (Alchemy), not the expansion
    -- child the window is showing (Midnight Alchemy).
    local prof = C_TradeSkillUI.GetChildProfessionInfo() or C_TradeSkillUI.GetBaseProfessionInfo()
    local skillLineID = prof and (prof.parentProfessionID or prof.professionID)
    if not skillLineID then
        Announce("couldn't tell which profession is open.")
        return
    end

    ForgetReagents(info.recipeID) -- re-read on the character that knows it
    local tx = form:GetTransaction()
    local concentrate = tx:IsApplyingConcentration() and true or false
    local key = CharKey()
    local entry
    for _, e in ipairs(db.entries) do
        if e.char == key and e.recipeID == info.recipeID then entry = e; break end
    end
    if entry then
        entry.count, entry.concentrate = count, concentrate
        Announce("%s now makes %dx %s%s.", ShortName(key), count, info.name,
            concentrate and " with concentration" or "")
    else
        entry = {
            char = key, recipeID = info.recipeID, name = info.name,
            skillLineID = skillLineID,
            profName = prof.parentProfessionName or prof.professionName,
            count = count, done = 0, toDeposit = 0, concentrate = concentrate,
            outputs = RecipeOutputs(info.recipeID),
        }
        tinsert(db.entries, entry)
        InvalidateMine()
        Announce("added %dx %s for %s%s.", count, info.name, ShortName(key),
            concentrate and ", with concentration" or "")
    end
    ReagentsFor(entry) -- saves the crafter's own reading on the entry
    local cost, _, childID, why = ConcentrationFor(info.recipeID, tx, (CraftReagents(entry, tx, 1)))
    entry.concCost = cost or (why ~= "unread" and 0 or nil)
    entry.childSkillLineID = childID or RecipeChildSkillLine(info.recipeID)
    SyncEvents()
    RefreshPanel()
end

local function RemoveEntry(entry)
    for i, e in ipairs(db.entries) do
        if e == entry then tremove(db.entries, i); break end
    end
    InvalidateMine()
    SyncEvents()
    RefreshPanel()
end

-------------------------------------------------------------------------------
-- Configuration UI
-------------------------------------------------------------------------------

local PANEL_W = DUI_PANEL_W
local LIST_H, REAGENT_LIST_H, ROW_H = 176, 154, 22

local config = DUI_CreateConfigFrame("DUI_CraftPlannerConfig", "Craft Planner",
    PANEL_W, DUI_PANEL_H, "DUI_CraftPlannerBtn")

local hereText, runText, concText, startBtn
local planBox, reagentBox
local planRows, reagentRows = {}, {}

local function MakeButton(parent, text, w, x, y, onClick, title, tip)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w, 25)
    b:SetPoint("TOPLEFT", x, y)
    b:SetText(text)
    StyleAsTealTab(b)
    b:SetScript("OnClick", onClick)
    if title then DUI_AddTooltip(b, title, tip) end
    return b
end

-- A small bordered toggle used on list rows (Conc, tier). Fixed gold/grey rather
-- than the accent: rows only repaint on refresh, so an accent would go stale.
local function MakeChip(parent, w)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w, 18)
    b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    b:SetBackdropColor(0, 0, 0, 0.5)
    b.text = b:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    b.text:SetPoint("CENTER")
    function b:SetLit(on)
        if on then
            self:SetBackdropBorderColor(1, 0.82, 0, 1)
            self.text:SetTextColor(1, 0.82, 0)
        else
            self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            self.text:SetTextColor(0.6, 0.6, 0.6)
        end
    end
    return b
end

-- A scrolling list box spanning the panel, at the layout cursor.
local function MakeListBox(L, height)
    local area = CreateFrame("Frame", nil, config, "BackdropTemplate")
    area:SetPoint("TOPLEFT", 16, L:Y())
    area:SetPoint("RIGHT", config, "RIGHT", -12, 0)
    area:SetHeight(height)
    DUI_StyleAsListBox(area)

    local scroll = CreateFrame("ScrollFrame", nil, area)
    scroll:SetPoint("TOPLEFT", 5, -5)
    scroll:SetPoint("BOTTOMRIGHT", -20, 5)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(PANEL_W - 60, 1)
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
    L:Advance(height + 10)
    return { content = content, bar = bar, scroll = scroll, height = height }
end

local function SizeListBox(box, rows)
    local height = math.max(rows * ROW_H + 8, box.height)
    box.content:SetHeight(height)
    local maxScroll = math.max(0, height - box.height)
    box.bar:SetMinMaxValues(0, maxScroll)
    if maxScroll > 0 then
        box.bar:Show()
    else
        box.bar:Hide()
        box.scroll:SetVerticalScroll(0)
    end
end

-- The "This character" block: what to do here, and whether the reagents are in
-- reach. The reagent check is the same tier-aware count the shopping list uses.
local function HereStatus()
    local key = CharKey()
    if not key then return "" end
    local mine = MyEntries()
    if #mine == 0 then
        return ShortName(key) .. " has nothing in the plan. To add something, open the profession, select the recipe, then press Add Open Recipe."
    end
    if not db.runActive then
        local names = {}
        for _, e in ipairs(mine) do names[#names + 1] = string.format("%dx %s", e.count or 1, e.name) end
        return "Assigned here: " .. table.concat(names, ", ") .. ". No run in progress - Start Run when you're ready."
    end

    local lines = {}
    for _, e in ipairs(mine) do
        local left = Remaining(e)
        if left > 0 then
            local missing = MissingFor(e)
            local line = string.format("|cffffffffCraft %dx %s|r (%s)", left, e.name, e.profName or "?")
            if e.concentrate then
                -- Live when the recipe is on screen, else the recorded cost against
                -- this character's projected concentration.
                local cost, have, why, _
                local info, form = ShownRecipeInfo()
                if info and info.recipeID == e.recipeID then
                    local tx = form:GetTransaction()
                    cost, have, _, why = ConcentrationFor(e.recipeID, tx, (CraftReagents(e, tx, left)))
                    if cost then e.concCost = cost elseif why ~= "unread" then e.concCost = 0 end
                elseif e.concCost and e.childSkillLineID then
                    cost, have = e.concCost, ProjectedConcentration(key, e.childSkillLineID)
                end
                if why == "maxed" or cost == 0 then
                    line = line .. " (top quality without concentration)"
                elseif cost and have then
                    line = line .. string.format(" with concentration, %s%d of %d|r",
                        (cost * left > have) and "|cffff8080" or "|cff80ff80", cost * left, have)
                else
                    line = line .. " with concentration"
                end
            end
            line = line .. "."
            if #missing == 0 then
                line = line .. " |cff80ff80Reagents ready.|r"
            else
                local parts = {}
                for i, m in ipairs(missing) do
                    if i > 4 then parts[#parts + 1] = "..."; break end
                    parts[#parts + 1] = string.format("%dx %s", m.count, ItemName(m.itemID))
                end
                line = line .. " |cffff8080Missing: " .. table.concat(parts, ", ") .. "|r"
            end
            lines[#lines + 1] = line
        elseif (e.toDeposit or 0) > 0 then
            lines[#lines + 1] = string.format("%s crafted - |cffffd100click Open Warbank (or visit a bank) to put %d in the warband bank.|r",
                e.name, e.toDeposit)
        else
            lines[#lines + 1] = string.format("|cff80ff80%s done and banked.|r", e.name)
        end
    end
    return table.concat(lines, "\n")
end

local function RunStatus()
    if #db.entries == 0 then return "The plan is empty." end
    local crafted, total, waiting = RunProgress()
    if not db.runActive then
        return string.format("No run in progress. The plan has %d craft%s.", total, total == 1 and "" or "s")
    end
    return string.format("Run in progress: %d of %d crafted%s.", crafted, total,
        waiting > 0 and string.format(", %d waiting to be banked", waiting) or "")
end

-- The panel measures concText once at build time (CONC_LINES deep) and the Start
-- Run buttons sit under that, so a longer report would be drawn over them. It is
-- capped instead: whole report lines are dropped from the end until the rest fits,
-- with a pointer to the chat copy Start Run prints in full.
local CONC_LINES = 4

local function SetConcStatus(fs)
    local lines = ConcentrationReport()
    if #lines == 0 then
        fs:SetText("Concentration: every character with Conc on has enough.")
        return
    end
    fs:SetText(table.concat(lines, "\n"))
    if not fs.IsTruncated then return end
    for keep = #lines - 1, 0, -1 do
        if not fs:IsTruncated() then return end
        local shown = {}
        for i = 1, keep do shown[i] = lines[i] end
        shown[keep + 1] = string.format("|cffffd100...and %d more - Start Run lists them all in chat.|r", #lines - keep)
        fs:SetText(table.concat(shown, "\n"))
    end
end

local function EntryStatus(e)
    if not db.runActive then return "|cff999999-|r" end
    if Remaining(e) > 0 then return string.format("|cffff8080%d/%d|r", e.done or 0, e.count or 1) end
    if (e.toDeposit or 0) > 0 then return "|cffffd100to bank|r" end
    return "|cff80ff80done|r"
end

local function BuildPanel()
    local L = DUI_CreateLayout(config)

    L:Header("This Character")
    -- Seeded with the longest thing it usually says so the paragraph is measured
    -- at a realistic height; the gap below covers a wrapped extra line.
    hereText = L:Text(string.rep("Craft 1x Cauldron of Something Long (Alchemy) with concentration, 1000 of 1000. Missing: 10x Reagent. ", 2),
        { color = { 0.85, 0.85, 0.85 } })
    L:Gap(24)

    MakeButton(config, "Craft", 120, 40, L:Y(), function() Craft() end, "Craft",
        { body = "First click opens the profession on the next recipe assigned to this character; the second crafts it. Pinned reagent tiers (Reagents section) replace Blizzard's allocation for those reagents, and concentration follows the Conc toggle on the plan row.",
          note = "Blizzard's own Create button works too - the result is counted either way, but it uses its own tiers." })
    MakeButton(config, "Deposit", 120, 170, L:Y(), function() Deposit(true) end, "Deposit",
        { body = "Moves this character's crafted items for the run, and any bought reagents the run still needs, into the warband bank.",
          note = "A bank has to be open." })
    -- A stand-in that only looks like Open Warbank: the real one is a secure button
    -- parented to UIParent and pinned over this (see SyncWarbankButton for why).
    -- Being in the panel, this one is clipped by the pane like everything else, so
    -- while the real button is down (slot scrolled part out of view, combat, module
    -- off) the panel shows this instead of a hole.
    local slot = MakeButton(config, "Open Warbank", 130, 300, L:Y(), function()
        if not db.enabled then
            Announce("Craft Planner is off - tick it on its row in the main window.")
        elseif InCombatLockdown() then
            Announce("Open Warbank can't be cast in combat.")
        else
            Announce("scroll Open Warbank fully into view to use it.")
        end
    end, "Open Warbank", { body = "Casts Warband Bank Distance Inhibitor, which opens the warband bank wherever you are." })
    config.warbankSlot = slot
    L:Advance(DUI_LAYOUT.ROW + 6)

    L:Header("Run")
    runText = L:Text(RunStatus(), { color = { 0.85, 0.85, 0.85 } })
    -- Seeded CONC_LINES deep and capped there (see SetConcStatus).
    concText = L:Text(string.rep("Alt: needs 1000 concentration, has ~900 (enough in 1d 4h).\n", CONC_LINES - 1)
        .. "Alt: needs 1000 concentration, has ~900 (enough in 1d 4h).",
        { color = { 0.85, 0.85, 0.85 } })
    concText:SetMaxLines(CONC_LINES)
    startBtn = MakeButton(config, "Start Run", 120, 40, L:Y(), function()
        if not db.enabled then
            Announce("Craft Planner is off - tick it on its row in the main window.")
            return
        end
        -- A run in progress loses its progress on restart, so that takes a second click.
        if db.runActive and select(1, RunProgress()) > 0 and not startBtn.armed then
            startBtn.armed = true
            startBtn:SetText("Click to restart")
            C_Timer.After(3, function() startBtn.armed = nil; startBtn:SetText("Start Run") end)
            return
        end
        startBtn.armed = nil
        startBtn:SetText("Start Run")
        StartRun()
    end, "Start Run", { body = "Resets every character's progress, warns about anyone short of concentration, and makes the Auctionator shopping list for the whole plan, minus reagents you already have in your bags, bank or warband bank." })
    MakeButton(config, "Rebuild List", 120, 170, L:Y(), function()
        if not db.enabled then
            Announce("Craft Planner is off - tick it on its row in the main window.")
            return
        end
        BuildShoppingList()
    end, "Rebuild List", { body = "Remakes the shopping list for the crafts still to do, without resetting progress. Use it after buying part of the list, or after changing a reagent tier." })
    L:Advance(DUI_LAYOUT.ROW + 6)

    L:Header("Plan", { card = false })
    local countLabel = config:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
    countLabel:SetPoint("TOPLEFT", 40, L:Y() - 5)
    countLabel:SetText("Count")
    local countInput = CreateFrame("EditBox", "DUI_CraftPlannerCountInput", config, "BackdropTemplate")
    countInput:SetSize(40, 25)
    countInput:SetPoint("TOPLEFT", 90, L:Y())
    countInput:SetAutoFocus(false)
    countInput:SetNumeric(true)
    countInput:SetFontObject(DUI_FontNormal)
    countInput:SetBackdrop(DUI_EditBackdrop)
    countInput:SetBackdropColor(0, 0, 0, 0.5)
    countInput:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(countInput, "border")
    countInput:SetTextInsets(5, 5, 0, 0)
    countInput:SetText("1")
    countInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    countInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    DUI_AddTooltip(countInput, "Count", "How many this character makes per run.")

    MakeButton(config, "Add Open Recipe", 140, 140, L:Y(), function()
        local n = tonumber(countInput:GetText()) or 1
        if n < 1 then n = 1 end
        AddOpenRecipe(n)
    end, "Add Open Recipe",
        { body = "Adds the recipe selected in your open profession window to the plan, for this character. Adding it again changes the count." })
    L:Advance(DUI_LAYOUT.ROW + 6)
    planBox = MakeListBox(L, LIST_H)

    L:Header("Reagents", { card = false })
    L:Text("Every reagent the plan uses, with how many you have against how many it needs. Pin a tier to buy and craft with that quality only; Any leaves the choice to you and Blizzard's window.")
    reagentBox = MakeListBox(L, REAGENT_LIST_H)

    L:Header("Options")
    L:Checkbox("Deposit crafted items when a bank opens", db, "autoDeposit", nil,
        "Opening any bank (or Open Warbank) moves what this character crafted for the run into the warband bank. Only the crafted items move, and only as many as were made.")
    L:Checkbox("Deposit bought reagents when a bank opens", db, "depositReagents", nil,
        "Opening any bank (or Open Warbank) during a run moves reagents the run still needs from your bags - and, at a banker, your own bank - into the warband bank, up to what the warband bank is short of. Pinned reagents move only their pinned tier.")
    L:Checkbox("Remind me on login", db, "loginReminder", nil,
        "Logging in on a character with something left to craft or bank prints a line in chat. /dan opens onto this panel either way.")

    L:FitHeight()
end

-- Hand correction for a miscounted craft: left-click on a row's progress marks one
-- more made, right-click takes one back. Before this the only way out of a wrong
-- credit was Start Run, which resets every character (reported live: a reagent
-- credited as the cauldron left Craft with nothing to make).
local function AdjustDone(entry, delta)
    if not db.runActive then
        Announce("no run in progress - nothing to correct.")
        return
    end
    local done = entry.done or 0
    local new = math.max(0, math.min(entry.count or 1, done + delta))
    if new == done then return end
    if delta < 0 then
        -- Takes back that craft's share of what is waiting for the bank, so a wrong
        -- credit doesn't leave the row stuck on "to bank".
        local share = math.floor((entry.toDeposit or 0) / done + 0.5)
        entry.toDeposit = math.max(0, (entry.toDeposit or 0) - share)
    else
        entry.toDeposit = (entry.toDeposit or 0) + 1
    end
    entry.done = new
    Announce("%s %s: %d of %d made.", ShortName(entry.char), entry.name or "?", new, entry.count or 1)
    SyncEvents()
    RefreshPanel()
end

local function PaintPlanList()
    for _, row in ipairs(planRows) do row:Hide() end
    local me = CharKey()
    for i, e in ipairs(db.entries) do
        local row = planRows[i]
        if not row then
            row = CreateFrame("Frame", nil, planBox.content)
            row:SetSize(PANEL_W - 70, 20)
            row.label = row:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
            row.label:SetPoint("LEFT", 4, 0)
            row.label:SetPoint("RIGHT", -140, 0)
            row.label:SetJustifyH("LEFT")
            row.label:SetWordWrap(false)
            row.statusBtn = CreateFrame("Button", nil, row)
            row.statusBtn:SetSize(56, 20)
            row.statusBtn:SetPoint("RIGHT", -30, 0)
            row.statusBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row.statusBtn:SetScript("OnClick", function(self, button)
                AdjustDone(self:GetParent().entry, button == "RightButton" and -1 or 1)
            end)
            DUI_AddTooltip(row.statusBtn, "Progress",
                "Made so far this run. Left-click marks one more made, right-click takes one back - for a craft that was counted wrong.")
            row.status = row.statusBtn:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
            row.status:SetPoint("RIGHT")
            row.conc = MakeChip(row, 42)
            row.conc:SetPoint("RIGHT", -90, 0)
            row.conc.text:SetText("Conc")
            row.conc:SetScript("OnClick", function(self)
                local e = self:GetParent().entry
                e.concentrate = not e.concentrate
                RefreshPanel()
            end)
            DUI_AddTooltip(row.conc, "Concentration",
                "Whether Craft spends concentration on this one (lit = yes). If the character runs short, Craft refuses rather than crafting without it.")
            row.remove = CreateFrame("Button", nil, row, "BackdropTemplate")
            row.remove:SetSize(20, 20)
            row.remove:SetPoint("RIGHT", -4, 0)
            row.remove:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
            row.remove:SetBackdropColor(0.6, 0.18, 0.18, 1) -- red = destructive
            row.remove:SetBackdropBorderColor(0, 0, 0, 1)
            local x = row.remove:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
            x:SetPoint("CENTER"); x:SetText("X"); x:SetTextColor(1, 1, 1)
            row.remove:SetScript("OnClick", function(self) RemoveEntry(self:GetParent().entry) end)
            DUI_AddTooltip(row.remove, "Remove", "Takes this craft out of the plan.")
            planRows[i] = row
        end
        row:SetPoint("TOPLEFT", planBox.content, "TOPLEFT", 6, -((i - 1) * ROW_H) - 4)
        row.entry = e
        -- This character in white, the rest dimmed. Not the accent: the list is only
        -- repainted on refresh, so an accent here would go stale on a theme change.
        row.label:SetText(string.format("%s%s|r  |cffdddddd%dx %s|r  |cff777777%s|r",
            e.char == me and "|cffffffff" or "|cff999999", ShortName(e.char),
            e.count or 1, e.name or "?", e.profName or ""))
        row.status:SetText(EntryStatus(e))
        row.conc:SetLit(e.concentrate)
        row:Show()
    end
    SizeListBox(planBox, #db.entries)
end

-- Cycles a reagent's pin: Any -> lowest tier -> ... -> highest -> Any.
local function CycleTier(ids)
    local t = TierIndex(ids)
    if not t then
        db.tiers[ids[1]] = 1
    elseif t < #ids then
        db.tiers[ids[1]] = t + 1
    else
        db.tiers[ids[1]] = nil
    end
    RefreshPanel()
end

local function PaintReagentList()
    for _, row in ipairs(reagentRows) do row:Hide() end
    local need, order = AggregateReagents(db.runActive)
    for i, key in ipairs(order) do
        local r = need[key]
        local row = reagentRows[i]
        if not row then
            row = CreateFrame("Frame", nil, reagentBox.content)
            row:SetSize(PANEL_W - 70, 20)
            row.label = row:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
            row.label:SetPoint("LEFT", 4, 0)
            row.label:SetPoint("RIGHT", -170, 0)
            row.label:SetJustifyH("LEFT")
            row.label:SetWordWrap(false)
            row.counts = row:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
            row.counts:SetPoint("RIGHT", -60, 0)
            row.tier = MakeChip(row, 46)
            row.tier:SetPoint("RIGHT", -4, 0)
            row.tier:SetScript("OnClick", function(self) CycleTier(self:GetParent().ids) end)
            DUI_AddTooltip(row.tier, "Reagent tier",
                { body = "Click to cycle Any / each tier. A pinned tier is what the shopping list searches for, the only tier counted as owned, and what Craft uses for this reagent.",
                  note = "Press Rebuild List after changing a tier." })
            reagentRows[i] = row
        end
        row:SetPoint("TOPLEFT", reagentBox.content, "TOPLEFT", 6, -((i - 1) * ROW_H) - 4)
        row.ids = r.ids
        local t = TierIndex(r.ids)
        local have = HaveOf(r.ids, OwnedCount)
        row.label:SetText(ItemName(r.ids[t or 1]))
        row.counts:SetText(string.format("%s%d|r / %d", have >= r.qty and "|cff80ff80" or "|cffff8080", have, r.qty))
        if #r.ids > 1 then
            row.tier.text:SetText(t and ("Q" .. TierQuality(r.ids, t)) or "Any")
            row.tier:SetLit(t ~= nil)
            row.tier:Show()
        else
            row.tier:Hide()
        end
        row:Show()
    end
    SizeListBox(reagentBox, #order)
end

RefreshPanel = function()
    if not (config.init and db and config:IsShown()) then return end
    hereText:SetText(HereStatus())
    runText:SetText(RunStatus())
    SetConcStatus(concText)
    PaintPlanList()
    PaintReagentList()
end

function DUI_OpenCraftPlannerConfig()
    if not db then DUI_InitCraftPlannerDB() end
    if not config.init then
        BuildPanel()
        config.init = true
    end
    config:Show()
    RefreshPanel()
end

function DUI_CraftPlannerApplyEnabled()
    SyncEvents()
    SyncWarbankButton()
    RefreshPanel()
end

-- Open Warbank. Casting a spell from a click needs a SecureActionButton, and a
-- secure button makes every frame above it protected - parented into this panel,
-- it would lock the docking pane and DUI_MainFrame, so /dan or a rail click in
-- combat would throw ADDON_ACTION_BLOCKED. So it is parented to UIParent and
-- only *pinned* over the panel's slot while the panel is up out of combat. At
-- PLAYER_REGEN_DISABLED (the last moment a protected Hide is allowed) it is
-- hidden and unpinned, so no insecure frame is anchoring a protected one in
-- combat either.
local warbankBtn = CreateFrame("Button", "DUI_CraftPlannerWarbankButton", UIParent,
    "SecureActionButtonTemplate, BackdropTemplate")
warbankBtn:SetSize(130, 25)
warbankBtn:Hide()
warbankBtn:SetAttribute("type", "spell")
warbankBtn:SetAttribute("spell", WARBANK_SPELL_ID)
warbankBtn:RegisterForClicks("AnyUp", "AnyDown")
warbankBtn:SetText("Open Warbank")
StyleAsTealTab(warbankBtn)
DUI_AddTooltip(warbankBtn, "Open Warbank",
    { body = "Casts Warband Bank Distance Inhibitor, which opens the warband bank wherever you are. With the deposit options ticked, crafted items and bought reagents then move in by themselves.",
      note = "The character needs the spell; if it doesn't have it, the cast just fails." })

-- Parented to UIParent, the button isn't clipped by the launcher pane's scroll
-- frame, so scrolling the slot out of the pane carried it out over the window's
-- edge (reported live). It is hidden instead whenever the slot isn't wholly
-- inside the visible pane, re-checked from the pane's OnVerticalScroll; the slot
-- is an inert look-alike, so the panel shows that rather than a gap.
local hookedScroll

local function PaneScrollFrame()
    local content = config:GetParent()
    local sf = content and content:GetParent()
    if sf and sf.GetScrollChild and sf:GetScrollChild() == content then return sf end
end

local function SlotInPaneView(slot)
    local sf = PaneScrollFrame()
    if not sf then return true end -- floating: nothing clips it
    if hookedScroll ~= sf then
        hookedScroll = sf
        sf:HookScript("OnVerticalScroll", function() SyncWarbankButton() end)
    end
    local st, sb, ft, fb = slot:GetTop(), slot:GetBottom(), sf:GetTop(), sf:GetBottom()
    if not (st and sb and ft and fb) then return true end -- not laid out yet
    local ss, fs = slot:GetEffectiveScale(), sf:GetEffectiveScale()
    return st * ss <= ft * fs + 1 and sb * ss >= fb * fs - 1
end

SyncWarbankButton = function()
    if InCombatLockdown() then return end
    local slot = config.warbankSlot
    local want = slot and db and db.enabled and config:IsVisible() and SlotInPaneView(slot)
    if want then
        warbankBtn:ClearAllPoints()
        warbankBtn:SetAllPoints(slot)
        -- The panel's own strata and just above its level. The main window is
        -- TOOLTIP strata, so anything lower (this was DIALOG) is drawn under the
        -- window's translucent fill - greyed out - and the window eats the click.
        -- Read from the panel rather than hardcoded, since docked and floating
        -- panels sit at different levels.
        warbankBtn:SetFrameStrata(config:GetFrameStrata())
        warbankBtn:SetFrameLevel(math.min(config:GetFrameLevel() + 20, 9000))
        warbankBtn:Show()
    elseif warbankBtn:IsShown() or warbankBtn:GetNumPoints() > 0 then
        warbankBtn:Hide()
        warbankBtn:ClearAllPoints()
    end
end

local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        -- Deliberately unguarded: this is the one place the hide is still allowed.
        warbankBtn:Hide()
        warbankBtn:ClearAllPoints()
    else
        SyncWarbankButton()
    end
end)

-- Bag counts, item names and the open recipe all change what the panel says.
-- They are chatty, so they are only listened to while it is up, and coalesced
-- to one repaint per frame.
local repaintQueued = false
local panelListener = CreateFrame("Frame")
panelListener:SetScript("OnEvent", function()
    if repaintQueued then return end
    repaintQueued = true
    C_Timer.After(0, function() repaintQueued = false; RefreshPanel() end)
end)

config:HookScript("OnShow", function()
    -- OnShow is queued, so the launcher's index warm-up (show and hide in one
    -- frame) still lands here with the panel already gone.
    if not config:IsShown() then return end
    panelListener:RegisterEvent("BAG_UPDATE_DELAYED")
    panelListener:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    panelListener:RegisterEvent("TRADE_SKILL_SHOW")
    panelListener:RegisterEvent("TRADE_SKILL_CLOSE")
    panelListener:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
    SyncWarbankButton()
    -- Again next frame, once the dock has re-parented the panel and laid it out,
    -- so the pane's scroll hook is in place and the view check reads real rects.
    C_Timer.After(0, SyncWarbankButton)
    RefreshPanel()
end)
-- Also fires when the main window hides around a docked panel (the client sends
-- OnHide down to descendants), so the button follows the window out.
config:HookScript("OnHide", function()
    panelListener:UnregisterAllEvents()
    SyncWarbankButton()
end)

DUI_CraftPlannerConfig = config

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

-- Registered only while there is something for each group to do on this
-- character, so a character with no part in a run hears none of them:
--   craft  - this character has crafts left in an active run. TRADE_SKILL_CRAFT_BEGIN
--            names the recipe of every craft started, so a result is credited to
--            the craft that made it (it replaced a player UNIT_SPELLCAST_SUCCEEDED
--            watch, which fired on every cast, combat included).
--   bank   - a run is active (crafted items or reagents may need depositing).
--   trade  - this character has anything in the plan (pending recipe opens, and a
--            concentration reading whenever its profession window opens).
local EVENT_GROUPS = {
    craft = { "TRADE_SKILL_ITEM_CRAFTED_RESULT", "TRADE_SKILL_CRAFT_BEGIN" },
    bank  = { "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
              "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" },
    trade = { "TRADE_SKILL_SHOW" },
}

local eventFrame = CreateFrame("Frame")
local groupOn = {}
local depositedThisVisit = false
local function SetGroup(name, on)
    on = on and true or false
    if (groupOn[name] or false) == on then return end
    groupOn[name] = on
    for _, e in ipairs(EVENT_GROUPS[name]) do
        if on then
            eventFrame:RegisterEvent(e)
        else
            eventFrame:UnregisterEvent(e)
        end
    end
end

function SyncEvents()
    if not db then return end
    local on = db.enabled
    local craftsLeft = false
    if on and db.runActive then
        for _, e in ipairs(MyEntries()) do
            if Remaining(e) > 0 then craftsLeft = true; break end
        end
    end
    SetGroup("craft", craftsLeft)
    if not groupOn.craft then craftingSpell = nil end
    SetGroup("bank", on and db.runActive)
    SetGroup("trade", on and #MyEntries() > 0)
    if not groupOn.trade then pendingOpenRecipe = nil end
end

-- Bank data settles a moment after the open, so the deposit waits half a second
-- and re-checks that the bank is still there. Once per visit: the banker and the
-- interaction manager both report the same open.
local function OnBankOpened()
    if depositedThisVisit or not (db.autoDeposit or db.depositReagents) then return end
    depositedThisVisit = true
    C_Timer.After(0.5, function() if AtBank() then Deposit(false) end end)
end

local function IsBankInteraction(t)
    local types = Enum.PlayerInteractionType
    return types and (t == types.Banker or t == types.AccountBanker)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if not db or not db.enabled then return end
    if event == "TRADE_SKILL_CRAFT_BEGIN" then
        -- Any recipe, plan or not: a craft outside the plan has to replace the
        -- last one, or its results would be credited to it.
        craftingSpell = ...
        return
    end
    if event == "TRADE_SKILL_SHOW" then
        RecordMyConcentration()
        if pendingOpenRecipe then
            local recipeID = pendingOpenRecipe
            pendingOpenRecipe = nil
            -- The window's own recipe list is filled a frame after it shows.
            C_Timer.After(0.1, function() C_TradeSkillUI.OpenRecipe(recipeID) end)
        end
    elseif event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
        OnCraftResult(...)
    elseif event == "BANKFRAME_OPENED" then
        OnBankOpened()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        if IsBankInteraction(...) then OnBankOpened() end
    elseif event == "BANKFRAME_CLOSED" then
        depositedThisVisit = false
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        if IsBankInteraction(...) then depositedThisVisit = false end
    end
end)

-- On login: refresh this character's saved reagent copies and concentration (the
-- other characters read both), then, if it has work in the run, point /dan at this
-- panel (the launcher re-docks whatever lastModule names) and optionally say so.
-- PLAYER_LOGIN rather than ADDON_LOADED: the realm half of the character key is
-- not reliable before it, so the key and the event sync are redone here.
local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function()
    if not db then return end
    myKey = nil
    InvalidateMine()
    for _, e in ipairs(MyEntries()) do
        ReagentsFor(e)
        PruneOutputs(e) -- clears a reagent wrongly learned as an output
    end
    RecordMyConcentration()
    SyncEvents()
    if not HasWork() then return end
    DanUIDB.Launcher = DanUIDB.Launcher or {}
    DanUIDB.Launcher.lastModule = "DUI_CraftPlannerConfig"
    if not db.loginReminder then return end
    -- Late enough to land below the login spam rather than in the middle of it.
    C_Timer.After(6, function()
        local entry = NextToCraft()
        if entry then
            Announce("this character still has to craft %dx %s. Type /dan to do it.", Remaining(entry), entry.name)
        else
            Announce("this character's crafts are done - Open Warbank (or visit a bank) to put them in the warband bank.")
        end
    end)
end)

function DUI_InitCraftPlanner()
    DUI_InitCraftPlannerDB()
    SyncEvents()
end
