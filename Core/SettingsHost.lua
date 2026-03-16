local ADDON_NAME, ns = ...

local MedaUI = LibStub("MedaUI-2.0")

local format = format
local tinsert = table.insert
local SIDEBAR_WIDTH = 304
local PANEL_WIDTH = 1180
local PANEL_HEIGHT = 840

local STABILITY_LEGEND = {
    { label = "Stable",       color = MedaAuras.STABILITY_COLORS.stable },
    { label = "Beta",         color = MedaAuras.STABILITY_COLORS.beta },
    { label = "Experimental", color = MedaAuras.STABILITY_COLORS.experimental },
}

local settingsHost
local selectedModuleId = "General"
local selectedPageId

local function SafeInvoke(label, func, ...)
    if type(func) ~= "function" then
        return true
    end

    local ok, err = xpcall(func, function(message)
        return format("[MedaAuras:%s] %s\n%s", label, tostring(message), debugstack(2, 12, 12))
    end, ...)
    if not ok and MedaAuras.LogError then
        MedaAuras.LogError(err)
    end
    return ok
end

local function ResetModuleDefaults(moduleId, moduleConfig)
    if not moduleConfig or not moduleConfig.defaults then
        return
    end

    local db = MedaAuras:GetModuleDB(moduleId)
    if not db then
        return
    end

    if moduleConfig.OnResetDefaults then
        SafeInvoke(moduleId .. ":OnResetDefaults", moduleConfig.OnResetDefaults, db)
    end

    for key, value in pairs(moduleConfig.defaults) do
        db[key] = MedaAuras.DeepCopy(value)
    end
end

local function BuildGeneralPage(parent)
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
    debugCheck:SetChecked(MedaAuras.IsDebugModeEnabled and MedaAuras:IsDebugModeEnabled() or false)
    debugCheck.OnValueChanged = function(_, checked)
        if MedaAuras.SetDebugMode then
            MedaAuras:SetDebugMode(checked)
        end
        if MedaAurasDB then
            MedaAurasDB.options.debugMode = checked
        end
        if MedaAuras.Log then
            MedaAuras.Log(format("Debug mode toggled %s", checked and "ON" or "OFF"))
        end
    end
    yOff = yOff - 40

    local muteSoundsCheck = MedaUI:CreateCheckbox(parent, "Mute All Sounds")
    muteSoundsCheck:SetPoint("TOPLEFT", 0, yOff)
    muteSoundsCheck:SetChecked(MedaAurasDB and MedaAurasDB.options and MedaAurasDB.options.muteSounds)
    muteSoundsCheck.OnValueChanged = function(_, checked)
        if MedaAurasDB then
            MedaAurasDB.options.muteSounds = checked
        end
        MedaUI:SetSoundsEnabled(not checked)
    end
    yOff = yOff - 40

    local LDBIcon = LibStub("LibDBIcon-1.0", true)
    local moduleNames = MedaAuras:GetRegisteredModuleNames()
    local hasMinimapModules = false
    for _, moduleName in ipairs(moduleNames) do
        local moduleConfig = MedaAuras:GetModule(moduleName)
        if moduleConfig and moduleConfig.defaults and moduleConfig.defaults.showMinimapButton ~= nil then
            hasMinimapModules = true
            break
        end
    end

    if hasMinimapModules then
        local minimapHeader = MedaUI:CreateSectionHeader(parent, "Minimap Buttons", 470)
        minimapHeader:SetPoint("TOPLEFT", 0, yOff)
        yOff = yOff - 40

        for _, moduleName in ipairs(moduleNames) do
            local moduleConfig = MedaAuras:GetModule(moduleName)
            if moduleConfig and moduleConfig.defaults and moduleConfig.defaults.showMinimapButton ~= nil then
                local moduleDB = MedaAuras:GetModuleDB(moduleName)
                local ldbName = "MedaAuras" .. moduleName
                local checkbox = MedaUI:CreateCheckbox(parent, moduleConfig.title or moduleName)
                checkbox:SetPoint("TOPLEFT", 0, yOff)
                checkbox:SetChecked(moduleDB and moduleDB.showMinimapButton ~= false)
                checkbox.OnValueChanged = function(_, checked)
                    if moduleDB then
                        moduleDB.showMinimapButton = checked
                    end
                    if LDBIcon and LDBIcon:IsRegistered(ldbName) then
                        if checked then
                            LDBIcon:Show(ldbName)
                        else
                            LDBIcon:Hide(ldbName)
                        end
                    end
                end
                yOff = yOff - 26
            end
        end
        yOff = yOff - 10
    end

    return math.abs(yOff)
end

