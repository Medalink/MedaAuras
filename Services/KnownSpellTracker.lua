local _, ns = ...

local format = format
local GetTime = GetTime
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local next = next
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown

local C_Spell = C_Spell
local C_UnitAuras = C_UnitAuras
local GetPlayerAuraBySpellID = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID or nil
local GetAuraDataBySpellName = C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName or nil

local KnownSpellTracker = {}
ns.Services.KnownSpellTracker = KnownSpellTracker

local eventFrame
local initialized = false
local castHandle
local watches = {} -- [key] = { spells = { { spellID, queryName, filter, duration, cooldown } }, bySpellID = {} }
local states = {}  -- [key] = { [spellID] = state }

local function LogDebug(msg)
    MedaAuras.LogDebug(format("[KnownSpellTracker] %s", msg))
end

local function IsValueNonSecret(value)
    if ns.IsValueNonSecret then
        return ns.IsValueNonSecret(value)
    end
    return true
end

local function ResolveSpellName(spellID, fallback)
    if C_Spell and C_Spell.GetSpellName and spellID then
        local ok, result = pcall(C_Spell.GetSpellName, spellID)
        if ok and type(result) == "string" and result ~= "" then
            return result
        end
    end
    return fallback
end

local function EnsureKeyState(key)
    states[key] = states[key] or {}
    return states[key]
end

local function BuildStateFromAura(spell, auraInfo, previousState)
    local now = GetTime()
    local state = previousState or {}

    state.spellID = spell.spellID
    state.spellName = spell.queryName
    state.active = false
    state.exactTiming = false
    state.duration = nil
    state.expirationTime = nil
    state.applications = 0

    if auraInfo then
        state.active = true
        if IsValueNonSecret(auraInfo.duration) and IsValueNonSecret(auraInfo.expirationTime) then
            state.exactTiming = true
            state.duration = tonumber(auraInfo.duration) or nil
            state.expirationTime = tonumber(auraInfo.expirationTime) or nil
            state.syntheticHold = false
        elseif previousState and previousState.expirationTime and previousState.expirationTime > now then
            state.duration = previousState.duration
            state.expirationTime = previousState.expirationTime
            state.syntheticHold = previousState.syntheticHold
        elseif spell.duration and spell.duration > 0 then
            state.duration = spell.duration
            state.expirationTime = now + spell.duration
            state.syntheticHold = true
        elseif previousState and previousState.active then
            state.duration = previousState.duration
            state.expirationTime = previousState.expirationTime
            state.syntheticHold = true
        else
            state.syntheticHold = true
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

        state.lastSeen = now
        return state
    end

    if previousState and previousState.active then
        if previousState.expirationTime and previousState.expirationTime > now then
            state.active = true
            state.duration = previousState.duration
            state.expirationTime = previousState.expirationTime
            state.applications = previousState.applications or 0
            state.syntheticHold = previousState.syntheticHold
            state.lastSeen = now
            return state
        end

        if previousState.syntheticHold and InCombatLockdown and InCombatLockdown() then
            state.active = true
            state.duration = previousState.duration
            state.expirationTime = previousState.expirationTime
            state.applications = previousState.applications or 0
            state.syntheticHold = true
            state.lastSeen = now
            return state
        end
    end

    state.syntheticHold = false
    state.lastSeen = now
    return state
end

local function SyncWatch(key)
    local watch = watches[key]
    if not watch then
        return
    end

    local keyState = EnsureKeyState(key)
    for _, spell in ipairs(watch.spells) do
        local previousState = keyState[spell.spellID]
        local auraInfo
        if GetPlayerAuraBySpellID then
            local ok, result = pcall(GetPlayerAuraBySpellID, spell.spellID)
            if ok and result then
                auraInfo = result
            end
        end
        if GetAuraDataBySpellName then
            local ok, result = pcall(GetAuraDataBySpellName, "player", spell.queryName, spell.filter)
            if ok and result then
                auraInfo = auraInfo or result
            end
        end
        keyState[spell.spellID] = BuildStateFromAura(spell, auraInfo, previousState)
    end
