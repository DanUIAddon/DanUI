local _, core = ...
core.Sort = {}

local Sort = core.Sort

local totalItemCount = {}
local itemsFlagged = {}
local movesToMake = {}
local startMoving = nil
local isSorting = false
local wait = 0.5

local movesLeftAnnouncer = {
    [10] = "10 moves left",
    [25] = "25 moves left",
    [50] = "50 moves left",
    [100] = "100 moves left",
}


local function delay(tick)
    local th = coroutine.running()
    C_Timer.After(tick, function() 
        local success, err = coroutine.resume(th)
        if not success then
            print("|cFFFF0000GuildBankSort Error:|r " .. tostring(err))
            isSorting = false -- Reset the lock so you can try again
        end
    end)
    coroutine.yield()
end

local function StartCoroutine(func, ...)
    if type(func) ~= "function" then
        print("|cff77DD77DUI_GuildBankSort:|r StartCoroutine called with non-function")
        return
    end
    
    if coroutine and coroutine.wrap then
        local ok, wrapper = pcall(coroutine.wrap, func)
        if ok and wrapper then
            return wrapper(...)
        end
    end
    
    if coroutine and coroutine.create and coroutine.resume then
        local ok, co = pcall(coroutine.create, func)
        if ok and co then
            local resumeOk, err = coroutine.resume(co, ...)
            if not resumeOk and err then
                print("|cff77DD77DUI_GuildBankSort:|r Coroutine error: " .. tostring(err))
            end
            return resumeOk, err
        end
    end
    
    print("|cff77DD77DUI_GuildBankSort:|r Coroutine support unavailable, calling function directly")
    return func(...)
end

local function IsGuildBankOpen()
    if core and core.GuildBankIsOpen then return true end
    if GuildBankFrame and GuildBankFrame:IsShown() then return true end
    local numTabs = GetNumGuildBankTabs()
    if numTabs and numTabs > 0 then return true end
    return false
end

local function updateGuildBankItems()
    print("|cff77DD77DUI_GuildBankSort:|r Updating guild bank items")
    for tab = 1, GetNumGuildBankTabs() do
        if not isSorting then return end

        print("|cff77DD77DUI_GuildBankSort:|r tab " .. tab)
        QueryGuildBankTab(tab)
        delay(wait)
    end
end

--- Returns if item is blacklisted or whitelisted
---@param itemID integer
---@param expacName string
---@param itemType string
---@param itemSubType string
---@param qualityName string
---@param profile table The player profile containing whitelist/blacklist
---@return "blacklist/whitelist"
local function getBlacklist(itemID, expacName, itemType, itemSubType, qualityName, profile)
    if not profile or not profile.whitelist or not profile.blacklist then
        return "whitelist"
    end
    
    for _, whitelistItem in ipairs(profile.whitelist) do
        if whitelistItem == itemID or whitelistItem == expacName or whitelistItem == itemType .. " " .. itemSubType or whitelistItem == itemType or whitelistItem == qualityName then
            return "whitelist"
        end
    end
    for _, blacklistItem in ipairs(profile.blacklist) do
        if blacklistItem == itemID or blacklistItem == expacName or blacklistItem == itemType .. " " .. itemSubType or blacklistItem == itemType or blacklistItem == qualityName or blacklistItem == "All Items" then
            return "blacklist"
        end
    end
    return "whitelist"
end

--- Adds item to table
---@param tab integer
---@param slot integer
---@param currentGuildBankTab boolean
---@param profile table The player profile containing options and priorities
local function FetchItemInfo(tab, slot, currentGuildBankTab, profile)
    if not profile then return end
    
local itemLink = GetGuildBankItemLink(tab, slot)
    if itemLink then
        local _, itemCount = GetGuildBankItemInfo(tab, slot)
        local itemName, _, itemQuality, _, _, itemType, itemSubType, itemStackCount, _, _, _, _, _, _, expacID = C_Item.GetItemInfo(itemLink)
        
        -- Safe fallback for itemID
        local itemID = nil
        if core and type(core.getItemID) == "function" then
            itemID = core:getItemID(itemLink)
        else
            -- Extract ID natively from the item string
            itemID = tonumber(string.match(itemLink, "item:(%d+)"))
        end
        
        if not itemID then return end -- Failsafe: skip if item is completely invalid
        
        -- Safe fallback for Expansion Name
        local expacName = "Unknown"
        if core and type(core.getExpacName) == "function" then
            expacName = core:getExpacName(expacID)
        elseif expacID then
            expacName = tostring(expacID)
        end
        local qualityName
        local priority
        local flag

        -- Get quality name from core.Config, with fallback
        if core and core.Config and core.Config.qualities then
            for _, qualityTable in ipairs(core.Config.qualities) do
                if itemQuality == qualityTable.qualityValue then
                    qualityName = qualityTable.qualityName
                end
            end
        else
            qualityName = "Unknown"
        end

        -- Get max priority with fallback
        local maxPrio = (core and core.DB and core.DB.maxPriority) or 100
        local midPrio = floor(maxPrio / 2) + 0.5
        
        if profile.options and profile.options.sortBy then
            priority = profile.priority[itemID] or profile.priority[expacName] or profile.priority[itemType .. " " .. itemSubType] or profile.priority[itemType] or profile.priority[qualityName] or midPrio
            flag = profile.flag[itemID] or profile.flag[expacName] or profile.flag[itemType .. " " .. itemSubType] or profile.flag[itemType] or profile.flag[qualityName] or 9
        else
            priority = profile.priority[itemID] or profile.priority[itemType .. " " .. itemSubType] or profile.priority[itemType] or profile.priority[expacName] or profile.priority[qualityName] or midPrio
            flag = profile.flag[itemID] or profile.flag[itemType .. " " .. itemSubType] or profile.flag[itemType] or profile.flag[expacName] or profile.flag[qualityName] or 9
        end

        local stack = profile.stack[itemID] or itemStackCount
        local blacklist
        
        if (currentGuildBankTab and tab ~= currentGuildBankTab) or (profile.options and profile.options.ignoreTab and profile.options.ignoreTab[tostring(tab)]) then
            blacklist = "blacklist"
        else
            blacklist = getBlacklist(itemID, expacName, itemType, itemSubType, qualityName, profile)
        end

        tinsert(Sort.itemLocation, {tab = tab, slot = slot, itemID = itemID, itemCount = itemCount, priority = priority, flag = flag, stack = stack, itemQuality = itemQuality, itemName = itemName, blacklist = blacklist, forced = false})
        
        if totalItemCount[itemID] then
            totalItemCount[itemID] = totalItemCount[itemID] + itemCount
        else
            totalItemCount[itemID] = itemCount
        end
    end
end

local function fetchAllItems(profile)
    if not profile then return end
    for tab = 1, GetNumGuildBankTabs() do
        for slot = 1, 98 do
            FetchItemInfo(tab, slot, nil, profile)
        end
    end
end

local function fetchCurrentTabItems(profile)
    if not profile then return end
    for tab = 1, GetNumGuildBankTabs() do
        for slot = 1, 98 do
            FetchItemInfo(tab, slot, GetCurrentGuildBankTab(), profile)
        end
    end
end

