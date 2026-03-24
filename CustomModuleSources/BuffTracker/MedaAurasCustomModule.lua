local MedaUI = LibStub("MedaUI-2.0")

local C_CooldownViewer = _G and _G.C_CooldownViewer or nil
local C_DelvesUI = _G and _G.C_DelvesUI or nil
local C_PartyInfo = _G and _G.C_PartyInfo or nil
local C_Timer = C_Timer
local C_Spell = C_Spell
local C_UnitAuras = C_UnitAuras
local AuraUtil = AuraUtil
local CreateFrame = CreateFrame
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local STANDARD_TEXT_FONT = STANDARD_TEXT_FONT
local UIParent = UIParent
local UnitExists = UnitExists
local UnitBuff = UnitBuff
local UnitInPartyIsAI = _G and _G.UnitInPartyIsAI or nil
local UnitName = UnitName
local format = format
local ipairs = ipairs
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local pairs = pairs
local strfind = string.find
local tonumber = tonumber
local tostring = tostring
local unpack = unpack or table.unpack
local wipe = wipe
local GetAuraDataByAuraInstanceID = C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID or nil
local GetAuraDataByIndex = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex or nil
local GetAuraDataBySpellName = C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName or nil
local GetPlayerAuraBySpellID = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID or nil

local MODULE_ID = "padding"
local MODULE_NAME = "Padding"
local MODULE_VERSION = "0.25"
local MODULE_AUTHOR = "Medalink"
local MODULE_DESCRIPTION = "Shows one draggable icon per configured player buff with countdown timers."

local DEFAULT_ICON = 134400
local ICON_SPACING = 6
local PREVIEW_SPACING = 12
local SUCCESS_COLOR = { 0.3, 0.85, 0.3 }
local WARNING_COLOR = { 1.0, 0.7, 0.2 }
local ERROR_COLOR = { 1.0, 0.35, 0.35 }
local AURA_WATCH_KEY = "PaddingPlayerBuffs"
local PROBE_AURA_ID = 1249975
local PROBE_NAME = "Vampiric Revitalization"
local PROBE_SYNTHETIC_DURATION = 15
local PROBE_MAX_STACKS = 4
local PROBE_VERBOSE_LOGS = false
local PROBE_PARTY_ACTIVITY_DEBOUNCE = 0.35
local PROBE_PARTY_ACTIVITY_GRACE = 0.5
local PROBE_PARTY_ACTIVITY_SPELLS = {
    [1250162] = "fumes_a", -- Crimson Vial Fumes
    [1250741] = "fumes_b", -- Crimson Vial Fumes
}
local PROBE_PARTY_SPELLS = {
    [1249953] = { name = "Vampiric Reaping" },
    [1249956] = { name = "Vampiric Reaping" },
    [1249969] = { name = "Reaped Orb" },
    [1250821] = { name = "Vampiric Reaping" },
    [1285815] = { name = "Vampiric Reaping" },
    [1285818] = { name = "Vampiric Reaping" },
    [1285821] = { name = "Vampiric Reaping" },
    [1285825] = { name = "Vampiric Reaping" },
    [1290656] = { name = "Vampiric Reaping" },
}
local BLIZZARD_BUFF_VIEWERS = {
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
}

local state = {
    db = nil,
    configPreviewActive = false,
    runtimeHost = nil,
    runtimeWidgets = {},
    runtimeDisplays = {},
    trackedSpells = {},
    trackedLookup = {},
    heldAuras = {},
    probeAuraInstanceIDs = {},
    partySpellHandle = nil,
    probePartySourceName = nil,
    probePartySourceUnit = nil,
    probePartyStartedAt = 0,
    probePartyLastActivityAt = 0,
    probePartyLastSpellID = nil,
    probePartySeenActivitySpells = {},
    probePartyPreviousSeenActivitySpells = {},
    probePartyPreviousProcID = 0,
    probePartyPreviousStartedAt = 0,
    probePartyProcTimeline = {},
    probePartyStartStacks = 0,
    probePartyProcID = 0,
    eventFrame = nil,
    elapsed = 0,
    probeElapsed = 0,
    probeAuraSignature = nil,
}

local IsSettingsPreviewVisible
local SnapshotProbeAura
local RefreshRuntimeDisplay

local MODULE_DEFAULTS = {
    enabled = false,
    spellIdsText = "",
    spellIds = {},
    locked = true,
    iconSize = 56,
    iconAlpha = 1,
    textSize = 18,
    backgroundOpacity = 0.55,
    showBorder = true,
    borderColor = { r = 1.0, g = 0.82, b = 0.0 },
    position = { point = "CENTER", x = 0, y = 0 },
}

local function EnsurePosition(db)
    db.position = db.position or {}
    db.position.point = db.position.point or "CENTER"
    db.position.x = tonumber(db.position.x) or 0
    db.position.y = tonumber(db.position.y) or 0
end

local function BuildSpellText(ids)
    local parts = {}
    for i, spellId in ipairs(ids or {}) do
        parts[i] = tostring(spellId)
    end
    return table.concat(parts, ", ")
end

