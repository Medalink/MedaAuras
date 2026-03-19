local ADDON_NAME, ns = ...

local MedaUI = LibStub("MedaUI-2.0")

local format = format
local GetTime = GetTime
local pairs = pairs
local ipairs = ipairs
local wipe = wipe
local pcall = pcall
local unpack = unpack
local sort = table.sort
local CreateFrame = CreateFrame
local CreateFont = _G and _G.CreateFont
local UnitName = UnitName
local UnitExists = UnitExists
local UnitClass = UnitClass
local UnitIsUnit = UnitIsUnit
local AuraUtil = AuraUtil
local C_CooldownViewer = _G and _G.C_CooldownViewer or nil
local UnitGroupRolesAssigned = _G and _G.UnitGroupRolesAssigned or nil
local IsInGroup = IsInGroup
local IsInRaid = IsInRaid
local IsInInstance = IsInInstance
local C_Timer = C_Timer
local GetSpellTexture = _G and _G.GetSpellTexture or nil
local IsSpellKnown = _G and _G.IsSpellKnown or nil
local IsPlayerSpell = IsPlayerSpell
local GetSpecialization = GetSpecialization
local GetSpecializationInfo = GetSpecializationInfo

if MedaAuras and MedaAuras.Log then
    MedaAuras.Log("[Cracked] File loaded OK")
end

-- ============================================================================
-- Module Info
-- ============================================================================

local MODULE_NAME      = "Cracked"
local MODULE_VERSION   = "0.2"
local MODULE_STABILITY = "experimental"

-- ============================================================================
-- Shared Data
-- ============================================================================

