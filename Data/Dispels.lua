local _, ns = ...
local D = ns.RemindersData
D.capabilities = D.capabilities or {}

D.capabilities.dispel_curse = {
    label       = "Curse Removal",
    description = "Ability to remove Curse debuffs from friendly targets. Many dungeon bosses and trash apply dangerous curses that, left unchecked, can overwhelm healing.",
    icon        = 136082,
    color       = { 0.6, 0.2, 0.8 },
    tags        = { "dispel", "curse" },

    providers = {
        {
            class     = "MAGE",
            specID    = nil,
            spellID   = 475,
            spellName = "Remove Curse",
            note      = "No cooldown. Can rapidly cleanse overlapping curses.",
        },
        {
            class     = "DRUID",
            specID    = 105,
            spellID   = 88423,
            spellName = "Nature's Cure",
            note      = "Also removes poison and magic (Resto only). 8 sec CD.",
        },
        {
            class     = "SHAMAN",
            specID    = 264,
            spellID   = 77130,
            spellName = "Purify Spirit",
            note      = "Resto only. Also removes magic. 8 sec CD.",
        },
    },

    conditions = {
        none = {
            severity    = "critical",
            banner      = "No curse dispel in group!",
            panelStatus = "NONE",
            detail      = "Nobody in your group can remove curses. This will be dangerous on curse-heavy encounters.",
            suggestion  = "Invite a Mage (no-CD Remove Curse) or swap to a healer spec with curse removal (Resto Druid/Shaman).",
        },
        single = {
            severity    = "info",
            banner      = nil,
            panelStatus = nil,
            detail      = "One curse dispeller. Be mindful of overlapping curse applications -- they may fall behind on heavy waves.",
            suggestion  = nil,
        },
        adequate = {
            severity    = nil,
            banner      = nil,
            panelStatus = nil,
            detail      = "Curse removal is well covered.",
            suggestion  = nil,
        },
    },

    thresholds = { none = 0, single = 1, adequate = 2 },

    personalReminder = {
        severity = "warning",
        banner   = "You can talent into curse removal!",
        detail   = "Your class has access to %spellName% but you don't currently have it. Consider picking it up for this content.",
    },
}

D.capabilities.dispel_poison = {
    label       = "Poison Removal",
    description = "Ability to remove Poison debuffs from friendly targets.",
    icon        = 136067,
    color       = { 0.0, 0.6, 0.1 },
    tags        = { "dispel", "poison" },

    providers = {
        {
            class     = "DRUID",
            specID    = 105,
            spellID   = 88423,
            spellName = "Nature's Cure",
            note      = "Also removes curses and magic (Resto only). 8 sec CD.",
        },
        {
            class     = "PALADIN",
            specID    = 65,
            spellID   = 4987,
            spellName = "Cleanse",
            note      = "Holy only. Also removes magic and disease. 8 sec CD.",
        },
        {
            class     = "MONK",
            specID    = 270,
            spellID   = 115450,
            spellName = "Detox",
            note      = "Mistweaver only. Also removes magic. 8 sec CD.",
        },
        {
            class     = "EVOKER",
            specID    = 1468,
            spellID   = 365585,
            spellName = "Expunge",
            note      = "Preservation only. Also removes bleed. 8 sec CD.",
        },
    },

    conditions = {
        none = {
            severity    = "critical",
            banner      = "No poison dispel in group!",
            panelStatus = "NONE",
            detail      = "Nobody can remove poisons. Stacking poison DoTs will be very difficult to heal through.",
            suggestion  = "Bring a healer that can cleanse poison: Resto Druid, Holy Paladin, MW Monk, or Pres Evoker.",
        },
        single = {
            severity    = "info",
            banner      = nil,
            panelStatus = nil,
            detail      = "One poison dispeller. Priority-dispel on high stacks.",
            suggestion  = nil,
        },
        adequate = {
            severity    = nil,
            banner      = nil,
            panelStatus = nil,
            detail      = "Poison removal is well covered.",
            suggestion  = nil,
        },
    },

    thresholds = { none = 0, single = 1, adequate = 2 },

    personalReminder = {
        severity = "warning",
        banner   = "You can talent into poison removal!",
        detail   = "Your class has access to %spellName%. Consider it for this content.",
    },
}

