local ADDON_NAME, ns = ...

local DefensiveData = {}
ns.DefensiveData = DefensiveData

if MedaAuras and MedaAuras.Log then
    MedaAuras.Log("[DefensiveData] Loaded OK")
end

-- ============================================================================
-- All tracked spells keyed by spellID (fast lookup after laundering)
--
-- This table is mostly defensives, but it also carries a small opt-in set of
-- important buffs and risky raid effects that share the same filtered aura path.
--
-- category:
--   "external"  = cast on another player (Pain Suppression, Ironbark, etc.)
--   "party"     = party-wide / raid CD or raid-important effect
--   "major"     = major personal or important self buff
--   "personal"  = shorter personal CD
--
-- cd       = base cooldown in seconds
-- duration = buff/effect duration in seconds (0 if instant/passive)
-- icon     = hardcoded texture ID (avoids C_Spell taint issues)
-- ============================================================================

DefensiveData.ALL_DEFENSIVES = {
    -- ========== PARTY-WIDE / RAID CDs ==========
    [97462]  = { name = "Rallying Cry",       cd = 180, duration = 10, icon = 132351,  category = "party",    class = "WARRIOR" },
    [51052]  = { name = "Anti-Magic Zone",    cd = 120, duration = 8,  icon = 237510,  category = "party",    class = "DEATHKNIGHT" },
    [196718] = { name = "Darkness",            cd = 180, duration = 8,  icon = 1305154, category = "party",    class = "DEMONHUNTER" },
    [98008]  = { name = "Spirit Link Totem",   cd = 180, duration = 6,  icon = 237586,  category = "party",    class = "SHAMAN", talentSpellID = 98008 },
    [62618]  = { name = "Power Word: Barrier", cd = 180, duration = 10, icon = 253400,  category = "party",    class = "PRIEST", talentSpellID = 62618 },
    [374227] = { name = "Zephyr",              cd = 120, duration = 8,  icon = 4622452, category = "party",    class = "EVOKER" },
    [31821]  = { name = "Aura Mastery",        cd = 180, duration = 8,  icon = 135872,  category = "party",    class = "PALADIN", talentSpellID = 31821 },
    [201633] = { name = "Earthen Wall Totem",  cd = 60,  duration = 15, icon = 136098,  category = "party",    class = "SHAMAN", talentSpellID = 201633 },
    [8178]   = { name = "Grounding Totem",     cd = 24,  duration = 3,  icon = 136039,  category = "party",    class = "SHAMAN", talentSpellID = 8178 },
    [64843]  = { name = "Divine Hymn",         cd = 180, duration = 5,  icon = 237540,  category = "party",    class = "PRIEST" },

    -- ========== EXTERNALS (cast on others) ==========
    [1044]   = { name = "Blessing of Freedom", cd = 25,  duration = 8,  icon = 135968,  category = "external", class = "PALADIN" },
    [33206]  = { name = "Pain Suppression",       cd = 180, duration = 8,  icon = 135936, category = "external", class = "PRIEST", talentSpellID = 33206 },
    [102342] = { name = "Ironbark",               cd = 90,  duration = 12, icon = 572025, category = "external", class = "DRUID" },
    [1022]   = { name = "Blessing of Protection", cd = 300, duration = 10, icon = 135964, category = "external", class = "PALADIN", talentSpellID = 1022 },
    [6940]   = { name = "Blessing of Sacrifice",  cd = 120, duration = 12, icon = 135966, category = "external", class = "PALADIN", talentSpellID = 6940 },
    [116849] = { name = "Life Cocoon",            cd = 120, duration = 12, icon = 627485, category = "external", class = "MONK" },
    [47788]  = { name = "Guardian Spirit",        cd = 180, duration = 10, icon = 237542, category = "external", class = "PRIEST", talentSpellID = 47788 },
    [357170] = { name = "Time Dilation",          cd = 60,  duration = 8,  icon = 4622478, category = "external", class = "EVOKER", talentSpellID = 357170 },
    [204018] = { name = "Blessing of Spellwarding", cd = 300, duration = 10, icon = 135880, category = "external", class = "PALADIN", talentSpellID = 204018 },
    [197268] = { name = "Ray of Hope",            cd = 90,  duration = 6,  icon = 1445239, category = "external", class = "PRIEST", talentSpellID = 197268 },
    [3411]   = { name = "Intervene",              cd = 30,  duration = 6,  icon = 132365, category = "external", class = "WARRIOR" },

    -- ========== MAJOR PERSONALS ==========
    [871]    = { name = "Shield Wall",          cd = 180, duration = 8,  icon = 132362, category = "major",    class = "WARRIOR" },
    [118038] = { name = "Die by the Sword",     cd = 120, duration = 8,  icon = 132336, category = "major",    class = "WARRIOR" },
    [48792]  = { name = "Icebound Fortitude",   cd = 180, duration = 8,  icon = 237525, category = "major",    class = "DEATHKNIGHT" },
    [61336]  = { name = "Survival Instincts",   cd = 180, duration = 6,  icon = 236169, category = "major",    class = "DRUID", talentSpellID = 61336 },
    [115203] = { name = "Fortifying Brew",      cd = 360, duration = 15, icon = 615341, category = "major",    class = "MONK", talentSpellID = 115203 },
    [642]    = { name = "Divine Shield",        cd = 300, duration = 8,  icon = 524354, category = "major",    class = "PALADIN" },
    [104773] = { name = "Unending Resolve",     cd = 180, duration = 8,  icon = 136150, category = "major",    class = "WARLOCK" },
    [186265] = { name = "Aspect of the Turtle", cd = 180, duration = 8, icon = 132199,  category = "major",    class = "HUNTER" },
    [45438]  = { name = "Ice Block",            cd = 240, duration = 10, icon = 135841, category = "major",    class = "MAGE" },
    [31224]  = { name = "Cloak of Shadows",     cd = 120, duration = 5,  icon = 136177, category = "major",    class = "ROGUE" },
    [108271] = { name = "Astral Shift",         cd = 90,  duration = 12, icon = 538565, category = "major",    class = "SHAMAN" },
    [363916] = { name = "Obsidian Scales",      cd = 150, duration = 12, icon = 4622455, category = "major",   class = "EVOKER" },
    [47585]  = { name = "Dispersion",           cd = 120, duration = 6,  icon = 237563, category = "major",    class = "PRIEST" },
    [49028]  = { name = "Dancing Rune Weapon",  cd = 90,  duration = 8,  icon = 135277,  category = "major",    class = "DEATHKNIGHT" },
    [55233]  = { name = "Vampiric Blood",       cd = 120, duration = 10, icon = 136168,  category = "major",    class = "DEATHKNIGHT" },
    [196555] = { name = "Netherwalk",           cd = 180, duration = 6,  icon = 463284,  category = "major",    class = "DEMONHUNTER", talentSpellID = 196555 },
    [200851] = { name = "Rage of the Sleeper",  cd = 120, duration = 8,  icon = 1129695, category = "major",    class = "DRUID", talentSpellID = 200851 },
    [102558] = { name = "Incarnation: Guardian of Ursoc", cd = 180, duration = 30, icon = 571586, category = "major", class = "DRUID", talentSpellID = 102558 },
    [370960] = { name = "Emerald Communion",    cd = 180, duration = 5,  icon = 4630447, category = "major",    class = "EVOKER", talentSpellID = 370960 },
    [264735] = { name = "Survival of the Fittest", cd = 150, duration = 6, icon = 136094, category = "major", class = "HUNTER" },
    [342246] = { name = "Alter Time",           cd = 60,  duration = 10, icon = 609811, category = "major",    class = "MAGE", talentSpellID = 342246 },
    [125174] = { name = "Touch of Karma",       cd = 90,  duration = 10, icon = 651728,  category = "major",    class = "MONK" },
    [31850]  = { name = "Ardent Defender",      cd = 120, duration = 8,  icon = 135870,  category = "major",    class = "PALADIN", talentSpellID = 31850 },
    [212641] = { name = "Guardian of Ancient Kings", cd = 300, duration = 8, icon = 135919, category = "major", class = "PALADIN", talentSpellID = 212641 },
    [184662] = { name = "Shield of Vengeance",  cd = 120, duration = 15, icon = 236264,  category = "major",    class = "PALADIN" },
    [114893] = { name = "Stone Bulwark Totem",  cd = 120, duration = 30, icon = 538572,  category = "major",    class = "SHAMAN" },
    [108416] = { name = "Dark Pact",            cd = 60,  duration = 20, icon = 136146,  category = "major",    class = "WARLOCK", talentSpellID = 108416 },
    [12975]  = { name = "Last Stand",           cd = 120, duration = 15, icon = 135871,  category = "major",    class = "WARRIOR" },
    [31884]  = { name = "Avenging Wrath",       cd = 120, duration = 20, icon = 135875,  category = "major",    class = "PALADIN" },
    [216331] = { name = "Avenging Crusader",    cd = 60,  duration = 10, icon = 460689,  category = "major",    class = "PALADIN", talentSpellID = 216331 },
    [51271]  = { name = "Pillar of Frost",      cd = 45,  duration = 12, icon = 458718,  category = "major",    class = "DEATHKNIGHT" },
    [102543] = { name = "Incarnation: Avatar of Ashamane", cd = 180, duration = 20, icon = 571586, category = "major", class = "DRUID", talentSpellID = 102543 },
    [102560] = { name = "Incarnation: Chosen of Elune", cd = 180, duration = 20, icon = 571586, category = "major", class = "DRUID", talentSpellID = 102560 },
    [106951] = { name = "Berserk",              cd = 180, duration = 15, icon = 132242,  category = "major",    class = "DRUID", talentSpellID = 106951 },
    [107574] = { name = "Avatar",               cd = 90,  duration = 20, icon = 613534,  category = "major",    class = "WARRIOR", talentSpellID = 107574 },
    [132578] = { name = "Invoke Niuzao, the Black Ox", cd = 120, duration = 25, icon = 627607, category = "major", class = "MONK" },
    [190319] = { name = "Combustion",           cd = 120, duration = 10, icon = 135824,  category = "major",    class = "MAGE" },
    [228260] = { name = "Voidform",             cd = 120, duration = 20, icon = 1386546, category = "major",    class = "PRIEST" },
    [288613] = { name = "Trueshot",             cd = 120, duration = 15, icon = 132329,  category = "major",    class = "HUNTER" },
    [365362] = { name = "Arcane Surge",         cd = 90,  duration = 15, icon = 4667417, category = "major",    class = "MAGE" },
    [375087] = { name = "Dragonrage",           cd = 120, duration = 18, icon = 4622452, category = "major",    class = "EVOKER" },

    -- ========== MINOR PERSONALS ==========
    [22812]  = { name = "Barkskin",             cd = 60,  duration = 8,  icon = 136097,  category = "personal", class = "DRUID" },
    [48707]  = { name = "Anti-Magic Shell",     cd = 60,  duration = 5,  icon = 136120,  category = "personal", class = "DEATHKNIGHT" },
    [5277]   = { name = "Evasion",              cd = 120, duration = 10, icon = 136205,  category = "personal", class = "ROGUE" },
    [122783] = { name = "Diffuse Magic",        cd = 90,  duration = 6,  icon = 775460,  category = "personal", class = "MONK" },
    [198589] = { name = "Blur",                 cd = 60,  duration = 10, icon = 1305150, category = "personal", class = "DEMONHUNTER" },
    [1966]   = { name = "Feint",                cd = 15,  duration = 5,  icon = 132294,  category = "personal", class = "ROGUE" },
    [184364] = { name = "Enraged Regeneration", cd = 120, duration = 8, icon = 132345,  category = "personal", class = "WARRIOR" },
    [194679] = { name = "Rune Tap",             cd = 25,  duration = 4,  icon = 237529, category = "personal", class = "DEATHKNIGHT" },
    [22842]  = { name = "Frenzied Regeneration", cd = 36, duration = 3,  icon = 132091, category = "personal", class = "DRUID", talentSpellID = 22842 },
    [374348] = { name = "Renewing Blaze",       cd = 90,  duration = 8,  icon = 4630463, category = "personal", class = "EVOKER" },
    [122278] = { name = "Dampen Harm",          cd = 120, duration = 10, icon = 620827, category = "personal", class = "MONK" },
    [498]    = { name = "Divine Protection",    cd = 60,  duration = 8,  icon = 524353, category = "personal", class = "PALADIN", talentSpellID = 498 },
    [205191] = { name = "Eye for an Eye",       cd = 45,  duration = 10, icon = 135986, category = "personal", class = "PALADIN", talentSpellID = 205191 },
    [389539] = { name = "Sentinel",             cd = 120, duration = 12, icon = 135922, category = "personal", class = "PALADIN", talentSpellID = 389539 },
    [19236]  = { name = "Desperate Prayer",     cd = 90,  duration = 10, icon = 237550, category = "personal", class = "PRIEST", talentSpellID = 19236 },
    [586]    = { name = "Fade",                 cd = 20,  duration = 10, icon = 135994, category = "personal", class = "PRIEST" },
    [23920]  = { name = "Spell Reflection",     cd = 25,  duration = 5,  icon = 132361, category = "personal", class = "WARRIOR" },
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
    [107574] = { [71] = true, [72] = true, [73] = true }, -- Avatar (Warrior)
    [118038] = { [71] = true },                 -- Die by the Sword (Arms Warrior)
    [184364] = { [72] = true },                 -- Enraged Regeneration (Fury Warrior)
    [51271]  = { [251] = true },                -- Pillar of Frost (Frost Death Knight)
    [49028]  = { [250] = true },                -- Dancing Rune Weapon (Blood Death Knight)
    [55233]  = { [250] = true },                -- Vampiric Blood (Blood Death Knight)
    [194679] = { [250] = true },                -- Rune Tap (Blood Death Knight)
    [102560] = { [102] = true },                -- Incarnation: Chosen of Elune (Balance Druid)
    [102543] = { [103] = true },                -- Incarnation: Avatar of Ashamane (Feral Druid)
    [106951] = { [103] = true },                -- Berserk (Feral Druid)
    [61336]  = { [103] = true, [104] = true }, -- Survival Instincts (Feral/Guardian)
    [102342] = { [105] = true },                -- Ironbark (Restoration Druid)
    [200851] = { [104] = true },                -- Rage of the Sleeper (Guardian Druid)
    [102558] = { [104] = true },                -- Incarnation: Guardian of Ursoc (Guardian Druid)
    [22842]  = { [104] = true },                -- Frenzied Regeneration (Guardian Druid)
    [198589] = { [577] = true },                -- Blur (Havoc Demon Hunter)
    [196555] = { [577] = true },                -- Netherwalk (Havoc Demon Hunter)
    [288613] = { [254] = true },                -- Trueshot (Marksmanship Hunter)
    [190319] = { [63] = true },                 -- Combustion (Fire Mage)
    [365362] = { [62] = true },                 -- Arcane Surge (Arcane Mage)
    [132578] = { [268] = true },                -- Invoke Niuzao, the Black Ox (Brewmaster Monk)
    [116849] = { [270] = true },                -- Life Cocoon (Mistweaver Monk)
    [1044]   = { [65] = true, [66] = true, [70] = true }, -- Blessing of Freedom (Paladin)
    [31884]  = { [65] = true, [66] = true, [70] = true }, -- Avenging Wrath (Paladin)
    [216331] = { [65] = true },                 -- Avenging Crusader (Holy Paladin)
    [357170] = { [1473] = true },               -- Time Dilation (Augmentation Evoker)
    [33206]  = { [256] = true },                -- Pain Suppression (Discipline Priest)
    [62618]  = { [256] = true },                -- Power Word: Barrier (Discipline Priest)
    [47788]  = { [257] = true },                -- Guardian Spirit (Holy Priest)
    [64843]  = { [257] = true },                -- Divine Hymn (Holy Priest)
    [197268] = { [257] = true },                -- Ray of Hope (Holy Priest)
    [47585]  = { [258] = true },                -- Dispersion (Shadow Priest)
    [228260] = { [258] = true },                -- Voidform (Shadow Priest)
    [31821]  = { [65] = true },                 -- Aura Mastery (Holy Paladin)
    [31850]  = { [66] = true },                 -- Ardent Defender (Protection Paladin)
    [212641] = { [66] = true },                 -- Guardian of Ancient Kings (Protection Paladin)
    [184662] = { [70] = true },                 -- Shield of Vengeance (Retribution Paladin)
    [205191] = { [70] = true },                 -- Eye for an Eye (Retribution Paladin)
    [389539] = { [70] = true },                 -- Sentinel (Retribution Paladin)
    [201633] = { [264] = true },                -- Earthen Wall Totem (Restoration Shaman)
    [98008]  = { [264] = true },                -- Spirit Link Totem (Restoration Shaman)
    [375087] = { [1467] = true },               -- Dragonrage (Devastation Evoker)
    [374227] = { [1468] = true },               -- Zephyr (Preservation Evoker)
    [370960] = { [1468] = true },               -- Emerald Communion (Preservation Evoker)
}

