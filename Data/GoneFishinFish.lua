local _, ns = ...

ns.GoneFishinData = ns.GoneFishinData or {}
ns.GoneFishinData.dataVersion = 2

-- ============================================================================
-- Category constants (used in midnightItems and runtime classification)
-- ============================================================================

ns.GoneFishinData.CATEGORIES = {
    FISH     = "fish",
    RECIPE   = "recipe",
    TREASURE = "treasure",
    LINE     = "line",
    ROD      = "rod",
    JUNK     = "junk",
    GEAR     = "gear",
    PET      = "pet",
    MOUNT    = "mount",
    TOY      = "toy",
    REAGENT  = "reagent",
    OTHER    = "other",
}

local CAT = ns.GoneFishinData.CATEGORIES

-- ============================================================================
-- Midnight Items  (Pokedex checklist)
--
-- Keys are item IDs.  Every entry has at minimum:
--   name, category
-- Fish add: icon, quality, rarity, openWaterZones, pools, notes?
-- Recipes add: craftedName, targetFishName, reagents, notes?
-- Treasures add: source, notes?
-- Line fragments add: quality, chain, tier, notes?
-- Rods add: quality, notes?
-- ============================================================================

ns.GoneFishinData.midnightItems = {

    -- =======================================================================
    -- FISH  (20)  –  data from wow-professions.com + WoWDB icons/quality
    -- =======================================================================

    -- Common ----------------------------------------------------------------

    [238365] = {
        name = "Sin'dorei Swarmer",
        icon = "inv_misc_fish_41",
        quality = 1, category = CAT.FISH, rarity = "common",
        openWaterZones = { "Eversong", "Zul'Aman" },
        pools = { "Bubbling Bloom", "Sunwell Swarm", "Surface Ripple" },
    },
    [238366] = {
        name = "Lynxfish",
        icon = "inv_12_profession_fishing_lynxfish_yellow",
        quality = 1, category = CAT.FISH, rarity = "common",
        openWaterZones = { "Eversong", "Zul'Aman" },
        pools = { "Bubbling Bloom", "Sunwell Swarm", "Surface Ripple" },
    },
    [238367] = {
        name = "Root Crab",
        icon = "inv_crab2_bronze",
        quality = 1, category = CAT.FISH, rarity = "common",
        openWaterZones = { "Zul'Aman", "Harandar" },
        pools = { "Obscured School", "Surface Ripple" },
    },
    [238371] = {
        name = "Arcane Wyrmfish",
        icon = "inv_crystalinefish_blue",
        quality = 1, category = CAT.FISH, rarity = "common",
        openWaterZones = { "Eversong", "Harandar" },
        pools = { "Bubbling Bloom", "Sunwell Swarm", "Blossoming Torrent" },
    },
    [238382] = {
        name = "Gore Guppy",
        icon = "inv_12_profession_fishing_goreguppies_red",
        quality = 2, category = CAT.FISH, rarity = "common",
        openWaterZones = { "Zul'Aman" },
        pools = { "Hunter Surge", "Surface Ripple" },
    },

    -- Uncommon ---------------------------------------------------------------

    [238369] = {
        name = "Bloomtail Minnow",
        icon = "inv_10_fishing_fishice_color4",
        quality = 2, category = CAT.FISH, rarity = "uncommon",
        openWaterZones = { "Harandar" },
        pools = { "Lashing Waves" },
    },
    [238370] = {
        name = "Shimmer Spinefish",
        icon = "inv_misc_fish_77",
        quality = 2, category = CAT.FISH, rarity = "uncommon",
        openWaterZones = { "Eversong", "Harandar" },
        pools = { "Bloom Swarm", "Bubbling Bloom", "Sunwell Swarm", "Blossoming Torrent" },
    },
    [238372] = {
        name = "Restored Songfish",
        icon = "inv_misc_fish_36",
        quality = 2, category = CAT.FISH, rarity = "uncommon",
        openWaterZones = { "Eversong", "Harandar" },
        pools = { "Bloom Swarm", "Bubbling Bloom", "Sunwell Swarm", "Blossoming Torrent" },
    },
    [238374] = {
        name = "Tender Lumifin",
        icon = "inv_12_profession_fishing_lumifin_blue",
        quality = 2, category = CAT.FISH, rarity = "uncommon",
        openWaterZones = { "Harandar" },
        pools = { "Blossoming Torrent" },
    },
    [238375] = {
        name = "Fungalskin Pike",
        icon = "inv_misc_fish_38",
        quality = 2, category = CAT.FISH, rarity = "uncommon",
        openWaterZones = { "Zul'Aman", "Harandar" },
        pools = { "Lashing Waves", "Obscured School", "Surface Ripple" },
    },
    [238377] = {
        name = "Blood Hunter",
        icon = "inv_10_fishing_fishlava_color4",
        quality = 2, category = CAT.FISH, rarity = "uncommon",
        openWaterZones = { "Zul'Aman", "Voidstorm" },
        pools = { "Surface Ripple", "Hunter Surge", "Viscous Void", "Oceanic Vortex" },
        notes = "Spawns a hostile Blood Hunter Spirit when caught. Use Amani Angler's Ward to prevent.",
    },
    [238378] = {
        name = "Shimmersiren",
        icon = "inv_misc_fish_72",
        quality = 2, category = CAT.FISH, rarity = "uncommon",
        openWaterZones = { "Voidstorm" },
        pools = { "Viscous Void", "Oceanic Vortex" },
    },
    [238384] = {
        name = "Sunwell Fish",
        icon = "inv_misc_fish_53",
        quality = 2, category = CAT.FISH, rarity = "uncommon",
        openWaterZones = { "Eversong" },
        pools = { "Sunwell Swarm", "Blossoming Torrent" },
    },

    -- Rare -------------------------------------------------------------------

    [238368] = {
        name = "Twisted Tetra",
        icon = "inv_misc_fish_64",
        quality = 3, category = CAT.FISH, rarity = "rare",
        openWaterZones = { "Eversong", "Zul'Aman", "Harandar" },
        pools = {},
    },
    [238373] = {
        name = "Ominous Octopus",
        icon = "inv_babyoctopus_black",
        quality = 3, category = CAT.FISH, rarity = "rare",
        openWaterZones = { "Voidstorm" },
        pools = { "Viscous Void", "Oceanic Vortex" },
    },
    [238376] = {
        name = "Lucky Loa",
        icon = "inv_fishing_elysianthade",
        quality = 3, category = CAT.FISH, rarity = "rare",
        openWaterZones = { "Zul'Aman" },
        pools = { "Obscured School", "Surface Ripple" },
    },
    [238379] = {
        name = "Warping Wise",
        icon = "inv_misc_fish_69",
        quality = 3, category = CAT.FISH, rarity = "rare",
        openWaterZones = { "Voidstorm" },
        pools = { "Viscous Void", "Oceanic Vortex" },
        notes = "Using this fish teleports you to a random Midnight zone.",
    },
    [238380] = {
        name = "Null Voidfish",
        icon = "inv_misc_fish_60",
        quality = 3, category = CAT.FISH, rarity = "rare",
        openWaterZones = { "Voidstorm" },
        pools = { "Viscous Void", "Oceanic Vortex" },
    },
    [238381] = {
        name = "Hollow Grouper",
        icon = "inv_12_profession_fishing_nullvoidfish_purple",
        quality = 3, category = CAT.FISH, rarity = "rare",
        openWaterZones = { "Voidstorm" },
        pools = { "Viscous Void", "Oceanic Vortex" },
    },
    [238383] = {
        name = "Eversong Trout",
        icon = "inv_fishing_lanesnapper",
        quality = 3, category = CAT.FISH, rarity = "rare",
        openWaterZones = { "Eversong" },
        pools = { "Sunwell Swarm", "Bubbling Bloom" },
    },

    -- =======================================================================
    -- LURE / WARD RECIPES  (5)  –  drop from treasure pools
    -- Key = recipe item ID (the item that drops while fishing)
    -- =======================================================================

    [244817] = {
        name = "Recipe: Blood Hunter Lure",
        category = CAT.RECIPE,
        craftedName   = "Blood Hunter Lure",
        targetFishName = "Blood Hunter",
        reagents = { { 238382, 5 } },
        source = "Careless Cargo, Lost Treasures",
    },
    [244816] = {
        name = "Recipe: Lucky Loa Lure",
        category = CAT.RECIPE,
        craftedName   = "Lucky Loa Lure",
        targetFishName = "Lucky Loa",
        reagents = { { 238365, 5 } },
        source = "Careless Cargo, Lost Treasures",
    },
    [244815] = {
        name = "Recipe: Ominous Octopus Lure",
        category = CAT.RECIPE,
        craftedName    = "Ominous Octopus Lure",
        targetFishName = "Ominous Octopus",
        reagents = { { 238380, 5 } },
        source = "Careless Cargo, Lost Treasures",
    },
    [258511] = {
        name = "Recipe: Sunwell Fish Lure",
        category = CAT.RECIPE,
        craftedName    = "Sunwell Fish Lure",
        targetFishName = "Sunwell Fish",
        reagents = { { 238365, 5 } },
        source = "Careless Cargo, Lost Treasures",
    },
    [244791] = {
        name = "Recipe: Amani Angler's Ward",
        category = CAT.RECIPE,
        craftedName    = "Amani Angler's Ward",
        targetFishName = nil,
        reagents = { { 238377, 2 } },
        notes  = "Prevents Blood Hunter Spirits from spawning for 30 min.",
        source = "Careless Cargo, Lost Treasures",
    },

    -- =======================================================================
    -- TREASURE / SPECIAL ITEMS  (3)
    -- =======================================================================

    [243343] = {
        name = "Angler's Anomaly",
        category = CAT.TREASURE,
        notes  = "Creates an Oceanic Vortex pool at your location. Lasts longer than natural pools.",
        source = "Treasure pools",
    },
    [262649] = {
        name = "An Angler's Deep Dive",
        category = CAT.TREASURE,
        notes  = "Increases Midnight Fishing skill by 10.",
        source = "Careless Cargo, Lost Treasures, Patient Treasures",
    },
    [243302] = {
        name = "Aquarius Bloom",
        category = CAT.TREASURE,
        notes  = "Turns any fishing pool into a Bloom Swarm.",
        source = "Treasure pools",
    },

    -- =======================================================================
    -- FISHING LINE FRAGMENTS  (9)  –  fished up while fishing anywhere
    -- =======================================================================

    -- Bloomline chain: 100 Shredded -> 1 Stranded, 20 Stranded -> 1 Weak, 5 Weak -> 1 Angler's
    [262792] = { name = "Shredded Bloomline",   category = CAT.LINE, quality = 1, chain = "bloom",   tier = 1 },
    [262793] = { name = "Stranded Bloomline",   category = CAT.LINE, quality = 1, chain = "bloom",   tier = 2 },
    [262794] = { name = "Weak Bloomline",       category = CAT.LINE, quality = 2, chain = "bloom",   tier = 3 },
    [262795] = { name = "Angler's Bloomline",   category = CAT.LINE, quality = 3, chain = "bloom",   tier = 4 },

    -- Glimmerline chain: 100 Shredded -> 1 Stranded, 20 Stranded -> 1 Weak, 20 Weak -> 1 Angler's
    [262797] = { name = "Shredded Glimmerline", category = CAT.LINE, quality = 1, chain = "glimmer", tier = 1 },
    [262798] = { name = "Stranded Glimmerline", category = CAT.LINE, quality = 1, chain = "glimmer", tier = 2 },
    [262799] = { name = "Weak Glimmerline",     category = CAT.LINE, quality = 2, chain = "glimmer", tier = 3 },
    [262800] = { name = "Angler's Glimmerline", category = CAT.LINE, quality = 3, chain = "glimmer", tier = 4 },

    -- Final combine: 1 Angler's Bloomline + 1 Angler's Glimmerline
    [262796] = {
        name = "Midnight Angler's Grand Line",
        category = CAT.LINE, quality = 4, chain = "final", tier = 5,
        notes = "Doubles treasure drops. Combine Angler's Bloomline + Angler's Glimmerline.",
    },

    -- =======================================================================
    -- FISHING RODS  (3)  –  crafted by Engineers, shown for reference
    -- =======================================================================

    [244711] = { name = "Farstrider Hobbyist Rod", category = CAT.ROD, quality = 2, notes = "Green quality, tradeable on AH." },
    [244712] = { name = "Sin'dorei Angler's Rod",  category = CAT.ROD, quality = 3, notes = "Rare, BoP. Place a Crafting Order." },
    [259179] = { name = "Sin'dorei Reeler's Rod",  category = CAT.ROD, quality = 4, notes = "Epic, BoP. Requires Fused Vitality." },
}