local function forceItems(profile)
    local forceCounter = {}
    for startPos = 1, #Sort.itemLocation - 1 do
        local forceStackSize
        local forceStacks
        if profile.forcedFlag[Sort.itemLocation[startPos].itemID] then
            forceStackSize = profile.forcedFlag[Sort.itemLocation[startPos].itemID].stackSize
            forceStacks = profile.forcedFlag[Sort.itemLocation[startPos].itemID].stack
        else
            forceStackSize = 0
            forceStacks = 0
        end
        if forceStacks > 0 and not forceCounter[Sort.itemLocation[startPos].itemID] then
            forceCounter[Sort.itemLocation[startPos].itemID] = 0
        end
        if forceStackSize > 0 and forceCounter[Sort.itemLocation[startPos].itemID] < forceStacks and Sort.itemLocation[startPos].blacklist == "whitelist" and not Sort.itemLocation[startPos].forced then
            local forceTab = profile.forcedFlag[Sort.itemLocation[startPos].itemID].tab
            if Sort.itemLocation[startPos].itemCount == forceStackSize then
                Sort.itemLocation[startPos].forced = true
                Sort.itemLocation[startPos].priority = 0
                Sort.itemLocation[startPos].flag = forceTab
                Sort.itemLocation[startPos].stack = forceStackSize
                forceCounter[Sort.itemLocation[startPos].itemID] = forceCounter[Sort.itemLocation[startPos].itemID] + 1
            elseif Sort.itemLocation[startPos].itemCount ~= 0 then
                for slot = 1, 98 do
                    local itemFound = false
                    for nextItem = 1, #Sort.itemLocation do
                        if Sort.itemLocation[nextItem].tab == forceTab and Sort.itemLocation[nextItem].slot == slot and Sort.itemLocation[nextItem].itemCount > 0 and startPos ~= nextItem and not Sort.itemLocation[nextItem].forced then
                            if Sort.itemLocation[startPos].itemID == Sort.itemLocation[nextItem].itemID then
                                if Sort.itemLocation[nextItem].itemCount == forceStackSize then
                                    Sort.itemLocation[nextItem].forced = true
                                    Sort.itemLocation[nextItem].priority = 0
                                    Sort.itemLocation[nextItem].flag = forceTab
                                    Sort.itemLocation[nextItem].stack = forceStackSize
                                    forceCounter[Sort.itemLocation[startPos].itemID] = forceCounter[Sort.itemLocation[startPos].itemID] + 1
                                elseif Sort.itemLocation[nextItem].itemCount < forceStackSize then
                                    if Sort.itemLocation[nextItem].itemCount + Sort.itemLocation[startPos].itemCount < forceStackSize then
                                        tinsert(movesToMake, {tab = Sort.itemLocation[startPos].tab, slot = Sort.itemLocation[startPos].slot})
                                        tinsert(movesToMake, {tab = forceTab, slot = slot})
                                        Sort.itemLocation[nextItem].itemCount = Sort.itemLocation[nextItem].itemCount + Sort.itemLocation[startPos].itemCount
                                        Sort.itemLocation[startPos].itemCount = 0
                                    else
                                        tinsert(movesToMake, {tab = Sort.itemLocation[startPos].tab, slot = Sort.itemLocation[startPos].slot, amount = forceStackSize - Sort.itemLocation[nextItem].itemCount})
                                        tinsert(movesToMake, {tab = forceTab, slot = slot})
                                        Sort.itemLocation[startPos].itemCount = Sort.itemLocation[startPos].itemCount - forceStackSize + Sort.itemLocation[nextItem].itemCount
                                        Sort.itemLocation[nextItem].itemCount = forceStackSize
                                        Sort.itemLocation[nextItem].forced = true
                                        Sort.itemLocation[nextItem].priority = 0
                                        Sort.itemLocation[nextItem].flag = forceTab
                                        Sort.itemLocation[nextItem].stack = forceStackSize
                                        forceCounter[Sort.itemLocation[startPos].itemID] = forceCounter[Sort.itemLocation[startPos].itemID] + 1
                                    end
                                end
                            elseif forceCounter[Sort.itemLocation[startPos].itemID] < forceStacks then
                                local tabSpot
                                local slotSpot
                                local foundEmptySpot
                                for emptySlot = 1, 98 do
                                    foundEmptySpot = true
                                    for emptyItem = 1, #Sort.itemLocation do
                                        if Sort.itemLocation[emptyItem].tab == forceTab and Sort.itemLocation[emptyItem].slot == emptySlot then
                                            foundEmptySpot = false
                                            if Sort.itemLocation[emptyItem].itemID == Sort.itemLocation[startPos].itemID and forceCounter[Sort.itemLocation[startPos].itemID] < forceStacks and not Sort.itemLocation[emptyItem].forced then
                                                if Sort.itemLocation[emptyItem].itemCount == forceStackSize then
                                                    Sort.itemLocation[emptyItem].forced = true
                                                    Sort.itemLocation[emptyItem].priority = 0
                                                    Sort.itemLocation[emptyItem].flag = forceTab
                                                    Sort.itemLocation[emptyItem].stack = forceStackSize
                                                    forceCounter[Sort.itemLocation[startPos].itemID] = forceCounter[Sort.itemLocation[startPos].itemID] + 1
                                                end
                                            end
                                            break
                                        end
                                    end
                                    if foundEmptySpot then
                                        tabSpot = forceTab
                                        slotSpot = emptySlot
                                        break
                                    end
                                end
                                if forceCounter[Sort.itemLocation[startPos].itemID] < forceStacks then
                                    if Sort.itemLocation[startPos].itemCount == forceStackSize then
                                        Sort.itemLocation[startPos].forced = true
                                        Sort.itemLocation[startPos].priority = 0
                                        Sort.itemLocation[startPos].flag = forceTab
                                        Sort.itemLocation[startPos].stack = forceStackSize
                                        forceCounter[Sort.itemLocation[startPos].itemID] = forceCounter[Sort.itemLocation[startPos].itemID] + 1
                                    elseif Sort.itemLocation[startPos].itemCount > forceStackSize then
                                        tinsert(movesToMake, {tab = Sort.itemLocation[startPos].tab, slot = Sort.itemLocation[startPos].slot, amount = forceStackSize})
                                        tinsert(movesToMake, {tab = tabSpot, slot = slotSpot})
                                        Sort.itemLocation[startPos].itemCount = Sort.itemLocation[startPos].itemCount - forceStackSize
                                        tinsert(Sort.itemLocation, {tab = tabSpot, slot = slotSpot, itemID = Sort.itemLocation[startPos].itemID, itemCount = forceStackSize, priority = 0, flag = forceTab, stack = forceStackSize, itemQuality = Sort.itemLocation[startPos].itemQuality, itemName = Sort.itemLocation[startPos].itemName, blacklist = Sort.itemLocation[startPos].blacklist, forced = true})
                                        forceCounter[Sort.itemLocation[startPos].itemID] = forceCounter[Sort.itemLocation[startPos].itemID] + 1
                                    elseif Sort.itemLocation[startPos].tab ~= forceTab then
                                        tinsert(movesToMake, {tab = Sort.itemLocation[startPos].tab, slot = Sort.itemLocation[startPos].slot})
                                        tinsert(movesToMake, {tab = tabSpot, slot = slotSpot})
                                        Sort.itemLocation[startPos].tab = tabSpot
                                        Sort.itemLocation[startPos].slot = slotSpot   
                                    end
                                end
                            else

                            end
                            itemFound = true
                            break
                        end
                    end
                    if not itemFound and not (Sort.itemLocation[startPos].tab == forceTab and Sort.itemLocation[startPos].slot == slot) and not Sort.itemLocation[startPos].forced then
                        if (Sort.itemLocation[startPos].itemCount == forceStackSize) or (totalItemCount[Sort.itemLocation[startPos].itemID] < forceStackSize * (forceCounter[Sort.itemLocation[startPos].itemID] + 1)) then
                            Sort.itemLocation[startPos].forced = true
                            Sort.itemLocation[startPos].priority = 0
                            Sort.itemLocation[startPos].flag = forceTab
                            Sort.itemLocation[startPos].stack = forceStackSize
                            forceCounter[Sort.itemLocation[startPos].itemID] = forceCounter[Sort.itemLocation[startPos].itemID] + 1
                        elseif Sort.itemLocation[startPos].itemCount > forceStackSize then
                            local foundItem = false
                            for nextItem = 1, #Sort.itemLocation do
                                if Sort.itemLocation[nextItem].tab == forceTab and Sort.itemLocation[nextItem].slot == slot and Sort.itemLocation[nextItem].itemCount > 0 then
                                    if not Sort.itemLocation[nextItem].forced then
                                        tinsert(movesToMake, {tab = Sort.itemLocation[startPos].tab, slot = Sort.itemLocation[startPos].slot, amount = forceStackSize})
                                        tinsert(movesToMake, {tab = forceTab, slot = slot})
                                        Sort.itemLocation[startPos].itemCount = Sort.itemLocation[startPos].itemCount - forceStackSize
                                        tinsert(Sort.itemLocation, {tab = forceTab, slot = slot, itemID = Sort.itemLocation[startPos].itemID, itemCount = forceStackSize, priority = 0, flag = forceTab, stack = forceStackSize, itemQuality = Sort.itemLocation[startPos].itemQuality, itemName = Sort.itemLocation[startPos].itemName, blacklist = Sort.itemLocation[startPos].blacklist, forced = true})
                                        forceCounter[Sort.itemLocation[startPos].itemID] = forceCounter[Sort.itemLocation[startPos].itemID] + 1
                                    end
                                    foundItem = true
                                    break
                                end
                            end
                            if not foundItem then
                                tinsert(movesToMake, {tab = Sort.itemLocation[startPos].tab, slot = Sort.itemLocation[startPos].slot, amount = forceStackSize})
                                tinsert(movesToMake, {tab = forceTab, slot = slot})
                                Sort.itemLocation[startPos].itemCount = Sort.itemLocation[startPos].itemCount - forceStackSize
                                tinsert(Sort.itemLocation, {tab = forceTab, slot = slot, itemID = Sort.itemLocation[startPos].itemID, itemCount = forceStackSize, priority = 0, flag = forceTab, stack = forceStackSize, itemQuality = Sort.itemLocation[startPos].itemQuality, itemName = Sort.itemLocation[startPos].itemName, blacklist = Sort.itemLocation[startPos].blacklist, forced = true})
                                forceCounter[Sort.itemLocation[startPos].itemID] = forceCounter[Sort.itemLocation[startPos].itemID] + 1
                            end
                        end
                    end
                    if Sort.itemLocation[startPos].itemCount == 0 or Sort.itemLocation[startPos].forced or (forceCounter[Sort.itemLocation[startPos].itemID] and forceCounter[Sort.itemLocation[startPos].itemID] == forceStacks) then
                        break
                    end
                end
            end
        end
    end
    for startPos = #Sort.itemLocation, 1, -1 do
        if Sort.itemLocation[startPos].itemCount == 0 then
            tremove(Sort.itemLocation, startPos)
        end
    end
