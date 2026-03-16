local ADDON_NAME, ns = ...

local MedaUI = LibStub("MedaUI-2.0")
local Pixel = MedaUI.Pixel
local debugstack = debugstack
local format = format
local geterrorhandler = geterrorhandler
local pcall = pcall
local tostring = tostring

MedaAuras = {}
MedaAuras.ns = ns

ns.Services = {}

-- ============================================================================
-- Utilities
-- ============================================================================

local function DeepCopy(orig)
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for k, v in pairs(orig) do
        copy[DeepCopy(k)] = DeepCopy(v)
    end
    return copy
end

local function MergeDefaults(saved, defaults)
    if type(saved) ~= "table" then return DeepCopy(defaults) end
    for k, v in pairs(defaults) do
        if saved[k] == nil then
            saved[k] = DeepCopy(v)
        elseif type(v) == "table" and type(saved[k]) == "table" then
            MergeDefaults(saved[k], v)
        end
    end
    return saved
end

MedaAuras.DeepCopy = DeepCopy

local function SafeStr(value, fallback)
    local ok, str = pcall(tostring, value)
    if not ok or str == nil then
        return fallback or "<unprintable>"
    end

    local clean = pcall(function()
        return str == str
    end)
    if not clean then
        return fallback or "<secret>"
    end

    return str
end

local function SafeDebugStack(level)
    local ok, stack = pcall(debugstack, (level or 1) + 1)
    if ok and stack and stack ~= "" then
        return stack
    end
    return "<stack unavailable>"
end

local function BuildErrorMessage(err, stackLevel)
    return format("%s\n%s", SafeStr(err, "Unknown MedaAuras error"), SafeDebugStack((stackLevel or 1) + 1))
end

ns.SafeStr = SafeStr
MedaAuras.SafeStr = SafeStr

-- ============================================================================
-- Logging (routes to MedaDebug when available)
-- ============================================================================

local debugAPI
local debugEnabled = false

local function InitDebug()
    debugAPI = _G.MedaDebugAPI or _G.MedaDebug
    if debugAPI and debugAPI.RegisterAddon then
        debugAPI:RegisterAddon("MedaAuras", {
            color = { 0.4, 0.8, 1.0 },
            prefix = "[MedaAuras]",
        })
    end
end

local function Log(msg)
    if debugAPI then
        debugAPI:Print("MedaAuras", tostring(msg))
    end
end

local function LogDebug(msg)
    if debugEnabled and debugAPI then
        debugAPI:DebugMsg("MedaAuras", tostring(msg))
    end
end

local function LogWarn(msg)
    if debugAPI then
        debugAPI:Warn("MedaAuras", tostring(msg))
    end
end

local function LogError(msg)
    if debugAPI then
        debugAPI:Error("MedaAuras", tostring(msg))
    end
end

local function LogTable(tbl, name, maxDepth)
    if debugAPI then
        debugAPI:Table("MedaAuras", tbl, name, maxDepth or 3)
    end
end

MedaAuras.Log = Log
MedaAuras.LogDebug = LogDebug
MedaAuras.LogWarn = LogWarn
MedaAuras.LogError = LogError
MedaAuras.LogTable = LogTable

function MedaAuras:SetDebugMode(enabled)
    debugEnabled = not not enabled
end

function MedaAuras:IsDebugModeEnabled()
    return debugEnabled
end

-- ============================================================================
-- Error Isolation
-- ============================================================================

local function ForwardError(err)
    local safeErr = SafeStr(err, "Unknown MedaAuras error")
    LogError(safeErr)

    local handler = geterrorhandler()
    if handler then
        local ok, handlerErr = pcall(handler, safeErr)
        if not ok then
            LogError(format("[MedaAuras] Error handler failed: %s", SafeStr(handlerErr)))
        end
    end
end

local function SafeCall(moduleName, func, ...)
    local ok, err = xpcall(func, function(e)
        return format("[MedaAuras:%s] %s", moduleName, BuildErrorMessage(e, 2))
    end, ...)
    if not ok then
        ForwardError(err)
    end
    return ok
end

-- ============================================================================
-- Module Registry
-- ============================================================================

local modules = {}
local moduleOrder = {}

local STABILITY_COLORS = {
    experimental = { 1.0, 0.6, 0.0 },
    beta         = { 1.0, 0.85, 0.0 },
    stable       = { 0.3, 0.85, 0.3 },
}

MedaAuras.STABILITY_COLORS = STABILITY_COLORS

