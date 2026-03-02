local _, ns = ...
local D = ns.RemindersData
D.groupCompDisplay = D.groupCompDisplay or {}

D.groupCompDisplay[#D.groupCompDisplay + 1] = {
    id           = "dispel_matrix",
    label        = "Dispel Coverage",
    description  = "Shows which dispel types your group can handle.",
    capabilities = { "dispel_curse", "dispel_poison", "dispel_disease", "dispel_magic" },
}

D.groupCompDisplay[#D.groupCompDisplay + 1] = {
    id           = "utility_coverage",
    label        = "Utility",
    description  = "Key group utility abilities.",
    capabilities = { "bloodlust", "battle_res" },
}

