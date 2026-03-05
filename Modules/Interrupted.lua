local ADDON_NAME, ns = ...

local MedaUI = LibStub("MedaUI-1.0")

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
local ALL_INTERRUPTS      = ID.ALL_INTERRUPTS
local CLASS_DEFAULTS      = ID.CLASS_DEFAULTS
local CLASS_INTERRUPT_LIST = ID.CLASS_INTERRUPT_LIST
local SPEC_OVERRIDES      = ID.SPEC_OVERRIDES
local SPEC_NO_INTERRUPT   = ID.SPEC_NO_INTERRUPT
local HEALER_KEEPS_KICK   = ID.HEALER_KEEPS_KICK
local CD_REDUCTION_TALENTS = ID.CD_REDUCTION_TALENTS
local CD_ON_KICK_TALENTS  = ID.CD_ON_KICK_TALENTS
local SPEC_EXTRA_KICKS    = ID.SPEC_EXTRA_KICKS
local SPELL_ALIASES       = ID.SPELL_ALIASES
local CLASS_COLORS        = ID.CLASS_COLORS

-- ============================================================================
-- State
-- ============================================================================

local db
local partyMembers = {}     -- [name] = { class, spellID, baseCd, cdEnd, onKickReduction, extraKicks }
local noInterruptPlayers = {} -- [name] = true
local myName, myClass, mySpellID, myBaseCd, myIsPetSpell
local myKickCdEnd = 0
local myExtraKicks = {}

local mainFrame, titleText, resizeHandle
local bars = {}
local updateTicker
local isResizing = false
local shouldShowByZone = true
local watcherHandle, mobKickHandle
local reinspectTicker

local FONT_FACE = GameFontNormal and GameFontNormal:GetFont() or "Fonts\\FRIZQT__.TTF"
local FONT_FLAGS = "OUTLINE"
local BAR_TEXTURE = "Interface\\BUTTONS\\WHITE8X8"

-- ============================================================================
-- Logging
-- ============================================================================

