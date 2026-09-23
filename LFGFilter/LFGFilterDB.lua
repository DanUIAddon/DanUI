-- LFGFilter/LFGFilterDB.lua
-------------------------------------------------------------------------------
-- Dan UI :: LFG Filter - saved-variable bootstrap
--
-- The vendored PGF source was rewritten to read and write DanUI's own saved
-- variables instead of registering two of its own:
--
--   PremadeGroupsFilterSettings  ->  DanUIDB.LFGFilter.settings   (account-wide)
--   PremadeGroupsFilterState     ->  DanUICharDB.LFGFilter        (per character)
--
-- Those are plain table paths rather than aliases, so PGF's state migrations can
-- reassign the whole table (MigrateStateV5 does) and it still lands in the right
-- place - no write-back pass needed.
--
-- PGF reads both from its own ADDON_LOADED handler, so the tables have to exist
-- by then. This file must load BEFORE LFGFilter/Init.lua: it loads first, so its
-- frame registers first, so it runs first. See the LFG Filter block in DanUI.toc.
--
-- Deliberately does NOT touch DanUIDB at file scope - DanUI.lua's own handler
-- migrates a nil DanUIDB from the legacy DansRandomNeedsDB, and creating an empty
-- table early would silently skip that.
-------------------------------------------------------------------------------

local function EnsureTables()
    DanUIDB = DanUIDB or {}
    DanUIDB.LFGFilter = DanUIDB.LFGFilter or {}
    DanUIDB.LFGFilter.settings = DanUIDB.LFGFilter.settings or {}

    DanUICharDB = DanUICharDB or {}
    DanUICharDB.LFGFilter = DanUICharDB.LFGFilter or {}
end

local bootstrap = CreateFrame("Frame")
bootstrap:RegisterEvent("ADDON_LOADED")
bootstrap:SetScript("OnEvent", function(self, _, name)
    if name ~= "DanUI" then return end
    EnsureTables()
    self:UnregisterEvent("ADDON_LOADED")
end)