function MedaAuras:RegisterModule(config)
    if not config or not config.name then
        error("MedaAuras:RegisterModule requires a config table with a 'name' field")
    end
    if modules[config.name] then
        error(format("MedaAuras: Module '%s' is already registered", config.name))
    end

    config.defaults = config.defaults or {}
    if config.defaults.enabled == nil then
        config.defaults.enabled = false
    end

    modules[config.name] = config
    moduleOrder[#moduleOrder + 1] = config.name
    LogDebug(format("Module registered: %s", config.name))
end

function MedaAuras:GetModule(name)
    if self.IsCustomModuleKey and self:IsCustomModuleKey(name) and self.GetCustomModuleConfig then
        return self:GetCustomModuleConfig(name)
    end
    return modules[name]
end

function MedaAuras:GetRegisteredModuleNames()
    local names = {}
    for index, name in ipairs(moduleOrder) do
        names[index] = name
    end
    return names
end

function MedaAuras:GetModuleDB(name)
    if MedaAurasDB and MedaAurasDB.modules then
        if MedaAurasDB.modules[name] then
            return MedaAurasDB.modules[name]
        end
    end
    if self.GetCustomModuleDB then
        return self:GetCustomModuleDB(name)
    end
end

function MedaAuras:IsModuleEnabled(name)
    local db = self:GetModuleDB(name)
    return db and db.enabled
end

function MedaAuras:EnableModule(name)
    if self.IsCustomModuleKey and self:IsCustomModuleKey(name) then
        return self:EnableCustomModule(name)
    end
    local config = modules[name]
    if not config then
        LogWarn(format("EnableModule: unknown module '%s'", tostring(name)))
        return false
    end
    local db = self:GetModuleDB(name)
    if not db then
        LogWarn(format("EnableModule: no DB for module '%s'", name))
        return false
    end

    if db.enabled then
        LogDebug(format("EnableModule: '%s' already enabled", name))
        return true
    end
    db.enabled = true
    Log(format("Enabling module: %s", name))

    if config.OnEnable then
        SafeCall(name, config.OnEnable, db)
    else
        LogDebug(format("EnableModule: '%s' has no OnEnable handler", name))
    end
    return true
end

function MedaAuras:DisableModule(name)
    if self.IsCustomModuleKey and self:IsCustomModuleKey(name) then
        return self:DisableCustomModule(name)
    end
    local config = modules[name]
    if not config then
        LogWarn(format("DisableModule: unknown module '%s'", tostring(name)))
        return false
    end
    local db = self:GetModuleDB(name)
    if not db then
        LogWarn(format("DisableModule: no DB for module '%s'", name))
        return false
    end

    if not db.enabled then
        LogDebug(format("DisableModule: '%s' already disabled", name))
        return true
    end
    db.enabled = false
    Log(format("Disabling module: %s", name))

    if config.OnDisable then
        SafeCall(name, config.OnDisable, db)
    end
    return true
end

-- ============================================================================
-- Default DB
-- ============================================================================

local DEFAULT_DB = {
    options = {
        theme = nil,
        debugMode = false,
        muteSounds = false,
    },
    modules = {},
    customModules = {},
}

function MedaAuras:GetDB()
    return MedaAurasDB
end

function MedaAuras:GetOptionsDB()
    return MedaAurasDB and MedaAurasDB.options
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

local function SlashHandler(msg)
    msg = (msg or ""):lower():trim()

    if msg == "" or msg == "config" or msg == "options" then
        MedaAuras:ToggleSettings()
        return
    end

    if msg == "debug" then
        debugEnabled = not debugEnabled
        if MedaAurasDB then
            MedaAurasDB.options.debugMode = debugEnabled
        end
        print(format("|cff00ccffMedaAuras:|r Debug mode %s.", debugEnabled and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
        Log(format("Debug mode toggled %s", debugEnabled and "ON" or "OFF"))
        return
    end

    if msg == "import" and MedaAuras.ShowImportCustomModuleDialog then
        MedaAuras:ShowImportCustomModuleDialog()
        return
    end

    if msg == "lock" then
        for _, modName in ipairs(moduleOrder) do
            local db = MedaAuras:GetModuleDB(modName)
            if db then db.locked = true end
        end
        print("|cff00ccffMedaAuras:|r All frames locked.")
        return
    end

    if msg == "unlock" then
        for _, modName in ipairs(moduleOrder) do
            local db = MedaAuras:GetModuleDB(modName)
            if db then db.locked = false end
        end
        print("|cff00ccffMedaAuras:|r All frames unlocked.")
        return
    end

    local cmd, rest = msg:match("^(%S+)%s*(.*)$")

    if cmd == "enable" and rest ~= "" then
        for _, modName in ipairs(moduleOrder) do
            if modName:lower() == rest then
                MedaAuras:EnableModule(modName)
                MedaAuras:RefreshSidebarDot(modName)
                print(format("|cff00ccffMedaAuras:|r Enabled %s.", modName))
                return
            end
        end
        print(format("|cff00ccffMedaAuras:|r Unknown module: %s", rest))
        return
    end

    if cmd == "disable" and rest ~= "" then
        for _, modName in ipairs(moduleOrder) do
            if modName:lower() == rest then
                MedaAuras:DisableModule(modName)
                MedaAuras:RefreshSidebarDot(modName)
                print(format("|cff00ccffMedaAuras:|r Disabled %s.", modName))
                return
            end
        end
        print(format("|cff00ccffMedaAuras:|r Unknown module: %s", rest))
        return
    end

    -- Route to module slash handler
    if cmd then
        for _, modName in ipairs(moduleOrder) do
            local config = modules[modName]
            if modName:lower() == cmd and config.slashCommands then
                local subCmd, subRest = (rest or ""):match("^(%S+)%s*(.*)$")
                subCmd = subCmd or rest
                if config.slashCommands[subCmd] then
                    local db = MedaAuras:GetModuleDB(modName)
                    SafeCall(modName, config.slashCommands[subCmd], db, subRest)
                    return
                end
            end
        end
    end

    print("|cff00ccffMedaAuras:|r Commands:")
    print("  /mwa - Open settings")
    print("  /mwa debug - Toggle verbose debug logging")
    print("  /mwa import - Import or create a custom module")
    print("  /mwa lock - Lock all frames")
    print("  /mwa unlock - Unlock all frames")
    print("  /mwa enable <module> - Enable a module")
    print("  /mwa disable <module> - Disable a module")
end

SLASH_MEDAAURAS1 = "/mwa"
SLASH_MEDAAURAS2 = "/mauras"
SlashCmdList["MEDAAURAS"] = SlashHandler

-- ============================================================================
-- Initialization
-- ============================================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitDebug()

        MedaAurasDB = MergeDefaults(MedaAurasDB or {}, DEFAULT_DB)

        MedaAurasCharDB = MedaAurasCharDB or {}
        MedaAurasCharDB.prophecy = MedaAurasCharDB.prophecy or {
            recordings = {},
            _checkpoint = nil,
        }

        -- Migrate SavedVariables: TalentReminder -> Reminders
        if MedaAurasDB.modules and MedaAurasDB.modules.TalentReminder and not MedaAurasDB.modules.Reminders then
            MedaAurasDB.modules.Reminders = MedaAurasDB.modules.TalentReminder
            MedaAurasDB.modules.TalentReminder = nil
        end

        debugEnabled = MedaAurasDB.options.debugMode or false

        Log("ADDON_LOADED: DB initialized")

        for _, modName in ipairs(moduleOrder) do
            local config = modules[modName]
            MedaAurasDB.modules[modName] = MergeDefaults(
                MedaAurasDB.modules[modName] or {},
                config.defaults
            )
            LogDebug(format("DB merged defaults for module: %s (enabled=%s)",
                modName, tostring(MedaAurasDB.modules[modName].enabled)))
        end

        if MedaAuras.InitCustomModules then
            MedaAuras:InitCustomModules()
        end

        local uiTheme = MedaAurasDB.options.theme or "onyx"
        if MedaUI and MedaUI.SetTheme then
            MedaUI:SetTheme(uiTheme)
            LogDebug(format("Applied UI theme: %s", uiTheme))
        end

        if MedaAurasDB.options.muteSounds then
            MedaUI:SetSoundsEnabled(false)
        end

    elseif event == "PLAYER_LOGIN" then
        -- Retry debug API discovery in case MedaDebug loaded after us
        if not debugAPI then
            InitDebug()
        end

        Log("PLAYER_LOGIN: Initializing services and modules")

        for serviceName, service in pairs(ns.Services) do
            if service.Initialize then
                LogDebug(format("Initializing service: %s", serviceName))
                local ok, err = xpcall(service.Initialize, function(e)
                    return format("[MedaAuras:Service:%s] %s", serviceName, BuildErrorMessage(e, 2))
                end, service)
                if not ok then
                    ForwardError(err)
                else
                    LogDebug(format("Service initialized: %s", serviceName))
                end
            end
        end

        for _, modName in ipairs(moduleOrder) do
            local config = modules[modName]
            local db = MedaAurasDB.modules[modName]
            if db and db.enabled then
                Log(format("Auto-initializing enabled module: %s", modName))
                if config.OnInitialize then
                    SafeCall(modName, config.OnInitialize, db)
                else
                    LogWarn(format("Module '%s' enabled but has no OnInitialize", modName))
                end
            else
                LogDebug(format("Skipping disabled module: %s", modName))
            end
        end

        if MedaAuras.LoadCustomModules then
            MedaAuras:LoadCustomModules()
        end

        Log(format("Startup complete. %d module(s) registered.", #moduleOrder))

        if debugAPI then
            Log("MedaDebug integration active")
        else
            print("|cff00ccffMedaAuras:|r MedaDebug not detected. Use /mwa debug for chat fallback.")
        end
    end
end)
