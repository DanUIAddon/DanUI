-- DanUI.lua
-------------------------------------------------------------------------------
-- Dan UI (DUI)
--
-- A modular suite of raid tools and UI enhancements.
--
-- Credits & Inspirations:
--   - Method Raid Tools (MRT): Roster management and group split logic.
--   - Quartz: Advanced castbar event handling and GUID tracking.
--   - BigWigs: Combat timer state management.
--   - PleebPotReminder: Health and Potion threshold monitoring.
--
-- License: GNU General Public License v3.0 or later - full text in LICENSE.
--   Auto Payout is GPL-3.0 and Premade Groups Filter is GPL-2.0-or-later, so
--   GPL-3.0 is the one license the combined work can carry. Bundled code keeps its
--   own notice; the full list is in CREDITS.md:
--
--     LFGFilter/          Premade Groups Filter   B. Saumweber    GPL-2.0-or-later
--     AutoPayout*.lua     Auto Payout             Oppzippy        GPL-3.0
--     LowHealthReminder   PleebPotReminder        .pleeb.         MIT
--     Libs/               LibCustomGlow, LibStub,                 per-library
--                         CallbackHandler-1.0, LibSharedMedia-3.0
--
--   NOT redistributable (All Rights Reserved upstream, left out of the public
--   repo and the release zip until the author agrees):
--     Mover*.lua (EnhanceQoL, R41z0r), NoAutoclose.lua (NoAutoClose, Numy),
--     Timeline.lua (Better Timeline / AbilityTimeline, Jods).
-------------------------------------------------------------------------------
local LSM = LibStub:GetLibrary("LibSharedMedia-3.0")

-- Expressway is a commercial Typodermic font whose license forbids embedding it in
-- software, so it is never published: the file is gitignored and the packager
-- strips this registration from the release. The released build ships Barlow Semi
-- Condensed (SIL OFL 1.1, Fonts/Barlow-OFL.txt) instead, and DUI_ResolveFont still
-- prefers Expressway whenever something else registers it (ElvUI, EllesmereUI).
--@do-not-package@
LSM:Register("font", "Expressway", [[Interface\AddOns\DanUI\Fonts\Expressway.ttf]])
--@end-do-not-package@
LSM:Register("font", "Barlow Semi Condensed", [[Interface\AddOns\DanUI\Fonts\BarlowSemiCondensed-Medium.ttf]])

-- Performance: Localize heavy API calls
local UnitName, UnitClass, UnitIsGroupLeader, UnitIsGroupAssistant, UnitAura = UnitName, UnitClass, UnitIsGroupLeader, UnitIsGroupAssistant, UnitAura
local GetNumGroupMembers, IsInRaid, IsInGroup, GetTime = GetNumGroupMembers, IsInRaid, IsInGroup, GetTime
local C_UnitAuras_GetAuraDataByIndex = C_UnitAuras.GetAuraDataByIndex
local RAID_CLASS_COLORS = RAID_CLASS_COLORS
local strfind = strfind

-- Global Theme Definition
DUI_Theme = {
    MainBG = {0.3, 0.3, 0.3, 0.8},    -- Dark Gray
    Accent = {0.51, 0.65, 0.44, 1},   -- Sage Green (user-customizable; see DUI_SetAccent)
    Secondary = {0.5, 0.5, 0.5, 1},  -- Mid Gray for buttons (see DUI_SetSecondary)
}
DUI_DEFAULT_ACCENT = {0.51, 0.65, 0.44, 1}
DUI_DEFAULT_MAINBG = {0.3, 0.3, 0.3, 0.8}
DUI_DEFAULT_SECONDARY = {0.5, 0.5, 0.5, 1}

-- The accent as a WoW colour escape ("ffrrggbb"), for text built with |c...|r.
-- Anything using this must be rebuilt when the accent changes: either it is
-- constructed on demand (menu titles) or it is registered as "hextext" below.
function DUI_AccentHex()
    local a = DUI_Theme.Accent
    -- Rounded to integers before formatting: %x on a float is a hard error on any
    -- Lua past 5.1, and 0.51 * 255 is not a whole number.
    return string.format("ff%02x%02x%02x",
        math.floor(a[1] * 255 + 0.5), math.floor(a[2] * 255 + 0.5), math.floor(a[3] * 255 + 0.5))
end

-- Wrap text in the current accent colour.
function DUI_AccentText(text)
    return "|c" .. DUI_AccentHex() .. text .. "|r"
end

