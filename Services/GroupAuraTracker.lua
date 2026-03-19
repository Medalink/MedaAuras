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
local issecretvalue = issecretvalue

local GroupAuraTracker = {}
ns.Services.GroupAuraTracker = GroupAuraTracker

local eventFrame
local watches = {} -- [key] = { spells = { { spellID, name, queryName, filter } } }
local states = {}  -- [key] = { [unit] = { unit, name, spells = { [spellID] = state } } }

local function LogDebug(msg)
    MedaAuras.LogDebug(format("[GroupAuraTracker] %s", msg))
end

local function IsValueNonSecret(value)
    if not issecretvalue or value == nil then
        return true
    end
    return not issecretvalue(value)
end

local function IsAuraNonSecret(auraInfo)
    if not auraInfo then
        return false
    end
    if not issecretvalue then
        return true
    end
    return not issecretvalue(auraInfo.spellId)
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
        }
        unitStates[unit] = state
    else
        state.unit = unit
        state.name = UnitName(unit) or state.name
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
    end

    return state
end

local function ScanUnitForWatch(key, watch, unit)
    if not watch or not unit or not UnitExists(unit) or not GetAuraDataBySpellName then
        return
    end

    local unitState = EnsureUnitState(key, unit)
    if not unitState then
        return
    end

    local spellStates = unitState.spells
    for _, spell in ipairs(watch.spells) do
        local previousState = spellStates[spell.spellID]
        local auraInfo
        local ok, result = pcall(GetAuraDataBySpellName, unit, spell.queryName, spell.filter)
        if ok then
            auraInfo = result
        end
        spellStates[spell.spellID] = BuildSpellState(unit, spell, auraInfo, previousState)
    end
end

local function ClearMissingUnitsForKey(key)
    local activeUnits = {}
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
        end
    end
end

local function RescanWatchUnit(key, unit)
    if not unit or not UnitExists(unit) then
        return
    end

    local watch = watches[key]
    if not watch then
        return
    end

    ScanUnitForWatch(key, watch, unit)
end

local function RescanWatchAll(key)
    local units = GetGroupUnits()
    for _, unit in ipairs(units) do
        RescanWatchUnit(key, unit)
    end
    ClearMissingUnitsForKey(key)
end

local function RescanUnit(unit)
    for key in pairs(watches) do
        RescanWatchUnit(key, unit)
    end
end

local function RescanAll()
    for key in pairs(watches) do
        RescanWatchAll(key)
    end
end

local function OnEvent(_, event, arg1)
    if event == "UNIT_AURA" then
        for key, watch in pairs(watches) do
            if watch.rescanMode == "full" then
                RescanWatchAll(key)
            else
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

    local spells = {}
    for _, spell in ipairs(config.spells or {}) do
        if spell and spell.spellID then
            spells[#spells + 1] = {
                spellID = spell.spellID,
                name = spell.name or ResolveSpellName(spell.spellID, tostring(spell.spellID)),
                queryName = ResolveSpellName(spell.spellID, spell.name),
                filter = spell.filter or config.filter or "HELPFUL",
            }
        end
    end

    watches[key] = {
        spells = spells,
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