-- ============================================================================
-- Pools  –  enriched with fish contents and zone locations
-- ============================================================================

ns.GoneFishinData.pools = {
    ["Bubbling Bloom"] = {
        zones = { "Eversong" },
        fish  = { 238365, 238366, 238370, 238371, 238372, 238383 },
    },
    ["Sunwell Swarm"] = {
        zones = { "Eversong" },
        fish  = { 238365, 238366, 238370, 238371, 238372, 238383, 238384 },
    },
    ["Surface Ripple"] = {
        zones = { "Zul'Aman" },
        fish  = { 238365, 238366, 238367, 238375, 238376, 238377, 238382 },
    },
    ["Hunter Surge"] = {
        zones = { "Zul'Aman" },
        fish  = { 238377, 238382 },
    },
    ["Obscured School"] = {
        zones = { "Zul'Aman", "Harandar" },
        fish  = { 238367, 238375, 238376 },
    },
    ["Bloom Swarm"] = {
        zones = { "Eversong", "Harandar" },
        fish  = { 238370, 238372 },
    },
    ["Blossoming Torrent"] = {
        zones = { "Harandar" },
        fish  = { 238370, 238371, 238372, 238374, 238384 },
    },
    ["Lashing Waves"] = {
        zones = { "Harandar" },
        fish  = { 238369, 238375 },
    },
    ["Song Swarm"] = {
        zones = { "Eversong" },
        fish  = {},
    },
    ["Sunbath School"] = {
        zones = { "Eversong" },
        fish  = {},
    },
    ["Viscous Void"] = {
        zones = { "Voidstorm" },
        fish  = { 238373, 238377, 238378, 238379, 238380, 238381 },
        notes = "Best source for Null Voidfish and Ominous Octopus.",
    },
    ["Oceanic Vortex"] = {
        zones = { "Voidstorm" },
        fish  = { 238373, 238377, 238378, 238379, 238380, 238381 },
        notes = "Bubble pools; only way to fish in Voidstorm. Don't appear on minimap fish tracking.",
    },
    ["Careless Cargo"] = {
        zones = { "Any" },
        fish  = {},
        type  = "treasure",
        notes = "Lure recipes, fishing line components, Motes, and other treasures.",
    },
    ["Lost Treasures"] = {
        zones = { "Any" },
        fish  = {},
        type  = "treasure",
        notes = "Very rare. Similar loot to Careless Cargo.",
    },
    ["Salmon Pool"] = {
        zones = { "Eversong" },
        fish  = {},
    },
}

