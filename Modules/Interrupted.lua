local ADDON_NAME, ns = ...

local MedaUI = LibStub("MedaUI-2.0")

local format = format
local GetTime = GetTime
local pairs = pairs
local ipairs = ipairs
local wipe = wipe
local pcall = pcall
local unpack = unpack
local CreateFrame = CreateFrame
local CreateFont = CreateFont
local GetSpellBaseCooldown = GetSpellBaseCooldown
local UnitName = UnitName
local UnitClass = UnitClass
local UnitGUID = UnitGUID
local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local UnitExists = UnitExists
local IsInGroup = IsInGroup
local IsPlayerSpell = IsPlayerSpell
local IsSpellKnown = IsSpellKnown
local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo
local C_Spell = C_Spell
local C_Timer = C_Timer

if MedaAuras and MedaAuras.Log then
    MedaAuras.Log("[Interrupted] File loaded OK")
end

-- ============================================================================
-- Module Info
-- ============================================================================

local MODULE_NAME      = "Interrupted"
local MODULE_VERSION   = "0.1"
local MODULE_STABILITY = "experimental"

-- ============================================================================
-- Shared Data
-- ============================================================================

local ID = ns.InterruptData
local StopData = ns.StopData
local ALL_INTERRUPTS      = ID.ALL_INTERRUPTS
local CD_REDUCTION_TALENTS = ID.CD_REDUCTION_TALENTS
local CD_ON_KICK_TALENTS  = ID.CD_ON_KICK_TALENTS
local SPELL_ALIASES       = ID.SPELL_ALIASES
local CLASS_COLORS        = ID.CLASS_COLORS
local InterruptResolver   = ns.Services and ns.Services.InterruptResolver

local FALLBACK_WHITE = { 1, 1, 1 }
local FALLBACK_INTERRUPT_ICON = 134400
local OUTLINE_MAP = { none = "", outline = "OUTLINE", thick = "THICKOUTLINE" }

-- ============================================================================
-- State
-- ============================================================================

local db
local partyMembers = {}     -- [name] = { class, spellID, baseCd, cdEnd, onKickReduction, extraKicks }
local partyStopMembers = {} -- [name] = { class, stops = { [spellID] = stopInfo } }
local noInterruptPlayers = {} -- [name] = true
local myName, myClass, mySpellID, myBaseCd, myIsPetSpell
local myKickCdEnd = 0
local myStops = {}          -- [spellID] = stopInfo

local mainFrame, titleText, resizeHandle
local stunFrame, stunTitleText, stunResizeHandle
local bars = {}
local stunBars = {}
local updateTicker
local isResizing = false
local shouldShowByZone = true
local hasVisibleEntries = false
local hasVisibleStunEntries = false
local watcherHandle, mobKickHandle, stopWatcherHandle
local UpdateDisplay
local AutoRegisterParty, CleanPartyList
local stopCombatFrame
local stopCombatUsesCallbackEvent = false

local DEFAULT_FONT_FACE = GameFontNormal and GameFontNormal:GetFont() or "Fonts\\FRIZQT__.TTF"
local FONT_FLAGS = "OUTLINE"
local BAR_TEXTURE = "Interface\\BUTTONS\\WHITE8X8"
local fontCache = {}

-- ============================================================================
-- Logging
-- ============================================================================

local function Log(msg)   MedaAuras.Log(format("[Interrupted] %s", msg)) end
local function LogDebug(msg) MedaAuras.LogDebug(format("[Interrupted] %s", msg)) end
local function LogWarn(msg)  MedaAuras.LogWarn(format("[Interrupted] %s", msg)) end

local function UpdateMainFrameVisibility()
    if mainFrame then
        if shouldShowByZone and hasVisibleEntries then
            mainFrame:Show()
        else
            mainFrame:Hide()
        end
    end

    if stunFrame then
        if shouldShowByZone and db and db.splitStunsToSeparateWindow and hasVisibleStunEntries then
            stunFrame:Show()
        else
            stunFrame:Hide()
        end
    end
end

local function GetFontObj(fontValue, size, outline)
    local path = MedaUI:GetFontPath(fontValue)
    local flags = OUTLINE_MAP[outline] or outline or FONT_FLAGS
    local key = (path or "default") .. "_" .. tostring(size) .. "_" .. flags
    if fontCache[key] then return fontCache[key] end

    local fontObject = CreateFont("MedaAurasInterrupted_" .. key:gsub("[^%w]", "_"))
    if path then
        fontObject:SetFont(path, size, flags)
    else
        fontObject:CopyFontObject(GameFontNormal)
        local basePath = select(1, fontObject:GetFont()) or DEFAULT_FONT_FACE
        fontObject:SetFont(basePath, size, flags)
    end

    fontCache[key] = fontObject
    return fontObject
end

local function GetSpellCooldownRemaining(spellID)
    local cdInfo = C_Spell.GetSpellCooldown(spellID)
    if cdInfo and cdInfo.startTime and cdInfo.duration and cdInfo.duration > 0 then
        return (cdInfo.startTime + cdInfo.duration) - GetTime()
    end
    return nil
end

local function GetCachedSpecID(unit)
    local inspector = ns.Services and ns.Services.GroupInspector
    if not inspector or not inspector.GetUnitInfo then return nil end

    local info = inspector:GetUnitInfo(unit)
    return info and info.specID or nil
end

local function IsKnownPlayerSpell(spellID)
    if not spellID then return false end

    local ok, known = pcall(IsPlayerSpell, spellID)
    if ok and known then
        return true
    end

    local ok2, known2 = pcall(IsSpellKnown, spellID, true)
    if ok2 and known2 then
        return true
    end

    local ok3, known3 = pcall(IsSpellKnown, spellID)
    return ok3 and known3 or false
end

local function GetStopRecord(spellID)
    if not StopData or not StopData.GetStop then
        return nil
    end
    return StopData:GetStop(spellID)
end

local function IsStunCategory(category)
    return category == "stun"
end

local HARD_CC_CATEGORIES = {
    stun = true,
    fear = true,
    disorient = true,
    incap = true,
    horror = true,
    sleep = true,
}

local function IsHardCCCategory(category)
    return HARD_CC_CATEGORIES[category] == true
end

local function ShouldHideStopCategory(category)
    return db and db.hideHardCC == true and IsHardCCCategory(category)
end

local function GetStopBaseCooldown(stopInfo)
    if not stopInfo then return 0 end
    return stopInfo.baseCd or stopInfo.cd or stopInfo.baseCD or 0
end

local function ResolveStopRecord(spellID, classToken)
    local direct = GetStopRecord(spellID)
    if direct then
        return direct, spellID
    end

    if not spellID or not classToken or not StopData or not StopData.GetClassStops then
        return nil, nil
    end

    local spellInfo = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID) or nil
    local spellName = spellInfo and spellInfo.name or nil
    if not spellName or spellName == "" then
        return nil, nil
    end

    local classLookup = StopData:GetClassStops(classToken)
    for knownSpellID, stopData in pairs(classLookup or {}) do
        if stopData and stopData.name == spellName then
            return stopData, knownSpellID
        end
    end

    return nil, nil
end

local function EnsurePartyStopMember(name, classToken)
    local info = partyStopMembers[name]
    if not info then
        info = {
            class = classToken,
            stops = {},
        }
        partyStopMembers[name] = info
    end

    if classToken then
        info.class = classToken
    end

    if not info.stops then
        info.stops = {}
    end

    return info
end

local function EnsureStopEntry(stopMap, stopData, ownerClass, defaultRegistered)
    if not stopMap or not stopData then return nil end

    local spellID = stopData.spellID or stopData.id
    if not spellID then return nil end

    local info = stopMap[spellID]
    if not info then
        info = {
            spellID = spellID,
            cdEnd = 0,
        }
        stopMap[spellID] = info
    end

    info.class = ownerClass or info.class or stopData.class
    info.category = stopData.category or info.category or "stop"
    info.spellName = stopData.name or info.spellName or ("Spell " .. tostring(spellID))
    info.baseCd = GetStopBaseCooldown(stopData)
    info.icon = stopData.icon or info.icon or FALLBACK_INTERRUPT_ICON
    info.cooldownSpellID = info.cooldownSpellID or spellID
    info.talentCheck = stopData.talentCheck or info.talentCheck
    if defaultRegistered ~= nil then
        info.defaultRegistered = defaultRegistered
    end

    return info
end

local function ApplyStopCooldownStamp(stopInfo, baseCd, observedSpellID, now)
    if not stopInfo then
        return false
    end

    local stampTime = now or GetTime()
    if stopInfo.lastUse and (stampTime - stopInfo.lastUse) < 0.2 then
        return false
    end

    stopInfo.baseCd = baseCd or stopInfo.baseCd or 0
    stopInfo.cooldownSpellID = observedSpellID or stopInfo.cooldownSpellID or stopInfo.spellID
    stopInfo.cdEnd = stampTime + (stopInfo.baseCd or 0)
    stopInfo.lastUse = stampTime
    return true
end

local function SyncPartyStopsForMember(unit, name, classToken, specID)
    if not StopData or not StopData.GetDefaultStopsForSpec or not name or not classToken then
        return
    end

    local member = EnsurePartyStopMember(name, classToken)
    member.unit = unit
    member.specID = specID

    local defaults = StopData:GetDefaultStopsForSpec(specID, classToken)
    if not defaults or #defaults == 0 then
        return
    end

    local inspector = ns.Services and ns.Services.GroupInspector
    local unitInfo = inspector and inspector.GetUnitInfo and inspector:GetUnitInfo(unit) or nil
    local talentsKnown = unitInfo and unitInfo.talentsKnown
    local keep = {}

    for _, stopData in ipairs(defaults) do
        local spellID = stopData.spellID or stopData.id
        local allowed = true
        if talentsKnown and stopData.talentCheck then
            allowed = inspector and inspector.UnitHasTalentSpell
                and inspector:UnitHasTalentSpell(unit, stopData.talentCheck) or false
        end

        if allowed and spellID then
            keep[spellID] = true
            EnsureStopEntry(member.stops, stopData, classToken, true)
        end
    end

    if talentsKnown then
        for spellID, stopInfo in pairs(member.stops) do
            if stopInfo.defaultRegistered and stopInfo.talentCheck and not keep[spellID] and (stopInfo.cdEnd or 0) <= GetTime() then
                member.stops[spellID] = nil
            end
        end
    end
end

local function ApplyInterruptEntry(info, classToken, entry)
    if not info or not entry then return false end

    local spellID = entry.spellID or entry.id
    local baseCd = entry.baseCD or entry.cd or 15
    local isPetSpell = entry.pet or false
    local changed = info.class ~= classToken
        or info.spellID ~= spellID
        or info.baseCd ~= baseCd
        or info.isPetSpell ~= isPetSpell

    info.class = classToken
    info.spellID = spellID
    info.spellName = entry.name or (spellID and ALL_INTERRUPTS[spellID] and ALL_INTERRUPTS[spellID].name) or "Interrupt"
    info.baseCd = baseCd
    info.isPetSpell = isPetSpell

    return changed
end

local function TrackPartyMember(name, classToken, entry)
    local info = partyMembers[name]
    if not info then
        info = { cdEnd = 0 }
        partyMembers[name] = info
    end

    local changed = ApplyInterruptEntry(info, classToken, entry)
    noInterruptPlayers[name] = nil
    return info, changed
end

