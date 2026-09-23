-- BagItemLevel.lua
-- Item level printed on gear in Blizzard's own bags (the separate bag windows and
-- the combined-bags frame). EllesmereUIBags does this for its own bag frame; this is
-- the same readout for when that addon is not running.
--
-- With EllesmereUIBags loaded this is harmless rather than doubled up: EUI reparents
-- every ContainerFrameN and ContainerFrameCombinedBags into a hidden frame, so the
-- buttons these labels hang off are never on screen.

local C_Container, C_Item = C_Container, C_Item
local GetItemInfoInstant = C_Item.GetItemInfoInstant
local GetCurrentItemLevel = C_Item.GetCurrentItemLevel
local GetContainerItemInfo = C_Container.GetContainerItemInfo
local GetContainerItemID = C_Container.GetContainerItemID
local ITEM_QUALITY_COLORS = ITEM_QUALITY_COLORS

local db -- DanUIDB.BagItemLevel

function DUI_GetBagItemLevelDefaults()
    return {
        enabled = true,
        fontSize = 12,
        anchor = "TOPLEFT",
        colorByQuality = true,
        fontColor = {1, 1, 1, 1},
    }
end

local ANCHORS = {
    { text = "Top Left",     value = "TOPLEFT",     x =  2, y = -2 },
    { text = "Top Right",    value = "TOPRIGHT",    x = -2, y = -2 },
    { text = "Bottom Left",  value = "BOTTOMLEFT",  x =  2, y =  2 },
    { text = "Center",       value = "CENTER",      x =  0, y =  0 },
}
local ANCHOR_BY_VALUE = {}
for _, a in ipairs(ANCHORS) do ANCHOR_BY_VALUE[a.value] = a end

-- Bottom right is left out of ANCHORS on purpose: it is where Blizzard draws the
-- stack count, and gear that shows a level never stacks, but a slot that changes
-- item keeps the same button and the two would collide mid-update.

-- Weapons, armour and profession tools/accessories carry a meaningful level. Within
-- those, shirts, tabards and cosmetic armour report a level that means nothing.
local ItemClass = Enum.ItemClass
local GEAR_CLASS = {
    [ItemClass.Weapon] = true,
    [ItemClass.Armor] = true,
    [ItemClass.Profession or -1] = true,
}
local SKIP_EQUIPLOC = {
    [""] = true,
    INVTYPE_BODY = true,
    INVTYPE_TABARD = true,
    INVTYPE_NON_EQUIP_IGNORE = true,
}
local COSMETIC = Enum.ItemArmorSubclass and Enum.ItemArmorSubclass.Cosmetic

-- Labels live in a side table keyed by button, never as a field on the button.
-- These are Blizzard's frames; a key written onto them from addon code is tainted,
-- and anything of Blizzard's that ever reads it back inherits that.
local labels = setmetatable({}, { __mode = "k" })

-- One ItemLocation reused for every slot. A bag refresh walks every button in every
-- open bag, and creating a fresh location per slot is garbage for no reason.
local loc = ItemLocation:CreateEmpty()

local function StyleLabel(fs)
    local a = ANCHOR_BY_VALUE[db.anchor] or ANCHORS[1]
    fs:ClearAllPoints()
    fs:SetPoint(a.value, a.x, a.y)
    fs:SetFont(DUI_FontPath, db.fontSize or 12, "OUTLINE")
end

local function GetLabel(button)
    local fs = labels[button]
    if not fs then
        fs = button:CreateFontString(nil, "OVERLAY", nil, 7)
        labels[button] = fs
    end
    if fs.styled ~= db then
        -- Restyled lazily the first time a label is touched after a settings change;
        -- DUI_RefreshBagItemLevels invalidates every label by clearing the marker.
        StyleLabel(fs)
        fs.styled = db
    end
    return fs
end

local function IsGear(itemID)
    local _, _, _, equipLoc, _, classID, subclassID = GetItemInfoInstant(itemID)
    if not classID or not GEAR_CLASS[classID] then return false end
    if SKIP_EQUIPLOC[equipLoc or ""] then return false end
    if classID == ItemClass.Armor and COSMETIC and subclassID == COSMETIC then return false end
    return true
end

local UpdateButton

local function Paint(button, fs, bag, slot, quality)
    loc:SetBagAndSlot(bag, slot)
    local level = GetCurrentItemLevel(loc)
    if not level then
        -- Not cached yet (first bag open after login is the usual case). Ask for it
        -- and repaint once it lands, provided the button still shows that slot.
        -- Only when it is genuinely uncached: ContinueOnItemLoad on a cached item
        -- calls back synchronously, and an item that is cached but still has no
        -- level would then recurse through here forever.
        local item = Item:CreateFromBagAndSlot(bag, slot)
        if item and not item:IsItemEmpty() and not item:IsItemDataCached() then
            item:ContinueOnItemLoad(function()
                if button:GetBagID() == bag and button:GetID() == slot then
                    UpdateButton(button)
                end
            end)
        end
        fs:Hide()
        return
    end
    if level <= 1 then fs:Hide(); return end

    fs:SetText(level)
    local c = db.colorByQuality and quality and ITEM_QUALITY_COLORS[quality]
    if c then
        fs:SetTextColor(c.r, c.g, c.b, 1)
    else
        fs:SetTextColor(unpack(db.fontColor or DUI_Theme.Accent))
    end
    fs:Show()
