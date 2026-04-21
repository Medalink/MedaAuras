local _, ns = ...

local R = ns.Reminders or {}
ns.Reminders = R

local S = R.state or {}
R.state = S

local MedaUI = LibStub("MedaUI-2.0")

local MODULE_NAME = R.MODULE_NAME
local MODULE_VERSION = R.MODULE_VERSION
local MODULE_STABILITY = R.MODULE_STABILITY
local MIN_DATA_VERSION = R.MIN_DATA_VERSION
local MAX_DATA_VERSION = R.MAX_DATA_VERSION
local CLASS_COLORS = R.CLASS_COLORS

local TANK_SPECS = R.TANK_SPECS
local HEALER_SPECS = R.HEALER_SPECS
local DPS_SPECS = R.DPS_SPECS
local ALL_CLASSES = R.ALL_CLASSES

local RunPipeline
local RequestInspectorRescan
local HandleRuntimeCaptureAuraUpdate

local function Log(...)
    return R.Log(...)
end

local function LogWarn(...)
    return R.LogWarn(...)
end

local function GetData(...)
    return R.GetData(...)
end

local function ShowCopyPopup(...)
    return R.ShowCopyPopup(...)
end

local function IsDataCompatible(...)
    return R.IsDataCompatible(...)
end

local function GetContextKey(...)
    return R.GetContextKey(...)
end

local function ResolveDungeonByName(...)
    return R.ResolveDungeonByName(...)
end

local function GetCurrentContext(...)
    return R.GetCurrentContext(...)
end

local function RefreshAffixes(...)
    return R.RefreshAffixes(...)
end

local function UpdateDetectedLabel(...)
    return R.UpdateDetectedLabel(...)
end

local function ReleaseRows(...)
    return R.ReleaseRows(...)
end

local function ReleaseSectionHeaders(...)
    return R.ReleaseSectionHeaders(...)
end

local function ReleaseTalentRows(...)
    return R.ReleaseTalentRows(...)
end

local function ReleaseTalentHeaders(...)
    return R.ReleaseTalentHeaders(...)
end

local function ReleasePrepRows(...)
    return R.ReleasePrepRows(...)
end

local function ReleasePrepHeaders(...)
    return R.ReleasePrepHeaders(...)
end

local function ReleasePlayerRows(...)
    return R.ReleasePlayerRows(...)
end

local function ReleasePlayerHeaders(...)
    return R.ReleasePlayerHeaders(...)
end

local function IsCapabilityEnabled(...)
    return R.IsCapabilityEnabled(...)
end

local function ResolveConditionKey(...)
    return R.ResolveConditionKey(...)
end

local function MergeOutput(...)
    return R.MergeOutput(...)
end

local function CheckPersonalReminder(...)
    return R.CheckPersonalReminder(...)
end

local function Evaluate(...)
    return R.Evaluate(...)
end

local function BuildContextDropdownItems(...)
    return R.BuildContextDropdownItems(...)
end

local function ParseContextSelection(...)
    return R.ParseContextSelection(...)
end

local function GetDefaultSpecForClassRole(...)
    return R.GetDefaultSpecForClassRole(...)
end

local function BuildRoleDropdownItems(...)
    return R.BuildRoleDropdownItems(...)
end

local function BuildClassDropdownItems(...)
    return R.BuildClassDropdownItems(...)
end

local function SyncViewerToolbar(...)
    return R.SyncViewerToolbar(...)
end

local function GetActivityKey(...)
    return R.GetActivityKey(...)
end

local function GetViewerProfile(...)
    return R.GetViewerProfile(...)
end

local function GetLivePlayerProfile(...)
    return R.GetLivePlayerProfile(...)
end

local function SetViewerState(...)
    return R.SetViewerState(...)
end

local function GetSpecMeta(...)
    return R.GetSpecMeta(...)
end

local function RenderCurrentPage(...)
    return R.RenderCurrentPage(...)
end

local function EvaluatePlayerToolkit(...)
    return R.EvaluatePlayerToolkit(...)
end

local function EnsureSpecRegistry(...)
    return R.EnsureSpecRegistry(...)
end

local function EnsurePersonalSchema(...)
    return R.EnsurePersonalSchema(...)
end

local function EnsureViewerState(...)
    return R.EnsureViewerState(...)
end
-- ============================================================================
-- Evaluation + render pipeline
-- ============================================================================

RunPipeline = function(clearDismiss)
    if not S.isEnabled then return end

    local ok, reason = IsDataCompatible()
    if not ok then return end

    EnsureSpecRegistry(GetData())
    EnsurePersonalSchema(GetData())
    EnsureViewerState()
    if S.uiState.viewer.mode == "live" then
        local live = GetLivePlayerProfile()
        if live then
            SetViewerState(live.classToken, live.role, live.specID, "live")
        end
    end

    if clearDismiss then
        local currentKey = GetContextKey(S.overrideContext or GetCurrentContext())
        if not S.dismissed or currentKey ~= S.dismissedContextKey then
            S.dismissed = false
            S.dismissedContextKey = nil
            if S.coveragePanel then
                S.coveragePanel:ClearDismissed()
            end
        end
    end

    RefreshAffixes()

    local results = Evaluate()
    S.lastResults = results

    -- Evaluate player toolkit for the "You" tab
    local data = GetData()
    local ctx = S.overrideContext or S.lastContext
    S.playerToolkit = EvaluatePlayerToolkit(data, ctx)

    if S.coveragePanel then
        S.coveragePanel:SetTitle("Reminders")
    end

    if S.uiState.workspaceShell then
        RenderCurrentPage()
    end

    if R.RefreshHUDs then
        R.RefreshHUDs()
    end

    -- Auto-show panel only when inside an instance (not in cities/open world)
    if S.db.autoShowInInstance ~= false and S.coveragePanel and not S.dismissed and S.lastContext and S.lastContext.inInstance then
        S.coveragePanel:Show()
        S.coveragePanel:Raise()
    end
end

RequestInspectorRescan = function()
    local GroupInspector = ns.Services.GroupInspector
    if GroupInspector then
        GroupInspector:RequestReinspectAll()
    end
    RunPipeline(false)
end

-- ============================================================================
-- Event handling
-- ============================================================================

local function OnEvent(_, event, arg1)
    if event == "UNIT_AURA" then
        HandleRuntimeCaptureAuraUpdate(arg1)
    elseif event == "PLAYER_ENTERING_WORLD" then
        UpdateDetectedLabel()
        RunPipeline(true)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        Log(format("Zone changed -- re-evaluating"))
        UpdateDetectedLabel()
        RunPipeline(true)
    elseif event == "GROUP_ROSTER_UPDATE" then
        RunPipeline(false)
    elseif event == "ACTIVE_DELVE_DATA_UPDATE" then
        Log("Delve data updated -- re-evaluating")
        UpdateDetectedLabel()
        RunPipeline(false)
    elseif event == "CHALLENGE_MODE_START" then
        Log("M+ key started -- re-evaluating")
        RefreshAffixes()
        UpdateDetectedLabel()
        RunPipeline(true)
    end
end

local function OnInspectorUpdate()
    RunPipeline(false)
end