DefensiveData.DEFENSIVE_TALENT_OVERRIDES = {
    [45438] = {
        talentSpellID = 414658,
        name = "Ice Cold",
        icon = 135777,
        cd = 150,
        duration = 6,
        maxCharges = 2,
    },
}

-- ============================================================================
-- Base spell IDs that are confirmed by the current supported tracking path.
--
-- Cracked uses this subset so the default catalog stays limited to abilities
-- with a known-good aura/rule path.
-- ============================================================================

DefensiveData.CONFIRMED_DEFENSIVE_IDS = {
    [498] = true,
    [642] = true,
    [871] = true,
    [1022] = true,
    [5277] = true,
    [6940] = true,
    [19236] = true,
    [22812] = true,
    [31224] = true,
    [31850] = true,
    [33206] = true,
    [45438] = true,
    [47585] = true,
    [47788] = true,
    [48707] = true,
    [48792] = true,
    [55233] = true,
    [102342] = true,
    [102558] = true,
    [104773] = true,
    [108271] = true,
    [115203] = true,
    [116849] = true,
    [118038] = true,
    [184364] = true,
    [186265] = true,
    [198589] = true,
    [204018] = true,
    [264735] = true,
    [342246] = true,
    [357170] = true,
    [363916] = true,
    [389539] = true,
}

