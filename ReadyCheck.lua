-- ReadyCheck.lua
-- Handles the Raid Inspection and Ready Check window

-- Localized for ScanUnit, which is the hottest loop in the addon: it runs up to
-- 40 aura reads per member, for up to 40 members, and a full pass is re-run on
-- every READY_CHECK_CONFIRM while the window is up. Every name below was a global
-- table lookup per iteration before this.
local UnitClass, UnitName, GetUnitName = UnitClass, UnitName, GetUnitName
local GetReadyCheckStatus, UnitGroupRolesAssigned = GetReadyCheckStatus, UnitGroupRolesAssigned
local GetAuraDataByIndex = C_UnitAuras.GetAuraDataByIndex
local strfind, pcall = strfind, pcall

local ICON_FOOD_DEFAULT = 136000 
local ICON_VANTUS       = 5976918
local ICON_RUNE_DEFAULT = 4549099
local SPELL_ID_SS       = 20707
local SPELL_ID_SOM      = 369459
local ICON_SS           = "Interface\\Icons\\Inv_misc_orb_04"
local ICON_SOM          = 4630412
local ICON_FLASK_DEFAULT = "Interface\\Icons\\Trade_Alchemy"

-- Column definitions drive the header icons, the per-row cells, and their tooltips.
-- `icon` is shown desaturated/dim as a placeholder and full-colour when the buff is found.
local COLUMNS = {
    { key = "food",   x = 180, icon = ICON_FOOD_DEFAULT, name = "Food (Well Fed)" },
    { key = "flask",  x = 220, icon = ICON_FLASK_DEFAULT, name = "Flask / Phial" },
    { key = "vantus", x = 260, icon = ICON_VANTUS,        name = "Vantus Rune" },
    { key = "rune",   x = 300, icon = ICON_RUNE_DEFAULT,  name = "Augment Rune" },
    { key = "stam",   x = 345, icon = ICON_STAM,          name = "Stamina" },
    { key = "int",    x = 385, icon = ICON_INT,           name = "Intellect" },
    { key = "ap",     x = 425, icon = ICON_AP,            name = "Attack Power" },
    { key = "vers",   x = 465, icon = ICON_VERS,          name = "Versatility" },
    { key = "mast",   x = 505, icon = ICON_MAST,          name = "Mastery" },
    { key = "move",   x = 545, icon = ICON_MOVE,          name = "Movement" },
}

-- Footer geometry. The assignments card is pinned to the bottom of the window and
-- the roster stops above it, so the scroll frame's bottom inset and the window's
-- height both derive from these rather than repeating a magic 80.
local FOOTER_PAD, FOOTER_H = 8, 72
local SCROLL_BOTTOM = FOOTER_PAD + FOOTER_H + 8

local RCFrame = CreateFrame("Frame", "DUI_ReadyCheckFrame", UIParent, "BackdropTemplate")
RCFrame:SetSize(590, 500); RCFrame:SetPoint("CENTER", 320, 0); RCFrame:Hide()
RCFrame:SetFrameStrata("TOOLTIP")
RCFrame:SetMovable(true); RCFrame:EnableMouse(true); RCFrame:RegisterForDrag("LeftButton")
RCFrame:SetClampedToScreen(true)
RCFrame:SetScript("OnDragStart", RCFrame.StartMoving); RCFrame:SetScript("OnDragStop", RCFrame.StopMovingOrSizing)
RCFrame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", tile = false, tileSize = 0, edgeSize = 1, insets = { left = 0, right = 0, top = 0, bottom = 0 } })
RCFrame:SetBackdropColor(unpack(DUI_Theme.MainBG)); RCFrame:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
DUI_RegisterAccent(RCFrame, "border")
DUI_RegisterMainBG(RCFrame, "bg")
RCFrame.Title = RCFrame:CreateFontString(nil, "OVERLAY", "DUI_FontLarge"); RCFrame.Title:SetPoint("TOP", 0, -10); RCFrame.Title:SetText("Ready Check")

local RCClose = CreateFrame("Button", nil, RCFrame, "BackdropTemplate")
RCClose:SetSize(20, 20); RCClose:SetPoint("TOPRIGHT", -5, -5)
StyleAsCloseButton(RCClose)
RCClose:SetScript("OnClick", function() RCFrame:Hide() end)

local HeaderBar = RCFrame:CreateTexture(nil, "BACKGROUND")
HeaderBar:SetSize(588, 22); HeaderBar:SetPoint("TOP", 0, -38); HeaderBar:SetColorTexture(0, 0, 0, 1)

local function CreateHeader(text, x)
    local h = RCFrame:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    h:SetPoint("LEFT", HeaderBar, "LEFT", x, 0); h:SetText(text); h:SetTextColor(1, 1, 1)
    return h
end
local ColNamesHeader = CreateHeader("Player (0/0 Ready)", 15)
CreateHeader("Food", 180); CreateHeader("Flsk", 220); CreateHeader("Vant", 260); CreateHeader("Rune", 300)
CreateHeader("Stam", 345); CreateHeader("Int", 385); CreateHeader("AP", 425); CreateHeader("Vers", 465); CreateHeader("Mast", 505); CreateHeader("Move", 545)

-- Forward declaration: the footer below re-scans the roster (on click, and on a
-- throttled refresh), but ScanUnit is defined further down next to the display code
-- that also uses it.
local ScanUnit

-- The window sits in the "TOOLTIP" strata, so a plain GameTooltip renders behind its
-- cells/text. Anchor it, then lift its frame level above the window so it shows on top.
local function OpenTooltip(owner, anchor)
    GameTooltip:SetOwner(owner, anchor)
    GameTooltip:SetFrameStrata("TOOLTIP")
    GameTooltip:SetFrameLevel(RCFrame:GetFrameLevel() + 50)
end

