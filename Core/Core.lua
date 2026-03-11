local ADDON_NAME, ns = ...

local MedaUI = LibStub("MedaUI-1.0")
local Pixel = MedaUI.Pixel

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

-- ============================================================================
-- Error Isolation
-- ============================================================================

local function SafeCall(moduleName, func, ...)
    local ok, err = xpcall(func, function(e)
        return format("[MedaAuras:%s] %s\n%s", moduleName, e, debugstack(2))
    end, ...)
    if not ok then
        LogError(err)
        geterrorhandler()(err)
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
-- Settings Panel
-- ============================================================================

local settingsPanel
local selectedModule = nil

local SIDEBAR_WIDTH = 304
local PANEL_WIDTH = 1180
local PANEL_HEIGHT = 840

local function BuildGeneralConfig(parent)
    local yOff = 0

    local headerContainer = MedaUI:CreateSectionHeader(parent, "General Settings", 470)
    headerContainer:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 40

    local themeLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    themeLabel:SetPoint("TOPLEFT", 0, yOff)
    themeLabel:SetText("UI Theme")
    themeLabel:SetTextColor(unpack(MedaUI.Theme.text))
    yOff = yOff - 20

    local themeSelector = MedaUI:CreateThemeSelector(parent, 200, {
        onChange = function(value)
            if MedaAurasDB then
                MedaAurasDB.options.theme = value
            end
        end,
    })
    themeSelector:SetPoint("TOPLEFT", 0, yOff)
    local currentTheme = MedaAurasDB and MedaAurasDB.options.theme
    if currentTheme then
        themeSelector:SetSelected(currentTheme)
    end
    yOff = yOff - 40

    local debugCheck = MedaUI:CreateCheckbox(parent, "Enable Debug Mode")
    debugCheck:SetPoint("TOPLEFT", 0, yOff)
    debugCheck:SetChecked(debugEnabled)
    debugCheck.OnValueChanged = function(_, checked)
        debugEnabled = checked
        if MedaAurasDB then
            MedaAurasDB.options.debugMode = checked
        end
        Log(format("Debug mode toggled %s", checked and "ON" or "OFF"))
    end
    yOff = yOff - 40

    local muteSoundsCheck = MedaUI:CreateCheckbox(parent, "Mute All Sounds")
    muteSoundsCheck:SetPoint("TOPLEFT", 0, yOff)
    muteSoundsCheck:SetChecked(MedaAurasDB and MedaAurasDB.options.muteSounds)
    muteSoundsCheck.OnValueChanged = function(_, checked)
        if MedaAurasDB then
            MedaAurasDB.options.muteSounds = checked
        end
        MedaUI:SetSoundsEnabled(not checked)
    end
    yOff = yOff - 40

    local LDBIcon = LibStub("LibDBIcon-1.0", true)
    local hasMinimapModules = false
    for _, modName in ipairs(moduleOrder) do
        local config = modules[modName]
        if config and config.defaults and config.defaults.showMinimapButton ~= nil then
            hasMinimapModules = true
            break
        end
    end

    if hasMinimapModules then
        local mmHeader = MedaUI:CreateSectionHeader(parent, "Minimap Buttons", 470)
        mmHeader:SetPoint("TOPLEFT", 0, yOff)
        yOff = yOff - 40

        for _, modName in ipairs(moduleOrder) do
            local config = modules[modName]
            if config and config.defaults and config.defaults.showMinimapButton ~= nil then
                local modDB = MedaAuras:GetModuleDB(modName)
                local ldbName = "MedaAuras" .. modName
                local cb = MedaUI:CreateCheckbox(parent, config.title or modName)
                cb:SetPoint("TOPLEFT", 0, yOff)
                cb:SetChecked(modDB and modDB.showMinimapButton ~= false)
                cb.OnValueChanged = function(_, checked)
                    if modDB then
                        modDB.showMinimapButton = checked
                    end
                    if LDBIcon and LDBIcon:IsRegistered(ldbName) then
                        if checked then LDBIcon:Show(ldbName) else LDBIcon:Hide(ldbName) end
                    end
                end
                yOff = yOff - 26
            end
        end
        yOff = yOff - 10
    end

    if settingsPanel then
        settingsPanel:SetContentHeight(math.abs(yOff))
    end
