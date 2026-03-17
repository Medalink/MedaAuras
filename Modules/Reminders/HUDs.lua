local _, ns = ...

local R = ns.Reminders or {}
ns.Reminders = R

local S = R.state or {}
R.state = S

local MedaUI = LibStub("MedaUI-2.0")

local CreateFont = CreateFont
local CreateFrame = CreateFrame
local format = format
local ipairs = ipairs
local math_floor = math.floor
local math_max = math.max
local pairs = pairs
local tostring = tostring

local OUTLINE_MAP = {
    none = "",
    outline = "OUTLINE",
    thick = "THICKOUTLINE",
}

local DISPEL_TYPE_META = {
    dispel_magic = {
        label = "Magic",
        color = { 0.2, 0.6, 1.0 },
    },
    dispel_curse = {
        label = "Curse",
        color = { 0.6, 0.2, 0.8 },
    },
    dispel_poison = {
        label = "Poison",
        color = { 0.0, 0.8, 0.27 },
    },
    dispel_disease = {
        label = "Disease",
        color = { 0.8, 0.53, 0.2 },
    },
    dispel_bleed = {
        label = "Bleed",
        color = { 0.8, 0.27, 0.27 },
    },
}

local HUD_DEFAULTS = {
    dispel = {
        enabled = true,
        showIcons = true,
        locked = false,
        filterMode = "mine",
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
}

local FALLBACK_POINT = {
    dispel = {
        point = "RIGHT",
        relativePoint = "RIGHT",
        x = -220,
        y = 120,
    },
    interrupt = {
        point = "RIGHT",
        relativePoint = "RIGHT",
        x = -220,
        y = -120,
    },
}

local FALLBACK_ICON = 136116
local FALLBACK_INTERRUPT_ICON = 132357
local SECTION_WIDTH = 300
local SECTION_INSET = 6
local HEADER_HEIGHT = 22
local TITLE_GAP = 16
local ROW_GAP = 4
local OVERFLOW_GAP = 6
local EMPTY_GAP = 6

local hudRuntime = S.hudRuntime or {
    fontCache = {},
    sections = {},
    rows = {
        dispel = {},
        interrupt = {},
    },
    overflowRows = {
        dispel = {},
        interrupt = {},
    },
}
S.hudRuntime = hudRuntime

local function CopyDefaults(dst, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(dst[key]) ~= "table" then
                dst[key] = {}
            end
            CopyDefaults(dst[key], value)
        elseif dst[key] == nil then
            dst[key] = value
        end
    end
end

local function EnsureHUDDB(moduleDB)
    moduleDB.huds = moduleDB.huds or {}
    CopyDefaults(moduleDB.huds, HUD_DEFAULTS)
    return moduleDB.huds
end

local function GetHUDDB(kind)
    local moduleDB = S.db
    if not moduleDB then
        return nil
    end

    local huds = EnsureHUDDB(moduleDB)
    return huds[kind]
end

local function GetFontObject(fontValue, size, outline)
    local path = MedaUI:GetFontPath(fontValue)
    local flags = OUTLINE_MAP[outline] or outline or ""
    local key = format("%s_%s_%s", tostring(path or "default"), tostring(size or 12), flags)
    if hudRuntime.fontCache[key] then
        return hudRuntime.fontCache[key]
    end

    local fontObject = CreateFont("MedaAurasRemindersHUD_" .. key:gsub("[^%w]", "_"))
    if path then
        fontObject:SetFont(path, size or 12, flags)
    else
        fontObject:CopyFontObject(GameFontNormal)
        local currentPath = fontObject:GetFont()
        fontObject:SetFont(currentPath, size or 12, flags)
    end

    hudRuntime.fontCache[key] = fontObject
    return fontObject
end

local function GetSeverityWeight(severity)
    if severity == "critical" or severity == "high" then return 3 end
    if severity == "warning" or severity == "medium" then return 2 end
    if severity == "info" or severity == "low" then return 1 end
    return 0
end

local function SafeText(value)
    if value == nil then return nil end
    if type(value) == "string" then
        local trimmed = value:match("^%s*(.-)%s*$")
        if trimmed == "" then return nil end
        return trimmed
    end
    return tostring(value)
end

local function GetCurrentContext()
    return (S.overrideContext or (R.GetCurrentContext and R.GetCurrentContext())) or nil
end

local function GetContextData()
    local data = R.GetData and R.GetData() or nil
    local ctx = GetCurrentContext()
    if not data or not ctx then
        return nil, nil, nil
    end

    local instanceCtx = R.ResolveInstanceContext and R.ResolveInstanceContext(data, ctx) or nil
    return data, ctx, instanceCtx
end

local function GetToolkitDangers(data, ctx)
    if not (data and ctx and R.EvaluatePlayerToolkit) then
        return nil
    end

    local toolkit = R.EvaluatePlayerToolkit(data, ctx)
    return toolkit and toolkit.dangers or nil
end

local function IsDispelCapability(capabilityID)
    return type(capabilityID) == "string" and capabilityID:find("^dispel_") ~= nil
end

local function GetProfileForFilter()
    return (R.GetLivePlayerProfile and R.GetLivePlayerProfile())
        or (R.GetViewerProfile and R.GetViewerProfile())
        or nil
end

local function ProfileHasCapability(profile, capability)
    if not profile or not capability or not capability.providers then
        return false
    end

    for _, provider in ipairs(capability.providers) do
        local classMatch = provider.class == profile.classToken
        local specMatch = (provider.specID == nil) or (provider.specID == profile.specID)
        if classMatch and specMatch then
            if profile.isLive then
                local spellID = provider.talentSpellID or provider.spellID
                if spellID and IsPlayerSpell and IsPlayerSpell(spellID) then
                    return true
                end
            else
                return true
            end
        end
    end

    return false
end

local function MakeEntryKey(danger)
    return table.concat({
        SafeText(danger and danger.capability) or "",
        SafeText(danger and danger.mechanic) or "",
        SafeText(danger and danger.source) or "",
    }, "|")
end

local function GetDangerIcon(data, danger, fallbackIcon)
    if danger and danger.spellID and GetSpellTexture then
        local texture = GetSpellTexture(danger.spellID)
        if texture then
            return texture
        end
    end

    local capability = data and data.capabilities and danger and danger.capability and data.capabilities[danger.capability] or nil
    if capability and capability.icon then
        return capability.icon
    end

    return fallbackIcon or FALLBACK_ICON
end

local function BuildDispelEntries(data, ctx, instanceCtx, config)
    if not (data and ctx and instanceCtx) then
        return {}
    end

    local dangers = GetToolkitDangers(data, ctx)
    if not dangers then
        return {}
    end

    local capabilityPriority = {}
    for index, capabilityID in ipairs(instanceCtx.dispelPriority or {}) do
        capabilityPriority[capabilityID] = index
    end

    local profile = GetProfileForFilter()
    local entries = {}
    local seen = {}

    for _, danger in ipairs(dangers) do
        local capabilityID = danger.capability
        if IsDispelCapability(capabilityID) and not seen[MakeEntryKey(danger)] then
            local capability = data.capabilities and data.capabilities[capabilityID] or nil
            local mineOnly = (config.filterMode or "mine") == "mine"
            if (not mineOnly) or ProfileHasCapability(profile, capability) then
                local meta = DISPEL_TYPE_META[capabilityID] or {
                    label = capability and capability.label or "Dispel",
                    color = { 1, 1, 1 },
                }

                entries[#entries + 1] = {
                    title = SafeText(danger.mechanic) or SafeText(capability and capability.label) or "Tracked Dispel",
                    detail = meta.label,
                    detailColor = meta.color,
                    icon = GetDangerIcon(data, danger, FALLBACK_ICON),
                    priority = capabilityPriority[capabilityID] or 999,
                    severityWeight = GetSeverityWeight(danger.severity),
                    sortLabel = (SafeText(danger.mechanic) or ""):lower(),
                }
                seen[MakeEntryKey(danger)] = true
            end
        end
    end

    table.sort(entries, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        if a.severityWeight ~= b.severityWeight then
            return a.severityWeight > b.severityWeight
        end
        return a.sortLabel < b.sortLabel
    end)

    return entries
end

local function BuildInterruptEntries(data, ctx, instanceCtx)
    if not (data and ctx and instanceCtx) then
        return {}
    end

    local dangers = GetToolkitDangers(data, ctx)
    if not dangers then
        return {}
    end

    local explicitPriority = {}
    for index, stop in ipairs(instanceCtx.interruptPriority or {}) do
        local key = format("%s|%s", SafeText(stop.spell) or "", SafeText(stop.mob) or "")
        explicitPriority[key] = index
    end

    local entries = {}
    local seen = {}
    for _, danger in ipairs(dangers) do
        local isInterrupt = danger.type == "interrupt" or danger.capability == "interrupt"
        if isInterrupt and not seen[MakeEntryKey(danger)] then
            local title = SafeText(danger.mechanic) or "Interrupt"
            local mob = SafeText(danger.source) or "Unknown Mob"
            local key = format("%s|%s", title, mob)

            entries[#entries + 1] = {
                title = title,
                detail = mob,
                detailColor = { 0.85, 0.72, 0.32 },
                icon = GetDangerIcon(data, danger, FALLBACK_INTERRUPT_ICON),
                priority = explicitPriority[key] or 999,
                severityWeight = GetSeverityWeight(danger.severity),
                sortLabel = title:lower(),
            }
            seen[MakeEntryKey(danger)] = true
        end
    end

    table.sort(entries, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        if a.severityWeight ~= b.severityWeight then
            return a.severityWeight > b.severityWeight
        end
        if a.sortLabel ~= b.sortLabel then
            return a.sortLabel < b.sortLabel
        end
        return (a.detail or "") < (b.detail or "")
    end)

    return entries
end

local function GetRowHeight(config)
    local titleSize = config.titleSize or 13
    local detailSize = config.detailSize or 11
    local iconSize = (config.showIcons ~= false) and (config.iconSize or 18) or 0
    return math_max(iconSize, titleSize + detailSize + 10)
end

local function CreateHUDRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.title = row:CreateFontString(nil, "OVERLAY")
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)
    row.title:SetShadowOffset(1, -1)
    row.title:SetShadowColor(0, 0, 0, 0.9)

    row.detail = row:CreateFontString(nil, "OVERLAY")
    row.detail:SetJustifyH("LEFT")
    row.detail:SetWordWrap(false)
    row.detail:SetShadowOffset(1, -1)
    row.detail:SetShadowColor(0, 0, 0, 0.9)

    function row:ApplyConfig(config)
        local width = SECTION_WIDTH - (SECTION_INSET * 2)
        local rowHeight = GetRowHeight(config)
        local iconSize = (config.showIcons ~= false) and (config.iconSize or 18) or 0
        local textLeft = iconSize > 0 and (iconSize + 8) or 0

        self:SetSize(width, rowHeight)

        self.icon:ClearAllPoints()
        if iconSize > 0 and self._iconTexture then
            self.icon:SetSize(iconSize, iconSize)
            self.icon:SetPoint("LEFT", self, "LEFT", 0, 0)
            self.icon:Show()
        else
            self.icon:Hide()
        end

        self.title:SetFontObject(GetFontObject(config.font or "default", config.titleSize or 13, config.outline or "outline"))
        self.detail:SetFontObject(GetFontObject(config.font or "default", config.detailSize or 11, config.outline or "outline"))

        self.title:ClearAllPoints()
        self.title:SetPoint("TOPLEFT", self, "TOPLEFT", textLeft, 0)
        self.title:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, 0)

        self.detail:ClearAllPoints()
        self.detail:SetPoint("TOPLEFT", self.title, "BOTTOMLEFT", 0, -2)
        self.detail:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, 0)
    end

    function row:SetEntry(entry, config)
        self._iconTexture = entry and entry.icon or nil
        if self._iconTexture then
            self.icon:SetTexture(self._iconTexture)
        end

        self:ApplyConfig(config)
        self.title:SetText(entry and entry.title or "")

        local detailColor = entry and entry.detailColor or { 0.75, 0.75, 0.75 }
        self.detail:SetText(entry and entry.detail or "")
        self.detail:SetTextColor(detailColor[1] or 1, detailColor[2] or 1, detailColor[3] or 1)
    end

    return row
