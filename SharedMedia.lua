-------------------------------------------------------------------------------
-- DanUI - Shared Media
--
-- Registers the DUI soundpack (formerly the standalone "SharedMedia_UB" addon)
-- with LibSharedMedia-3.0 so it shows up in every LSM-aware sound dropdown:
-- DanUI's own modules (BreakTimer, LowHealthReminder, CombatAlerts),
-- WeakAuras, BigWigs, etc.
--
-- The display names are kept byte-for-byte identical to the old SharedMedia_UB
-- registrations - DanUI stores the LSM *name* in DanUIDB, so changing them here
-- would silently reset everyone's saved sound picks.
--
-- Files live in DanUI\Sounds\ and DanUI\Textures\.
-------------------------------------------------------------------------------
local LSM = LibStub:GetLibrary("LibSharedMedia-3.0")

local SOUND = [[Interface\AddOns\DanUI\Sounds\]]

-- name shown in dropdowns -> file in DanUI\Sounds\
local sounds = {
    -- Voice clips / memes
    { "|cFFFFFF00FREDORAWR|r",          "UB_FREDORAWR.ogg" },
    -- A movie clip: not ours to publish, so the file is gitignored and the packager
    -- strips this entry from the release.
    --@do-not-package@
    { "|cFFFFFF00VADERNO|r",            "UB_VADERNO.ogg" },
    --@end-do-not-package@
    { "|cFFFFFF00CHRISFUNNY|r",         "UB_CHRISFUNNY.ogg" },
    { "|cFFFFFF00CHRISOHGOD|r",         "UB_CHRISOHGOD.ogg" },
    { "|cFFFFFF00DOIT|r",               "UB_DOIT.ogg" },
    { "|cFFFFFF00GUNCOCK|r",            "UB_GUNCOCK.ogg" },
    { "|cFFFFFF00GUNSHOT|r",            "UB_GUNSHOT.ogg" },
    { "|cFFFFFF00KAIBADEAD|r",          "UB_KAIBADEAD.ogg" },
    { "|cFFFFFF00KAIBAPLEASE|r",        "UB_KAIBAPLEASE.ogg" },
    { "|cFFFFFF00CRINGEDAWG|r",         "UB_POLOCRINGEDAWG.ogg" },
    { "|cFFFFFF00POLOLAUGH|r",          "UB_PoloLaugh.ogg" },
    { "|cFFFFFF00SALBAM|r",             "UB_SALBAM.ogg" },
    { "|cFFFFFF00SURPRISE|r",           "UB_SURPRISEMFUCKER.ogg" },
    { "|cFFFFFF00YUMYUMYUMMERS|r",      "UB_YUMYUM.ogg" },
    { "|cFFFFFF00ELYANIPLAY|r",         "UB_ELYANIPLAY.ogg" },
    { "|cFFFFFF00ELYANIBUST|r",         "UB_ELYANIBUST.ogg" },
    { "|cFFFFFF00ELYANIBUSTLONG|r",     "UB_ELYANIBUSTLONG.ogg" },
    { "|cFFFFFF00SALLOOSTY|r",          "UB_SALLUST.ogg" },
    { "|cFFFFFF00FREDOGOOFED|r",        "UB_FREDOGOOFED.ogg" },
    { "|cFFFFFF00CHIZOCEANIA|r",        "UB_CHIZOCEANIA.ogg" },
    { "|cFFFFFF00BOTTLES_DARVEIN|r",    "UB_BOTTLES.ogg" },
    { "|cFFFFFF00YOURMOVES|r",          "UB_YOURMOVES.ogg" },
    { "|cFFFFFF00SSPI|r",               "UB_SSPI.ogg" },
    { "|cFFFFFF00PRETTYGOOD|r",         "UB_PRETTYGOOD.ogg" },
    { "|cFFFFFF00FORCHIZDONTOPEN|r",    "UB_FORCHIZDONTOPEN.ogg" },
    { "|cFFFFFF00PEWPEWPEW|r",          "UB_PEWPEWPEW.ogg" },
    { "|cFFFFFF00READYCHECKPULL|r",     "UB_READYCHECKPULL.ogg" },
    { "|cFFFFFF00SlingshotEngaged|r",   "SlingshotEngaged.ogg" },
    { "|cFFFFFF00UB_SALONANOOO|r",      "UB_SALONANOOO.ogg" },
    { "|cFFFFFF00UB_KAIBAMYGOD|r",      "UB_KAIBAMYGOD.ogg" },
    { "|cFFFFFF00UB_ElyaniHairflip|r",  "UB_ElyaniHairflip.ogg" },
    { "|cFFFFFF00UB_ElyaniLaugh|r",     "UB_ElyaniLaugh.ogg" },
    { "|cFFFFFF00UB_ElyaniArise|r",     "UB_ElyaniArise.ogg" },
    { "|cFFFFFF00UB_ElyaniGamedge|r",   "UB_ElyaniGamedge.ogg" },
    { "|cFFFFFF00UB_ELYANIDEAD|r",      "UB_ELYANIDEAD.ogg" },
    { "|cFFFFFF00UB_BoomcatYell|r",     "UB_BoomcatYell.ogg" },

    -- TTS callouts
    { "|cFF9CAF88UB_lifebloomtts|r",    "lifebloomtts.ogg" },
    { "|cFF9CAF88convoketts|r",         "convoketts.ogg" },
    { "|cFF9CAF88tranquilitytts|r",     "tranquilitytts.ogg" },
    { "|cFF9CAF88incarntts|r",          "incarntts.ogg" },
    { "|cFF9CAF88innervatetts|r",       "innervatetts.ogg" },
    { "|cFF9CAF88ironbarktts|r",        "ironbarktts.ogg" },
    { "|cFF9CAF88invokeyulontts|r",     "invokeyulontts.ogg" },
    { "|cFF9CAF88revivaltts|r",         "revivaltts.ogg" },
    { "|cFF9CAF88conduittts|r",         "conduittts.ogg" },
    { "|cFF9CAF88personaltts|r",        "personaltts.ogg" },
    { "|cFF9CAF88barkskintts|r",        "barkskintts.ogg" },
    { "|cFF9CAF88emptythebagtts|r",     "emptythebagtts.ogg" },
    { "|cFF9CAF88usepottts|r",          "usepottts.ogg" },
    { "|cFF9CAF88orbdefencetts|r",      "orbdefencetts.ogg" },
    { "|cFF9CAF88stampedingroartts|r",  "stampedingroartts.ogg" },
    { "|cFF9CAF88checkdpsmeterstts|r",  "checkdpsmeterstts.ogg" },
    { "|cFF9CAF88altertimetts|r",       "altertimetts.ogg" },
    { "|cFF9CAF88defensivetts|r",       "defensivetts.ogg" },
    { "|cFF9CAF88icecoldtts|r",         "icecoldtts.ogg" },
    { "|cFF9CAF88rayoffrosttts|r",      "rayoffrosttts.ogg" },
    { "|cFF9CAF88redtts|r",             "redtts.ogg" },
    { "|cFF9CAF88bluetts|r",            "bluetts.ogg" },
    { "|cFF9CAF88clickingrunestts|r",   "clickingrunestts.ogg" },
    { "|cFF9CAF88innervatereckpottts|r","innervatereckpottts.ogg" },

    -- Used as defaults by DanUI modules
    { "|cFFFFFF00deathsound|r",         "deathsound.ogg" },
    { "|cFFFFFF00messagesound|r",       "messagesound.ogg" },
    { "|cFF9CAF88dispeltts|r",          "dispeltts.mp3" },
    { "|cFF9CAF88invokechijitts|r",     "invokechijitts.mp3" },
    { "|cFF9CAF88lifecocoontts|r",      "lifecocoontts.mp3" },
    { "|cFF9CAF88Setmarkerstts|r",      "Setmarkerstts.mp3" },
    { "|cFF9CAF88soaktts|r",            "soaktts.mp3" },
    { "|cFF9CAF88transcendancetts|r",   "transcendancetts.mp3" },
    { "|cFF9CAF88gotomarkertts|r",      "gotomarkertts.mp3" },
    { "|cFF9CAF88lookoutformushroomtts|r","lookoutformushroomtts.mp3" },
    { "|cFF9CAF88debuffstts|r",         "debuffstts.mp3" },
    { "|cFF9CAF88stacktts|r",           "stacktts.mp3" },
    { "|cFF9CAF88tigerslusttts|r",      "tigerslusttts.mp3" },
    { "|cFF9CAF88wavestts|r",           "wavestts.mp3" },
    { "|cFF9CAF88ringofpeacetts|r",     "ringofpeacetts.mp3" },
    { "|cFF9CAF88soakguillotinetts|r",  "soakguillotinetts.mp3" },
    { "|cFF9CAF88safetts|r",            "safetts.mp3" },
    { "|cFF9CAF883ghoststts|r",         "3ghoststts.mp3" },
}

for _, entry in ipairs(sounds) do
    LSM:Register("sound", entry[1], SOUND .. entry[2])
end

-- Arrow textures (previously SharedMedia_UB\Icons\). Not registered as an LSM
-- "background"/"border" type - they are referenced directly by path from
-- WeakAuras, so they only need to exist on disk. Exposed here so the paths are
-- greppable from one place if they ever move again.
DUI_MediaTextures = {
    arrowsone   = [[Interface\AddOns\DanUI\Textures\arrowsone.tga]],
    arrowstwo   = [[Interface\AddOns\DanUI\Textures\arrowstwo.tga]],
    arrowsthree = [[Interface\AddOns\DanUI\Textures\arrowsthree.tga]],
    arrowsfour  = [[Interface\AddOns\DanUI\Textures\arrowsfour.tga]],
}
