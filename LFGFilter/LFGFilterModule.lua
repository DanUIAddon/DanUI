-- LFGFilter/LFGFilterModule.lua
-------------------------------------------------------------------------------
-- Dan UI :: LFG Filter
--
-- DanUI module wrapper around Premade Groups Filter (Bernhard Saumweber, GPL-2.0),
-- vendored under LFGFilter/. The upstream tree is kept as close to as-shipped as
-- possible so it stays easy to diff against new PGF releases; everything
-- DanUI-specific lives in this file.
--
-- Changes made inside the vendored tree (all marked with a `DUI:` comment):
--   * saved variables renamed throughout - PremadeGroupsFilterSettings became
--     DanUIDB.LFGFilter.settings, PremadeGroupsFilterState became
--     DanUICharDB.LFGFilter. See LFGFilterDB.lua for why they are plain table
--     paths rather than aliases.
--   * Init.lua - dropped the file-scope settings initializer (DanUIDB may not
--     exist that early; LFGFilterDB.lua owns it now)
--   * Settings/Settings.lua - the Blizzard canvas panel and its
--     Settings.RegisterAddOnCategory call are gone, so LFG Filter no longer
--     appears under Settings > AddOns. What remains is the settings table, now
--     exposed as PGF.SettingsTable and rendered by the config panel below;
--     PGF.OpenSettings points at that panel so the dialog gear button still works.
--   * Settings/Settings.lua - texture paths repointed at DanUI\LFGFilter\Textures
-- Plus DanUI.toc carries `## X-Flavor: Retail`, which Init.lua reads to decide
-- which client it is running on. LFGFilterSkin.lua restyles the dialog itself.
--
-- Every PGF file takes its namespace from `select(2, ...)`, i.e. DanUI's own
-- addon-private table, so `PGF` below is the same table those files populate.
-- None of PGF's keys collide with the ones AutoPayout / GuildBankSort put there.
--
-- Master toggle scope: the DanUI checkbox turns off result filtering, the filter
-- dialog, and the PGF checkbox on the group finder. The cosmetic extras (class
-- bars, leader crown, rating, group age, tooltips) reset themselves from their own
-- settings, so they keep their individual checkboxes in the config panel below
-- rather than being force-cleared here.
-------------------------------------------------------------------------------

local _, PGF = ...
local L_ = PGF.L  -- PGF's localization table; `L` is the layout cursor inside the panel builder

local db                            -- DanUIDB.LFGFilter
local Dialog = PGF.Dialog           -- PremadeGroupsFilterDialog
local UsePGFButton = PGF.UsePGFButton

function DUI_GetLFGFilterDefaults()
    return {
        enabled = true,
    }
end

local function MasterEnabled()
    -- Default to on until the DB is initialized, so PGF behaves normally during
    -- the window between file load and ADDON_LOADED.
    return db == nil or db.enabled
end

-- Filtering and dialog visibility both funnel through these two Dialog methods, so
-- wrapping them is enough to make the master toggle take effect immediately without
-- a reload. PGF resolves them by table lookup at call time, so its own
-- hooksecurefunc handlers pick these up too.
local origGetEnabled = Dialog.GetEnabled
function Dialog:GetEnabled()
    if not MasterEnabled() then return false end
    return origGetEnabled(self)
end

local origToggle = Dialog.Toggle
function Dialog:Toggle()
    if not MasterEnabled() then self:Hide() return end
    origToggle(self)
end

-- Sort the dungeon list by the leader's M+ rating, highest first.
--
-- PGF's default order already considers rating, but only as a late tie-breaker,
-- behind applications, party fit, friends and guildmates. Returning a sorting
-- expression promotes it to the primary key; equal ratings still fall through to
-- PGF's usual ordering. Note this means your own applications no longer pin to
-- the top of the list - they sort by rating with everything else.
--
-- Scoped to the dungeon panel: env.mprating is only populated for dungeon
-- results, and PGF's own comparator guards it with the same category check.
-- Nothing gates this on the master toggle because it does not need to be -
-- sorting only runs from FilterSearchResults, which already returns early when
-- the filter is off, so this follows the DUI checkbox automatically.
local origGetSortingExpression = Dialog.GetSortingExpression
function Dialog:GetSortingExpression()
    local userSorting = origGetSortingExpression(self)
    -- Never override a sort the user typed themselves.
    if userSorting and userSorting ~= "" then return userSorting end
    if self.activePanel and self.activePanel.name == "dungeon" then
        return "mprating desc"
    end
    return userSorting
end

function DUI_LFGFilterApplyEnabled(enabled)
    if db then db.enabled = enabled and true or false end

    if UsePGFButton then
        UsePGFButton:SetShown(MasterEnabled())
        if MasterEnabled() then UsePGFButton:UpdateChecked() end
    end
    Dialog:Toggle()

    -- Re-run the filter so the visible list picks it back up (or drops it).
    if LFGListFrame and LFGListFrame.SearchPanel and LFGListFrame.SearchPanel:IsVisible() then
        PGF.FilterSearchResults()
    end
end

