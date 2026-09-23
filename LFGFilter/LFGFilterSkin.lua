-- LFGFilter/LFGFilterSkin.lua
-------------------------------------------------------------------------------
-- Dan UI :: LFG Filter - dialog skin
--
-- Restyles PGF's group-finder dialog (the window that docks to the right of
-- PVEFrame) into the DUI theme, and trims the parts of it DanUI does not use.
-- Purely presentational - no filtering behaviour changes here.
--
-- Loads after every UI/*.lua file, so all panels are registered and every widget
-- in them already exists (they are declared in XML, not built on demand). The one
-- exception is PopupMenu's rows, which are created lazily - hooked at the end.
--
-- Why DrawBox instead of SetBackdrop: these widgets come from Blizzard templates
-- that predate BackdropTemplate, so they have no SetBackdrop. Mixing
-- BackdropTemplateMixin in at runtime did not take, so the DUI field look is drawn
-- from plain textures here rather than reusing StyleAsPlainCheckbox /
-- StyleAsTealTab. The colours are kept identical to those helpers, and the accent
-- parts still register with DUI_RegisterAccent so DUI_SetAccent restyles them.
-------------------------------------------------------------------------------

local _, PGF = ...

local WHITE = "Interface\\Buttons\\WHITE8X8"
local Dialog = PGF.Dialog

-- Side margin for the filter column and the footer row. The template ran its
-- content flush to the window edge, which is most of why the window read as
-- unfinished; everything that defines the left and right edge uses this.
local PAD = 16

-- DUI_ApplyAccent can retint borders, backgrounds, text and plain vertex colours,
-- but it always writes the accent at full opacity. The gradients and half-
-- transparent washes below would be flattened or left behind by it, so they
-- repaint themselves from here instead of registering.
local accentPainters = {}

local function AddAccentPainter(paint)
    accentPainters[#accentPainters + 1] = paint
    paint()
end

if DUI_ApplyAccent then
    hooksecurefunc("DUI_ApplyAccent", function()
        for _, paint in ipairs(accentPainters) do pcall(paint) end
    end)
end

-- Button labels need a font object that carries its own white, because WoW
-- re-applies the state font object's colour whenever a button changes state -
-- setting the FontString colour directly would be undone on the next hover.
local WhiteFont = CreateFont("DUI_LFGFilterWhite")
WhiteFont:SetFont(DUI_FontPath or "Fonts\\FRIZQT__.TTF", 12, "")
WhiteFont:SetShadowColor(0, 0, 0, 1)
WhiteFont:SetShadowOffset(1, -1)
WhiteFont:SetTextColor(1, 1, 1)

-- Every step runs under pcall and records its failure instead of aborting the
-- pass: one widget whose template does not match what we expect must not leave
-- the rest of the window half-skinned, which is exactly what happened before.
-- /duiskin prints the report.
local failures = {}
local function Try(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then failures[#failures + 1] = label .. " -> " .. tostring(err) end
    return ok
end

local function GetDebugNameOf(f)
    return f.GetDebugName and f:GetDebugName()
end

local function Named(f)
    if not f then return "?" end
    -- pcall takes the function and its argument directly rather than a closure,
    -- so naming a frame does not allocate one.
    local ok, name = pcall(GetDebugNameOf, f)
    return (ok and name) or "?"
end

-- Try for a step that belongs to a frame. Same behaviour, except the frame's
-- debug name is resolved only when the step actually fails: GetDebugName walks a
-- frame's whole ancestry to build a string, and a clean pass spent more time
-- naming widgets for a message nobody would ever read than on the skinning.
local function TryOn(what, frame, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        failures[#failures + 1] = what .. " " .. Named(frame) .. " -> " .. tostring(err)
    end
    return ok
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

-- Blizzard chrome lives in a frame's own texture regions; clearing them leaves a
-- blank canvas for the DUI look.
local function StripTextures(f)
    if not f or not f.GetRegions then return end
    for _, r in ipairs({ f:GetRegions() }) do
        if r.GetObjectType and r:GetObjectType() == "Texture" and not r.duiOwned then
            r:SetTexture(nil)
            r:Hide()
        end
    end
end

local function ClearButtonArt(btn)
    if not btn then return end
    for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture" }) do
        local tex = btn[getter] and btn[getter](btn)
        if tex then tex:SetTexture(nil); tex:Hide() end
    end
    -- No Set*Texture(nil) here: retail rejects nil ("bad argument #1 ... (asset)").
    -- The getter loop above already blanked each texture object, which is the
    -- supported way to clear button art.
    StripTextures(btn)
end

local function SetFont(fs, fontObject, r, g, b)
    if not fs then return end
    fs:SetFontObject(fontObject)
    if r then fs:SetTextColor(r, g, b) end
end

-- Section heading (Group / Dungeons / ...). An accent tick to the left of the
-- label and a hairline rule beneath it, so a section reads as a titled block
-- instead of a stray line of text floating above some controls.
--
-- Takes the container rather than the FontString because the rule has to be
-- sized off the panel's column width: these section frames are 400px wide in the
-- XML while the window is narrowed to the column, so anything sized off the
-- container itself would run off the edge. The label is deliberately left on its
-- original anchors - the first row hangs off Title's BOTTOM, so re-anchoring it
-- drags the whole column with it.
local function StyleHeading(f)
    local fs = f.Title
    if not fs then return end
    fs:SetFontObject(DUI_FontNormal)
    fs:SetTextColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(fs, "text")

    if f.duiHeading then return end
    f.duiHeading = true

    local panel = f:GetParent()
    local width = (panel and panel.groupWidth) or 245

    local tick = f:CreateTexture(nil, "ARTWORK")
    tick:SetTexture(WHITE)
    tick.duiOwned = true
    tick:SetSize(3, 11)
    tick:SetPoint("RIGHT", fs, "LEFT", -5, 0)
    tick:SetVertexColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(tick, "vertex")

    -- Flush with the row bands below, so it caps them like the top edge of a card.
    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetTexture(WHITE)
    rule.duiOwned = true
    rule:SetHeight(1)
    -- +1, not -4, for the same reason: the rows are inset 5px inside this frame,
    -- so the rule has to start 5px further in to line up with the bands under it.
    rule:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -30)
    rule:SetWidth(width + 8)
    AddAccentPainter(function()
        local a = DUI_Theme.Accent
        rule:SetVertexColor(a[1], a[2], a[3], 0.22)
    end)
end

-- DUI's flat field: a solid border rectangle with a darker fill inset into it.
-- opts: edge, top/bottom/left/right insets, borderColor, fill, accentFill.
local function DrawBox(frame, opts)
    if not frame or frame.duiBox then return frame and frame.duiBox end
    opts = opts or {}
    local edge = opts.edge or 2

    local border = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
    border:SetTexture(WHITE)
    border:SetPoint("TOPLEFT", opts.left or 0, -(opts.top or 0))
    border:SetPoint("BOTTOMRIGHT", -(opts.right or 0), opts.bottom or 0)
    local bc = opts.borderColor or DUI_Theme.Accent
    border:SetVertexColor(bc[1], bc[2], bc[3], bc[4] or 1)
    if not opts.borderColor then DUI_RegisterAccent(border, "vertex") end

    local fill = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
    fill:SetTexture(WHITE)
    fill:SetPoint("TOPLEFT", border, "TOPLEFT", edge, -edge)
    fill:SetPoint("BOTTOMRIGHT", border, "BOTTOMRIGHT", -edge, edge)
    local fc = opts.fill or { 0, 0, 0, 0.6 }
    fill:SetVertexColor(fc[1], fc[2], fc[3], fc[4] or 1)
    if opts.accentFill then DUI_RegisterAccent(fill, "vertex")
    elseif opts.secondaryFill then DUI_RegisterSecondary(fill, "vertex") end

    border.duiOwned, fill.duiOwned = true, true
    frame.duiBox = { border = border, fill = fill }
    return frame.duiBox
end

-------------------------------------------------------------------------------
-- Widget skins
-------------------------------------------------------------------------------

-- Matches StyleAsPlainCheckbox: 22px box, accent border, dark well, grey square
-- when unchecked and an accent square when checked.
local function SkinCheckBox(cb)
    if not cb or cb.duiSkinned then return end
    cb.duiSkinned = true

    cb:SetSize(22, 22)
    cb:SetHitRectInsets(0, 0, 0, 0)
    DrawBox(cb, { edge = 2, fill = { 0, 0, 0, 0.7 } })

    local hl = cb.GetHighlightTexture and cb:GetHighlightTexture()
    if hl then hl:SetAlpha(0) end

    -- Same as StyleAsPlainCheckbox: repaint the template's gold "UI-CheckBox-Down"
    -- pressed frame in place instead of replacing it, so it stays underneath the
    -- checked square.
    local pushed = cb.GetPushedTexture and cb:GetPushedTexture()
    if pushed then
        pushed:SetTexture(WHITE)
        pushed:SetVertexColor(0.4, 0.4, 0.4, 1)
        pushed:ClearAllPoints()
        pushed:SetPoint("TOPLEFT", cb, "TOPLEFT", 4, -4)
        pushed:SetPoint("BOTTOMRIGHT", cb, "BOTTOMRIGHT", -4, 4)
    end

    local normal = cb.GetNormalTexture and cb:GetNormalTexture()
    if normal then
        normal:SetTexture(WHITE)
        normal:SetVertexColor(0.25, 0.25, 0.25, 1)
        normal:ClearAllPoints()
        normal:SetPoint("TOPLEFT", cb, "TOPLEFT", 4, -4)
        normal:SetPoint("BOTTOMRIGHT", cb, "BOTTOMRIGHT", -4, 4)
    end

    local check = cb.GetCheckedTexture and cb:GetCheckedTexture()
    if check then
        check:SetTexture(WHITE)
        check:SetVertexColor(unpack(DUI_Theme.Accent))
        DUI_RegisterAccent(check, "vertex")
        check:ClearAllPoints()
        check:SetPoint("TOPLEFT", cb, "TOPLEFT", 4, -4)
        check:SetPoint("BOTTOMRIGHT", cb, "BOTTOMRIGHT", -4, 4)
    end

    if cb.Text then SetFont(cb.Text, DUI_FontSmall, 0.9, 0.9, 0.9) end
end

-- Idle fields sit on a dimmed border so the focused one stands out; without a
-- state change every field looked identical whether or not it was taking input.
-- The border carries an explicit colour so DrawBox does not register it for
-- accent updates and fight these handlers; Paint covers the accent instead, so
-- changing the accent now restyles the fields live rather than at the next reload.
local function SkinEditBox(eb)
    if not eb or eb.duiSkinned then return end
    eb.duiSkinned = true
    StripTextures(eb)

    local box = DrawBox(eb, { edge = 1, borderColor = { 0, 0, 0, 1 }, fill = { 0, 0, 0, 0.5 } })

    eb:SetFontObject(DUI_FontSmall)
    eb:SetTextInsets(5, 5, 0, 0)
    eb:SetTextColor(1, 1, 1)

    if not box then return end

    -- Focused gets a full accent border and a lifted fill, so the caret has
    -- something to sit against and the active field is obvious at a glance.
    local function Paint()
        local a = DUI_Theme.Accent
        local state = eb.duiState
        if state == "focused" then
            box.border:SetVertexColor(a[1], a[2], a[3], 1)
            box.fill:SetVertexColor(a[1] * 0.16, a[2] * 0.16, a[3] * 0.16, 0.85)
        elseif state == "hot" then
            box.border:SetVertexColor(a[1], a[2], a[3], 1)
            box.fill:SetVertexColor(0, 0, 0, 0.5)
        else
            box.border:SetVertexColor(a[1] * 0.4, a[2] * 0.4, a[3] * 0.4, 1)
            box.fill:SetVertexColor(0, 0, 0, 0.5)
        end
    end

    local function Set(state) eb.duiState = state; Paint() end

    Set("idle")
    AddAccentPainter(Paint)
    -- HookScript, not SetScript: PGF attaches its own text/focus handlers here.
    eb:HookScript("OnEditFocusGained", function() Set("focused") end)
    eb:HookScript("OnEditFocusLost", function() Set("idle") end)
    eb:HookScript("OnEnter", function(self) if not self:HasFocus() then Set("hot") end end)
    eb:HookScript("OnLeave", function(self) if not self:HasFocus() then Set("idle") end end)
end

-- Text button body. Blizzard art off, DUI teal-tab colours on. `primary` fills
-- it with the accent instead of the grey body, which is what marks Search out as
-- the action the window exists for rather than one more grey rectangle.
local function SkinFlatButton(btn, primary)
    if not btn or btn.duiSkinned then return end
    btn.duiSkinned = true
    ClearButtonArt(btn)

    DrawBox(btn, {
        edge = 1, borderColor = { 0, 0, 0, 1 },
        fill = primary and DUI_Theme.Accent or DUI_Theme.Secondary,
        accentFill = primary,
        secondaryFill = not primary,
    })

    btn:SetHighlightTexture(WHITE)
    local hl = btn:GetHighlightTexture()
    if hl then
        hl.duiOwned = true
        hl:SetVertexColor(DUI_Theme.Accent[1], DUI_Theme.Accent[2], DUI_Theme.Accent[3], 0.22)
        hl:ClearAllPoints()
        hl:SetPoint("TOPLEFT", 1, -1)
        hl:SetPoint("BOTTOMRIGHT", -1, 1)
    end
    btn:SetNormalFontObject(WhiteFont)
    btn:SetHighlightFontObject(WhiteFont)
    btn:SetDisabledFontObject(WhiteFont)
    local fs = btn:GetFontString()
    if fs then fs:SetTextColor(1, 1, 1) end
    btn:SetPushedTextOffset(0, 0)
end

-- Reset keeps its icon, but Blizzard's gold atlas art clashes with everything
-- around it, so it gets the same square as the other buttons with the glyph
-- desaturated and tinted to the accent. Guarded throughout: if the template stops
-- exposing an icon the button still works, it just keeps Blizzard's art.
local function SkinIconButton(btn)
    if not btn or btn.duiSkinned then return end

    local icon = btn.Icon or (btn.GetNormalTexture and btn:GetNormalTexture())
    -- With no glyph to preserve there is nothing safe to do here: stripping the
    -- template's art would leave an empty square, and drawing over it without
    -- stripping just hides our own box behind Blizzard's. Leave the button alone.
    if not icon then return end

    btn.duiSkinned = true
    btn:SetSize(24, 24)

    -- Tag the glyph before stripping so it survives the pass, then clear the
    -- template's frame art out from over the top of our box.
    icon.duiOwned = true
    for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture" }) do
        local tex = btn[getter] and btn[getter](btn)
        if tex and tex ~= icon then tex:SetTexture(nil); tex:Hide() end
    end
    StripTextures(btn)

    DrawBox(btn, { edge = 1, borderColor = { 0, 0, 0, 1 }, fill = DUI_Theme.Secondary, secondaryFill = true })

    icon:ClearAllPoints()
    icon:SetPoint("CENTER")
    icon:SetSize(14, 14)
    if icon.SetDesaturated then icon:SetDesaturated(true) end
    icon:SetVertexColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(icon, "vertex")
    icon:Show()

    btn:SetHighlightTexture(WHITE)
    local hl = btn:GetHighlightTexture()
    if hl then
        hl.duiOwned = true
        hl:ClearAllPoints()
        hl:SetPoint("TOPLEFT", 1, -1)
        hl:SetPoint("BOTTOMRIGHT", -1, 1)
        AddAccentPainter(function()
            local a = DUI_Theme.Accent
            hl:SetVertexColor(a[1], a[2], a[3], 0.22)
        end)
    end
end

-- Square accent glyph button in the title bar (close / maximize / minimize).
-- Blizzard re-applies this art on show, so the strip is hooked as well.
local function SkinGlyphButton(btn, glyph)
    if not btn or btn.duiSkinned then return end
    btn.duiSkinned = true
    ClearButtonArt(btn)
    btn:HookScript("OnShow", function(self) ClearButtonArt(self) end)

    btn:SetSize(20, 20)
    local box = DrawBox(btn, {
        edge = 1, borderColor = { 0, 0, 0, 1 }, fill = DUI_Theme.Accent, accentFill = true,
    })
    if box then box.border:SetDrawLayer("BACKGROUND", -7) end

    local label = btn:CreateFontString(nil, "OVERLAY", "DUI_FontSmall")
    label:SetPoint("CENTER")
    label:SetText(glyph)
    label:SetTextColor(1, 1, 1)

    btn:SetHighlightTexture(WHITE)
    local hl = btn:GetHighlightTexture()
    if hl then hl.duiOwned = true; hl:SetVertexColor(1, 1, 1, 0.2) end
end

-- PGF registers each dropdown's entries under a menu name, keyed by the dropdown
-- frame itself, so the frame can be mapped back to its entry list.
local function MenuNameFor(dd)
    if not PGF.PopupMenus then return nil end
    for name, menu in pairs(PGF.PopupMenus) do
        if menu.relativeTo == dd then return name end
    end
end

-- Swap PGF's popup menu for DUI_ShowScrollDropdown, the same widget the Castbar
-- config uses. The entries keep their original func, so selecting still runs PGF's
-- own handler and the filter updates exactly as before.
local function UseDUIDropdown(dd)
    local name = MenuNameFor(dd)
    if not name or not DUI_ShowScrollDropdown then return false end

    local function Open()
        local menu = PGF.PopupMenus[name]
        if not menu then return end
        local current = dd.Text and dd.Text:GetText()
        local items, currentValue = {}, nil
        for _, e in ipairs(menu.entries) do
            items[#items + 1] = { text = e.title, value = e.value }
            if e.title == current then currentValue = e.value end
        end
        DUI_ShowScrollDropdown(dd, items, function(val)
            for _, e in ipairs(menu.entries) do
                if e.value == val then e.func(e) return end
            end
        end, currentValue)
    end

    if dd.Button then dd.Button:SetScript("OnClick", Open) end
    dd:SetScript("OnMouseUp", Open)
    dd:SetScript("OnHide", DUI_HideScrollDropdown)
    return true
end

-- PGF's own dropdown: three seam textures, a label and an arrow button.
--
-- Dressed as a DUI teal tab rather than an input field, because that is what a
-- dropdown looks like everywhere else in DanUI (the Castbar config opens
-- DUI_ShowScrollDropdown from plain StyleAsTealTab buttons). Those carry no arrow
-- glyph, so PGF's chat-scroll icon is dropped outright instead of recoloured -
-- the whole field is the button, with a hover glow as the affordance.
--
-- Geometry: the template makes this frame 145x32 and hangs it 13px off the row's
-- right edge, because Blizzard's seam art carries a wide dead margin with the
-- real field well inside it. With that art hidden the frame's own bounds became
-- the visible box, so the overhang ran straight through the window border. It is
-- re-anchored onto the exact span the Min/Max boxes occupy on every other row, so
-- the whole right-hand column lines up on one edge.
local function SkinDropDown(dd)
    if not dd or dd.duiSkinned then return end
    dd.duiSkinned = true

    for _, key in ipairs({ "Left", "Middle", "Right" }) do
        if dd[key] then dd[key]:SetTexture(nil); dd[key]:Hide() end
    end

    dd:EnableMouse(true)
    -- Hide PGF's arrow only once the DUI dropdown is confirmed wired up; if the
    -- takeover ever fails, PGF's own arrow button stays as the way to open it.
    if UseDUIDropdown(dd) and dd.Button then dd.Button:Hide() end

    -- Offsets come from PremadeGroupsFilterMinMaxTemplate, measured off the row's
    -- right edge like the fields themselves: Min sits at -110 and is 40 wide, Max
    -- at -45 and 40 wide, both 20 tall at y=-1. So the field column runs from -110
    -- to -5, and matching it here needs no insets - the frame is the box.
    local row = dd:GetParent()
    if row then
        dd:ClearAllPoints()
        dd:SetPoint("TOPLEFT", row, "TOPRIGHT", -110, -1)
        dd:SetPoint("BOTTOMRIGHT", row, "TOPRIGHT", -5, -21)
    end

    local box = DrawBox(dd, {
        edge = 1, borderColor = { 0, 0, 0, 1 }, fill = DUI_Theme.Secondary, secondaryFill = true,
    })

    -- Hover glow, matching StyleAsTealTab's accent wash.
    if box then
        local glow = dd:CreateTexture(nil, "BACKGROUND", nil, -5)
        glow:SetTexture(WHITE)
        glow.duiOwned = true
        glow:SetPoint("TOPLEFT", box.border, "TOPLEFT", 1, -1)
        glow:SetPoint("BOTTOMRIGHT", box.border, "BOTTOMRIGHT", -1, 1)
        glow:SetVertexColor(DUI_Theme.Accent[1], DUI_Theme.Accent[2], DUI_Theme.Accent[3], 0.22)
        glow:Hide()
        dd:SetScript("OnEnter", function() glow:Show() end)
        dd:SetScript("OnLeave", function() glow:Hide() end)
    end

    -- The label was anchored off the (now hidden) right-hand seam texture, which
    -- left it jammed against the old arrow. Sit it in the field instead.
    if dd.Text then
        dd.Text:ClearAllPoints()
        dd.Text:SetPoint("LEFT", dd, "LEFT", 10, 0)
        dd.Text:SetPoint("RIGHT", dd, "RIGHT", -10, 0)
        dd.Text:SetJustifyH("LEFT")
        SetFont(dd.Text, DUI_FontSmall, 0.9, 0.9, 0.9)
    end
end

-------------------------------------------------------------------------------
-- Panel walk
-------------------------------------------------------------------------------

-- Rows come from PremadeGroupsFilterBasicTemplate and its two descendants, so
-- these parent keys cover every filter row in every panel.
-- The template pins the box to the row's top-left with a +4 nudge, sized for the
-- 32px Blizzard checkbox. At DUI's 22px that leaves it riding about 4px above the
-- label's centre, so anchor it centred instead. Hoisted out of SkinRow so a walk
-- does not build a fresh closure for every row it touches.
local function AnchorRowCheckBox(f)
    f.Act:ClearAllPoints()
    f.Act:SetPoint("LEFT", f, "LEFT", 0, 0)
end

-- A band behind every filter row. Rows stack flush against each other, so the
-- bands merge into one continuous card behind the section - the structure the
-- flat original was missing - while each row still lights up on its own under
-- the cursor.
local function BandRow(f)
    if f.duiBand then return end
    f.duiBand = true

    local band = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    band:SetTexture(WHITE)
    band.duiOwned = true
    band:SetPoint("TOPLEFT", -4, 0)
    band:SetPoint("BOTTOMRIGHT", 4, 0)
    band:SetVertexColor(0, 0, 0, 0.18)

    local hover = f:CreateTexture(nil, "BACKGROUND", nil, -7)
    hover:SetTexture(WHITE)
    hover.duiOwned = true
    hover:SetAllPoints(band)
    hover:Hide()
    AddAccentPainter(function()
        local a = DUI_Theme.Accent
        hover:SetVertexColor(a[1], a[2], a[3], 0.14)
    end)

    -- Motion, not EnableMouse: the row must not swallow clicks or it would block
    -- dragging the window by its body. As a side effect this finally delivers
    -- PGF's own per-row tooltips, which were set on frames that had no mouse
    -- enabled at all and so could never fire.
    if f.SetMouseMotionEnabled then f:SetMouseMotionEnabled(true) end
    f:HookScript("OnEnter", function() hover:Show() end)
    f:HookScript("OnLeave", function() hover:Hide() end)
end

local function SkinRow(f)
    if f.Act then
        TryOn("checkbox", f, SkinCheckBox, f.Act)
        TryOn("checkbox anchor", f, AnchorRowCheckBox, f)
        TryOn("band", f, BandRow, f)
    end
    if f.Title then
        if f.Act then
            TryOn("label", f, SetFont, f.Title, DUI_FontSmall, 0.9, 0.9, 0.9)
        else
            TryOn("heading", f, StyleHeading, f)
        end
    end
    if f.Min then TryOn("min", f, SkinEditBox, f.Min) end
    if f.Max then TryOn("max", f, SkinEditBox, f.Max) end
    if f.To then TryOn("to", f, SetFont, f.To, DUI_FontSmall, 0.55, 0.55, 0.55) end
    if f.DropDown then TryOn("dropdown", f, SkinDropDown, f.DropDown) end
end

local function SkinPanel(frame, depth)
    if not frame or depth > 8 then return end
    SkinRow(frame)
    for _, child in ipairs({ frame:GetChildren() }) do
        local t = child.GetObjectType and child:GetObjectType()
        if t == "CheckButton" then
            TryOn("checkbox", child, SkinCheckBox, child)
        elseif t == "EditBox" then
            TryOn("editbox", child, SkinEditBox, child)
        end
        SkinPanel(child, depth + 1)
    end
end

-------------------------------------------------------------------------------
-- Trims: advanced-expression box and the settings cog
-------------------------------------------------------------------------------

-- The expression box is hidden rather than removed: PGF still reads
-- panel.state.expression when building the filter, and an empty string is a
-- no-op, so hiding keeps the layout simple without touching the filter logic.
local function HideAdvanced(panel)
    if panel and panel.Advanced then panel.Advanced:Hide() end
end

-- Replaces the dungeon column with a single multi-select dropdown above the Group
-- box, which lets the window lose its whole second column.
--
-- The dropdown drives PGF's existing checkboxes rather than keeping its own state:
-- each pick flips the real CheckButton and fires the OnClick handler PGF installed,
-- so panel.state and the filter refresh exactly as they did when the boxes were
-- visible. Only the presentation changed.
local function CollapseDungeonList(panel)
    if not panel or panel.duiDungeonList then return end
    local col = panel.Dungeons
    if not col or not col.Dungeon1 or not panel.Group or not DUI_ShowScrollDropdown then return end
    panel.duiDungeonList = true

    local rows = {}
    while true do
        local row = col["Dungeon" .. (#rows + 1)]
        if not row or not row.Act then break end
        rows[#rows + 1] = row
    end
    if #rows == 0 then return end

    col:Hide()

    local groupW = panel.groupWidth or 245

    local btn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    btn:SetSize(groupW, 24)
    btn:SetPoint("TOPLEFT", PAD, -4)
    StyleAsTealTab(btn)
    panel.duiDungeonBtn = btn

    local function Label()
        local n = 0
        for _, row in ipairs(rows) do
            if row.Act:GetChecked() then n = n + 1 end
        end
        if n == 0 then
            btn:SetText("Dungeons: None")
        elseif n == #rows then
            btn:SetText("Dungeons: All")
        else
            btn:SetText(("Dungeons: %d of %d"):format(n, #rows))
        end
    end

    -- Ticked entries read in the accent colour, unticked ones grey. The header
    -- also carries the count, since a colour alone is easy to miss.
    local function BuildItems()
        local items = {
            { text = "Select All", value = "all", color = { 1, 1, 1 } },
            { text = "Select None", value = "none", color = { 1, 1, 1 } },
        }
        for i, row in ipairs(rows) do
            local on = row.Act:GetChecked()
            items[#items + 1] = {
                text = (row.Title and row.Title:GetText()) or ("Dungeon " .. i),
                value = i,
                color = on and { DUI_Theme.Accent[1], DUI_Theme.Accent[2], DUI_Theme.Accent[3] }
                        or { 0.6, 0.6, 0.6 },
            }
        end
        return items
    end

    -- Flip a row the way a click on its checkbox would, so PGF's own handler runs.
    --
    -- That handler writes panel.state, which the dialog only creates in Init. This
    -- runs at file load too, well before any Init, so bail rather than tick a box
    -- whose state cannot be recorded - a half-applied selection is worse than none.
    local function SetRow(row, checked)
        if row.Act:GetChecked() == checked then return end
        if not panel.state then return end
        row.Act:SetChecked(checked)
        local onClick = row.Act:GetScript("OnClick")
        if onClick then onClick(row.Act) end
    end

    -- Persist the selection by challenge-mode ID rather than by slot.
    --
    -- PGF stores it as state.dungeon1..dungeon15, keyed by position in the list,
    -- and that list is built from C_ChallengeMode.GetMapTable() - which is empty
    -- early in a session and can come back in a different order. So the tick marks
    -- survive a reload while the dungeon under slot 3 may not be the one that was
    -- ticked, which is exactly "the highlight stayed but the filter changed".
    -- Keying on the dungeon itself makes the restore self-correcting.
    --
    -- Account-wide (DanUIDB), unlike PGF's per-character state, so the same
    -- dungeons come up on every character.
    local function SaveSelection()
        local saved = {}
        for _, row in ipairs(rows) do
            if row.cmId and row.Act:GetChecked() then saved[row.cmId] = true end
        end
        DanUIDB.LFGFilter.dungeons = saved
    end

    local function RestoreSelection()
        if not DanUIDB or not DanUIDB.LFGFilter then return end

        -- Rows only learn their cmId once InitChallengeModes has run. Until then
        -- there is nothing to match against, so leave the panel alone and wait to
        -- be called again from the hook below.
        local ready = false
        for _, row in ipairs(rows) do
            if row.cmId then ready = true; break end
        end
        -- Relabel on the way out regardless: the count on the button has to track
        -- what is actually ticked, even when the selection cannot be applied yet.
        if not ready or not panel.state then Label(); return end

        -- Nothing stored yet: adopt whatever PGF just restored instead of
        -- clearing the user's existing selection on first run.
        local saved = DanUIDB.LFGFilter.dungeons
        if not saved then SaveSelection(); Label(); return end

        for _, row in ipairs(rows) do
            if row.cmId then SetRow(row, saved[row.cmId] and true or false) end
        end
        Label()
        DUI_RefreshScrollDropdown(BuildItems())
    end

    local function OnPick(val)
        if val == "all" then
            for _, row in ipairs(rows) do SetRow(row, true) end
        elseif val == "none" then
            for _, row in ipairs(rows) do SetRow(row, false) end
        else
            local row = rows[val]
            if row then SetRow(row, not row.Act:GetChecked()) end
        end
        Label()
        SaveSelection()
        DUI_RefreshScrollDropdown(BuildItems())
    end

    -- The map table usually arrives after the panel is first built, so re-apply
    -- whenever PGF rebuilds the dungeon list.
    if panel.InitChallengeModes then
        hooksecurefunc(panel, "InitChallengeModes", RestoreSelection)
    end
    -- SwitchToPanel calls this after Init, which is the first moment the selection
    -- can actually be applied and the button labelled from real values.
    panel.duiRestoreDungeons = RestoreSelection
    RestoreSelection()

    btn:SetScript("OnClick", function(self)
        DUI_ShowScrollDropdown(self, BuildItems(), OnPick, nil, { keepOpen = true })
    end)
    btn:SetScript("OnHide", DUI_HideScrollDropdown)

    -- Group box moves down to make room for the button. The -5 is not slop:
    -- the XML anchors Difficulty at LEFT x=5 and every row below chains off it, so
    -- the rows sit 5px inside this frame. Pulling it 5px left is what puts the
    -- rows themselves on the column the buttons above use.
    panel.Group:ClearAllPoints()
    panel.Group:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", -5, -8)

    -- With the second column gone the dialog only needs to fit the group box, and
    -- an equal margin either side of it.
    function panel:GetDesiredDialogWidth()
        return (self.groupWidth or 245) + PAD * 2
    end

    Label()
end

-- The XML anchors panels 20px below the dialog top, which tucks the Group and
-- Dungeons headings under the title bar and its accent divider. Drop them clear.
local PANEL_TOP = 46

local function AnchorPanel(panel)
    if not panel or panel.duiAnchored then return end
    panel.duiAnchored = true
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", 0, -PANEL_TOP)
    panel:SetPoint("BOTTOMRIGHT", 0, 30)
end

-- Hiding the box leaves a tall empty strip, so measure where the visible content
-- actually ends and shrink the dialog to it. Measured rather than hardcoded
-- because each panel's content is a different height.
local function FitDialogHeight()
    local panel, state = Dialog.activePanel, Dialog.activeState
    if not panel or not state or state.minimized then return end

    local top = Dialog:GetTop()
    if not top then return end

    local lowest
    for _, child in ipairs({ panel:GetChildren() }) do
        if child ~= panel.Advanced and child:IsShown() then
            local b = child:GetBottom()
            if b and (not lowest or b < lowest) then lowest = b end
        end
    end
    if not lowest then return end

    local h = math.floor(top - lowest) + 52 -- room for the Reset / Search row
    if h < 200 or h > 700 then return end   -- never act on a bad measurement
    Dialog.maximizedHeight = h
    Dialog:SetHeight(h)
end

-------------------------------------------------------------------------------
-- Dialog chrome
-------------------------------------------------------------------------------

-- The template's panel art. Some pieces hang off a parentKey, some exist only as
-- a global named after the frame (the older $parentInset style), and the template
-- re-shows several of them whenever the window is shown - so this is driven off a
-- list and re-asserted on OnShow rather than done once and hoped for. The inset in
-- particular is a rounded nine-slice filling the body, which is exactly the sort of
-- thing that shows up as an odd-cornered grey slab behind the filters.
local CHROME_KEYS = {
    "NineSlice", "PortraitContainer", "Bg", "Inset", "TitleContainer",
    "TopTileStreaks", "BorderFrame",
}
local CHROME_SUFFIXES = {
    "Inset", "Bg", "TitleBg", "TopTileStreaks", "Portrait", "PortraitFrame",
    "TopLeftCorner", "TopRightCorner", "BotLeftCorner", "BotRightCorner",
    "LeftBorder", "RightBorder", "TopBorder", "BottomBorder",
}

local function HideChrome()
    for _, key in ipairs(CHROME_KEYS) do
        local obj = Dialog[key]
        if obj and obj.Hide then obj:Hide() end
    end
    local name = Dialog.GetName and Dialog:GetName()
    if name then
        for _, suffix in ipairs(CHROME_SUFFIXES) do
            local obj = _G[name .. suffix]
            if obj and obj.Hide then obj:Hide() end
        end
    end
    StripTextures(Dialog)
end

-- Docking to PVEFrame.
--
-- PGF anchored frame edge to frame edge, which lined up while both windows drew
-- the same Blizzard nine-slice: each one's art sat the same distance inside its
-- own frame bounds, so the two visible borders met in the middle. This window's
-- backdrop is flush with its frame now, so that inset survives only on PVEFrame's
-- side and the panels no longer touch. The offset closes it, and it is saved
-- rather than hardcoded because the right value moves with UI scale - /duiskin
-- dock <x> <y> nudges it live.
local DOCK_X, DOCK_Y = -8, 0

local function DockOffset()
    local dock = DanUIDB and DanUIDB.LFGFilter and DanUIDB.LFGFilter.dock
    if not dock then return DOCK_X, DOCK_Y end
    return dock.x or DOCK_X, dock.y or DOCK_Y
end

local function ApplyDock()
    if not PVEFrame then return end
    local x, y = DockOffset()
    Dialog:ClearAllPoints()
    Dialog:SetPoint("TOPLEFT", PVEFrame, "TOPRIGHT", x, y)
end

local function SkinDialog()
    if Dialog.duiSkinned then return end
    Dialog.duiSkinned = true

    HideChrome()
    -- The template repaints its own art on show, so re-assert both.
    Dialog:HookScript("OnShow", function()
        HideChrome()
        ApplyDock()
    end)

    -- PGF re-anchors on every show when the window is not user-movable; keep that
    -- behaviour and just correct the offset it lands on.
    if not Dialog.duiDocked then
        Dialog.duiDocked = true
        local origResetPosition = Dialog.ResetPosition
        function Dialog:ResetPosition()
            origResetPosition(self)
            ApplyDock()
        end
    end

    -- Same frame level as the dialog, so it sits behind every panel it parents.
    local bg = CreateFrame("Frame", nil, Dialog, "BackdropTemplate")
    bg:SetAllPoints(Dialog)
    bg:SetFrameLevel(Dialog:GetFrameLevel())
    bg:SetBackdrop({
        bgFile = WHITE, edgeFile = WHITE, tile = true, tileSize = 16, edgeSize = 2,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    bg:SetBackdropColor(unpack(DUI_Theme.MainBG))
    bg:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(bg, "border")
    DUI_RegisterMainBG(bg, "bg")
    DUI_AddDropShadow(bg)

    -- Depth. Sublevel 1 sits above the backdrop's own fill but still below the
    -- title chrome and every panel, so this washes the whole body without a
    -- gradient texture per section: light off the top, shaded into the bottom.
    local wash = bg:CreateTexture(nil, "BACKGROUND", nil, 1)
    wash:SetTexture(WHITE)
    wash:SetPoint("TOPLEFT", 2, -2)
    wash:SetPoint("BOTTOMRIGHT", -2, 2)
    wash:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0.28), CreateColor(1, 1, 1, 0.06))

    local divider = DUI_AddTitleChrome(bg)

    -- Accent bloom fading down off the title rule, so the header reads as a lit
    -- band rather than a line ruled across a flat panel.
    if divider then
        local bloom = bg:CreateTexture(nil, "BACKGROUND", nil, 2)
        bloom:SetTexture(WHITE)
        bloom:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, 0)
        bloom:SetPoint("TOPRIGHT", divider, "BOTTOMRIGHT", 0, 0)
        bloom:SetHeight(16)
        AddAccentPainter(function()
            local a = DUI_Theme.Accent
            bloom:SetGradient("VERTICAL", CreateColor(a[1], a[2], a[3], 0),
                                          CreateColor(a[1], a[2], a[3], 0.18))
        end)
    end

    Dialog.duiBackdrop = bg

    -- The template centres its title inside TitleContainer, which is inset for the
    -- portrait on one side and the buttons on the other, so it never lands on the
    -- window's actual centre. Use our own FontString on the backdrop, anchored the
    -- way DUI_CreateConfigFrame anchors every other DUI window title.
    if Dialog.TitleContainer then Dialog.TitleContainer:Hide() end
    local title = bg:CreateFontString(nil, "OVERLAY", "DUI_FontLarge")
    title:SetPoint("TOP", bg, "TOP", 0, -10)
    title:SetText("DUI LFG")
    title:SetTextColor(unpack(DUI_Theme.Accent))
    DUI_RegisterAccent(title, "text")
    Dialog.duiTitle = title

    Try("close button", SkinGlyphButton, Dialog.CloseButton, "X")

    -- Minimize is gone, so the window must never sit in the minimized state (that
    -- state swaps in the mini panel and would leave no way back).
    if Dialog.MaximizeMinimizeFrame then
        Dialog.MaximizeMinimizeFrame:Hide()
        Dialog.MaximizeMinimizeFrame:HookScript("OnShow", function(self) self:Hide() end)
    end
    if not Dialog.duiNoMinimize then
        Dialog.duiNoMinimize = true
        local origMaximizeMinimize = Dialog.MaximizeMinimize
        function Dialog:MaximizeMinimize()
            if self.activeState then self.activeState.minimized = false end
            origMaximizeMinimize(self)
        end
    end

    -- Footer: a rule to part the action row from the filters, and margins that
    -- line up with the filter column instead of the template's 5 and 7px.
    local footer = bg:CreateTexture(nil, "ARTWORK")
    footer:SetTexture(WHITE)
    footer:SetHeight(1)
    footer:SetPoint("BOTTOMLEFT", bg, "BOTTOMLEFT", PAD - 4, 36)
    footer:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -(PAD - 4), 36)
    AddAccentPainter(function()
        local a = DUI_Theme.Accent
        footer:SetVertexColor(a[1], a[2], a[3], 0.20)
    end)

    Try("search button", SkinFlatButton, Dialog.RefreshButton, true)
    Try("reset button", SkinIconButton, Dialog.ResetButton)

    if Dialog.RefreshButton then
        Dialog.RefreshButton:ClearAllPoints()
        Dialog.RefreshButton:SetSize(120, 24)
        Dialog.RefreshButton:SetPoint("BOTTOMRIGHT", -PAD, 9)
    end
    if Dialog.ResetButton then
        Dialog.ResetButton:ClearAllPoints()
        Dialog.ResetButton:SetPoint("BOTTOMLEFT", PAD, 9)
    end

    -- The cog opened PGF's own options panel, which DanUI replaced with the
    -- LFG Filter config in the DUI window. Reset stays.
    if Dialog.SettingsButton then
        Dialog.SettingsButton:Hide()
        Dialog.SettingsButton:HookScript("OnShow", function(self) self:Hide() end)
    end
end

-------------------------------------------------------------------------------
-- Apply
-------------------------------------------------------------------------------

local function SkinUsePGFButton()
    if not PGF.UsePGFButton then return end
    SkinCheckBox(PGF.UsePGFButton)
    -- Branded as DanUI in the group finder; the dialog title and its tooltip
    -- still name the upstream addon.
    if PGF.UsePGFButton.Text then
        PGF.UsePGFButton.Text:SetText("DUI")
        PGF.UsePGFButton.Text:SetWidth(30)
    end
end

-- Panels are declared in XML, so every widget in one already exists the first
-- time it is walked. Re-walking on each category switch allocates a table per
-- frame out of GetChildren and re-reads hundreds of widgets only to find that
-- they all carry duiSkinned already, so walk each panel once. PopupMenu's rows
-- are the one lazily-built part of the window, and they are hooked separately.
local function SkinPanelOnce(panel)
    if not panel or panel.duiWalked then return end
    panel.duiWalked = true
    SkinPanel(panel, 0)
end

local function SkinEverything(force)
    wipe(failures)
    Try("dialog chrome", SkinDialog)
    for id, panel in pairs(Dialog.panels or {}) do
        if force then panel.duiWalked = nil end
        Try("panel " .. tostring(id), SkinPanelOnce, panel)
        Try("advanced " .. tostring(id), HideAdvanced, panel)
        Try("anchor " .. tostring(id), AnchorPanel, panel)
        Try("dungeon list " .. tostring(id), CollapseDungeonList, panel)
    end
    Try("group finder checkbox", SkinUsePGFButton)
    return #failures
end

local function Report()
    print(("|cFF00FF00[DUI]|r LFG Filter skin: %d step(s) failed."):format(#failures))
    for i = 1, math.min(#failures, 8) do print("   " .. failures[i]) end
    if #failures > 8 then print(("   ...and %d more."):format(#failures - 8)) end
end

-- Measure the window rather than eyeball it: prints where the two frames actually
-- sit, the gap between them, and anything of Blizzard's still drawing on top of
-- the dialog. Both windows must be open for the rects to exist.
local function Dump()
    print("|cFF00FF00[DUI]|r LFG dialog geometry")

    local function Rect(f, label)
        if not f or not f.GetLeft or not f:GetLeft() then
            print(("   %s: not positioned (is the window open?)"):format(label))
            return false
        end
        print(("   %s: L=%.0f R=%.0f T=%.0f B=%.0f  %.0fx%.0f  shown=%s"):format(
            label, f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom(),
            f:GetWidth(), f:GetHeight(), tostring(f:IsShown())))
        return true
    end

    local okPVE, okDlg = Rect(PVEFrame, "PVEFrame"), Rect(Dialog, "Dialog")
    if okPVE and okDlg then
        print(("   horizontal gap: %.1f   vertical top offset: %.1f"):format(
            Dialog:GetLeft() - PVEFrame:GetRight(), Dialog:GetTop() - PVEFrame:GetTop()))
    end
    local x, y = DockOffset()
    print(("   dock offset: %d, %d   -- /duiskin dock <x> <y> to change"):format(x, y))

    local isPanel = {}
    for _, p in pairs(Dialog.panels or {}) do isPanel[p] = true end

    print("   Blizzard art still visible on the dialog:")
    local found = 0
    for _, r in ipairs({ Dialog:GetRegions() }) do
        if r:IsShown() and not r.duiOwned then
            found = found + 1
            print(("     %s  %s"):format(r:GetObjectType(), Named(r)))
        end
    end
    for _, c in ipairs({ Dialog:GetChildren() }) do
        if c:IsShown() and not isPanel[c] and c ~= Dialog.duiBackdrop then
            found = found + 1
            print(("     Frame  %s"):format(Named(c)))
        end
    end
    if found == 0 then print("     none") end
end

SkinEverything()
-- Silence means the pass ran clean; no message at all means this file never ran.
if #failures > 0 then Report() end

-- Re-run on demand without a reload, and say what state the window is in. This is
-- the quickest way to tell "the skin errored" apart from "the file never ran".
SLASH_DUISKIN1 = "/duiskin"
SlashCmdList["DUISKIN"] = function(msg)
    local args = {}
    for word in tostring(msg or ""):gmatch("%S+") do args[#args + 1] = word end
    local cmd = args[1] and args[1]:lower()

    if cmd == "dump" then Dump() return end

    if cmd == "dock" then
        local x, y = tonumber(args[2]), tonumber(args[3])
        if not x or not y then
            print("|cFF00FF00[DUI]|r usage: /duiskin dock <x> <y>   (current: "
                .. table.concat({ DockOffset() }, ", ") .. ")")
            return
        end
        if DanUIDB and DanUIDB.LFGFilter then
            DanUIDB.LFGFilter.dock = { x = x, y = y }
        end
        ApplyDock()
        print(("|cFF00FF00[DUI]|r LFG dock offset set to %d, %d"):format(x, y))
        return
    end

    SkinEverything(true) -- force a fresh walk so the report reflects a real pass
    Report()
    local panel = Dialog.activePanel
    print(("   dialog skinned: %s | cog hidden: %s | advanced hidden: %s"):format(
        tostring(Dialog.duiSkinned or false),
        tostring((Dialog.SettingsButton and not Dialog.SettingsButton:IsShown()) or false),
        tostring((panel and panel.Advanced and not panel.Advanced:IsShown()) or false)))
end

-- Every panel is walked once at load, so this normally finds nothing left to do;
-- it stays hooked for the layout steps, which depend on which panel is active,
-- and to cover a panel registered after load.
hooksecurefunc(Dialog, "SwitchToPanel", function(self)
    if not self.activePanel then return end
    SkinPanelOnce(self.activePanel)
    HideAdvanced(self.activePanel)
    AnchorPanel(self.activePanel)
    CollapseDungeonList(self.activePanel)
    if self.activePanel.duiRestoreDungeons then self.activePanel.duiRestoreDungeons() end
    C_Timer.After(0, FitDialogHeight) -- let the anchors settle before measuring
end)

-- PopupMenu builds its rows on first open.
if PremadeGroupsFilter and PremadeGroupsFilter.PopupMenuFrame then
    local popup = PremadeGroupsFilter.PopupMenuFrame
    if popup.SetBackdropColor then
        popup:SetBackdropColor(0.08, 0.08, 0.08, 0.95)
        popup:SetBackdropBorderColor(unpack(DUI_Theme.Accent))
        DUI_RegisterAccent(popup, "border")
    end
    popup:HookScript("OnShow", function(self)
        for _, btn in ipairs(self.Buttons or {}) do
            if not btn.duiSkinned then
                btn.duiSkinned = true
                SetFont(btn.Text, DUI_FontSmall, 0.9, 0.9, 0.9)
                local hl = btn:GetHighlightTexture()
                if hl then
                    hl:SetTexture(WHITE)
                    hl:SetVertexColor(DUI_Theme.Accent[1], DUI_Theme.Accent[2],
                        DUI_Theme.Accent[3], 0.25)
                end
            end
        end
    end)
end
