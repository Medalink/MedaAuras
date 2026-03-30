local ADDON_NAME, ns = ...

local C = ns.Cracked or {}
ns.Cracked = C

local MedaUI = LibStub("MedaUI-2.0")

local format = format
local GetTime = GetTime
local pairs = pairs
local ipairs = ipairs
local wipe = wipe
local pcall = pcall
local sort = table.sort
local CreateFrame = CreateFrame
local CreateFont = _G and _G.CreateFont
local UnitName = UnitName
local UnitExists = UnitExists
local UnitClass = UnitClass
local UnitIsUnit = UnitIsUnit
local AuraUtil = AuraUtil
local C_CooldownViewer = _G and _G.C_CooldownViewer or nil
local IsInGroup = IsInGroup
local IsInRaid = IsInRaid
local IsInInstance = IsInInstance
local C_Timer = C_Timer
local IsSpellKnown = _G and _G.IsSpellKnown or nil
local IsPlayerSpell = IsPlayerSpell
local GetSpellCooldown = _G and _G.GetSpellCooldown or nil
local GetSpellCharges = _G and _G.GetSpellCharges or nil
local C_Spell = _G and _G.C_Spell or nil
local GetSpecialization = GetSpecialization
local GetSpecializationInfo = GetSpecializationInfo

-- ============================================================================
-- Module Info
-- ============================================================================

-- ============================================================================
-- Shared Data
-- ============================================================================

local DD = ns.DefensiveData
local ALL_DEFENSIVES     = DD.ALL_DEFENSIVES
local CLASS_COLORS       = DD.CLASS_COLORS
local CATEGORY_INFO      = DD.CATEGORY_INFO
local ENTRY_TO_ID        = DD.ENTRY_TO_ID
local CONFIRMED_DEFENSIVE_IDS = DD.CONFIRMED_DEFENSIVE_IDS or {}
local EXPERIMENTAL_DEFENSIVE_IDS = DD.EXPERIMENTAL_DEFENSIVE_IDS or {}
local EXPERIMENTAL_IMPORTANT_BUFF_IDS = DD.EXPERIMENTAL_IMPORTANT_BUFF_IDS or {}
local RISKY_RAID_EFFECT_IDS = DD.RISKY_RAID_EFFECT_IDS or {}
local SPELL_SPEC_WHITELIST = DD.SPELL_SPEC_WHITELIST or {}
local DEFENSIVE_TALENT_OVERRIDES = DD.DEFENSIVE_TALENT_OVERRIDES or {}
local GROUP_BUFFS = DD.GROUP_BUFFS or {}
local REQUIRED_GROUP_BUFFS_BY_SPEC = DD.REQUIRED_GROUP_BUFFS_BY_SPEC or {}
local REQUIRED_GROUP_BUFFS_FOR_EVERYONE = DD.REQUIRED_GROUP_BUFFS_FOR_EVERYONE or {}

local FALLBACK_WHITE = { 1, 1, 1 }
local ACTIVE_COLOR   = { 0.2, 1.0, 0.2 }
local DEFAULT_SPELL_ICON = 134400
local AURA_WATCH_KEY = "CrackedDefensives"
local GROUP_BUFF_WATCH_KEY = "CrackedGroupBuffs"

-- ============================================================================
-- State
-- ============================================================================

local db

-- partyMembers[name] = {
--   class = "WARRIOR",
--   cds = {
--     [spellID] = { baseCd=180, cdEnd=<GetTime>, activeEnd=<GetTime>, lastUse=<GetTime> }
--   }
-- }
local partyMembers = {}
local myName, myClass
local myCds = {}  -- [spellID] = { baseCd, cdEnd, activeEnd, lastUse }

local paneFrames = {}
local shouldShowByZone = true
local showInSettings = false
local spellMatchHandle
local rosterFrame
local blizzardProbeCount = 0
local settingsPreviewCleanup
local lastVisibilityState = {}
local activeSettingsPaneId = "all"
local IsCategoryEnabled
local UpdateDisplay
local RebuildPaneBars
local catalogPreviewEnabled = false
local initialized = false

local MAX_BARS = 15

local FONT_FACE = GameFontNormal and GameFontNormal:GetFont() or "Fonts\\FRIZQT__.TTF"
local FONT_FLAGS = "OUTLINE"
local BAR_TEXTURE = "Interface\\BUTTONS\\WHITE8X8"
local OUTLINE_MAP = { none = "", outline = "OUTLINE", thick = "THICKOUTLINE" }
local fontCache = {}

local PANE_STYLE_ROOT = "paneStyles"
local PANE_STYLE_DEFAULTS = {
    frameWidth = 240,
    barHeight = 24,
    showTitle = true,
    showIcons = true,
    showPlayerName = true,
    showSpellName = false,
    growUp = false,
    alpha = 0.9,
    font = "default",
    titleFontSize = 12,
    nameFontSize = 0,
    readyFontSize = 0,
    iconSize = 0,
}
local STYLE_PANE_IDS = { "external", "party", "major", "personal", "buffs" }
local DISPLAY_PANE_IDS = { "all", "external", "party", "major", "personal", "buffs" }
local PANE_LABELS = {
    all = "Everything",
    external = "Externals",
    party = "Party CDs",
    major = "Major CDs",
    personal = "Minor CDs",
    buffs = "Group Buffs",
}
local PANE_TITLES = {
    all = "Cooldowns",
    external = "Externals",
    party = "Party CDs",
    major = "Major CDs",
    personal = "Minor CDs",
    buffs = "Group Buffs",
}
local CLASS_DISPLAY_NAMES = {
    WARRIOR = "Warrior",
    DEATHKNIGHT = "Death Knight",
    DEMONHUNTER = "Demon Hunter",
    SHAMAN = "Shaman",
    PRIEST = "Priest",
    EVOKER = "Evoker",
    DRUID = "Druid",
    PALADIN = "Paladin",
    MONK = "Monk",
    HUNTER = "Hunter",
    MAGE = "Mage",
    ROGUE = "Rogue",
    WARLOCK = "Warlock",
}
local LEGACY_STYLE_KEYS = {
    "frameWidth",
    "barHeight",
    "showTitle",
    "showIcons",
    "showNames",
    "showPlayerName",
    "showSpellName",
    "growUp",
    "alpha",
    "font",
    "titleFontSize",
    "nameFontSize",
    "readyFontSize",
    "iconSize",
}

local function BuildDefensiveAuraFilters(defData)
    if not defData then
        return { "HELPFUL" }
    end

    if defData.category == "external" then
        return {
            "HELPFUL|EXTERNAL_DEFENSIVE",
        }
    end

    return {
        "HELPFUL|BIG_DEFENSIVE",
        "HELPFUL|IMPORTANT",
    }
end

local TRACKED_DEFENSIVES = {}
local TRACKED_CLASS_DEFENSIVE_IDS = {}
local TRACKED_WATCH_SPELLS = {}

local function ShouldTrackExperimentalDefensives()
    return db and db.trackExperimentalDefensives == true
end

local function ShouldTrackExperimentalImportantBuffs()
    return db and db.trackExperimentalImportantBuffs == true
end

local function ShouldTrackRiskyRaidEffects()
    return db and db.trackRiskyRaidEffects == true
end

