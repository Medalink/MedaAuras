local ADDON_NAME, ns = ...

local format = format
local GetTime = GetTime
local ipairs = ipairs
local next = next
local pairs = pairs
local pcall = pcall
local tostring = tostring
local type = type
local UnitName = UnitName
local UnitExists = UnitExists
local UnitGUID = UnitGUID
local CreateFrame = CreateFrame
local C_Timer = C_Timer

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
    return cleanID, {
        barOk = barOk,
        barErr = barErr,
        sliderOk = sliderOk,
        sliderErr = sliderErr,
        barResult = barResult,
        sliderResult = sliderResult,
    }
end

-- ============================================================================
-- Spell Match Bar (binary equality test for tainted spell IDs)
--
-- StatusBar clamping lets us test if a tainted ID equals a known clean ID
-- without any Lua comparison or table indexing:
--   Test 1: range=[K, K+1], init=K+1.  OnValueChanged fires iff input <= K
--   Test 2: range=[K-1, K], init=K-1.  OnValueChanged fires iff input >= K
--   Both fire -> input == K
-- ============================================================================

local matchBar = CreateFrame("StatusBar")
local matchDidChange = false
matchBar:SetScript("OnValueChanged", function()
    matchDidChange = true
end)

local function BuildKnownIDs(lookupTable)
    local knownIDs = {}
    for id in pairs(lookupTable) do
        knownIDs[#knownIDs + 1] = id
    end
    table.sort(knownIDs)
    return knownIDs
end

local function FormatIDList(knownIDs, lookupTable, maxCount)
    if not knownIDs or #knownIDs == 0 then
        return "none"
    end

    local parts = {}
    local limit = maxCount or 6
    for i, spellID in ipairs(knownIDs) do
        if i > limit then
            parts[#parts + 1] = format("+%d more", #knownIDs - limit)
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

local function MatchTaintedAgainstTable(taintedID, knownIDs, lookupTable)
    local result = {
        tested = knownIDs and #knownIDs or 0,
        test1Pass = 0,
        test2Pass = 0,
        falsePositiveCount = 0,
        falsePositiveIDs = {},
        matchID = nil,
        matchData = nil,
    }

    if not knownIDs or #knownIDs == 0 then
        return result
    end

    for _, knownID in ipairs(knownIDs) do
        -- Test 1: taintedID <= knownID?
        matchBar:SetMinMaxValues(knownID, knownID + 1)
        matchBar:SetValue(knownID + 1)
        matchDidChange = false
        local ok1 = pcall(matchBar.SetValue, matchBar, taintedID)

        if matchDidChange then
            result.test1Pass = result.test1Pass + 1
            -- Test 2: taintedID >= knownID?
            matchBar:SetMinMaxValues(knownID - 1, knownID)
            matchBar:SetValue(knownID - 1)
            matchDidChange = false
            local ok2 = pcall(matchBar.SetValue, matchBar, taintedID)

            if matchDidChange then
                result.test2Pass = result.test2Pass + 1
                -- Confirmation test: taintedID should NOT equal knownID+1
                matchBar:SetMinMaxValues(knownID + 1, knownID + 2)
                matchBar:SetValue(knownID + 2)
                matchDidChange = false
                local ok3 = pcall(matchBar.SetValue, matchBar, taintedID)

                if matchDidChange then
                    result.falsePositiveCount = result.falsePositiveCount + 1
                    if #result.falsePositiveIDs < 3 then
                        result.falsePositiveIDs[#result.falsePositiveIDs + 1] = knownID
                    end
                else
                    result.matchID = knownID
                    result.matchData = lookupTable[knownID]
                    result.ok1 = ok1
                    result.ok2 = ok2
                    result.ok3 = ok3
                    return result
                end
            end
        end
    end
    return result
end

local function DirectLookupByCleanID(cleanID, lookupTable, entryToID)
    local result = {
        hit = false,
        spellID = nil,
        data = nil,
        ok = false,
    }

    if not cleanID or not lookupTable then
        return result
    end

    local ok, data = pcall(function()
        return lookupTable[cleanID]
    end)
    result.ok = ok
    result.data = data

    if ok and data then
        result.hit = true
        result.spellID = cleanID
        if entryToID and entryToID[data] then
            result.spellID = entryToID[data]
        end
    end
    return result
end

local function NormalizeCandidateResult(result)
    if not result then return nil end
    if result.lookupTable then
        result.knownIDs = result.knownIDs or BuildKnownIDs(result.lookupTable)
        return result
    end
    return {
        lookupTable = result,
        knownIDs = BuildKnownIDs(result),
        label = "resolver",
    }
end

local function FormatMatchSummary(label, summary)
    if not summary then
        return format("%s=none", label)
    end
    if summary.matchID then
        return format("%s=match:%d tested=%d t1=%d t2=%d fp=%d",
            label, summary.matchID, summary.tested or 0,
            summary.test1Pass or 0, summary.test2Pass or 0, summary.falsePositiveCount or 0)
    end
    return format("%s=miss tested=%d t1=%d t2=%d fp=%d",
        label, summary.tested or 0, summary.test1Pass or 0,
        summary.test2Pass or 0, summary.falsePositiveCount or 0)
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
local castSequence = 0

local interruptCallbacks = {}   -- [handle] = func(name, spellID, unit)
local mobKickCallbacks = {}     -- [handle] = func(name)
local anySpellCallbacks = {}    -- [handle] = func(name, spellID, unit)
local spellMatchEntries = {}   -- [handle] = { knownIDs, lookupTable, callback, candidateResolver, label, entryToID }
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

local function FireAnySpell(name, spellID, unit)
    local count = 0
    for handle, func in pairs(anySpellCallbacks) do
        count = count + 1
        local ok, err = pcall(func, name, spellID, unit)
        if not ok then
            MedaAuras.LogWarn(format("[PartySpellWatcher] any-spell callback[%d] error: %s", handle, tostring(err)))
        end
    end
    if count > 0 then
        -- spellID is tainted; format(%d) produces a tainted string that
        -- crashes MedaDebug.  Log without the raw ID.
        LogDebug(format("FireAnySpell: name=%s unit=%s subscribers=%d",
            tostring(name), tostring(unit), count))
    end
end

local function FireSpellMatches(name, taintedID, unit, cleanID, launderInfo, castID)
    for handle, entry in pairs(spellMatchEntries) do
        local label = entry.label or ("handle" .. handle)
        local candidate = NormalizeCandidateResult(
            entry.candidateResolver and entry.candidateResolver(name, unit, cleanID)
        )

        local fullDirect = DirectLookupByCleanID(cleanID, entry.lookupTable, entry.entryToID)
        local candidateDirect = DirectLookupByCleanID(
            cleanID,
            candidate and candidate.lookupTable or nil,
            entry.entryToID
        )
        local fullEquality = MatchTaintedAgainstTable(taintedID, entry.knownIDs, entry.lookupTable)
        local candidateEquality = MatchTaintedAgainstTable(
            taintedID,
            candidate and candidate.knownIDs or nil,
            candidate and candidate.lookupTable or nil
        )

        local chosenID, chosenData
        local confidence = "blocked"
        local chosenBy = "none"

        if candidate and candidate.lookupTable and #candidate.knownIDs > 0 then
            if candidateDirect.hit then
                chosenID = candidateDirect.spellID
                chosenData = candidateDirect.data
                confidence = "exact"
                chosenBy = "candidate-clean"
            elseif candidateEquality.matchID and candidateEquality.matchData then
                chosenID = candidateEquality.matchID
                chosenData = candidateEquality.matchData
                confidence = "exact"
                chosenBy = "candidate-equality"
            elseif #candidate.knownIDs == 1 then
                chosenID = candidate.knownIDs[1]
                chosenData = candidate.lookupTable[chosenID]
                confidence = "likely"
                chosenBy = "single-candidate"
            elseif fullDirect.hit or fullEquality.matchID then
                confidence = "rejected"
                chosenBy = "full-table-conflict"
            else
                confidence = "ambiguous"
                chosenBy = "candidate-miss"
            end
        elseif fullDirect.hit then
            chosenID = fullDirect.spellID
            chosenData = fullDirect.data
            confidence = "exact"
            chosenBy = "full-clean"
        elseif fullEquality.matchID and fullEquality.matchData then
            chosenID = fullEquality.matchID
            chosenData = fullEquality.matchData
            confidence = "exact"
            chosenBy = "full-equality"
        end

        LogDebug(format(
            "Cast[%d] SpellMatch[%d:%s]: name=%s unit=%s cleanID=%s launder(bar=%s slider=%s) candidates=%s | candidateList=%s | directCand=%s | directFull=%s | %s | %s | confidence=%s via=%s",
            castID,
            handle,
            label,
            tostring(name),
            tostring(unit),
            tostring(cleanID),
            tostring(launderInfo and launderInfo.barOk),
            tostring(launderInfo and launderInfo.sliderOk),
            tostring(candidate and #candidate.knownIDs or 0),
            FormatIDList(candidate and candidate.knownIDs or nil, candidate and candidate.lookupTable or nil, 5),
            candidateDirect.hit and tostring(candidateDirect.spellID) or "miss",
            fullDirect.hit and tostring(fullDirect.spellID) or "miss",
            FormatMatchSummary("candidateEq", candidateEquality),
            FormatMatchSummary("fullEq", fullEquality),
            confidence,
            chosenBy
        ))

        if chosenID and chosenData and (confidence == "exact" or confidence == "likely") then
            Log(format("SpellMatch[%d:%s]: %s matched %s (%d) confidence=%s via=%s",
                handle, label, name, chosenData.name or "spell", chosenID, confidence, chosenBy))
            local debugInfo = {
                castID = castID,
                confidence = confidence,
                chosenBy = chosenBy,
                cleanID = cleanID,
                candidateIDs = candidate and candidate.knownIDs or nil,
                candidateLookup = candidate and candidate.lookupTable or nil,
                candidateLabel = candidate and candidate.label or nil,
                experiments = {
                    launder = launderInfo,
                    candidateDirect = candidateDirect,
                    fullDirect = fullDirect,
                    candidateEquality = candidateEquality,
                    fullEquality = fullEquality,
                },
            }
            local ok, err = pcall(entry.callback, name, chosenID, chosenData, unit, debugInfo)
            if not ok then
                MedaAuras.LogWarn(format("[PartySpellWatcher] spell-match callback[%d] error: %s", handle, tostring(err)))
            end
        else
            LogDebug(format("Cast[%d] SpellMatch[%d:%s] suppressed: confidence=%s via=%s",
                castID, handle, label, confidence, chosenBy))
        end
    end
end

-- ============================================================================
-- Party spell cast handler (with laundering)
-- ============================================================================

local function OnPartyCast(partyIndex, isOwnerOfPet)
    return function(_, event, eUnit, eCastGUID, eSpellID)
        local hasInterrupt = next(interruptCallbacks)
        local hasAny = next(anySpellCallbacks)
        local hasMatch = next(spellMatchEntries)
        if not hasInterrupt and not hasAny and not hasMatch then return end

        local ownerUnit = "party" .. partyIndex
        local cleanName = UnitName(ownerUnit)
        if not cleanName then return end

        castSequence = castSequence + 1
        recentPartyCasts[cleanName] = GetTime()

        local cleanID, launderInfo = LaunderSpellID(eSpellID)
        LogDebug(format("Cast[%d] PARTY SPELL: name=%s unit=%s pet=%s cleanID=%s",
            castSequence, cleanName, ownerUnit, tostring(isOwnerOfPet), tostring(cleanID)))

        if hasAny and cleanID then
            FireAnySpell(cleanName, cleanID, ownerUnit)
        end

        if hasMatch then
            FireSpellMatches(cleanName, eSpellID, ownerUnit, cleanID, launderInfo, castSequence)
        end

        if not cleanID then
            LogDebug(format("Cast[%d] Laundering failed for %s cast", castSequence, cleanName))
            return
        end

        if hasInterrupt then
            local data = ns.InterruptData and ns.InterruptData.ALL_INTERRUPTS
            if data then
                local ok, kickData = pcall(function() return data[cleanID] end)
                if ok and kickData then
                    Log(format("PARTY KICK: %s cast %s (ID %d) via %s",
                        cleanName, kickData.name, cleanID,
                        isOwnerOfPet and "pet" or "self"))
                    FireInterrupt(cleanName, cleanID, ownerUnit)
                end
            end
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
    if not next(mobKickCallbacks) then return end
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

function PartySpellWatcher:OnAnyPartySpell(callback)
    handleCounter = handleCounter + 1
    local handle = handleCounter
    anySpellCallbacks[handle] = callback
    LogDebug(format("OnAnyPartySpell registered: handle=%d", handle))
    return handle
end

function PartySpellWatcher:OnPartySpellMatch(lookupTable, callback)
    local config
    if type(lookupTable) == "table" and callback == nil and lookupTable.callback then
        config = lookupTable
    else
        config = {
            lookupTable = lookupTable,
            callback = callback,
        }
    end

    handleCounter = handleCounter + 1
    local handle = handleCounter
    local knownIDs = BuildKnownIDs(config.lookupTable)
    spellMatchEntries[handle] = {
        knownIDs = knownIDs,
        lookupTable = config.lookupTable,
        callback = config.callback,
        candidateResolver = config.candidateResolver,
        label = config.label,
        entryToID = config.entryToID,
    }
    Log(format("OnPartySpellMatch registered: handle=%d spells=%d label=%s",
        handle, #knownIDs, tostring(config.label)))
    return handle
end

function PartySpellWatcher:Unregister(handle)
    interruptCallbacks[handle] = nil
    mobKickCallbacks[handle] = nil
    anySpellCallbacks[handle] = nil
    spellMatchEntries[handle] = nil
end

function PartySpellWatcher:GetRecentCastTime(name)
    return recentPartyCasts[name]
end