end

local function stackItems()
    for startPos = 1, #Sort.itemLocation - 1 do
        if Sort.itemLocation[startPos].itemCount ~= 0 and Sort.itemLocation[startPos].itemCount < Sort.itemLocation[startPos].stack and Sort.itemLocation[startPos].itemCount < totalItemCount[Sort.itemLocation[startPos].itemID] and Sort.itemLocation[startPos].blacklist == "whitelist" and not Sort.itemLocation[startPos].forced then
            for newPos = startPos + 1, #Sort.itemLocation do
                if Sort.itemLocation[newPos].itemID == Sort.itemLocation[startPos].itemID and Sort.itemLocation[newPos].itemCount ~= 0 and Sort.itemLocation[newPos].itemCount ~= Sort.itemLocation[newPos].stack and not Sort.itemLocation[newPos].forced then
                    if Sort.itemLocation[startPos].itemCount >= Sort.itemLocation[newPos].itemCount then
                        if Sort.itemLocation[newPos].stack and Sort.itemLocation[newPos].itemCount > Sort.itemLocation[newPos].stack - Sort.itemLocation[startPos].itemCount then
                            tinsert(movesToMake, {tab = Sort.itemLocation[newPos].tab, slot = Sort.itemLocation[newPos].slot, amount = Sort.itemLocation[newPos].stack - Sort.itemLocation[startPos].itemCount})
                        else
                            tinsert(movesToMake, {tab = Sort.itemLocation[newPos].tab, slot = Sort.itemLocation[newPos].slot})
                        end

                        tinsert(movesToMake, {tab = Sort.itemLocation[startPos].tab, slot = Sort.itemLocation[startPos].slot})
            
                        Sort.itemLocation[startPos].itemCount = Sort.itemLocation[startPos].itemCount + Sort.itemLocation[newPos].itemCount
                        if Sort.itemLocation[startPos].itemCount >= Sort.itemLocation[startPos].stack then
                            Sort.itemLocation[newPos].itemCount = Sort.itemLocation[startPos].itemCount - Sort.itemLocation[startPos].stack
                            Sort.itemLocation[startPos].itemCount = Sort.itemLocation[startPos].stack
                            break
                        else
                            Sort.itemLocation[newPos].itemCount = 0
                        end
                    elseif Sort.itemLocation[startPos].itemCount < Sort.itemLocation[newPos].itemCount then
                        if Sort.itemLocation[startPos].stack and Sort.itemLocation[startPos].itemCount > Sort.itemLocation[startPos].stack - Sort.itemLocation[newPos].itemCount then
                            tinsert(movesToMake, {tab = Sort.itemLocation[startPos].tab, slot = Sort.itemLocation[startPos].slot, amount = Sort.itemLocation[startPos].stack - Sort.itemLocation[newPos].itemCount})
                        else
                            tinsert(movesToMake, {tab = Sort.itemLocation[startPos].tab, slot = Sort.itemLocation[startPos].slot})
                        end

                        tinsert(movesToMake, {tab = Sort.itemLocation[newPos].tab, slot = Sort.itemLocation[newPos].slot})
            
                        Sort.itemLocation[newPos].itemCount = Sort.itemLocation[startPos].itemCount + Sort.itemLocation[newPos].itemCount
                        if Sort.itemLocation[newPos].itemCount >= Sort.itemLocation[newPos].stack then
                            Sort.itemLocation[startPos].itemCount = Sort.itemLocation[newPos].itemCount - Sort.itemLocation[newPos].stack
                            Sort.itemLocation[newPos].itemCount = Sort.itemLocation[newPos].stack
                        else
                            Sort.itemLocation[startPos].itemCount = 0
                            break
                        end
                    end
                end
            end
        end
    end
    for startPos = #Sort.itemLocation, 1, -1 do
        if Sort.itemLocation[startPos].itemCount == 0 then
            tremove(Sort.itemLocation, startPos)
        end
    end
end

local function splitItems()
    local finishStack = nil
    for startPos = 1, #Sort.itemLocation do
        if Sort.itemLocation[startPos].stack and Sort.itemLocation[startPos].itemCount > Sort.itemLocation[startPos].stack and Sort.itemLocation[startPos].blacklist == "whitelist" and not Sort.itemLocation[startPos].forced then
            for tab = 1, GetNumGuildBankTabs() do
                if not finishStack or tab == finishStack then
                    finishStack = nil
                    for slot = 1, 98 do
                        local spaceTaken = false
                        local itemPlace = nil
                        for nextItem = 1, #Sort.itemLocation do
                            if Sort.itemLocation[nextItem].tab == tab and Sort.itemLocation[nextItem].slot == slot then
                                if Sort.itemLocation[startPos].itemID == Sort.itemLocation[nextItem].itemID and Sort.itemLocation[nextItem].stack and Sort.itemLocation[nextItem].itemCount < Sort.itemLocation[nextItem].stack and not Sort.itemLocation[nextItem].forced then
                                    itemPlace = nextItem
                                else
                                    spaceTaken = true
                                end
                                break
                            end
                        end
                        if not spaceTaken then
                            local carryOver = nil
                            if itemPlace then
                                carryOver = Sort.itemLocation[itemPlace].stack - Sort.itemLocation[itemPlace].itemCount
                                Sort.itemLocation[itemPlace].itemCount = Sort.itemLocation[itemPlace].stack
                            else
                                tinsert(Sort.itemLocation, {tab = tab, slot = slot, itemID = Sort.itemLocation[startPos].itemID, itemCount = Sort.itemLocation[startPos].stack, priority = Sort.itemLocation[startPos].priority, flag = Sort.itemLocation[startPos].flag, stack = Sort.itemLocation[startPos].stack, itemQuality = Sort.itemLocation[startPos].itemQuality, itemName = Sort.itemLocation[startPos].itemName, blacklist = Sort.itemLocation[startPos].blacklist, forced = false})
                            end
                            
                            tinsert(movesToMake, {tab = Sort.itemLocation[startPos].tab, slot = Sort.itemLocation[startPos].slot, amount = carryOver or Sort.itemLocation[startPos].stack})
                            tinsert(movesToMake, {tab = tab, slot = slot})
                            Sort.itemLocation[startPos].itemCount = Sort.itemLocation[startPos].itemCount - (carryOver or Sort.itemLocation[startPos].stack)
                            if Sort.itemLocation[startPos].itemCount == Sort.itemLocation[startPos].stack then
                                break
                            elseif Sort.itemLocation[startPos].itemCount < Sort.itemLocation[startPos].stack then
                                finishStack = Sort.itemLocation[startPos].tab
                                break
                            end
                        end
                    end
                end
                if Sort.itemLocation[startPos].itemCount <= Sort.itemLocation[startPos].stack then
                    break
                end
            end
        end
    end
end

