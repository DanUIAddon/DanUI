-- GroupSplit.lua
-- Logic inspired by MRT (Method Raid Tools)

local splitClassPrio = {
    [1] = 15, -- WARRIOR
    [2] = 14, -- PALADIN
    [4] = 13, -- ROGUE
    [6] = 12, -- DEATHKNIGHT
    [12] = 11, -- DEMONHUNTER
    [7] = 10, -- SHAMAN
    [10] = 9, -- MONK
    [11] = 8, -- DRUID
    [3] = 7,  -- HUNTER
    [5] = 6,  -- PRIEST
    [8] = 5,  -- MAGE
    [9] = 4,  -- WARLOCK
    [13] = 3, -- EVOKER
}

local function GetPlayerPrio(name)
    local prio = 0

    local role = UnitGroupRolesAssigned(name)
    local _, _, classNum = UnitClass(name)

    if role == "TANK" then prio = prio + 60
    elseif role == "DAMAGER" then prio = prio + 40
    elseif role == "HEALER" then prio = prio + 20 end

    if classNum then
        prio = prio + (splitClassPrio[classNum] or classNum)
    end
    return prio
end

function DUI_SplitRoster()
    local db = DanUIDB
    local popout = DUI_GroupsPopout
    if not db or not popout or not popout.Edits then return end

    local GROUPS_OPT = db.SplitGroups or {true, true, true, true, true, true, true, true}
    local splitParts = db.SplitParts or "auto"
    -- "block"      -> each part gets a contiguous run of groups (1,2,3 | 4,5,6)
    -- "interleave" -> parts take every Nth group in turn      (1,3,5 | 2,4,6)
    local splitLayout = db.SplitLayout or "block"

    if splitParts == "auto" then
        local numMembers = GetNumGroupMembers()
        if numMembers > 30 then
            splitParts = 8
        elseif numMembers > 20 then
            splitParts = 6
        elseif numMembers > 10 then
            splitParts = 4
        else
            splitParts = 2
        end
        print(string.format("|cFF00FF00[DUI]|r Auto-selected split into %d parts based on raid size (%d members).", splitParts, numMembers))
    end

    local roster = {}
    local groups_opted_max = 0

    -- 1. Collect names from enabled groups
    for i = 1, 8 do
        if GROUPS_OPT[i] then
            groups_opted_max = groups_opted_max + 1
            for j = 1, 5 do
                local idx = (i - 1) * 5 + j
                local eb = popout.Edits[idx]
                local name = strtrim(eb:GetText())
                if name and name ~= "" then
                    table.insert(roster, {name = name, prio = GetPlayerPrio(name)})
                end
            end
        end
    end

    -- Pull from current raid roster if arranger is empty
    if #roster == 0 then
        if IsInRaid() then
            for i = 1, GetNumGroupMembers() do
                local name = GetRaidRosterInfo(i)
                if name then
                    table.insert(roster, {name = Ambiguate(name, "short"), prio = GetPlayerPrio(name)})
                end
            end
        end
    end

    if #roster == 0 then return end
    -- Clear existing names in enabled groups before redistribution
    for i = 1, 8 do
        if GROUPS_OPT[i] then
            for j = 1, 5 do
                popout.Edits[(i - 1) * 5 + j]:SetText("")
            end
        end
    end

    -- 2. Sort by priority
    table.sort(roster, function(a, b)
        if a.prio == b.prio then return a.name < b.name else return a.prio > b.prio end
    end)

    -- 3. Distribute players alternatingly (Balancing roles/classes across parts)
    local enabledGroups = {}
    for i = 1, 8 do
        if GROUPS_OPT[i] then
            table.insert(enabledGroups, i)
        end
    end

    -- Size the bundles per part, not for the raid as a whole. Players are dealt
    -- to parts evenly, so every part needs room for ceil(#roster / parts) of them.
    -- Sizing the raid instead (ceil(24/5) = 5 groups) split 2 teams as 3 | 2
    -- groups, and the second team's 12 players could not fit in 10 slots.
    local groupsPerPart = math.ceil(math.ceil(#roster / splitParts) / 5)
    local groupsToUse = math.min(#enabledGroups, groupsPerPart * splitParts)

    -- Build the bundle of raid groups that belongs to each part
    local partGroups = {}
    for p = 1, splitParts do partGroups[p] = {} end

    if splitLayout == "interleave" then
        -- Part 1 takes groups 1,3,5 ... part 2 takes 2,4,6 ...
        for idx = 1, groupsToUse do
            local p = ((idx - 1) % splitParts) + 1
            table.insert(partGroups[p], enabledGroups[idx])
        end
    else
        -- Part 1 takes groups 1,2,3 ... part 2 takes 4,5,6 ...
        local basePartSize = math.floor(groupsToUse / splitParts)
        local extraGroups = groupsToUse % splitParts
        local currentIdx = 1
        for p = 1, splitParts do
            local size = basePartSize + (p <= extraGroups and 1 or 0)
            for _ = 1, size do
                table.insert(partGroups[p], enabledGroups[currentIdx])
                currentIdx = currentIdx + 1
            end
        end
    end

    -- Drop parts that ended up with no groups (fewer groups available than parts)
    local activeParts = {}
    for p = 1, splitParts do
        if #partGroups[p] > 0 then
            table.insert(activeParts, partGroups[p])
        end
    end
    if #activeParts == 0 then return end
    splitParts = #activeParts

    -- If every team ends up with a single group there is nothing to bundle, so both
    -- layouts collapse to a plain round-robin. Say so rather than silently ignoring it.
    local maxBundle = 0
    for _, bundle in ipairs(activeParts) do
        if #bundle > maxBundle then maxBundle = #bundle end
    end
    if maxBundle == 1 and #activeParts > 1 then
        print(string.format("|cFFFFAA00[DUI]|r Layout ignored: %d teams across %d groups leaves 1 group per team. Right-click Split and pick '2 Teams' for a 1,2,3 | 4,5,6 style split.", #activeParts, groupsToUse))
    end

    local partCursor = {} -- Which group in the bundle we are currently targeting for each part
    for p = 1, splitParts do partCursor[p] = 1 end

    local groupSlots = {1, 1, 1, 1, 1, 1, 1, 1} -- Tracks the next available slot (1-5) for every actual group (1-8)

    -- Each part's groups fill in fives, the remainder in its last group: 14
    -- players over groups 1-3 come out 5/5/4, and 12 come out 5/5/2 rather than
    -- an even 4/4/4. Players are still dealt round-robin across
    -- the bundle below, so tanks and healers keep spreading over the groups; the
    -- caps only decide where each group stops taking them.
    local groupCap = {5, 5, 5, 5, 5, 5, 5, 5}
    for p, bundle in ipairs(activeParts) do
        -- Parts are dealt in strict rotation, so their sizes are known up front.
        local left = math.floor(#roster / splitParts) + (p <= #roster % splitParts and 1 or 0)
        for _, g in ipairs(bundle) do
            groupCap[g] = math.max(0, math.min(5, left))
            left = left - groupCap[g]
        end
    end

    -- Next group with a free slot in this part's bundle, starting at its cursor.
    -- Falls back to any enabled group so a player is never silently dropped when
    -- the enabled groups are too few for an even split.
    local function FindGroup(p)
        local bundle = activeParts[p]
        for step = 0, #bundle - 1 do
            local c = ((partCursor[p] - 1 + step) % #bundle) + 1
            if groupSlots[bundle[c]] <= groupCap[bundle[c]] then
                partCursor[p] = (c % #bundle) + 1
                return bundle[c]
            end
        end
        for _, g in ipairs(enabledGroups) do
            if groupSlots[g] <= 5 then return g end
        end
    end

    local unplaced = 0
    local currentPart = 1
    for i = 1, #roster do
        local targetGroup = FindGroup(currentPart)
        if targetGroup then
            local posInGroup = groupSlots[targetGroup]
            local eb = popout.Edits[(targetGroup - 1) * 5 + posInGroup]
            eb:SetText(roster[i].name)
            eb:SetCursorPosition(0)
            groupSlots[targetGroup] = posInGroup + 1
        else
            unplaced = unplaced + 1
        end

        currentPart = currentPart + 1
        if currentPart > splitParts then currentPart = 1 end
    end
    if unplaced > 0 then
        print(string.format("|cFFFFAA00[DUI]|r %d player(s) did not fit in the enabled groups. Enable more groups (right-click Split).", unplaced))
    end
end
