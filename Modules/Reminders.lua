local _, ns = ...

local MedaUI = LibStub("MedaUI-1.0")

-- ============================================================================
-- Constants
-- ============================================================================

local MODULE_NAME = "Reminders"
local MIN_DATA_VERSION = 1
local MAX_DATA_VERSION = 10

local SEVERITY_PRIORITY = { critical = 3, warning = 2, info = 1 }
local SEVERITY_COLORS = {
    critical = { 0.9, 0.2, 0.2 },
    warning  = { 1.0, 0.7, 0.2 },
    info     = { 0.4, 0.7, 1.0 },
}
local COVERED_COLOR = { 0.3, 0.85, 0.3 }

local CLASS_COLORS = RAID_CLASS_COLORS

-- ============================================================================
-- State
-- ============================================================================

local db
local eventFrame
local coveragePanel
local alertBanner
local minimapButton
local rowPool = {}
local activeRows = {}
local sectionHeaders = {}
local lastResults = {}
local lastContext = {}
local dismissed = false
local debugMode = false
local isEnabled = false
local overrideContext = nil
local contextDropdown = nil
local detectedLabel = nil

-- ============================================================================
-- Logging
-- ============================================================================

local function Log(msg)
    MedaAuras.Log(format("[Reminders] %s", msg))
end

local function LogDebug(msg)
    MedaAuras.LogDebug(format("[Reminders] %s", msg))
end

local function LogWarn(msg)
    MedaAuras.LogWarn(format("[Reminders] %s", msg))
end

-- ============================================================================
-- Data compatibility check
-- ============================================================================

local function GetData()
    return ns.RemindersData
end

local function IsDataCompatible()
    local data = GetData()
    if not data or not data.dataVersion then return false, "missing" end
    if data.dataVersion < MIN_DATA_VERSION then return false, "too_old" end
    if data.dataVersion > MAX_DATA_VERSION then return false, "too_new" end
    return true, nil
end

-- ============================================================================
-- Trigger matching
-- ============================================================================

local function GetCurrentContext()
    local inInstance, instanceType = IsInInstance()
    local ctx = {
        inInstance    = inInstance,
        instanceType  = instanceType,
        instanceID    = nil,
        instanceName  = nil,
    }
    if inInstance then
        local name, _, _, _, _, _, _, id = GetInstanceInfo()
        ctx.instanceID = id
        ctx.instanceName = name
    end
    return ctx
end

local function TriggerMatches(trigger, ctx)
    if not trigger or not trigger.type then return false end

    if trigger.type == "instance" then
        if not ctx.inInstance then return false end

        if trigger.instanceType and trigger.instanceType ~= ctx.instanceType then
            return false
        end

        if trigger.instanceIDs then
            local found = false
            for _, id in ipairs(trigger.instanceIDs) do
                if id == ctx.instanceID then
                    found = true
                    break
                end
            end
            if not found then return false end
        end

        return true

    elseif trigger.type == "always" then
        return true
    end

    return false
end

-- ============================================================================
-- Evaluation engine
-- ============================================================================

local function ResolveConditionKey(capability, matchCount)
    local thresholds = capability.thresholds
    if not thresholds then return "none" end

    local bestKey = "none"
    local bestVal = -1

    for key, val in pairs(thresholds) do
        if matchCount > val and val > bestVal then
            bestVal = val
            bestKey = key
        elseif matchCount == val and val > bestVal then
            bestVal = val
            bestKey = key
        end
    end

    if matchCount <= (thresholds.none or 0) then
        return "none"
    end

    return bestKey
end

local function MergeOutput(capability, check, conditionKey)
    local base = capability.conditions and capability.conditions[conditionKey]
    local override = check.overrides and check.overrides[conditionKey]

    if override then
        local merged = {}
        if base then
            for k, v in pairs(base) do merged[k] = v end
        end
        for k, v in pairs(override) do merged[k] = v end
        return merged
    end

    return base or {}
end

local function CheckPersonalReminder(capability)
    if not capability.personalReminder then return nil end
    if not capability.providers then return nil end

    local _, playerClass = UnitClass("player")
    if not playerClass then return nil end

    for _, provider in ipairs(capability.providers) do
        if provider.class == playerClass then
            local specMatch = true
            if provider.specID then
                local specIndex = GetSpecialization()
                local currentSpec = specIndex and GetSpecializationInfo(specIndex)
                specMatch = currentSpec == provider.specID
            end

            if specMatch and not IsPlayerSpell(provider.spellID) then
                local reminder = {}
                for k, v in pairs(capability.personalReminder) do
                    reminder[k] = v
                end
                if reminder.detail then
                    reminder.detail = reminder.detail:gsub("%%spellName%%", provider.spellName or "")
                end
                if reminder.banner then
                    reminder.banner = reminder.banner:gsub("%%spellName%%", provider.spellName or "")
                end
                return reminder
            end
        end
    end

    return nil
end

local function IsCapabilityEnabled(capability)
    if not capability.tags or not db then return true end
    for _, tag in ipairs(capability.tags) do
        local key = "tag_" .. tag
        if db[key] == false then return false end
    end
    return true
end