--- Start sorting the items
---@param startingTab integer
---@param onlyCurrentTab boolean
local function sortItems(startingTab, onlyCurrentTab, profile)  
    table.sort(Sort.itemLocation, function(a,b)
        if a.flag ~= b.flag then
            return a.flag < b.flag
        end
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        if a.itemQuality ~= b.itemQuality then
            return a.itemQuality > b.itemQuality
        end
        if a.itemName ~= b.itemName then
            return a.itemName < b.itemName
        end
        if a.itemID ~= b.itemID then
            return a.itemID > b.itemID
        end
        return a.itemCount > b.itemCount
    end)
    local tab = startingTab
    local tabSlots = {}
    for index = 1, GetNumGuildBankTabs() do
        tabSlots[index] = 1
        itemsFlagged[index] = 0
    end
    for currentItem = 1, #Sort.itemLocation do
        if Sort.itemLocation[currentItem].blacklist == "whitelist" then
            if itemsFlagged[Sort.itemLocation[currentItem].flag] == 98 then
                Sort.itemLocation[currentItem].flag = 9
            end
            if Sort.itemLocation[currentItem].flag ~= 9 then
            itemsFlagged[Sort.itemLocation[currentItem].flag] = itemsFlagged[Sort.itemLocation[currentItem].flag] + 1
            end
            if Sort.itemLocation[currentItem].flag ~= tab and Sort.itemLocation[currentItem].flag ~= 9 then
                tab = Sort.itemLocation[currentItem].flag
            elseif Sort.itemLocation[currentItem].flag == 9 then
                tab = startingTab
                while tabSlots[tab] == 99 do
                    tab = tab + 1
                end
            end

            if onlyCurrentTab and Sort.itemLocation[currentItem].flag ~= startingTab and Sort.itemLocation[currentItem].flag ~= 9 then
                for slot = 1, 98 do
                    local itemFound = false
                    for nextItem = 1, #Sort.itemLocation do
                        if Sort.itemLocation[nextItem].tab == tab and Sort.itemLocation[nextItem].slot == slot then
                            itemFound = true
                            break
                        end
                    end
                    if not itemFound then
                        tabSlots[tab] = slot
                        break
                    elseif slot == 98 then
                        tab = startingTab
                    end
                end
            end

            local itemID = nil
            local itemCount = 0
            local itemPlace = nil
            local isBlacklisted = false

            while true do
                isBlacklisted = false
                for nextItem = 1, #Sort.itemLocation do
                    if Sort.itemLocation[nextItem].tab == tab and Sort.itemLocation[nextItem].slot == tabSlots[tab] then
                        if Sort.itemLocation[nextItem].blacklist == "blacklist" and ((onlyCurrentTab and Sort.itemLocation[nextItem].tab ~= tab) or (profile and profile.options and profile.options.keepBlacklisted)) then                            isBlacklisted = true
                        else
                            itemID = Sort.itemLocation[nextItem].itemID
                            itemCount = Sort.itemLocation[nextItem].itemCount
                            itemPlace = nextItem
                        end
                        break
                    end
                end
                if not isBlacklisted then
                    break
                end
                tabSlots[tab] = tabSlots[tab] + 1
                if tabSlots[tab] == 99 then
                    tab = tab + 1
                end
            end
            
            if not itemID then
                tinsert(movesToMake, {tab = Sort.itemLocation[currentItem].tab, slot = Sort.itemLocation[currentItem].slot})
                tinsert(movesToMake, {tab = tab, slot = tabSlots[tab]})
                Sort.itemLocation[currentItem].tab = tab
                Sort.itemLocation[currentItem].slot = tabSlots[tab]
            
            elseif Sort.itemLocation[currentItem].itemID ~= itemID and (Sort.itemLocation[currentItem].tab ~= tab or Sort.itemLocation[currentItem].slot ~= tabSlots[tab]) then
                tinsert(movesToMake, {tab = Sort.itemLocation[currentItem].tab, slot = Sort.itemLocation[currentItem].slot})
                tinsert(movesToMake, {tab = tab, slot = tabSlots[tab]})
                Sort.itemLocation[itemPlace].tab = Sort.itemLocation[currentItem].tab
                Sort.itemLocation[itemPlace].slot = Sort.itemLocation[currentItem].slot
                Sort.itemLocation[currentItem].tab = tab
                Sort.itemLocation[currentItem].slot = tabSlots[tab]

            elseif Sort.itemLocation[currentItem].itemID == itemID and (Sort.itemLocation[currentItem].tab ~= tab or Sort.itemLocation[currentItem].slot ~= tabSlots[tab]) then
                local spaceTaken = false
                if not Sort.itemLocation[itemPlace].forced and Sort.itemLocation[currentItem].forced then
                    for newTab = startingTab, GetNumGuildBankTabs() do
                        for newSlot = 1, 98 do
                            spaceTaken = false
                            for nextItem = 1, #Sort.itemLocation do
                                if Sort.itemLocation[nextItem].tab == newTab and Sort.itemLocation[nextItem].slot == newSlot then
                                    spaceTaken = true
                                    break
                                end
                            end
                            if not spaceTaken then
                                tinsert(movesToMake, {tab = tab, slot = tabSlots[tab]})
                                tinsert(movesToMake, {tab = newTab, slot = newSlot})
                                
                                tinsert(movesToMake, {tab = Sort.itemLocation[currentItem].tab, slot = Sort.itemLocation[currentItem].slot})
                                tinsert(movesToMake, {tab = tab, slot = tabSlots[tab]})
                                
                                Sort.itemLocation[currentItem].tab = newTab
                                Sort.itemLocation[currentItem].slot = newSlot
                                break
                            end
                        end
                        if not spaceTaken then
                            break
                        end
                    end
                elseif Sort.itemLocation[itemPlace].itemCount < Sort.itemLocation[currentItem].itemCount then
                    if Sort.itemLocation[itemPlace].stack then
                        for newTab = startingTab, GetNumGuildBankTabs() do
                            for newSlot = 1, 98 do
                                spaceTaken = false
                                for nextItem = 1, #Sort.itemLocation do
                                    if Sort.itemLocation[nextItem].tab == newTab and Sort.itemLocation[nextItem].slot == newSlot then
                                        spaceTaken = true
                                        break
                                    end
                                end
                                if not spaceTaken then
                                    tinsert(movesToMake, {tab = tab, slot = tabSlots[tab]})
                                    tinsert(movesToMake, {tab = newTab, slot = newSlot})

                                    tinsert(movesToMake, {tab = Sort.itemLocation[currentItem].tab, slot = Sort.itemLocation[currentItem].slot})
                                    tinsert(movesToMake, {tab = tab, slot = tabSlots[tab]})
                                    
                                    Sort.itemLocation[currentItem].tab = newTab
                                    Sort.itemLocation[currentItem].slot = newSlot
                                    break
                                end
                            end
                            if not spaceTaken then
                                break
                            end
                        end
                    else
                        tinsert(movesToMake, {tab = Sort.itemLocation[currentItem].tab, slot = Sort.itemLocation[currentItem].slot})
                        tinsert(movesToMake, {tab = tab, slot = tabSlots[tab]})
                    end
                end
                Sort.itemLocation[itemPlace].tab = Sort.itemLocation[currentItem].tab
                Sort.itemLocation[itemPlace].slot = Sort.itemLocation[currentItem].slot
                Sort.itemLocation[currentItem].tab = tab
                Sort.itemLocation[currentItem].slot = tabSlots[tab]
            end
            
            tabSlots[tab] = tabSlots[tab] + 1
            if tabSlots[tab] == 99 then
                tab = tab + 1
            end
        end
    end
    
end

