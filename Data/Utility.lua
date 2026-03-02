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
        },
        {
            class     = "MAGE",
            specID    = nil,
            spellID   = 80353,
            spellName = "Time Warp",
            note      = "Baseline Mage ability.",
        },
        {
            class     = "HUNTER",
            specID    = nil,
            spellID   = 264667,
            spellName = "Primal Rage",
            note      = "Available via exotic pet or talent.",
        },
        {
            class     = "EVOKER",
            specID    = nil,
            spellID   = 390386,
            spellName = "Fury of the Aspects",
            note      = "Baseline Evoker ability.",
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
        },
        {
            class     = "DEATHKNIGHT",
            specID    = nil,
            spellID   = 61999,
            spellName = "Raise Ally",
            note      = "Baseline Death Knight ability. 10 min CD.",
        },
        {
            class     = "WARLOCK",
            specID    = nil,
            spellID   = 20707,
            spellName = "Soulstone",
            note      = "Can be pre-cast before combat or used as combat res. 10 min CD.",
        },
        {
            class     = "PALADIN",
            specID    = nil,
            spellID   = 391054,
            spellName = "Intercession",
            note      = "Requires Holy Power. Baseline Paladin ability.",
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