end

local STABILITY_LEGEND = {
    { label = "Stable",       color = STABILITY_COLORS.stable },
    { label = "Beta",         color = STABILITY_COLORS.beta },
    { label = "Experimental", color = STABILITY_COLORS.experimental },
}

local function RebuildSidebar()
    settingsPanel:BeginSidebar()

    -- General section
    settingsPanel:AddSection("General")
    settingsPanel:AddNavRow("General", "Settings")
    settingsPanel:AddNavRow("Import", "Import")

    -- Modules section
    settingsPanel:AddSection("Modules")
    table.sort(moduleOrder)
    for _, modName in ipairs(moduleOrder) do
        local config = modules[modName]
        local db = MedaAuras:GetModuleDB(modName)
        settingsPanel:AddModuleRow(modName, config.title or modName, {
            enabled = db and db.enabled or false,
            getEnabled = function() local d = MedaAuras:GetModuleDB(modName); return d and d.enabled end,
            stability = config.stability,
            stabilityColors = STABILITY_COLORS,
            version = config.version,
            author = config.author,
            customTag = config.customTag,
            customColor = config.customColor,
            slashCommands = config.slashCommands,
            slashPrefix = "/mwa " .. modName:lower(),
            onToggle = function(key, enabled)
                if enabled then
                    MedaAuras:EnableModule(key)
                else
                    MedaAuras:DisableModule(key)
                end
                MedaAuras:RefreshSidebarDot(key)
            end,
        })
    end

    -- Custom Modules section
    if MedaAuras.GetCustomModuleEntries then
        local customEntries = MedaAuras:GetCustomModuleEntries()
        settingsPanel:AddSection("Custom Modules")

        for _, entry in ipairs(customEntries) do
            local config = MedaAuras:GetCustomModuleConfig(entry.key)
            if config then
                local db = MedaAuras:GetModuleDB(entry.key)
                settingsPanel:AddModuleRow(entry.key, config.title or entry.moduleId, {
                    enabled = db and db.enabled or false,
                    getEnabled = function() local d = MedaAuras:GetModuleDB(entry.key); return d and d.enabled end,
                    stability = config.stability,
                    stabilityColors = STABILITY_COLORS,
                    version = config.version,
                    customTag = config.customTag,
                    customColor = config.customColor,
                    onToggle = function(key, enabled)
                        if enabled then
                            MedaAuras:EnableModule(key)
                        else
                            MedaAuras:DisableModule(key)
                        end
                        MedaAuras:RefreshSidebarDot(key)
                    end,
                })
            end
        end
    end

    settingsPanel:EndSidebar()
end