local function BuildImportPage(parent)
    local yOff = 0
    local description = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    description:SetPoint("TOPLEFT", 0, yOff)
    description:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
    description:SetJustifyH("LEFT")
    description:SetWordWrap(true)
    description:SetText("Import a custom module package into MedaAuras. Imported modules remain embedded in MedaAuras and use the same embedded MedaUI host as built-in modules.")
    description:SetTextColor(unpack(MedaUI.Theme.text))
    yOff = yOff - description:GetStringHeight() - 20

    local importButton = MedaUI:CreateButton(parent, "Open Import Dialog", 180)
    importButton:SetPoint("TOPLEFT", 0, yOff)
    importButton:SetScript("OnClick", function()
        if MedaAuras.ShowImportCustomModuleDialog then
            MedaAuras:ShowImportCustomModuleDialog()
        end
    end)
    yOff = yOff - 46

    local note = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    note:SetPoint("TOPLEFT", 0, yOff)
    note:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
    note:SetJustifyH("LEFT")
    note:SetWordWrap(true)
    note:SetText("Imported modules appear under Custom Modules in the sidebar after a successful import.")
    note:SetTextColor(unpack(MedaUI.Theme.textDim or { 0.6, 0.6, 0.6, 1 }))
    yOff = yOff - note:GetStringHeight() - 12

    return math.abs(yOff)
end

local function BuildRuntimeModuleDefinition(moduleName)
    local moduleConfig = MedaAuras:GetModule(moduleName)
    if not moduleConfig then
        return nil
    end

    if not moduleConfig.pages or not moduleConfig.buildPage then
        error(format("MedaAuras module '%s' must define pages + buildPage for the settings host", moduleName))
    end

    return {
        title = moduleConfig.title or moduleName,
        description = moduleConfig.description,
        version = moduleConfig.version,
        author = moduleConfig.author,
        stability = moduleConfig.stability,
        sidebarGroup = "Modules",
        sidebarOrder = 1000,
        entryType = "module",
        stabilityColors = MedaAuras.STABILITY_COLORS,
        pages = moduleConfig.pages,
        pageHeights = moduleConfig.pageHeights,
        defaultPageHeight = moduleConfig.defaultPageHeight or 800,
        slashCommands = moduleConfig.slashCommands,
        slashPrefix = "/mwa " .. moduleName:lower(),
        getEnabled = function()
            local db = MedaAuras:GetModuleDB(moduleName)
            return db and db.enabled
        end,
        setEnabled = function(enabled)
            if enabled then
                MedaAuras:EnableModule(moduleName)
            else
                MedaAuras:DisableModule(moduleName)
            end
        end,
        onReset = function(pageName)
            if moduleConfig.onReset then
                moduleConfig.onReset(pageName)
                return
            end
            ResetModuleDefaults(moduleName, moduleConfig)
        end,
        onPageCacheRestore = moduleConfig.onPageCacheRestore,
        getHeaderBuilder = moduleConfig.getHeaderBuilder,
        buildPage = function(pageName, parent, yOffset, host)
            return moduleConfig.buildPage(pageName, parent, yOffset, host)
        end,
    }
end

local function BuildCustomModuleDefinition(entry)
    local moduleConfig = MedaAuras:GetCustomModuleConfig(entry.key)
    if not moduleConfig then
        return nil
    end

    return {
        title = moduleConfig.title or entry.moduleId,
        description = moduleConfig.sidebarDesc,
        version = moduleConfig.version,
        stability = moduleConfig.stability,
        sidebarGroup = "Custom Modules",
        sidebarOrder = 2000,
        entryType = "module",
        stabilityColors = MedaAuras.STABILITY_COLORS,
        tag = moduleConfig.customTag,
        tagColor = moduleConfig.customColor,
        pages = { { id = "settings", label = "Settings" } },
        defaultPageHeight = 800,
        getEnabled = function()
            local db = MedaAuras:GetModuleDB(entry.key)
            return db and db.enabled
        end,
        setEnabled = function(enabled)
            if enabled then
                MedaAuras:EnableModule(entry.key)
            else
                MedaAuras:DisableModule(entry.key)
            end
        end,
        buildPage = function(_, parent)
            if MedaAuras.BuildCustomModuleConfig then
                MedaAuras:BuildCustomModuleConfig(parent, entry.key)
            end
            return 800
        end,
    }
end