-- ============================================================================
-- Experimental defensive spell IDs that are reasonable candidates for the
-- current tracking path but are not yet confirmed.
-- ============================================================================

DefensiveData.EXPERIMENTAL_DEFENSIVE_IDS = {
    [586] = true,
    [1966] = true,
    [3411] = true,
    [12975] = true,
    [197268] = true,
    [22842] = true,
    [23920] = true,
    [49028] = true,
    [61336] = true,
    [108416] = true,
    [114893] = true,
    [122278] = true,
    [122783] = true,
    [125174] = true,
    [184662] = true,
    [194679] = true,
    [196555] = true,
    [200851] = true,
    [205191] = true,
    [212641] = true,
    [370960] = true,
    [374348] = true,
}

-- ============================================================================
-- Experimental important-buff spell IDs that appear to be exposed through the
-- same filtered aura buckets but are not part of the default defensive subset.
-- ============================================================================

DefensiveData.EXPERIMENTAL_IMPORTANT_BUFF_IDS = {
    [1044] = true,
    [64843] = true,
    [31884] = true,
    [216331] = true,
    [51271] = true,
    [102543] = true,
    [102560] = true,
    [106951] = true,
    [107574] = true,
    [132578] = true,
    [190319] = true,
    [228260] = true,
    [288613] = true,
    [365362] = true,
    [375087] = true,
}

