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

-- Column definitions drive the header labels, the per-row cells, their tooltips and
-- the module panel's tick list. `icon` is shown desaturated/dim as a placeholder and
-- full-colour when the buff is found. `x` is not fixed: ApplyLayout packs the columns
-- the user has ticked and writes it, and `group` puts a wider gap between the
-- consumables and the raid buffs.
local COLUMNS = {
    { key = "food",   label = "Food", group = "cons", icon = ICON_FOOD_DEFAULT,  name = "Food (Well Fed)" },
    { key = "flask",  label = "Flsk", group = "cons", icon = ICON_FLASK_DEFAULT, name = "Flask / Phial" },
    { key = "vantus", label = "Vant", group = "cons", icon = ICON_VANTUS,        name = "Vantus Rune" },
    { key = "rune",   label = "Rune", group = "cons", icon = ICON_RUNE_DEFAULT,  name = "Augment Rune" },
    { key = "stam",   label = "Stam", group = "raid", icon = ICON_STAM,          name = "Stamina" },
    { key = "int",    label = "Int",  group = "raid", icon = ICON_INT,           name = "Intellect" },
    { key = "ap",     label = "AP",   group = "raid", icon = ICON_AP,            name = "Attack Power" },
    { key = "vers",   label = "Vers", group = "raid", icon = ICON_VERS,          name = "Versatility" },
    { key = "mast",   label = "Mast", group = "raid", icon = ICON_MAST,          name = "Mastery" },
    { key = "move",   label = "Move", group = "raid", icon = ICON_MOVE,          name = "Movement" },
}

-- Column pitch: the first cell's x, the step between cells, the extra gap between
-- groups, and what is left past the last cell. With all ten on these reproduce the
-- old fixed 590px window exactly.
local COL_X0, COL_STEP, COL_GROUP_GAP, COL_TAIL = 180, 40, 5, 29
-- Narrowest the window goes with most columns off: the footer's rows need the room.
local MIN_W = 400

-- ---- Settings -----------------------------------------------------------------
-- DanUIDB.ReadyCheckWindow. Columns are flat `col_<key>` flags rather than a nested
-- table because DUI_InitModuleDB backfills one level only.
function DUI_GetReadyCheckWindowDefaults()
    local d = {
        enabled = true,
        openOnReadyCheck = true,
        closeDelay = 10,
        sortByMissing = true,
        maxRows = 20,
        scale = 1,
        showSoulstone = true,
        showSourceOfMagic = true,
        autoNagWarlocks = true,
    }
    for _, col in ipairs(COLUMNS) do d["col_" .. col.key] = true end
    return d
end

local DEFAULTS = DUI_GetReadyCheckWindowDefaults()

-- The live table once ADDON_LOADED has seeded it; the defaults before that, so
-- nothing here has to nil-check its way through the first frame.
local function Settings()
    return (DanUIDB and DanUIDB.ReadyCheckWindow) or DEFAULTS
end
function DUI_ReadyCheckWindowDB() return Settings() end

local function ColumnOn(col) return Settings()["col_" .. col.key] ~= false end

-- Footer geometry. The assignments card is pinned to the bottom of the window and
-- the roster stops above it, so the scroll frame's bottom inset and the window's
-- height both derive from these. The card loses a row for each assignment row
-- switched off, and goes away (taking its inset with it) when both are.
local FOOTER_PAD, FOOTER_CAPTION_H, FOOTER_ROW_H = 8, 24, 22
local scrollBottom = FOOTER_PAD + FOOTER_CAPTION_H + 2 * FOOTER_ROW_H + 4 + 8
local windowW = 590

local RCFrame = CreateFrame("Frame", "DUI_ReadyCheckFrame", UIParent, "BackdropTemplate")
RCFrame:SetSize(590, 500); RCFrame:SetPoint("CENTER", 320, 0); RCFrame:Hide()
RCFrame:SetFrameStrata("TOOLTIP")
RCFrame:SetMovable(true); RCFrame:EnableMouse(true); RCFrame:RegisterForDrag("LeftButton")
RCFrame:SetClampedToScreen(true)
RCFrame:SetScript("OnDragStart", RCFrame.StartMoving)
-- Remembered across sessions; the panel's Reset Position puts it back.
RCFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local t = DanUIDB and DanUIDB.ReadyCheckWindow
    if t then
        local point, _, relPoint, x, y = self:GetPoint(1)
        t.point = { point, relPoint, x, y }
    end