-- Accent recolor registry: widgets whose accent-colored part can be restyled live.
-- kind: "border" (SetBackdropBorderColor), "bg" (SetBackdropColor),
--       "text" (SetTextColor), "vertex" (SetVertexColor),
--       "hextext" (FontString whose text embeds the accent as a |c escape; the
--        registered build function is re-run to regenerate it)
--       "fn" (state-dependent coloring -- e.g. only the active tab wears the
--        accent -- so the widget cannot just be recolored blindly; the registered
--        function is called and repaints whatever it owns. obj is only the owner
--        the entry hangs off, and is not touched.)
local accentRegistry = {}
function DUI_RegisterAccent(obj, kind, build)
    if obj then accentRegistry[#accentRegistry + 1] = { obj = obj, kind = kind, build = build } end
end

function DUI_ApplyAccent()
    local a = DUI_Theme.Accent
    -- Unpacked once rather than per entry. The registry holds one row per accented
    -- widget across every panel -- several hundred once the launcher has warmed
    -- them all -- and this whole loop re-runs on every step of a colour-picker
    -- drag, so an unpack call per row is a C call per widget per frame.
    local r, g, b, al = a[1], a[2], a[3], a[4]
    for _, e in ipairs(accentRegistry) do
        if e.kind == "hextext" then if e.build then e.obj:SetText(e.build()) end
        elseif e.kind == "border" then e.obj:SetBackdropBorderColor(r, g, b, al)
        elseif e.kind == "bg" then e.obj:SetBackdropColor(r, g, b, al)
        elseif e.kind == "text" then e.obj:SetTextColor(r, g, b, al)
        elseif e.kind == "vertex" then e.obj:SetVertexColor(r, g, b, al)
        elseif e.kind == "fn" then if e.build then e.build() end end
    end
    -- The rail's selection highlight is a plain registered texture, so it recolors
    -- with everything else above; the old conditional tab-border restyle that
    -- stood here went with the tabs.
    if DUI_ConfigRegistry then
        for _, e in ipairs(DUI_ConfigRegistry) do
            local f, btn = _G[e.f], e.b and _G[e.b]
            if btn and btn.SetBackdropBorderColor and f and f:IsShown() then
                btn:SetBackdropBorderColor(unpack(a))
            end
        end
    end
end

-- Mutate the accent in place (the table identity is shared by every module) and
-- restyle registered widgets. Widgets not in the registry keep the old color
-- until the next /reload.
function DUI_SetAccent(r, g, b, a)
    local c = DUI_Theme.Accent
    c[1], c[2], c[3], c[4] = r, g, b, a or 1
    if DanUIDB then DanUIDB.AccentColor = { r, g, b, a or 1 } end
    DUI_ApplyAccent()
end

-- Panel-background registry: the same machinery as the accent registry above, for
-- the gray fill every DUI window shares. Deliberately a second registry rather
-- than more kinds on the first -- the two colors are picked independently, and
-- changing one must not repaint the other.
-- kind: "bg" (SetBackdropColor), "vertex" (SetVertexColor),
--       "fn" (the registered function is called; for the handful of spots that
--        want the background's RGB but not its alpha)
local mainBGRegistry = {}
function DUI_RegisterMainBG(obj, kind, build)
    if obj then mainBGRegistry[#mainBGRegistry + 1] = { obj = obj, kind = kind, build = build } end
end

function DUI_ApplyMainBG()
    local c = DUI_Theme.MainBG
    -- Hoisted for the same reason as the accent loop: the opacity slider drives
    -- this on every step of its drag.
    local r, g, b, a = c[1], c[2], c[3], c[4]
    for _, e in ipairs(mainBGRegistry) do
        if e.kind == "bg" then e.obj:SetBackdropColor(r, g, b, a)
        elseif e.kind == "vertex" then e.obj:SetVertexColor(r, g, b, a)
        elseif e.kind == "fn" then if e.build then e.build() end end
    end
end

-- Mutate the background in place (the table identity is shared by every module)
-- and repaint. Alpha is optional so the color picker can change the shade without
-- disturbing the opacity slider, and the slider can move without touching the hue.
function DUI_SetMainBG(r, g, b, a)
    local c = DUI_Theme.MainBG
    c[1], c[2], c[3], c[4] = r, g, b, a or c[4]
    if DanUIDB then DanUIDB.MainBGColor = { c[1], c[2], c[3], c[4] } end
    DUI_ApplyMainBG()
end

-- Button-color registry: the third of the three colors the Theme panel owns, for
-- the grey body every DUI button and tab wears and the border around sunken
-- fields (dropdowns, sliders, list wells). A third registry rather than more
-- kinds on the other two, for the same reason they are separate from each other:
-- the colors are picked independently, and repainting one must not touch another.
-- kind: "bg" (SetBackdropColor), "border" (SetBackdropBorderColor),
--       "vertex" (SetVertexColor), "fn" (the registered function is called)
local secondaryRegistry = {}
function DUI_RegisterSecondary(obj, kind, build)
    if obj then secondaryRegistry[#secondaryRegistry + 1] = { obj = obj, kind = kind, build = build } end
end

-- Opt a widget back out after it has been registered. Danger buttons are teal
-- tabs with a red body painted over the top, so StyleAsTealTab enrolls them and
-- StyleAsDangerButton has to undo that or the next repaint turns them grey.
function DUI_ExemptSecondary(obj)
    if obj then obj.duiSecondaryExempt = true end
end

function DUI_ApplySecondary()
    local c = DUI_Theme.Secondary
    local r, g, b, a = c[1], c[2], c[3], c[4]
    for _, e in ipairs(secondaryRegistry) do
        if not e.obj.duiSecondaryExempt then
            if e.kind == "bg" then e.obj:SetBackdropColor(r, g, b, a)
            elseif e.kind == "border" then e.obj:SetBackdropBorderColor(r, g, b, a)
            elseif e.kind == "vertex" then e.obj:SetVertexColor(r, g, b, a)
            elseif e.kind == "fn" then if e.build then e.build() end end
        end
    end
end

-- Mutate the button color in place (the table identity is shared by every module)
-- and repaint. Widgets not in the registry keep the old color until the next
-- /reload, same as the accent.
function DUI_SetSecondary(r, g, b, a)
    local c = DUI_Theme.Secondary
    c[1], c[2], c[3], c[4] = r, g, b, a or 1
    if DanUIDB then DanUIDB.ButtonColor = { r, g, b, a or 1 } end
    DUI_ApplySecondary()
end

-- First registered wins. The third argument to Fetch is noDefault: without it LSM
-- hands back its own default font for an unknown name, so the fallback never ran.
local DUI_FONT_PREFERENCE = { "Expressway", "Barlow Semi Condensed" }
local function DUI_ResolveFont()
    for _, name in ipairs(DUI_FONT_PREFERENCE) do
        local path = LSM:Fetch("font", name, true)
        if path then return path end
    end
    return "Fonts\\FRIZQT__.TTF"
end

DUI_FontPath = DUI_ResolveFont()

DUI_FontNormal = CreateFont("DUI_FontNormal")
DUI_FontNormal:SetFont(DUI_FontPath, 14, ""); DUI_FontNormal:SetShadowColor(0, 0, 0, 1); DUI_FontNormal:SetShadowOffset(1, -1)

DUI_FontSmall = CreateFont("DUI_FontSmall")
DUI_FontSmall:SetFont(DUI_FontPath, 12, ""); DUI_FontSmall:SetShadowColor(0, 0, 0, 1); DUI_FontSmall:SetShadowOffset(1, -1)

DUI_FontLarge = CreateFont("DUI_FontLarge")
DUI_FontLarge:SetFont(DUI_FontPath, 18, ""); DUI_FontLarge:SetShadowColor(0, 0, 0, 1); DUI_FontLarge:SetShadowOffset(1, -1)

DUI_FontGroup = CreateFont("DUI_FontGroup")
DUI_FontGroup:SetFont(DUI_FontPath, 11, "")

DUI_FontBR = CreateFont("DUI_FontBR")
DUI_FontBR:SetFont(DUI_FontPath, 16, "OUTLINE")

local function RefreshDUIFonts()
    local path = DUI_ResolveFont()
    if path ~= DUI_FontPath then
        DUI_FontPath = path
        DUI_FontNormal:SetFont(path, 14, "")
        DUI_FontSmall:SetFont(path, 12, "")
        DUI_FontLarge:SetFont(path, 18, "")
        DUI_FontGroup:SetFont(path, 11, "")
        DUI_FontBR:SetFont(path, 16, "OUTLINE")
        return true
    end
    return false
end

DUI_EditBackdrop = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    tile = true, tileSize = 16, edgeSize = 2,
    insets = { left = 0, right = 0, top = 0, bottom = 0 }
}

-- The inset a scrollable list sits in. Nine panels each built one of these by
-- hand and they had drifted apart: 0.3 / 0.35 / 0.4 / 0.5 fills, a 1px edge in
-- some and 2px in others, an accent border in six against a secondary one in a
-- seventh. A list is the one element that reads as carved into a panel rather
-- than laid on it, so it is worth having exactly one of.
function DUI_StyleAsListBox(frame)
    frame:SetBackdrop(DUI_EditBackdrop)
    frame:SetBackdropColor(0, 0, 0, 0.35)
    frame:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(frame, "border")
    return frame
end

-- ---- physical-pixel snapping --------------------------------------------
-- The launcher scales 0.6-1.4 on top of whatever UIParent's own scale is, so a
-- length in UI units is almost never a whole number of physical pixels. That
-- matters most in the module rail: rows stacked at a fractional pitch each land
-- on a different sub-pixel phase, and the renderer rounds every edge it draws to
-- the nearest real pixel independently. A checkbox's border and its inner square
-- then round opposite ways on some rows but not others, which reads as a thick
-- top edge on one row and a thick bottom edge three rows down.
--
-- Snapping the pitch and the box geometry to whole pixels puts every row on the
-- same phase, so they all round identically. `even` forces an even pixel count,
-- which is what lets a box centre inside a row without landing on a half pixel.
function DUI_SnapPixels(len, frame, even)
    local scale = frame and frame.GetEffectiveScale and frame:GetEffectiveScale() or 0
    if scale <= 0 then return len end
    local least = even and 2 or 1
    local px = math.floor(len * scale + 0.5)
    if even and px % 2 == 1 then px = px - 1 end
    if px < least then px = least end
    return px / scale
end

-- Checkbox geometry, in UI units: the accent ring, then the dark gap inside it,
-- then the tick fills what is left. Both are snapped to whole physical pixels at
-- draw time, so these are nominal widths rather than exact ones.
local CHECK_EDGE, CHECK_GAP = 2, 2

-- Every checkbox StyleAsPlainCheckbox has touched, so a scale change can re-snap
-- the lot. Checkboxes live for the session, so nothing is ever removed.
DUI_StyledCheckboxes = {}

-- Re-applies a checkbox's whole geometry at whole physical pixels. Split out of
-- StyleAsPlainCheckbox because the right answer changes with the effective scale,
-- which moves when the launcher is rescaled or UIParent's scale changes.
--
-- Everything here is computed in physical pixels and converted back to UI units
-- at the end. A border only reads as a border when both of its edges land on the
-- pixel grid: snapping the box but not the ring inside it just moves the problem.
function DUI_SnapCheckbox(cb)
    if not cb or not cb.duiBoxSize then return end
    local scale = cb:GetEffectiveScale()
    if not scale or scale <= 0 then return end

    local box = math.floor(cb.duiBoxSize * scale + 0.5)
    if box % 2 == 1 then box = box - 1 end -- even, so the box centres in a row on a whole pixel
    if box < 6 then box = 6 end

    local edge = math.max(1, math.floor(CHECK_EDGE * scale + 0.5))
    local gap = math.max(1, math.floor(CHECK_GAP * scale + 0.5))
    -- A 16px box at a low UI scale is around ten real pixels, and a 2+2 ring on
    -- each side would leave nothing in the middle. The tick wins: give up the gap
    -- first, then the ring, rather than shrinking the thing the ring is around.
    while box - 2 * (edge + gap) < 2 and (gap > 1 or edge > 1) do
        if gap > 1 then gap = gap - 1 else edge = edge - 1 end
    end

    cb:SetSize(box / scale, box / scale)

    -- ClearAllPoints before re-anchoring the state textures. The template anchors
    -- those itself, and leaving its points in play over-constrains them: the tick
    -- resolves off-centre, and differently for the normal and checked textures.
    local function Rect(tex, inset)
        if not tex then return end
        inset = inset / scale
        tex:ClearAllPoints()
        tex:SetPoint("TOPLEFT", cb, "TOPLEFT", inset, -inset)
        tex:SetPoint("BOTTOMRIGHT", cb, "BOTTOMRIGHT", -inset, inset)
    end

    Rect(cb.duiBorder, 0)
    Rect(cb.duiFill, edge)
    Rect(cb.GetPushedTexture and cb:GetPushedTexture(), edge + gap)
    Rect(cb.GetNormalTexture and cb:GetNormalTexture(), edge + gap)
    Rect(cb.GetCheckedTexture and cb:GetCheckedTexture(), edge + gap)
end

function DUI_ResnapCheckboxes()
    for i = 1, #DUI_StyledCheckboxes do DUI_SnapCheckbox(DUI_StyledCheckboxes[i]) end
end

function StyleAsPlainCheckbox(cb, size)
    if not cb then return end
    cb.duiBoxSize = size or 22
    cb:SetHitRectInsets(0, 0, 0, 0)

    -- The box is two stacked rectangles, not a Backdrop.
    --
    -- A Backdrop's edgeSize is in UI units and the mixin rounds each of the four
    -- edge strips to physical pixels independently, so at any scale where 2 UI
    -- units is not a whole pixel the ring comes out 1px on some sides and 2px on
    -- others -- and differently again on the next box down the list, because each
    -- one sits at a different sub-pixel offset. That is the "randomly thick" look.
    -- An accent rectangle with a darker one inset into it has four edges we place
    -- ourselves, and DUI_SnapCheckbox snaps every one of them.
    if not cb.duiBorder then
        cb.duiBorder = cb:CreateTexture(nil, "BACKGROUND", nil, -8)
        cb.duiBorder:SetTexture("Interface\\Buttons\\WHITE8X8")
        cb.duiBorder:SetVertexColor(unpack(DUI_Theme.Accent))
        DUI_RegisterAccent(cb.duiBorder, "vertex")

        cb.duiFill = cb:CreateTexture(nil, "BACKGROUND", nil, -7)
        cb.duiFill:SetTexture("Interface\\Buttons\\WHITE8X8")
        cb.duiFill:SetVertexColor(0, 0, 0, 0.7)

        DUI_StyledCheckboxes[#DUI_StyledCheckboxes + 1] = cb
    end

    if cb.GetHighlightTexture and cb:GetHighlightTexture() then
        cb:GetHighlightTexture():SetAlpha(0)
    end

    -- The template's pressed state is the vanilla gold "UI-CheckBox-Down" frame,
    -- which flashed inside our box on every click. Repaint the texture the
    -- template already made rather than calling SetPushedTexture: a fresh texture
    -- would sort above the checked square and hide it while the box is held.
    local pushed = cb:GetPushedTexture()
    if pushed then
        pushed:SetTexture("Interface\\Buttons\\WHITE8X8")
        pushed:SetVertexColor(0.4, 0.4, 0.4, 1)
    end

    local normal = cb:GetNormalTexture()
    normal:SetTexture("Interface\\Buttons\\WHITE8X8")
    normal:SetVertexColor(0.25, 0.25, 0.25, 1) -- Neutral Gray for Unchecked

    local check = cb:GetCheckedTexture()
    check:SetTexture("Interface\\Buttons\\WHITE8X8")
    check:SetVertexColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(check, "vertex")

    DUI_SnapCheckbox(cb)
end

-- UIParent's own scale moves under us -- the Blizzard UI-scale slider, a
-- resolution change, an addon that rescales the whole UI at login -- and every
-- snapped length above is derived from it, so it all has to be recomputed.
local SnapWatcher = CreateFrame("Frame")
SnapWatcher:RegisterEvent("UI_SCALE_CHANGED")
SnapWatcher:RegisterEvent("DISPLAY_SIZE_CHANGED")
SnapWatcher:SetScript("OnEvent", function()
    DUI_ResnapCheckboxes()
    if DUI_SyncUIEnableChecks then DUI_SyncUIEnableChecks() end -- re-snaps the rail's pitch
end)


DUI_Spells = { -- Made global for other modules to access
    Food = {
        [185736]=true, [257413]=true, [257418]=true, [257408]=true, [257422]=true, [259449]=true, [259452]=true, [259448]=true, [259453]=true, [288074]=true,
        [257415]=true, [257420]=true, [257410]=true, [257424]=true, [259455]=true, [259456]=true, [259454]=true, [259457]=true, [288075]=true, [290468]=true,
        [290469]=true, [290467]=true, [285719]=true, [285720]=true, [285721]=true, [286171]=true, [297117]=true, [297118]=true, [297116]=true, [297034]=true,
        [297035]=true, [297039]=true, [297037]=true, [297119]=true, [297040]=true, [382145]=true, [382150]=true, [382146]=true, [382149]=true, [396092]=true,
        [382246]=true, [382247]=true, [382152]=true, [382153]=true, [382157]=true, [382230]=true, [382231]=true, [382232]=true, [382154]=true, [382155]=true,
        [382156]=true, [382234]=true, [382235]=true, [382236]=true,
    },
    Flask = {
        [307187]=true, [307185]=true, [307166]=true, [371339]=true, [374000]=true, [371354]=true, [371204]=true, [370662]=true, [373257]=true, [371386]=true,
        [370652]=true, [371172]=true, [371186]=true, [432021]=true, [432473]=true, [431971]=true, [431972]=true, [431974]=true, [431973]=true, [1236763]=true,
        [1239355]=true, [1235057]=true, [1239755]=true, [1236767]=true, [1235111]=true, [1235110]=true, [1235108]=true,
    },
    Runes = {
        [224001]=true, [270058]=true, [317065]=true, [347901]=true, [367405]=true, [393438]=true, [453250]=true, [1234969]=true, [1242347]=true, [1264426]=true,
    },
    Vantus = {
        [384233]=true, [384234]=true, [384235]=true, [384229]=true, [384228]=true, [384227]=true, [384192]=true, [384203]=true, [384201]=true, [384239]=true,
        [384240]=true, [384241]=true, [384245]=true, [384246]=true, [384247]=true, [384220]=true, [384221]=true, [384222]=true, [384210]=true,
        [384209]=true, [384208]=true, [384214]=true, [384215]=true, [384216]=true, [384154]=true, [384248]=true, [384306]=true,
        [443414]=true, [443407]=true, [443411]=true, [443413]=true, [443412]=true, [443410]=true, [443408]=true, [443409]=true, -- Nerub-ar Palace
    }
}

DUI_RaidBuffs = { -- Made global for other modules to access
    Stamina     = {[21562]=true, [264764]=true},
    Intellect   = {[1459]=true,  [264760]=true},
    AP          = {[6673]=true,  [264761]=true},
    Versatility = {[1126]=true},
    Mastery     = {[462854]=true},
    Movement    = {[381732]=true,[381741]=true,[381746]=true,[381748]=true,[381749]=true,[381750]=true,[381751]=true,[381752]=true,[381753]=true,[381754]=true,[381756]=true,[381757]=true,[381758]=true},
}

-- Global Constants and Utility Functions (used across multiple modules)
SPELL_ID_BREZ = 20484
SPELL_ID_SS = 20707

ICON_STAM = 135987
ICON_INT = 135932
ICON_AP = 132333
ICON_VERS = 136078
ICON_MAST = 4630367
ICON_MOVE = 4622448

-- Unit tokens are looked up rather than concatenated. This is called once per group
-- member by every scanning path in the addon (ready check rows, consumable scans,
-- roster promotions), so at 40 members the old "raid"..index built 40 throwaway
-- strings per pass, on a pass that can run dozens of times during a single ready check.
local RAID_TOKENS, PARTY_TOKENS = {}, {}
for i = 1, 40 do RAID_TOKENS[i] = "raid" .. i end
for i = 1, 4 do PARTY_TOKENS[i] = "party" .. i end

function GetUnitID(index, numMembers)
    numMembers = numMembers or math.max(GetNumGroupMembers(), 1)
    if IsInRaid() then return RAID_TOKENS[index] or ("raid" .. index) end
    if index == numMembers then return "player" end
    return PARTY_TOKENS[index] or ("party" .. index)
end

-- The exact inverse of GetUnitID: which group index a unit token belongs to, or nil
-- if that token is not one this group's indices map onto (a "player" arriving while
-- in a raid, a "party3" in a group of two).
--
-- Handlers that are given a token and need its index used to find it by walking
-- 1..numMembers calling GetUnitID, which at 40 members is 40 IsInRaid calls and 40
-- string compares per event -- on UNIT_AURA, during a ready check, for every aura
-- that ticks on anyone in the raid.
local RAID_INDEX, PARTY_INDEX = {}, {}
for i = 1, 40 do RAID_INDEX[RAID_TOKENS[i]] = i end
for i = 1, 4 do PARTY_INDEX[PARTY_TOKENS[i]] = i end

function DUI_GroupIndexOf(unit, numMembers)
    if not unit then return nil end
    numMembers = numMembers or math.max(GetNumGroupMembers(), 1)
    local index
    if IsInRaid() then
        index = RAID_INDEX[unit]
    elseif unit == "player" then
        index = numMembers
    else
        index = PARTY_INDEX[unit]
        -- In a party the last index is the player, so a partyN claiming it is not
        -- a token GetUnitID would ever have produced.
        if index == numMembers then return nil end
    end
    if index and index <= numMembers then return index end
    return nil
end

-- Every unit token a group member can occupy (player + party1-4 + raid1-40).
-- Never hand this to RegisterUnitEvent directly - see DUI_CreateGroupUnitWatcher.
DUI_GROUP_UNITS = { "player" }
for i = 1, 4 do DUI_GROUP_UNITS[#DUI_GROUP_UNITS + 1] = PARTY_TOKENS[i] end
for i = 1, 40 do DUI_GROUP_UNITS[#DUI_GROUP_UNITS + 1] = RAID_TOKENS[i] end

-- Set form of the above, for handlers that need to test a unit token they were
-- handed. A hash lookup instead of a string pattern match, which matters because
-- the callers sit on UNIT_HEALTH - one of the highest-frequency events in a raid.
DUI_GROUP_UNIT_SET = {}
for _, u in ipairs(DUI_GROUP_UNITS) do DUI_GROUP_UNIT_SET[u] = true end

-- UNIT_* events filtered to the group at the C level. RegisterUnitEvent takes at
-- most TWO unit tokens and silently drops the rest, and a second call on the same
-- frame replaces the filter rather than adding to it - so the old
-- `RegisterUnitEvent(e, unpack(DUI_GROUP_UNITS))` only ever heard player + party1,
-- and nothing at all from a raid member. One frame per pair of tokens is the only
-- way to keep the C-level filter for the whole group (BigWigs does the same, one
-- frame per unit). Plain RegisterEvent would work too, but UNIT_HEALTH/UNIT_AURA
-- then fire for every nameplate and passer-by.
-- Returns an object with :SetRegistered(on); handler gets (self, event, unit, ...).
function DUI_CreateGroupUnitWatcher(events, handler)
    local frames = {}
    for i = 1, #DUI_GROUP_UNITS, 2 do
        local f = CreateFrame("Frame")
        f:SetScript("OnEvent", handler)
        frames[#frames + 1] = { frame = f, u1 = DUI_GROUP_UNITS[i], u2 = DUI_GROUP_UNITS[i + 1] }
    end
    local watcher, on = {}, false
    function watcher:SetRegistered(want)
        want = want and true or false
        if want == on then return end
        on = want
        for _, e in ipairs(frames) do
            if want then
                for _, ev in ipairs(events) do e.frame:RegisterUnitEvent(ev, e.u1, e.u2) end
            else
                e.frame:UnregisterAllEvents()
            end
        end
    end
    return watcher
end


-- Global bridges (functions exposed from other modules)
DUI_ReadyCheckFrame = nil
UpdateRCWindow = nil
DUI_FloatingBar = nil
UpdateFloatingBar = nil
DUI_HideFloatingBar = nil
DUI_GroupsPopout = nil
RG_Update = nil
ToggleBRTracker = nil
DUI_SplitRoster = nil
DUI_OpenAssistConfig = nil
DUI_RefreshAssistList = nil
DUI_OpenInvitesConfig = nil
DUI_OpenBattleResTrackerConfig = nil
DUI_OpenFloatingButtonsConfig = nil
DUI_OpenRaidAutomationConfig = nil
DUI_InitRaidAutomation = nil
DUI_InitTimeline = nil
DUI_OpenTimelineConfig = nil
DUI_InitBreakTimer = nil
DUI_OpenBreakTimerConfig = nil
DUI_GuildBankSortConfig = nil
DUI_OpenGuildBankSortConfig = nil
DUI_InitGuildBankSort = nil
DUI_WarbankGoldConfig = nil
DUI_OpenWarbankGoldConfig = nil
DUI_InitWarbankGold = nil
DUI_GuildBankRestockConfig = nil
DUI_OpenGuildBankRestockConfig = nil
DUI_InitGuildBankRestock = nil
DUI_OpenAutoPayoutConfig = nil
DUI_InitAutoPayout = nil
DUI_InitAutomation = nil
DUI_OpenAutomationConfig = nil
DUI_InitLFGFilter = nil
DUI_OpenLFGFilterConfig = nil

-- Global UI Component Helpers

-- Standard hover tooltip for a config widget. `tip` is either a plain string
-- (used as the body, with `title` for the heading) or a table {title, body, note}.
-- Config panels sit in the TOOLTIP strata, so the tooltip has to be lifted above
-- the owner's frame level or it renders behind the panel.
function DUI_AddTooltip(widget, title, tip)
    if not widget or not tip then return end
    local body, note
    if type(tip) == "table" then
        title, body, note = tip.title or title, tip.body or tip[1], tip.note or tip[2]
    else
        body = tip
    end
    widget:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetFrameStrata("TOOLTIP")
        GameTooltip:SetFrameLevel(self:GetFrameLevel() + 50)
        -- The first line always goes through SetText so the tooltip is reset even
        -- for an untitled widget; AddLine alone can append to whatever was there.
        if title then
            GameTooltip:SetText(title, 1, 1, 1)
            if body then GameTooltip:AddLine(body, 0.8, 0.8, 0.8, true) end
        elseif body then
            GameTooltip:SetText(body, 0.9, 0.9, 0.9, 1, true)
        end
        if note then GameTooltip:AddLine(note, 0.6, 0.6, 0.6, true) end
        GameTooltip:Show()
    end)
    widget:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- ---- Settings search index ------------------------------------------------
-- The launcher's search box used to match module titles only, so finding a
-- setting meant already knowing which of the 22 modules owned it. Every labelled
-- widget the constructors below build registers itself here, keyed by the config
-- frame it lands in, and the rail searches that as well as the module name.
--
-- Harvested in the constructors rather than by walking a finished panel: panels
-- build lazily on first open, and their contents are a mix of frames and bare
-- FontStrings with no common child list to walk.
DUI_SearchIndex = {}

-- Nearest registered config frame above `frame`, falling back to the outermost
-- named ancestor. The registry is checked first because a docked panel's parent
-- chain continues up into DUI_MainFrame, and a widget built (or rebuilt) while
-- its panel is docked would otherwise be filed under the launcher window.
local searchOwners, searchOwnerCount
local function SearchOwnerName(frame)
    -- Tolerates a nil registry: this file's own constructors are defined above
    -- the table they read, and the count check rebuilds the set as panels
    -- register, so an early call cannot cache an empty one for good.
    local registry = DUI_ConfigRegistry or {}
    if not searchOwners or searchOwnerCount ~= #registry then
        searchOwners, searchOwnerCount = {}, #registry
        for _, e in ipairs(registry) do searchOwners[e.f] = true end
    end
    local outermost
    while frame and frame ~= UIParent do
        local name = frame.GetName and frame:GetName()
        if name then
            if searchOwners[name] then return name end
            outermost = name
        end
        frame = frame.GetParent and frame:GetParent()
    end
    return outermost
end

-- Flattens whatever DUI_AddTooltip accepts into one searchable string, so typing
-- "modifier" finds the option whose body text is the only place the word appears.
local function SearchTipText(tip)
    if type(tip) == "string" then return tip end
    if type(tip) == "table" then
        return (tip.title or "") .. " " .. (tip.body or tip[1] or "") .. " " .. (tip.note or tip[2] or "")
    end
    return ""
end

-- `widget` is what a search hit scrolls to and flashes; a paragraph passes none,
-- because it is worth matching but has no name worth listing as a result.
-- `kind` "text" is searched but never listed; anything else is a named result.
function DUI_IndexSearchEntry(parent, label, widget, tip, kind)
    if type(label) ~= "string" or label == "" then return end
    local owner = SearchOwnerName(parent)
    if not owner then return end
    local list = DUI_SearchIndex[owner]
    if not list then list = {}; DUI_SearchIndex[owner] = list end
    -- A couple of panels re-run their layout on Refresh(); without this the same
    -- label would stack up a fresh result row on every rebuild.
    for _, e in ipairs(list) do
        if e.label == label and e.kind == (kind or "option") then
            e.widget = widget or e.widget
            return e
        end
    end
    local entry = {
        label    = label,
        kind     = kind or "option",
        widget   = widget,
        haystack = (label .. " " .. SearchTipText(tip)):lower(),
    }
    list[#list + 1] = entry
    return entry
end

function DUI_CreateHeader(parent, text, yOffset)
    local h = parent:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
    h:SetPoint("TOPLEFT", 20, yOffset); h:SetText(text)
    if DUI_Theme then h:SetTextColor(unpack(DUI_Theme.Accent)) end
    DUI_RegisterAccent(h, "text")
    DUI_IndexSearchEntry(parent, text, h, nil, "header")
    return h
end

function DUI_CreateCheckbox(parent, label, yOffset, dbTable, key, onUpdateFunc, tooltip)
    local cb = CreateFrame("CheckButton", nil, parent, "ChatConfigCheckButtonTemplate, BackdropTemplate")
    cb:SetPoint("TOPLEFT", 40, yOffset); cb.Text:SetText(label)
    StyleAsPlainCheckbox(cb)
    -- The template anchors the label overlapping the box on this client; place it clear to the right.
    cb.Text:ClearAllPoints()
    cb.Text:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    cb.Text:SetJustifyH("LEFT")
    cb:SetScript("OnClick", function(self)
        dbTable[key] = self:GetChecked()
        if onUpdateFunc then onUpdateFunc(self:GetChecked()) end
    end)
    DUI_AddTooltip(cb, label, tooltip)
    DUI_IndexSearchEntry(parent, label, cb, tooltip)
    return cb
end

function DUI_CreateColorButton(parent, label, yOffset, dbTable, key, onUpdateFunc, tooltip)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(20, 20); btn:SetPoint("TOPLEFT", 40, yOffset)
    btn:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
    local text = btn:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
    text:SetPoint("LEFT", btn, "RIGHT", 10, 0); text:SetText(label)
    btn.label = text
    btn:SetScript("OnClick", function()
        local color = dbTable[key]
        local r, g, b, a = color[1], color[2], color[3], color[4] or 1
        ColorPickerFrame:SetupColorPickerAndShow({
            swatchFunc = function()
                local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                local na = ColorPickerFrame:GetColorAlpha()
                dbTable[key] = {nr, ng, nb, na}
                btn:SetBackdropColor(nr, ng, nb, na)
                if onUpdateFunc then onUpdateFunc() end
            end,
            hasOpacity = true, opacity = a, r = r, g = g, b = b
        })
    end)
    DUI_AddTooltip(btn, label, tooltip)
    DUI_IndexSearchEntry(parent, label, btn, tooltip)
    return btn
end

-- ---- Canonical panel size ------------------------------------------------
-- Every config panel is built to the docking pane's inner area rather than to
-- whatever size its content happened to need. Panels used to range from 320x220
-- to 560x600, and in the pane a small one read as a little window floating in an
-- empty one -- content clustered in the top-left corner of a much larger box.
--
-- Width is fixed: narrower leaves a void, wider is clipped by the pane. Height is
-- a floor, so a panel with genuinely more content than fits (Castbar, Frame Mover)
-- still gets its room and scrolls instead of being squashed.
--
-- The launcher's PANE_W adds the 16px scrollbar gutter on top of this.
DUI_PANEL_W, DUI_PANEL_H = 560, 580

-- Config frame registry: every module's config popout frame + its UI-tab button.
-- Populated by DUI_CreateConfigFrame; seeded here with the legacy Tools-tab frames
-- that build their own chrome instead of using the factory.
DUI_ConfigRegistry = {
    { f = "DUI_AssistConfig",        b = "DUI_AssistBtn_Tools" },
    { f = "DUI_GroupsPopout",        b = "DUI_RaidGroupsBtn_Tools" },
    -- GuildBankSort and AutoPayout register themselves via DUI_CreateConfigFrame.
}

function DUI_RegisterConfig(frameName, btnName)
    table.insert(DUI_ConfigRegistry, { f = frameName, b = btnName })
end

-- Ensures DanUIDB[key] exists and backfills any default keys missing from
-- existing saved variables. Returns the module's DB table.
function DUI_InitModuleDB(key, defaultsFunc)
    DanUIDB[key] = DanUIDB[key] or {}
    for k, v in pairs(defaultsFunc()) do
        if DanUIDB[key][k] == nil then DanUIDB[key][k] = v end
    end
    return DanUIDB[key]
end

-- Hide every registered config frame and reset its button border to black.
function DUI_HideAllConfigs()
    for _, e in ipairs(DUI_ConfigRegistry) do
        local frame = _G[e.f]
        if frame then frame:Hide() end
        local btn = e.b and _G[e.b]
        if btn and btn.SetBackdropBorderColor then btn:SetBackdropBorderColor(0, 0, 0, 1) end
    end
end

-- "Is this module's config panel open?", for the modules that put a draggable
-- placeholder on screen while theirs is. It has to be IsVisible, not IsShown:
-- a docked panel is a child of DUI_MainFrame, so closing the window (Esc, or the
-- corner X) leaves the panel's own shown flag set even though nothing is on
-- screen. The panel's OnHide still fires -- the client dispatches it when an
-- ancestor hides too -- and every one of those handlers re-runs the module's
-- appearance pass, which read IsShown, concluded the panel was still open, and
-- put the drag anchor straight back. IsVisible walks the parent chain, so it
-- goes false the moment the window does.
function DUI_IsConfigOpen(name)
    local f = _G[name]
    return (f and f:IsVisible()) and true or false
end

-- Config panel positions. A panel that has never been dragged parks itself beside
-- the main window; once it has been moved, that spot is what it reopens at, so a
-- layout you arranged survives closing the panel and reloading.
--
-- A dragged position is stored as an offset from DUI_MainFrame, not as screen
-- coordinates. Screen coordinates looked right until you moved the main window:
-- the panel stayed behind, because dragging it once swapped its live anchor on
-- DUI_MainFrame for a dead one on UIParent. Keeping the anchor on the main window
-- means every panel travels with it whether or not you have ever dragged it.
-- Entries missing `anchor` are pre-fix screen coordinates and are ignored, so a
-- panel saved under the old scheme falls back to its default spot beside the
-- window and re-saves in the new form the next time you drag it.
function DUI_SaveConfigPosition(frame)
    local name = frame:GetName()
    if not (name and DanUIDB) then return end
    DanUIDB.ConfigPos = DanUIDB.ConfigPos or {}

    -- Offsets are measured TOPLEFT-to-TOPLEFT: unlike CENTER, that stays put when
    -- a panel changes height, which several of these do as their lists grow.
    if DUI_MainFrame and frame:GetLeft() and DUI_MainFrame:GetLeft() then
        DanUIDB.ConfigPos[name] = {
            anchor   = "main",
            point    = "TOPLEFT",
            relPoint = "TOPLEFT",
            x        = frame:GetLeft() - DUI_MainFrame:GetLeft(),
            y        = frame:GetTop() - DUI_MainFrame:GetTop(),
        }
        return
    end

    local point, _, relPoint, x, y = frame:GetPoint()
    if not point then return end
    DanUIDB.ConfigPos[name] = { point = point, relPoint = relPoint, x = x, y = y }
end

function DUI_RestoreConfigPosition(frame)
    local name = frame:GetName()
    local saved = name and DanUIDB and DanUIDB.ConfigPos and DanUIDB.ConfigPos[name]
    frame:ClearAllPoints()
    if saved and saved.anchor == "main" and DUI_MainFrame then
        frame:SetPoint(saved.point, DUI_MainFrame, saved.relPoint, saved.x, saved.y)
    elseif DUI_MainFrame then
        frame:SetPoint("RIGHT", DUI_MainFrame, "LEFT", -5, 0)
    else
        frame:SetPoint("CENTER")
    end
end

-- Escape hatch: send every panel back to its default spot beside the main window.
function DUI_ResetConfigPositions()
    if DanUIDB then DanUIDB.ConfigPos = nil end
    for _, e in ipairs(DUI_ConfigRegistry) do
        local f = _G[e.f]
        if f and f:IsShown() then DUI_RestoreConfigPosition(f) end
    end
    print("|cFF00FF00[DUI]|r Config panel positions reset.")
end

-- Builds the standard DUI config popout: backdrop, close button, title, anchoring to
-- the main frame, and button-border highlighting. opts.onShow / opts.onHide are optional
-- extra callbacks run after the standard show/hide logic. Returns the config frame.
-- width is accepted for call-site documentation and then ignored: every panel is
-- DUI_PANEL_W wide so it fills the pane exactly. height is a minimum -- a module
-- that asks for more keeps it, and one that asks for less is grown to the pane.
function DUI_CreateConfigFrame(name, title, width, height, btnName, opts)
    opts = opts or {}
    local config = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    config:SetFrameStrata("TOOLTIP")
    config:SetSize(DUI_PANEL_W, math.max(height or 0, DUI_PANEL_H))
    config:SetPoint("CENTER")
    config:SetClampedToScreen(true)
    config:SetMovable(true); config:EnableMouse(true); config:RegisterForDrag("LeftButton")
    config:SetScript("OnDragStart", config.StartMoving)
    config:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); DUI_SaveConfigPosition(self) end)
    config:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
    config:SetBackdropColor(unpack(DUI_Theme.MainBG)); config:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(config, "border")
    DUI_RegisterMainBG(config, "bg")
    DUI_AddDropShadow(config)
    config:Hide()

    local closeBtn = CreateFrame("Button", nil, config, "BackdropTemplate")
    closeBtn:SetSize(20, 20); closeBtn:SetPoint("TOPRIGHT", -5, -5)
    StyleAsCloseButton(closeBtn)
    closeBtn:SetScript("OnClick", function() config:Hide() end)
    -- Held so the launcher can hide it while the panel is docked: in the dock the
    -- window's own close button is the one that closes things, and a second X
    -- inside the pane just empties it.
    config.closeBtn = closeBtn

    tinsert(UISpecialFrames, name)

    config.title = config:CreateFontString(nil, "OVERLAY", "DUI_FontLarge")
    config.title:SetPoint("TOP", 0, -10); config.title:SetText(title or "")
    DUI_AddTitleChrome(config)

    config:HookScript("OnShow", function(self)
        -- OnShow is queued, not run inside Show(): the client dispatches it after
        -- the calling code has returned. A panel shown and hidden again in the
        -- same frame -- which is exactly what the launcher's index warm-up does --
        -- still gets here, with the panel already off screen and the launcher's
        -- `docking` guard already reset. Both lines below then misfire:
        -- UIFrameFadeIn calls Show() and puts the panel back on screen, and
        -- RestoreConfigPosition anchors it beside the window, which is how a
        -- warmed panel ended up floating there on the first /dan of a session.
        if not self:IsShown() then return end
        UIFrameFadeIn(self, 0.12, 0, 1)
        DUI_RestoreConfigPosition(self)
        local btn = btnName and _G[btnName]
        if btn and btn.SetBackdropBorderColor then btn:SetBackdropBorderColor(unpack(DUI_Theme.Accent)) end
        if opts.onShow then opts.onShow(self) end
    end)
    config:HookScript("OnHide", function(self)
        local btn = btnName and _G[btnName]
        if btn and btn.SetBackdropBorderColor then btn:SetBackdropBorderColor(0, 0, 0, 1) end
        if DUI_HideScrollDropdown then DUI_HideScrollDropdown() end
        if opts.onHide then opts.onHide(self) end
    end)

    DUI_RegisterConfig(name, btnName)
    return config
end

-- Window close button. Deliberately the quietest control in the window: a solid
-- accent fill made "close" the highest-emphasis thing on screen, out-shouting the
-- module buttons that are the actual reason the window is open. Neutral at rest,
-- red on hover, so it still reads as the destructive corner control.
function StyleAsCloseButton(btn)
    btn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    btn:SetBackdropColor(0.18, 0.18, 0.18, 0.9)
    btn:SetBackdropBorderColor(0, 0, 0, 1)

    btn:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
    local hl = btn:GetHighlightTexture()
    if hl then
        hl:SetVertexColor(0.8, 0.25, 0.25, 0.55)
        hl:ClearAllPoints(); hl:SetPoint("TOPLEFT", 1, -1); hl:SetPoint("BOTTOMRIGHT", -1, 1)
    end

    local x = btn:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
    x:SetPoint("CENTER"); x:SetText("X"); x:SetTextColor(0.75, 0.75, 0.75)
    btn:HookScript("OnEnter", function() x:SetTextColor(1, 1, 1) end)
    btn:HookScript("OnLeave", function() x:SetTextColor(0.75, 0.75, 0.75) end)
    return x
end

function StyleAsTealTab(btn)
    btn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", tile = true, tileSize = 16, edgeSize = 1, insets = { left = 0, right = 0, top = 0, bottom = 0 } })
    btn:SetBackdropColor(unpack(DUI_Theme.Secondary)); btn:SetBackdropBorderColor(0, 0, 0, 1)
    DUI_RegisterSecondary(btn, "bg")
    btn:SetNormalFontObject(DUI_FontSmall)
    btn:SetHighlightFontObject(DUI_FontSmall)
    btn:SetPushedTextOffset(0, 0)

    -- Hover glow: a translucent accent overlay driven by the button's built-in
    -- highlight state, so it adds feedback without clobbering any OnEnter/OnLeave
    -- the caller sets. Accent = interactive affordance; the gray body = idle.
    btn:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
    local hl = btn:GetHighlightTexture()
    if hl then
        hl:SetVertexColor(DUI_Theme.Accent[1], DUI_Theme.Accent[2], DUI_Theme.Accent[3], 0.22)
        hl:ClearAllPoints(); hl:SetPoint("TOPLEFT", 1, -1); hl:SetPoint("BOTTOMRIGHT", -1, 1)
    end
    -- Press feedback: a subtle darken while the button is held down.
    btn:SetPushedTexture("Interface\\Buttons\\WHITE8X8")
    local pt = btn:GetPushedTexture()
    if pt then
        pt:SetVertexColor(0, 0, 0, 0.25)
        pt:ClearAllPoints(); pt:SetPoint("TOPLEFT", 1, -1); pt:SetPoint("BOTTOMRIGHT", -1, 1)
    end
end

-- Destructive-action button: same shape as a teal tab but a muted-red body and a
-- red hover glow, so "delete / cancel" reads differently from normal actions.
function StyleAsDangerButton(btn)
    StyleAsTealTab(btn)
    -- StyleAsTealTab just put this button in the button-color registry; red is not
    -- a themed body, so drop it back out before painting over the grey.
    DUI_ExemptSecondary(btn)
    btn:SetBackdropColor(0.6, 0.18, 0.18, 1)
    local hl = btn:GetHighlightTexture()
    if hl then hl:SetVertexColor(1, 0.35, 0.35, 0.25) end
end

-- Title-bar chrome: a subtle dark strip behind the title plus an accent divider
-- under it. Gives every window a clear header, applied by the config factory and the
-- main frame so the whole suite matches.
function DUI_AddTitleChrome(frame)
    local strip = frame:CreateTexture(nil, "BORDER")
    strip:SetTexture("Interface\\Buttons\\WHITE8X8")
    strip:SetVertexColor(0, 0, 0, 0.25)
    strip:SetPoint("TOPLEFT", 2, -2)
    strip:SetPoint("TOPRIGHT", -2, -2)
    strip:SetHeight(28)

    local divider = frame:CreateTexture(nil, "ARTWORK")
    divider:SetTexture("Interface\\Buttons\\WHITE8X8")
    divider:SetVertexColor(unpack(DUI_Theme.Accent))
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", 6, -32)
    divider:SetPoint("TOPRIGHT", -6, -32)
    DUI_RegisterAccent(divider, "vertex")
    return divider
end

-- Soft elevation shadow: a dark halo peeking out on every edge, drawn behind the
-- frame's own background so windows read as lifted off the game world.
function DUI_AddDropShadow(frame, size, alpha)
    size = size or 6
    local s = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    s:SetTexture("Interface\\Buttons\\WHITE8X8")
    s:SetVertexColor(0, 0, 0, alpha or 0.3)
    s:SetPoint("TOPLEFT", -size, size)
    s:SetPoint("BOTTOMRIGHT", size, -size)
    return s
end

-- Scrollable region: a ScrollFrame plus the thin accent-thumbed slider this addon
-- uses everywhere instead of Blizzard's chrome. The same fifteen lines were
-- hand-copied into the dropdown, the payout list, the bank pages and the rule
-- list; the launcher needs two more, so it lives here now.
--
-- Returns the scroll frame, its content child, and the bar. Call
-- area:Update(contentHeight) after resizing the content: it sizes the bar's range
-- and hides it outright when everything already fits, so a short list has no
-- vestigial track sitting beside it.
function DUI_CreateScrollArea(parent)
    local area = CreateFrame("Frame", nil, parent)

    local sf = CreateFrame("ScrollFrame", nil, area)
    sf:SetPoint("TOPLEFT", 0, 0)
    sf:SetPoint("BOTTOMRIGHT", -16, 0)

    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(1, 1)
    sf:SetScrollChild(content)

    local sb = CreateFrame("Slider", nil, area, "BackdropTemplate")
    sb:SetWidth(12)
    sb:SetPoint("TOPRIGHT", 0, 0); sb:SetPoint("BOTTOMRIGHT", 0, 0)
    sb:SetBackdrop(DUI_EditBackdrop); sb:SetBackdropColor(0, 0, 0, 0.5)
    sb:SetBackdropBorderColor(0, 0, 0, 1)
    sb:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
    sb:GetThumbTexture():SetSize(10, 40)
    sb:GetThumbTexture():SetVertexColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(sb:GetThumbTexture(), "vertex")
    sb:SetMinMaxValues(0, 0); sb:SetValueStep(1); sb:SetObeyStepOnDrag(true)
    sb:SetValue(0)
    sb:SetScript("OnValueChanged", function(self, value) sf:SetVerticalScroll(value) end)

    -- The wheel is bound on the scroll frame, but a mouse-enabled child (a docked
    -- panel, a row button) swallows it, so the outer frame carries it too.
    local function wheel(_, delta) sb:SetValue(sb:GetValue() - delta * 30) end
    sf:EnableMouseWheel(true); sf:SetScript("OnMouseWheel", wheel)
    area:EnableMouseWheel(true); area:SetScript("OnMouseWheel", wheel)

    area.scroll, area.content, area.bar = sf, content, sb

    function area:Update(contentHeight)
        local visible = self:GetHeight()
        local maxScroll = math.max(0, (contentHeight or 0) - visible)
        sb:SetMinMaxValues(0, maxScroll)
        if maxScroll > 0 then
            sb:Show()
            sf:SetPoint("BOTTOMRIGHT", -16, 0)
        else
            sb:SetValue(0)
            sf:SetVerticalScroll(0)
            sb:Hide()
            -- Reclaim the gutter when there is nothing to scroll.
            sf:SetPoint("BOTTOMRIGHT", 0, 0)
        end
    end

    return area
end

-- Thin accent divider line for separating sections inside a panel.
function DUI_CreateSeparator(parent, yOffset, inset)
    inset = inset or 20
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetTexture("Interface\\Buttons\\WHITE8X8")
    line:SetVertexColor(DUI_Theme.Accent[1], DUI_Theme.Accent[2], DUI_Theme.Accent[3], 0.30)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", inset, yOffset)
    line:SetPoint("TOPRIGHT", -inset, yOffset)
    DUI_RegisterAccent(line, "vertex")
    return line
end

-- ---- Dropdown control ----------------------------------------------------
-- Every "menu" in DUI used to be a plain teal-tab button whose text happened to
-- read "Label: value", which made it indistinguishable from an action button
-- ("Texture: Blizzard" and "Test Cast" were the same widget). A dropdown gets its
-- own shape instead: a sunken field like an edit box, the label pinned left, the
-- current value right-aligned, and a caret marking it as something that opens a list.

local function ApplyCaretArt(tex)
    -- Prefer a modern atlas; fall back to the long-standing arrow texture on
    -- clients that don't have it (same approach as the floating bar's icon).
    local candidates = { "common-dropdown-icon-arrow-down", "uitools-icon-chevron-down" }
    if C_Texture and C_Texture.GetAtlasInfo then
        for _, atlas in ipairs(candidates) do
            if C_Texture.GetAtlasInfo(atlas) then
                tex:SetAtlas(atlas)
                return
            end
        end
    end
    tex:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    -- The old arrow art carries a lot of transparent padding and sits high.
    tex:SetTexCoord(0.1, 0.9, 0.45, 0.95)
end

-- label:   text shown on the left of the field (nil for a value-only field)
-- opts:    { width, height, tooltip, indent, justify }
-- Returns the button; set the displayed value with btn:SetValue("...").
function DUI_CreateDropdown(parent, label, opts)
    opts = opts or {}
    local btn = CreateFrame("Button", opts.name, parent, "BackdropTemplate")
    btn:SetSize(opts.width or 180, opts.height or 24)
    btn:SetBackdrop(DUI_EditBackdrop)
    btn:SetBackdropColor(0, 0, 0, 0.5)
    btn:SetBackdropBorderColor(unpack(DUI_Theme.Secondary))
    DUI_RegisterSecondary(btn, "border")

    local caret = btn:CreateTexture(nil, "OVERLAY")
    caret:SetSize(10, 10)
    caret:SetPoint("RIGHT", -6, 0)
    -- Art first: SetAtlas can reset the vertex colour, so tinting has to follow it.
    ApplyCaretArt(caret)
    caret:SetVertexColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(caret, "vertex")

    local labelFS
    if label then
        labelFS = btn:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
        labelFS:SetPoint("LEFT", 7, 0)
        labelFS:SetJustifyH("LEFT")
        labelFS:SetWordWrap(false)
        labelFS:SetTextColor(0.7, 0.7, 0.7)
        labelFS:SetText(label)
    end

    -- The value takes whatever room the label leaves, right-aligned against the
    -- caret, and clips rather than wrapping -- LibSharedMedia names get long.
    local valueFS = btn:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    valueFS:SetPoint("LEFT", labelFS or btn, labelFS and "RIGHT" or "LEFT", labelFS and 8 or 7, 0)
    valueFS:SetPoint("RIGHT", caret, "LEFT", -4, 0)
    valueFS:SetJustifyH(opts.justify or "RIGHT")
    valueFS:SetWordWrap(false)
    valueFS:SetTextColor(1, 1, 1)

    -- Hover: accent the border and the caret, so the field reads as live.
    btn:HookScript("OnEnter", function(self)
        self:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
        caret:SetVertexColor(1, 1, 1)
    end)
    btn:HookScript("OnLeave", function(self)
        self:SetBackdropBorderColor(unpack(DUI_Theme.Secondary))
        caret:SetVertexColor(unpack(DUI_Theme.Accent))
    end)

    btn.label, btn.value, btn.caret = labelFS, valueFS, caret
    function btn:SetValue(text) valueFS:SetText(text or "") end
    function btn:GetValue() return valueFS:GetText() end
    function btn:SetLabel(text) if labelFS then labelFS:SetText(text or "") end end

    DUI_AddTooltip(btn, label, opts.tooltip)
    DUI_IndexSearchEntry(parent, label, btn, opts.tooltip)
    return btn
end

-- ---- Panel layout cursor -------------------------------------------------
-- Config panels used to position every widget with a hand-picked negative offset,
-- so one panel could carry four different vertical rhythms and inserting an option
-- meant renumbering everything below it. The cursor owns the spacing instead:
-- each Add* call places the widget at the current Y and advances by that widget's
-- own step. Panels that need a bespoke layout can still read/set the cursor.

DUI_LAYOUT = {
    TOP        = 40,  -- clears the title chrome
    INDENT     = 40,  -- standard control indent
    TEXT_INSET = 25,  -- wrapped paragraphs sit slightly wider than controls
    HEADER     = 30,  -- header -> first control under it (also clears the card's top edge)
    SECTION    = 18,  -- extra breathing room above a header (not the first)
    ROW        = 28,  -- checkbox / dropdown / colour row
    SLIDER     = 42,  -- slider row, including the caption above its track
    SLIDER_CAP = 12,  -- OptionsSliderTemplate draws its caption above the track,
                      -- so the track is pushed down to leave room for it
    BOTTOM     = 16,  -- padding under the last widget when a panel self-sizes
    EDGE       = 20,  -- padding kept clear on the right of a column
    CARD       = 0.035, -- fill alpha of a section card (0 turns cards off entirely)
    CARD_EDGE  = 0.09,  -- alpha of the card's hairline outline
    CARD_PAD   = 9,     -- gap between the card's top edge and the first widget inside it.
                        -- There is no matching bottom constant: a row's step already
                        -- includes its trailing gap, so the card ends at the cursor.
}

local LayoutMixin = {}
LayoutMixin.__index = LayoutMixin

function LayoutMixin:Y() return -self.y end
function LayoutMixin:SetY(v) self.y = math.abs(v) end
function LayoutMixin:Gap(n) self.y = self.y + (n or DUI_LAYOUT.SECTION) end
function LayoutMixin:Height() return self.y end

-- ---- columns -------------------------------------------------------------
-- Panels are built to the full width of the docking pane, which is far wider than
-- the single 40px-indented column they were all authored as. A column is treated
-- as a virtual frame: switching to column 2 just shifts the cursor's x origin, so
-- every widget keeps the same indent it has always had relative to its own column
-- and no factory needs to know columns exist.
--
-- Each column carries its own vertical cursor, so you can fill the left one, jump
-- right, and fill that one from the top.

function LayoutMixin:Columns(n)
    n = n or 2
    local pitch = self.frame:GetWidth() / n
    self.cols = {}
    for i = 1, n do
        -- Column 1 continues whatever the cursor was already doing, so a panel can
        -- lay out a full-width block and then split: it inherits the header count
        -- (which decides whether the next header gets a gap above it) and any card
        -- still open. The rest start clean.
        self.cols[i] = {
            x       = (i - 1) * pitch,
            y       = self.y,
            headers = (i == 1) and self.headerCount or 0,
            card    = (i == 1) and self.card or nil,
        }
    end
    self.pitch = pitch
    self.col = 1
    self.x, self.w = 0, pitch
    return self
end

function LayoutMixin:Column(i)
    if not (self.cols and self.cols[i]) then return self end
    -- Park everything about the column being left, so returning to it later picks
    -- up exactly where it stopped.
    local from = self.cols[self.col]
    from.y, from.headers, from.card = self.y, self.headerCount, self.card

    local to = self.cols[i]
    self.col = i
    self.x, self.w = to.x, self.pitch
    self.y, self.headerCount, self.card = to.y, to.headers, to.card
    return self
end

function LayoutMixin:NextColumn() return self:Column((self.col or 1) + 1) end

-- Back to one full-width column, starting below the tallest of the columns just
-- laid out. For a panel that splits its options two-up and then wants a list or a
-- paragraph spanning the whole pane underneath them.
function LayoutMixin:EndColumns()
    if not self.cols then return self end
    self.cols[self.col].y = self.y
    self.cols[self.col].headers = self.headerCount
    self.cols[self.col].card = self.card
    local y, headers = 0, 0
    for _, c in ipairs(self.cols) do
        if c.y > y then y = c.y end
        headers = headers + c.headers
    end
    self.cols, self.pitch, self.col = nil, nil, nil
    self.x, self.w = 0, self.frame:GetWidth()
    -- Each column's card was grown in place as that column was filled, so there is
    -- nothing to close here; the full-width cursor just resumes without one.
    self.y, self.headerCount, self.card = y, headers, nil
    return self
end

-- Room a widget has between its indent and the right edge of its column.
function LayoutMixin:ContentWidth(indent)
    return math.max(self.w - (indent or DUI_LAYOUT.INDENT) - DUI_LAYOUT.EDGE, 40)
end

-- ---- internals -----------------------------------------------------------

-- Re-anchors a factory-built widget into the current column. The factories anchor
-- to a hardcoded x, which is correct for a single-column panel and is exactly the
-- offset a column wants added to its own origin.
function LayoutMixin:Anchor(widget, indent, yOffset)
    widget:ClearAllPoints()
    widget:SetPoint("TOPLEFT", self.x + indent, -(yOffset or self.y))
    return widget
end

-- ---- section cards -------------------------------------------------------
-- Rows used to be zebra-striped: a lighter band behind every other control. That
-- reads as a dense settings list, which is what a tall standalone panel wanted --
-- but every panel docks into the one main window now, and a four-row panel there is
-- mostly empty space with two grey bars floating in it. Worse, the pattern landed
-- differently in every module, because what it looked like depended on how many
-- rows each section happened to have.
--
-- A section is drawn as a single card instead: one soft fill with a hairline
-- outline, running from the first widget under a header to the last. Two rows or
-- ten, a section reads as one block, and every module's panel gets the same shape
-- without asking for it. Headers sit above their card rather than inside it, so the
-- accent label still reads as the thing that names the block.
--
-- The card grows as the cursor advances rather than being sized when its section
-- ends, because there is no reliable "ends": a panel can stop mid-section and hand
-- the cursor's Y to hand-rolled content (CastbarModule's tab strip does exactly
-- that), and nothing would ever close the last card. A card that is never advanced
-- past simply stays hidden.

local function CardTexture(frame, sublevel, alpha)
    -- Sublevels 1/2: above the frame's own backdrop fill and the drop shadow (-8),
    -- below everything the panel puts in ARTWORK and up.
    local t = frame:CreateTexture(nil, "BACKGROUND", nil, sublevel)
    t:SetTexture("Interface\\Buttons\\WHITE8X8")
    t:SetVertexColor(1, 1, 1, alpha)
    t:Hide()
    return t
end

-- A card on its own, for panels that are not a vertical list of rows and so have
-- no layout cursor to open one for them -- Groups draws one behind each of its
-- eight group columns. Every offset is measured from `frame`'s TOPLEFT, with `top`
-- and `bottom` counted downwards. Omit `bottom` to size it later with :SetBottom,
-- which is how the cursor grows a section as it fills.
function DUI_CreateCard(frame, left, top, right, bottom)
    if DUI_LAYOUT.CARD <= 0 then return nil end
    local card = { frame = frame, left = left, top = top, right = right }
    card.fill = CardTexture(frame, 1, DUI_LAYOUT.CARD)
    card.fill:SetPoint("TOPLEFT", frame, "TOPLEFT", left, -top)
    -- The outline anchors to the fill, so growing the card downwards is one SetPoint
    -- on the fill and the four hairlines follow it.
    local edges = {}
    for i = 1, 4 do edges[i] = CardTexture(frame, 2, DUI_LAYOUT.CARD_EDGE) end
    local eTop, eBottom, eLeft, eRight = unpack(edges)
    eTop:SetHeight(1)
    eTop:SetPoint("TOPLEFT", card.fill, "TOPLEFT")
    eTop:SetPoint("TOPRIGHT", card.fill, "TOPRIGHT")
    eBottom:SetHeight(1)
    eBottom:SetPoint("BOTTOMLEFT", card.fill, "BOTTOMLEFT")
    eBottom:SetPoint("BOTTOMRIGHT", card.fill, "BOTTOMRIGHT")
    eLeft:SetWidth(1)
    eLeft:SetPoint("TOPLEFT", card.fill, "TOPLEFT")
    eLeft:SetPoint("BOTTOMLEFT", card.fill, "BOTTOMLEFT")
    eRight:SetWidth(1)
    eRight:SetPoint("TOPRIGHT", card.fill, "TOPRIGHT")
    eRight:SetPoint("BOTTOMRIGHT", card.fill, "BOTTOMRIGHT")
    card.edges = edges

    function card:SetBottom(y)
        -- Nothing has been laid out in it yet: leave it hidden rather than draw a
        -- sliver. This is what keeps an empty section from showing an outline.
        if y <= self.top + 4 then return end
        self.fill:SetPoint("BOTTOMRIGHT", self.frame, "TOPLEFT", self.right, -y)
        self.sized = true
        self:SetShown(true)
    end

    -- So a card can join a list of widgets that get shown and hidden together --
    -- Groups hides the cards for the raid groups it is not using. A card that was
    -- never given a bottom stays hidden whatever it is asked for.
    function card:SetShown(shown)
        shown = (shown and self.sized) and true or false
        self.fill:SetShown(shown)
        for _, e in ipairs(self.edges) do e:SetShown(shown) end
    end

    if bottom then card:SetBottom(bottom) end
    return card
end

-- Open a card whose top edge sits `top` pixels down the frame, spanning the current
-- column. Left/right insets match what DUI_CreateSeparator uses, so a card lines up
-- with anything else drawn across a column.
function LayoutMixin:OpenCard(top)
    self.card = DUI_CreateCard(self.frame, self.x + 16, top, self.x + self.w - 12)
    return self.card
end

-- Grow the open card so its bottom edge sits `y` pixels down the frame. Public,
-- because a panel that anchors its own content (rather than going through Place)
-- still wants that content inside its section: pass the Y the content ends at.
function LayoutMixin:ExtendCard(y)
    if self.card then self.card:SetBottom(y) end
end

-- Advance the cursor and stretch the open card to follow it. Every widget method
-- goes through here, so a section covers whatever was laid out under its header --
-- factory rows and bespoke content alike -- and nothing sits half in, half out.
-- Each widget's step already carries its own trailing gap, so the card simply ends
-- where the cursor now is.
function LayoutMixin:Advance(step)
    self.y = self.y + step
    self:ExtendCard(self.y)
end

-- ---- widgets -------------------------------------------------------------

-- Section header. Opens a card underneath itself, so everything added until the
-- next header reads as one block. The card is what separates sections now: the
-- accent rule that used to sit above each header was doing the same job twice, and
-- two dividers plus an outline is more furniture than a five-row panel can carry.
--
-- opts.card = false suppresses the card, for a section whose content is a single
-- bordered thing that draws its own frame (a scrollable list). Nesting an outline
-- inside an outline reads as a mistake, and the list is already its own block.
function LayoutMixin:Header(text, opts)
    if self.headerCount > 0 then self.y = self.y + DUI_LAYOUT.SECTION end
    self.headerCount = self.headerCount + 1
    local h = DUI_CreateHeader(self.frame, text, -self.y)
    self:Anchor(h, 20)
    self.y = self.y + DUI_LAYOUT.HEADER
    if opts and opts.card == false then
        self.card = nil
    else
        self:OpenCard(self.y - DUI_LAYOUT.CARD_PAD)
    end
    return h
end

function LayoutMixin:Checkbox(label, dbTable, key, onUpdate, tooltip)
    local cb = DUI_CreateCheckbox(self.frame, label, -self.y, dbTable, key, onUpdate, tooltip)
    if dbTable and key ~= nil then cb:SetChecked(dbTable[key] and true or false) end

    -- The label is given the room its column actually has and allowed to wrap, so
    -- a long option name in a two-column panel wraps instead of running under the
    -- column beside it. The row then grows to whatever the label needed.
    cb.Text:SetWidth(self:ContentWidth(DUI_LAYOUT.INDENT) - 30)
    cb.Text:SetWordWrap(true)
    local rowH = math.max(DUI_LAYOUT.ROW, cb.Text:GetStringHeight() + 12)

    self:Anchor(cb, DUI_LAYOUT.INDENT)
    self:Advance(rowH)
    return cb
end

function LayoutMixin:Slider(name, label, min, max, step, dbTable, key, onUpdate, opts)
    opts = opts or {}
    -- The track sits below the cursor so the template's caption, which is drawn
    -- above the track, lands in the row's own space instead of over the widget above.
    local s = DUI_CreateSlider(self.frame, name, label, min, max, step,
        -(self.y + DUI_LAYOUT.SLIDER_CAP), dbTable, key, onUpdate, opts)
    self:Anchor(s, DUI_LAYOUT.INDENT, self.y + DUI_LAYOUT.SLIDER_CAP)
    s:SetWidth(opts.width or self:ContentWidth(DUI_LAYOUT.INDENT))
    self:Advance(DUI_LAYOUT.SLIDER)
    return s
end

function LayoutMixin:ColorButton(label, dbTable, key, onUpdate, tooltip)
    local b = DUI_CreateColorButton(self.frame, label, -self.y, dbTable, key, onUpdate, tooltip)
    if dbTable and dbTable[key] then b:SetBackdropColor(unpack(dbTable[key])) end
    self:Anchor(b, DUI_LAYOUT.INDENT)
    self:Advance(DUI_LAYOUT.ROW)
    return b
end

function LayoutMixin:Dropdown(label, opts)
    opts = opts or {}
    local d = DUI_CreateDropdown(self.frame, label, opts)
    local indent = opts.indent or DUI_LAYOUT.INDENT
    self:Anchor(d, indent)
    -- Fills its column unless the module asked for a specific size. A dropdown
    -- stretched across the pane is most of what makes a panel look built for the
    -- window rather than dropped into it.
    d:SetWidth(opts.width or self:ContentWidth(indent))
    self:Advance(DUI_LAYOUT.ROW)
    return d
end

-- A wrapped explanatory paragraph. Advances by the height the text actually
-- takes, so a two-line and a four-line note both leave the cursor in the right place.
function LayoutMixin:Text(text, opts)
    opts = opts or {}
    local fs = self.frame:CreateFontString(nil, "OVERLAY", opts.font or "DUI_FontSmall")
    local inset = opts.indent or DUI_LAYOUT.TEXT_INSET
    self:Anchor(fs, inset)
    -- Width is set explicitly rather than left to a second anchor: GetStringHeight
    -- below needs a known wrap width, and an anchor-derived one is not resolved yet
    -- on the frame's first layout pass, which would under-measure the paragraph and
    -- let the next widget overlap it.
    fs:SetWidth(math.max(self.w - inset * 2, 40))
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    fs:SetText(text)
    if opts.accent then
        fs:SetTextColor(unpack(DUI_Theme.Accent))
        DUI_RegisterAccent(fs, "text")
    else
        fs:SetTextColor(unpack(opts.color or { 0.6, 0.6, 0.6 }))
    end
    -- Indexed as searchable body text only: a paragraph surfaces its module when
    -- the wording matches, but is not itself a result worth naming in the rail.
    DUI_IndexSearchEntry(self.frame, text, nil, nil, "text")
    self:Advance(math.max(fs:GetStringHeight() + 8, 20))
    return fs
end

-- Place a widget the module built itself, then advance. Keeps bespoke controls in
-- the same rhythm as the factory-built ones. opts.fill stretches it across the
-- column, for the lists and boxes that used to be authored at a fixed 180-300px.
--
-- opts.band is still accepted and now does nothing: it used to ask for a zebra
-- stripe behind this one widget, and the section card covers everything under a
-- header either way.
function LayoutMixin:Place(widget, opts)
    opts = opts or {}
    local indent = opts.indent or DUI_LAYOUT.INDENT
    local step = opts.step or (widget:GetHeight() + 6)
    self:Anchor(widget, indent)
    if opts.fill then widget:SetWidth(self:ContentWidth(indent)) end
    self:Advance(step)
    return widget
end

-- Size the panel to the content the cursor actually laid out, so a panel can gain
-- or lose an option without anyone re-guessing its height. `extra` reserves room
-- for anything pinned to the bottom (a Test or Refresh button, say). In a
-- multi-column panel the tallest column is what the panel has to fit.
function LayoutMixin:FitHeight(extra)
    local y = self.y
    if self.cols then
        self.cols[self.col].y = self.y
        for _, c in ipairs(self.cols) do
            if c.y > y then y = c.y end
        end
    end
    local h = y + DUI_LAYOUT.BOTTOM + (extra or 0)
    if h > self.frame:GetHeight() then self.frame:SetHeight(h) end
    return h
end

-- `width` is for a frame that takes its size from anchors rather than SetSize:
-- AutoPayout's four tab frames are pinned to their config's corners and have no
-- width of their own when the panel is built at file scope. Everything else can
-- leave it out.
function DUI_CreateLayout(frame, startY, width)
    return setmetatable({
        frame = frame,
        y = startY or DUI_LAYOUT.TOP,
        headerCount = 0,
        card = nil,
        -- Single column by default: origin at the frame's left edge, the full
        -- frame width to work with. Columns() replaces both.
        x = 0,
        w = width or frame:GetWidth(),
    }, LayoutMixin)
end

-- 3. MAIN WINDOW SETUP
local MainFrame = CreateFrame("Frame", "DUI_MainFrame", UIParent, "BackdropTemplate")
MainFrame:SetSize(320, 380)
MainFrame:SetPoint("CENTER")
MainFrame:SetClampedToScreen(true)
MainFrame:SetMovable(true)
MainFrame:SetFrameStrata("TOOLTIP")
MainFrame:EnableMouse(true)
MainFrame:RegisterForDrag("LeftButton")
MainFrame:SetScript("OnDragStart", MainFrame.StartMoving)
MainFrame:SetScript("OnDragStop", MainFrame.StopMovingOrSizing)

-- COSMETIC: Dark gray fill with sage-green border
MainFrame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8", 
    tile = true, tileSize = 256, edgeSize = 2, 
    insets = { left = 0, right = 0, top = 0, bottom = 0 }
})
MainFrame:SetBackdropColor(unpack(DUI_Theme.MainBG))
MainFrame:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
DUI_RegisterAccent(MainFrame, "border")
DUI_RegisterMainBG(MainFrame, "bg")
DUI_AddDropShadow(MainFrame)

table.insert(UISpecialFrames, "DUI_MainFrame")

MainFrame:HookScript("OnHide", function()
    DUI_HideAllConfigs()
    if UpdateFloatingBar then UpdateFloatingBar() end
end)

MainFrame:HookScript("OnShow", function()
    UIFrameFadeIn(MainFrame, 0.12, 0, 1)
    if UpdateFloatingBar then UpdateFloatingBar() end
    if DUI_SyncUIEnableChecks then DUI_SyncUIEnableChecks() end
end)

MainFrame.Title = MainFrame:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
MainFrame.Title:SetPoint("TOP", 0, -12)
MainFrame.Title:SetText("Dan UI")
DUI_AddTitleChrome(MainFrame)

local CloseBtn = CreateFrame("Button", nil, MainFrame, "BackdropTemplate")
CloseBtn:SetSize(20, 20)
CloseBtn:SetPoint("TOPRIGHT", -5, -5)
StyleAsCloseButton(CloseBtn)
CloseBtn:SetScript("OnClick", function()
    if InCombatLockdown() then
        print("|cFF00FF00[DUI]|r Cannot close Main Frame in combat due to secure buttons.")
        return
    end
    MainFrame:Hide()
end)

-- The Tools / UI tab frames that used to live here are gone: the window is one
-- rail plus one docking pane now, built at the bottom of this file.

-- Global Generic Scroll Dropdown System
local genericPicker
function DUI_HideScrollDropdown() if genericPicker then genericPicker:Hide() end end
function DUI_ShowScrollDropdown(anchor, items, onSelect, currentValue, opts)
    if not genericPicker then
        local p = CreateFrame("Frame", "DUI_GenericPicker", UIParent, "BackdropTemplate")
        p:SetSize(180, 405); p:SetFrameStrata("TOOLTIP"); p:SetFrameLevel(9999)
        p:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        -- Near-opaque rather than MainBG's 0.8: a dropdown list sits over arbitrary
        -- world content and has to stay readable.
        p:SetBackdropColor(DUI_Theme.MainBG[1], DUI_Theme.MainBG[2], DUI_Theme.MainBG[3], 0.96)
        p:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
        DUI_RegisterAccent(p, "border")
        -- Follows the background's shade but keeps its own floor on opacity, for
        -- the same reason it was near-opaque to begin with.
        DUI_RegisterMainBG(p, "fn", function()
            local c = DUI_Theme.MainBG
            p:SetBackdropColor(c[1], c[2], c[3], math.max(c[4], 0.96))
        end)
        local sf = CreateFrame("ScrollFrame", nil, p, "BackdropTemplate")
        sf:SetPoint("TOPLEFT", 5, -5); sf:SetPoint("BOTTOMRIGHT", -25, 5)
        local content = CreateFrame("Frame", nil, sf); content:SetSize(150, 1); sf:SetScrollChild(content)
        local sb = CreateFrame("Slider", nil, p, "BackdropTemplate")
        sb:SetSize(12, 1); sb:SetPoint("TOPRIGHT", -5, -5); sb:SetPoint("BOTTOMRIGHT", -5, 5)
        sb:SetBackdrop(DUI_EditBackdrop); sb:SetBackdropColor(0, 0, 0, 0.5)
        sb:SetThumbTexture("Interface\\Buttons\\WHITE8X8"); sb:GetThumbTexture():SetSize(10, 40); sb:GetThumbTexture():SetVertexColor(unpack(DUI_Theme.Accent))
        sb:SetMinMaxValues(0, 1); sb:SetValueStep(1); sb:SetObeyStepOnDrag(true)
        sb:SetScript("OnValueChanged", function(self, value) sf:SetVerticalScroll(value) end)
        sf:SetScript("OnMouseWheel", function(self, delta) sb:SetValue(sb:GetValue() - (delta * 40)) end)
        p.sf, p.content, p.sb, p.buttons = sf, content, sb, {}
        genericPicker = p
    end
    if genericPicker:IsShown() and genericPicker.lastAnchor == anchor then genericPicker:Hide(); return end
    genericPicker.lastAnchor = anchor; genericPicker:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    local rowHeight, maxVisible = 20, 20
    local numItems = #items; local visibleRows = math.min(numItems, maxVisible)
    genericPicker:SetHeight((visibleRows * rowHeight) + 10); genericPicker.content:SetHeight(numItems * rowHeight)
    genericPicker.sb:SetMinMaxValues(0, math.max(0, (numItems * rowHeight) - (visibleRows * rowHeight - 5))); genericPicker.sb:SetValue(0)
    for i = 1, math.max(numItems, #genericPicker.buttons) do
        if i <= numItems then
            local data = items[i]
            if not genericPicker.buttons[i] then
                local b = CreateFrame("Button", nil, genericPicker.content, "BackdropTemplate")
                b:SetSize(145, rowHeight); b:SetPoint("TOPLEFT", 0, -((i - 1) * rowHeight))
                b.text = b:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
                b.text:SetPoint("LEFT", 5, 0); b.text:SetPoint("RIGHT", -5, 0); b.text:SetJustifyH("LEFT")
                b:SetScript("OnEnter", function(self) self.text:SetTextColor(unpack(DUI_Theme.Accent)) end)
                b:SetScript("OnLeave", function(self) if genericPicker.currentValue ~= self.val then self.text:SetTextColor(unpack(self.defaultColor or {1,1,1})) end end)
                b:SetScript("OnClick", function(self)
                    genericPicker.onSelect(self.val, self.txt)
                    -- keepOpen: multi-select menus stay up so several entries can
                    -- be ticked in one visit (see DUI_RefreshScrollDropdown).
                    if not genericPicker.keepOpen then genericPicker:Hide() end
                end)
                genericPicker.buttons[i] = b
            end
            local btn = genericPicker.buttons[i]
            btn.val, btn.txt = data.value, data.text; btn.text:SetText(data.text)
            local color = data.color or ((data.checked and {1,0,0}) or ((currentValue == data.value and {unpack(DUI_Theme.Accent)}) or {1,1,1}))
            if type(color) == "table" then
                btn.defaultColor = color
                btn.text:SetTextColor(unpack(color))
            else
                btn.defaultColor = {1,1,1}
                btn.text:SetTextColor(1,1,1)
            end
            btn:Show()
        elseif genericPicker.buttons[i] then genericPicker.buttons[i]:Hide() end
    end
    genericPicker.onSelect, genericPicker.currentValue = onSelect, currentValue
    genericPicker.keepOpen = opts and opts.keepOpen or nil
    genericPicker:Show()
end

-- Re-label / recolour the open dropdown in place. For keepOpen menus, where the
-- ticked state changes while the list stays on screen; does nothing if closed.
function DUI_RefreshScrollDropdown(items, currentValue)
    if not genericPicker or not genericPicker:IsShown() then return end
    for i, data in ipairs(items) do
        local btn = genericPicker.buttons[i]
        if btn then
            btn.val, btn.txt = data.value, data.text
            btn.text:SetText(data.text)
            local color = data.color
                    or ((currentValue == data.value and { unpack(DUI_Theme.Accent) }) or { 1, 1, 1 })
            btn.defaultColor = color
            btn.text:SetTextColor(unpack(color))
        end
    end
    genericPicker.currentValue = currentValue
end

-- Global Helper for Module Toggling (Exclusive Visibility + Minimize)
--
-- Now the single entry point into the docking pane. Anything that used to pop a
-- config frame out beside the window -- a rail row, Theme's "Skin" button, a
-- module opening its own panel -- routes through here and lands in the pane
-- instead, so nothing had to learn about docking to get it.
--
-- DUI_DockPanel is defined by the launcher at the bottom of this file. The
-- floating fallback below is what runs before it exists (a module opening a panel
-- during load) and if the launcher is ever stripped out.
function DUI_ToggleConfig(targetFrame, openFunc)
    if DUI_DockPanel then return DUI_DockPanel(targetFrame, openFunc) end

    local isShown = targetFrame and targetFrame:IsShown()
    DUI_HideAllConfigs()
    if not isShown then
        if openFunc then
            openFunc()
        elseif targetFrame then
            targetFrame:Show()
        end
    end
end


SLASH_DAN1, SLASH_DAN2, SLASH_DUIRC1 = "/dan", "/dui", "/duirc"
SlashCmdList["DAN"] = function(msg)
    -- Config panels remember where you drag them; this puts them all back beside
    -- the main window if one ends up somewhere awkward.
    if msg and msg:lower():match("^%s*resetpos%s*$") then
        DUI_ResetConfigPositions()
        return
    end
    if MainFrame:IsShown() then MainFrame:Hide() else MainFrame:Show() end
    if UpdateFloatingBar then UpdateFloatingBar() end
end
-- Bare /duirc toggles the window; /duirc <state> hands off to the preview in
-- ReadyCheck.lua, which paints it from an invented roster (/duirc help lists them).
SlashCmdList["DUIRC"] = function(msg)
    local arg = strtrim(msg or "")
    if arg ~= "" and DUI_PreviewReadyCheckWindow then return DUI_PreviewReadyCheckWindow(arg) end
    if DUI_ReadyCheckFrame and DUI_ReadyCheckFrame:IsShown() then DUI_ReadyCheckFrame:Hide()
    elseif DUI_ReadyCheckFrame then DUI_ReadyCheckFrame:Show(); UpdateRCWindow() end
end
MainFrame:Hide()




-- Slider with a live value readout.
--
-- The bare track carried no number anywhere: the Low/High labels are hidden (they
-- clutter more than they inform) and the caption was a static string, so "Width"
-- never told you what the width was. Five modules worked around that by rewriting
-- _G[name.."Text"] inside their own callback; now the factory owns it.
--
-- opts.fmt is a format string applied to the value ("%d", "%ds", "%.1f", "%d%%").
-- Pass a plain label -- the factory appends ": <value>" itself. opts.tooltip is
-- the hover help, opts.value the initial value.
function DUI_CreateSlider(parent, name, label, min, max, step, yOffset, dbTable, key, onUpdateFunc, opts)
    opts = opts or {}
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate, BackdropTemplate")
    s:SetPoint("TOP", 0, yOffset); s:SetSize(180, 17); s:SetMinMaxValues(min, max); s:SetValueStep(step); s:SetObeyStepOnDrag(true)
    if s.NineSlice then s.NineSlice:Hide() end
    s:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    s:SetBackdropColor(0, 0, 0, 0.5)
    if DUI_Theme then s:SetBackdropBorderColor(unpack(DUI_Theme.Secondary)) end
    DUI_RegisterSecondary(s, "border")
    local thumb = s:GetThumbTexture()
    thumb:SetTexture("Interface\\Buttons\\WHITE8X8"); thumb:SetSize(12, 17)
    if DUI_Theme then thumb:SetVertexColor(unpack(DUI_Theme.Accent)) end
    DUI_RegisterAccent(thumb, "vertex")

    local caption = _G[name .. "Text"]
    caption:SetFontObject(DUI_FontSmall)
    -- The template centres the caption over the track. Sliders now stretch to the
    -- width of their column, and a centred caption over a 500px track floats in
    -- the middle of nothing -- pin it to the left edge so it lines up with the
    -- checkbox labels above and below it.
    caption:ClearAllPoints()
    caption:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 2)
    caption:SetJustifyH("LEFT")
    _G[name.."Low"]:Hide(); _G[name.."High"]:Hide()

    -- Integer steps should never show a trailing ".0"; fractional steps keep a
    -- decimal. Modules can override both with opts.fmt.
    local fmt = opts.fmt or ((step and step < 1) and "%.1f" or "%d")
    s.baseLabel, s.valueFmt = label, fmt

    function s:SetLabelFormat(newFmt) self.valueFmt = newFmt; self:UpdateCaption(self:GetValue()) end
    function s:UpdateCaption(value)
        local f = self.valueFmt
        if not f then caption:SetText(self.baseLabel); return end
        -- A function handles anything a format string cannot (thousands separators,
        -- coin strings); a string is applied directly, rounding for integer specs.
        if type(f) == "function" then
            caption:SetText(self.baseLabel .. ": " .. f(value))
        else
            local shown = value
            if f:find("%%d") then shown = math.floor(value + 0.5) end
            caption:SetText(self.baseLabel .. ": " .. f:format(shown))
        end
    end

    s:SetScript("OnValueChanged", function(self, value)
        dbTable[key] = value
        self:UpdateCaption(value)
        if onUpdateFunc then onUpdateFunc(value, self) end
    end)

    -- SetValue only fires OnValueChanged when the value actually moves, so seed
    -- the caption directly rather than relying on the callback to paint it.
    if opts.value ~= nil then s:SetValue(opts.value) end
    s:UpdateCaption(s:GetValue())
    DUI_AddTooltip(s, label, opts.tooltip)
    DUI_IndexSearchEntry(parent, label, s, opts.tooltip)
    return s
end



-- 9. EVENT LOGIC
local EventFrame = CreateFrame("Frame")
EventFrame:RegisterEvent("ADDON_LOADED"); EventFrame:RegisterEvent("GROUP_ROSTER_UPDATE"); EventFrame:RegisterEvent("READY_CHECK")
EventFrame:RegisterEvent("READY_CHECK_CONFIRM"); EventFrame:RegisterEvent("READY_CHECK_FINISHED"); EventFrame:RegisterEvent("PLAYER_REGEN_DISABLED"); EventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
-- No CHAT_MSG_WHISPER here: this frame has no branch for it, and RaidToolsModule
-- owns the auto-invite listener. Registering it woke this handler on every whisper.

local RC_Ticker, rosterTimer

-- Live buff columns while a ready check window is up. Its own frames (see
-- DUI_CreateGroupUnitWatcher) rather than EventFrame, which can only filter two units.
local rcAuraWatcher = DUI_CreateGroupUnitWatcher({ "UNIT_AURA" }, function(_, _, unit)
    if DUI_ReadyCheckFrame and DUI_ReadyCheckFrame:IsShown() then
        local i = DUI_GroupIndexOf(unit)
        if i and DUI_QueueReadyCheckRow then DUI_QueueReadyCheckRow(i) end
    end
end)

-- GROUP_ROSTER_UPDATE arrives in bursts - a dozen or more on joining a raid or a
-- zone-in - and each one re-laid-out the floating bar (every button re-anchored,
-- a table built per call) and the Raid Arranger. Coalesced onto one pass.
local function FlushRosterUpdate()
    rosterTimer = nil
    UpdateFloatingBar()
    if RG_Update then RG_Update() end
end
EventFrame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" and arg1 == "DanUI" then
        -- One-time migration: adopt settings saved under the old addon name
        -- (DansRandomNeeds/DansRandomNeedsDB) before they get discarded.
        if DanUIDB == nil and DansRandomNeedsDB ~= nil then
            DanUIDB = DansRandomNeedsDB
            DansRandomNeedsDB = nil
        end
        -- (Database Initialization logic remains unchanged)
        DanUIDB = DanUIDB or { PullTimer = 10, LockButtons = false }
        -- Apply the saved accent color before modules build their frames.
        if DanUIDB.AccentColor then
            local c = DanUIDB.AccentColor
            DUI_Theme.Accent[1], DUI_Theme.Accent[2], DUI_Theme.Accent[3], DUI_Theme.Accent[4] = c[1], c[2], c[3], c[4] or 1
            DUI_ApplyAccent()
        end
        -- Same for the panel background. Module frames built at file scope have
        -- already taken the default, so the registry repaint is what fixes them.
        if DanUIDB.MainBGColor then
            local c = DanUIDB.MainBGColor
            DUI_Theme.MainBG[1], DUI_Theme.MainBG[2], DUI_Theme.MainBG[3] = c[1], c[2], c[3]
            DUI_Theme.MainBG[4] = c[4] or DUI_DEFAULT_MAINBG[4]
            DUI_ApplyMainBG()
        end
        -- And the button color, third of the three the Theme panel owns.
        if DanUIDB.ButtonColor then
            local c = DanUIDB.ButtonColor
            local sc = DUI_Theme.Secondary
            sc[1], sc[2], sc[3], sc[4] = c[1], c[2], c[3], c[4] or 1
            DUI_ApplySecondary()
        end
        if not DanUIDB.AssistList then DanUIDB.AssistList = {} end
        if DanUIDB.AutoInviteEnabled == nil then DanUIDB.AutoInviteEnabled = false end
        DanUIDB.AutoInviteKeywords = DanUIDB.AutoInviteKeywords or "inv invite"
        if DanUIDB.BattleResEnabled == nil then DanUIDB.BattleResEnabled = true end
        if DanUIDB.BattleResLocked == nil then DanUIDB.BattleResLocked = false end
         -- Split Roster Defaults
        if DanUIDB.SplitParts == nil then DanUIDB.SplitParts = "auto" end
        if DanUIDB.SplitLayout == nil then DanUIDB.SplitLayout = "block" end
        if DanUIDB.SplitGroups == nil or #DanUIDB.SplitGroups < 8 then DanUIDB.SplitGroups = {true, true, true, true, true, true, true, true} end
        -- Castbar Defaults (profile-based, so it keeps its own init logic).
        -- Profiles are account-wide; the active one is per character and lives in
        -- CastbarCharProfile -- see DUI_GetCastbarActiveProfile in CastbarModule.
        if DUI_GetCastbarDefaults then
            DanUIDB.CastbarProfiles = DanUIDB.CastbarProfiles or {}
            DanUIDB.CastbarCharProfile = DanUIDB.CastbarCharProfile or {}

            -- Migrate any pre-profile settings into "Default", or create it fresh.
            if DanUIDB.Castbar and not DanUIDB.CastbarProfiles["Default"] then
                DanUIDB.CastbarProfiles["Default"] = DanUIDB.Castbar
            end
            if not DanUIDB.CastbarProfiles["Default"] then
                DanUIDB.CastbarProfiles["Default"] = DUI_GetCastbarDefaults()
            end

            DUI_LoadCastbarProfile()
        end
        if DUI_UpdateCastbarAppearance then DUI_UpdateCastbarAppearance() end

        -- CombatTime
        if DUI_GetCombatTimeDefaults then
            DUI_InitModuleDB("CombatTime", DUI_GetCombatTimeDefaults)
            if DUI_UpdateCombatTimeAppearance then DUI_UpdateCombatTimeAppearance() end
        end

        -- CombatAlerts
        if DUI_GetCombatAlertsDefaults then
            DUI_InitModuleDB("CombatAlerts", DUI_GetCombatAlertsDefaults)
            if DUI_InitCombatAlerts then DUI_InitCombatAlerts() end
        end

        -- LowHealthReminder
        if DUI_GetLowHealthReminderDefaults then
            DUI_InitModuleDB("LowHealthReminder", DUI_GetLowHealthReminderDefaults)
            if DUI_UpdateLowHealthReminderAppearance then DUI_UpdateLowHealthReminderAppearance() end
        end

        -- NoAutoClose
        if DUI_GetNoAutoCloseDefaults then
            DUI_InitModuleDB("NoAutoClose", DUI_GetNoAutoCloseDefaults)
            if DUI_InitNoAutoClose then DUI_InitNoAutoClose() end
        end

        -- Bag Item Level. Seeds its own module DB inside its init.
        if DUI_InitBagItemLevel then DUI_InitBagItemLevel() end

        -- Automation. Seeds its own module DB inside its init, because it folds
        -- the older DanUIDB.AutoRepair table into DanUIDB.Automation first.
        if DUI_InitAutomation then DUI_InitAutomation() end

        -- Warbank Gold / Guild Bank Restock. Both seed their own module DB inside
        -- their init, because both also fold an older saved table into it first.
        if DUI_InitWarbankGold then DUI_InitWarbankGold() end
        if DUI_InitGuildBankRestock then DUI_InitGuildBankRestock() end

        -- Timeline (also owns the BigWigs bar-visibility settings)
        if DUI_GetTimelineDefaults then
            DUI_InitModuleDB("Timeline", DUI_GetTimelineDefaults)
        end
        if DUI_InitTimeline then DUI_InitTimeline() end

        -- Break Timer
        if DUI_GetBreakTimerDefaults then
            DUI_InitModuleDB("BreakTimer", DUI_GetBreakTimerDefaults)
        end
        if DUI_InitBreakTimer then DUI_InitBreakTimer() end

        -- ReadyCheckPullTimer Defaults
        if DUI_InitReadyCheckPullTimer then
            DUI_InitReadyCheckPullTimer()
        end

        if DUI_InitFloatingButtons then DUI_InitFloatingButtons() end
        if DUI_InitRaidToolsModule then DUI_InitRaidToolsModule() end

        -- Raid Automation (difficulty schedule + raid group filter). It owns its
        -- own DUI_InitModuleDB call so the pre-rename AutoRaidDiff table is
        -- migrated before the defaults are backfilled onto it.
        if DUI_InitRaidAutomation then DUI_InitRaidAutomation() end

        if ToggleBRTracker then ToggleBRTracker(DanUIDB.BattleResEnabled) end
        if DUI_InitAssistModule then DUI_InitAssistModule() end
        if DUI_InitGuildBankSort then DUI_InitGuildBankSort() end
        if DUI_InitAutoPayout then DUI_InitAutoPayout() end
        -- Raid Arranger has no init of its own; this only creates the table its
        -- enable flag lives in, so the launcher rail has something to read.
        if DUI_EnsureRaidArrangerDB then DUI_EnsureRaidArrangerDB() end
        -- Saved variables only exist now, so the window scale set by the title-bar
        -- slider is restored here rather than when the launcher was built.
        if DUI_ApplyLauncherScale and DanUIDB.Launcher and DanUIDB.Launcher.scale then
            DUI_ApplyLauncherScale(DanUIDB.Launcher.scale)
        end
        if DUI_InitLFGFilter then DUI_InitLFGFilter() end

        -- Frame Mover
        if DUI_GetMoverDefaults then
            DUI_InitModuleDB("Mover", DUI_GetMoverDefaults)
            if DUI_InitMover then DUI_InitMover() end
        end

        if LSM.RegisterCallback then
            LSM.RegisterCallback("DUI", "LibSharedMedia_Registered", function(_, mediatype)
                if mediatype == "font" then RefreshDUIFonts()
                elseif (mediatype == "statusbar" or mediatype == "border") and DUI_UpdateCastbarAppearance then
                    DUI_UpdateCastbarAppearance()
                end
            end)
        end

        -- Initialize UI elements from saved data
        if DUI_RefreshAssistList then DUI_RefreshAssistList() end
        if UpdateFloatingBar then UpdateFloatingBar() end
        if DUI_InitMinimapButton then DUI_InitMinimapButton() end
        DUI_SyncUIEnableChecks()
    elseif event == "PLAYER_REGEN_DISABLED" then
        if MainFrame:IsShown() then MainFrame:Hide() end
        if DUI_FloatingBar and DUI_FloatingBar:IsShown() then DUI_FloatingBar:Hide() end
        if DUI_ReadyCheckFrame and DUI_ReadyCheckFrame:IsShown() then DUI_ReadyCheckFrame:Hide() end
        if DUI_CastbarConfig and DUI_CastbarConfig:IsShown() then DUI_CastbarConfig:Hide() end
        if DUI_CombatTimeConfig and DUI_CombatTimeConfig:IsShown() then DUI_CombatTimeConfig:Hide() end
        if DUI_CombatAlertsConfig and DUI_CombatAlertsConfig:IsShown() then DUI_CombatAlertsConfig:Hide() end
        if DUI_LowHealthReminderConfig and DUI_LowHealthReminderConfig:IsShown() then DUI_LowHealthReminderConfig:Hide() end
        if DUI_NoAutoCloseConfig and DUI_NoAutoCloseConfig:IsShown() then DUI_NoAutoCloseConfig:Hide() end
        if DUI_AutoPayoutConfig and DUI_AutoPayoutConfig:IsShown() then DUI_AutoPayoutConfig:Hide() end
        if RC_Ticker then RC_Ticker:Cancel() end
        rcAuraWatcher:SetRegistered(false)
    elseif event == "PLAYER_REGEN_ENABLED" then
        UpdateFloatingBar()
    elseif event == "GROUP_ROSTER_UPDATE" then
        if not rosterTimer then rosterTimer = C_Timer.NewTimer(0.2, FlushRosterUpdate) end
    elseif event == "READY_CHECK" then
        if not InCombatLockdown() then
            rcAuraWatcher:SetRegistered(true)
            local timeLeft = 35; if DUI_ReadyCheckFrame then DUI_ReadyCheckFrame.Title:SetText("Ready Check: 35s"); DUI_ReadyCheckFrame:Show(); UpdateRCWindow() end
            if RC_Ticker then RC_Ticker:Cancel() end
            RC_Ticker = C_Timer.NewTicker(1, function() timeLeft = timeLeft - 1; if DUI_ReadyCheckFrame then DUI_ReadyCheckFrame.Title:SetText("Ready Check: " .. timeLeft .. "s") end; if timeLeft <= 0 then RC_Ticker:Cancel() end end)
        end
    elseif event == "READY_CHECK_CONFIRM" then if DUI_ReadyCheckFrame and DUI_ReadyCheckFrame:IsShown() then DUI_QueueReadyCheckRefresh() end
    elseif event == "READY_CHECK_FINISHED" then rcAuraWatcher:SetRegistered(false); if RC_Ticker then RC_Ticker:Cancel() end; C_Timer.After(10, function() if not InCombatLockdown() and DUI_ReadyCheckFrame then DUI_ReadyCheckFrame:Hide() end end)
    end
end)



