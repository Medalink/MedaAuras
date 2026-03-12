--[[
    Prophecy Module -- Settings
    BuildConfig entry point. Creates TabBar and delegates to sub-tabs.
    Appearance tab lives here; Timeline/Editor/History delegate to Builder.lua.
]]

local _, ns = ...

local MedaUI = LibStub("MedaUI-1.0")
local Pixel = MedaUI.Pixel

local function GetDB()
    return MedaAuras:GetModuleDB("Prophecy")
end

-- =====================================================================
-- Appearance tab
-- =====================================================================

local function BuildAppearanceTab(parent, db)
    local yOff = 0
    local LEFT_X = 0
    local RIGHT_X = 238

    -- Overlay opacity
    local opacitySlider = MedaUI:CreateLabeledSlider(parent, "Overlay Opacity", 200, 0, 100, 1)
    Pixel.SetPoint(opacitySlider, "TOPLEFT", LEFT_X, -yOff)
    opacitySlider:SetValue((db.overlayOpacity or 0.8) * 100)
    opacitySlider.OnValueChanged = function(_, val)
        db.overlayOpacity = val / 100
        if ns.Prophecy.OnRefresh then ns.Prophecy.OnRefresh() end
    end

    -- Max visible
    local maxSlider = MedaUI:CreateLabeledSlider(parent, "Max Visible Prophecies", 200, 3, 15, 1)
    Pixel.SetPoint(maxSlider, "TOPLEFT", RIGHT_X, -yOff)
    maxSlider:SetValue(db.maxVisible or 5)
    maxSlider.OnValueChanged = function(_, val) db.maxVisible = val end
    yOff = yOff + 55

    -- Font size
    local fontOptions = {
        { value = "xs", label = "Extra Small" },
        { value = "sm", label = "Small" },
        { value = "md", label = "Medium" },
        { value = "lg", label = "Large" },
        { value = "xl", label = "Extra Large" },
    }
    local fontDropdown = MedaUI:CreateLabeledDropdown(parent, "Font Size", 200, fontOptions)
    Pixel.SetPoint(fontDropdown, "TOPLEFT", LEFT_X, -yOff)
    fontDropdown:SetSelected(db.fontSize or "md")
    fontDropdown.OnValueChanged = function(_, val) db.fontSize = val end
    yOff = yOff + 60

    -- Checkboxes
    local showBg = MedaUI:CreateCheckbox(parent, "Show Background")
    Pixel.SetPoint(showBg, "TOPLEFT", LEFT_X, -yOff)
    showBg:SetChecked(db.showBackground or false)
    showBg.OnValueChanged = function(_, val) db.showBackground = val end

    local showDelta = MedaUI:CreateCheckbox(parent, "Show Delta Indicators")
    Pixel.SetPoint(showDelta, "TOPLEFT", RIGHT_X, -yOff)
    showDelta:SetChecked(db.showDelta ~= false)
    showDelta.OnValueChanged = function(_, val) db.showDelta = val end
    yOff = yOff + 24

    local showTimers = MedaUI:CreateCheckbox(parent, "Show Timer Countdowns")
    Pixel.SetPoint(showTimers, "TOPLEFT", LEFT_X, -yOff)
    showTimers:SetChecked(db.showTimers ~= false)
    showTimers.OnValueChanged = function(_, val) db.showTimers = val end

    local lockPos = MedaUI:CreateCheckbox(parent, "Lock Overlay Position")
    Pixel.SetPoint(lockPos, "TOPLEFT", RIGHT_X, -yOff)
    lockPos:SetChecked(db.locked or false)
    lockPos.OnValueChanged = function(_, val) db.locked = val end
    yOff = yOff + 24

    local dungeonOnly = MedaUI:CreateCheckbox(parent, "Show In Dungeon Only")
    Pixel.SetPoint(dungeonOnly, "TOPLEFT", LEFT_X, -yOff)
    dungeonOnly:SetChecked(db.showInDungeonOnly ~= false)
    dungeonOnly.OnValueChanged = function(_, val) db.showInDungeonOnly = val end

    local softSync = MedaUI:CreateCheckbox(parent, "Enable Soft Sync")
    Pixel.SetPoint(softSync, "TOPLEFT", RIGHT_X, -yOff)
    softSync:SetChecked(db.enableSoftSync or false)
    softSync.OnValueChanged = function(_, val) db.enableSoftSync = val end
    yOff = yOff + 24

    local excludeWipes = MedaUI:CreateCheckbox(parent, "Exclude Wipes From Averages")
    Pixel.SetPoint(excludeWipes, "TOPLEFT", LEFT_X, -yOff)
    excludeWipes:SetChecked(db.excludeWipesFromAvg ~= false)
    excludeWipes.OnValueChanged = function(_, val) db.excludeWipesFromAvg = val end
    yOff = yOff + 30

    -- Background opacity (conditional)
    local bgOpacity = MedaUI:CreateLabeledSlider(parent, "Background Opacity", 200, 0, 100, 1)
    Pixel.SetPoint(bgOpacity, "TOPLEFT", LEFT_X, -yOff)
    bgOpacity:SetValue((db.backgroundOpacity or 0.4) * 100)
    bgOpacity.OnValueChanged = function(_, val) db.backgroundOpacity = val / 100 end
    yOff = yOff + 55

    -- Drift thresholds
    local neutralSlider = MedaUI:CreateLabeledSlider(parent, "Neutral Threshold (seconds)", 200, 5, 30, 1)
    Pixel.SetPoint(neutralSlider, "TOPLEFT", LEFT_X, -yOff)
    neutralSlider:SetValue(db.driftNeutralThreshold or 15)
    neutralSlider.OnValueChanged = function(_, val) db.driftNeutralThreshold = val end

    local warnSlider = MedaUI:CreateLabeledSlider(parent, "Warning Threshold (seconds)", 200, 30, 120, 1)
    Pixel.SetPoint(warnSlider, "TOPLEFT", RIGHT_X, -yOff)
    warnSlider:SetValue(db.driftMildThreshold or 60)
    warnSlider.OnValueChanged = function(_, val) db.driftMildThreshold = val end
    yOff = yOff + 55

    -- Category filters
    local catHeader = MedaUI:CreateSectionHeader(parent, "Category Filters", 440)
    Pixel.SetPoint(catHeader, "TOPLEFT", LEFT_X, -yOff)
    yOff = yOff + 24

    local categories = { "BUFF", "LUST", "INTERRUPT", "BOSS", "CD", "AWARENESS" }
    local catX = LEFT_X
    for _, cat in ipairs(categories) do
        local cb = MedaUI:CreateCheckbox(parent, cat)
        Pixel.SetPoint(cb, "TOPLEFT", catX, -yOff)
        cb:SetChecked(db.categories and db.categories[cat] ~= false)
        cb.OnValueChanged = function(_, val)
            db.categories = db.categories or {}
            db.categories[cat] = val
        end
        catX = catX + 80
        if catX > 400 then catX = LEFT_X; yOff = yOff + 24 end
    end
    yOff = yOff + 30

    -- Action buttons
    local resetBtn = MedaUI:CreateButton(parent, "Reset Position", 120)
    Pixel.SetPoint(resetBtn, "TOPLEFT", LEFT_X, -yOff)
    resetBtn:SetScript("OnClick", function()
        if ns.Prophecy.ResetOverlayPosition then ns.Prophecy.ResetOverlayPosition() end
    end)

    local previewBtn = MedaUI:CreateButton(parent, "Preview Mode", 120)
    Pixel.SetPoint(previewBtn, "TOPLEFT", 130, -yOff)
    previewBtn:SetScript("OnClick", function()
        if ns.Prophecy.TogglePreview then ns.Prophecy.TogglePreview() end
    end)