-- ---- Assignments footer ---------------------------------------------------
-- Soulstone and Source of Magic are the same kind of fact -- somebody in the raid
-- owes the group a buff -- so they share one card at the bottom of the window
-- rather than sitting as two loose icons with a name list trailing off them: a row
-- each, holding an icon, what it is, a count chip, and who is carrying it.
--
-- The count is providers *covered*, not buffs seen: two stones from one warlock is
-- one warlock covered, which is the number that decides whether anyone needs nagging.
-- It is also the card's only control -- the Soulstone chip clicks through to a
-- whisper for exactly the warlocks that count says are missing -- so the number and
-- the action that fixes it are the same widget instead of a button beside it.

local STATE_GOOD    = { 0.35, 0.80, 0.40 }
local STATE_PARTIAL = { 1.00, 0.65, 0.20 }
local STATE_BAD     = { 0.90, 0.32, 0.32 }
local STATE_IDLE    = { 0.55, 0.55, 0.55 }

-- Set while a /duirc preview is on screen. The card is showing invented data then, so
-- the chip must not whisper real people off the back of it; any real update clears it.
local previewActive = false

-- One-shot latch for the automatic nag's "auras are unreadable here" notice, so the
-- explanation arrives the first time it matters and not once per pull all night.
local blindNoticeShown = false

local Footer = CreateFrame("Frame", nil, RCFrame, "BackdropTemplate")
Footer:SetPoint("BOTTOMLEFT", FOOTER_PAD, FOOTER_PAD); Footer:SetPoint("BOTTOMRIGHT", -FOOTER_PAD, FOOTER_PAD)
Footer:SetHeight(FOOTER_H)
Footer:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
Footer:SetBackdropColor(0, 0, 0, 0.35); Footer:SetBackdropBorderColor(0, 0, 0, 1)

-- Accent hairline along the top edge, matching the divider under every DUI title.
-- Registered as "fn" rather than "vertex" because the shared vertex repaint drags the
-- accent's own alpha in with it and would paint this solid.
local FooterEdge = Footer:CreateTexture(nil, "ARTWORK")
FooterEdge:SetTexture("Interface\\Buttons\\WHITE8X8"); FooterEdge:SetHeight(1)
FooterEdge:SetPoint("TOPLEFT", 0, 0); FooterEdge:SetPoint("TOPRIGHT", 0, 0)
local function PaintFooterEdge()
    local a = DUI_Theme.Accent
    FooterEdge:SetVertexColor(a[1], a[2], a[3], 0.55)
end
PaintFooterEdge()
DUI_RegisterAccent(FooterEdge, "fn", PaintFooterEdge)

local FooterCaption = Footer:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
FooterCaption:SetFont(DUI_FontPath, 11, ""); FooterCaption:SetPoint("TOPLEFT", 10, -7)
FooterCaption:SetText("ASSIGNMENTS"); FooterCaption:SetTextColor(unpack(DUI_Theme.Accent))
DUI_RegisterAccent(FooterCaption, "text")

-- Chips carry the count and the state colour; the body stays translucent so the
-- border and the number are what read at a glance.
local function SetChip(chip, text, color)
    chip:SetBackdropColor(color[1], color[2], color[3], 0.18)
    chip:SetBackdropBorderColor(color[1], color[2], color[3], 0.85)
    chip.text:SetText(text); chip.text:SetTextColor(color[1], color[2], color[3])
end

-- Row hover: the full carrier list, who still owes one, and - on a row whose chip is
-- live - what clicking it does. Anchored to the row rather than to whatever the
-- pointer is over, so crossing onto the chip doesn't move the tooltip.
local function ShowAssignmentTooltip(row)
    OpenTooltip(row, "ANCHOR_TOPRIGHT")
    GameTooltip:SetText(row.label, 1, 1, 1)
    GameTooltip:AddLine(row.tipCarried or ("Nobody has " .. row.label .. " up."), 0.8, 0.8, 0.8, true)
    if row.tipOwed then GameTooltip:AddLine(row.tipOwed, 1, 0.45, 0.45, true) end
    if row.tipNote then GameTooltip:AddLine(row.tipNote, 0.6, 0.6, 0.6, true) end
    if row.tipAction then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(row.tipAction, 0.45, 0.75, 1, true)
    end
    GameTooltip:Show()
end

-- The chip sits inside the row and has its own hover, so hide only once the pointer
-- has left the row's rect entirely -- otherwise crossing onto the chip blinks the
-- tooltip out and back.
local function HideAssignmentTooltip(row)
    if not row:IsMouseOver() then GameTooltip:Hide() end
end