-- ===========================================================================
-- 11. LAUNCHER: RAIL + DOCKING PANE
--
-- Replaces the two tabbed columns of identical buttons. The window is a fixed
-- left rail of module rows and a fixed-size pane that the module's own config
-- frame is re-parented into.
--
-- The pane is deliberately a fixed size with a scroll inside it, not a pane that
-- resizes per module: the panels range from 320x250 (Auto Repair) to 560x745
-- (Raid Arranger at eight groups), and sizing the window to each one made it jump
-- on every click.
-- Anything taller or wider than the pane scrolls instead.
--
-- Every row carries an enable checkbox. Its meaning is one rule across every
-- module: unchecked means the module takes no action. For a background module
-- that stops its behaviour; for an on-demand tool (Raid Arranger, Guild Bank
-- Sorter) it makes the action button inert. The panel always opens either way, so
-- a module can be configured before it is switched on.
-- ===========================================================================

-- The pane's inner area is the size every config panel is built to
-- (DUI_PANEL_W x DUI_PANEL_H, set near the config factory); PANE_W adds the 16px
-- scrollbar gutter on top so a panel is never clipped when the pane scrolls.
local RAIL_W = 190
local PANE_W, PANE_H = DUI_PANEL_W + 16, DUI_PANEL_H
-- Window scale bounds. The floor is where DUI_FontSmall stops being readable on a
-- 1080p screen; the ceiling is roughly where the 796x660 window stops fitting one.
local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.6, 1.4, 0.05
local PAD, TITLE_H, BOTTOM_H = 10, 36, 34
local ROW_H, HDR_H, GROUP_GAP = 22, 24, 6
-- A search result row is one setting found inside a module's panel. Shorter and
-- quieter than a module row, and capped per module so one broad term ("colour")
-- cannot bury the rail under sixty lines.
local HIT_H, MAX_HITS = 17, 4

