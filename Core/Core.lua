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
local sidebarButtons = {}
local contentFrame
local sidebarFrame
local sidebarDynamicFrames = {}
local sidebarScrollParent
local sidebarScrollContent

local SIDEBAR_WIDTH = 280
local PANEL_WIDTH = 820
local PANEL_HEIGHT = 720
local CONTENT_INSET = 14

local scrollParent
local scrollFrame
local scrollChild

local configCleanupFrames = {}

local function ClearContent()
    for _, frame in ipairs(configCleanupFrames) do
        frame:Hide()
        frame:SetParent(nil)
    end
    wipe(configCleanupFrames)

    if contentFrame then
        local children = { contentFrame:GetChildren() }
        for _, child in ipairs(children) do
            child:Hide()
            child:SetParent(nil)
        end
        local regions = { contentFrame:GetRegions() }
        for _, region in ipairs(regions) do
            region:Hide()
        end
    end
    if scrollParent then
        scrollParent:ResetScroll()
    end
end

local function SetContentHeight(usedHeight)
    if scrollChild and scrollFrame then
        scrollChild:SetHeight(math.max(usedHeight, scrollFrame:GetHeight()))
    end
end

local function BuildGeneralConfig(parent)
    local yOff = 0

    local headerContainer = MedaUI:CreateSectionHeader(parent, "General Settings")
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

    -- Debug mode toggle
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


    -- Minimap Buttons section
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
        local mmHeader = MedaUI:CreateSectionHeader(parent, "Minimap Buttons")
        mmHeader:SetPoint("TOPLEFT", 0, yOff)
        yOff = yOff - 34

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

    SetContentHeight(math.abs(yOff))
end

local function UpdateSidebarSelection()
    for modName, btn in pairs(sidebarButtons) do
        local Theme = MedaUI.Theme
        if modName == selectedModule then
            btn:SetBackdropColor(unpack(Theme.buttonHover))
            btn:SetBackdropBorderColor(unpack(Theme.gold))
        else
            btn:SetBackdropColor(0, 0, 0, 0)
            btn:SetBackdropBorderColor(0, 0, 0, 0)
        end
    end
end

local function LoadModuleConfig(modName)
    selectedModule = modName
    ClearContent()
    UpdateSidebarSelection()

    if modName == "General" then
        BuildGeneralConfig(contentFrame)
        return
    end

    if MedaAuras.IsCustomModuleKey and MedaAuras:IsCustomModuleKey(modName) then
        if MedaAuras.BuildCustomModuleConfig then
            MedaAuras:BuildCustomModuleConfig(contentFrame, modName)
        end
        if scrollChild and scrollChild:GetHeight() < 1 then
            SetContentHeight(800)
        end
        return
    end

    local config = modules[modName]
    if not config then return end
    local db = MedaAuras:GetModuleDB(modName)
    if not db then return end

    if config.BuildConfig then
        SafeCall(modName, config.BuildConfig, contentFrame, db)
    end

    -- If the module didn't set height, use a safe default
    if scrollChild and scrollChild:GetHeight() < 1 then
        SetContentHeight(800)
    end
end

