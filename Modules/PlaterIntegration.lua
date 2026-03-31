local ADDON_NAME, ns = ...

local MedaUI = LibStub("MedaUI-2.0")

local format = format
local ipairs = ipairs
local mathAbs = math.abs
local pcall = pcall
local tonumber = tonumber
local tostring = tostring
local type = type
local unpack = unpack
local CreateFrame = CreateFrame

local MODULE_NAME = "PlaterIntegration"
local MODULE_VERSION = "1.0"
local MODULE_STABILITY = "beta"

local SUCCESS_COLOR = { 0.30, 0.85, 0.30 }
local WARNING_COLOR = { 1.00, 0.72, 0.20 }
local ERROR_COLOR = { 1.00, 0.35, 0.35 }
local INFO_COLOR = { 0.35, 0.85, 1.00 }

local M = {}
ns.PlaterIntegration = M

local eventFrame
local runtimeState = {
    lastActionText = nil,
    lastActionColor = nil,
}

local function SetLastAction(text, color)
    runtimeState.lastActionText = text
    runtimeState.lastActionColor = color or INFO_COLOR
end

local function RefreshConfigPage()
    if MedaAuras and MedaAuras.RefreshModuleConfig then
        MedaAuras:RefreshModuleConfig()
    end
end

local function GetPayloads()
    return ns.PlaterPayloads or {}
end

local function GetPayloadByKey(payloadKey)
    for _, payload in ipairs(GetPayloads()) do
        if payload.key == payloadKey then
            return payload
        end
    end
end

local function GetPlaterState()
    local plater = _G.Plater
    local state = {
        plater = plater,
        platerAvailable = type(plater) == "table",
    }

    state.hasImporter = state.platerAvailable and type(plater.ImportScriptString) == "function" or false
    state.hasCompile = state.platerAvailable and type(plater.CompileAllScripts) == "function" or false
    state.hasPlateRefresh = state.platerAvailable and type(plater.UpdateAllPlates) == "function" or false
    state.canDirectInstall = state.hasImporter and state.hasCompile and state.hasPlateRefresh
    state.hookDB = state.platerAvailable and plater.db and plater.db.profile and plater.db.profile.hook_data or nil

    return state
end

local function FindInstalledPayload(payload, platerState)
    if not payload or type(platerState) ~= "table" or type(platerState.hookDB) ~= "table" then
        return nil
    end

    local nameMatch
    local nameMatchIndex

    for index, scriptObject in ipairs(platerState.hookDB) do
        if type(scriptObject) == "table" then
            if payload.uid and scriptObject.UID == payload.uid then
                return scriptObject, index, "uid"
            end

            if not nameMatch and payload.name and scriptObject.Name == payload.name then
                nameMatch = scriptObject
                nameMatchIndex = index
            end
        end
    end

    if nameMatch then
        return nameMatch, nameMatchIndex, "name"
    end
end

local function BuildStatus(payload)
    local platerState = GetPlaterState()
    local expectedRevision = tonumber(payload.expectedRevision) or 0
    local status = {
        expectedRevision = expectedRevision,
        platerAvailable = platerState.platerAvailable,
        canDirectInstall = platerState.canDirectInstall,
        installed = false,
        installedRevision = nil,
        enabled = nil,
        state = "missing",
        message = "Not installed in Plater.",
        color = WARNING_COLOR,
    }

    if not platerState.platerAvailable then
        status.state = "plater-missing"
        status.message = "Plater is not loaded. Direct install is unavailable."
        status.color = WARNING_COLOR
        return status
    end

    if not platerState.canDirectInstall then
        status.state = "plater-api-unavailable"
        status.message = "Plater is loaded, but its importer APIs are unavailable."
        status.color = WARNING_COLOR
        return status
    end

    local scriptObject, _, matchSource = FindInstalledPayload(payload, platerState)
    if not scriptObject then
        status.state = "missing"
        status.message = "Not installed in Plater."
        status.color = WARNING_COLOR
        return status
    end

    local installedRevision = tonumber(scriptObject.Revision) or 0

    status.installed = true
    status.installedRevision = installedRevision
    status.enabled = scriptObject.Enabled == true
    status.matchSource = matchSource

    if installedRevision < expectedRevision then
        status.state = "installed-outdated"
        status.message = format("Installed revision %d. Update available to revision %d.", installedRevision, expectedRevision)
        status.color = WARNING_COLOR
    else
        status.state = "installed-current"
        if status.enabled then
            status.message = format("Installed revision %d. Current.", installedRevision)
            status.color = SUCCESS_COLOR
        else
            status.message = format("Installed revision %d. Current, but disabled in Plater.", installedRevision)
            status.color = WARNING_COLOR
        end
    end

    return status
end

function M:GetManagedPayloads()
    return GetPayloads()
end

function M:GetPayloadStatus(payload)
    return BuildStatus(payload)
end