-- ============================================================================
-- Runtime capture
-- ============================================================================

local CAPTURE_HISTORY_LIMIT = 32
local CAPTURE_TIMEOUT_S = 12
local CAPTURE_SETTLE_S = 1.5

local function EnsureRuntimeCaptureStore()
    S.db.runtimeCaptureBlocks = type(S.db.runtimeCaptureBlocks) == "table" and S.db.runtimeCaptureBlocks or {}
    S.db.runtimeCaptureNextID = tonumber(S.db.runtimeCaptureNextID) or 1
    return S.db.runtimeCaptureBlocks
end

local function FormatCaptureTimestamp(epochSeconds)
    local epoch = tonumber(epochSeconds) or time()
    return date("%Y-%m-%d %H:%M:%S", epoch)
end

local function BuildPlayerAuraSnapshot()
    local snapshot = {}

    for i = 1, 255 do
        local ok, aura = pcall(C_UnitAuras.GetBuffDataByIndex, "player", i)
        if not ok or not aura then
            break
        end

        local spellID = tonumber(aura.spellId or aura.spellID)
        local name = aura.name
        if spellID and spellID > 0 and type(name) == "string" and name ~= "" then
            snapshot[spellID] = {
                spellID = spellID,
                name = name,
            }
        end
    end

    return snapshot
end

local function GetCaptureContext(mode, explicitContext)
    local trimmed = type(explicitContext) == "string" and explicitContext:match("^%s*(.-)%s*$") or nil
    if trimmed and trimmed ~= "" then
        return trimmed
    end

    if mode == "unit" then
        if UnitExists("target") then
            local targetName = UnitName("target")
            if type(targetName) == "string" and targetName ~= "" then
                return targetName
            end
        end
        if UnitExists("mouseover") then
            local mouseoverName = UnitName("mouseover")
            if type(mouseoverName) == "string" and mouseoverName ~= "" then
                return mouseoverName
            end
        end
    end

    return nil
end