local function BuildSettingsPanel()
    if settingsPanel then
        RebuildSidebar()
        return settingsPanel
    end

    settingsPanel = MedaUI:CreateSettingsPanel("MedaAurasSettingsPanel", {
        width = PANEL_WIDTH,
        height = PANEL_HEIGHT,
        sidebarWidth = SIDEBAR_WIDTH,
        title = "MedaAuras",
        subtitle = "C O N F I G U R A T I O N",
        minWidth = SIDEBAR_WIDTH + 300,
        minHeight = 400,
        watermarkTexture = MedaUI.mediaPath .. "Textures\\meda-logo.tga",
    })
    tinsert(UISpecialFrames, "MedaAurasSettingsPanel")

    -- Register content builders for special pages
    settingsPanel:SetContentBuilder("General", function(contentFrame)
        BuildGeneralConfig(contentFrame)
    end)

    settingsPanel:SetContentBuilder("Import", function()
        if MedaAuras.ShowImportCustomModuleDialog then
            MedaAuras:ShowImportCustomModuleDialog()
        end
    end)

    settingsPanel:SetOnItemSelected(function(key)
        selectedModule = key

        if key == "General" or key == "Import" then return end

        local contentFrame = settingsPanel:GetContentFrame()

        if MedaAuras.IsCustomModuleKey and MedaAuras:IsCustomModuleKey(key) then
            if MedaAuras.BuildCustomModuleConfig then
                MedaAuras:BuildCustomModuleConfig(contentFrame, key)
            end
            settingsPanel:SetContentHeight(800)
            return
        end

        local config = modules[key]
        if not config then return end
        local db = MedaAuras:GetModuleDB(key)
        if not db then return end

        local headerHeight = settingsPanel:BuildConfigHeader(contentFrame, {
            title = config.title or config.name or key,
            stability = config.stability,
            stabilityColors = STABILITY_COLORS,
            version = config.version,
            author = config.author,
            description = config.description,
        })

        local moduleFrame = CreateFrame("Frame", nil, contentFrame)
        moduleFrame:SetPoint("TOPLEFT", 0, -headerHeight)
        moduleFrame:SetPoint("RIGHT", 0, 0)
        moduleFrame:SetHeight(5000)

        if config.BuildConfig then
            SafeCall(key, config.BuildConfig, moduleFrame, db)
        end

        settingsPanel:SetContentHeight(800)
    end)

    -- Footer buttons
    settingsPanel:SetFooterButtons({
        {
            text = "Reset to Defaults",
            width = 164,
            align = "left",
            onClick = function()
                if selectedModule and selectedModule ~= "General" and selectedModule ~= "Editor" and selectedModule ~= "Import" then
                    local config = modules[selectedModule]
                    if config and config.defaults then
                        local db = MedaAuras:GetModuleDB(selectedModule)
                        if db then
                            if config.OnResetDefaults then
                                config.OnResetDefaults(db)
                            end
                            for k, v in pairs(config.defaults) do
                                db[k] = DeepCopy(v)
                            end
                            settingsPanel:SelectItem(selectedModule)
                            Log(format("Reset defaults for module: %s", selectedModule))
                        end
                    end
                end
            end,
        },
        {
            text = "Close",
            width = 108,
            align = "right",
            onClick = function()
                settingsPanel:Hide()
            end,
        },
    })

    -- Legend
    settingsPanel:SetLegend(STABILITY_LEGEND)

    -- Build sidebar and select General
    RebuildSidebar()
    settingsPanel:SelectItem("General")

    return settingsPanel
end

function MedaAuras:ToggleSettings()
    local panel = BuildSettingsPanel()
    panel:Toggle()
    if panel:IsShown() then
        panel:SelectItem(selectedModule or "General")
    end
end

function MedaAuras:RebuildSettingsSidebar()
    if settingsPanel then
        RebuildSidebar()
    end
end

function MedaAuras:SetContentHeight(height)
    if settingsPanel then
        settingsPanel:SetContentHeight(height)
    end
end

function MedaAuras:RegisterConfigCleanup(frame)
    if settingsPanel then
        settingsPanel:RegisterConfigCleanup(frame)
    end
end

function MedaAuras:CreateConfigTabs(parent, tabs)
    if settingsPanel then
        return settingsPanel:CreateConfigTabs(parent, tabs)
    end
    return MedaUI:CreateTabBar(parent, tabs), {}
end

function MedaAuras:RefreshModuleConfig()
    if selectedModule and settingsPanel and settingsPanel:IsShown() then
        settingsPanel:SelectItem(selectedModule)
    end
end

function MedaAuras:RefreshSidebarDot(modName)
    if settingsPanel then
        settingsPanel:RefreshModuleToggle(modName)
    end
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
                    return format("[MedaAuras:Service:%s] %s\n%s", serviceName, e, debugstack(2))
                end, service)
                if not ok then
                    LogError(err)
                    geterrorhandler()(err)
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