-- ============================================================================
-- Zones  –  skill thresholds and metadata
-- ============================================================================

ns.GoneFishinData.zones = {
    ["Eversong"] = {
        skill   = 1,
        range   = "1-75",
        aliases = { "Eversong Woods", "Silvermoon City", "Silvermoon" },
    },
    ["Zul'Aman"] = {
        skill   = 75,
        range   = "75-150",
        aliases = { "Zul'Aman" },
    },
    ["Harandar"] = {
        skill   = 150,
        range   = "150-225",
        aliases = { "Harandar" },
    },
    ["Voidstorm"] = {
        skill   = 225,
        range   = "225-300",
        aliases = { "Voidstorm" },
        notes   = "No open water. Fish only from Oceanic Vortex bubble pools.",
    },
}

-- ============================================================================
-- Lure-to-fish quick-lookup  (built from midnightItems at load time)
-- Maps target fish name -> { lureName, recipeItemID, reagents }
-- ============================================================================

ns.GoneFishinData.lureLookup = {}
for itemID, info in pairs(ns.GoneFishinData.midnightItems) do
    if info.category == CAT.RECIPE and info.targetFishName then
        ns.GoneFishinData.lureLookup[info.targetFishName] = {
            lureName     = info.craftedName or info.name,
            recipeItemID = itemID,
            reagents     = info.reagents,
        }
    end
end

-- ============================================================================
-- Zone alias reverse-lookup  (alias string -> canonical zone name)
-- ============================================================================

ns.GoneFishinData.zoneAliasMap = {}
for canonical, zoneInfo in pairs(ns.GoneFishinData.zones) do
    ns.GoneFishinData.zoneAliasMap[canonical] = canonical
    if zoneInfo.aliases then
        for _, alias in ipairs(zoneInfo.aliases) do
            ns.GoneFishinData.zoneAliasMap[alias] = canonical
        end
    end
end