local function Evaluate()
    local data = GetData()
    if not data then return {} end

    local ctx = overrideContext or GetCurrentContext()
    lastContext = ctx

    local results = {}
    local seenCapabilities = {}
    local GroupInspector = ns.Services.GroupInspector

    if not GroupInspector then
        LogWarn("GroupInspector service not available")
        return results
    end

    LogDebug(format("Evaluating -- instance=%s type=%s id=%s",
        tostring(ctx.inInstance), tostring(ctx.instanceType), tostring(ctx.instanceID)))

    for _, rule in ipairs(data.rules) do
        if TriggerMatches(rule.trigger, ctx) then
            LogDebug(format("Rule '%s' triggered -- %d checks", rule.id, #(rule.checks or {})))

            for _, check in ipairs(rule.checks or {}) do
                local capID = check.capability
                if not seenCapabilities[capID] then
                    local capability = data.capabilities[capID]
                    if not capability then
                        LogWarn(format("Capability '%s' referenced by rule '%s' but not found in data",
                            capID, rule.id))
                    elseif IsCapabilityEnabled(capability) then
                        seenCapabilities[capID] = true

                        local matches = GroupInspector:QueryProviders(capability.providers)
                        local matchCount = #matches
                        local conditionKey = ResolveConditionKey(capability, matchCount)
                        local output = MergeOutput(capability, check, conditionKey)
                        local personal = CheckPersonalReminder(capability)

                        LogDebug(format("  Check %s: %d match(es) -> condition '%s'%s",
                            capID, matchCount, conditionKey,
                            personal and " +personal" or ""))

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
    end

    LogDebug(format("Evaluation complete: %d results", #results))

    if debugMode then
        MedaAuras.LogTable(results, "Reminders_EvaluationResults", 4)
    end

    return results
end

-- ============================================================================
-- UI: Coverage Panel
-- ============================================================================

local ICON_SIZE = 28
local ICON_ZOOM = { 0.11, 0.89, 0.11, 0.89 }

local function AcquireRow(parent)
    local row = table.remove(rowPool)
    if not row then
        row = MedaUI:CreateStatusRow(parent, { width = nil, showNote = true, iconSize = ICON_SIZE })
    else
        row:SetParent(parent)
        row:Reset()
    end
    row.icon:SetTexCoord(unpack(ICON_ZOOM))
    row:Show()
    return row
end

local function ReleaseRows()
    for _, row in ipairs(activeRows) do
        row:Hide()
        row:SetParent(nil)
        rowPool[#rowPool + 1] = row
    end
    wipe(activeRows)
end

local function ReleaseSectionHeaders()
    for _, hdr in ipairs(sectionHeaders) do
        hdr:Hide()
    end
    wipe(sectionHeaders)
end

local function GetDetectedLabel(ctx)
    if not ctx or not ctx.inInstance then return "World" end
    if ctx.instanceName then return ctx.instanceName end
    local data = GetData()
    if data and data.contexts and data.contexts.instanceTypes and ctx.instanceType then
        local it = data.contexts.instanceTypes[ctx.instanceType]
        if it then return it.label end
    end
    return ctx.instanceType or "Instance"
end

local function BuildContextDropdownItems()
    local data = GetData()
    local items = { { value = "auto", label = "Auto (Live)" } }
    if not data or not data.contexts then return items end

    if data.contexts.instanceTypes then
        local sorted = {}
        for key, info in pairs(data.contexts.instanceTypes) do
            sorted[#sorted + 1] = { key = key, label = info.label }
        end
        table.sort(sorted, function(a, b) return a.label < b.label end)
        for _, entry in ipairs(sorted) do
            items[#items + 1] = { value = "type:" .. entry.key, label = entry.label }
        end
    end

    if data.contexts.dungeons then
        local sorted = {}
        for id, info in pairs(data.contexts.dungeons) do
            sorted[#sorted + 1] = { id = id, name = info.name }
        end
        table.sort(sorted, function(a, b) return a.name < b.name end)
        for _, entry in ipairs(sorted) do
            items[#items + 1] = { value = "dungeon:" .. entry.id, label = entry.name }
        end
    end

    return items
end

local function ParseContextSelection(value)
    if not value or value == "auto" then return nil end

    local typeKey = value:match("^type:(.+)$")
    if typeKey then
        return {
            inInstance   = true,
            instanceType = typeKey,
            instanceID   = nil,
            instanceName = nil,
        }
    end

    local dungeonID = value:match("^dungeon:(%d+)$")
    if dungeonID then
        dungeonID = tonumber(dungeonID)
        local data = GetData()
        local name
        if data and data.contexts and data.contexts.dungeons and data.contexts.dungeons[dungeonID] then
            name = data.contexts.dungeons[dungeonID].name
        end
        return {
            inInstance   = true,
            instanceType = "party",
            instanceID   = dungeonID,
            instanceName = name,
        }
    end

    return nil
end

local function GetContextHeader(data, ctx)
    if ctx.instanceID and data.contexts and data.contexts.dungeons then
        local dungeon = data.contexts.dungeons[ctx.instanceID]
        if dungeon then
            return dungeon.name, dungeon.header, dungeon.notes
        end
    end
    if ctx.instanceType and data.contexts and data.contexts.instanceTypes then
        local it = data.contexts.instanceTypes[ctx.instanceType]
        if it then return it.label, nil, nil end
    end
    return nil, nil, nil
end

local SOURCE_BADGES = {
    archon  = "|cff00ccff[A]|r",
    wowhead = "|cffff8800[W]|r",
    icyveins = "|cff33cc33[IV]|r",
}

local function FormatSourceBadge(source)
    return SOURCE_BADGES[source] or ""
end

local function IsSourceEnabled(source)
    if not db or not db.sources then return true end
    return db.sources[source] ~= false
end

local function FilterNoteBySource(note)
    if not note or note == "" then return note end
    if not db or not db.sources then return note end

    local filtered = note
    if not IsSourceEnabled("wowhead") then
        filtered = filtered:gsub("%s*%[Wowhead:[^%]]*%]", "")
    end
    if not IsSourceEnabled("icyveins") then
        filtered = filtered:gsub("%s*%[Icy Veins:[^%]]*%]", "")
    end
    if not IsSourceEnabled("archon") then
        filtered = filtered:gsub("%s*%[Archon:[^%]]*%]", "")
    end
    return filtered:match("^%s*(.-)%s*$") or ""
end

local function FormatProviderText(matches)
    if not matches or #matches == 0 then return nil end
    local parts = {}
    for _, m in ipairs(matches) do
        local cc = CLASS_COLORS[m.class]
        local colorStr = cc and format("|cff%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255) or "|cffffffff"
        parts[#parts + 1] = format("%s%s|r", colorStr, m.name or "?")
    end
    return table.concat(parts, ", ")
end

local function UpdateDetectedLabel()
    if not detectedLabel then return end
    local liveCtx = GetCurrentContext()
    detectedLabel:SetText("Detected: " .. GetDetectedLabel(liveCtx))
end

local function RenderPanel(results)
    if not coveragePanel then return end
    if #results == 0 then
        coveragePanel:Hide()
        return
    end

    local data = GetData()
    if not data then return end

    coveragePanel:ClearContent()
    ReleaseRows()
    ReleaseSectionHeaders()

    local content = coveragePanel:GetContent()
    local yOff = -4

    -- Context selector UI
    if detectedLabel then
        detectedLabel:SetParent(content)
        detectedLabel:ClearAllPoints()
        detectedLabel:SetPoint("TOPLEFT", 4, yOff)
        detectedLabel:SetPoint("RIGHT", content, "RIGHT", -4, 0)
        detectedLabel:Show()
        UpdateDetectedLabel()
        yOff = yOff - 16
    end

    if contextDropdown then
        contextDropdown:SetParent(content)
        contextDropdown:ClearAllPoints()
        contextDropdown:SetPoint("TOPLEFT", 4, yOff)
        contextDropdown:Show()
        yOff = yOff - 34
    end

    -- Context header
    local ctxName, ctxHeader, ctxNotes = GetContextHeader(data, lastContext)
    if ctxName then
        coveragePanel:SetTitle(ctxName)
    else
        coveragePanel:SetTitle("Group Coverage")
    end

    if ctxNotes and #ctxNotes > 0 then
        for _, note in ipairs(ctxNotes) do
            local noteText = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            noteText:SetPoint("TOPLEFT", 4, yOff)
            noteText:SetPoint("RIGHT", content, "RIGHT", -4, 0)
            noteText:SetJustifyH("LEFT")
            noteText:SetWordWrap(true)
            local Theme = MedaUI.Theme
            noteText:SetTextColor(unpack(Theme.textDim or {0.6, 0.6, 0.6}))
            noteText:SetText(note)
            yOff = yOff - noteText:GetStringHeight() - 4
        end
        yOff = yOff - 4
    end

    -- Build a lookup from capabilityID -> result
    local resultMap = {}
    for _, r in ipairs(results) do
        resultMap[r.capabilityID] = r
    end

    -- Render sections from groupCompDisplay
    local personalReminders = {}
    local sections = data.groupCompDisplay or {}

    for _, section in ipairs(sections) do
        local hasContent = false
        for _, capID in ipairs(section.capabilities or {}) do
            if resultMap[capID] then
                hasContent = true
                break
            end
        end

        if hasContent then
            local _, _, hdrContainer = MedaUI:CreateSectionHeader(content, section.label, content:GetWidth() - 8)
            hdrContainer:SetPoint("TOPLEFT", 4, yOff)
            sectionHeaders[#sectionHeaders + 1] = hdrContainer
            yOff = yOff - 28

            for _, capID in ipairs(section.capabilities or {}) do
                local r = resultMap[capID]
                if r then
                    local cap = r.capability
                    local row = AcquireRow(content)
                    activeRows[#activeRows + 1] = row

                    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOff)
                    row:SetPoint("RIGHT", content, "RIGHT", 0, 0)

                    row:SetIcon(cap.icon)
                    row:SetLabel(cap.label or capID)

                    local output = r.output or {}
                    local severity = output.severity

                    if severity and SEVERITY_COLORS[severity] then
                        local sc = SEVERITY_COLORS[severity]
                        row:SetAccentColor(sc[1], sc[2], sc[3])
                        row:SetHighlight(severity == "critical" or severity == "warning")
                    else
                        row:SetAccentColor(COVERED_COLOR[1], COVERED_COLOR[2], COVERED_COLOR[3])
                        row:SetHighlight(false)
                    end

                    if r.matchCount > 0 then
                        local provText = FormatProviderText(r.matches)
                        row:SetStatus(provText or "Covered")
                    elseif output.panelStatus then
                        local sc = severity and SEVERITY_COLORS[severity] or {1, 1, 1}
                        row:SetStatus(output.panelStatus, sc[1], sc[2], sc[3])
                    else
                        row:SetStatus("")
                    end

                    -- Note: provider note for covered, suggestion for gaps (filtered by source)
                    if r.matchCount > 0 and r.matches[1] and r.matches[1].note then
                        row:SetNote(FilterNoteBySource(r.matches[1].note))
                    elseif output.suggestion then
                        row:SetNote(FilterNoteBySource(output.suggestion))
                    elseif output.detail then
                        row:SetNote(FilterNoteBySource(output.detail))
                    else
                        row:SetNote("")
                    end

                    -- Tooltip with full detail
                    row:SetTooltipFunc(function(_, tip)
                        tip:AddLine(cap.label or capID, 1, 0.82, 0)
                        if cap.description then
                            tip:AddLine(cap.description, 1, 1, 1, true)
                        end
                        tip:AddLine(" ")
                        if output.detail then
                            tip:AddLine(output.detail, 1, 1, 1, true)
                        end
                        if r.matches and #r.matches > 0 then
                            tip:AddLine(" ")
                            tip:AddLine("Providers:", 0.6, 0.8, 1.0)
                            for _, m in ipairs(r.matches) do
                                local cc = CLASS_COLORS[m.class]
                                local cr, cg, cb = 1, 1, 1
                                if cc then cr, cg, cb = cc.r, cc.g, cc.b end
                                tip:AddDoubleLine(
                                    format("%s (%s)", m.name, m.spellName or "?"),
                                    "",
                                    cr, cg, cb, 1, 1, 1
                                )
                                if m.note and m.note ~= "" then
                                    tip:AddLine("  " .. m.note, 0.7, 0.7, 0.7, true)
                                end
                            end
                        end
                    end)

                    yOff = yOff - row:GetHeight() - 2

                    if r.personal then
                        personalReminders[#personalReminders + 1] = r
                    end
                end
            end

            yOff = yOff - 6
        end
    end

    -- Recommendations section (from archon/wowhead/icyveins)
    local recData = data.recommendations
    if recData then
        local _, playerClass = UnitClass("player")
        local specIdx = GetSpecialization()
        local playerSpec = specIdx and GetSpecializationInfo(specIdx)

        if playerClass and playerSpec then
            local specKey = playerClass .. "_" .. playerSpec
            local specRecs = recData[specKey]

            if specRecs then
                local hasVisibleRec = false
                for _, rec in ipairs(specRecs) do
                    if rec.source and IsSourceEnabled(rec.source) and rec.buildType == "talent" then
                        hasVisibleRec = true
                        break
                    end
                end

                if hasVisibleRec then
                    local _, _, recHdrContainer = MedaUI:CreateSectionHeader(content, "Build Recommendations", content:GetWidth() - 8)
                    recHdrContainer:SetPoint("TOPLEFT", 4, yOff)
                    sectionHeaders[#sectionHeaders + 1] = recHdrContainer
                    yOff = yOff - 28

                    for _, rec in ipairs(specRecs) do
                        if rec.source and IsSourceEnabled(rec.source) and rec.buildType == "talent" then
                            local badge = FormatSourceBadge(rec.source)
                            local noteText = rec.notes or ""
                            local recLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                            recLabel:SetPoint("TOPLEFT", 8, yOff)
                            recLabel:SetPoint("RIGHT", content, "RIGHT", -8, 0)
                            recLabel:SetJustifyH("LEFT")
                            recLabel:SetWordWrap(true)
                            recLabel:SetText(badge .. " " .. noteText)
                            yOff = yOff - recLabel:GetStringHeight() - 4
                        end
                    end
                    yOff = yOff - 6
                end
            end
        end
    end

    -- Personal reminders footer
    if #personalReminders > 0 and db and db.personalReminders ~= false then
        local first = personalReminders[1]
        local text = first.personal.detail or ""
        if first.personal.banner then
            text = first.personal.banner .. "\n" .. text
        end
        coveragePanel:SetFooter(text, 1.0, 0.82, 0.2)
        yOff = yOff - 30
    else
        coveragePanel:SetFooter("")
    end

    coveragePanel:SetContentHeight(math.abs(yOff) + 8)

    if not dismissed then
        coveragePanel:Show()
    end
end

-- ============================================================================
-- UI: Notification Banner
-- ============================================================================

local function ShowBannerIfNeeded(results)
    if not alertBanner or not db or not db.alertEnabled then return end
    if coveragePanel and coveragePanel:IsShown() then return end

    local threshold = SEVERITY_PRIORITY[db.alertSeverityThreshold or "warning"] or 2

    for _, r in ipairs(results) do
        local output = r.output or {}
        if output.banner and output.severity then
            local pri = SEVERITY_PRIORITY[output.severity] or 0
            if pri >= threshold then
                alertBanner:Show(output.banner, db.alertDuration or 5)
                Log(format("Banner shown: %s", output.banner))
                return
            end
        end
    end
end

-- ============================================================================
-- Evaluation + render pipeline
-- ============================================================================

local function RunPipeline(clearDismiss)
    if not isEnabled then return end

    local ok, reason = IsDataCompatible()
    if not ok then return end

    if clearDismiss then
        dismissed = false
        if coveragePanel then
            coveragePanel:ClearDismissed()
        end
    end

    local results = Evaluate()
    lastResults = results

    RenderPanel(results)
    ShowBannerIfNeeded(results)
end

-- ============================================================================
-- Event handling
-- ============================================================================

local function OnEvent(_, event, arg1)
    if event == "PLAYER_ENTERING_WORLD" then
        UpdateDetectedLabel()
        RunPipeline(true)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        Log(format("Zone changed -- re-evaluating"))
        UpdateDetectedLabel()
        RunPipeline(true)
    elseif event == "GROUP_ROSTER_UPDATE" then
        RunPipeline(true)
    end
end

local function OnInspectorUpdate()
    RunPipeline(false)
end

-- ============================================================================
-- UI creation
-- ============================================================================

local function CreateUI()
    -- Coverage panel
    coveragePanel = MedaUI:CreateInfoPanel("MedaAurasRemindersPanel", {
        width       = db.panelWidth or 360,
        height      = db.panelHeight or 400,
        title       = "Group Coverage",
        icon        = 134063,
        strata      = "MEDIUM",
        dismissable = true,
        locked      = db.locked or false,
    })

    coveragePanel.OnDismiss = function()
        dismissed = true
        Log("Panel dismissed by user")
    end

    coveragePanel.OnPositionChanged = function(self)
        db.panelPoint = self:SavePosition()
    end

    if db.panelPoint then
        coveragePanel:RestorePosition(db.panelPoint)
    else
        coveragePanel:SetPoint("RIGHT", UIParent, "RIGHT", -50, 0)
    end

    coveragePanel:SetBackgroundOpacity(db.backgroundOpacity or 0)

    -- Context selector (persistent across re-renders)
    detectedLabel = coveragePanel:GetContent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    detectedLabel:SetJustifyH("LEFT")
    detectedLabel:SetWordWrap(false)
    local Theme = MedaUI.Theme
    detectedLabel:SetTextColor(unpack(Theme.textDim or {0.6, 0.6, 0.6}))
    detectedLabel:SetText("Detected: World")

    local ddItems = BuildContextDropdownItems()
    contextDropdown = MedaUI:CreateDropdown(coveragePanel:GetContent(), 200, ddItems)
    contextDropdown:SetSelected("auto")
    contextDropdown.OnValueChanged = function(_, val)
        overrideContext = ParseContextSelection(val)
        RunPipeline(false)
    end

    -- Notification banner
    alertBanner = MedaUI:CreateNotificationBanner("MedaAurasRemindersAlert", {
        duration = db.alertDuration or 5,
        strata   = "HIGH",
        locked   = db.alertLocked or false,
    })

    alertBanner:HookScript("OnDragStop", function(self)
        db.alertPoint = self:SavePosition()
    end)

    if db.alertPoint then
        alertBanner:RestorePosition(db.alertPoint)
    else
        alertBanner:SetPoint("TOP", UIParent, "TOP", 0, -120)
    end

    -- Minimap button
    minimapButton = MedaUI:CreateMinimapButton(
        "MedaAurasReminders",
        134063,
        function()
            if coveragePanel then
                if coveragePanel:IsShown() then
                    coveragePanel:Dismiss()
                else
                    dismissed = false
                    coveragePanel:ClearDismissed()
                    RunPipeline(false)
                    coveragePanel:Show()
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

    if minimapButton and db.showMinimapButton == false then
        minimapButton.HideButton()
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

    isEnabled = true
    CreateUI()

    if not eventFrame then
        eventFrame = CreateFrame("Frame")
    end
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:SetScript("OnEvent", OnEvent)

    local GroupInspector = ns.Services.GroupInspector
    if GroupInspector then
        GroupInspector:RegisterCallback("Reminders", OnInspectorUpdate)
    end

    Log("Module enabled")
    RunPipeline(true)
end

local function StopModule()
    isEnabled = false

    if eventFrame then
        eventFrame:UnregisterAllEvents()
        eventFrame:SetScript("OnEvent", nil)
    end

    local GroupInspector = ns.Services.GroupInspector
    if GroupInspector then
        GroupInspector:UnregisterCallback("Reminders")
    end

    if coveragePanel then coveragePanel:Hide() end
    if alertBanner then alertBanner:Dismiss() end

    ReleaseRows()
    ReleaseSectionHeaders()

    Log("Module disabled")
end

local function OnInitialize(moduleDB)
    db = moduleDB
    StartModule()
end

local function OnEnable(moduleDB)
    db = moduleDB
    StartModule()
end

local function OnDisable(moduleDB)
    db = moduleDB
    StopModule()
end

-- ============================================================================
-- Preview / test mode
-- ============================================================================

local ALL_CLASS_SPECS = {
    DEATHKNIGHT = { 250, 251, 252 },
    DEMONHUNTER = { 577, 581 },
    DRUID       = { 102, 103, 104, 105 },
    EVOKER      = { 1467, 1468, 1473 },
    HUNTER      = { 253, 254, 255 },
    MAGE        = { 62, 63, 64 },
    MONK        = { 268, 269, 270 },
    PALADIN     = { 65, 66, 70 },
    PRIEST      = { 256, 257, 258 },
    ROGUE       = { 259, 260, 261 },
    SHAMAN      = { 262, 263, 264 },
    WARLOCK     = { 265, 266, 267 },
    WARRIOR     = { 71, 72, 73 },
}

local TANK_SPECS = {
    DEATHKNIGHT = 250, DEMONHUNTER = 581, DRUID = 104,
    MONK = 268, PALADIN = 66, WARRIOR = 73,
}
local HEALER_SPECS = {
    DRUID = 105, EVOKER = 1468, MONK = 270,
    PALADIN = 65, PRIEST = { 256, 257 }, SHAMAN = 264,
}
local DPS_SPECS = {
    DEATHKNIGHT = { 251, 252 }, DEMONHUNTER = { 577 },
    DRUID = { 102, 103 }, EVOKER = { 1467, 1473 },
    HUNTER = { 253, 254, 255 }, MAGE = { 62, 63, 64 },
    MONK = { 269 }, PALADIN = { 70 },
    PRIEST = { 258 }, ROGUE = { 259, 260, 261 },
    SHAMAN = { 262, 263 }, WARLOCK = { 265, 266, 267 },
    WARRIOR = { 71, 72 },
}

local ALL_CLASSES = {}
for token in pairs(ALL_CLASS_SPECS) do ALL_CLASSES[#ALL_CLASSES + 1] = token end
table.sort(ALL_CLASSES)

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

    if not coveragePanel then CreateUI() end

    local fakeGroup = GeneratePreviewGroup()

    local groupDesc = {}
    for _, m in ipairs(fakeGroup) do
        local cc = CLASS_COLORS[m.class]
        local hex = cc and format("%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255) or "ffffff"
        groupDesc[#groupDesc + 1] = format("|cff%s%s|r", hex, m.name)
    end
    Log(format("Preview group: %s", table.concat(groupDesc, ", ")))

    lastContext = { inInstance = true, instanceType = "party", instanceID = nil, instanceName = "Preview" }
    local results = EvaluatePreview(fakeGroup)
    lastResults = results

    dismissed = false
    if coveragePanel then coveragePanel:ClearDismissed() end
    RenderPanel(results)
    if coveragePanel then coveragePanel:SetTitle("Group Coverage (Preview)") end
end

-- ============================================================================
-- Settings UI
-- ============================================================================

local function BuildConfig(parent, moduleDB)
    local yOff = 0
    db = moduleDB
    local Theme = MedaUI.Theme

    -- ================================================================
    -- Section: General
    -- ================================================================
    local _, _, genHdr = MedaUI:CreateSectionHeader(parent, "General", 280)
    genHdr:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 34

    local mmCb = MedaUI:CreateCheckbox(parent, "Show minimap button")
    mmCb:SetChecked(db.showMinimapButton ~= false)
    mmCb.OnValueChanged = function(_, val)
        db.showMinimapButton = val
        if minimapButton then
            if val then minimapButton.ShowButton() else minimapButton.HideButton() end
        end
    end
    mmCb:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 28

    local lockCb = MedaUI:CreateCheckbox(parent, "Lock panel position")
    lockCb:SetChecked(db.locked or false)
    lockCb.OnValueChanged = function(_, val)
        db.locked = val
        if coveragePanel then coveragePanel:SetLocked(val) end
    end
    lockCb:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 28

    -- ================================================================
    -- Section: Talent
    -- ================================================================
    yOff = yOff - 10
    local _, _, talHdr = MedaUI:CreateSectionHeader(parent, "Talent", 280)
    talHdr:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 34

    local prCb = MedaUI:CreateCheckbox(parent, "Show personal talent reminders")
    prCb:SetChecked(db.personalReminders ~= false)
    prCb.OnValueChanged = function(_, val)
        db.personalReminders = val
        RunPipeline(false)
    end
    prCb:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 28

    local talUtilCb = MedaUI:CreateCheckbox(parent, "Track utility talents (Bloodlust, Battle Res)")
    talUtilCb:SetChecked(db.tag_utility ~= false)
    talUtilCb.OnValueChanged = function(_, val)
        db.tag_utility = val
        RunPipeline(false)
    end
    talUtilCb:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 28

    -- ================================================================
    -- Section: Debuff
    -- ================================================================
    yOff = yOff - 10
    local _, _, debuffHdr = MedaUI:CreateSectionHeader(parent, "Debuff", 280)
    debuffHdr:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 34

    local dispelMasterCb = MedaUI:CreateCheckbox(parent, "Track dispel coverage")
    dispelMasterCb:SetChecked(db.tag_dispel ~= false)
    dispelMasterCb.OnValueChanged = function(_, val)
        db.tag_dispel = val
        RunPipeline(false)
    end
    dispelMasterCb:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 28

    local debuffTypes = {
        { key = "tag_curse",   label = "Curse removal" },
        { key = "tag_poison",  label = "Poison removal" },
        { key = "tag_disease", label = "Disease removal" },
        { key = "tag_magic",   label = "Magic removal" },
    }

    for _, dt in ipairs(debuffTypes) do
        local dtCb = MedaUI:CreateCheckbox(parent, dt.label)
        dtCb:SetChecked(db[dt.key] ~= false)
        dtCb.OnValueChanged = function(_, val)
            db[dt.key] = val
            RunPipeline(false)
        end
        dtCb:SetPoint("TOPLEFT", 16, yOff)
        yOff = yOff - 28
    end

    -- ================================================================
    -- Section: Sources
    -- ================================================================
    yOff = yOff - 10
    local _, _, srcHdr = MedaUI:CreateSectionHeader(parent, "Sources", 280)
    srcHdr:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 34

    local srcDesc = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    srcDesc:SetPoint("TOPLEFT", 0, yOff)
    srcDesc:SetPoint("RIGHT", parent, "RIGHT", -4, 0)
    srcDesc:SetJustifyH("LEFT")
    srcDesc:SetWordWrap(true)
    srcDesc:SetTextColor(unpack(Theme.textDim or {0.6, 0.6, 0.6}))
    srcDesc:SetText("Choose which data sources provide recommendations. At least one must be active.")
    yOff = yOff - srcDesc:GetStringHeight() - 8

    if not db.sources then
        db.sources = { wowhead = true, icyveins = true, archon = true }
    end

    local sourceCheckboxes = {}
    local sourceKeys = {
        { key = "wowhead",  label = "Wowhead" },
        { key = "icyveins", label = "Icy Veins" },
        { key = "archon",   label = "Archon" },
    }

    local function CountActiveSources()
        local count = 0
        for _, sk in ipairs(sourceKeys) do
            if db.sources[sk.key] ~= false then count = count + 1 end
        end
        return count
    end

    for _, sk in ipairs(sourceKeys) do
        local sCb = MedaUI:CreateCheckbox(parent, sk.label)
        sCb:SetChecked(db.sources[sk.key] ~= false)
        sCb.OnValueChanged = function(_, val)
            if not val and CountActiveSources() <= 1 then
                sCb:SetChecked(true)
                return
            end
            db.sources[sk.key] = val
            RunPipeline(false)
        end
        sCb:SetPoint("TOPLEFT", 0, yOff)
        sourceCheckboxes[sk.key] = sCb
        yOff = yOff - 28
    end

    -- ================================================================
    -- Section: Theme
    -- ================================================================
    yOff = yOff - 10
    local _, _, themeHdr = MedaUI:CreateSectionHeader(parent, "Theme", 280)
    themeHdr:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 34

    local bgCb = MedaUI:CreateCheckbox(parent, "Show panel background")
    bgCb:SetChecked(db.showBackground or false)
    bgCb:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 28

    local bgLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bgLabel:SetPoint("TOPLEFT", 16, yOff)
    bgLabel:SetText("Background opacity:")
    bgLabel:SetTextColor(unpack(Theme.text))
    yOff = yOff - 18

    local bgSlider = MedaUI:CreateSlider(parent, 200, 0.1, 1.0, 0.05)
    bgSlider:SetValue(db.showBackground and (db.backgroundOpacity > 0 and db.backgroundOpacity or 0.8) or 0.8)
    bgSlider:SetPoint("TOPLEFT", 16, yOff)

    bgSlider.OnValueChanged = function(_, val)
        if db.showBackground then
            db.backgroundOpacity = val
            if coveragePanel then coveragePanel:SetBackgroundOpacity(val) end
        end
    end

    bgCb.OnValueChanged = function(_, val)
        db.showBackground = val
        if val then
            local opacity = bgSlider:GetValue()
            db.backgroundOpacity = opacity
            bgSlider:Show()
            bgLabel:Show()
        else
            db.backgroundOpacity = 0
            bgSlider:Hide()
            bgLabel:Hide()
        end
        if coveragePanel then coveragePanel:SetBackgroundOpacity(db.backgroundOpacity) end
    end

    if not db.showBackground then
        bgSlider:Hide()
        bgLabel:Hide()
    end
    yOff = yOff - 48

    local widthLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    widthLabel:SetPoint("TOPLEFT", 0, yOff)
    widthLabel:SetText("Panel width:")
    widthLabel:SetTextColor(unpack(Theme.text))
    yOff = yOff - 18

    local widthSlider = MedaUI:CreateSlider(parent, 200, 260, 600, 10)
    widthSlider:SetValue(db.panelWidth or 360)
    widthSlider.OnValueChanged = function(_, val)
        db.panelWidth = val
        if coveragePanel then coveragePanel:SetWidth(val) end
    end
    widthSlider:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 48

    -- ================================================================
    -- Section: Alerts
    -- ================================================================
    local _, _, alertHdr = MedaUI:CreateSectionHeader(parent, "Alerts", 280)
    alertHdr:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 34

    local alertCb = MedaUI:CreateCheckbox(parent, "Enable notification banners")
    alertCb:SetChecked(db.alertEnabled ~= false)
    alertCb.OnValueChanged = function(_, val)
        db.alertEnabled = val
    end
    alertCb:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 28

    local sevLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sevLabel:SetPoint("TOPLEFT", 0, yOff)
    sevLabel:SetText("Minimum severity for banner:")
    sevLabel:SetTextColor(unpack(Theme.text))
    yOff = yOff - 18

    local sevDropdown = MedaUI:CreateDropdown(parent, 140, {
        { value = "info",     label = "Info" },
        { value = "warning",  label = "Warning" },
        { value = "critical", label = "Critical" },
    })
    sevDropdown:SetSelected(db.alertSeverityThreshold or "warning")
    sevDropdown.OnValueChanged = function(_, val)
        db.alertSeverityThreshold = val
    end
    sevDropdown:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 48

    local durLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    durLabel:SetPoint("TOPLEFT", 0, yOff)
    durLabel:SetText("Banner duration (sec):")
    durLabel:SetTextColor(unpack(Theme.text))
    yOff = yOff - 18

    local durSlider = MedaUI:CreateSlider(parent, 200, 2, 15, 1)
    durSlider:SetValue(db.alertDuration or 5)
    durSlider.OnValueChanged = function(_, val)
        db.alertDuration = val
        if alertBanner then alertBanner:SetDuration(val) end
    end
    durSlider:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 48

    -- ================================================================
    -- Section: Actions
    -- ================================================================
    local _, _, resetHdr = MedaUI:CreateSectionHeader(parent, "Actions", 280)
    resetHdr:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 34

    local resetPanelBtn = MedaUI:CreateButton(parent, "Reset panel position", 160)
    resetPanelBtn:SetPoint("TOPLEFT", 0, yOff)
    resetPanelBtn.OnClick = function()
        if coveragePanel then
            coveragePanel:ClearAllPoints()
            coveragePanel:SetPoint("RIGHT", UIParent, "RIGHT", -50, 0)
            db.panelPoint = nil
        end
    end
    yOff = yOff - 32

    local resetAlertBtn = MedaUI:CreateButton(parent, "Reset alert position", 160)
    resetAlertBtn:SetPoint("TOPLEFT", 0, yOff)
    resetAlertBtn.OnClick = function()
        if alertBanner then
            alertBanner:ResetPosition()
            db.alertPoint = nil
        end
    end
    yOff = yOff - 32

    -- ================================================================
    -- Section: Preview
    -- ================================================================
    yOff = yOff - 10
    local _, _, prevHdr = MedaUI:CreateSectionHeader(parent, "Preview", 280)
    prevHdr:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 34

    local previewBtn = MedaUI:CreateButton(parent, "Randomize group", 160)
    previewBtn:SetPoint("TOPLEFT", 0, yOff)
    previewBtn.OnClick = function()
        RunPreview()
    end
    yOff = yOff - 32

    MedaAuras:SetContentHeight(math.abs(yOff))

    RunPreview()
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

local slashCommands = {
    show = function()
        if coveragePanel then
            dismissed = false
            coveragePanel:ClearDismissed()
            RunPipeline(false)
            coveragePanel:Show()
        end
    end,
    hide = function()
        if coveragePanel then coveragePanel:Dismiss() end
    end,
    debug = function()
        debugMode = not debugMode
        Log(format("Debug mode: %s", debugMode and "ON" or "OFF"))
    end,
    refresh = function()
        local GroupInspector = ns.Services.GroupInspector
        if GroupInspector then
            GroupInspector:RequestRefresh()
        end
        RunPipeline(true)
    end,
    preview = function()
        RunPreview()
    end,
}

-- ============================================================================
-- Defaults & Registration
-- ============================================================================

local MODULE_DEFAULTS = {
    enabled = false,
    locked = false,
    showMinimapButton = true,
    personalReminders = true,

    panelWidth = 360,
    panelHeight = 400,
    panelPoint = nil,
    showBackground = false,
    backgroundOpacity = 0,

    alertEnabled = true,
    alertSeverityThreshold = "warning",
    alertDuration = 5,
    alertLocked = false,
    alertPoint = nil,

    sources = { wowhead = true, icyveins = true, archon = true },
}

MedaAuras:RegisterModule({
    name          = MODULE_NAME,
    title         = "Reminders",
    description   = "Data-driven group composition checker and build advisor. "
                 .. "Shows dispel coverage, utility gaps, personal talent suggestions, and build recommendations.",
    defaults      = MODULE_DEFAULTS,
    OnInitialize  = OnInitialize,
    OnEnable      = OnEnable,
    OnDisable     = OnDisable,
    BuildConfig   = BuildConfig,
    slashCommands = slashCommands,
})
