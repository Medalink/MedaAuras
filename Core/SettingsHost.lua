local ADDON_NAME, ns = ...

local MedaUI = LibStub("MedaUI-2.0")

local AddOnProfilerMetric = _G.Enum and _G.Enum.AddOnProfilerMetric or nil
local format = format
local mathAbs = math.abs
local tconcat = table.concat
local tinsert = table.insert
local SIDEBAR_WIDTH = 304
local PANEL_WIDTH = 1180
local PANEL_HEIGHT = 840
local DIAGNOSTICS_REFRESH_SECONDS = 5
local DIAGNOSTICS_PAGE_HEIGHT = 620

local STABILITY_LEGEND = {
    { label = "Stable",       color = MedaAuras.STABILITY_COLORS.stable },
    { label = "Beta",         color = MedaAuras.STABILITY_COLORS.beta },
    { label = "Experimental", color = MedaAuras.STABILITY_COLORS.experimental },
}

local settingsHost
local selectedModuleId = "General"
local selectedPageId
local diagnosticsState = {
    page = nil,
    baseYOffset = 0,
    rows = nil,
    ticker = nil,
}

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

local function StopDiagnosticsTicker()
    if diagnosticsState.ticker then
        diagnosticsState.ticker:Cancel()
        diagnosticsState.ticker = nil
    end
end

local function GetDiagnosticsRoster()
    local roster = { "MedaAuras" }
    if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("MedaUI") then
        roster[#roster + 1] = "MedaUI"
    end
    return roster
end

local function CountModuleStates()
    local builtInEnabled, builtInTotal = 0, 0
    for _, moduleName in ipairs(MedaAuras:GetRegisteredModuleNames()) do
        builtInTotal = builtInTotal + 1
        local db = MedaAuras:GetModuleDB(moduleName)
        if db and db.enabled then
            builtInEnabled = builtInEnabled + 1
        end
    end

    local customEnabled, customTotal = 0, 0
    if MedaAuras.GetCustomModuleEntries then
        for _, entry in ipairs(MedaAuras:GetCustomModuleEntries()) do
            customTotal = customTotal + 1
            local db = MedaAuras:GetModuleDB(entry.key)
            if db and db.enabled then
                customEnabled = customEnabled + 1
            end
        end
    end

    return builtInEnabled + customEnabled,
        builtInTotal + customTotal,
        builtInEnabled,
        builtInTotal,
        customEnabled,
        customTotal
end

local function LayoutDiagnosticsRows()
    if not diagnosticsState.rows then
        return DIAGNOSTICS_PAGE_HEIGHT
    end

    local yOff = diagnosticsState.baseYOffset or 0
    for i = 1, #diagnosticsState.rows do
        local row = diagnosticsState.rows[i]
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, yOff)
        yOff = yOff - row:GetHeight() - 12
    end

    return math.max(DIAGNOSTICS_PAGE_HEIGHT, mathAbs(yOff) + 16)
end

