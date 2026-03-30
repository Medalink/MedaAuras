local _, ns = ...

local MedaUI = LibStub("MedaUI-2.0")

local C_Timer = C_Timer
local CreateFrame = CreateFrame
local GetTime = GetTime
local ipairs = ipairs
local unpack = unpack
local wipe = wipe

local C = ns.Cracked or {}
ns.Cracked = C

local MODULE_NAME = "Cracked"

local pvContainer
local pvInner
local pvBars
local pvTitleText
local pvTicker
local pvStartTime = 0
local layoutRefreshTimer
local layoutRefreshScope

local PREVIEW_MOCK = {
    { name = "Tanksworth", class = "WARRIOR", spellID = 871, baseCd = 180, duration = 8, cdOffset = 60 },
    { name = "Stabsworth", class = "ROGUE", spellID = 31224, baseCd = 120, duration = 5, cdOffset = 0 },
    { name = "Frostbyte", class = "MAGE", spellID = 45438, baseCd = 240, duration = 10, cdOffset = 100 },
    { name = "Healbot", class = "PRIEST", spellID = 33206, baseCd = 180, duration = 8, cdOffset = 30 },
    { name = "Felrush", class = "DEMONHUNTER", spellID = 198589, baseCd = 60, duration = 10, cdOffset = 0 },
}

local function GetPreviewPaneId()
    local paneId = C.GetActiveSettingsPaneId and C.GetActiveSettingsPaneId() or "all"
    local labels = C.GetPaneLabels and C.GetPaneLabels() or {}
    return labels[paneId] and paneId or "all"
end