local function BuildSettingsPanel()
    if settingsPanel then
        if settingsPanel.RebuildSidebar then
            settingsPanel:RebuildSidebar()
        end
        return settingsPanel
    end

    settingsPanel = MedaUI:CreatePanel("MedaAurasSettingsPanel", PANEL_WIDTH, PANEL_HEIGHT, "MedaAuras Settings")
    settingsPanel:SetResizable(true, {
        minWidth = SIDEBAR_WIDTH + 300,
        minHeight = 400,
    })
    tinsert(UISpecialFrames, "MedaAurasSettingsPanel")

    local content = settingsPanel:GetContent()

    sidebarFrame = CreateFrame("Frame", nil, content, "BackdropTemplate")
    sidebarFrame:SetWidth(SIDEBAR_WIDTH)
    sidebarFrame:SetPoint("TOPLEFT", 0, 0)
    sidebarFrame:SetPoint("BOTTOMLEFT", 0, 0)
    sidebarFrame:SetBackdrop(MedaUI:CreateBackdrop(true))

    local function ApplySidebarTheme()
        local Theme = MedaUI.Theme
        sidebarFrame:SetBackdropColor(unpack(Theme.backgroundDark))
        sidebarFrame:SetBackdropBorderColor(unpack(Theme.border))
    end
    MedaUI:RegisterThemedWidget(sidebarFrame, ApplySidebarTheme)
    ApplySidebarTheme()

    local divider = content:CreateTexture(nil, "ARTWORK")
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", sidebarFrame, "TOPRIGHT", 0, 0)
    divider:SetPoint("BOTTOMLEFT", sidebarFrame, "BOTTOMRIGHT", 0, 0)
    divider:SetColorTexture(unpack(MedaUI.Theme.border))
    MedaUI:RegisterThemedWidget(divider, function()
        divider:SetColorTexture(unpack(MedaUI.Theme.border))
    end)

    scrollParent = MedaUI:CreateScrollFrame(content)
    Pixel.SetPoint(scrollParent, "TOPLEFT", sidebarFrame, "TOPRIGHT", CONTENT_INSET + 1, -CONTENT_INSET)
    Pixel.SetPoint(scrollParent, "BOTTOMRIGHT", -CONTENT_INSET, CONTENT_INSET)
    scrollParent:SetScrollStep(30)

    scrollFrame = scrollParent.scrollFrame
    scrollChild = scrollParent.scrollContent
    Pixel.SetHeight(scrollChild, 1)

    contentFrame = scrollChild

    sidebarScrollParent = MedaUI:CreateScrollFrame(sidebarFrame)
    Pixel.SetPoint(sidebarScrollParent, "TOPLEFT", 0, -6)
    Pixel.SetPoint(sidebarScrollParent, "BOTTOMRIGHT", 0, 30)
    sidebarScrollParent:SetScrollStep(30)
    sidebarScrollContent = sidebarScrollParent.scrollContent
    Pixel.SetHeight(sidebarScrollContent, 1)

    local GENERAL_ROW_HEIGHT = 30
    local MODULE_ROW_HEIGHT = 56

    local function TrackSidebarFrame(frame)
        sidebarDynamicFrames[#sidebarDynamicFrames + 1] = frame
        return frame
    end

    local function ClearSidebarFrames()
        for _, frame in ipairs(sidebarDynamicFrames) do
            frame:Hide()
            frame:SetParent(nil)
        end
        wipe(sidebarDynamicFrames)
        wipe(sidebarButtons)
    end

    local function RebuildSidebar()
        ClearSidebarFrames()

        local yOff = -8

        local function CreateSidebarButton(name, displayText, isModule, modConfig)
            local rowHeight = isModule and MODULE_ROW_HEIGHT or GENERAL_ROW_HEIGHT
            local btn = TrackSidebarFrame(CreateFrame("Button", nil, sidebarScrollContent, "BackdropTemplate"))
            btn:SetHeight(rowHeight)
            btn:SetPoint("TOPLEFT", 6, yOff)
            btn:SetPoint("TOPRIGHT", -6, yOff)
            btn:SetBackdrop(MedaUI:CreateBackdrop(false))
            btn:SetBackdropColor(0, 0, 0, 0)
            btn:SetBackdropBorderColor(0, 0, 0, 0)

            local labelAnchorLeft = 12

            if isModule then
                local cbBox = TrackSidebarFrame(CreateFrame("Button", nil, btn, "BackdropTemplate"))
                cbBox:SetSize(16, 16)
                cbBox:SetPoint("TOPLEFT", 10, -8)
                cbBox:SetBackdrop(MedaUI:CreateBackdrop(true))

                cbBox.check = cbBox:CreateTexture(nil, "OVERLAY")
                cbBox.check:SetTexture(MedaUI.mediaPath .. "Textures\\checkmark.tga")
                cbBox.check:SetPoint("CENTER", 0, 0)
                cbBox.check:SetSize(12, 12)
                cbBox.check:Hide()

                local db = MedaAuras:GetModuleDB(name)
                if db and db.enabled then
                    cbBox.check:Show()
                end

                local function ApplyCBTheme()
                    local Theme = MedaUI.Theme
                    cbBox:SetBackdropColor(unpack(Theme.input))
                    cbBox:SetBackdropBorderColor(unpack(Theme.border))
                    cbBox.check:SetVertexColor(1, 1, 1, 1)
                end
                MedaUI:RegisterThemedWidget(cbBox, ApplyCBTheme)
                ApplyCBTheme()

                cbBox:SetScript("OnClick", function()
                    local mdb = MedaAuras:GetModuleDB(name)
                    if not mdb then return end
                    if mdb.enabled then
                    MedaAuras:DisableModule(name)
                    else
                    MedaAuras:EnableModule(name)
                    end
                MedaAuras:RefreshSidebarDot(name)
                    if selectedModule == name then
                        LoadModuleConfig(name)
                    end
                end)

                cbBox:SetScript("OnEnter", function()
                    local Theme = MedaUI.Theme
                    cbBox:SetBackdropBorderColor(unpack(Theme.gold))
                end)
                cbBox:SetScript("OnLeave", function()
                    local Theme = MedaUI.Theme
                    cbBox:SetBackdropBorderColor(unpack(Theme.border))
                end)

                btn.cbBox = cbBox
                labelAnchorLeft = 34
            end

            btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            btn.label:SetJustifyH("LEFT")
            btn.label:SetWordWrap(false)
            btn.label:SetText(displayText)

            local stabColor = isModule and modConfig and (modConfig.customColor or STABILITY_COLORS[modConfig.stability or ""])
            if stabColor then
                btn.label:SetTextColor(unpack(stabColor))
            else
                btn.label:SetTextColor(unpack(MedaUI.Theme.text))
            end

            if isModule then
                btn.label:SetPoint("TOPLEFT", labelAnchorLeft, -7)

                if modConfig and modConfig.customTag then
                    btn.tagLabel = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    btn.tagLabel:SetPoint("TOPRIGHT", -8, -8)
                    btn.tagLabel:SetText(modConfig.customTag)
                    btn.tagLabel:SetTextColor(unpack(modConfig.customColor or { 0.35, 0.85, 1.0 }))
                end

                if modConfig and modConfig.version then
                    btn.versionLabel = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    if btn.tagLabel then
                        btn.versionLabel:SetPoint("TOPRIGHT", btn.tagLabel, "TOPLEFT", -6, 0)
                    else
                        btn.versionLabel:SetPoint("TOPRIGHT", -8, -8)
                    end
                    btn.versionLabel:SetTextColor(0.45, 0.45, 0.45)
                    local ver = tostring(modConfig.version or "")
                    if ver:sub(1, 1):lower() ~= "v" then ver = "v" .. ver end
                    btn.versionLabel:SetText(ver)
                    btn.label:SetPoint("RIGHT", btn.versionLabel, "LEFT", -6, 0)
                else
                    btn.label:SetPoint("RIGHT", -6, 0)
                end

                local sDesc = modConfig and modConfig.sidebarDesc
                if sDesc and sDesc ~= "" then
                    btn.descLabel = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    btn.descLabel:SetPoint("TOPLEFT", labelAnchorLeft, -22)
                    btn.descLabel:SetPoint("RIGHT", -8, 0)
                    btn.descLabel:SetJustifyH("LEFT")
                    btn.descLabel:SetWordWrap(true)
                    btn.descLabel:SetText(sDesc)
                    btn.descLabel:SetTextColor(0.55, 0.55, 0.55)
                end
            else
                btn.label:SetPoint("LEFT", labelAnchorLeft, 0)
                btn.label:SetPoint("RIGHT", -6, 0)
            end

            btn:SetScript("OnClick", function()
                LoadModuleConfig(name)
            end)

            btn:SetScript("OnEnter", function(self)
                if name ~= selectedModule then
                    self:SetBackdropColor(unpack(MedaUI.Theme.buttonHover))
                end

                if isModule and modConfig and modConfig.slashCommands then
                    local cmds = {}
                    for cmd in pairs(modConfig.slashCommands) do
                        if cmd ~= "" then
                            cmds[#cmds + 1] = cmd
                        end
                    end
                    if #cmds > 0 then
                        table.sort(cmds)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT", 4, 0)
                        GameTooltip:AddLine(displayText, 1, 0.82, 0)
                        GameTooltip:AddLine(" ")
                        GameTooltip:AddLine("Slash Commands:", 0.65, 0.65, 0.65)
                        local slug = name:lower()
                        for _, cmd in ipairs(cmds) do
                            GameTooltip:AddLine(format("  /mwa %s %s", slug, cmd), 0.4, 0.78, 1)
                        end
                        GameTooltip:Show()
                    end
                end
            end)

            btn:SetScript("OnLeave", function(self)
                if name ~= selectedModule then
                    self:SetBackdropColor(0, 0, 0, 0)
                end
                GameTooltip:Hide()
            end)

            MedaUI:RegisterThemedWidget(btn, function()
                local Theme = MedaUI.Theme
                if stabColor then
                    btn.label:SetTextColor(unpack(stabColor))
                else
                    btn.label:SetTextColor(unpack(Theme.text))
                end
                if btn.versionLabel then
                    btn.versionLabel:SetTextColor(0.45, 0.45, 0.45)
                end
                if btn.tagLabel then
                    btn.tagLabel:SetTextColor(unpack(modConfig.customColor or { 0.35, 0.85, 1.0 }))
                end
                if btn.descLabel then
                    btn.descLabel:SetTextColor(0.55, 0.55, 0.55)
                end
                if name == selectedModule then
                    btn:SetBackdropColor(unpack(Theme.buttonHover))
                    btn:SetBackdropBorderColor(unpack(Theme.gold))
                else
                    btn:SetBackdropColor(0, 0, 0, 0)
                    btn:SetBackdropBorderColor(0, 0, 0, 0)
                end
            end)

            sidebarButtons[name] = btn
            yOff = yOff - rowHeight
        end

        local function CreateSeparator()
            local sep = TrackSidebarFrame(sidebarScrollContent:CreateTexture(nil, "ARTWORK"))
            sep:SetHeight(1)
            sep:SetPoint("TOPLEFT", 10, yOff - 4)
            sep:SetPoint("TOPRIGHT", -10, yOff - 4)
            sep:SetColorTexture(unpack(MedaUI.Theme.border))
            MedaUI:RegisterThemedWidget(sep, function()
                sep:SetColorTexture(unpack(MedaUI.Theme.border))
            end)
            yOff = yOff - 12
        end

        local function CreateSectionLabel(text)
            local label = TrackSidebarFrame(sidebarScrollContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
            label:SetPoint("TOPLEFT", 12, yOff)
            label:SetPoint("RIGHT", -12, 0)
            label:SetJustifyH("LEFT")
            label:SetText(text)
            label:SetTextColor(0.7, 0.7, 0.7)
            yOff = yOff - 20
        end

        local function CreateActionButton(text, onClick)
            local btn = TrackSidebarFrame(MedaUI:CreateButton(sidebarScrollContent, text))
            btn:SetHeight(22)
            btn:SetPoint("TOPLEFT", 12, yOff)
            btn:SetPoint("TOPRIGHT", -12, yOff)
            btn:SetScript("OnClick", onClick)
            yOff = yOff - 28
        end

        CreateSidebarButton("General", "General", false, nil)
        CreateSeparator()

        if MedaAuras.GetCustomModuleEntries then
            local customEntries = MedaAuras:GetCustomModuleEntries()
            CreateSectionLabel("Custom Modules")

            if MedaAuras.ShowImportCustomModuleDialog then
                CreateActionButton("Import Module", function() MedaAuras:ShowImportCustomModuleDialog() end)
            end

            for _, entry in ipairs(customEntries) do
                local config = MedaAuras:GetCustomModuleConfig(entry.key)
                if config then
                    CreateSidebarButton(entry.key, config.title or entry.moduleId, true, config)
                end
            end

            CreateSeparator()
        end

        table.sort(moduleOrder)
        for _, modName in ipairs(moduleOrder) do
            local config = modules[modName]
            CreateSidebarButton(modName, config.title or modName, true, config)
        end

        if selectedModule ~= "General" and not sidebarButtons[selectedModule] then
            selectedModule = "General"
        end

        if sidebarScrollParent then
            sidebarScrollParent:SetContentHeight(math.abs(yOff) + 8, true, true)
        end
        UpdateSidebarSelection()
    end

    settingsPanel.RebuildSidebar = RebuildSidebar
    RebuildSidebar()

    local legendSep = sidebarFrame:CreateTexture(nil, "ARTWORK")
    legendSep:SetHeight(1)
    legendSep:SetPoint("BOTTOMLEFT", 10, 24)
    legendSep:SetPoint("BOTTOMRIGHT", -10, 24)
    legendSep:SetColorTexture(unpack(MedaUI.Theme.border))

    local legendFrame = CreateFrame("Frame", nil, sidebarFrame)
    legendFrame:SetHeight(20)
    legendFrame:SetPoint("BOTTOMLEFT", 8, 4)
    legendFrame:SetPoint("BOTTOMRIGHT", -8, 4)

    local legendEntries = {
        { label = "Stable",       color = STABILITY_COLORS.stable },
        { label = "Beta",         color = STABILITY_COLORS.beta },
        { label = "Experimental", color = STABILITY_COLORS.experimental },
    }
    local lx = 0
    for _, entry in ipairs(legendEntries) do
        local dot = legendFrame:CreateTexture(nil, "ARTWORK")
        dot:SetSize(6, 6)
        dot:SetPoint("LEFT", lx, 0)
        dot:SetColorTexture(unpack(entry.color))

        local lbl = legendFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", lx + 9, 0)
        lbl:SetText(entry.label)
        lbl:SetTextColor(unpack(entry.color))

        lx = lx + 9 + lbl:GetStringWidth() + 10
    end

    MedaUI:RegisterThemedWidget(legendFrame, function()
        legendSep:SetColorTexture(unpack(MedaUI.Theme.border))
    end)

    LoadModuleConfig("General")

    return settingsPanel
end

function MedaAuras:ToggleSettings()
    local panel = BuildSettingsPanel()
    if panel:IsShown() then
        panel:Hide()
    else
        panel:Show()
        LoadModuleConfig(selectedModule or "General")
    end
end

function MedaAuras:RebuildSettingsSidebar()
    if settingsPanel and settingsPanel.RebuildSidebar then
        settingsPanel:RebuildSidebar()
    end
end

function MedaAuras:SetContentHeight(height)
    SetContentHeight(height)
end

function MedaAuras:RegisterConfigCleanup(frame)
    configCleanupFrames[#configCleanupFrames + 1] = frame
end

function MedaAuras:CreateConfigTabs(parent, tabs)
    local tabBar = MedaUI:CreateTabBar(parent, tabs)
    tabBar:SetPoint("TOPLEFT", 0, 0)
    tabBar:SetPoint("RIGHT", 0, 0)

    local frames = {}
    for _, tab in ipairs(tabs) do
        local f = CreateFrame("Frame", nil, parent)
        f:SetPoint("TOPLEFT", 0, -36)
        f:SetPoint("RIGHT", 0, 0)
        f:SetHeight(5000)
        f:Hide()
        frames[tab.id] = f
    end

    frames[tabs[1].id]:Show()

    tabBar.OnTabChanged = function(_, tabId)
        for id, f in pairs(frames) do
            if id == tabId then f:Show() else f:Hide() end
        end
    end

    return tabBar, frames
end

function MedaAuras:RefreshModuleConfig()
    if selectedModule and settingsPanel and settingsPanel:IsShown() then
        LoadModuleConfig(selectedModule)
    end
end

function MedaAuras:RefreshSidebarDot(modName)
    local btn = sidebarButtons[modName]
    if btn and btn.cbBox then
        local db = self:GetModuleDB(modName)
        if db and db.enabled then
            btn.cbBox.check:Show()
        else
            btn.cbBox.check:Hide()
        end
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

        local uiTheme = MedaAurasDB.options.theme
        if uiTheme and MedaUI and MedaUI.SetTheme then
            MedaUI:SetTheme(uiTheme)
            LogDebug(format("Applied UI theme: %s", uiTheme))
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
