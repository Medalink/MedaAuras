local ADDON_NAME, ns = ...

local StopData = {}
ns.StopData = StopData

local C_Spell = C_Spell
local GetSpellBaseCooldown = GetSpellBaseCooldown

if MedaAuras and MedaAuras.Log then
    MedaAuras.Log("[StopData] Loaded OK")
end

local RAW_STOPS = {
    [107570] = { class = "WARRIOR",      category = "stun",      fallbackCD = 30,  talentCheck = 107570 }, -- Storm Bolt
    [46968]  = { class = "WARRIOR",      category = "stun",      fallbackCD = 40,  talentCheck = 46968  }, -- Shockwave
    [5246]   = { class = "WARRIOR",      category = "fear",      fallbackCD = 90 },                         -- Intimidating Shout

    [31661]  = { class = "MAGE",         category = "disorient", fallbackCD = 45,  talentCheck = 31661  }, -- Dragon's Breath

    [853]    = { class = "PALADIN",      category = "stun",      fallbackCD = 60 },                         -- Hammer of Justice
    [115750] = { class = "PALADIN",      category = "disorient", fallbackCD = 90,  talentCheck = 115750 }, -- Blinding Light

    [5211]   = { class = "DRUID",        category = "stun",      fallbackCD = 50,  talentCheck = 5211   }, -- Mighty Bash
    [99]     = { class = "DRUID",        category = "incap",     fallbackCD = 30,  talentCheck = 99     }, -- Incapacitating Roar
    [132469] = { class = "DRUID",        category = "knock",     fallbackCD = 30,  talentCheck = 132469 }, -- Typhoon

    [221562] = { class = "DEATHKNIGHT",  category = "stun",      fallbackCD = 45,  talentCheck = 221562 }, -- Asphyxiate
    [207167] = { class = "DEATHKNIGHT",  category = "disorient", fallbackCD = 60,  talentCheck = 207167 }, -- Blinding Sleet
    [49576]  = { class = "DEATHKNIGHT",  category = "grip",      fallbackCD = 25 },                         -- Death Grip

    [19577]  = { class = "HUNTER",       category = "stun",      fallbackCD = 60,  talentCheck = 19577  }, -- Intimidation
    [186387] = { class = "HUNTER",       category = "knock",     fallbackCD = 30,  talentCheck = 186387 }, -- Bursting Shot
    [213691] = { class = "HUNTER",       category = "disorient", fallbackCD = 30,  talentCheck = 213691 }, -- Scatter Shot

    [8122]   = { class = "PRIEST",       category = "fear",      fallbackCD = 60 },                         -- Psychic Scream
    [88625]  = { class = "PRIEST",       category = "disorient", fallbackCD = 30 },                         -- Holy Word: Chastise
    [205369] = { class = "PRIEST",       category = "fear",      fallbackCD = 30,  talentCheck = 205369 }, -- Mind Bomb

    [408]    = { class = "ROGUE",        category = "stun",      fallbackCD = 20 },                         -- Kidney Shot
    [1833]   = { class = "ROGUE",        category = "stun",      fallbackCD = 20 },                         -- Cheap Shot
    [2094]   = { class = "ROGUE",        category = "disorient", fallbackCD = 120 },                        -- Blind
    [1776]   = { class = "ROGUE",        category = "incap",     fallbackCD = 15 },                         -- Gouge

    [192058] = { class = "SHAMAN",       category = "stun",      fallbackCD = 60,  talentCheck = 192058 }, -- Capacitor Totem
    [51514]  = { class = "SHAMAN",       category = "incap",     fallbackCD = 30,  talentCheck = 51514  }, -- Hex
    [51490]  = { class = "SHAMAN",       category = "knock",     fallbackCD = 45,  talentCheck = 51490  }, -- Thunderstorm

    [5782]   = { class = "WARLOCK",      category = "fear",      fallbackCD = 0  },                         -- Fear
    [5484]   = { class = "WARLOCK",      category = "fear",      fallbackCD = 40,  talentCheck = 5484   }, -- Howl of Terror
    [6789]   = { class = "WARLOCK",      category = "horror",    fallbackCD = 45 },                         -- Mortal Coil
    [30283]  = { class = "WARLOCK",      category = "stun",      fallbackCD = 60,  talentCheck = 30283  }, -- Shadowfury

    [119381] = { class = "MONK",         category = "stun",      fallbackCD = 60,  talentCheck = 119381 }, -- Leg Sweep
    [115078] = { class = "MONK",         category = "incap",     fallbackCD = 45 },                         -- Paralysis
    [116844] = { class = "MONK",         category = "knock",     fallbackCD = 45,  talentCheck = 116844 }, -- Ring of Peace
    [198909] = { class = "MONK",         category = "disorient", fallbackCD = 45,  talentCheck = 198909 }, -- Song of Chi-Ji

    [179057] = { class = "DEMONHUNTER",  category = "stun",      fallbackCD = 60 },                         -- Chaos Nova
    [217832] = { class = "DEMONHUNTER",  category = "incap",     fallbackCD = 45 },                         -- Imprison
    [207685] = { class = "DEMONHUNTER",  category = "fear",      fallbackCD = 90,  talentCheck = 207685 }, -- Sigil of Misery
    [211881] = { class = "DEMONHUNTER",  category = "stun",      fallbackCD = 30,  talentCheck = 211881 }, -- Fel Eruption

    [368970] = { class = "EVOKER",       category = "knock",     fallbackCD = 90 },                         -- Tail Swipe
    [357214] = { class = "EVOKER",       category = "knock",     fallbackCD = 90 },                         -- Wing Buffet
    [360806] = { class = "EVOKER",       category = "sleep",     fallbackCD = 15,  talentCheck = 360806 }, -- Sleep Walk
}

