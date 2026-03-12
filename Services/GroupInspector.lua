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
local C_Timer = C_Timer

local GroupInspector = {}
ns.Services.GroupInspector = GroupInspector

-- ============================================================================
-- State
-- ============================================================================

local eventFrame
local cache = {}           -- [guid] = { unit, name, class, specID, inspected, timestamp }
local inspectQueue = {}    -- FIFO of { unit, guid } awaiting inspect
local queuedInspects = {}  -- [guid] = true while queued
local inspectBusy = false
local callbacks = {}       -- [key] = func
local inspectCompleteCallbacks = {} -- [key] = func(unit, name, class, specID)
local ticker

local INSPECT_INTERVAL = 1.5
local CACHE_STALE_SEC = 300

-- ============================================================================
-- Logging helpers
-- ============================================================================

local function Log(msg)
    MedaAuras.Log(format("[GroupInspector] %s", msg))
end

local function LogDebug(msg)
    MedaAuras.LogDebug(format("[GroupInspector] %s", msg))
end

local function LogWarn(msg)
    MedaAuras.LogWarn(format("[GroupInspector] %s", msg))
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

local function CacheUnit(unit)
    if not UnitExists(unit) then return nil end
    local guid = UnitGUID(unit)
    if not guid then return nil end

    local _, class = UnitClass(unit)
    local name = UnitName(unit)
    local specID = nil
    local inspected = false

    if UnitIsUnit(unit, "player") then
        local specIndex = GetSpecialization()
        if specIndex then
            specID = GetSpecializationInfo(specIndex)
        end
        inspected = true
    end

    local existing = cache[guid]
    if existing and existing.specID and not inspected then
        specID = existing.specID
        inspected = existing.inspected
    end

    cache[guid] = {
        unit      = unit,
        name      = name or "Unknown",
        class     = class or "UNKNOWN",
        specID    = specID,
        inspected = inspected,
        timestamp = GetTime(),
    }

    LogDebug(format("Cached %s: %s class=%s specID=%s inspected=%s",
        unit, name or "?", class or "?", tostring(specID), tostring(inspected)))

    return guid
end

local function ProcessInspectQueue()
    if inspectBusy or #inspectQueue == 0 then return end
    if not next(callbacks) and not next(inspectCompleteCallbacks) then return end

    local request = table.remove(inspectQueue, 1)
    local unit = request and request.unit
    local guid = request and request.guid
    if guid then
        queuedInspects[guid] = nil
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
    LogDebug(format("Sending NotifyInspect for %s", unit))

    local ok, err = pcall(NotifyInspect, unit)
    if not ok then
        LogWarn(format("NotifyInspect failed for %s: %s", unit, tostring(err)))
        inspectBusy = false
        C_Timer.After(INSPECT_INTERVAL, ProcessInspectQueue)
    end
end

local function OnInspectReady(guid)
    inspectBusy = false

    for _, entry in pairs(cache) do
        if entry.unit and UnitGUID(entry.unit) == guid then
            local specID = GetInspectSpecialization(entry.unit)
            if specID and specID > 0 then
                local oldSpec = entry.specID
                entry.specID = specID
                entry.inspected = true
                entry.timestamp = GetTime()
                LogDebug(format("Inspected %s: specID=%d%s",
                    entry.name, specID,
                    oldSpec and oldSpec ~= specID and format(" (changed from %d)", oldSpec) or ""))
                FireCallbacks()
                FireInspectComplete(entry.unit, entry.name, entry.class, specID)
            end
            break
        end
    end

    C_Timer.After(INSPECT_INTERVAL, ProcessInspectQueue)
end

local function ScanRoster()
    local units = GetGroupUnits()
    local currentGUIDs = {}
    local newCount, cachedCount, leftCount = 0, 0, 0

    for _, unit in ipairs(units) do
        local guid = CacheUnit(unit)
        if guid then
            currentGUIDs[guid] = true
            local entry = cache[guid]
            if not entry.inspected and not UnitIsUnit(unit, "player") then
                if not queuedInspects[guid] then
                    inspectQueue[#inspectQueue + 1] = { unit = unit, guid = guid }
                    queuedInspects[guid] = true
                    newCount = newCount + 1
                else
                    cachedCount = cachedCount + 1
                end
            else
                cachedCount = cachedCount + 1
            end
        end
    end

    for guid in pairs(cache) do
        if not currentGUIDs[guid] then
            cache[guid] = nil
            leftCount = leftCount + 1
        end
    end

    Log(format("GROUP_ROSTER_UPDATE: %d new, %d cached, %d left", newCount, cachedCount, leftCount))

    FireCallbacks()
    ProcessInspectQueue()
end

-- ============================================================================
-- Event handling
-- ============================================================================

local function OnEvent(_, event, arg1)
    if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        ScanRoster()
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
    eventFrame:RegisterEvent("INSPECT_READY")
    eventFrame:SetScript("OnEvent", OnEvent)

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
            local guid = UnitGUID(unit)
            local entry = guid and cache[guid]
            local _, unitClass = UnitClass(unit)

            for _, provider in ipairs(providersList) do
                if unitClass == provider.class then
                    local specMatch = (provider.specID == nil) or
                                     (entry and entry.specID == provider.specID)

                    if specMatch then
                        local hasSpell = false
                        if UnitIsUnit(unit, "player") then
                            hasSpell = IsPlayerSpell(provider.spellID)
                        else
                            hasSpell = true
                        end

                        if hasSpell then
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
    end

    return results
end

function GroupInspector:GetUnitInfo(unit)
    if not UnitExists(unit) then return nil end
    local guid = UnitGUID(unit)
    return guid and cache[guid] or nil
end

function GroupInspector:RequestRefresh()
    wipe(inspectQueue)
    wipe(queuedInspects)
    inspectBusy = false
    ScanRoster()
end

function GroupInspector:RequestReinspectAll()
    for _, entry in pairs(cache) do
        if not UnitIsUnit(entry.unit, "player") then
            entry.inspected = false
        end
    end
    wipe(inspectQueue)
    wipe(queuedInspects)
    inspectBusy = false
    ScanRoster()
end

function GroupInspector:GetAllCached()
    return cache
end
