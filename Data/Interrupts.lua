local ADDON_NAME, ns = ...

local InterruptData = {}
ns.InterruptData = InterruptData

if MedaAuras and MedaAuras.Log then
    MedaAuras.Log("[InterruptData] Loaded OK")
end

-- ============================================================================
-- All interrupt spells keyed by spellID (fast lookup for laundering checks)
-- icon: hardcoded icon ID/path (more reliable than C_Spell for pet variants)
-- ============================================================================

InterruptData.ALL_INTERRUPTS = {
    [6552]    = { name = "Pummel",            cd = 15, icon = 132938 },
    [1766]    = { name = "Kick",              cd = 15, icon = 132219 },
    [2139]    = { name = "Counterspell",      cd = 24, icon = 135856 },
    [57994]   = { name = "Wind Shear",        cd = 12, icon = 136018 },
    [106839]  = { name = "Skull Bash",        cd = 15, icon = 236946 },
    [78675]   = { name = "Solar Beam",        cd = 60, icon = 236748 },
    [47528]   = { name = "Mind Freeze",       cd = 15, icon = 237527 },
    [96231]   = { name = "Rebuke",            cd = 15, icon = 523893 },
    [183752]  = { name = "Disrupt",           cd = 15, icon = 1305153 },
    [116705]  = { name = "Spear Hand Strike", cd = 15, icon = 608940 },
    [15487]   = { name = "Silence",           cd = 45, icon = 458230 },
    [147362]  = { name = "Counter Shot",      cd = 24, icon = 249170 },
    [187707]  = { name = "Muzzle",            cd = 15, icon = 1376045 },
    [282220]  = { name = "Muzzle",            cd = 15, icon = 1376045 },
    [19647]   = { name = "Spell Lock",        cd = 24, icon = 136174 },
    [119910]  = { name = "Spell Lock",        cd = 24, icon = 136174 },
    [132409]  = { name = "Spell Lock",        cd = 24, icon = 136174 },
    [119914]  = { name = "Axe Toss",          cd = 30, icon = "Interface\\Icons\\ability_warrior_titansgrip" },
    [89766]   = { name = "Axe Toss",          cd = 30, icon = "Interface\\Icons\\ability_warrior_titansgrip" },
    [1276467] = { name = "Fel Ravager",       cd = 25, icon = "Interface\\Icons\\spell_shadow_summonfelhunter" },
    [351338]  = { name = "Quell",             cd = 20, icon = 4622469 },
}

-- ============================================================================
-- Full array with class/pet metadata (for FocusInterruptHelper-style iteration)
-- ============================================================================

InterruptData.INTERRUPTS = {
    { id = 351338,  name = "Quell",                class = "EVOKER",       baseCD = 20 },
    { id = 1766,    name = "Kick",                 class = "ROGUE",        baseCD = 15 },
    { id = 6552,    name = "Pummel",               class = "WARRIOR",      baseCD = 15 },
    { id = 2139,    name = "Counterspell",         class = "MAGE",         baseCD = 24 },
    { id = 57994,   name = "Wind Shear",           class = "SHAMAN",       baseCD = 12 },
    { id = 106839,  name = "Skull Bash",           class = "DRUID",        baseCD = 15 },
    { id = 78675,   name = "Solar Beam",           class = "DRUID",        baseCD = 60 },
    { id = 96231,   name = "Rebuke",               class = "PALADIN",      baseCD = 15 },
    { id = 47528,   name = "Mind Freeze",          class = "DEATHKNIGHT",  baseCD = 15 },
    { id = 147362,  name = "Counter Shot",         class = "HUNTER",       baseCD = 24 },
    { id = 187707,  name = "Muzzle",               class = "HUNTER",       baseCD = 15 },
    { id = 282220,  name = "Muzzle",               class = "HUNTER",       baseCD = 15 },
    { id = 183752,  name = "Disrupt",              class = "DEMONHUNTER",  baseCD = 15 },
    { id = 116705,  name = "Spear Hand Strike",    class = "MONK",         baseCD = 15 },
    { id = 15487,   name = "Silence",              class = "PRIEST",       baseCD = 45 },
    { id = 119910,  name = "Spell Lock",           class = "WARLOCK",      baseCD = 24, pet = true, altIDs = {19647, 119898, 1276467, 89766} },
    { id = 19647,   name = "Spell Lock",           class = "WARLOCK",      baseCD = 24, pet = true, altIDs = {119910, 119898, 1276467, 89766} },
    { id = 89766,   name = "Axe Toss",             class = "WARLOCK",      baseCD = 30, pet = true, altIDs = {119910, 19647, 119898, 1276467} },
    { id = 1276467, name = "Grimoire: Fel Ravager", class = "WARLOCK",     baseCD = 25, pet = false, altIDs = {119910, 19647, 89766} },
}