end)
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
for _, col in ipairs(COLUMNS) do col.header = CreateHeader(col.label, 0) end

-- Forward declaration: the footer below re-scans the roster (on click, and on a
-- throttled refresh), but ScanUnit is defined further down next to the display code
-- that also uses it.
local ScanUnit
local CountMissing

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
Footer:SetHeight(FOOTER_CAPTION_H + 2 * FOOTER_ROW_H + 4)
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
ScrollFrame:SetPoint("TOPLEFT", 1, -60); ScrollFrame:SetPoint("BOTTOMRIGHT", -20, scrollBottom)
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
    cell:SetSize(16, 16)
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
        if ColumnOn(col) and not d.found[col.key] then missing[#missing + 1] = col.name end
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

-- Only the columns on screen count: the sort and the row tooltip are about what the
-- user chose to track, and an untracked buff shouldn't push someone to the top.
-- The scan itself still reads every buff - the cost is in the aura walk, not here.
CountMissing = function(found)
    local missing = 0
    for _, col in ipairs(COLUMNS) do
        if ColumnOn(col) and not found[col.key] then missing = missing + 1 end
    end
    return missing
end

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
    data.missing = CountMissing(found)
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

-- Bumped by ApplyLayout; a row painted under an older layout re-anchors its cells.
local layoutGen = 1

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

    if row.layoutGen ~= layoutGen then
        row.layoutGen = layoutGen
        for _, col in ipairs(COLUMNS) do
            local cell = row.cells[col.key]
            cell:ClearAllPoints(); cell:SetPoint("LEFT", row.frame, "LEFT", col.x or 0, 0)
            cell:SetShown(ColumnOn(col))
        end
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
    local maxRows = Settings().maxRows or 20
    local displayCount = math.min(numMembers, maxRows)
    -- The floor keeps a small group's window tall enough for the footer card; with
    -- the card off, a one-row window can be as short as its content.
    local floor = Footer:IsShown() and 228 or 110
    RCFrame:SetHeight(math.max(floor, 65 + scrollBottom + (displayCount * 20))); ScrollContent:SetHeight(numMembers * 20)
    local showScroll = numMembers > maxRows
    ScrollBar:SetShown(showScroll)
    if showScroll then
        ScrollBar:SetMinMaxValues(0, (numMembers - maxRows) * 20); ScrollFrame:SetPoint("BOTTOMRIGHT", -20, scrollBottom); ScrollContent:SetWidth(windowW - 22)
    else
        ScrollBar:SetValue(0); ScrollFrame:SetPoint("BOTTOMRIGHT", -2, scrollBottom); ScrollContent:SetWidth(windowW - 4)
    end

    -- Scan everyone, then sort missing-buffs-to-top (raid order breaks ties) so the
    -- people who still need attention sit at the top of the list.
    if not datas then
        previewActive = false
        datas = {}
        for i = 1, numMembers do datas[i] = ScanUnit(i, numMembers) end
    end
    local byMissing = Settings().sortByMissing
    table.sort(datas, function(a, b)
        if byMissing and a.missing ~= b.missing then return a.missing > b.missing end
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
-- The preset on screen, so a settings change can repaint the preview in place.
local previewPreset

local function BuildPreviewRoster(preset)
    local datas, byName = {}, {}
    for _, m in ipairs(PREVIEW_CAST) do
        local provider = m.class == "WARLOCK" or m.class == "EVOKER"
        if not (preset.noProviders and provider) then
            -- Every column filled, then the member's own gaps knocked back out, so the
            -- roster above the card looks like a real one instead of a wall of icons.
            local found = {}
            for _, col in ipairs(COLUMNS) do found[col.key] = col.icon end
            for _, key in ipairs(m.gaps or {}) do found[key] = nil end
            local missing = CountMissing(found)

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

    previewActive, previewPreset = true, preset
    RCFrame.Title:SetText("Raid Inspection - preview: " .. name)
    RCFrame:Show()
    UpdateRCWindow(BuildPreviewRoster(preset))
    print(string.format("|cFF00FF00[DUI]|r Preview: |cffffffff%s|r (%s). A real ready check replaces it; /duirc off to close.", name, preset.desc))
end

function DUI_ShowReadyCheckWindow(timeLeft)
    DUI_ReadyCheckFrame.Title:SetText("Ready Check: " .. timeLeft .. "s")
    DUI_ReadyCheckFrame:Show()
    UpdateRCWindow()
end

function DUI_HideReadyCheckWindow()
    DUI_ReadyCheckFrame:Hide()
end

-- ===========================================================================
-- Module: the window as its own rail row ("Ready Check Window", RAID group).
--
-- Off means the window never opens: not on a ready check, and not from the floating
-- bar's Inspect button, the minimap right-click or a bare /duirc either (the rail's
-- rule for on-demand buttons). Those say so in chat rather than doing nothing.
-- /duirc <state> previews still open it - that is a test tool, asked for by name.
-- The Soulstone whisper below belongs to this module too (it moved here from RC &
-- Pull on 2026-10-01), so it rides this row's switch.
-- ===========================================================================

-- A missing table reads as on, so the window keeps working before ADDON_LOADED has
-- seeded the module and on an install that predates it.
function DUI_ReadyCheckWindowEnabled()
    local t = DanUIDB and DanUIDB.ReadyCheckWindow
    return not t or t.enabled ~= false
end

-- Packs the ticked columns left to right, sizes the window to them, and shrinks or
-- drops the assignments card to the rows that are on. Every setting on the panel
-- funnels through here, then repaints whatever is on screen (a preview included).
local function ApplyLayout()
    local t = Settings()

    local x, last, prevGroup = COL_X0, nil, nil
    for _, col in ipairs(COLUMNS) do
        local on = ColumnOn(col)
        if on then
            if prevGroup and col.group ~= prevGroup then x = x + COL_GROUP_GAP end
            col.x, prevGroup, last = x, col.group, x
            x = x + COL_STEP
            col.header:ClearAllPoints(); col.header:SetPoint("LEFT", HeaderBar, "LEFT", col.x, 0)
        end
        col.header:SetShown(on)
    end
    windowW = math.max(MIN_W, last and (last + 16 + COL_TAIL) or 0)
    RCFrame:SetWidth(windowW); HeaderBar:SetWidth(windowW - 2)

    -- Visible rows stack from the top of the card, so turning off Soulstone moves
    -- Source of Magic up rather than leaving a hole above it.
    local rows = 0
    for _, entry in ipairs({ { SSRow, t.showSoulstone }, { SoMRow, t.showSourceOfMagic } }) do
        local row, on = entry[1], entry[2] ~= false
        row:SetShown(on)
        if on then
            local y = -(FOOTER_CAPTION_H + rows * FOOTER_ROW_H)
            row:ClearAllPoints(); row:SetPoint("TOPLEFT", 10, y); row:SetPoint("TOPRIGHT", -10, y)
            rows = rows + 1
        end
    end
    Footer:SetShown(rows > 0)
    if rows > 0 then
        Footer:SetHeight(FOOTER_CAPTION_H + rows * FOOTER_ROW_H + 4)
        scrollBottom = FOOTER_PAD + FOOTER_CAPTION_H + rows * FOOTER_ROW_H + 4 + 8
    else
        scrollBottom = FOOTER_PAD
    end

    RCFrame:SetScale(t.scale or 1)
    layoutGen = layoutGen + 1

    if RCFrame:IsShown() then
        if previewActive and previewPreset then UpdateRCWindow(BuildPreviewRoster(previewPreset))
        else UpdateRCWindow() end
    end
end

-- Once at load on the defaults, so the columns have an x and the headers an anchor
-- even before ADDON_LOADED re-runs it on the saved settings.
ApplyLayout()

local function ApplyPosition()
    local p = Settings().point
    RCFrame:ClearAllPoints()
    if p and p[1] then
        RCFrame:SetPoint(p[1], UIParent, p[2] or p[1], p[3] or 0, p[4] or 0)
    else
        RCFrame:SetPoint("CENTER", 320, 0)
    end
end

-- Shared by the floating bar, the minimap button and /duirc.
function DUI_ToggleReadyCheckWindow(title)
    if RCFrame:IsShown() then RCFrame:Hide(); return end
    if not DUI_ReadyCheckWindowEnabled() then
        print("|cFF00FF00[DUI]|r The ready check window is turned off (Ready Check Window, in /dan).")
        return
    end
    RCFrame.Title:SetText(title or "Raid Inspection")
    RCFrame:Show()
    UpdateRCWindow()
end

local function IsSecret(v)
    return issecretvalue and issecretvalue(v)
end

local NagFrame = CreateFrame("Frame")
local NagWanted

-- ---- Soulstone nag --------------------------------------------------------
-- A ready check is the moment the question "has every warlock put a stone out" is
-- actually being asked, so it is where the ready check window's Soulstone chip can be
-- pulled without anyone clicking it. RunWarlockNag above does the whispering; this
-- half only decides whether this client is the one that should be sending anything.
--
-- Every client in the group sees READY_CHECK, and a whisper -- unlike a ready check or
-- a pull timer -- is not deduplicated by the server: ten raiders running DanUI with
-- this on would send the same warlock ten copies. It used to be settled by letting
-- only the player who *started* the check nag, which meant a check run by anyone
-- without DanUI (or with it off) whispered nobody.
--
-- Now every DanUI client with the setting on claims the job over an addon message the
-- moment the check goes out, and when the 2s delay below is up each one runs the same
-- election over the same claims: the initiator wins if they claimed, otherwise the
-- lowest Name-Realm. Every client reaches the same answer without a reply round, so
-- there is still exactly one sender.
local lastNag = 0
local NAG_COOLDOWN = 60
local NAG_DELAY = 2
local NAG_PREFIX = "DanUI"
local NAG_MSG = "NAG1:"      -- versioned so a later format can't be misread as this one
local CLAIM_WINDOW = 6       -- a claim older than this belongs to a previous ready check

local claims = {}            -- Name-Realm -> { t = GetTime(), init = bool }

-- CHAT_MSG_ADDON is heard only while an election is open. It fires for every
-- registered prefix of every addon in the group -- BigWigs/DBM syncs, Details!,
-- WeakAuras, MRT -- so leaving it on for the module's lifetime woke the handler
-- constantly through a raid night to read a claim that only matters for the ~2s
-- after a ready check. Opened on READY_CHECK, before this client sends its own
-- claim: the others send theirs only after *their* READY_CHECK, which the server
-- broadcast to us first, so a claim cannot beat the registration here.
-- The generation counter keeps an older election's timer from closing a newer one.
local electionGen = 0

local function OpenElection()
    electionGen = electionGen + 1
    NagFrame:RegisterEvent("CHAT_MSG_ADDON")
    return electionGen
end

local function CloseElection(gen)
    if gen ~= electionGen then return end
    NagFrame:UnregisterEvent("CHAT_MSG_ADDON")
end

-- A failed register only loses the election's input; the send below notices that and
-- falls back to the initiator rule, so this is not worth erroring over.
if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    pcall(C_ChatInfo.RegisterAddonMessagePrefix, NAG_PREFIX)
end

local function StartedByPlayer(initiator)
    if not initiator then return false end
    -- READY_CHECK hands back a plain name, and a group member's name is itself a valid
    -- unit token, so UnitIsUnit resolves that and a raid token alike. It answers nil
    -- rather than false for a name it can't place, which is what the fallback is for.
    local ok, isPlayer = pcall(UnitIsUnit, initiator, "player")
    if ok and isPlayer ~= nil then return isPlayer end
    return Ambiguate(initiator, "short") == UnitName("player")
end

-- CHAT_MSG_ADDON names the sender "Name-Realm", but a same-realm name can arrive bare
-- elsewhere; normalise both sides so the election compares like with like.
local function FullName(name)
    if not name or IsSecret(name) then return nil end
    if not strfind(name, "-", 1, true) then name = name .. "-" .. (GetNormalizedRealmName() or "") end
    return name
end

local function MyFullName() return FullName(UnitName("player")) end

-- Instance groups (LFR, a queued dungeon) talk on INSTANCE_CHAT, not RAID/PARTY.
local function GroupChannel()
    if IsInGroup(LE_PARTY_CATEGORY_HOME) then return IsInRaid() and "RAID" or "PARTY" end
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
end

-- Older clients returned a boolean; current ones return Enum.SendAddonMessageResult.
local function SendClaim(init)
    local channel = GroupChannel()
    if not channel or not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return false end
    local ok, res = pcall(C_ChatInfo.SendAddonMessage, NAG_PREFIX, NAG_MSG .. (init and "1" or "0"), channel)
    if not ok then return false end
    return res == nil or res == true or res == 0
end

local function OnClaim(text, sender)
    if IsSecret(text) or type(text) ~= "string" or strsub(text, 1, #NAG_MSG) ~= NAG_MSG then return end
    sender = FullName(sender)
    -- Our own claim is recorded locally when it is sent, so the echo is dropped rather
    -- than relied on: if it never arrived we would lose an election we had won.
    if not sender or sender == MyFullName() then return end
    claims[sender] = { t = GetTime(), init = strsub(text, #NAG_MSG + 1, #NAG_MSG + 1) == "1" }
end

-- The initiator first, then the lowest name. Deterministic over the same set, which is
-- the whole point: nobody has to be told they won.
local function ElectedSender()
    local now, best, bestInit = GetTime(), nil, false
    for name, c in pairs(claims) do
        if now - c.t <= CLAIM_WINDOW then
            if not best or (c.init and not bestInit) or (c.init == bestInit and name < best) then
                best, bestInit = name, c.init
            end
        end
    end
    return best
end

local function MaybeNagWarlocks(initiator)
    if not DUI_AutoNagWarlocks or not IsInGroup() then return end

    local gen = OpenElection()
    local init = StartedByPlayer(initiator)
    local me = MyFullName()
    if me then claims[me] = { t = GetTime(), init = init } end
    -- No working addon channel means no election, and guessing would let every client
    -- that can't talk whisper at once. Degrade to the old rule: the initiator alone.
    local commsOk = me and SendClaim(init)

    -- Held a beat rather than run on the event itself: the ready check window paints on
    -- this same event, a warlock already casting as the check goes out gets to finish,
    -- any /duirc preview on screen has been replaced by a live scan by the time this
    -- fires -- and the other clients' claims have had time to arrive.
    C_Timer.After(NAG_DELAY, function()
        -- Every claim that counts has arrived by now; ElectedSender reads the table,
        -- not the event, so the listener can close before the vote is counted.
        CloseElection(gen)
        -- Re-checked: the row (or the setting) can be switched off inside the delay.
        if not NagWanted() then return end
        if commsOk then
            if ElectedSender() ~= me then return end
        elseif not init then
            return
        end

        -- A second ready check right after the first ("are we ready *now*") is normal,
        -- and whispering the same warlock again twenty seconds later reads as nagging
        -- rather than reminding. Applied only by the elected sender, and after the
        -- election rather than before the claim: a throttled client that dropped out of
        -- the running would hand the job to the next name, who would whisper anyway.
        local now = GetTime()
        if now - lastNag < NAG_COOLDOWN then return end
        lastNag = now
        DUI_AutoNagWarlocks()
    end)
end

-- READY_CHECK is held only while the module and the setting are both on, so a
-- switched-off nag costs nothing - the same rule every other module follows.
local nagEventsOn = false

NagWanted = function()
    return DUI_ReadyCheckWindowEnabled() and Settings().autoNagWarlocks and true or false
end

function DUI_SyncReadyCheckNag()
    local on = NagWanted()
    if on == nagEventsOn then return end
    nagEventsOn = on
    if on then NagFrame:RegisterEvent("READY_CHECK") else NagFrame:UnregisterEvent("READY_CHECK") end
end

NagFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "READY_CHECK" then
        MaybeNagWarlocks((...))
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, text, _, sender = ...
        if prefix == NAG_PREFIX then OnClaim(text, sender) end
    end
end)

function DUI_InitReadyCheck()
    local t = DanUIDB.ReadyCheckWindow or {}
    DanUIDB.ReadyCheckWindow = t

    -- The whisper used to be RC & Pull's setting. Carried over once, before the
    -- defaults backfill could write a `true` over it, and then removed from there.
    -- Its effective state is what moves: it only ever ran with RC & Pull on, and an
    -- install that never got the 2026-09-15 default flip (no ...Defaulted flag) gets
    -- the flip here, as it would have there. Delete once no live DanUIDB still has
    -- ReadyCheckPullTimer.autoNagWarlocks.
    local old = DanUIDB.ReadyCheckPullTimer
    if old and old.autoNagWarlocks ~= nil then
        if t.autoNagWarlocks == nil then
            local on = old.autoNagWarlocks
            if not old.autoNagWarlocksDefaulted then on = true end
            if old.enabled == false then on = false end
            t.autoNagWarlocks = on
        end
        old.autoNagWarlocks, old.autoNagWarlocksDefaulted = nil, nil
    end

    DUI_InitModuleDB("ReadyCheckWindow", DUI_GetReadyCheckWindowDefaults)
    ApplyPosition()
    ApplyLayout()
    DUI_SyncReadyCheckNag()
end

-- /duinag - why did (or didn't) the last ready check whisper anyone. Reports this
-- module's gates, then hands off to the scan's own dry run. Nothing is ever sent.
-- `/duinag on|off` flips the setting, quicker than opening the panel.
SLASH_DUINAG1 = "/duinag"
SlashCmdList["DUINAG"] = function(msg)
    local t = DUI_InitModuleDB("ReadyCheckWindow", DUI_GetReadyCheckWindowDefaults)
    local arg = strlower(strtrim(msg or ""))

    if arg == "on" or arg == "off" then
        t.autoNagWarlocks = (arg == "on")
        DUI_SyncReadyCheckNag()
        if DUI_RCWNagCheck then DUI_RCWNagCheck:SetChecked(t.autoNagWarlocks) end
        print("|cFF00FF00[DUI]|r Soulstone nag on ready check: " ..
            (t.autoNagWarlocks and "|cff00FF00on|r" or "|cffFFA500off|r"))
        return
    end

    print("|cFF00FF00[DUI]|r Soulstone nag - |cffffffff/duinag on|r or |cffffffff/duinag off|r to switch it.")
    print("  Ready Check Window module: " .. (t.enabled and "|cff00FF00enabled|r" or "|cffFFA500disabled|r - the nag rides this flag"))
    print("  Whisper on ready check: " .. (t.autoNagWarlocks and "|cff00FF00on|r" or "|cffFFA500off|r"))
    print("  In a group: " .. (IsInGroup() and "|cff00FF00yes|r" or "|cffFFA500no|r"))
    local wait = NAG_COOLDOWN - (GetTime() - lastNag)
    if lastNag > 0 and wait > 0 then
        print(string.format("  Throttle: |cffFFA500%ds left|r before another ready check would whisper", math.ceil(wait)))
    end
    print("  |cff9a9a9aAny ready check counts. One DanUI client sends: whoever started it if they run DanUI with this on, otherwise the first by name.|r")

    DUI_ReportWarlockNag()
end

-- ---- Config panel -----------------------------------------------------------
local rcwConfig = DUI_CreateConfigFrame("DUI_ReadyCheckWindowConfig", "Ready Check Window", 320, 300, "DUI_ReadyCheckWindowBtn")

local function PanelButton(L, text, tip, onClick)
    local b = CreateFrame("Button", nil, rcwConfig, "BackdropTemplate")
    b:SetSize(150, 22)
    L:Place(b)
    b:SetText(text)
    StyleAsTealTab(b)
    DUI_AddTooltip(b, text, tip)
    b:SetScript("OnClick", onClick)
    return b
end

-- Lays a run of column ticks out two-up under the current header.
local function ColumnTicks(L, db, group)
    local list = {}
    for _, col in ipairs(COLUMNS) do if col.group == group then list[#list + 1] = col end end
    L:Columns(2)
    for i, col in ipairs(list) do
        L:Column(((i - 1) % 2) + 1)
        L:Checkbox(col.name, db, "col_" .. col.key, ApplyLayout,
            "Shows the " .. col.name .. " column. A hidden column also stops counting towards the missing-buffs sort and the row tooltip.")
    end
    L:EndColumns()
end

function DUI_OpenReadyCheckWindowConfig()
    local db = DUI_InitModuleDB("ReadyCheckWindow", DUI_GetReadyCheckWindowDefaults)

    if not rcwConfig.init then
        local L = DUI_CreateLayout(rcwConfig)

        L:Header("Behavior")
        L:Checkbox("Open on Ready Check", db, "openOnReadyCheck", nil,
            { body = "Opens the window when any ready check starts.",
              note = "Off leaves it to the floating bar's Inspect button, the minimap right-click and /duirc. The Soulstone whisper still runs on ready checks either way." })
        L:Slider("DUI_RCW_CloseDelay", "Close After Check", 0, 60, 1, db, "closeDelay", nil,
            { fmt = "%ds", value = db.closeDelay,
              tooltip = "How long the window stays up once the ready check finishes. 0 leaves it open until you close it." })
        L:Checkbox("Sort by Missing Buffs", db, "sortByMissing", ApplyLayout,
            "Puts whoever is missing the most tracked buffs at the top. Off keeps raid order.")
        L:Slider("DUI_RCW_MaxRows", "Visible Rows", 10, 40, 5, db, "maxRows", ApplyLayout,
            { fmt = "%d", value = db.maxRows, tooltip = "Rows shown before the list scrolls." })
        L:Slider("DUI_RCW_Scale", "Window Scale", 0.6, 1.5, 0.05, db, "scale", ApplyLayout,
            { fmt = "%.2f", value = db.scale, tooltip = "Size of the whole window." })

        L:Header("Consumables")
        ColumnTicks(L, db, "cons")

        L:Header("Raid Buffs")
        ColumnTicks(L, db, "raid")

        L:Header("Assignments")
        L:Checkbox("Soulstone", db, "showSoulstone", ApplyLayout,
            "The Soulstone row of the card under the roster: how many warlocks have a stone out, and on whom. Its count is the button that whispers the ones who haven't.")
        L:Checkbox("Source of Magic", db, "showSourceOfMagic", ApplyLayout,
            "The Source of Magic row: how many evokers have it out, and on whom.")
        DUI_RCWNagCheck = L:Checkbox("Whisper Unstoned Warlocks", db, "autoNagWarlocks", DUI_SyncReadyCheckNag,
            { body = "When a ready check starts, whispers every warlock who has not put a Soulstone out yet.",
              note = "Sends real whispers with no confirmation. Works on anyone's ready check, and with the window closed or the Soulstone row hidden; when several people run DanUI only one of them whispers (whoever started the check, else the first by name). At most once a minute, and stays quiet if Soulstone buffs can't be read at that moment rather than guessing. /duinag reports what it would do without sending anything." })

        L:Header("Window")
        PanelButton(L, "Show Preview",
            "Opens the window filled with an invented raid, so you can see your settings without a ready check. Click again for the next state; /duirc lists them.",
            function() DUI_PreviewReadyCheckWindow("next") end)
        PanelButton(L, "Reset Position", "Puts the window back where it starts. Drag it by any empty part to move it.",
            function()
                db.point = nil
                ApplyPosition()
            end)

        L:FitHeight()
        rcwConfig.init = true
    end
    rcwConfig:Show()
end
