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

