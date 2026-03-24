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
local table_sort = table.sort
local tostring = tostring
local GET_SPELL_TEXTURE = _G and _G.GetSpellTexture or nil

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

local HUD_META = {
    dispel = {
        title = "Key Dispels",
        settingsPage = "dispelhud",
        fallbackPoint = {
            point = "RIGHT",
            relativePoint = "RIGHT",
            x = -220,
            y = 180,
        },
    },
    interrupt = {
        title = "Key Interrupts",
        settingsPage = "interrupthud",
        fallbackPoint = {
            point = "RIGHT",
            relativePoint = "RIGHT",
            x = -220,
            y = 20,
        },
    },
    boss = {
        title = "Boss Tips",
        settingsPage = "bosstipshud",
        fallbackPoint = {
            point = "RIGHT",
            relativePoint = "RIGHT",
            x = -220,
            y = -140,
        },
    },
    tricks = {
        title = "Tips & Tricks",
        settingsPage = "tipsandtrickshud",
        fallbackPoint = {
            point = "RIGHT",
            relativePoint = "RIGHT",
            x = -220,
            y = -300,
        },
    },
}

local HUD_KINDS = { "dispel", "interrupt", "boss", "tricks" }

local HUD_DEFAULTS = {
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
}

local FALLBACK_ICON = 136116
local FALLBACK_INTERRUPT_ICON = 132357
local FALLBACK_BOSS_ICON = 236344
local FALLBACK_TRICK_ICON = 134400
local SECTION_WIDTH = 300
local SECTION_INSET = 6
local HEADER_HEIGHT = 22
local TITLE_GAP = 16
local ROW_GAP = 4
local OVERFLOW_GAP = 6
local EMPTY_GAP = 6
local HUD_SETTINGS_PAGES = {
    dispel = "dispelhud",
    interrupt = "interrupthud",
    boss = "bosstipshud",
    tricks = "tipsandtrickshud",
}

local hudRuntime = S.hudRuntime or {
    fontCache = {},
    sections = {},
    rows = {
        dispel = {},
        interrupt = {},
        boss = {},
        tricks = {},
    },
    overflowRows = {
        dispel = {},
        interrupt = {},
        boss = {},
        tricks = {},
    },
}
S.hudRuntime = hudRuntime

local BuildDispelEntries
local BuildInterruptEntries
local BuildBossEntries
local BuildTrickEntries
local IsDispelCapability
local GetProfileForFilter
local ProfileHasCapability
local GetDangerIcon

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

local function IsHUDSettingsPreviewActive(kind)
    if not (R.IsHUDSettingsPreviewActive and HUD_SETTINGS_PAGES[kind]) then
        return false
    end

    return R.IsHUDSettingsPreviewActive(kind) == true
end

local function ResolveSpellID(spellRef)
    if R.ResolveSpellID then
        return R.ResolveSpellID(spellRef)
    end

    if type(spellRef) == "number" and spellRef > 0 then
        return spellRef
    end

    return nil
end

local function GetDungeonTimerInfo(ctx, instanceCtx)
    if R.GetDungeonTimerInfo then
        return R.GetDungeonTimerInfo(ctx, instanceCtx)
    end
    return nil
end

local function GetDispelTypeKey(danger)
    if not danger then return nil end
    if type(danger.dispelType) == "string" and danger.dispelType ~= "" then
        return danger.dispelType:lower()
    end
    if type(danger.capability) == "string" and danger.capability:match("^dispel_") then
        return danger.capability:gsub("^dispel_", ""):lower()
    end
    return nil
end

local function TrimSummary(value, maxLength)
    local text = SafeText(value)
    local limit = maxLength or 96
    if not text or #text <= limit then
        return text
    end

    local trimmed = text:sub(1, math.max(1, limit - 3))
    trimmed = trimmed:gsub("%s+%S*$", "")
    return trimmed .. "..."
end

