local _, ns = ...
local D = ns.RemindersData
D.capabilities = D.capabilities or {}

D.capabilities.bloodlust = {
    label       = "Bloodlust / Heroism",
    description = "A major cooldown that grants 30% Haste to the entire group for 40 seconds.",
    icon        = 132313,
    color       = { 1.0, 0.4, 0.1 },
    tags        = { "utility", "throughput" },

    providers = {
        {
            class     = "SHAMAN",
            specID    = nil,
            spellID   = 2825,
            spellName = "Bloodlust",
            note      = "Baseline Shaman ability.",
            icon      = 136012,
            rangeText = "Self",
            cooldownMS = 300000,
        },
        {
            class     = "MAGE",
            specID    = nil,
            spellID   = 80353,
            spellName = "Time Warp",
            note      = "Baseline Mage ability. [IV: StandardHeroismeffect. Raid-wide 30% Haste cooldown.]",
            icon      = 458224,
            rangeText = "Self",
            cooldownMS = 300000,
        },
        {
            class     = "HUNTER",
            specID    = nil,
            spellID   = 264667,
            spellName = "Primal Rage",
            note      = "Available via exotic pet or talent.",
            icon      = 136224,
            rangeText = "Self",
            cooldownMS = 360000,
        },
        {
            class     = "EVOKER",
            specID    = nil,
            spellID   = 390386,
            spellName = "Fury of the Aspects",
            note      = "Baseline Evoker ability.",
            icon      = 4723908,
            rangeText = "Self",
            cooldownMS = 300000,
        },
    },

    conditions = {
        none = {
            severity    = "warning",
            banner      = "No Bloodlust / Heroism in group",
            panelStatus = "NONE",
            detail      = "Your group has no lust. You'll miss significant DPS on bosses and dangerous trash packs.",
            suggestion  = "Invite a Shaman, Mage, Hunter, or Evoker.",
        },
        single = {
            severity    = nil,
            banner      = nil,
            panelStatus = nil,
            detail      = "Bloodlust covered.",
            suggestion  = nil,
        },
        adequate = {
            severity    = nil,
            banner      = nil,
            panelStatus = nil,
            detail      = "Bloodlust covered.",
            suggestion  = nil,
        },
    },

    thresholds = { none = 0, single = 1, adequate = 1 },

    personalReminder = nil,
}

D.capabilities.battle_res = {
    label       = "Battle Resurrection",
    description = "Ability to resurrect a fallen party member during combat. Limited to one charge per encounter in M+ (recharges on boss kill).",
    icon        = 136080,
    color       = { 0.2, 0.8, 0.2 },
    tags        = { "utility", "survival" },

    providers = {
        {
            class     = "DRUID",
            specID    = nil,
            spellID   = 20484,
            spellName = "Rebirth",
            note      = "Baseline Druid ability. 10 min CD (shared bres pool in M+).",
            icon      = 136080,
            rangeText = "Long",
            cooldownMS = 600000,
        },
        {
            class     = "DEATHKNIGHT",
            specID    = nil,
            spellID   = 61999,
            spellName = "Raise Ally",
            note      = "Baseline Death Knight ability. 10 min CD.",
            icon      = 136143,
            rangeText = "Long",
            cooldownMS = 600000,
        },
        {
            class     = "WARLOCK",
            specID    = nil,
            spellID   = 20707,
            spellName = "Soulstone",
            note      = "Can be pre-cast before combat or used as combat res. 10 min CD.",
            icon      = 136210,
            rangeText = "Long",
            cooldownMS = 600000,
        },
        {
            class     = "PALADIN",
            specID    = nil,
            spellID   = 391054,
            spellName = "Intercession",
            note      = "Requires Holy Power. Baseline Paladin ability.",
            icon      = 4726195,
            rangeText = "Long",
            cooldownMS = 600000,
        },
    },

    conditions = {
        none = {
            severity    = "warning",
            banner      = "No battle res in group!",
            panelStatus = "NONE",
            detail      = "No one can resurrect during combat. A death in a key fight means you're down a player for the rest of the encounter.",
            suggestion  = "Invite a Druid, Death Knight, Warlock, or Paladin.",
        },
        single = {
            severity    = nil,
            banner      = nil,
            panelStatus = nil,
            detail      = "One battle res. Standard for 5-man.",
            suggestion  = nil,
        },
        adequate = {
            severity    = nil,
            banner      = nil,
            panelStatus = nil,
            detail      = "Battle res well covered.",
            suggestion  = nil,
        },
    },

    thresholds = { none = 0, single = 1, adequate = 2 },

    personalReminder = nil,
}