-- dbKey names the DanUIDB subtable; field defaults to "enabled". The three
-- RaidTools entries share one table and differ only by field, which is why the
-- field is spelled out rather than assumed.
local DUI_MODULE_GROUPS = {
    { name = "RAID", modules = {
        { text = "Invites",            frame = "DUI_InvitesConfig",           open = "DUI_OpenInvitesConfig",             dbKey = "RaidTools", field = "autoInviteEnabled" },
        { text = "Raid Automation",    frame = "DUI_RaidAutomationConfig",    open = "DUI_OpenRaidAutomationConfig",      dbKey = "RaidAutomation" },
        { text = "Raid Arranger",      frame = "DUI_GroupsPopout",                                                        dbKey = "RaidArranger" },
        { text = "Auto-Assist List",   frame = "DUI_AssistConfig",            open = "DUI_OpenAssistConfig",              dbKey = "AssistModule" },
        { text = "RC & Pull",          frame = "DUI_RCPTConfig",              open = "DUI_OpenReadyCheckPullTimerConfig", dbKey = "ReadyCheckPullTimer", apply = "DUI_ReadyCheckPullTimerApplyEnabled" },
        { text = "Break Timer",        frame = "DUI_BreakTimerConfig",        open = "DUI_OpenBreakTimerConfig",          dbKey = "BreakTimer",          apply = "DUI_BreakTimerApplyEnabled" },
        { text = "BigWigs & Timeline", frame = "DUI_TimelineConfig",          open = "DUI_OpenTimelineConfig",            dbKey = "Timeline",            apply = "DUI_TimelineApplyEnabled" },
    }},
    { name = "COMBAT", modules = {
        { text = "Castbar",            frame = "DUI_CastbarConfig",           open = "DUI_OpenCastbarConfig",             dbKey = "Castbar",             apply = "DUI_OnCastbarChanged" },
        { text = "Combat Timer",       frame = "DUI_CombatTimeConfig",        open = "DUI_OpenCombatTimeConfig",          dbKey = "CombatTime",          apply = "DUI_UpdateCombatTimeAppearance" },
        { text = "Combat Alerts",      frame = "DUI_CombatAlertsConfig",      open = "DUI_OpenCombatAlertsConfig",        dbKey = "CombatAlerts",        apply = "DUI_InitCombatAlerts" },
        { text = "HP Reminder",        frame = "DUI_LowHealthReminderConfig", open = "DUI_OpenLowHealthReminderConfig",   dbKey = "LowHealthReminder",   apply = "DUI_UpdateLowHealthReminderAppearance" },
    }},
    { name = "INTERFACE", modules = {
        { text = "Frame Mover",        frame = "DUI_MoverConfig",             open = "DUI_OpenMoverConfig",               dbKey = "Mover",               apply = "DUI_MoverApplyEnabled" },
        { text = "Floating Buttons",   frame = "DUI_FloatingButtonsConfig",   open = "DUI_OpenFloatingButtonsConfig",     dbKey = "RaidTools", field = "floatingEnabled", apply = "DUI_FloatingButtonsApplyEnabled" },
        { text = "No Auto Close",      frame = "DUI_NoAutoCloseConfig",       open = "DUI_OpenNoAutoCloseConfig",         dbKey = "NoAutoClose",         apply = "DUI_NoAutoCloseSetEnabled" },
        { text = "LFG Filter",         frame = "DUI_LFGFilterConfig",         open = "DUI_OpenLFGFilterConfig",           dbKey = "LFGFilter",           apply = "DUI_LFGFilterApplyEnabled" },
        { text = "Bag Item Level",     frame = "DUI_BagItemLevelConfig",      open = "DUI_OpenBagItemLevelConfig",        dbKey = "BagItemLevel",        apply = "DUI_BagItemLevelApplyEnabled" },
        { text = "Battle Res Tracker", frame = "DUI_BattleResTrackerConfig",  open = "DUI_OpenBattleResTrackerConfig",    dbKey = "RaidTools", field = "battleResEnabled", apply = "DUI_BattleResApplyEnabled" },
    }},
    { name = "QUALITY OF LIFE", modules = {
        { text = "Guild Bank Sorter",  frame = "DUI_GuildBankSortConfig",     open = "DUI_OpenGuildBankSortConfig",       dbKey = "GuildBankSort" },
        { text = "AutoPayout",         frame = "DUI_AutoPayoutConfig",        open = "DUI_OpenAutoPayoutConfig",          dbKey = "AutoPayout" },
        { text = "Guild Bank Restock", frame = "DUI_GuildBankRestockConfig",  open = "DUI_OpenGuildBankRestockConfig",    dbKey = "GuildBankRestock",    apply = "DUI_GuildBankRestockApplyEnabled" },
        { text = "Warbank Gold",       frame = "DUI_WarbankGoldConfig",       open = "DUI_OpenWarbankGoldConfig",         dbKey = "WarbankGold",         apply = "DUI_WarbankGoldApplyEnabled" },
        { text = "Automation",         frame = "DUI_AutomationConfig",        open = "DUI_OpenAutomationConfig",          dbKey = "Automation",          apply = "DUI_AutomationApplyEnabled" },
    }},
}

