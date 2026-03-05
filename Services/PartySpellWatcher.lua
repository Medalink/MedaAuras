local ADDON_NAME, ns = ...

local PartySpellWatcher = {}
ns.Services.PartySpellWatcher = PartySpellWatcher

-- ============================================================================
-- Logging helpers (must be first -- laundering callbacks can fire at load time)
-- ============================================================================

local function Log(msg)
    MedaAuras.Log(format("[PartySpellWatcher] %s", msg))
end

local function LogDebug(msg)
    MedaAuras.LogDebug(format("[PartySpellWatcher] %s", msg))
end

-- ============================================================================
-- Taint Laundering Widgets
--
-- UNIT_SPELLCAST_SUCCEEDED fires for party1-4 / partypet1-4 but the spellID
-- arg is tainted (SecretWhenUnitSpellCastRestricted).  A tainted number can't
-- be used as a table key.  The trick: set a StatusBar/Slider value to the
-- tainted number, and its OnValueChanged callback receives a CLEAN copy from
-- the C++ widget internals.
-- ============================================================================

local launderBar = CreateFrame("StatusBar")
launderBar:SetMinMaxValues(0, 9999999)

local launderSlider = CreateFrame("Slider", nil, UIParent)
launderSlider:SetMinMaxValues(0, 9999999)
launderSlider:SetSize(1, 1)
launderSlider:Hide()

local barResult = nil
local sliderResult = nil

launderBar:SetScript("OnValueChanged", function(_, value)
    barResult = value
end)

launderSlider:SetScript("OnValueChanged", function(_, value)
    sliderResult = value
end)

local function LaunderSpellID(taintedID)
    barResult = nil
    launderBar:SetValue(0)
    local barOk, barErr = pcall(launderBar.SetValue, launderBar, taintedID)

    sliderResult = nil
    launderSlider:SetValue(0)
    local sliderOk, sliderErr = pcall(launderSlider.SetValue, launderSlider, taintedID)

    local cleanID = barResult or sliderResult
    if not cleanID then
        LogDebug(format("LaunderSpellID FAILED: barOk=%s barErr=%s sliderOk=%s sliderErr=%s",
            tostring(barOk), tostring(barErr), tostring(sliderOk), tostring(sliderErr)))
    end
    return cleanID
end

-- ============================================================================
-- State
-- ============================================================================

local partyFrames = {}
local partyPetFrames = {}
for i = 1, 4 do
    partyFrames[i] = CreateFrame("Frame")
    partyPetFrames[i] = CreateFrame("Frame")
end

local recentPartyCasts = {}     -- [playerName] = GetTime()
local nameplateCastFrames = {}  -- [unit] = frame
local mobInterruptFrame
local nameplateFrame
local rosterFrame
local initialized = false

local interruptCallbacks = {}   -- [handle] = func(name, spellID, unit)
local mobKickCallbacks = {}     -- [handle] = func(name)
local handleCounter = 0

-- ============================================================================
-- Callback dispatch
-- ============================================================================

local function FireInterrupt(name, spellID, unit)
    for handle, func in pairs(interruptCallbacks) do
        local ok, err = pcall(func, name, spellID, unit)
        if not ok then
            MedaAuras.LogWarn(format("[PartySpellWatcher] callback[%d] error: %s", handle, tostring(err)))
        end
    end
end

local function FireMobKick(name)
    for handle, func in pairs(mobKickCallbacks) do
        local ok, err = pcall(func, name)
        if not ok then
            MedaAuras.LogWarn(format("[PartySpellWatcher] mob-kick callback[%d] error: %s", handle, tostring(err)))
        end
    end
end

-- ============================================================================
-- Party spell cast handler (with laundering)
-- ============================================================================

local function OnPartyCast(partyIndex, isOwnerOfPet)
    return function(_, event, eUnit, eCastGUID, eSpellID)
        local ownerUnit = "party" .. partyIndex
        local cleanName = UnitName(ownerUnit)
        if not cleanName then return end

        recentPartyCasts[cleanName] = GetTime()

        local cleanID = LaunderSpellID(eSpellID)
        if not cleanID then
            LogDebug(format("Laundering failed for %s cast", cleanName))
            return
        end

        local data = ns.InterruptData and ns.InterruptData.ALL_INTERRUPTS
        if not data then return end

        local ok, kickData = pcall(function() return data[cleanID] end)
        if ok and kickData then
            Log(format("PARTY KICK: %s cast %s (ID %d) via %s",
                cleanName, kickData.name, cleanID,
                isOwnerOfPet and "pet" or "self"))
            FireInterrupt(cleanName, cleanID, ownerUnit)
        end
    end