local DD = ns.DefensiveData
local ALL_DEFENSIVES     = DD.ALL_DEFENSIVES
local CLASS_COLORS       = DD.CLASS_COLORS
local CLASS_DEFENSIVE_IDS = DD.CLASS_DEFENSIVE_IDS
local CATEGORY_INFO      = DD.CATEGORY_INFO
local ENTRY_TO_ID        = DD.ENTRY_TO_ID
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
local updateTicker
local shouldShowByZone = true
local showInSettings = false
local spellMatchHandle
local rosterFrame
local blizzardProbeCount = 0
local settingsPreviewCleanup
local lastVisibilityState = {}
local lastRenderSummary = {}
local activeSettingsPaneId = "all"
local IsCategoryEnabled
local UpdateDisplay
local RebuildPaneBars

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
    major = "Major Personals",
    personal = "Minor Personals",
    buffs = "Group Buffs",
}
local PANE_TITLES = {
    all = "Defensives",
    external = "Externals",
    party = "Party CDs",
    major = "Major Personals",
    personal = "Minor Personals",
    buffs = "Group Buffs",
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

local WATCH_SPELLS = {}
for spellID, defData in pairs(ALL_DEFENSIVES) do
    WATCH_SPELLS[#WATCH_SPELLS + 1] = {
        spellID = spellID,
        name = defData.name,
        filter = "HELPFUL",
    }
end
sort(WATCH_SPELLS, function(a, b)
    return a.spellID < b.spellID
end)

local GROUP_BUFF_WATCH_SPELLS = {}
for _, buffData in pairs(GROUP_BUFFS) do
    for _, provider in ipairs(buffData.providers or {}) do
        GROUP_BUFF_WATCH_SPELLS[#GROUP_BUFF_WATCH_SPELLS + 1] = {
            spellID = provider.spellID,
            name = provider.name,
            filter = "HELPFUL",
        }
    end
end
sort(GROUP_BUFF_WATCH_SPELLS, function(a, b)
    return a.spellID < b.spellID
end)

-- ============================================================================
-- Logging
-- ============================================================================

local function Log(msg)      MedaAuras.Log(format("[Cracked] %s", msg)) end
local function LogDebug(msg) MedaAuras.LogDebug(format("[Cracked] %s", msg)) end
local function LogWarn(msg)  MedaAuras.LogWarn(format("[Cracked] %s", msg)) end

local function SafeStr(value)
    local ok, str = pcall(tostring, value)
    if not ok then return "<secret>" end
    local clean = pcall(function() return str == str end)
    if not clean then return "<secret>" end
    return str
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

local function GetPaneStyle(paneId)
    EnsurePaneState()
    return MedaUI:GetResolvedLinkedSettings(db, PANE_STYLE_ROOT, paneId == "all" and "all" or paneId, PANE_STYLE_DEFAULTS)
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

local function IsPaneEnabled(paneId)
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

local function BuildRenderSummary(entries, numVisible, now)
    if not entries or numVisible <= 0 then
        return "entries=none"
    end

    local parts = {}
    for i = 1, math.min(numVisible, 4) do
        local entry = entries[i]
        if entry then
            local state = "READY"
            local chargeText = entry.maxCharges and entry.maxCharges > 1
                and format("%d/%d", entry.currentCharges or entry.maxCharges, entry.maxCharges)
                or nil
            if entry.entryKind == "missingBuff" then
                state = format("MISSING:%d", entry.count or 0)
            elseif entry.isActive then
                state = entry.activeEnd and entry.activeEnd > now
                    and format("ACTIVE:%.1f", entry.activeEnd - now)
                    or "ACTIVE"
            elseif entry.isOnCd then
                state = entry.cdEnd and entry.cdEnd > now
                    and format("CD:%.1f", entry.cdEnd - now)
                    or "CD"
            end
            if chargeText then
                state = chargeText .. ":" .. state
            end

            local label = entry.entryKind == "missingBuff"
                and entry.spellName
                or format("%s:%s", SafeStr(entry.name), entry.spellName)
            parts[#parts + 1] = format("%s[%s]", label, state)
        end
    end

    return table.concat(parts, " | ")
end

local function LogPlayerTrackingSnapshot(reason)
    if not myName then
        return
    end

    local parts = {}
    local now = GetTime()
    for spellID, cd in pairs(myCds) do
        local defData = ALL_DEFENSIVES[spellID]
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
    if db and db.forceFullAuraRescan then
        return "full"
    end
    return "unit"
end

local function RefreshAuraWatches()
    if not ns.Services.GroupAuraTracker or not ns.Services.GroupAuraTracker.RegisterWatch then
        return
    end

    ns.Services.GroupAuraTracker:RegisterWatch(AURA_WATCH_KEY, {
        spells = WATCH_SPELLS,
        filter = "HELPFUL",
        rescanMode = BuildAuraRescanMode(),
    })
    ns.Services.GroupAuraTracker:RegisterWatch(GROUP_BUFF_WATCH_KEY, {
        spells = GROUP_BUFF_WATCH_SPELLS,
        filter = "HELPFUL",
        rescanMode = BuildAuraRescanMode(),
    })
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
    settingsPreviewCleanup = nil
    UpdateMainFrameVisibility()
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

local function GetCachedSpecID(unit)
    if not unit or not UnitExists(unit) then return nil end
    local info = ns.Services.GroupInspector and ns.Services.GroupInspector:GetUnitInfo(unit)
    return info and info.specID or nil
end

local function BuildCandidateSet(cls, specID)
    local ids = CLASS_DEFENSIVE_IDS[cls]
    local candidateLookup = {}
    local candidateIDs = {}
    local classWideCount = 0

    if not ids then
        return candidateLookup, candidateIDs, classWideCount
    end

    for _, spellID in ipairs(ids) do
        local data = ALL_DEFENSIVES[spellID]
        if data and IsCategoryEnabled(data.category) then
            classWideCount = classWideCount + 1
            local allowed = true
            local whitelist = SPELL_SPEC_WHITELIST[spellID]
            if specID and whitelist and not whitelist[specID] then
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

local function UpdateMemberDefensives(name, cls, specID, reason, unit)
    local candidateLookup, candidateIDs, classWideCount = BuildCandidateSet(cls, specID)
    local oldInfo = partyMembers[name]
    local cds = {}
    local effectiveUnit = unit or (oldInfo and oldInfo.unit)

    for _, spellID in ipairs(candidateIDs) do
        local data = ALL_DEFENSIVES[spellID]
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
        specID = specID,
        unit = unit or (oldInfo and oldInfo.unit),
        cds = cds,
        candidateLookup = candidateLookup,
        candidateIDs = candidateIDs,
        classWideCount = classWideCount,
    }

    Log(format("Registered %s (%s spec=%s) with %d/%d defensive candidates via %s",
        name, cls, tostring(specID), #candidateIDs, classWideCount, tostring(reason)))
    LogDebug(format("  CandidateIDs for %s: %s",
        name, FormatCandidateIDs(candidateIDs, candidateLookup)))
end

-- ============================================================================
-- Find own defensive spells
-- ============================================================================

local function FindMyDefensives()
    local _, cls = UnitClass("player")
    myClass = cls
    myName = UnitName("player")

    LogDebug(format("FindMyDefensives: class=%s name=%s", tostring(cls), tostring(myName)))

    wipe(myCds)

    local ids = CLASS_DEFENSIVE_IDS[cls]
    if not ids then
        LogDebug(format("  No defensive IDs for class=%s", tostring(cls)))
        return
    end

    local count = 0
    for _, spellID in ipairs(ids) do
        local data = ALL_DEFENSIVES[spellID]
        if data and IsCategoryEnabled(data.category) then
            local known = IsSpellKnown(spellID)
            if not known then
                local ok, r = pcall(IsPlayerSpell, spellID)
                if ok and r then known = true end
            end
            LogDebug(format("  spellID %d (%s) known=%s cat=%s",
                spellID, data.name, tostring(known), data.category))
            if known then
                local override = GetDefensiveTalentOverride("player", spellID, true)
                local state = {
                    baseCd = data.cd,
                    cdEnd = 0,
                    activeEnd = 0,
                    lastUse = 0,
                }
                ApplyDefensiveMetadata(state, data, override)
                NormalizeChargeState(state, GetTime())
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

    Log(format("FindMyDefensives: found %d known defensives for %s (%s)", count, tostring(myName), tostring(cls)))
    LogPlayerTrackingSnapshot("find-my-defensives")
end

-- ============================================================================
-- Auto-register party members
-- ============================================================================

local function AutoRegisterParty()
    LogDebug(format("AutoRegisterParty: inGroup=%s", tostring(IsInGroup())))
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) then
            local name = UnitName(u)
            local _, cls = UnitClass(u)
            local role = UnitGroupRolesAssigned(u)
            local specID = GetCachedSpecID(u)
            LogDebug(format("  %s: name=%s class=%s role=%s already=%s",
                u, tostring(name), tostring(cls), tostring(role),
                tostring(name and partyMembers[name] ~= nil)))
            if name and cls then
                UpdateMemberDefensives(name, cls, specID, "roster", u)
            end
        else
            LogDebug(format("  %s: does not exist", u))
        end
    end

    local count = 0
    for _ in pairs(partyMembers) do count = count + 1 end
    LogDebug(format("  Total tracked: %d party members", count))
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
            LogDebug(format("CleanPartyList: removed %s (left group)", name))
        end
    end
    if removed > 0 then
        LogDebug(format("CleanPartyList: removed %d member(s)", removed))
    end
end

-- ============================================================================
-- Handle party defensive matched via PartySpellWatcher StatusBar equality test
--
-- PSW's OnPartySpellMatch uses StatusBar clamping to binary-test the tainted
-- spell ID against every key in ALL_DEFENSIVES.  On match, this callback
-- receives fully clean (name, cleanSpellID, defData, unit) args.
-- ============================================================================

local function ProbeCandidateAuras(name, unit, debugInfo)
    if not AuraUtil or not unit or not UnitExists(unit) or not debugInfo or not debugInfo.candidateIDs then
        return
    end

    local function RunProbe(tag)
        local active = {}
        local memberInfo = partyMembers[name]
        for _, spellID in ipairs(debugInfo.candidateIDs) do
            local defData = ALL_DEFENSIVES[spellID]
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
    if info and info.candidateLookup and info.candidateIDs then
        return {
            lookupTable = info.candidateLookup,
            knownIDs = info.candidateIDs,
            label = format("%s:%s", tostring(info.class), tostring(info.specID or "nospec")),
        }
    end

    if unit and UnitExists(unit) then
        local _, cls = UnitClass(unit)
        local specID = GetCachedSpecID(unit)
        if cls then
            local lookupTable, knownIDs = BuildCandidateSet(cls, specID)
            return {
                lookupTable = lookupTable,
                knownIDs = knownIDs,
                label = format("%s:%s(ephemeral)", tostring(cls), tostring(specID or "nospec")),
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

    Log(format("PARTY DEFENSIVE: %s cast %s (ID %d, cat=%s, CD=%ds, dur=%ds, confidence=%s via=%s)",
        SafeStr(name), defData.name, cleanSpellID, defData.category,
        defData.cd, defData.duration,
        tostring(debugInfo and debugInfo.confidence or "unknown"),
        tostring(debugInfo and debugInfo.chosenBy or "unknown")))
    if debugInfo then
        LogDebug(format("  MatchDebug cast=%s cleanID=%s candidates=%s",
            SafeStr(debugInfo.castID),
            SafeStr(debugInfo.cleanID),
            FormatCandidateIDs(debugInfo.candidateIDs, debugInfo.candidateLookup)))
    end

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
        ConsumeDefensiveUse(cd, now)
        local activeDuration = type(cd.displayDuration) == "number" and cd.displayDuration or defData.duration
        cd.activeEnd = activeDuration > 0 and (now + activeDuration) or 0
        cd.lastUse = now

        Log(format("  STATE -> ACTIVE: %s %s activeEnd=%.1f cdEnd=%.1f",
            SafeStr(name), cd.displayName or defData.name,
            cd.activeEnd > 0 and cd.activeEnd or 0,
            cd.cdEnd))
    else
        LogWarn(format("  Could not register %s from %s", SafeStr(name), SafeStr(unit)))
    end

    if ns.Services.GroupAuraTracker and ns.Services.GroupAuraTracker.RequestWatchScan and unit then
        ns.Services.GroupAuraTracker:RequestWatchScan(AURA_WATCH_KEY, unit)
    end

    if unit then
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

    ProbeCandidateAuras(name, unit, debugInfo)
    ProbeBlizzardUISurfaces("match:" .. tostring(defData.name))
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
        local defData = ALL_DEFENSIVES[spellID]
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

        Log(format("OWN DEFENSIVE: %s (ID %d, cat=%s, CD=%ds, dur=%ds) activeEnd=%.1f cdEnd=%.1f",
            cd.displayName or defData.name, spellID, defData.category,
            cd.baseCd or defData.cd, activeDuration,
            cd.activeEnd > 0 and cd.activeEnd or 0,
            cd.cdEnd))
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

    local style = GetPaneStyle(paneId)
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
    frame:SetSize(style.frameWidth, 200)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetResizable(true)
    frame:SetResizeBounds(80, 40, 600, 800)
    frame:SetAlpha(style.alpha)
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
    local summary = BuildRenderSummary(entries, numVisible, now)

    pane.enabled = db.paneMode ~= "split" and paneId == "all" or (db.paneMode == "split" and paneId ~= "all" and IsPaneEnabled(paneId))
    pane.hasVisibleEntries = numVisible > 0 and pane.enabled

    if lastRenderSummary[paneId] ~= summary then
        lastRenderSummary[paneId] = summary
        LogDebug(format("RenderEntries pane=%s visible=%d summary=%s", paneId, numVisible, summary))
    end

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
    local cooldownEntries = {}
    local missingBuffEntries = {}
    local now = GetTime()

    local function GetTrackedAuraState(unit, spellID)
        if not unit or not ns.Services.GroupAuraTracker or not ns.Services.GroupAuraTracker.GetUnitSpellState then
            return nil
        end
        return ns.Services.GroupAuraTracker:GetUnitSpellState(AURA_WATCH_KEY, unit, spellID)
    end

    local function GetTrackedGroupBuffState(unit, spellID)
        if not unit or not ns.Services.GroupAuraTracker or not ns.Services.GroupAuraTracker.GetUnitSpellState then
            return nil
        end
        return ns.Services.GroupAuraTracker:GetUnitSpellState(GROUP_BUFF_WATCH_KEY, unit, spellID)
    end

    local function ResolveActiveState(unit, spellID, cd, defData, isPlayer)
        local auraState = isPlayer and nil or GetTrackedAuraState(unit, spellID)
        local renderMode = "none"
        local activeStart = nil
        local activeEnd = 0
        local activeDuration = 0
        local activeSource = nil
        local duration = defData.duration or 0

        if auraState and auraState.active then
            if auraState.exactTiming and auraState.expirationTime and auraState.duration and auraState.expirationTime > now then
                renderMode = "timer"
                activeEnd = auraState.expirationTime
                activeDuration = auraState.duration
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
            local defData = ALL_DEFENSIVES[spellID]
            if defData and IsCategoryEnabled(defData.category) then
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
                    icon = cd.displayIcon or defData.icon or (GetSpellTexture and GetSpellTexture(spellID)) or DEFAULT_SPELL_ICON,
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
end

local lastStateDump = 0

UpdateDisplay = function()
    if not next(paneFrames) then return end

    local now = GetTime()

    if now - lastStateDump > 10 then
        lastStateDump = now
        local memberCount = 0
        local totalTracked = 0
        for n, info in pairs(partyMembers) do
            memberCount = memberCount + 1
            for sid, cd in pairs(info.cds) do
                totalTracked = totalTracked + 1
                local defData = ALL_DEFENSIVES[sid]
                NormalizeChargeState(cd, now)
                local displayName = cd.displayName or (defData and defData.name) or tostring(sid)
                local activeEnd = type(cd.activeEnd) == "number" and cd.activeEnd or 0
                local cdEnd = type(cd.cdEnd) == "number" and cd.cdEnd or 0
                local currentCharges = type(cd.currentCharges) == "number" and cd.currentCharges or nil
                local maxCharges = type(cd.maxCharges) == "number" and cd.maxCharges or nil
                local isActive = activeEnd > now
                local isOnCd = maxCharges and maxCharges > 1
                    and currentCharges ~= nil
                    and currentCharges <= 0
                    and cdEnd > now
                    or (not (maxCharges and maxCharges > 1) and cdEnd > now)
                if isActive or isOnCd or (maxCharges and maxCharges > 1 and currentCharges and currentCharges < maxCharges) then
                    local chargeSuffix = maxCharges and maxCharges > 1
                        and format(" charges=%d/%d", currentCharges or maxCharges, maxCharges)
                        or ""
                    LogDebug(format("  STATE: %s %s active=%s activeRem=%.1f cdRem=%.1f%s",
                        n, displayName,
                        tostring(isActive),
                        isActive and (activeEnd - now) or 0,
                        cdEnd > now and (cdEnd - now) or 0,
                        chargeSuffix))
                end
            end
        end
        local myCount = 0
        for _ in pairs(myCds) do myCount = myCount + 1 end
        LogDebug(format("UpdateDisplay tick: myDefensives=%d members=%d totalTracked=%d visible=%s",
            myCount, memberCount, totalTracked, tostring(shouldShowByZone)))
    end

    local allEntries = CollectDisplayEntries()

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
end

-- ============================================================================
-- UI: Create main frame
-- ============================================================================

local function CreateUI()
    EnsurePaneState()
    if next(paneFrames) then
        LogDebug("CreateUI: pane frames already exist, refreshing")
        RebuildAllPaneBars()
        UpdateMainFrameVisibility()
        return
    end

    LogDebug("CreateUI: building pane frames...")
    for _, paneId in ipairs(DISPLAY_PANE_IDS) do
        EnsurePaneFrame(paneId)
    end
    RebuildAllPaneBars()
    UpdateMainFrameVisibility()
    LogDebug("CreateUI: complete")
end

local function DestroyUI()
    if updateTicker then updateTicker:Cancel(); updateTicker = nil end
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
        LogDebug(format("Roster event: %s arg1=%s", event, tostring(arg1)))
        if event == "GROUP_ROSTER_UPDATE" then
            CleanPartyList()
            AutoRegisterParty()
        elseif event == "PLAYER_ENTERING_WORLD" then
            CheckZoneVisibility()
            AutoRegisterParty()
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
end

-- ============================================================================
-- Module Lifecycle
-- ============================================================================

local function OnInitialize(moduleDB)
    db = moduleDB
    Log("OnInitialize starting...")

    LogDebug(format("  db.enabled=%s", tostring(moduleDB.enabled)))
    LogDebug(format("  ns.DefensiveData=%s", tostring(ns.DefensiveData ~= nil)))
    LogDebug(format("  ns.Services.PartySpellWatcher=%s", tostring(ns.Services.PartySpellWatcher ~= nil)))
    LogDebug(format("  ns.Services.GroupInspector=%s", tostring(ns.Services.GroupInspector ~= nil)))
    LogDebug(format("  ns.Services.GroupAuraTracker=%s", tostring(ns.Services.GroupAuraTracker ~= nil)))
    if ns.Services.GroupInspector and ns.Services.GroupInspector.Initialize then
        ns.Services.GroupInspector:Initialize()
    end
    if ns.Services.GroupAuraTracker and ns.Services.GroupAuraTracker.Initialize then
        ns.Services.GroupAuraTracker:Initialize()
        RefreshAuraWatches()
    end

    LogDebug("  Step 1: FindMyDefensives")
    FindMyDefensives()

    LogDebug("  Step 2: CreateUI")
    CreateUI()
    LogDebug(format("  paneFrames created: %s", tostring(next(paneFrames) ~= nil)))

    LogDebug("  Step 3: CheckZoneVisibility")
    CheckZoneVisibility()

    LogDebug("  Step 4: SetupOwnTracking")
    SetupOwnTracking()

    LogDebug("  Step 5: SetupRosterEvents")
    SetupRosterEvents()

    LogDebug("  Step 6: AutoRegisterParty")
    AutoRegisterParty()

    LogDebug("  Step 7: Register PartySpellWatcher spell match for defensives")
    ns.Services.PartySpellWatcher:Initialize()
    spellMatchHandle = ns.Services.PartySpellWatcher:OnPartySpellMatch({
        label = "CrackedDefensives",
        lookupTable = ALL_DEFENSIVES,
        candidateResolver = ResolveDefensiveCandidates,
        entryToID = ENTRY_TO_ID,
        callback = OnPartyDefensiveMatch,
    })
    Log(format("  spellMatchHandle=%s", tostring(spellMatchHandle)))

    LogDebug("  Step 8: Register GroupInspector inspect-complete callback")
    ns.Services.GroupInspector:RegisterInspectComplete("Cracked", OnInspectComplete)

    LogDebug("  Step 9: Start UpdateDisplay ticker (0.1s)")
    if updateTicker then updateTicker:Cancel() end
    updateTicker = C_Timer.NewTicker(0.1, UpdateDisplay)

    ProbeBlizzardUISurfaces("init")
    Log("OnInitialize complete - tracking started")
end

local function OnEnable(moduleDB)
    db = moduleDB
    Log("OnEnable called")
    OnInitialize(moduleDB)
end

local function OnDisable()
    Log("OnDisable called")
    DestroyUI()
    TeardownOwnTracking()
    TeardownRosterEvents()

    if spellMatchHandle then
        ns.Services.PartySpellWatcher:Unregister(spellMatchHandle)
        spellMatchHandle = nil
    end

    ns.Services.GroupInspector:UnregisterInspectComplete("Cracked")
    if ns.Services.GroupAuraTracker and ns.Services.GroupAuraTracker.UnregisterWatch then
        ns.Services.GroupAuraTracker:UnregisterWatch(AURA_WATCH_KEY)
        ns.Services.GroupAuraTracker:UnregisterWatch(GROUP_BUFF_WATCH_KEY)
    end

    wipe(partyMembers)
    wipe(myCds)
end

-- ============================================================================
-- Module Defaults
-- ============================================================================

local MODULE_DEFAULTS = {
    enabled = false,
    frameWidth = 240,
    barHeight = 24,
    locked = false,
    showTitle = true,
    showIcons = true,
    showPlayerName = true,
    showSpellName = false,
    growUp = false,
    alpha = 0.9,
    nameFontSize = 0,
    readyFontSize = 0,
    showExternals = true,
    showPartyWide = true,
    showMajor = true,
    showPersonal = false,
    showMissingGroupBuffs = true,
    forceFullAuraRescan = false,
    showInDungeon = true,
    showInRaid = true,
    showInOpenWorld = false,
    showInArena = true,
    showInBG = false,
    paneMode = "combined",
    font = "default",
    titleFontSize = 12,
    iconSize = 0,
    panePositions = {},
    paneStyles = {},
    position = { point = "CENTER", x = 250, y = -150 },
}

-- ============================================================================
-- Preview
-- ============================================================================

local pvContainer, pvInner, pvBars, pvTitleText
local pvTicker
local pvStartTime = 0

local PREVIEW_MOCK = {
    { name = "Tanksworth",  class = "WARRIOR",     spellID = 97462,  baseCd = 180, duration = 10, cdOffset = 60 },
    { name = "Stabsworth",  class = "ROGUE",       spellID = 31224,  baseCd = 120, duration = 5,  cdOffset = 0  },
    { name = "Frostbyte",   class = "MAGE",        spellID = 45438,  baseCd = 240, duration = 10, cdOffset = 100 },
    { name = "Healbot",     class = "PRIEST",      spellID = 33206,  baseCd = 180, duration = 8,  cdOffset = 30 },
    { name = "Felrush",     class = "DEMONHUNTER", spellID = 196718, baseCd = 180, duration = 8,  cdOffset = 0  },
}

local function GetPreviewPaneId()
    return PANE_LABELS[activeSettingsPaneId] and activeSettingsPaneId or "all"
end

local function GetPreviewEntries()
    local paneId = GetPreviewPaneId()
    if paneId == "buffs" then
        return {
            {
                entryKind = "missingBuff",
                spellName = "Fortitude",
                icon = GROUP_BUFFS.stamina and GROUP_BUFFS.stamina.icon or 135987,
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
        local defData = ALL_DEFENSIVES[mock.spellID]
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
    if pvTicker then pvTicker:Cancel(); pvTicker = nil end
    if pvBars then
        for i = 1, #pvBars do
            pvBars[i]:Hide()
            pvBars[i]:SetParent(nil)
        end
        wipe(pvBars)
        pvBars = nil
    end
    pvTitleText = nil
    if pvInner then pvInner:Hide(); pvInner:SetParent(nil); pvInner = nil end
    if pvContainer then pvContainer:Hide(); pvContainer:SetParent(nil); pvContainer = nil end
end

local function CreatePreviewBars()
    if pvInner then pvInner:Hide(); pvInner:SetParent(nil) end

    pvInner = CreateFrame("Frame", nil, pvContainer)
    pvInner:SetAllPoints()
    pvBars = {}

    local paneId = GetPreviewPaneId()
    local style = GetPaneStyle(paneId)
    local entries = GetPreviewEntries()
    local barW, barH, iconS, fontSize, cdFontSize, titleH, titleFontSize = GetBarLayoutForStyle(style)

    if style.showTitle then
        pvTitleText = pvInner:CreateFontString(nil, "OVERLAY")
        pvTitleText:SetFontObject(GetFontObj(style.font or "default", titleFontSize, "outline"))
        pvTitleText:SetPoint("TOP", 0, -3)
        pvTitleText:SetText("|cFF00DDDD" .. (PANE_TITLES[paneId] or "Defensives") .. "|r")
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

        local f = CreateFrame("Frame", nil, pvInner)
        f:SetSize(iconS + barW, barH)
        if style.growUp then
            f:SetPoint("BOTTOMLEFT", 0, yOff)
        else
            f:SetPoint("TOPLEFT", 0, yOff)
        end

        local ico = f:CreateTexture(nil, "ARTWORK")
        ico:SetSize(iconS, barH)
        ico:SetPoint("LEFT", 0, 0)
        ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        if iconS == 0 then ico:Hide() end
        f.icon = ico

        local barBg = f:CreateTexture(nil, "BACKGROUND")
        barBg:SetPoint("TOPLEFT", iconS, 0)
        barBg:SetPoint("BOTTOMRIGHT", 0, 0)
        barBg:SetTexture(BAR_TEXTURE)
        barBg:SetVertexColor(0.15, 0.15, 0.15, 0.9)
        f.barBg = barBg

        local sb = CreateFrame("StatusBar", nil, f)
        sb:SetPoint("TOPLEFT", iconS, 0)
        sb:SetPoint("BOTTOMRIGHT", 0, 0)
        sb:SetStatusBarTexture(BAR_TEXTURE)
        sb:SetStatusBarColor(1, 1, 1, 0.85)
        sb:SetMinMaxValues(0, 1)
        sb:SetValue(0)
        sb:SetFrameLevel(f:GetFrameLevel() + 1)
        f.cdBar = sb

        local content = CreateFrame("Frame", nil, f)
        content:SetPoint("TOPLEFT", iconS, 0)
        content:SetPoint("BOTTOMRIGHT", 0, 0)
        content:SetFrameLevel(sb:GetFrameLevel() + 1)

        local nm = content:CreateFontString(nil, "OVERLAY")
        nm:SetFontObject(GetFontObj(style.font or "default", fontSize, "outline"))
        nm:SetPoint("LEFT", 6, 0)
        nm:SetJustifyH("LEFT")
        nm:SetWidth(barW - 50)
        nm:SetWordWrap(false)
        nm:SetShadowOffset(1, -1)
        nm:SetShadowColor(0, 0, 0, 1)
        if style.showPlayerName == false and not style.showSpellName then nm:Hide() end
        f.nameText = nm

        local cdTxt = content:CreateFontString(nil, "OVERLAY")
        cdTxt:SetFontObject(GetFontObj(style.font or "default", cdFontSize, "outline"))
        cdTxt:SetPoint("RIGHT", -6, 0)
        cdTxt:SetShadowOffset(1, -1)
        cdTxt:SetShadowColor(0, 0, 0, 1)
        f.cdText = cdTxt

        f:Show()
        pvBars[i] = f
    end

    pvContainer:SetSize(style.frameWidth, titleH + #entries * (barH + 1))
end

local function UpdatePreview()
    if not pvContainer or not pvBars or not db then return end

    local paneId = GetPreviewPaneId()
    local style = GetPaneStyle(paneId)
    local entries = GetPreviewEntries()
    local elapsed = GetTime() - pvStartTime
    local _, barH, _, _, _, titleH = GetBarLayoutForStyle(style)

    for i, mock in ipairs(entries) do
        local bar = pvBars[i]
        if not bar then break end

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
            local defData = ALL_DEFENSIVES[mock.spellID]
            if defData then
                bar.icon:SetTexture(defData.icon)
                local col = CLASS_COLORS[mock.class] or FALLBACK_WHITE

                if style.showPlayerName == false and not style.showSpellName then
                    bar.nameText:Hide()
                else
                    bar.nameText:Show()
                    local label = BuildEntryLabel(style, mock.name, defData.name)
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
                    bar.cdBar:SetStatusBarColor(ACTIVE_COLOR[1], ACTIVE_COLOR[2], ACTIVE_COLOR[3], 0.85)
                    bar.barBg:SetVertexColor(ACTIVE_COLOR[1] * 0.25, ACTIVE_COLOR[2] * 0.25, ACTIVE_COLOR[3] * 0.25, 0.9)
                    bar.cdText:SetText(format("%.1fs", rem))
                    bar.cdText:SetTextColor(0.2, 1.0, 0.2)
                elseif pos < mock.baseCd then
                    local rem = mock.baseCd - pos
                    bar.cdBar:SetMinMaxValues(0, mock.baseCd)
                    bar.cdBar:SetValue(rem)
                    bar.cdBar:SetStatusBarColor(col[1], col[2], col[3], 0.85)
                    bar.barBg:SetVertexColor(col[1] * 0.25, col[2] * 0.25, col[3] * 0.25, 0.9)
                    bar.cdText:SetText(format("%.0f", rem))
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

    pvContainer:SetAlpha(style.alpha)
    pvContainer:SetSize(style.frameWidth, titleH + #entries * (barH + 1))
end

local function RebuildPreview()
    if not pvContainer then return end
    CreatePreviewBars()
    UpdatePreview()
end

-- ============================================================================
-- Settings UI
-- ============================================================================

local function BuildSettingsPage(parent, moduleDB)
    db = moduleDB
    EnsurePaneState()
    DestroyPreview()
    EndSettingsLivePreview()

    do
        local anchor = _G["MedaAurasSettingsPanel"]
        if anchor then
            pvContainer = CreateFrame("Frame", nil, anchor)
            pvContainer:SetFrameStrata("HIGH")
            pvContainer:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 0)
            pvContainer:SetClampedToScreen(true)
            pvContainer:SetScript("OnHide", function()
                if pvTicker then pvTicker:Cancel(); pvTicker = nil end
            end)
            MedaAuras:RegisterConfigCleanup(pvContainer)

            local pvBg = pvContainer:CreateTexture(nil, "BACKGROUND")
            pvBg:SetAllPoints()
            pvBg:SetTexture(BAR_TEXTURE)
            pvBg:SetVertexColor(0.08, 0.08, 0.08, 0.85)

            pvStartTime = GetTime()
            CreatePreviewBars()
            UpdatePreview()

            pvTicker = C_Timer.NewTicker(0.1, UpdatePreview)
            if moduleDB.enabled then
                BeginSettingsLivePreview(anchor)
                UpdateDisplay()
            end
        end
    end

    local LEFT_X = 0
    local RIGHT_X = 240
    local generalHeight
    local maxPaneHeight = 0

    local function RefreshVisualLayout()
        if next(paneFrames) then
            RebuildAllPaneBars()
            UpdateDisplay()
        end
        RebuildPreview()
    end

    local function RefreshVisualState()
        if next(paneFrames) then
            UpdateDisplay()
        end
        UpdatePreview()
    end

    local function ResetPanePositions()
        moduleDB.panePositions = {}
        moduleDB._crackedPanePositionMigrated = false
        EnsurePaneState()
        for _, paneId in ipairs(DISPLAY_PANE_IDS) do
            ApplyPanePosition(paneId)
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
            activeSettingsPaneId = previewId
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
                    BeginSettingsLivePreview(anchor)
                    RefreshVisualState()
                end)
            else
                EndSettingsLivePreview()
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

        local resetBtn = MedaUI:CreateButton(p, "Reset Pane Positions", 180)
        resetBtn:SetPoint("TOPLEFT", RIGHT_X, yOff + 16)
        resetBtn.OnClick = ResetPanePositions
        yOff = yOff - 58

        local info = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        info:SetPoint("TOPLEFT", LEFT_X, yOff)
        info:SetTextColor(unpack(MedaUI.Theme.textDim))
        info:SetText("Linked category tabs inherit the Everything style until you unlink them.")
        yOff = yOff - 28

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
            RefreshVisualState()
            RebuildPreview()
        end
        yOff = yOff - 45

        local auraHeader = MedaUI:CreateSectionHeader(p, "Aura Tracking")
        auraHeader:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local fullRescanCB = MedaUI:CreateCheckbox(p, "Force Full Aura Rescan")
        fullRescanCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        fullRescanCB:SetChecked(moduleDB.forceFullAuraRescan)
        fullRescanCB.OnValueChanged = function(_, checked)
            moduleDB.forceFullAuraRescan = checked
            if moduleDB.enabled then
                RefreshAuraWatches()
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
                CheckZoneVisibility()
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

        local header = MedaUI:CreateSectionHeader(p, PANE_LABELS[paneId] .. " Style")
        header:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local linkCB
        local stateLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        stateLabel:SetTextColor(unpack(MedaUI.Theme.textDim))

        if paneId ~= "all" then
            linkCB = MedaUI:CreateCheckbox(p, "Link To Shared Style")
            linkCB:SetPoint("TOPLEFT", LEFT_X, yOff)
            yOff = yOff - 28
        end

        stateLabel:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 24

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
            local style = GetPaneStyle(paneId)
            isRefreshing = true

            if linkCB then
                linkCB:SetChecked(IsPaneLinked(paneId))
                stateLabel:SetText(IsPaneLinked(paneId)
                    and "Linked: edits here update the shared Everything style."
                    or "Unlinked: this pane now keeps its own style.")
            else
                stateLabel:SetText("Editing this tab updates the shared source used by linked panes.")
            end

            fontDD:SetSelected(style.font or "default")
            alphaSlider:SetValue(style.alpha or PANE_STYLE_DEFAULTS.alpha)
            titleCB:SetChecked(style.showTitle ~= false)
            growCB:SetChecked(style.growUp == true)
            iconsCB:SetChecked(style.showIcons ~= false)
            namesCB:SetChecked(style.showPlayerName ~= false)
            spellCB:SetChecked(style.showSpellName == true)
            widthSlider:SetValue(style.frameWidth or PANE_STYLE_DEFAULTS.frameWidth)
            barSlider:SetValue(style.barHeight or PANE_STYLE_DEFAULTS.barHeight)
            iconSlider:SetValue(style.iconSize or 0)
            titleSlider:SetValue(style.titleFontSize or 12)
            nameSlider:SetValue(style.nameFontSize or 0)
            readySlider:SetValue(style.readyFontSize or 0)

            isRefreshing = false
        end

        if linkCB then
            linkCB.OnValueChanged = Guard(function(_, checked)
                SetPaneLinked(paneId, checked)
                RefreshControls()
                RefreshVisualLayout()
            end)
        end

        fontDD.OnValueChanged = Guard(function(_, value) SetPaneStyleValue(paneId, "font", value); RefreshVisualLayout() end)
        alphaSlider.OnValueChanged = Guard(function(_, value) SetPaneStyleValue(paneId, "alpha", value); RefreshVisualLayout() end)
        titleCB.OnValueChanged = Guard(function(_, checked) SetPaneStyleValue(paneId, "showTitle", checked); RefreshVisualLayout() end)
        growCB.OnValueChanged = Guard(function(_, checked) SetPaneStyleValue(paneId, "growUp", checked); RefreshVisualLayout() end)
        iconsCB.OnValueChanged = Guard(function(_, checked) SetPaneStyleValue(paneId, "showIcons", checked); RefreshVisualLayout() end)
        namesCB.OnValueChanged = Guard(function(_, checked) SetPaneStyleValue(paneId, "showPlayerName", checked); RefreshVisualLayout() end)
        spellCB.OnValueChanged = Guard(function(_, checked) SetPaneStyleValue(paneId, "showSpellName", checked); RefreshVisualLayout() end)
        widthSlider.OnValueChanged = Guard(function(_, value) SetPaneStyleValue(paneId, "frameWidth", value); RefreshVisualLayout() end)
        barSlider.OnValueChanged = Guard(function(_, value) SetPaneStyleValue(paneId, "barHeight", value); RefreshVisualLayout() end)
        iconSlider.OnValueChanged = Guard(function(_, value) SetPaneStyleValue(paneId, "iconSize", value); RefreshVisualLayout() end)
        titleSlider.OnValueChanged = Guard(function(_, value) SetPaneStyleValue(paneId, "titleFontSize", value); RefreshVisualLayout() end)
        nameSlider.OnValueChanged = Guard(function(_, value) SetPaneStyleValue(paneId, "nameFontSize", value); RefreshVisualLayout() end)
        readySlider.OnValueChanged = Guard(function(_, value) SetPaneStyleValue(paneId, "readyFontSize", value); RefreshVisualLayout() end)

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

-- ============================================================================
-- Register Module
-- ============================================================================

MedaAuras:RegisterModule({
    name        = MODULE_NAME,
    title       = "Cracked",
    version     = MODULE_VERSION,
    stability   = MODULE_STABILITY,
    author      = "Medalink",
    description = "Tracks party defensive cooldowns in M+ and dungeons. "
               .. "Detects when party members use defensive abilities and "
               .. "displays cooldown bars with active/CD states, colored by class. "
               .. "Uses secret laundering to read tainted party spell IDs.",
    sidebarDesc = "Party defensive cooldown tracker (experimental).",
    defaults    = MODULE_DEFAULTS,
    OnInitialize = OnInitialize,
    OnEnable    = OnEnable,
    OnDisable   = OnDisable,
    pages       = {
        { id = "settings", label = "Settings" },
    },
    buildPage   = function(_, parent)
        BuildSettingsPage(parent, MedaAuras:GetModuleDB(MODULE_NAME))
        return 760
    end,
})