D.capabilities.dispel_disease = {
    label       = "Disease Removal",
    description = "Ability to remove Disease debuffs from friendly targets.",
    icon        = 136066,
    color       = { 0.6, 0.4, 0.0 },
    tags        = { "dispel", "disease" },

    providers = {
        {
            class     = "PALADIN",
            specID    = 65,
            spellID   = 4987,
            spellName = "Cleanse",
            note      = "Holy only. Also removes magic and poison. 8 sec CD.",
        },
        {
            class     = "MONK",
            specID    = 270,
            spellID   = 115450,
            spellName = "Detox",
            note      = "Mistweaver Detox also removes magic. 8 sec CD.",
        },
        {
            class     = "PRIEST",
            specID    = 256,
            spellID   = 527,
            spellName = "Purify",
            note      = "Disc only. Also removes magic. 8 sec CD.",
        },
        {
            class     = "PRIEST",
            specID    = 257,
            spellID   = 527,
            spellName = "Purify",
            note      = "Holy only. Also removes magic. 8 sec CD.",
        },
    },

    conditions = {
        none = {
            severity    = "warning",
            banner      = "No disease dispel in group!",
            panelStatus = "NONE",
            detail      = "No one can remove diseases. Some dungeons have dangerous disease effects that stack if not removed.",
            suggestion  = "A Holy Paladin, Priest healer, or MW Monk can remove disease.",
        },
        single = {
            severity    = nil,
            banner      = nil,
            panelStatus = nil,
            detail      = "One disease dispeller. Should be sufficient for most content.",
            suggestion  = nil,
        },
        adequate = {
            severity    = nil,
            banner      = nil,
            panelStatus = nil,
            detail      = "Disease removal is well covered.",
            suggestion  = nil,
        },
    },

    thresholds = { none = 0, single = 1, adequate = 2 },

    personalReminder = {
        severity = "warning",
        banner   = "You can talent into disease removal!",
        detail   = "Your class has access to %spellName%. Consider it for this content.",
    },
}

D.capabilities.dispel_magic = {
    label       = "Magic Removal",
    description = "Ability to remove Magic debuffs from friendly targets.",
    icon        = 136120,
    color       = { 0.2, 0.5, 1.0 },
    tags        = { "dispel", "magic" },

    providers = {
        {
            class     = "PRIEST",
            specID    = 256,
            spellID   = 527,
            spellName = "Purify",
            note      = "Disc only. Also removes disease. 8 sec CD.",
        },
        {
            class     = "PRIEST",
            specID    = 257,
            spellID   = 527,
            spellName = "Purify",
            note      = "Holy only. Also removes disease. 8 sec CD.",
        },
        {
            class     = "PALADIN",
            specID    = 65,
            spellID   = 4987,
            spellName = "Cleanse",
            note      = "Holy only. Also removes poison and disease. 8 sec CD.",
        },
        {
            class     = "MONK",
            specID    = 270,
            spellID   = 115450,
            spellName = "Detox",
            note      = "Mistweaver only. Also removes poison. 8 sec CD.",
        },
        {
            class     = "DRUID",
            specID    = 105,
            spellID   = 88423,
            spellName = "Nature's Cure",
            note      = "Resto only. Also removes curse and poison. 8 sec CD.",
        },
        {
            class     = "SHAMAN",
            specID    = 264,
            spellID   = 77130,
            spellName = "Purify Spirit",
            note      = "Resto only. Also removes curse. 8 sec CD.",
        },
        {
            class     = "EVOKER",
            specID    = 1468,
            spellID   = 365585,
            spellName = "Expunge",
            note      = "Preservation only. Also removes poison and bleed. 8 sec CD.",
        },
    },

    conditions = {
        none = {
            severity    = "critical",
            banner      = "No magic dispel in group!",
            panelStatus = "NONE",
            detail      = "Nobody can remove magic debuffs from allies. Many boss and trash mechanics apply magic effects that must be dispelled quickly.",
            suggestion  = "Any healer except Resto Druid (without NPC) can dispel magic. Consider your healer choice.",
        },
        single = {
            severity    = nil,
            banner      = nil,
            panelStatus = nil,
            detail      = "One magic dispeller (your healer). Standard for 5-man.",
            suggestion  = nil,
        },
        adequate = {
            severity    = nil,
            banner      = nil,
            panelStatus = nil,
            detail      = "Magic removal is well covered.",
            suggestion  = nil,
        },
    },

    thresholds = { none = 0, single = 1, adequate = 1 },

    personalReminder = nil,
}