MainFrame:SetSize(PAD + RAIL_W + PAD + PANE_W + PAD, TITLE_H + PANE_H + PAD + BOTTOM_H)

local railArea, paneArea, paneHint, moduleRows, groupHeaders, RelayoutRail
local dockedFrame, dockedRestore

-- ---- enable flags -------------------------------------------------------
-- Read and written through here rather than inline, because three modules keep
-- their flag as a named field of a shared table instead of DanUIDB.X.enabled.

local function ModuleDB(spec)
    return DanUIDB and spec.dbKey and DanUIDB[spec.dbKey] or nil
end

local function IsModuleEnabled(spec)
    local mdb = ModuleDB(spec)
    if not mdb then return nil end
    return mdb[spec.field or "enabled"] and true or false
end

local function SetModuleEnabled(spec, value)
    local mdb = ModuleDB(spec)
    if not mdb then return false end
    mdb[spec.field or "enabled"] = value and true or false
    local apply = spec.apply and _G[spec.apply]
    if apply then apply(value and true or false) end
    return true
end

-- ---- docking ------------------------------------------------------------

-- True while a panel is being docked, so the config factory's OnShow hook does
-- not yank it back out to its floating anchor beside the window.
local docking = false

-- Wrapped rather than replaced: /dan resetpos and any not-yet-docked panel still
-- need the real thing.
local RestoreConfigPosition_Floating = DUI_RestoreConfigPosition
function DUI_RestoreConfigPosition(frame)
    -- Bails mid-dock (the factory's OnShow hook would re-anchor the panel back out
    -- to the side of the window) and for whatever is currently docked, so that
    -- "/dan resetpos" cannot rip the open panel out of the pane.
    if docking or (frame ~= nil and frame == dockedFrame) then return end
    return RestoreConfigPosition_Floating(frame)
