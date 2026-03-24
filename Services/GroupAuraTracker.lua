local _, ns = ...

local format = format
local GetTime = GetTime
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local CreateFrame = CreateFrame
local UnitExists = UnitExists
local UnitName = UnitName
local GetNumGroupMembers = GetNumGroupMembers
local IsInGroup = IsInGroup
local IsInRaid = IsInRaid

local C_UnitAuras = C_UnitAuras
local C_Spell = C_Spell
local GetAuraDataBySpellName = C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName or nil
local GetAuraDataByAuraInstanceID = C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID or nil

local GroupAuraTracker = {}
ns.Services.GroupAuraTracker = GroupAuraTracker

local eventFrame
local watches = {} -- [key] = { spells = { { spellID, name, queryName, filter } } }
local states = {}  -- [key] = { [unit] = { unit, name, spells = { [spellID] = state } } }
local callbacks = {} -- [key] = func(watchKey, unit)

local function LogDebug(msg)
    MedaAuras.LogDebug(format("[GroupAuraTracker] %s", msg))
end

local function FireCallbacks(watchKey, unit)
    for key, func in pairs(callbacks) do
        local ok, err = pcall(func, watchKey, unit)
        if not ok then
            MedaAuras.LogWarn(format("[GroupAuraTracker] callback '%s' error: %s", tostring(key), tostring(err)))
        end
    end
end

local function IsValueNonSecret(value)
    if ns.IsValueNonSecret then
        return ns.IsValueNonSecret(value)
    end
    return true
end

local function IsAuraNonSecret(auraInfo)
    if ns.IsAuraNonSecret then
        return ns.IsAuraNonSecret(auraInfo)
    end
    return auraInfo ~= nil
end

local function IsAuraTimingReadable(auraInfo)
    if not auraInfo then
        return false
    end
    return IsValueNonSecret(auraInfo.duration) and IsValueNonSecret(auraInfo.expirationTime)
end

local function ResolveSpellName(spellID, fallbackName)
    if C_Spell and C_Spell.GetSpellName and spellID then
        local ok, result = pcall(C_Spell.GetSpellName, spellID)
        if ok and type(result) == "string" and result ~= "" then
            return result
        end
    end
    return fallbackName
end

local function IsTrackedGroupUnit(unit)
    if unit == "player" then
        return UnitExists(unit)
    end

    if type(unit) ~= "string" or not UnitExists(unit) then
        return false
    end

    if IsInRaid() then
        return unit:match("^raid%d+$") ~= nil
    end

    if IsInGroup() then
        return unit:match("^party%d+$") ~= nil
    end

    return false
end