local function GetPreviewEntries()
    local paneId = GetPreviewPaneId()
    local groupBuffs = C.GetGroupBuffs and C.GetGroupBuffs() or {}
    local allDefensives = C.GetAllDefensives and C.GetAllDefensives() or {}

    if paneId == "buffs" then
        return {
            {
                entryKind = "missingBuff",
                spellName = "Fortitude",
                icon = groupBuffs.stamina and groupBuffs.stamina.icon or 135987,
                count = 2,
                summary = "Tanksworth, Frostbyte",
            },
        }
    end

    if paneId == "all" then
        return PREVIEW_MOCK
    end

    local filtered = {}
    for _, mock in ipairs(PREVIEW_MOCK) do
        local defData = allDefensives[mock.spellID]
        if defData and defData.category == paneId then
            filtered[#filtered + 1] = mock
        end
    end

    if #filtered == 0 then
        return PREVIEW_MOCK
    end

    return filtered
end

local function DestroyPreview()
    if pvTicker then
        pvTicker:Cancel()
        pvTicker = nil
    end

    if pvBars then
        for i = 1, #pvBars do
            pvBars[i]:Hide()
            pvBars[i]:SetParent(nil)
        end
        wipe(pvBars)
        pvBars = nil
    end

    pvTitleText = nil
    if pvInner then
        pvInner:Hide()
        pvInner:SetParent(nil)
        pvInner = nil
    end
    if pvContainer then
        pvContainer:Hide()
        pvContainer:SetParent(nil)
        pvContainer = nil
    end
end

local function CreatePreviewBars()
    if not pvContainer then
        return
    end

    if pvInner then
        pvInner:Hide()
        pvInner:SetParent(nil)
    end

    pvInner = CreateFrame("Frame", nil, pvContainer)
    pvInner:SetAllPoints()
    pvBars = {}

    local paneId = GetPreviewPaneId()
    local style = C.GetPaneStyle and C.GetPaneStyle(paneId) or {}
    local entries = GetPreviewEntries()
    local barW, barH, iconS, fontSize, cdFontSize, titleH, titleFontSize = C.GetBarLayoutForStyle(style)
    local getFontObj = C.GetFontObj
    local barTexture = C.GetBarTexture and C.GetBarTexture() or "Interface\\BUTTONS\\WHITE8X8"
    local paneTitles = C.GetPaneTitles and C.GetPaneTitles() or {}

    if style.showTitle then
        pvTitleText = pvInner:CreateFontString(nil, "OVERLAY")
        pvTitleText:SetFontObject(getFontObj(style.font or "default", titleFontSize, "outline"))
        pvTitleText:SetPoint("TOP", 0, -3)
        pvTitleText:SetText("|cFF00DDDD" .. (paneTitles[paneId] or "Defensives") .. "|r")
    else
        pvTitleText = nil
    end

    for i = 1, #entries do
        local yOff
        if style.growUp then
            yOff = (i - 1) * (barH + 1)
        else
            yOff = -(titleH + (i - 1) * (barH + 1))
        end

        local frame = CreateFrame("Frame", nil, pvInner)
        frame:SetSize(iconS + barW, barH)
        if style.growUp then
            frame:SetPoint("BOTTOMLEFT", 0, yOff)
        else
            frame:SetPoint("TOPLEFT", 0, yOff)
        end

        local icon = frame:CreateTexture(nil, "ARTWORK")
        icon:SetSize(iconS, barH)
        icon:SetPoint("LEFT", 0, 0)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        if iconS == 0 then
            icon:Hide()
        end
        frame.icon = icon

        local barBg = frame:CreateTexture(nil, "BACKGROUND")
        barBg:SetPoint("TOPLEFT", iconS, 0)
        barBg:SetPoint("BOTTOMRIGHT", 0, 0)
        barBg:SetTexture(barTexture)
        barBg:SetVertexColor(0.15, 0.15, 0.15, 0.9)
        frame.barBg = barBg

        local statusBar = CreateFrame("StatusBar", nil, frame)
        statusBar:SetPoint("TOPLEFT", iconS, 0)
        statusBar:SetPoint("BOTTOMRIGHT", 0, 0)
        statusBar:SetStatusBarTexture(barTexture)
        statusBar:SetStatusBarColor(1, 1, 1, 0.85)
        statusBar:SetMinMaxValues(0, 1)
        statusBar:SetValue(0)
        statusBar:SetFrameLevel(frame:GetFrameLevel() + 1)
        frame.cdBar = statusBar

        local content = CreateFrame("Frame", nil, frame)
        content:SetPoint("TOPLEFT", iconS, 0)
        content:SetPoint("BOTTOMRIGHT", 0, 0)
        content:SetFrameLevel(statusBar:GetFrameLevel() + 1)

        local nameText = content:CreateFontString(nil, "OVERLAY")
        nameText:SetFontObject(getFontObj(style.font or "default", fontSize, "outline"))
        nameText:SetPoint("LEFT", 6, 0)
        nameText:SetJustifyH("LEFT")
        nameText:SetWidth(barW - 50)
        nameText:SetWordWrap(false)
        nameText:SetShadowOffset(1, -1)
        nameText:SetShadowColor(0, 0, 0, 1)
        if style.showPlayerName == false and not style.showSpellName then
            nameText:Hide()
        end
        frame.nameText = nameText

        local cdText = content:CreateFontString(nil, "OVERLAY")
        cdText:SetFontObject(getFontObj(style.font or "default", cdFontSize, "outline"))
        cdText:SetPoint("RIGHT", -6, 0)
        cdText:SetShadowOffset(1, -1)
        cdText:SetShadowColor(0, 0, 0, 1)
        frame.cdText = cdText

        frame:Show()
        pvBars[i] = frame
    end

    pvContainer:SetSize(style.frameWidth or 240, titleH + #entries * (barH + 1))
end

local function UpdatePreview()
    if not pvContainer or not pvBars then
        return
    end

    local paneId = GetPreviewPaneId()
    local style = C.GetPaneStyle and C.GetPaneStyle(paneId) or {}
    local entries = GetPreviewEntries()
    local elapsed = GetTime() - pvStartTime
    local _, barH, _, _, _, titleH = C.GetBarLayoutForStyle(style)
    local allDefensives = C.GetAllDefensives and C.GetAllDefensives() or {}
    local classColors = C.GetClassColors and C.GetClassColors() or {}
    local activeColor = C.GetActiveColor and C.GetActiveColor() or { 0.2, 1.0, 0.2 }
    local fallbackWhite = C.GetFallbackWhite and C.GetFallbackWhite() or { 1, 1, 1 }
    local defaultSpellIcon = C.GetDefaultSpellIcon and C.GetDefaultSpellIcon() or 134400

    for i, mock in ipairs(entries) do
        local bar = pvBars[i]
        if not bar then
            break
        end

        if mock.entryKind == "missingBuff" then
            bar.icon:SetTexture(mock.icon)
            if style.showPlayerName == false and not style.showSpellName then
                bar.nameText:Hide()
            else
                bar.nameText:Show()
                bar.nameText:SetText("|cFFFFFFFF" .. mock.spellName .. " - " .. mock.summary .. "|r")
            end
            bar.cdBar:Hide()
            bar.barBg:SetVertexColor(0.28, 0.21, 0.05, 0.95)
            bar.cdText:SetText(tostring(mock.count))
            bar.cdText:SetTextColor(1.0, 0.82, 0.22)
        else
            local defData = allDefensives[mock.spellID]
            if defData then
                bar.icon:SetTexture(defData.icon or defaultSpellIcon)
                local col = classColors[mock.class] or fallbackWhite

                if style.showPlayerName == false and not style.showSpellName then
                    bar.nameText:Hide()
                else
                    bar.nameText:Show()
                    local label = C.BuildEntryLabel(style, mock.name, defData.name)
                    bar.nameText:SetText("|cFFFFFFFF" .. label .. "|r")
                end

                local readyWindow = 5
                local activeWindow = mock.duration
                local cycleLen = mock.baseCd + readyWindow
                local pos = (elapsed + mock.cdOffset) % cycleLen

                if pos < activeWindow then
                    local rem = activeWindow - pos
                    bar.cdBar:SetMinMaxValues(0, activeWindow)
                    bar.cdBar:SetValue(rem)
                    bar.cdBar:SetStatusBarColor(activeColor[1], activeColor[2], activeColor[3], 0.85)
                    bar.barBg:SetVertexColor(activeColor[1] * 0.25, activeColor[2] * 0.25, activeColor[3] * 0.25, 0.9)
                    bar.cdText:SetText(string.format("%.1fs", rem))
                    bar.cdText:SetTextColor(0.2, 1.0, 0.2)
                elseif pos < mock.baseCd then
                    local rem = mock.baseCd - pos
                    bar.cdBar:SetMinMaxValues(0, mock.baseCd)
                    bar.cdBar:SetValue(rem)
                    bar.cdBar:SetStatusBarColor(col[1], col[2], col[3], 0.85)
                    bar.barBg:SetVertexColor(col[1] * 0.25, col[2] * 0.25, col[3] * 0.25, 0.9)
                    bar.cdText:SetText(string.format("%.0f", rem))
                    bar.cdText:SetTextColor(1, 1, 1)
                else
                    bar.cdBar:SetMinMaxValues(0, 1)
                    bar.cdBar:SetValue(0)
                    bar.barBg:SetVertexColor(col[1], col[2], col[3], 0.85)
                    bar.cdText:SetText("READY")
                    bar.cdText:SetTextColor(0.2, 1.0, 0.2)
                end
            end
        end
    end

    pvContainer:SetAlpha(style.alpha or 0.9)
    pvContainer:SetSize(style.frameWidth or 240, titleH + #entries * (barH + 1))
end

local function RebuildPreview()
    if not pvContainer then
        return
    end
    CreatePreviewBars()
    UpdatePreview()
end

local function NormalizeLayoutScope(scope)
    if scope == "all" or scope == nil then
        return "all"
    end
    if layoutRefreshScope == "all" or (layoutRefreshScope and layoutRefreshScope ~= scope) then
        return "all"
    end
    return scope
end

local function FlushVisualLayout()
    local scope = layoutRefreshScope or "all"
    layoutRefreshTimer = nil
    layoutRefreshScope = nil

    if scope == "all" then
        if C.RebuildAllPaneBars then
            C.RebuildAllPaneBars()
        end
    elseif C.RebuildPaneBars then
        C.RebuildPaneBars(scope)
    end

    if C.RequestDisplayRefresh then
        C.RequestDisplayRefresh()
    end
    RebuildPreview()
end

local function ScheduleVisualLayout(scope)
    layoutRefreshScope = NormalizeLayoutScope(scope)
    if layoutRefreshTimer then
        return
    end
    layoutRefreshTimer = C_Timer.NewTimer(0.05, FlushVisualLayout)
end

local function RefreshVisualState()
    if C.RequestDisplayRefresh then
        C.RequestDisplayRefresh()
    end
    UpdatePreview()
end

local function ResolveLayoutScope(paneId)
    if paneId == "all" or (C.IsPaneLinked and C.IsPaneLinked(paneId)) then
        return "all"
    end
    return paneId
end

function C.BuildSettingsPage(parent, moduleDB)
    if not moduleDB then
        return
    end

    if C.SetDB then
        C.SetDB(moduleDB)
    end

    if C.EnsurePaneState then
        C.EnsurePaneState()
    end

    DestroyPreview()
    if C.EndSettingsLivePreview then
        C.EndSettingsLivePreview()
    end

    do
        local anchor = _G["MedaAurasSettingsPanel"]
        if anchor then
            pvContainer = CreateFrame("Frame", nil, anchor)
            pvContainer:SetFrameStrata("HIGH")
            pvContainer:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 0)
            pvContainer:SetClampedToScreen(true)
            pvContainer:SetScript("OnHide", function()
                if pvTicker then
                    pvTicker:Cancel()
                    pvTicker = nil
                end
            end)
            MedaAuras:RegisterConfigCleanup(pvContainer)

            local pvBg = pvContainer:CreateTexture(nil, "BACKGROUND")
            pvBg:SetAllPoints()
            pvBg:SetTexture(C.GetBarTexture and C.GetBarTexture() or "Interface\\BUTTONS\\WHITE8X8")
            pvBg:SetVertexColor(0.08, 0.08, 0.08, 0.85)

            pvStartTime = GetTime()
            CreatePreviewBars()
            UpdatePreview()

            pvTicker = C_Timer.NewTicker(0.1, UpdatePreview)
            if moduleDB.enabled and C.BeginSettingsLivePreview then
                C.BeginSettingsLivePreview(anchor)
                if C.RequestDisplayRefresh then
                    C.RequestDisplayRefresh()
                end
            end
        end
    end

    local LEFT_X = 0
    local RIGHT_X = 240
    local generalHeight
    local maxPaneHeight = 0

    local function ResetPanePositions()
        moduleDB.panePositions = {}
        moduleDB._crackedPanePositionMigrated = false
        if C.EnsurePaneState then
            C.EnsurePaneState()
        end
        local displayPaneIds = C.GetDisplayPaneIds and C.GetDisplayPaneIds() or {}
        for _, paneId in ipairs(displayPaneIds) do
            if C.ApplyPanePosition then
                C.ApplyPanePosition(paneId)
            end
        end
        RefreshVisualState()
    end

    local _, tabs = MedaAuras:CreateConfigTabs(parent, {
        { id = "general", label = "General" },
        { id = "all", label = "Everything" },
        { id = "external", label = "Externals" },
        { id = "party", label = "Party CDs" },
        { id = "major", label = "Major" },
        { id = "personal", label = "Minor" },
        { id = "buffs", label = "Buffs" },
    })

    local function BindPreviewTab(tabId, previewId)
        tabs[tabId]:HookScript("OnShow", function()
            if C.SetActiveSettingsPaneId then
                C.SetActiveSettingsPaneId(previewId)
            end
            RebuildPreview()
        end)
    end

    BindPreviewTab("general", "all")
    BindPreviewTab("all", "all")
    BindPreviewTab("external", "external")
    BindPreviewTab("party", "party")
    BindPreviewTab("major", "major")
    BindPreviewTab("personal", "personal")
    BindPreviewTab("buffs", "buffs")

    do
        local p = tabs.general
        local yOff = 0

        local header = MedaUI:CreateSectionHeader(p, "Cracked")
        header:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local enableCB = MedaUI:CreateCheckbox(p, "Enable Module")
        enableCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        enableCB:SetChecked(moduleDB.enabled)
        enableCB.OnValueChanged = function(_, checked)
            if checked then
                MedaAuras:EnableModule(MODULE_NAME)
            else
                MedaAuras:DisableModule(MODULE_NAME)
            end
            MedaAuras:RefreshSidebarDot(MODULE_NAME)
            if checked then
                C_Timer.After(0, function()
                    local anchor = _G["MedaAurasSettingsPanel"]
                    if C.BeginSettingsLivePreview then
                        C.BeginSettingsLivePreview(anchor)
                    end
                    RefreshVisualState()
                end)
            elseif C.EndSettingsLivePreview then
                C.EndSettingsLivePreview()
            end
        end

        local lockCB = MedaUI:CreateCheckbox(p, "Lock Pane Positions")
        lockCB:SetPoint("TOPLEFT", RIGHT_X, yOff)
        lockCB:SetChecked(moduleDB.locked)
        lockCB.OnValueChanged = function(_, checked)
            moduleDB.locked = checked
        end
        yOff = yOff - 35

        local modeDD = MedaUI:CreateLabeledDropdown(p, "Layout Mode", 200, {
            { value = "combined", label = "Everything In One Pane" },
            { value = "split", label = "Split By Category" },
        })
        modeDD:SetPoint("TOPLEFT", LEFT_X, yOff)
        modeDD:SetSelected(moduleDB.paneMode or "combined")
        modeDD.OnValueChanged = function(_, value)
            moduleDB.paneMode = value
            RefreshVisualState()
        end

        local modeControl = modeDD.GetControl and modeDD:GetControl() or modeDD
        local resetBtn = MedaUI:CreateButton(p, "Reset Pane Positions", 180)
        resetBtn:SetPoint("TOPLEFT", modeControl, "TOPRIGHT", 40, 0)
        resetBtn.OnClick = ResetPanePositions
        yOff = yOff - 66

        local info = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        info:SetPoint("TOPLEFT", LEFT_X, yOff)
        info:SetWidth(420)
        info:SetJustifyH("LEFT")
        info:SetTextColor(unpack(MedaUI.Theme.textDim))
        info:SetText("Linked category tabs inherit the Everything style until you unlink them.")
        yOff = yOff - 34

        local catHeader = MedaUI:CreateSectionHeader(p, "Tracked Categories")
        catHeader:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local extCB = MedaUI:CreateCheckbox(p, "Externals")
        extCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        extCB:SetChecked(moduleDB.showExternals ~= false)
        extCB.OnValueChanged = function(_, checked)
            moduleDB.showExternals = checked
            RefreshVisualState()
        end

        local partyCB = MedaUI:CreateCheckbox(p, "Party CDs")
        partyCB:SetPoint("TOPLEFT", RIGHT_X, yOff)
        partyCB:SetChecked(moduleDB.showPartyWide ~= false)
        partyCB.OnValueChanged = function(_, checked)
            moduleDB.showPartyWide = checked
            RefreshVisualState()
        end
        yOff = yOff - 30

        local majorCB = MedaUI:CreateCheckbox(p, "Major Personals")
        majorCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        majorCB:SetChecked(moduleDB.showMajor ~= false)
        majorCB.OnValueChanged = function(_, checked)
            moduleDB.showMajor = checked
            RefreshVisualState()
        end

        local personalCB = MedaUI:CreateCheckbox(p, "Minor Personals")
        personalCB:SetPoint("TOPLEFT", RIGHT_X, yOff)
        personalCB:SetChecked(moduleDB.showPersonal)
        personalCB.OnValueChanged = function(_, checked)
            moduleDB.showPersonal = checked
            RefreshVisualState()
        end
        yOff = yOff - 30

        local missingBuffsCB = MedaUI:CreateCheckbox(p, "Show Missing Group Buffs")
        missingBuffsCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        missingBuffsCB:SetChecked(moduleDB.showMissingGroupBuffs ~= false)
        missingBuffsCB.OnValueChanged = function(_, checked)
            moduleDB.showMissingGroupBuffs = checked
            if moduleDB.enabled and C.RefreshAuraWatches then
                C.RefreshAuraWatches()
            end
            RefreshVisualState()
            RebuildPreview()
        end

        local function RefreshTrackedCatalogOptions()
            if C.RefreshTrackedDefensiveState then
                C.RefreshTrackedDefensiveState(moduleDB)
            elseif C.SetDB then
                C.SetDB(moduleDB)
            end
            RefreshVisualState()
            RebuildPreview()
        end

        local experimentalCB = MedaUI:CreateCheckbox(p, "Track Experimental Defensives")
        experimentalCB:SetPoint("TOPLEFT", RIGHT_X, yOff)
        experimentalCB:SetChecked(moduleDB.trackExperimentalDefensives == true)
        experimentalCB.OnValueChanged = function(_, checked)
            moduleDB.trackExperimentalDefensives = checked and true or false
            RefreshTrackedCatalogOptions()
        end
        yOff = yOff - 30

        local importantCB = MedaUI:CreateCheckbox(p, "Track Experimental Important Buffs")
        importantCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        importantCB:SetChecked(moduleDB.trackExperimentalImportantBuffs == true)
        importantCB.OnValueChanged = function(_, checked)
            moduleDB.trackExperimentalImportantBuffs = checked and true or false
            RefreshTrackedCatalogOptions()
        end

        local riskyRaidCB = MedaUI:CreateCheckbox(p, "Track Risky Raid Effects")
        riskyRaidCB:SetPoint("TOPLEFT", RIGHT_X, yOff)
        riskyRaidCB:SetChecked(moduleDB.trackRiskyRaidEffects == true)
        riskyRaidCB.OnValueChanged = function(_, checked)
            moduleDB.trackRiskyRaidEffects = checked and true or false
            RefreshTrackedCatalogOptions()
        end
        yOff = yOff - 45

        local auraHeader = MedaUI:CreateSectionHeader(p, "Aura Tracking")
        auraHeader:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local fullRescanCB = MedaUI:CreateCheckbox(p, "Debug: Force Full Aura Rescan")
        fullRescanCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        fullRescanCB:SetChecked(moduleDB.forceFullAuraRescan)
        fullRescanCB.OnValueChanged = function(_, checked)
            moduleDB.forceFullAuraRescan = checked
            if moduleDB.enabled and C.RefreshAuraWatches then
                C.RefreshAuraWatches()
            end
            if moduleDB.enabled and ns.Services.GroupAuraTracker and ns.Services.GroupAuraTracker.RequestFullRescan then
                ns.Services.GroupAuraTracker:RequestFullRescan()
            end
        end
        yOff = yOff - 45

        local zoneHeader = MedaUI:CreateSectionHeader(p, "Show In")
        zoneHeader:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local function ZoneCB(label, key, x, y)
            local cb = MedaUI:CreateCheckbox(p, label)
            cb:SetPoint("TOPLEFT", x, y)
            cb:SetChecked(moduleDB[key])
            cb.OnValueChanged = function(_, checked)
                moduleDB[key] = checked
                if C.CheckZoneVisibility then
                    C.CheckZoneVisibility()
                end
            end
        end

        ZoneCB("Dungeons", "showInDungeon", LEFT_X, yOff)
        ZoneCB("Raids", "showInRaid", RIGHT_X, yOff)
        yOff = yOff - 30
        ZoneCB("Open World", "showInOpenWorld", LEFT_X, yOff)
        ZoneCB("Arena", "showInArena", RIGHT_X, yOff)
        yOff = yOff - 30
        ZoneCB("Battlegrounds", "showInBG", LEFT_X, yOff)

        generalHeight = math.abs(yOff - 80)
    end

    local function BuildPaneStyleTab(tabId, paneId)
        local p = tabs[tabId]
        local yOff = 0
        local isRefreshing = false

        local function Guard(callback)
            return function(...)
                if isRefreshing then
                    return
                end
                callback(...)
            end
        end

        local paneLabels = C.GetPaneLabels and C.GetPaneLabels() or {}
        local header = MedaUI:CreateSectionHeader(p, (paneLabels[paneId] or paneId) .. " Style")
        header:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local linkCB
        local stateLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        stateLabel:SetWidth(420)
        stateLabel:SetJustifyH("LEFT")
        stateLabel:SetTextColor(unpack(MedaUI.Theme.textDim))

        if paneId ~= "all" then
            linkCB = MedaUI:CreateCheckbox(p, "Link To Shared Style")
            linkCB:SetPoint("TOPLEFT", LEFT_X, yOff)
            yOff = yOff - 32
        end

        stateLabel:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 30

        local previewButton
        local previewLabel
        if paneId == "all" then
            previewButton = MedaUI:CreateButton(p, "Show Full Catalog Preview", 210)
            previewButton:SetPoint("TOPLEFT", LEFT_X, yOff)

            previewLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            previewLabel:SetPoint("TOPLEFT", previewButton, "BOTTOMLEFT", 0, -8)
            previewLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
            previewLabel:SetWidth(420)
            previewLabel:SetHeight(42)
            previewLabel:SetJustifyH("LEFT")
            previewLabel:SetText("Populate the live Cracked panes with every defensive and group buff we track.")
            yOff = yOff - 84
        end

        local fontDD = MedaUI:CreateLabeledDropdown(p, "Font", 200, MedaUI:GetFontList(), "font")
        fontDD:SetPoint("TOPLEFT", LEFT_X, yOff)
        local alphaSlider = MedaUI:CreateLabeledSlider(p, "Opacity", 200, 0.3, 1.0, 0.05)
        alphaSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
        yOff = yOff - 60

        local titleCB = MedaUI:CreateCheckbox(p, "Show Title")
        titleCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        local growCB = MedaUI:CreateCheckbox(p, "Grow Upward")
        growCB:SetPoint("TOPLEFT", RIGHT_X, yOff)
        yOff = yOff - 30

        local iconsCB = MedaUI:CreateCheckbox(p, "Show Icons")
        iconsCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        local namesCB = MedaUI:CreateCheckbox(p, "Show Player Name")
        namesCB:SetPoint("TOPLEFT", RIGHT_X, yOff)
        yOff = yOff - 30

        local spellCB = MedaUI:CreateCheckbox(p, "Show Spell Name")
        spellCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local widthSlider = MedaUI:CreateLabeledSlider(p, "Frame Width", 200, 140, 420, 10)
        widthSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
        local barSlider = MedaUI:CreateLabeledSlider(p, "Bar Height", 200, 12, 48, 1)
        barSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
        yOff = yOff - 60

        local iconSlider = MedaUI:CreateLabeledSlider(p, "Icon Size", 200, 0, 64, 1)
        iconSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
        local titleSlider = MedaUI:CreateLabeledSlider(p, "Title Text Size", 200, 8, 32, 1)
        titleSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
        yOff = yOff - 60

        local nameSlider = MedaUI:CreateLabeledSlider(p, "Name Text Size", 200, 0, 48, 1)
        nameSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
        local readySlider = MedaUI:CreateLabeledSlider(p, "Cooldown Text Size", 200, 0, 48, 1)
        readySlider:SetPoint("TOPLEFT", RIGHT_X, yOff)

        local function RefreshControls()
            local style = C.GetPaneStyle and C.GetPaneStyle(paneId) or {}
            isRefreshing = true

            if linkCB then
                local linked = C.IsPaneLinked and C.IsPaneLinked(paneId)
                linkCB:SetChecked(linked)
                stateLabel:SetText(linked
                    and "Linked: edits here update the shared Everything style."
                    or "Unlinked: this pane now keeps its own style.")
            else
                stateLabel:SetText("Editing this tab updates the shared source used by linked panes.")
            end

            if previewButton then
                local catalogPreviewEnabled = C.IsCatalogPreviewEnabled and C.IsCatalogPreviewEnabled() or false
                previewButton:SetText(catalogPreviewEnabled and "Hide Full Catalog Preview" or "Show Full Catalog Preview")
                previewButton:SetEnabled(moduleDB.enabled)
                if previewLabel then
                    if not moduleDB.enabled then
                        previewLabel:SetText("Enable Cracked to preview the live frames.")
                    elseif catalogPreviewEnabled then
                        previewLabel:SetText("Catalog preview is active in the live Cracked panes. Switch combined/split or restyle tabs to inspect the full tracked set.")
                    else
                        previewLabel:SetText("Populate the live Cracked panes with every defensive and group buff we track.")
                    end
                end
            end

            fontDD:SetSelected(style.font or "default")
            alphaSlider:SetValue(style.alpha or 0.9)
            titleCB:SetChecked(style.showTitle ~= false)
            growCB:SetChecked(style.growUp == true)
            iconsCB:SetChecked(style.showIcons ~= false)
            namesCB:SetChecked(style.showPlayerName ~= false)
            spellCB:SetChecked(style.showSpellName == true)
            widthSlider:SetValue(style.frameWidth or 240)
            barSlider:SetValue(style.barHeight or 24)
            iconSlider:SetValue(style.iconSize or 0)
            titleSlider:SetValue(style.titleFontSize or 12)
            nameSlider:SetValue(style.nameFontSize or 0)
            readySlider:SetValue(style.readyFontSize or 0)

            isRefreshing = false
        end

        if linkCB then
            linkCB.OnValueChanged = Guard(function(_, checked)
                if C.SetPaneLinked then
                    C.SetPaneLinked(paneId, checked)
                end
                RefreshControls()
                ScheduleVisualLayout(ResolveLayoutScope(paneId))
            end)
        end

        if previewButton then
            previewButton.OnClick = function()
                if not moduleDB.enabled then
                    return
                end
                if C.SetCatalogPreviewEnabled then
                    C.SetCatalogPreviewEnabled(not (C.IsCatalogPreviewEnabled and C.IsCatalogPreviewEnabled()))
                end
                RefreshControls()
                RefreshVisualState()
            end
        end

        fontDD.OnValueChanged = Guard(function(_, value) if C.SetPaneStyleValue then C.SetPaneStyleValue(paneId, "font", value) end ScheduleVisualLayout(ResolveLayoutScope(paneId)) end)
        alphaSlider.OnValueChanged = Guard(function(_, value) if C.SetPaneStyleValue then C.SetPaneStyleValue(paneId, "alpha", value) end ScheduleVisualLayout(ResolveLayoutScope(paneId)) end)
        titleCB.OnValueChanged = Guard(function(_, checked) if C.SetPaneStyleValue then C.SetPaneStyleValue(paneId, "showTitle", checked) end ScheduleVisualLayout(ResolveLayoutScope(paneId)) end)
        growCB.OnValueChanged = Guard(function(_, checked) if C.SetPaneStyleValue then C.SetPaneStyleValue(paneId, "growUp", checked) end ScheduleVisualLayout(ResolveLayoutScope(paneId)) end)
        iconsCB.OnValueChanged = Guard(function(_, checked) if C.SetPaneStyleValue then C.SetPaneStyleValue(paneId, "showIcons", checked) end ScheduleVisualLayout(ResolveLayoutScope(paneId)) end)
        namesCB.OnValueChanged = Guard(function(_, checked) if C.SetPaneStyleValue then C.SetPaneStyleValue(paneId, "showPlayerName", checked) end ScheduleVisualLayout(ResolveLayoutScope(paneId)) end)
        spellCB.OnValueChanged = Guard(function(_, checked) if C.SetPaneStyleValue then C.SetPaneStyleValue(paneId, "showSpellName", checked) end ScheduleVisualLayout(ResolveLayoutScope(paneId)) end)
        widthSlider.OnValueChanged = Guard(function(_, value) if C.SetPaneStyleValue then C.SetPaneStyleValue(paneId, "frameWidth", value) end ScheduleVisualLayout(ResolveLayoutScope(paneId)) end)
        barSlider.OnValueChanged = Guard(function(_, value) if C.SetPaneStyleValue then C.SetPaneStyleValue(paneId, "barHeight", value) end ScheduleVisualLayout(ResolveLayoutScope(paneId)) end)
        iconSlider.OnValueChanged = Guard(function(_, value) if C.SetPaneStyleValue then C.SetPaneStyleValue(paneId, "iconSize", value) end ScheduleVisualLayout(ResolveLayoutScope(paneId)) end)
        titleSlider.OnValueChanged = Guard(function(_, value) if C.SetPaneStyleValue then C.SetPaneStyleValue(paneId, "titleFontSize", value) end ScheduleVisualLayout(ResolveLayoutScope(paneId)) end)
        nameSlider.OnValueChanged = Guard(function(_, value) if C.SetPaneStyleValue then C.SetPaneStyleValue(paneId, "nameFontSize", value) end ScheduleVisualLayout(ResolveLayoutScope(paneId)) end)
        readySlider.OnValueChanged = Guard(function(_, value) if C.SetPaneStyleValue then C.SetPaneStyleValue(paneId, "readyFontSize", value) end ScheduleVisualLayout(ResolveLayoutScope(paneId)) end)

        p:HookScript("OnShow", RefreshControls)
        RefreshControls()

        maxPaneHeight = math.max(maxPaneHeight, math.abs(yOff - 90))
    end

    BuildPaneStyleTab("all", "all")
    BuildPaneStyleTab("external", "external")
    BuildPaneStyleTab("party", "party")
    BuildPaneStyleTab("major", "major")
    BuildPaneStyleTab("personal", "personal")
    BuildPaneStyleTab("buffs", "buffs")

    MedaAuras:SetContentHeight(math.max(generalHeight, maxPaneHeight, 760))
end