-- Whispers only the warlocks who don't have a stone out. The Soulstone buff sits on
-- the recipient, so "who still owes one" comes from each aura's caster (see ScanUnit).
-- Attribution can be missing - caster left the group, or aura data is restricted - and
-- an unattributed warlock is whispered rather than silently let off, with the chat
-- summary saying how many stones were ambiguous.
--
-- `auto` marks the pass fired by a ready check rather than a click on the chip. It
-- whispers the same people for the same reasons; what changes is that it has to be
-- able to keep quiet. A click is someone asking for this once and watching the result,
-- so it still whispers on a scan it couldn't read and explains itself afterwards. The
-- automatic pass runs unattended on every ready check of the night, so the same guess
-- would be a whisper to every warlock at every pull -- see the blind bail below.
-- `dry` is /duinag: the same scan, reported instead of sent. Every other path here
-- either whispers or goes quiet, which left no way to ask why a ready check did
-- nothing -- feature off, nobody owed a stone, and auras unreadable all look alike
-- from the outside.
local function RunWarlockNag(mode)
    local auto, dry = mode == "auto", mode == "dry"

    if previewActive and not dry then
        if not auto then
            print("|cFFFFA500[DUI]|r That's a preview - nobody was whispered. /duirc off to leave it.")
        end
        return
    end

    local numMembers = math.max(GetNumGroupMembers(), 1)

    -- Roster first: naming the warlocks needs no aura data, so this half still works
    -- when the soulstone scan below can't run.
    local warlocks = {}
    for i = 1, numMembers do
        local unit = GetUnitID(i, numMembers)
        local _, class = UnitClass(unit)
        local name = GetUnitName(unit, true) or UnitName(unit)
        if name and class == "WARLOCK" then warlocks[#warlocks + 1] = name end
    end

    -- Who already has a stone out. Aura index reads throw in restricted content, so a
    -- failed scan degrades to the old behaviour - whisper everyone - instead of erroring.
    local casters, stones, attributed, scanFailed = {}, 0, 0, false
    local aurasRead = 0
    for i = 1, numMembers do
        local ok, data = pcall(ScanUnit, i, numMembers)
        if not ok then scanFailed = true; break end
        aurasRead = aurasRead + (data.aurasRead or 0)
        if data.hasSS then
            stones = stones + 1
            if data.ssCaster then casters[data.ssCaster] = true; attributed = attributed + 1 end
        end
    end

    -- Nothing readable came back at all, which is not the same fact as "no stones".
    local blind = scanFailed or aurasRead == 0

    if dry then
        print("|cFF00FF00[DUI]|r Soulstone nag dry run - |cffffffffnobody was whispered|r.")
        print(string.format("  Group: |cffffffff%d|r member(s), |cffffffff%d|r warlock(s)%s",
            numMembers, #warlocks, previewActive and " |cffFFA500(a /duirc preview is on screen; this scanned the real group)|r" or ""))
        if blind then
            print("  Soulstone buffs: |cffFFA500unreadable here|r - the client is hiding aura data from addons right now.")
            print("  A ready check would |cffFFA500whisper nobody|r; the Soulstone chip would whisper all " .. #warlocks .. ".")
            return
        end
        print(string.format("  Soulstone buffs: |cff00FF00readable|r (%d aura(s) scanned, %d stone(s) out)", aurasRead, stones))
        local owed, held = {}, {}
        for _, name in ipairs(warlocks) do
            if casters[name] then held[#held + 1] = name else owed[#owed + 1] = name end
        end
        print("  Would whisper: " .. (#owed > 0 and ("|cffFFA500" .. table.concat(owed, ", ") .. "|r") or "|cff00FF00nobody|r"))
        print("  Already stoned: " .. (#held > 0 and ("|cff00FF00" .. table.concat(held, ", ") .. "|r") or "|cff9a9a9anobody|r"))
        return
    end

    -- Aura data the client is withholding (an encounter, M+) comes back as nothing,
    -- and a roster nobody could read any buff on scans exactly like a roster where
    -- nobody has stoned. This is deliberately a test of the scan, not of IsInInstance:
    -- a raid instance between pulls reads fine - the Soulstone column works there -
    -- and a ready check is an out-of-combat event. A
    -- whole raid with zero readable auras between them is not a state a real group is
    -- in, so treat it as "no data" rather than "no stones" and say nothing: the
    -- alternative is whispering every warlock in the raid, every ready check, for
    -- something they may well have already done. The chip is still there to do it by
    -- hand. Announced once a session, because the condition holds for the whole raid.
    if auto and #warlocks > 0 and blind then
        if not blindNoticeShown then
            blindNoticeShown = true
            print("|cFFFFA500[DUI]|r Soulstone buffs can't be read here (restricted content), so the automatic warlock whisper is staying quiet. The Soulstone chip on the ready check window still whispers every warlock if you want it.")
        end
        return
    end

    local whispered, skipped = 0, 0
    for _, name in ipairs(warlocks) do
        if casters[name] then
            skipped = skipped + 1
        else
            SendChatMessage("DUI: Please use your Soulstone!", "WHISPER", nil, name)
            whispered = whispered + 1
        end
    end

    -- Nothing to report on an automatic pass that found nothing to do: it runs on every
    -- ready check, and "nobody whispered" once a pull is chat noise nobody asked for.
    if whispered == 0 then
        if not auto then
            print("|cFF00FF00[DUI]|r Every warlock already has a Soulstone out - nobody whispered.")
        end
        return
    end

    print(string.format("|cFF00FF00[DUI]|r %sWhispered %d warlock(s), skipped %d with a stone already out.",
        auto and "Ready check: " or "", whispered, skipped))
    if scanFailed then
        print("|cFFFFA500[DUI]|r Soulstone buffs couldn't be read (restricted content), so every warlock was whispered.")
    elseif stones > attributed then
        print(string.format("|cFFFFA500[DUI]|r %d Soulstone(s) had no readable caster, so those warlocks may have been whispered anyway.", stones - attributed))
    end
end

-- The chip's click handler. Named for what the chip does, and kept as the row's
-- `action` so the tooltip and the enable/disable logic below read unchanged.
local function NagWarlocks() RunWarlockNag("click") end

-- Called from ReadyCheckPullTimer.lua's READY_CHECK handler, which owns the setting
-- and decides whether this client is the one that should be whispering at all.
function DUI_AutoNagWarlocks() RunWarlockNag("auto") end

-- The scan half of /duinag. The gates that decide whether a ready check gets this far
-- live in ReadyCheckPullTimer.lua and report themselves before calling this.
function DUI_ReportWarlockNag() RunWarlockNag("dry") end

-- action:  what clicking the chip does, and the noun for the tooltip's click line.
--          A row without one gets a plain chip: no hover glow, nothing to press.
local function CreateAssignmentRow(iconTex, label, absent, yOffset, action, noun)
    local row = CreateFrame("Frame", nil, Footer)
    row:SetPoint("TOPLEFT", 10, yOffset); row:SetPoint("TOPRIGHT", -10, yOffset)
    row:SetHeight(20)

    -- Spell icons ship with a baked-in border; crop it off and sit the art on a dark
    -- plate so the two rows read as a list rather than two loose pictures.
    local plate = row:CreateTexture(nil, "BACKGROUND")
    plate:SetSize(20, 20); plate:SetPoint("LEFT", 0, 0); plate:SetColorTexture(0, 0, 0, 0.55)
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16); icon:SetPoint("CENTER", plate, "CENTER")
    icon:SetTexture(iconTex); icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local title = row:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    title:SetPoint("LEFT", plate, "RIGHT", 8, 0)
    title:SetWidth(102); title:SetJustifyH("LEFT"); title:SetWordWrap(false)
    title:SetText(label); title:SetTextColor(0.82, 0.82, 0.82)

    local chip = CreateFrame("Button", nil, row, "BackdropTemplate")
    chip:SetSize(48, 18); chip:SetPoint("LEFT", title, "RIGHT", 6, 0)
    chip:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    chip.text = chip:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    chip.text:SetFont(DUI_FontPath, 11, ""); chip.text:SetPoint("CENTER", 0, 0)

    if action then
        -- The glow is the only thing saying this number is pressable, and a disabled
        -- button doesn't draw it -- so it appears exactly when there is someone to nag.
        chip:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
        local hl = chip:GetHighlightTexture()
        hl:SetVertexColor(1, 1, 1, 0.20)
        hl:ClearAllPoints(); hl:SetPoint("TOPLEFT", 1, -1); hl:SetPoint("BOTTOMRIGHT", -1, 1)
        chip:SetPushedTexture("Interface\\Buttons\\WHITE8X8")
        local pt = chip:GetPushedTexture()
        pt:SetVertexColor(0, 0, 0, 0.25)
        pt:ClearAllPoints(); pt:SetPoint("TOPLEFT", 1, -1); pt:SetPoint("BOTTOMRIGHT", -1, 1)
        chip:SetScript("OnClick", action)
        -- Starts inert: the card shows "N/A" until the first scan paints it, and a
        -- number standing for nothing shouldn't glow as if it could be pressed.
        chip:Disable()
    end
    -- Disabled buttons still take hover, so the tooltip works whatever the state.
    chip:SetScript("OnEnter", function() ShowAssignmentTooltip(row) end)
    chip:SetScript("OnLeave", function() HideAssignmentTooltip(row) end)

    -- Truncates with an ellipsis rather than running off the card; the tooltip carries
    -- the full list.
    local carriers = row:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    carriers:SetPoint("LEFT", chip, "RIGHT", 10, 0); carriers:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    carriers:SetJustifyH("LEFT"); carriers:SetWordWrap(false)

    row.label, row.absent, row.chip, row.carriers = label, absent, chip, carriers
    row.action, row.noun = action, noun
    SetChip(chip, "N/A", STATE_IDLE)
    carriers:SetText("|cff888888" .. absent .. "|r")

    row:EnableMouse(true)
    row:SetScript("OnEnter", ShowAssignmentTooltip)
    row:SetScript("OnLeave", HideAssignmentTooltip)
    return row
end

local SSRow  = CreateAssignmentRow(ICON_SS,  "Soulstone",       "No warlocks in the raid", -24, NagWarlocks, "warlock")
local SoMRow = CreateAssignmentRow(ICON_SOM, "Source of Magic", "No evokers in the raid",  -46)

-- Turns a scan into a display state: who is carrying the buff, which providers are
-- covered, and who still owes one.
--
-- `blind` is the fallback for buffs that are plainly up but whose caster couldn't be
-- read - out of range, or aura data restricted inside an instance. Then the buffs are
-- counted instead of the casters, so the row can't claim 0/2 with two names listed
-- beside it, and "who owes" is left unknown rather than blaming everyone.
local function Resolve(t)
    local providers = #t.providers
    local casterCount = 0
    for _ in pairs(t.casters) do casterCount = casterCount + 1 end
    t.owed, t.blind = {}, casterCount == 0 and #t.carried > 0
    if t.blind then
        t.covered = math.min(#t.carried, providers)
    else
        for _, p in ipairs(t.providers) do
            if not t.casters[p.key] then t.owed[#t.owed + 1] = p.tag end
        end
        t.covered = providers - #t.owed
    end
    return t
end

local function SetAssignmentRow(row, t)
    local providers, covered = #t.providers, t.covered
    local carried = #t.carried > 0 and table.concat(t.carried, ", ") or nil
    local nag = providers > 0 and covered < providers

    if providers == 0 then
        SetChip(row.chip, "N/A", STATE_IDLE)
        row.carriers:SetText(carried or ("|cff888888" .. row.absent .. "|r"))
    else
        local color = covered >= providers and STATE_GOOD or (covered == 0 and STATE_BAD or STATE_PARTIAL)
        SetChip(row.chip, covered .. "/" .. providers, color)
        row.carriers:SetText(carried or "|cffff5555None|r")
    end

    row.tipCarried = carried and ("Up on: " .. carried) or nil
    row.tipOwed = #t.owed > 0 and ("Still owes one: " .. table.concat(t.owed, ", ")) or nil
    row.tipNote = t.blind and "Casters couldn't be read, so this counts buffs rather than who cast them." or nil

    -- The count doubles as the button, so it goes live only while somebody is actually
    -- missing one: a covered raid leaves a number that can't be pressed for nothing.
    if row.action then
        if nag then row.chip:Enable() else row.chip:Disable() end
        if not nag then
            row.tipAction = nil
        elseif #t.owed > 0 then
            row.tipAction = "Click to whisper them."
        else
            row.tipAction = "Click to whisper every " .. row.noun .. "; the casters couldn't be read."
        end
    end
end

-- Summarises the whole roster into the two rows. Takes the scan UpdateRCWindow
-- already did when it has one, and does its own otherwise.
local function UpdateAssignments(datas)
    local numMembers = math.max(GetNumGroupMembers(), 1)
    if not datas then
        datas = {}
        for i = 1, numMembers do
            -- Aura index reads throw in restricted content; leave the last good state
            -- on screen rather than erroring or blanking the card.
            local ok, data = pcall(ScanUnit, i, numMembers)
            if not ok then return end
            datas[i] = data
        end
    end

    local ss  = { carried = {}, casters = {}, providers = {} }
    local som = { carried = {}, casters = {}, providers = {} }
    for _, data in ipairs(datas) do
        local color = RAID_CLASS_COLORS[data.class] or { colorStr = "ffffffff" }
        local tag = string.format("|c%s%s|r", color.colorStr, data.name:gsub("%-.+", ""))
        local key = data.fullName or data.name
        if data.class == "WARLOCK" then ss.providers[#ss.providers + 1] = { key = key, tag = tag } end
        if data.class == "EVOKER" then som.providers[#som.providers + 1] = { key = key, tag = tag } end
        if data.hasSS then
            ss.carried[#ss.carried + 1] = tag
            if data.ssCaster then ss.casters[data.ssCaster] = true end
        end
        if data.hasSoM then
            som.carried[#som.carried + 1] = tag
            if data.somCaster then som.casters[data.somCaster] = true end
        end
    end

    SetAssignmentRow(SSRow, Resolve(ss))
    SetAssignmentRow(SoMRow, Resolve(som))
end

-- UNIT_AURA repaints one player row in place; the footer summarises everyone, so
-- coalesce a burst of aura ticks into one rescan instead of walking the roster for
-- each. Keeps the card live while stones go out during a ready check.
local assignmentsPending = false
local function QueueAssignmentRefresh()
    if assignmentsPending then return end
    assignmentsPending = true
    C_Timer.After(0.5, function()
        assignmentsPending = false
        if RCFrame:IsShown() then UpdateAssignments() end
    end)
end

local ScrollFrame = CreateFrame("ScrollFrame", "DUI_RCScrollFrame", RCFrame, "BackdropTemplate")
ScrollFrame:SetPoint("TOPLEFT", 1, -60); ScrollFrame:SetPoint("BOTTOMRIGHT", -20, SCROLL_BOTTOM)
local ScrollContent = CreateFrame("Frame", "DUI_RCScrollContent", ScrollFrame); ScrollContent:SetSize(568, 1); ScrollFrame:SetScrollChild(ScrollContent)
local ScrollBar = CreateFrame("Slider", "DUI_RCScrollBar", RCFrame, "BackdropTemplate")
ScrollBar:SetSize(12, 1); ScrollBar:SetPoint("TOPLEFT", ScrollFrame, "TOPRIGHT", 4, 0); ScrollBar:SetPoint("BOTTOMLEFT", ScrollFrame, "BOTTOMRIGHT", 4, 0)
ScrollBar:SetBackdrop(DUI_EditBackdrop); ScrollBar:SetBackdropColor(0, 0, 0, 0.5); ScrollBar:SetThumbTexture("Interface\\Buttons\\WHITE8X8"); ScrollBar:GetThumbTexture():SetSize(10, 60); ScrollBar:GetThumbTexture():SetVertexColor(unpack(DUI_Theme.Accent)); ScrollBar:SetMinMaxValues(0, 1); ScrollBar:SetValueStep(1)
DUI_RegisterAccent(ScrollBar:GetThumbTexture(), "vertex")
ScrollBar:SetScript("OnValueChanged", function(self, value) ScrollFrame:SetVerticalScroll(value) end)
ScrollFrame:SetScript("OnMouseWheel", function(self, delta) ScrollBar:SetValue(ScrollBar:GetValue() - (delta * 20)) end)

local playerRows = {}

-- Sets a cell to its full-colour "found" state (foundTex given) or a dim, desaturated
-- placeholder, so a missing buff reads differently from an unscanned/empty cell.
local function SetCell(cell, foundTex)
    if foundTex then
        cell.tex:SetTexture(foundTex); cell.tex:SetDesaturated(false); cell.tex:SetAlpha(1)
        cell.found = true
    else
        cell.tex:SetTexture(cell.col.icon); cell.tex:SetDesaturated(true); cell.tex:SetAlpha(0.25)
        cell.found = false
    end
end

local function CreateCell(row, col)
    local cell = CreateFrame("Button", nil, row)
    cell:SetSize(16, 16); cell:SetPoint("LEFT", row, "LEFT", col.x, 0)
    cell.tex = cell:CreateTexture(nil, "OVERLAY"); cell.tex:SetAllPoints()
    cell.col = col
    cell:SetScript("OnEnter", function(self)
        OpenTooltip(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(self.col.name)
        if self.found then GameTooltip:AddLine("Active", 0, 1, 0)
        else GameTooltip:AddLine("Missing", 1, 0.25, 0.25) end
        GameTooltip:Show()
    end)
    cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return cell
end

-- Row-level tooltip: player, role, and a plain-language list of what they're missing.
local function ShowRowTooltip(row)
    local d = row.data
    if not d then return end
    OpenTooltip(row.frame, "ANCHOR_RIGHT")
    local color = (d.class and RAID_CLASS_COLORS[d.class]) or {r = 1, g = 1, b = 1}
    GameTooltip:AddLine(d.name, color.r, color.g, color.b)
    if d.role and d.role ~= "NONE" then GameTooltip:AddLine(d.role, 0.7, 0.7, 0.7) end
    local missing = {}
    for _, col in ipairs(COLUMNS) do
        if not d.found[col.key] then missing[#missing + 1] = col.name end
    end
    if #missing > 0 then
        GameTooltip:AddLine("Missing: " .. table.concat(missing, ", "), 1, 0.3, 0.3, true)
    else
        GameTooltip:AddLine("All buffs active", 0, 1, 0)
    end
    GameTooltip:Show()
end

-- Display rows are keyed by on-screen position, not raid index, so the list can be
-- sorted independently of roster order.
local function GetRow(pos)
    if not playerRows[pos] then
        local f = CreateFrame("Button", nil, ScrollContent)
        f:SetHeight(18); f:SetPoint("TOPLEFT", 0, -((pos - 1) * 20)); f:SetPoint("TOPRIGHT", 0, -((pos - 1) * 20))
        local bg = f:CreateTexture(nil, "BACKGROUND"); bg:SetTexture("Interface\\Buttons\\WHITE8X8"); bg:SetAllPoints()
        local readyIcon = f:CreateTexture(nil, "OVERLAY"); readyIcon:SetSize(14, 14); readyIcon:SetPoint("LEFT", f, "LEFT", 2, 0)
        local name = f:CreateFontString(nil, "OVERLAY", "DUI_FontNormal"); name:SetPoint("LEFT", f, "LEFT", 20, 0); name:SetFont(DUI_FontPath, 14, "OUTLINE")
        local cells = {}
        for _, col in ipairs(COLUMNS) do cells[col.key] = CreateCell(f, col) end
        playerRows[pos] = { frame = f, bg = bg, name = name, readyIcon = readyIcon, cells = cells }
        f:SetScript("OnEnter", function() ShowRowTooltip(playerRows[pos]) end)
        f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return playerRows[pos]
end

-- Reading a secret value throws, so a comparison is used as a probe: if this errors
-- under pcall the aura's data is restricted and the scan has to stop.
--
-- Deliberately a file-scope function rather than the inline `function() ... end` it
-- used to be. As a closure it was allocated afresh on every aura of every member,
-- which is up to 1600 throwaway closures per full roster scan -- and a full scan is
-- what a ready check runs.
local function ProbeReadable(v) return v == v end

-- Which warlock/evoker a buff belongs to. Both Soulstone and Source of Magic sit on
-- the *recipient*, so the only way to tell who still owes one is the aura's caster.
-- sourceUnit is nil once the caster leaves the group or drops out of range, and the
-- read is unavailable in restricted content, so callers must cope with a buff that
-- has no owner.
local function ResolveCaster(src)
    if not src then return nil end
    local ok, name = pcall(GetUnitName, src, true)
    return ok and name or nil
end

-- Reads one raid member's state (ready status, role, tracked buffs) into a plain table
-- so scanning is decoupled from display and sorting.
function ScanUnit(i, numMembers)
    local unit = GetUnitID(i, numMembers)
    local _, class = UnitClass(unit)
    local data = {
        index = i, unit = unit,
        name = UnitName(unit) or "Unknown",
        -- Name-Realm for cross-realm members: what SendChatMessage needs, and the form
        -- casters resolve to, so the two can be compared.
        fullName = GetUnitName(unit, true),
        class = class,
        status = GetReadyCheckStatus(unit),
        role = UnitGroupRolesAssigned(unit),
        found = {},
    }
    local found = data.found
    local hasSS, hasSoM, foundCount, ssSource, somSource = false, false, 0, nil, nil
    -- Counted so a caller can tell "nobody has a stone out" from "no aura was readable
    -- at all". The second is what withheld aura data looks like from here: index 1
    -- comes back nil and every member scans as completely unbuffed.
    local aurasRead = 0
    for j = 1, 40 do
        if foundCount == 10 and hasSS and hasSoM then break end
        local aura = GetAuraDataByIndex(unit, j, "HELPFUL")
        if not aura or not aura.spellId then break end
        local aID = aura.spellId
        if not pcall(ProbeReadable, aID) then break end
        aurasRead = aurasRead + 1
        if not hasSS and aID == SPELL_ID_SS then hasSS = true; ssSource = aura.sourceUnit
        elseif not hasSoM and aID == SPELL_ID_SOM then hasSoM = true; somSource = aura.sourceUnit
        elseif not found.vantus and (DUI_Spells.Vantus[aID] or (aura.name and strfind(aura.name, "Vantus", 1, true))) then found.vantus = ICON_VANTUS; foundCount = foundCount + 1
        elseif not found.food and (DUI_Spells.Food[aID] or (aura.name and strfind(aura.name, "Well Fed", 1, true))) then found.food = ICON_FOOD_DEFAULT; foundCount = foundCount + 1
        elseif not found.rune and DUI_Spells.Runes[aID] then found.rune = ICON_RUNE_DEFAULT; foundCount = foundCount + 1
        elseif not found.flask and (DUI_Spells.Flask[aID] or (aura.isHelpful and aura.isPersistThroughDeath)) then found.flask = aura.icon or ICON_FLASK_DEFAULT; foundCount = foundCount + 1
        elseif not found.stam and DUI_RaidBuffs.Stamina[aID] then found.stam = ICON_STAM; foundCount = foundCount + 1
        elseif not found.int and DUI_RaidBuffs.Intellect[aID] then found.int = ICON_INT; foundCount = foundCount + 1
        elseif not found.ap and DUI_RaidBuffs.AP[aID] then found.ap = ICON_AP; foundCount = foundCount + 1
        elseif not found.vers and DUI_RaidBuffs.Versatility[aID] then found.vers = ICON_VERS; foundCount = foundCount + 1
        elseif not found.mast and DUI_RaidBuffs.Mastery[aID] then found.mast = ICON_MAST; foundCount = foundCount + 1
        elseif not found.move and DUI_RaidBuffs.Movement[aID] then found.move = ICON_MOVE; foundCount = foundCount + 1 end
    end
    data.hasSS, data.hasSoM = hasSS, hasSoM
    data.aurasRead = aurasRead
    data.ssCaster, data.somCaster = ResolveCaster(ssSource), ResolveCaster(somSource)
    local missing = 0
    for _, col in ipairs(COLUMNS) do if not found[col.key] then missing = missing + 1 end end
    data.missing = missing
    return data
end

-- The row gradient per class, built once. PaintRow used to allocate two ColorMixins
-- (and a fallback colour table) per row per paint, and a live ready check paints
-- every row on each refresh.
local WHITE = { r = 1, g = 1, b = 1 }
local gradientCache = {}
local function RowGradient(class)
    local key = class or ""
    local g = gradientCache[key]
    if not g then
        local c = (class and RAID_CLASS_COLORS[class]) or WHITE
        g = { c, CreateColor(c.r, c.g, c.b, 0.45), CreateColor(c.r * 0.3, c.g * 0.3, c.b * 0.3, 0.45) }
        gradientCache[key] = g
    end
    return g[1], g[2], g[3]
end

-- Paints scanned data into a display row.
local function PaintRow(row, data)
    row.data, row.unitIndex = data, data.index
    local color, from, to = RowGradient(data.class)
    row.bg:SetGradient("HORIZONTAL", from, to)
    row.name:SetText(data.name); row.name:SetTextColor(color.r, color.g, color.b)

    -- Distinguish an active "Not Ready" (red X) from "no response yet" (hourglass).
    local status = data.status
    if status == "ready" then
        row.readyIcon:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready"); row.readyIcon:Show()
    elseif status == "notready" then
        row.readyIcon:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady"); row.readyIcon:Show()
    elseif status == "waiting" then
        row.readyIcon:SetTexture("Interface\\RaidFrame\\ReadyCheck-Waiting"); row.readyIcon:Show()
    else
        row.readyIcon:Hide()
    end

    for _, col in ipairs(COLUMNS) do SetCell(row.cells[col.key], data.found[col.key]) end
    row.frame:Show()
end

-- Called on UNIT_AURA for a single member: repaint that member's row in place (no
-- reordering, so someone lighting up a buff doesn't make the list jump around).
function UpdatePlayerRow(i)
    local numMembers = math.max(GetNumGroupMembers(), 1)
    -- A buff landing on one player can change the footer's whole summary (a stone
    -- going out covers its warlock), so ask for a coalesced rescan of the card.
    QueueAssignmentRefresh()
    for pos = 1, #playerRows do
        local row = playerRows[pos]
        if row.frame:IsShown() and row.unitIndex == i then
            local data = ScanUnit(i, numMembers)
            PaintRow(row, data)
            return data.hasSS, data.hasSoM
        end
    end
    if i <= numMembers then
        local data = ScanUnit(i, numMembers)
        return data.hasSS, data.hasSoM
    end
end

-- `datas` is only passed by the preview below; a real update scans the live roster
-- and, in doing so, drops any preview that was on screen.
function UpdateRCWindow(datas)
    local numMembers = datas and #datas or math.max(GetNumGroupMembers(), 1)
    local displayCount = math.min(numMembers, 20)
    RCFrame:SetHeight(math.max(228, 65 + SCROLL_BOTTOM + (displayCount * 20))); ScrollContent:SetHeight(numMembers * 20)
    local showScroll = numMembers > 20
    ScrollBar:SetShown(showScroll)
    if showScroll then
        ScrollBar:SetMinMaxValues(0, (numMembers - 20) * 20); ScrollFrame:SetPoint("BOTTOMRIGHT", -20, SCROLL_BOTTOM); ScrollContent:SetWidth(568)
    else
        ScrollBar:SetValue(0); ScrollFrame:SetPoint("BOTTOMRIGHT", -2, SCROLL_BOTTOM); ScrollContent:SetWidth(586)
    end

    -- Scan everyone, then sort missing-buffs-to-top (raid order breaks ties) so the
    -- people who still need attention sit at the top of the list.
    if not datas then
        previewActive = false
        datas = {}
        for i = 1, numMembers do datas[i] = ScanUnit(i, numMembers) end
    end
    table.sort(datas, function(a, b)
        if a.missing ~= b.missing then return a.missing > b.missing end
        return a.index < b.index
    end)

    local readyCount = 0
    for pos = 1, numMembers do
        local data = datas[pos]
        PaintRow(GetRow(pos), data)
        if data.status == "ready" then readyCount = readyCount + 1 end
    end

    for i = numMembers + 1, #playerRows do playerRows[i].frame:Hide() end
    ColNamesHeader:SetText(string.format("Player (%d/%d Ready)", readyCount, numMembers))
    UpdateAssignments(datas)
end

-- READY_CHECK_CONFIRM fires once per player answering, so a 30-man raid sends ~30
-- of them over a couple of seconds. Each one used to drive a full UpdateRCWindow:
-- every member rescanned (up to 40 aura reads each) and the list re-sorted, for a
-- change that only ever moves the "N/M Ready" counter and one row's icon.
--
-- Same coalescing as QueueAssignmentRefresh above, and the same reasoning. The
-- window is a ready-check readout, not an animation; a fifth of a second of lag on
-- the counter is not visible, and the burst collapses to a handful of passes.
local refreshPending = false
function DUI_QueueReadyCheckRefresh()
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(0.2, function()
        refreshPending = false
        if RCFrame:IsShown() then UpdateRCWindow() end
    end)
end

-- UNIT_AURA per member, coalesced the same way. A raid buff or a feast lands on the
-- whole raid in one frame, i.e. up to 40 events each asking for a 40-aura rescan of
-- that member; collecting the indices and repainting each once at the end of the
-- burst turns that into one pass. Each member still only rescans itself.
local dirtyRows, rowsPending = {}, false
function DUI_QueueReadyCheckRow(i)
    dirtyRows[i] = true
    if rowsPending then return end
    rowsPending = true
    C_Timer.After(0.2, function()
        rowsPending = false
        local shown = RCFrame:IsShown()
        for idx in pairs(dirtyRows) do
            dirtyRows[idx] = nil
            if shown then UpdatePlayerRow(idx) end
        end
    end)
end

-- ---- Preview --------------------------------------------------------------
-- Paints the window from an invented roster so the card can be looked at solo: the
-- states worth checking here - a warlock who still owes a stone, two stones from the
-- same warlock - otherwise need a raid and someone else's cooperation to reproduce.
--
-- /duirc <state>, or DUI_PreviewReadyCheckWindow("partial") from a macro. This is the
-- roster window; /duirctest previews the pull-timer overlay.
local PREVIEW_CAST = {
    { name = "Thornhoof",  class = "DRUID",       role = "TANK",    status = "ready" },
    { name = "Grimtusk",   class = "WARRIOR",     role = "TANK",    status = "ready",    gaps = { "vantus" } },
    { name = "Sunwhisper", class = "PRIEST",      role = "HEALER",  status = "ready" },
    { name = "Mosswake",   class = "SHAMAN",      role = "HEALER",  status = "waiting",  gaps = { "food", "flask" } },
    { name = "Nyxvoid",    class = "WARLOCK",     role = "DAMAGER", status = "ready" },
    { name = "Feldrix",    class = "WARLOCK",     role = "DAMAGER", status = "notready", gaps = { "rune" } },
    { name = "Emberwing",  class = "EVOKER",      role = "DAMAGER", status = "ready" },
    { name = "Rimefang",   class = "DEATHKNIGHT", role = "DAMAGER", status = "ready" },
    { name = "Zephyra",    class = "MAGE",        role = "DAMAGER", status = "ready",    gaps = { "vantus", "rune" } },
    { name = "Kitedancer", class = "HUNTER",      role = "DAMAGER", status = "waiting" },
}

-- stones/som entries are { on = who is carrying the buff, by = who cast it }.
-- `blind` drops the casters, standing in for buffs whose source can't be read (caster
-- out of range, or an instance's restricted aura data).
local PREVIEWS = {
    partial = { desc = "one lock still owes a stone, no SoM yet",
                stones = { { on = "Sunwhisper", by = "Nyxvoid" } } },
    covered = { desc = "both locks stoned, evoker's SoM out",
                stones = { { on = "Sunwhisper", by = "Nyxvoid" }, { on = "Thornhoof", by = "Feldrix" } },
                som = { { on = "Mosswake", by = "Emberwing" } } },
    doubled = { desc = "two stones, both from the same lock",
                stones = { { on = "Sunwhisper", by = "Nyxvoid" }, { on = "Thornhoof", by = "Nyxvoid" } },
                som = { { on = "Mosswake", by = "Emberwing" } } },
    blind   = { desc = "buffs up but their casters unreadable", blind = true,
                stones = { { on = "Sunwhisper" }, { on = "Thornhoof" } },
                som = { { on = "Mosswake" } } },
    none    = { desc = "nothing out at all" },
    solo    = { desc = "no warlocks or evokers in the raid", noProviders = true },
}
local PREVIEW_ORDER = { "partial", "covered", "doubled", "blind", "none", "solo" }
local previewIndex = 0

local function BuildPreviewRoster(preset)
    local datas, byName = {}, {}
    for _, m in ipairs(PREVIEW_CAST) do
        local provider = m.class == "WARLOCK" or m.class == "EVOKER"
        if not (preset.noProviders and provider) then
            -- Every column filled, then the member's own gaps knocked back out, so the
            -- roster above the card looks like a real one instead of a wall of icons.
            local found, missing = {}, 0
            for _, col in ipairs(COLUMNS) do found[col.key] = col.icon end
            for _, key in ipairs(m.gaps or {}) do found[key] = nil end
            for _, col in ipairs(COLUMNS) do if not found[col.key] then missing = missing + 1 end end

            local data = {
                index = #datas + 1, unit = "player", name = m.name, fullName = m.name,
                class = m.class, role = m.role, status = m.status,
                found = found, missing = missing, hasSS = false, hasSoM = false,
            }
            datas[#datas + 1] = data
            byName[m.name] = data
        end
    end

    for _, s in ipairs(preset.stones or {}) do
        local d = byName[s.on]
        if d then d.hasSS = true; d.ssCaster = (not preset.blind) and s.by or nil end
    end
    for _, s in ipairs(preset.som or {}) do
        local d = byName[s.on]
        if d then d.hasSoM = true; d.somCaster = (not preset.blind) and s.by or nil end
    end
    return datas
end

function DUI_PreviewReadyCheckWindow(arg)
    local name = strlower(strtrim(arg or ""))

    if name == "off" or name == "hide" then
        previewActive = false
        RCFrame.Title:SetText("Ready Check")
        RCFrame:Hide()
        return
    end

    if name == "next" or name == "cycle" then
        previewIndex = (previewIndex % #PREVIEW_ORDER) + 1
        name = PREVIEW_ORDER[previewIndex]
    end

    local preset = PREVIEWS[name]
    if not preset then
        print("|cFF00FF00[DUI]|r Ready check window preview - usage: /duirc <state>")
        for i, key in ipairs(PREVIEW_ORDER) do
            print(string.format("  |cff9a9a9a%d.|r |cffffffff%s|r - %s", i, key, PREVIEWS[key].desc))
        end
        print("  |cffffffffnext|r - step through the list, |cffffffffoff|r - close the preview")
        return
    end

    previewActive = true
    RCFrame.Title:SetText("Raid Inspection - preview: " .. name)
    RCFrame:Show()
    UpdateRCWindow(BuildPreviewRoster(preset))
    print(string.format("|cFF00FF00[DUI]|r Preview: |cffffffff%s|r (%s). A real ready check replaces it; /duirc off to close.", name, preset.desc))
end

function DUI_InitReadyCheck()
    -- Window setup already handled in local scope, this just ensures visibility if needed
end

function DUI_ShowReadyCheckWindow(timeLeft)
    DUI_ReadyCheckFrame.Title:SetText("Ready Check: " .. timeLeft .. "s")
    DUI_ReadyCheckFrame:Show()
    UpdateRCWindow()
end

function DUI_HideReadyCheckWindow()
    DUI_ReadyCheckFrame:Hide()
end