function DUI_InitLFGFilter()
    db = DUI_InitModuleDB("LFGFilter", DUI_GetLFGFilterDefaults)

    local IsAddOnLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
    if IsAddOnLoaded and IsAddOnLoaded("PremadeGroupsFilter") then
        print("|cFF00FF00[DUI]|r LFG Filter: the standalone Premade Groups Filter addon is also "
            .. "enabled. Disable it - running both double-hooks the group finder.")
    end

    DUI_LFGFilterApplyEnabled(db.enabled)
end

-------------------------------------------------------------------------------
-- Configuration UI
--
-- Rendered straight off PGF.SettingsTable so it stays in step with upstream:
-- headers and checkboxes come out as DUI widgets, driven by the same
-- DanUIDB.LFGFilter.settings keys the Blizzard-options panel writes.
-------------------------------------------------------------------------------

-- Rows carrying a preview image need the extra height; the tallest is 32px.
local IMG_ROW_H = 38
-- Room the preview strips were authored to fit (they used to start at a fixed
-- x=278 in a 400px list). Reserved on the right of every row, image or not, so the
-- option labels all wrap at the same place rather than each row finding its own.
local IMG_COL_W = 122

local config = DUI_CreateConfigFrame("DUI_LFGFilterConfig", "LFG Filter", 460, 560, "DUI_LFGFilterBtn")

-- PGF's settings list opens with five ungrouped checkboxes before its first
-- header. Every other DanUI panel starts with a section, and a section is what
-- draws the card, so name that opening group rather than leave it floating.
local FIRST_SECTION = "General"

-- Renders PGF.SettingsTable through DanUI's layout cursor.
--
-- This used to be a hand-rolled row list inside a black inset scroll box, which is
-- exactly how PGF's own standalone options panel looks -- so the one module that
-- was vendored whole was also the one that still read as somebody else's addon.
-- There is no inner scroll frame any more either: the panel self-sizes and the
-- launcher's docking pane scrolls it, the same as every other module.
local function BuildSettingRows(L)
    local rows = {}
    local settings = DanUIDB.LFGFilter.settings
    -- Labels stop short of the preview column. Width is set before the row height
    -- is measured, because a label that wraps is what decides how tall its row is.
    local labelW = math.max(L:ContentWidth(DUI_LAYOUT.INDENT) - IMG_COL_W - 42, 120)
    local seenHeader = false

    for _, entry in ipairs(PGF.SettingsTable) do
        if entry.visible then
            if entry.type == "header" then
                L:Header(entry.title)
                seenHeader = true
            elseif entry.type == "checkbox" then
                if not seenHeader then
                    L:Header(FIRST_SECTION)
                    seenHeader = true
                end

                -- PGF's own panel carried the description and the taint warning as
                -- tooltips; they go through DUI_AddTooltip now so LFG Filter hovers
                -- like the rest of DanUI. The warning keeps its own line, prefixed
                -- rather than coloured -- a note line is grey here.
                local notes = {}
                if entry.warning then notes[#notes + 1] = "Warning: " .. entry.warning end
                if entry.reload then notes[#notes + 1] = "Needs a UI reload to take effect." end
                local tip = {
                    body = entry.tooltip,
                    note = #notes > 0 and table.concat(notes, " ") or nil,
                }

                local title = entry.reload and (entry.title .. " *") or entry.title
                local cb = DUI_CreateCheckbox(config, title, L:Y(), settings,
                    entry.key, entry.callback, tip)
                cb.Text:SetWidth(labelW)
                cb.Text:SetWordWrap(true)

                -- The same preview strips PGF showed in its own options panel, so
                -- what each option does stays visible at a glance. Anchored off the
                -- right edge, inside the section card, rather than at the fixed x
                -- the 400px-wide original used.
                if entry.image then
                    local img = config:CreateTexture(nil, "ARTWORK")
                    img:SetTexture(entry.image)
                    img:SetPoint("TOPRIGHT", config, "TOPRIGHT", -24, L:Y() - 2)
                end

                local rowH = math.max(DUI_LAYOUT.ROW, cb.Text:GetStringHeight() + 12,
                    entry.image and IMG_ROW_H or 0)
                L:Place(cb, { step = rowH })
                rows[#rows + 1] = { cb = cb, key = entry.key }
            elseif entry.type == "note" then
                L:Gap(6)
                L:Text(entry.text)
            end
        end
    end

    return rows
end

function DUI_OpenLFGFilterConfig()
    db = DUI_InitModuleDB("LFGFilter", DUI_GetLFGFilterDefaults)

    if not config.init then
        local L = DUI_CreateLayout(config)
        config.rows = BuildSettingRows(L)
        L:FitHeight(40) -- room for the Reset button pinned to the bottom

        local resetBtn = CreateFrame("Button", nil, config, "BackdropTemplate")
        resetBtn:SetSize(150, 25); resetBtn:SetPoint("BOTTOMRIGHT", -16, 12)
        resetBtn:SetText("Reset Filters"); StyleAsTealTab(resetBtn)
        resetBtn:SetScript("OnClick", function()
            if Dialog.activePanel then Dialog:Reset() end
        end)
        DUI_AddTooltip(resetBtn, "Reset Filters", L_["dialog.reset"])

        config.init = true
    end

    for _, row in ipairs(config.rows) do
        row.cb:SetChecked(DanUIDB.LFGFilter.settings[row.key] and true or false)
    end
    config:Show()
end