local function RegisterOptionsModules()
    settingsHost:ClearModules()

    settingsHost:RegisterModule("General", {
        title = "Settings",
        description = "Global MedaAuras options, UI theme, debug logging, and embedded addon controls.",
        sidebarGroup = "General",
        sidebarOrder = 10,
        entryType = "nav",
        pages = { { id = "settings", label = "Settings", title = "General Settings" } },
        defaultPageHeight = 320,
        buildPage = function(_, parent)
            return BuildGeneralPage(parent)
        end,
        getHeaderBuilder = function()
            return function()
                return 0
            end
        end,
    })

    settingsHost:RegisterModule("Import", {
        title = "Import",
        description = "Import standalone custom module packages into MedaAuras without introducing a shared UI dependency addon.",
        sidebarGroup = "General",
        sidebarOrder = 20,
        entryType = "nav",
        pages = { { id = "settings", label = "Import", title = "Import Custom Module" } },
        defaultPageHeight = 220,
        buildPage = function(_, parent)
            return BuildImportPage(parent)
        end,
    })

    for _, moduleName in ipairs(MedaAuras:GetRegisteredModuleNames()) do
        local definition = BuildRuntimeModuleDefinition(moduleName)
        if definition then
            settingsHost:RegisterModule(moduleName, definition)
        end
    end

    if MedaAuras.GetCustomModuleEntries then
        for _, entry in ipairs(MedaAuras:GetCustomModuleEntries()) do
            local definition = BuildCustomModuleDefinition(entry)
            if definition then
                settingsHost:RegisterModule(entry.key, definition)
            end
        end
    end

    settingsHost:RebuildSidebar()
end

local function BuildSettingsHost()
    if settingsHost then
        RegisterOptionsModules()
        return settingsHost
    end

    settingsHost = MedaUI:CreateOptionsHost({
        name = "MedaAurasSettingsPanel",
        width = PANEL_WIDTH,
        height = PANEL_HEIGHT,
        sidebarWidth = SIDEBAR_WIDTH,
        title = "MedaAuras",
        subtitle = "C O N F I G U R A T I O N",
        minWidth = SIDEBAR_WIDTH + 300,
        minHeight = 400,
        watermarkTexture = MedaUI.mediaPath .. "Textures\\meda-logo.tga",
        groupOrder = { "General", "Modules", "Custom Modules" },
        legend = STABILITY_LEGEND,
        stabilityColors = MedaAuras.STABILITY_COLORS,
    })

    tinsert(UISpecialFrames, "MedaAurasSettingsPanel")

    settingsHost:SetFooterButtons({
        {
            text = "Reset to Defaults",
            width = 164,
            align = "left",
            onClick = function()
                local moduleId = settingsHost.activeModuleId
                local moduleDefinition = moduleId and settingsHost.modules[moduleId]
                if not moduleDefinition or not moduleDefinition.onReset then
                    return
                end

                moduleDefinition.onReset(settingsHost.activePageId, settingsHost)
                settingsHost:InvalidatePage(moduleId)
                settingsHost:SelectModule(moduleId, settingsHost.activePageId)

                if MedaAuras.Log then
                    MedaAuras.Log(format("Reset defaults for module: %s", moduleId))
                end
            end,
        },
        {
            text = "Close",
            width = 108,
            align = "right",
            onClick = function()
                settingsHost:Hide()
            end,
        },
    })

    settingsHost.OnSelectionChanged = function(moduleId, pageId)
        selectedModuleId = moduleId or selectedModuleId
        selectedPageId = pageId
    end

    RegisterOptionsModules()
    settingsHost:SelectModule(selectedModuleId or "General", selectedPageId)

    return settingsHost
end

function MedaAuras:ToggleSettings()
    local host = BuildSettingsHost()
    host:Toggle()
    if host:IsShown() then
        host:SelectModule(selectedModuleId or host.activeModuleId or "General", selectedPageId)
    end
end

function MedaAuras:RebuildSettingsSidebar()
    if not settingsHost then
        return
    end

    local activeModuleId = settingsHost.activeModuleId or selectedModuleId
    local activePageId = settingsHost.activePageId or selectedPageId

    RegisterOptionsModules()

    if activeModuleId and settingsHost.modules[activeModuleId] then
        settingsHost:SelectModule(activeModuleId, activePageId)
    else
        settingsHost:SelectModule("General")
    end
end

function MedaAuras:SetContentHeight(height)
    if settingsHost then
        settingsHost:SetActivePageHeight(height)
    end
end

function MedaAuras:RegisterConfigCleanup(frame)
    if settingsHost then
        settingsHost:RegisterConfigCleanup(frame)
    end
end

function MedaAuras:CreateConfigTabs(parent, tabs)
    if settingsHost then
        return settingsHost:CreateConfigTabs(parent, tabs)
    end
    return MedaUI:CreateTabBar(parent, tabs), {}
end

function MedaAuras:RefreshModuleConfig()
    if settingsHost and settingsHost:IsShown() then
        settingsHost:RefreshActivePage(true)
    end
end

function MedaAuras:RefreshSidebarDot(moduleId)
    if settingsHost then
        settingsHost:RefreshModuleToggle(moduleId)
    end
end
