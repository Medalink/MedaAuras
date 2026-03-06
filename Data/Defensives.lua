local ADDON_NAME, ns = ...

local DefensiveData = {}
ns.DefensiveData = DefensiveData

if MedaAuras and MedaAuras.Log then
    MedaAuras.Log("[DefensiveData] Loaded OK")
end

-- ============================================================================
-- All defensive spells keyed by spellID (fast lookup after laundering)
--
-- category:
--   "external"  = cast on another player (Pain Suppression, Ironbark, etc.)
--   "party"     = party-wide / raid CD (Rallying Cry, Darkness, etc.)
--   "major"     = major personal (long CD, strong effect)
--   "personal"  = shorter personal CD
--
-- cd       = base cooldown in seconds
-- duration = buff/effect duration in seconds (0 if instant/passive)
-- icon     = hardcoded texture ID (avoids C_Spell taint issues)
-- ============================================================================

DefensiveData.ALL_DEFENSIVES = {
    -- ========== PARTY-WIDE / RAID CDs ==========
    [97462]  = { name = "Rallying Cry",       cd = 180, duration = 10, icon = 132351,  category = "party",    class = "WARRIOR" },
    [51052]  = { name = "Anti-Magic Zone",     cd = 120, duration = 8,  icon = 237510,  category = "party",    class = "DEATHKNIGHT" },
    [196718] = { name = "Darkness",            cd = 180, duration = 8,  icon = 1305154, category = "party",    class = "DEMONHUNTER" },
    [98008]  = { name = "Spirit Link Totem",   cd = 180, duration = 6,  icon = 237586,  category = "party",    class = "SHAMAN" },
    [62618]  = { name = "Power Word: Barrier", cd = 180, duration = 10, icon = 253400,  category = "party",    class = "PRIEST" },
    [374227] = { name = "Zephyr",              cd = 120, duration = 8,  icon = 4622452, category = "party",    class = "EVOKER" },

    -- ========== EXTERNALS (cast on others) ==========
    [33206]  = { name = "Pain Suppression",    cd = 180, duration = 8,  icon = 135936,  category = "external", class = "PRIEST" },
    [102342] = { name = "Ironbark",            cd = 90,  duration = 12, icon = 572025,  category = "external", class = "DRUID" },
    [1022]   = { name = "Blessing of Protection", cd = 300, duration = 10, icon = 135964, category = "external", class = "PALADIN" },
    [6940]   = { name = "Blessing of Sacrifice",  cd = 120, duration = 12, icon = 135966, category = "external", class = "PALADIN" },
    [116849] = { name = "Life Cocoon",         cd = 120, duration = 12, icon = 627485,  category = "external", class = "MONK" },
    [47788]  = { name = "Guardian Spirit",     cd = 180, duration = 10, icon = 237542,  category = "external", class = "PRIEST" },

    -- ========== MAJOR PERSONALS ==========
    [871]    = { name = "Shield Wall",         cd = 180, duration = 8,  icon = 132362,  category = "major",    class = "WARRIOR" },
    [118038] = { name = "Die by the Sword",    cd = 120, duration = 8,  icon = 132336,  category = "major",    class = "WARRIOR" },
    [48792]  = { name = "Icebound Fortitude",  cd = 180, duration = 8,  icon = 237525,  category = "major",    class = "DEATHKNIGHT" },
    [61336]  = { name = "Survival Instincts",  cd = 180, duration = 6,  icon = 236169,  category = "major",    class = "DRUID" },
    [115203] = { name = "Fortifying Brew",     cd = 360, duration = 15, icon = 615341,  category = "major",    class = "MONK" },
    [642]    = { name = "Divine Shield",       cd = 300, duration = 8,  icon = 524354,  category = "major",    class = "PALADIN" },
    [104773] = { name = "Unending Resolve",    cd = 180, duration = 8,  icon = 136150,  category = "major",    class = "WARLOCK" },
    [186265] = { name = "Aspect of the Turtle", cd = 180, duration = 8, icon = 132199,  category = "major",    class = "HUNTER" },
    [45438]  = { name = "Ice Block",           cd = 240, duration = 10, icon = 135841,  category = "major",    class = "MAGE" },
    [31224]  = { name = "Cloak of Shadows",    cd = 120, duration = 5,  icon = 136177,  category = "major",    class = "ROGUE" },
    [108271] = { name = "Astral Shift",        cd = 90,  duration = 12, icon = 538565,  category = "major",    class = "SHAMAN" },
    [363916] = { name = "Obsidian Scales",     cd = 150, duration = 12, icon = 4622455, category = "major",    class = "EVOKER" },
    [47585]  = { name = "Dispersion",          cd = 120, duration = 6,  icon = 237563,  category = "major",    class = "PRIEST" },

    -- ========== MINOR PERSONALS ==========
    [22812]  = { name = "Barkskin",            cd = 60,  duration = 8,  icon = 136097,  category = "personal", class = "DRUID" },
    [48707]  = { name = "Anti-Magic Shell",    cd = 60,  duration = 5,  icon = 136120,  category = "personal", class = "DEATHKNIGHT" },
    [5277]   = { name = "Evasion",             cd = 120, duration = 10, icon = 136205,  category = "personal", class = "ROGUE" },
    [122783] = { name = "Diffuse Magic",       cd = 90,  duration = 6,  icon = 775460,  category = "personal", class = "MONK" },
    [198589] = { name = "Blur",                cd = 60,  duration = 10, icon = 1305150, category = "personal", class = "DEMONHUNTER" },
    [1966]   = { name = "Feint",               cd = 15,  duration = 5,  icon = 132294,  category = "personal", class = "ROGUE" },
    [184364] = { name = "Enraged Regeneration", cd = 120, duration = 8, icon = 132345,  category = "personal", class = "WARRIOR" },
}