local function GetBossSortRank(value)
    local text = SafeText(value)
    if not text then return 50 end

    local lower = text:lower()
    if lower:find("1st boss", 1, true) or lower:find("first boss", 1, true) then return 1 end
    if lower:find("2nd boss", 1, true) or lower:find("second boss", 1, true) then return 2 end
    if lower:find("3rd boss", 1, true) or lower:find("third boss", 1, true) then return 3 end
    if lower:find("4th boss", 1, true) or lower:find("fourth boss", 1, true) then return 4 end
    if lower:find("final boss", 1, true) or lower:find("last boss", 1, true) then return 99 end
    if lower:find("all bosses", 1, true) then return 90 end
    if lower:find("boss", 1, true) then return 70 end
    return 50
end

local function BuildHUDPageDetail(entry, bodyLimit)
    local contextParts = {}
    if SafeText(entry and entry.encounter) then
        contextParts[#contextParts + 1] = entry.encounter
    end
    if SafeText(entry and entry.source) then
        contextParts[#contextParts + 1] = entry.source
    elseif SafeText(entry and entry.mob) then
        contextParts[#contextParts + 1] = entry.mob
    end

    local summary = TrimSummary(entry and entry.body, bodyLimit or 92)
    if #contextParts > 0 and summary then
        return table.concat(contextParts, " • ") .. " - " .. summary
    end
    if #contextParts > 0 then
        return table.concat(contextParts, " • ")
    end
    return summary
end

local function FormatClockDuration(seconds)
    if type(seconds) ~= "number" or seconds <= 0 then
        return nil
    end

    local total = math.floor(seconds + 0.5)
    return format("%d:%02d", math.floor(total / 60), total % 60)
end

local function CreateTimerHUDEntry(timerInfo)
    if not (timerInfo and timerInfo.timeLimitSeconds) then
        return nil
    end

    local detail = "Beat timer: " .. (timerInfo.timeLimitLabel or FormatClockDuration(timerInfo.timeLimitSeconds) or tostring(timerInfo.timeLimitSeconds))
    if timerInfo.source == "api" then
        detail = detail .. " - live M+ timer"
    end

    return {
        title = "Dungeon Timer",
        detail = detail,
        detailColor = { 1.0, 0.78, 0.36 },
        icon = 134376,
        priority = 1,
        severityWeight = 3,
        sortLabel = "dungeon timer",
    }
end

local function SplitNormalizedTipText(value, fallbackTitle)
    local text = SafeText(value)
    if not text then return fallbackTitle or "Tip", nil, nil end

    local prefix, body = text:match("^(.-):%s*(.+)$")
    if prefix and body then
        return prefix, body, prefix
    end

    return fallbackTitle or "Tip", text, nil
end

local function BuildPreviewCandidates(data)
    local candidates = {}
    local seen = {}

    local function AddCandidate(ctx, instanceCtx)
        if not (ctx and instanceCtx) then
            return
        end

        local key = tostring(ctx.instanceType or "?") .. ":" .. tostring(ctx.instanceID or ctx.instanceName or "?")
        if seen[key] then
            return
        end

        seen[key] = true
        candidates[#candidates + 1] = {
            ctx = ctx,
            instanceCtx = instanceCtx,
        }
    end

    local currentCtx = GetCurrentContext()
    if currentCtx and R.ResolveInstanceContext then
        AddCandidate(currentCtx, R.ResolveInstanceContext(data, currentCtx))
    end

    if S.lastContext and R.ResolveInstanceContext then
        AddCandidate(S.lastContext, R.ResolveInstanceContext(data, S.lastContext))
    end

    local dungeons = data and data.contexts and data.contexts.dungeons or nil
    if dungeons then
        local ordered = {}
        for instanceID, dungeon in pairs(dungeons) do
            if type(dungeon) == "table" then
                ordered[#ordered + 1] = {
                    instanceID = tonumber(instanceID) or instanceID,
                    dungeon = dungeon,
                }
            end
        end

        table_sort(ordered, function(a, b)
            local aName = SafeText(a and a.dungeon and a.dungeon.name) or ""
            local bName = SafeText(b and b.dungeon and b.dungeon.name) or ""
            if aName ~= bName then
                return aName < bName
            end
            return tostring(a and a.instanceID or "") < tostring(b and b.instanceID or "")
        end)

        for _, entry in ipairs(ordered) do
            AddCandidate({
                inInstance = true,
                instanceType = "party",
                instanceID = entry.instanceID,
                instanceName = entry.dungeon.name,
            }, entry.dungeon)
        end
    end

    return candidates
end

local function BuildPreviewDispelEntries(data, instanceCtx, config)
    if not (data and instanceCtx and config) then
        return {}
    end

    local capabilityPriority = {}
    for index, capabilityID in ipairs(instanceCtx.dispelPriority or {}) do
        capabilityPriority[capabilityID] = index
    end

    local profile = GetProfileForFilter()
    local entries = {}
    for _, danger in ipairs(instanceCtx.keyDispels or {}) do
        local capabilityID = danger.capability
        if IsDispelCapability(capabilityID) or capabilityID == "offensive_dispel" or capabilityID == "soothe" then
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
            end
        end
    end

    table_sort(entries, function(a, b)
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

local function BuildPreviewInterruptEntries(data, instanceCtx)
    if not instanceCtx then
        return {}
    end

    local entries = {}
    for index, stop in ipairs(instanceCtx.keyInterrupts or {}) do
        local title = SafeText(stop.spell) or SafeText(stop.spellName) or "Interrupt"
        local detail = BuildHUDPageDetail({
            encounter = stop.encounter,
            source = stop.mob or "Unknown Mob",
            body = stop.tip,
        }, 88)
        entries[#entries + 1] = {
            title = title,
            detail = detail,
            detailColor = { 0.85, 0.72, 0.32 },
            icon = GetDangerIcon(data, {
                mechanic = title,
                source = stop.mob,
                spellID = stop.spellID or ResolveSpellID(title),
                capability = "interrupt",
                type = "interrupt",
                icon = stop.icon,
            }, FALLBACK_INTERRUPT_ICON),
            priority = index,
            severityWeight = GetSeverityWeight(stop.danger),
            sortLabel = title:lower(),
        }
    end

    table_sort(entries, function(a, b)
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

local function BuildPreviewBossEntries(_, _, instanceCtx)
    local entries = {}

    for index, text in ipairs(instanceCtx and instanceCtx.bossTips or {}) do
        local title, detail, encounter = SplitNormalizedTipText(text, "Boss Tip")
        entries[#entries + 1] = {
            title = title,
            detail = BuildHUDPageDetail({
                encounter = encounter,
                body = detail,
            }, 104),
            detailColor = { 1.0, 0.78, 0.36 },
            icon = FALLBACK_BOSS_ICON,
            priority = GetBossSortRank(encounter or title) + index,
            severityWeight = 3,
            sortLabel = (title or ""):lower(),
        }
    end

    table_sort(entries, function(a, b)
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

local function BuildPreviewTrickEntries(_, ctx, instanceCtx)
    local entries = {}
    local seen = {}

    if S.db and S.db.showDungeonTimers ~= false then
        local timerEntry = CreateTimerHUDEntry(GetDungeonTimerInfo(ctx, instanceCtx))
        if timerEntry then
            entries[#entries + 1] = timerEntry
            seen.timer = true
        end
    end

    for _, text in ipairs(instanceCtx and instanceCtx.tipsAndTricks or {}) do
        local title, detail, encounter = SplitNormalizedTipText(text, "Tip")
        local signature = table.concat({
            SafeText(title) or "",
            SafeText(encounter) or "",
            SafeText(detail) or "",
        }, "|")
        if not seen[signature] then
            entries[#entries + 1] = {
                title = title,
                detail = BuildHUDPageDetail({
                    encounter = encounter,
                    body = detail,
                }, 100),
                detailColor = { 0.85, 0.78, 0.42 },
                icon = FALLBACK_TRICK_ICON,
                priority = 2,
                severityWeight = 2,
                sortLabel = (title or ""):lower(),
            }
            seen[signature] = true
        end
    end

    table_sort(entries, function(a, b)
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

local function GetPreviewEntries(kind)
    local data = R.GetData and R.GetData() or nil
    local config = GetHUDDB(kind)
    if not (data and config) then
        return {}
    end

    local candidates = BuildPreviewCandidates(data)
    for _, candidate in ipairs(candidates) do
        local entries
        if kind == "dispel" then
            entries = BuildPreviewDispelEntries(data, candidate.instanceCtx, config)
            if #entries == 0 and (config.filterMode or "mine") == "mine" then
                local previewConfig = {}
                for key, value in pairs(config) do
                    previewConfig[key] = value
                end
                previewConfig.filterMode = "all"
                entries = BuildPreviewDispelEntries(data, candidate.instanceCtx, previewConfig)
            end
        elseif kind == "interrupt" then
            entries = BuildPreviewInterruptEntries(data, candidate.instanceCtx)
        elseif kind == "boss" then
            entries = BuildPreviewBossEntries(data, candidate.ctx, candidate.instanceCtx)
        else
            entries = BuildPreviewTrickEntries(data, candidate.ctx, candidate.instanceCtx)
        end

        if entries and #entries > 0 then
            return entries
        end
    end

    return {}
end

IsDispelCapability = function(capabilityID)
    return type(capabilityID) == "string" and capabilityID:find("^dispel_") ~= nil
end

GetProfileForFilter = function()
    return (R.GetLivePlayerProfile and R.GetLivePlayerProfile())
        or (R.GetViewerProfile and R.GetViewerProfile())
        or nil
end

ProfileHasCapability = function(profile, capability)
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

GetDangerIcon = function(data, danger, fallbackIcon)
    if danger and type(danger.icon) == "number" and danger.icon > 0 then
        return danger.icon
    end

    if danger and danger.spellID and GET_SPELL_TEXTURE then
        local texture = GET_SPELL_TEXTURE(danger.spellID)
        if texture then
            return texture
        end
    end

    local spellID = ResolveSpellID(danger and danger.mechanic)
    if spellID and GET_SPELL_TEXTURE then
        local texture = GET_SPELL_TEXTURE(spellID)
        if texture then
            return texture
        end
    end

    local capability = data and data.capabilities and danger and danger.capability and data.capabilities[danger.capability] or nil
    if capability and capability.icon then
        return capability.icon
    end

    if danger and (danger.type == "interrupt" or danger.capability == "interrupt") then
        return FALLBACK_INTERRUPT_ICON
    end

    local dispelType = GetDispelTypeKey(danger)
    if dispelType == "magic" then return 135894 end
    if dispelType == "curse" then return 135952 end
    if dispelType == "poison" then return 136068 end
    if dispelType == "disease" then return 135935 end
    if dispelType == "bleed" then return 4630445 end

    return fallbackIcon or FALLBACK_ICON
end

BuildDispelEntries = function(data, ctx, instanceCtx, config)
    if not (data and instanceCtx and config) then
        return {}
    end

    return BuildPreviewDispelEntries(data, instanceCtx, config)
end

BuildInterruptEntries = function(data, ctx, instanceCtx)
    if not (data and instanceCtx) then
        return {}
    end

    return BuildPreviewInterruptEntries(data, instanceCtx)
end

BuildBossEntries = function(data, ctx, instanceCtx)
    if not (data and ctx) then
        return {}
    end

    return BuildPreviewBossEntries(data, ctx, instanceCtx)
end

BuildTrickEntries = function(data, ctx, instanceCtx)
    if not (data and ctx) then
        return {}
    end

    return BuildPreviewTrickEntries(data, ctx, instanceCtx)
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
    return (HUD_META[kind] and HUD_META[kind].title) or "Reminders HUD"
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
    section:RestorePosition(config.point, HUD_META[kind] and HUD_META[kind].fallbackPoint or nil)
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

local function GetEntriesForKind(kind, data, ctx, instanceCtx, config)
    if kind == "dispel" then
        return BuildDispelEntries(data, ctx, instanceCtx, config)
    end
    if kind == "interrupt" then
        return BuildInterruptEntries(data, ctx, instanceCtx)
    end
    if kind == "boss" then
        return BuildBossEntries(data, ctx, instanceCtx)
    end
    return BuildTrickEntries(data, ctx, instanceCtx)
end

local function GetEmptyTextForKind(kind, config)
    if kind == "dispel" then
        if (config.filterMode or "all") == "mine" then
            return "No dispels you can handle in this content."
        end
        return "No tracked dispels in this content."
    end
    if kind == "interrupt" then
        return "No tracked interrupts in this content."
    end
    if kind == "boss" then
        return "No boss tips in this content."
    end
    return "No extra tricks in this content."
end

local function RefreshHUD(kind, data, ctx, instanceCtx)
    local config = GetHUDDB(kind)
    if not config or config.enabled == false then
        HideHUD(kind)
        return
    end

    if not instanceCtx then
        if IsHUDSettingsPreviewActive(kind) then
            LayoutEntries(kind, GetPreviewEntries(kind))
        else
            HideHUD(kind)
        end
        return
    end

    local entries = GetEntriesForKind(kind, data, ctx, instanceCtx, config)
    local emptyText = (#entries == 0) and GetEmptyTextForKind(kind, config) or nil
    LayoutEntries(kind, entries, emptyText)
end

function R.RefreshHUDs()
    if not S.isEnabled then
        for _, kind in ipairs(HUD_KINDS) do
            HideHUD(kind)
        end
        return
    end

    if not S.db then
        return
    end

    EnsureHUDDB(S.db)

    local data, ctx, instanceCtx = GetContextData()
    for _, kind in ipairs(HUD_KINDS) do
        RefreshHUD(kind, data, ctx, instanceCtx)
    end
end

function R.HideHUDs()
    for _, kind in ipairs(HUD_KINDS) do
        HideHUD(kind)
    end
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
        section:RestorePosition(nil, HUD_META[kind] and HUD_META[kind].fallbackPoint or nil)
    end
end

local function BuildSpecificHUDTab(parent, kind)
    local config = GetHUDDB(kind)
    if not config then
        return 0
    end

    local LEFT_X = 0
    local RIGHT_X = 260
    local yOff = 0

    local title = GetSectionTitle(kind)
    local header = MedaUI:CreateSectionHeader(parent, title)
    header:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 44

    local note = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    note:SetPoint("TOPLEFT", LEFT_X, yOff)
    note:SetPoint("RIGHT", parent, "RIGHT", -12, 0)
    note:SetJustifyH("LEFT")
    note:SetWordWrap(true)
    note:SetTextColor(unpack(MedaUI.Theme.textDim or { 0.65, 0.65, 0.65 }))
    note:SetText("This overlay follows the current Reminders content selection. While this page is open, a mock HUD appears on screen so you can tune and drag it directly.")
    yOff = yOff - note:GetStringHeight() - 18

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
            { value = "all", label = "Show Group Dispels" },
            { value = "mine", label = "Only Mine" },
        })
        filterDd:SetPoint("TOPLEFT", RIGHT_X, yOff + 8)
        filterDd:SetSelected(config.filterMode or "all")
        filterDd.OnValueChanged = function(_, value)
            config.filterMode = value or "all"
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

    local resetLabel = "Reset " .. GetSectionTitle(kind)
    local resetBtn = MedaUI:CreateButton(parent, resetLabel, 160)
    resetBtn:SetPoint("TOPLEFT", LEFT_X, yOff)
    resetBtn.OnClick = function()
        R.ResetHUDPosition(kind)
        R.RefreshHUDs()
    end

    return math.abs(yOff) + 90
end

function R.BuildHUDSettingsTab(parent, moduleDB, kind)
    if not parent or not moduleDB then
        return 720
    end

    S.db = moduleDB
    EnsureHUDDB(moduleDB)
    return math_max(BuildSpecificHUDTab(parent, kind), 720)
end