local function GetRenderableInterruptData(info)
    if not info then return nil end

    local spellID = info.spellID
    local data = spellID and ALL_INTERRUPTS[spellID] or nil
    if not data and spellID then
        local aliased = SPELL_ALIASES[spellID]
        data = aliased and ALL_INTERRUPTS[aliased] or nil
    end

    if data then
        return {
            name = data.name,
            cd = info.baseCd or data.cd or 15,
            icon = data.icon or FALLBACK_INTERRUPT_ICON,
        }
    end

    if spellID or info.baseCd or info.spellName then
        return {
            name = info.spellName or (spellID and ("Spell " .. spellID)) or "Interrupt",
            cd = info.baseCd or 15,
            icon = FALLBACK_INTERRUPT_ICON,
        }
    end

    return nil
end

local function NormalizeRemainingCooldown(rem)
    if not rem or rem <= 0.5 then return 0 end
    return rem
end

local function RequestInspectorRescan()
    local inspector = ns.Services and ns.Services.GroupInspector
    if not inspector then return end

    Log("Manual group rescan requested")
    inspector:RequestReinspectAll()
    CleanPartyList()
    AutoRegisterParty()
    UpdateDisplay()
end

local function GetPartyCooldownRemaining(info, now)
    if not info or not now then return 0 end
    if info.cdEnd and info.cdEnd > now then
        return NormalizeRemainingCooldown(info.cdEnd - now)
    end
    return 0
end

local function GetPlayerCooldownRemaining(now)
    if not now or not mySpellID then return 0 end

    local rem = 0
    if myKickCdEnd > now then
        rem = myKickCdEnd - now
        if not myIsPetSpell then
            local ok, result = pcall(GetSpellCooldownRemaining, mySpellID)
            if ok and result and result > 0 then
                rem = result
            end
        end
    end

    return NormalizeRemainingCooldown(rem)
end

local function GetStopCooldownRemaining(stopInfo, now, readLiveCooldown)
    if not stopInfo or not now then return 0 end

    local rem = 0
    if stopInfo.cdEnd and stopInfo.cdEnd > now then
        rem = stopInfo.cdEnd - now
    end

    local cooldownSpellID = stopInfo.cooldownSpellID or stopInfo.spellID
    if readLiveCooldown and cooldownSpellID and IsKnownPlayerSpell(cooldownSpellID) then
        local ok, result = pcall(GetSpellCooldownRemaining, cooldownSpellID)
        if ok and result and result > 0 then
            rem = result
        end
    end

    return NormalizeRemainingCooldown(rem)
end

local function BuildAbilityLabel(ownerName, abilityName)
    local cleanOwner = ownerName or "?"
    local cleanAbility = abilityName or "Stop"
    return format("%s - %s", cleanOwner, cleanAbility)
end

local function BuildDisplayEntry(ownerName, classToken, abilityName, icon, baseCd, remaining, isPlayer, kind, category)
    return {
        name = ownerName or "?",
        label = BuildAbilityLabel(ownerName, abilityName),
        info = {
            class = classToken,
            baseCd = baseCd or 0,
        },
        data = {
            name = abilityName or "Stop",
            icon = icon or FALLBACK_INTERRUPT_ICON,
            cd = baseCd or 0,
        },
        remaining = remaining or 0,
        isPlayer = isPlayer == true,
        kind = kind or "stop",
        category = category,
    }
end

local function SortByNextAvailable(entries)
    table.sort(entries, function(a, b)
        if a.remaining ~= b.remaining then
            return a.remaining < b.remaining
        end

        if a.isPlayer ~= b.isPlayer then
            return a.isPlayer and not b.isPlayer
        end

        if a.name ~= b.name then
            return a.name < b.name
        end

        return (a.data and a.data.name or "") < (b.data and b.data.name or "")
    end)
end

local function GetRenderablePartyInterruptEntries(now)
    local entries = {}
    for name, info in pairs(partyMembers) do
        local data = GetRenderableInterruptData(info)
        if data then
            entries[#entries + 1] = {
                name = name,
                label = BuildAbilityLabel(name, data.name),
                info = info,
                data = data,
                remaining = GetPartyCooldownRemaining(info, now or GetTime()),
                kind = "interrupt",
                category = "interrupt",
            }
        end
    end

    if db and db.sortByNextAvailable ~= false then
        SortByNextAvailable(entries)
    else
        table.sort(entries, function(a, b)
            return a.name < b.name
        end)
    end

    return entries
end

local function GetRenderablePlayerStopEntries(now)
    local entries = {}
    for spellID, stopInfo in pairs(myStops) do
        local stopData = GetStopRecord(spellID)
        local abilityName = (stopData and stopData.name) or stopInfo.spellName
        local icon = (stopData and stopData.icon) or stopInfo.icon
        local baseCd = (stopData and stopData.cd) or stopInfo.baseCd or 0
        entries[#entries + 1] = BuildDisplayEntry(
            myName or "?",
            myClass,
            abilityName,
            icon,
            baseCd,
            GetStopCooldownRemaining(stopInfo, now, true),
            true,
            "stop",
            stopInfo.category
        )
    end
    return entries
end

local function GetRenderablePartyStopEntries(now)
    local entries = {}
    for name, member in pairs(partyStopMembers) do
        for spellID, stopInfo in pairs(member.stops or {}) do
            local stopData = GetStopRecord(spellID)
            local abilityName = (stopData and stopData.name) or stopInfo.spellName
            local icon = (stopData and stopData.icon) or stopInfo.icon
            local baseCd = (stopData and stopData.cd) or stopInfo.baseCd or 0
            entries[#entries + 1] = BuildDisplayEntry(
                name,
                member.class or stopInfo.class,
                abilityName,
                icon,
                baseCd,
                GetStopCooldownRemaining(stopInfo, now, false),
                false,
                "stop",
                stopInfo.category
            )
        end
    end
    return entries
end