end

function UpdateButton(button)
    local fs = labels[button]
    if not (db and db.enabled) then
        if fs then fs:Hide() end
        return
    end

    -- ID first: GetContainerItemInfo builds a fresh table per call, and this runs
    -- for every slot of every open bag on each BAG_UPDATE. Most slots are not gear,
    -- so only those that are pay for the table (it is where quality comes from).
    local bag, slot = button:GetBagID(), button:GetID()
    local itemID = bag and slot and GetContainerItemID(bag, slot)
    local info = itemID and IsGear(itemID) and GetContainerItemInfo(bag, slot)
    if not info then
        if fs then fs:Hide() end
        return
    end

    Paint(button, GetLabel(button), bag, slot, info.quality)
end

local function UpdateFrame(frame)
    if not frame.EnumerateValidItems then return end
    for _, button in frame:EnumerateValidItems() do
        UpdateButton(button)
    end
end

-- Every container frame's UpdateItems runs on open and on each BAG_UPDATE for its
-- bag, which is exactly when the labels go stale. hooksecurefunc so Blizzard's own
-- call stays untainted. The combined-bags frame is hooked separately because it is
-- not one of the numbered frames, and which of the two is in use is a user setting.
local function EachContainerFrame(fn)
    for i = 1, 13 do
        local f = _G["ContainerFrame" .. i]
        if f then fn(f) end
    end
    if ContainerFrameCombinedBags then fn(ContainerFrameCombinedBags) end
end

local hooked = false
local function InstallHooks()
    if hooked then return end
    hooked = true
    EachContainerFrame(function(f)
        if f.UpdateItems then hooksecurefunc(f, "UpdateItems", UpdateFrame) end
    end)
end

-- Repaints every open bag. Called on any settings change; a closed bag repaints
-- itself through the hook when it next opens.
function DUI_RefreshBagItemLevels()
    for _, fs in pairs(labels) do fs.styled = nil end
    EachContainerFrame(function(f)
        if f:IsShown() then UpdateFrame(f) end
    end)
    -- Labels on buttons no open frame enumerates (a bag that has since closed) still
    -- need hiding when the module goes off.
    if not (db and db.enabled) then
        for _, fs in pairs(labels) do fs:Hide() end
    end
end

function DUI_InitBagItemLevel()
    db = DUI_InitModuleDB("BagItemLevel", DUI_GetBagItemLevelDefaults)
    -- The hooks stay installed when the module is off (a hooksecurefunc cannot be
    -- removed); UpdateButton checks the flag, so they cost one table read per slot.
    InstallHooks()
    DUI_RefreshBagItemLevels()
end

function DUI_BagItemLevelApplyEnabled()
    DUI_RefreshBagItemLevels()
end

-- Configuration UI
local config = DUI_CreateConfigFrame("DUI_BagItemLevelConfig", "Bag Item Level", 320, 300, "DUI_BagItemLevelBtn")

function DUI_OpenBagItemLevelConfig()
    db = DUI_InitModuleDB("BagItemLevel", DUI_GetBagItemLevelDefaults)

    if not config.init then
        local L = DUI_CreateLayout(config)
        L:Header("Display")
        L:Slider("DUI_BIL_Font", "Font Size", 8, 20, 1, db, "fontSize", DUI_RefreshBagItemLevels,
            { value = db.fontSize, tooltip = "Size of the item level number on each bag slot." })

        local anchorBtn = L:Dropdown("Position", {
            tooltip = { body = "Which corner of the slot the number sits in.",
                        note = "Bottom right is not offered: that is where the stack count goes." },
        })
        local function AnchorText(v) return (ANCHOR_BY_VALUE[v] or ANCHORS[1]).text end
        anchorBtn:SetValue(AnchorText(db.anchor))
        anchorBtn:SetScript("OnClick", function(self)
            DUI_ShowScrollDropdown(self, ANCHORS, function(val)
                db.anchor = val
                self:SetValue(AnchorText(val))
                DUI_RefreshBagItemLevels()
            end, db.anchor)
        end)

        L:Header("Color")
        L:Checkbox("Color by Item Quality", db, "colorByQuality", DUI_RefreshBagItemLevels,
            "Tints the number with the item's rarity color (epic purple, rare blue, and so on). Turn off to use the color below.")
        L:ColorButton("Font Color", db, "fontColor", DUI_RefreshBagItemLevels,
            "Color of the number when quality coloring is off.")

        L:Gap()
        L:Text("Shown on weapons, armor and profession gear in Blizzard's bags. If EllesmereUI Bags is running, its own bag window replaces these and shows its own item levels.")

        L:FitHeight()
        config.init = true
    end
    config:Show()
end