function M:ShowPayloadImportString(payloadKey)
    local payload = GetPayloadByKey(payloadKey)
    if not payload then
        SetLastAction("Unable to find the requested Plater payload.", ERROR_COLOR)
        RefreshConfigPage()
        return false
    end

    if MedaAuras and MedaAuras.ShowCustomModuleTextPopup then
        MedaAuras:ShowCustomModuleTextPopup(payload.name .. " Import String", payload.importString or "", true)
    end

    SetLastAction("Opened the encoded Plater import string. Paste it into Plater's hook import dialog.", INFO_COLOR)
    RefreshConfigPage()
    return true
end

function M:InstallPayload(payloadKey, force)
    local payload = GetPayloadByKey(payloadKey)
    if not payload then
        SetLastAction("Unable to find the requested Plater payload.", ERROR_COLOR)
        RefreshConfigPage()
        return false
    end

    local platerState = GetPlaterState()
    if not platerState.canDirectInstall then
        self:ShowPayloadImportString(payloadKey)
        return false
    end

    local existingStatus = BuildStatus(payload)
    local callOk, success, objectAdded, wasEnabled = pcall(
        platerState.plater.ImportScriptString,
        payload.importString,
        force == true,
        false,
        false,
        false
    )

    if not callOk then
        SetLastAction("Plater import failed: " .. tostring(success), ERROR_COLOR)
        RefreshConfigPage()
        return false, success
    end

    if not success or type(objectAdded) ~= "table" then
        SetLastAction("Plater did not accept the import string.", ERROR_COLOR)
        RefreshConfigPage()
        return false
    end

    if not existingStatus.installed and type(wasEnabled) ~= "boolean" then
        objectAdded.Enabled = true
    end

    local compileOk, compileErr = pcall(platerState.plater.CompileAllScripts, "hook")
    local refreshOk, refreshErr = pcall(platerState.plater.UpdateAllPlates)

    if compileOk and refreshOk then
        if force then
            SetLastAction("Reinstalled the managed Plater hook and refreshed visible nameplates.", SUCCESS_COLOR)
        elseif existingStatus.installed then
            SetLastAction("Updated the managed Plater hook and refreshed visible nameplates.", SUCCESS_COLOR)
        else
            SetLastAction("Installed the managed Plater hook and refreshed visible nameplates.", SUCCESS_COLOR)
        end
    else
        local errorBits = {}
        if not compileOk then
            errorBits[#errorBits + 1] = "compile: " .. tostring(compileErr)
        end
        if not refreshOk then
            errorBits[#errorBits + 1] = "refresh: " .. tostring(refreshErr)
        end
        SetLastAction("Installed in Plater, but the live refresh step had issues (" .. table.concat(errorBits, "; ") .. ").", WARNING_COLOR)
    end

    RefreshConfigPage()
    return true, objectAdded
end

local function EnsureEventFrame()
    if eventFrame then
        return eventFrame
    end

    eventFrame = CreateFrame("Frame")
    eventFrame:SetScript("OnEvent", function(_, event, addonName)
        if event == "ADDON_LOADED" and addonName == "Plater" then
            eventFrame:UnregisterEvent("ADDON_LOADED")
            RefreshConfigPage()
        end
    end)

    return eventFrame
end

local function UpdatePlaterWatcher()
    local frame = EnsureEventFrame()
    frame:UnregisterAllEvents()

    if not _G.Plater then
        frame:RegisterEvent("ADDON_LOADED")
    end
end

local function AddWrappedText(parent, yOffset, text, fontObject, color)
    local label = parent:CreateFontString(nil, "OVERLAY", fontObject or "GameFontNormal")
    label:SetPoint("TOPLEFT", 0, yOffset)
    label:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(true)
    label:SetText(text or "")
    label:SetTextColor(unpack(color or MedaUI.Theme.text))
    return label, yOffset - label:GetStringHeight() - 12
end

local function AddInfoLine(parent, yOffset, labelText, valueText, color)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 0, yOffset)
    label:SetWidth(140)
    label:SetJustifyH("LEFT")
    label:SetText(labelText or "")
    label:SetTextColor(0.70, 0.70, 0.70)

    local value = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    value:SetPoint("TOPLEFT", 146, yOffset)
    value:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
    value:SetJustifyH("LEFT")
    value:SetWordWrap(true)
    value:SetText(valueText or "")
    value:SetTextColor(unpack(color or MedaUI.Theme.text))

    local lineHeight = math.max(label:GetStringHeight(), value:GetStringHeight())
    return yOffset - lineHeight - 8
end

local function BuildTopBanner()
    local platerState = GetPlaterState()

    if not platerState.platerAvailable then
        return "Plater not detected. Direct install is unavailable, but you can still copy the encoded import string.", WARNING_COLOR
    end

    if not platerState.canDirectInstall then
        return "Plater is detected, but its install APIs are unavailable in this session. Use the copy flow instead.", WARNING_COLOR
    end

    return "Plater is detected. Managed hook installs compile immediately and refresh visible nameplates without a reload.", SUCCESS_COLOR
end

local function BuildSettingsPage(parent)
    local yOffset = 0

    local header = MedaUI:CreateSectionHeader(parent, "Plater Integration")
    header:SetPoint("TOPLEFT", 0, yOffset)
    yOffset = yOffset - 40

    local description = "Manage bundled Plater hook payloads from inside MedaAuras. This page only handles install, update, reinstall, and copy flows. Runtime settings such as opacity, mode, and focus behavior remain in Plater's own mod options."
    local _, nextY = AddWrappedText(parent, yOffset, description, "GameFontNormal", MedaUI.Theme.text)
    yOffset = nextY

    local bannerText, bannerColor = BuildTopBanner()
    _, nextY = AddWrappedText(parent, yOffset, bannerText, "GameFontNormalSmall", bannerColor)
    yOffset = nextY

    if runtimeState.lastActionText then
        _, nextY = AddWrappedText(parent, yOffset, runtimeState.lastActionText, "GameFontNormalSmall", runtimeState.lastActionColor)
        yOffset = nextY
    end

    local payloadHeader = MedaUI:CreateSectionHeader(parent, "Managed Payloads")
    payloadHeader:SetPoint("TOPLEFT", 0, yOffset)
    yOffset = yOffset - 40

    for _, payload in ipairs(GetPayloads()) do
        local payloadStatus = BuildStatus(payload)

        local section = MedaUI:CreateSectionHeader(parent, payload.name)
        section:SetPoint("TOPLEFT", 0, yOffset)
        yOffset = yOffset - 36

        _, nextY = AddWrappedText(parent, yOffset, payload.description, "GameFontNormalSmall", MedaUI.Theme.textDim or { 0.65, 0.65, 0.65, 1.0 })
        yOffset = nextY

        yOffset = AddInfoLine(parent, yOffset, "Type", payload.kind or "hook")
        yOffset = AddInfoLine(parent, yOffset, "Expected Revision", tostring(payloadStatus.expectedRevision))
        yOffset = AddInfoLine(parent, yOffset, "Installed Revision", payloadStatus.installedRevision and tostring(payloadStatus.installedRevision) or "Not installed")
        yOffset = AddInfoLine(parent, yOffset, "Status", payloadStatus.message, payloadStatus.color)
        yOffset = AddInfoLine(parent, yOffset, "Enabled In Plater", payloadStatus.installed and (payloadStatus.enabled and "Yes" or "No") or "N/A")

        local installBtn = MedaUI:CreateButton(parent, "Install", 92, 28)
        installBtn:SetPoint("TOPLEFT", 0, yOffset - 6)
        installBtn:SetEnabled(payloadStatus.state == "missing" and payloadStatus.canDirectInstall)
        installBtn:SetScript("OnClick", function()
            M:InstallPayload(payload.key, false)
        end)

        local updateBtn = MedaUI:CreateButton(parent, "Update", 92, 28)
        updateBtn:SetPoint("LEFT", installBtn, "RIGHT", 8, 0)
        updateBtn:SetEnabled(payloadStatus.state == "installed-outdated" and payloadStatus.canDirectInstall)
        updateBtn:SetScript("OnClick", function()
            M:InstallPayload(payload.key, false)
        end)

        local reinstallBtn = MedaUI:CreateButton(parent, "Reinstall", 96, 28)
        reinstallBtn:SetPoint("LEFT", updateBtn, "RIGHT", 8, 0)
        reinstallBtn:SetEnabled(payloadStatus.installed and payloadStatus.canDirectInstall)
        reinstallBtn:SetScript("OnClick", function()
            M:InstallPayload(payload.key, true)
        end)

        local copyBtn = MedaUI:CreateButton(parent, "Copy Import String", 152, 28)
        copyBtn:SetPoint("LEFT", reinstallBtn, "RIGHT", 8, 0)
        copyBtn:SetScript("OnClick", function()
            M:ShowPayloadImportString(payload.key)
        end)

        yOffset = yOffset - 50
    end

    local footerNote = "Use MedaAuras for lifecycle and version management. Use Plater for the hook's actual runtime settings after installation."
    _, nextY = AddWrappedText(parent, yOffset, footerNote, "GameFontNormalSmall", MedaUI.Theme.textDim or { 0.65, 0.65, 0.65, 1.0 })
    yOffset = nextY

    return mathAbs(yOffset) + 20
end

local function OnInitialize()
    UpdatePlaterWatcher()
end

local function OnEnable()
    UpdatePlaterWatcher()
end

local function OnDisable()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
    end
end

MedaAuras:RegisterModule({
    name = MODULE_NAME,
    title = "Plater Integration",
    version = MODULE_VERSION,
    stability = MODULE_STABILITY,
    author = "Medalink",
    description = "Install and update managed Plater hooks from inside the shared MedaAuras settings shell.",
    sidebarDesc = "Manage bundled Plater hook installs without leaving MedaAuras.",
    defaults = {
        enabled = true,
    },
    OnInitialize = OnInitialize,
    OnEnable = OnEnable,
    OnDisable = OnDisable,
    pages = {
        { id = "settings", label = "Settings" },
    },
    buildPage = function(_, parent)
        return BuildSettingsPage(parent)
    end,
})