function Sort:startSorting()
    startMoving = C_Timer.NewTicker(1, function()
        if movesToMake[1] and movesToMake[1].amount then
            SplitGuildBankItem(movesToMake[1].tab, movesToMake[1].slot, movesToMake[1].amount)
        elseif movesToMake[1] then
            PickupGuildBankItem(movesToMake[1].tab, movesToMake[1].slot)
        end
        local firstTab = movesToMake[1] and movesToMake[1].tab
        tremove(movesToMake, 1)

        local secondTab = movesToMake[1] and movesToMake[1].tab
        if movesToMake[1] then
            PickupGuildBankItem(movesToMake[1].tab, movesToMake[1].slot)
        end
        tremove(movesToMake, 1)

        if firstTab then QueryGuildBankTab(firstTab) end
        if secondTab then
            C_Timer.After(0.5, function()
                QueryGuildBankTab(secondTab)
            end)
        end

        if #movesToMake == 0 then
            print("|cff77DD77DUI_GuildBankSort:|r Finished sorting")
            isSorting = false
            startMoving:Cancel()
        elseif movesLeftAnnouncer[#movesToMake/2] and core and core.DB then
            local profile = core.DB.profiles[core.DB.currentProfile[core:getPlayerName()]]
            if profile and profile.options and profile.options.printStepsLeft then
                print("|cff77DD77DUI_GuildBankSort:|r " .. movesLeftAnnouncer[#movesToMake/2])
            end
        end 
    end)
end

function Sort:stopSorting()
    if startMoving and not startMoving:IsCancelled() then
        startMoving:Cancel()
        print("|cff77DD77DUI_GuildBankSort:|r Stopped sorting")
        isSorting = false
        if core and core.Config and core.Config.Preview then core.Config.Preview.hidePreview() end
    end
    if isSorting then
        print("|cff77DD77DUI_GuildBankSort:|r Stopped sorting")
        isSorting = false
        if core and core.Config and core.Config.Preview then core.Config.Preview.hidePreview() end
    end
end
-- DanUI guild bank sort config UI and rule handling
local db
local ignoreCheckboxes = {}
local ruleRows = {}

-- Forward declarations: these are defined further down but referenced by handlers
-- created earlier in the file (the add-rule button, the GET_ITEM_INFO_RECEIVED
-- listener). Without these the earlier references compile as globals and are nil.
local RefreshGuildBankSortRules
local RefreshGuildBankSortUI
local ForceRefreshGuildBankSortRules

local function GetGuildBankSortDefaults()
    return {
        enabled = true,
        rules = {},
        ignoreTabs = {},
        overflowTab = 1,
    }
end

local function EnsureGuildBankSortDB()
    if not DanUIDB then DanUIDB = {} end
    if not DanUIDB.GuildBankSort then DanUIDB.GuildBankSort = GetGuildBankSortDefaults() end
    db = DanUIDB.GuildBankSort
    db.rules = db.rules or {}
    db.ignoreTabs = db.ignoreTabs or {}
    db.overflowTab = db.overflowTab or 1
end

local function AddOrUpdateRule(itemID, stackSize, stacks, tab)
    EnsureGuildBankSortDB()
    if not itemID or itemID < 1 or not stackSize or stackSize < 1 or not stacks or stacks < 1 or not tab or tab < 1 then
        return
    end
    for _,rule in ipairs(db.rules) do
        if rule.itemID == itemID then
            rule.stackSize = stackSize
            rule.stacks = stacks
            rule.tab = tab
            return
        end
    end
    tinsert(db.rules, { itemID = itemID, stackSize = stackSize, stacks = stacks, tab = tab })
end

local function RemoveRule(itemID)
    for i,rule in ipairs(db.rules) do
        if rule.itemID == itemID then
            tremove(db.rules, i)
            return
        end
    end
end

local function ApplyGuildBankSortRules(profile)
    if not db then EnsureGuildBankSortDB() end
    if not profile.options then profile.options = {} end
    profile.options.ignoreTab = {}
    for tab,enabled in pairs(db.ignoreTabs) do
        if enabled then
            profile.options.ignoreTab[tostring(tab)] = true
        end
    end
    profile.options.overflowTab = db.overflowTab or profile.options.overflowTab
    profile.forcedFlag = {}
    for _,rule in ipairs(db.rules) do
        profile.forcedFlag[rule.itemID] = {
            stackSize = rule.stackSize,
            stack = rule.stacks,
            tab = rule.tab,
        }
    end
end

local function ApplyOverflowTargets()
    if not db or not db.rules then return end
    local ruleMap = {}
    for _,rule in ipairs(db.rules) do
        ruleMap[rule.itemID] = rule
    end
    for _,entry in ipairs(Sort.itemLocation) do
        if not entry.forced then
            local rule = ruleMap[entry.itemID]
            if rule and db.overflowTab and db.overflowTab > 0 then
                local forcedCapacity = rule.stackSize * rule.stacks
                if forcedCapacity > 0 and totalItemCount[entry.itemID] > forcedCapacity then
                    entry.flag = db.overflowTab
                    entry.priority = 0
                end
            end
        end
    end
end
-- Exported for Guild Bank Restock, which refuses to start mid-sort. The
-- guard runs both ways (see RestockBusy below): both features drive the cursor a
-- move at a time, and interleaving them drops items back into the bank at random.
function DUI_GuildBankSortIsBusy() return isSorting end

-- Apply hook for the main window's rail. The Sort button already refuses while the
-- row is off; this stops a sort that was already moving items when it was unticked.
function DUI_GuildBankSortApplyEnabled(enabled)
    if not enabled and isSorting then Sort:stopSorting() end
end

local function RestockBusy()
    if DUI_GuildBankRestockIsBusy and DUI_GuildBankRestockIsBusy() then
        print("|cff77DD77DUI_GuildBankSort:|r Restock is still running - try again when it finishes")
        return true
    end
    return false
end

-- Helper to fetch legacy profile or create a safe fallback
local function GetActiveProfile()
    local profile = nil
    if core and core.DB and core.DB.profiles and core.DB.currentProfile and core.getPlayerName then
        local playerName = core:getPlayerName()
        if playerName and core.DB.currentProfile[playerName] then
            profile = core.DB.profiles[core.DB.currentProfile[playerName]]
        end
    end
    
    if not profile then
        profile = {
            options = { stackItems = true, updateItems = true, keepBlacklisted = false },
            priority = {}, flag = {}, stack = {}, whitelist = {}, blacklist = {}, forcedFlag = {}
        }
    end
    return profile
end

local function sortAll(profile)
    if not IsGuildBankOpen() then print("|cff77DD77DUI_GuildBankSort:|r Guild bank is not open"); return end
    if startMoving and not startMoving:IsCancelled() then startMoving:Cancel(); isSorting = false; if core.Config and core.Config.Preview then core.Config.Preview.hidePreview() end; return end
    if isSorting then isSorting = false; if core.Config and core.Config.Preview then core.Config.Preview.hidePreview() end; return end

    Sort.itemLocation = {}
    totalItemCount = {}
    movesToMake = {}
    isSorting = true
    
    if not profile then isSorting = false; return end
    
    ApplyGuildBankSortRules(profile)
    if profile.options and profile.options.updateItems then updateGuildBankItems() end
    if not isSorting then return end
    fetchAllItems(profile)
    forceItems(profile)
    if profile.options and profile.options.stackItems then splitItems(); stackItems() end
    ApplyOverflowTargets()
    sortItems(1, false, profile)

    if #movesToMake == 0 then print("|cff77DD77DUI_GuildBankSort:|r No moves to make"); isSorting = false
    elseif profile.options.showPreview and core.Config and core.Config.Preview then print("|cff77DD77DUI_GuildBankSort:|r Moves to make: " .. #movesToMake/2); core.Config.Preview.showPreview()
    else print("|cff77DD77DUI_GuildBankSort:|r Moves to make: " .. #movesToMake/2); Sort:startSorting() end
end

function Sort:sortAllTabs()
    if RestockBusy() then return end
    StartCoroutine(sortAll, GetActiveProfile())
end

local function sortCurrent(profile)
    if not IsGuildBankOpen() then print("|cff77DD77DUI_GuildBankSort:|r Guild bank is not open"); return end
    if startMoving and not startMoving:IsCancelled() then startMoving:Cancel(); isSorting = false; if core.Config and core.Config.Preview then core.Config.Preview.hidePreview() end; return end
    if isSorting then isSorting = false; if core.Config and core.Config.Preview then core.Config.Preview.hidePreview() end; return end

    Sort.itemLocation = {}
    totalItemCount = {}
    movesToMake = {}
    isSorting = true
    
    if not profile then isSorting = false; return end
    
    ApplyGuildBankSortRules(profile)
    if profile.options and profile.options.updateItems then updateGuildBankItems() end
    if not isSorting then return end
    fetchCurrentTabItems(profile)
    forceItems(profile)
    if profile.options and profile.options.stackItems then splitItems(); stackItems() end
    ApplyOverflowTargets()
    sortItems(GetCurrentGuildBankTab(), true, profile)
    
    if #movesToMake == 0 then print("|cff77DD77DUI_GuildBankSort:|r No moves to make"); isSorting = false
    elseif profile.options.showPreview and core.Config and core.Config.Preview then print("|cff77DD77DUI_GuildBankSort:|r Moves to make: " .. #movesToMake/2); core.Config.Preview.showPreview()
    else print("|cff77DD77DUI_GuildBankSort:|r Moves to make: " .. #movesToMake/2); Sort:startSorting() end
end

function Sort:sortCurrentTab()
    if RestockBusy() then return end
    StartCoroutine(sortCurrent, GetActiveProfile())
end

local function sortStacks(profile)
    if not IsGuildBankOpen() then print("|cff77DD77DUI_GuildBankSort:|r Guild bank is not open"); return end
    if startMoving and not startMoving:IsCancelled() then startMoving:Cancel(); isSorting = false; if core.Config and core.Config.Preview then core.Config.Preview.hidePreview() end; return end
    if isSorting then isSorting = false; if core.Config and core.Config.Preview then core.Config.Preview.hidePreview() end; return end

    Sort.itemLocation = {}
    totalItemCount = {}
    movesToMake = {}
    isSorting = true
    
    if not profile then isSorting = false; return end
    
    if profile.options and profile.options.updateItems then updateGuildBankItems() end
    fetchAllItems(profile)
    splitItems()
    stackItems()
    
    if #movesToMake == 0 then print("|cff77DD77DUI_GuildBankSort:|r No moves to make"); isSorting = false
    elseif profile.options.showPreview and core.Config and core.Config.Preview then print("|cff77DD77DUI_GuildBankSort:|r Moves to make: " .. #movesToMake/2); core.Config.Preview.showPreview()
    else print("|cff77DD77DUI_GuildBankSort:|r Moves to make: " .. #movesToMake/2); Sort:startSorting() end
end

function Sort:sortStacks()
    if RestockBusy() then return end
    StartCoroutine(sortStacks, GetActiveProfile())
end



local selectedRuleTab = 1
local function TruncateText(text, maxLength)
    if not text then return "" end
    if #text <= maxLength then return text end
    return string.sub(text, 1, maxLength - 3) .. "..."
end

local function GetGuildBankTabName(tab)
    local name = select(1, GetGuildBankTabInfo(tab))
    return (name and name ~= "" and name) or "Tab " .. tab
end

local function GetGuildBankTabItems()
    local items = {}
    local numTabs = GetNumGuildBankTabs()
    if numTabs == 0 then
        for tab = 1, 8 do
            tinsert(items, { value = tab, text = "Tab " .. tab })
        end
        return items
    end
    for tab = 1, numTabs do
        tinsert(items, { value = tab, text = GetGuildBankTabName(tab) })
    end
    return items
end

local function ShowScrollDropdown(anchor, items, callback, defaultText)
    if DUI_ShowScrollDropdown then
        DUI_ShowScrollDropdown(anchor, items, callback, defaultText)
        return
    end
    local menuFrame = _G["DUI_GuildBankSort_ScrollMenuFrame"] or CreateFrame("Frame", "DUI_GuildBankSort_ScrollMenuFrame", UIParent, "UIDropDownMenuTemplate")
    if EasyMenu then
        EasyMenu(items, menuFrame, anchor, 0, 0, "MENU")
    end
end

-- Standard DUI chrome (backdrop, close button, title bar, drop shadow, main-window
-- anchoring, button highlight, Esc-to-close, accent + config-registry membership).
-- The item-info listener and refresh-on-show behaviour is added as an extra HookScript
-- further down, after those upvalues are defined.
local config = DUI_CreateConfigFrame("DUI_GuildBankSortConfig", "Guild Bank Sort", 520, 400, "DUI_GuildBankSortBtn_Tools")

-- This panel was authored at fixed offsets (-40, -100, -150, -180, -240, -265),
-- which is why "Add / Update Rule" and the "Rules" header sat on top of each other:
-- the button ran to -252 and the header was placed at -240. The layout cursor owns
-- the vertical rhythm now, so the panel matches every other module's and cannot
-- collide with itself again. Rows built out of several widgets anchored to each
-- other keep those chains -- only the row's own starting Y comes from the cursor.
local L = DUI_CreateLayout(config)

L:Text("Use rules to force item stacks into tabs, ignore tabs, and send overflow to a spare tab.")

L:Header("Tabs")
-- A dropdown is anchored to its label's LEFT, so it straddles the label's centre
-- line: the label starts 7px below the cursor to put the whole row inside the card.
local ignoreLabel = config:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
ignoreLabel:SetPoint("TOPLEFT", DUI_LAYOUT.INDENT, L:Y() - 7)
ignoreLabel:SetText("Ignore:")
ignoreLabel:SetTextColor(1, 1, 1)
local ignoreButton = DUI_CreateDropdown(config, nil, {
    name = "DUI_GuildBankSortIgnoreBtn", width = 128, height = 26, justify = "LEFT",
    tooltip = { body = "Tabs the sorter leaves completely alone.",
                note = "Tick as many as you like; ticked tabs show red in the list." },
})
ignoreButton:SetPoint("LEFT", ignoreLabel, "RIGHT", 6, 0)
local ignoreButtonText = ignoreButton.value
local function GetIgnoreTabsText()
    if not db or not db.ignoreTabs then return "None" end
    local names = {}
    for tab = 1, GetNumGuildBankTabs() do
        if db.ignoreTabs[tostring(tab)] then
            tinsert(names, GetGuildBankTabName(tab))
        end
    end
    if #names == 0 then
        return "None"
    elseif #names == 1 then
        return names[1]
    elseif #names == 2 then
        return names[1] .. ", " .. names[2]
    else
        return tostring(#names) .. " tabs"
    end
end

local function ShowIgnoreTabsDropdown(anchor)
    EnsureGuildBankSortDB()
    local items = GetGuildBankTabItems()
    for _, it in ipairs(items) do
        if db.ignoreTabs[tostring(it.value)] then
            it.color = {1, 0, 0}
        end
    end
    ShowScrollDropdown(anchor, items, function(value, text)
        db.ignoreTabs[tostring(value)] = not db.ignoreTabs[tostring(value)]
        ignoreButtonText:SetText(GetIgnoreTabsText())
    end, GetIgnoreTabsText())
end
ignoreButton:SetScript("OnClick", function(self) ShowIgnoreTabsDropdown(self) end)
ignoreCheckboxes = nil

local overflowLabel = config:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
overflowLabel:SetPoint("LEFT", ignoreButton, "RIGHT", 12, 0)
overflowLabel:SetText("Overflow:")
overflowLabel:SetTextColor(1, 1, 1)
local overflowButton = DUI_CreateDropdown(config, nil, {
    name = "DUI_GuildBankSortOverflowBtn", width = 110, height = 26, justify = "LEFT",
    tooltip = "Tab that receives items when their intended tab is full.",
})
overflowButton:SetPoint("LEFT", overflowLabel, "RIGHT", 6, 0)
local overflowButtonText = overflowButton.value
local function ShowOverflowDropdown(anchor)
    local items = GetGuildBankTabItems()
    ShowScrollDropdown(anchor, items, function(value, text)
        db.overflowTab = value
        overflowButtonText:SetText(text)
    end, GetGuildBankTabName(db.overflowTab or 1))
end
overflowButton:SetScript("OnClick", function(self) ShowOverflowDropdown(self) end)
L:Advance(32)

L:Header("Item Rules")
local itemIDLabel = config:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
itemIDLabel:SetPoint("TOPLEFT", DUI_LAYOUT.INDENT, L:Y() - 7)
itemIDLabel:SetText("Item ID:")
local itemIDInput = CreateFrame("EditBox", "DUI_GuildBankSortItemIDInput", config, "BackdropTemplate")
itemIDInput:SetSize(60, 25)
itemIDInput:SetPoint("LEFT", itemIDLabel, "RIGHT", 8, 0)
itemIDInput:SetAutoFocus(false)
itemIDInput:SetNumeric(true)
itemIDInput:SetFontObject(DUI_FontNormal)
itemIDInput:SetBackdrop(DUI_EditBackdrop)
itemIDInput:SetBackdropColor(0, 0, 0, 0.5)
itemIDInput:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
DUI_RegisterAccent(itemIDInput, "border")
itemIDInput:SetTextInsets(5, 5, 0, 0)
itemIDInput:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(1, 1, 0, 1) end)
itemIDInput:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(unpack(DUI_Theme.Accent)) end)
itemIDInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
itemIDInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local stackSizeLabel = config:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
stackSizeLabel:SetPoint("LEFT", itemIDInput, "RIGHT", 8, 0)
stackSizeLabel:SetText("Stack Size:")
local stackSizeInput = CreateFrame("EditBox", "DUI_GuildBankSortStackSizeInput", config, "BackdropTemplate")
stackSizeInput:SetSize(40, 25)
stackSizeInput:SetPoint("LEFT", stackSizeLabel, "RIGHT", 8, 0)
stackSizeInput:SetAutoFocus(false)
stackSizeInput:SetNumeric(true)
stackSizeInput:SetFontObject(DUI_FontNormal)
stackSizeInput:SetBackdrop(DUI_EditBackdrop)
stackSizeInput:SetBackdropColor(0, 0, 0, 0.5)
stackSizeInput:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
DUI_RegisterAccent(stackSizeInput, "border")
stackSizeInput:SetTextInsets(5, 5, 0, 0)
stackSizeInput:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(1, 1, 0, 1) end)
stackSizeInput:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(unpack(DUI_Theme.Accent)) end)
stackSizeInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
stackSizeInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local stacksLabel = config:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
stacksLabel:SetPoint("LEFT", stackSizeInput, "RIGHT", 8, 0)
stacksLabel:SetText("Stacks:")
local stacksInput = CreateFrame("EditBox", "DUI_GuildBankSortStacksInput", config, "BackdropTemplate")
stacksInput:SetSize(40, 25)
stacksInput:SetPoint("LEFT", stacksLabel, "RIGHT", 8, 0)
stacksInput:SetAutoFocus(false)
stacksInput:SetNumeric(true)
stacksInput:SetFontObject(DUI_FontNormal)
stacksInput:SetBackdrop(DUI_EditBackdrop)
stacksInput:SetBackdropColor(0, 0, 0, 0.5)
stacksInput:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
DUI_RegisterAccent(stacksInput, "border")
stacksInput:SetTextInsets(5, 5, 0, 0)
stacksInput:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(1, 1, 0, 1) end)
stacksInput:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(unpack(DUI_Theme.Accent)) end)
stacksInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
stacksInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local tabLabel = config:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
tabLabel:SetPoint("LEFT", stacksInput, "RIGHT", 6, 0)
tabLabel:SetText("Tab:")
local tabButton = CreateFrame("Button", "DUI_GuildBankSortTabButton", config, "BackdropTemplate")
    tabButton:SetSize(100, 25)
tabButton:SetPoint("LEFT", tabLabel, "RIGHT", 8, 0)
tabButton:SetBackdrop(DUI_EditBackdrop)
tabButton:SetBackdropColor(0, 0, 0, 0.5)
tabButton:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
DUI_RegisterAccent(tabButton, "border")
local tabButtonText = tabButton:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
    tabButtonText:SetPoint("LEFT", tabButton, "LEFT", 6, 0)
    tabButtonText:SetPoint("RIGHT", tabButton, "RIGHT", -6, 0)
    tabButtonText:SetHeight(20)
    tabButtonText:SetJustifyH("LEFT")
    tabButtonText:SetWordWrap(false)
    tabButtonText:SetText(TruncateText(GetGuildBankTabName(selectedRuleTab), 14))

local function UpdateRuleTabDropdown()
    tabButtonText:SetText(TruncateText(GetGuildBankTabName(selectedRuleTab), 14))
end

local function ShowGuildBankTabDropdown(anchor)
    local items = GetGuildBankTabItems()
    ShowScrollDropdown(anchor, items, function(value, text)
        selectedRuleTab = value
        tabButtonText:SetText(TruncateText(text, 14))
    end, GetGuildBankTabName(selectedRuleTab))
end

tabButton:SetScript("OnClick", function(self)
    ShowGuildBankTabDropdown(self)
end)

L:Advance(32)

local addRuleBtn = CreateFrame("Button", "DUI_GuildBankSortAddRuleBtn", config, "BackdropTemplate")
addRuleBtn:SetSize(140, 25)
addRuleBtn:SetPoint("TOPLEFT", DUI_LAYOUT.INDENT, L:Y())
addRuleBtn:SetText("Add / Update Rule")
StyleAsTealTab(addRuleBtn)
addRuleBtn:SetScript("OnClick", function()
    local itemID = tonumber(itemIDInput:GetText())
    local stackSize = tonumber(stackSizeInput:GetText())
    local stacks = tonumber(stacksInput:GetText())
    local tab = selectedRuleTab
    if not itemID or not stackSize or not stacks or not tab then
        print("|cFF00FF00[DUI]|r Invalid rule values.")
        return
    end
    EnsureGuildBankSortDB()
    AddOrUpdateRule(itemID, stackSize, stacks, tab)
    print(string.format("|cff77DD77DUI_GuildBankSort:|r added/updated rule for ID %d → %d stacks of %d in tab %d", itemID, stacks, stackSize, tab))
    -- Inline immediate UI rebuild for rules (avoid relying on other functions)
    EnsureGuildBankSortDB()
    db.rules = db.rules or {}
    -- If the scroll child isn't created yet (UI still building), schedule a retry
    if not rulesContent or type(rulesContent.SetHeight) ~= "function" then
        C_Timer.After(0.05, function()
            if type(ForceRefreshGuildBankSortRules) == "function" then
                pcall(ForceRefreshGuildBankSortRules)
            elseif type(RefreshGuildBankSortRules) == "function" then
                pcall(RefreshGuildBankSortRules)
            end
        end)
        return
    end
    for _,row in ipairs(ruleRows) do if row.frame then row.frame:Hide() end end
    local offset = -10
    for i, rule in ipairs(db.rules) do
        if not ruleRows[i] then
            local row = {}
            row.frame = CreateFrame("Frame", nil, rulesContent)
            -- Rows are anchored 10px in from the scroll child's left edge (see the
            -- SetPoint further down), so the row only gets the viewport width less
            -- that inset. At the old full viewport width the row overhung the
            -- scroll frame's right edge and the remove button, being right-anchored,
            -- was the part that got clipped away.
            row.frame:SetSize(config:GetWidth() - 75, 20)
            row.itemLabel = row.frame:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
            row.itemLabel:SetPoint("LEFT", row.frame, "LEFT", 4, 0)
            row.itemLabel:SetJustifyH("LEFT")
            row.itemLabel:SetWordWrap(false)
            row.removeBtn = CreateFrame("Button", nil, row.frame, "BackdropTemplate")
            row.removeBtn:SetSize(20, 20)
            row.removeBtn:SetPoint("RIGHT", row.frame, "RIGHT", -4, 0)
            -- Anchored to the button rather than given a fixed width, so a long
            -- item link is truncated at the button instead of running under it.
            row.itemLabel:SetPoint("RIGHT", row.removeBtn, "LEFT", -6, 0)
            row.removeBtn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
            row.removeBtn:SetBackdropColor(0.6, 0.18, 0.18, 1) -- red = destructive
            row.removeBtn:SetBackdropBorderColor(0, 0, 0, 1)
            local x = row.removeBtn:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
            x:SetPoint("CENTER")
            x:SetText("X")
            x:SetTextColor(1,1,1)
            ruleRows[i] = row
        end
        local row = ruleRows[i]
        row.frame:SetPoint("TOPLEFT", rulesContent, "TOPLEFT", 10, offset)
        local name, link = GetItemInfo(rule.itemID)
        if not name and C_Item and C_Item.RequestLoadItemData then
            pcall(C_Item.RequestLoadItemData, rule.itemID)
        end
        local display = link or name or ("ID " .. tostring(rule.itemID or 0))
        row.itemLabel:SetText(string.format("%s %d stacks of %d in %s", display, rule.stacks or 0, rule.stackSize or 0, GetGuildBankTabName(rule.tab or 0)))
        row.removeBtn:SetScript("OnClick", function()
            RemoveRule(rule.itemID)
            if type(ForceRefreshGuildBankSortRules) == "function" then
                ForceRefreshGuildBankSortRules()
            elseif type(RefreshGuildBankSortRules) == "function" then
                RefreshGuildBankSortRules()
            end
        end)
        row.frame:Show()
        offset = offset - 22
    end
    local totalHeight = math.max(#db.rules * 22 + 10, 120)
    rulesContent:SetHeight(totalHeight)
    local maxScroll = math.max(0, totalHeight - 120)
    rulesScrollBar:SetMinMaxValues(0, maxScroll)
    if maxScroll > 0 then
        rulesScrollBar:Show()
    else
        rulesScrollBar:Hide()
        rulesScroll:SetVerticalScroll(0)
    end
    itemIDInput:SetText("")
    stackSizeInput:SetText("")
    stacksInput:SetText("")
    -- Ensure UI refresh so the newly-added rule appears immediately
    -- Force immediate rebuild of the rules list to guarantee visibility
    if type(ForceRefreshGuildBankSortRules) == "function" then
        local ok, err = pcall(ForceRefreshGuildBankSortRules)
        if not ok then
            print("|cff77DD77DUI_GuildBankSort:|r ForceRefresh failed:", tostring(err))
        end
    else
        print("|cff77DD77DUI_GuildBankSort:|r ForceRefreshGuildBankSortRules not available yet")
    end
    -- Also schedule the normal UI refresh for consistency
    if type(RefreshGuildBankSortUI) == "function" then
        C_Timer.After(0, RefreshGuildBankSortUI)
    else
        C_Timer.After(0.05, function()
            if type(RefreshGuildBankSortUI) == "function" then RefreshGuildBankSortUI() end
        end)
    end
end)

local sortBtn = CreateFrame("Button", "DUI_GuildBankSortRunBtn", config, "BackdropTemplate")
sortBtn:SetSize(120, 25)
sortBtn:SetPoint("LEFT", addRuleBtn, "RIGHT", 12, 0)
sortBtn:SetText("Sort Guild Bank")
StyleAsTealTab(sortBtn)
sortBtn:SetScript("OnClick", function()
    -- This module has no passive behaviour to switch off -- moving items is the
    -- whole of it -- so its checkbox on the launcher rail gates the sort itself.
    EnsureGuildBankSortDB()
    if db and db.enabled == false then
        print("|cFF00FF00[DUI]|r Guild Bank Sorter is switched off in the module list.")
        return
    end
    if Sort and type(Sort.sortAllTabs) == "function" then
        Sort:sortAllTabs()
    elseif Sort and type(Sort.sortAll) == "function" then
        Sort:sortAll()
    else
        print("|cff77DD77DUI_GuildBankSort:|r Sort function not available")
    end
end)

L:Advance(31) -- the Add / Update Rule and Sort buttons share one 25px row

-- No card: the list below draws its own border and stretches to the panel's
-- bottom edge, so a card would wrap the header and nothing else.
local rulesLabel = L:Header("Rules", { card = false })

local rulesArea = CreateFrame("Frame", nil, config, "BackdropTemplate")
-- Anchored to the bottom of the panel rather than given a fixed 480x120 box: the
-- rules list is the whole point of this panel, and it was a letterbox strip with
-- empty panel under it. It now takes everything below the controls.
-- Edges match the section cards above so the list lines up with them.
rulesArea:SetPoint("TOPLEFT", 16, L:Y())
rulesArea:SetPoint("BOTTOMRIGHT", -12, 16)
DUI_StyleAsListBox(rulesArea)

local rulesScroll = CreateFrame("ScrollFrame", "DUI_GuildBankSortRulesScroll", rulesArea, "BackdropTemplate")
rulesScroll:SetPoint("TOPLEFT", 5, -5)
rulesScroll:SetPoint("BOTTOMRIGHT", -20, 5)
local rulesContent = CreateFrame("Frame", nil, rulesScroll)
rulesContent:SetSize(1, 1)
rulesScroll:SetScrollChild(rulesContent)

local rulesScrollBar = CreateFrame("Slider", nil, rulesArea, "BackdropTemplate")
rulesScrollBar:SetPoint("TOPRIGHT", -5, -5)
rulesScrollBar:SetPoint("BOTTOMRIGHT", -5, 5)
rulesScrollBar:SetWidth(12)
rulesScrollBar:SetBackdrop(DUI_EditBackdrop)
rulesScrollBar:SetBackdropColor(0, 0, 0, 0.5)
rulesScrollBar:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
rulesScrollBar:GetThumbTexture():SetSize(10, 40)
rulesScrollBar:GetThumbTexture():SetVertexColor(unpack(DUI_Theme.Accent))
DUI_RegisterAccent(rulesScrollBar:GetThumbTexture(), "vertex")
rulesScrollBar:SetMinMaxValues(0, 1)
rulesScrollBar:SetValueStep(1)
rulesScrollBar:SetObeyStepOnDrag(true)
rulesScrollBar:SetScript("OnValueChanged", function(self, value) rulesScroll:SetVerticalScroll(value) end)
rulesArea:SetScript("OnMouseWheel", function(self, delta)
    local current = rulesScrollBar:GetValue()
    rulesScrollBar:SetValue(current - (delta * 20))
end)

-- Refresh when item info becomes available so names/links update live. The event
-- (GET_ITEM_INFO_RECEIVED) fires for every item the client resolves and is very
-- frequent on login/bag opens, but only matters while the config is open, so the
-- frame is registered/unregistered from the config's OnShow/OnHide below.
-- Opening the panel with a list of uncached items sends one GET_ITEM_INFO_RECEIVED
-- per item, in a burst, and each one used to rebuild the whole rule list. Collapsed
-- onto one rebuild at the end of the frame.
local rulesRefreshQueued = false
local function FlushRulesRefresh()
    rulesRefreshQueued = false
    if config and config:IsShown() then RefreshGuildBankSortRules() end
end

local itemInfoListener = CreateFrame("Frame")
itemInfoListener:SetScript("OnEvent", function(self, event, itemID)
    if not itemID or rulesRefreshQueued then return end
    if not db or not db.rules then return end
    for _, rule in ipairs(db.rules) do
        if rule.itemID == itemID then
            rulesRefreshQueued = true
            C_Timer.After(0, FlushRulesRefresh)
            break
        end
    end
end)

function RefreshGuildBankSortRules()
    EnsureGuildBankSortDB()
    db.rules = db.rules or {}
    for _,row in ipairs(ruleRows) do
        if row.frame then row.frame:Hide() end
    end
    local offset = -10
    for i,rule in ipairs(db.rules) do
        if not ruleRows[i] then
            local row = {}
            row.frame = CreateFrame("Frame", nil, rulesContent)
            -- Rows are anchored 10px in from the scroll child's left edge (see the
            -- SetPoint further down), so the row only gets the viewport width less
            -- that inset. At the old full viewport width the row overhung the
            -- scroll frame's right edge and the remove button, being right-anchored,
            -- was the part that got clipped away.
            row.frame:SetSize(config:GetWidth() - 75, 20)
            row.itemLabel = row.frame:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
            row.itemLabel:SetPoint("LEFT", row.frame, "LEFT", 4, 0)
            row.itemLabel:SetJustifyH("LEFT")
            row.itemLabel:SetWordWrap(false)
            row.removeBtn = CreateFrame("Button", nil, row.frame, "BackdropTemplate")
            row.removeBtn:SetSize(20, 20)
            row.removeBtn:SetPoint("RIGHT", row.frame, "RIGHT", -4, 0)
            -- Anchored to the button rather than given a fixed width, so a long
            -- item link is truncated at the button instead of running under it.
            row.itemLabel:SetPoint("RIGHT", row.removeBtn, "LEFT", -6, 0)
            row.removeBtn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
            row.removeBtn:SetBackdropColor(0.6, 0.18, 0.18, 1) -- red = destructive
            row.removeBtn:SetBackdropBorderColor(0, 0, 0, 1)
            local x = row.removeBtn:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
            x:SetPoint("CENTER")
            x:SetText("X")
            x:SetTextColor(1,1,1)
            ruleRows[i] = row
        end
        local row = ruleRows[i]
        row.frame:SetPoint("TOPLEFT", rulesContent, "TOPLEFT", 10, offset)
        local name, link = GetItemInfo(rule.itemID)
        if not name and C_Item and C_Item.RequestLoadItemData then
            pcall(C_Item.RequestLoadItemData, rule.itemID)
        end
        local display = link or name or ("ID " .. tostring(rule.itemID or 0))
        row.itemLabel:SetText(string.format("%s %d stacks of %d in %s", display, rule.stacks or 0, rule.stackSize or 0, GetGuildBankTabName(rule.tab or 0)))
        row.removeBtn:SetScript("OnClick", function()
            RemoveRule(rule.itemID)
            RefreshGuildBankSortRules()
        end)
        row.frame:Show()
        offset = offset - 22
    end
    local totalHeight = math.max(#db.rules * 22 + 10, 120)
    rulesContent:SetHeight(totalHeight)
    local maxScroll = math.max(0, totalHeight - 120)
    rulesScrollBar:SetMinMaxValues(0, maxScroll)
    if maxScroll > 0 then
        rulesScrollBar:Show()
    else
        rulesScrollBar:Hide()
        rulesScroll:SetVerticalScroll(0)
    end
end

function RefreshGuildBankSortUI()
    EnsureGuildBankSortDB()
    if overflowButtonText then
        overflowButtonText:SetText(GetGuildBankTabName(db.overflowTab or 0))
    end
    if ignoreButtonText then
        ignoreButtonText:SetText(GetIgnoreTabsText())
    end
    RefreshGuildBankSortRules()
end

-- Close button, main-window anchoring and button highlight come from the factory.
-- These hooks just add the item-info listener + list refresh while the panel is open.
config:HookScript("OnShow", function(self)
    -- OnShow is queued rather than run inside Show(), so the launcher's index
    -- warm-up -- which shows and hides every panel in one frame to make it build
    -- -- still lands here with the panel already gone, leaving the listener
    -- registered for a closed panel.
    if not self:IsShown() then return end
    itemInfoListener:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    RefreshGuildBankSortUI()
end)
config:HookScript("OnHide", function(self)
    itemInfoListener:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
end)

DUI_GuildBankSortConfig = config

function DUI_InitGuildBankSort()
    EnsureGuildBankSortDB()
end

function DUI_OpenGuildBankSortConfig()
    EnsureGuildBankSortDB()
    config:Show()
end

-- Immediate rebuild helper (used to guarantee the UI updates right after adding a rule)
function ForceRefreshGuildBankSortRules()
    EnsureGuildBankSortDB()
    db.rules = db.rules or {}
    for _,row in ipairs(ruleRows) do
        if row.frame then row.frame:Hide() end
    end
    local offset = -10
    for i,rule in ipairs(db.rules) do
        if not ruleRows[i] then
            local row = {}
            row.frame = CreateFrame("Frame", nil, rulesContent)
            -- Rows are anchored 10px in from the scroll child's left edge (see the
            -- SetPoint further down), so the row only gets the viewport width less
            -- that inset. At the old full viewport width the row overhung the
            -- scroll frame's right edge and the remove button, being right-anchored,
            -- was the part that got clipped away.
            row.frame:SetSize(config:GetWidth() - 75, 20)
            row.itemLabel = row.frame:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
            row.itemLabel:SetPoint("LEFT", row.frame, "LEFT", 4, 0)
            row.itemLabel:SetJustifyH("LEFT")
            row.itemLabel:SetWordWrap(false)
            row.removeBtn = CreateFrame("Button", nil, row.frame, "BackdropTemplate")
            row.removeBtn:SetSize(20, 20)
            row.removeBtn:SetPoint("RIGHT", row.frame, "RIGHT", -4, 0)
            -- Anchored to the button rather than given a fixed width, so a long
            -- item link is truncated at the button instead of running under it.
            row.itemLabel:SetPoint("RIGHT", row.removeBtn, "LEFT", -6, 0)
            row.removeBtn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
            row.removeBtn:SetBackdropColor(0.6, 0.18, 0.18, 1) -- red = destructive
            row.removeBtn:SetBackdropBorderColor(0, 0, 0, 1)
            local x = row.removeBtn:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
            x:SetPoint("CENTER")
            x:SetText("X")
            x:SetTextColor(1,1,1)
            ruleRows[i] = row
        end
        local row = ruleRows[i]
        row.frame:SetPoint("TOPLEFT", rulesContent, "TOPLEFT", 10, offset)
        local name, link = GetItemInfo(rule.itemID)
        if not name and C_Item and C_Item.RequestLoadItemData then
            pcall(C_Item.RequestLoadItemData, rule.itemID)
        end
        local display = link or name or ("ID " .. tostring(rule.itemID or 0))
        row.itemLabel:SetText(string.format("%s %d stacks of %d in %s", display, rule.stacks or 0, rule.stackSize or 0, GetGuildBankTabName(rule.tab or 0)))
        row.removeBtn:SetScript("OnClick", function()
            RemoveRule(rule.itemID)
            ForceRefreshGuildBankSortRules()
        end)
        row.frame:Show()
        offset = offset - 22
    end
    local totalHeight = math.max(#db.rules * 22 + 10, 120)
    rulesContent:SetHeight(totalHeight)
    local maxScroll = math.max(0, totalHeight - 120)
    rulesScrollBar:SetMinMaxValues(0, maxScroll)
    if maxScroll > 0 then
        rulesScrollBar:Show()
    else
        rulesScrollBar:Hide()
        rulesScroll:SetVerticalScroll(0)
    end
end