D.capabilities.offensive_dispel = {
    label       = "Offensive Dispel (Purge)",
    description = "Ability to remove beneficial magic effects from enemies. Critical for stripping shields, buffs, and enrages from dangerous mobs.",
    icon        = 136075,
    color       = { 0.9, 0.3, 0.9 },
    tags        = { "utility", "offensive" },

    providers = {
        {
            class     = "SHAMAN",
            specID    = nil,
            spellID   = 370,
            spellName = "Purge",
            talentSpellID = 370,
            note      = "Removes 1 beneficial magic effect from an enemy.",
            icon      = 136075,
            rangeText = "Medium",
            cooldownMS = 1500,
            dispelTargets = { "Magic" },
        },
        {
            class     = "MAGE",
            specID    = nil,
            spellID   = 30449,
            spellName = "Spellsteal",
            talentSpellID = 30449,
            note      = "Steals a beneficial magic effect. Can be powerful with the right buffs. [IV: Dispels enemy magic and usually grants it to yourself for up to 2\nminutes. Offensive dispels are somewhat rare, and usually, if a target's\nability can be Spellstolen; it will be glowing on the target]",
            icon      = 135729,
            rangeText = "Long",
            cooldownMS = 1500,
        },
        {
            class     = "PRIEST",
            specID    = nil,
            spellID   = 528,
            spellName = "Dispel Magic",
            talentSpellID = 528,
            note      = "Can be cast on enemies to remove 1 beneficial effect.",
            icon      = 136066,
            rangeText = "Medium",
            cooldownMS = 1500,
            dispelTargets = { "Magic" },
        },
        {
            class     = "DEMONHUNTER",
            specID    = nil,
            spellID   = 278326,
            spellName = "Consume Magic",
            talentSpellID = 278326,
            note      = "Removes 1 beneficial magic effect and generates Fury. [Wowhead: Sunblade Enforcer 's Arcane Blade , Lightward Healer 's Power Word: Shield and Seranel Sunlash 's Hastening Ward can all be purged with Consume Magic .]",
            icon      = 828455,
            rangeText = "Medium",
            cooldownMS = 10000,
            dispelTargets = { "Magic" },
        },
        {
            class     = "HUNTER",
            specID    = nil,
            spellID   = 19801,
            spellName = "Tranquilizing Shot",
            talentSpellID = 19801,
            note      = "Removes 1 Enrage and 1 Magic effect from an enemy. [Wowhead: On Seranel Sunlash , use Tranquilizing Shot to remove Hastening Ward .]",
            icon      = 136020,
            rangeText = "Long",
            cooldownMS = 10000,
            dispelTargets = { "Enrage", "Magic" },
        },
        {
            class     = "WARLOCK",
            specID    = nil,
            spellID   = 19505,
            spellName = "Devour Magic",
            note      = "Felhunter pet ability. Removes 1 beneficial magic effect.",
            icon      = 136075,
            rangeText = "Medium",
            cooldownMS = 15000,
            dispelTargets = { "Magic" },
        },
    },

    conditions = {
        none = {
            severity    = "warning",
            banner      = "No offensive dispel (Purge) in group!",
            panelStatus = "NONE",
            detail      = "Nobody can remove enemy buffs or shields. Some dungeon mechanics require purging.",
            suggestion  = "Bring a Shaman, Mage, Priest, DH, Hunter, or Warlock.",
        },
        single = {
            severity    = nil,
            banner      = nil,
            panelStatus = nil,
            detail      = "One offensive dispel available.",
            suggestion  = nil,
        },
        adequate = {
            severity    = nil,
            banner      = nil,
            panelStatus = nil,
            detail      = "Offensive dispel well covered.",
            suggestion  = nil,
        },
    },

    thresholds = { none = 0, single = 1, adequate = 2 },

    personalReminder = nil,
}

