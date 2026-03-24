local _, ns = ...

ns.MissingPet = ns.MissingPet or {}

local M = ns.MissingPet

M.MODULE_NAME = "MissingPet"
M.MODULE_VERSION = "1.0"
M.MODULE_STABILITY = "stable"
M.DEFAULT_TEXT = "Pet Missing"
M.DEFAULT_TAUNT_TEXT = "Pet Taunt On"
M.DEFAULT_FONT = GameFontNormalLarge and select(1, GameFontNormalLarge:GetFont()) or "Fonts\\FRIZQT__.TTF"
M.GOOD_COLOR = { 0.30, 0.85, 0.30 }
M.WARN_COLOR = { 1.00, 0.28, 0.28 }
M.INFO_COLOR = { 0.72, 0.76, 0.84 }
M.PAGE_HEIGHT = 460

M.DEFAULTS = {
    enabled = false,
    locked = false,
    onlyInCombat = false,
    text = M.DEFAULT_TEXT,
    textSize = 30,
    font = "default",
    color = { 1.0, 0.28, 0.28, 1.0 },
    position = { point = "CENTER", x = 0, y = 220 },
}

function M.GetDB()
    return MedaAuras:GetModuleDB(M.MODULE_NAME)
end

MedaAuras:RegisterModule({
    name = M.MODULE_NAME,
    title = "Missing Pet",
    version = M.MODULE_VERSION,
    stability = M.MODULE_STABILITY,
    author = "Medalink",
    description = "Shows a simple on-screen warning when your expected pet is missing or its taunt is enabled in raid and dungeon content.",
    sidebarDesc = "Displays a pulsing text reminder for missing pets and pet taunt issues.",
    defaults = M.DEFAULTS,
    OnInitialize = function(moduleDB)
        if M.OnInitialize then
            M.OnInitialize(moduleDB)
        end
    end,
    OnEnable = function(moduleDB)
        if M.OnEnable then
            M.OnEnable(moduleDB)
        end
    end,
    OnDisable = function(moduleDB)
        if M.OnDisable then
            M.OnDisable(moduleDB)
        end
    end,
    pages = {
        { id = "settings", label = "Settings" },
    },
    buildPage = function(_, parent)
        if M.BuildSettingsPage then
            M.BuildSettingsPage(parent, M.GetDB())
        end
        return M.PAGE_HEIGHT
    end,
    onPageCacheRestore = function(pageName)
        if pageName == "settings" and M.SetPreview then
            M.SetPreview(true, M.GetDB())
        end
    end,
})