-- ============================================================================
-- Class colors (shared with Interrupted -- same palette)
-- ============================================================================

DefensiveData.CLASS_COLORS = {
    WARRIOR     = { 0.78, 0.61, 0.43 },
    ROGUE       = { 1.00, 0.96, 0.41 },
    MAGE        = { 0.41, 0.80, 0.94 },
    SHAMAN      = { 0.00, 0.44, 0.87 },
    DRUID       = { 1.00, 0.49, 0.04 },
    DEATHKNIGHT = { 0.77, 0.12, 0.23 },
    PALADIN     = { 0.96, 0.55, 0.73 },
    DEMONHUNTER = { 0.64, 0.19, 0.79 },
    MONK        = { 0.00, 1.00, 0.59 },
    PRIEST      = { 1.00, 1.00, 1.00 },
    HUNTER      = { 0.67, 0.83, 0.45 },
    WARLOCK     = { 0.58, 0.51, 0.79 },
    EVOKER      = { 0.20, 0.58, 0.50 },
}

-- ============================================================================
-- Reverse lookup: spellID -> class (built automatically)
-- ============================================================================

DefensiveData.SPELL_TO_CLASS = {}
for id, data in pairs(DefensiveData.ALL_DEFENSIVES) do
    DefensiveData.SPELL_TO_CLASS[id] = data.class
end

-- ============================================================================
-- Reverse lookup: data entry -> clean spellID
--
-- After pcall(function() return ALL_DEFENSIVES[taintedID] end) succeeds,
-- the returned entry is a clean table reference from our own code.
-- This map converts it back to a clean (untainted) spellID number that
-- is safe to use as table keys, in format strings, and for logging.
-- ============================================================================

DefensiveData.ENTRY_TO_ID = {}
for id, data in pairs(DefensiveData.ALL_DEFENSIVES) do
    DefensiveData.ENTRY_TO_ID[data] = id
end

-- ============================================================================
-- Which defensive spellIDs belong to each class (for auto-registration)
-- ============================================================================

DefensiveData.CLASS_DEFENSIVE_IDS = {}
for id, data in pairs(DefensiveData.ALL_DEFENSIVES) do
    if not DefensiveData.CLASS_DEFENSIVE_IDS[data.class] then
        DefensiveData.CLASS_DEFENSIVE_IDS[data.class] = {}
    end
    table.insert(DefensiveData.CLASS_DEFENSIVE_IDS[data.class], id)
end

-- ============================================================================
-- Category display names and sort priority
-- ============================================================================

DefensiveData.CATEGORY_INFO = {
    external = { label = "External",       priority = 1 },
    party    = { label = "Party-Wide",     priority = 2 },
    major    = { label = "Major Personal", priority = 3 },
    personal = { label = "Personal",       priority = 4 },
}

-- ============================================================================
-- Optional spec whitelists for defensives that are confidently spec-bound.
--
-- These are used only to narrow party candidate sets when GroupInspector has a
-- specID. Spells not listed here remain class-wide so we don't accidentally
-- exclude valid Midnight variants while debugging.
-- ============================================================================

DefensiveData.SPELL_SPEC_WHITELIST = {
    [871]    = { [73] = true },                 -- Shield Wall (Protection Warrior)
    [118038] = { [71] = true },                 -- Die by the Sword (Arms Warrior)
    [184364] = { [72] = true },                 -- Enraged Regeneration (Fury Warrior)
    [61336]  = { [103] = true, [104] = true }, -- Survival Instincts (Feral/Guardian)
    [102342] = { [105] = true },                -- Ironbark (Restoration Druid)
    [198589] = { [577] = true },                -- Blur (Havoc Demon Hunter)
    [116849] = { [270] = true },                -- Life Cocoon (Mistweaver Monk)
    [33206]  = { [256] = true },                -- Pain Suppression (Discipline Priest)
    [62618]  = { [256] = true },                -- Power Word: Barrier (Discipline Priest)
    [47788]  = { [257] = true },                -- Guardian Spirit (Holy Priest)
    [47585]  = { [258] = true },                -- Dispersion (Shadow Priest)
    [98008]  = { [264] = true },                -- Spirit Link Totem (Restoration Shaman)
    [374227] = { [1468] = true },               -- Zephyr (Preservation Evoker)
}