D.capabilities.soothe = {
    label       = "Enrage Removal (Soothe)",
    description = "Ability to remove Enrage effects from enemies. Important when mobs gain significant damage buffs from enraging.",
    icon        = 132163,
    color       = { 0.4, 0.8, 0.4 },
    tags        = { "utility", "offensive" },

    providers = {
        {
            class     = "DRUID",
            specID    = nil,
            spellID   = 2908,
            spellName = "Soothe",
            talentSpellID = 2908,
            note      = "Removes all Enrage effects from an enemy. 10 sec CD. [Wowhead: You can use Soothe to remove the Blood Frenzy buff from Frenzied Berserker .]",
            icon      = 132163,
            rangeText = "Long",
            cooldownMS = 10000,
            dispelTargets = { "Enrage" },
        },
        {
            class     = "HUNTER",
            specID    = nil,
            spellID   = 19801,
            spellName = "Tranquilizing Shot",
            talentSpellID = 19801,
            note      = "Removes 1 Enrage and 1 Magic effect. 10 sec CD. [Wowhead: On Seranel Sunlash , use Tranquilizing Shot to remove Hastening Ward .]",
            icon      = 136020,
            rangeText = "Long",
            cooldownMS = 10000,
            dispelTargets = { "Enrage", "Magic" },
        },
        {
            class     = "ROGUE",
            specID    = nil,
            spellID   = 5938,
            spellName = "Shiv",
            note      = "Applies concentrated poison which can remove Enrage when using specific poisons. [Wowhead: Frenzied Berserker s will gain Blood Frenzy . You can use Shiv to remove this.]",
            icon      = 135428,
            rangeText = "Combat",
            cooldownMS = 1000,
            dispelTargets = { "Enrage" },
        },
    },

    conditions = {
        none = {
            severity    = "info",
            banner      = nil,
            panelStatus = "NONE",
            detail      = "No Enrage removal available. Enraged mobs will need to be kited or burned.",
            suggestion  = "A Druid (Soothe) or Hunter (Tranq Shot) can remove Enrage.",
        },
        single = {
            severity    = nil,
            banner      = nil,
            panelStatus = nil,
            detail      = "One soothe available.",
            suggestion  = nil,
        },
        adequate = {
            severity    = nil,
            banner      = nil,
            panelStatus = nil,
            detail      = "Enrage removal well covered.",
            suggestion  = nil,
        },
    },

    thresholds = { none = 0, single = 1, adequate = 1 },

    personalReminder = nil,
}

D.capabilities.shroud = {
    label       = "Group Stealth (Shroud)",
    description = "Ability to stealth the entire party, allowing the group to skip trash packs. A powerful routing tool in M+.",
    icon        = 635350,
    color       = { 0.5, 0.5, 0.7 },
    tags        = { "utility", "routing" },

    providers = {
        {
            class     = "ROGUE",
            specID    = nil,
            spellID   = 114018,
            spellName = "Shroud of Concealment",
            note      = "Stealths all party members within 20 yards for 15 sec. 6 min CD.",
            icon      = 635350,
            rangeText = "Self",
            cooldownMS = 360000,
        },
    },

    conditions = {
        none = {
            severity    = "info",
            banner      = nil,
            panelStatus = "None",
            detail      = "No group stealth available. May need to pull extra packs or use other skips.",
            suggestion  = "A Rogue provides Shroud of Concealment for group skips.",
        },
        single = {
            severity    = nil,
            banner      = nil,
            panelStatus = nil,
            detail      = "Shroud available for one skip per key.",
            suggestion  = nil,
        },
        adequate = {
            severity    = nil,
            banner      = nil,
            panelStatus = nil,
            detail      = "Group stealth covered.",
            suggestion  = nil,
        },
    },

    thresholds = { none = 0, single = 1, adequate = 1 },

    personalReminder = nil,
}

