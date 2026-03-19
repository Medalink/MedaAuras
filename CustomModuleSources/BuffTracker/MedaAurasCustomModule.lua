local MedaUI = LibStub("MedaUI-2.0")

local C_Spell = C_Spell
local C_UnitAuras = C_UnitAuras
local CreateFrame = CreateFrame
local GetTime = GetTime
local STANDARD_TEXT_FONT = STANDARD_TEXT_FONT
local UIParent = UIParent
local UnitExists = UnitExists
local format = format
local ipairs = ipairs
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local tonumber = tonumber
local tostring = tostring
local unpack = unpack or table.unpack
local wipe = wipe

local MODULE_ID = "padding"
local MODULE_NAME = "Padding"
local MODULE_VERSION = "0.8"
local MODULE_AUTHOR = "Medalink"
local MODULE_DESCRIPTION = "Shows one draggable icon per configured player buff with countdown timers."

local DEFAULT_ICON = 134400
local ICON_SPACING = 6
local PREVIEW_SPACING = 12
local SUCCESS_COLOR = { 0.3, 0.85, 0.3 }
local WARNING_COLOR = { 1.0, 0.7, 0.2 }
local ERROR_COLOR = { 1.0, 0.35, 0.35 }
local AURA_WATCH_KEY = "PaddingPlayerBuffs"

local state = {
    db = nil,
    configPreviewActive = false,
    runtimeHost = nil,
    runtimeWidgets = {},
    runtimeDisplays = {},
    trackedSpells = {},
    trackedLookup = {},
    eventFrame = nil,
    elapsed = 0,
}

local IsSettingsPreviewVisible

local MODULE_DEFAULTS = {
    enabled = false,
    spellIdsText = "",
    spellIds = {},
    locked = true,
    iconSize = 56,
    iconAlpha = 1,
    textSize = 18,
    backgroundOpacity = 0.55,
    showBorder = true,
    borderColor = { r = 1.0, g = 0.82, b = 0.0 },
    position = { point = "CENTER", x = 0, y = 0 },
}

local function EnsurePosition(db)
    db.position = db.position or {}
    db.position.point = db.position.point or "CENTER"
    db.position.x = tonumber(db.position.x) or 0
    db.position.y = tonumber(db.position.y) or 0
end

local function BuildSpellText(ids)
    local parts = {}
    for i, spellId in ipairs(ids or {}) do
        parts[i] = tostring(spellId)
    end
    return table.concat(parts, ", ")
end

