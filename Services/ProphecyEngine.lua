--[[
    ProphecyEngine Service
    Core engine for the Prophecy system. Manages trigger evaluation,
    prophecy lifecycle, drift tracking, checkpoint/recovery, and run recording.
    Independent of any module -- the Prophecy module wires callbacks to this.
]]

local _, ns = ...
ns.Services = ns.Services or {}

local GetTime = GetTime
local _GetWorldElapsedTime = GetWorldElapsedTime
local _worldTimerAvailable = nil
local GetWorldElapsedTimeSafe = function(id)
    if _worldTimerAvailable == nil then
        local ok, _, elapsed = pcall(_GetWorldElapsedTime, id)
        _worldTimerAvailable = ok
        return ok and elapsed or 0
    end
    if _worldTimerAvailable then
        local _, elapsed = _GetWorldElapsedTime(id)
        return elapsed or 0
    end
    return 0
end
local pairs = pairs
local ipairs = ipairs
local tinsert = table.insert
local tremove = table.remove
local wipe = wipe
local format = format
local pcall = pcall
local type = type
local select = select
local math_floor = math.floor
local math_abs = math.abs
local math_min = math.min
local CreateFrame = CreateFrame

-- =====================================================================
-- Part 1: Trigger Type Registry
-- =====================================================================

local TriggerRegistry = {}

local registeredTypes = {}

function TriggerRegistry:Register(triggerDef)
    registeredTypes[triggerDef.key] = triggerDef
end

function TriggerRegistry:Get(key)
    return registeredTypes[key]
end

function TriggerRegistry:GetAll()
    return registeredTypes
end

-- Built-in trigger type definitions
-- Each has: key, label, description, params (schema for SchemaForm),
-- setup(prophecy, engine), evaluate(prophecy, engine), teardown(prophecy, engine)

TriggerRegistry:Register({
    key = "timer",
    label = "Timer",
    description = "Fires after a set number of seconds from key start or another prophecy's fulfillment.",
    params = {
        { name = "seconds", label = "Seconds", type = "number", min = 0, max = 3600, step = 1, default = 60 },
        { name = "relativeTo", label = "Relative To", type = "prophecyRef" },
    },
    setup = function() end,
    evaluate = function(trigger, prophecy, engine)
        local elapsed = engine:GetElapsed()
        if not elapsed then return false end
        local base = 0
        if trigger.relativeTo then
            local ref = engine:GetNode(trigger.relativeTo)
            if ref and ref.actualTime then
                base = ref.actualTime
            else
                return false
            end
        end
        return elapsed >= base + (trigger.seconds or 0)
    end,
    teardown = function() end,
})

TriggerRegistry:Register({
    key = "buff_gained",
    label = "Buff Gained",
    description = "Fires when the player gains a buff matching the pattern.",
    params = {
        { name = "pattern", label = "Buff Pattern", type = "string" },
    },
    setup = function() end,
    evaluate = function(trigger, prophecy, engine)
        if not trigger.pattern then return false end
        local ok, found = pcall(function()
            for i = 1, 40 do
                local name = UnitBuff("player", i)
                if not name then break end
                if name:find(trigger.pattern) then return true end
            end
            return false
        end)
        return ok and found or false
    end,
    teardown = function() end,
})

TriggerRegistry:Register({
    key = "buff_lost",
    label = "Buff Lost",
    description = "Fires when a previously detected buff is no longer present.",
    params = {
        { name = "pattern", label = "Buff Pattern", type = "string" },
    },
    setup = function(trigger, prophecy)
        prophecy._buffWasPresent = false
    end,
    evaluate = function(trigger, prophecy, engine)
        if not trigger.pattern then return false end
        local ok, present = pcall(function()
            for i = 1, 40 do
                local name = UnitBuff("player", i)
                if not name then break end
                if name:find(trigger.pattern) then return true end
            end
            return false
        end)
        present = ok and present or false
        if present then
            prophecy._buffWasPresent = true
            return false
        end
        return prophecy._buffWasPresent == true
    end,
    teardown = function() end,
})

TriggerRegistry:Register({
    key = "cleu_spell",
    label = "Spell Cast",
    description = "Fires when a specific spell is cast (via CLEU).",
    params = {
        { name = "spellIds", label = "Spell IDs", type = "spellIds" },
        { name = "subevent", label = "Sub-event", type = "select", options = {
            { value = "SPELL_CAST_SUCCESS", label = "Cast Success" },
            { value = "SPELL_AURA_APPLIED", label = "Aura Applied" },
            { value = "SPELL_DAMAGE", label = "Spell Damage" },
        }, default = "SPELL_CAST_SUCCESS" },
    },
    setup = function() end,
    evaluate = function() return false end,  -- driven by CLEU event, not polling
    teardown = function() end,
})

TriggerRegistry:Register({
    key = "encounter_start",
    label = "Boss Engaged",
    description = "Fires on ENCOUNTER_START, optionally filtered by ID.",
    params = {
        { name = "encounterId", label = "Encounter ID", type = "number", min = 0, max = 99999 },
        { name = "encounterName", label = "Encounter Name", type = "string" },
    },
    setup = function() end,
    evaluate = function() return false end,  -- driven by event
    teardown = function() end,
})