local function ParseSpellIds(rawText)
    local ids = {}
    local seen = {}

    rawText = tostring(rawText or "")
    for token in rawText:gmatch("%d+") do
        local spellId = tonumber(token)
        if spellId and spellId > 0 and not seen[spellId] then
            seen[spellId] = true
            ids[#ids + 1] = spellId
        end
    end

    return ids
end

local function GetSpellDetails(spellId)
    local name
    local icon

    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
        if ok and type(info) == "table" then
            name = info.name
            icon = info.iconID
        end
    end

    if (not name or not icon) and GetSpellInfo then
        local ok, legacyName, _, legacyIcon = pcall(GetSpellInfo, spellId)
        if ok then
            name = name or legacyName
            icon = icon or legacyIcon
        end
    end

    if not icon and C_Spell and C_Spell.GetSpellTexture then
        local ok, texture = pcall(C_Spell.GetSpellTexture, spellId)
        if ok then
            icon = texture
        end
    end

    return name, icon
end

local function BuildSpellEntries(ids)
    local entries = {}
    local lookup = {}
    local unresolved = 0

    for _, spellId in ipairs(ids or {}) do
        local name, icon = GetSpellDetails(spellId)
        local entry = {
            spellId = spellId,
            name = name or ("Unknown Spell " .. tostring(spellId)),
            icon = icon or DEFAULT_ICON,
            resolved = name ~= nil or icon ~= nil,
        }
        if not entry.resolved then
            unresolved = unresolved + 1
        end
        entries[#entries + 1] = entry
        lookup[spellId] = entry
    end

    return entries, lookup, unresolved
end

local function RefreshConfiguredSpells(db)
    local ids = ParseSpellIds(db.spellIdsText)
    if #ids == 0 and type(db.spellIds) == "table" and #db.spellIds > 0 then
        ids = ParseSpellIds(BuildSpellText(db.spellIds))
    end

    db.spellIds = ids
    db.spellIdsText = BuildSpellText(ids)
    state.trackedSpells, state.trackedLookup = BuildSpellEntries(ids)

    for spellId in pairs(state.heldAuras) do
        if not state.trackedLookup[spellId] then
            state.heldAuras[spellId] = nil
        end
    end

    if not state.trackedLookup[PROBE_AURA_ID] then
        wipe(state.probeAuraInstanceIDs)
    end
end

local function FormatRemaining(seconds)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then
        return ""
    end
    if seconds >= 3600 then
        return format("%dh", math_floor(seconds / 3600 + 0.5))
    end
    if seconds >= 60 then
        local minutes = math_floor(seconds / 60)
        local remainder = math_floor(seconds % 60)
        return format("%d:%02d", minutes, remainder)
    end
    if seconds >= 10 then
        return tostring(math_floor(seconds + 0.5))
    end
    return format("%.1f", seconds)
end

local function GetKnownSpellTracker()
    return MedaAuras and MedaAuras.ns and MedaAuras.ns.Services and MedaAuras.ns.Services.KnownSpellTracker or nil
end

local function GetPartySpellWatcher()
    return MedaAuras and MedaAuras.ns and MedaAuras.ns.Services and MedaAuras.ns.Services.PartySpellWatcher or nil
end

local function LogDebug(msg)
    if MedaAuras and MedaAuras.LogDebug then
        MedaAuras.LogDebug(format("[Padding] %s", msg))
    end
end

local function SafeEquals(left, right)
    if left == nil or right == nil then
        return false
    end

    local ok, equal = pcall(function()
        return left == right
    end)
    return ok and equal or false
end

local function NormalizeAuraInfo(aura, fallbackIcon)
    if type(aura) ~= "table" then
        return nil
    end

    return {
        icon = aura.icon or aura.iconID or fallbackIcon,
        duration = aura.duration,
        expirationTime = aura.expirationTime,
        applications = aura.applications or aura.stackCount or aura.count or aura.charges,
    }
end

local function GetAuraSpellID(aura)
    if type(aura) ~= "table" then
        return nil
    end

    return tonumber(aura.spellId or aura.spellID)
end

local function GetAuraInstanceID(aura)
    if type(aura) ~= "table" then
        return nil
    end

    return tonumber(aura.auraInstanceID)
end

local function GetAuraApplicationCount(aura)
    if type(aura) ~= "table" then
        return nil
    end

    return tonumber(aura.applications)
        or tonumber(aura.stackCount)
        or tonumber(aura.count)
        or tonumber(aura.charges)
end

local function IsProbeAuraInfo(aura)
    if type(aura) ~= "table" then
        return false
    end

    local spellId = GetAuraSpellID(aura)
    if spellId and SafeEquals(spellId, PROBE_AURA_ID) then
        return true
    end

    return SafeEquals(aura.name, PROBE_NAME)
end

local function NormalizeCooldownViewerInfo(info, fallbackIcon)
    if type(info) ~= "table" then
        return nil
    end

    local duration = tonumber(info.duration) or nil
    local startTime = tonumber(info.startTime) or nil
    local expirationTime = nil
    if duration and duration > 0 and startTime then
        expirationTime = startTime + duration
    end

    return {
        icon = info.iconFileID or info.icon or fallbackIcon,
        duration = duration,
        expirationTime = expirationTime,
        applications = tonumber(info.charges) or tonumber(info.stackCount) or tonumber(info.count) or 0,
    }
end

local function CopyAuraInfo(aura)
    if type(aura) ~= "table" then
        return nil
    end

    return {
        icon = aura.icon,
        duration = aura.duration,
        expirationTime = aura.expirationTime,
        applications = aura.applications,
        syntheticHold = aura.syntheticHold,
    }
end

local function GetHeldAura(spellId)
    local heldAura = state.heldAuras[spellId]
    if type(heldAura) ~= "table" then
        return nil
    end

    local expirationTime = tonumber(heldAura.expirationTime) or 0
    if expirationTime > 0 and expirationTime <= GetTime() then
        state.heldAuras[spellId] = nil
        return nil
    end

    return CopyAuraInfo(heldAura)
end

local function AuraMatchesEntry(aura, entry)
    if type(aura) ~= "table" or not entry then
        return false
    end

    if aura.name and entry.name and SafeEquals(aura.name, entry.name) then
        return true
    end

    local auraIcon = aura.icon or aura.iconID
    return auraIcon and entry.icon and SafeEquals(auraIcon, entry.icon) or false
end

local function BuildLegacyAuraInfo(index, entry)
    if not UnitBuff then
        return nil
    end

    local ok, name, icon, count, _, duration, expirationTime = pcall(UnitBuff, "player", index, "HELPFUL")
    if not ok or not name then
        return nil
    end

    if not SafeEquals(name, entry.name) and not (icon and entry.icon and SafeEquals(icon, entry.icon)) then
        return nil
    end

    return {
        icon = icon or entry.icon,
        duration = duration,
        expirationTime = expirationTime,
        applications = count,
    }
end

local function ShouldProbeAura()
    return state.trackedLookup[PROBE_AURA_ID] ~= nil
end

local function GetCooldownViewerSpellID(child, info)
    if type(info) == "table" then
        local overrideSpellID = tonumber(info.overrideSpellID)
        if overrideSpellID and overrideSpellID > 0 then
            return overrideSpellID
        end

        local spellID = tonumber(info.spellID)
        if spellID and spellID > 0 then
            return spellID
        end
    end

    if child and child.spellID then
        local spellID = tonumber(child.spellID)
        if spellID and spellID > 0 then
            return spellID
        end
    end

    if child and child.GetSpellID and type(child.GetSpellID) == "function" then
        local ok, spellID = pcall(child.GetSpellID, child)
        spellID = ok and tonumber(spellID) or nil
        if spellID and spellID > 0 then
            return spellID
        end
    end

    return nil
end

local function GetCooldownViewerInfo(child)
    if not child or not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCooldownInfo then
        return nil
    end

    local cooldownID = child.cooldownID or (child.cooldownInfo and child.cooldownInfo.cooldownID)
    if not cooldownID then
        return nil
    end

    local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
    if ok then
        return info
    end

    return nil
end

local function CollectCooldownViewerAuras(parent, depth, auraBySpellId)
    if not parent or depth > 4 then
        return
    end

    local ok, children = pcall(function()
        return { parent:GetChildren() }
    end)
    if not ok or not children then
        return
    end

    for _, child in ipairs(children) do
        local info = GetCooldownViewerInfo(child)
        local spellID = GetCooldownViewerSpellID(child, info)
        if spellID and not auraBySpellId[spellID] then
            auraBySpellId[spellID] = NormalizeCooldownViewerInfo(info, child.icon and child.icon.GetTexture and child.icon:GetTexture() or nil)
        end

        CollectCooldownViewerAuras(child, depth + 1, auraBySpellId)
    end
end

local function GetCooldownViewerAuraMap()
    local auraBySpellId = {}
    if not C_CooldownViewer then
        return auraBySpellId
    end

    for _, viewerName in ipairs(BLIZZARD_BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            CollectCooldownViewerAuras(viewer, 0, auraBySpellId)
        end
    end

    return auraBySpellId
end

local function SetHeldAura(spellId, aura, reason, syntheticHold)
    local entry = state.trackedLookup[spellId]
    if not entry then
        return
    end

    local now = GetTime()
    local heldAura = state.heldAuras[spellId] or {}
    local normalizedAura = NormalizeAuraInfo(aura, entry.icon) or {}
    local duration = tonumber(normalizedAura.duration) or tonumber(heldAura.duration) or PROBE_SYNTHETIC_DURATION
    local expirationTime = tonumber(normalizedAura.expirationTime) or (now + duration)
    local applications = GetAuraApplicationCount(normalizedAura)
        or GetAuraApplicationCount(aura)
        or tonumber(heldAura.applications)
        or 1

    heldAura.icon = normalizedAura.icon or heldAura.icon or entry.icon
    heldAura.duration = duration
    heldAura.expirationTime = expirationTime
    heldAura.applications = math_max(applications, 1)
    heldAura.syntheticHold = syntheticHold ~= false
    state.heldAuras[spellId] = heldAura
    LogDebug(format(
        "SyntheticHold reason=%s spell=%s duration=%s exp=%s stacks=%s",
        tostring(reason),
        tostring(spellId),
        tostring(heldAura.duration),
        tostring(heldAura.expirationTime),
        tostring(heldAura.applications)
    ))
end

local function SetSyntheticHeldAura(spellId, duration, applications, reason)
    SetHeldAura(spellId, {
        duration = duration,
        expirationTime = GetTime() + duration,
        applications = applications,
    }, reason, true)
end

local function GetSyntheticStackCount(spellId)
    local heldAura = GetHeldAura(spellId)
    if heldAura and heldAura.expirationTime and heldAura.expirationTime > GetTime() then
        return tonumber(heldAura.applications) or 0
    end
    return 0
end

local function HandleProbeAuraInfo(aura, reason)
    if not ShouldProbeAura() or not IsProbeAuraInfo(aura) then
        return false
    end

    local auraInstanceID = GetAuraInstanceID(aura)
    if auraInstanceID then
        state.probeAuraInstanceIDs[auraInstanceID] = true
    end

    LogDebug(format(
        "ProbeAuraUpdate[%s] instance=%s stacks=%s dur=%s exp=%s",
        tostring(reason),
        tostring(auraInstanceID),
        tostring(GetAuraApplicationCount(aura) or 0),
        tostring(aura.duration),
        tostring(aura.expirationTime)
    ))

    SetHeldAura(PROBE_AURA_ID, aura, reason, true)
    SnapshotProbeAura(reason, true)
    return true
end

local function HandleProbeAuraUpdateInfo(updateInfo)
    if not ShouldProbeAura() or type(updateInfo) ~= "table" then
        return
    end

    if type(updateInfo.addedAuras) == "table" then
        for _, aura in ipairs(updateInfo.addedAuras) do
            HandleProbeAuraInfo(aura, "UNIT_AURA:add")
        end
    end

    if GetAuraDataByAuraInstanceID and type(updateInfo.updatedAuraInstanceIDs) == "table" then
        for _, auraInstanceID in ipairs(updateInfo.updatedAuraInstanceIDs) do
            local ok, aura = pcall(GetAuraDataByAuraInstanceID, "player", auraInstanceID)
            if ok and aura then
                HandleProbeAuraInfo(aura, "UNIT_AURA:update")
            end
        end
    end

    if type(updateInfo.removedAuraInstanceIDs) == "table" then
        for _, auraInstanceID in ipairs(updateInfo.removedAuraInstanceIDs) do
            if state.probeAuraInstanceIDs[auraInstanceID] then
                if InCombatLockdown and InCombatLockdown() then
                    LogDebug(format("ProbeAuraUpdate[UNIT_AURA:remove] ignored in-combat instance=%s", tostring(auraInstanceID)))
                    SnapshotProbeAura("UNIT_AURA:remove-ignored", true)
                    return
                end

                state.probeAuraInstanceIDs[auraInstanceID] = nil
                state.heldAuras[PROBE_AURA_ID] = nil
                state.probePartySourceName = nil
                state.probePartySourceUnit = nil
                state.probePartyStartedAt = 0
                state.probePartyLastActivityAt = 0
                state.probePartyLastSpellID = nil
                wipe(state.probePartySeenActivitySpells)
                LogDebug(format("ProbeAuraUpdate[UNIT_AURA:remove] instance=%s", tostring(auraInstanceID)))
                SnapshotProbeAura("UNIT_AURA:remove", true)
            end
        end
    end
end

local function GetProbeSyntheticStacks()
    local heldAura = state.heldAuras[PROBE_AURA_ID]
    if type(heldAura) ~= "table" then
        return 0
    end

    return tonumber(heldAura.applications) or 0
end

local function GetProbeActualStacks()
    local trackerStacks
    local byIDStacks
    local byNameStacks

    local tracker = GetKnownSpellTracker()
    if tracker and tracker.GetPlayerSpellState then
        local trackerState = tracker:GetPlayerSpellState(AURA_WATCH_KEY, PROBE_AURA_ID)
        if trackerState and trackerState.active then
            trackerStacks = tonumber(trackerState.applications) or 0
        end
    end

    if GetPlayerAuraBySpellID then
        local ok, aura = pcall(GetPlayerAuraBySpellID, PROBE_AURA_ID)
        if ok and aura then
            byIDStacks = GetAuraApplicationCount(aura) or 0
        end
    end

    if GetAuraDataBySpellName then
        local ok, aura = pcall(GetAuraDataBySpellName, "player", PROBE_NAME, "HELPFUL")
        if ok and aura then
            byNameStacks = GetAuraApplicationCount(aura) or 0
        end
    end

    return {
        tracker = trackerStacks,
        byID = byIDStacks,
        byName = byNameStacks,
    }
end

local function GetProbeVisibleAura()
    if GetPlayerAuraBySpellID then
        local ok, aura = pcall(GetPlayerAuraBySpellID, PROBE_AURA_ID)
        if ok and type(aura) == "table" then
            local normalizedAura = NormalizeAuraInfo(aura)
            if normalizedAura and (GetAuraApplicationCount(normalizedAura) or 0) > 0 then
                return normalizedAura, "byID"
            end
        end
    end

    if GetAuraDataBySpellName then
        local ok, aura = pcall(GetAuraDataBySpellName, "player", PROBE_NAME, "HELPFUL")
        if ok and type(aura) == "table" then
            local normalizedAura = NormalizeAuraInfo(aura)
            if normalizedAura and (GetAuraApplicationCount(normalizedAura) or 0) > 0 then
                return normalizedAura, "byName"
            end
        end
    end

    return nil, nil
end

local function ReconcileProbeVisibleAura(reason)
    if not ShouldProbeAura() then
        return false
    end

    local visibleAura, visibleSource = GetProbeVisibleAura()
    if not visibleAura then
        return false
    end

    local visibleStacks = GetAuraApplicationCount(visibleAura) or 0
    local currentStacks = GetSyntheticStackCount(PROBE_AURA_ID)
    local currentHeld = GetHeldAura(PROBE_AURA_ID)
    local currentExpiration = currentHeld and tonumber(currentHeld.expirationTime) or 0
    local visibleExpiration = tonumber(visibleAura.expirationTime) or 0

    if visibleStacks ~= currentStacks
        or (visibleExpiration > 0 and (currentExpiration <= 0 or math.abs(visibleExpiration - currentExpiration) > 0.05)) then
        SetHeldAura(PROBE_AURA_ID, visibleAura, tostring(reason) .. ":" .. tostring(visibleSource), false)
        LogDebug(format(
            "ProbeVisibleSync reason=%s source=%s stacks=%s exp=%s",
            tostring(reason),
            tostring(visibleSource),
            tostring(visibleStacks),
            tostring(visibleAura.expirationTime)
        ))
        return true
    end

    return false
end

local function FormatProbeActualStacks(actual)
    actual = actual or {}
    return format(
        "tracker=%s byID=%s byName=%s",
        tostring(actual.tracker),
        tostring(actual.byID),
        tostring(actual.byName)
    )
end

local function CopyKeySet(source)
    local target = {}
    for key, value in pairs(source or {}) do
        if value then
            target[key] = true
        end
    end
    return target
end

local function FormatProbeSeenKeys(seen)
    local keys = {}
    for key in pairs(seen or {}) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    return (#keys > 0 and table.concat(keys, ",") or "none")
end

local function HasProbeSeenActivity()
    return next(state.probePartySeenActivitySpells or {}) ~= nil
end

local function AppendProbeProcTimeline(kind, spellId, now)
    local elapsed = 0
    if now and state.probePartyStartedAt and state.probePartyStartedAt > 0 then
        elapsed = math_max(0, now - state.probePartyStartedAt)
    end

    local timeline = state.probePartyProcTimeline
    timeline[#timeline + 1] = {
        kind = tostring(kind),
        spellId = tonumber(spellId) or spellId,
        elapsed = elapsed,
    }
end

local function FormatProbeProcTimeline()
    local parts = {}
    for _, event in ipairs(state.probePartyProcTimeline or {}) do
        parts[#parts + 1] = format("%s:%s@%.3f", tostring(event.kind), tostring(event.spellId), tonumber(event.elapsed) or 0)
    end
    return (#parts > 0 and table.concat(parts, ",") or "none")
end

local function BuildProbeModelSummary()
    local startStacks = tonumber(state.probePartyStartStacks) or 0
    local seen = {}

    for _, event in ipairs(state.probePartyProcTimeline or {}) do
        if event.kind ~= "start" then
            seen[event.spellId] = true
        end
    end

    local function CountDistinct(ids)
        local total = startStacks
        for _, id in ipairs(ids) do
            if seen[id] then
                total = total + 1
            end
        end
        return math_min(PROBE_MAX_STACKS, total)
    end

    local fumesSeparate = CountDistinct({ 1250162, 1250741 })
    local fumesAny = math_min(PROBE_MAX_STACKS, startStacks + ((seen[1250162] or seen[1250741]) and 1 or 0))
    local ruptureFumes = CountDistinct({ 1247770, 1250162, 1250741 })
    local ruptureSpreeFumes = CountDistinct({ 1247770, 1248011, 1250162, 1250741 })

    return format(
        "start=%s fumesSep=%s fumesAny=%s ruptureFumes=%s ruptureSpreeFumes=%s",
        tostring(startStacks),
        tostring(fumesSeparate),
        tostring(fumesAny),
        tostring(ruptureFumes),
        tostring(ruptureSpreeFumes)
    )
end

local function GetProbePreferredStartStacks(currentStacks)
    local actual = GetProbeActualStacks()
    local preferredStacks
    local preferredSource

    if actual.byID ~= nil then
        preferredStacks = tonumber(actual.byID) or 0
        preferredSource = "byID"
    elseif actual.byName ~= nil then
        preferredStacks = tonumber(actual.byName) or 0
        preferredSource = "byName"
    end

    if preferredStacks and preferredStacks > 0 then
        return preferredStacks, preferredSource, actual
    end

    if currentStacks > 0 then
        return currentStacks, "synthetic", actual
    end

    return 1, "default", actual
end

local function LogProbeCombatEndCompare(reason)
    if not ShouldProbeAura() then
        return
    end

    local syntheticStacks = GetProbeSyntheticStacks()
    local actual = GetProbeActualStacks()
    LogDebug(format(
        "CombatEndCompare[%s] proc=%s synthetic=%s tracker=%s byID=%s byName=%s seen=%s prevProc=%s prevSeen=%s models={%s} timeline=%s",
        tostring(reason),
        tostring(state.probePartyProcID),
        tostring(syntheticStacks),
        tostring(actual and actual.tracker),
        tostring(actual and actual.byID),
        tostring(actual and actual.byName),
        FormatProbeSeenKeys(state.probePartySeenActivitySpells),
        tostring(state.probePartyPreviousProcID),
        FormatProbeSeenKeys(state.probePartyPreviousSeenActivitySpells),
        BuildProbeModelSummary(),
        FormatProbeProcTimeline()
    ))
end

local function DescribeAuraForLog(aura)
    if type(aura) ~= "table" then
        return "inactive"
    end

    return format(
        "active icon=%s dur=%s exp=%s stacks=%s",
        tostring(aura.icon or aura.iconID),
        tostring(aura.duration),
        tostring(aura.expirationTime),
        tostring(aura.applications or aura.stackCount or aura.count or aura.charges or 0)
    )
end

SnapshotProbeAura = function(reason, force)
    if not PROBE_VERBOSE_LOGS then
        return
    end

    if not ShouldProbeAura() then
        return
    end

    local parts = {}
    local entry = state.trackedLookup[PROBE_AURA_ID]
    local tracker = GetKnownSpellTracker()

    if tracker and tracker.GetPlayerSpellState then
        local trackerState = tracker:GetPlayerSpellState(AURA_WATCH_KEY, PROBE_AURA_ID)
        if trackerState then
            local trackerSummary = format(
                "tracker active=%s synthetic=%s dur=%s exp=%s stacks=%s",
                tostring(trackerState.active),
                tostring(trackerState.syntheticHold),
                tostring(trackerState.duration),
                tostring(trackerState.expirationTime),
                tostring(trackerState.applications)
            )
            if force then
                trackerSummary = trackerSummary .. format(" lastSeen=%s", tostring(trackerState.lastSeen))
            end
            parts[#parts + 1] = trackerSummary
        else
            parts[#parts + 1] = "tracker inactive"
        end
    end

    if GetPlayerAuraBySpellID then
        local ok, aura = pcall(GetPlayerAuraBySpellID, PROBE_AURA_ID)
        parts[#parts + 1] = ok and ("byID " .. DescribeAuraForLog(aura)) or "byID error"
    end

    if GetAuraDataBySpellName then
        local ok, aura = pcall(GetAuraDataBySpellName, "player", PROBE_NAME, "HELPFUL")
        parts[#parts + 1] = ok and ("byName " .. DescribeAuraForLog(aura)) or "byName error"
    end

    if AuraUtil and AuraUtil.FindAuraByName then
        local ok, aura = pcall(AuraUtil.FindAuraByName, PROBE_NAME, "player", "HELPFUL")
        if ok then
            if type(aura) == "table" then
                parts[#parts + 1] = "AuraUtil " .. DescribeAuraForLog(aura)
            else
                parts[#parts + 1] = format("AuraUtil match=%s", tostring(aura ~= nil))
            end
        else
            parts[#parts + 1] = "AuraUtil error"
        end
    end

    do
        local viewerAura = GetCooldownViewerAuraMap()[PROBE_AURA_ID]
        parts[#parts + 1] = "viewer " .. DescribeAuraForLog(viewerAura)
    end

    if entry then
        for index = 1, 40 do
            local aura = BuildLegacyAuraInfo(index, entry)
            if aura then
                parts[#parts + 1] = format("UnitBuff[%d] %s", index, DescribeAuraForLog(aura))
                break
            end

            local ok, name = pcall(UnitBuff, "player", index, "HELPFUL")
            if not ok or not name then
                break
            end
        end
    end

    local signature = table.concat(parts, " | ")
    if force or signature ~= state.probeAuraSignature then
        state.probeAuraSignature = signature
        LogDebug(format("ProbeAura[%s] %s", tostring(reason), signature ~= "" and signature or "no-data"))
    end
end

local function IsPlayerAssistTarget(assistedPlayer)
    if type(assistedPlayer) ~= "string" or assistedPlayer == "" then
        return false
    end

    local playerName = UnitName and UnitName("player") or nil
    if type(playerName) ~= "string" or playerName == "" then
        return false
    end

    return assistedPlayer == playerName or strfind(assistedPlayer, playerName .. "-", 1, true) == 1
end

local function OnDelveAssistAction(data)
    if type(data) ~= "table" then
        if PROBE_VERBOSE_LOGS then
            LogDebug("DelveAssist invalid payload")
        end
        return
    end

    if PROBE_VERBOSE_LOGS then
        LogDebug(format(
            "DelveAssist action=%s player=%s creature=%s spell=%s map=%s",
            tostring(data.assistAction),
            tostring(data.assistedPlayer),
            tostring(data.creatureName),
            tostring(data.receivedSpellID),
            tostring(data.mapName)
        ))
    end

    if not ShouldProbeAura() or not IsPlayerAssistTarget(data.assistedPlayer) then
        return
    end

    if tonumber(data.receivedSpellID) == PROBE_AURA_ID then
        SetSyntheticHeldAura(PROBE_AURA_ID, PROBE_SYNTHETIC_DURATION, nil, "DELVE_ASSIST_ACTION")
        SnapshotProbeAura("DELVE_ASSIST_ACTION", true)
    end
end

local function ShouldUsePartySpellProbe()
    return state.trackedLookup[PROBE_AURA_ID] ~= nil
        and C_PartyInfo
        and C_PartyInfo.IsDelveInProgress
        and C_PartyInfo.IsDelveInProgress()
end

local function IsProbePartySource(name, unit)
    if state.probePartySourceUnit and unit and state.probePartySourceUnit == unit then
        return true
    end

    return state.probePartySourceName and name and SafeEquals(state.probePartySourceName, name) or false
end

local function RememberProbePartySource(name, unit, spellId)
    state.probePartySourceName = name
    state.probePartySourceUnit = unit
    state.probePartyLastActivityAt = GetTime()
    state.probePartyLastSpellID = spellId
end

local function LogProbePartyEvent(kind, name, unit, spellId, currentStacks, extra, now)
    local elapsed = 0
    if now and state.probePartyStartedAt and state.probePartyStartedAt > 0 then
        elapsed = math_max(0, now - state.probePartyStartedAt)
    end

    local actual = GetProbeActualStacks()
    local heldAura = GetHeldAura(PROBE_AURA_ID)
    local holdRemaining = nil
    if heldAura and heldAura.expirationTime then
        holdRemaining = math_max(0, (tonumber(heldAura.expirationTime) or 0) - GetTime())
    end

    LogDebug(format(
        "PartyEvent proc=%s kind=%s name=%s unit=%s spell=%s elapsed=%.3f stacks=%s hold=%.3f actual={%s} %s",
        tostring(state.probePartyProcID),
        tostring(kind),
        tostring(name),
        tostring(unit),
        tostring(spellId),
        elapsed,
        tostring(currentStacks),
        tonumber(holdRemaining) or -1,
        FormatProbeActualStacks(actual),
        tostring(extra or "")
    ))
end

local function OnProbePartySpell(name, spellId, unit)
    if not ShouldUsePartySpellProbe() then
        return
    end

    if not unit or not UnitInPartyIsAI or not UnitInPartyIsAI(unit) then
        return
    end

    local now = GetTime()
    local matchedSpell = PROBE_PARTY_SPELLS[spellId]
    local currentStacks = GetSyntheticStackCount(PROBE_AURA_ID)
    if ReconcileProbeVisibleAura("PARTY_VISIBLE:" .. tostring(spellId)) then
        currentStacks = GetSyntheticStackCount(PROBE_AURA_ID)
        LogProbePartyEvent(
            "sync",
            name,
            unit,
            spellId,
            currentStacks,
            "source=visible",
            now
        )
    end

    if matchedSpell then
        local startStacks, startSource = GetProbePreferredStartStacks(currentStacks)
        local previousProcID = state.probePartyProcID
        local previousStartedAt = state.probePartyStartedAt or 0
        local previousElapsed = 0
        if previousStartedAt > 0 then
            previousElapsed = math_max(0, now - previousStartedAt)
        end
        state.probePartyPreviousProcID = previousProcID
        state.probePartyPreviousStartedAt = previousStartedAt
        state.probePartyPreviousSeenActivitySpells = CopyKeySet(state.probePartySeenActivitySpells)

        state.probePartyProcID = state.probePartyProcID + 1
        wipe(state.probePartySeenActivitySpells)
        wipe(state.probePartyProcTimeline)
        state.probePartyStartedAt = now
        state.probePartyStartStacks = startStacks
        RememberProbePartySource(name, unit, spellId)
        AppendProbeProcTimeline("start", spellId, now)
        LogProbePartyEvent(
            "start",
            name,
            unit,
            spellId,
            currentStacks,
            format(
                "spellName=%s prevStacks=%s startStacks=%s startSource=%s prevProc=%s prevElapsed=%.3f prevSeen=%s",
                tostring(matchedSpell.name),
                tostring(currentStacks),
                tostring(startStacks),
                tostring(startSource),
                tostring(previousProcID),
                previousElapsed,
                FormatProbeSeenKeys(state.probePartyPreviousSeenActivitySpells)
            ),
            now
        )

        SetSyntheticHeldAura(PROBE_AURA_ID, PROBE_SYNTHETIC_DURATION, startStacks, "PARTY_SPELL:" .. tostring(spellId))
        SnapshotProbeAura("PARTY_SPELL:" .. tostring(spellId), true)
        RefreshRuntimeDisplay()
        return
    end

    if not IsProbePartySource(name, unit) then
        return
    end

    AppendProbeProcTimeline("spell", spellId, now)

    if currentStacks <= 0 then
        return
    end

    local activityKey = PROBE_PARTY_ACTIVITY_SPELLS[spellId]
    if not activityKey and spellId == 1247770 and currentStacks >= 3 and not HasProbeSeenActivity() then
        activityKey = "rupture_carry"
    end
    if not activityKey then
        LogProbePartyEvent("skip", name, unit, spellId, currentStacks, "reason=not-whitelist", now)
        return
    end

    if state.probePartySeenActivitySpells[activityKey] then
        LogProbePartyEvent("skip", name, unit, spellId, currentStacks, "reason=seen key=" .. tostring(activityKey), now)
        return
    end

    if (now - (state.probePartyStartedAt or 0)) < PROBE_PARTY_ACTIVITY_GRACE then
        LogProbePartyEvent("skip", name, unit, spellId, currentStacks, format("reason=grace dt=%.3f key=%s", now - (state.probePartyStartedAt or 0), tostring(activityKey)), now)
        return
    end

    if spellId == state.probePartyLastSpellID and (now - (state.probePartyLastActivityAt or 0)) < PROBE_PARTY_ACTIVITY_DEBOUNCE then
        LogProbePartyEvent("skip", name, unit, spellId, currentStacks, format("reason=debounce dt=%.3f key=%s", now - (state.probePartyLastActivityAt or 0), tostring(activityKey)), now)
        return
    end

    if currentStacks >= PROBE_MAX_STACKS then
        LogProbePartyEvent(
            "refresh",
            name,
            unit,
            spellId,
            currentStacks,
            format("key=%s next=%s", tostring(activityKey), tostring(currentStacks)),
            now
        )
        RememberProbePartySource(name, unit, spellId)
        SetSyntheticHeldAura(PROBE_AURA_ID, PROBE_SYNTHETIC_DURATION, currentStacks, "PARTY_REFRESH:" .. tostring(spellId))
        SnapshotProbeAura("PARTY_REFRESH:" .. tostring(spellId), true)
        RefreshRuntimeDisplay()
        return
    end

    LogProbePartyEvent(
        "accept",
        name,
        unit,
        spellId,
        currentStacks,
        format(
            "key=%s next=%s prevProc=%s prevSeen=%s",
            tostring(activityKey),
            tostring(math_min(PROBE_MAX_STACKS, currentStacks + 1)),
            tostring(state.probePartyPreviousProcID),
            tostring(state.probePartyPreviousSeenActivitySpells and state.probePartyPreviousSeenActivitySpells[activityKey] and true or false)
        ),
        now
    )

    state.probePartySeenActivitySpells[activityKey] = true
    RememberProbePartySource(name, unit, spellId)
    SetSyntheticHeldAura(PROBE_AURA_ID, PROBE_SYNTHETIC_DURATION, math_min(PROBE_MAX_STACKS, currentStacks + 1), "PARTY_ACTIVITY:" .. tostring(spellId))
    SnapshotProbeAura("PARTY_ACTIVITY:" .. tostring(spellId), true)
    RefreshRuntimeDisplay()
end

local function SyncPartySpellWatcher()
    local watcher = GetPartySpellWatcher()
    if not watcher or not watcher.Initialize or not watcher.OnAnyPartySpell then
        return
    end

    if state.partySpellHandle then
        if watcher.Unregister then
            watcher:Unregister(state.partySpellHandle)
        end
        state.partySpellHandle = nil
    end

    if not ShouldProbeAura() then
        return
    end

    watcher:Initialize()
    state.partySpellHandle = watcher:OnAnyPartySpell(OnProbePartySpell)
end

local function SyncAuraWatch()
    local tracker = GetKnownSpellTracker()
    if not tracker or not tracker.Initialize or not tracker.RegisterPlayerWatch then
        return
    end

    tracker:Initialize()

    if #state.trackedSpells == 0 then
        if tracker.UnregisterWatch then
            tracker:UnregisterWatch(AURA_WATCH_KEY)
        end
        return
    end

    local spells = {}
    for _, entry in ipairs(state.trackedSpells) do
        spells[#spells + 1] = {
            spellID = entry.spellId,
            name = entry.name,
            filter = "HELPFUL",
        }
    end

    tracker:RegisterPlayerWatch(AURA_WATCH_KEY, {
        spells = spells,
        filter = "HELPFUL",
    })

    if tracker.RequestPlayerScan then
        tracker:RequestPlayerScan(AURA_WATCH_KEY)
    end
end

local function GetTrackedAuraMap()
    local auraBySpellId = {}
    local tracker = GetKnownSpellTracker()
    local inCombat = InCombatLockdown and InCombatLockdown()
    local cooldownViewerAuraBySpellId = nil

    if tracker and tracker.GetPlayerSpellState then
        for _, entry in ipairs(state.trackedSpells) do
            local auraState = tracker:GetPlayerSpellState(AURA_WATCH_KEY, entry.spellId)
            if auraState and auraState.active then
                auraBySpellId[entry.spellId] = {
                    spellId = entry.spellId,
                    icon = entry.icon,
                    duration = auraState.duration,
                    expirationTime = auraState.expirationTime,
                    applications = auraState.applications,
                    syntheticHold = auraState.syntheticHold,
                }
            end
        end
    end

    if not UnitExists or not UnitExists("player") then
        return auraBySpellId
    end

    if GetPlayerAuraBySpellID then
        for _, entry in ipairs(state.trackedSpells) do
            if not auraBySpellId[entry.spellId] then
                local ok, aura = pcall(GetPlayerAuraBySpellID, entry.spellId)
                if ok and aura then
                    auraBySpellId[entry.spellId] = NormalizeAuraInfo(aura, entry.icon)
                end
            end
        end
    end

    if GetAuraDataBySpellName then
        for _, entry in ipairs(state.trackedSpells) do
            if not auraBySpellId[entry.spellId] then
                local ok, aura = pcall(GetAuraDataBySpellName, "player", entry.name, "HELPFUL")
                if ok and aura then
                    auraBySpellId[entry.spellId] = NormalizeAuraInfo(aura, entry.icon)
                end
            end
        end
    end

    if AuraUtil and AuraUtil.FindAuraByName then
        for _, entry in ipairs(state.trackedSpells) do
            if not auraBySpellId[entry.spellId] then
                local ok, aura = pcall(AuraUtil.FindAuraByName, entry.name, "player", "HELPFUL")
                if ok and aura then
                    if type(aura) == "table" then
                        auraBySpellId[entry.spellId] = NormalizeAuraInfo(aura, entry.icon)
                    else
                        auraBySpellId[entry.spellId] = {
                            icon = entry.icon,
                        }
                    end
                end
            end
        end
    end

    if GetAuraDataByIndex then
        for index = 1, 40 do
            local ok, aura = pcall(GetAuraDataByIndex, "player", index, "HELPFUL")
            if not ok or not aura then
                break
            end

            for _, entry in ipairs(state.trackedSpells) do
                if not auraBySpellId[entry.spellId] and AuraMatchesEntry(aura, entry) then
                    auraBySpellId[entry.spellId] = NormalizeAuraInfo(aura, entry.icon)
                    break
                end
            end
        end
    elseif C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
        for index = 1, 40 do
            local ok, aura = pcall(C_UnitAuras.GetBuffDataByIndex, "player", index)
            if not ok or not aura then
                break
            end

            for _, entry in ipairs(state.trackedSpells) do
                if not auraBySpellId[entry.spellId] and AuraMatchesEntry(aura, entry) then
                    auraBySpellId[entry.spellId] = NormalizeAuraInfo(aura, entry.icon)
                    break
                end
            end
        end
    end

    for index = 1, 40 do
        local anyFound = false

        for _, entry in ipairs(state.trackedSpells) do
            if not auraBySpellId[entry.spellId] then
                local aura = BuildLegacyAuraInfo(index, entry)
                if aura then
                    auraBySpellId[entry.spellId] = aura
                    anyFound = true
                end
            end
        end

        if not anyFound then
            local ok, name = pcall(UnitBuff, "player", index, "HELPFUL")
            if not ok or not name then
                break
            end
        end
    end

    if inCombat or C_CooldownViewer then
        cooldownViewerAuraBySpellId = GetCooldownViewerAuraMap()
    end

    if cooldownViewerAuraBySpellId then
        for _, entry in ipairs(state.trackedSpells) do
            if not auraBySpellId[entry.spellId] and cooldownViewerAuraBySpellId[entry.spellId] then
                auraBySpellId[entry.spellId] = NormalizeAuraInfo(cooldownViewerAuraBySpellId[entry.spellId], entry.icon)
            end
        end
    end

    for _, entry in ipairs(state.trackedSpells) do
        local spellId = entry.spellId
        local activeAura = auraBySpellId[spellId]
        local heldAura = GetHeldAura(spellId)

        if activeAura then
            local activeStacks = GetAuraApplicationCount(activeAura) or 0
            local heldStacks = GetAuraApplicationCount(heldAura) or 0
            local activeExpiration = tonumber(activeAura.expirationTime) or 0
            local heldExpiration = tonumber(heldAura and heldAura.expirationTime) or 0

            if heldAura
                and heldExpiration > activeExpiration
                and heldStacks >= activeStacks then
                auraBySpellId[spellId] = heldAura
                state.heldAuras[spellId] = CopyAuraInfo(heldAura)
            else
                state.heldAuras[spellId] = CopyAuraInfo(activeAura)
            end
        elseif inCombat then
            if heldAura then
                auraBySpellId[spellId] = heldAura
            end
        else
            state.heldAuras[spellId] = nil
        end
    end

    return auraBySpellId
end

local function CreateIconWidget(parent)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetBackdrop(MedaUI:CreateBackdrop(true))

    frame.icon = frame:CreateTexture(nil, "ARTWORK")
    frame.icon:SetPoint("TOPLEFT", 4, -4)
    frame.icon:SetPoint("BOTTOMRIGHT", -4, 4)
    frame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    frame.cooldown = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
    frame.cooldown:SetAllPoints(frame.icon)
    frame.cooldown:SetReverse(false)
    frame.cooldown:SetHideCountdownNumbers(true)
    if frame.cooldown.SetDrawBling then
        frame.cooldown:SetDrawBling(false)
    end
    if frame.cooldown.SetDrawEdge then
        frame.cooldown:SetDrawEdge(false)
    end
    if frame.cooldown.SetDrawSwipe then
        frame.cooldown:SetDrawSwipe(true)
    end
    frame.cooldown:Hide()

    frame.timeText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.timeText:SetPoint("CENTER", 0, 0)
    frame.timeText:SetJustifyH("CENTER")
    frame.timeText:SetShadowOffset(1, -1)
    frame.timeText:SetShadowColor(0, 0, 0, 1)

    frame.stackText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.stackText:SetPoint("BOTTOMRIGHT", -3, 3)
    frame.stackText:SetJustifyH("RIGHT")
    frame.stackText:SetShadowOffset(1, -1)
    frame.stackText:SetShadowColor(0, 0, 0, 1)

    return frame
end

local function ApplyWidgetStyle(widget, db, size, alphaOverride)
    local borderColor = db.borderColor or MODULE_DEFAULTS.borderColor
    local bgAlpha = tonumber(db.backgroundOpacity) or MODULE_DEFAULTS.backgroundOpacity
    local textSize = math_max(8, tonumber(db.textSize) or MODULE_DEFAULTS.textSize)

    widget:SetSize(size, size)
    widget:SetAlpha(alphaOverride or tonumber(db.iconAlpha) or MODULE_DEFAULTS.iconAlpha)
    widget:SetBackdropColor(0, 0, 0, bgAlpha)
    widget.timeText:SetFont(STANDARD_TEXT_FONT, textSize, "OUTLINE")
    widget.stackText:SetFont(STANDARD_TEXT_FONT, math_max(10, math_floor(textSize * 0.7)), "OUTLINE")

    if db.showBorder == false then
        widget:SetBackdropBorderColor(0, 0, 0, 0)
    else
        widget:SetBackdropBorderColor(
            borderColor.r or MODULE_DEFAULTS.borderColor.r,
            borderColor.g or MODULE_DEFAULTS.borderColor.g,
            borderColor.b or MODULE_DEFAULTS.borderColor.b,
            1
        )
    end
end

local function GetAuraStacks(aura)
    if type(aura) ~= "table" then
        return 0
    end

    return tonumber(aura.applications)
        or tonumber(aura.stackCount)
        or tonumber(aura.charges)
        or tonumber(aura.count)
        or 0
end

local function ApplyDisplayToWidget(widget, display, db, size, alphaOverride)
    ApplyWidgetStyle(widget, db, size, alphaOverride)

    widget.icon:SetTexture((display.entry and display.entry.icon) or DEFAULT_ICON)
    widget.timeText:SetText("")
    widget.stackText:SetText("")

    if display.aura then
        local expirationTime = tonumber(display.aura.expirationTime) or 0
        local duration = tonumber(display.aura.duration) or 0
        local remaining = expirationTime - GetTime()
        local stacks = GetAuraStacks(display.aura)

        widget.icon:SetTexture(display.aura.icon or widget.icon:GetTexture() or DEFAULT_ICON)
        widget.icon:SetDesaturated(false)

        if duration > 0 and expirationTime > 0 then
            widget.cooldown:SetCooldown(expirationTime - duration, duration)
            widget.cooldown:Show()
            widget.timeText:SetText(FormatRemaining(remaining))
        else
            widget.cooldown:Hide()
        end

        if stacks and stacks > 1 then
            widget.stackText:SetText(tostring(stacks))
        end
    else
        widget.cooldown:Hide()
        widget.icon:SetDesaturated(true)
        if display.previewTime then
            widget.timeText:SetText(display.previewTime)
        elseif display.placeholder then
            widget.timeText:SetText("12")
        end
        if display.previewStacks and display.previewStacks > 1 then
            widget.stackText:SetText(tostring(display.previewStacks))
        end
    end

    widget:Show()
end

local function EnsureRuntimeHost()
    if state.runtimeHost then
        return state.runtimeHost
    end

    local host = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    host:SetFrameStrata("MEDIUM")
    host:SetClampedToScreen(true)
    host:EnableMouse(true)
    host:SetMovable(true)
    host:RegisterForDrag("LeftButton")
    host:SetBackdrop(MedaUI:CreateBackdrop(true))
    host:SetBackdropColor(0, 0, 0, 0)
    host:SetBackdropBorderColor(0, 0, 0, 0)

    host:SetScript("OnDragStart", function(self)
        if state.db and (IsSettingsPreviewVisible() or state.db.locked == false) then
            self:StartMoving()
        end
    end)

    host:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if state.db then
            EnsurePosition(state.db)
            local point, _, _, x, y = self:GetPoint()
            state.db.position.point = point or "CENTER"
            state.db.position.x = x or 0
            state.db.position.y = y or 0
        end
    end)

    state.runtimeHost = host
    return host
end

local function ApplyRuntimePosition(db)
    local host = EnsureRuntimeHost()
    EnsurePosition(db)
    host:ClearAllPoints()
    host:SetPoint(db.position.point, UIParent, db.position.point, db.position.x, db.position.y)
end

local function EnsureRuntimeWidget(index)
    if state.runtimeWidgets[index] then
        return state.runtimeWidgets[index]
    end

    local host = EnsureRuntimeHost()
    local widget = CreateIconWidget(host)
    widget:EnableMouse(false)
    state.runtimeWidgets[index] = widget
    return widget
end

local function HideUnusedRuntimeWidgets(fromIndex)
    for index = fromIndex, #state.runtimeWidgets do
        state.runtimeWidgets[index]:Hide()
    end
end

function IsSettingsPreviewVisible()
    if not state.configPreviewActive then
        return false
    end

    if not MedaAuras or not MedaAuras.GetActiveSettingsSelection then
        return false
    end

    local activeModuleId = MedaAuras:GetActiveSettingsSelection()
    if not activeModuleId then
        return false
    end

    if MedaAuras.GetCustomModuleKey then
        return activeModuleId == MedaAuras:GetCustomModuleKey(MODULE_ID)
    end

    return false
end

local function ShouldShowSettingsPreview()
    return IsSettingsPreviewVisible()
end

local function ShouldShowUnlockedPreview(db)
    return db and db.locked == false
end

local function ShouldShowAnyDisplay(db)
    return (db and db.enabled) or ShouldShowSettingsPreview() or ShouldShowUnlockedPreview(db)
end

RefreshRuntimeDisplay = function()
    local db = state.db
    local host = EnsureRuntimeHost()
    local showSettingsPreview = ShouldShowSettingsPreview()
    local showUnlockedPreview = ShouldShowUnlockedPreview(db)

    if not db or not ShouldShowAnyDisplay(db) then
        wipe(state.runtimeDisplays)
        host:Hide()
        host:SetScript("OnUpdate", nil)
        HideUnusedRuntimeWidgets(1)
        return
    end

    RefreshConfiguredSpells(db)

    local activeDisplays = {}
    local auraBySpellId = GetTrackedAuraMap()
    for _, entry in ipairs(state.trackedSpells) do
        local aura = auraBySpellId[entry.spellId]
        if aura then
            activeDisplays[#activeDisplays + 1] = {
                entry = entry,
                aura = aura,
            }
        end
    end

    if showSettingsPreview and #activeDisplays > 0 then
        state.runtimeDisplays = activeDisplays
    elseif db.enabled and #activeDisplays > 0 then
        state.runtimeDisplays = activeDisplays
    elseif showSettingsPreview then
        state.runtimeDisplays = {}
        if #state.trackedSpells == 0 then
            state.runtimeDisplays[1] = {
                entry = {
                    icon = DEFAULT_ICON,
                    name = "Preview",
                },
                placeholder = true,
                preview = true,
                previewTime = "12",
                previewStacks = 2,
            }
        else
            for _, entry in ipairs(state.trackedSpells) do
                state.runtimeDisplays[#state.runtimeDisplays + 1] = {
                    entry = entry,
                    preview = true,
                    previewTime = "12",
                    previewStacks = 2,
                }
            end
        end
    elseif showUnlockedPreview then
        state.runtimeDisplays = {}
        if #state.trackedSpells == 0 then
            state.runtimeDisplays[1] = {
                entry = {
                    icon = DEFAULT_ICON,
                    name = "Preview",
                },
                placeholder = true,
                preview = true,
                previewTime = "12",
                previewStacks = 2,
            }
        else
            for _, entry in ipairs(state.trackedSpells) do
                state.runtimeDisplays[#state.runtimeDisplays + 1] = {
                    entry = entry,
                    preview = true,
                    previewTime = "12",
                    previewStacks = 2,
                }
            end
        end
    else
        state.runtimeDisplays = activeDisplays
    end

    if #state.runtimeDisplays == 0 then
        host:Hide()
        host:SetScript("OnUpdate", nil)
        HideUnusedRuntimeWidgets(1)
        return
    end

    local size = math_max(24, tonumber(db.iconSize) or MODULE_DEFAULTS.iconSize)
    local width = (#state.runtimeDisplays * size) + (math_max(#state.runtimeDisplays - 1, 0) * ICON_SPACING)

    host:SetSize(width, size)
    ApplyRuntimePosition(db)
    host:Show()

    for index, display in ipairs(state.runtimeDisplays) do
        local widget = EnsureRuntimeWidget(index)
        widget:ClearAllPoints()
        widget:SetPoint("LEFT", host, "LEFT", (index - 1) * (size + ICON_SPACING), 0)
        ApplyDisplayToWidget(widget, display, db, size, display.preview and ((tonumber(db.iconAlpha) or 1) * 0.7) or nil)
    end

    HideUnusedRuntimeWidgets(#state.runtimeDisplays + 1)

    local hasTimer = false
    for _, display in ipairs(state.runtimeDisplays) do
        local aura = display.aura
        if aura and tonumber(aura.duration) and tonumber(aura.duration) > 0 and tonumber(aura.expirationTime) and tonumber(aura.expirationTime) > 0 then
            hasTimer = true
            break
        end
    end

    if not hasTimer then
        host:SetScript("OnUpdate", nil)
        return
    end

    host:SetScript("OnUpdate", function(_, elapsed)
        state.elapsed = state.elapsed + elapsed
        if state.elapsed < 0.05 then
            return
        end
        state.elapsed = 0

        local now = GetTime()
        for index, display in ipairs(state.runtimeDisplays) do
            if display.aura then
                local remaining = (tonumber(display.aura.expirationTime) or 0) - now
                if remaining <= 0 then
                    RefreshRuntimeDisplay()
                    return
                end
                local widget = state.runtimeWidgets[index]
                if widget then
                    widget.timeText:SetText(FormatRemaining(remaining))
                end
            end
        end
    end)
end

local function EnsureEventFrame()
    if state.eventFrame then
        return state.eventFrame
    end

    local frame = CreateFrame("Frame")
    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "DELVE_ASSIST_ACTION" then
            OnDelveAssistAction(...)
            RefreshRuntimeDisplay()
            return
        end

        local unit, updateInfo = ...
        if event == "UNIT_AURA" and unit ~= "player" then
            return
        end

        if event == "UNIT_AURA" then
            HandleProbeAuraUpdateInfo(updateInfo)
            SnapshotProbeAura("UNIT_AURA", false)
        elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_ENTERING_WORLD" then
            if event == "PLAYER_REGEN_ENABLED" then
                ReconcileProbeVisibleAura("PLAYER_REGEN_ENABLED")
                LogProbeCombatEndCompare("immediate")
                if C_Timer and C_Timer.After then
                    C_Timer.After(0.15, function()
                        ReconcileProbeVisibleAura("PLAYER_REGEN_ENABLED_DELAYED")
                        LogProbeCombatEndCompare("delayed")
                    end)
                end
            end
            if event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_ENTERING_WORLD" then
                state.probePartySourceName = nil
                state.probePartySourceUnit = nil
                state.probePartyStartedAt = 0
                state.probePartyLastActivityAt = 0
                state.probePartyLastSpellID = nil
                wipe(state.probePartySeenActivitySpells)
            end
            SnapshotProbeAura(event, true)
        end

        RefreshRuntimeDisplay()
    end)
    frame:SetScript("OnUpdate", function(_, elapsed)
        if not ShouldProbeAura() then
            state.probeElapsed = 0
            return
        end

        if not (InCombatLockdown and InCombatLockdown()) then
            state.probeElapsed = 0
            return
        end

        state.probeElapsed = state.probeElapsed + elapsed
        if state.probeElapsed < 0.2 then
            return
        end

        state.probeElapsed = 0
        ReconcileProbeVisibleAura("combat-poll")
        SnapshotProbeAura("combat-poll", false)
        RefreshRuntimeDisplay()
    end)
    state.eventFrame = frame
    return frame
end

local function RegisterEvents()
    local frame = EnsureEventFrame()
    if C_DelvesUI then
        frame:RegisterEvent("DELVE_ASSIST_ACTION")
    end
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    if frame.RegisterUnitEvent then
        local ok = pcall(frame.RegisterUnitEvent, frame, "UNIT_AURA", "player")
        if not ok then
            frame:RegisterEvent("UNIT_AURA")
        end
    else
        frame:RegisterEvent("UNIT_AURA")
    end
end

local function UnregisterEvents()
    if state.eventFrame then
        state.eventFrame:UnregisterAllEvents()
    end
end

local function OnInitialize(db)
    state.db = db
    RefreshConfiguredSpells(db)
    SyncAuraWatch()
    SyncPartySpellWatcher()
    EnsureRuntimeHost()
end

local function OnEnable(db)
    state.db = db
    RefreshConfiguredSpells(db)
    SyncAuraWatch()
    SyncPartySpellWatcher()
    RegisterEvents()
    RefreshRuntimeDisplay()
end

local function OnDisable()
    local watcher = GetPartySpellWatcher()
    if watcher and watcher.Unregister and state.partySpellHandle then
        watcher:Unregister(state.partySpellHandle)
        state.partySpellHandle = nil
    end
    if not ShouldShowSettingsPreview() then
        UnregisterEvents()
    end
    wipe(state.runtimeDisplays)
    if state.runtimeHost and not ShouldShowAnyDisplay(state.db) then
        state.runtimeHost:Hide()
        state.runtimeHost:SetScript("OnUpdate", nil)
    end
    HideUnusedRuntimeWidgets(1)
end

local function SetStatus(label, message, color)
    label:SetText(message or "")
    if color then
        label:SetTextColor(color[1], color[2], color[3])
    else
        label:SetTextColor(unpack(MedaUI.Theme.text))
    end
end

local function BuildConfig(parent, db)
    local LEFT_X = 0
    local RIGHT_X = 250
    local PREVIEW_WIDTH = 500
    local yOff = 0

    state.db = db
    state.configPreviewActive = true
    RefreshConfiguredSpells(db)
    SyncAuraWatch()
    SyncPartySpellWatcher()
    RegisterEvents()

    local cleanup = CreateFrame("Frame", nil, parent)
    cleanup:SetAllPoints(parent)
    cleanup:Show()
    cleanup:SetScript("OnHide", function()
        state.configPreviewActive = false
        if state.db and not state.db.enabled then
            UnregisterEvents()
        end
        RefreshRuntimeDisplay()
    end)
    if MedaAuras.RegisterConfigCleanup then
        MedaAuras:RegisterConfigCleanup(cleanup)
    end

    local title = MedaUI:CreateSectionHeader(parent, MODULE_NAME)
    title:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 40

    local summary = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    summary:SetPoint("TOPLEFT", LEFT_X, yOff)
    summary:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
    summary:SetJustifyH("LEFT")
    summary:SetWordWrap(true)
    summary:SetText("Enter one or more player buff spell IDs separated by commas or spaces. While this settings page is open, the icon group is always shown and can be dragged. When settings are closed, locked mode hides the group until one of the tracked buffs is actually active.")
    summary:SetTextColor(unpack(MedaUI.Theme.textDim or { 0.7, 0.7, 0.7, 1 }))
    yOff = yOff - summary:GetStringHeight() - 20

    local spellHeader = MedaUI:CreateSectionHeader(parent, "Tracked Spell IDs")
    spellHeader:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 36

    local spellInput = MedaUI:CreateEditBox(parent, 340, 24)
    spellInput:SetPoint("TOPLEFT", LEFT_X, yOff)
    spellInput:SetText(db.spellIdsText or "")

    local applyBtn = MedaUI:CreateButton(parent, "Apply", 90)
    applyBtn:SetPoint("LEFT", spellInput, "RIGHT", 10, 0)

    local statusText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("TOPLEFT", LEFT_X, yOff - 30)
    statusText:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
    statusText:SetJustifyH("LEFT")
    statusText:SetWordWrap(true)
    yOff = yOff - 66

    local previewHeader = MedaUI:CreateSectionHeader(parent, "Preview")
    previewHeader:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 34

    local previewHolder = CreateFrame("Frame", nil, parent)
    previewHolder:SetPoint("TOPLEFT", LEFT_X, yOff)
    previewHolder:SetSize(PREVIEW_WIDTH, 80)

    local previewWidgets = {}
    local previewCaptions = {}

    local function ReleasePreviewWidgets()
        for _, widget in ipairs(previewWidgets) do
            widget:Hide()
            widget:SetParent(nil)
        end
        wipe(previewWidgets)

        for _, caption in ipairs(previewCaptions) do
            caption:Hide()
            caption:SetParent(nil)
        end
        wipe(previewCaptions)
    end

    local appearanceHeader = MedaUI:CreateSectionHeader(parent, "Appearance")
    local lockCB = MedaUI:CreateCheckbox(parent, "Locked")
    local borderCB = MedaUI:CreateCheckbox(parent, "Show Border")
    local sizeSlider = MedaUI:CreateLabeledSlider(parent, "Icon Size", 200, 24, 120, 2)
    local textSlider = MedaUI:CreateLabeledSlider(parent, "Countdown Size", 200, 8, 36, 1)
    local alphaSlider = MedaUI:CreateLabeledSlider(parent, "Icon Alpha", 200, 10, 100, 5)
    local bgSlider = MedaUI:CreateLabeledSlider(parent, "Background Opacity", 200, 0, 100, 5)
    local borderPicker = MedaUI:CreateLabeledColorPicker(parent, "Border Color")
    local footerNote = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

    local function BuildPreviewDisplays()
        local displays = {}
        local auraBySpellId = GetTrackedAuraMap()

        if #state.trackedSpells == 0 then
            displays[1] = {
                entry = {
                    icon = DEFAULT_ICON,
                    name = "Preview",
                },
                placeholder = true,
                caption = "Add a spell ID",
                previewTime = "12",
                previewStacks = 2,
            }
            return displays
        end

        for _, entry in ipairs(state.trackedSpells) do
            displays[#displays + 1] = {
                entry = entry,
                aura = auraBySpellId[entry.spellId],
                caption = "#" .. tostring(entry.spellId),
                previewTime = "12",
                previewStacks = 2,
            }
        end

        return displays
    end

    local function RefreshAllVisuals()
        local displays = BuildPreviewDisplays()
        local previewSize = math_min(math_max(32, tonumber(db.iconSize) or MODULE_DEFAULTS.iconSize), 72)
        local cellHeight = previewSize + 18
        local columns = math_max(1, math_floor((PREVIEW_WIDTH + PREVIEW_SPACING) / (previewSize + PREVIEW_SPACING)))

        ReleasePreviewWidgets()

        for index, display in ipairs(displays) do
            local column = (index - 1) % columns
            local row = math_floor((index - 1) / columns)
            local x = column * (previewSize + PREVIEW_SPACING)
            local y = -(row * cellHeight)

            local widget = CreateIconWidget(previewHolder)
            widget:SetPoint("TOPLEFT", x, y)
            ApplyDisplayToWidget(widget, display, db, previewSize, display.aura and nil or ((tonumber(db.iconAlpha) or 1) * 0.85))
            previewWidgets[#previewWidgets + 1] = widget

            local caption = previewHolder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            caption:SetPoint("TOP", widget, "BOTTOM", 0, -4)
            caption:SetWidth(previewSize + 20)
            caption:SetJustifyH("CENTER")
            caption:SetWordWrap(false)
            caption:SetText(display.caption)
            caption:SetTextColor(unpack(MedaUI.Theme.textDim or { 0.7, 0.7, 0.7, 1 }))
            previewCaptions[#previewCaptions + 1] = caption
        end

        local rows = math_max(1, math_floor((#displays - 1) / columns) + 1)
        previewHolder:SetHeight(rows * cellHeight)

        appearanceHeader:SetPoint("TOPLEFT", previewHolder, "BOTTOMLEFT", 0, -20)
        lockCB:SetPoint("TOPLEFT", appearanceHeader, "BOTTOMLEFT", 0, -12)
        borderCB:SetPoint("TOPLEFT", appearanceHeader, "BOTTOMLEFT", RIGHT_X, -12)
        sizeSlider:SetPoint("TOPLEFT", lockCB, "BOTTOMLEFT", 0, -18)
        textSlider:SetPoint("TOPLEFT", borderCB, "BOTTOMLEFT", 0, -18)
        alphaSlider:SetPoint("TOPLEFT", sizeSlider, "BOTTOMLEFT", 0, -20)
        bgSlider:SetPoint("TOPLEFT", textSlider, "BOTTOMLEFT", 0, -20)
        borderPicker:SetPoint("TOPLEFT", alphaSlider, "BOTTOMLEFT", 0, -20)

        if #state.trackedSpells == 0 then
            SetStatus(statusText, "Add one or more spell IDs, then click Apply. A placeholder icon stays visible in the preview until then.", WARNING_COLOR)
        else
            local unresolved = 0
            for _, entry in ipairs(state.trackedSpells) do
                if not entry.resolved then
                    unresolved = unresolved + 1
                end
            end

            if unresolved > 0 then
                SetStatus(statusText, format("Saved %d spell ID(s). %d could not be resolved yet, but each buff will still track independently if WoW returns it at runtime.", #state.trackedSpells, unresolved), WARNING_COLOR)
            else
                SetStatus(statusText, format("Saved %d spell ID(s). Each configured buff now displays as its own icon instead of collapsing to one shared icon.", #state.trackedSpells), SUCCESS_COLOR)
            end
        end

        borderPicker:SetAlpha((db.showBorder == false) and 0.4 or 1)
        RefreshRuntimeDisplay()

        footerNote:SetPoint("TOPLEFT", bgSlider, "BOTTOMLEFT", 0, -26)
        footerNote:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
        footerNote:SetJustifyH("LEFT")
        footerNote:SetWordWrap(true)
        footerNote:SetText("Visibility rules: settings open always shows the group and allows dragging. Settings closed + unlocked keeps the preview visible. Settings closed + locked hides the group until a tracked buff is actually active on the player.")
        footerNote:SetTextColor(unpack(MedaUI.Theme.textDim or { 0.7, 0.7, 0.7, 1 }))

        local totalHeight = math_max(860, 760 + previewHolder:GetHeight() + footerNote:GetStringHeight())
        MedaAuras:SetContentHeight(totalHeight)
    end

    lockCB:SetChecked(db.locked ~= false)
    lockCB.OnValueChanged = function(_, checked)
        db.locked = checked
        RefreshAllVisuals()
    end

    borderCB:SetChecked(db.showBorder ~= false)
    borderCB.OnValueChanged = function(_, checked)
        db.showBorder = checked
        RefreshAllVisuals()
    end

    sizeSlider:SetValue(db.iconSize or MODULE_DEFAULTS.iconSize)
    sizeSlider.OnValueChanged = function(_, value)
        db.iconSize = value
        RefreshAllVisuals()
    end

    textSlider:SetValue(db.textSize or MODULE_DEFAULTS.textSize)
    textSlider.OnValueChanged = function(_, value)
        db.textSize = value
        RefreshAllVisuals()
    end

    alphaSlider:SetValue((db.iconAlpha or MODULE_DEFAULTS.iconAlpha) * 100)
    alphaSlider.OnValueChanged = function(_, value)
        db.iconAlpha = value / 100
        RefreshAllVisuals()
    end

    bgSlider:SetValue((db.backgroundOpacity or MODULE_DEFAULTS.backgroundOpacity) * 100)
    bgSlider.OnValueChanged = function(_, value)
        db.backgroundOpacity = value / 100
        RefreshAllVisuals()
    end

    do
        local borderColor = db.borderColor or MODULE_DEFAULTS.borderColor
        borderPicker:SetColor(
            borderColor.r or MODULE_DEFAULTS.borderColor.r,
            borderColor.g or MODULE_DEFAULTS.borderColor.g,
            borderColor.b or MODULE_DEFAULTS.borderColor.b
        )
    end
    borderPicker.OnColorChanged = function(_, r, g, b)
        db.borderColor = { r = r, g = g, b = b }
        RefreshAllVisuals()
    end

    local function ApplySpellInput(text)
        db.spellIds = ParseSpellIds(text)
        db.spellIdsText = BuildSpellText(db.spellIds)
        spellInput:SetText(db.spellIdsText)
        RefreshConfiguredSpells(db)
        SyncAuraWatch()
        RefreshAllVisuals()
    end

    applyBtn:SetScript("OnClick", function()
        ApplySpellInput(spellInput:GetText())
    end)

    spellInput.OnEnterPressed = function(_, text)
        ApplySpellInput(text)
    end

    RefreshAllVisuals()
end

MedaAuras:RegisterCustomModule({
    moduleId = MODULE_ID,
    name = MODULE_NAME,
    title = MODULE_NAME,
    version = MODULE_VERSION,
    author = MODULE_AUTHOR,
    description = MODULE_DESCRIPTION,
    dataVersion = 1,
    stability = "stable",
    sidebarDesc = "Tracks configured player buffs and shows one draggable icon per active buff.",
    defaults = MODULE_DEFAULTS,
    OnInitialize = OnInitialize,
    OnEnable = OnEnable,
    OnDisable = OnDisable,
    BuildConfig = BuildConfig,
})
