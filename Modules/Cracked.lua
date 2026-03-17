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
local UnitName = UnitName
local UnitGUID = UnitGUID
local UnitExists = UnitExists
local UnitClass = UnitClass
local AuraUtil = AuraUtil
local C_CooldownViewer = C_CooldownViewer
local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local IsInGroup = IsInGroup
local C_Spell = C_Spell
local C_Timer = C_Timer
local IsSpellKnown = IsSpellKnown
local IsPlayerSpell = IsPlayerSpell

if MedaAuras and MedaAuras.Log then
    MedaAuras.Log("[Cracked] File loaded OK")
end

-- ============================================================================
-- Module Info
-- ============================================================================

local MODULE_NAME      = "Cracked"
local MODULE_VERSION   = "0.1"
local MODULE_STABILITY = "experimental"

-- ============================================================================
-- Shared Data
-- ============================================================================

local DD = ns.DefensiveData
local ALL_DEFENSIVES     = DD.ALL_DEFENSIVES
local CLASS_COLORS       = DD.CLASS_COLORS
local CLASS_DEFENSIVE_IDS = DD.CLASS_DEFENSIVE_IDS
local CATEGORY_INFO      = DD.CATEGORY_INFO
local ENTRY_TO_ID        = DD.ENTRY_TO_ID
local SPELL_SPEC_WHITELIST = DD.SPELL_SPEC_WHITELIST or {}

local FALLBACK_WHITE = { 1, 1, 1 }
local ACTIVE_COLOR   = { 0.2, 1.0, 0.2 }

-- ============================================================================
-- State
-- ============================================================================

local db

-- partyMembers[name] = {
--   class = "WARRIOR",
--   cds = {
--     [spellID] = { baseCd=180, cdEnd=<GetTime>, activeEnd=<GetTime>, lastUse=<GetTime> }
--   }
-- }
local partyMembers = {}
local myName, myClass
local myCds = {}  -- [spellID] = { baseCd, cdEnd, activeEnd, lastUse }

local mainFrame, titleText, resizeHandle
local bars = {}
local updateTicker
local isResizing = false
local shouldShowByZone = true
local spellMatchHandle
local rosterFrame
local blizzardProbeCount = 0

local MAX_BARS = 15

local FONT_FACE = GameFontNormal and GameFontNormal:GetFont() or "Fonts\\FRIZQT__.TTF"
local FONT_FLAGS = "OUTLINE"
local BAR_TEXTURE = "Interface\\BUTTONS\\WHITE8X8"

-- ============================================================================
-- Logging
-- ============================================================================

local function Log(msg)      MedaAuras.Log(format("[Cracked] %s", msg)) end
local function LogDebug(msg) MedaAuras.LogDebug(format("[Cracked] %s", msg)) end
local function LogWarn(msg)  MedaAuras.LogWarn(format("[Cracked] %s", msg)) end

-- ============================================================================
-- Category filter helper
-- ============================================================================

local function IsCategoryEnabled(category)
    if not db then return true end
    if category == "external" then return db.showExternals ~= false end
    if category == "party"    then return db.showPartyWide ~= false end
    if category == "major"    then return db.showMajor ~= false end
    if category == "personal" then return db.showPersonal end
    return true
end