local function BuildCaptureBlock(session)
    local lines = {
        "=== MedaDebug Dungeon Object Capture ===",
        "Capture ID: " .. tostring(session.captureID or 0),
        "Status: " .. tostring(session.status or "unmatched"),
        "Confidence: " .. tostring(session.confidence or "low"),
        "Context: " .. tostring(session.context or ""),
        "Tooltip Type: " .. tostring(session.tooltipType or "object"),
        "Source: " .. tostring(session.source or "reminders-live"),
        "Timestamp: " .. tostring(session.timestampText or FormatCaptureTimestamp(session.startedAtEpoch)),
        "Instance: " .. format("%s (%s)", tostring(session.instanceName or "Unknown"), tostring(session.instanceID or 0)),
        "=== Outcomes ===",
    }

    if not session.outcomes or #session.outcomes == 0 then
        lines[#lines + 1] = "(no correlated outcomes)"
    else
        for index, outcome in ipairs(session.outcomes) do
            local delayText = outcome.delayS and format(" (%.2fs)", outcome.delayS) or ""
            lines[#lines + 1] = format(
                "%d. [aura] %s gained %s%s",
                index,
                tostring(outcome.unit or "player"),
                tostring(outcome.spellName or "Unknown"),
                delayText
            )
            if outcome.spellID then
                lines[#lines + 1] = "spellID: " .. tostring(outcome.spellID)
            end
            if outcome.unit then
                lines[#lines + 1] = "unit: " .. tostring(outcome.unit)
            end
        end
    end

    return table.concat(lines, "\n")
end

local function CopyRuntimeCaptureDump()
    local blocks = EnsureRuntimeCaptureStore()
    if #blocks == 0 then
        Log("No runtime capture blocks stored yet.")
        return
    end

    ShowCopyPopup(table.concat(blocks, "\n\n"), "Runtime Capture Dump")
end

local function ClearRuntimeCaptureDump()
    local blocks = EnsureRuntimeCaptureStore()
    wipe(blocks)
    S.db.runtimeCaptureNextID = 1
    Log("Cleared stored runtime capture blocks.")
end

local function FinalizeRuntimeCapture(reason)
    local session = S.runtimeCaptureSession
    if not session or session.finalized then
        return
    end

    session.finalized = true
    session.status = (#session.outcomes > 0) and "matched" or "unmatched"
    session.confidence = (#session.outcomes > 0) and "high" or "low"
    session.endReason = reason or "completed"

    local block = BuildCaptureBlock(session)
    local blocks = EnsureRuntimeCaptureStore()
    blocks[#blocks + 1] = block
    while #blocks > CAPTURE_HISTORY_LIMIT do
        table.remove(blocks, 1)
    end

    if session.status == "matched" then
        Log(format(
            "Runtime capture matched %s in %s with %d aura outcome(s). Use /mr capture copy to export.",
            tostring(session.context or "?"),
            tostring(session.instanceName or "?"),
            #session.outcomes
        ))
        ShowCopyPopup(table.concat(blocks, "\n\n"), "Runtime Capture Dump")
    else
        Log(format(
            "Runtime capture finished without a new aura for %s.",
            tostring(session.context or "?")
        ))
    end

    S.runtimeCaptureSession = nil
end

local function ScheduleRuntimeCaptureFinalize(delayS)
    local session = S.runtimeCaptureSession
    if not session then
        return
    end

    local token = session.token
    C_Timer.After(delayS, function()
        local current = S.runtimeCaptureSession
        if not current or current.token ~= token then
            return
        end
        if current.lastOutcomeAt and (GetTime() - current.lastOutcomeAt) < (delayS - 0.05) then
            return
        end
        FinalizeRuntimeCapture("settled")
    end)
end

local function StartRuntimeCapture(mode, explicitContext)
    if S.runtimeCaptureSession and not S.runtimeCaptureSession.finalized then
        Log("A runtime capture is already active. Use /mr capture stop before arming a new one.")
        return
    end

    local inInstance = IsInInstance()
    if not inInstance then
        Log("Runtime capture works only inside an instance.")
        return
    end

    local instanceName, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    if not instanceID then
        Log("Could not resolve the current instance ID.")
        return
    end

    local tooltipType = (mode == "object") and "object" or "unit"
    local context = GetCaptureContext(tooltipType, explicitContext)
    if not context then
        if tooltipType == "unit" then
            Log("Target or mouse over the recruiter first, or pass an explicit context label.")
        else
            Log("Provide an explicit object label, for example: /mr capture object Arcane Tome")
        end
        return
    end

    EnsureRuntimeCaptureStore()

    local captureID = S.db.runtimeCaptureNextID
    S.db.runtimeCaptureNextID = captureID + 1

    S.runtimeCaptureSession = {
        token = tostring(captureID) .. ":" .. tostring(time()),
        captureID = captureID,
        context = context,
        tooltipType = tooltipType,
        source = "reminders-live",
        instanceName = instanceName,
        instanceID = instanceID,
        startedAt = GetTime(),
        startedAtEpoch = time(),
        timestampText = FormatCaptureTimestamp(time()),
        baselineAuras = BuildPlayerAuraSnapshot(),
        observedSpellIDs = {},
        outcomes = {},
        status = "pending",
        confidence = "low",
        finalized = false,
        playerName = UnitName("player") or "player",
    }

    Log(format(
        "Runtime capture armed for %s [%s] in %s (%s). Interact now; capture will auto-finish after a new player aura appears.",
        context,
        tooltipType,
        tostring(instanceName),
        tostring(instanceID)
    ))

    local token = S.runtimeCaptureSession.token
    C_Timer.After(CAPTURE_TIMEOUT_S, function()
        local current = S.runtimeCaptureSession
        if not current or current.token ~= token then
            return
        end
        FinalizeRuntimeCapture("timeout")
    end)
end

HandleRuntimeCaptureAuraUpdate = function(unit)
    if unit ~= "player" then
        return
    end

    local session = S.runtimeCaptureSession
    if not session or session.finalized then
        return
    end

    local currentSnapshot = BuildPlayerAuraSnapshot()
    local added = false

    for spellID, aura in pairs(currentSnapshot) do
        if not session.baselineAuras[spellID] and not session.observedSpellIDs[spellID] then
            session.observedSpellIDs[spellID] = true
            session.outcomes[#session.outcomes + 1] = {
                kind = "aura",
                spellID = spellID,
                spellName = aura.name,
                unit = session.playerName or "player",
                delayS = math.max(0, GetTime() - (session.startedAt or GetTime())),
            }
            added = true
        end
    end

    if added then
        session.lastOutcomeAt = GetTime()
        ScheduleRuntimeCaptureFinalize(CAPTURE_SETTLE_S)
    end
end

local function HandleRuntimeCaptureCommand(args)
    local command, remainder = (args or ""):match("^(%S+)%s*(.*)$")
    command = command and command:lower() or ""

    if command == "" or command == "start" then
        StartRuntimeCapture("unit", remainder)
        return
    end

    if command == "unit" then
        StartRuntimeCapture("unit", remainder)
        return
    end

    if command == "object" then
        StartRuntimeCapture("object", remainder)
        return
    end

    if command == "stop" then
        if S.runtimeCaptureSession then
            FinalizeRuntimeCapture("manual_stop")
        else
            Log("No active runtime capture.")
        end
        return
    end

    if command == "copy" then
        CopyRuntimeCaptureDump()
        return
    end

    if command == "clear" then
        ClearRuntimeCaptureDump()
        return
    end

    if command == "status" then
        local blocks = EnsureRuntimeCaptureStore()
        if S.runtimeCaptureSession then
            Log(format(
                "Active runtime capture: %s [%s] in %s (%s). Stored blocks: %d.",
                tostring(S.runtimeCaptureSession.context or "?"),
                tostring(S.runtimeCaptureSession.tooltipType or "?"),
                tostring(S.runtimeCaptureSession.instanceName or "?"),
                tostring(S.runtimeCaptureSession.instanceID or "?"),
                #blocks
            ))
        else
            Log(format("No active runtime capture. Stored blocks: %d.", #blocks))
        end
        return
    end

    Log("Usage: /mr capture [start|unit|object <label>|stop|copy|clear|status]")
end

-- ============================================================================
-- UI creation
-- ============================================================================

local function CreateUI()
    if S.coveragePanel then return end

    if MedaUI and MedaUI.SetTheme and MedaAurasDB and MedaAurasDB.options and MedaAurasDB.options.theme then
        local desiredTheme = MedaAurasDB.options.theme
        if MedaUI.GetActiveThemeName and MedaUI:GetActiveThemeName() ~= desiredTheme then
            MedaUI:SetTheme(desiredTheme)
        end
    end

    -- Coverage panel
    S.coveragePanel = MedaUI:CreateInfoPanel("MedaAurasRemindersPanel", {
        width       = S.db.panelWidth or 1120,
        height      = S.db.panelHeight or 720,
        title       = "Reminders",
        icon        = 134063,
        strata      = "DIALOG",
        dismissable = true,
        locked      = S.db.locked or false,
    })
    S.coveragePanel:SetToplevel(true)
    S.coveragePanel:Raise()
    if S.coveragePanel.EnableKeyboard then
        S.coveragePanel:EnableKeyboard(true)
    end
    if S.coveragePanel.SetPropagateKeyboardInput then
        S.coveragePanel:SetPropagateKeyboardInput(true)
    end
    local function HandleCoveragePanelKeyDown(self, key)
        if self.SetPropagateKeyboardInput then
            self:SetPropagateKeyboardInput(key ~= "ESCAPE")
        end
        if key == "ESCAPE" and self.IsShown and self:IsShown() and self.Dismiss then
            self:Dismiss()
        end
    end
    if S.coveragePanel.HookScript then
        S.coveragePanel:HookScript("OnKeyDown", HandleCoveragePanelKeyDown)
    elseif S.coveragePanel.SetScript then
        S.coveragePanel:SetScript("OnKeyDown", HandleCoveragePanelKeyDown)
    end

    S.coveragePanel.OnDismiss = function()
        S.dismissed = true
        S.dismissedContextKey = GetContextKey(S.lastContext)
        Log("Panel S.dismissed by user")
    end

    S.coveragePanel.OnMove = function(self)
        S.db.panelPoint = self:SavePosition()
    end

    if S.db.panelPoint then
        S.coveragePanel:RestorePosition(S.db.panelPoint)
    else
        S.coveragePanel:SetPoint("RIGHT", UIParent, "RIGHT", -50, 0)
    end

    S.coveragePanel:SetBackgroundOpacity(S.db.backgroundOpacity or 0.85)

    S.coveragePanel:SetResizable(true, {
        minWidth  = 920,
        minHeight = 500,
    })
    S.coveragePanel.OnResize = function(self, w, h)
        S.db.panelWidth = math.floor(w)
        S.db.panelHeight = math.floor(h)
        if S.uiState.workspaceShell and S.uiState.workspaceShell.RefreshNavigation then
            S.uiState.workspaceShell:RefreshNavigation()
        end
        RunPipeline(false)
    end

    if S.coveragePanel.scrollParent then S.coveragePanel.scrollParent:Hide() end
    if S.coveragePanel.footer then S.coveragePanel.footer:Hide() end
    if S.coveragePanel.statusBar then S.coveragePanel.statusBar:Hide() end

    S.uiState.workspaceShell = MedaUI:CreateWorkspaceHost(S.coveragePanel, {
        toolbarWidth = 900,
        headerTextRightGap = 920,
    })
    S.uiState.workspaceShell:SetPoint("TOPLEFT", S.coveragePanel, "TOPLEFT", 8, -38)
    S.uiState.workspaceShell:SetPoint("BOTTOMRIGHT", S.coveragePanel, "BOTTOMRIGHT", -8, 8)
    S.uiState.workspaceShell.OnNavigate = function(_, pageId)
        S.uiState.selectedPage = pageId
        RenderCurrentPage()
    end
    S.uiState.workspaceShell.OnGroupToggle = function(_, groupId, expanded)
        if groupId == "nav_delves" then
            S.uiState.navExpanded.delves = expanded
        elseif groupId == "nav_dungeons" then
            S.uiState.navExpanded.dungeons = expanded
        elseif groupId == "nav_raids" then
            S.uiState.navExpanded.raids = expanded
        end
    end

    local toolbar = S.uiState.workspaceShell:GetToolbar()
    S.uiState.toolbar = {}

    local liveResetButton = MedaUI:CreateButton(toolbar, "Use My Spec", 110)
    liveResetButton:SetPoint("TOPLEFT", toolbar, "TOPLEFT", 0, 0)
    liveResetButton.OnClick = function()
        local live = GetLivePlayerProfile()
        if not live then return end
        SetViewerState(live.classToken, live.role, live.specID, "live")
        SyncViewerToolbar()
        RunPipeline(false)
    end
    liveResetButton:Hide()
    S.uiState.toolbar.liveResetButton = liveResetButton

    local rescanButton = MedaUI:CreateButton(toolbar, "Rescan Group", 110)
    rescanButton:SetPoint("LEFT", liveResetButton, "RIGHT", 8, 0)
    rescanButton.OnClick = function()
        RequestInspectorRescan()
    end
    S.uiState.toolbar.rescanButton = rescanButton

    local contextDropdown = MedaUI:CreateDropdown(toolbar, 220, BuildContextDropdownItems())
    contextDropdown:SetPoint("TOPRIGHT", toolbar, "TOPRIGHT", 0, 0)
    contextDropdown.OnValueChanged = function(_, val)
        if S.uiState.suppressToolbarCallbacks then return end
        if val and val:match("^_hdr_") then return end
        S.overrideContext = ParseContextSelection(val)
        S.uiState.selectedPage = "personal"
        RunPipeline(false)
    end
    S.uiState.toolbar.contextDropdown = contextDropdown

    local classDropdown = MedaUI:CreateDropdown(toolbar, 150, BuildClassDropdownItems())
    classDropdown:SetPoint("RIGHT", contextDropdown, "LEFT", -8, 0)
    classDropdown.OnValueChanged = function(_, classToken)
        if S.uiState.suppressToolbarCallbacks then return end
        if not classToken then return end
        local currentRole = S.uiState.viewer.role
        local spec = GetDefaultSpecForClassRole(classToken, currentRole) or GetDefaultSpecForClassRole(classToken)
        if not spec then return end
        SetViewerState(classToken, spec.role, spec.specID)
        SyncViewerToolbar()
        RunPipeline(false)
    end
    S.uiState.toolbar.classDropdown = classDropdown

    local roleDropdown = MedaUI:CreateDropdown(toolbar, 110, BuildRoleDropdownItems((GetLivePlayerProfile() or {}).classToken))
    roleDropdown:SetPoint("RIGHT", classDropdown, "LEFT", -8, 0)
    roleDropdown.OnValueChanged = function(_, role)
        if S.uiState.suppressToolbarCallbacks then return end
        if not role then return end
        local viewer = GetViewerProfile()
        local spec = GetDefaultSpecForClassRole(viewer and viewer.classToken, role)
        if not spec then return end
        SetViewerState(spec.classToken, role, spec.specID)
        SyncViewerToolbar()
        RunPipeline(false)
    end
    S.uiState.toolbar.roleDropdown = roleDropdown

    local specDropdown = MedaUI:CreateDropdown(toolbar, 140, {})
    specDropdown:SetPoint("RIGHT", roleDropdown, "LEFT", -8, 0)
    specDropdown.OnValueChanged = function(_, specID)
        if S.uiState.suppressToolbarCallbacks then return end
        if not specID then return end
        local viewer = GetViewerProfile()
        local specMeta = GetSpecMeta(specID, viewer and viewer.classToken)
        SetViewerState(viewer and viewer.classToken, specMeta.role, specID)
        SyncViewerToolbar()
        RunPipeline(false)
    end
    S.uiState.toolbar.specDropdown = specDropdown

    S.uiState.suppressToolbarCallbacks = true
    if S.overrideContext then
        local ctxSelection = nil
        local activity = GetActivityKey(S.overrideContext)
        if activity == "dungeon" and S.overrideContext.instanceID then
            ctxSelection = "dungeon:" .. S.overrideContext.instanceID
        elseif activity == "raid" and S.overrideContext.raidKey then
            ctxSelection = "raid:" .. S.overrideContext.raidKey
        elseif activity == "delve" and S.overrideContext.instanceName then
            for i, delve in ipairs((GetData() and GetData().contexts and GetData().contexts.delves) or {}) do
                if delve.name == S.overrideContext.instanceName then
                    ctxSelection = "delve:" .. i
                    break
                end
            end
        elseif S.overrideContext.instanceType then
            ctxSelection = "type:" .. S.overrideContext.instanceType
        end
        contextDropdown:SetSelected(ctxSelection or "auto")
    else
        contextDropdown:SetSelected("auto")
    end
    SyncViewerToolbar()
    S.uiState.suppressToolbarCallbacks = false

    -- Minimap button
    S.minimapButton = MedaUI:CreateMinimapButton(
        "MedaAurasReminders",
        134063,
        function()
            if S.coveragePanel then
                if S.coveragePanel:IsShown() then
                    S.coveragePanel:Dismiss()
                else
                    S.dismissed = false
                    S.coveragePanel:ClearDismissed()
                    RunPipeline(false)
                    S.coveragePanel:Show()
                    S.coveragePanel:Raise()
                    Log("Panel toggled via minimap button")
                end
            end
        end,
        function()
            if MedaAuras.ToggleSettings then
                MedaAuras:ToggleSettings()
            end
        end
    )

    if S.minimapButton and S.db.showMinimapButton == false then
        S.minimapButton.HideButton()
    end
end

-- ============================================================================
-- Module lifecycle
-- ============================================================================

local function StartModule()
    local ok, reason = IsDataCompatible()
    if not ok then
        if reason == "too_old" then
            local data = GetData()
            LogWarn(format("Data version %s is too old (need >= %d). Re-run the scraper.",
                tostring(data and data.dataVersion), MIN_DATA_VERSION))
        elseif reason == "too_new" then
            local data = GetData()
            LogWarn(format("Data version %s is newer than supported (max %d). Update MedaAuras.",
                tostring(data and data.dataVersion), MAX_DATA_VERSION))
        end
        return
    end

    S.isEnabled = true
    CreateUI()

    if not S.eventFrame then
        S.eventFrame = CreateFrame("Frame")
    end
    S.eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    S.eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    S.eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    S.eventFrame:RegisterEvent("ACTIVE_DELVE_DATA_UPDATE")
    S.eventFrame:RegisterEvent("CHALLENGE_MODE_START")
    S.eventFrame:RegisterEvent("UNIT_AURA")
    S.eventFrame:SetScript("OnEvent", OnEvent)

    local GroupInspector = ns.Services.GroupInspector
    if GroupInspector then
        if GroupInspector.Initialize then
            GroupInspector:Initialize()
        end
        GroupInspector:RegisterCallback("Reminders", OnInspectorUpdate)
    end

    Log("Module enabled")
    RunPipeline(true)
end

local function StopModule()
    S.isEnabled = false

    if S.eventFrame then
        S.eventFrame:UnregisterAllEvents()
        S.eventFrame:SetScript("OnEvent", nil)
    end

    local GroupInspector = ns.Services.GroupInspector
    if GroupInspector then
        GroupInspector:UnregisterCallback("Reminders")
    end

    if S.coveragePanel then S.coveragePanel:Hide() end
    if S.copyPopup then S.copyPopup:Hide() end
    if R.HideHUDs then R.HideHUDs() end

    ReleaseRows()
    ReleaseSectionHeaders()
    ReleaseTalentRows()
    ReleaseTalentHeaders()
    ReleasePrepRows()
    ReleasePrepHeaders()
    ReleasePlayerRows()
    ReleasePlayerHeaders()
    wipe(S.playerSectionExpanded)
    S.playerSectionLastCtxKey = nil
    S.currentAffixes = nil
    S.playerToolkit = nil
    S.runtimeCaptureSession = nil

    Log("Module disabled")
end

local function OnInitialize(moduleDB)
    S.db = moduleDB
    if R.EnsureHUDDB then R.EnsureHUDDB(S.db) end

    if not S.db._sizeMigrated then
        if (S.db.panelWidth or 0) <= 440 then S.db.panelWidth = 920 end
        if (S.db.panelHeight or 0) <= 520 then S.db.panelHeight = 720 end
        S.db._sizeMigrated = true
    end

    if not S.db._sizeMigrated2 then
        if (S.db.panelWidth or 0) <= 520 then S.db.panelWidth = 920 end
        if (S.db.panelHeight or 0) <= 620 then S.db.panelHeight = 720 end
        S.db._sizeMigrated2 = true
    end

    if not S.db._sizeMigrated3 then
        if (S.db.panelWidth or 0) <= 920 then S.db.panelWidth = 1120 end
        if (S.db.panelHeight or 0) <= 620 then S.db.panelHeight = 720 end
        S.db._sizeMigrated3 = true
    end
end

local function OnEnable(moduleDB)
    S.db = moduleDB
    if R.EnsureHUDDB then R.EnsureHUDDB(S.db) end
    StartModule()
end

local function OnDisable(moduleDB)
    S.db = moduleDB
    StopModule()
end

-- ============================================================================
-- Preview / test mode
-- ============================================================================


local PREVIEW_NAMES = {
    "Tankyboi", "Healmaster", "Pewpew", "Stabsworth", "Dotlord",
    "Moonfrost", "Shadowbeam", "Flamestrike", "Naturecall", "Holybubble",
    "Ragesmash", "Sneakydagger", "Totemslam", "Beastcaller", "Voidwhisper",
}

local function ShuffleInPlace(t)
    for i = #t, 2, -1 do
        local j = math.random(1, i)
        t[i], t[j] = t[j], t[i]
    end
end

local function PickOneFrom(val)
    if type(val) == "table" then return val[math.random(1, #val)] end
    return val
end

local function GeneratePreviewGroup()
    local _, playerClass = UnitClass("player")
    local playerSpec
    local specIdx = GetSpecialization()
    if specIdx then playerSpec = GetSpecializationInfo(specIdx) end

    local playerIsTank = TANK_SPECS[playerClass] and playerSpec == TANK_SPECS[playerClass]
    local playerIsHealer = false
    if HEALER_SPECS[playerClass] then
        local hs = HEALER_SPECS[playerClass]
        if type(hs) == "table" then
            for _, s in ipairs(hs) do
                if playerSpec == s then playerIsHealer = true; break end
            end
        else
            playerIsHealer = playerSpec == hs
        end
    end

    local usedClasses = { [playerClass] = true }
    local group = {
        { name = UnitName("player") or "You", class = playerClass, specID = playerSpec },
    }

    local namePool = {}
    for _, n in ipairs(PREVIEW_NAMES) do namePool[#namePool + 1] = n end
    ShuffleInPlace(namePool)
    local nameIdx = 0
    local function nextName()
        nameIdx = nameIdx + 1
        return namePool[nameIdx] or ("Player" .. nameIdx)
    end

    local function pickClassForRole(roleMap)
        local candidates = {}
        for cls in pairs(roleMap) do
            if not usedClasses[cls] then candidates[#candidates + 1] = cls end
        end
        if #candidates == 0 then return nil end
        ShuffleInPlace(candidates)
        return candidates[1]
    end

    if not playerIsTank then
        local cls = pickClassForRole(TANK_SPECS)
        if cls then
            usedClasses[cls] = true
            group[#group + 1] = { name = nextName(), class = cls, specID = TANK_SPECS[cls] }
        end
    end

    if not playerIsHealer then
        local cls = pickClassForRole(HEALER_SPECS)
        if cls then
            usedClasses[cls] = true
            group[#group + 1] = { name = nextName(), class = cls, specID = PickOneFrom(HEALER_SPECS[cls]) }
        end
    end

    local dpsPool = {}
    for _, token in ipairs(ALL_CLASSES) do
        if not usedClasses[token] and DPS_SPECS[token] then
            dpsPool[#dpsPool + 1] = token
        end
    end
    ShuffleInPlace(dpsPool)

    local remaining = 5 - #group
    for i = 1, remaining do
        local cls = dpsPool[i]
        if not cls then break end
        usedClasses[cls] = true
        local specs = DPS_SPECS[cls]
        group[#group + 1] = { name = nextName(), class = cls, specID = PickOneFrom(specs) }
    end

    return group
end

local function QueryProvidersPreview(providersList, fakeGroup)
    if not providersList then return {} end
    local results = {}
    for _, member in ipairs(fakeGroup) do
        for _, provider in ipairs(providersList) do
            if member.class == provider.class then
                local specMatch = (provider.specID == nil) or (member.specID == provider.specID)
                if specMatch then
                    results[#results + 1] = {
                        unit      = "player",
                        name      = member.name,
                        class     = member.class,
                        specID    = member.specID,
                        spellID   = provider.spellID,
                        spellName = provider.spellName,
                        note      = provider.note,
                        icon      = provider.icon,
                        rangeText = provider.rangeText,
                        castTimeMS = provider.castTimeMS,
                        cooldownMS = provider.cooldownMS,
                        dispelTargets = provider.dispelTargets,
                    }
                end
            end
        end
    end
    return results
end

local function EvaluatePreview(fakeGroup)
    local data = GetData()
    if not data then return {} end

    local results = {}
    local seenCapabilities = {}

    for _, rule in ipairs(data.rules) do
        for _, check in ipairs(rule.checks or {}) do
            local capID = check.capability
            if not seenCapabilities[capID] then
                local capability = data.capabilities[capID]
                if capability and IsCapabilityEnabled(capability) then
                    seenCapabilities[capID] = true

                    local matches = QueryProvidersPreview(capability.providers, fakeGroup)
                    local matchCount = #matches
                    local conditionKey = ResolveConditionKey(capability, matchCount)
                    local output = MergeOutput(capability, check, conditionKey)
                    local personal = CheckPersonalReminder(capability)

                    results[#results + 1] = {
                        capabilityID = capID,
                        capability   = capability,
                        matchCount   = matchCount,
                        matches      = matches,
                        conditionKey = conditionKey,
                        output       = output,
                        personal     = personal,
                    }
                end
            end
        end
    end

    return results
end

local function RunPreview()
    local ok, reason = IsDataCompatible()
    if not ok then
        Log("Cannot preview: data " .. (reason or "issue"))
        return
    end

    if not S.coveragePanel then CreateUI() end

    local fakeGroup = GeneratePreviewGroup()

    local groupDesc = {}
    for _, m in ipairs(fakeGroup) do
        local cc = CLASS_COLORS[m.class]
        local hex = cc and format("%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255) or "ffffff"
        groupDesc[#groupDesc + 1] = format("|cff%s%s|r", hex, m.name)
    end
    Log(format("Preview group: %s", table.concat(groupDesc, ", ")))

    S.lastContext = { inInstance = true, instanceType = "party", instanceID = nil, instanceName = "Preview" }
    local results = EvaluatePreview(fakeGroup)
    S.lastResults = results
    S.playerToolkit = EvaluatePlayerToolkit(GetData(), S.lastContext)

    S.dismissed = false
    if S.coveragePanel then S.coveragePanel:ClearDismissed() end
    S.uiState.selectedPage = "dungeon_group"
    if S.coveragePanel then
        S.coveragePanel:SetTitle("Reminders (Preview)")
        S.coveragePanel:Show()
        S.coveragePanel:Raise()
    end
    if S.uiState.workspaceShell then
        RenderCurrentPage()
    end
    if R.RefreshHUDs then
        R.RefreshHUDs()
    end
end

-- ============================================================================
-- Settings UI
-- ============================================================================

local function BuildTrackingPage(parent, moduleDB)
    local LEFT_X, RIGHT_X = 0, 238
    S.db = moduleDB
    local yOff = 0

    local genHdr = MedaUI:CreateSectionHeader(parent, "General")
    genHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 34

    local mmCb = MedaUI:CreateCheckbox(parent, "Show minimap button")
    mmCb:SetChecked(S.db.showMinimapButton ~= false)
    mmCb.OnValueChanged = function(_, val)
        S.db.showMinimapButton = val
        if S.minimapButton then
            if val then S.minimapButton.ShowButton() else S.minimapButton.HideButton() end
        end
    end
    mmCb:SetPoint("TOPLEFT", LEFT_X, yOff)
    local lockCb = MedaUI:CreateCheckbox(parent, "Lock panel position")
    lockCb:SetChecked(S.db.locked or false)
    lockCb.OnValueChanged = function(_, val)
        S.db.locked = val
        if S.coveragePanel then S.coveragePanel:SetLocked(val) end
    end
    lockCb:SetPoint("TOPLEFT", RIGHT_X, yOff)
    yOff = yOff - 28

    local autoShowCb = MedaUI:CreateCheckbox(parent, "Auto-show on instance entrance")
    autoShowCb:SetChecked(S.db.autoShowInInstance ~= false)
    autoShowCb.OnValueChanged = function(_, val) S.db.autoShowInInstance = val end
    autoShowCb:SetPoint("TOPLEFT", LEFT_X, yOff)
    local rescanBtn = MedaUI:CreateButton(parent, "Rescan Group Cache", 180)
    rescanBtn:SetPoint("TOPLEFT", RIGHT_X, yOff - 4)
    rescanBtn.OnClick = RequestInspectorRescan
    yOff = yOff - 34

    local talHdr = MedaUI:CreateSectionHeader(parent, "Talent")
    talHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 34

    local prCb = MedaUI:CreateCheckbox(parent, "Show personal talent reminders")
    prCb:SetChecked(S.db.personalReminders ~= false)
    prCb.OnValueChanged = function(_, val) S.db.personalReminders = val; RunPipeline(false) end
    prCb:SetPoint("TOPLEFT", LEFT_X, yOff)
    local talUtilCb = MedaUI:CreateCheckbox(parent, "Track utility talents")
    talUtilCb:SetChecked(S.db.tag_utility ~= false)
    talUtilCb.OnValueChanged = function(_, val) S.db.tag_utility = val; RunPipeline(false) end
    talUtilCb:SetPoint("TOPLEFT", RIGHT_X, yOff)
    yOff = yOff - 34

    local debuffHdr = MedaUI:CreateSectionHeader(parent, "Debuff")
    debuffHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 34

    local dispelMasterCb = MedaUI:CreateCheckbox(parent, "Track dispel coverage")
    dispelMasterCb:SetChecked(S.db.tag_dispel ~= false)
    dispelMasterCb.OnValueChanged = function(_, val) S.db.tag_dispel = val; RunPipeline(false) end
    dispelMasterCb:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 28

    local curseCb = MedaUI:CreateCheckbox(parent, "Curse removal")
    curseCb:SetChecked(S.db.tag_curse ~= false)
    curseCb.OnValueChanged = function(_, val) S.db.tag_curse = val; RunPipeline(false) end
    curseCb:SetPoint("TOPLEFT", LEFT_X + 16, yOff)
    local poisonCb = MedaUI:CreateCheckbox(parent, "Poison removal")
    poisonCb:SetChecked(S.db.tag_poison ~= false)
    poisonCb.OnValueChanged = function(_, val) S.db.tag_poison = val; RunPipeline(false) end
    poisonCb:SetPoint("TOPLEFT", RIGHT_X, yOff)
    yOff = yOff - 28

    local diseaseCb = MedaUI:CreateCheckbox(parent, "Disease removal")
    diseaseCb:SetChecked(S.db.tag_disease ~= false)
    diseaseCb.OnValueChanged = function(_, val) S.db.tag_disease = val; RunPipeline(false) end
    diseaseCb:SetPoint("TOPLEFT", LEFT_X + 16, yOff)
    local magicCb = MedaUI:CreateCheckbox(parent, "Magic removal")
    magicCb:SetChecked(S.db.tag_magic ~= false)
    magicCb.OnValueChanged = function(_, val) S.db.tag_magic = val; RunPipeline(false) end
    magicCb:SetPoint("TOPLEFT", RIGHT_X, yOff)
    yOff = yOff - 34

    local diHdr = MedaUI:CreateSectionHeader(parent, "Dungeon Info")
    diHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 34

    local intCb = MedaUI:CreateCheckbox(parent, "Show interrupt priorities")
    intCb:SetChecked(S.db.showInterrupts ~= false)
    intCb.OnValueChanged = function(_, val) S.db.showInterrupts = val; RunPipeline(false) end
    intCb:SetPoint("TOPLEFT", LEFT_X, yOff)
    local affCb = MedaUI:CreateCheckbox(parent, "Show affix tips")
    affCb:SetChecked(S.db.showAffixTips ~= false)
    affCb.OnValueChanged = function(_, val) S.db.showAffixTips = val; RunPipeline(false) end
    affCb:SetPoint("TOPLEFT", RIGHT_X, yOff)
    yOff = yOff - 28

    local timerCb = MedaUI:CreateCheckbox(parent, "Show dungeon timers")
    timerCb:SetChecked(S.db.showDungeonTimers ~= false)
    timerCb.OnValueChanged = function(_, val) S.db.showDungeonTimers = val; RunPipeline(false) end
    timerCb:SetPoint("TOPLEFT", LEFT_X + 16, yOff)

    return 500
end

local function BuildSourcesPage(parent, moduleDB)
    local LEFT_X = 0
    local Theme = MedaUI.Theme
    S.db = moduleDB

    local yOff = 0
    local srcHdr = MedaUI:CreateSectionHeader(parent, "Sources")
    srcHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 34

    local srcDesc = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    srcDesc:SetPoint("TOPLEFT", LEFT_X, yOff)
    srcDesc:SetPoint("RIGHT", parent, "RIGHT", -4, 0)
    srcDesc:SetJustifyH("LEFT")
    srcDesc:SetWordWrap(true)
    srcDesc:SetTextColor(unpack(Theme.textDim or {0.6, 0.6, 0.6}))
    srcDesc:SetText("Choose which data sources provide recommendations. At least one must be active.")
    yOff = yOff - srcDesc:GetStringHeight() - 8

    if not S.db.sources then S.db.sources = {} end

    local configData = GetData()
    local sourceKeys = {}
    if configData and configData.sources then
        for key, src in pairs(configData.sources) do
            sourceKeys[#sourceKeys + 1] = { key = key, label = src.label }
        end
        table.sort(sourceKeys, function(a, b) return a.label < b.label end)
    end

    local function CountActiveSources()
        local count = 0
        for _, sk in ipairs(sourceKeys) do
            if S.db.sources[sk.key] ~= false then count = count + 1 end
        end
        return count
    end

    for _, sk in ipairs(sourceKeys) do
        local srcMeta = configData.sources[sk.key]
        local cbLabel = srcMeta and srcMeta.url and format("%s  |cff888888(%s)|r", sk.label, srcMeta.url) or sk.label
        local sCb = MedaUI:CreateCheckbox(parent, cbLabel)
        sCb:SetChecked(S.db.sources[sk.key] ~= false)
        sCb.OnValueChanged = function(_, val)
            if not val and CountActiveSources() <= 1 then
                sCb:SetChecked(true)
                return
            end
            S.db.sources[sk.key] = val
            RunPipeline(false)
        end
        sCb:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 28
    end

    return 500
end

local function BuildAppearancePage(parent, moduleDB)
    local LEFT_X, RIGHT_X = 0, 238
    local Theme = MedaUI.Theme
    S.db = moduleDB

    local yOff = 0
    local themeHdr = MedaUI:CreateSectionHeader(parent, "Theme")
    themeHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 34

    local bgCb = MedaUI:CreateCheckbox(parent, "Show panel background")
    bgCb:SetChecked(S.db.showBackground ~= false)
    bgCb:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 28

    local bgLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bgLabel:SetPoint("TOPLEFT", LEFT_X + 16, yOff)
    bgLabel:SetText("Background opacity:")
    bgLabel:SetTextColor(unpack(Theme.text))
    yOff = yOff - 18

    local bgSlider = MedaUI:CreateSlider(parent, 200, 0.1, 1.0, 0.05)
    bgSlider:SetValue(S.db.showBackground and (S.db.backgroundOpacity > 0 and S.db.backgroundOpacity or 0.8) or 0.8)
    bgSlider:SetPoint("TOPLEFT", LEFT_X + 16, yOff)
    bgSlider.OnValueChanged = function(_, val)
        if S.db.showBackground then
            S.db.backgroundOpacity = val
            if S.coveragePanel then S.coveragePanel:SetBackgroundOpacity(val) end
        end
    end

    bgCb.OnValueChanged = function(_, val)
        S.db.showBackground = val
        if val then
            local opacity = bgSlider:GetValue()
            S.db.backgroundOpacity = opacity
            bgSlider:Show()
            bgLabel:Show()
        else
            S.db.backgroundOpacity = 0
            bgSlider:Hide()
            bgLabel:Hide()
        end
        if S.coveragePanel then S.coveragePanel:SetBackgroundOpacity(S.db.backgroundOpacity) end
    end
    if not S.db.showBackground then bgSlider:Hide(); bgLabel:Hide() end
    yOff = yOff - 48

    local shellHdr = MedaUI:CreateSectionHeader(parent, "Workspace")
    shellHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 34

    local shellDesc = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    shellDesc:SetPoint("TOPLEFT", LEFT_X, yOff)
    shellDesc:SetPoint("RIGHT", parent, "RIGHT", -4, 0)
    shellDesc:SetJustifyH("LEFT")
    shellDesc:SetWordWrap(true)
    shellDesc:SetTextColor(unpack(Theme.textDim or { 0.6, 0.6, 0.6 }))
    shellDesc:SetText("The new reminders window keeps navigation, activity selection, and source freshness pinned in the chrome at all times.")
    yOff = yOff - shellDesc:GetStringHeight() - 14

    local actionsHdr = MedaUI:CreateSectionHeader(parent, "Actions")
    actionsHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 34

    local resetPanelBtn = MedaUI:CreateButton(parent, "Reset panel position", 160)
    resetPanelBtn:SetPoint("TOPLEFT", LEFT_X, yOff)
    resetPanelBtn.OnClick = function()
        if S.coveragePanel then
            S.coveragePanel:ClearAllPoints()
            S.coveragePanel:SetPoint("RIGHT", UIParent, "RIGHT", -50, 0)
            S.coveragePanel:SetSize(1120, 720)
            S.db.panelPoint = nil
            S.db.panelWidth = 1120
            S.db.panelHeight = 720
        end
    end

    local openBtn = MedaUI:CreateButton(parent, "Open Reminders", 160)
    openBtn:SetPoint("TOPLEFT", RIGHT_X, yOff)
    openBtn.OnClick = function()
        S.dismissed = false
        if S.coveragePanel then
            S.coveragePanel:ClearDismissed()
            RunPipeline(false)
            S.coveragePanel:Show()
            S.coveragePanel:Raise()
        end
    end

    return 500
end

local function ShouldAutoPreviewSettingsPage()
    if not S.coveragePanel then
        return true
    end

    if S.coveragePanel:IsShown() then
        return true
    end

    return not S.dismissed
end

local function IsHUDSettingsPage(pageName)
    return pageName == "dispelhud"
        or pageName == "interrupthud"
        or pageName == "bosstipshud"
        or pageName == "tipsandtrickshud"
end

local function RefreshSettingsPreview(pageName)
    if ShouldAutoPreviewSettingsPage() then
        RunPreview()
        return
    end

    if IsHUDSettingsPage(pageName) and R.RefreshHUDs then
        R.RefreshHUDs()
    end
end

function R.IsHUDSettingsPreviewActive(kind)
    local activeModuleId, activePageId = nil, nil
    if MedaAuras.GetActiveSettingsSelection then
        activeModuleId, activePageId = MedaAuras:GetActiveSettingsSelection()
    end
    if not activeModuleId then
        return false
    end

    if activeModuleId ~= MODULE_NAME then
        return false
    end

    if kind == "dispel" then
        return activePageId == "dispelhud"
    elseif kind == "interrupt" then
        return activePageId == "interrupthud"
    elseif kind == "boss" then
        return activePageId == "bosstipshud"
    elseif kind == "tricks" then
        return activePageId == "tipsandtrickshud"
    end

    return false
end

local function BuildPage(pageName, parent)
    local moduleDB = S.db or MedaAuras:GetModuleDB(MODULE_NAME)
    local height = 500
    if pageName == "tracking" then
        height = BuildTrackingPage(parent, moduleDB)
    elseif pageName == "sources" then
        height = BuildSourcesPage(parent, moduleDB)
    elseif pageName == "appearance" then
        height = BuildAppearancePage(parent, moduleDB)
    elseif pageName == "dispelhud" and R.BuildHUDSettingsTab then
        height = R.BuildHUDSettingsTab(parent, moduleDB, "dispel")
    elseif pageName == "interrupthud" and R.BuildHUDSettingsTab then
        height = R.BuildHUDSettingsTab(parent, moduleDB, "interrupt")
    elseif pageName == "bosstipshud" and R.BuildHUDSettingsTab then
        height = R.BuildHUDSettingsTab(parent, moduleDB, "boss")
    elseif pageName == "tipsandtrickshud" and R.BuildHUDSettingsTab then
        height = R.BuildHUDSettingsTab(parent, moduleDB, "tricks")
    end
    RefreshSettingsPreview(pageName)
    return height
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

local slashCommands = {
    show = function()
        if S.coveragePanel then
            S.dismissed = false
            S.coveragePanel:ClearDismissed()
            RunPipeline(false)
            S.coveragePanel:Show()
            S.coveragePanel:Raise()
        end
    end,
    hide = function()
        if S.coveragePanel then S.coveragePanel:Dismiss() end
    end,
    debug = function()
        S.debugMode = not S.debugMode
        Log(format("Debug mode: %s", S.debugMode and "ON" or "OFF"))
    end,
    refresh = function()
        local GroupInspector = ns.Services.GroupInspector
        if GroupInspector then
            GroupInspector:RequestReinspectAll()
        end
        RunPipeline(true)
    end,
    preview = function()
        RunPreview()
    end,
    instanceinfo = function()
        local inInstance = IsInInstance()
        if not inInstance then
            Log("Not currently in an instance. Zone into a dungeon or delve first.")
            return
        end
        local name, instType, diffID, diffName, maxPlayers, dynDiff, isDyn, instID = GetInstanceInfo()
        Log(format("Instance: %s | type: %s | ID: %s | diff: %s (%s) | max: %s",
            tostring(name), tostring(instType), tostring(instID),
            tostring(diffID), tostring(diffName), tostring(maxPlayers)))

        local data = GetData()
        local known = data and data.contexts and data.contexts.dungeons and data.contexts.dungeons[instID]
        if known then
            Log(format("  -> Matched data entry: %s (ID %d)", known.name, instID))
        else
            local resolved = ResolveDungeonByName(name)
            if resolved then
                Log(format("  -> ID not in data, but name '%s' resolved to data ID %d", name, resolved))
                Log(format("  -> Update dungeons.json in knowledge base: change instanceID from %d to %d", resolved, instID))
            else
                Log("  -> No matching entry in dungeon data.")
            end
        end
    end,
    capture = function(_, args)
        HandleRuntimeCaptureCommand(args)
    end,
}

SLASH_MEDAREMINDERS1 = "/mr"
SlashCmdList["MEDAREMINDERS"] = function(msg)
    local trimmed = type(msg) == "string" and msg:match("^%s*(.-)%s*$") or ""
    if trimmed ~= "" then
        local subCmd, subRest = trimmed:match("^(%S+)%s*(.*)$")
        subCmd = subCmd and subCmd:lower() or ""
        local handler = slashCommands[subCmd]
        if handler then
            local db = S.db or MedaAuras:GetModuleDB(MODULE_NAME)
            handler(db, subRest)
            return
        end
        Log("Unknown /mr command. Try /mr capture status or /mr instanceinfo.")
        return
    end

    if S.coveragePanel then
        S.dismissed = false
        S.coveragePanel:ClearDismissed()
        RunPipeline(false)
        S.coveragePanel:Show()
        S.coveragePanel:Raise()
    end
end

-- ============================================================================
-- Defaults & Registration
-- ============================================================================

local MODULE_DEFAULTS = {
    enabled = false,
    locked = false,
    showMinimapButton = true,
    autoShowInInstance = true,
    personalReminders = true,

    panelWidth = 1120,
    panelHeight = 720,
    panelPoint = nil,
    showBackground = true,
    backgroundOpacity = 0.85,

    sources = { wowhead = true, icyveins = true, archon = true },

    showInterrupts = true,
    showAffixTips  = true,
    showDungeonTimers = true,
    runtimeCaptureBlocks = {},
    runtimeCaptureNextID = 1,
    huds = {
        dispel = {
            enabled = true,
            showIcons = true,
            locked = false,
            filterMode = "all",
            font = "default",
            outline = "outline",
            titleSize = 13,
            detailSize = 11,
            iconSize = 18,
            topX = 6,
            expanded = false,
            point = nil,
        },
        interrupt = {
            enabled = true,
            showIcons = true,
            locked = false,
            font = "default",
            outline = "outline",
            titleSize = 13,
            detailSize = 11,
            iconSize = 18,
            topX = 6,
            expanded = false,
            point = nil,
        },
        boss = {
            enabled = true,
            showIcons = true,
            locked = false,
            font = "default",
            outline = "outline",
            titleSize = 13,
            detailSize = 11,
            iconSize = 18,
            topX = 5,
            expanded = false,
            point = nil,
        },
        tricks = {
            enabled = true,
            showIcons = true,
            locked = false,
            font = "default",
            outline = "outline",
            titleSize = 13,
            detailSize = 11,
            iconSize = 18,
            topX = 5,
            expanded = false,
            point = nil,
        },
    },
}

MedaAuras:RegisterModule({
    name          = MODULE_NAME,
    title         = "Reminders",
    version       = MODULE_VERSION,
    stability     = MODULE_STABILITY,
    author        = "Medalink",
    description   = "Data-driven group composition checker and dungeon prep assistant. "
                 .. "Shows dispel coverage, utility gaps, interrupt priorities, affix tips, "
                 .. "dungeon timers, "
                 .. "full build recommendations (talents, stats, gear, enchants, consumables), "
                 .. "and a pre-key prep checklist for dungeons, delves, and more.",
    sidebarDesc   = "Pre-key prep checklist with dispel coverage, utility gaps, and build tips.",
    defaults      = MODULE_DEFAULTS,
    OnInitialize  = OnInitialize,
    OnEnable      = OnEnable,
    OnDisable     = OnDisable,
    pages         = {
        { id = "tracking", label = "Tracking" },
        { id = "sources", label = "Sources" },
        { id = "appearance", label = "Appearance" },
        { id = "dispelhud", label = "Key Dispels" },
        { id = "interrupthud", label = "Key Interrupts" },
        { id = "bosstipshud", label = "Boss Tips" },
        { id = "tipsandtrickshud", label = "Tips & Tricks" },
    },
    pageHeights   = {
        tracking = 500,
        sources = 500,
        appearance = 500,
        dispelhud = 720,
        interrupthud = 720,
        bosstipshud = 720,
        tipsandtrickshud = 720,
    },
    buildPage     = BuildPage,
    onPageCacheRestore = function(pageName)
        RefreshSettingsPreview(pageName)
    end,
    slashCommands = slashCommands,
})

R.RunPipeline = RunPipeline
