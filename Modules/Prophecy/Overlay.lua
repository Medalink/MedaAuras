--[[
    Prophecy Module -- Overlay
    Transparent HUD overlay using MedaUI:CreateHUDRow.
    Active list, fulfilled collapse, delta indicators, timer countdowns,
    manual check-off, wipe/re-sync pulsing indicator, combat-aware rendering.
]]

local _, ns = ...

local MedaUI = LibStub("MedaUI-1.0")
local Pixel = MedaUI.Pixel

local GetTime = GetTime
local pairs = pairs
local ipairs = ipairs
local math_floor = math.floor
local format = string.format

local FRAME_THROTTLE = 1.0
local ROW_HEIGHT = 20
local MAX_ROWS = 15

local overlayFrame
local headerText
local rows = {}
local fulfilledRows = {}
local fulfilledSection
local fulfilledExpanded = false
local overflowText
local wipeIndicator
local isPreviewMode = false
local previewTemplateLoaded = false
local Refresh

local FONT_OBJECTS = {
    xs = "GameFontNormalSmall",
    sm = "GameFontHighlightSmall",
    md = "GameFontNormal",
    lg = "GameFontHighlight",
    xl = "GameFontNormalLarge",
}

local function FormatTimer(seconds)
    if not seconds or seconds <= 0 then return "" end
    return format("~%d:%02d", math_floor(seconds / 60), seconds % 60)
end

local function GetDB()
    return MedaAuras:GetModuleDB("Prophecy")
end

local function ApplyRowFontSize(row, sizeKey)
    if not row then return end

    local fontObject = FONT_OBJECTS[sizeKey] or FONT_OBJECTS.md
    if row.text then row.text:SetFontObject(fontObject) end
    if row.timer then row.timer:SetFontObject(fontObject) end
    if row.delta then row.delta:SetFontObject(fontObject) end
    if row.stateMarker then row.stateMarker:SetFontObject(fontObject) end
end

local function ApplyOverlayState()
    if not overlayFrame then return end

    local db = GetDB()
    if not db then return end

    overlayFrame:SetBackgroundVisible(db.showBackground or false)
    overlayFrame:SetBackgroundOpacity(db.backgroundOpacity or 0.4)
    overlayFrame:SetLocked(db.locked or false)

    local fontObject = FONT_OBJECTS[db.fontSize] or FONT_OBJECTS.md
    if headerText then headerText:SetFontObject(fontObject) end
    if wipeIndicator then wipeIndicator:SetFontObject(fontObject) end
    if overflowText then overflowText:SetFontObject(fontObject) end

    for _, row in ipairs(rows) do
        ApplyRowFontSize(row, db.fontSize)
    end
    for _, row in ipairs(fulfilledRows) do
        ApplyRowFontSize(row, db.fontSize)
    end
end

-- ----------------------------------------------------------------
-- Overlay frame creation
-- ----------------------------------------------------------------

local function EnsureOverlay()
    if overlayFrame then return end
    local db = GetDB()
    if not db then return end

    overlayFrame = MedaUI:CreateOverlayContainer("MedaAurasProphecyOverlay", {
        width = 280,
        height = 300,
        strata = "MEDIUM",
        title = "Prophecy",
        titleFont = "GameFontNormal",
        titleTone = "dim",
        titleAlpha = 0.6,
        showBackground = db.showBackground or false,
        backgroundOpacity = db.backgroundOpacity or 0.4,
        locked = db.locked or false,
        point = db.overlayPoint and {
            point = db.overlayPoint[1] or "CENTER",
            relativePoint = db.overlayPoint[1] or "CENTER",
            x = db.overlayPoint[2] or 0,
            y = db.overlayPoint[3] or 0,
        } or {
            point = "RIGHT",
            relativePoint = "RIGHT",
            x = -200,
            y = 100,
        },
    })
    headerText = overlayFrame.title

    overlayFrame.OnMove = function(_, state)
        local d = GetDB()
        if d and state then
            d.overlayPoint = { state.point, state.x, state.y }
        end
    end

    -- Wipe re-sync indicator
    wipeIndicator = MedaUI:CreateLabel(overlayFrame, "\226\159\179  Re-syncing at next boss...", {
        fontObject = "GameFontNormalSmall",
        tone = "warning",
        shadow = true,
    })
    wipeIndicator:SetPoint("TOPLEFT", overlayFrame, "TOPLEFT", 4, -22)
    wipeIndicator:Hide()

    -- Fulfilled collapse section
    fulfilledSection = MedaUI:CreateCollapsibleSectionHeader(overlayFrame, {
        text = "0 fulfilled",
        width = 270,
    })
    fulfilledSection:SetPoint("BOTTOMLEFT", overlayFrame, "BOTTOMLEFT", 4, 4)
    fulfilledSection:Hide()
    fulfilledSection:SetOnToggle(function(expanded)
        fulfilledExpanded = expanded
        Refresh()
    end)

    -- Overflow indicator
    overflowText = MedaUI:CreateLabel(overlayFrame, "", {
        fontObject = "GameFontNormalSmall",
        tone = "dim",
        shadow = true,
    })
    overflowText:SetText("")
    overflowText:Hide()

    -- Timer tick
    local elapsed = 0
    overlayFrame:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < FRAME_THROTTLE then return end
        elapsed = 0
        ns.Prophecy._UpdateTimers()
    end)

    ApplyOverlayState()