-- ============================================================================
-- Risky raid-effect spell IDs use the same filtered aura path, but many are
-- raid-wide, totem-based, or ground-based effects and can be less reliable as
-- per-unit aura evidence.
-- ============================================================================

DefensiveData.RISKY_RAID_EFFECT_IDS = {
    [8178] = true,
    [31821] = true,
    [51052] = true,
    [62618] = true,
    [97462] = true,
    [98008] = true,
    [196718] = true,
    [201633] = true,
    [374227] = true,
}

DefensiveData.GROUP_BUFFS = {
    stamina = {
        key = "stamina",
        label = "Fortitude",
        icon = 135987,
        order = 1,
        providers = {
            { class = "PRIEST", spellID = 21562, name = "Power Word: Fortitude" },
        },
    },
    versatility = {
        key = "versatility",
        label = "Mark of the Wild",
        icon = 136078,
        order = 2,
        providers = {
            { class = "DRUID", spellID = 1126, name = "Mark of the Wild" },
        },
    },
    mastery = {
        key = "mastery",
        label = "Skyfury",
        icon = 4630367,
        order = 3,
        providers = {
            { class = "SHAMAN", spellID = 462854, name = "Skyfury" },
        },
    },
    intellect = {
        key = "intellect",
        label = "Arcane Intellect",
        icon = 135932,
        order = 4,
        providers = {
            { class = "MAGE", spellID = 1459, name = "Arcane Intellect" },
        },
    },
    attackPower = {
        key = "attackPower",
        label = "Battle Shout",
        icon = 132333,
        order = 5,
        providers = {
            { class = "WARRIOR", spellID = 6673, name = "Battle Shout" },
        },
    },
    movement = {
        key = "movement",
        label = "Blessing of the Bronze",
        icon = 4622448,
        order = 6,
        providers = {
            { class = "EVOKER", spellID = 364342, name = "Blessing of the Bronze" },
        },
    },
}