local function ParseSpellIds(rawText)
    local ids = {}
    local seen = {}

    rawText = tostring(rawText or "")
    for token in rawText:gmatch("%d+") do
        local spellId = tonumber(token)
        if spellId and spellId > 0 and not seen[spellId] then
            seen[spellId] = true
            ids[#ids + 1] = spellId
        end
    end

    return ids
end

local function GetSpellDetails(spellId)
    local name
    local icon

    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
        if ok and type(info) == "table" then
            name = info.name
            icon = info.iconID
        end
    end

    if (not name or not icon) and GetSpellInfo then
        local ok, legacyName, _, legacyIcon = pcall(GetSpellInfo, spellId)
        if ok then
            name = name or legacyName
            icon = icon or legacyIcon
        end
    end

    if not icon and C_Spell and C_Spell.GetSpellTexture then
        local ok, texture = pcall(C_Spell.GetSpellTexture, spellId)
        if ok then
            icon = texture
        end
    end

    return name, icon
end

local function BuildSpellEntries(ids)
    local entries = {}
    local lookup = {}
    local unresolved = 0

    for _, spellId in ipairs(ids or {}) do
        local name, icon = GetSpellDetails(spellId)
        local entry = {
            spellId = spellId,
            name = name or ("Unknown Spell " .. tostring(spellId)),
            icon = icon or DEFAULT_ICON,
            resolved = name ~= nil or icon ~= nil,
        }
        if not entry.resolved then
            unresolved = unresolved + 1
        end
        entries[#entries + 1] = entry
        lookup[spellId] = entry
    end

    return entries, lookup, unresolved
end

local function RefreshConfiguredSpells(db)
    local ids = ParseSpellIds(db.spellIdsText)
    if #ids == 0 and type(db.spellIds) == "table" and #db.spellIds > 0 then
        ids = ParseSpellIds(BuildSpellText(db.spellIds))
    end

    db.spellIds = ids
    db.spellIdsText = BuildSpellText(ids)
    state.trackedSpells, state.trackedLookup = BuildSpellEntries(ids)
end

local function FormatRemaining(seconds)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then
        return ""
    end
    if seconds >= 3600 then
        return format("%dh", math_floor(seconds / 3600 + 0.5))
    end
    if seconds >= 60 then
        local minutes = math_floor(seconds / 60)
        local remainder = math_floor(seconds % 60)
        return format("%d:%02d", minutes, remainder)
    end
    if seconds >= 10 then
        return tostring(math_floor(seconds + 0.5))
    end
    return format("%.1f", seconds)
end

local function GetAuraTracker()
    return MedaAuras and MedaAuras.ns and MedaAuras.ns.Services and MedaAuras.ns.Services.GroupAuraTracker or nil
end

local function SyncAuraWatch()
    local tracker = GetAuraTracker()
    if not tracker or not tracker.Initialize or not tracker.RegisterWatch then
        return
    end

    tracker:Initialize()

    if #state.trackedSpells == 0 then
        if tracker.UnregisterWatch then
            tracker:UnregisterWatch(AURA_WATCH_KEY)
        end
        return
    end

    local spells = {}
    for _, entry in ipairs(state.trackedSpells) do
        spells[#spells + 1] = {
            spellID = entry.spellId,
            name = entry.name,
            filter = "HELPFUL",
        }
    end

    tracker:RegisterWatch(AURA_WATCH_KEY, {
        spells = spells,
        filter = "HELPFUL",
        rescanMode = "unit",
    })

    if tracker.RequestWatchScan then
        tracker:RequestWatchScan(AURA_WATCH_KEY, "player")
    end
end

local function GetTrackedAuraMap()
    local auraBySpellId = {}
    local tracker = GetAuraTracker()

    if tracker and tracker.GetUnitSpellState then
        for _, entry in ipairs(state.trackedSpells) do
            local auraState = tracker:GetUnitSpellState(AURA_WATCH_KEY, "player", entry.spellId)
            if auraState and auraState.active then
                auraBySpellId[entry.spellId] = {
                    spellId = entry.spellId,
                    icon = entry.icon,
                    duration = auraState.duration,
                    expirationTime = auraState.expirationTime,
                    applications = auraState.applications,
                }
            end
        end

        if next(auraBySpellId) then
            return auraBySpellId
        end
    end

    if not UnitExists("player") or not C_UnitAuras or not C_UnitAuras.GetBuffDataByIndex then
        return auraBySpellId
    end

    for index = 1, 255 do
        local ok, aura = pcall(C_UnitAuras.GetBuffDataByIndex, "player", index)
        if not ok or not aura then
            break
        end
        if aura.spellId and state.trackedLookup[aura.spellId] then
            auraBySpellId[aura.spellId] = aura
        end
    end

    return auraBySpellId
end

local function CreateIconWidget(parent)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetBackdrop(MedaUI:CreateBackdrop(true))

    frame.icon = frame:CreateTexture(nil, "ARTWORK")
    frame.icon:SetPoint("TOPLEFT", 4, -4)
    frame.icon:SetPoint("BOTTOMRIGHT", -4, 4)
    frame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    frame.cooldown = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
    frame.cooldown:SetAllPoints(frame.icon)
    frame.cooldown:SetReverse(false)
    frame.cooldown:SetHideCountdownNumbers(true)
    if frame.cooldown.SetDrawBling then
        frame.cooldown:SetDrawBling(false)
    end
    if frame.cooldown.SetDrawEdge then
        frame.cooldown:SetDrawEdge(false)
    end
    if frame.cooldown.SetDrawSwipe then
        frame.cooldown:SetDrawSwipe(true)
    end
    frame.cooldown:Hide()

    frame.timeText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.timeText:SetPoint("CENTER", 0, 0)
    frame.timeText:SetJustifyH("CENTER")
    frame.timeText:SetShadowOffset(1, -1)
    frame.timeText:SetShadowColor(0, 0, 0, 1)

    frame.stackText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.stackText:SetPoint("BOTTOMRIGHT", -3, 3)
    frame.stackText:SetJustifyH("RIGHT")
    frame.stackText:SetShadowOffset(1, -1)
    frame.stackText:SetShadowColor(0, 0, 0, 1)

    return frame
end

local function ApplyWidgetStyle(widget, db, size, alphaOverride)
    local borderColor = db.borderColor or MODULE_DEFAULTS.borderColor
    local bgAlpha = tonumber(db.backgroundOpacity) or MODULE_DEFAULTS.backgroundOpacity
    local textSize = math_max(8, tonumber(db.textSize) or MODULE_DEFAULTS.textSize)

    widget:SetSize(size, size)
    widget:SetAlpha(alphaOverride or tonumber(db.iconAlpha) or MODULE_DEFAULTS.iconAlpha)
    widget:SetBackdropColor(0, 0, 0, bgAlpha)
    widget.timeText:SetFont(STANDARD_TEXT_FONT, textSize, "OUTLINE")
    widget.stackText:SetFont(STANDARD_TEXT_FONT, math_max(10, math_floor(textSize * 0.7)), "OUTLINE")

    if db.showBorder == false then
        widget:SetBackdropBorderColor(0, 0, 0, 0)
    else
        widget:SetBackdropBorderColor(
            borderColor.r or MODULE_DEFAULTS.borderColor.r,
            borderColor.g or MODULE_DEFAULTS.borderColor.g,
            borderColor.b or MODULE_DEFAULTS.borderColor.b,
            1
        )
    end
end

local function GetAuraStacks(aura)
    if type(aura) ~= "table" then
        return 0
    end

    return tonumber(aura.applications)
        or tonumber(aura.stackCount)
        or tonumber(aura.charges)
        or tonumber(aura.count)
        or 0
end

local function ApplyDisplayToWidget(widget, display, db, size, alphaOverride)
    ApplyWidgetStyle(widget, db, size, alphaOverride)

    widget.icon:SetTexture((display.entry and display.entry.icon) or DEFAULT_ICON)
    widget.timeText:SetText("")
    widget.stackText:SetText("")

    if display.aura then
        local expirationTime = tonumber(display.aura.expirationTime) or 0
        local duration = tonumber(display.aura.duration) or 0
        local remaining = expirationTime - GetTime()
        local stacks = GetAuraStacks(display.aura)

        widget.icon:SetTexture(display.aura.icon or widget.icon:GetTexture() or DEFAULT_ICON)
        widget.icon:SetDesaturated(false)

        if duration > 0 and expirationTime > 0 then
            widget.cooldown:SetCooldown(expirationTime - duration, duration)
            widget.cooldown:Show()
            widget.timeText:SetText(FormatRemaining(remaining))
        else
            widget.cooldown:Hide()
        end

        if stacks and stacks > 1 then
            widget.stackText:SetText(tostring(stacks))
        end
    else
        widget.cooldown:Hide()
        widget.icon:SetDesaturated(true)
        if display.previewTime then
            widget.timeText:SetText(display.previewTime)
        elseif display.placeholder then
            widget.timeText:SetText("12")
        end
        if display.previewStacks and display.previewStacks > 1 then
            widget.stackText:SetText(tostring(display.previewStacks))
        end
    end

    widget:Show()
end

local function EnsureRuntimeHost()
    if state.runtimeHost then
        return state.runtimeHost
    end

    local host = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    host:SetFrameStrata("MEDIUM")
    host:SetClampedToScreen(true)
    host:EnableMouse(true)
    host:SetMovable(true)
    host:RegisterForDrag("LeftButton")
    host:SetBackdrop(MedaUI:CreateBackdrop(true))
    host:SetBackdropColor(0, 0, 0, 0)
    host:SetBackdropBorderColor(0, 0, 0, 0)

    host:SetScript("OnDragStart", function(self)
        if state.db and (IsSettingsPreviewVisible() or state.db.locked == false) then
            self:StartMoving()
        end
    end)

    host:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if state.db then
            EnsurePosition(state.db)
            local point, _, _, x, y = self:GetPoint()
            state.db.position.point = point or "CENTER"
            state.db.position.x = x or 0
            state.db.position.y = y or 0
        end
    end)

    state.runtimeHost = host
    return host
end

local function ApplyRuntimePosition(db)
    local host = EnsureRuntimeHost()
    EnsurePosition(db)
    host:ClearAllPoints()
    host:SetPoint(db.position.point, UIParent, db.position.point, db.position.x, db.position.y)
end

local function EnsureRuntimeWidget(index)
    if state.runtimeWidgets[index] then
        return state.runtimeWidgets[index]
    end

    local host = EnsureRuntimeHost()
    local widget = CreateIconWidget(host)
    widget:EnableMouse(false)
    state.runtimeWidgets[index] = widget
    return widget
end

local function HideUnusedRuntimeWidgets(fromIndex)
    for index = fromIndex, #state.runtimeWidgets do
        state.runtimeWidgets[index]:Hide()
    end
end

function IsSettingsPreviewVisible()
    if not state.configPreviewActive then
        return false
    end

    if not MedaAuras or not MedaAuras.GetActiveSettingsSelection then
        return false
    end

    local activeModuleId = MedaAuras:GetActiveSettingsSelection()
    if not activeModuleId then
        return false
    end

    if MedaAuras.GetCustomModuleKey then
        return activeModuleId == MedaAuras:GetCustomModuleKey(MODULE_ID)
    end

    return false
end

local function ShouldShowSettingsPreview()
    return IsSettingsPreviewVisible()
end

local function ShouldShowUnlockedPreview(db)
    return db and db.locked == false
end

local function ShouldShowAnyDisplay(db)
    return (db and db.enabled) or ShouldShowSettingsPreview() or ShouldShowUnlockedPreview(db)
end

local function RefreshRuntimeDisplay()
    local db = state.db
    local host = EnsureRuntimeHost()
    local showSettingsPreview = ShouldShowSettingsPreview()
    local showUnlockedPreview = ShouldShowUnlockedPreview(db)

    if not db or not ShouldShowAnyDisplay(db) then
        wipe(state.runtimeDisplays)
        host:Hide()
        host:SetScript("OnUpdate", nil)
        HideUnusedRuntimeWidgets(1)
        return
    end

    RefreshConfiguredSpells(db)

    local activeDisplays = {}
    local auraBySpellId = GetTrackedAuraMap()
    for _, entry in ipairs(state.trackedSpells) do
        local aura = auraBySpellId[entry.spellId]
        if aura then
            activeDisplays[#activeDisplays + 1] = {
                entry = entry,
                aura = aura,
            }
        end
    end

    if showSettingsPreview and #activeDisplays > 0 then
        state.runtimeDisplays = activeDisplays
    elseif db.enabled and #activeDisplays > 0 then
        state.runtimeDisplays = activeDisplays
    elseif showSettingsPreview then
        state.runtimeDisplays = {}
        if #state.trackedSpells == 0 then
            state.runtimeDisplays[1] = {
                entry = {
                    icon = DEFAULT_ICON,
                    name = "Preview",
                },
                placeholder = true,
                preview = true,
                previewTime = "12",
                previewStacks = 2,
            }
        else
            for _, entry in ipairs(state.trackedSpells) do
                state.runtimeDisplays[#state.runtimeDisplays + 1] = {
                    entry = entry,
                    preview = true,
                    previewTime = "12",
                    previewStacks = 2,
                }
            end
        end
    elseif showUnlockedPreview then
        state.runtimeDisplays = {}
        if #state.trackedSpells == 0 then
            state.runtimeDisplays[1] = {
                entry = {
                    icon = DEFAULT_ICON,
                    name = "Preview",
                },
                placeholder = true,
                preview = true,
                previewTime = "12",
                previewStacks = 2,
            }
        else
            for _, entry in ipairs(state.trackedSpells) do
                state.runtimeDisplays[#state.runtimeDisplays + 1] = {
                    entry = entry,
                    preview = true,
                    previewTime = "12",
                    previewStacks = 2,
                }
            end
        end
    else
        state.runtimeDisplays = activeDisplays
    end

    if #state.runtimeDisplays == 0 then
        host:Hide()
        host:SetScript("OnUpdate", nil)
        HideUnusedRuntimeWidgets(1)
        return
    end

    local size = math_max(24, tonumber(db.iconSize) or MODULE_DEFAULTS.iconSize)
    local width = (#state.runtimeDisplays * size) + (math_max(#state.runtimeDisplays - 1, 0) * ICON_SPACING)

    host:SetSize(width, size)
    ApplyRuntimePosition(db)
    host:Show()

    for index, display in ipairs(state.runtimeDisplays) do
        local widget = EnsureRuntimeWidget(index)
        widget:ClearAllPoints()
        widget:SetPoint("LEFT", host, "LEFT", (index - 1) * (size + ICON_SPACING), 0)
        ApplyDisplayToWidget(widget, display, db, size, display.preview and ((tonumber(db.iconAlpha) or 1) * 0.7) or nil)
    end

    HideUnusedRuntimeWidgets(#state.runtimeDisplays + 1)

    local hasTimer = false
    for _, display in ipairs(state.runtimeDisplays) do
        local aura = display.aura
        if aura and tonumber(aura.duration) and tonumber(aura.duration) > 0 and tonumber(aura.expirationTime) and tonumber(aura.expirationTime) > 0 then
            hasTimer = true
            break
        end
    end

    if not hasTimer then
        host:SetScript("OnUpdate", nil)
        return
    end

    host:SetScript("OnUpdate", function(_, elapsed)
        state.elapsed = state.elapsed + elapsed
        if state.elapsed < 0.05 then
            return
        end
        state.elapsed = 0

        local now = GetTime()
        for index, display in ipairs(state.runtimeDisplays) do
            if display.aura then
                local remaining = (tonumber(display.aura.expirationTime) or 0) - now
                if remaining <= 0 then
                    RefreshRuntimeDisplay()
                    return
                end
                local widget = state.runtimeWidgets[index]
                if widget then
                    widget.timeText:SetText(FormatRemaining(remaining))
                end
            end
        end
    end)
end

local function EnsureEventFrame()
    if state.eventFrame then
        return state.eventFrame
    end

    local frame = CreateFrame("Frame")
    frame:SetScript("OnEvent", function(_, event, unit)
        if event == "UNIT_AURA" and unit ~= "player" then
            return
        end
        RefreshRuntimeDisplay()
    end)
    state.eventFrame = frame
    return frame
end

local function RegisterEvents()
    local frame = EnsureEventFrame()
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("UNIT_AURA")
end

local function UnregisterEvents()
    if state.eventFrame then
        state.eventFrame:UnregisterAllEvents()
    end
end

local function OnInitialize(db)
    state.db = db
    RefreshConfiguredSpells(db)
    SyncAuraWatch()
    EnsureRuntimeHost()
end

local function OnEnable(db)
    state.db = db
    RefreshConfiguredSpells(db)
    SyncAuraWatch()
    RegisterEvents()
    RefreshRuntimeDisplay()
end

local function OnDisable()
    if not ShouldShowSettingsPreview() then
        UnregisterEvents()
    end
    wipe(state.runtimeDisplays)
    if state.runtimeHost and not ShouldShowAnyDisplay(state.db) then
        state.runtimeHost:Hide()
        state.runtimeHost:SetScript("OnUpdate", nil)
    end
    HideUnusedRuntimeWidgets(1)
end

local function SetStatus(label, message, color)
    label:SetText(message or "")
    if color then
        label:SetTextColor(color[1], color[2], color[3])
    else
        label:SetTextColor(unpack(MedaUI.Theme.text))
    end
end

local function BuildConfig(parent, db)
    local LEFT_X = 0
    local RIGHT_X = 250
    local PREVIEW_WIDTH = 500
    local yOff = 0

    state.db = db
    state.configPreviewActive = true
    RefreshConfiguredSpells(db)
    SyncAuraWatch()
    RegisterEvents()

    local cleanup = CreateFrame("Frame", nil, parent)
    cleanup:SetAllPoints(parent)
    cleanup:Show()
    cleanup:SetScript("OnHide", function()
        state.configPreviewActive = false
        if state.db and not state.db.enabled then
            UnregisterEvents()
        end
        RefreshRuntimeDisplay()
    end)
    if MedaAuras.RegisterConfigCleanup then
        MedaAuras:RegisterConfigCleanup(cleanup)
    end

    local title = MedaUI:CreateSectionHeader(parent, MODULE_NAME)
    title:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 40

    local summary = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    summary:SetPoint("TOPLEFT", LEFT_X, yOff)
    summary:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
    summary:SetJustifyH("LEFT")
    summary:SetWordWrap(true)
    summary:SetText("Enter one or more player buff spell IDs separated by commas or spaces. While this settings page is open, the icon group is always shown and can be dragged. When settings are closed, locked mode hides the group until one of the tracked buffs is actually active.")
    summary:SetTextColor(unpack(MedaUI.Theme.textDim or { 0.7, 0.7, 0.7, 1 }))
    yOff = yOff - summary:GetStringHeight() - 20

    local spellHeader = MedaUI:CreateSectionHeader(parent, "Tracked Spell IDs")
    spellHeader:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 36

    local spellInput = MedaUI:CreateEditBox(parent, 340, 24)
    spellInput:SetPoint("TOPLEFT", LEFT_X, yOff)
    spellInput:SetText(db.spellIdsText or "")

    local applyBtn = MedaUI:CreateButton(parent, "Apply", 90)
    applyBtn:SetPoint("LEFT", spellInput, "RIGHT", 10, 0)

    local statusText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("TOPLEFT", LEFT_X, yOff - 30)
    statusText:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
    statusText:SetJustifyH("LEFT")
    statusText:SetWordWrap(true)
    yOff = yOff - 66

    local previewHeader = MedaUI:CreateSectionHeader(parent, "Preview")
    previewHeader:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 34

    local previewHolder = CreateFrame("Frame", nil, parent)
    previewHolder:SetPoint("TOPLEFT", LEFT_X, yOff)
    previewHolder:SetSize(PREVIEW_WIDTH, 80)

    local previewWidgets = {}
    local previewCaptions = {}

    local function ReleasePreviewWidgets()
        for _, widget in ipairs(previewWidgets) do
            widget:Hide()
            widget:SetParent(nil)
        end
        wipe(previewWidgets)

        for _, caption in ipairs(previewCaptions) do
            caption:Hide()
            caption:SetParent(nil)
        end
        wipe(previewCaptions)
    end

    local appearanceHeader = MedaUI:CreateSectionHeader(parent, "Appearance")
    local lockCB = MedaUI:CreateCheckbox(parent, "Locked")
    local borderCB = MedaUI:CreateCheckbox(parent, "Show Border")
    local sizeSlider = MedaUI:CreateLabeledSlider(parent, "Icon Size", 200, 24, 120, 2)
    local textSlider = MedaUI:CreateLabeledSlider(parent, "Countdown Size", 200, 8, 36, 1)
    local alphaSlider = MedaUI:CreateLabeledSlider(parent, "Icon Alpha", 200, 10, 100, 5)
    local bgSlider = MedaUI:CreateLabeledSlider(parent, "Background Opacity", 200, 0, 100, 5)
    local borderPicker = MedaUI:CreateLabeledColorPicker(parent, "Border Color")
    local footerNote = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

    local function BuildPreviewDisplays()
        local displays = {}
        local auraBySpellId = GetTrackedAuraMap()

        if #state.trackedSpells == 0 then
            displays[1] = {
                entry = {
                    icon = DEFAULT_ICON,
                    name = "Preview",
                },
                placeholder = true,
                caption = "Add a spell ID",
                previewTime = "12",
                previewStacks = 2,
            }
            return displays
        end

        for _, entry in ipairs(state.trackedSpells) do
            displays[#displays + 1] = {
                entry = entry,
                aura = auraBySpellId[entry.spellId],
                caption = "#" .. tostring(entry.spellId),
                previewTime = "12",
                previewStacks = 2,
            }
        end

        return displays
    end

    local function RefreshAllVisuals()
        local displays = BuildPreviewDisplays()
        local previewSize = math_min(math_max(32, tonumber(db.iconSize) or MODULE_DEFAULTS.iconSize), 72)
        local cellHeight = previewSize + 18
        local columns = math_max(1, math_floor((PREVIEW_WIDTH + PREVIEW_SPACING) / (previewSize + PREVIEW_SPACING)))

        ReleasePreviewWidgets()

        for index, display in ipairs(displays) do
            local column = (index - 1) % columns
            local row = math_floor((index - 1) / columns)
            local x = column * (previewSize + PREVIEW_SPACING)
            local y = -(row * cellHeight)

            local widget = CreateIconWidget(previewHolder)
            widget:SetPoint("TOPLEFT", x, y)
            ApplyDisplayToWidget(widget, display, db, previewSize, display.aura and nil or ((tonumber(db.iconAlpha) or 1) * 0.85))
            previewWidgets[#previewWidgets + 1] = widget

            local caption = previewHolder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            caption:SetPoint("TOP", widget, "BOTTOM", 0, -4)
            caption:SetWidth(previewSize + 20)
            caption:SetJustifyH("CENTER")
            caption:SetWordWrap(false)
            caption:SetText(display.caption)
            caption:SetTextColor(unpack(MedaUI.Theme.textDim or { 0.7, 0.7, 0.7, 1 }))
            previewCaptions[#previewCaptions + 1] = caption
        end

        local rows = math_max(1, math_floor((#displays - 1) / columns) + 1)
        previewHolder:SetHeight(rows * cellHeight)

        appearanceHeader:SetPoint("TOPLEFT", previewHolder, "BOTTOMLEFT", 0, -20)
        lockCB:SetPoint("TOPLEFT", appearanceHeader, "BOTTOMLEFT", 0, -12)
        borderCB:SetPoint("TOPLEFT", appearanceHeader, "BOTTOMLEFT", RIGHT_X, -12)
        sizeSlider:SetPoint("TOPLEFT", lockCB, "BOTTOMLEFT", 0, -18)
        textSlider:SetPoint("TOPLEFT", borderCB, "BOTTOMLEFT", 0, -18)
        alphaSlider:SetPoint("TOPLEFT", sizeSlider, "BOTTOMLEFT", 0, -20)
        bgSlider:SetPoint("TOPLEFT", textSlider, "BOTTOMLEFT", 0, -20)
        borderPicker:SetPoint("TOPLEFT", alphaSlider, "BOTTOMLEFT", 0, -20)

        if #state.trackedSpells == 0 then
            SetStatus(statusText, "Add one or more spell IDs, then click Apply. A placeholder icon stays visible in the preview until then.", WARNING_COLOR)
        else
            local unresolved = 0
            for _, entry in ipairs(state.trackedSpells) do
                if not entry.resolved then
                    unresolved = unresolved + 1
                end
            end

            if unresolved > 0 then
                SetStatus(statusText, format("Saved %d spell ID(s). %d could not be resolved yet, but each buff will still track independently if WoW returns it at runtime.", #state.trackedSpells, unresolved), WARNING_COLOR)
            else
                SetStatus(statusText, format("Saved %d spell ID(s). Each configured buff now displays as its own icon instead of collapsing to one shared icon.", #state.trackedSpells), SUCCESS_COLOR)
            end
        end

        borderPicker:SetAlpha((db.showBorder == false) and 0.4 or 1)
        RefreshRuntimeDisplay()

        footerNote:SetPoint("TOPLEFT", bgSlider, "BOTTOMLEFT", 0, -26)
        footerNote:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
        footerNote:SetJustifyH("LEFT")
        footerNote:SetWordWrap(true)
        footerNote:SetText("Visibility rules: settings open always shows the group and allows dragging. Settings closed + unlocked keeps the preview visible. Settings closed + locked hides the group until a tracked buff is actually active on the player.")
        footerNote:SetTextColor(unpack(MedaUI.Theme.textDim or { 0.7, 0.7, 0.7, 1 }))

        local totalHeight = math_max(860, 760 + previewHolder:GetHeight() + footerNote:GetStringHeight())
        MedaAuras:SetContentHeight(totalHeight)
    end

    lockCB:SetChecked(db.locked ~= false)
    lockCB.OnValueChanged = function(_, checked)
        db.locked = checked
        RefreshAllVisuals()
    end

    borderCB:SetChecked(db.showBorder ~= false)
    borderCB.OnValueChanged = function(_, checked)
        db.showBorder = checked
        RefreshAllVisuals()
    end

    sizeSlider:SetValue(db.iconSize or MODULE_DEFAULTS.iconSize)
    sizeSlider.OnValueChanged = function(_, value)
        db.iconSize = value
        RefreshAllVisuals()
    end

    textSlider:SetValue(db.textSize or MODULE_DEFAULTS.textSize)
    textSlider.OnValueChanged = function(_, value)
        db.textSize = value
        RefreshAllVisuals()
    end

    alphaSlider:SetValue((db.iconAlpha or MODULE_DEFAULTS.iconAlpha) * 100)
    alphaSlider.OnValueChanged = function(_, value)
        db.iconAlpha = value / 100
        RefreshAllVisuals()
    end

    bgSlider:SetValue((db.backgroundOpacity or MODULE_DEFAULTS.backgroundOpacity) * 100)
    bgSlider.OnValueChanged = function(_, value)
        db.backgroundOpacity = value / 100
        RefreshAllVisuals()
    end

    do
        local borderColor = db.borderColor or MODULE_DEFAULTS.borderColor
        borderPicker:SetColor(
            borderColor.r or MODULE_DEFAULTS.borderColor.r,
            borderColor.g or MODULE_DEFAULTS.borderColor.g,
            borderColor.b or MODULE_DEFAULTS.borderColor.b
        )
    end
    borderPicker.OnColorChanged = function(_, r, g, b)
        db.borderColor = { r = r, g = g, b = b }
        RefreshAllVisuals()
    end

    local function ApplySpellInput(text)
        db.spellIds = ParseSpellIds(text)
        db.spellIdsText = BuildSpellText(db.spellIds)
        spellInput:SetText(db.spellIdsText)
        RefreshConfiguredSpells(db)
        SyncAuraWatch()
        RefreshAllVisuals()
    end

    applyBtn:SetScript("OnClick", function()
        ApplySpellInput(spellInput:GetText())
    end)

    spellInput.OnEnterPressed = function(_, text)
        ApplySpellInput(text)
    end

    RefreshAllVisuals()
end

MedaAuras:RegisterCustomModule({
    moduleId = MODULE_ID,
    name = MODULE_NAME,
    title = MODULE_NAME,
    version = MODULE_VERSION,
    author = MODULE_AUTHOR,
    description = MODULE_DESCRIPTION,
    dataVersion = 1,
    stability = "stable",
    sidebarDesc = "Tracks configured player buffs and shows one draggable icon per active buff.",
    defaults = MODULE_DEFAULTS,
    OnInitialize = OnInitialize,
    OnEnable = OnEnable,
    OnDisable = OnDisable,
    BuildConfig = BuildConfig,
})
