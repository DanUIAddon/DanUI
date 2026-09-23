-------------------------------------------------------------------------------
-- Premade Groups Filter
-------------------------------------------------------------------------------
-- Copyright (C) 2026 Bernhard Saumweber
--
-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation; either version 2 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License along
-- with this program; if not, write to the Free Software Foundation, Inc.,
-- 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
-------------------------------------------------------------------------------

local PGF = select(2, ...)
local L = PGF.L
local C = PGF.C

local PGFSettingsTable = {
    {
        key = "dialogMovable",
        type = "checkbox",
        title = L["settings.dialogMovable.title"],
        tooltip = L["settings.dialogMovable.tooltip"],
        visible = true,
    },
    {
        key = "classNamesInTooltip",
        type = "checkbox",
        title = L["settings.classNamesInTooltip.title"],
        tooltip = L["settings.classNamesInTooltip.tooltip"],
        visible = true,
    },
    {
        key = "coloredGroupTexts",
        type = "checkbox",
        title = L["settings.coloredGroupTexts.title"],
        tooltip = L["settings.coloredGroupTexts.tooltip"],
        visible = true,
    },
    {
        key = "groupAge",
        type = "checkbox",
        title = L["settings.groupAge.title"],
        tooltip = L["settings.groupAge.tooltip"],
        visible = true,
    },
    {
        key = "compactListEntries",
        type = "checkbox",
        title = L["settings.compactListEntries.title"],
        tooltip = L["settings.compactListEntries.tooltip"],
        warning = L["settings.warning.taint"],
        visible = PGF.IsRetail(),
        reload = true,
    },
    {
        type = "header",
        title = L["settings.section.mythicplus.title"],
        visible = true,
    },
    {
        key = "ratingInfo",
        type = "checkbox",
        title = L["settings.ratingInfo.title"],
        tooltip = L["settings.ratingInfo.tooltip"],
        image = "Interface\\AddOns\\DanUI\\LFGFilter\\Textures\\SettingsRatingInfo",
        visible = true,
    },
    {
        key = "rioRatingColors",
        type = "checkbox",
        title = L["settings.rioRatingColors.title"],
        tooltip = L["settings.rioRatingColors.tooltip"],
        image = nil,
        visible = RaiderIO and true or false,
    },
    {
        key = "specIcon",
        type = "checkbox",
        title = L["settings.specIcon.title"],
        tooltip = L["settings.specIcon.tooltip"],
        image = "Interface\\AddOns\\DanUI\\LFGFilter\\Textures\\SettingsSpecIcon",
        visible = PGF.SupportsSpecializations(),
    },
    {
        key = "classCircle",
        type = "checkbox",
        title = L["settings.classCircle.title"],
        tooltip = L["settings.classCircle.tooltip"],
        visible = false, -- circle not available in wrath and provided by default in retail since 10.2.7
    },
    {
        key = "classBar",
        type = "checkbox",
        title = L["settings.classBar.title"],
        tooltip = L["settings.classBar.tooltip"],
        image = "Interface\\AddOns\\DanUI\\LFGFilter\\Textures\\SettingsClassBar",
        visible = true,
    },
    {
        key = "leaderCrown",
        type = "checkbox",
        title = L["settings.leaderCrown.title"],
        tooltip = L["settings.leaderCrown.tooltip"],
        image = "Interface\\AddOns\\DanUI\\LFGFilter\\Textures\\SettingsLeaderCrown",
        visible = true,
    },
    {
        key = "missingRoles",
        type = "checkbox",
        title = L["settings.missingRoles.title"],
        tooltip = L["settings.missingRoles.tooltip"],
        image = "Interface\\AddOns\\DanUI\\LFGFilter\\Textures\\SettingsMissingRoles",
        visible = PGF.SupportsDragonflightUI(),
    },
    {
        type = "header",
        title = L["settings.section.signup.title"],
        visible = true,
    },
    {
        key = "oneClickSignUp",
        type = "checkbox",
        title = L["settings.oneClickSignUp.title"],
        tooltip = L["settings.oneClickSignUp.tooltip"],
        warning = L["settings.warning.taint"],
        visible = true,
    },
    {
        key = "cancelOldestApp",
        type = "checkbox",
        title = L["settings.cancelOldestApp.title"],
        tooltip = L["settings.cancelOldestApp.tooltip"],
        visible = true,
    },
    {
        key = "persistSignUpNote",
        type = "checkbox",
        title = L["settings.persistSignUpNote.title"],
        tooltip = L["settings.persistSignUpNote.tooltip"],
        warning = L["settings.warning.taint"],
        reload = true,
        visible = true,
    },
    {
        key = "signupOnEnter",
        type = "checkbox",
        title = L["settings.signupOnEnter.title"],
        tooltip = L["settings.signupOnEnter.tooltip"],
        visible = true,
    },
    {
        key = "skipSignUpDialog",
        type = "checkbox",
        title = L["settings.skipSignUpDialog.title"],
        tooltip = L["settings.skipSignUpDialog.tooltip"],
        warning = L["settings.warning.taint"],
        visible = true,
    },
    {
        key = "signUpDeclined",
        type = "checkbox",
        title = L["settings.signUpDeclined.title"],
        tooltip = L["settings.signUpDeclined.tooltip"],
        warning = L["settings.warning.taint"],
        visible = PGF.IsRetail(),
        callback = function (enabled)
            -- clear existing declines when the setting is checked
            if enabled then
                LFGListFrame.declines = {}
            end
        end
    },
    {
        type = "note",
        text = L["settings.info.reload"],
        visible = PGF.IsRetail(),
    },
}

-- DUI: expose the settings definitions so DanUI's own config panel can render the
-- same list with DUI widgets instead of duplicating it. Vendored-source change.
PGF.SettingsTable = PGFSettingsTable

-- DUI: the upstream canvas panel and its Settings.RegisterAddOnCategory call were
-- removed, so LFG Filter no longer shows up under Settings > AddOns. The table
-- above is now pure data, rendered by DUI_OpenLFGFilterConfig in
-- LFGFilterModule.lua. Settings/Settings.xml is unloaded for the same reason.
--
-- PGFDialog's gear button calls this, so point it at the DUI panel.
function PGF.OpenSettings()
    if DUI_OpenLFGFilterConfig then DUI_OpenLFGFilterConfig() end
end
