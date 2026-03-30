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
local GetUnitAuras = C_UnitAuras and C_UnitAuras.GetUnitAuras or nil
local IsAuraFilteredOutByInstanceID = C_UnitAuras and C_UnitAuras.IsAuraFilteredOutByInstanceID or nil

local GroupAuraTracker = {}
ns.Services.GroupAuraTracker = GroupAuraTracker

local eventFrame
local watches = {} -- [key] = watch
local states = {} -- [key] = { [unit] = unitState }
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

local function ResolveSpellIcon(spellID, fallbackIcon)
    if C_Spell and C_Spell.GetSpellTexture and spellID then
        local ok, result = pcall(C_Spell.GetSpellTexture, spellID)
        if ok and result ~= nil and IsValueNonSecret(result) then
            return result
        end
    end
    return fallbackIcon
end

local function AddUnique(list, seen, value)
    if type(value) ~= "string" or value == "" or seen[value] then
        return
    end
    seen[value] = true
    list[#list + 1] = value
end

local function RegisterLookupBucket(map, key, entry)
    if type(key) ~= "string" or key == "" then
        return
    end

    local bucket = map[key]
    if not bucket then
        bucket = {}
        map[key] = bucket
    end

    bucket[#bucket + 1] = entry
end

local function RegisterIconBucket(map, icon, entry)
    if icon == nil or not IsValueNonSecret(icon) then
        return
    end

    local bucket = map[icon]
    if not bucket then
        bucket = {}
        map[icon] = bucket
    end

    bucket[#bucket + 1] = entry
end

local function ChooseSpellFromBucket(bucket, auraIcon)
    if type(bucket) ~= "table" or #bucket == 0 then
        return nil
    end

    if #bucket == 1 then
        return bucket[1]
    end

    if auraIcon ~= nil and IsValueNonSecret(auraIcon) then
        local matched
        for _, entry in ipairs(bucket) do
            if entry.icon ~= nil and entry.icon == auraIcon then
                if matched then
                    return nil
                end
                matched = entry
            end
        end
        if matched then
            return matched
        end
    end

    return nil
end

local function BuildScanFilters(spell, watchConfigDefaultFilter, watchConfigFilters)
    local scanFilters = {}
    local seenFilters = {}

    if type(spell.filters) == "table" then
        for _, filter in ipairs(spell.filters) do
            AddUnique(scanFilters, seenFilters, filter)
        end
    end

    if type(watchConfigFilters) == "table" then
        for _, filter in ipairs(watchConfigFilters) do
            AddUnique(scanFilters, seenFilters, filter)
        end
    end

    if #scanFilters == 0 then
        AddUnique(scanFilters, seenFilters, spell.filter or watchConfigDefaultFilter or "HELPFUL")
    end

    return scanFilters
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
        return nil
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

    return state
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

local function MatchAuraToSpell(watch, auraInfo)
    if type(auraInfo) ~= "table" then
        return nil, 0
    end

    local auraIcon = auraInfo.icon or auraInfo.iconID
    local auraSpellID = tonumber(auraInfo.spellId or auraInfo.spellID)
    if auraSpellID and IsValueNonSecret(auraSpellID) then
        local spell = watch.bySpellID[auraSpellID]
        if spell then
            return spell, 3
        end
    end

    local auraName = auraInfo.name
    if type(auraName) == "string" and auraName ~= "" and IsValueNonSecret(auraName) then
        local spell = ChooseSpellFromBucket(watch.byName[auraName], auraIcon)
        if spell then
            return spell, 2
        end
    end

    if auraIcon ~= nil and IsValueNonSecret(auraIcon) then
        local spell = ChooseSpellFromBucket(watch.byIcon[auraIcon], auraIcon)
        if spell then
            return spell, 1
        end
    end

    return nil, 0
end

local function IsBetterAuraMatch(existingAura, existingPriority, newAura, newPriority)
    if not existingAura then
        return true
    end

    if newPriority ~= existingPriority then
        return newPriority > existingPriority
    end

    local existingExact = IsAuraTimingReadable(existingAura)
    local newExact = IsAuraTimingReadable(newAura)
    if newExact ~= existingExact then
        return newExact
    end

    local existingExpiration = tonumber(existingAura.expirationTime) or 0
    local newExpiration = tonumber(newAura.expirationTime) or 0
    return newExpiration > existingExpiration
end

local function CollectMatchedAuras(watch, unit)
    local matchedBySpellID = {}
    local matchPriorityBySpellID = {}

    if not GetUnitAuras or not watch or not unit or not UnitExists(unit) then
        return matchedBySpellID
    end

    for _, filter in ipairs(watch.filters) do
        local ok, auras = pcall(GetUnitAuras, unit, filter)
        if ok and type(auras) == "table" then
            for _, auraInfo in ipairs(auras) do
                local spell, priority = MatchAuraToSpell(watch, auraInfo)
                if spell then
                    local spellID = spell.spellID
                    if IsBetterAuraMatch(
                        matchedBySpellID[spellID],
                        matchPriorityBySpellID[spellID] or 0,
                        auraInfo,
                        priority
                    ) then
                        matchedBySpellID[spellID] = auraInfo
                        matchPriorityBySpellID[spellID] = priority
                    end
                end
            end
        end
    end

    return matchedBySpellID
end

local function GetDirectAuraForSpell(unit, spell)
    if not GetAuraDataBySpellName or not spell or not spell.queryName then
        return nil
    end

    local ok, result = pcall(GetAuraDataBySpellName, unit, spell.queryName, spell.filter)
    if ok then
        return result
    end

    return nil
end

local function ScanUnitForWatch(key, watch, unit)
    if not watch or not unit or not UnitExists(unit) then
        return false
    end

    local unitState = EnsureUnitState(key, unit)
    if not unitState then
        return false
    end

    local matchedBySpellID = CollectMatchedAuras(watch, unit)
    local spellStates = unitState.spells
    local auraInstances = {}
    local changed = false

    for _, spell in ipairs(watch.spells) do
        local previousState = spellStates[spell.spellID]
        local auraInfo = matchedBySpellID[spell.spellID]
        if not auraInfo and watch.allowDirectLookup then
            auraInfo = GetDirectAuraForSpell(unit, spell)
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

local function WatchHasFilterInterest(watch, unit, auraInstanceID)
    if not IsAuraFilteredOutByInstanceID or not watch or not unit or not auraInstanceID then
        return true
    end

    for _, filter in ipairs(watch.filters) do
        local ok, filteredOut = pcall(IsAuraFilteredOutByInstanceID, unit, auraInstanceID, filter)
        if ok and filteredOut == false then
            return true
        end
    end

    return false
end

local function UnitAuraUpdateRelevant(key, watch, unit, updateInfo)
    if not watch or not unit or not UnitExists(unit) then
        return false
    end

    if not updateInfo or updateInfo.isFullUpdate then
        return true
    end

    local unitState = states[key] and states[key][unit] or nil
    local trackedInstances = unitState and unitState.auraInstances or nil

    if type(updateInfo.addedAuras) == "table" then
        for _, auraInfo in ipairs(updateInfo.addedAuras) do
            local auraInstanceID = auraInfo and auraInfo.auraInstanceID or nil
            if auraInstanceID and WatchHasFilterInterest(watch, unit, auraInstanceID) then
                return true
            end
        end
    end

    if type(updateInfo.updatedAuraInstanceIDs) == "table" then
        for _, auraInstanceID in ipairs(updateInfo.updatedAuraInstanceIDs) do
            if auraInstanceID and ((trackedInstances and trackedInstances[auraInstanceID]) or WatchHasFilterInterest(watch, unit, auraInstanceID)) then
                return true
            end
        end
    end

    if type(updateInfo.removedAuraInstanceIDs) == "table" and trackedInstances then
        for _, auraInstanceID in ipairs(updateInfo.removedAuraInstanceIDs) do
            if auraInstanceID and trackedInstances[auraInstanceID] then
                return true
            end
        end
    end

    return false
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
            elseif UnitAuraUpdateRelevant(key, watch, arg1, arg2) then
                RescanWatchUnit(key, arg1)
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

    local defaultFilter = config.filter or "HELPFUL"
    local watchFilters = {}
    local watchFilterSet = {}
    local spells = {}
    local bySpellID = {}
    local byName = {}
    local byIcon = {}

    for _, spell in ipairs(config.spells or {}) do
        if spell and spell.spellID then
            local queryName = ResolveSpellName(spell.spellID, spell.queryName or spell.name or tostring(spell.spellID))
            local entry = {
                spellID = spell.spellID,
                name = spell.name or queryName or tostring(spell.spellID),
                queryName = queryName,
                filter = spell.filter or defaultFilter,
                filters = BuildScanFilters(spell, defaultFilter, config.filters or config.extraFilters),
                icon = spell.icon or ResolveSpellIcon(spell.spellID, nil),
            }

            for _, filter in ipairs(entry.filters) do
                AddUnique(watchFilters, watchFilterSet, filter)
            end

            spells[#spells + 1] = entry
            bySpellID[entry.spellID] = entry

            RegisterLookupBucket(byName, entry.queryName, entry)
            if entry.queryName ~= entry.name then
                RegisterLookupBucket(byName, entry.name, entry)
            end
            RegisterIconBucket(byIcon, entry.icon, entry)
        end
    end

    if #watchFilters == 0 then
        AddUnique(watchFilters, watchFilterSet, defaultFilter)
    end

    watches[key] = {
        spells = spells,
        bySpellID = bySpellID,
        byName = byName,
        byIcon = byIcon,
        filters = watchFilters,
        allowDirectLookup = config.allowDirectLookup ~= false,
        rescanMode = config.rescanMode == "full" and "full" or "unit",
    }
    states[key] = states[key] or {}

    LogDebug(format("Registered watch '%s' with %d spell(s), %d scan filter(s), rescanMode=%s",
        key, #spells, #watchFilters, watches[key].rescanMode))
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