end

-- =====================================================================
-- BuildConfig entry point
-- =====================================================================

function ns.Prophecy.BuildConfig(parent, db)
    local tabBar = MedaUI:CreateTabBar(parent, {
        { id = "timeline",   label = "Timeline" },
        { id = "editor",     label = "Editor" },
        { id = "history",    label = "History" },
        { id = "appearance", label = "Appearance" },
    })
    Pixel.SetPoint(tabBar, "TOPLEFT", 0, 0)

    local contentFrame = CreateFrame("Frame", nil, parent)
    Pixel.SetPoint(contentFrame, "TOPLEFT", 0, -34)
    Pixel.SetPoint(contentFrame, "BOTTOMRIGHT", 0, 0)

    local currentContent = nil

    local function ClearContent()
        if currentContent then
            for _, child in ipairs({ currentContent:GetChildren() }) do
                child:Hide()
            end
            currentContent:Hide()
        end
    end

    local function ShowTab(tabId)
        ClearContent()
        local frame = CreateFrame("Frame", nil, contentFrame)
        frame:SetAllPoints()
        currentContent = frame

        if tabId == "timeline" then
            ns.Prophecy.BuildBuilderTabs(parent, db, frame)
        elseif tabId == "editor" then
            ns.Prophecy.BuildEditorTab(frame, db)
        elseif tabId == "history" then
            ns.Prophecy.BuildHistoryTab(frame, db)
        elseif tabId == "appearance" then
            BuildAppearanceTab(frame, db)
        end

        frame:Show()
    end

    tabBar.OnTabSelected = function(_, tabId)
        ShowTab(tabId)
    end

    ShowTab("timeline")
end
