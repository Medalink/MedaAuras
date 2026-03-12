local _, ns = ...

ns.RemindersData = {
    dataVersion   = 2,
    lastUpdated   = "2026-03-12",

    sources       = {},
    capabilities  = {},
    contexts      = { dungeons = {}, delves = {}, raids = {}, instanceTypes = {}, affixes = {} },
    rules         = {},
    groupCompDisplay = {},
    specRegistry  = {
        byClass = {},
        bySpecID = {},
    },
    personal      = {
        bySpec = {},
    },
    recommendations = {},
}

-- Source registry
local S = ns.RemindersData.sources

S.archon = {
    label = "Archon",
    badge = "|cff00ccff[A]|r",
    color = { 0, 0.8, 1.0 },
    url   = "archon.gg",
    lastFetched = 1773333704,
}

S.wowhead = {
    label = "Wowhead",
    badge = "|cffff8800[W]|r",
    color = { 1.0, 0.53, 0 },
    url   = "wowhead.com",
    lastFetched = 1773333704,
}

S.icyveins = {
    label = "Icy Veins",
    badge = "|cff33cc33[IV]|r",
    color = { 0.2, 0.8, 0.2 },
    url   = "icy-veins.com",
    lastFetched = 1773333704,
}