local function GetDisplayEntries(now)
    local entries = {}
    local playerData = mySpellID and ALL_INTERRUPTS[mySpellID]

    if playerData then
        entries[#entries + 1] = BuildDisplayEntry(
            myName or "?",
            myClass,
            playerData.name,
            playerData.icon,
            myBaseCd or playerData.cd,
            GetPlayerCooldownRemaining(now),
            true,
            "interrupt",
            "interrupt"
        )
    end

    local playerStops = GetRenderablePlayerStopEntries(now)
    for _, entry in ipairs(playerStops) do
        if not ShouldHideStopCategory(entry.category)
            and not (db and db.splitStunsToSeparateWindow and IsStunCategory(entry.category)) then
            entries[#entries + 1] = entry
        end
    end

    local renderablePartyEntries = GetRenderablePartyInterruptEntries(now)
    for _, entry in ipairs(renderablePartyEntries) do
        entries[#entries + 1] = entry
    end

    local partyStops = GetRenderablePartyStopEntries(now)
    for _, entry in ipairs(partyStops) do
        if not ShouldHideStopCategory(entry.category)
            and not (db and db.splitStunsToSeparateWindow and IsStunCategory(entry.category)) then
            entries[#entries + 1] = entry
        end
    end

    if db and db.sortByNextAvailable ~= false then
        SortByNextAvailable(entries)
    end

    return entries
end

local function GetStunDisplayEntries(now)
    local entries = {}
    if not (db and db.splitStunsToSeparateWindow) or ShouldHideStopCategory("stun") then
        return entries
    end

    for _, entry in ipairs(GetRenderablePlayerStopEntries(now)) do
        if IsStunCategory(entry.category) then
            entries[#entries + 1] = entry
        end
    end

    for _, entry in ipairs(GetRenderablePartyStopEntries(now)) do
        if IsStunCategory(entry.category) then
            entries[#entries + 1] = entry
        end
    end

    if db.sortByNextAvailable ~= false then
        SortByNextAvailable(entries)
    end

    return entries
end

local function GetReadyDisplayText(baseCd)
    if db and db.showBaseCooldownWhenReady then
        return format("%ds", baseCd or 0)
    end

    if db and db.showReady then
        return "READY"
    end

    return ""
end

local function ResolveBarColor(classToken)
    if db and db.barColorMode == "custom" then
        local custom = db.customBarColor or FALLBACK_WHITE
        return custom[1] or 1, custom[2] or 1, custom[3] or 1
    end

    local classColor = CLASS_COLORS[classToken] or FALLBACK_WHITE
    return classColor[1], classColor[2], classColor[3]
end

local function ResolveNameColor(isPlayer, classToken)
    if isPlayer and db and db.playerNameColorMode == "custom" then
        local custom = db.customPlayerNameColor or FALLBACK_WHITE
        return custom[1] or 1, custom[2] or 1, custom[3] or 1
    end

    if isPlayer and db and db.playerNameColorMode == "class" then
        local classColor = CLASS_COLORS[classToken] or FALLBACK_WHITE
        return classColor[1], classColor[2], classColor[3]
    end

    return 1, 1, 1
end

local function ApplyBarVisuals(bar, entryName, classToken, icon, maxCd, remaining, isPlayer, nameFontSize, cdFontSize)
    if not bar then return end

    local barR, barG, barB = ResolveBarColor(classToken)
    local nameR, nameG, nameB = ResolveNameColor(isPlayer, classToken)
    local nameOutline = isPlayer and (db.playerNameOutline or "outline") or "outline"
    local rem = remaining or 0
    local cooldown = maxCd or 15

    bar.icon:SetTexture(icon or FALLBACK_INTERRUPT_ICON)
    bar.nameText:SetFontObject(GetFontObj(db.font or "default", nameFontSize, nameOutline))
    bar.nameText:SetText(entryName or "")
    bar.nameText:SetTextColor(nameR, nameG, nameB)
    bar.cdText:SetFontObject(GetFontObj(db.font or "default", cdFontSize, "outline"))
    bar.cdBar:SetMinMaxValues(0, cooldown)

    if rem > 0 then
        bar.cdBar:SetValue(rem)
        bar.cdBar:SetStatusBarColor(barR, barG, barB, 0.85)
        bar.barBg:SetVertexColor(barR * 0.25, barG * 0.25, barB * 0.25, 0.9)
        bar.cdText:SetText(string.format("%.0f", rem))
        bar.cdText:SetTextColor(1, 1, 1)
    else
        bar.cdBar:SetValue(0)
        bar.barBg:SetVertexColor(barR, barG, barB, 0.85)
        bar.cdText:SetText(GetReadyDisplayText(cooldown))
        bar.cdText:SetTextColor(0.2, 1.0, 0.2)
    end
end

local function GetDetectedPlayerInterrupts()
    if not InterruptResolver or not InterruptResolver.GetAvailablePlayerInterrupts then
        return {}
    end

    local available = InterruptResolver:GetAvailablePlayerInterrupts()
    local detected = {}
    for _, entry in ipairs(available or {}) do
        local spellID = entry.spellID or entry.id
        local data = spellID and ALL_INTERRUPTS[spellID] or nil
        detected[#detected + 1] = {
            spellID = spellID,
            name = entry.name or (data and data.name) or "Interrupt",
            cd = entry.baseCD or entry.cd or (data and data.cd) or 0,
            icon = (data and data.icon) or FALLBACK_INTERRUPT_ICON,
            pet = entry.pet or false,
        }
    end

    return detected
end

local function GetDetectedPlayerStops()
    if not StopData or not StopData.GetAllPlayerStopCandidates then
        return {}
    end

    local detected = {}
    local seen = {}
    local specIndex = GetSpecialization()
    local specID = specIndex and GetSpecializationInfo(specIndex)
    local candidates = StopData:GetAllPlayerStopCandidates(myClass or select(2, UnitClass("player")), specID)

    for _, entry in ipairs(candidates or {}) do
        local spellID = entry.spellID or entry.id
        if spellID and not seen[spellID] and IsKnownPlayerSpell(spellID) then
            seen[spellID] = true
            detected[#detected + 1] = {
                spellID = spellID,
                name = entry.name or ("Spell " .. tostring(spellID)),
                cd = entry.cd or entry.baseCD or 0,
                icon = entry.icon or FALLBACK_INTERRUPT_ICON,
                category = entry.category or "stop",
            }
        end
    end

    return detected
end

local function SyncKnownPlayerStops()
    local seen = {}
    for _, entry in ipairs(GetDetectedPlayerStops()) do
        seen[entry.spellID] = true
        EnsureStopEntry(myStops, entry, myClass, true)
    end

    local now = GetTime()
    for spellID, stopInfo in pairs(myStops) do
        if not seen[spellID] and (stopInfo.cdEnd or 0) <= now then
            myStops[spellID] = nil
        end
    end
end

-- ============================================================================
-- Find own interrupt spell
-- ============================================================================

local function FindMyInterrupt()
    local _, cls = UnitClass("player")
    myClass = cls
    myName = UnitName("player")

    LogDebug(format("FindMyInterrupt: class=%s name=%s", tostring(cls), tostring(myName)))

    local specIndex = GetSpecialization()
    local specID = specIndex and GetSpecializationInfo(specIndex)
    LogDebug(format("  specIndex=%s specID=%s", tostring(specIndex), tostring(specID)))

    mySpellID = nil
    myBaseCd = nil
    myIsPetSpell = false
    wipe(myStops)

    if not InterruptResolver then
        LogWarn("InterruptResolver unavailable; player interrupt cannot be resolved")
        SyncKnownPlayerStops()
        return
    end

    local entry = InterruptResolver:ResolvePlayerInterrupt()
    if not entry then
        local specData = specID and ID:GetSpecData(specID) or nil
        if specData and specData.hasInterrupt == false then
            LogDebug(format("  specID %d has no interrupt", specID))
        end
        SyncKnownPlayerStops()
        return
    end

    mySpellID = entry.spellID
    myBaseCd = entry.baseCD or entry.cd
    myIsPetSpell = entry.pet or false

    if mySpellID then
        local ok, ms = pcall(GetSpellBaseCooldown, mySpellID)
        LogDebug(format("  GetSpellBaseCooldown(%d): ok=%s ms=%s", mySpellID, tostring(ok), tostring(ms)))
        if ok and ms and ms > 1500 then
            myBaseCd = ms / 1000
        end
    end

    Log(format("FindMyInterrupt result: %s (ID %s, CD %ss, pet=%s)",
        mySpellID and ALL_INTERRUPTS[mySpellID] and ALL_INTERRUPTS[mySpellID].name or "NONE",
        tostring(mySpellID), tostring(myBaseCd), tostring(myIsPetSpell)))

    SyncKnownPlayerStops()
end

-- ============================================================================
-- Auto-register party members by class
-- ============================================================================

AutoRegisterParty = function()
    LogDebug(format("AutoRegisterParty: inGroup=%s", tostring(IsInGroup())))
    for i = 1, 4 do
        local u = "party" .. i
        local exists = UnitExists(u)
        if exists then
            local name = UnitName(u)
            local _, cls = UnitClass(u)
            local role = UnitGroupRolesAssigned(u)
            local specID = GetCachedSpecID(u)
            local entry, source
            if InterruptResolver then
                entry, source = InterruptResolver:ResolvePartyPrimaryInterrupt(cls, specID, role)
            end
            local hasDefault = entry ~= nil or source == "spec_no_interrupt" or source == "role_no_interrupt"
            LogDebug(format("  %s: name=%s class=%s role=%s hasDefault=%s already=%s noKick=%s",
                u, tostring(name), tostring(cls), tostring(role),
                tostring(hasDefault),
                tostring(name and partyMembers[name] ~= nil),
                tostring(name and noInterruptPlayers[name] ~= nil)))
            if name and cls then
                SyncPartyStopsForMember(u, name, cls, specID)
                if source == "spec_no_interrupt" or source == "role_no_interrupt" then
                    partyMembers[name] = nil
                    noInterruptPlayers[name] = true
                    LogDebug(format("    -> %s has no interrupt (%s)", name, source))
                elseif entry then
                    local _, changed = TrackPartyMember(name, cls, entry)
                    if changed then
                        Log(format("Auto-registered %s (%s) %s CD=%d [%s]",
                            name, cls, entry.name, entry.baseCD or entry.cd or 15, source))
                    end
                else
                    noInterruptPlayers[name] = nil
                    LogDebug(format("    -> waiting for exact interrupt data for %s (%s)", name, cls))
                end
            end
        else
            LogDebug(format("  %s: does not exist", u))
        end
    end

    local count = 0
    for _ in pairs(partyMembers) do count = count + 1 end
    LogDebug(format("  Total tracked: %d party members, %d no-kick",
        count, (function() local n=0 for _ in pairs(noInterruptPlayers) do n=n+1 end return n end)()))
    UpdateDisplay()
end

CleanPartyList = function()
    local current = {}
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) then current[UnitName(u)] = true end
    end
    local removed = 0
    for name in pairs(partyMembers) do
        if not current[name] then
            partyMembers[name] = nil
            removed = removed + 1
            LogDebug(format("CleanPartyList: removed %s (left group)", name))
        end
    end
    for name in pairs(partyStopMembers) do
        if not current[name] then
            partyStopMembers[name] = nil
        end
    end
    for name in pairs(noInterruptPlayers) do
        if not current[name] then noInterruptPlayers[name] = nil end
    end
    if removed > 0 then
        LogDebug(format("CleanPartyList: removed %d member(s)", removed))
    end
    UpdateDisplay()
end

-- ============================================================================
-- Talent-aware interrupt tuning from GroupInspector cache
-- ============================================================================

local function ApplyTalentModifiersForMember(unit, name, class, specID)
    LogDebug(format("ApplyTalentModifiersForMember: unit=%s name=%s class=%s specID=%s",
        tostring(unit), tostring(name), tostring(class), tostring(specID)))

    SyncPartyStopsForMember(unit, name, class, specID)

    if not InterruptResolver then
        LogWarn("InterruptResolver unavailable during talent scan")
        return
    end

    local primary, source = InterruptResolver:ResolvePartyPrimaryInterrupt(class, specID)
    if source == "spec_no_interrupt" or not primary then
        partyMembers[name] = nil
        noInterruptPlayers[name] = true
        LogDebug(format("%s has no interrupt (specID=%d), removed", name, specID or -1))
        UpdateDisplay()
        return
    end

    local info = TrackPartyMember(name, class, primary)
    info.onKickReduction = nil

    local inspector = ns.Services and ns.Services.GroupInspector
    local unitInfo = inspector and inspector.GetUnitInfo and inspector:GetUnitInfo(unit) or nil
    if not unitInfo or not unitInfo.talentsKnown then
        LogDebug("  -> No inspected talent cache available, skipping talent modifiers")
        return
    end

    for spellID, talent in pairs(CD_REDUCTION_TALENTS) do
        if inspector:UnitHasTalentSpell(unit, spellID) then
            local newCd
            if talent.pctReduction then
                newCd = info.baseCd * (1 - talent.pctReduction / 100)
                newCd = math.floor(newCd + 0.5)
            else
                newCd = info.baseCd - talent.reduction
            end
            if newCd < 1 then newCd = 1 end
            info.baseCd = newCd
            LogDebug(format("%s has %s, CD -> %ds", name, talent.name, newCd))
        end
    end

    for spellID, onKick in pairs(CD_ON_KICK_TALENTS) do
        if inspector:UnitHasTalentSpell(unit, spellID) then
            info.onKickReduction = onKick.reduction
            LogDebug(format("%s has %s, -%ds on kick", name, onKick.name, onKick.reduction))
        end
    end

    UpdateDisplay()
end

-- ============================================================================
-- Handle party interrupt cast detected (from PartySpellWatcher)
-- ============================================================================

local function OnPartyInterruptDetected(name, spellID, unit)
    local resolvedID = SPELL_ALIASES[spellID] or spellID
    local now = GetTime()

    Log(format("PARTY INTERRUPT CALLBACK: name=%s spellID=%s resolved=%s unit=%s",
        tostring(name), tostring(spellID), tostring(resolvedID), tostring(unit)))

    local info = partyMembers[name]
    if info then
        local baseCd = info.baseCd or (ALL_INTERRUPTS[resolvedID] and ALL_INTERRUPTS[resolvedID].cd) or 15
        info.cdEnd = now + baseCd
        info.lastKickTime = now
        Log(format("  -> %s existing member, CD set to %ds (ends at %.1f)", name, baseCd, info.cdEnd))
    else
        if noInterruptPlayers[name] then
            LogDebug(format("  -> %s was marked no-kick, clearing due to observed interrupt", name))
            noInterruptPlayers[name] = nil
        end
        local ok, _, cls = pcall(UnitClass, unit)
        local role = UnitGroupRolesAssigned(unit)
        local specID = GetCachedSpecID(unit)
        local expected
        if InterruptResolver then
            expected = InterruptResolver:ResolvePartyPrimaryInterrupt(cls, specID, role)
        end
        LogDebug(format("  -> %s not in partyMembers, UnitClass(%s): ok=%s cls=%s",
            name, tostring(unit), tostring(ok), tostring(cls)))
        if ok and cls then
            local kickData = ALL_INTERRUPTS[resolvedID]
            if not kickData then
                LogWarn(format("  -> Could not register %s: spell %s not in interrupt data", name, tostring(resolvedID)))
                return
            end

            local newInfo = partyMembers[name] or {}
            local baseCd = expected and (expected.baseCD or expected.cd) or kickData.cd or 15
            ApplyInterruptEntry(newInfo, cls, {
                spellID = resolvedID,
                baseCD = baseCd,
                pet = expected and expected.pet or false,
            })
            newInfo.cdEnd = now + baseCd
            newInfo.lastKickTime = now
            partyMembers[name] = newInfo
            Log(format("  -> Late-registered %s (%s) from cast, CD=%d",
                name, cls, baseCd))
        else
            LogWarn(format("  -> Could not register %s: UnitClass failed", name))
        end
    end
    UpdateDisplay()
end

local function ResolveStopCandidates(name, unit)
    if not StopData or not StopData.GetClassStops then
        return nil
    end

    local classToken = name and partyStopMembers[name] and partyStopMembers[name].class or nil
    if not classToken and unit and UnitExists(unit) then
        classToken = select(2, UnitClass(unit))
    end
    if not classToken then
        return nil
    end

    local lookupTable, knownIDs = StopData:GetClassStops(classToken)
    return {
        lookupTable = lookupTable,
        knownIDs = knownIDs,
        label = format("%s:stops", tostring(classToken)),
    }
end

local function OnPartyStopDetected(name, spellID, stopData, unit, debugInfo)
    if not stopData then
        return
    end

    local now = GetTime()
    local classToken = name and partyStopMembers[name] and partyStopMembers[name].class or nil
    if not classToken and unit and UnitExists(unit) then
        classToken = select(2, UnitClass(unit))
    end
    if not classToken then
        LogWarn(format("PARTY STOP: unable to resolve class for %s (%s)", tostring(name), tostring(unit)))
        return
    end

    local member = EnsurePartyStopMember(name, classToken)
    member.unit = unit or member.unit
    local stopInfo = EnsureStopEntry(member.stops, stopData, classToken, false)
    if not stopInfo then
        return
    end

    local baseCd = stopInfo.baseCd or stopData.cd or stopData.baseCD or 0
    if not ApplyStopCooldownStamp(stopInfo, baseCd, spellID, now) then
        return
    end

    Log(format("PARTY STOP: %s cast %s (ID %d, cat=%s, CD=%ds, confidence=%s via=%s)",
        tostring(name),
        tostring(stopInfo.spellName or stopData.name or spellID),
        tonumber(spellID) or 0,
        tostring(stopInfo.category or stopData.category or "stop"),
        tonumber(baseCd) or 0,
        tostring(debugInfo and debugInfo.confidence or "unknown"),
        tostring(debugInfo and debugInfo.chosenBy or "unknown")))

    UpdateDisplay()
end

-- ============================================================================
-- Handle mob interrupt correlation (from PartySpellWatcher)
-- ============================================================================

local function OnMobKickConfirmed(name)
    local info = partyMembers[name]
    if not info then
        LogDebug(format("OnMobKickConfirmed: %s not in partyMembers", tostring(name)))
        return
    end

    local now = GetTime()
    if info.lastKickTime and (now - info.lastKickTime) < 0.5 then
        return
    end

    local baseCd = info.baseCd or 15
    local reduction = info.onKickReduction or 0
    local cd = baseCd - reduction
    if cd < 1 then cd = 1 end

    info.cdEnd = now + cd
    info.lastKickTime = now

    Log(format("CONFIRMED KICK: %s -> CD %ds%s",
        name, cd, reduction > 0 and format(" (base %d -%d on-kick)", baseCd, reduction) or ""))
    UpdateDisplay()
end

-- ============================================================================
-- Own kick tracking (player + pet)
-- ============================================================================

local playerCastFrame

local function SetupOwnKickTracking()
    if playerCastFrame then
        LogDebug("SetupOwnKickTracking: already set up")
        return
    end
    playerCastFrame = CreateFrame("Frame")
    playerCastFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "pet")
    playerCastFrame:SetScript("OnEvent", function(_, _, unit, _, spellID)
        local isInterrupt = ALL_INTERRUPTS[spellID]
        if isInterrupt and mySpellID then
            local cd
            if spellID == mySpellID then
                cd = myBaseCd or isInterrupt.cd
            else
                cd = isInterrupt.cd
            end
            myKickCdEnd = GetTime() + cd
            Log(format("OWN KICK: unit=%s spellID=%d (%s) CD=%ds (mySpellID=%s)",
                tostring(unit), spellID, isInterrupt.name, cd, tostring(mySpellID)))
        end

        local stopData, canonicalStopID = ResolveStopRecord(spellID, myClass)
        if stopData then
            local stopInfo = EnsureStopEntry(myStops, stopData, myClass, true)
            if stopInfo and ApplyStopCooldownStamp(stopInfo, stopInfo.baseCd or stopData.cd or 0, spellID, GetTime()) then
                if canonicalStopID and canonicalStopID ~= stopInfo.spellID then
                    stopInfo.spellID = canonicalStopID
                end
                Log(format("OWN STOP: unit=%s spellID=%d (%s) cat=%s CD=%ds",
                    tostring(unit),
                    tonumber(spellID) or 0,
                    tostring(stopInfo.spellName or stopData.name),
                    tostring(stopInfo.category or stopData.category or "stop"),
                    tonumber(stopInfo.baseCd or stopData.cd or 0) or 0))
            end
        end
    end)
    LogDebug("SetupOwnKickTracking: registered UNIT_SPELLCAST_SUCCEEDED for player+pet")
end

local function TeardownOwnKickTracking()
    if playerCastFrame then
        playerCastFrame:UnregisterAllEvents()
        playerCastFrame = nil
    end
end

local function ResolvePartySourceOwner(sourceGUID, sourceName)
    if not sourceGUID then
        return nil, nil, nil
    end

    if UnitGUID("player") == sourceGUID or UnitGUID("pet") == sourceGUID then
        return myName or UnitName("player"), myClass or select(2, UnitClass("player")), "player"
    end

    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) and UnitGUID(unit) == sourceGUID then
            return UnitName(unit), select(2, UnitClass(unit)), unit
        end

        local petUnit = "partypet" .. i
        if UnitExists(petUnit) and UnitGUID(petUnit) == sourceGUID then
            return UnitName(unit), select(2, UnitClass(unit)), unit
        end
    end

    if sourceName and partyStopMembers[sourceName] then
        local member = partyStopMembers[sourceName]
        return sourceName, member and member.class or nil, member and member.unit or nil
    end

    return nil, nil, nil
end

-- Retail 12.0 moved CLEU onto the restricted callback-event path. Registering
-- it through Frame:RegisterEvent() from the options toggle flow can trip the
-- protected-action popup, so prefer RegisterEventCallback when available.
local function HandleStopCombatEvent()
    local _, subEvent, _, sourceGUID, sourceName, _, _, _, _, _, _, spellID = CombatLogGetCurrentEventInfo()
    if subEvent ~= "SPELL_CAST_SUCCESS" and subEvent ~= "SPELL_CREATE" and subEvent ~= "SPELL_SUMMON" then
        return
    end

    local ownerName, classToken, ownerUnit = ResolvePartySourceOwner(sourceGUID, sourceName)
    if not ownerName or not classToken then
        return
    end

    local stopData, canonicalStopID = ResolveStopRecord(spellID, classToken)
    if not stopData then
        return
    end

    local now = GetTime()
    if ownerUnit == "player" then
        local stopInfo = EnsureStopEntry(myStops, stopData, myClass or classToken, true)
        if stopInfo and ApplyStopCooldownStamp(stopInfo, stopInfo.baseCd or stopData.cd or 0, spellID, now) then
            if canonicalStopID and canonicalStopID ~= stopInfo.spellID then
                stopInfo.spellID = canonicalStopID
            end
            Log(format("OWN STOP [CLEU]: spellID=%d (%s) cat=%s CD=%ds",
                tonumber(spellID) or 0,
                tostring(stopInfo.spellName or stopData.name),
                tostring(stopInfo.category or stopData.category or "stop"),
                tonumber(stopInfo.baseCd or stopData.cd or 0) or 0))
            UpdateDisplay()
        end
        return
    end

    local member = EnsurePartyStopMember(ownerName, classToken)
    member.unit = ownerUnit or member.unit
    local stopInfo = EnsureStopEntry(member.stops, stopData, classToken, false)
    if stopInfo and ApplyStopCooldownStamp(stopInfo, stopInfo.baseCd or stopData.cd or 0, spellID, now) then
        if canonicalStopID and canonicalStopID ~= stopInfo.spellID then
            stopInfo.spellID = canonicalStopID
        end
        Log(format("PARTY STOP [CLEU]: %s cast %s (ID %d, cat=%s, CD=%ds)",
            tostring(ownerName),
            tostring(stopInfo.spellName or stopData.name or spellID),
            tonumber(spellID) or 0,
            tostring(stopInfo.category or stopData.category or "stop"),
            tonumber(stopInfo.baseCd or stopData.cd or 0) or 0))
        UpdateDisplay()
    end
end

local function SetupStopCombatFallback()
    if stopCombatFrame then
        return
    end

    stopCombatFrame = CreateFrame("Frame")
    stopCombatUsesCallbackEvent = false

    if stopCombatFrame.RegisterEventCallback and stopCombatFrame.UnregisterEventCallback then
        local ok, registered = pcall(
            stopCombatFrame.RegisterEventCallback,
            stopCombatFrame,
            "COMBAT_LOG_EVENT_UNFILTERED",
            HandleStopCombatEvent
        )
        if ok and registered ~= false then
            stopCombatUsesCallbackEvent = true
            LogDebug("SetupStopCombatFallback: registered COMBAT_LOG_EVENT_UNFILTERED via RegisterEventCallback")
            return
        end

        LogWarn(format(
            "SetupStopCombatFallback: callback registration failed, falling back to RegisterEvent (ok=%s registered=%s)",
            tostring(ok),
            tostring(registered)
        ))
    end

    stopCombatFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    stopCombatFrame:SetScript("OnEvent", HandleStopCombatEvent)
    LogDebug("SetupStopCombatFallback: registered COMBAT_LOG_EVENT_UNFILTERED via RegisterEvent")
end

local function TeardownStopCombatFallback()
    if stopCombatFrame then
        if stopCombatUsesCallbackEvent and stopCombatFrame.UnregisterEventCallback then
            pcall(
                stopCombatFrame.UnregisterEventCallback,
                stopCombatFrame,
                "COMBAT_LOG_EVENT_UNFILTERED",
                HandleStopCombatEvent
            )
        else
            stopCombatFrame:UnregisterAllEvents()
        end
        stopCombatFrame:SetScript("OnEvent", nil)
        stopCombatUsesCallbackEvent = false
        stopCombatFrame = nil
    end
end

-- ============================================================================
-- UI: Bar layout
-- ============================================================================

local function GetBarLayout()
    local fw = db.frameWidth
    local baseBarH = math.max(12, db.barHeight)
    local titleFontSize = (db.titleFontSize and db.titleFontSize > 0) and db.titleFontSize or 12
    local titleH = db.showTitle and math.max(20, titleFontSize + 8) or 0
    local iconS = 0
    if db.showIcons ~= false then
        iconS = (db.iconSize and db.iconSize > 0) and db.iconSize or baseBarH
    end
    local barH = math.max(baseBarH, iconS)
    local barW = math.max(60, fw - iconS)
    local autoNameSize = math.max(9, math.floor(barH * 0.45))
    local autoCdSize = math.max(10, math.floor(barH * 0.55))
    local fontSize = (db.nameFontSize and db.nameFontSize > 0) and db.nameFontSize or autoNameSize
    local cdFontSize = (db.readyFontSize and db.readyFontSize > 0) and db.readyFontSize or autoCdSize
    return barW, barH, iconS, fontSize, cdFontSize, titleH, titleFontSize
end

local function ClearBarSet(barSet)
    for i = 1, #barSet do
        if barSet[i] then
            barSet[i]:Hide()
            barSet[i]:SetParent(nil)
            barSet[i] = nil
        end
    end
end

local function CreateBarForFrame(parentFrame, index)
    local barW, barH, iconS, fontSize, cdFontSize, titleH = GetBarLayout()
    local yOff
    if db.growUp then
        yOff = (index - 1) * (barH + 1)
    else
        yOff = -(titleH + (index - 1) * (barH + 1))
    end

    local f = CreateFrame("Frame", nil, parentFrame)
    f:SetSize(iconS + barW, barH)
    if db.growUp then
        f:SetPoint("BOTTOMLEFT", 0, yOff)
    else
        f:SetPoint("TOPLEFT", 0, yOff)
    end

    local ico = f:CreateTexture(nil, "ARTWORK")
    ico:SetSize(iconS, iconS)
    ico:SetPoint("LEFT", 0, 0)
    ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if iconS == 0 then ico:Hide() end
    f.icon = ico

    local barBg = f:CreateTexture(nil, "BACKGROUND")
    barBg:SetPoint("TOPLEFT", iconS, 0)
    barBg:SetPoint("BOTTOMRIGHT", 0, 0)
    barBg:SetTexture(BAR_TEXTURE)
    barBg:SetVertexColor(0.15, 0.15, 0.15, 0.9)
    f.barBg = barBg

    local sb = CreateFrame("StatusBar", nil, f)
    sb:SetPoint("TOPLEFT", iconS, 0)
    sb:SetPoint("BOTTOMRIGHT", 0, 0)
    sb:SetStatusBarTexture(BAR_TEXTURE)
    sb:SetStatusBarColor(1, 1, 1, 0.85)
    sb:SetMinMaxValues(0, 1)
    sb:SetValue(0)
    sb:SetFrameLevel(f:GetFrameLevel() + 1)
    f.cdBar = sb

    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", iconS, 0)
    content:SetPoint("BOTTOMRIGHT", 0, 0)
    content:SetFrameLevel(sb:GetFrameLevel() + 1)

    local nm = content:CreateFontString(nil, "OVERLAY")
    nm:SetFontObject(GetFontObj(db.font or "default", fontSize, "outline"))
    nm:SetPoint("LEFT", 6, 0)
    nm:SetJustifyH("LEFT")
    nm:SetWidth(barW - 50)
    nm:SetWordWrap(false)
    nm:SetShadowOffset(1, -1)
    nm:SetShadowColor(0, 0, 0, 1)
    if db.showNames == false then nm:Hide() end
    f.nameText = nm

    local cdTxt = content:CreateFontString(nil, "OVERLAY")
    cdTxt:SetFontObject(GetFontObj(db.font or "default", cdFontSize, "outline"))
    cdTxt:SetPoint("RIGHT", -6, 0)
    cdTxt:SetShadowOffset(1, -1)
    cdTxt:SetShadowColor(0, 0, 0, 1)
    f.cdText = cdTxt

    f:Hide()
    return f
end

local function RebuildBarSet(parentFrame, titleFS, resizeBtn, barSet, requiredCount)
    if not parentFrame then return end

    ClearBarSet(barSet)

    local barW, barH, iconS, fontSize, cdFontSize, titleH, titleFontSize = GetBarLayout()
    parentFrame:SetWidth(db.frameWidth)
    parentFrame:SetAlpha(db.alpha)

    if titleFS then
        titleFS:SetFontObject(GetFontObj(db.font or "default", titleFontSize, "outline"))
        if db.showTitle then titleFS:Show() else titleFS:Hide() end
    end

    local count = math.max(6, requiredCount or 0)
    for i = 1, count do
        barSet[i] = CreateBarForFrame(parentFrame, i)
    end

    if resizeBtn then
        resizeBtn:Raise()
    end
end

local function RebuildBars(requiredCount)
    RebuildBarSet(mainFrame, titleText, resizeHandle, bars, requiredCount)
end

local function RebuildStunBars(requiredCount)
    RebuildBarSet(stunFrame, stunTitleText, stunResizeHandle, stunBars, requiredCount)
end

local function CountVisibleBars(barSet)
    local numVisible = 0
    for i = 1, #barSet do
        if barSet[i] and barSet[i]:IsShown() then
            numVisible = numVisible + 1
        end
    end
    if numVisible < 1 then
        numVisible = 1
    end
    return numVisible
end

local function ApplyFrameEntries(frame, barSet, entries)
    if not frame then return 0 end

    local _, barH, _, fontSize, cdFontSize, titleH = GetBarLayout()
    local numVisible = #entries
    if numVisible > #barSet then
        if barSet == bars then
            RebuildBars(numVisible)
        else
            RebuildStunBars(numVisible)
        end
    end

    for index, entry in ipairs(entries) do
        local bar = barSet[index]
        if not bar then break end
        bar:Show()
        ApplyBarVisuals(
            bar,
            entry.label or entry.name,
            entry.info.class,
            entry.data.icon or FALLBACK_INTERRUPT_ICON,
            entry.info.baseCd or entry.data.cd or 15,
            entry.remaining,
            entry.isPlayer,
            fontSize,
            cdFontSize
        )
    end

    for i = numVisible + 1, #barSet do
        if barSet[i] then
            barSet[i]:Hide()
        end
    end

    if not isResizing then
        local visibleCount = numVisible > 0 and numVisible or 1
        frame:SetHeight(titleH + visibleCount * (barH + 1))
    end

    return numVisible
end

-- ============================================================================
-- UI: Display update
-- ============================================================================

local function CheckZoneVisibility()
    local _, instanceType = IsInInstance()
    if instanceType == "party" then
        shouldShowByZone = db.showInDungeon
    elseif instanceType == "raid" then
        shouldShowByZone = db.showInRaid
    elseif instanceType == "arena" then
        shouldShowByZone = db.showInArena
    elseif instanceType == "pvp" then
        shouldShowByZone = db.showInBG
    else
        shouldShowByZone = db.showInOpenWorld
    end
    LogDebug(format("CheckZoneVisibility: instanceType=%s showByZone=%s mainFrame=%s",
        tostring(instanceType), tostring(shouldShowByZone), tostring(mainFrame ~= nil)))
    UpdateMainFrameVisibility()
end

local lastStateDump = 0

UpdateDisplay = function()
    if not mainFrame then return end

    if not shouldShowByZone then
        hasVisibleEntries = false
        hasVisibleStunEntries = false
        UpdateMainFrameVisibility()
        return
    end

    local now = GetTime()
    local displayEntries = GetDisplayEntries(now)
    local stunEntries = GetStunDisplayEntries(now)
    local numVisible = #displayEntries
    hasVisibleEntries = numVisible > 0
    hasVisibleStunEntries = #stunEntries > 0

    if now - lastStateDump > 10 then
        lastStateDump = now
        local memberCount = 0
        for n, info in pairs(partyMembers) do
            memberCount = memberCount + 1
            local rem = info.cdEnd > now and (info.cdEnd - now) or 0
            LogDebug(format("  STATE: %s class=%s spell=%s cd=%.1fs",
                n, info.class, tostring(info.spellID), rem))
        end
        LogDebug(format("UpdateDisplay tick: mySpell=%s myCD=%.1f members=%d display=%d stuns=%d visible=%s",
            tostring(mySpellID), GetPlayerCooldownRemaining(now),
            memberCount, #displayEntries, #stunEntries, tostring(shouldShowByZone)))
    end

    ApplyFrameEntries(mainFrame, bars, displayEntries)
    if stunFrame then
        ApplyFrameEntries(stunFrame, stunBars, stunEntries)
    end
    UpdateMainFrameVisibility()
end

-- ============================================================================
-- UI: Create main frame
-- ============================================================================

local function FinishSharedResize(frame, barSet)
    frame:StopMovingOrSizing()
    isResizing = false
    db.frameWidth = math.floor(frame:GetWidth())
    local titleH = db.showTitle and 20 or 0
    local dragH = frame:GetHeight() - titleH
    local numVisible = CountVisibleBars(barSet)
    db.barHeight = math.max(12, math.floor(dragH / numVisible) - 1)
    RebuildBars(#GetDisplayEntries(GetTime()))
    RebuildStunBars(#GetStunDisplayEntries(GetTime()))
end

local function CreateTrackerFrame(frameName, titleMarkup, positionKey, existingFrame, existingTitle, existingResize, barSet)
    if existingFrame then
        return existingFrame, existingTitle, existingResize
    end

    local frame = CreateFrame("Frame", frameName, UIParent)
    frame:SetSize(db.frameWidth, 200)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not db.locked then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        local pos = db[positionKey]
        pos.point = point
        pos.x = x
        pos.y = y
    end)
    frame:SetAlpha(db.alpha)
    frame:SetResizable(true)
    frame:SetResizeBounds(80, 40, 600, 1200)

    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(BAR_TEXTURE)
    bg:SetVertexColor(0.05, 0.05, 0.05, 0.85)

    local titleFS = frame:CreateFontString(nil, "OVERLAY")
    titleFS:SetFontObject(GetFontObj(db.font or "default", (db.titleFontSize and db.titleFontSize > 0) and db.titleFontSize or 12, "outline"))
    titleFS:SetPoint("TOP", 0, -3)
    titleFS:SetText(titleMarkup)
    if not db.showTitle then titleFS:Hide() end

    local resizeBtn = CreateFrame("Button", nil, frame)
    resizeBtn:SetSize(16, 16)
    resizeBtn:SetPoint("BOTTOMRIGHT", 0, 0)
    resizeBtn:SetFrameLevel(frame:GetFrameLevel() + 10)
    resizeBtn:EnableMouse(true)

    for j = 0, 2 do
        local line = resizeBtn:CreateTexture(nil, "OVERLAY", nil, 1)
        line:SetTexture(BAR_TEXTURE)
        line:SetVertexColor(0.6, 0.8, 0.9, 0.7)
        line:SetSize(1, (3 - j) * 4)
        line:SetPoint("BOTTOMRIGHT", -(j * 4 + 2), 2)
    end

    resizeBtn:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" and not db.locked then
            isResizing = true
            frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    resizeBtn:SetScript("OnMouseUp", function()
        FinishSharedResize(frame, barSet)
    end)

    local pos = db[positionKey]
    if not pos then
        pos = { point = "CENTER", x = positionKey == "stunPosition" and 250 or 0, y = -150 }
        db[positionKey] = pos
    end
    frame:ClearAllPoints()
    frame:SetPoint(pos.point, UIParent, pos.point, pos.x, pos.y)

    return frame, titleFS, resizeBtn
end

local function CreateUI()
    if mainFrame then
        LogDebug("CreateUI: mainFrame already exists, skipping")
        return
    end
    LogDebug("CreateUI: building main frame...")

    mainFrame, titleText, resizeHandle = CreateTrackerFrame(
        "MedaAurasInterruptedFrame",
        "|cFF00DDDDStops|r",
        "position",
        mainFrame,
        titleText,
        resizeHandle,
        bars
    )
    stunFrame, stunTitleText, stunResizeHandle = CreateTrackerFrame(
        "MedaAurasInterruptedStunFrame",
        "|cFF74F2FFStuns|r",
        "stunPosition",
        stunFrame,
        stunTitleText,
        stunResizeHandle,
        stunBars
    )
    UpdateMainFrameVisibility()

    LogDebug(format("CreateUI: frame positioned at %s (%.0f, %.0f), now building bars",
        db.position.point, db.position.x, db.position.y))
    RebuildBars(#GetDisplayEntries(GetTime()))
    RebuildStunBars(#GetStunDisplayEntries(GetTime()))
    LogDebug("CreateUI: complete")
end

local function DestroyUI()
    if updateTicker then updateTicker:Cancel(); updateTicker = nil end
    hasVisibleEntries = false
    hasVisibleStunEntries = false
    if mainFrame then mainFrame:Hide() end
    if stunFrame then stunFrame:Hide() end
end

-- ============================================================================
-- Roster event frame (inside-module, separate from PartySpellWatcher)
-- ============================================================================

local rosterFrame

local function SetupRosterEvents()
    if rosterFrame then return end
    rosterFrame = CreateFrame("Frame")
    rosterFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    rosterFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    rosterFrame:RegisterEvent("SPELLS_CHANGED")
    rosterFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    rosterFrame:RegisterEvent("ROLE_CHANGED_INFORM")
    rosterFrame:SetScript("OnEvent", function(_, event, arg1)
        LogDebug(format("Roster event: %s arg1=%s", event, tostring(arg1)))
        if event == "GROUP_ROSTER_UPDATE" then
            CleanPartyList()
            AutoRegisterParty()
        elseif event == "PLAYER_ENTERING_WORLD" then
            CheckZoneVisibility()
            FindMyInterrupt()
            AutoRegisterParty()
        elseif event == "SPELLS_CHANGED" then
            FindMyInterrupt()
        elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
            if arg1 == "player" then
                FindMyInterrupt()
            end
        elseif event == "ROLE_CHANGED_INFORM" then
            AutoRegisterParty()
        end
    end)
end

local function TeardownRosterEvents()
    if rosterFrame then
        rosterFrame:UnregisterAllEvents()
        rosterFrame = nil
    end
end

-- ============================================================================
-- Module Lifecycle
-- ============================================================================

local function OnInitialize(moduleDB)
    db = moduleDB
    Log("OnInitialize starting...")

    LogDebug(format("  db.enabled=%s", tostring(moduleDB.enabled)))
    LogDebug(format("  ns.InterruptData=%s", tostring(ns.InterruptData ~= nil)))
    LogDebug(format("  ns.Services.PartySpellWatcher=%s", tostring(ns.Services.PartySpellWatcher ~= nil)))
    LogDebug(format("  ns.Services.GroupInspector=%s", tostring(ns.Services.GroupInspector ~= nil)))
    LogDebug(format("  ns.Services.InterruptResolver=%s", tostring(ns.Services.InterruptResolver ~= nil)))
    if ns.Services.GroupInspector and ns.Services.GroupInspector.Initialize then
        ns.Services.GroupInspector:Initialize()
    end

    LogDebug("  Step 1: FindMyInterrupt")
    FindMyInterrupt()

    LogDebug("  Step 2: CreateUI")
    CreateUI()
    LogDebug(format("  mainFrame created: %s", tostring(mainFrame ~= nil)))

    LogDebug("  Step 3: CheckZoneVisibility")
    CheckZoneVisibility()

    LogDebug("  Step 4: SetupOwnKickTracking")
    SetupOwnKickTracking()
    SetupStopCombatFallback()

    LogDebug("  Step 5: SetupRosterEvents")
    SetupRosterEvents()

    LogDebug("  Step 6: AutoRegisterParty")
    AutoRegisterParty()

    LogDebug("  Step 7: Register PartySpellWatcher callbacks")
    ns.Services.PartySpellWatcher:Initialize()
    watcherHandle = ns.Services.PartySpellWatcher:OnPartyInterrupt(OnPartyInterruptDetected)
    mobKickHandle = ns.Services.PartySpellWatcher:OnMobKick(OnMobKickConfirmed)
    if StopData and StopData.GetAllStopsLookup then
        stopWatcherHandle = ns.Services.PartySpellWatcher:OnPartySpellMatch({
            label = "InterruptedStops",
            lookupTable = StopData:GetAllStopsLookup(),
            candidateResolver = ResolveStopCandidates,
            callback = OnPartyStopDetected,
        })
    end
    LogDebug(format("  watcherHandle=%s mobKickHandle=%s stopWatcherHandle=%s",
        tostring(watcherHandle), tostring(mobKickHandle), tostring(stopWatcherHandle)))

    LogDebug("  Step 8: Register GroupInspector inspect-complete callback")
    ns.Services.GroupInspector:RegisterInspectComplete("Interrupted", ApplyTalentModifiersForMember)

    LogDebug("  Step 9: Start UpdateDisplay ticker (0.1s)")
    if updateTicker then updateTicker:Cancel() end
    updateTicker = C_Timer.NewTicker(0.1, UpdateDisplay)

    Log("OnInitialize complete - tracking started")
end

local function OnEnable(moduleDB)
    db = moduleDB
    Log("OnEnable called")
    OnInitialize(moduleDB)
end

local function OnDisable()
    Log("OnDisable called")
    DestroyUI()
    TeardownOwnKickTracking()
    TeardownStopCombatFallback()
    TeardownRosterEvents()

    if watcherHandle then
        ns.Services.PartySpellWatcher:Unregister(watcherHandle)
        watcherHandle = nil
    end
    if mobKickHandle then
        ns.Services.PartySpellWatcher:Unregister(mobKickHandle)
        mobKickHandle = nil
    end
    if stopWatcherHandle then
        ns.Services.PartySpellWatcher:Unregister(stopWatcherHandle)
        stopWatcherHandle = nil
    end

    ns.Services.GroupInspector:UnregisterInspectComplete("Interrupted")

    wipe(partyMembers)
    wipe(partyStopMembers)
    wipe(noInterruptPlayers)
    wipe(myStops)
    mySpellID = nil
    myKickCdEnd = 0
end

-- ============================================================================
-- Module Defaults
-- ============================================================================

local MODULE_DEFAULTS = {
    enabled = false,
    frameWidth = 220,
    barHeight = 28,
    locked = false,
    showTitle = true,
    showIcons = true,
    showNames = true,
    growUp = false,
    alpha = 0.9,
    font = "default",
    titleFontSize = 12,
    nameFontSize = 0,
    readyFontSize = 0,
    iconSize = 0,
    showReady = true,
    showBaseCooldownWhenReady = false,
    sortByNextAvailable = true,
    barColorMode = "class",
    customBarColor = { 1, 1, 1 },
    playerNameColorMode = "default",
    customPlayerNameColor = { 1, 1, 1 },
    playerNameOutline = "outline",
    showInDungeon = true,
    showInRaid = false,
    showInOpenWorld = false,
    showInArena = true,
    showInBG = false,
    splitStunsToSeparateWindow = false,
    hideHardCC = false,
    position = { point = "CENTER", x = 0, y = -150 },
    stunPosition = { point = "CENTER", x = 250, y = -150 },
}

-- ============================================================================
-- Preview
-- ============================================================================

local pvContainer, pvInner, pvBars, pvTitleText
local pvTicker
local pvStartTime = 0

local PREVIEW_MOCK = {
    { name = "Pummeler",    class = "WARRIOR",     spellID = 6552,   baseCd = 15, cdOffset = 8  },
    { name = "Stabsworth",  class = "ROGUE",       spellID = 1766,   baseCd = 15, cdOffset = 0  },
    { name = "Frostbyte",   class = "MAGE",        spellID = 2139,   baseCd = 24, cdOffset = 16 },
    { name = "Thundercall", class = "SHAMAN",      spellID = 57994,  baseCd = 12, cdOffset = 3  },
    { name = "Felrush",     class = "DEMONHUNTER", spellID = 183752, baseCd = 15, cdOffset = 0  },
}

local function GetPreviewMocks()
    local preview = {}
    local playerName = myName or UnitName("player")
    local playerClass = myClass or select(2, UnitClass("player"))

    for index, mock in ipairs(PREVIEW_MOCK) do
        local entry = {
            name = mock.name,
            class = mock.class,
            spellID = mock.spellID,
            baseCd = mock.baseCd,
            cdOffset = mock.cdOffset,
            isPlayer = false,
        }

        if index == 1 then
            entry.name = playerName or mock.name
            entry.class = playerClass or mock.class
            entry.spellID = mySpellID or mock.spellID
            entry.baseCd = myBaseCd or mock.baseCd
            entry.isPlayer = true
        end

        preview[#preview + 1] = entry
    end

    return preview
end

local function DestroyPreview()
    if pvTicker then pvTicker:Cancel(); pvTicker = nil end
    if pvBars then
        for i = 1, #pvBars do
            pvBars[i]:Hide()
            pvBars[i]:SetParent(nil)
        end
        wipe(pvBars)
        pvBars = nil
    end
    pvTitleText = nil
    if pvInner then pvInner:Hide(); pvInner:SetParent(nil); pvInner = nil end
    if pvContainer then pvContainer:Hide(); pvContainer:SetParent(nil); pvContainer = nil end
end

local function CreatePreviewBars()
    if pvInner then pvInner:Hide(); pvInner:SetParent(nil) end

    pvInner = CreateFrame("Frame", nil, pvContainer)
    pvInner:SetAllPoints()
    pvBars = {}

    local barW, barH, iconS, fontSize, cdFontSize, titleH, titleFontSize = GetBarLayout()

    if db.showTitle then
        pvTitleText = pvInner:CreateFontString(nil, "OVERLAY")
        pvTitleText:SetFontObject(GetFontObj(db.font or "default", titleFontSize, "outline"))
        pvTitleText:SetPoint("TOP", 0, -3)
        pvTitleText:SetText("|cFF00DDDDStops|r")
    else
        pvTitleText = nil
    end

    for i = 1, #PREVIEW_MOCK do
        local yOff
        if db.growUp then
            yOff = (i - 1) * (barH + 1)
        else
            yOff = -(titleH + (i - 1) * (barH + 1))
        end

        local f = CreateFrame("Frame", nil, pvInner)
        f:SetSize(iconS + barW, barH)
        if db.growUp then
            f:SetPoint("BOTTOMLEFT", 0, yOff)
        else
            f:SetPoint("TOPLEFT", 0, yOff)
        end

        local ico = f:CreateTexture(nil, "ARTWORK")
        ico:SetSize(iconS, iconS)
        ico:SetPoint("LEFT", 0, 0)
        ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        if iconS == 0 then ico:Hide() end
        f.icon = ico

        local barBg = f:CreateTexture(nil, "BACKGROUND")
        barBg:SetPoint("TOPLEFT", iconS, 0)
        barBg:SetPoint("BOTTOMRIGHT", 0, 0)
        barBg:SetTexture(BAR_TEXTURE)
        barBg:SetVertexColor(0.15, 0.15, 0.15, 0.9)
        f.barBg = barBg

        local sb = CreateFrame("StatusBar", nil, f)
        sb:SetPoint("TOPLEFT", iconS, 0)
        sb:SetPoint("BOTTOMRIGHT", 0, 0)
        sb:SetStatusBarTexture(BAR_TEXTURE)
        sb:SetStatusBarColor(1, 1, 1, 0.85)
        sb:SetMinMaxValues(0, 1)
        sb:SetValue(0)
        sb:SetFrameLevel(f:GetFrameLevel() + 1)
        f.cdBar = sb

        local content = CreateFrame("Frame", nil, f)
        content:SetPoint("TOPLEFT", iconS, 0)
        content:SetPoint("BOTTOMRIGHT", 0, 0)
        content:SetFrameLevel(sb:GetFrameLevel() + 1)

        local nm = content:CreateFontString(nil, "OVERLAY")
        nm:SetFontObject(GetFontObj(db.font or "default", fontSize, "outline"))
        nm:SetPoint("LEFT", 6, 0)
        nm:SetJustifyH("LEFT")
        nm:SetWidth(barW - 50)
        nm:SetWordWrap(false)
        nm:SetShadowOffset(1, -1)
        nm:SetShadowColor(0, 0, 0, 1)
        if db.showNames == false then nm:Hide() end
        f.nameText = nm

        local cdTxt = content:CreateFontString(nil, "OVERLAY")
        cdTxt:SetFontObject(GetFontObj(db.font or "default", cdFontSize, "outline"))
        cdTxt:SetPoint("RIGHT", -6, 0)
        cdTxt:SetShadowOffset(1, -1)
        cdTxt:SetShadowColor(0, 0, 0, 1)
        f.cdText = cdTxt

        f:Show()
        pvBars[i] = f
    end

    local numBars = #PREVIEW_MOCK
    pvContainer:SetSize(db.frameWidth, titleH + numBars * (barH + 1))
end

local function UpdatePreview()
    if not pvContainer or not pvBars or not db then return end

    local elapsed = GetTime() - pvStartTime
    local _, barH, _, fontSize, cdFontSize, titleH = GetBarLayout()
    local previewEntries = {}
    local previewMocks = GetPreviewMocks()

    for _, mock in ipairs(previewMocks) do
        local readyWindow = 5
        local cycleLen = mock.baseCd + readyWindow
        local pos = (elapsed + mock.cdOffset) % cycleLen
        local rem = mock.baseCd - pos
        if rem < 0 then rem = 0 end

        previewEntries[#previewEntries + 1] = {
            mock = mock,
            remaining = NormalizeRemainingCooldown(rem),
        }
    end

    if db.sortByNextAvailable ~= false then
        table.sort(previewEntries, function(a, b)
            if a.remaining ~= b.remaining then
                return a.remaining < b.remaining
            end

            return a.mock.name < b.mock.name
        end)
    end

    for i, entry in ipairs(previewEntries) do
        local mock = entry.mock
        local bar = pvBars[i]
        if not bar then break end

        local data = ALL_INTERRUPTS[mock.spellID]
        ApplyBarVisuals(
            bar,
            mock.name,
            mock.class,
            data and data.icon or FALLBACK_INTERRUPT_ICON,
            mock.baseCd,
            entry.remaining,
            mock.isPlayer,
            fontSize,
            cdFontSize
        )
    end

    pvContainer:SetAlpha(db.alpha)
    pvContainer:SetSize(db.frameWidth, titleH + #previewMocks * (barH + 1))
end

local function RebuildPreview()
    if not pvContainer then return end
    CreatePreviewBars()
    UpdatePreview()
end

-- ============================================================================
-- Settings UI
-- ============================================================================

local function BuildSettingsPage(parent, moduleDB)
    db = moduleDB
    DestroyPreview()

    do
        local anchor = MedaAurasSettingsPanel or _G["MedaAurasSettingsPanel"]
        if anchor then
            pvContainer = CreateFrame("Frame", nil, anchor)
            pvContainer:SetFrameStrata("HIGH")
            pvContainer:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 0)
            pvContainer:SetClampedToScreen(true)
            pvContainer:SetScript("OnHide", function()
                if pvTicker then pvTicker:Cancel(); pvTicker = nil end
            end)
            MedaAuras:RegisterConfigCleanup(pvContainer)

            local bg = pvContainer:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetTexture(BAR_TEXTURE)
            bg:SetVertexColor(0.08, 0.08, 0.08, 0.85)

            pvStartTime = GetTime()
            CreatePreviewBars()
            UpdatePreview()

            pvTicker = C_Timer.NewTicker(0.1, UpdatePreview)
        end
    end

    local LEFT_X = 0
    local RIGHT_X = 240
    local detectedNameLabel

    local function RefreshDetectedPlayerPreview()
        if not detectedNameLabel then return end

        local playerName = myName or UnitName("player") or "Player"
        local playerClass = myClass or select(2, UnitClass("player"))
        local r, g, b = ResolveNameColor(true, playerClass)

        detectedNameLabel:SetFontObject(GetFontObj(moduleDB.font or "default", 13, moduleDB.playerNameOutline or "outline"))
        detectedNameLabel:SetText(playerName)
        detectedNameLabel:SetTextColor(r, g, b)
    end

    local function RefreshVisualLayout()
        wipe(fontCache)
        if mainFrame then
            RebuildBars()
            RebuildStunBars()
            UpdateDisplay()
        end
        RebuildPreview()
        RefreshDetectedPlayerPreview()
    end

    local function RefreshVisualState()
        if mainFrame then
            UpdateDisplay()
        end
        UpdatePreview()
        RefreshDetectedPlayerPreview()
    end

    local _, tabs = MedaAuras:CreateConfigTabs(parent, {
        { id = "general", label = "General" },
        { id = "sizingfont", label = "Sizing & Font" },
    })

    local generalHeight
    local sizingHeight

    do
        local p = tabs["general"]
        local generalY = 0

        local header = MedaUI:CreateSectionHeader(p, "General")
        header:SetPoint("TOPLEFT", LEFT_X, generalY)
        generalY = generalY - 45

        local enableCB = MedaUI:CreateCheckbox(p, "Enable Module")
        enableCB:SetPoint("TOPLEFT", LEFT_X, generalY)
        enableCB:SetChecked(moduleDB.enabled)
        enableCB.OnValueChanged = function(_, checked)
            if checked then MedaAuras:EnableModule(MODULE_NAME)
            else MedaAuras:DisableModule(MODULE_NAME) end
            MedaAuras:RefreshSidebarDot(MODULE_NAME)
        end
        generalY = generalY - 35

        local dispHeader = MedaUI:CreateSectionHeader(p, "Display")
        dispHeader:SetPoint("TOPLEFT", LEFT_X, generalY)
        generalY = generalY - 40

        local titleCB = MedaUI:CreateCheckbox(p, "Show Title")
        titleCB:SetPoint("TOPLEFT", LEFT_X, generalY)
        titleCB:SetChecked(moduleDB.showTitle)
        titleCB.OnValueChanged = function(_, checked)
            moduleDB.showTitle = checked
            RefreshVisualLayout()
        end

        local lockCB = MedaUI:CreateCheckbox(p, "Lock Position")
        lockCB:SetPoint("TOPLEFT", RIGHT_X, generalY)
        lockCB:SetChecked(moduleDB.locked)
        lockCB.OnValueChanged = function(_, checked) moduleDB.locked = checked end
        generalY = generalY - 30

        local rescanBtn = MedaUI:CreateButton(p, "Rescan Group Cache", 180)
        rescanBtn:SetPoint("TOPLEFT", LEFT_X, generalY)
        rescanBtn.OnClick = RequestInspectorRescan
        generalY = generalY - 40

        local iconsCB = MedaUI:CreateCheckbox(p, "Show Icons")
        iconsCB:SetPoint("TOPLEFT", LEFT_X, generalY)
        iconsCB:SetChecked(moduleDB.showIcons ~= false)
        iconsCB.OnValueChanged = function(_, checked)
            moduleDB.showIcons = checked
            RefreshVisualLayout()
        end

        local namesCB = MedaUI:CreateCheckbox(p, "Show Names")
        namesCB:SetPoint("TOPLEFT", RIGHT_X, generalY)
        namesCB:SetChecked(moduleDB.showNames ~= false)
        namesCB.OnValueChanged = function(_, checked)
            moduleDB.showNames = checked
            RefreshVisualLayout()
        end
        generalY = generalY - 30

        local growCB = MedaUI:CreateCheckbox(p, "Grow Upward")
        growCB:SetPoint("TOPLEFT", LEFT_X, generalY)
        growCB:SetChecked(moduleDB.growUp)
        growCB.OnValueChanged = function(_, checked)
            moduleDB.growUp = checked
            RefreshVisualLayout()
        end

        local sortCB = MedaUI:CreateCheckbox(p, "Sort By Next Available")
        sortCB:SetPoint("TOPLEFT", RIGHT_X, generalY)
        sortCB:SetChecked(moduleDB.sortByNextAvailable ~= false)
        sortCB.OnValueChanged = function(_, checked)
            moduleDB.sortByNextAvailable = checked
            RefreshVisualState()
        end
        generalY = generalY - 30

        local readyCB = MedaUI:CreateCheckbox(p, "Show READY Text")
        readyCB:SetPoint("TOPLEFT", LEFT_X, generalY)
        readyCB:SetChecked(moduleDB.showReady)
        readyCB.OnValueChanged = function(_, checked)
            moduleDB.showReady = checked
            RefreshVisualState()
        end

        local readyCdCB = MedaUI:CreateCheckbox(p, "Show Base Cooldown When Ready")
        readyCdCB:SetPoint("TOPLEFT", RIGHT_X, generalY)
        readyCdCB:SetChecked(moduleDB.showBaseCooldownWhenReady == true)
        readyCdCB.OnValueChanged = function(_, checked)
            moduleDB.showBaseCooldownWhenReady = checked
            RefreshVisualState()
        end
        generalY = generalY - 40

        local alphaSlider = MedaUI:CreateLabeledSlider(p, "Opacity", 200, 0.3, 1.0, 0.05)
        alphaSlider:SetPoint("TOPLEFT", LEFT_X, generalY)
        alphaSlider:SetValue(moduleDB.alpha)
        alphaSlider.OnValueChanged = function(_, value)
            moduleDB.alpha = value
            if mainFrame then mainFrame:SetAlpha(value) end
            if stunFrame then stunFrame:SetAlpha(value) end
            UpdatePreview()
        end
        generalY = generalY - 55

        local splitStunsCB = MedaUI:CreateCheckbox(p, "Split Stuns To Separate Window")
        splitStunsCB:SetPoint("TOPLEFT", LEFT_X, generalY)
        splitStunsCB:SetChecked(moduleDB.splitStunsToSeparateWindow == true)
        splitStunsCB.OnValueChanged = function(_, checked)
            moduleDB.splitStunsToSeparateWindow = checked
            RefreshVisualLayout()
        end

        local splitHint = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        splitHint:SetPoint("TOPLEFT", LEFT_X + 20, generalY - 18)
        splitHint:SetTextColor(unpack(MedaUI.Theme.textDim))
        splitHint:SetText("Moves stun entries into a second draggable frame that uses its own saved position.")
        generalY = generalY - 55

        local hideHardCCCB = MedaUI:CreateCheckbox(p, "Hide Stuns / Hard CC")
        hideHardCCCB:SetPoint("TOPLEFT", LEFT_X, generalY)
        hideHardCCCB:SetChecked(moduleDB.hideHardCC == true)
        hideHardCCCB.OnValueChanged = function(_, checked)
            moduleDB.hideHardCC = checked
            RefreshVisualLayout()
        end

        local hideHardCCHint = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hideHardCCHint:SetPoint("TOPLEFT", LEFT_X + 20, generalY - 18)
        hideHardCCHint:SetTextColor(unpack(MedaUI.Theme.textDim))
        hideHardCCHint:SetText("Suppresses stun, fear, disorient, incap, horror, and sleep tools from the HUD.")
        generalY = generalY - 55

        local colorHeader = MedaUI:CreateSectionHeader(p, "Colors")
        colorHeader:SetPoint("TOPLEFT", LEFT_X, generalY)
        generalY = generalY - 45

        local barColorDD = MedaUI:CreateLabeledDropdown(p, "Bar Color", 200, {
            { value = "class", label = "Class Color" },
            { value = "custom", label = "Custom" },
        })
        barColorDD:SetPoint("TOPLEFT", LEFT_X, generalY)
        barColorDD:SetSelected(moduleDB.barColorMode or "class")

        local barColorPicker = MedaUI:CreateLabeledColorPicker(p, "Custom Bar Color")
        barColorPicker:SetPoint("TOPLEFT", RIGHT_X, generalY)
        local barColor = moduleDB.customBarColor or { 1, 1, 1 }
        barColorPicker:SetColor(barColor[1], barColor[2], barColor[3])
        barColorPicker:SetAlpha((moduleDB.barColorMode or "class") == "custom" and 1 or 0.4)
        barColorPicker.OnColorChanged = function(_, r, g, b)
            moduleDB.customBarColor = { r, g, b }
            RefreshVisualState()
        end
        barColorDD.OnValueChanged = function(_, value)
            moduleDB.barColorMode = value
            barColorPicker:SetAlpha(value == "custom" and 1 or 0.4)
            RefreshVisualState()
        end
        generalY = generalY - 55

        local playerNameColorDD = MedaUI:CreateLabeledDropdown(p, "Player Name Color", 200, {
            { value = "default", label = "Default White" },
            { value = "class", label = "Class Color" },
            { value = "custom", label = "Custom" },
        })
        playerNameColorDD:SetPoint("TOPLEFT", LEFT_X, generalY)
        playerNameColorDD:SetSelected(moduleDB.playerNameColorMode or "default")

        local playerNameColorPicker = MedaUI:CreateLabeledColorPicker(p, "Custom Player Name")
        playerNameColorPicker:SetPoint("TOPLEFT", RIGHT_X, generalY)
        local playerNameColor = moduleDB.customPlayerNameColor or { 1, 1, 1 }
        playerNameColorPicker:SetColor(playerNameColor[1], playerNameColor[2], playerNameColor[3])
        playerNameColorPicker:SetAlpha((moduleDB.playerNameColorMode or "default") == "custom" and 1 or 0.4)
        playerNameColorPicker.OnColorChanged = function(_, r, g, b)
            moduleDB.customPlayerNameColor = { r, g, b }
            RefreshVisualState()
        end
        playerNameColorDD.OnValueChanged = function(_, value)
            moduleDB.playerNameColorMode = value
            playerNameColorPicker:SetAlpha(value == "custom" and 1 or 0.4)
            RefreshVisualState()
        end
        generalY = generalY - 55

        local zoneHeader = MedaUI:CreateSectionHeader(p, "Show In")
        zoneHeader:SetPoint("TOPLEFT", LEFT_X, generalY)
        generalY = generalY - 40

        local function ZoneCB(label, key, x, y)
            local cb = MedaUI:CreateCheckbox(p, label)
            cb:SetPoint("TOPLEFT", x, y)
            cb:SetChecked(moduleDB[key])
            cb.OnValueChanged = function(_, checked)
                moduleDB[key] = checked
                CheckZoneVisibility()
            end
            return cb
        end

        ZoneCB("Dungeons", "showInDungeon", LEFT_X, generalY)
        ZoneCB("Raids", "showInRaid", RIGHT_X, generalY)
        generalY = generalY - 30
        ZoneCB("Open World", "showInOpenWorld", LEFT_X, generalY)
        ZoneCB("Arena", "showInArena", RIGHT_X, generalY)
        generalY = generalY - 30
        ZoneCB("Battlegrounds", "showInBG", LEFT_X, generalY)
        generalY = generalY - 40

        local detectedInterrupts = GetDetectedPlayerInterrupts()
        if #detectedInterrupts > 0 then
            local detectedHeader = MedaUI:CreateSectionHeader(p, "Detected Interrupts")
            detectedHeader:SetPoint("TOPLEFT", LEFT_X, generalY)
            generalY = generalY - 45

            local detectedFrame = CreateFrame("Frame", nil, p)
            detectedFrame:SetPoint("TOPLEFT", LEFT_X, generalY)
            detectedFrame:SetSize(440, 28 + (#detectedInterrupts * 22))

            local detectedBg = detectedFrame:CreateTexture(nil, "BACKGROUND")
            detectedBg:SetAllPoints()
            detectedBg:SetTexture(BAR_TEXTURE)
            detectedBg:SetVertexColor(0.08, 0.08, 0.08, 0.85)

            detectedNameLabel = detectedFrame:CreateFontString(nil, "OVERLAY")
            detectedNameLabel:SetPoint("TOPLEFT", 10, -8)
            RefreshDetectedPlayerPreview()

            local detectedLabel = detectedFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            detectedLabel:SetPoint("TOPRIGHT", -10, -10)
            detectedLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
            detectedLabel:SetText(format("%d detected", #detectedInterrupts))

            local rowY = -30
            for _, entry in ipairs(detectedInterrupts) do
                local icon = detectedFrame:CreateTexture(nil, "ARTWORK")
                icon:SetSize(16, 16)
                icon:SetPoint("TOPLEFT", 10, rowY)
                icon:SetTexture(entry.icon)
                icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                local spellLabel = detectedFrame:CreateFontString(nil, "OVERLAY")
                spellLabel:SetFontObject(GetFontObj(moduleDB.font or "default", 11, "outline"))
                spellLabel:SetPoint("LEFT", icon, "RIGHT", 8, 0)
                spellLabel:SetTextColor(unpack(MedaUI.Theme.text))
                spellLabel:SetText(entry.pet and format("%s  |cFF8FD3FFPet|r", entry.name) or entry.name)

                local cdLabel = detectedFrame:CreateFontString(nil, "OVERLAY")
                cdLabel:SetFontObject(GetFontObj(moduleDB.font or "default", 11, "outline"))
                cdLabel:SetPoint("RIGHT", detectedFrame, "TOPRIGHT", -10, rowY - 1)
                cdLabel:SetJustifyH("RIGHT")
                cdLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
                cdLabel:SetText(format("%ds", entry.cd or 0))

                rowY = rowY - 22
            end

            generalY = generalY - (30 + (#detectedInterrupts * 22))
        end

        local detectedStops = GetDetectedPlayerStops()
        if #detectedStops > 0 then
            local detectedHeader = MedaUI:CreateSectionHeader(p, "Detected Stop Tools")
            detectedHeader:SetPoint("TOPLEFT", LEFT_X, generalY)
            generalY = generalY - 45

            local detectedFrame = CreateFrame("Frame", nil, p)
            detectedFrame:SetPoint("TOPLEFT", LEFT_X, generalY)
            detectedFrame:SetSize(440, 28 + (#detectedStops * 22))

            local detectedBg = detectedFrame:CreateTexture(nil, "BACKGROUND")
            detectedBg:SetAllPoints()
            detectedBg:SetTexture(BAR_TEXTURE)
            detectedBg:SetVertexColor(0.08, 0.08, 0.08, 0.85)

            local detectedLabel = detectedFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            detectedLabel:SetPoint("TOPLEFT", 10, -10)
            detectedLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
            detectedLabel:SetText(format("%d detected", #detectedStops))

            local rowY = -30
            for _, entry in ipairs(detectedStops) do
                local icon = detectedFrame:CreateTexture(nil, "ARTWORK")
                icon:SetSize(16, 16)
                icon:SetPoint("TOPLEFT", 10, rowY)
                icon:SetTexture(entry.icon)
                icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                local spellLabel = detectedFrame:CreateFontString(nil, "OVERLAY")
                spellLabel:SetFontObject(GetFontObj(moduleDB.font or "default", 11, "outline"))
                spellLabel:SetPoint("LEFT", icon, "RIGHT", 8, 0)
                spellLabel:SetTextColor(unpack(MedaUI.Theme.text))
                spellLabel:SetText(entry.name)

                local cdLabel = detectedFrame:CreateFontString(nil, "OVERLAY")
                cdLabel:SetFontObject(GetFontObj(moduleDB.font or "default", 11, "outline"))
                cdLabel:SetPoint("RIGHT", detectedFrame, "TOPRIGHT", -10, rowY - 1)
                cdLabel:SetJustifyH("RIGHT")
                cdLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
                cdLabel:SetText(format("%s  %ds",
                    IsStunCategory(entry.category) and "Stun" or (entry.category or "Stop"),
                    entry.cd or 0))

                rowY = rowY - 22
            end

            generalY = generalY - (30 + (#detectedStops * 22))
        end

        local trackedEntries = GetDisplayEntries(GetTime())
        local stunEntries = GetStunDisplayEntries(GetTime())
        if moduleDB.splitStunsToSeparateWindow == true then
            for _, entry in ipairs(stunEntries) do
                trackedEntries[#trackedEntries + 1] = entry
            end
        end

        if #trackedEntries > 0 then
            local partyLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            partyLabel:SetPoint("TOPLEFT", LEFT_X, generalY)
            partyLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
            partyLabel:SetText(format("Tracking %d stop entries", #trackedEntries))
            generalY = generalY - 20

            for _, entry in ipairs(trackedEntries) do
                local trackedLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                trackedLabel:SetPoint("TOPLEFT", LEFT_X + 12, generalY)
                trackedLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
                trackedLabel:SetText(format("- %s: %s (%ds)",
                    entry.name,
                    entry.data.name or "Stop",
                    entry.info.baseCd or entry.data.cd or 15))
                generalY = generalY - 18
            end
        end

        generalHeight = math.abs(generalY - 10)
    end

    do
        local p = tabs["sizingfont"]
        local sizingY = 0

        local sizeHeader = MedaUI:CreateSectionHeader(p, "Sizing & Font")
        sizeHeader:SetPoint("TOPLEFT", LEFT_X, sizingY)
        sizingY = sizingY - 45

        local fontPicker = MedaUI:CreateLabeledDropdown(p, "Font", 200, MedaUI:GetFontList(), "font")
        fontPicker:SetPoint("TOPLEFT", LEFT_X, sizingY)
        fontPicker:SetSelected(moduleDB.font or "default")
        fontPicker.OnValueChanged = function(_, value)
            moduleDB.font = value
            RefreshVisualLayout()
        end

        local playerOutlineDD = MedaUI:CreateLabeledDropdown(p, "Player Name Outline", 200, {
            { value = "none", label = "None" },
            { value = "outline", label = "Outline" },
            { value = "thick", label = "Thick Outline" },
        })
        playerOutlineDD:SetPoint("TOPLEFT", RIGHT_X, sizingY)
        playerOutlineDD:SetSelected(moduleDB.playerNameOutline or "outline")
        playerOutlineDD.OnValueChanged = function(_, value)
            moduleDB.playerNameOutline = value
            RefreshVisualState()
        end
        sizingY = sizingY - 55

        local titleSizeSlider = MedaUI:CreateLabeledSlider(p, "Title Text Size", 200, 8, 32, 1)
        titleSizeSlider:SetPoint("TOPLEFT", LEFT_X, sizingY)
        titleSizeSlider:SetValue(moduleDB.titleFontSize or 12)
        titleSizeSlider.OnValueChanged = function(_, value)
            moduleDB.titleFontSize = value
            RefreshVisualLayout()
        end

        local nameSizeSlider = MedaUI:CreateLabeledSlider(p, "Name Text Size", 200, 0, 48, 1)
        nameSizeSlider:SetPoint("TOPLEFT", RIGHT_X, sizingY)
        nameSizeSlider:SetValue(moduleDB.nameFontSize or 0)
        nameSizeSlider.OnValueChanged = function(_, value)
            moduleDB.nameFontSize = value
            RefreshVisualLayout()
        end
        sizingY = sizingY - 55

        local cdSizeSlider = MedaUI:CreateLabeledSlider(p, "Cooldown/Ready Text Size", 200, 0, 48, 1)
        cdSizeSlider:SetPoint("TOPLEFT", LEFT_X, sizingY)
        cdSizeSlider:SetValue(moduleDB.readyFontSize or 0)
        cdSizeSlider.OnValueChanged = function(_, value)
            moduleDB.readyFontSize = value
            RefreshVisualLayout()
        end

        local iconSizeSlider = MedaUI:CreateLabeledSlider(p, "Icon Size", 200, 0, 48, 1)
        iconSizeSlider:SetPoint("TOPLEFT", RIGHT_X, sizingY)
        iconSizeSlider:SetValue(moduleDB.iconSize or 0)
        iconSizeSlider.OnValueChanged = function(_, value)
            moduleDB.iconSize = value
            RefreshVisualLayout()
        end

        sizingHeight = math.abs(sizingY - 70)
    end

    MedaAuras:SetContentHeight(math.max(generalHeight, sizingHeight, 900) + 120)
end

-- ============================================================================
-- Register Module
-- ============================================================================

MedaAuras:RegisterModule({
    name        = MODULE_NAME,
    title       = "Interrupted",
    version     = MODULE_VERSION,
    stability   = MODULE_STABILITY,
    author      = "Medalink",
    description = "Tracks party interrupt cooldowns plus major stop tools in M+ and dungeons. "
               .. "Detects kicks, stuns, and other tracked stops and displays "
               .. "cooldown bars for each player, colored by class.",
    sidebarDesc = "Party stop tracker for M+ dungeons.",
    defaults    = MODULE_DEFAULTS,
    OnInitialize = OnInitialize,
    OnEnable    = OnEnable,
    OnDisable   = OnDisable,
    pages       = {
        { id = "settings", label = "Settings" },
    },
    buildPage   = function(_, parent)
        BuildSettingsPage(parent, MedaAuras:GetModuleDB(MODULE_NAME))
        return 1020
    end,
})