TriggerRegistry:Register({
    key = "encounter_end",
    label = "Boss Killed",
    description = "Fires on ENCOUNTER_END with success=1.",
    params = {
        { name = "encounterId", label = "Encounter ID", type = "number", min = 0, max = 99999 },
        { name = "encounterName", label = "Encounter Name", type = "string" },
    },
    setup = function() end,
    evaluate = function() return false end,
    teardown = function() end,
})

TriggerRegistry:Register({
    key = "combat_start",
    label = "Combat Start",
    description = "Fires on PLAYER_REGEN_DISABLED.",
    params = {},
    setup = function() end,
    evaluate = function() return false end,
    teardown = function() end,
})

TriggerRegistry:Register({
    key = "combat_end",
    label = "Combat End",
    description = "Fires on PLAYER_REGEN_ENABLED.",
    params = {},
    setup = function() end,
    evaluate = function() return false end,
    teardown = function() end,
})

TriggerRegistry:Register({
    key = "unit_died",
    label = "Unit Died",
    description = "Fires on CLEU UNIT_DIED with optional name match.",
    params = {
        { name = "namePattern", label = "Name Pattern", type = "string" },
    },
    setup = function() end,
    evaluate = function() return false end,
    teardown = function() end,
})

TriggerRegistry:Register({
    key = "zone_changed",
    label = "Zone Changed",
    description = "Fires on ZONE_CHANGED_NEW_AREA.",
    params = {
        { name = "subZone", label = "Sub Zone", type = "string" },
    },
    setup = function() end,
    evaluate = function() return false end,
    teardown = function() end,
})

TriggerRegistry:Register({
    key = "challenge_start",
    label = "Key Started",
    description = "Fires on CHALLENGE_MODE_START.",
    params = {},
    setup = function() end,
    evaluate = function() return false end,
    teardown = function() end,
})

TriggerRegistry:Register({
    key = "manual",
    label = "Manual",
    description = "Fires when the user right-clicks the prophecy.",
    params = {},
    setup = function() end,
    evaluate = function() return false end,
    teardown = function() end,
})

TriggerRegistry:Register({
    key = "chain",
    label = "Chained",
    description = "Fires when the referenced prophecy is fulfilled.",
    params = {
        { name = "afterProphecy", label = "After Prophecy", type = "prophecyRef" },
    },
    setup = function() end,
    evaluate = function() return false end,
    teardown = function() end,
})

-- =====================================================================
-- Part 2: Prophecy Engine Core
-- =====================================================================

local ProphecyEngine = {}
ns.Services.ProphecyEngine = ProphecyEngine

ProphecyEngine.TriggerRegistry = TriggerRegistry

local STATES = {
    DORMANT   = "dormant",
    ACTIVE    = "active",
    PENDING   = "pending",
    FULFILLED = "fulfilled",
    DISMISSED = "dismissed",
    COLLAPSED = "collapsed",
}
ProphecyEngine.STATES = STATES

local LUST_SPELL_IDS = { [80353] = true, [32182] = true, [2825] = true, [390386] = true, [264667] = true }

local function IsEvaluatable(state)
    return state == STATES.ACTIVE or state == STATES.PENDING
end

local nodes = {}           -- [id] = prophecy node
local nodeOrder = {}       -- ordered array of node ids
local callbacks = {}       -- { onStateChange, onDriftUpdate, onWipeStateChange, onRefresh }
local engineActive = false
local eventFrame
local TRACKED_EVENTS = {
    "ENCOUNTER_START",
    "ENCOUNTER_END",
    "CHALLENGE_MODE_START",
    "CHALLENGE_MODE_COMPLETED",
    "PLAYER_ENTERING_WORLD",
}

-- CLEU performance index: [spellId] = { {node, triggerIndex, subevent}, ... }
local cleuSpellIndex = {}

-- Cached node lists (rebuilt on state change, avoids GC pressure from 1Hz overlay refresh)
local cachedActiveNodes = {}
local cachedFulfilledNodes = {}
local nodeCacheDirty = true

-- =====================================================================
-- Part 2b: DriftTracker
-- =====================================================================

local DriftTracker = {
    currentDrift       = 0,
    lastAnchorId       = nil,
    lastAnchorActual   = 0,
    lastAnchorExpected = 0,
    wipeCount          = 0,
    wipeActive         = false,
    wipeStartTime      = nil,
    totalWipeTime      = 0,
    segments           = {},
}
ProphecyEngine.DriftTracker = DriftTracker

function DriftTracker:Reset()
    self.currentDrift = 0
    self.lastAnchorId = nil
    self.lastAnchorActual = 0
    self.lastAnchorExpected = 0
    self.wipeCount = 0
    self.wipeActive = false
    self.wipeStartTime = nil
    self.totalWipeTime = 0
    wipe(self.segments)
end