end

-- ----------------------------------------------------------------
-- Row pool
-- ----------------------------------------------------------------

local function GetRow(index)
    if rows[index] then return rows[index] end
    local row = MedaUI:CreateHUDRow(overlayFrame, {
        width = 270,
        showTimer = true,
        showDelta = true,
        interactive = true,
    })
    local db = GetDB()
    if db then
        ApplyRowFontSize(row, db.fontSize)
    end
    rows[index] = row
    return row
end

-- ----------------------------------------------------------------
-- Refresh / render
-- ----------------------------------------------------------------

Refresh = function()
    if not overlayFrame then return end
    local db = GetDB()
    if not db then return end

    local Engine = ns.Services.ProphecyEngine
    if not Engine or not Engine:IsActive() then
        overlayFrame:Hide()
        return
    end

    if db.showInDungeonOnly then
        local _, _, difficultyID = GetInstanceInfo()
        if difficultyID ~= 8 and not isPreviewMode then
            overlayFrame:Hide()
            return
        end
    end

    ApplyOverlayState()
    overlayFrame:Show()
    overlayFrame:SetAlpha(db.overlayOpacity or 0.8)

    local activeNodes = Engine:GetActiveNodes()
    local fulfilledNodes = Engine:GetFulfilledNodes()
    local maxVisible = db.maxVisible or 5
    local drift = Engine.DriftTracker

    -- Hide all rows first
    for _, row in ipairs(rows) do row:Hide() end

    local yOff = -24
    if drift.wipeActive then
        wipeIndicator:Show()
        local Theme = MedaUI.Theme
        local warning = Theme.warning or { 1, 0.62, 0.12, 1 }
        wipeIndicator:SetColorOverride(warning[1], warning[2], warning[3], warning[4] or 1)
        yOff = yOff - 18
    else
        wipeIndicator:Hide()
    end

    local shown = 0
    local filteredTotal = 0
    for _, node in ipairs(activeNodes) do
        if not db.categories or db.categories[node.type] ~= false then
            filteredTotal = filteredTotal + 1
        end
    end
    for i, node in ipairs(activeNodes) do
        if shown >= maxVisible then break end
        if not db.categories or db.categories[node.type] ~= false then
            shown = shown + 1
            local row = GetRow(shown)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", overlayFrame, "TOPLEFT", 4, yOff)
            yOff = yOff - ROW_HEIGHT

            row:SetState(drift.wipeActive and "paused" or "active")
            row:SetText(node.text or "")
            row:SetIcon(node.icon)

            -- Timer
            if db.showTimers and node.adjustedTime then
                local elapsed = Engine:GetElapsed()
                local remaining = node.adjustedTime - elapsed
                if drift.wipeActive then
                    row:SetTimer("paused")
                elseif remaining > 0 then
                    row:SetTimer(FormatTimer(remaining))
                else
                    row:SetTimer("")
                end
            else
                row:SetTimer("")
            end

            -- Delta
            if db.showDelta and node.adjustedTime and node.expectedTime then
                local deltaSeconds = (node.adjustedTime - node.expectedTime)
                if deltaSeconds ~= 0 then
                    row:SetDelta(deltaSeconds, {
                        neutral = db.driftNeutralThreshold or 15,
                        mild = db.driftMildThreshold or 60,
                    })
                else
                    row:SetDelta(nil)
                end
            else
                row:SetDelta(nil)
            end

            row:SetOnFulfill(function() Engine:ManualFulfill(node.id) end)
            row:SetOnDismiss(function() Engine:ManualDismiss(node.id) end)
            row:Show()
        end
    end

    -- Overflow
    local remaining = filteredTotal - shown
    if remaining > 0 then
        overflowText:SetText(format("   \194\183\194\183\194\183 %d more", remaining))
        overflowText:ClearAllPoints()
        overflowText:SetPoint("TOPLEFT", overlayFrame, "TOPLEFT", 4, yOff)
        overflowText:Show()
        yOff = yOff - 16
    else
        overflowText:Hide()
    end

    -- Hide previous fulfilled rows
    for _, fr in ipairs(fulfilledRows) do fr:Hide() end

    -- Fulfilled section
    if #fulfilledNodes > 0 then
        fulfilledSection:SetText(format("%d fulfilled", #fulfilledNodes))
        fulfilledSection:ClearAllPoints()
        fulfilledSection:SetPoint("TOPLEFT", overlayFrame, "TOPLEFT", 4, yOff - 8)
        fulfilledSection:Show()
        yOff = yOff - 28

        if fulfilledExpanded then
            for fi, fnode in ipairs(fulfilledNodes) do
                if not fulfilledRows[fi] then
                    fulfilledRows[fi] = MedaUI:CreateHUDRow(overlayFrame, {
                        width = 270, showTimer = false, showDelta = true, interactive = false,
                    })
                    ApplyRowFontSize(fulfilledRows[fi], db.fontSize)
                end
                local fr = fulfilledRows[fi]
                fr:ClearAllPoints()
                fr:SetPoint("TOPLEFT", overlayFrame, "TOPLEFT", 4, yOff)
                fr:SetState("fulfilled")
                fr:SetText(fnode.text or "")
                fr:SetIcon(fnode.icon)
                if fnode.actualTime and fnode.expectedTime then
                    fr:SetDelta(fnode.actualTime - fnode.expectedTime, {
                        neutral = db.driftNeutralThreshold or 15,
                        mild = db.driftMildThreshold or 60,
                    })
                else
                    fr:SetDelta(nil)
                end
                fr:Show()
                yOff = yOff - ROW_HEIGHT
            end
        end
    else
        fulfilledSection:Hide()
    end
end

-- ----------------------------------------------------------------
-- Timer update (called at 1 Hz via OnUpdate)
-- ----------------------------------------------------------------

function ns.Prophecy._UpdateTimers()
    if not overlayFrame or not overlayFrame:IsShown() then return end
    Refresh()
end

-- ----------------------------------------------------------------
-- Public API on ns.Prophecy
-- ----------------------------------------------------------------

function ns.Prophecy.CreateOverlay(db)
    EnsureOverlay()
    Refresh()
end

function ns.Prophecy.HideOverlay()
    if overlayFrame then overlayFrame:Hide() end
end

function ns.Prophecy.OnStateChange(node)
    Refresh()
end

function ns.Prophecy.OnDriftUpdate(drift)
    Refresh()
end

function ns.Prophecy.OnWipeStateChange(isWiping)
    Refresh()
end

function ns.Prophecy.OnRefresh()
    Refresh()
end

function ns.Prophecy.ResetOverlayPosition()
    if overlayFrame then
        overlayFrame:ClearAllPoints()
        overlayFrame:SetPoint("RIGHT", UIParent, "RIGHT", -200, 100)
        local db = GetDB()
        if db then db.overlayPoint = nil end
    end
end

function ns.Prophecy.TogglePreview()
    isPreviewMode = not isPreviewMode
    local Engine = ns.Services.ProphecyEngine

    if isPreviewMode then
        EnsureOverlay()
        if Engine and not Engine:IsActive() then
            local Templates = ns.ProphecyTemplates
            if Templates then
                local dungeons = Templates:GetAvailableDungeons()
                if dungeons[1] then
                    local template = Templates:Generate(dungeons[1])
                    if template then
                        Engine:LoadTemplate(template)
                        previewTemplateLoaded = true
                    end
                end
            end
        end
    elseif previewTemplateLoaded and Engine and Engine:IsActive() then
        Engine:Shutdown()
        previewTemplateLoaded = false
    else
        previewTemplateLoaded = false
    end
    Refresh()
end
