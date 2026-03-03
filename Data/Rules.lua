local _, ns = ...
local D = ns.RemindersData
D.rules = D.rules or {}

D.rules[#D.rules + 1] = {
    id      = "generic_dungeon_dispels",
    trigger = {
        type         = "instance",
        instanceType = "party",
    },
    checks = {
        { capability = "dispel_curse" },
        { capability = "dispel_poison" },
        { capability = "dispel_disease" },
        { capability = "dispel_magic" },
    },
}

D.rules[#D.rules + 1] = {
    id      = "generic_dungeon_lust",
    trigger = {
        type         = "instance",
        instanceType = "party",
    },
    checks = {
        { capability = "bloodlust" },
    },
}

D.rules[#D.rules + 1] = {
    id      = "generic_dungeon_bres",
    trigger = {
        type         = "instance",
        instanceType = "party",
    },
    checks = {
        { capability = "battle_res" },
    },
}

D.rules[#D.rules + 1] = {
    id      = "generic_dungeon_offensive",
    trigger = {
        type         = "instance",
        instanceType = "party",
    },
    checks = {
        { capability = "offensive_dispel" },
        { capability = "soothe" },
        { capability = "shroud" },
    },
}

D.rules[#D.rules + 1] = {
    id      = "windrunner_curse",
    trigger = {
        type         = "instance",
        instanceIDs  = { 2801 },
    },
    checks = {
        {
            capability = "dispel_curse",
            overrides = {
                none = {
                    severity   = "critical",
                    banner     = "Windrunner Spire: Curse of Darkness spawns Dark Entity if not dispelled!",
                    detail     = "Curse of Darkness from Derelict Duo spawns a Dark Entity if not removed. Curse dispel is essential.",
                    suggestion = "Bring a Mage or Resto Druid/Shaman for curse removal.",
                },
            },
        },
        {
            capability = "offensive_dispel",
            overrides = {
                none = {
                    severity   = "warning",
                    banner     = nil,
                    detail     = "Spellguard's Protection shields on mobs require purge to remove efficiently.",
                    suggestion = nil,
                },
            },
        },
    },
}

D.rules[#D.rules + 1] = {
    id      = "magisters_purge",
    trigger = {
        type         = "instance",
        instanceIDs  = { 2803 },
    },
    checks = {
        {
            capability = "offensive_dispel",
            overrides = {
                none = {
                    severity   = "critical",
                    banner     = "Magister's Terrace: Enemy shields MUST be purged!",
                    detail     = "Frequent magical shields on enemies require offensive dispel. This is essential for efficient damage.",
                    suggestion = "Bring a Shaman (Purge), Mage (Spellsteal), or Priest.",
                },
            },
        },
    },
}

D.rules[#D.rules + 1] = {
    id      = "blindingvale_purge",
    trigger = {
        type         = "instance",
        instanceIDs  = { 2804 },
    },
    checks = {
        {
            capability = "offensive_dispel",
            overrides = {
                none = {
                    severity   = "critical",
                    banner     = "The Blinding Vale: Light shields need purging!",
                    detail     = "Light-empowered enemies gain purgeable shields. Offensive dispel is important.",
                    suggestion = nil,
                },
            },
        },
    },
}

D.rules[#D.rules + 1] = {
    id      = "maisara_disease",
    trigger = {
        type         = "instance",
        instanceIDs  = { 2806 },
    },
    checks = {
        {
            capability = "dispel_disease",
            overrides = {
                none = {
                    severity   = "critical",
                    banner     = "Maisara Caverns: Necromantic disease effects are deadly!",
                    detail     = "Necromantic casters apply dangerous disease debuffs throughout. Disease dispel is essential.",
                    suggestion = "Bring a Paladin, Priest, or MW Monk healer for disease removal.",
                },
            },
        },
    },
}

D.rules[#D.rules + 1] = {
    id      = "murderrow_purge",
    trigger = {
        type         = "instance",
        instanceIDs  = { 2802 },
    },
    checks = {
        {
            capability = "offensive_dispel",
            overrides = {
                none = {
                    severity   = "warning",
                    banner     = nil,
                    detail     = "Fel shields on enemies should be purged for efficient damage.",
                    suggestion = nil,
                },
            },
        },
    },
}

D.rules[#D.rules + 1] = {
    id      = "pitofsaron_disease",
    trigger = {
        type         = "instance",
        instanceIDs  = { 658 },
    },
    checks = {
        {
            capability = "dispel_disease",
            overrides = {
                none = {
                    severity   = "critical",
                    banner     = "Pit of Saron: Scourge disease effects are constant!",
                    detail     = "Scourge enemies apply disease effects throughout the dungeon. Disease dispel is critical.",
                    suggestion = "Bring a healer that can dispel disease.",
                },
            },
        },
    },
}

D.rules[#D.rules + 1] = {
    id      = "seat_purge",
    trigger = {
        type         = "instance",
        instanceIDs  = { 1753 },
    },
    checks = {
        {
            capability = "offensive_dispel",
            overrides = {
                none = {
                    severity   = "warning",
                    banner     = nil,
                    detail     = "Some encounters have purgeable Void shields.",
                    suggestion = nil,
                },
            },
        },
    },
}

D.rules[#D.rules + 1] = {
    id      = "delve_dispels",
    trigger = {
        type         = "instance",
        instanceType = "delve",
    },
    checks = {
        { capability = "dispel_curse" },
        { capability = "dispel_poison" },
        { capability = "dispel_disease" },
        { capability = "dispel_magic" },
    },
}