local CLASS_STOP_IDS = {
    WARRIOR = { 107570, 46968, 5246 },
    MAGE = { 31661 },
    PALADIN = { 853, 115750 },
    DRUID = { 5211, 99, 132469 },
    DEATHKNIGHT = { 221562, 207167, 49576 },
    HUNTER = { 19577, 186387, 213691 },
    PRIEST = { 8122, 88625, 205369 },
    ROGUE = { 408, 1833, 2094, 1776 },
    SHAMAN = { 192058, 51514, 51490 },
    WARLOCK = { 5782, 5484, 6789, 30283 },
    MONK = { 119381, 115078, 116844, 198909 },
    DEMONHUNTER = { 179057, 217832, 207685, 211881 },
    EVOKER = { 368970, 357214, 360806 },
}

local SPEC_DEFAULT_STOP_IDS = {
    [71] = { 107570, 46968 },
    [72] = { 107570, 46968 },
    [73] = { 107570, 46968 },

    [62] = { 31661 },
    [63] = { 31661 },
    [64] = { 31661 },

    [65] = { 853, 115750 },
    [66] = { 853, 115750 },
    [70] = { 853, 115750 },

    [102] = { 132469, 5211 },
    [103] = { 5211, 99 },
    [104] = { 5211, 99 },
    [105] = { 132469, 99 },

    [250] = { 221562, 49576 },
    [251] = { 221562, 207167, 49576 },
    [252] = { 221562, 207167, 49576 },

    [253] = { 19577, 186387 },
    [254] = { 19577, 213691, 186387 },
    [255] = { 19577, 186387 },

    [256] = { 88625, 8122 },
    [257] = { 88625, 8122 },
    [258] = { 8122, 205369 },

    [259] = { 408, 1833, 2094 },
    [260] = { 408, 1833, 2094, 1776 },
    [261] = { 408, 1833, 2094 },

    [262] = { 192058, 51514, 51490 },
    [263] = { 192058, 51514 },
    [264] = { 192058, 51514, 51490 },

    [265] = { 5782, 5484, 6789, 30283 },
    [266] = { 5782, 5484, 6789, 30283 },
    [267] = { 5782, 5484, 6789, 30283 },

    [268] = { 119381, 115078, 116844 },
    [269] = { 119381, 115078, 116844 },
    [270] = { 119381, 115078, 116844, 198909 },

    [577] = { 179057, 217832, 211881 },
    [581] = { 179057, 217832, 207685 },

    [1467] = { 368970, 357214, 360806 },
    [1468] = { 368970, 357214, 360806 },
    [1473] = { 368970, 357214, 360806 },
}

local classLookupCache = {}
local allLookupCache

StopData.ALL_STOPS = RAW_STOPS

local function EnrichStop(spellID, entry)
    if not spellID or not entry then return nil end

    if entry.name and entry.icon and entry.cd then
        return entry
    end

    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID) or nil
    local cooldownMS = GetSpellBaseCooldown and GetSpellBaseCooldown(spellID) or 0
    if type(cooldownMS) ~= "number" then
        cooldownMS = 0
    end

    entry.spellID = spellID
    entry.name = entry.name or (info and info.name) or ("Spell " .. tostring(spellID))
    entry.icon = entry.icon or (info and info.iconID) or 134400
    entry.cd = entry.cd or ((cooldownMS > 0 and cooldownMS / 1000) or entry.fallbackCD or 0)
    return entry
end

function StopData:GetStop(spellID)
    local entry = RAW_STOPS[spellID]
    if not entry then return nil end
    return EnrichStop(spellID, entry)
end

function StopData:GetClassStops(classToken)
    local cached = classLookupCache[classToken]
    if cached then
        return cached.lookupTable, cached.ids
    end

    local lookupTable = {}
    local ids = {}
    for _, spellID in ipairs(CLASS_STOP_IDS[classToken] or {}) do
        local entry = self:GetStop(spellID)
        if entry then
            lookupTable[spellID] = entry
            ids[#ids + 1] = spellID
        end
    end

    classLookupCache[classToken] = {
        lookupTable = lookupTable,
        ids = ids,
    }
    return lookupTable, ids
end

function StopData:GetAllStopsLookup()
    if allLookupCache then
        return allLookupCache
    end

    local lookupTable = {}
    for spellID in pairs(RAW_STOPS) do
        local entry = self:GetStop(spellID)
        if entry then
            lookupTable[spellID] = entry
        end
    end
    allLookupCache = lookupTable
    return lookupTable
end

function StopData:GetDefaultStopsForSpec(specID, classToken)
    local ids = SPEC_DEFAULT_STOP_IDS[specID] or CLASS_STOP_IDS[classToken] or {}
    local results = {}
    for _, spellID in ipairs(ids) do
        local entry = self:GetStop(spellID)
        if entry then
            results[#results + 1] = entry
        end
    end
    return results
end

function StopData:GetAllPlayerStopCandidates(classToken, specID)
    local ids = {}
    local seen = {}

    for _, spellID in ipairs(SPEC_DEFAULT_STOP_IDS[specID] or {}) do
        if not seen[spellID] then
            seen[spellID] = true
            ids[#ids + 1] = spellID
        end
    end

    for _, spellID in ipairs(CLASS_STOP_IDS[classToken] or {}) do
        if not seen[spellID] then
            seen[spellID] = true
            ids[#ids + 1] = spellID
        end
    end

    local results = {}
    for _, spellID in ipairs(ids) do
        local entry = self:GetStop(spellID)
        if entry then
            results[#results + 1] = entry
        end
    end
    return results
end