local function UpdateDiagnosticsRows()
    if not diagnosticsState.rows then
        return
    end

    local roster = GetDiagnosticsRoster()
    local rosterLabel = tconcat(roster, ", ")
    local profilerAvailable = MedaUI.IsAddOnProfilerAvailable and MedaUI:IsAddOnProfilerAvailable()
    local profilerEnabled = profilerAvailable and MedaUI:IsAddOnProfilerEnabled()
    local rosterNote = #roster > 1
        and "Standalone MedaUI is loaded separately and included in the suite total."
        or "Embedded MedaUI code is included in MedaAuras totals."

    local profilerRow = diagnosticsState.rows[1]
    profilerRow:SetLabel("Profiler")
    if profilerAvailable then
        local status = profilerEnabled and "Active" or "Disabled"
        local r, g, b = profilerEnabled and 0.4 or 1.0, profilerEnabled and 0.9 or 0.8, profilerEnabled and 0.4 or 0.0
        profilerRow:SetStatus(status, r, g, b)
        profilerRow:SetAccentColor(r, g, b)
        profilerRow:SetNote(format(
            "Sampling %d addon(s): %s. Refresh runs every %d seconds only while this page is visible. %s",
            #roster,
            rosterLabel,
            DIAGNOSTICS_REFRESH_SECONDS,
            rosterNote
        ))
    else
        profilerRow:SetStatus("Unavailable", 1.0, 0.3, 0.3)
        profilerRow:SetAccentColor(1.0, 0.3, 0.3)
        profilerRow:SetNote("This client build does not expose the Blizzard addon profiler API.")
    end

    local recentCpuRow = diagnosticsState.rows[2]
    recentCpuRow:SetLabel("Recent CPU")
    if profilerAvailable and profilerEnabled and AddOnProfilerMetric then
        local fps = GetFramerate() or 0
        local recentMs = MedaUI:GatherSuiteCPUMs(roster, AddOnProfilerMetric.RecentAverageTime)
        local recentPct = MedaUI:ComputeFrameBudgetPercent(recentMs, fps)
        local r, g, b = MedaUI:GetCPUColor(recentPct)
        recentCpuRow:SetStatus(MedaUI:FormatCPUMs(recentMs), r, g, b)
        recentCpuRow:SetAccentColor(r, g, b)
        if fps > 0 then
            recentCpuRow:SetNote(format("%.2f%% of the current frame budget at %.1f FPS.", recentPct, fps))
        else
            recentCpuRow:SetNote("Frame-budget percent is unavailable while FPS is zero.")
        end
    else
        recentCpuRow:SetStatus("N/A")
        recentCpuRow:SetAccentColor(0.45, 0.45, 0.45)
        recentCpuRow:SetNote("Recent CPU sampling requires the Blizzard addon profiler API.")
    end

    local sessionCpuRow = diagnosticsState.rows[3]
    sessionCpuRow:SetLabel("Session / Peak CPU")
    if profilerAvailable and profilerEnabled and AddOnProfilerMetric then
        local sessionMs = MedaUI:GatherSuiteCPUMs(roster, AddOnProfilerMetric.SessionAverageTime)
        local peakMs = MedaUI:GatherSuiteCPUMs(roster, AddOnProfilerMetric.PeakTime)
        local recentMs = MedaUI:GatherSuiteCPUMs(roster, AddOnProfilerMetric.RecentAverageTime)
        local peakPct = MedaUI:ComputeFrameBudgetPercent(peakMs, GetFramerate() or 0)
        local r, g, b = MedaUI:GetCPUColor(math.max(
            MedaUI:ComputeFrameBudgetPercent(sessionMs, GetFramerate() or 0),
            peakPct
        ))
        sessionCpuRow:SetStatus(format("%s / %s", MedaUI:FormatCPUMs(sessionMs), MedaUI:FormatCPUMs(peakMs)), r, g, b)
        sessionCpuRow:SetAccentColor(r, g, b)
        sessionCpuRow:SetNote(format(
            "Recent sample %s. Peak spikes matter more than averages when a module feels bursty.",
            MedaUI:FormatCPUMs(recentMs)
        ))
    else
        sessionCpuRow:SetStatus("N/A")
        sessionCpuRow:SetAccentColor(0.45, 0.45, 0.45)
        sessionCpuRow:SetNote("Session and peak CPU metrics are unavailable without the profiler API.")
    end

    local memoryRow = diagnosticsState.rows[4]
    memoryRow:SetLabel("Memory Snapshot")
    local memoryKB = MedaUI:GatherSuiteMemoryKB(roster)
    if memoryKB ~= nil then
        local memoryMB = (tonumber(memoryKB) or 0) / 1024
        local r, g, b = MedaUI:GetStatusColor(memoryMB, {
            { max = 4, color = { 0.4, 0.9, 0.4 } },
            { max = 12, color = { 1, 0.8, 0 } },
            { color = { 1, 0.3, 0.3 } },
        })
        memoryRow:SetStatus(MedaUI:FormatMemoryKB(memoryKB), r, g, b)
        memoryRow:SetAccentColor(r, g, b)
        memoryRow:SetNote("Point-in-time snapshot only. Use scoped slash/debug probes for allocator investigations instead of a permanent runtime monitor.")
    else
        memoryRow:SetStatus("Unavailable", 1.0, 0.3, 0.3)
        memoryRow:SetAccentColor(1.0, 0.3, 0.3)
        memoryRow:SetNote("This client build does not expose addon memory snapshot APIs.")
    end

    local lifecycleRow = diagnosticsState.rows[5]
    local enabledCount, totalCount, builtInEnabled, builtInTotal, customEnabled, customTotal = CountModuleStates()
    lifecycleRow:SetLabel("Runtime Modules")
    lifecycleRow:SetStatus(format("%d / %d enabled", enabledCount, totalCount), 1.0, 0.8, 0.0)
    lifecycleRow:SetAccentColor(1.0, 0.8, 0.0)
    lifecycleRow:SetNote(format(
        "Built-in %d/%d, custom %d/%d. Built-in modules initialize on ADDON_LOADED and enable on PLAYER_LOGIN; enabled custom modules initialize and enable during login startup when their runtime payload is loaded.",
        builtInEnabled,
        builtInTotal,
        customEnabled,
        customTotal
    ))

    local targetHeight = LayoutDiagnosticsRows()
    if settingsHost and settingsHost:IsShown()
        and settingsHost.activeModuleId == "General"
        and settingsHost.activePageId == "diagnostics" then
        MedaAuras:SetContentHeight(targetHeight)
    end
end