-- ============================================================================
-- Default (primary) interrupt per class for auto-registration
-- ============================================================================

InterruptData.CLASS_DEFAULTS = {
    WARRIOR     = { id = 6552,   cd = 15, name = "Pummel" },
    ROGUE       = { id = 1766,   cd = 15, name = "Kick" },
    MAGE        = { id = 2139,   cd = 24, name = "Counterspell" },
    SHAMAN      = { id = 57994,  cd = 12, name = "Wind Shear" },
    DRUID       = { id = 106839, cd = 15, name = "Skull Bash" },
    DEATHKNIGHT = { id = 47528,  cd = 15, name = "Mind Freeze" },
    PALADIN     = { id = 96231,  cd = 15, name = "Rebuke" },
    DEMONHUNTER = { id = 183752, cd = 15, name = "Disrupt" },
    HUNTER      = { id = 147362, cd = 24, name = "Counter Shot" },
    MONK        = { id = 116705, cd = 15, name = "Spear Hand Strike" },
    WARLOCK     = { id = 19647,  cd = 24, name = "Spell Lock" },
    PRIEST      = { id = 15487,  cd = 45, name = "Silence" },
    EVOKER      = { id = 351338, cd = 20, name = "Quell" },
}

-- ============================================================================
-- Ordered spell IDs to check per class (first known spell wins as primary)
-- ============================================================================

InterruptData.CLASS_INTERRUPT_LIST = {
    WARRIOR     = { 6552 },
    ROGUE       = { 1766 },
    MAGE        = { 2139 },
    SHAMAN      = { 57994 },
    DRUID       = { 106839, 78675 },
    DEATHKNIGHT = { 47528 },
    PALADIN     = { 96231 },
    DEMONHUNTER = { 183752 },
    MONK        = { 116705 },
    PRIEST      = { 15487 },
    HUNTER      = { 147362, 187707, 282220 },
    WARLOCK     = { 19647, 132409, 119914, 119910 },
    EVOKER      = { 351338 },
}

-- ============================================================================
-- Spec overrides (specID -> different interrupt or CD)
-- ============================================================================

InterruptData.SPEC_OVERRIDES = {
    [255] = { id = 187707, cd = 15, name = "Muzzle" },
    [264] = { id = 57994,  cd = 30, name = "Wind Shear" },
    [266] = { id = 119914, cd = 30, name = "Axe Toss", isPet = true, petSpellID = 89766 },
}

-- ============================================================================
-- Specs that have no interrupt at all
-- ============================================================================

InterruptData.SPEC_NO_INTERRUPT = {
    [256] = true,   -- Discipline Priest
    [257] = true,   -- Holy Priest
    [105] = true,   -- Restoration Druid (Skull Bash removed in 12.0)
    [65]  = true,   -- Holy Paladin
}

-- ============================================================================
-- Healers that still keep their interrupt
-- ============================================================================

InterruptData.HEALER_KEEPS_KICK = {
    SHAMAN = true,
}

-- ============================================================================
-- Passive CD reduction talents (applied to baseCd on inspect)
-- ============================================================================

InterruptData.CD_REDUCTION_TALENTS = {
    [388039] = { affects = 147362, reduction = 2,     name = "Lone Survivor" },
    [412713] = { affects = 351338, pctReduction = 10, name = "Interwoven Threads" },
}

-- ============================================================================
-- CD reduction on successful interrupt (applied when mob cast is interrupted)
-- ============================================================================

InterruptData.CD_ON_KICK_TALENTS = {
    [378848] = { reduction = 3, name = "Coldthirst" },
}

-- ============================================================================
-- Extra kicks granted by spec (second interrupt ability)
-- ============================================================================

InterruptData.SPEC_EXTRA_KICKS = {
    [266] = {
        { id = 132409, cd = 25, name = "Fel Ravager / Spell Lock",
          icon = "Interface\\Icons\\spell_shadow_summonfelhunter",
          talentCheck = 1276467 },
    },
}

-- ============================================================================
-- Spell aliases: some spells fire different IDs on party vs own client
-- ============================================================================

InterruptData.SPELL_ALIASES = {
    [1276467] = 132409,
    [282220]  = 187707,
    [119910]  = 19647,
}

-- ============================================================================
-- Class colors for the tracker UI
-- ============================================================================

InterruptData.CLASS_COLORS = {
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