end

local function AcquireRow(kind, poolName, index, parent)
    local pool = poolName == "overflow" and hudRuntime.overflowRows[kind] or hudRuntime.rows[kind]
    if pool[index] then
        return pool[index]
    end

    local row = CreateHUDRow(parent)
    pool[index] = row
    return row
end

local function HideExtraRows(kind, fromIndex, poolName)
    local pool = poolName == "overflow" and hudRuntime.overflowRows[kind] or hudRuntime.rows[kind]
    for index = fromIndex, #pool do
        pool[index]:Hide()
    end
end

local function GetSectionTitle(kind)
    if kind == "dispel" then
        return "Dispel HUD"
    end
    return "Interrupt HUD"
end

local function EnsureSection(kind)
    if hudRuntime.sections[kind] then
        return hudRuntime.sections[kind]
    end

    local config = GetHUDDB(kind)
    if not config then
        return nil
    end

    local section = MedaUI:CreateHUDSection(UIParent, {
        width = SECTION_WIDTH,
        height = 120,
        title = GetSectionTitle(kind),
        titleFont = "GameFontHighlightSmall",
        titleTone = "dim",
        titleAlpha = 0.85,
        showBackground = false,
        locked = config.locked or false,
    })
    section:SetFrameStrata("MEDIUM")
    section:RestorePosition(config.point, FALLBACK_POINT[kind])
    section.OnMove = function(_, state)
        local db = GetHUDDB(kind)
        if db and state then
            db.point = state
        end
    end

    local overflow = MedaUI:CreateCollapsibleSectionHeader(section, {
        text = "",
        width = SECTION_WIDTH - (SECTION_INSET * 2),
        height = 20,
        expanded = config.expanded or false,
        tone = "textDim",
        showLine = false,
    })
    overflow:SetOnToggle(function(expanded)
        local db = GetHUDDB(kind)
        if db then
            db.expanded = expanded and true or false
        end
        R.RefreshHUDs()
    end)
    overflow:Hide()

    local emptyLabel = MedaUI:CreateLabel(section, "", {
        fontObject = "GameFontNormalSmall",
        tone = "textDim",
        shadow = true,
        wrap = false,
    })
    emptyLabel:Hide()

    section.overflow = overflow
    section.emptyLabel = emptyLabel
    hudRuntime.sections[kind] = section
    return section