function DriftTracker:OnAnchorFulfilled(node, actualTime)
    if not node.isAnchor or not node.expectedTime then return end

    local newDrift = actualTime - node.expectedTime

    tinsert(self.segments, {
        fromAnchor       = self.lastAnchorId,
        toAnchor         = node.id,
        expectedDuration = node.expectedTime - self.lastAnchorExpected,
        actualDuration   = actualTime - self.lastAnchorActual,
        drift            = newDrift,
    })

    self.currentDrift = newDrift
    self.lastAnchorId = node.id
    self.lastAnchorActual = actualTime
    self.lastAnchorExpected = node.expectedTime

    -- Propagate to all unfulfilled nodes with expectedTime
    for _, nid in ipairs(nodeOrder) do
        local n = nodes[nid]
        if n and n.state ~= STATES.FULFILLED and n.state ~= STATES.COLLAPSED
            and n.state ~= STATES.DISMISSED and n.expectedTime then
            n.adjustedTime = n.expectedTime + newDrift
        end
    end

    if self.wipeActive then
        self.wipeActive = false
    end

    ProphecyEngine:_FireCallback("onDriftUpdate", newDrift)
end

function DriftTracker:OnWipeDetected()
    self.wipeCount = self.wipeCount + 1
    self.wipeActive = true
    self.wipeStartTime = ProphecyEngine:GetElapsed()
    ProphecyEngine:_FireCallback("onWipeStateChange", true)
end

function DriftTracker:OnWipeRecovery()
    if not self.wipeActive then return end
    local elapsed = ProphecyEngine:GetElapsed()
    local wipeDuration = 0
    if self.wipeStartTime then
        wipeDuration = elapsed - self.wipeStartTime
        self.totalWipeTime = self.totalWipeTime + wipeDuration
    end
    self.wipeActive = false
    self.wipeStartTime = nil
    RunRecorder:RecordEvent("wipe_end", { wipeDuration = wipeDuration })
    ProphecyEngine:_FireCallback("onWipeStateChange", false)
end

function DriftTracker:GetState()
    return {
        currentDrift       = self.currentDrift,
        lastAnchorId       = self.lastAnchorId,
        lastAnchorActual   = self.lastAnchorActual,
        lastAnchorExpected = self.lastAnchorExpected,
        wipeCount          = self.wipeCount,
        totalWipeTime      = self.totalWipeTime,
        wipeActive         = self.wipeActive,
    }
end

function DriftTracker:RestoreState(state)
    if not state then return end
    self.currentDrift = state.currentDrift or 0
    self.lastAnchorId = state.lastAnchorId
    self.lastAnchorActual = state.lastAnchorActual or 0
    self.lastAnchorExpected = state.lastAnchorExpected or 0
    self.wipeCount = state.wipeCount or 0
    self.totalWipeTime = state.totalWipeTime or 0
    self.wipeActive = state.wipeActive or false
end

-- =====================================================================
-- Part 2c: Checkpoint/Recovery System
-- =====================================================================

local Checkpoint = {}
ProphecyEngine.Checkpoint = Checkpoint

local CHECKPOINT_INTERVAL = 60

function Checkpoint:Write()
    if not engineActive then return end
    local db = MedaAurasCharDB and MedaAurasCharDB.prophecy
    if not db then return end

    local nodeStates = {}
    for id, node in pairs(nodes) do
        if node.state ~= node._defaultState then
            nodeStates[id] = { state = node.state, actualTime = node.actualTime }
        end
    end

    local _, _, _, _, _, _, _, instanceID = GetInstanceInfo()

    db._checkpoint = {
        version        = 1,
        instanceID     = instanceID,
        keystoneLevel  = ProphecyEngine._keystoneLevel or 0,
        templateSource = ProphecyEngine._templateSource or "curated",
        nodeStates     = nodeStates,
        drift          = DriftTracker:GetState(),
        recorderEvents = RunRecorder:GetEvents(),
    }
end

function Checkpoint:Clear()
    if MedaAurasCharDB and MedaAurasCharDB.prophecy then
        MedaAurasCharDB.prophecy._checkpoint = nil
    end
end

function Checkpoint:Load()
    if not MedaAurasCharDB or not MedaAurasCharDB.prophecy then return nil end
    return MedaAurasCharDB.prophecy._checkpoint
end

