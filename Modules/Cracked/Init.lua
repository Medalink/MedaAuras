local _, ns = ...

ns.Cracked = ns.Cracked or {}

local C = ns.Cracked

local MODULE_NAME = "Cracked"
local MODULE_VERSION = "0.2"
local MODULE_STABILITY = "experimental"

local MODULE_DEFAULTS = {
    enabled = false,
    frameWidth = 240,
    barHeight = 24,
    locked = false,
    showTitle = true,
    showIcons = true,
    showPlayerName = true,
    showSpellName = false,
    growUp = false,
    alpha = 0.9,
    nameFontSize = 0,
    readyFontSize = 0,
    showExternals = true,
    showPartyWide = true,
    showMajor = true,
    showPersonal = false,
    showMissingGroupBuffs = true,
    trackExperimentalDefensives = false,
    trackExperimentalImportantBuffs = false,
    trackRiskyRaidEffects = false,
    forceFullAuraRescan = false,
    showInDungeon = true,
    showInRaid = true,
    showInOpenWorld = false,
    showInArena = true,
    showInBG = false,
    paneMode = "combined",
    font = "default",
    titleFontSize = 12,
    iconSize = 0,
    panePositions = {},
    paneStyles = {},
    position = { point = "CENTER", x = 250, y = -150 },
}

MedaAuras:RegisterModule({
    name = MODULE_NAME,
    title = "Cracked",
    version = MODULE_VERSION,
    stability = MODULE_STABILITY,
    author = "Medalink",
    description = "Tracks the supported subset of party defensive cooldowns in M+ and dungeons, "
        .. "with optional experimental important buffs and risky raid effects. "
        .. "Detects when party members use supported abilities and "
        .. "displays cooldown bars with active/CD states, colored by class. "
        .. "Uses filtered aura tracking plus tainted spell-ID matching.",
    sidebarDesc = "Party cooldown tracker (experimental).",
    defaults = MODULE_DEFAULTS,
    OnInitialize = function(moduleDB)
        if C.OnInitialize then
            C.OnInitialize(moduleDB)
        end
    end,
    OnEnable = function(moduleDB)
        if C.OnEnable then
            C.OnEnable(moduleDB)
        end
    end,
    OnDisable = function(moduleDB)
        if C.OnDisable then
            C.OnDisable(moduleDB)
        end
    end,
    pages = {
        { id = "settings", label = "Settings" },
    },
    buildPage = function(_, parent)
        if C.BuildSettingsPage then
            C.BuildSettingsPage(parent, MedaAuras:GetModuleDB(MODULE_NAME))
        end
        return 760
    end,
})