end

-- ============================================================================
-- Register watchers for current party members
-- ============================================================================

local function RegisterPartyWatchers()
    local registered = 0
    local petRegistered = 0
    for i = 1, 4 do
        local unit = "party" .. i
        partyFrames[i]:UnregisterAllEvents()
        if UnitExists(unit) then
            partyFrames[i]:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", unit)
            partyFrames[i]:SetScript("OnEvent", OnPartyCast(i, false))
            registered = registered + 1
        end

        local petUnit = "partypet" .. i
        partyPetFrames[i]:UnregisterAllEvents()
        if UnitExists(petUnit) then
            partyPetFrames[i]:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", petUnit)
            partyPetFrames[i]:SetScript("OnEvent", OnPartyCast(i, true))
            petRegistered = petRegistered + 1
        end
    end
    LogDebug(format("RegisterPartyWatchers: %d party, %d pet", registered, petRegistered))
end

-- ============================================================================
-- Mob interrupt correlation
--
-- When UNIT_SPELLCAST_INTERRUPTED fires on target/focus/nameplate, find the
-- party member whose cast timestamp is closest (< 0.5s) to attribute the kick.
-- ============================================================================

local CORRELATION_WINDOW = 0.5

local function OnMobInterrupted(unit)
    local now = GetTime()
    local bestName = nil
    local bestDelta = 999

    for name, ts in pairs(recentPartyCasts) do
        local delta = now - ts
        if delta > 1.0 then
            recentPartyCasts[name] = nil
        elseif delta < bestDelta then
            bestDelta = delta
            bestName = name
        end
    end

    if bestName and bestDelta < CORRELATION_WINDOW then
        Log(format("Mob kick attributed to %s (delta=%.3fs)", bestName, bestDelta))
        FireMobKick(bestName)
    end
end

local function SetupMobInterruptTracking()
    if mobInterruptFrame then return end

    mobInterruptFrame = CreateFrame("Frame")
    mobInterruptFrame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "target", "focus")
    mobInterruptFrame:SetScript("OnEvent", function(_, _, unit)
        OnMobInterrupted(unit)
    end)

    nameplateFrame = CreateFrame("Frame")
    nameplateFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    nameplateFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    nameplateFrame:SetScript("OnEvent", function(_, event, unit)
        if event == "NAME_PLATE_UNIT_ADDED" then
            if not nameplateCastFrames[unit] then
                nameplateCastFrames[unit] = CreateFrame("Frame")
            end
            local f = nameplateCastFrames[unit]
            f:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", unit)
            f:SetScript("OnEvent", function(_, _, eUnit)
                OnMobInterrupted(eUnit)
            end)
        elseif event == "NAME_PLATE_UNIT_REMOVED" then
            if nameplateCastFrames[unit] then
                nameplateCastFrames[unit]:UnregisterAllEvents()
            end
        end
    end)
end

-- ============================================================================
-- Roster change handling
-- ============================================================================

local function SetupRosterTracking()
    if rosterFrame then return end

    rosterFrame = CreateFrame("Frame")
    rosterFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    rosterFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    rosterFrame:RegisterEvent("UNIT_PET")
    rosterFrame:SetScript("OnEvent", function(_, event)
        RegisterPartyWatchers()
    end)
end

-- ============================================================================
-- Public API
-- ============================================================================

function PartySpellWatcher:Initialize()
    if initialized then return end
    initialized = true

    Log("Initializing")
    SetupMobInterruptTracking()
    SetupRosterTracking()
    RegisterPartyWatchers()
    Log("Initialized OK")
end

function PartySpellWatcher:OnPartyInterrupt(callback)
    handleCounter = handleCounter + 1
    local handle = handleCounter
    interruptCallbacks[handle] = callback
    return handle
end

function PartySpellWatcher:OnMobKick(callback)
    handleCounter = handleCounter + 1
    local handle = handleCounter
    mobKickCallbacks[handle] = callback
    return handle
end

function PartySpellWatcher:Unregister(handle)
    interruptCallbacks[handle] = nil
    mobKickCallbacks[handle] = nil
end

function PartySpellWatcher:GetRecentCastTime(name)
    return recentPartyCasts[name]
end