end

function DUI_UndockPanel()
    if not dockedFrame then return end
    local f, s = dockedFrame, dockedRestore
    dockedFrame, dockedRestore = nil, nil

    f:Hide()
    f:SetParent(UIParent)
    if s then
        f:SetFrameStrata(s.strata)
        f:SetMovable(s.movable)
        if s.bg and f.GetBackdrop and f:GetBackdrop() then
            f:SetBackdropColor(unpack(s.bg))
            f:SetBackdropBorderColor(unpack(s.border))
        end
        if s.closeShown ~= nil and f.closeBtn then f.closeBtn:SetShown(s.closeShown) end
    end
    f:ClearAllPoints()
    DUI_RestoreConfigPosition(f)

    if paneHint then paneHint:Show() end
    if RelayoutRail then RelayoutRail() end
end

-- The pane's scroll child holds exactly one panel. Docking is: open it (which
-- builds its contents the first time and settles its final height), measure it,
-- then re-parent and strip the chrome that only makes sense on a floating window.
function DUI_DockPanel(targetFrame, openFunc)
    local wasDocked = (targetFrame ~= nil and targetFrame == dockedFrame)
    DUI_UndockPanel()
    if wasDocked then return end -- clicking the open module again clears the pane

    -- Nothing to re-parent: a caller that only has an open function, or a module
    -- whose frame never got built. Open it floating rather than suppressing the
    -- position logic below and stranding it wherever it last sat.
    if not targetFrame then
        if openFunc then openFunc() end
        return
    end

    -- Opening it is what builds its contents the first time and settles its final
    -- height, so this has to happen before anything is measured.
    --
    -- pcall'd because a panel builds on its first open, and a build that throws
    -- used to take the rest of this function with it: `docking` stayed true for
    -- the session (so no panel could be positioned again) and the half-open panel
    -- was left showing beside the window, outside the pane, looking like the
    -- launcher had popped it out. A module that cannot open is reported and the
    -- pane is left empty instead.
    local f = targetFrame
    docking = true
    local ok, err = pcall(function()
        if openFunc then openFunc() else f:Show() end
    end)
    docking = false
    if not ok then
        f:Hide()
        print("|cFF00FF00[DUI]|r " .. (f:GetName() or "panel") .. " failed to open: " .. tostring(err))
        return
    end
    if not f:IsShown() then f:Show() end

    dockedRestore = { strata = f:GetFrameStrata(), movable = f:IsMovable() }
    if f.GetBackdrop and f:GetBackdrop() then
        dockedRestore.bg     = { f:GetBackdropColor() }
        dockedRestore.border = { f:GetBackdropBorderColor() }
    end
    if f.closeBtn then
        dockedRestore.closeShown = f.closeBtn:IsShown()
        f.closeBtn:Hide()
    end
    dockedFrame = f

    local content = paneArea.content
    content:SetSize(math.max(f:GetWidth(), PANE_W - 16), f:GetHeight())

    f:SetParent(content)
    f:SetFrameStrata(MainFrame:GetFrameStrata())
    f:SetFrameLevel(MainFrame:GetFrameLevel() + 5)
    f:SetMovable(false)
    -- The pane supplies the fill; a second border inside it reads as a window
    -- inside a window.
    if f.GetBackdrop and f:GetBackdrop() then
        f:SetBackdropColor(0, 0, 0, 0)
        f:SetBackdropBorderColor(0, 0, 0, 0)
    end
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)

    -- Some panels resize themselves after they are open -- Raid Arranger grows a
    -- row as its groups fill up -- so the pane has to follow rather than keep the
    -- height measured at dock time. Hooked once per frame, not once per dock, or
    -- the hooks would stack up.
    if not f.dockResizeHooked then
        f:HookScript("OnSizeChanged", function(self)
            if dockedFrame ~= self then return end
            paneArea.content:SetSize(math.max(self:GetWidth(), PANE_W - 16), self:GetHeight())
            paneArea:Update(self:GetHeight())
        end)
        f.dockResizeHooked = true
    end

    paneArea.bar:SetValue(0)
    paneArea:Update(f:GetHeight())
    if paneHint then paneHint:Hide() end

    if DanUIDB then
        DanUIDB.Launcher = DanUIDB.Launcher or {}
        DanUIDB.Launcher.lastModule = f:GetName()
    end
    if RelayoutRail then RelayoutRail() end