local function UpdateDiagnosticsMonitorState()
    if not settingsHost or not settingsHost:IsShown() then
        StopDiagnosticsTicker()
        return
    end

    if settingsHost.activeModuleId ~= "General" or settingsHost.activePageId ~= "diagnostics" then
        StopDiagnosticsTicker()
        return
    end

    if not diagnosticsState.rows then
        return
    end

    UpdateDiagnosticsRows()
    if not diagnosticsState.ticker then
        diagnosticsState.ticker = C_Timer.NewTicker(DIAGNOSTICS_REFRESH_SECONDS, UpdateDiagnosticsRows)
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

    local loggingHeader = MedaUI:CreateSectionHeader(parent, "Logging", 470)
    loggingHeader:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 38

    local loggingControls = MedaUI:BuildLogPolicyControls(parent, function()
        return MedaAuras.GetLogPolicy and MedaAuras:GetLogPolicy() or nil
    end, function(policy)
        if MedaAuras.SetLogPolicy then
            MedaAuras:SetLogPolicy(policy)
        end
    end, {
        width = 260,
        includeChatFallback = true,
        description = "Sender-owned logging policy used whether or not MedaDebug is installed.",
    })
    loggingControls:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - loggingControls:GetHeight() - 12

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

local function BuildDiagnosticsPage(parent)
    StopDiagnosticsTicker()
    diagnosticsState.page = parent
    diagnosticsState.rows = {}

    local yOff = 0

    local header = MedaUI:CreateSectionHeader(parent, "Suite Diagnostics", 520)
    header:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 40

    local note = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    note:SetPoint("TOPLEFT", 0, yOff)
    note:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
    note:SetJustifyH("LEFT")
    note:SetWordWrap(true)
    note:SetText("Suite-level CPU and memory snapshots for MedaAuras. Refresh is intentionally slow and only runs while this page is visible.")
    note:SetTextColor(unpack(MedaUI.Theme.text))
    yOff = yOff - note:GetStringHeight() - 18

    diagnosticsState.baseYOffset = yOff

    local function CreateDiagnosticsRow()
        local row = MedaUI:CreateStatusRow(parent, {
            width = 560,
            showNote = true,
            cardStyle = true,
        })
        row:SetIcon(nil)
        diagnosticsState.rows[#diagnosticsState.rows + 1] = row
        return row
    end

    CreateDiagnosticsRow()
    CreateDiagnosticsRow()
    CreateDiagnosticsRow()
    CreateDiagnosticsRow()
    CreateDiagnosticsRow()

    UpdateDiagnosticsRows()
    UpdateDiagnosticsMonitorState()
    return LayoutDiagnosticsRows()
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
        defaultPageHeight = 1400,
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
            if MedaAuras.RefreshModuleConfig then
                MedaAuras:RefreshModuleConfig()
            end
        end,
        buildPage = function(_, parent)
            if MedaAuras.BuildCustomModuleConfig then
                return MedaAuras:BuildCustomModuleConfig(parent, entry.key) or 1400
            end
            return 1400
        end,
    }
end

local function RegisterOptionsModules()
    settingsHost:ClearModules()

    settingsHost:RegisterModule("General", {
        title = "Settings",
        description = "Global MedaAuras options, suite diagnostics, debug logging, and embedded addon controls.",
        sidebarGroup = "General",
        sidebarOrder = 10,
        entryType = "nav",
        pages = {
            { id = "settings", label = "Settings", title = "General Settings" },
            { id = "diagnostics", label = "Diagnostics", title = "Suite Diagnostics" },
        },
        pageHeights = {
            settings = 520,
            diagnostics = DIAGNOSTICS_PAGE_HEIGHT,
        },
        defaultPageHeight = DIAGNOSTICS_PAGE_HEIGHT,
        buildPage = function(pageName, parent)
            if pageName == "diagnostics" then
                return BuildDiagnosticsPage(parent)
            end
            return BuildGeneralPage(parent)
        end,
        onPageCacheRestore = function(pageName)
            if pageName == "diagnostics" then
                UpdateDiagnosticsRows()
                UpdateDiagnosticsMonitorState()
            end
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
        selectedPageId = pageId or selectedPageId
        if ns.Reminders and ns.Reminders.RefreshHUDs then
            ns.Reminders.RefreshHUDs()
        end
        UpdateDiagnosticsMonitorState()
    end

    local hostFrame = settingsHost.GetFrame and settingsHost:GetFrame() or nil
    if hostFrame and hostFrame.HookScript then
        hostFrame:HookScript("OnShow", function()
            UpdateDiagnosticsMonitorState()
        end)
        hostFrame:HookScript("OnHide", function()
            StopDiagnosticsTicker()
            if ns.Reminders and ns.Reminders.RefreshHUDs then
                ns.Reminders.RefreshHUDs()
            end
        end)
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
        UpdateDiagnosticsMonitorState()
    else
        StopDiagnosticsTicker()
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

    UpdateDiagnosticsMonitorState()
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

function MedaAuras:GetActiveSettingsSelection()
    if not settingsHost or not settingsHost:IsShown() then
        return nil, nil
    end

    return settingsHost.activeModuleId, settingsHost.activePageId
end

function MedaAuras:RefreshModuleConfig()
    if settingsHost and settingsHost:IsShown() then
        settingsHost:RefreshActivePage(true)
        UpdateDiagnosticsMonitorState()
    end
end

function MedaAuras:RefreshSidebarDot(moduleId)
    if settingsHost then
        settingsHost:RefreshModuleToggle(moduleId)
    end
end