local function RebuildTrackedDefensiveCatalog()
    TRACKED_DEFENSIVES = {}
    TRACKED_CLASS_DEFENSIVE_IDS = {}
    TRACKED_WATCH_SPELLS = {}

    for spellID, defData in pairs(ALL_DEFENSIVES) do
        local include = CONFIRMED_DEFENSIVE_IDS[spellID]
            or (ShouldTrackExperimentalDefensives() and EXPERIMENTAL_DEFENSIVE_IDS[spellID])
            or (ShouldTrackExperimentalImportantBuffs() and EXPERIMENTAL_IMPORTANT_BUFF_IDS[spellID])
            or (ShouldTrackRiskyRaidEffects() and RISKY_RAID_EFFECT_IDS[spellID])

        if include then
            TRACKED_DEFENSIVES[spellID] = defData
            TRACKED_CLASS_DEFENSIVE_IDS[defData.class] = TRACKED_CLASS_DEFENSIVE_IDS[defData.class] or {}
            TRACKED_CLASS_DEFENSIVE_IDS[defData.class][#TRACKED_CLASS_DEFENSIVE_IDS[defData.class] + 1] = spellID
            TRACKED_WATCH_SPELLS[#TRACKED_WATCH_SPELLS + 1] = {
                spellID = spellID,
                name = defData.name,
                filter = "HELPFUL",
                filters = BuildDefensiveAuraFilters(defData),
                icon = defData.icon,
            }
        end
    end

    for _, ids in pairs(TRACKED_CLASS_DEFENSIVE_IDS) do
        sort(ids)
    end

    sort(TRACKED_WATCH_SPELLS, function(a, b)
        return a.spellID < b.spellID
    end)
end

local GROUP_BUFF_WATCH_SPELLS = {}
for _, buffData in pairs(GROUP_BUFFS) do
    for _, provider in ipairs(buffData.providers or {}) do
        GROUP_BUFF_WATCH_SPELLS[#GROUP_BUFF_WATCH_SPELLS + 1] = {
            spellID = provider.spellID,
            name = provider.name,
            filter = "HELPFUL",
            icon = buffData.icon,
        }
    end
end
sort(GROUP_BUFF_WATCH_SPELLS, function(a, b)
    return a.spellID < b.spellID
end)

do
    local totalTracked = 0
    for _ in pairs(ALL_DEFENSIVES) do
        totalTracked = totalTracked + 1
    end
    for _ in pairs(GROUP_BUFFS) do
        totalTracked = totalTracked + 1
    end
    MAX_BARS = math.max(MAX_BARS, totalTracked)
end

RebuildTrackedDefensiveCatalog()

-- ============================================================================
-- Logging
-- ============================================================================

local function Log(msg)      MedaAuras.Log(format("[Cracked] %s", msg)) end
local function LogDebug(msg) MedaAuras.LogDebug(format("[Cracked] %s", msg)) end
local function LogWarn(msg)  MedaAuras.LogWarn(format("[Cracked] %s", msg)) end

local function IsDebugModeEnabled()
    return MedaAuras.IsDebugModeEnabled and MedaAuras:IsDebugModeEnabled() or false
end

local function IsDeepDebugModeEnabled()
    return MedaAuras.IsDeepDebugModeEnabled and MedaAuras:IsDeepDebugModeEnabled() or false
end

local function SafeStr(value)
    local ok, str = pcall(tostring, value)
    if not ok then return "<secret>" end
    local clean = pcall(function() return str == str end)
    if not clean then return "<secret>" end
    return str
end

local function SafeNumber(value)
    if ns.SafeNumber then
        return ns.SafeNumber(value)
    end
    if type(value) ~= "number" then
        return nil
    end
    return value
end

local function CopyTable(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, child in pairs(value) do
        copy[key] = CopyTable(child)
    end
    return copy
end

local function CopyPosition(position)
    local source = type(position) == "table" and position or {}
    return {
        point = source.point or "CENTER",
        x = source.x or 0,
        y = source.y or 0,
    }
end

local function GetFontObj(fontValue, size, outline)
    local path = MedaUI:GetFontPath(fontValue)
    local flags = OUTLINE_MAP[outline] or outline or FONT_FLAGS
    local key = (path or "default") .. "_" .. tostring(size) .. "_" .. flags
    if fontCache[key] then
        return fontCache[key]
    end

    local fontObject = CreateFont("MedaAurasCracked_" .. key:gsub("[^%w]", "_"))
    if path then
        fontObject:SetFont(path, size, flags)
    else
        fontObject:CopyFontObject(GameFontNormal)
        local basePath = select(1, fontObject:GetFont()) or FONT_FACE
        fontObject:SetFont(basePath, size, flags)
    end

    fontCache[key] = fontObject
    return fontObject
end

local function GetDefaultPanePosition(paneId, basePosition)
    local base = CopyPosition(basePosition)
    if paneId == "all" then
        return base
    end

    local order = {
        external = 0,
        party = 1,
        major = 2,
        personal = 3,
        buffs = 4,
    }

    return {
        point = base.point,
        x = base.x + 280,
        y = base.y - ((order[paneId] or 0) * 160),
    }
end

local function EnsurePaneState()
    if not db then
        return
    end

    local root = MedaUI:EnsureLinkedSettingsState(db, PANE_STYLE_ROOT, STYLE_PANE_IDS, PANE_STYLE_DEFAULTS)
    if root then
        local needsMigration = db._crackedPaneStyleMigrated ~= true
        if needsMigration then
            for _, key in ipairs(LEGACY_STYLE_KEYS) do
                if db[key] ~= nil then
                    root.shared[key] = CopyTable(db[key])
                end
            end
            db._crackedPaneStyleMigrated = true
        end

        if root.shared.showPlayerName == nil and root.shared.showNames ~= nil then
            root.shared.showPlayerName = root.shared.showNames
        end
        root.shared.showNames = nil

        for _, paneId in ipairs(STYLE_PANE_IDS) do
            local group = root.groups[paneId]
            if group and group.showPlayerName == nil and group.showNames ~= nil then
                group.showPlayerName = group.showNames
            end
            if group then
                group.showNames = nil
            end
        end
    end

    db.paneMode = db.paneMode or "combined"
    db.panePositions = type(db.panePositions) == "table" and db.panePositions or {}

    if db._crackedPanePositionMigrated ~= true then
        local basePosition = db.position or GetDefaultPanePosition("all")
        for _, paneId in ipairs(DISPLAY_PANE_IDS) do
            db.panePositions[paneId] = GetDefaultPanePosition(paneId, basePosition)
        end
        db._crackedPanePositionMigrated = true
    else
        local basePosition = db.panePositions.all or db.position or GetDefaultPanePosition("all")
        for _, paneId in ipairs(DISPLAY_PANE_IDS) do
            if type(db.panePositions[paneId]) ~= "table" then
                db.panePositions[paneId] = GetDefaultPanePosition(paneId, basePosition)
            else
                db.panePositions[paneId] = CopyPosition(db.panePositions[paneId])
            end
        end
    end

    if type(db.position) ~= "table" then
        db.position = CopyPosition(db.panePositions.all)
    end
end

local function NormalizeNumber(value, fallback, minimum, maximum)
    if type(value) ~= "number" then
        value = fallback
    end
    if minimum and value < minimum then
        value = minimum
    end
    if maximum and value > maximum then
        value = maximum
    end
    return value
end

local function NormalizePaneStyle(style)
    local source = type(style) == "table" and style or {}
    return {
        frameWidth = NormalizeNumber(source.frameWidth, PANE_STYLE_DEFAULTS.frameWidth, 80, 600),
        barHeight = NormalizeNumber(source.barHeight, PANE_STYLE_DEFAULTS.barHeight, 12, 64),
        showTitle = source.showTitle ~= false,
        showIcons = source.showIcons ~= false,
        showPlayerName = source.showPlayerName ~= false,
        showSpellName = source.showSpellName == true,
        growUp = source.growUp == true,
        alpha = NormalizeNumber(source.alpha, PANE_STYLE_DEFAULTS.alpha, 0.05, 1.0),
        font = type(source.font) == "string" and source.font or PANE_STYLE_DEFAULTS.font,
        titleFontSize = NormalizeNumber(source.titleFontSize, PANE_STYLE_DEFAULTS.titleFontSize, 8, 48),
        nameFontSize = NormalizeNumber(source.nameFontSize, PANE_STYLE_DEFAULTS.nameFontSize, 0, 64),
        readyFontSize = NormalizeNumber(source.readyFontSize, PANE_STYLE_DEFAULTS.readyFontSize, 0, 64),
        iconSize = NormalizeNumber(source.iconSize, PANE_STYLE_DEFAULTS.iconSize, 0, 64),
    }
end

local function GetPaneStyle(paneId)
    EnsurePaneState()
    return NormalizePaneStyle(
        MedaUI:GetResolvedLinkedSettings(db, PANE_STYLE_ROOT, paneId == "all" and "all" or paneId, PANE_STYLE_DEFAULTS)
    )
end

local function SetPaneStyleValue(paneId, key, value)
    EnsurePaneState()
    MedaUI:SetLinkedSettingsValue(db, PANE_STYLE_ROOT, paneId == "all" and "all" or paneId, key, value, PANE_STYLE_DEFAULTS)
end

local function IsPaneLinked(paneId)
    if paneId == "all" then
        return true
    end
    EnsurePaneState()
    return MedaUI:IsLinkedSettingsGroup(db, PANE_STYLE_ROOT, paneId)
end

local function SetPaneLinked(paneId, linked)
    if paneId == "all" then
        return
    end
    EnsurePaneState()
    MedaUI:SetLinkedSettingsGroupLinked(db, PANE_STYLE_ROOT, paneId, linked, PANE_STYLE_DEFAULTS)
end

local function GetPanePosition(paneId)
    EnsurePaneState()
    return db.panePositions[paneId]
end

local function SavePanePosition(paneId, point, x, y)
    EnsurePaneState()
    db.panePositions[paneId] = {
        point = point or "CENTER",
        x = x or 0,
        y = y or 0,
    }

    if paneId == "all" then
        db.position = CopyPosition(db.panePositions.all)
    end
end

local function BuildEntryLabel(style, playerName, spellName)
    local parts = {}
    if style.showPlayerName ~= false and playerName and playerName ~= "" then
        parts[#parts + 1] = playerName
    end
    if style.showSpellName and spellName and spellName ~= "" then
        parts[#parts + 1] = spellName
    end
    return table.concat(parts, " - ")
end

local function BuildCatalogPreviewEntries(now)
    local entries = {}
    local spellIDs = {}
    local index = 0

    for spellID in pairs(TRACKED_DEFENSIVES) do
        spellIDs[#spellIDs + 1] = spellID
    end

    table.sort(spellIDs, function(a, b)
        local left = TRACKED_DEFENSIVES[a]
        local right = TRACKED_DEFENSIVES[b]
        local leftPriority = CATEGORY_INFO[left.category] and CATEGORY_INFO[left.category].priority or 99
        local rightPriority = CATEGORY_INFO[right.category] and CATEGORY_INFO[right.category].priority or 99
        if leftPriority ~= rightPriority then
            return leftPriority < rightPriority
        end
        return left.name < right.name
    end)

    for _, spellID in ipairs(spellIDs) do
        local defData = TRACKED_DEFENSIVES[spellID]
        local categoryInfo = CATEGORY_INFO[defData.category]
        local stateMode = index % 3
        local activeDuration = math.max(3, math.min(defData.duration or 0, 12))
        local activeEnd = 0
        local activeStart = nil
        local activeRenderMode = "none"
        local cdEnd = 0

        if stateMode == 0 and activeDuration > 0 then
            activeEnd = now + activeDuration - ((index % 4) * 0.6)
            activeStart = activeEnd - activeDuration
            activeRenderMode = "timer"
        elseif stateMode == 1 then
            cdEnd = now + math.max(8, math.min((defData.cd or 0) * 0.65, 120))
        end

        entries[#entries + 1] = {
            name = CLASS_DISPLAY_NAMES[defData.class] or defData.class or "Class",
            class = defData.class,
            spellID = spellID,
            spellName = defData.name,
            icon = defData.icon or DEFAULT_SPELL_ICON,
            category = defData.category,
            catPriority = categoryInfo and categoryInfo.priority or 99,
            isActive = activeRenderMode ~= "none",
            isOnCd = activeRenderMode == "none" and cdEnd > now,
            isReady = activeRenderMode == "none" and cdEnd <= now,
            activeStart = activeStart,
            activeEnd = activeEnd,
            activeDuration = activeDuration,
            activeRenderMode = activeRenderMode,
            activeSource = "catalog",
            cdEnd = cdEnd,
            baseCd = defData.cd or 0,
            duration = defData.duration or 0,
            unit = nil,
            isPlayer = false,
        }
        index = index + 1
    end

    local buffKeys = {}
    for buffKey in pairs(GROUP_BUFFS) do
        buffKeys[#buffKeys + 1] = buffKey
    end
    table.sort(buffKeys, function(a, b)
        local left = GROUP_BUFFS[a]
        local right = GROUP_BUFFS[b]
        if (left.order or 99) ~= (right.order or 99) then
            return (left.order or 99) < (right.order or 99)
        end
        return left.label < right.label
    end)

    for buffIndex, buffKey in ipairs(buffKeys) do
        local buffData = GROUP_BUFFS[buffKey]
        entries[#entries + 1] = {
            entryKind = "missingBuff",
            spellName = buffData.label,
            icon = buffData.icon or DEFAULT_SPELL_ICON,
            category = "buffs",
            count = (buffIndex % 3) + 1,
            summary = buffIndex % 2 == 0 and "Tank, Mage" or "Healer",
            order = buffData.order or 99,
        }
    end

    table.sort(entries, function(a, b)
        if (a.entryKind == "missingBuff") ~= (b.entryKind == "missingBuff") then
            return a.entryKind ~= "missingBuff"
        end
        if (a.catPriority or 99) ~= (b.catPriority or 99) then
            return (a.catPriority or 99) < (b.catPriority or 99)
        end
        if a.entryKind == "missingBuff" and b.entryKind == "missingBuff" then
            return (a.order or 99) < (b.order or 99)
        end
        if a.isActive ~= b.isActive then
            return a.isActive
        end
        if a.isOnCd ~= b.isOnCd then
            return a.isOnCd
        end
        return (a.spellName or "") < (b.spellName or "")
    end)

    return entries
end

local function IsPaneEnabled(paneId)
    if catalogPreviewEnabled and showInSettings then
        return true
    end
    if paneId == "all" then
        return true
    end
    if paneId == "buffs" then
        return db and db.showMissingGroupBuffs ~= false
    end
    return IsCategoryEnabled(paneId)
end

local function ShortName(name)
    if type(name) ~= "string" then
        return "Unknown"
    end
    return name:match("^[^-]+") or name
end

local function GetAuraDebugStateSummary(watchKey, unit, spellID)
    local tracker = ns.Services and ns.Services.GroupAuraTracker
    if not tracker or not tracker.GetUnitSpellState or not unit then
        return "aura=tracker-unavailable"
    end

    local state = tracker:GetUnitSpellState(watchKey, unit, spellID)
    if not state then
        return "aura=none"
    end
    if state.active == false then
        return "aura=inactive"
    end
    if not state.active then
        return "aura=unknown"
    end
    if state.exactTiming then
        if state.usedCachedTiming then
            return "aura=active:cached"
        end
        return "aura=active:exact"
    end
    return "aura=active:secret"
end

local function GetDefensiveTalentOverride(unit, spellID, isPlayer)
    local override = DEFENSIVE_TALENT_OVERRIDES[spellID]
    if not override or not override.talentSpellID then
        return nil
    end

    if isPlayer then
        return IsPlayerSpell and IsPlayerSpell(override.talentSpellID) and override or nil
    end

    local inspector = ns.Services and ns.Services.GroupInspector
    if inspector and inspector.UnitHasTalentSpell and unit and inspector:UnitHasTalentSpell(unit, override.talentSpellID) then
        return override
    end

    return nil
end

local function NormalizeChargeState(state, now)
    if not state or not state.maxCharges or state.maxCharges <= 1 then
        state.currentCharges = nil
        state.rechargeEnds = nil
        return
    end

    local rechargeEnds = state.rechargeEnds or {}
    table.sort(rechargeEnds)

    local currentCharges = state.currentCharges
    if type(currentCharges) ~= "number" then
        currentCharges = state.maxCharges - #rechargeEnds
    end

    if currentCharges < 0 then currentCharges = 0 end
    if currentCharges > state.maxCharges then currentCharges = state.maxCharges end

    while rechargeEnds[1] and rechargeEnds[1] <= now do
        table.remove(rechargeEnds, 1)
        currentCharges = math.min(state.maxCharges, currentCharges + 1)
    end

    state.currentCharges = currentCharges
    state.rechargeEnds = rechargeEnds
    state.cdEnd = rechargeEnds[1] or 0
end

local function ApplyDefensiveMetadata(state, defData, override)
    if not state or not defData then
        return
    end

    state.displayName = override and override.name or defData.name
    state.displayIcon = override and override.icon or defData.icon
    state.displayDuration = override and override.duration or defData.duration
    state.baseCd = override and override.cd or defData.cd
    state.maxCharges = override and override.maxCharges or nil

    if state.maxCharges and state.maxCharges > 1 then
        state.currentCharges = math.min(state.currentCharges or state.maxCharges, state.maxCharges)
        state.rechargeEnds = state.rechargeEnds or {}
    else
        state.currentCharges = nil
        state.rechargeEnds = nil
    end
end

local function ConsumeDefensiveUse(state, now)
    if not state then
        return
    end

    NormalizeChargeState(state, now)

    if state.maxCharges and state.maxCharges > 1 then
        state.currentCharges = math.max(0, (state.currentCharges or state.maxCharges) - 1)
        state.rechargeEnds = state.rechargeEnds or {}
        state.rechargeEnds[#state.rechargeEnds + 1] = now + (state.baseCd or 0)
        table.sort(state.rechargeEnds)
        state.cdEnd = state.rechargeEnds[1] or 0
    else
        state.cdEnd = now + (state.baseCd or 0)
    end
end

local function ResolveCooldownEnd(startTime, duration, modRate)
    startTime = SafeNumber(startTime)
    duration = SafeNumber(duration)
    modRate = SafeNumber(modRate)

    if not startTime or not duration or duration <= 0 then
        return 0
    end

    local rate = modRate or 1
    if rate <= 0 then
        rate = 1
    end

    return startTime + (duration / rate)
end

local function SyncPlayerDefensiveCooldown(spellID, state, defData)
    if not spellID or not state or not defData then
        return
    end

    local chargesCurrent, chargesMax, chargeStart, chargeDuration, chargeModRate
    if GetSpellCharges then
        local okCharges, current, maximum, startTime, duration, modRate = pcall(GetSpellCharges, spellID)
        if okCharges then
            chargesCurrent = SafeNumber(current)
            chargesMax = SafeNumber(maximum)
            chargeStart = SafeNumber(startTime)
            chargeDuration = SafeNumber(duration)
            chargeModRate = SafeNumber(modRate)
        end
    end

    if chargesMax and chargesMax > 1 then
        state.maxCharges = chargesMax
        state.currentCharges = math.max(0, math.min(chargesCurrent or chargesMax, chargesMax))
        state.rechargeEnds = nil
        state.cdEnd = state.currentCharges < chargesMax
            and ResolveCooldownEnd(chargeStart, chargeDuration, chargeModRate)
            or 0

        if chargeDuration and chargeDuration > 1 then
            local rate = chargeModRate or 1
            if rate <= 0 then rate = 1 end
            state.baseCd = chargeDuration / rate
        end
        return
    end

    local startTime, duration, enabled, modRate
    if C_Spell and C_Spell.GetSpellCooldown then
        local okInfo, info = pcall(C_Spell.GetSpellCooldown, spellID)
        if okInfo and info then
            startTime = SafeNumber(info.startTime)
            duration = SafeNumber(info.duration)
            enabled = info.isEnabled
            modRate = SafeNumber(info.modRate)
        end
    elseif GetSpellCooldown then
        local okCooldown, startValue, durationValue, enabledValue, modRateValue = pcall(GetSpellCooldown, spellID)
        if okCooldown then
            startTime = SafeNumber(startValue)
            duration = SafeNumber(durationValue)
            enabled = enabledValue
            modRate = SafeNumber(modRateValue)
        end
    end

    state.currentCharges = nil
    state.rechargeEnds = nil

    if enabled == 0 then
        state.cdEnd = 0
        return
    end

    state.cdEnd = ResolveCooldownEnd(startTime, duration, modRate)

    if duration and duration > 1 then
        local rate = modRate or 1
        if rate <= 0 then rate = 1 end
        state.baseCd = duration / rate
    elseif not state.baseCd or state.baseCd <= 0 then
        state.baseCd = defData.cd or 0
    end
end

local function LogPlayerTrackingSnapshot(reason)
    if not myName then
        return
    end

    local parts = {}
    local now = GetTime()
    for spellID, cd in pairs(myCds) do
        local defData = TRACKED_DEFENSIVES[spellID]
        if defData then
            NormalizeChargeState(cd, now)
            local cdEnd = type(cd.cdEnd) == "number" and cd.cdEnd or 0
            local activeEnd = type(cd.activeEnd) == "number" and cd.activeEnd or 0
            local chargeSuffix = cd.maxCharges and cd.maxCharges > 1
                and format(" charges=%d/%d", cd.currentCharges or cd.maxCharges, cd.maxCharges)
                or ""
            parts[#parts + 1] = format("%s[cd=%.1f active=%.1f%s %s]",
                cd.displayName or defData.name,
                cdEnd > now and (cdEnd - now) or 0,
                activeEnd > now and (activeEnd - now) or 0,
                chargeSuffix,
                GetAuraDebugStateSummary(AURA_WATCH_KEY, "player", spellID))
        end
    end

    if #parts == 0 then
        LogWarn(format("Tracking[%s] player=%s tracked=0 class=%s", tostring(reason), tostring(myName), tostring(myClass)))
        return
    end

    table.sort(parts)
    LogDebug(format("Tracking[%s] player=%s tracked=%d %s",
        tostring(reason), tostring(myName), #parts, table.concat(parts, " | ")))
end

local function BuildAuraRescanMode()
    if db and db.forceFullAuraRescan and IsDebugModeEnabled() then
        return "full"
    end
    return "unit"
end

local function RefreshAuraWatches()
    local tracker = ns.Services.GroupAuraTracker
    if not tracker or not tracker.RegisterWatch then
        return
    end

    tracker:RegisterWatch(AURA_WATCH_KEY, {
        spells = TRACKED_WATCH_SPELLS,
        filter = "HELPFUL",
        allowDirectLookup = false,
        rescanMode = BuildAuraRescanMode(),
    })

    if db and db.showMissingGroupBuffs ~= false then
        tracker:RegisterWatch(GROUP_BUFF_WATCH_KEY, {
            spells = GROUP_BUFF_WATCH_SPELLS,
            filter = "HELPFUL",
            rescanMode = BuildAuraRescanMode(),
        })
    elseif tracker.UnregisterWatch then
        tracker:UnregisterWatch(GROUP_BUFF_WATCH_KEY)
    end
end

local function ShouldShowLiveFrame()
    return shouldShowByZone or showInSettings
end

local function UpdateMainFrameVisibility()
    local shouldShowFrames = ShouldShowLiveFrame()

    for paneId, pane in pairs(paneFrames) do
        local shouldShow = shouldShowFrames and pane.hasVisibleEntries and pane.enabled ~= false
        if shouldShow then
            pane.frame:Show()
        else
            pane.frame:Hide()
        end

        if lastVisibilityState[paneId] ~= shouldShow then
            lastVisibilityState[paneId] = shouldShow
            local point, _, _, x, y = pane.frame:GetPoint()
            LogDebug(format("FrameVisibility pane=%s shown=%s zone=%s settings=%s entries=%s point=%s x=%.0f y=%.0f alpha=%.2f",
                tostring(paneId),
                tostring(shouldShow),
                tostring(shouldShowByZone),
                tostring(showInSettings),
                tostring(pane.hasVisibleEntries),
                tostring(point),
                x or 0,
                y or 0,
                pane.frame:GetAlpha() or 0))
        end
    end

end

local function EndSettingsLivePreview()
    showInSettings = false
    catalogPreviewEnabled = false
    settingsPreviewCleanup = nil
    UpdateMainFrameVisibility()
    if C.RequestDisplayRefresh then
        C.RequestDisplayRefresh()
    end
end

local function BeginSettingsLivePreview(anchor)
    if not db or not db.enabled or not next(paneFrames) then
        return
    end

    if settingsPreviewCleanup and settingsPreviewCleanup.Hide then
        settingsPreviewCleanup:Hide()
    end

    showInSettings = true
    UpdateMainFrameVisibility()
    if C.RequestDisplayRefresh then
        C.RequestDisplayRefresh()
    end

    if anchor then
        local cleanup = CreateFrame("Frame", nil, anchor)
        cleanup:Show()
        cleanup:SetScript("OnHide", EndSettingsLivePreview)
        settingsPreviewCleanup = cleanup
        MedaAuras:RegisterConfigCleanup(cleanup)
    end
end

-- ============================================================================
-- Category filter helper
-- ============================================================================

IsCategoryEnabled = function(category)
    if not db then return true end
    if category == "external" then return db.showExternals ~= false end
    if category == "party"    then return db.showPartyWide ~= false end
    if category == "major"    then return db.showMajor ~= false end
    if category == "personal" then return db.showPersonal end
    return true
end

local function FormatCandidateIDs(ids, lookupTable)
    if not ids or #ids == 0 then return "none" end

    local parts = {}
    for i, spellID in ipairs(ids) do
        if i > 5 then
            parts[#parts + 1] = format("+%d more", #ids - 5)
            break
        end
        local data = lookupTable and lookupTable[spellID]
        if data and data.name then
            parts[#parts + 1] = format("%d:%s", spellID, data.name)
        else
            parts[#parts + 1] = tostring(spellID)
        end
    end
    return table.concat(parts, ", ")
end

local function FormatDecisionList(items)
    if not items or #items == 0 then
        return "none"
    end

    local parts = {}
    for i, item in ipairs(items) do
        if i > 6 then
            parts[#parts + 1] = format("+%d more", #items - 6)
            break
        end
        parts[#parts + 1] = item
    end
    return table.concat(parts, ", ")
end

local function DidCandidateIDsChange(oldInfo, candidateIDs)
    if not oldInfo or not oldInfo.candidateIDs then
        return true
    end

    if #oldInfo.candidateIDs ~= #candidateIDs then
        return true
    end

    for index, spellID in ipairs(candidateIDs) do
        if oldInfo.candidateIDs[index] ~= spellID then
            return true
        end
    end

    return false
end

local function GetCachedSpecID(unit)
    if not unit or not UnitExists(unit) then return nil end
    local info = ns.Services.GroupInspector and ns.Services.GroupInspector:GetUnitInfo(unit)
    return info and info.specID or nil
end

local function GetCachedInspectorInfo(unit)
    if not unit or not UnitExists(unit) then
        return nil
    end
    local inspector = ns.Services and ns.Services.GroupInspector
    if not inspector or not inspector.GetUnitInfo then
        return nil
    end
    return inspector:GetUnitInfo(unit)
end

local function HasRequiredTalentSpell(unit, spellID, defData)
    local talentSpellID = defData and defData.talentSpellID
    if not talentSpellID then
        return true
    end

    if unit and UnitIsUnit(unit, "player") then
        return IsPlayerSpell and IsPlayerSpell(talentSpellID) or false
    end

    local inspector = ns.Services and ns.Services.GroupInspector
    if not inspector or not inspector.UnitHasTalentSpell or not inspector.GetUnitInfo or not unit then
        return true
    end

    local info = inspector:GetUnitInfo(unit)
    if not info or not info.talentsKnown then
        return true
    end

    return inspector:UnitHasTalentSpell(unit, talentSpellID)
end

local function IsReadyForPartyRegistration(unit)
    local info = GetCachedInspectorInfo(unit)
    return info and info.inspected and info.specID ~= nil
end

local function BuildCandidateSet(cls, specID, unit)
    local ids = TRACKED_CLASS_DEFENSIVE_IDS[cls]
    local candidateLookup = {}
    local candidateIDs = {}
    local classWideCount = 0

    if not ids then
        return candidateLookup, candidateIDs, classWideCount
    end

    for _, spellID in ipairs(ids) do
        local data = TRACKED_DEFENSIVES[spellID]
        if data and IsCategoryEnabled(data.category) then
            classWideCount = classWideCount + 1
            local allowed = true
            local whitelist = SPELL_SPEC_WHITELIST[spellID]
            if specID and whitelist and not whitelist[specID] then
                allowed = false
            end

            if allowed and unit and not HasRequiredTalentSpell(unit, spellID, data) then
                allowed = false
            end

            if allowed then
                candidateLookup[spellID] = data
                candidateIDs[#candidateIDs + 1] = spellID
            end
        end
    end

    table.sort(candidateIDs)
    return candidateLookup, candidateIDs, classWideCount
end

local function BuildCandidateDecisionSummary(cls, specID, unit)
    local ids = TRACKED_CLASS_DEFENSIVE_IDS[cls]
    local included = {}
    local excluded = {}

    if not ids then
        return included, excluded
    end

    for _, spellID in ipairs(ids) do
        local data = TRACKED_DEFENSIVES[spellID]
        if data and IsCategoryEnabled(data.category) then
            local reason = nil
            local whitelist = SPELL_SPEC_WHITELIST[spellID]
            if specID and whitelist and not whitelist[specID] then
                reason = "spec"
            elseif unit and not HasRequiredTalentSpell(unit, spellID, data) then
                reason = "talent"
            end

            if reason then
                excluded[#excluded + 1] = format("%s(%s)", data.name, reason)
            else
                included[#included + 1] = data.name
            end
        end
    end

    table.sort(included)
    table.sort(excluded)
    return included, excluded
end

local function UpdateMemberDefensives(name, cls, specID, reason, unit)
    local oldInfo = partyMembers[name]
    local effectiveSpecID = specID
    if oldInfo and oldInfo.specID and not specID and reason == "roster" then
        effectiveSpecID = oldInfo.specID
    end

    local effectiveUnit = unit or (oldInfo and oldInfo.unit)
    local candidateLookup, candidateIDs, classWideCount = BuildCandidateSet(cls, effectiveSpecID, effectiveUnit)
    local cds = {}

    for _, spellID in ipairs(candidateIDs) do
        local data = TRACKED_DEFENSIVES[spellID]
        local existing = oldInfo and oldInfo.cds and oldInfo.cds[spellID]
        local state = existing or {
            baseCd = data.cd,
            cdEnd = 0,
            activeEnd = 0,
            lastUse = 0,
        }
        local override = GetDefensiveTalentOverride(effectiveUnit, spellID, false)
        ApplyDefensiveMetadata(state, data, override)
        NormalizeChargeState(state, GetTime())
        cds[spellID] = state
        if override then
            LogDebug(format("  Talent override for %s: %s -> %s (%d charge%s, %ds)",
                tostring(name),
                data.name,
                override.name,
                override.maxCharges or 1,
                (override.maxCharges or 1) == 1 and "" or "s",
                override.cd or data.cd))
        end
    end

    partyMembers[name] = {
        class = cls,
        specID = effectiveSpecID,
        unit = unit or (oldInfo and oldInfo.unit),
        cds = cds,
        candidateLookup = candidateLookup,
        candidateIDs = candidateIDs,
        classWideCount = classWideCount,
    }

    if reason ~= "roster"
        or not oldInfo
        or oldInfo.class ~= cls
        or oldInfo.specID ~= effectiveSpecID
        or DidCandidateIDsChange(oldInfo, candidateIDs)
    then
        LogDebug(format("Registered %s (%s spec=%s) with %d/%d defensive candidates via %s",
            name, cls, tostring(effectiveSpecID), #candidateIDs, classWideCount, tostring(reason)))
        LogDebug(format("  CandidateIDs for %s: %s",
            name, FormatCandidateIDs(candidateIDs, candidateLookup)))
        if reason == "inspect" then
            local included, excluded = BuildCandidateDecisionSummary(cls, effectiveSpecID, effectiveUnit)
            LogDebug(format("  TalentGate %s: include=%s exclude=%s",
                name,
                FormatDecisionList(included),
                FormatDecisionList(excluded)))
        end
    end
end

-- ============================================================================
-- Find own defensive spells
-- ============================================================================

local function FindMyDefensives()
    local _, cls = UnitClass("player")
    myClass = cls
    myName = UnitName("player")
    local previousCds = {}

    for spellID, state in pairs(myCds) do
        previousCds[spellID] = state
    end
    wipe(myCds)

    local ids = TRACKED_CLASS_DEFENSIVE_IDS[cls]
    if not ids then
        return
    end

    local count = 0
    for _, spellID in ipairs(ids) do
        local data = TRACKED_DEFENSIVES[spellID]
        if data and IsCategoryEnabled(data.category) then
            local known = IsSpellKnown(spellID)
            if not known then
                local ok, r = pcall(IsPlayerSpell, spellID)
                if ok and r then known = true end
            end
            if known then
                local override = GetDefensiveTalentOverride("player", spellID, true)
                local state = previousCds[spellID] or {
                    baseCd = data.cd,
                    cdEnd = 0,
                    activeEnd = 0,
                    lastUse = 0,
                }
                ApplyDefensiveMetadata(state, data, override)
                NormalizeChargeState(state, GetTime())
                SyncPlayerDefensiveCooldown(spellID, state, data)
                myCds[spellID] = state
                count = count + 1
                if override then
                    LogDebug(format("    -> talent override applied: %s -> %s (%d charge%s, %ds)",
                        data.name,
                        override.name,
                        override.maxCharges or 1,
                        (override.maxCharges or 1) == 1 and "" or "s",
                        override.cd or data.cd))
                end
            end
        end
    end

    LogDebug(format("FindMyDefensives: tracked=%d player=%s class=%s",
        count, tostring(myName), tostring(cls)))
    if IsDeepDebugModeEnabled() then
        LogPlayerTrackingSnapshot("find-my-defensives")
    end
    if C.RequestDisplayRefresh then
        C.RequestDisplayRefresh()
    end
end

-- ============================================================================
-- Auto-register party members
-- ============================================================================

local function AutoRegisterParty()
    local unknownName = _G.UNKNOWNOBJECT or _G.UNKNOWN
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) then
            local name = UnitName(u)
            local _, cls = UnitClass(u)
            local specID = GetCachedSpecID(u)
            if (not unknownName or name ~= unknownName) and name and cls and IsReadyForPartyRegistration(u) then
                UpdateMemberDefensives(name, cls, specID, "roster", u)
            end
        end
    end
end

local function CleanPartyList()
    local current = {}
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) then current[UnitName(u)] = true end
    end
    local removed = 0
    for name in pairs(partyMembers) do
        if not current[name] then
            partyMembers[name] = nil
            removed = removed + 1
        end
    end
end

-- ============================================================================
-- Handle party defensive matched via PartySpellWatcher StatusBar equality test
--
-- PSW's OnPartySpellMatch uses StatusBar clamping to binary-test the tainted
-- spell ID against every key in the confirmed defensive lookup table. On match, this callback
-- receives fully clean (name, cleanSpellID, defData, unit) args.
-- ============================================================================

local function ProbeCandidateAuras(name, unit, debugInfo)
    if not IsDeepDebugModeEnabled() or not AuraUtil or not unit or not UnitExists(unit) or not debugInfo or not debugInfo.candidateIDs then
        return
    end

    local function RunProbe(tag)
        local active = {}
        local memberInfo = partyMembers[name]
        for _, spellID in ipairs(debugInfo.candidateIDs) do
            local defData = TRACKED_DEFENSIVES[spellID]
            if defData then
                local auraName = memberInfo and memberInfo.cds and memberInfo.cds[spellID]
                    and memberInfo.cds[spellID].displayName or defData.name
                local ok, aura = pcall(AuraUtil.FindAuraByName, auraName, unit, "HELPFUL")
                if ok and aura then
                    active[#active + 1] = auraName
                end
            end
        end
        LogDebug(format("AuraProbe[%s] %s unit=%s candidates=%s active=%s",
            tag, SafeStr(name), SafeStr(unit),
            FormatCandidateIDs(debugInfo.candidateIDs, debugInfo.candidateLookup),
            #active > 0 and table.concat(active, ", ") or "none"))
    end

    RunProbe("0.0")
    C_Timer.After(0.2, function()
        RunProbe("0.2")
    end)
end

local BLIZZ_VIEWERS = {
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
}

local function ProbeBlizzardUISurfaces(reason)
    if not IsDeepDebugModeEnabled() then
        return
    end

    blizzardProbeCount = blizzardProbeCount + 1
    if blizzardProbeCount > 12 then return end

    LogDebug(format("BlizzardUIProbe[%d]: reason=%s C_CooldownViewer=%s",
        blizzardProbeCount, tostring(reason), tostring(C_CooldownViewer ~= nil)))

    for _, viewerName in ipairs(BLIZZ_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            local ok, children = pcall(function() return { viewer:GetChildren() } end)
            local childCount = ok and #children or 0
            LogDebug(format("  Viewer %s exists shown=%s children=%d",
                viewerName, tostring(viewer:IsShown()), childCount))

            if ok and children then
                for idx, child in ipairs(children) do
                    if idx > 4 then break end
                    local cdID = child.cooldownID or (child.cooldownInfo and child.cooldownInfo.cooldownID)
                    local spellID = child.spellID
                    local itemID = child.itemID
                    local info = nil
                    if cdID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
                        local okInfo, rInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
                        if okInfo then info = rInfo end
                    end
                    LogDebug(format("    child[%d] name=%s shown=%s cdID=%s spellID=%s itemID=%s infoSpell=%s",
                        idx,
                        tostring(child.GetName and child:GetName() or nil),
                        tostring(child.IsShown and child:IsShown() or false),
                        tostring(cdID),
                        tostring(spellID),
                        tostring(itemID),
                        tostring(info and (info.overrideSpellID or info.spellID) or nil)))
                end
            end
        else
            LogDebug(format("  Viewer %s missing", viewerName))
        end
    end

    for i = 1, 4 do
        local partyFrame = _G["CompactPartyFrameMember" .. i]
        if partyFrame then
            local okChildren, children = pcall(function() return { partyFrame:GetChildren() } end)
            local okRegions, regions = pcall(function() return { partyFrame:GetRegions() } end)
            LogDebug(format("  CompactPartyFrameMember%d shown=%s children=%d regions=%d",
                i,
                tostring(partyFrame:IsShown()),
                okChildren and #children or -1,
                okRegions and #regions or -1))
        end
    end
end

local function ResolveDefensiveCandidates(name, unit)
    local info = partyMembers[name]
    if info and info.class then
        -- Cast matching should stay broader than display pre-registration.
        -- Talent gates can be wrong or stale; exact live casts should still land.
        local lookupTable, knownIDs = BuildCandidateSet(info.class, info.specID, nil)
        return {
            lookupTable = lookupTable,
            knownIDs = knownIDs,
            label = format("%s:%s(match)", tostring(info.class), tostring(info.specID or "nospec")),
        }
    end

    if unit and UnitExists(unit) then
        local _, cls = UnitClass(unit)
        local specID = GetCachedSpecID(unit)
        if cls then
            local lookupTable, knownIDs = BuildCandidateSet(cls, specID, nil)
            return {
                lookupTable = lookupTable,
                knownIDs = knownIDs,
                label = format("%s:%s(match-ephemeral)", tostring(cls), tostring(specID or "nospec")),
            }
        end
    end
end

local function OnPartyDefensiveMatch(name, cleanSpellID, defData, unit, debugInfo)
    if not IsCategoryEnabled(defData.category) then
        LogDebug(format("FILTERED (cat disabled): %s cast %s (ID %d, cat=%s)",
            SafeStr(name), defData.name, cleanSpellID, defData.category))
        return
    end

    local now = GetTime()
    local cd

    local info = partyMembers[name]
    if not info then
        for i = 1, 4 do
            local u = "party" .. i
            if UnitExists(u) and UnitName(u) == name then
                local _, cls = UnitClass(u)
                local specID = GetCachedSpecID(u)
                if cls then
                    UpdateMemberDefensives(name, cls, specID, "late-cast", u)
                    info = partyMembers[name]
                end
                break
            end
        end
    end

    if info then
        if not info.cds[cleanSpellID] then
            info.cds[cleanSpellID] = {
                baseCd = defData.cd,
                cdEnd = 0,
                activeEnd = 0,
                lastUse = 0,
            }
            ApplyDefensiveMetadata(info.cds[cleanSpellID], defData, GetDefensiveTalentOverride(info.unit or unit, cleanSpellID, false))
            LogDebug(format("  Late-added spell %d (%s) for %s", cleanSpellID, defData.name, SafeStr(name)))
        end

        cd = info.cds[cleanSpellID]
        Log(format("PARTY DEFENSIVE: %s cast %s (ID %d, cat=%s, CD=%ds, dur=%ds, confidence=%s via=%s)",
            SafeStr(name), defData.name, cleanSpellID, defData.category,
            defData.cd, defData.duration,
            tostring(debugInfo and debugInfo.confidence or "unknown"),
            tostring(debugInfo and debugInfo.chosenBy or "unknown")))
        if debugInfo and IsDeepDebugModeEnabled() then
            LogDebug(format("  MatchDebug cast=%s cleanID=%s candidates=%s",
                SafeStr(debugInfo.castID),
                SafeStr(debugInfo.cleanID),
                FormatCandidateIDs(debugInfo.candidateIDs, debugInfo.candidateLookup)))
        end
        ConsumeDefensiveUse(cd, now)
        local activeDuration = type(cd.displayDuration) == "number" and cd.displayDuration or defData.duration
        cd.activeEnd = activeDuration > 0 and (now + activeDuration) or 0
        cd.lastUse = now

    else
        Log(format("PARTY DEFENSIVE: %s cast %s (ID %d, cat=%s, CD=%ds, dur=%ds, confidence=%s via=%s)",
            SafeStr(name), defData.name, cleanSpellID, defData.category,
            defData.cd, defData.duration,
            tostring(debugInfo and debugInfo.confidence or "unknown"),
            tostring(debugInfo and debugInfo.chosenBy or "unknown")))
        LogWarn(format("  Could not register %s from %s", SafeStr(name), SafeStr(unit)))
    end

    if ns.Services.GroupAuraTracker and ns.Services.GroupAuraTracker.RequestWatchScan and unit then
        ns.Services.GroupAuraTracker:RequestWatchScan(AURA_WATCH_KEY, unit)
    end

    if unit and IsDeepDebugModeEnabled() then
        local cdEnd = type(cd and cd.cdEnd) == "number" and cd.cdEnd or 0
        local activeEnd = type(cd and cd.activeEnd) == "number" and cd.activeEnd or 0
        LogDebug(format("MatchPostScan name=%s unit=%s spell=%s cd=%.1f active=%.1f %s",
            SafeStr(name),
            SafeStr(unit),
            cd and cd.displayName or defData.name,
            cdEnd > now and (cdEnd - now) or 0,
            activeEnd > now and (activeEnd - now) or 0,
            GetAuraDebugStateSummary(AURA_WATCH_KEY, unit, cleanSpellID)))
    end

    if IsDeepDebugModeEnabled() then
        ProbeCandidateAuras(name, unit, debugInfo)
        ProbeBlizzardUISurfaces("match:" .. tostring(defData.name))
    end

    if C.RequestDisplayRefresh then
        C.RequestDisplayRefresh()
    end
end

-- ============================================================================
-- Own defensive tracking
-- ============================================================================

local playerCastFrame

local function SetupOwnTracking()
    if playerCastFrame then
        LogDebug("SetupOwnTracking: already set up")
        return
    end
    playerCastFrame = CreateFrame("Frame")
    playerCastFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    playerCastFrame:SetScript("OnEvent", function(_, _, unit, _, spellID)
        local defData = TRACKED_DEFENSIVES[spellID]
        if not defData then return end
        if not IsCategoryEnabled(defData.category) then return end

        local cd = myCds[spellID]
        if not cd then
            cd = { baseCd = defData.cd, cdEnd = 0, activeEnd = 0, lastUse = 0 }
            ApplyDefensiveMetadata(cd, defData, GetDefensiveTalentOverride("player", spellID, true))
            myCds[spellID] = cd
        end

        local now = GetTime()
        ConsumeDefensiveUse(cd, now)
        local activeDuration = type(cd.displayDuration) == "number" and cd.displayDuration or defData.duration
        cd.activeEnd = activeDuration > 0 and (now + activeDuration) or 0
        cd.lastUse = now
        SyncPlayerDefensiveCooldown(spellID, cd, defData)

        Log(format("OWN DEFENSIVE: %s (ID %d, cat=%s, CD=%ds, dur=%ds) activeEnd=%.1f cdEnd=%.1f",
            cd.displayName or defData.name, spellID, defData.category,
            cd.baseCd or defData.cd, activeDuration,
            cd.activeEnd > 0 and cd.activeEnd or 0,
            cd.cdEnd))

        if C.RequestDisplayRefresh then
            C.RequestDisplayRefresh()
        end
    end)
    LogDebug("SetupOwnTracking: registered UNIT_SPELLCAST_SUCCEEDED for player")
end

local function TeardownOwnTracking()
    if playerCastFrame then
        playerCastFrame:UnregisterAllEvents()
        playerCastFrame = nil
    end
end

-- ============================================================================
-- UI: Bar layout
-- ============================================================================

local function GetBarLayoutForStyle(style)
    local frameWidth = style.frameWidth or PANE_STYLE_DEFAULTS.frameWidth
    local baseBarHeight = math.max(12, style.barHeight or PANE_STYLE_DEFAULTS.barHeight)
    local titleFontSize = (style.titleFontSize and style.titleFontSize > 0) and style.titleFontSize or 12
    local titleHeight = style.showTitle and math.max(20, titleFontSize + 8) or 0
    local iconSize = 0

    if style.showIcons ~= false then
        iconSize = (style.iconSize and style.iconSize > 0) and style.iconSize or baseBarHeight
    end

    local barHeight = math.max(baseBarHeight, iconSize)
    local barWidth = math.max(60, frameWidth - iconSize)
    local autoNameSize = math.max(9, math.floor(barHeight * 0.45))
    local autoCdSize = math.max(10, math.floor(barHeight * 0.55))
    local nameFontSize = (style.nameFontSize and style.nameFontSize > 0) and style.nameFontSize or autoNameSize
    local readyFontSize = (style.readyFontSize and style.readyFontSize > 0) and style.readyFontSize or autoCdSize

    return barWidth, barHeight, iconSize, nameFontSize, readyFontSize, titleHeight, titleFontSize
end

local function ApplyPanePosition(paneId)
    local pane = paneFrames[paneId]
    if not pane then
        return
    end

    local position = GetPanePosition(paneId)
    pane.frame:ClearAllPoints()
    pane.frame:SetPoint(position.point, UIParent, position.point, position.x, position.y)
end

local function EnsurePaneFrame(paneId)
    if paneFrames[paneId] then
        return paneFrames[paneId]
    end

    local style = GetPaneStyle(paneId) or PANE_STYLE_DEFAULTS
    local paneName = paneId == "all" and "MedaAurasCrackedFrame" or ("MedaAurasCrackedFrame" .. paneId:gsub("^%l", string.upper))
    local pane = {
        paneId = paneId,
        bars = {},
        enabled = true,
        hasVisibleEntries = false,
        isResizing = false,
    }
    local _, _, _, _, _, _, titleFontSize = GetBarLayoutForStyle(style)

    local frame = CreateFrame("Frame", paneName, UIParent)
    frame:SetSize(style.frameWidth or PANE_STYLE_DEFAULTS.frameWidth, 200)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetResizable(true)
    frame:SetResizeBounds(80, 40, 600, 800)
    frame:SetAlpha(style.alpha or PANE_STYLE_DEFAULTS.alpha)
    frame:SetScript("OnDragStart", function(self)
        if not db.locked then
            self:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        SavePanePosition(paneId, point, x, y)
    end)

    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(BAR_TEXTURE)
    bg:SetVertexColor(0.05, 0.05, 0.05, 0.85)
    pane.background = bg

    local headerText = frame:CreateFontString(nil, "OVERLAY")
    headerText:SetFontObject(GetFontObj(style.font or "default", titleFontSize, "outline"))
    headerText:SetPoint("TOP", 0, -3)
    headerText:SetText("|cFF00DDDD" .. (PANE_TITLES[paneId] or "Defensives") .. "|r")
    pane.titleText = headerText

    local handle = CreateFrame("Button", nil, frame)
    handle:SetSize(16, 16)
    handle:SetPoint("BOTTOMRIGHT", 0, 0)
    handle:SetFrameLevel(frame:GetFrameLevel() + 10)
    handle:EnableMouse(true)

    for i = 0, 2 do
        local line = handle:CreateTexture(nil, "OVERLAY", nil, 1)
        line:SetTexture(BAR_TEXTURE)
        line:SetVertexColor(0.6, 0.8, 0.9, 0.7)
        line:SetSize(1, (3 - i) * 4)
        line:SetPoint("BOTTOMRIGHT", -(i * 4 + 2), 2)
    end

    handle:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" and not db.locked then
            pane.isResizing = true
            frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    handle:SetScript("OnMouseUp", function()
        local _, _, _, _, _, titleHeight = GetBarLayoutForStyle(GetPaneStyle(paneId))
        frame:StopMovingOrSizing()
        pane.isResizing = false

        local visibleCount = 0
        for i = 1, MAX_BARS do
            if pane.bars[i] and pane.bars[i]:IsShown() then
                visibleCount = visibleCount + 1
            end
        end
        if visibleCount < 1 then
            visibleCount = 1
        end

        SetPaneStyleValue(paneId, "frameWidth", math.floor(frame:GetWidth()))
        SetPaneStyleValue(paneId, "barHeight", math.max(12, math.floor((frame:GetHeight() - titleHeight) / visibleCount) - 1))
        wipe(fontCache)
        RebuildPaneBars(paneId)
        UpdateDisplay()
    end)
    pane.resizeHandle = handle
    pane.frame = frame
    paneFrames[paneId] = pane

    ApplyPanePosition(paneId)
    return pane
end

RebuildPaneBars = function(paneId)
    local pane = EnsurePaneFrame(paneId)
    local style = GetPaneStyle(paneId)
    local barWidth, barHeight, iconSize, nameFontSize, readyFontSize, titleHeight, titleFontSize = GetBarLayoutForStyle(style)

    for i = 1, MAX_BARS do
        if pane.bars[i] then
            pane.bars[i]:Hide()
            pane.bars[i]:SetParent(nil)
            pane.bars[i] = nil
        end
    end

    pane.frame:SetWidth(style.frameWidth)
    pane.frame:SetAlpha(style.alpha)
    pane.titleText:SetFontObject(GetFontObj(style.font or "default", titleFontSize, "outline"))
    if style.showTitle then
        pane.titleText:Show()
    else
        pane.titleText:Hide()
    end

    for i = 1, MAX_BARS do
        local yOffset
        if style.growUp then
            yOffset = (i - 1) * (barHeight + 1)
        else
            yOffset = -(titleHeight + (i - 1) * (barHeight + 1))
        end

        local bar = CreateFrame("Frame", nil, pane.frame)
        bar:SetSize(iconSize + barWidth, barHeight)
        if style.growUp then
            bar:SetPoint("BOTTOMLEFT", 0, yOffset)
        else
            bar:SetPoint("TOPLEFT", 0, yOffset)
        end

        local icon = bar:CreateTexture(nil, "ARTWORK")
        icon:SetSize(iconSize, barHeight)
        icon:SetPoint("LEFT", 0, 0)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        if iconSize == 0 then
            icon:Hide()
        end
        bar.icon = icon

        local swipe = CreateFrame("Cooldown", nil, bar, "CooldownFrameTemplate")
        swipe:SetAllPoints(icon)
        swipe:SetReverse(false)
        swipe:SetHideCountdownNumbers(true)
        if swipe.SetDrawBling then swipe:SetDrawBling(false) end
        if swipe.SetDrawEdge then swipe:SetDrawEdge(false) end
        if swipe.SetDrawSwipe then swipe:SetDrawSwipe(true) end
        swipe:Hide()
        bar.activeSwipe = swipe

        local barBg = bar:CreateTexture(nil, "BACKGROUND")
        barBg:SetPoint("TOPLEFT", iconSize, 0)
        barBg:SetPoint("BOTTOMRIGHT", 0, 0)
        barBg:SetTexture(BAR_TEXTURE)
        barBg:SetVertexColor(0.15, 0.15, 0.15, 0.9)
        bar.barBg = barBg

        local statusBar = CreateFrame("StatusBar", nil, bar)
        statusBar:SetPoint("TOPLEFT", iconSize, 0)
        statusBar:SetPoint("BOTTOMRIGHT", 0, 0)
        statusBar:SetStatusBarTexture(BAR_TEXTURE)
        statusBar:SetStatusBarColor(1, 1, 1, 0.85)
        statusBar:SetMinMaxValues(0, 1)
        statusBar:SetValue(0)
        statusBar:SetFrameLevel(bar:GetFrameLevel() + 1)
        bar.cdBar = statusBar

        local content = CreateFrame("Frame", nil, bar)
        content:SetPoint("TOPLEFT", iconSize, 0)
        content:SetPoint("BOTTOMRIGHT", 0, 0)
        content:SetFrameLevel(statusBar:GetFrameLevel() + 1)

        local nameText = content:CreateFontString(nil, "OVERLAY")
        nameText:SetFontObject(GetFontObj(style.font or "default", nameFontSize, "outline"))
        nameText:SetPoint("LEFT", 6, 0)
        nameText:SetJustifyH("LEFT")
        nameText:SetWidth(barWidth - 50)
        nameText:SetWordWrap(false)
        nameText:SetShadowOffset(1, -1)
        nameText:SetShadowColor(0, 0, 0, 1)
        if style.showPlayerName == false and not style.showSpellName then
            nameText:Hide()
        end
        bar.nameText = nameText

        local cdText = content:CreateFontString(nil, "OVERLAY")
        cdText:SetFontObject(GetFontObj(style.font or "default", readyFontSize, "outline"))
        cdText:SetPoint("RIGHT", -6, 0)
        cdText:SetShadowOffset(1, -1)
        cdText:SetShadowColor(0, 0, 0, 1)
        bar.cdText = cdText

        bar:Hide()
        pane.bars[i] = bar
    end

    if pane.resizeHandle then
        pane.resizeHandle:Raise()
    end
end

local function RebuildAllPaneBars()
    wipe(fontCache)
    for _, paneId in ipairs(DISPLAY_PANE_IDS) do
        RebuildPaneBars(paneId)
    end
end

local function GetPaneEntries(entries, paneId)
    if paneId == "all" then
        return entries
    end

    local filtered = {}
    for _, entry in ipairs(entries) do
        if entry.category == paneId then
            filtered[#filtered + 1] = entry
        end
    end
    return filtered
end

local function RenderPaneEntries(paneId, entries, now)
    local pane = EnsurePaneFrame(paneId)
    local style = GetPaneStyle(paneId)
    local _, barHeight, _, _, _, titleHeight = GetBarLayoutForStyle(style)
    local numVisible = math.min(#entries, MAX_BARS)
    pane.enabled = db.paneMode ~= "split" and paneId == "all" or (db.paneMode == "split" and paneId ~= "all" and IsPaneEnabled(paneId))
    pane.hasVisibleEntries = numVisible > 0 and pane.enabled

    for i = 1, MAX_BARS do
        local entry = entries[i]
        local bar = pane.bars[i]
        if not bar then
            break
        end

        if entry and pane.enabled then
            local color = CLASS_COLORS[entry.class] or FALLBACK_WHITE
            local chargeText = entry.maxCharges and entry.maxCharges > 1
                and format("%d/%d", entry.currentCharges or entry.maxCharges, entry.maxCharges)
                or nil

            bar:Show()
            bar.icon:SetTexture(entry.icon)
            if style.showIcons ~= false then
                bar.icon:Show()
            else
                bar.icon:Hide()
            end

            if entry.entryKind == "missingBuff" then
                if bar.activeSwipe then
                    bar.activeSwipe:Hide()
                end
                bar.cdBar:Hide()
                bar.barBg:SetVertexColor(0.28, 0.21, 0.05, 0.95)
                bar.nameText:SetText("|cFFFFFFFF" .. entry.spellName .. " - " .. entry.summary .. "|r")
                bar.cdText:SetText(tostring(entry.count))
                bar.cdText:SetTextColor(1.0, 0.82, 0.22)
            else
                local label = BuildEntryLabel(style, entry.name, entry.spellName)
                bar.nameText:SetText(label ~= "" and ("|cFFFFFFFF" .. label .. "|r") or "")
            end

            if entry.entryKind == "missingBuff" then
                bar.nameText:Show()
            elseif style.showPlayerName == false and not style.showSpellName then
                bar.nameText:Hide()
            else
                bar.nameText:Show()
            end

            if entry.entryKind ~= "missingBuff" and entry.isActive then
                bar.cdBar:Hide()
                bar.barBg:SetVertexColor(ACTIVE_COLOR[1] * 0.25, ACTIVE_COLOR[2] * 0.25, ACTIVE_COLOR[3] * 0.25, 0.9)
                if bar.activeSwipe and style.showIcons ~= false and entry.activeRenderMode == "timer"
                    and entry.activeStart and entry.activeDuration and entry.activeDuration > 0 then
                    bar.activeSwipe:SetCooldown(entry.activeStart, entry.activeDuration)
                    bar.activeSwipe:Show()
                elseif bar.activeSwipe then
                    bar.activeSwipe:Hide()
                end

                if entry.activeRenderMode == "timer" and entry.activeEnd > now then
                    local remaining = entry.activeEnd - now
                    if chargeText then
                        bar.cdText:SetText(format("%s %.1fs", chargeText, remaining))
                    else
                        bar.cdText:SetText(format("%.1fs", remaining))
                    end
                else
                    bar.cdText:SetText(chargeText and (chargeText .. " ACTIVE") or "ACTIVE")
                end
                bar.cdText:SetTextColor(0.2, 1.0, 0.2)
            elseif entry.entryKind ~= "missingBuff" and entry.isOnCd then
                local remaining = entry.cdEnd - now
                if bar.activeSwipe then
                    bar.activeSwipe:Hide()
                end
                bar.cdBar:Show()
                bar.cdBar:SetMinMaxValues(0, entry.baseCd)
                bar.cdBar:SetValue(remaining)
                bar.cdBar:SetStatusBarColor(color[1], color[2], color[3], 0.85)
                bar.barBg:SetVertexColor(color[1] * 0.25, color[2] * 0.25, color[3] * 0.25, 0.9)
                if chargeText then
                    bar.cdText:SetText(format("%s %.0f", chargeText, remaining))
                else
                    bar.cdText:SetText(format("%.0f", remaining))
                end
                bar.cdText:SetTextColor(1, 1, 1)
            elseif entry.entryKind ~= "missingBuff" then
                if bar.activeSwipe then
                    bar.activeSwipe:Hide()
                end
                bar.cdBar:Show()
                bar.cdBar:SetMinMaxValues(0, 1)
                bar.cdBar:SetValue(0)
                bar.cdBar:SetStatusBarColor(color[1], color[2], color[3], 0.85)
                bar.barBg:SetVertexColor(color[1], color[2], color[3], 0.85)
                bar.cdText:SetText(chargeText and (chargeText .. " READY") or "READY")
                bar.cdText:SetTextColor(0.2, 1.0, 0.2)
            end
        else
            if bar.activeSwipe then
                bar.activeSwipe:Hide()
            end
            bar:Hide()
        end
    end

    if not pane.isResizing and numVisible > 0 then
        pane.frame:SetHeight(titleHeight + numVisible * (barHeight + 1))
    end
end

-- ============================================================================
-- UI: Collect active/cd entries for display, sorted by priority
-- ============================================================================

local function CollectDisplayEntries()
    if catalogPreviewEnabled and showInSettings then
        return BuildCatalogPreviewEntries(GetTime())
    end

    local cooldownEntries = {}
    local missingBuffEntries = {}
    local now = GetTime()

    local function GetTrackedAuraState(unit, spellID)
        if not unit or not ns.Services.GroupAuraTracker or not ns.Services.GroupAuraTracker.GetUnitSpellState then
            return nil
        end
        return ns.Services.GroupAuraTracker:GetUnitSpellState(AURA_WATCH_KEY, unit, spellID)
    end

    local function GetTrackedExternalAuraState(casterUnit, spellID)
        local tracker = ns.Services and ns.Services.GroupAuraTracker
        if not casterUnit or not spellID or not tracker or not tracker.GetWatchState then
            return nil
        end

        local watchState = tracker:GetWatchState(AURA_WATCH_KEY)
        if not watchState then
            return nil
        end

        local bestState = nil
        for _, recipientState in pairs(watchState) do
            local spellState = recipientState and recipientState.spells and recipientState.spells[spellID] or nil
            if spellState and spellState.active and spellState.sourceUnit == casterUnit then
                if not bestState then
                    bestState = spellState
                elseif spellState.exactTiming and not bestState.exactTiming then
                    bestState = spellState
                elseif spellState.expirationTime and bestState.expirationTime and spellState.expirationTime > bestState.expirationTime then
                    bestState = spellState
                end
            end
        end

        return bestState
    end

    local function GetTrackedGroupBuffState(unit, spellID)
        if not unit or not ns.Services.GroupAuraTracker or not ns.Services.GroupAuraTracker.GetUnitSpellState then
            return nil
        end
        return ns.Services.GroupAuraTracker:GetUnitSpellState(GROUP_BUFF_WATCH_KEY, unit, spellID)
    end

    local function ResolveActiveState(unit, spellID, cd, defData, isPlayer)
        local auraState = GetTrackedAuraState(unit, spellID)
        if (not auraState or not auraState.active) and defData.category == "external" then
            auraState = GetTrackedExternalAuraState(unit, spellID) or auraState
        end
        local renderMode = "none"
        local activeStart = nil
        local activeEnd = 0
        local activeDuration = 0
        local activeSource = nil
        local duration = defData.duration or 0

        if auraState and auraState.active then
            local auraExpirationTime = SafeNumber(auraState.expirationTime)
            local auraDuration = SafeNumber(auraState.duration)
            if auraState.exactTiming and auraExpirationTime and auraDuration and auraExpirationTime > now then
                renderMode = "timer"
                activeEnd = auraExpirationTime
                activeDuration = auraDuration
                activeStart = activeEnd - activeDuration
                activeSource = "aura"
            elseif cd.activeEnd > now and duration > 0 then
                renderMode = "timer"
                activeEnd = cd.activeEnd
                activeDuration = duration
                activeStart = activeEnd - activeDuration
                activeSource = "estimated"
            else
                renderMode = "active"
                activeSource = "secret"
            end
        elseif auraState and auraState.active == false then
            renderMode = "none"
        elseif cd.activeEnd > now and duration > 0 then
            renderMode = "timer"
            activeEnd = cd.activeEnd
            activeDuration = duration
            activeStart = activeEnd - activeDuration
            activeSource = isPlayer and "player" or "cast"
        end

        return renderMode, activeStart, activeEnd, activeDuration, activeSource
    end

    local function AddEntries(name, cls, cds, isPlayer, unit)
        for spellID, cd in pairs(cds) do
            local defData = TRACKED_DEFENSIVES[spellID]
            if defData and IsCategoryEnabled(defData.category) then
                if isPlayer then
                    SyncPlayerDefensiveCooldown(spellID, cd, defData)
                end
                NormalizeChargeState(cd, now)
                local cdEnd = type(cd.cdEnd) == "number" and cd.cdEnd or 0
                local activeEndValue = type(cd.activeEnd) == "number" and cd.activeEnd or 0
                local baseCd = type(cd.baseCd) == "number" and cd.baseCd or defData.cd or 0
                local effectiveDuration = type(cd.displayDuration) == "number" and cd.displayDuration or defData.duration
                local currentCharges = type(cd.currentCharges) == "number" and cd.currentCharges or nil
                local maxCharges = type(cd.maxCharges) == "number" and cd.maxCharges or nil
                local activeRenderMode, activeStart, activeEnd, activeDuration, activeSource =
                    ResolveActiveState(unit, spellID, {
                        activeEnd = activeEndValue,
                        cdEnd = cdEnd,
                    }, {
                        duration = effectiveDuration,
                    }, isPlayer)
                local isActive = activeRenderMode ~= "none"
                local isOnCd = maxCharges and maxCharges > 1
                    and currentCharges ~= nil
                    and currentCharges <= 0
                    and cdEnd > now
                    or (not (maxCharges and maxCharges > 1) and cdEnd > now)
                local catInfo = CATEGORY_INFO[defData.category]
                cooldownEntries[#cooldownEntries + 1] = {
                    name = name,
                    class = cls,
                    spellID = spellID,
                    spellName = cd.displayName or defData.name,
                    icon = cd.displayIcon or defData.icon or DEFAULT_SPELL_ICON,
                    category = defData.category,
                    catPriority = catInfo and catInfo.priority or 99,
                    isActive = isActive,
                    isOnCd = isOnCd,
                    isReady = not isActive and not isOnCd,
                    activeStart = activeStart,
                    activeEnd = activeEnd,
                    activeDuration = activeDuration,
                    activeRenderMode = activeRenderMode,
                    activeSource = activeSource,
                    cdEnd = cdEnd,
                    baseCd = baseCd,
                    duration = effectiveDuration,
                    currentCharges = currentCharges,
                    maxCharges = maxCharges,
                    unit = unit,
                    isPlayer = isPlayer,
                }
            end
        end
    end

    local function BuildRoster()
        local roster = {}
        local specIndex = GetSpecialization and GetSpecialization()

        roster[#roster + 1] = {
            unit = "player",
            name = UnitName("player") or "You",
            class = select(2, UnitClass("player")),
            specID = specIndex and GetSpecializationInfo(specIndex) or nil,
            isPlayer = true,
        }

        if IsInRaid() then
            for i = 1, GetNumGroupMembers() do
                local unit = "raid" .. i
                if UnitExists(unit) and not (UnitIsUnit and UnitIsUnit(unit, "player")) then
                    local info = ns.Services.GroupInspector and ns.Services.GroupInspector.GetUnitInfo
                        and ns.Services.GroupInspector:GetUnitInfo(unit) or nil
                    roster[#roster + 1] = {
                        unit = unit,
                        name = UnitName(unit) or "Unknown",
                        class = select(2, UnitClass(unit)),
                        specID = info and info.specID or nil,
                        isPlayer = false,
                    }
                end
            end
        elseif IsInGroup() then
            for i = 1, 4 do
                local unit = "party" .. i
                if UnitExists(unit) then
                    local info = ns.Services.GroupInspector and ns.Services.GroupInspector.GetUnitInfo
                        and ns.Services.GroupInspector:GetUnitInfo(unit) or nil
                    roster[#roster + 1] = {
                        unit = unit,
                        name = UnitName(unit) or "Unknown",
                        class = select(2, UnitClass(unit)),
                        specID = info and info.specID or nil,
                        isPlayer = false,
                    }
                end
            end
        end

        return roster
    end

    local function BuildMissingBuffEntries()
        if not db.showMissingGroupBuffs then
            return
        end

        local roster = BuildRoster()
        if #roster == 0 then
            return
        end

        local available = {}
        for buffKey in pairs(GROUP_BUFFS) do
            available[buffKey] = false
        end

        for _, member in ipairs(roster) do
            for buffKey, buffData in pairs(GROUP_BUFFS) do
                if not available[buffKey] then
                    for _, provider in ipairs(buffData.providers or {}) do
                        if provider.class == member.class then
                            available[buffKey] = true
                            break
                        end
                    end
                end
            end
        end

        for buffKey, buffData in pairs(GROUP_BUFFS) do
            if available[buffKey] then
                local missing = {}

                for _, member in ipairs(roster) do
                    local requiredBuff = member.specID and REQUIRED_GROUP_BUFFS_BY_SPEC[member.specID] or nil
                    local needsBuff = REQUIRED_GROUP_BUFFS_FOR_EVERYONE[buffKey] or requiredBuff == buffKey
                    if needsBuff then
                        local hasBuff = false
                        for _, provider in ipairs(buffData.providers or {}) do
                            local auraState = GetTrackedGroupBuffState(member.unit, provider.spellID)
                            if auraState and auraState.active then
                                hasBuff = true
                                break
                            end
                        end

                        if not hasBuff then
                            missing[#missing + 1] = ShortName(member.name)
                        end
                    end
                end

                if #missing > 0 then
                    table.sort(missing)
                    local summary = table.concat(missing, ", ", 1, math.min(#missing, 3))
                    if #missing > 3 then
                        summary = format("%s +%d", summary, #missing - 3)
                    end

                    missingBuffEntries[#missingBuffEntries + 1] = {
                        entryKind = "missingBuff",
                        spellName = buffData.label,
                        icon = buffData.icon,
                        category = "buffs",
                        count = #missing,
                        summary = summary,
                        order = buffData.order or 99,
                    }
                end
            end
        end

        table.sort(missingBuffEntries, function(a, b)
            if a.order ~= b.order then
                return a.order < b.order
            end
            return a.count > b.count
        end)
    end

    AddEntries(myName or "You", myClass or "WARRIOR", myCds, true, "player")

    for name, info in pairs(partyMembers) do
        AddEntries(name, info.class, info.cds, false, info.unit)
    end

    BuildMissingBuffEntries()

    table.sort(cooldownEntries, function(a, b)
        if a.isActive ~= b.isActive then return a.isActive end
        if a.isOnCd ~= b.isOnCd then return a.isOnCd end
        if a.catPriority ~= b.catPriority then return a.catPriority < b.catPriority end
        if a.isActive then
            return a.activeEnd < b.activeEnd
        end
        if a.isOnCd then
            return a.cdEnd < b.cdEnd
        end
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.cdEnd < b.cdEnd
    end)

    local entries = cooldownEntries
    for _, entry in ipairs(missingBuffEntries) do
        entries[#entries + 1] = entry
    end

    return entries
end

-- ============================================================================
-- UI: Display update
-- ============================================================================

local function CheckZoneVisibility()
    local _, instanceType = IsInInstance()
    if instanceType == "party" then
        shouldShowByZone = db.showInDungeon
    elseif instanceType == "raid" then
        shouldShowByZone = db.showInRaid
    elseif instanceType == "arena" then
        shouldShowByZone = db.showInArena
    elseif instanceType == "pvp" then
        shouldShowByZone = db.showInBG
    else
        shouldShowByZone = db.showInOpenWorld
    end
    LogDebug(format("CheckZoneVisibility: instanceType=%s showByZone=%s",
        tostring(instanceType), tostring(shouldShowByZone)))
    UpdateMainFrameVisibility()
    if C.RequestDisplayRefresh then
        C.RequestDisplayRefresh()
    end
end

local function OnAuraStateChanged(watchKey)
    if watchKey ~= nil and watchKey ~= AURA_WATCH_KEY and watchKey ~= GROUP_BUFF_WATCH_KEY then
        return
    end

    if C.RequestDisplayRefresh then
        C.RequestDisplayRefresh()
    end
end

local function NeedsAnimatedEntry(entry)
    if not entry or entry.entryKind == "missingBuff" then
        return false
    end

    if entry.isActive or entry.isOnCd then
        return true
    end

    return entry.maxCharges and entry.maxCharges > 1
        and entry.currentCharges ~= nil
        and entry.currentCharges < entry.maxCharges
end

UpdateDisplay = function()
    if not next(paneFrames) then
        return false
    end

    local now = GetTime()

    local allEntries = CollectDisplayEntries()
    local needsAnimation = false
    for _, entry in ipairs(allEntries) do
        if NeedsAnimatedEntry(entry) then
            needsAnimation = true
            break
        end
    end

    if #allEntries == 0 and ShouldShowLiveFrame() then
        LogPlayerTrackingSnapshot("no-visible-entries")
    end

    if db.paneMode == "split" then
        for _, paneId in ipairs(STYLE_PANE_IDS) do
            local filtered = GetPaneEntries(allEntries, paneId)
            RenderPaneEntries(paneId, filtered, now)
        end
        if paneFrames.all then
            paneFrames.all.enabled = false
            paneFrames.all.hasVisibleEntries = false
        end
    else
        RenderPaneEntries("all", allEntries, now)
        for _, paneId in ipairs(STYLE_PANE_IDS) do
            if paneFrames[paneId] then
                paneFrames[paneId].enabled = false
                paneFrames[paneId].hasVisibleEntries = false
            end
        end
    end

    UpdateMainFrameVisibility()
    return ShouldShowLiveFrame() and needsAnimation
end

-- ============================================================================
-- UI: Create main frame
-- ============================================================================

local function CreateUI()
    EnsurePaneState()
    if next(paneFrames) then
        return
    end

    for _, paneId in ipairs(DISPLAY_PANE_IDS) do
        EnsurePaneFrame(paneId)
    end
    RebuildAllPaneBars()
    UpdateMainFrameVisibility()
end

local function DestroyUI()
    if C.StopDisplayUpdates then
        C.StopDisplayUpdates()
    end
    EndSettingsLivePreview()
    for _, pane in pairs(paneFrames) do
        pane.hasVisibleEntries = false
        pane.enabled = false
        pane.frame:Hide()
    end
end

-- ============================================================================
-- Roster event frame
-- ============================================================================

local function SetupRosterEvents()
    if rosterFrame then return end
    rosterFrame = CreateFrame("Frame")
    rosterFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    rosterFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    rosterFrame:RegisterEvent("SPELLS_CHANGED")
    rosterFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    rosterFrame:SetScript("OnEvent", function(_, event, arg1)
        if event == "GROUP_ROSTER_UPDATE" then
            CleanPartyList()
            AutoRegisterParty()
            if C.RequestDisplayRefresh then
                C.RequestDisplayRefresh()
            end
        elseif event == "PLAYER_ENTERING_WORLD" then
            CheckZoneVisibility()
            AutoRegisterParty()
            if C.RequestDisplayRefresh then
                C.RequestDisplayRefresh()
            end
        elseif event == "SPELLS_CHANGED" then
            FindMyDefensives()
        elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
            if arg1 == "player" then
                FindMyDefensives()
            end
        end
    end)
end

local function TeardownRosterEvents()
    if rosterFrame then
        rosterFrame:UnregisterAllEvents()
        rosterFrame = nil
    end
end

-- ============================================================================
-- GroupInspector callback (update tracked defensives on spec change)
-- ============================================================================

local function OnInspectComplete(unit, name, class, specID)
    LogDebug(format("OnInspectComplete: unit=%s name=%s class=%s specID=%s",
        tostring(unit), tostring(name), tostring(class), tostring(specID)))

    local info = partyMembers[name]
    if not info then
        LogDebug(format("  -> %s not tracked, skipping", tostring(name)))
        return
    end

    UpdateMemberDefensives(name, class or info.class, specID, "inspect", unit)
    info = partyMembers[name]
    LogDebug(format("  -> %s tracked with %d defensive entries, specID=%d",
        name, (function() local n=0 for _ in pairs(info.cds) do n=n+1 end return n end)(), specID))
    if C.RequestDisplayRefresh then
        C.RequestDisplayRefresh()
    end
end

local function RegisterSpellMatchWatcher()
    if spellMatchHandle then
        ns.Services.PartySpellWatcher:Unregister(spellMatchHandle)
        spellMatchHandle = nil
    end

    if not ns.Services.PartySpellWatcher or not ns.Services.PartySpellWatcher.OnPartySpellMatch then
        return
    end

    ns.Services.PartySpellWatcher:Initialize()
    spellMatchHandle = ns.Services.PartySpellWatcher:OnPartySpellMatch({
        label = "CrackedDefensives",
        lookupTable = TRACKED_DEFENSIVES,
        candidateResolver = ResolveDefensiveCandidates,
        entryToID = ENTRY_TO_ID,
        callback = OnPartyDefensiveMatch,
    })
end

local function RefreshTrackedDefensiveState(moduleDB)
    if moduleDB then
        db = moduleDB
    end

    RebuildTrackedDefensiveCatalog()

    if not initialized then
        return
    end

    if ns.Services.GroupAuraTracker and ns.Services.GroupAuraTracker.RegisterWatch then
        RefreshAuraWatches()
        if ns.Services.GroupAuraTracker.RequestFullRescan then
            ns.Services.GroupAuraTracker:RequestFullRescan()
        end
    end

    FindMyDefensives()
    CleanPartyList()
    AutoRegisterParty()
    RegisterSpellMatchWatcher()

    if C.RequestDisplayRefresh then
        C.RequestDisplayRefresh()
    end
end

-- ============================================================================
-- Module Lifecycle
-- ============================================================================

local function OnInitialize(moduleDB)
    if initialized then
        db = moduleDB
        RebuildTrackedDefensiveCatalog()
        return
    end
    db = moduleDB
    RebuildTrackedDefensiveCatalog()
    if ns.Services.GroupInspector and ns.Services.GroupInspector.Initialize then
        ns.Services.GroupInspector:Initialize()
    end
    if ns.Services.GroupAuraTracker and ns.Services.GroupAuraTracker.Initialize then
        ns.Services.GroupAuraTracker:Initialize()
        if ns.Services.GroupAuraTracker.RegisterCallback then
            ns.Services.GroupAuraTracker:RegisterCallback("Cracked", OnAuraStateChanged)
        end
        RefreshAuraWatches()
    end

    FindMyDefensives()

    CheckZoneVisibility()

    SetupOwnTracking()

    SetupRosterEvents()

    AutoRegisterParty()

    RegisterSpellMatchWatcher()

    ns.Services.GroupInspector:RegisterInspectComplete("Cracked", OnInspectComplete)

    if C.RequestDisplayRefresh then
        C.RequestDisplayRefresh()
    end

    if IsDeepDebugModeEnabled() then
        ProbeBlizzardUISurfaces("init")
    end
    initialized = true
    LogDebug("OnInitialize complete")
end

local function OnEnable(moduleDB)
    db = moduleDB
    RebuildTrackedDefensiveCatalog()
    if not initialized then
        OnInitialize(moduleDB)
        return
    end

    if ns.Services.GroupAuraTracker and ns.Services.GroupAuraTracker.RegisterCallback then
        ns.Services.GroupAuraTracker:RegisterCallback("Cracked", OnAuraStateChanged)
        RefreshAuraWatches()
    end

    FindMyDefensives()
    CheckZoneVisibility()
    SetupOwnTracking()
    SetupRosterEvents()
    AutoRegisterParty()

    RegisterSpellMatchWatcher()

    ns.Services.GroupInspector:RegisterInspectComplete("Cracked", OnInspectComplete)

    if C.RequestDisplayRefresh then
        C.RequestDisplayRefresh()
    end
end

local function OnDisable()
    DestroyUI()
    TeardownOwnTracking()
    TeardownRosterEvents()

    if spellMatchHandle then
        ns.Services.PartySpellWatcher:Unregister(spellMatchHandle)
        spellMatchHandle = nil
    end

    ns.Services.GroupInspector:UnregisterInspectComplete("Cracked")
    if ns.Services.GroupAuraTracker and ns.Services.GroupAuraTracker.UnregisterWatch then
        if ns.Services.GroupAuraTracker.UnregisterCallback then
            ns.Services.GroupAuraTracker:UnregisterCallback("Cracked")
        end
        ns.Services.GroupAuraTracker:UnregisterWatch(AURA_WATCH_KEY)
        ns.Services.GroupAuraTracker:UnregisterWatch(GROUP_BUFF_WATCH_KEY)
    end

    wipe(partyMembers)
    wipe(myCds)
    initialized = false
end

-- ============================================================================
-- Exports
-- ============================================================================

C.OnInitialize = OnInitialize
C.OnEnable = OnEnable
C.OnDisable = OnDisable
C.ShouldShowLiveFrame = ShouldShowLiveFrame
C.UpdateMainFrameVisibility = UpdateMainFrameVisibility
C.UpdateDisplayNow = UpdateDisplay
C.CreateUI = CreateUI
C.DestroyUI = DestroyUI
C.CheckZoneVisibility = CheckZoneVisibility
C.RefreshAuraWatches = RefreshAuraWatches
C.RefreshTrackedDefensiveState = RefreshTrackedDefensiveState
C.BeginSettingsLivePreview = BeginSettingsLivePreview
C.EndSettingsLivePreview = EndSettingsLivePreview
C.RebuildPaneBars = RebuildPaneBars
C.RebuildAllPaneBars = RebuildAllPaneBars
C.ApplyPanePosition = ApplyPanePosition
C.EnsurePaneState = EnsurePaneState
C.GetPaneStyle = GetPaneStyle
C.SetPaneStyleValue = SetPaneStyleValue
C.IsPaneLinked = IsPaneLinked
C.SetPaneLinked = SetPaneLinked
C.SetCatalogPreviewEnabled = function(enabled)
    catalogPreviewEnabled = not not enabled
end
C.IsCatalogPreviewEnabled = function()
    return catalogPreviewEnabled
end
C.SetActiveSettingsPaneId = function(paneId)
    if PANE_LABELS[paneId] then
        activeSettingsPaneId = paneId
    else
        activeSettingsPaneId = "all"
    end
end
C.GetActiveSettingsPaneId = function()
    return activeSettingsPaneId
end
C.GetDisplayPaneIds = function()
    return DISPLAY_PANE_IDS
end
C.GetStylePaneIds = function()
    return STYLE_PANE_IDS
end
C.GetPaneLabels = function()
    return PANE_LABELS
end
C.GetPaneTitles = function()
    return PANE_TITLES
end
C.GetBarLayoutForStyle = GetBarLayoutForStyle
C.GetFontObj = GetFontObj
C.BuildEntryLabel = BuildEntryLabel
C.GetAllDefensives = function()
    return TRACKED_DEFENSIVES
end
C.GetGroupBuffs = function()
    return GROUP_BUFFS
end
C.GetClassColors = function()
    return CLASS_COLORS
end
C.GetDefaultSpellIcon = function()
    return DEFAULT_SPELL_ICON
end
C.GetActiveColor = function()
    return ACTIVE_COLOR
end
C.GetFallbackWhite = function()
    return FALLBACK_WHITE
end
C.GetBarTexture = function()
    return BAR_TEXTURE
end
C.GetDB = function()
    return db
end
C.SetDB = function(moduleDB)
    db = moduleDB
    RebuildTrackedDefensiveCatalog()
end