local function Log(msg)   MedaAuras.Log(format("[Interrupted] %s", msg)) end
local function LogDebug(msg) MedaAuras.LogDebug(format("[Interrupted] %s", msg)) end
local function LogWarn(msg)  MedaAuras.LogWarn(format("[Interrupted] %s", msg)) end

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

    if specID and SPEC_NO_INTERRUPT[specID] then
        LogDebug(format("  specID %d is in SPEC_NO_INTERRUPT, no interrupt for this spec", specID))
        mySpellID = nil
        myBaseCd = nil
        myIsPetSpell = false
        return
    end

    mySpellID = nil
    myIsPetSpell = false

    if specID and SPEC_OVERRIDES[specID] then
        local ov = SPEC_OVERRIDES[specID]
        LogDebug(format("  Spec override found: %s (id=%d, isPet=%s)", ov.name, ov.id, tostring(ov.isPet)))
        if ov.isPet then
            local known = IsSpellKnown(ov.id, true) or IsSpellKnown(ov.id)
            if not known then
                local ok, r = pcall(IsPlayerSpell, ov.id)
                if ok and r then known = true end
            end
            if not known and ov.petSpellID then
                local ok, r = pcall(IsSpellKnown, ov.petSpellID, true)
                if ok and r then known = true end
            end
            LogDebug(format("  Pet spell known=%s", tostring(known)))
            if known then
                mySpellID = ov.id
                myBaseCd = ov.cd
                myIsPetSpell = true
            end
        else
            mySpellID = ov.id
            myBaseCd = ov.cd
        end
    end

    local spellList = CLASS_INTERRUPT_LIST[myClass]
    if spellList then
        LogDebug(format("  Checking CLASS_INTERRUPT_LIST for %s (%d spells)", tostring(myClass), #spellList))
        for _, sid in ipairs(spellList) do
            local known = IsSpellKnown(sid) or IsSpellKnown(sid, true)
            if not known then
                local ok, r = pcall(IsPlayerSpell, sid)
                if ok and r then known = true end
            end
            LogDebug(format("    spellID %d known=%s", sid, tostring(known)))
            if known and not mySpellID then
                mySpellID = sid
                if not myBaseCd then
                    myBaseCd = ALL_INTERRUPTS[sid] and ALL_INTERRUPTS[sid].cd or 15
                end
                LogDebug(format("    -> selected as primary interrupt"))
            end
        end
    else
        LogDebug(format("  No CLASS_INTERRUPT_LIST for class=%s", tostring(myClass)))
    end

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
end

-- ============================================================================
-- Auto-register party members by class
-- ============================================================================

local function AutoRegisterParty()
    LogDebug(format("AutoRegisterParty: inGroup=%s", tostring(IsInGroup())))
    for i = 1, 4 do
        local u = "party" .. i
        local exists = UnitExists(u)
        if exists then
            local name = UnitName(u)
            local _, cls = UnitClass(u)
            local role = UnitGroupRolesAssigned(u)
            local hasDefault = cls and CLASS_DEFAULTS[cls] ~= nil
            LogDebug(format("  %s: name=%s class=%s role=%s hasDefault=%s already=%s noKick=%s",
                u, tostring(name), tostring(cls), tostring(role),
                tostring(hasDefault),
                tostring(name and partyMembers[name] ~= nil),
                tostring(name and noInterruptPlayers[name] ~= nil)))
            if name and cls and CLASS_DEFAULTS[cls] then
                if not partyMembers[name] and not noInterruptPlayers[name] then
                    if role == "HEALER" and not HEALER_KEEPS_KICK[cls] then
                        noInterruptPlayers[name] = true
                        LogDebug(format("    -> marked as healer (no kick): %s", name))
                    else
                        local kick = CLASS_DEFAULTS[cls]
                        partyMembers[name] = {
                            class = cls,
                            spellID = kick.id,
                            baseCd = kick.cd,
                            cdEnd = 0,
                        }
                        Log(format("Auto-registered %s (%s) %s CD=%d",
                            name, cls, kick.name, kick.cd))
                    end
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
    for name in pairs(noInterruptPlayers) do
        if not current[name] then noInterruptPlayers[name] = nil end
    end
    if removed > 0 then
        LogDebug(format("CleanPartyList: removed %d member(s)", removed))
    end
end

-- ============================================================================
-- Talent scanning on inspect complete
-- ============================================================================

local function ScanTalentsForMember(unit, name, class, specID)
    LogDebug(format("ScanTalentsForMember: unit=%s name=%s class=%s specID=%s",
        tostring(unit), tostring(name), tostring(class), tostring(specID)))
    local info = partyMembers[name]
    if not info then
        LogDebug(format("  -> %s not in partyMembers, skipping talent scan", tostring(name)))
        return
    end

    if SPEC_NO_INTERRUPT[specID] then
        partyMembers[name] = nil
        noInterruptPlayers[name] = true
        LogDebug(format("%s has no interrupt (specID=%d), removed", name, specID))
        return
    end

    local defaultKick = CLASS_DEFAULTS[class]
    if defaultKick then
        info.spellID = defaultKick.id
        info.baseCd = defaultKick.cd
    end
    info.onKickReduction = nil

    local ov = SPEC_OVERRIDES[specID]
    if ov then
        local apply = true
        if ov.isPet then
            local petUnit
            local idx = unit:match("party(%d)")
            if idx then petUnit = "partypet" .. idx end
            if petUnit and not UnitExists(petUnit) then apply = false end
        end
        if apply then
            info.spellID = ov.id
            info.baseCd = ov.cd
            LogDebug(format("Spec override for %s: %s CD=%d", name, ov.name, ov.cd))
        end
    end

    local configID = -1
    local ok, configInfo = pcall(C_Traits.GetConfigInfo, configID)
    LogDebug(format("  C_Traits.GetConfigInfo(-1): ok=%s hasConfig=%s hasTrees=%s",
        tostring(ok), tostring(configInfo ~= nil),
        tostring(configInfo and configInfo.treeIDs and #configInfo.treeIDs or 0)))
    if not ok or not configInfo or not configInfo.treeIDs or #configInfo.treeIDs == 0 then
        LogDebug("  -> No trait config available, skipping talent scan")
        return
    end

    local treeID = configInfo.treeIDs[1]
    local ok2, nodeIDs = pcall(C_Traits.GetTreeNodes, treeID)
    if not ok2 or not nodeIDs then return end

    for _, nodeID in ipairs(nodeIDs) do
        local ok3, nodeInfo = pcall(C_Traits.GetNodeInfo, configID, nodeID)
        if ok3 and nodeInfo and nodeInfo.activeEntry and nodeInfo.activeRank and nodeInfo.activeRank > 0 then
            local entryID = nodeInfo.activeEntry.entryID
            if entryID then
                local ok4, entryInfo = pcall(C_Traits.GetEntryInfo, configID, entryID)
                if ok4 and entryInfo and entryInfo.definitionID then
                    local ok5, defInfo = pcall(C_Traits.GetDefinitionInfo, entryInfo.definitionID)
                    if ok5 and defInfo and defInfo.spellID then
                        local talent = CD_REDUCTION_TALENTS[defInfo.spellID]
                        if talent then
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

                        local onKick = CD_ON_KICK_TALENTS[defInfo.spellID]
                        if onKick then
                            info.onKickReduction = onKick.reduction
                            LogDebug(format("%s has %s, -%ds on kick", name, onKick.name, onKick.reduction))
                        end
                    end
                end
            end
        end
    end
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
            LogDebug(format("  -> %s is in noInterruptPlayers, ignoring", name))
            return
        end
        local ok, _, cls = pcall(UnitClass, unit)
        LogDebug(format("  -> %s not in partyMembers, UnitClass(%s): ok=%s cls=%s",
            name, tostring(unit), tostring(ok), tostring(cls)))
        if ok and cls and CLASS_DEFAULTS[cls] then
            local role = UnitGroupRolesAssigned(unit)
            if role == "HEALER" and not HEALER_KEEPS_KICK[cls] then
                noInterruptPlayers[name] = true
                LogDebug(format("  -> %s is healer, marked as no-kick", name))
                return
            end
            local kickData = ALL_INTERRUPTS[resolvedID]
            partyMembers[name] = {
                class = cls,
                spellID = resolvedID,
                baseCd = kickData and kickData.cd or 15,
                cdEnd = now + (kickData and kickData.cd or 15),
                lastKickTime = now,
            }
            Log(format("  -> Late-registered %s (%s) from cast, CD=%d",
                name, cls, kickData and kickData.cd or 15))
        else
            LogWarn(format("  -> Could not register %s: UnitClass failed or no default", name))
        end
    end
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
        if not mySpellID then return end
        local isInterrupt = ALL_INTERRUPTS[spellID]
        if not isInterrupt then return end
        local cd
        if spellID == mySpellID then
            cd = myBaseCd or isInterrupt.cd
        else
            cd = isInterrupt.cd
        end
        myKickCdEnd = GetTime() + cd
        Log(format("OWN KICK: unit=%s spellID=%d (%s) CD=%ds (mySpellID=%s)",
            tostring(unit), spellID, isInterrupt.name, cd, tostring(mySpellID)))
    end)
    LogDebug("SetupOwnKickTracking: registered UNIT_SPELLCAST_SUCCEEDED for player+pet")
end

local function TeardownOwnKickTracking()
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
    local iconS = barH
    local barW = math.max(60, fw - iconS)
    local autoNameSize = math.max(9, math.floor(barH * 0.45))
    local autoCdSize = math.max(10, math.floor(barH * 0.55))
    local fontSize = (db.nameFontSize and db.nameFontSize > 0) and db.nameFontSize or autoNameSize
    local cdFontSize = (db.readyFontSize and db.readyFontSize > 0) and db.readyFontSize or autoCdSize
    return barW, barH, iconS, fontSize, cdFontSize, titleH
end

local function RebuildBars()
    for i = 1, 6 do
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

    for i = 1, 6 do
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
    if mainFrame then
        if shouldShowByZone then mainFrame:Show() else mainFrame:Hide() end
    end
end

local lastStateDump = 0

local function UpdateDisplay()
    if not mainFrame or not shouldShowByZone then return end

    local _, barH, _, _, _, titleH = GetBarLayout()
    local now = GetTime()
    local barIdx = 1

    if now - lastStateDump > 10 then
        lastStateDump = now
        local memberCount = 0
        for n, info in pairs(partyMembers) do
            memberCount = memberCount + 1
            local rem = info.cdEnd > now and (info.cdEnd - now) or 0
            LogDebug(format("  STATE: %s class=%s spell=%s cd=%.1fs",
                n, info.class, tostring(info.spellID), rem))
        end
        LogDebug(format("UpdateDisplay tick: mySpell=%s myCD=%.1f members=%d visible=%s",
            tostring(mySpellID), myKickCdEnd > now and (myKickCdEnd - now) or 0,
            memberCount, tostring(shouldShowByZone)))
    end

    -- Player bar
    local myData = mySpellID and ALL_INTERRUPTS[mySpellID]
    if myData and barIdx <= 6 then
        local bar = bars[barIdx]
        bar:Show()
        bar.icon:SetTexture(myData.icon)
        local col = CLASS_COLORS[myClass] or { 1, 1, 1 }
        bar.nameText:SetText("|cFFFFFFFF" .. (myName or "?") .. "|r")

        if myKickCdEnd > now then
            local rem = myKickCdEnd - now
            if not myIsPetSpell then
                local ok, result = pcall(function()
                    local cdInfo = C_Spell.GetSpellCooldown(mySpellID)
                    if cdInfo and cdInfo.startTime and cdInfo.duration and cdInfo.duration > 0 then
                        return (cdInfo.startTime + cdInfo.duration) - GetTime()
                    end
                    return nil
                end)
                if ok and result and result > 0 then rem = result end
            end
            bar.cdText:SetText(string.format("%.0f", rem))
            bar.cdText:SetTextColor(1, 1, 1)
            bar.cdBar:SetMinMaxValues(0, myBaseCd or myData.cd)
            bar.cdBar:SetValue(rem)
            bar.cdBar:SetStatusBarColor(col[1], col[2], col[3], 0.85)
            bar.barBg:SetVertexColor(col[1] * 0.25, col[2] * 0.25, col[3] * 0.25, 0.9)
        else
            bar.cdText:SetText(db.showReady and "READY" or "")
            bar.cdText:SetTextColor(0.2, 1.0, 0.2)
            bar.cdBar:SetMinMaxValues(0, 1)
            bar.cdBar:SetValue(0)
            bar.barBg:SetVertexColor(col[1], col[2], col[3], 0.85)
        end
        barIdx = barIdx + 1
    end

    -- Party bars
    for name, info in pairs(partyMembers) do
        if barIdx > 6 then break end
        local data = ALL_INTERRUPTS[info.spellID]
        if data then
            local bar = bars[barIdx]
            bar:Show()
            bar.icon:SetTexture(data.icon)
            local col = CLASS_COLORS[info.class] or { 1, 1, 1 }
            bar.nameText:SetText("|cFFFFFFFF" .. name .. "|r")

            local rem = 0
            if info.cdEnd > now then rem = info.cdEnd - now end
            bar.cdBar:SetMinMaxValues(0, info.baseCd or data.cd)

            if rem > 0.5 then
                bar.cdBar:SetValue(rem)
                bar.cdBar:SetStatusBarColor(col[1], col[2], col[3], 0.85)
                bar.barBg:SetVertexColor(col[1] * 0.25, col[2] * 0.25, col[3] * 0.25, 0.9)
                bar.cdText:SetText(string.format("%.0f", rem))
                bar.cdText:SetTextColor(1, 1, 1)
            else
                bar.cdBar:SetValue(0)
                bar.barBg:SetVertexColor(col[1], col[2], col[3], 0.85)
                bar.cdText:SetText(db.showReady and "READY" or "")
                bar.cdText:SetTextColor(0.2, 1.0, 0.2)
            end
            barIdx = barIdx + 1
        end
    end

    for i = barIdx, 6 do
        if bars[i] then bars[i]:Hide() end
    end

    if not isResizing then
        local numVisible = barIdx - 1
        if numVisible > 0 then
            mainFrame:SetHeight(titleH + numVisible * (barH + 1))
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

    mainFrame = CreateFrame("Frame", "MedaAurasInterruptedFrame", UIParent)
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
    mainFrame:SetResizeBounds(80, 40, 600, 600)

    local bg = mainFrame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(BAR_TEXTURE)
    bg:SetVertexColor(0.05, 0.05, 0.05, 0.85)

    titleText = mainFrame:CreateFontString(nil, "OVERLAY")
    titleText:SetFont(FONT_FACE, 12, FONT_FLAGS)
    titleText:SetPoint("TOP", 0, -3)
    titleText:SetText("|cFF00DDDDInterrupts|r")
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
        for i = 1, 6 do
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
            AutoRegisterParty()
        elseif event == "SPELLS_CHANGED" then
            FindMyInterrupt()
        elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
            if arg1 == "player" then
                FindMyInterrupt()
            end
        elseif event == "ROLE_CHANGED_INFORM" then
            for i = 1, 4 do
                local u = "party" .. i
                if UnitExists(u) then
                    local name = UnitName(u)
                    local _, cls = UnitClass(u)
                    local role = UnitGroupRolesAssigned(u)
                    if name and role == "HEALER" and cls ~= "SHAMAN" and partyMembers[name] then
                        partyMembers[name] = nil
                        noInterruptPlayers[name] = true
                    end
                end
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
-- Module Lifecycle
-- ============================================================================

local function OnInitialize(moduleDB)
    db = moduleDB
    Log("OnInitialize starting...")

    LogDebug(format("  db.enabled=%s", tostring(moduleDB.enabled)))
    LogDebug(format("  ns.InterruptData=%s", tostring(ns.InterruptData ~= nil)))
    LogDebug(format("  ns.Services.PartySpellWatcher=%s", tostring(ns.Services.PartySpellWatcher ~= nil)))
    LogDebug(format("  ns.Services.GroupInspector=%s", tostring(ns.Services.GroupInspector ~= nil)))

    LogDebug("  Step 1: FindMyInterrupt")
    FindMyInterrupt()

    LogDebug("  Step 2: CreateUI")
    CreateUI()
    LogDebug(format("  mainFrame created: %s", tostring(mainFrame ~= nil)))

    LogDebug("  Step 3: CheckZoneVisibility")
    CheckZoneVisibility()

    LogDebug("  Step 4: SetupOwnKickTracking")
    SetupOwnKickTracking()

    LogDebug("  Step 5: SetupRosterEvents")
    SetupRosterEvents()

    LogDebug("  Step 6: AutoRegisterParty")
    AutoRegisterParty()

    LogDebug("  Step 7: Register PartySpellWatcher callbacks")
    watcherHandle = ns.Services.PartySpellWatcher:OnPartyInterrupt(OnPartyInterruptDetected)
    mobKickHandle = ns.Services.PartySpellWatcher:OnMobKick(OnMobKickConfirmed)
    LogDebug(format("  watcherHandle=%s mobKickHandle=%s", tostring(watcherHandle), tostring(mobKickHandle)))

    LogDebug("  Step 8: Register GroupInspector inspect-complete callback")
    ns.Services.GroupInspector:RegisterInspectComplete("Interrupted", ScanTalentsForMember)

    LogDebug("  Step 9: Start reinspect ticker (30s)")
    reinspectTicker = C_Timer.NewTicker(30, function()
        if IsInGroup() then
            LogDebug("Reinspect ticker fired, requesting re-inspect all")
            ns.Services.GroupInspector:RequestReinspectAll()
        end
    end)

    LogDebug("  Step 10: Start UpdateDisplay ticker (0.1s)")
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
    TeardownRosterEvents()

    if watcherHandle then
        ns.Services.PartySpellWatcher:Unregister(watcherHandle)
        watcherHandle = nil
    end
    if mobKickHandle then
        ns.Services.PartySpellWatcher:Unregister(mobKickHandle)
        mobKickHandle = nil
    end

    ns.Services.GroupInspector:UnregisterInspectComplete("Interrupted")

    if reinspectTicker then reinspectTicker:Cancel(); reinspectTicker = nil end

    wipe(partyMembers)
    wipe(noInterruptPlayers)
    mySpellID = nil
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
    growUp = false,
    alpha = 0.9,
    nameFontSize = 0,
    readyFontSize = 0,
    showReady = true,
    showInDungeon = true,
    showInRaid = false,
    showInOpenWorld = true,
    showInArena = false,
    showInBG = false,
    position = { point = "CENTER", x = 0, y = -150 },
}

-- ============================================================================
-- Settings UI
-- ============================================================================

local function BuildConfig(parent, moduleDB)
    db = moduleDB
    local LEFT_X = 0
    local yOff = 0

    local header = MedaUI:CreateSectionHeader(parent, "Interrupted")
    header:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 45

    local enableCB = MedaUI:CreateCheckbox(parent, "Enable Module")
    enableCB:SetPoint("TOPLEFT", LEFT_X, yOff)
    enableCB:SetChecked(moduleDB.enabled)
    enableCB.OnValueChanged = function(_, checked)
        if checked then MedaAuras:EnableModule(MODULE_NAME)
        else MedaAuras:DisableModule(MODULE_NAME) end
        MedaAuras:RefreshSidebarDot(MODULE_NAME)
    end
    yOff = yOff - 35

    -- Display settings
    local dispHeader = MedaUI:CreateSectionHeader(parent, "Display")
    dispHeader:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 40

    local titleCB = MedaUI:CreateCheckbox(parent, "Show Title")
    titleCB:SetPoint("TOPLEFT", LEFT_X, yOff)
    titleCB:SetChecked(moduleDB.showTitle)
    titleCB.OnValueChanged = function(_, checked)
        moduleDB.showTitle = checked
        if mainFrame then RebuildBars() end
    end

    local lockCB = MedaUI:CreateCheckbox(parent, "Lock Position")
    lockCB:SetPoint("TOPLEFT", 240, yOff)
    lockCB:SetChecked(moduleDB.locked)
    lockCB.OnValueChanged = function(_, checked) moduleDB.locked = checked end
    yOff = yOff - 30

    local growCB = MedaUI:CreateCheckbox(parent, "Grow Upward")
    growCB:SetPoint("TOPLEFT", LEFT_X, yOff)
    growCB:SetChecked(moduleDB.growUp)
    growCB.OnValueChanged = function(_, checked)
        moduleDB.growUp = checked
        if mainFrame then RebuildBars() end
    end

    local readyCB = MedaUI:CreateCheckbox(parent, "Show READY Text")
    readyCB:SetPoint("TOPLEFT", 240, yOff)
    readyCB:SetChecked(moduleDB.showReady)
    readyCB.OnValueChanged = function(_, checked) moduleDB.showReady = checked end
    yOff = yOff - 40

    local alphaSlider = MedaUI:CreateLabeledSlider(parent, "Opacity", 200, 0.3, 1.0, 0.05)
    alphaSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
    alphaSlider:SetValue(moduleDB.alpha)
    alphaSlider.OnValueChanged = function(_, value)
        moduleDB.alpha = value
        if mainFrame then mainFrame:SetAlpha(value) end
    end
    yOff = yOff - 55

    -- Zone visibility
    local zoneHeader = MedaUI:CreateSectionHeader(parent, "Show In")
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
    yOff = yOff - 30
    ZoneCB("Open World", "showInOpenWorld", LEFT_X, yOff)
    ZoneCB("Arena", "showInArena", 240, yOff)
    yOff = yOff - 30
    ZoneCB("Battlegrounds", "showInBG", LEFT_X, yOff)
    yOff = yOff - 40

    -- Debug info
    if mySpellID and ALL_INTERRUPTS[mySpellID] then
        local infoLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        infoLabel:SetPoint("TOPLEFT", LEFT_X, yOff)
        infoLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
        infoLabel:SetText(format("Detected: %s (ID %d, CD %ds)",
            ALL_INTERRUPTS[mySpellID].name, mySpellID, myBaseCd or 0))
        yOff = yOff - 20
    end

    local partyCount = 0
    for _ in pairs(partyMembers) do partyCount = partyCount + 1 end
    if partyCount > 0 then
        local partyLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        partyLabel:SetPoint("TOPLEFT", LEFT_X, yOff)
        partyLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
        partyLabel:SetText(format("Tracking %d party member(s)", partyCount))
        yOff = yOff - 20
    end

    yOff = yOff - 10

    local resetBtn = MedaUI:CreateButton(parent, "Reset to Defaults")
    resetBtn:SetPoint("TOPLEFT", LEFT_X, yOff)
    resetBtn:SetScript("OnClick", function()
        for k, v in pairs(MODULE_DEFAULTS) do moduleDB[k] = MedaAuras.DeepCopy(v) end
        MedaAuras:ToggleSettings()
        MedaAuras:ToggleSettings()
    end)
    yOff = yOff - 45

    MedaAuras:SetContentHeight(math.abs(yOff))
end

-- ============================================================================
-- Register Module
-- ============================================================================

MedaAuras:RegisterModule({
    name        = MODULE_NAME,
    title       = "Interrupted",
    version     = MODULE_VERSION,
    stability   = MODULE_STABILITY,
    description = "Tracks party interrupt cooldowns in M+ and dungeons. "
               .. "Detects when party members use their kick and displays "
               .. "cooldown bars for each player, colored by class.",
    sidebarDesc = "Party interrupt cooldown tracker for M+ dungeons.",
    defaults    = MODULE_DEFAULTS,
    OnInitialize = OnInitialize,
    OnEnable    = OnEnable,
    OnDisable   = OnDisable,
    BuildConfig = BuildConfig,
})