end

-- Undocking is the dock's version of hiding everything, so the existing callers
-- of DUI_HideAllConfigs (closing the window, entering combat) keep working.
local HideAllConfigs_Floating = DUI_HideAllConfigs
function DUI_HideAllConfigs()
    DUI_UndockPanel()
    return HideAllConfigs_Floating()
end

-- ---- rail ---------------------------------------------------------------

local function PaintRow(row)
    local spec = row.spec
    local enabled = IsModuleEnabled(spec)
    row.check:SetChecked(enabled and true or false)
    -- A module whose saved variables have not been created yet (its addon file
    -- bailed, e.g. a dependency it needs is absent) cannot be toggled, so say so
    -- rather than offering a checkbox that silently does nothing.
    row.check:SetEnabled(enabled ~= nil)
    row.check:SetAlpha(enabled == nil and 0.35 or 1)

    local selected = (dockedFrame ~= nil and _G[spec.frame] == dockedFrame)
    row.sel:SetShown(selected)
    row.bar:SetShown(selected)
    if selected then
        row.label:SetTextColor(1, 1, 1)
    elseif enabled == false then
        row.label:SetTextColor(0.55, 0.55, 0.55)
    else
        row.label:SetTextColor(0.85, 0.85, 0.85)
    end
end

local function CreateModuleRow(parent, spec)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(RAIL_W - 16, ROW_H)
    row.spec = spec

    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.sel:SetVertexColor(DUI_Theme.Accent[1], DUI_Theme.Accent[2], DUI_Theme.Accent[3], 0.18)
    row.sel:SetAllPoints(); row.sel:Hide()
    DUI_RegisterAccent(row.sel, "fn", function()
        local a = DUI_Theme.Accent
        row.sel:SetVertexColor(a[1], a[2], a[3], 0.18)
    end)

    row.bar = row:CreateTexture(nil, "ARTWORK")
    row.bar:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.bar:SetVertexColor(unpack(DUI_Theme.Accent))
    row.bar:SetPoint("TOPLEFT"); row.bar:SetPoint("BOTTOMLEFT")
    row.bar:SetWidth(2); row.bar:Hide()
    DUI_RegisterAccent(row.bar, "vertex")

    row:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
    row:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.07)

    local cb = CreateFrame("CheckButton", nil, row, "ChatConfigCheckButtonTemplate, BackdropTemplate")
    StyleAsPlainCheckbox(cb, 16)
    cb.Text:SetText("")
    cb:SetPoint("LEFT", 6, 0)
    cb:SetScript("OnClick", function(self)
        if not SetModuleEnabled(spec, self:GetChecked()) then
            self:SetChecked(not self:GetChecked()) -- no saved variables yet: refuse
            return
        end
        RelayoutRail()
    end)
    cb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetFrameStrata("TOOLTIP")
        GameTooltip:SetFrameLevel(self:GetFrameLevel() + 50)
        local enabled = IsModuleEnabled(spec)
        if enabled == nil then
            GameTooltip:SetText(spec.text, 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Not loaded this session.", 1, 1, 1, true)
        else
            GameTooltip:SetText((enabled and "Disable " or "Enable ") .. spec.text, 1, 1, 1)
            GameTooltip:AddLine("Off means this module takes no action.", 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.check = cb

    row.label = row:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    row.label:SetPoint("LEFT", 28, 0)
    row.label:SetPoint("RIGHT", -4, 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetText(spec.text)

    row:SetScript("OnClick", function()
        DUI_ToggleConfig(_G[spec.frame], spec.open and _G[spec.open])
    end)
    return row
end

-- ---- window -------------------------------------------------------------

do
    -- ---- window scale ---------------------------------------------------
    -- Sits in the title bar, left of the close button. Scaling the window scales
    -- the rail and whatever is docked in it together, which is the point: the pane
    -- is a fixed 576x580, so shrinking the window is how a tall panel like Raid
    -- Arranger (820px) stops needing to scroll.
    local scaleSlider = CreateFrame("Slider", "DUI_ScaleSlider", MainFrame, "BackdropTemplate")
    scaleSlider:SetSize(90, 12)
    scaleSlider:SetPoint("TOPRIGHT", -32, -13)
    scaleSlider:SetOrientation("HORIZONTAL")
    scaleSlider:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    scaleSlider:SetBackdropColor(0, 0, 0, 0.5)
    scaleSlider:SetBackdropBorderColor(unpack(DUI_Theme.Secondary))
    DUI_RegisterSecondary(scaleSlider, "border")
    scaleSlider:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
    local scaleThumb = scaleSlider:GetThumbTexture()
    scaleThumb:SetSize(8, 12)
    scaleThumb:SetVertexColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(scaleThumb, "vertex")
    scaleSlider:SetMinMaxValues(SCALE_MIN, SCALE_MAX)
    scaleSlider:SetValueStep(SCALE_STEP)
    scaleSlider:SetObeyStepOnDrag(true)

    local scaleText = MainFrame:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    scaleText:SetPoint("RIGHT", scaleSlider, "LEFT", -6, 0)
    scaleText:SetTextColor(0.6, 0.6, 0.6)
    scaleText:SetText("100%")

    -- Seeded before OnValueChanged exists. Saved variables are already loaded by
    -- the time this file runs, so a callback firing here would write 100% over the
    -- stored scale before ADDON_LOADED below ever gets to read it.
    scaleSlider:SetValue(1)

    -- The scale is committed on release, not continuously through the drag, and
    -- that is not a stylistic choice.
    --
    -- This slider is a child of the frame it scales. Applying SetScale mid-drag
    -- moves and resizes the slider itself under a cursor that has not moved, so
    -- the next frame recomputes the value from the new geometry, which changes the
    -- scale again. Dragging right widens the window, pushing the track right, so
    -- the cursor ends up further left within it -- the value collapses to the
    -- minimum in a single frame, and from the minimum the geometry inverts and it
    -- slams to the maximum. Any live application of the scale feeds back this way
    -- while the control lives inside the thing it resizes.
    --
    -- So the drag only moves the number, which turns accent-coloured to show it is
    -- pending, and the window resizes once on mouse-up.
    local pendingScale, dragging = 1, false

    local function Clamp(value)
        return math.max(SCALE_MIN, math.min(SCALE_MAX, tonumber(value) or 1))
    end

    local function ShowPending(value, isPending)
        scaleText:SetText(math.floor(value * 100 + 0.5) .. "%")
        if isPending then
            scaleText:SetTextColor(unpack(DUI_Theme.Accent))
        else
            scaleText:SetTextColor(0.6, 0.6, 0.6)
        end
    end

    -- The only place the window is actually resized.
    local function CommitScale(value)
        value = Clamp(value)
        pendingScale = value
        MainFrame:SetScale(value)
        ShowPending(value, false)
        -- The pixel snapping is computed against the effective scale, so it has to
        -- be redone once the new scale is live -- for every checkbox in the window,
        -- not just the rail's, since docked panels scale with it too.
        DUI_ResnapCheckboxes()
        if RelayoutRail then RelayoutRail() end
        if DanUIDB then
            DanUIDB.Launcher = DanUIDB.Launcher or {}
            DanUIDB.Launcher.scale = value
        end
    end

    -- Applied at ADDON_LOADED and by the right-click reset, so the size survives a
    -- reload. Moves the thumb as well as the window.
    function DUI_ApplyLauncherScale(value)
        value = Clamp(value)
        dragging = false
        if scaleSlider:GetValue() ~= value then scaleSlider:SetValue(value) end
        CommitScale(value)
    end

    scaleSlider:SetScript("OnValueChanged", function(_, value)
        value = Clamp(value)
        pendingScale = value
        if dragging then
            ShowPending(value, true) -- preview only; the window is left alone
        else
            CommitScale(value)       -- keyboard, or a programmatic SetValue
        end
    end)

    scaleSlider:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then dragging = true end
    end)

    scaleSlider:SetScript("OnMouseUp", function(_, button)
        -- Right-click resets to 100%, the same gesture the Skin button uses to
        -- reset the theme.
        if button == "RightButton" then
            DUI_ApplyLauncherScale(1)
            return
        end
        dragging = false
        CommitScale(pendingScale)
    end)

    -- A drag released off the edge of the slider still ends here, so the window
    -- can never be left showing a pending number it never applied.
    scaleSlider:SetScript("OnHide", function()
        if dragging then
            dragging = false
            CommitScale(pendingScale)
        end
    end)

    DUI_AddTooltip(scaleSlider, "Window Scale",
        { body = "Resizes this window and everything docked in it. Drag to pick a size, release to apply.",
          note = "Right-click to reset to 100%." })

    local rule = MainFrame:CreateTexture(nil, "ARTWORK")
    rule:SetTexture("Interface\\Buttons\\WHITE8X8")
    rule:SetVertexColor(DUI_Theme.Accent[1], DUI_Theme.Accent[2], DUI_Theme.Accent[3], 0.25)
    rule:SetWidth(1)
    rule:SetPoint("TOPLEFT", MainFrame, "TOPLEFT", PAD + RAIL_W + PAD / 2, -TITLE_H)
    rule:SetPoint("BOTTOMLEFT", MainFrame, "BOTTOMLEFT", PAD + RAIL_W + PAD / 2, BOTTOM_H)
    DUI_RegisterAccent(rule, "fn", function()
        local a = DUI_Theme.Accent
        rule:SetVertexColor(a[1], a[2], a[3], 0.25)
    end)

    local search = CreateFrame("EditBox", "DUI_ModuleSearchBox", MainFrame, "BackdropTemplate")
    search:SetSize(RAIL_W, 22)
    search:SetPoint("TOPLEFT", PAD, -TITLE_H - 6)
    search:SetAutoFocus(false); search:SetFontObject(DUI_FontSmall)
    search:SetBackdrop(DUI_EditBackdrop); search:SetBackdropColor(0, 0, 0, 0.5)
    search:SetBackdropBorderColor(unpack(DUI_Theme.Accent)); search:SetTextInsets(6, 6, 0, 0)
    DUI_RegisterAccent(search, "border")
    search:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    search:SetScript("OnTextChanged", function()
        -- First keystroke pays for the index: panels build on first open, so
        -- until they have been built there are no contents to search.
        if MainFrame.WarmSearchIndex then MainFrame.WarmSearchIndex() end
        RelayoutRail()
    end)

    local hint = search:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    hint:SetPoint("LEFT", 8, 0); hint:SetText("Search modules & settings"); hint:SetTextColor(0.6, 0.6, 0.6)
    hint:SetWordWrap(false)
    search:SetScript("OnEditFocusGained", function() hint:Hide() end)
    search:SetScript("OnEditFocusLost", function(self) if self:GetText() == "" then hint:Show() end end)

    railArea = DUI_CreateScrollArea(MainFrame)
    railArea:SetPoint("TOPLEFT", PAD, -TITLE_H - 34)
    railArea:SetPoint("BOTTOMLEFT", PAD, BOTTOM_H)
    railArea:SetWidth(RAIL_W)

    paneArea = DUI_CreateScrollArea(MainFrame)
    paneArea:SetPoint("TOPLEFT", PAD + RAIL_W + PAD, -TITLE_H)
    paneArea:SetSize(PANE_W, PANE_H)

    paneHint = paneArea:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
    paneHint:SetPoint("CENTER")
    paneHint:SetText("Select a module")
    paneHint:SetTextColor(0.45, 0.45, 0.45)

    moduleRows, groupHeaders = {}, {}
    for _, group in ipairs(DUI_MODULE_GROUPS) do
        local h = CreateFrame("Button", nil, railArea.content)
        h:SetSize(RAIL_W - 16, HDR_H)
        h.group = group
        h.label = h:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
        h.label:SetPoint("LEFT", 4, 0)
        h.count = h:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
        h.count:SetPoint("RIGHT", -4, 0)
        h.count:SetTextColor(0.5, 0.5, 0.5)
        h:SetScript("OnClick", function(self)
            self.group.collapsed = not self.group.collapsed
            RelayoutRail()
        end)
        groupHeaders[#groupHeaders + 1] = h

        for _, spec in ipairs(group.modules) do
            local row = CreateModuleRow(railArea.content, spec)
            row.group = group
            moduleRows[#moduleRows + 1] = row
        end
    end

    -- ---- search results -------------------------------------------------

    -- Everything in one module's panel that matches. Label matches come first,
    -- because a term found in an option's name is a better answer than the same
    -- term buried in another option's tooltip. `any` is reported separately from
    -- the list: a paragraph match is enough to surface the module, but has no
    -- name worth listing under it.
    local function SettingHits(spec, filter)
        local list = DUI_SearchIndex[spec.frame]
        if not list then return nil, false end
        local byLabel, byTip, any = {}, {}, false
        for _, e in ipairs(list) do
            if e.haystack:find(filter, 1, true) then
                any = true
                if e.kind ~= "text" then
                    if e.label:lower():find(filter, 1, true) then
                        byLabel[#byLabel + 1] = e
                    else
                        byTip[#byTip + 1] = e
                    end
                end
            end
        end
        for _, e in ipairs(byTip) do byLabel[#byLabel + 1] = e end
        return byLabel, any
    end

    -- Pooled and re-anchored on every keystroke: the set of matches changes with
    -- every character typed, and creating frames per keystroke would be the only
    -- expensive part of a rail this short.
    local hitRows = {}
    local function AcquireHitRow(index)
        local hit = hitRows[index]
        if hit then return hit end

        hit = CreateFrame("Button", nil, railArea.content)
        hit:SetSize(RAIL_W - 16, HIT_H)
        hit:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
        hit:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.07)

        hit.dot = hit:CreateTexture(nil, "ARTWORK")
        hit.dot:SetTexture("Interface\\Buttons\\WHITE8X8")
        hit.dot:SetSize(2, 2); hit.dot:SetPoint("LEFT", 34, 0)
        hit.dot:SetVertexColor(unpack(DUI_Theme.Accent))
        DUI_RegisterAccent(hit.dot, "vertex")

        hit.label = hit:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
        hit.label:SetPoint("LEFT", 42, 0); hit.label:SetPoint("RIGHT", -4, 0)
        hit.label:SetJustifyH("LEFT"); hit.label:SetWordWrap(false)

        hit:SetScript("OnClick", function(self)
            if self.spec then DUI_RevealSetting(self.spec, self.entry) end
        end)
        hitRows[index] = hit
        return hit
    end

    local noHits = railArea.content:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    noHits:SetPoint("TOPLEFT", 6, -8)
    noHits:SetTextColor(0.45, 0.45, 0.45)
    noHits:Hide()

    -- ---- index warm-up ---------------------------------------------------
    -- A panel registers its widgets while it builds, and it builds on first open,
    -- so on a fresh session the index describes only the panels already visited.
    -- This opens each one once, hidden, purely to make it build.
    --
    -- One per tick rather than one loop: building all 22 at once is a visible
    -- hitch, and Raid Arranger and Guild Bank Sorter are most of it. Nothing runs
    -- in combat -- config panels carry secure buttons, and Show/Hide on those is
    -- blocked -- so the pass parks itself until the fight is over.
    local warmIndex, warmDone, warmRunning = 0, false, false

    local function WarmPanel(spec)
        local f = _G[spec.frame]
        -- Anything already on screen is left alone: hiding a panel the user is
        -- reading is worse than an index with a gap in it. Anything already
        -- indexed has been built, so opening it would gain nothing.
        if not f or f:IsShown() or f == dockedFrame or DUI_SearchIndex[spec.frame] then return end

        docking = true -- stops the config factory's OnShow hook re-anchoring it
        pcall(function()
            local open = spec.open and _G[spec.open]
            if open then open() else f:Show() end
        end)
        docking = false

        -- Hidden in the same frame it was shown, so nothing is ever drawn. The
        -- fade the factory starts on show has to be cancelled explicitly, or the
        -- panel is left part-way transparent the next time it opens for real.
        if UIFrameFadeRemoveFrame then UIFrameFadeRemoveFrame(f) end
        f:Hide()
        f:SetAlpha(1)

        -- This Hide only sticks because the config factory's OnShow hook checks
        -- IsShown before acting. OnShow is queued rather than run inside Show(),
        -- so it lands here *after* the Hide, and its UIFrameFadeIn would call
        -- Show() and put the panel back on screen beside the window. Do not drop
        -- that guard.
    end

    -- Chained rather than a ticker: in combat the pass parks itself for five
    -- seconds instead of waking twenty times a second to find it still cannot run.
    local function WarmNextPanel()
        if InCombatLockdown() then C_Timer.After(5, WarmNextPanel); return end

        warmIndex = warmIndex + 1
        local row = moduleRows[warmIndex]
        if not row then
            warmDone, warmRunning = true, false
            RelayoutRail()
            return
        end

        WarmPanel(row.spec)
        -- Results fill in as the index grows, rather than after the last panel.
        if search:GetText() ~= "" then RelayoutRail() end
        C_Timer.After(0.05, WarmNextPanel)
    end

    -- Held on the frame rather than in a new file-scope local: the search box's
    -- OnTextChanged is written above this point and the window's OnShow hook
    -- below it, and both have to reach it.
    function MainFrame.WarmSearchIndex()
        if warmRunning or warmDone then return end
        warmRunning = true
        WarmNextPanel()
    end

    -- ---- reveal ----------------------------------------------------------
    -- Clicking a result docks the owning panel, scrolls the pane to the setting
    -- and flashes it. The scroll and the flash wait a frame: a panel docked for
    -- the first time has only just been built, and nothing in it has a resolved
    -- screen position until the next layout pass.
    local flash
    local function FlashWidget(widget)
        if not widget or not widget.GetTop or not widget:GetTop() then return end
        if not flash then
            flash = CreateFrame("Frame", nil, UIParent)
            flash.tex = flash:CreateTexture(nil, "OVERLAY")
            flash.tex:SetTexture("Interface\\Buttons\\WHITE8X8")
            flash.tex:SetAllPoints()
        end
        flash:SetParent(widget:GetParent() or UIParent)
        flash:SetFrameStrata("TOOLTIP")
        flash:ClearAllPoints()
        flash:SetPoint("TOPLEFT", widget, "TOPLEFT", -6, 4)
        -- A checkbox is a 16px box and a colour swatch a 20px square; the name the
        -- user searched for lives in a separate FontString beside it, so the
        -- highlight is drawn out over that rather than round the control alone.
        local caption = widget.Text or widget.label
        if caption and widget:GetWidth() < 80 then
            flash:SetPoint("BOTTOMRIGHT", caption, "BOTTOMRIGHT", 6, -4)
        else
            flash:SetPoint("BOTTOMRIGHT", widget, "BOTTOMRIGHT", 6, -4)
        end
        local a = DUI_Theme.Accent
        flash.tex:SetVertexColor(a[1], a[2], a[3], 0.35)
        flash:SetAlpha(1); flash:Show()
        UIFrameFadeOut(flash, 1.6, 1, 0)
        -- Tokened, so clicking a second result mid-fade does not have the first
        -- one's timer hide the highlight that has only just appeared.
        flash.token = (flash.token or 0) + 1
        local token = flash.token
        C_Timer.After(1.7, function()
            if flash.token == token then flash:Hide(); flash:SetAlpha(1) end
        end)
    end

    function DUI_RevealSetting(spec, entry)
        local frame = _G[spec.frame]
        -- DUI_DockPanel toggles, so docking the panel that is already docked would
        -- empty the pane instead of jumping to the setting.
        if frame ~= dockedFrame then
            DUI_DockPanel(frame, spec.open and _G[spec.open])
        end
        if not entry or not entry.widget then return end
        C_Timer.After(0, function()
            local widget, panel = entry.widget, _G[spec.frame]
            if not panel or panel ~= dockedFrame or not widget.GetTop then return end
            local top, wtop = panel:GetTop(), widget:GetTop()
            if top and wtop then
                -- 40px of lead-in, so the setting lands below the pane's top edge
                -- with the header above it still on screen.
                local _, maxScroll = paneArea.bar:GetMinMaxValues()
                paneArea.bar:SetValue(math.min(math.max(0, top - wtop - 40), maxScroll or 0))
            end
            FlashWidget(widget)
        end)
    end

    -- Re-stacks the rail top-down. A search term matches across every group and
    -- overrides collapse, so you never have to expand a section to find something.
    -- It matches a module's settings as well as its name: the ones that matched
    -- are listed under the module as rows that jump straight to the control.
    RelayoutRail = function()
        local filter = search:GetText():lower()

        -- Snap the pitch to whole physical pixels before stacking anything, so
        -- every row lands on the same sub-pixel phase and the checkboxes all round
        -- the same way. Recomputed per run because the window scale can change
        -- between runs -- CommitScale calls back in here for exactly that reason.
        -- Row and header heights snap to an even count so a 16px box centres on a
        -- whole pixel rather than a half one.
        local content = railArea.content
        local rowH = DUI_SnapPixels(ROW_H, content, true)
        local hdrH = DUI_SnapPixels(HDR_H, content, true)
        local hitH = DUI_SnapPixels(HIT_H, content)
        local gap = DUI_SnapPixels(GROUP_GAP, content)

        local y, hitCount, anyRow = 0, 0, false
        for _, h in ipairs(groupHeaders) do
            local group, matched, on, total = h.group, {}, 0, 0
            for _, row in ipairs(moduleRows) do
                if row.group == group then row:Hide() end
                -- A row whose panel was never created belongs to a module that is not
                -- installed: the released build leaves out the modules ported from
                -- All Rights Reserved addons (see DanUI.toc). Every panel is created at
                -- file scope, so by the time the window can be opened, a missing global
                -- means the file was not loaded - not that it has not loaded yet.
                if row.group == group and _G[row.spec.frame] then
                    row.hits = nil
                    total = total + 1
                    if IsModuleEnabled(row.spec) then on = on + 1 end
                    if filter == "" then
                        matched[#matched + 1] = row
                    else
                        local byTitle = row.spec.text:lower():find(filter, 1, true) ~= nil
                        local hits, any = SettingHits(row.spec, filter)
                        if byTitle or any then
                            -- A module found by name lists its matching settings
                            -- too, so "colour" under Castbar still says which of
                            -- the four colours it meant.
                            row.hits = hits
                            matched[#matched + 1] = row
                        end
                    end
                end
            end

            if #matched == 0 then
                h:Hide()
            else
                anyRow = true
                local open = (filter ~= "") or not group.collapsed
                h:ClearAllPoints(); h:SetPoint("TOPLEFT", 0, -y); h:Show()
                h.label:SetText((open and "|cffbbbbbb-|r " or "|cffbbbbbb+|r ") .. DUI_AccentText(group.name))
                h.count:SetText(on .. "/" .. total)
                h:SetHeight(hdrH)
                y = y + hdrH
                if open then
                    for _, row in ipairs(matched) do
                        row:SetHeight(rowH)
                        DUI_SnapCheckbox(row.check)
                        row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, -y); row:Show()
                        PaintRow(row)
                        y = y + rowH

                        local hits = row.hits
                        for i = 1, math.min(hits and #hits or 0, MAX_HITS) do
                            hitCount = hitCount + 1
                            local hit = AcquireHitRow(hitCount)
                            hit.spec, hit.entry = row.spec, hits[i]
                            hit.label:SetText(hits[i].label)
                            hit.label:SetTextColor(0.62, 0.62, 0.62)
                            hit.dot:Show()
                            hit:SetHeight(hitH)
                            hit:ClearAllPoints(); hit:SetPoint("TOPLEFT", 0, -y); hit:Show()
                            y = y + hitH
                        end
                        -- The overflow line is a count, not a result: it has no
                        -- spec, so clicking it does nothing.
                        if hits and #hits > MAX_HITS then
                            hitCount = hitCount + 1
                            local hit = AcquireHitRow(hitCount)
                            hit.spec, hit.entry = nil, nil
                            hit.label:SetText("+" .. (#hits - MAX_HITS) .. " more")
                            hit.label:SetTextColor(0.4, 0.4, 0.4)
                            hit.dot:Hide()
                            hit:SetHeight(hitH)
                            hit:ClearAllPoints(); hit:SetPoint("TOPLEFT", 0, -y); hit:Show()
                            y = y + hitH
                        end
                    end
                end
                y = y + gap
            end
        end

        for i = hitCount + 1, #hitRows do hitRows[i]:Hide() end

        -- Says whether the search came up empty or is still filling in, because
        -- the two look identical while the warm-up is part-way through the list.
        if anyRow then
            noHits:Hide()
        else
            noHits:SetText(warmDone and "No matches." or "Indexing settings...")
            noHits:Show()
            y = 24
        end

        railArea.content:SetSize(RAIL_W - 16, math.max(y, 1))
        railArea:Update(y)
    end

    RelayoutRail()
end

-- Kept under its old name: the ADDON_LOADED handler and the window's OnShow both
-- call it to re-read the saved variables once modules have initialised theirs.
function DUI_SyncUIEnableChecks()
    if RelayoutRail then RelayoutRail() end
end

-- Re-open whatever was docked last time, so the window comes back where you left
-- it rather than on an empty pane.
MainFrame:HookScript("OnShow", function()
    -- Built one panel per tick from here rather than on the first keystroke, so
    -- the first search is already looking at a full index.
    if MainFrame.WarmSearchIndex then MainFrame.WarmSearchIndex() end

    local last = DanUIDB and DanUIDB.Launcher and DanUIDB.Launcher.lastModule
    if last and not dockedFrame then
        for _, group in ipairs(DUI_MODULE_GROUPS) do
            for _, spec in ipairs(group.modules) do
                if spec.frame == last and _G[spec.frame] then
                    DUI_DockPanel(_G[spec.frame], spec.open and _G[spec.open])
                    break
                end
            end
            if dockedFrame then break end
        end
    end

end)
