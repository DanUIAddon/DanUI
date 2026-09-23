-- Theme.lua
-- The look of the whole suite, in one window: the three colors every DUI widget
-- is painted from plus the panel opacity.
--
-- These controls used to live loose along the bottom of the main window -- two
-- 18px swatches on the left of the tab row and a 60px slider on the right -- which
-- gave three unlabeled chips no room to say what they did and no room to grow.
-- They are one "Skin" button and one panel now, which is also what makes a third
-- color (the grey button body) affordable.
--
-- The colors themselves live in DanUI.lua: DUI_Theme holds them, and the three
-- registries there (accent / main background / secondary) are what repaint the
-- widgets already on screen. This module is only the controls.

-- One color row: a chip, a label, and a click that opens Blizzard's picker.
--
-- The chip repaints through the same registry as every other themed widget, so a
-- right-click reset or an edit made from anywhere else is reflected here without
-- the panel having to watch for it.
--
-- get()             returns the live color table
-- set(r, g, b)      writes it through the DUI_Set* that owns the repaint
-- registerFn        the matching DUI_Register* for that color
local function ThemeSwatch(parent, label, get, set, registerFn, tooltip)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(20, 20)
    btn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    btn:SetBackdropBorderColor(0, 0, 0, 1)

    local function Repaint()
        local c = get()
        -- Painted opaque on purpose: as a color chip it still has to read as a
        -- color when the thing it stands for is set nearly transparent.
        btn:SetBackdropColor(c[1], c[2], c[3], 1)
    end
    Repaint()
    registerFn(btn, "fn", Repaint)

    local text = btn:CreateFontString(nil, "OVERLAY", "DUI_FontNormal")
    text:SetPoint("LEFT", btn, "RIGHT", 10, 0)
    text:SetText(label)

    btn:SetScript("OnClick", function()
        local c = get()
        ColorPickerFrame:SetupColorPickerAndShow({
            -- No opacity on any of the three: the background's alpha is the slider
            -- at the bottom of this panel, and the other two are always solid.
            -- Two controls writing one value would have to be kept in sync for no gain.
            swatchFunc = function()
                local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                set(nr, ng, nb)
            end,
            hasOpacity = false, r = c[1], g = c[2], b = c[3],
        })
    end)

    DUI_AddTooltip(btn, label, tooltip)
    return btn
end

local config = DUI_CreateConfigFrame("DUI_ThemeConfig", "Theme", 320, 320, "DUI_ThemeBtn")

-- Push the current theme back into the panel's own widgets. Only the opacity
-- slider needs it (the chips are in the color registries and repaint themselves),
-- but a slider is a stateful control, so a reset has to move the thumb.
function DUI_RefreshThemePanel()
    if config.init and config.opacity then
        config.opacity:SetValue(DUI_Theme.MainBG[4])
    end
end

-- Everything back to the shipped theme. Shared by the panel's button and the
-- right-click on the "Skin" button, so the two can never drift apart.
function DUI_ResetTheme()
    DUI_SetAccent(unpack(DUI_DEFAULT_ACCENT))
    DUI_SetMainBG(unpack(DUI_DEFAULT_MAINBG))
    DUI_SetSecondary(unpack(DUI_DEFAULT_SECONDARY))
    DUI_RefreshThemePanel()
end

function DUI_OpenThemeConfig()
    if not config.init then
        local L = DUI_CreateLayout(config)

        L:Header("Colors")
        L:Place(ThemeSwatch(config, "Accent color",
            function() return DUI_Theme.Accent end,
            function(r, g, b) DUI_SetAccent(r, g, b, 1) end,
            DUI_RegisterAccent,
            "Borders, headers, dividers, slider thumbs - everything the suite picks out."),
            { step = DUI_LAYOUT.ROW, band = true })

        L:Place(ThemeSwatch(config, "Background color",
            function() return DUI_Theme.MainBG end,
            function(r, g, b) DUI_SetMainBG(r, g, b) end,
            DUI_RegisterMainBG,
            { body = "The shade every DUI window is filled with.",
              note = "How solid it sits over the world is the opacity slider below." }),
            { step = DUI_LAYOUT.ROW, band = true })

        L:Place(ThemeSwatch(config, "Button color",
            function() return DUI_Theme.Secondary end,
            function(r, g, b) DUI_SetSecondary(r, g, b, 1) end,
            DUI_RegisterSecondary,
            "The body of buttons and tabs, and the border around dropdowns, sliders and list panes."),
            { step = DUI_LAYOUT.ROW, band = true })

        L:Header("Panel")
        -- The slider's "database" is the live theme table, with 4 as the key: the
        -- factory writes dbTable[key] itself, so pointing it at MainBG[4] means the
        -- value it stores and the value it displays are the same one. The callback
        -- still goes through DUI_SetMainBG, which is what saves and repaints.
        config.opacity = L:Slider("DUI_ThemeOpacitySlider", "Background opacity",
            -- Floor of 0.1 rather than 0: the last tenth is indistinguishable from
            -- fully clear, and bottoming out would leave every window looking gone.
            0.1, 1, 0.05, DUI_Theme.MainBG, 4,
            function(value)
                local c = DUI_Theme.MainBG
                DUI_SetMainBG(c[1], c[2], c[3], value)
            end,
            { value = DUI_Theme.MainBG[4],
              fmt = function(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end,
              tooltip = "How solid the panel background sits over the world." })

        L:Gap()
        L:Text("Widgets that are not registered for live recoloring pick up a new theme on the next /reload.")

        -- Reserve the pinned reset button's strip so the note above never lands under it.
        L:FitHeight(34)

        local reset = CreateFrame("Button", nil, config, "BackdropTemplate")
        reset:SetSize(140, 22)
        reset:SetPoint("BOTTOM", 0, 12)
        reset:SetText("Reset to Default")
        StyleAsTealTab(reset)
        reset:SetScript("OnClick", DUI_ResetTheme)
        DUI_AddTooltip(reset, "Reset to Default",
            "Puts all three colors and the opacity back to the theme DUI ships with.")

        config.init = true
    end

    DUI_RefreshThemePanel()
    config:Show()
end

-- The button, in the bottom-left corner of the main window where the accent
-- swatch used to be. Sized and styled as a tab so it shares a baseline with the
-- Tools / UI tab row across the middle of the same strip, without being mistaken
-- for a third tab.
local ThemeBtn = CreateFrame("Button", "DUI_ThemeBtn", DUI_MainFrame, "BackdropTemplate")
ThemeBtn:SetSize(46, 25)
ThemeBtn:SetPoint("BOTTOMLEFT", 10, 10)
ThemeBtn:SetText("Skin")
StyleAsTealTab(ThemeBtn)
ThemeBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
ThemeBtn:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        DUI_ResetTheme()
        return
    end
    DUI_ToggleConfig(config, DUI_OpenThemeConfig)
end)
ThemeBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetFrameStrata("TOOLTIP")
    GameTooltip:SetFrameLevel(self:GetFrameLevel() + 50)
    GameTooltip:SetText("Theme", 1, 1, 1)
    GameTooltip:AddLine("Left-click: edit the color theme.", nil, nil, nil, true)
    GameTooltip:AddLine("Right-click: reset to default.", nil, nil, nil, true)
    GameTooltip:AddLine("Some elements update after /reload.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end)
ThemeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
