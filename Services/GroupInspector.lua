local _, ns = ...

local format = format
local GetTime = GetTime
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local wipe = wipe
local CreateFrame = CreateFrame
local UnitExists = UnitExists
local UnitGUID = UnitGUID
local UnitName = UnitName
local UnitClass = UnitClass
local UnitIsUnit = UnitIsUnit
local UnitIsConnected = UnitIsConnected
local IsInRaid = IsInRaid
local IsInGroup = IsInGroup
local GetNumGroupMembers = GetNumGroupMembers
local GetSpecialization = GetSpecialization
local GetSpecializationInfo = GetSpecializationInfo
local GetInspectSpecialization = GetInspectSpecialization
local CanInspect = CanInspect
local NotifyInspect = NotifyInspect
local IsPlayerSpell = IsPlayerSpell
local InCombatLockdown = InCombatLockdown
local IsInInstance = IsInInstance
local GetInstanceInfo = GetInstanceInfo
local C_Traits = _G and _G.C_Traits or nil
local C_Timer = C_Timer

local GroupInspector = {}
ns.Services.GroupInspector = GroupInspector

-- ============================================================================
-- State
-- ============================================================================

local eventFrame
local cache = {}           -- [unit] = { unit, name, class, specID, inspected, talentSpells, talentsKnown, timestamp }
local inspectQueue = {}    -- FIFO of { unit } awaiting inspect
local queuedInspects = {}  -- [unit] = true while queued
local inspectBusy = false
local inspectBusyUnit
local inspectBusyGUID
local callbacks = {}       -- [key] = func
local inspectCompleteCallbacks = {} -- [key] = func(unit, name, class, specID)
local pendingProcessAfterCombat = false
local lastInstanceKey

local INSPECT_INTERVAL = 1.5

-- ============================================================================
-- Logging helpers
-- ============================================================================

local function LogDebug(msg)
    MedaAuras.LogDebug(format("[GroupInspector] %s", msg))
end

local function LogWarn(msg)
    MedaAuras.LogWarn(format("[GroupInspector] %s", msg))
end

local function IsValueNonSecret(value)
    if ns.IsValueNonSecret then
        return ns.IsValueNonSecret(value)
    end
    return true
end

local function SafeStr(value)
    if ns.SafeStr then
        return ns.SafeStr(value, "<secret>")
    end
    return tostring(value)
end

-- ============================================================================
-- Internal helpers
-- ============================================================================

