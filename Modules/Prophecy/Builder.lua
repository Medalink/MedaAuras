--[[
    Prophecy Module -- Builder
    Settings UI tabs: Timeline viewer, Node Editor, History.
    Consumes MedaUI:CreateReorderableList, CreateSchemaForm,
    CreateEventTimeline, CreateNodeConnector.
]]

local _, ns = ...

local MedaUI = LibStub("MedaUI-1.0")
local Pixel = MedaUI.Pixel

local format = string.format
local ipairs = ipairs

local Engine = nil  -- set lazily

StaticPopupDialogs["MEDAAURAS_PROPHECY_CLEAR_HISTORY"] = {
    text = "Are you sure you want to clear all Prophecy run history? This cannot be undone.",
    button1 = "Clear",
    button2 = "Cancel",
    OnAccept = function()
        if MedaAurasCharDB and MedaAurasCharDB.prophecy then
            wipe(MedaAurasCharDB.prophecy.recordings)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function GetEngine()
    if not Engine then Engine = ns.Services.ProphecyEngine end
    return Engine
end

local function GetDB()
    return MedaAuras:GetModuleDB("Prophecy")
end

-- =====================================================================
-- Tab: Timeline
-- =====================================================================

local function BuildTimelineTab(parent, db)
    local yOff = 0

    -- Dungeon selector
    local Templates = ns.ProphecyTemplates
    local dungeonOptions = {}
    if Templates then
        for _, iid in ipairs(Templates:GetAvailableDungeons()) do
            dungeonOptions[#dungeonOptions + 1] = {
                value = iid,
                label = Templates:GetDungeonName(iid),
            }
        end
    end

    local dungeonDropdown = MedaUI:CreateLabeledDropdown(parent, "Dungeon", 220, dungeonOptions)
    Pixel.SetPoint(dungeonDropdown, "TOPLEFT", 0, -yOff)
    yOff = yOff + 60

    -- Template source radio group
    local sourceLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    Pixel.SetPoint(sourceLabel, "TOPLEFT", 0, -yOff)
    sourceLabel:SetText("Template Source")
    yOff = yOff + 18

    local sourceCurated = MedaUI:CreateRadio(parent, "Curated", "prophecy_source")
    Pixel.SetPoint(sourceCurated, "TOPLEFT", 0, -yOff)
    local sourcePersonal = MedaUI:CreateRadio(parent, "Personal", "prophecy_source")
    Pixel.SetPoint(sourcePersonal, "TOPLEFT", 80, -yOff)
    local sourceCustom = MedaUI:CreateRadio(parent, "Custom", "prophecy_source")
    Pixel.SetPoint(sourceCustom, "TOPLEFT", 160, -yOff)
    yOff = yOff + 28

    -- Prophecy node list (reorderable for custom, read-only for others)
    local nodeList = MedaUI:CreateReorderableList(parent, 440, 300, {
        rowHeight = 32,
        dragEnabled = false,
        renderRow = function(row, data, index)
            if not row._label then
                row._label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                Pixel.SetPoint(row._label, "LEFT", 28, 0)
                row._label:SetJustifyH("LEFT")
            end
            if not row._badge then
                row._badge = MedaUI:CreateBadge(row)
                Pixel.SetPoint(row._badge, "LEFT", 4, 0)
            end
            row._label:SetText(data.text or "")
            row._badge:SetText(data.type or "")
        end,
        onReorder = function(data, from, to)
            -- Save reordered custom template
        end,
    })
    Pixel.SetPoint(nodeList, "TOPLEFT", 0, -yOff)
    yOff = yOff + 310

    -- Chain arrows (for visualizing connections)
    local connector = MedaUI:CreateNodeConnector(parent)

    -- Load template when dungeon changes
    dungeonDropdown.OnValueChanged = function(_, instanceID)
        if not Templates then return end
        local template = Templates:Generate(instanceID)
        if template and template.nodes then
            nodeList:SetData(template.nodes)
        end
    end

    return { dungeonDropdown = dungeonDropdown, nodeList = nodeList, connector = connector }
end

-- =====================================================================
-- Tab: Editor
-- =====================================================================

local function BuildEditorTab(parent, db)
    local yOff = 0

    local textBox = MedaUI:CreateLabeledEditBox(parent, "Display Text", 300)
    Pixel.SetPoint(textBox, "TOPLEFT", 0, -yOff)
    yOff = yOff + 50

    local typeOptions = {
        { value = "BUFF", label = "Buff" },
        { value = "LUST", label = "Lust" },
        { value = "INTERRUPT", label = "Interrupt" },
        { value = "BOSS", label = "Boss" },
        { value = "CD", label = "Cooldown" },
        { value = "AWARENESS", label = "Awareness" },
    }
    local typeDropdown = MedaUI:CreateLabeledDropdown(parent, "Type", 200, typeOptions)
    Pixel.SetPoint(typeDropdown, "TOPLEFT", 0, -yOff)
    yOff = yOff + 60

    -- Trigger editor (SchemaForm, built dynamically per trigger type)
    local triggerHeader = MedaUI:CreateSectionHeader(parent, "Triggers", 440)
    Pixel.SetPoint(triggerHeader, "TOPLEFT", 0, -yOff)
    yOff = yOff + 30

    local triggerForm = MedaUI:CreateSchemaForm(parent, 440, {
        schema = {},
        values = {},
        onChange = function(fieldName, newValue)
            -- Update trigger params in real time
        end,
    })
    Pixel.SetPoint(triggerForm, "TOPLEFT", 0, -yOff)
    yOff = yOff + 120

    -- Add Trigger button
    local engine = GetEngine()
    local triggerTypeOptions = {}
    if engine then
        for key, def in pairs(engine.TriggerRegistry:GetAll()) do
            triggerTypeOptions[#triggerTypeOptions + 1] = { value = key, label = def.label }
        end
    end

    local addTriggerBtn = MedaUI:CreateButton(parent, "Add Trigger", 120)
    Pixel.SetPoint(addTriggerBtn, "TOPLEFT", 0, -yOff)
    yOff = yOff + 30

    -- AND/OR mode toggle
    local modeToggle = MedaUI:CreateToggle(parent, "ANY (OR)")
    Pixel.SetPoint(modeToggle, "TOPLEFT", 130, -(yOff - 30))

    -- Actions section
    local actionsHeader = MedaUI:CreateSectionHeader(parent, "Actions", 440)
    Pixel.SetPoint(actionsHeader, "TOPLEFT", 0, -yOff)
    yOff = yOff + 30

    local expectedTime = MedaUI:CreateLabeledSlider(parent, "Expected Time (seconds)", 200, 0, 3600, 1)
    Pixel.SetPoint(expectedTime, "TOPLEFT", 0, -yOff)
    yOff = yOff + 55

    local priority = MedaUI:CreateLabeledSlider(parent, "Priority", 200, 1, 100, 1)
    Pixel.SetPoint(priority, "TOPLEFT", 0, -yOff)

    addTriggerBtn:SetScript("OnClick", function()
        -- Open trigger type dropdown, then rebuild SchemaForm from selected type's params
        if #triggerTypeOptions > 0 then
            local first = triggerTypeOptions[1]
            local def = engine and engine.TriggerRegistry:Get(first.value)
            if def and def.params then
                triggerForm:SetSchema(def.params)
            end
        end
    end)
end

-- =====================================================================
-- Tab: History
-- =====================================================================

local function BuildHistoryTab(parent, db)
    local yOff = 0

    -- Run list using DataTable
    local runList = MedaUI:CreateDataTable(parent, 440, 200, {
        columns = {
            { key = "date", label = "Date", width = 120 },
            { key = "keyLevel", label = "Level", width = 50 },
            { key = "duration", label = "Duration", width = 80 },
            { key = "status", label = "Status", width = 80 },
        },
    })
    Pixel.SetPoint(runList, "TOPLEFT", 0, -yOff)
    yOff = yOff + 210

    -- Event timeline (for viewing a selected run)
    local eventTimeline = MedaUI:CreateEventTimeline(parent, 440, 200, {
        markerSize = 8,
    })
    Pixel.SetPoint(eventTimeline, "TOPLEFT", 0, -yOff)
    yOff = yOff + 210

    -- Action buttons
    local generateBtn = MedaUI:CreateButton(parent, "Generate Personal Template", 200)
    Pixel.SetPoint(generateBtn, "TOPLEFT", 0, -yOff)
    generateBtn:SetScript("OnClick", function()
        local engine = GetEngine()
        if not engine then return end
        local charDB = MedaAurasCharDB and MedaAurasCharDB.prophecy
        if not charDB or not charDB.recordings then return end
        for instanceID, recordings in pairs(charDB.recordings) do
            if recordings.runs and #recordings.runs >= 1 then
                recordings.personalTemplate = engine.RunRecorder:_AggregatePersonalTemplate(recordings.runs, instanceID,
                    MedaAurasDB and MedaAurasDB.modules and MedaAurasDB.modules.Prophecy)
            end
        end
        LoadRecordings()
    end)

    local promoteBtn = MedaUI:CreateButton(parent, "Promote Run to Template", 200)
    Pixel.SetPoint(promoteBtn, "TOPLEFT", 210, -yOff)
    promoteBtn:SetScript("OnClick", function()
        -- Promote the most recent completed run as the personal template
        local charDB = MedaAurasCharDB and MedaAurasCharDB.prophecy
        if not charDB or not charDB.recordings then return end
        for instanceID, recordings in pairs(charDB.recordings) do
            local runs = recordings.runs
            if runs then
                for i = #runs, 1, -1 do
                    if runs[i].completed then
                        local engine = GetEngine()
                        if engine then
                            recordings.personalTemplate = engine.RunRecorder:_AggregatePersonalTemplate({ runs[i] }, instanceID,
                                MedaAurasDB and MedaAurasDB.modules and MedaAurasDB.modules.Prophecy)
                        end
                        break
                    end
                end
            end
        end
    end)
    yOff = yOff + 30

    local clearBtn = MedaUI:CreateButton(parent, "Clear History", 120)
    Pixel.SetPoint(clearBtn, "TOPLEFT", 0, -yOff)
    clearBtn:SetScript("OnClick", function()
        StaticPopup_Show("MEDAAURAS_PROPHECY_CLEAR_HISTORY")
    end)

    local importBtn = MedaUI:CreateButton(parent, "Import", 80)
    Pixel.SetPoint(importBtn, "TOPLEFT", 130, -yOff)
    importBtn:SetScript("OnClick", function()
        local dialog = MedaUI:CreateImportExportDialog({
            title = "Import Prophecy Template",
            mode = "import",
            onImport = function(encodedString)
                local LibSerialize = LibStub("LibSerialize")
                local LibDeflate = LibStub("LibDeflate")
                if not LibSerialize or not LibDeflate then return end
                local decoded = LibDeflate:DecodeForPrint(encodedString)
                if not decoded then return end
                local decompressed = LibDeflate:DecompressDeflate(decoded)
                if not decompressed then return end
                local success, data = LibSerialize:Deserialize(decompressed)
                if success and data and data.nodes then
                    local acctDB = MedaAurasDB and MedaAurasDB.modules and MedaAurasDB.modules.Prophecy
                    if acctDB then
                        local instanceID = data.instanceID or 0
                        acctDB.customTemplates = acctDB.customTemplates or {}
                        acctDB.customTemplates[instanceID] = data
                    end
                end
            end,
        })
        dialog:Show()
    end)

    local exportBtn = MedaUI:CreateButton(parent, "Export", 80)
    Pixel.SetPoint(exportBtn, "TOPLEFT", 220, -yOff)
    exportBtn:SetScript("OnClick", function()
        local acctDB = MedaAurasDB and MedaAurasDB.modules and MedaAurasDB.modules.Prophecy
        if not acctDB or not acctDB.customTemplates then return end
        local firstID = next(acctDB.customTemplates)
        if not firstID then return end
        local template = acctDB.customTemplates[firstID]

        local LibSerialize = LibStub("LibSerialize")
        local LibDeflate = LibStub("LibDeflate")
        if not LibSerialize or not LibDeflate then return end
        local serialized = LibSerialize:Serialize(template)
        local compressed = LibDeflate:CompressDeflate(serialized)
        local encoded = LibDeflate:EncodeForPrint(compressed)

        local dialog = MedaUI:CreateImportExportDialog({
            title = "Export Prophecy Template",
            mode = "export",
            exportText = encoded,
        })
        dialog:Show()
    end)

    -- Load recordings
    local function LoadRecordings()
        if not runList then return end
        local charDB = MedaAurasCharDB and MedaAurasCharDB.prophecy
        if not charDB or not charDB.recordings then return end

        local tableData = {}
        for instanceID, recordings in pairs(charDB.recordings) do
            for _, run in ipairs(recordings.runs or {}) do
                tableData[#tableData + 1] = {
                    date     = date("%Y-%m-%d", run.timestamp),
                    keyLevel = run.keyLevel or 0,
                    duration = format("%d:%02d", math.floor((run.duration or 0) / 60), (run.duration or 0) % 60),
                    status   = run.completed and "Completed" or "Depleted",
                    _events  = run.events,
                }
            end
        end
        runList:SetData(tableData)
    end

    -- Show event timeline when a run is selected
    runList.OnRowClick = function(_, rowData)
        if rowData and rowData._events then
            local timelineData = {}
            for _, ev in ipairs(rowData._events) do
                timelineData[#timelineData + 1] = {
                    t = ev.t or 0,
                    text = ev.type or "",
                    type = ev.type,
                }
            end
            eventTimeline:SetData(timelineData)
        end
    end

    C_Timer.After(0, LoadRecordings)
end

-- =====================================================================
-- Public: Build all builder tabs (called by Settings.lua)
-- =====================================================================

function ns.Prophecy.BuildBuilderTabs(parent, db, tabContentFrame)
    BuildTimelineTab(tabContentFrame, db)
end

function ns.Prophecy.BuildEditorTab(parent, db)
    BuildEditorTab(parent, db)
end

function ns.Prophecy.BuildHistoryTab(parent, db)
    BuildHistoryTab(parent, db)
end