local function GetGroupUnits()
    local units = {}

    if IsInRaid() then
        local count = GetNumGroupMembers()
        for i = 1, count do
            units[#units + 1] = "raid" .. i
        end
    elseif IsInGroup() then
        units[#units + 1] = "player"
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                units[#units + 1] = unit
            end
        end
    else
        units[#units + 1] = "player"
    end

    return units
end

local function EnsureUnitState(key, unit)
    if not unit or not UnitExists(unit) then
        return nil, nil
    end

    states[key] = states[key] or {}
    local unitStates = states[key]
    local state = unitStates[unit]
    if not state then
        state = {
            unit = unit,
            name = UnitName(unit) or "Unknown",
            spells = {},
            auraInstances = {},
        }
        unitStates[unit] = state
    else
        state.unit = unit
        state.name = UnitName(unit) or state.name
        state.auraInstances = state.auraInstances or {}
    end

    return state, unit
end

local function BuildSpellState(unit, spell, auraInfo, previousState)
    local state = {
        spellID = spell.spellID,
        spellName = spell.name,
        queryName = spell.queryName,
        filter = spell.filter,
        unit = unit,
        active = auraInfo ~= nil,
        exactTiming = false,
        usedCachedTiming = false,
        isNonSecret = false,
        sourceUnit = nil,
        duration = nil,
        expirationTime = nil,
        applications = 0,
        lastSeen = GetTime(),
    }

    if auraInfo then
        state.isNonSecret = IsAuraNonSecret(auraInfo)
        state.exactTiming = IsAuraTimingReadable(auraInfo)

        if state.exactTiming then
            state.duration = auraInfo.duration
            state.expirationTime = auraInfo.expirationTime
        elseif previousState and previousState.active and previousState.exactTiming
            and previousState.expirationTime and previousState.expirationTime > GetTime() then
            state.exactTiming = true
            state.usedCachedTiming = true
            state.duration = previousState.duration
            state.expirationTime = previousState.expirationTime
        end

        if IsValueNonSecret(auraInfo.sourceUnit) then
            state.sourceUnit = auraInfo.sourceUnit
        elseif previousState and previousState.sourceUnit then
            state.sourceUnit = previousState.sourceUnit
        end

        if IsValueNonSecret(auraInfo.applications) then
            state.applications = tonumber(auraInfo.applications) or 0
        elseif IsValueNonSecret(auraInfo.stackCount) then
            state.applications = tonumber(auraInfo.stackCount) or 0
        elseif IsValueNonSecret(auraInfo.count) then
            state.applications = tonumber(auraInfo.count) or 0
        elseif previousState and previousState.active then
            state.applications = tonumber(previousState.applications) or 0
        end
    elseif previousState and previousState.active then
        state.applications = tonumber(previousState.applications) or 0
    end

    return state
end

local function SpellStateChanged(previousState, nextState)
    if previousState == nil or nextState == nil then
        return previousState ~= nextState
    end

    return previousState.active ~= nextState.active
        or previousState.exactTiming ~= nextState.exactTiming
        or previousState.usedCachedTiming ~= nextState.usedCachedTiming
        or previousState.sourceUnit ~= nextState.sourceUnit
        or previousState.duration ~= nextState.duration
        or previousState.expirationTime ~= nextState.expirationTime
        or previousState.applications ~= nextState.applications
end

local function ScanUnitForWatch(key, watch, unit)
    if not watch or not unit or not UnitExists(unit) or not GetAuraDataBySpellName then
        return false
    end

    local unitState = EnsureUnitState(key, unit)
    if not unitState then
        return false
    end

    local spellStates = unitState.spells
    local auraInstances = {}
    local changed = false
    for _, spell in ipairs(watch.spells) do
        local previousState = spellStates[spell.spellID]
        local auraInfo
        local ok, result = pcall(GetAuraDataBySpellName, unit, spell.queryName, spell.filter)
        if ok then
            auraInfo = result
        end
        if auraInfo and IsValueNonSecret(auraInfo.auraInstanceID) then
            auraInstances[auraInfo.auraInstanceID] = spell.spellID
        end
        local nextState = BuildSpellState(unit, spell, auraInfo, previousState)
        if SpellStateChanged(previousState, nextState) then
            changed = true
        end
        spellStates[spell.spellID] = nextState
    end
    unitState.auraInstances = auraInstances

    return changed
end

local function UpdateSpellState(unitState, unit, spell, auraInfo)
    local previousState = unitState.spells[spell.spellID]
    local nextState = BuildSpellState(unit, spell, auraInfo, previousState)
    local changed = SpellStateChanged(previousState, nextState)
    unitState.spells[spell.spellID] = nextState

    if auraInfo and IsValueNonSecret(auraInfo.auraInstanceID) then
        unitState.auraInstances[auraInfo.auraInstanceID] = spell.spellID
    end

    return changed
end

local function ClearSpellInstance(unitState, unit, spell, auraInstanceID)
    local previousState = unitState.spells[spell.spellID]
    local nextState = BuildSpellState(unit, spell, nil, previousState)
    local changed = SpellStateChanged(previousState, nextState)
    unitState.spells[spell.spellID] = nextState
    if auraInstanceID ~= nil then
        unitState.auraInstances[auraInstanceID] = nil
    end
    return changed
end

local function ApplyAuraUpdateToWatch(key, watch, unit, updateInfo)
    if not watch or not unit or not UnitExists(unit) then
        return false
    end

    if not updateInfo or updateInfo.isFullUpdate or not GetAuraDataByAuraInstanceID then
        return ScanUnitForWatch(key, watch, unit)
    end

    local unitState = EnsureUnitState(key, unit)
    if not unitState then
        return false
    end

    local changed = false
    local needsFallbackScan = false

    if updateInfo.addedAuras then
        for _, auraInfo in ipairs(updateInfo.addedAuras) do
            local spellID = auraInfo and auraInfo.spellId or nil
            if IsValueNonSecret(spellID) then
                local spell = watch.bySpellID[spellID]
                if spell and UpdateSpellState(unitState, unit, spell, auraInfo) then
                    changed = true
                end
            elseif auraInfo ~= nil then
                needsFallbackScan = true
            end
        end
    end

    if updateInfo.updatedAuraInstanceIDs then
        for _, auraInstanceID in ipairs(updateInfo.updatedAuraInstanceIDs) do
            if IsValueNonSecret(auraInstanceID) then
                local knownSpellID = unitState.auraInstances[auraInstanceID]
                local auraInfo
                local ok, result = pcall(GetAuraDataByAuraInstanceID, unit, auraInstanceID)
                if ok then
                    auraInfo = result
                end

                local spellID = knownSpellID
                if auraInfo and IsValueNonSecret(auraInfo.spellId) then
                    spellID = auraInfo.spellId
                end

                local spell = spellID and watch.bySpellID[spellID] or nil
                if spell then
                    if auraInfo then
                        if UpdateSpellState(unitState, unit, spell, auraInfo) then
                            changed = true
                        end
                    elseif ClearSpellInstance(unitState, unit, spell, auraInstanceID) then
                        changed = true
                    end
                elseif auraInfo ~= nil or knownSpellID ~= nil then
                    needsFallbackScan = true
                end
            else
                needsFallbackScan = true
            end
        end
    end

    if updateInfo.removedAuraInstanceIDs then
        for _, auraInstanceID in ipairs(updateInfo.removedAuraInstanceIDs) do
            if IsValueNonSecret(auraInstanceID) then
                local spellID = unitState.auraInstances[auraInstanceID]
                local spell = spellID and watch.bySpellID[spellID] or nil
                if spell and ClearSpellInstance(unitState, unit, spell, auraInstanceID) then
                    changed = true
                end
            else
                needsFallbackScan = true
            end
        end
    end

    if needsFallbackScan then
        return ScanUnitForWatch(key, watch, unit) or changed
    end

    return changed
end

local function ClearMissingUnitsForKey(key)
    local activeUnits = {}
    local removed = false
    for _, unit in ipairs(GetGroupUnits()) do
        if unit and UnitExists(unit) then
            activeUnits[unit] = true
        end
    end

    local unitStates = states[key]
    if not unitStates then
        return
    end

    for unit in pairs(unitStates) do
        if not activeUnits[unit] then
            unitStates[unit] = nil
            removed = true
        end
    end

    return removed
end

local function RescanWatchUnit(key, unit, suppressNotify)
    if not unit or not UnitExists(unit) then
        return false
    end

    local watch = watches[key]
    if not watch then
        return false
    end

    local changed = ScanUnitForWatch(key, watch, unit)
    if changed and not suppressNotify then
        FireCallbacks(key, unit)
    end

    return changed
end

local function RescanWatchAll(key, suppressNotify)
    local units = GetGroupUnits()
    local changed = false
    for _, unit in ipairs(units) do
        if RescanWatchUnit(key, unit, true) then
            changed = true
        end
    end
    if ClearMissingUnitsForKey(key) then
        changed = true
    end
    if changed and not suppressNotify then
        FireCallbacks(key, nil)
    end

    return changed
end

local function RescanUnit(unit)
    local changed = false
    for key in pairs(watches) do
        if RescanWatchUnit(key, unit, true) then
            changed = true
        end
    end
    if changed then
        FireCallbacks(nil, unit)
    end
end

local function RescanAll()
    local changed = false
    for key in pairs(watches) do
        if RescanWatchAll(key, true) then
            changed = true
        end
    end
    if changed then
        FireCallbacks(nil, nil)
    end
end

local function OnEvent(_, event, arg1, arg2)
    if event == "UNIT_AURA" then
        if not IsTrackedGroupUnit(arg1) then
            return
        end
        for key, watch in pairs(watches) do
            if watch.rescanMode == "full" then
                RescanWatchAll(key)
            else
                local changed = ApplyAuraUpdateToWatch(key, watch, arg1, arg2)
                if changed then
                    FireCallbacks(key, arg1)
                end
            end
        end
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        RescanAll()
    end
end

function GroupAuraTracker:Initialize()
    if eventFrame then
        return
    end

    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("UNIT_AURA")
    eventFrame:SetScript("OnEvent", OnEvent)

    LogDebug("Initialized")
end

function GroupAuraTracker:RegisterWatch(key, config)
    if type(key) ~= "string" or key == "" or type(config) ~= "table" then
        return false
    end

    local spells = {}
    local bySpellID = {}
    for _, spell in ipairs(config.spells or {}) do
        if spell and spell.spellID then
            local entry = {
                spellID = spell.spellID,
                name = spell.name or ResolveSpellName(spell.spellID, tostring(spell.spellID)),
                queryName = ResolveSpellName(spell.spellID, spell.name),
                filter = spell.filter or config.filter or "HELPFUL",
            }
            spells[#spells + 1] = entry
            bySpellID[entry.spellID] = entry
        end
    end

    watches[key] = {
        spells = spells,
        bySpellID = bySpellID,
        rescanMode = config.rescanMode == "full" and "full" or "unit",
    }
    states[key] = states[key] or {}

    LogDebug(format("Registered watch '%s' with %d spell(s), rescanMode=%s",
        key, #spells, watches[key].rescanMode))
    RescanWatchAll(key)
    return true
end

function GroupAuraTracker:UnregisterWatch(key)
    watches[key] = nil
    states[key] = nil
end

function GroupAuraTracker:RequestUnitScan(unit)
    RescanUnit(unit)
end

function GroupAuraTracker:RequestWatchScan(key, unit)
    if unit then
        RescanWatchUnit(key, unit)
    else
        RescanWatchAll(key)
    end
end

function GroupAuraTracker:RequestFullRescan()
    RescanAll()
end

function GroupAuraTracker:GetUnitSpellState(key, unit, spellID)
    if not key or not unit or not spellID then
        return nil
    end

    local unitState = states[key] and states[key][unit]
    return unitState and unitState.spells and unitState.spells[spellID] or nil
end

function GroupAuraTracker:GetWatchState(key)
    return states[key]
end

function GroupAuraTracker:RegisterCallback(key, func)
    callbacks[key] = func
end

function GroupAuraTracker:UnregisterCallback(key)
    callbacks[key] = nil
end