end

local function ApplySectionStyle(section, config)
    if not (section and config) then
        return
    end

    section:SetLocked(config.locked or false)
    if section.title then
        section.title:SetFontObject(GetFontObject(config.font or "default", (config.titleSize or 13) + 1, config.outline or "outline"))
    end
    if section.overflow and section.overflow.header then
        section.overflow.header:SetFontObject(GetFontObject(config.font or "default", config.detailSize or 11, config.outline or "outline"))
    end
    if section.overflow and section.overflow.badge then
        section.overflow.badge:SetFontObject(GetFontObject(config.font or "default", config.detailSize or 11, config.outline or "outline"))
    end
    if section.emptyLabel then
        section.emptyLabel:SetFontObject(GetFontObject(config.font or "default", config.detailSize or 11, config.outline or "outline"))
    end
end

local function LayoutEntries(kind, entries, emptyText)
    local config = GetHUDDB(kind)
    local section = EnsureSection(kind)
    if not (config and section) then
        return
    end

    ApplySectionStyle(section, config)
    section:SetTitle(GetSectionTitle(kind))

    if not entries or #entries == 0 then
        section.overflow:Hide()
        HideExtraRows(kind, 1, "main")
        HideExtraRows(kind, 1, "overflow")

        section.emptyLabel:SetText(emptyText or "")
        section.emptyLabel:ClearAllPoints()
        section.emptyLabel:SetPoint("TOPLEFT", section, "TOPLEFT", SECTION_INSET, -(HEADER_HEIGHT + EMPTY_GAP))
        section.emptyLabel:Show()

        section:SetHeight(HEADER_HEIGHT + 26)
        section:Show()
        return
    end

    section.emptyLabel:Hide()

    local rowHeight = GetRowHeight(config)
    local topCount = math_max(1, math_floor(config.topX or 6))
    local primaryCount = math.min(#entries, topCount)
    local overflowCount = math_max(0, #entries - primaryCount)
    local yOff = -(HEADER_HEIGHT + TITLE_GAP)

    for index = 1, primaryCount do
        local row = AcquireRow(kind, "main", index, section)
        row:SetParent(section)
        row:SetEntry(entries[index], config)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", section, "TOPLEFT", SECTION_INSET, yOff)
        row:Show()
        yOff = yOff - rowHeight - ROW_GAP
    end
    HideExtraRows(kind, primaryCount + 1, "main")

    if overflowCount > 0 then
        local overflow = section.overflow
        overflow:SetText(format("%d more", overflowCount))
        overflow:SetExpanded(config.expanded or false)
        overflow:ClearAllPoints()
        overflow:SetPoint("TOPLEFT", section, "TOPLEFT", SECTION_INSET, yOff - OVERFLOW_GAP)
        overflow:Show()
        yOff = yOff - 20 - OVERFLOW_GAP - 2

        if config.expanded then
            for index = 1, overflowCount do
                local row = AcquireRow(kind, "overflow", index, section)
                row:SetParent(section)
                row:SetEntry(entries[primaryCount + index], config)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", section, "TOPLEFT", SECTION_INSET, yOff)
                row:Show()
                yOff = yOff - rowHeight - ROW_GAP
            end
            HideExtraRows(kind, overflowCount + 1, "overflow")
        else
            HideExtraRows(kind, 1, "overflow")
        end
    else
        section.overflow:Hide()
        HideExtraRows(kind, 1, "overflow")
    end

    section:SetHeight(math_max(HEADER_HEIGHT + rowHeight, -yOff + 8))
    section:Show()
end

local function HideHUD(kind)
    local section = hudRuntime.sections[kind]
    if section then
        section:Hide()
    end
end

local function RefreshDispelHUD(data, ctx, instanceCtx)
    local config = GetHUDDB("dispel")
    if not config or config.enabled == false then
        HideHUD("dispel")
        return
    end

    local entries = BuildDispelEntries(data, ctx, instanceCtx, config)
    if not instanceCtx then
        HideHUD("dispel")
        return
    end

    local emptyText = nil
    if #entries == 0 then
        if (config.filterMode or "mine") == "mine" then
            emptyText = "No dispels you can handle in this content."
        else
            emptyText = "No tracked dispels in this content."
        end
    end
    LayoutEntries("dispel", entries, emptyText)
end

local function RefreshInterruptHUD(data, ctx, instanceCtx)
    local config = GetHUDDB("interrupt")
    if not config or config.enabled == false then
        HideHUD("interrupt")
        return
    end

    local entries = BuildInterruptEntries(data, ctx, instanceCtx)
    if not instanceCtx then
        HideHUD("interrupt")
        return
    end

    local emptyText = (#entries == 0) and "No tracked interrupts in this content." or nil
    LayoutEntries("interrupt", entries, emptyText)
end

function R.RefreshHUDs()
    if not S.isEnabled then
        HideHUD("dispel")
        HideHUD("interrupt")
        return
    end

    if not S.db then
        return
    end

    EnsureHUDDB(S.db)

    local data, ctx, instanceCtx = GetContextData()
    RefreshDispelHUD(data, ctx, instanceCtx)
    RefreshInterruptHUD(data, ctx, instanceCtx)
end

function R.HideHUDs()
    HideHUD("dispel")
    HideHUD("interrupt")
end

function R.EnsureHUDDB(moduleDB)
    return EnsureHUDDB(moduleDB)
end

function R.ResetHUDPosition(kind)
    local config = GetHUDDB(kind)
    local section = hudRuntime.sections[kind]
    if not config then
        return
    end

    config.point = nil
    if section then
        section:RestorePosition(nil, FALLBACK_POINT[kind])
    end
end

local function BuildGeneralHUDTab(parent)
    local yOff = 0

    local header = MedaUI:CreateSectionHeader(parent, "HUDs")
    header:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 42

    local note = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    note:SetPoint("TOPLEFT", 0, yOff)
    note:SetPoint("RIGHT", parent, "RIGHT", -12, 0)
    note:SetJustifyH("LEFT")
    note:SetWordWrap(true)
    note:SetTextColor(unpack(MedaUI.Theme.textDim or { 0.65, 0.65, 0.65 }))
    note:SetText("These overlays follow the current Reminders content selection. With no manual override selected in Reminders, they follow your live delve, dungeon, or raid context.")
    yOff = yOff - note:GetStringHeight() - 18

    local resetDispel = MedaUI:CreateButton(parent, "Reset Dispel HUD", 160)
    resetDispel:SetPoint("TOPLEFT", 0, yOff)
    resetDispel.OnClick = function()
        R.ResetHUDPosition("dispel")
        R.RefreshHUDs()
    end

    local resetInterrupt = MedaUI:CreateButton(parent, "Reset Interrupt HUD", 160)
    resetInterrupt:SetPoint("TOPLEFT", 190, yOff)
    resetInterrupt.OnClick = function()
        R.ResetHUDPosition("interrupt")
        R.RefreshHUDs()
    end

    yOff = yOff - 52

    local dragNote = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dragNote:SetPoint("TOPLEFT", 0, yOff)
    dragNote:SetPoint("RIGHT", parent, "RIGHT", -12, 0)
    dragNote:SetJustifyH("LEFT")
    dragNote:SetWordWrap(true)
    dragNote:SetTextColor(unpack(MedaUI.Theme.textDim or { 0.65, 0.65, 0.65 }))
    dragNote:SetText("Unlock a HUD to drag it directly on screen. Overflow rows stay collapsed until you expand the section header under the visible top list.")
    yOff = yOff - dragNote:GetStringHeight() - 12

    return math.abs(yOff) + 80
end

local function BuildSpecificHUDTab(parent, kind)
    local config = GetHUDDB(kind)
    if not config then
        return 0
    end

    local LEFT_X = 0
    local RIGHT_X = 260
    local yOff = 0

    local title = kind == "dispel" and "Dispel HUD" or "Interrupt HUD"
    local header = MedaUI:CreateSectionHeader(parent, title)
    header:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 44

    local enableCb = MedaUI:CreateCheckbox(parent, "Enable HUD")
    enableCb:SetPoint("TOPLEFT", LEFT_X, yOff)
    enableCb:SetChecked(config.enabled ~= false)
    enableCb.OnValueChanged = function(_, checked)
        config.enabled = checked
        R.RefreshHUDs()
    end

    local lockCb = MedaUI:CreateCheckbox(parent, "Lock Position")
    lockCb:SetPoint("TOPLEFT", RIGHT_X, yOff)
    lockCb:SetChecked(config.locked or false)
    lockCb.OnValueChanged = function(_, checked)
        config.locked = checked
        R.RefreshHUDs()
    end
    yOff = yOff - 30

    local iconCb = MedaUI:CreateCheckbox(parent, "Show Icons")
    iconCb:SetPoint("TOPLEFT", LEFT_X, yOff)
    iconCb:SetChecked(config.showIcons ~= false)
    iconCb.OnValueChanged = function(_, checked)
        config.showIcons = checked
        R.RefreshHUDs()
    end

    if kind == "dispel" then
        local filterDd = MedaUI:CreateLabeledDropdown(parent, "Filter", 200, {
            { value = "mine", label = "Dispellable By Me" },
            { value = "all", label = "Show All Dispels" },
        })
        filterDd:SetPoint("TOPLEFT", RIGHT_X, yOff + 8)
        filterDd:SetSelected(config.filterMode or "mine")
        filterDd.OnValueChanged = function(_, value)
            config.filterMode = value or "mine"
            R.RefreshHUDs()
        end
    end
    yOff = yOff - 50

    local topSlider = MedaUI:CreateLabeledSlider(parent, "Show Top X", 200, 1, 20, 1)
    topSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
    topSlider:SetValue(config.topX or 6)
    topSlider.OnValueChanged = function(_, value)
        config.topX = math_floor(value or 6)
        R.RefreshHUDs()
    end

    local iconSlider = MedaUI:CreateLabeledSlider(parent, "Icon Size", 200, 0, 32, 1)
    iconSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
    iconSlider:SetValue(config.iconSize or 18)
    iconSlider.OnValueChanged = function(_, value)
        config.iconSize = math_floor(value or 18)
        R.RefreshHUDs()
    end
    yOff = yOff - 56

    local fontDd = MedaUI:CreateLabeledDropdown(parent, "Font", 200, MedaUI:GetFontList(), "font")
    fontDd:SetPoint("TOPLEFT", LEFT_X, yOff)
    fontDd:SetSelected(config.font or "default")
    fontDd.OnValueChanged = function(_, value)
        config.font = value or "default"
        R.RefreshHUDs()
    end

    local outlineDd = MedaUI:CreateLabeledDropdown(parent, "Outline", 200, {
        { value = "none", label = "None" },
        { value = "outline", label = "Outline" },
        { value = "thick", label = "Thick Outline" },
    })
    outlineDd:SetPoint("TOPLEFT", RIGHT_X, yOff)
    outlineDd:SetSelected(config.outline or "outline")
    outlineDd.OnValueChanged = function(_, value)
        config.outline = value or "outline"
        R.RefreshHUDs()
    end
    yOff = yOff - 58

    local titleSlider = MedaUI:CreateLabeledSlider(parent, "Title Text Size", 200, 8, 24, 1)
    titleSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
    titleSlider:SetValue(config.titleSize or 13)
    titleSlider.OnValueChanged = function(_, value)
        config.titleSize = math_floor(value or 13)
        R.RefreshHUDs()
    end

    local detailSlider = MedaUI:CreateLabeledSlider(parent, "Detail Text Size", 200, 8, 20, 1)
    detailSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
    detailSlider:SetValue(config.detailSize or 11)
    detailSlider.OnValueChanged = function(_, value)
        config.detailSize = math_floor(value or 11)
        R.RefreshHUDs()
    end
    yOff = yOff - 62

    local resetBtn = MedaUI:CreateButton(parent, "Reset Position", 140)
    resetBtn:SetPoint("TOPLEFT", LEFT_X, yOff)
    resetBtn.OnClick = function()
        R.ResetHUDPosition(kind)
        R.RefreshHUDs()
    end

    return math.abs(yOff) + 90
end

function R.BuildHUDSettingsPage(parent, moduleDB)
    if not parent or not moduleDB then
        return 720
    end

    S.db = moduleDB
    EnsureHUDDB(moduleDB)

    local _, tabs = MedaAuras:CreateConfigTabs(parent, {
        { id = "general", label = "General" },
        { id = "dispel", label = "Dispel HUD" },
        { id = "interrupt", label = "Interrupt HUD" },
    })

    local generalHeight = BuildGeneralHUDTab(tabs.general)
    local dispelHeight = BuildSpecificHUDTab(tabs.dispel, "dispel")
    local interruptHeight = BuildSpecificHUDTab(tabs.interrupt, "interrupt")

    return math_max(generalHeight, dispelHeight, interruptHeight, 720)
end
