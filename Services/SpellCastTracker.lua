local _, ns = ...

local GetTime = GetTime
local pairs = pairs
local format = format
local CreateFrame = CreateFrame

local SpellCastTracker = {}
ns.Services.SpellCastTracker = SpellCastTracker

local handleCounter = 0
local spellCallbacks = {}   -- [spellID] = { [handle] = func }
local anyCallbacks = {}     -- [handle] = func
local lastCastTimes = {}    -- [spellID] = timestamp

local eventFrame

function SpellCastTracker:Initialize()
    if eventFrame then return end

    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    eventFrame:SetScript("OnEvent", function(_, _, unit, _, spellID)
        if unit ~= "player" then return end

        local cbs = spellCallbacks[spellID]
        local hasAny = next(anyCallbacks)
        if not cbs and not hasAny then return end

        local now = GetTime()
        lastCastTimes[spellID] = now

        if cbs then
            for _, func in pairs(cbs) do
                func(spellID, now)
            end
        end

        if hasAny then
            for _, func in pairs(anyCallbacks) do
                func(spellID, now)
            end
        end
    end)

    MedaAuras.LogDebug("[SpellCastTracker] Initialized, listening to UNIT_SPELLCAST_SUCCEEDED")
end

function SpellCastTracker:OnPlayerCast(spellID, callback)
    handleCounter = handleCounter + 1
    local handle = handleCounter

    if not spellCallbacks[spellID] then
        spellCallbacks[spellID] = {}
    end
    spellCallbacks[spellID][handle] = callback

    return handle
end

function SpellCastTracker:OnAnyPlayerCast(callback)
    handleCounter = handleCounter + 1
    local handle = handleCounter
    anyCallbacks[handle] = callback
    return handle
end

function SpellCastTracker:Unregister(handle)
    anyCallbacks[handle] = nil
    for _, cbs in pairs(spellCallbacks) do
        cbs[handle] = nil
    end
end

function SpellCastTracker:GetLastCastTime(spellID)
    return lastCastTimes[spellID]
end