local function GetGroupUnits()
    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            units[#units + 1] = "raid" .. i
        end
    elseif IsInGroup() then
        units[#units + 1] = "player"
        for i = 1, 4 do
            local u = "party" .. i
            if UnitExists(u) then
                units[#units + 1] = u
            end
        end
    else
        units[#units + 1] = "player"
    end
    return units
end

local function FireCallbacks()
    for key, func in pairs(callbacks) do
        local ok, err = pcall(func)
        if not ok then
            LogWarn(format("Callback '%s' error: %s", tostring(key), tostring(err)))
        end
    end
end

local function FireInspectComplete(unit, name, class, specID)
    for key, func in pairs(inspectCompleteCallbacks) do
        local ok, err = pcall(func, unit, name, class, specID)
        if not ok then
            LogWarn(format("InspectComplete callback '%s' error: %s", tostring(key), tostring(err)))
        end
    end
end

local function GetInstanceKey()
    local inInstance, instanceType = IsInInstance and IsInInstance() or false, nil
    if inInstance and GetInstanceInfo then
        local _, instType, diffID, _, _, _, _, instID = GetInstanceInfo()
        return format("%s:%s:%s", tostring(instType or instanceType or "instance"), tostring(instID or 0), tostring(diffID or 0))
    end

    return "world"
end

local function BuildTalentSpellSet()
    local spells = {}
    if not C_Traits then
        return spells, false
    end

    local configID = -1
    local okConfig, configInfo = pcall(C_Traits.GetConfigInfo, configID)
    if not okConfig or not configInfo or not configInfo.treeIDs or #configInfo.treeIDs == 0 then
        return spells, false
    end

    for _, treeID in ipairs(configInfo.treeIDs) do
        local okTree, nodeIDs = pcall(C_Traits.GetTreeNodes, treeID)
        if okTree and nodeIDs then
            for _, nodeID in ipairs(nodeIDs) do
                local okNode, nodeInfo = pcall(C_Traits.GetNodeInfo, configID, nodeID)
                if okNode and nodeInfo and nodeInfo.activeEntry and nodeInfo.activeRank and nodeInfo.activeRank > 0 then
                    local entryID = nodeInfo.activeEntry.entryID
                    if entryID then
                        local okEntry, entryInfo = pcall(C_Traits.GetEntryInfo, configID, entryID)
                        if okEntry and entryInfo and entryInfo.definitionID then
                            local okDef, defInfo = pcall(C_Traits.GetDefinitionInfo, entryInfo.definitionID)
                            if okDef and defInfo and defInfo.spellID and defInfo.spellID > 0 then
                                spells[defInfo.spellID] = true
                            end
                        end
                    end
                end
            end
        end
    end

    return spells, true
end

local function ScanTalentSpellsIntoEntry(entry)
    if not entry then return false end

    local spells, ok = BuildTalentSpellSet()
    entry.talentSpells = spells
    entry.talentsKnown = ok
    entry.timestamp = GetTime()

    local count = 0
    for _ in pairs(spells) do
        count = count + 1
    end
    LogDebug(format("Talent scan for %s: known=%s count=%d",
        entry.name or "Unknown", tostring(ok), count))
    return ok
end

local function CacheUnit(unit)
    if not UnitExists(unit) then return nil end

    local _, class = UnitClass(unit)
    local name = UnitName(unit)
    local rawGUID = UnitGUID(unit)
    local guid = IsValueNonSecret(rawGUID) and rawGUID or nil
    local specID = nil
    local inspected = false

    if UnitIsUnit(unit, "player") then
        local specIndex = GetSpecialization()
        if specIndex then
            specID = GetSpecializationInfo(specIndex)
        end
        inspected = true
    end

    local existing = cache[unit]
    local sameUnit = existing and existing.guid ~= nil and guid ~= nil and existing.guid == guid
    if existing and existing.specID and not inspected and sameUnit then
        specID = existing.specID
        inspected = existing.inspected
    end

    cache[unit] = {
        unit      = unit,
        guid      = guid,
        name      = name or "Unknown",
        class     = class or "UNKNOWN",
        specID    = specID,
        inspected = inspected,
        talentSpells = sameUnit and existing and existing.talentSpells or {},
        talentsKnown = sameUnit and existing and existing.talentsKnown or UnitIsUnit(unit, "player"),
        timestamp = GetTime(),
    }

    LogDebug(format("Cached %s: %s class=%s guid=%s specID=%s inspected=%s reused=%s",
        unit, name or "?", class or "?", SafeStr(guid), tostring(specID), tostring(inspected), tostring(sameUnit)))

    return unit
end

local function ProcessInspectQueue()
    if inspectBusy or #inspectQueue == 0 then return end
    if not next(callbacks) and not next(inspectCompleteCallbacks) then return end
    if InCombatLockdown and InCombatLockdown() then
        if not pendingProcessAfterCombat then
            pendingProcessAfterCombat = true
            LogDebug("Deferring inspect queue until combat ends")
        end
        return
    end

    local request = table.remove(inspectQueue, 1)
    local unit = request and request.unit
    if unit then
        queuedInspects[unit] = nil
    end

    if not UnitExists(unit) or UnitIsUnit(unit, "player") then
        ProcessInspectQueue()
        return
    end

    if not UnitIsConnected(unit) then
        LogDebug(format("Skipping inspect for %s -- not connected", unit))
        ProcessInspectQueue()
        return
    end

    if not CanInspect(unit) then
        LogDebug(format("Cannot inspect %s -- CanInspect returned false", unit))
        ProcessInspectQueue()
        return
    end

    inspectBusy = true
    inspectBusyUnit = unit
    local busyGUID = UnitGUID(unit)
    inspectBusyGUID = IsValueNonSecret(busyGUID) and busyGUID or nil
    LogDebug(format("Sending NotifyInspect for %s", unit))

    local ok, err = pcall(NotifyInspect, unit)
    if not ok then
        LogWarn(format("NotifyInspect failed for %s: %s", unit, tostring(err)))
        inspectBusy = false
        inspectBusyUnit = nil
        inspectBusyGUID = nil
        C_Timer.After(INSPECT_INTERVAL, ProcessInspectQueue)
    end
end

local function OnInspectReady(guid)
    inspectBusy = false
    local targetUnit = nil

    if inspectBusyUnit and UnitExists(inspectBusyUnit) then
        local okMatch, isMatch = pcall(function()
            if guid == nil or inspectBusyGUID == nil then
                return true
            end
            return inspectBusyGUID == guid
        end)
        if okMatch and isMatch then
            targetUnit = inspectBusyUnit
        end
    end

    if not targetUnit and guid ~= nil then
        for unit, entry in pairs(cache) do
            if entry.unit and UnitExists(entry.unit) then
                local unitGUID = UnitGUID(entry.unit)
                local okMatch, isMatch = pcall(function()
                    if not IsValueNonSecret(unitGUID) then
                        return false
                    end
                    return unitGUID == guid
                end)
                if okMatch and isMatch then
                    targetUnit = unit
                    break
                end
            end
        end
    end

    inspectBusyUnit = nil
    inspectBusyGUID = nil

    local entry = targetUnit and cache[targetUnit] or nil
    if entry and entry.unit and UnitExists(entry.unit) then
        local specID = GetInspectSpecialization(entry.unit)
        if specID and specID > 0 then
            local oldSpec = entry.specID
            entry.specID = specID
            entry.inspected = true
            ScanTalentSpellsIntoEntry(entry)
            LogDebug(format("Inspected %s: specID=%d%s",
                entry.name, specID,
                oldSpec and oldSpec ~= specID and format(" (changed from %d)", oldSpec) or ""))
            FireCallbacks()
            FireInspectComplete(entry.unit, entry.name, entry.class, specID)
        end
    end

    C_Timer.After(INSPECT_INTERVAL, ProcessInspectQueue)
end

local function MarkAllNonPlayerEntriesStale()
    for _, entry in pairs(cache) do
        if not UnitIsUnit(entry.unit, "player") then
            entry.inspected = false
        end
    end
end

local function UnitHasProvider(unit, provider)
    if not unit or not provider or not UnitExists(unit) then
        return false
    end

    if UnitIsUnit(unit, "player") then
        local spellID = provider.talentSpellID or provider.spellID
        return spellID and IsPlayerSpell and IsPlayerSpell(spellID) or false
    end

    local entry = cache[unit]
    if provider.talentSpellID then
        return entry and entry.talentsKnown and entry.talentSpells and entry.talentSpells[provider.talentSpellID] or false
    end

    return true
end

local function ScanRoster()
    local units = GetGroupUnits()
    local currentUnits = {}
    local newCount, cachedCount, leftCount = 0, 0, 0

    for _, unit in ipairs(units) do
        local cacheKey = CacheUnit(unit)
        if cacheKey then
            currentUnits[cacheKey] = true
            local entry = cache[cacheKey]
            local inspectInFlight = false
            if inspectBusy and inspectBusyUnit and inspectBusyGUID then
                local okMatch, isMatch = pcall(function()
                    return cacheKey == inspectBusyUnit or UnitGUID(unit) == inspectBusyGUID
                end)
                inspectInFlight = okMatch and isMatch or false
            elseif inspectBusy and inspectBusyUnit then
                inspectInFlight = cacheKey == inspectBusyUnit
            end
            if not entry.inspected and not UnitIsUnit(unit, "player") then
                if not queuedInspects[cacheKey] and not inspectInFlight then
                    inspectQueue[#inspectQueue + 1] = { unit = unit }
                    queuedInspects[cacheKey] = true
                    newCount = newCount + 1
                else
                    cachedCount = cachedCount + 1
                end
            else
                cachedCount = cachedCount + 1
            end
        end
    end

    for unit in pairs(cache) do
        if not currentUnits[unit] then
            cache[unit] = nil
            queuedInspects[unit] = nil
            leftCount = leftCount + 1
        end
    end

    LogDebug(format("GROUP_ROSTER_UPDATE: %d new, %d cached, %d left", newCount, cachedCount, leftCount))

    FireCallbacks()
    ProcessInspectQueue()
end

local function QueueInspectUnit(unit, forceReinspect)
    if not unit or not UnitExists(unit) or UnitIsUnit(unit, "player") then
        return false
    end

    local cacheKey = CacheUnit(unit)
    if not cacheKey then
        return false
    end

    local entry = cache[cacheKey]
    if forceReinspect and entry then
        entry.specID = nil
        entry.inspected = false
        entry.talentSpells = {}
        entry.talentsKnown = false
    end

    if not queuedInspects[cacheKey] then
        inspectQueue[#inspectQueue + 1] = { unit = cacheKey }
        queuedInspects[cacheKey] = true
    end

    ProcessInspectQueue()
    return true
end

-- ============================================================================
-- Event handling
-- ============================================================================

local function OnEvent(_, event, arg1)
    if event == "GROUP_ROSTER_UPDATE" then
        ScanRoster()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        local instanceKey = GetInstanceKey()
        local instanceChanged = instanceKey ~= lastInstanceKey
        lastInstanceKey = instanceKey

        if instanceChanged then
            LogDebug(format("Instance boundary changed to %s; scheduling full reinspect", instanceKey))
            MarkAllNonPlayerEntriesStale()
        end

        ScanRoster()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingProcessAfterCombat then
            pendingProcessAfterCombat = false
            ProcessInspectQueue()
        end
    elseif event == "INSPECT_READY" then
        OnInspectReady(arg1)
    end
end

-- ============================================================================
-- Public API
-- ============================================================================

function GroupInspector:Initialize()
    if eventFrame then return end

    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("INSPECT_READY")
    eventFrame:SetScript("OnEvent", OnEvent)

    lastInstanceKey = GetInstanceKey()
    LogDebug("Initialized")
    ScanRoster()
end

function GroupInspector:RegisterCallback(key, func)
    callbacks[key] = func
    LogDebug(format("Callback registered: %s", tostring(key)))
end

function GroupInspector:UnregisterCallback(key)
    callbacks[key] = nil
end

function GroupInspector:RegisterInspectComplete(key, func)
    inspectCompleteCallbacks[key] = func
    LogDebug(format("InspectComplete callback registered: %s", tostring(key)))
end

function GroupInspector:UnregisterInspectComplete(key)
    inspectCompleteCallbacks[key] = nil
end

function GroupInspector:QueryProviders(providersList)
    if not providersList then return {} end

    local results = {}
    local units = GetGroupUnits()

    for _, unit in ipairs(units) do
        if UnitExists(unit) then
            local entry = cache[unit]
            local _, unitClass = UnitClass(unit)

            for _, provider in ipairs(providersList) do
                if unitClass == provider.class then
                    local specMatch = (provider.specID == nil) or
                                     (entry and entry.specID == provider.specID)

                    if specMatch and UnitHasProvider(unit, provider) then
                            results[#results + 1] = {
                                unit      = unit,
                                name      = entry and entry.name or UnitName(unit) or "Unknown",
                                class     = unitClass,
                                specID    = entry and entry.specID,
                                spellID   = provider.spellID,
                                spellName = provider.spellName,
                                note      = provider.note,
                            }
                    end
                end
            end
        end
    end

    return results
end

function GroupInspector:GetUnitInfo(unit)
    if not UnitExists(unit) then return nil end
    return cache[unit]
end

function GroupInspector:UnitHasTalentSpell(unit, spellID)
    if not spellID or spellID <= 0 or not UnitExists(unit) then return false end
    if UnitIsUnit(unit, "player") then
        return IsPlayerSpell and IsPlayerSpell(spellID) or false
    end

    local entry = cache[unit]
    return entry and entry.talentsKnown and entry.talentSpells and entry.talentSpells[spellID] or false
end

function GroupInspector:UnitHasProvider(unit, provider)
    return UnitHasProvider(unit, provider)
end

function GroupInspector:RequestRefresh()
    wipe(inspectQueue)
    wipe(queuedInspects)
    inspectBusy = false
    inspectBusyUnit = nil
    inspectBusyGUID = nil
    pendingProcessAfterCombat = false
    ScanRoster()
end

function GroupInspector:RequestUnitReinspect(unit)
    return QueueInspectUnit(unit, true)
end

function GroupInspector:RequestReinspectAll()
    MarkAllNonPlayerEntriesStale()
    wipe(inspectQueue)
    wipe(queuedInspects)
    inspectBusy = false
    inspectBusyUnit = nil
    inspectBusyGUID = nil
    pendingProcessAfterCombat = false
    ScanRoster()
end

function GroupInspector:GetAllCached()
    return cache
end
