local _, NS = ...
local API = NS.API

local MODULE_KEY = "BuffTracker"

local addon = NS.Lite.NewAddon("MedaAuras" .. MODULE_KEY)
local defaults = {
    enabled = true,
}

NS.ModuleDefaults = NS.ModuleDefaults or {}
NS.ModuleDefaults[MODULE_KEY] = defaults

function addon:OnInitialize()
    self.db = API:GetModuleDB(MODULE_KEY, defaults)
end

function addon:OnEnable()
    if not self.db.enabled then
        return
    end

    API:Print("Tracked Buff Icon module enabled.")
end