function Checkpoint:Recover()
    local cp = self:Load()
    if not cp then return false end

    local _, instanceType, difficultyID, _, _, _, _, instanceID = GetInstanceInfo()
    if difficultyID ~= 8 or instanceType ~= "party" then
        self:Clear()
        return false
    end

    if cp.instanceID ~= instanceID then
        self:Clear()
        return false
    end

    local elapsed = GetWorldElapsedTimeSafe(1)
    if elapsed <= 0 then
        self:Clear()
        return false
    end

    -- Reload the template first (nodes table is empty after a reload)
    if not next(nodes) then
        local template = ProphecyEngine:_ResolveTemplate(instanceID)
        if template then
            ProphecyEngine:LoadTemplate(template)
        end
    end

    -- Restore node states on top of the freshly loaded template
    if cp.nodeStates then
        for id, saved in pairs(cp.nodeStates) do
            local node = nodes[id]
            if node then
                node.state = saved.state
                node.actualTime = saved.actualTime
            end
        end
    end

    -- Re-arm any restored active/pending nodes so setup-dependent triggers
    -- keep working after a /reload or reconnect recovery.
    for _, nid in ipairs(nodeOrder) do
        local node = nodes[nid]
        if node and IsEvaluatable(node.state) then
            ProphecyEngine:_CallTriggerSetup(node)
        end
    end

    -- Restore drift
    DriftTracker:RestoreState(cp.drift)

    -- Restore recorder events
    if cp.recorderEvents then
        RunRecorder:RestoreEvents(cp.recorderEvents)
        local lastT = (cp.recorderEvents[#cp.recorderEvents] or {}).t or 0
        RunRecorder:RecordEvent("session_resume", { gap = elapsed - lastT })
    end

    ProphecyEngine._keystoneLevel = cp.keystoneLevel
    ProphecyEngine._templateSource = cp.templateSource

    -- Evaluate missed timers
    for _, nid in ipairs(nodeOrder) do
        local node = nodes[nid]
        if node and IsEvaluatable(node.state) and node.expectedTime and node.expectedTime < elapsed then
            node._missed = true
        end
    end

    return true
end

-- =====================================================================
-- Part 3: RunRecorder
-- =====================================================================

local RunRecorder = {}
ProphecyEngine.RunRecorder = RunRecorder

local recordedEvents = {}
local recordingActive = false

function RunRecorder:Start(keystoneLevel, instanceID)
    wipe(recordedEvents)
    recordingActive = true
end

function RunRecorder:Stop()
    recordingActive = false
end

function RunRecorder:IsRecording()
    return recordingActive
end

function RunRecorder:RecordEvent(eventType, data)
    if not recordingActive then return end
    local elapsed = ProphecyEngine:GetElapsed()
    local entry = { t = elapsed, type = eventType }
    if data then
        for k, v in pairs(data) do
            entry[k] = v
        end
    end
    tinsert(recordedEvents, entry)
end

function RunRecorder:GetEvents()
    local copy = {}
    for i, e in ipairs(recordedEvents) do copy[i] = e end
    return copy
end

function RunRecorder:RestoreEvents(events)
    wipe(recordedEvents)
    for i, e in ipairs(events) do recordedEvents[i] = e end
    recordingActive = true
end

function RunRecorder:Finalize(completed, duration)
    recordingActive = false
    local db = MedaAurasCharDB and MedaAurasCharDB.prophecy
    if not db then return end

    local _, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    if not instanceID then return end

    db.recordings = db.recordings or {}
    db.recordings[instanceID] = db.recordings[instanceID] or { runs = {}, personalTemplate = nil }

    local segmentsCopy = {}
    for i, seg in ipairs(DriftTracker.segments) do
        segmentsCopy[i] = {
            fromAnchor = seg.fromAnchor, toAnchor = seg.toAnchor,
            expectedDuration = seg.expectedDuration, actualDuration = seg.actualDuration,
            drift = seg.drift,
        }
    end

    local run = {
        timestamp    = time(),
        keyLevel     = ProphecyEngine._keystoneLevel or 0,
        duration     = duration or 0,
        completed    = completed or false,
        events       = self:GetEvents(),
        driftSummary = {
            totalDrift    = DriftTracker.currentDrift,
            wipeCount     = DriftTracker.wipeCount,
            totalWipeTime = DriftTracker.totalWipeTime,
            segments      = segmentsCopy,
        },
    }

    local runs = db.recordings[instanceID].runs
    tinsert(runs, run)

    -- Cap stored runs
    local maxRuns = 20
    local acctDB = MedaAurasDB and MedaAurasDB.modules and MedaAurasDB.modules.Prophecy
    if acctDB then maxRuns = acctDB.maxRecordedRuns or 20 end
    while #runs > maxRuns do tremove(runs, 1) end

    -- Auto-generate personal template after N completed runs
    local autoAfter = acctDB and acctDB.autoGenerateAfter or 3
    local completedRuns = 0
    for _, r in ipairs(runs) do
        if r.completed then completedRuns = completedRuns + 1 end
    end
    if completedRuns >= autoAfter and not db.recordings[instanceID].personalTemplate then
        db.recordings[instanceID].personalTemplate = self:_AggregatePersonalTemplate(runs, instanceID, acctDB)
    end
end

function RunRecorder:_AggregatePersonalTemplate(runs, instanceID, acctDB)
    local excludeWipes = acctDB and acctDB.excludeWipesFromAvg ~= false
    local CLUSTER_WINDOW = 90

    -- Collect all event timestamps grouped by event type+id
    local buckets = {}  -- [key] = { timestamps }
    local durations = {}
    for _, run in ipairs(runs) do
        if run.completed then
            tinsert(durations, run.duration)
            for _, ev in ipairs(run.events or {}) do
                local isSessionMarker = (ev.type == "key_start" or ev.type == "session_resume")
                local isExcludedWipe = excludeWipes and (ev.type == "wipe_start" or ev.type == "wipe_end")
                if not isSessionMarker and not isExcludedWipe then
                    local key = ev.type
                    if ev.encounterId then key = key .. "_" .. ev.encounterId end
                    if ev.spellId then key = key .. "_" .. ev.spellId end
                    buckets[key] = buckets[key] or { type = ev.type, encounterId = ev.encounterId, spellId = ev.spellId, timestamps = {} }
                    tinsert(buckets[key].timestamps, ev.t)
                end
            end
        end
    end

    local avgDuration = #durations > 0 and (function()
        local sum = 0
        for _, d in ipairs(durations) do sum = sum + d end
        return math_floor(sum / #durations)
    end)() or 0

    -- Cluster timestamps for each bucket and build template nodes
    local templateNodes = {}
    local idx = 0

    -- Key start anchor
    tinsert(templateNodes, {
        id = "key_start", text = "Key Started", type = "BOSS",
        isAnchor = true, expectedTime = 0,
        triggers = { { type = "challenge_start" } },
        actions = { { type = "fulfill" }, { type = "record", eventType = "key_start" } },
    })

    for key, bucket in pairs(buckets) do
        local sorted = bucket.timestamps
        table.sort(sorted)
        if #sorted > 0 then
            -- Simple clustering: take median of all timestamps
            local median = sorted[math_floor(#sorted / 2) + 1]
            idx = idx + 1

            local nodeType = "AWARENESS"
            local text = bucket.type
            local triggers = { { type = "manual" } }

            if bucket.type == "encounter_start" then
                nodeType = "BOSS"
                text = "Boss Engage"
                triggers = { { type = "encounter_start", encounterId = bucket.encounterId } }
            elseif bucket.type == "encounter_end" then
                nodeType = "BOSS"
                text = "Boss Kill"
                triggers = { { type = "encounter_end", encounterId = bucket.encounterId } }
            elseif bucket.type == "lust" then
                nodeType = "LUST"
                text = "Bloodlust"
                triggers = {
                    mode = "any",
                    { type = "cleu_spell", spellIds = { 80353, 32182, 2825, 390386, 264667 } },
                    { type = "manual" },
                }
            end

            local isAnchor = (nodeType == "BOSS" or nodeType == "LUST")

            tinsert(templateNodes, {
                id = "personal_" .. idx,
                text = text,
                type = nodeType,
                isAnchor = isAnchor,
                anchorWeight = isAnchor and 1.0 or nil,
                expectedTime = median,
                triggers = triggers,
                actions = { { type = "fulfill" } },
            })
        end
    end

    -- Sort by expectedTime
    table.sort(templateNodes, function(a, b)
        return (a.expectedTime or 9999) < (b.expectedTime or 9999)
    end)

    return { instanceID = instanceID, name = "Personal", nodes = templateNodes }
end

-- =====================================================================
-- Engine Core Methods
-- =====================================================================

local function IsProphecyEnabled()
    local acctDB = MedaAurasDB and MedaAurasDB.modules and MedaAurasDB.modules.Prophecy
    return acctDB and acctDB.enabled
end

function ProphecyEngine:Initialize()
    if eventFrame then return true end
    if not IsProphecyEnabled() then return false end

    eventFrame = CreateFrame("Frame")

    local function TraceInfo(msg)
        if MedaAuras and MedaAuras.Log then
            MedaAuras.Log(msg)
        elseif print then
            print(msg)
        end
    end

    local function TraceError(msg)
        if MedaAuras and MedaAuras.LogError then
            MedaAuras.LogError(msg)
        else
            TraceInfo(msg)
        end
    end

    local function RegisterTrackedEvent(eventName)
        TraceInfo(format("[ProphecyEngine] About to register event '%s'", eventName))
        local ok, err = pcall(eventFrame.RegisterEvent, eventFrame, eventName)
        if ok then
            TraceInfo(format("[ProphecyEngine] Registered event '%s'", eventName))
        else
            TraceError(format("[ProphecyEngine] Failed to register event '%s': %s", eventName, tostring(err)))
        end
        return ok
    end

    for _, eventName in ipairs(TRACKED_EVENTS) do
        RegisterTrackedEvent(eventName)
    end

    eventFrame:SetScript("OnEvent", function(_, event, ...)
        ProphecyEngine:OnEvent(event, ...)
    end)

    -- Periodic checkpoint + poll timer
    local pollElapsed = 0
    local checkpointElapsed = 0
    local POLL_INTERVAL = 2
    local POLL_INTERVAL_COMBAT = 5

    eventFrame:SetScript("OnUpdate", function(_, dt)
        if not engineActive then return end

        pollElapsed = pollElapsed + dt
        checkpointElapsed = checkpointElapsed + dt

        local interval = InCombatLockdown() and POLL_INTERVAL_COMBAT or POLL_INTERVAL
        if pollElapsed >= interval then
            pollElapsed = 0
            ProphecyEngine:PollTriggers()
        end

        if checkpointElapsed >= CHECKPOINT_INTERVAL then
            checkpointElapsed = 0
            Checkpoint:Write()
        end
    end)
end

function ProphecyEngine:OnEvent(event, ...)
    -- Only process game events if the module is enabled (PLAYER_ENTERING_WORLD and logout always run for recovery)
    local isRecoveryEvent = (event == "PLAYER_ENTERING_WORLD")
    if not isRecoveryEvent then
        local acctDB = MedaAurasDB and MedaAurasDB.modules and MedaAurasDB.modules.Prophecy
        if not acctDB or not acctDB.enabled then return end
    end

    if event == "ENCOUNTER_START" then
        local encounterID, encounterName = ...
        self:OnEncounterStart(encounterID, encounterName)
    elseif event == "ENCOUNTER_END" then
        local encounterID, encounterName, _, _, success = ...
        self:OnEncounterEnd(encounterID, encounterName, success == 1)
    elseif event == "CHALLENGE_MODE_START" then
        self:OnKeyStart()
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        self:OnKeyComplete()
    elseif event == "PLAYER_ENTERING_WORLD" then
        self:OnPlayerEnteringWorld()
    end
end

function ProphecyEngine:OnCLEU()
    if not engineActive then return end
    local _, subevent, _, _, _, _, _, _, destName, _, _, spellId = CombatLogGetCurrentEventInfo()

    if subevent == "UNIT_DIED" then
        self:OnEventTrigger("unit_died", { namePattern = destName })
        return
    end

    -- O(1) spell ID lookup instead of iterating all nodes
    local entries = cleuSpellIndex[spellId]
    if entries then
        for _, entry in ipairs(entries) do
            if entry.subevent == subevent and IsEvaluatable(entry.node.state) then
                self:_MarkTriggerFired(entry.node, entry.triggerIndex)
            end
        end
    end

    -- Lust detection for recorder
    if subevent == "SPELL_CAST_SUCCESS" and LUST_SPELL_IDS[spellId] then
        RunRecorder:RecordEvent("lust", { spellId = spellId })
    end

    -- Interrupt success detection for recorder
    if subevent == "SPELL_INTERRUPT" then
        RunRecorder:RecordEvent("interrupt_success", { spellId = spellId, target = destName })
    end
end

function ProphecyEngine:OnEncounterStart(encounterID, encounterName)
    if not engineActive then return end
    RunRecorder:RecordEvent("encounter_start", { encounterId = encounterID })

    for _, nid in ipairs(nodeOrder) do
        local node = nodes[nid]
        if node and IsEvaluatable(node.state) and node.triggers then
            for ti, trigger in ipairs(node.triggers) do
                if trigger.type == "encounter_start" then
                    local match = true
                    if trigger.encounterId and trigger.encounterId ~= encounterID then match = false end
                    if trigger.encounterName and not encounterName:find(trigger.encounterName) then match = false end
                    if match then self:_MarkTriggerFired(node, ti) end
                end
            end
        end
    end
end

function ProphecyEngine:OnEncounterEnd(encounterID, encounterName, success)
    if not engineActive then return end

    if success then
        RunRecorder:RecordEvent("encounter_end", { encounterId = encounterID, success = true })
        for _, nid in ipairs(nodeOrder) do
            local node = nodes[nid]
            if node and IsEvaluatable(node.state) and node.triggers then
                for ti, trigger in ipairs(node.triggers) do
                    if trigger.type == "encounter_end" then
                        local match = true
                        if trigger.encounterId and trigger.encounterId ~= encounterID then match = false end
                        if trigger.encounterName and not encounterName:find(trigger.encounterName) then match = false end
                        if match then self:_MarkTriggerFired(node, ti) end
                    end
                end
            end
        end
    else
        RunRecorder:RecordEvent("encounter_end", { encounterId = encounterID, success = false })
        RunRecorder:RecordEvent("wipe_start")
        DriftTracker:OnWipeDetected()
    end
end

function ProphecyEngine:OnEventTrigger(triggerKey, data)
    if not engineActive then return end
    data = data or {}

    for _, nid in ipairs(nodeOrder) do
        local node = nodes[nid]
        if node and IsEvaluatable(node.state) and node.triggers then
            for ti, trigger in ipairs(node.triggers) do
                if trigger.type == triggerKey then
                    local match = true
                    if triggerKey == "zone_changed" and trigger.subZone then
                        if not (data.subZone or ""):find(trigger.subZone) then match = false end
                    end
                    if triggerKey == "unit_died" and trigger.namePattern then
                        if not (data.namePattern or ""):find(trigger.namePattern) then match = false end
                    end
                    if match then self:_MarkTriggerFired(node, ti) end
                end
            end
        end
    end
end

function ProphecyEngine:OnKeyStart()
    local _, _, _, difficultyID, _, _, _, instanceID = GetInstanceInfo()
    local level = C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo and C_ChallengeMode.GetActiveKeystoneInfo() or 0
    self._keystoneLevel = level

    -- Load template based on user's templateSource preference
    if not next(nodes) then
        local template = self:_ResolveTemplate(instanceID)
        if template then
            self:LoadTemplate(template)
        end
    end

    RunRecorder:Start(level, instanceID)
    Checkpoint:Clear()

    -- Fire the challenge_start trigger so key_start nodes fulfill
    self:OnEventTrigger("challenge_start")

    self:_FireCallback("onRefresh")
end

function ProphecyEngine:_ResolveTemplate(instanceID)
    local acctDB = MedaAurasDB and MedaAurasDB.modules and MedaAurasDB.modules.Prophecy
    local source = "curated"
    if acctDB and acctDB.templateSource and acctDB.templateSource[instanceID] then
        source = acctDB.templateSource[instanceID]
    end
    self._templateSource = source

    if source == "personal" then
        local charDB = MedaAurasCharDB and MedaAurasCharDB.prophecy
        if charDB and charDB.recordings and charDB.recordings[instanceID] then
            local pt = charDB.recordings[instanceID].personalTemplate
            if pt then return pt end
        end
    elseif source == "custom" then
        if acctDB and acctDB.customTemplates and acctDB.customTemplates[instanceID] then
            return acctDB.customTemplates[instanceID]
        end
    end

    -- Fallback to curated
    local Templates = ns.ProphecyTemplates
    if Templates then
        return Templates:Generate(instanceID)
    end
    return nil
end

function ProphecyEngine:OnKeyComplete()
    if not engineActive then return end
    local elapsed = self:GetElapsed()
    RunRecorder:RecordEvent("key_complete")
    RunRecorder:Finalize(true, elapsed)
    Checkpoint:Clear()
    engineActive = false
    self:_FireCallback("onRefresh")
end

function ProphecyEngine:OnPlayerEnteringWorld()
    local _, instanceType, difficultyID, _, _, _, _, instanceID = GetInstanceInfo()
    if difficultyID == 8 and instanceType == "party" and GetWorldElapsedTimeSafe(1) > 0 then
        if Checkpoint:Recover() then
            engineActive = true
            self:_FireCallback("onRefresh")
        end
    else
        Checkpoint:Clear()
    end
end

-- =====================================================================
-- Lifecycle: Generate, Activate, Fulfill, Chain
-- =====================================================================

function ProphecyEngine:LoadTemplate(template)
    wipe(nodes)
    wipe(nodeOrder)
    wipe(cleuSpellIndex)
    DriftTracker:Reset()

    if not template or not template.nodes then return end

    for _, def in ipairs(template.nodes) do
        local node = {
            id            = def.id,
            text          = def.text or "",
            type          = def.type or "AWARENESS",
            triggers      = def.triggers or {},
            actions       = def.actions or {},
            expectedTime  = def.expectedTime,
            adjustedTime  = def.expectedTime,
            actualTime    = nil,
            isAnchor      = def.isAnchor or false,
            anchorWeight  = def.anchorWeight or 1.0,
            state         = STATES.DORMANT,
            _defaultState = STATES.DORMANT,
            _missed       = false,
            icon          = def.icon,
        }

        local hasDependency = false
        if node.triggers then
            for ti, t in ipairs(node.triggers) do
                if t.type == "chain" then
                    hasDependency = true
                elseif t.type == "cleu_spell" and t.spellIds then
                    local subevent = t.subevent or "SPELL_CAST_SUCCESS"
                    for _, sid in ipairs(t.spellIds) do
                        cleuSpellIndex[sid] = cleuSpellIndex[sid] or {}
                        tinsert(cleuSpellIndex[sid], { node = node, triggerIndex = ti, subevent = subevent })
                    end
                end
            end
        end

        if not hasDependency then
            node.state = STATES.ACTIVE
            node._defaultState = STATES.ACTIVE
        end

        nodes[node.id] = node
        tinsert(nodeOrder, node.id)
    end

    -- Call setup on all initially-active nodes
    for _, nid in ipairs(nodeOrder) do
        local n = nodes[nid]
        if n and n.state == STATES.ACTIVE then
            self:_CallTriggerSetup(n)
        end
    end

    engineActive = true
    self:_FireCallback("onRefresh")
end

function ProphecyEngine:_CallTriggerSetup(node)
    if not node or not node.triggers then return end
    for _, trigger in ipairs(node.triggers) do
        if type(trigger) == "table" and trigger.type then
            local def = TriggerRegistry:Get(trigger.type)
            if def and def.setup then
                pcall(def.setup, trigger, node)
            end
        end
    end
end

function ProphecyEngine:_CallTriggerTeardown(node)
    if not node or not node.triggers then return end
    for _, trigger in ipairs(node.triggers) do
        if type(trigger) == "table" and trigger.type then
            local def = TriggerRegistry:Get(trigger.type)
            if def and def.teardown then
                pcall(def.teardown, trigger, node)
            end
        end
    end
end

function ProphecyEngine:FulfillNode(node)
    if not node or not IsEvaluatable(node.state) then return end
    local elapsed = self:GetElapsed()

    node.state = STATES.FULFILLED
    node.actualTime = elapsed
    self:_CallTriggerTeardown(node)

    -- Anchor handling
    if node.isAnchor then
        DriftTracker:OnAnchorFulfilled(node, elapsed)
    end

    -- Execute actions
    if node.actions then
        for _, action in ipairs(node.actions) do
            if action.type == "activate" and action.target then
                local target = nodes[action.target]
                if target and target.state == STATES.DORMANT then
                    target.state = STATES.ACTIVE
                    self:_CallTriggerSetup(target)
                    self:_FireCallback("onStateChange", target)
                end
            elseif action.type == "start_timer" and action.target then
                local target = nodes[action.target]
                if target and target.state == STATES.ACTIVE and action.duration then
                    target.adjustedTime = elapsed + action.duration
                    target.expectedTime = target.expectedTime or target.adjustedTime
                end
            elseif action.type == "record" and action.eventType then
                RunRecorder:RecordEvent(action.eventType, { prophecyId = node.id })
            end
        end
    end

    -- Fire chain triggers on other nodes
    for _, nid in ipairs(nodeOrder) do
        local n = nodes[nid]
        if n and n.state == STATES.DORMANT and n.triggers then
            for _, t in ipairs(n.triggers) do
                if t.type == "chain" and t.afterProphecy == node.id then
                    n.state = STATES.ACTIVE
                    self:_CallTriggerSetup(n)
                    self:_FireCallback("onStateChange", n)
                    break
                end
            end
        end
    end

    Checkpoint:Write()
    self:_FireCallback("onStateChange", node)
end

function ProphecyEngine:DismissNode(node)
    if not node or not IsEvaluatable(node.state) then return end
    node.state = STATES.DISMISSED
    self:_CallTriggerTeardown(node)
    Checkpoint:Write()
    self:_FireCallback("onStateChange", node)
end

function ProphecyEngine:ManualFulfill(nodeId)
    local node = nodes[nodeId]
    if node then self:FulfillNode(node) end
end

function ProphecyEngine:ManualDismiss(nodeId)
    local node = nodes[nodeId]
    if node then self:DismissNode(node) end
end

-- =====================================================================
-- Composite trigger evaluation helper
-- =====================================================================

--- Mark a specific trigger index as fired on a node, then check if the
--- node should be fulfilled based on its composite mode (any/all).
function ProphecyEngine:_MarkTriggerFired(node, triggerIndex)
    if not node or not IsEvaluatable(node.state) then return end

    node._firedTriggers = node._firedTriggers or {}
    node._firedTriggers[triggerIndex] = true

    local mode = node.triggers.mode or "any"

    if mode == "any" then
        self:FulfillNode(node)
        return
    end

    -- mode == "all": check if every trigger (that is a table with .type) has fired
    local allFired = true
    for i, trigger in ipairs(node.triggers) do
        if type(trigger) == "table" and trigger.type then
            if not node._firedTriggers[i] then
                allFired = false
                break
            end
        end
    end
    if allFired then
        self:FulfillNode(node)
    end
end

-- =====================================================================
-- Poll-based trigger evaluation
-- =====================================================================

function ProphecyEngine:PollTriggers()
    for _, nid in ipairs(nodeOrder) do
        local node = nodes[nid]
        if node and IsEvaluatable(node.state) and node.triggers then
            for ti, trigger in ipairs(node.triggers) do
                if type(trigger) == "table" and trigger.type then
                    local def = TriggerRegistry:Get(trigger.type)
                    if def and def.evaluate then
                        local ok, result = pcall(def.evaluate, trigger, node, self)
                        if ok and result then
                            self:_MarkTriggerFired(node, ti)
                            if node.state ~= STATES.ACTIVE then break end
                        end
                    end
                end
            end
        end
    end
end

-- =====================================================================
-- Accessor/utility methods
-- =====================================================================

function ProphecyEngine:GetElapsed()
    return GetWorldElapsedTimeSafe(1)
end

function ProphecyEngine:GetNode(id)
    return nodes[id]
end

function ProphecyEngine:GetNodes()
    return nodes
end

function ProphecyEngine:GetNodeOrder()
    return nodeOrder
end

local function RebuildNodeCaches()
    wipe(cachedActiveNodes)
    wipe(cachedFulfilledNodes)
    for _, nid in ipairs(nodeOrder) do
        local n = nodes[nid]
        if n then
            if IsEvaluatable(n.state) then
                cachedActiveNodes[#cachedActiveNodes + 1] = n
            elseif n.state == STATES.FULFILLED or n.state == STATES.COLLAPSED then
                cachedFulfilledNodes[#cachedFulfilledNodes + 1] = n
            end
        end
    end
    nodeCacheDirty = false
end

function ProphecyEngine:GetActiveNodes()
    if nodeCacheDirty then RebuildNodeCaches() end
    return cachedActiveNodes
end

function ProphecyEngine:GetFulfilledNodes()
    if nodeCacheDirty then RebuildNodeCaches() end
    return cachedFulfilledNodes
end

function ProphecyEngine:IsActive()
    return engineActive
end

function ProphecyEngine:SetActive(active)
    engineActive = active
end

function ProphecyEngine:SetTemplateSource(source)
    self._templateSource = source
end

function ProphecyEngine:RegisterCallback(name, fn)
    callbacks[name] = fn
end

function ProphecyEngine:_FireCallback(name, ...)
    if name == "onStateChange" or name == "onRefresh" then
        nodeCacheDirty = true
    end
    if callbacks[name] then
        local ok, err = pcall(callbacks[name], ...)
        if not ok then
            local SafeStr = ns.SafeStr or tostring
            MedaAuras.LogDebug(format("[ProphecyEngine] Callback error (%s): %s", tostring(name), SafeStr(err)))
        end
    end
end

function ProphecyEngine:Shutdown()
    engineActive = false
    if eventFrame then
        eventFrame:UnregisterAllEvents()
        eventFrame:SetScript("OnEvent", nil)
        eventFrame:SetScript("OnUpdate", nil)
        eventFrame = nil
    end
    RunRecorder:Stop()
    Checkpoint:Clear()
    wipe(nodes)
    wipe(nodeOrder)
    wipe(cleuSpellIndex)
    wipe(cachedActiveNodes)
    wipe(cachedFulfilledNodes)
    nodeCacheDirty = true
    DriftTracker:Reset()
end