local function FormatCandidateIDs(ids, lookupTable)
    if not ids or #ids == 0 then return "none" end

    local parts = {}
    for i, spellID in ipairs(ids) do
        if i > 5 then
            parts[#parts + 1] = format("+%d more", #ids - 5)
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

local function GetCachedSpecID(unit)
    if not unit or not UnitExists(unit) then return nil end
    local info = ns.Services.GroupInspector and ns.Services.GroupInspector:GetUnitInfo(unit)
    return info and info.specID or nil
end

local function BuildCandidateSet(cls, specID)
    local ids = CLASS_DEFENSIVE_IDS[cls]
    local candidateLookup = {}
    local candidateIDs = {}
    local classWideCount = 0

    if not ids then
        return candidateLookup, candidateIDs, classWideCount
    end

    for _, spellID in ipairs(ids) do
        local data = ALL_DEFENSIVES[spellID]
        if data and IsCategoryEnabled(data.category) then
            classWideCount = classWideCount + 1
            local allowed = true
            local whitelist = SPELL_SPEC_WHITELIST[spellID]
            if specID and whitelist and not whitelist[specID] then
                allowed = false
            end

            if allowed then
                candidateLookup[spellID] = data
                candidateIDs[#candidateIDs + 1] = spellID
            end
        end
    end

    table.sort(candidateIDs)
    return candidateLookup, candidateIDs, classWideCount
end

local function UpdateMemberDefensives(name, cls, specID, reason)
    local candidateLookup, candidateIDs, classWideCount = BuildCandidateSet(cls, specID)
    local oldInfo = partyMembers[name]
    local cds = {}

    for _, spellID in ipairs(candidateIDs) do
        local data = ALL_DEFENSIVES[spellID]
        local existing = oldInfo and oldInfo.cds and oldInfo.cds[spellID]
        cds[spellID] = existing or {
            baseCd = data.cd,
            cdEnd = 0,
            activeEnd = 0,
            lastUse = 0,
        }
    end

    partyMembers[name] = {
        class = cls,
        specID = specID,
        cds = cds,
        candidateLookup = candidateLookup,
        candidateIDs = candidateIDs,
        classWideCount = classWideCount,
    }

    Log(format("Registered %s (%s spec=%s) with %d/%d defensive candidates via %s",
        name, cls, tostring(specID), #candidateIDs, classWideCount, tostring(reason)))
    LogDebug(format("  CandidateIDs for %s: %s",
        name, FormatCandidateIDs(candidateIDs, candidateLookup)))
end

-- ============================================================================
-- Find own defensive spells
-- ============================================================================

local function FindMyDefensives()
    local _, cls = UnitClass("player")
    myClass = cls
    myName = UnitName("player")

    LogDebug(format("FindMyDefensives: class=%s name=%s", tostring(cls), tostring(myName)))

    wipe(myCds)

    local ids = CLASS_DEFENSIVE_IDS[cls]
    if not ids then
        LogDebug(format("  No defensive IDs for class=%s", tostring(cls)))
        return
    end

    local count = 0
    for _, spellID in ipairs(ids) do
        local data = ALL_DEFENSIVES[spellID]
        if data and IsCategoryEnabled(data.category) then
            local known = IsSpellKnown(spellID)
            if not known then
                local ok, r = pcall(IsPlayerSpell, spellID)
                if ok and r then known = true end
            end
            LogDebug(format("  spellID %d (%s) known=%s cat=%s",
                spellID, data.name, tostring(known), data.category))
            if known then
                myCds[spellID] = {
                    baseCd = data.cd,
                    cdEnd = 0,
                    activeEnd = 0,
                    lastUse = 0,
                }
                count = count + 1
            end
        end
    end

    Log(format("FindMyDefensives: found %d known defensives for %s (%s)", count, tostring(myName), tostring(cls)))
end

-- ============================================================================
-- Auto-register party members
-- ============================================================================

local function AutoRegisterParty()
    LogDebug(format("AutoRegisterParty: inGroup=%s", tostring(IsInGroup())))
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) then
            local name = UnitName(u)
            local _, cls = UnitClass(u)
            local role = UnitGroupRolesAssigned(u)
            local specID = GetCachedSpecID(u)
            LogDebug(format("  %s: name=%s class=%s role=%s already=%s",
                u, tostring(name), tostring(cls), tostring(role),
                tostring(name and partyMembers[name] ~= nil)))
            if name and cls then
                UpdateMemberDefensives(name, cls, specID, "roster")
            end
        else
            LogDebug(format("  %s: does not exist", u))
        end
    end

    local count = 0
    for _ in pairs(partyMembers) do count = count + 1 end
    LogDebug(format("  Total tracked: %d party members", count))
end

local function CleanPartyList()
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
    if removed > 0 then
        LogDebug(format("CleanPartyList: removed %d member(s)", removed))
    end
end

-- ============================================================================
-- Handle party defensive matched via PartySpellWatcher StatusBar equality test
--
-- PSW's OnPartySpellMatch uses StatusBar clamping to binary-test the tainted
-- spell ID against every key in ALL_DEFENSIVES.  On match, this callback
-- receives fully clean (name, cleanSpellID, defData, unit) args.
-- ============================================================================

local function ProbeCandidateAuras(name, unit, debugInfo)
    if not AuraUtil or not unit or not UnitExists(unit) or not debugInfo or not debugInfo.candidateIDs then
        return
    end

    local function RunProbe(tag)
        local active = {}
        for _, spellID in ipairs(debugInfo.candidateIDs) do
            local defData = ALL_DEFENSIVES[spellID]
            if defData then
                local ok, aura = pcall(AuraUtil.FindAuraByName, defData.name, unit, "HELPFUL")
                if ok and aura then
                    active[#active + 1] = defData.name
                end
            end
        end
        LogDebug(format("AuraProbe[%s] %s unit=%s candidates=%s active=%s",
            tag, name, tostring(unit),
            FormatCandidateIDs(debugInfo.candidateIDs, debugInfo.candidateLookup),
            #active > 0 and table.concat(active, ", ") or "none"))
    end

    RunProbe("0.0")
    C_Timer.After(0.2, function()
        RunProbe("0.2")
    end)
end

local BLIZZ_VIEWERS = {
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
}

local function ProbeBlizzardUISurfaces(reason)
    blizzardProbeCount = blizzardProbeCount + 1
    if blizzardProbeCount > 12 then return end

    LogDebug(format("BlizzardUIProbe[%d]: reason=%s C_CooldownViewer=%s",
        blizzardProbeCount, tostring(reason), tostring(C_CooldownViewer ~= nil)))

    for _, viewerName in ipairs(BLIZZ_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            local ok, children = pcall(function() return { viewer:GetChildren() } end)
            local childCount = ok and #children or 0
            LogDebug(format("  Viewer %s exists shown=%s children=%d",
                viewerName, tostring(viewer:IsShown()), childCount))

            if ok and children then
                for idx, child in ipairs(children) do
                    if idx > 4 then break end
                    local cdID = child.cooldownID or (child.cooldownInfo and child.cooldownInfo.cooldownID)
                    local spellID = child.spellID
                    local itemID = child.itemID
                    local info = nil
                    if cdID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
                        local okInfo, rInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
                        if okInfo then info = rInfo end
                    end
                    LogDebug(format("    child[%d] name=%s shown=%s cdID=%s spellID=%s itemID=%s infoSpell=%s",
                        idx,
                        tostring(child.GetName and child:GetName() or nil),
                        tostring(child.IsShown and child:IsShown() or false),
                        tostring(cdID),
                        tostring(spellID),
                        tostring(itemID),
                        tostring(info and (info.overrideSpellID or info.spellID) or nil)))
                end
            end
        else
            LogDebug(format("  Viewer %s missing", viewerName))
        end
    end

    for i = 1, 4 do
        local partyFrame = _G["CompactPartyFrameMember" .. i]
        if partyFrame then
            local okChildren, children = pcall(function() return { partyFrame:GetChildren() } end)
            local okRegions, regions = pcall(function() return { partyFrame:GetRegions() } end)
            LogDebug(format("  CompactPartyFrameMember%d shown=%s children=%d regions=%d",
                i,
                tostring(partyFrame:IsShown()),
                okChildren and #children or -1,
                okRegions and #regions or -1))
        end
    end
end

local function ResolveDefensiveCandidates(name, unit)
    local info = partyMembers[name]
    if info and info.candidateLookup and info.candidateIDs then
        return {
            lookupTable = info.candidateLookup,
            knownIDs = info.candidateIDs,
            label = format("%s:%s", tostring(info.class), tostring(info.specID or "nospec")),
        }
    end

    if unit and UnitExists(unit) then
        local _, cls = UnitClass(unit)
        local specID = GetCachedSpecID(unit)
        if cls then
            local lookupTable, knownIDs = BuildCandidateSet(cls, specID)
            return {
                lookupTable = lookupTable,
                knownIDs = knownIDs,
                label = format("%s:%s(ephemeral)", tostring(cls), tostring(specID or "nospec")),
            }
        end
    end
end

local function OnPartyDefensiveMatch(name, cleanSpellID, defData, unit, debugInfo)
    if not IsCategoryEnabled(defData.category) then
        LogDebug(format("FILTERED (cat disabled): %s cast %s (ID %d, cat=%s)",
            name, defData.name, cleanSpellID, defData.category))
        return
    end

    local now = GetTime()

    Log(format("PARTY DEFENSIVE: %s cast %s (ID %d, cat=%s, CD=%ds, dur=%ds, confidence=%s via=%s)",
        name, defData.name, cleanSpellID, defData.category,
        defData.cd, defData.duration,
        tostring(debugInfo and debugInfo.confidence or "unknown"),
        tostring(debugInfo and debugInfo.chosenBy or "unknown")))
    if debugInfo then
        LogDebug(format("  MatchDebug cast=%s cleanID=%s candidates=%s",
            tostring(debugInfo.castID),
            tostring(debugInfo.cleanID),
            FormatCandidateIDs(debugInfo.candidateIDs, debugInfo.candidateLookup)))
    end

    local info = partyMembers[name]
    if not info then
        for i = 1, 4 do
            local u = "party" .. i
            if UnitExists(u) and UnitName(u) == name then
                local _, cls = UnitClass(u)
                local specID = GetCachedSpecID(u)
                if cls then
                    UpdateMemberDefensives(name, cls, specID, "late-cast")
                    info = partyMembers[name]
                end
                break
            end
        end
    end

    if info then
        if not info.cds[cleanSpellID] then
            info.cds[cleanSpellID] = {
                baseCd = defData.cd,
                cdEnd = 0,
                activeEnd = 0,
                lastUse = 0,
            }
            LogDebug(format("  Late-added spell %d (%s) for %s", cleanSpellID, defData.name, name))
        end

        local cd = info.cds[cleanSpellID]
        cd.cdEnd = now + defData.cd
        cd.activeEnd = defData.duration > 0 and (now + defData.duration) or 0
        cd.lastUse = now

        Log(format("  STATE -> ACTIVE: %s %s activeEnd=%.1f cdEnd=%.1f",
            name, defData.name,
            cd.activeEnd > 0 and cd.activeEnd or 0,
            cd.cdEnd))
    else
        LogWarn(format("  Could not register %s from %s", name, tostring(unit)))
    end

    ProbeCandidateAuras(name, unit, debugInfo)
    ProbeBlizzardUISurfaces("match:" .. tostring(defData.name))
end

-- ============================================================================
-- Own defensive tracking
-- ============================================================================

local playerCastFrame

local function SetupOwnTracking()
    if playerCastFrame then
        LogDebug("SetupOwnTracking: already set up")
        return
    end
    playerCastFrame = CreateFrame("Frame")
    playerCastFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    playerCastFrame:SetScript("OnEvent", function(_, _, unit, _, spellID)
        local defData = ALL_DEFENSIVES[spellID]
        if not defData then return end
        if not IsCategoryEnabled(defData.category) then return end

        local cd = myCds[spellID]
        if not cd then
            cd = { baseCd = defData.cd, cdEnd = 0, activeEnd = 0, lastUse = 0 }
            myCds[spellID] = cd
        end

        local now = GetTime()
        cd.cdEnd = now + defData.cd
        cd.activeEnd = defData.duration > 0 and (now + defData.duration) or 0
        cd.lastUse = now

        Log(format("OWN DEFENSIVE: %s (ID %d, cat=%s, CD=%ds, dur=%ds) activeEnd=%.1f cdEnd=%.1f",
            defData.name, spellID, defData.category,
            defData.cd, defData.duration,
            cd.activeEnd > 0 and cd.activeEnd or 0,
            cd.cdEnd))
    end)
    LogDebug("SetupOwnTracking: registered UNIT_SPELLCAST_SUCCEEDED for player")
end

local function TeardownOwnTracking()
    if playerCastFrame then
        playerCastFrame:UnregisterAllEvents()
        playerCastFrame = nil
    end
end

-- ============================================================================
-- UI: Bar layout
-- ============================================================================

local function GetBarLayout()
    local fw = db.frameWidth
    local titleH = db.showTitle and 20 or 0
    local barH = math.max(12, db.barHeight)
    local iconS = (db.showIcons ~= false) and barH or 0
    local barW = math.max(60, fw - iconS)
    local autoNameSize = math.max(9, math.floor(barH * 0.45))
    local autoCdSize = math.max(10, math.floor(barH * 0.55))
    local fontSize = (db.nameFontSize and db.nameFontSize > 0) and db.nameFontSize or autoNameSize
    local cdFontSize = (db.readyFontSize and db.readyFontSize > 0) and db.readyFontSize or autoCdSize
    return barW, barH, iconS, fontSize, cdFontSize, titleH
end

local function RebuildBars()
    for i = 1, MAX_BARS do
        if bars[i] then
            bars[i]:Hide()
            bars[i]:SetParent(nil)
            bars[i] = nil
        end
    end

    local barW, barH, iconS, fontSize, cdFontSize, titleH = GetBarLayout()
    mainFrame:SetWidth(db.frameWidth)
    mainFrame:SetAlpha(db.alpha)

    if titleText then
        if db.showTitle then titleText:Show() else titleText:Hide() end
    end

    for i = 1, MAX_BARS do
        local yOff
        if db.growUp then
            yOff = (i - 1) * (barH + 1)
        else
            yOff = -(titleH + (i - 1) * (barH + 1))
        end

        local f = CreateFrame("Frame", nil, mainFrame)
        f:SetSize(iconS + barW, barH)
        if db.growUp then
            f:SetPoint("BOTTOMLEFT", 0, yOff)
        else
            f:SetPoint("TOPLEFT", 0, yOff)
        end

        local ico = f:CreateTexture(nil, "ARTWORK")
        ico:SetSize(iconS, barH)
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
        nm:SetFont(FONT_FACE, fontSize, FONT_FLAGS)
        nm:SetPoint("LEFT", 6, 0)
        nm:SetJustifyH("LEFT")
        nm:SetWidth(barW - 50)
        nm:SetWordWrap(false)
        nm:SetShadowOffset(1, -1)
        nm:SetShadowColor(0, 0, 0, 1)
        if db.showNames == false then nm:Hide() end
        f.nameText = nm

        local cdTxt = content:CreateFontString(nil, "OVERLAY")
        cdTxt:SetFont(FONT_FACE, cdFontSize, FONT_FLAGS)
        cdTxt:SetPoint("RIGHT", -6, 0)
        cdTxt:SetShadowOffset(1, -1)
        cdTxt:SetShadowColor(0, 0, 0, 1)
        f.cdText = cdTxt

        f:Hide()
        bars[i] = f
    end

    if resizeHandle then resizeHandle:Raise() end
end

-- ============================================================================
-- UI: Collect active/cd entries for display, sorted by priority
-- ============================================================================

local function CollectDisplayEntries()
    local entries = {}
    local now = GetTime()

    local function AddEntries(name, cls, cds, isPlayer)
        for spellID, cd in pairs(cds) do
            local defData = ALL_DEFENSIVES[spellID]
            if defData and IsCategoryEnabled(defData.category) then
                local isActive = cd.activeEnd > now
                local isOnCd = cd.cdEnd > now
                if isActive or isOnCd then
                    local catInfo = CATEGORY_INFO[defData.category]
                    entries[#entries + 1] = {
                        name = name,
                        class = cls,
                        spellID = spellID,
                        spellName = defData.name,
                        icon = defData.icon,
                        category = defData.category,
                        catPriority = catInfo and catInfo.priority or 99,
                        isActive = isActive,
                        activeEnd = cd.activeEnd,
                        cdEnd = cd.cdEnd,
                        baseCd = cd.baseCd,
                        duration = defData.duration,
                        isPlayer = isPlayer,
                    }
                end
            end
        end
    end

    AddEntries(myName or "You", myClass or "WARRIOR", myCds, true)

    for name, info in pairs(partyMembers) do
        AddEntries(name, info.class, info.cds, false)
    end

    table.sort(entries, function(a, b)
        if a.isActive ~= b.isActive then return a.isActive end
        if a.catPriority ~= b.catPriority then return a.catPriority < b.catPriority end
        if a.isActive then
            return a.activeEnd < b.activeEnd
        end
        return a.cdEnd < b.cdEnd
    end)

    return entries
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
    LogDebug(format("CheckZoneVisibility: instanceType=%s showByZone=%s",
        tostring(instanceType), tostring(shouldShowByZone)))
    if mainFrame then
        if shouldShowByZone then mainFrame:Show() else mainFrame:Hide() end
    end
end

local lastStateDump = 0

local function UpdateDisplay()
    if not mainFrame or not shouldShowByZone then return end

    local _, barH, _, _, _, titleH = GetBarLayout()
    local now = GetTime()

    if now - lastStateDump > 10 then
        lastStateDump = now
        local memberCount = 0
        local totalTracked = 0
        for n, info in pairs(partyMembers) do
            memberCount = memberCount + 1
            for sid, cd in pairs(info.cds) do
                totalTracked = totalTracked + 1
                local defData = ALL_DEFENSIVES[sid]
                local isActive = cd.activeEnd > now
                local isOnCd = cd.cdEnd > now
                if isActive or isOnCd then
                    LogDebug(format("  STATE: %s %s active=%s activeRem=%.1f cdRem=%.1f",
                        n, defData and defData.name or tostring(sid),
                        tostring(isActive),
                        isActive and (cd.activeEnd - now) or 0,
                        isOnCd and (cd.cdEnd - now) or 0))
                end
            end
        end
        local myCount = 0
        for _ in pairs(myCds) do myCount = myCount + 1 end
        LogDebug(format("UpdateDisplay tick: myDefensives=%d members=%d totalTracked=%d visible=%s",
            myCount, memberCount, totalTracked, tostring(shouldShowByZone)))
    end

    local entries = CollectDisplayEntries()

    for i = 1, MAX_BARS do
        local entry = entries[i]
        local bar = bars[i]
        if not bar then break end

        if entry then
            bar:Show()
            bar.icon:SetTexture(entry.icon)
            local col = CLASS_COLORS[entry.class] or FALLBACK_WHITE

            local label = entry.name
            if db.showSpellName then
                label = label .. " - " .. entry.spellName
            end
            bar.nameText:SetText("|cFFFFFFFF" .. label .. "|r")

            if entry.isActive then
                local rem = entry.activeEnd - now
                bar.cdBar:SetMinMaxValues(0, entry.duration)
                bar.cdBar:SetValue(rem)
                bar.cdBar:SetStatusBarColor(ACTIVE_COLOR[1], ACTIVE_COLOR[2], ACTIVE_COLOR[3], 0.85)
                bar.barBg:SetVertexColor(ACTIVE_COLOR[1] * 0.25, ACTIVE_COLOR[2] * 0.25, ACTIVE_COLOR[3] * 0.25, 0.9)
                bar.cdText:SetText(format("%.1fs", rem))
                bar.cdText:SetTextColor(0.2, 1.0, 0.2)
            else
                local rem = entry.cdEnd - now
                bar.cdBar:SetMinMaxValues(0, entry.baseCd)
                bar.cdBar:SetValue(rem)
                bar.cdBar:SetStatusBarColor(col[1], col[2], col[3], 0.85)
                bar.barBg:SetVertexColor(col[1] * 0.25, col[2] * 0.25, col[3] * 0.25, 0.9)
                bar.cdText:SetText(format("%.0f", rem))
                bar.cdText:SetTextColor(1, 1, 1)
            end
        else
            bar:Hide()
        end
    end

    if not isResizing then
        local numVisible = math.min(#entries, MAX_BARS)
        if numVisible > 0 then
            mainFrame:SetHeight(titleH + numVisible * (barH + 1))
        else
            mainFrame:SetHeight(titleH + barH + 1)
        end
    end
end

-- ============================================================================
-- UI: Create main frame
-- ============================================================================

local function CreateUI()
    if mainFrame then
        LogDebug("CreateUI: mainFrame already exists, skipping")
        return
    end
    LogDebug("CreateUI: building main frame...")

    mainFrame = CreateFrame("Frame", "MedaAurasCrackedFrame", UIParent)
    mainFrame:SetSize(db.frameWidth, 200)
    mainFrame:SetFrameStrata("MEDIUM")
    mainFrame:SetClampedToScreen(true)
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", function(self)
        if not db.locked then self:StartMoving() end
    end)
    mainFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        db.position.point = point
        db.position.x = x
        db.position.y = y
    end)
    mainFrame:SetAlpha(db.alpha)
    mainFrame:SetResizable(true)
    mainFrame:SetResizeBounds(80, 40, 600, 800)

    local bg = mainFrame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(BAR_TEXTURE)
    bg:SetVertexColor(0.05, 0.05, 0.05, 0.85)

    titleText = mainFrame:CreateFontString(nil, "OVERLAY")
    titleText:SetFont(FONT_FACE, 12, FONT_FLAGS)
    titleText:SetPoint("TOP", 0, -3)
    titleText:SetText("|cFF00DDDDDefensives|r")
    if not db.showTitle then titleText:Hide() end

    resizeHandle = CreateFrame("Button", nil, mainFrame)
    resizeHandle:SetSize(16, 16)
    resizeHandle:SetPoint("BOTTOMRIGHT", 0, 0)
    resizeHandle:SetFrameLevel(mainFrame:GetFrameLevel() + 10)
    resizeHandle:EnableMouse(true)

    for j = 0, 2 do
        local line = resizeHandle:CreateTexture(nil, "OVERLAY", nil, 1)
        line:SetTexture(BAR_TEXTURE)
        line:SetVertexColor(0.6, 0.8, 0.9, 0.7)
        line:SetSize(1, (3 - j) * 4)
        line:SetPoint("BOTTOMRIGHT", -(j * 4 + 2), 2)
    end

    resizeHandle:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" and not db.locked then
            isResizing = true
            mainFrame:StartSizing("BOTTOMRIGHT")
        end
    end)
    resizeHandle:SetScript("OnMouseUp", function()
        mainFrame:StopMovingOrSizing()
        isResizing = false
        db.frameWidth = math.floor(mainFrame:GetWidth())
        local numVisible = 0
        for i = 1, MAX_BARS do
            if bars[i] and bars[i]:IsShown() then numVisible = numVisible + 1 end
        end
        if numVisible < 1 then numVisible = 1 end
        local titleH = db.showTitle and 20 or 0
        local dragH = mainFrame:GetHeight() - titleH
        db.barHeight = math.max(12, math.floor(dragH / numVisible) - 1)
        RebuildBars()
    end)

    mainFrame:ClearAllPoints()
    mainFrame:SetPoint(db.position.point, UIParent, db.position.point, db.position.x, db.position.y)
    mainFrame:Show()

    LogDebug(format("CreateUI: frame positioned at %s (%.0f, %.0f), now building bars",
        db.position.point, db.position.x, db.position.y))
    RebuildBars()
    LogDebug("CreateUI: complete")
end

local function DestroyUI()
    if updateTicker then updateTicker:Cancel(); updateTicker = nil end
    if mainFrame then mainFrame:Hide() end
end

-- ============================================================================
-- Roster event frame
-- ============================================================================

local function SetupRosterEvents()
    if rosterFrame then return end
    rosterFrame = CreateFrame("Frame")
    rosterFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    rosterFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    rosterFrame:RegisterEvent("SPELLS_CHANGED")
    rosterFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    rosterFrame:SetScript("OnEvent", function(_, event, arg1)
        LogDebug(format("Roster event: %s arg1=%s", event, tostring(arg1)))
        if event == "GROUP_ROSTER_UPDATE" then
            CleanPartyList()
            AutoRegisterParty()
        elseif event == "PLAYER_ENTERING_WORLD" then
            CheckZoneVisibility()
            AutoRegisterParty()
        elseif event == "SPELLS_CHANGED" then
            FindMyDefensives()
        elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
            if arg1 == "player" then
                FindMyDefensives()
            end
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
-- GroupInspector callback (update tracked defensives on spec change)
-- ============================================================================

local function OnInspectComplete(unit, name, class, specID)
    LogDebug(format("OnInspectComplete: unit=%s name=%s class=%s specID=%s",
        tostring(unit), tostring(name), tostring(class), tostring(specID)))

    local info = partyMembers[name]
    if not info then
        LogDebug(format("  -> %s not tracked, skipping", tostring(name)))
        return
    end

    UpdateMemberDefensives(name, class or info.class, specID, "inspect")
    info = partyMembers[name]
    LogDebug(format("  -> %s tracked with %d defensive entries, specID=%d",
        name, (function() local n=0 for _ in pairs(info.cds) do n=n+1 end return n end)(), specID))
end

-- ============================================================================
-- Module Lifecycle
-- ============================================================================

local function OnInitialize(moduleDB)
    db = moduleDB
    Log("OnInitialize starting...")

    LogDebug(format("  db.enabled=%s", tostring(moduleDB.enabled)))
    LogDebug(format("  ns.DefensiveData=%s", tostring(ns.DefensiveData ~= nil)))
    LogDebug(format("  ns.Services.PartySpellWatcher=%s", tostring(ns.Services.PartySpellWatcher ~= nil)))
    LogDebug(format("  ns.Services.GroupInspector=%s", tostring(ns.Services.GroupInspector ~= nil)))
    if ns.Services.GroupInspector and ns.Services.GroupInspector.Initialize then
        ns.Services.GroupInspector:Initialize()
    end

    LogDebug("  Step 1: FindMyDefensives")
    FindMyDefensives()

    LogDebug("  Step 2: CreateUI")
    CreateUI()
    LogDebug(format("  mainFrame created: %s", tostring(mainFrame ~= nil)))

    LogDebug("  Step 3: CheckZoneVisibility")
    CheckZoneVisibility()

    LogDebug("  Step 4: SetupOwnTracking")
    SetupOwnTracking()

    LogDebug("  Step 5: SetupRosterEvents")
    SetupRosterEvents()

    LogDebug("  Step 6: AutoRegisterParty")
    AutoRegisterParty()

    LogDebug("  Step 7: Register PartySpellWatcher spell match for defensives")
    ns.Services.PartySpellWatcher:Initialize()
    spellMatchHandle = ns.Services.PartySpellWatcher:OnPartySpellMatch({
        label = "CrackedDefensives",
        lookupTable = ALL_DEFENSIVES,
        candidateResolver = ResolveDefensiveCandidates,
        entryToID = ENTRY_TO_ID,
        callback = OnPartyDefensiveMatch,
    })
    Log(format("  spellMatchHandle=%s", tostring(spellMatchHandle)))

    LogDebug("  Step 8: Register GroupInspector inspect-complete callback")
    ns.Services.GroupInspector:RegisterInspectComplete("Cracked", OnInspectComplete)

    LogDebug("  Step 9: Start UpdateDisplay ticker (0.1s)")
    if updateTicker then updateTicker:Cancel() end
    updateTicker = C_Timer.NewTicker(0.1, UpdateDisplay)

    ProbeBlizzardUISurfaces("init")
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
    TeardownOwnTracking()
    TeardownRosterEvents()

    if spellMatchHandle then
        ns.Services.PartySpellWatcher:Unregister(spellMatchHandle)
        spellMatchHandle = nil
    end

    ns.Services.GroupInspector:UnregisterInspectComplete("Cracked")

    wipe(partyMembers)
    wipe(myCds)
end

-- ============================================================================
-- Module Defaults
-- ============================================================================

local MODULE_DEFAULTS = {
    enabled = false,
    frameWidth = 240,
    barHeight = 24,
    locked = false,
    showTitle = true,
    showIcons = true,
    showNames = true,
    showSpellName = false,
    growUp = false,
    alpha = 0.9,
    nameFontSize = 0,
    readyFontSize = 0,
    showExternals = true,
    showPartyWide = true,
    showMajor = true,
    showPersonal = false,
    showInDungeon = true,
    showInRaid = true,
    showInOpenWorld = false,
    showInArena = true,
    showInBG = false,
    position = { point = "CENTER", x = 250, y = -150 },
}

-- ============================================================================
-- Preview
-- ============================================================================

local pvContainer, pvInner, pvBars, pvTitleText
local pvTicker
local pvStartTime = 0

local PREVIEW_MOCK = {
    { name = "Tanksworth",  class = "WARRIOR",     spellID = 97462,  baseCd = 180, duration = 10, cdOffset = 60 },
    { name = "Stabsworth",  class = "ROGUE",       spellID = 31224,  baseCd = 120, duration = 5,  cdOffset = 0  },
    { name = "Frostbyte",   class = "MAGE",        spellID = 45438,  baseCd = 240, duration = 10, cdOffset = 100 },
    { name = "Healbot",     class = "PRIEST",      spellID = 33206,  baseCd = 180, duration = 8,  cdOffset = 30 },
    { name = "Felrush",     class = "DEMONHUNTER", spellID = 196718, baseCd = 180, duration = 8,  cdOffset = 0  },
}

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

    local barW, barH, iconS, fontSize, cdFontSize, titleH = GetBarLayout()

    if db.showTitle then
        pvTitleText = pvInner:CreateFontString(nil, "OVERLAY")
        pvTitleText:SetFont(FONT_FACE, 12, FONT_FLAGS)
        pvTitleText:SetPoint("TOP", 0, -3)
        pvTitleText:SetText("|cFF00DDDDDefensives|r")
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
        ico:SetSize(iconS, barH)
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
        nm:SetFont(FONT_FACE, fontSize, FONT_FLAGS)
        nm:SetPoint("LEFT", 6, 0)
        nm:SetJustifyH("LEFT")
        nm:SetWidth(barW - 50)
        nm:SetWordWrap(false)
        nm:SetShadowOffset(1, -1)
        nm:SetShadowColor(0, 0, 0, 1)
        if db.showNames == false then nm:Hide() end
        f.nameText = nm

        local cdTxt = content:CreateFontString(nil, "OVERLAY")
        cdTxt:SetFont(FONT_FACE, cdFontSize, FONT_FLAGS)
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
    local _, barH, _, _, _, titleH = GetBarLayout()

    for i, mock in ipairs(PREVIEW_MOCK) do
        local bar = pvBars[i]
        if not bar then break end

        local defData = ALL_DEFENSIVES[mock.spellID]
        if defData then
            bar.icon:SetTexture(defData.icon)
            local col = CLASS_COLORS[mock.class] or FALLBACK_WHITE

            local label = mock.name
            if db.showSpellName then
                label = label .. " - " .. defData.name
            end
            bar.nameText:SetText("|cFFFFFFFF" .. label .. "|r")

            local readyWindow = 5
            local activeWindow = mock.duration
            local cycleLen = mock.baseCd + readyWindow
            local pos = (elapsed + mock.cdOffset) % cycleLen

            if pos < activeWindow then
                local rem = activeWindow - pos
                bar.cdBar:SetMinMaxValues(0, activeWindow)
                bar.cdBar:SetValue(rem)
                bar.cdBar:SetStatusBarColor(ACTIVE_COLOR[1], ACTIVE_COLOR[2], ACTIVE_COLOR[3], 0.85)
                bar.barBg:SetVertexColor(ACTIVE_COLOR[1] * 0.25, ACTIVE_COLOR[2] * 0.25, ACTIVE_COLOR[3] * 0.25, 0.9)
                bar.cdText:SetText(format("%.1fs", rem))
                bar.cdText:SetTextColor(0.2, 1.0, 0.2)
            elseif pos < mock.baseCd then
                local rem = mock.baseCd - pos
                bar.cdBar:SetMinMaxValues(0, mock.baseCd)
                bar.cdBar:SetValue(rem)
                bar.cdBar:SetStatusBarColor(col[1], col[2], col[3], 0.85)
                bar.barBg:SetVertexColor(col[1] * 0.25, col[2] * 0.25, col[3] * 0.25, 0.9)
                bar.cdText:SetText(format("%.0f", rem))
                bar.cdText:SetTextColor(1, 1, 1)
            else
                bar.cdBar:SetMinMaxValues(0, 1)
                bar.cdBar:SetValue(0)
                bar.barBg:SetVertexColor(col[1], col[2], col[3], 0.85)
                bar.cdText:SetText("READY")
                bar.cdText:SetTextColor(0.2, 1.0, 0.2)
            end
        end
    end

    pvContainer:SetAlpha(db.alpha)
    pvContainer:SetSize(db.frameWidth, titleH + #PREVIEW_MOCK * (barH + 1))
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

            local pvBg = pvContainer:CreateTexture(nil, "BACKGROUND")
            pvBg:SetAllPoints()
            pvBg:SetTexture(BAR_TEXTURE)
            pvBg:SetVertexColor(0.08, 0.08, 0.08, 0.85)

            pvStartTime = GetTime()
            CreatePreviewBars()
            UpdatePreview()

            pvTicker = C_Timer.NewTicker(0.1, UpdatePreview)
        end
    end

    local LEFT_X = 0
    local yOff = 0

    local header = MedaUI:CreateSectionHeader(parent, "Cracked", 470)
    header:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 40

    local enableCB = MedaUI:CreateCheckbox(parent, "Enable Module")
    enableCB:SetPoint("TOPLEFT", LEFT_X, yOff)
    enableCB:SetChecked(moduleDB.enabled)
    enableCB.OnValueChanged = function(_, checked)
        if checked then MedaAuras:EnableModule(MODULE_NAME)
        else MedaAuras:DisableModule(MODULE_NAME) end
        MedaAuras:RefreshSidebarDot(MODULE_NAME)
    end
    yOff = yOff - 42

    local catHeader = MedaUI:CreateSectionHeader(parent, "Track Categories", 470)
    catHeader:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 40

    local extCB = MedaUI:CreateCheckbox(parent, "Externals (Pain Supp, Ironbark, etc.)")
    extCB:SetPoint("TOPLEFT", LEFT_X, yOff)
    extCB:SetChecked(moduleDB.showExternals ~= false)
    extCB.OnValueChanged = function(_, checked)
        moduleDB.showExternals = checked
        RebuildPreview()
    end
    yOff = yOff - 32

    local partyCB = MedaUI:CreateCheckbox(parent, "Party-Wide (Rally, AMZ, Darkness, etc.)")
    partyCB:SetPoint("TOPLEFT", LEFT_X, yOff)
    partyCB:SetChecked(moduleDB.showPartyWide ~= false)
    partyCB.OnValueChanged = function(_, checked)
        moduleDB.showPartyWide = checked
        RebuildPreview()
    end
    yOff = yOff - 32

    local majorCB = MedaUI:CreateCheckbox(parent, "Major Personals (Wall, IBF, Ice Block, etc.)")
    majorCB:SetPoint("TOPLEFT", LEFT_X, yOff)
    majorCB:SetChecked(moduleDB.showMajor ~= false)
    majorCB.OnValueChanged = function(_, checked)
        moduleDB.showMajor = checked
        RebuildPreview()
    end
    yOff = yOff - 32

    local persCB = MedaUI:CreateCheckbox(parent, "Minor Personals (Barkskin, AMS, Feint, etc.)")
    persCB:SetPoint("TOPLEFT", LEFT_X, yOff)
    persCB:SetChecked(moduleDB.showPersonal)
    persCB.OnValueChanged = function(_, checked)
        moduleDB.showPersonal = checked
        RebuildPreview()
    end
    yOff = yOff - 42

    local dispHeader = MedaUI:CreateSectionHeader(parent, "Display", 470)
    dispHeader:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 40

    local titleCB = MedaUI:CreateCheckbox(parent, "Show Title")
    titleCB:SetPoint("TOPLEFT", LEFT_X, yOff)
    titleCB:SetChecked(moduleDB.showTitle)
    titleCB.OnValueChanged = function(_, checked)
        moduleDB.showTitle = checked
        if mainFrame then RebuildBars() end
        RebuildPreview()
    end

    local lockCB = MedaUI:CreateCheckbox(parent, "Lock Position")
    lockCB:SetPoint("TOPLEFT", 240, yOff)
    lockCB:SetChecked(moduleDB.locked)
    lockCB.OnValueChanged = function(_, checked) moduleDB.locked = checked end
    yOff = yOff - 32

    local iconsCB = MedaUI:CreateCheckbox(parent, "Show Icons")
    iconsCB:SetPoint("TOPLEFT", LEFT_X, yOff)
    iconsCB:SetChecked(moduleDB.showIcons ~= false)
    iconsCB.OnValueChanged = function(_, checked)
        moduleDB.showIcons = checked
        if mainFrame then RebuildBars() end
        RebuildPreview()
    end

    local namesCB = MedaUI:CreateCheckbox(parent, "Show Names")
    namesCB:SetPoint("TOPLEFT", 240, yOff)
    namesCB:SetChecked(moduleDB.showNames ~= false)
    namesCB.OnValueChanged = function(_, checked)
        moduleDB.showNames = checked
        if mainFrame then RebuildBars() end
        RebuildPreview()
    end
    yOff = yOff - 32

    local spellCB = MedaUI:CreateCheckbox(parent, "Show Spell Name")
    spellCB:SetPoint("TOPLEFT", LEFT_X, yOff)
    spellCB:SetChecked(moduleDB.showSpellName)
    spellCB.OnValueChanged = function(_, checked)
        moduleDB.showSpellName = checked
        RebuildPreview()
    end

    local growCB = MedaUI:CreateCheckbox(parent, "Grow Upward")
    growCB:SetPoint("TOPLEFT", 240, yOff)
    growCB:SetChecked(moduleDB.growUp)
    growCB.OnValueChanged = function(_, checked)
        moduleDB.growUp = checked
        if mainFrame then RebuildBars() end
        RebuildPreview()
    end
    yOff = yOff - 36

    local alphaSlider = MedaUI:CreateLabeledSlider(parent, "Opacity", 200, 0.3, 1.0, 0.05)
    alphaSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
    alphaSlider:SetValue(moduleDB.alpha)
    alphaSlider.OnValueChanged = function(_, value)
        moduleDB.alpha = value
        if mainFrame then mainFrame:SetAlpha(value) end
        UpdatePreview()
    end
    yOff = yOff - 60

    local zoneHeader = MedaUI:CreateSectionHeader(parent, "Show In", 470)
    zoneHeader:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 40

    local function ZoneCB(label, key, x, y)
        local cb = MedaUI:CreateCheckbox(parent, label)
        cb:SetPoint("TOPLEFT", x, y)
        cb:SetChecked(moduleDB[key])
        cb.OnValueChanged = function(_, checked)
            moduleDB[key] = checked
            CheckZoneVisibility()
        end
        return cb
    end

    ZoneCB("Dungeons", "showInDungeon", LEFT_X, yOff)
    ZoneCB("Raids", "showInRaid", 240, yOff)
    yOff = yOff - 32
    ZoneCB("Open World", "showInOpenWorld", LEFT_X, yOff)
    ZoneCB("Arena", "showInArena", 240, yOff)
    yOff = yOff - 32
    ZoneCB("Battlegrounds", "showInBG", LEFT_X, yOff)
    yOff = yOff - 46

    MedaAuras:SetContentHeight(math.abs(yOff))
end

-- ============================================================================
-- Register Module
-- ============================================================================

MedaAuras:RegisterModule({
    name        = MODULE_NAME,
    title       = "Cracked",
    version     = MODULE_VERSION,
    stability   = MODULE_STABILITY,
    author      = "Medalink",
    description = "Tracks party defensive cooldowns in M+ and dungeons. "
               .. "Detects when party members use defensive abilities and "
               .. "displays cooldown bars with active/CD states, colored by class. "
               .. "Uses secret laundering to read tainted party spell IDs.",
    sidebarDesc = "Party defensive cooldown tracker (experimental).",
    defaults    = MODULE_DEFAULTS,
    OnInitialize = OnInitialize,
    OnEnable    = OnEnable,
    OnDisable   = OnDisable,
    pages       = {
        { id = "settings", label = "Settings" },
    },
    buildPage   = function(_, parent)
        BuildSettingsPage(parent, MedaAuras:GetModuleDB(MODULE_NAME))
        return 760
    end,
})