DefensiveData.REQUIRED_GROUP_BUFFS_BY_SPEC = {
    [250] = "attackPower",
    [251] = "attackPower",
    [252] = "attackPower",
    [577] = "attackPower",
    [581] = "attackPower",
    [102] = "intellect",
    [103] = "attackPower",
    [104] = "attackPower",
    [105] = "intellect",
    [1467] = "intellect",
    [1468] = "intellect",
    [253] = "attackPower",
    [254] = "attackPower",
    [255] = "attackPower",
    [62] = "intellect",
    [63] = "intellect",
    [64] = "intellect",
    [268] = "attackPower",
    [269] = "attackPower",
    [270] = "intellect",
    [65] = "intellect",
    [66] = "attackPower",
    [70] = "attackPower",
    [256] = "intellect",
    [257] = "intellect",
    [258] = "intellect",
    [259] = "attackPower",
    [260] = "attackPower",
    [261] = "attackPower",
    [262] = "intellect",
    [263] = "attackPower",
    [264] = "intellect",
    [265] = "intellect",
    [266] = "intellect",
    [267] = "intellect",
    [71] = "attackPower",
    [72] = "attackPower",
    [73] = "attackPower",
}

DefensiveData.REQUIRED_GROUP_BUFFS_FOR_EVERYONE = {
    stamina = true,
    versatility = true,
    mastery = true,
    movement = true,
}
