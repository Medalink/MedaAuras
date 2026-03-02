local _, ns = ...
local D = ns.RemindersData
D.contexts = D.contexts or {}
D.contexts.dungeons = D.contexts.dungeons or {}
D.contexts.instanceTypes = D.contexts.instanceTypes or {}

D.contexts.dungeons[2526] = {
    name   = "Algeth'ar Academy",
    notes  = {},
    header = "Algeth'ar Academy -- key dispel hazards",
}

D.contexts.instanceTypes.party = { label = "Dungeon" }
D.contexts.instanceTypes.raid = { label = "Raid" }
D.contexts.instanceTypes.scenario = { label = "Scenario" }

