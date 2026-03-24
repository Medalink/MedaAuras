local _, ns = ...

ns.SoulstoneReminder = ns.SoulstoneReminder or {}

local M = ns.SoulstoneReminder

M.MODULE_NAME = "SoulstoneReminder"
M.MODULE_VERSION = "1.0"
M.MODULE_STABILITY = "experimental"
M.DEFAULT_TEXT = "Soulstone a healer"
M.DEFAULT_FONT = GameFontNormalLarge and select(1, GameFontNormalLarge:GetFont()) or "Fonts\\FRIZQT__.TTF"
M.GOOD_COLOR = { 0.30, 0.85, 0.30 }
M.WARN_COLOR = { 1.00, 0.82, 0.20 }
M.INFO_COLOR = { 0.72, 0.76, 0.84 }
M.PAGE_HEIGHT = 430

M.DEFAULTS = {
    enabled = false,
    locked = false,
    showHealerName = true,
    text = M.DEFAULT_TEXT,
    textSize = 32,
    font = "default",
    color = { 0.56, 0.96, 0.45, 1.0 },
    position = { point = "CENTER", x = 0, y = 240 },
}

function M.GetDB()
    return MedaAuras:GetModuleDB(M.MODULE_NAME)
end

MedaAuras:RegisterModule({
    name = M.MODULE_NAME,
    title = "Soulstone Reminder",
    version = M.MODULE_VERSION,
    stability = M.MODULE_STABILITY,
    author = "Medalink",
    description = "Warns Warlocks in party or raid instances when no healer currently has Soulstone while the group is out of combat.",
    sidebarDesc = "Out-of-combat Soulstone reminder for healer targets.",
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