end

local function SyncAll()
    for key in pairs(watches) do
        SyncWatch(key)
    end
end

local function OnEvent(_, event, unit)
    if event == "PLAYER_ENTERING_WORLD" then
        SyncAll()
    elseif event == "UNIT_AURA" then
        if unit == "player" then
            SyncAll()
        end
    end
end

local function EnsureEventFrame()
    if eventFrame then
        return eventFrame
    end

    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

    if eventFrame.RegisterUnitEvent then
        local ok = pcall(eventFrame.RegisterUnitEvent, eventFrame, "UNIT_AURA", "player")
        if not ok then
            eventFrame:RegisterEvent("UNIT_AURA")
        end
    else
        eventFrame:RegisterEvent("UNIT_AURA")
    end

    eventFrame:SetScript("OnEvent", OnEvent)
    return eventFrame
end

local function ActivateSpell(key, spellID, source)
    local watch = watches[key]
    if not watch then
        return
    end

    local spell = watch.bySpellID[spellID]
    if not spell then
        return
    end

    local now = GetTime()
    local keyState = EnsureKeyState(key)
    local state = keyState[spellID] or {
        spellID = spellID,
        spellName = spell.queryName,
    }

    state.active = true
    state.lastSeen = now
    state.lastSource = source

    if spell.duration and spell.duration > 0 then
        state.duration = spell.duration
        state.expirationTime = now + spell.duration
        state.syntheticHold = true
    else
        state.syntheticHold = true
    end

    if spell.cooldown and spell.cooldown > 0 then
        state.cdEnd = now + spell.cooldown
    end

    keyState[spellID] = state
end

function KnownSpellTracker:Initialize()
    if initialized then
        return
    end

    initialized = true

    if ns.Services.SpellCastTracker and not castHandle then
        ns.Services.SpellCastTracker:Initialize()
        castHandle = ns.Services.SpellCastTracker:OnAnyPlayerCast(function(spellID)
            for key, watch in pairs(watches) do
                if watch.bySpellID[spellID] then
                    ActivateSpell(key, spellID, "cast")
                end
            end
        end)
    end

    LogDebug("Initialized")
end

function KnownSpellTracker:RegisterPlayerWatch(key, config)
    if type(key) ~= "string" or key == "" or type(config) ~= "table" then
        return false
    end

    self:Initialize()
    EnsureEventFrame()

    local spells = {}
    local bySpellID = {}

    for _, spell in ipairs(config.spells or {}) do
        if spell and spell.spellID then
            local entry = {
                spellID = spell.spellID,
                queryName = ResolveSpellName(spell.spellID, spell.name or tostring(spell.spellID)),
                filter = spell.filter or config.filter or "HELPFUL",
                duration = tonumber(spell.duration) or nil,
                cooldown = tonumber(spell.cooldown) or nil,
            }
            spells[#spells + 1] = entry
            bySpellID[entry.spellID] = entry
        end
    end

    watches[key] = {
        spells = spells,
        bySpellID = bySpellID,
    }
    states[key] = states[key] or {}

    SyncWatch(key)
    LogDebug(format("Registered player watch '%s' with %d spell(s)", key, #spells))
    return true
end

function KnownSpellTracker:UnregisterWatch(key)
    watches[key] = nil
    states[key] = nil

    if eventFrame and not next(watches) then
        eventFrame:UnregisterAllEvents()
        eventFrame:SetScript("OnEvent", nil)
        eventFrame = nil
    end
end

function KnownSpellTracker:RequestPlayerScan(key)
    if key and watches[key] then
        SyncWatch(key)
        return
    end
    SyncAll()
end

function KnownSpellTracker:GetPlayerSpellState(key, spellID)
    local keyState = states[key]
    return keyState and keyState[spellID] or nil
end
