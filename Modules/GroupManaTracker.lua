local _, ns = ...

local MedaUI = LibStub("MedaUI-2.0")

local format = format
local GetTime = GetTime
local pairs = pairs
local ipairs = ipairs
local wipe = wipe
local pcall = pcall
local unpack = unpack
local UnitPower = UnitPower
local UnitPowerMax = UnitPowerMax
local UnitPowerType = UnitPowerType
local UnitName = UnitName
local UnitGUID = UnitGUID
local UnitExists = UnitExists
local UnitIsUnit = UnitIsUnit
local CreateFrame = CreateFrame
local IsInGroup = IsInGroup
local IsInRaid = IsInRaid
local C_Timer = C_Timer

-- ============================================================================
-- Constants
-- ============================================================================

local MODULE_VERSION   = "1.0"
local MODULE_STABILITY = "experimental"   -- "experimental" | "beta" | "stable"

local MANA_POWER_TYPE = 0
local MAX_PARTY = 4
local MAX_RAID = 40
local TICKER_INTERVAL = 0.5
local SCAN_INTERVAL = 6
local SETTINGS_MIGRATION_VERSION = 1

local CLASS_ICON_ATLAS = "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"
local ROLE_ICON_ATLAS = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"
local ROLE_ICON_TCOORDS = {
    TANK    = { 0, 19/64, 22/64, 41/64 },
    HEALER  = { 20/64, 39/64, 1/64, 20/64 },
    DAMAGER = { 20/64, 39/64, 22/64, 41/64 },
}
local ICON_PAD = 5
local ROW_PAD_H = 6
local ROW_PAD_V = 4

local MODULE_NAME = "GroupManaTracker"

local OUTLINE_MAP = { none = "", outline = "OUTLINE", thick = "THICKOUTLINE" }

local fontCache = {}
local function GetFontObj(fontValue, size, outline)
    local path = MedaUI:GetFontPath(fontValue)
    local flags = OUTLINE_MAP[outline] or outline or ""
    local key = (path or "default") .. "_" .. size .. "_" .. flags
    if fontCache[key] then return fontCache[key] end
    local fo = CreateFont("MedaAurasGMT_" .. key:gsub("[^%w]", "_"))
    if path then
        fo:SetFont(path, size, flags)
    else
        fo:CopyFontObject(GameFontNormal)
        local p, _, _ = fo:GetFont()
        fo:SetFont(p, size, flags)
    end
    fontCache[key] = fo
    return fo
end

-- ============================================================================
-- State
-- ============================================================================

local db
local updateTicker
local eventFrame
local displayFrame
local alertFrame
local rowPool = {}
local activeRows = {}

local healers = {}
local healerOrder = {}
local lastKnownMana = {}
local scanTickCounter = 0
local isEnabled = false

local drinkingHealers = {}
local prevDrinkingSet = {}
local newDrinkingBuf = {}
local alertPreviewActive = false
local alertManualVisibleUntil = 0

-- ============================================================================
-- Helpers
-- ============================================================================

local DRINK_BUFFS = {"Food & Drink", "Drinking", "Refreshment"}
local DRINK_KEYWORDS = {"drink", "refreshment", "food"}

local function IsUsableNumber(val)
    if val == nil then return false end
    local ok = pcall(function() return val + 0 end)
    return ok
end

local function IsDrinking(unit)
    for _, buffName in ipairs(DRINK_BUFFS) do
        local ok, aura = pcall(AuraUtil.FindAuraByName, buffName, unit, "HELPFUL")
        if ok and aura then
            local clean = pcall(function()
                if aura == "___taint_probe___" then end
            end)
            if clean then return true end
        end
    end

    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 40 do
            local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
            if ok and data and data.name then
                local lowerOk, lowerName = pcall(strlower, data.name)
                if lowerOk and lowerName then
                    for _, keyword in ipairs(DRINK_KEYWORDS) do
                        if strfind(lowerName, keyword, 1, true) then
                            return true
                        end
                    end
                end
            end
        end
    end

    return false
end

local function UnpackColor(tbl, fallbackR, fallbackG, fallbackB)
    if tbl and tbl[1] then return tbl[1], tbl[2], tbl[3] end
    return fallbackR or 1, fallbackG or 1, fallbackB or 1
end

local function SafeUnitInCombat(unit)
    local ok, result = pcall(UnitAffectingCombat, unit)
    if not ok then return nil end
    local clean = pcall(function() if result then end end)
    if not clean then return nil end
    return result
end

local function IsGroupInCombat()
    local numGroup = GetNumGroupMembers()
    if numGroup == 0 then return false end

    local inRaid = IsInRaid()
    local prefix = inRaid and "raid" or "party"
    local limit = inRaid and numGroup or numGroup

    for i = 1, limit do
        local unit = prefix .. i
        if UnitExists(unit) then
            local inCombat = SafeUnitInCombat(unit)
            if inCombat then return true end
        end
    end

    if not inRaid then
        local inCombat = SafeUnitInCombat("player")
        if inCombat then return true end
    end

    return false
end

-- ============================================================================
-- Roster Scanning
-- ============================================================================

local function ShouldTrackManaUnit(unit)
    local role = UnitGroupRolesAssigned(unit)
    if role == "HEALER" then
        return true, role
    end

    if not db or db.includeNonHealers ~= true then
        return false, role
    end

    local powerType = UnitPowerType(unit)
    local isManaUser = IsUsableNumber(powerType) and powerType == MANA_POWER_TYPE
    if not isManaUser then
        return false, role
    end

    return true, role
end

local function ScanHealers()
    wipe(healers)
    wipe(healerOrder)

    local numGroup = GetNumGroupMembers()
    if numGroup == 0 then return end

    local inRaid = IsInRaid()
    local limit = inRaid and numGroup or MAX_PARTY
    local unitPrefix = inRaid and "raid" or "party"

    local function AddUnit(unit)
        if not UnitExists(unit) then return end
        local guid = UnitGUID(unit)
        if not guid or healers[guid] then return end

        local shouldTrack, role = ShouldTrackManaUnit(unit)
        if not shouldTrack then
            return
        end

        local name = UnitName(unit)
        local _, class = UnitClass(unit)

        healers[guid] = {
            unit = unit,
            name = name or "Unknown",
            class = class or "PRIEST",
            role = role or "DAMAGER",
        }
        healerOrder[#healerOrder + 1] = guid
    end

    if db.showSelf then
        AddUnit("player")
    end

    for i = 1, limit do
        local unit = unitPrefix .. i
        if not UnitIsUnit(unit, "player") then
            AddUnit(unit)
        end
    end
end

-- ============================================================================
-- Row Management
-- ============================================================================

local function CreateRow(parent)
    local row = CreateFrame("Frame", nil, parent)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetTexture(CLASS_ICON_ATLAS)

    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)

    row.statusText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.statusText:SetJustifyH("LEFT")
    row.statusText:SetWordWrap(false)
    row.statusText:SetText("")

    row.manaText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.manaText:SetJustifyH("LEFT")
    row.manaText:SetWordWrap(false)

    return row
end

local function AcquireRow(parent)
    local row = table.remove(rowPool)
    if not row then
        row = CreateRow(parent)
    else
        row:SetParent(parent)
    end
    row:Show()
    return row
end

local function ReleaseRow(row)
    row:Hide()
    row:ClearAllPoints()
    rowPool[#rowPool + 1] = row
end

local function ApplyRowStyle(row, info)
    local nameSize = db.textSize or 16
    local manaSize = db.manaTextSize or math.max(nameSize - 1, 8)
    local outline = db.textOutline or "none"
    local iconSz = db.iconSize or 18

    local nameFont = GetFontObj(db.font, nameSize, outline)
    local manaFont = GetFontObj(db.font, manaSize, outline)
    row.nameText:SetFontObject(nameFont)
    row.manaText:SetFontObject(manaFont)
    row.statusText:SetFontObject(manaFont)

    row.icon:SetSize(iconSz, iconSz)
    row.icon:ClearAllPoints()
    row.icon:SetPoint("TOPLEFT", ROW_PAD_H, -ROW_PAD_V)

    local showIcon = (db.iconMode or "class") ~= "none"
    local nameLineH = math.max(nameSize, iconSz)
    local manaIndent = showIcon and (iconSz + ICON_PAD) or 0

    row.nameText:ClearAllPoints()
    row.statusText:ClearAllPoints()
    row.manaText:ClearAllPoints()

    if showIcon then
        row.icon:Show()
        row.nameText:SetPoint("LEFT", row.icon, "RIGHT", ICON_PAD, 0)
    else
        row.icon:Hide()
        row.nameText:SetPoint("LEFT", row, "LEFT", ROW_PAD_H, 0)
    end

    row.statusText:SetPoint("LEFT", row.nameText, "RIGHT", 6, 0)
    row.manaText:SetPoint("TOPLEFT", ROW_PAD_H + manaIndent, -(ROW_PAD_V + nameLineH + 1))

    if info then
        if db.nameColorMode == "custom" then
            local r, g, b = UnpackColor(db.customNameColor, 1, 1, 1)
            row.nameText:SetTextColor(r, g, b)
        else
            local classColor = RAID_CLASS_COLORS[info.class]
            if classColor then
                row.nameText:SetTextColor(classColor.r, classColor.g, classColor.b)
            else
                row.nameText:SetTextColor(1, 1, 1)
            end
        end
    end
end

local function ApplyIconZoom(tex, l, r, t, b)
    local zoom = (db and db.iconZoom or 0) / 100
    if zoom > 0 then
        local hw = (r - l) * zoom * 0.5
        local hh = (b - t) * zoom * 0.5
        l, r = l + hw, r - hw
        t, b = t + hh, b - hh
    end
    tex:SetTexCoord(l, r, t, b)
end

local function SetRowIcon(tex, class, role)
    local mode = db and db.iconMode or "class"
    if mode == "role" then
        tex:SetTexture(ROLE_ICON_ATLAS)
        local coords = ROLE_ICON_TCOORDS[role or "DAMAGER"]
        if coords then
            ApplyIconZoom(tex, coords[1], coords[2], coords[3], coords[4])
        else
            ApplyIconZoom(tex, 0, 1, 0, 1)
        end
    else
        tex:SetTexture(CLASS_ICON_ATLAS)
        local coords = CLASS_ICON_TCOORDS[class]
        if coords then
            ApplyIconZoom(tex, coords[1], coords[2], coords[3], coords[4])
        else
            ApplyIconZoom(tex, 0, 1, 0, 1)
        end
    end
end

-- ============================================================================
-- Display Frame
-- ============================================================================

local function SavePosition()
    if not displayFrame or not db then return end
    local point, _, _, x, y = displayFrame:GetPoint()
    db.framePoint = { point = point or "CENTER", x = x or 0, y = y or 0 }
end

local function RestorePosition()
    if not displayFrame or not db then return end
    displayFrame:ClearAllPoints()
    local fp = db.framePoint
    if fp then
        displayFrame:SetPoint(fp.point or "CENTER", UIParent, fp.point or "CENTER", fp.x or 0, fp.y or 0)
    else
        displayFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
    end
end

local function ApplyFrameStyle()
    if not displayFrame or not db then return end
    displayFrame:SetScale(db.frameScale or 1)
    local bgAlpha = db.backgroundOpacity or 0.8
    local r, g, b = MedaUI.Theme.backgroundDark[1], MedaUI.Theme.backgroundDark[2], MedaUI.Theme.backgroundDark[3]
    displayFrame:SetBackdropColor(r, g, b, bgAlpha)
    if db.showBorder == false then
        displayFrame:SetBackdropBorderColor(0, 0, 0, 0)
    else
        local br, bg, bb, ba = unpack(MedaUI.Theme.border)
        displayFrame:SetBackdropBorderColor(br, bg, bb, ba)
    end
end

local function CreateDisplayFrame()
    if displayFrame then return displayFrame end

    displayFrame = CreateFrame("Frame", "MedaAuras_GroupManaTracker", UIParent, "BackdropTemplate")
    displayFrame:SetFrameStrata("MEDIUM")
    displayFrame:SetClampedToScreen(true)
    displayFrame:SetMovable(true)
    displayFrame:EnableMouse(true)

    displayFrame:SetScript("OnDragStart", function(self)
        if not db.locked then self:StartMoving() end
    end)
    displayFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    displayFrame:RegisterForDrag("LeftButton")

    MedaUI:ApplyBackdrop(displayFrame, "backgroundDark", "border")
    ApplyFrameStyle()

    return displayFrame
end

-- ============================================================================
-- Drinking Alert Banner (via MedaUI:CreateNotificationBanner)
-- ============================================================================

local function EnsureAlertFrame()
    if alertFrame then return alertFrame end
    alertFrame = MedaUI:CreateNotificationBanner("MedaAuras_GMT_DrinkAlert", {
        duration = (db and db.alertDuration) or 3,
        barHeight = (db and db.alertBarHeight) or 4,
        showBar = not (db and db.alertShowBar == false),
    })
    alertFrame.OnHide = function() end
    return alertFrame
end

local function ApplyAlertStyle()
    if not alertFrame or not db then return end
    alertFrame:SetScale(db.alertScale or 1)
    alertFrame:SetBackgroundOpacity(db.alertBgOpacity or 0.85)
    alertFrame:SetLocked(db.alertLocked or false)
    alertFrame:SetDuration(db.alertDuration or 3)
    alertFrame:SetBarHeight(db.alertBarHeight or 4)
    alertFrame:SetShowBar(db.alertShowBar ~= false)

    local fontObj = GetFontObj(db.alertFont or "default", db.alertTextSize or 18, db.alertTextOutline or "outline")
    alertFrame:SetTextFont(fontObj)

    local tr, tg, tb = UnpackColor(db.alertTextColor, 0.33, 0.87, 1.0)
    alertFrame:SetTextColor(tr, tg, tb)

    local br, bg, bb = UnpackColor(db.alertBarColor, 0.2, 0.58, 1.0)
    alertFrame:SetBarColor(br, bg, bb)
end

local function ShowAlert(text)
    EnsureAlertFrame()
    ApplyAlertStyle()
    alertPreviewActive = false
    alertFrame:RestorePosition(db.alertPoint)
    alertFrame:Show(text, db.alertDuration or 3)

    local soundPath = MedaUI:GetSoundPath(db.alertSound)
    if soundPath then
        MedaUI:PlaySoundPath(soundPath)
    end

    alertFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if db then db.alertPoint = self:SavePosition() end
    end)
end

local function HideAlert()
    alertManualVisibleUntil = 0
    if alertFrame then alertFrame:Dismiss() end
end

local function ShowAlertPreview(moduleDB)
    if not moduleDB then return end

    db = moduleDB
    EnsureAlertFrame()
    ApplyAlertStyle()
    alertPreviewActive = true
    alertManualVisibleUntil = 0
    alertFrame:RestorePosition(moduleDB.alertPoint)
    alertFrame:SetLocked(false)
    alertFrame:SetShowBar(moduleDB.alertShowBar ~= false)
    alertFrame:ShowPreview("Healer Drinking (Preview)")
    alertFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        moduleDB.alertPoint = self:SavePosition()
    end)
end

local function HideAlertPreview(moduleDB)
    if not alertFrame then return end

    alertPreviewActive = false
    alertFrame:DismissPreview()
    if moduleDB then
        alertFrame:SetLocked(moduleDB.alertLocked or false)
    end
end

local function TestLiveAlert(moduleDB, text)
    if moduleDB then
        db = moduleDB
    end
    if not db then return end

    alertPreviewActive = false
    alertManualVisibleUntil = GetTime() + (db.alertDuration or 3)
    ShowAlert(text or "Group Mana Tracker Alert Test")
end

local function ShouldKeepVisibleAlert()
    if alertPreviewActive then
        return true
    end

    return alertManualVisibleUntil > GetTime()
end

-- ============================================================================
-- Update Logic
-- ============================================================================

local function ShowStale(row, guid)
    local sr, sg, sb = UnpackColor(db.staleColor, 0.5, 0.6, 0.7)
    local stale = guid and lastKnownMana[guid]
    if stale then
        row.manaText:SetTextColor(sr, sg, sb)
        pcall(row.manaText.SetText, row.manaText, stale)
    else
        row.manaText:SetTextColor(sr, sg, sb)
        row.manaText:SetText("---")
    end
end

local function UpdateManaText(row, unit, guid)
    local showDrink = db.showDrinking ~= false
    local showDead = db.showDead ~= false

    local drinkOk, drinking = pcall(IsDrinking, unit)
    local deadOk, isDead = pcall(UnitIsDeadOrGhost, unit)

    if showDrink and drinkOk and drinking then
        row.statusText:SetText("|cff55ddffDrinking|r")
    elseif showDead and deadOk and isDead then
        row.statusText:SetText("|cff888888Dead|r")
    else
        row.statusText:SetText("")
    end

    local ptOk, pt = pcall(UnitPowerType, unit)
    local activeIsMana = ptOk and IsUsableNumber(pt) and pt == MANA_POWER_TYPE

    if ptOk and not activeIsMana then
        ShowStale(row, guid)
        return
    end

    local maxOk, maxVal = pcall(UnitPowerMax, unit, MANA_POWER_TYPE, true)
    if not maxOk or not IsUsableNumber(maxVal) or maxVal <= 0 then
        ShowStale(row, guid)
        return
    end

    local curOk, curVal = pcall(UnitPower, unit, MANA_POWER_TYPE)
    if not curOk then
        ShowStale(row, guid)
        return
    end

    local showMax = db and db.showMaxMana
    local fmtOk = pcall(function()
        if showMax then
            row.manaText:SetText(format("%d / %d", curVal, maxVal))
        else
            row.manaText:SetText(format("%d", curVal))
        end
    end)

    if fmtOk then
        local mr, mg, mb = UnpackColor(db.manaColor, 0.7, 0.85, 1.0)
        row.manaText:SetTextColor(mr, mg, mb)
        if guid then
            pcall(function()
                if showMax then
                    lastKnownMana[guid] = format("%d / %d", curVal, maxVal)
                else
                    lastKnownMana[guid] = format("%d", curVal)
                end
            end)
        end
    else
        ShowStale(row, guid)
    end
end

local function UpdateDisplay()
    if not displayFrame then return end

    if db.showManaList == false then
        displayFrame:Hide()
        return
    end

    for _, row in ipairs(activeRows) do
        ReleaseRow(row)
    end
    wipe(activeRows)

    local count = #healerOrder
    if count == 0 then
        displayFrame:Hide()
        return
    end

    local iconSz = db.iconSize or 18
    local nameSize = db.textSize or 16
    local manaSize = db.manaTextSize or math.max(nameSize - 1, 8)
    local nameLineH = math.max(nameSize, iconSz)
    local manaLineH = manaSize
    local pad = db.framePadding or 5

    local rowHeight = ROW_PAD_V + nameLineH + 1 + manaLineH + ROW_PAD_V
    local rowSpacing = db.rowSpacing or 2
    local frameWidth = (db.frameWidth or 160) + pad * 2
    local contentHeight = count * rowHeight + math.max(0, count - 1) * rowSpacing
    local frameHeight = contentHeight + pad * 2

    displayFrame:SetSize(frameWidth, frameHeight)
    ApplyFrameStyle()

    local rowWidth = frameWidth - pad * 2
    local growUp = db.growUp or false

    for i, guid in ipairs(healerOrder) do
        local info = healers[guid]
        if info then
            local row = AcquireRow(displayFrame)
            row:SetSize(rowWidth, rowHeight)

            if growUp then
                row:SetPoint("BOTTOMLEFT", pad, pad + (i - 1) * (rowHeight + rowSpacing))
            else
                row:SetPoint("TOPLEFT", pad, -(pad + (i - 1) * (rowHeight + rowSpacing)))
            end

            SetRowIcon(row.icon, info.class, info.role)
            row.nameText:SetText(info.name)

            ApplyRowStyle(row, info)
            UpdateManaText(row, info.unit, guid)

            activeRows[#activeRows + 1] = row
        end
    end

    if not displayFrame:IsShown() then
        displayFrame:Show()
    end
end

-- ============================================================================
-- Drinking Alert Detection
-- ============================================================================

local function IsAlertVisible()
    return alertFrame and alertFrame:IsShown()
end

local function UpdateDrinkingAlert()
    if not db.alertEnabled then
        if IsAlertVisible() then HideAlert() end
        return
    end

    wipe(newDrinkingBuf)
    local newDrinking = newDrinkingBuf
    local drinkCount = 0
    local lastName

    for _, guid in ipairs(healerOrder) do
        local info = healers[guid]
        if info then
            local ok, drinking = pcall(IsDrinking, info.unit)
            if ok and drinking then
                newDrinking[guid] = info.name
                drinkCount = drinkCount + 1
                lastName = info.name
            end
        end
    end

    local hasNew = false
    for guid in pairs(newDrinking) do
        if not prevDrinkingSet[guid] then
            hasNew = true
            break
        end
    end

    if hasNew and drinkCount > 0 then
        local suppress = false
        if db.alertOnlyInCombat then
            local groupFighting = IsGroupInCombat()
            if not groupFighting then suppress = true end
        end

        if not suppress then
            local text
            if drinkCount == 1 then
                text = (lastName or (db.includeNonHealers and "Player" or "Healer")) .. " is drinking"
            else
                text = drinkCount .. (db.includeNonHealers and " players drinking" or " healers drinking")
            end
            ShowAlert(text)
        end
    end

    wipe(prevDrinkingSet)
    for guid, name in pairs(newDrinking) do
        prevDrinkingSet[guid] = name
    end
    wipe(drinkingHealers)
    for guid, name in pairs(newDrinking) do
        drinkingHealers[guid] = name
    end
end

local function MigrateSettings(moduleDB)
    if not moduleDB then return end

    local version = moduleDB.settingsVersion or 0
    if version < SETTINGS_MIGRATION_VERSION then
        if moduleDB.alertOnlyInCombat == true then
            moduleDB.alertOnlyInCombat = false
        end
        moduleDB.settingsVersion = SETTINGS_MIGRATION_VERSION
    end
end

-- ============================================================================
-- Tick & Events
-- ============================================================================

local function OnTick()
    if not isEnabled then return end

    scanTickCounter = scanTickCounter + 1
    local shouldRescan = scanTickCounter >= (SCAN_INTERVAL / TICKER_INTERVAL)
    if shouldRescan then
        scanTickCounter = 0
        ScanHealers()
    end

    if #healerOrder == 0 then
        if displayFrame and displayFrame:IsShown() and db.showManaList ~= false then
            displayFrame:Hide()
        end
        if IsAlertVisible() and not ShouldKeepVisibleAlert() then HideAlert() end
        return
    end

    if db.showManaList ~= false then
        for _, guid in ipairs(healerOrder) do
            local info = healers[guid]
            if info then
                for _, row in ipairs(activeRows) do
                    if row.nameText:GetText() == info.name then
                        UpdateManaText(row, info.unit, guid)
                        break
                    end
                end
            end
        end
    end

    UpdateDrinkingAlert()
end

local function OnEvent(self, event, arg1)
    if not isEnabled then return end

    if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        scanTickCounter = 0
        ScanHealers()
        UpdateDisplay()
        UpdateDrinkingAlert()
    elseif event == "UNIT_POWER_UPDATE" then
        if db.showManaList == false then return end
        if not displayFrame or not displayFrame:IsShown() then return end
        local unit = arg1
        for _, guid in ipairs(healerOrder) do
            local info = healers[guid]
            if info and info.unit == unit then
                for _, row in ipairs(activeRows) do
                    if row.nameText:GetText() == info.name then
                        UpdateManaText(row, unit, guid)
                        break
                    end
                end
                break
            end
        end
    end
end

local function RegisterEvents()
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", OnEvent)
    end
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("UNIT_POWER_UPDATE")
end

local function UnregisterEvents()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
    end
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

local function StartModule()
    isEnabled = true
    scanTickCounter = 0

    CreateDisplayFrame()
    RestorePosition()

    if db.alertEnabled then
        EnsureAlertFrame()
        alertFrame:RestorePosition(db.alertPoint)
    end

    RegisterEvents()
    ScanHealers()
    UpdateDisplay()
    UpdateDrinkingAlert()

    if not updateTicker then
        updateTicker = C_Timer.NewTicker(TICKER_INTERVAL, OnTick)
    end
end

local function StopModule()
    isEnabled = false

    if updateTicker then
        updateTicker:Cancel()
        updateTicker = nil
    end

    UnregisterEvents()

    for _, row in ipairs(activeRows) do
        ReleaseRow(row)
    end
    wipe(activeRows)

    if displayFrame then displayFrame:Hide() end
    HideAlert()

    wipe(healers)
    wipe(healerOrder)
    wipe(lastKnownMana)
    wipe(drinkingHealers)
    wipe(prevDrinkingSet)
end

local function OnInitialize(moduleDB)
    MigrateSettings(moduleDB)
    db = moduleDB
end

local function OnEnable(moduleDB)
    db = moduleDB
    StartModule()
end

local function OnDisable(moduleDB)
    db = moduleDB
    StopModule()
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

local slashCommands = {
    ["show"] = function(moduleDB)
        db = moduleDB
        if not displayFrame then
            CreateDisplayFrame()
            RestorePosition()
        end
        displayFrame:Show()
        ScanHealers()
        UpdateDisplay()
    end,
    ["hide"] = function(moduleDB)
        if displayFrame then displayFrame:Hide() end
    end,
    ["toggle"] = function(moduleDB)
        db = moduleDB
        if displayFrame and displayFrame:IsShown() then
            displayFrame:Hide()
        else
            if not displayFrame then
                CreateDisplayFrame()
                RestorePosition()
            end
            displayFrame:Show()
            ScanHealers()
            UpdateDisplay()
        end
    end,
    ["reset"] = function(moduleDB)
        db = moduleDB
        db.framePoint = nil
        if displayFrame then RestorePosition() end
        print("|cff00ccffMedaAuras:|r Group Mana Tracker position reset.")
    end,
    ["alerttest"] = function(moduleDB)
        TestLiveAlert(moduleDB, "Healer Drinking (Live Test)")
        print("|cff00ccffMedaAuras:|r Group Mana Tracker live alert test shown.")
    end,
}

-- ============================================================================
-- Settings UI — Preview
-- ============================================================================

local PREVIEW_MOCK = {
    { name = "Restodude", class = "DRUID", role = "HEALER", cur = 87432, max = 120000, drinking = false, stale = false },
    { name = "Holypriest", class = "PRIEST", role = "HEALER", cur = 45210, max = 120000, drinking = true, stale = false },
    { name = "Shamanman", class = "SHAMAN", role = "HEALER", cur = 62100, max = 120000, drinking = false, stale = true },
}

local pvContainer, pvListFrame, pvAlertFrame
local pvRows = {}

local function UpdatePreview()
    if not pvContainer or not db then return end

    local iconSz = db.iconSize or 18
    local nameSize = db.textSize or 16
    local manaSize = db.manaTextSize or math.max(nameSize - 1, 8)
    local nameLineH = math.max(nameSize, iconSz)
    local manaLineH = manaSize
    local pad = db.framePadding or 5
    local showMax = db.showMaxMana
    local showDrink = db.showDrinking ~= false

    local rowHeight = ROW_PAD_V + nameLineH + 1 + manaLineH + ROW_PAD_V
    local rowSpacing = db.rowSpacing or 2
    local count = #PREVIEW_MOCK
    local listW = (db.frameWidth or 160) + pad * 2
    local contentH = count * rowHeight + math.max(0, count - 1) * rowSpacing
    local listH = contentH + pad * 2

    -- Style the mock list frame
    if db.showManaList ~= false then
        pvListFrame:Show()
        pvListFrame:SetSize(listW, listH)
        local bgAlpha = db.backgroundOpacity or 0.8
        local bgr, bgg, bgb = MedaUI.Theme.backgroundDark[1], MedaUI.Theme.backgroundDark[2], MedaUI.Theme.backgroundDark[3]
        pvListFrame:SetBackdropColor(bgr, bgg, bgb, bgAlpha)
        if db.showBorder == false then
            pvListFrame:SetBackdropBorderColor(0, 0, 0, 0)
        else
            pvListFrame:SetBackdropBorderColor(unpack(MedaUI.Theme.border))
        end

        local rowW = listW - pad * 2
        local growUp = db.growUp or false

        for i, mock in ipairs(PREVIEW_MOCK) do
            local row = pvRows[i]
            row:Show()
            row:SetParent(pvListFrame)
            row:ClearAllPoints()
            row:SetSize(rowW, rowHeight)
            if growUp then
                row:SetPoint("BOTTOMLEFT", pad, pad + (i - 1) * (rowHeight + rowSpacing))
            else
                row:SetPoint("TOPLEFT", pad, -(pad + (i - 1) * (rowHeight + rowSpacing)))
            end

            SetRowIcon(row.icon, mock.class, mock.role)
            row.nameText:SetText(mock.name)

            ApplyRowStyle(row, mock)

            local manaStr
            if showMax then
                manaStr = format("%d / %d", mock.cur, mock.max)
            else
                manaStr = format("%d", mock.cur)
            end
            row.manaText:SetText(manaStr)

            if mock.stale then
                local sr, sg, sb = UnpackColor(db.staleColor, 0.5, 0.6, 0.7)
                row.manaText:SetTextColor(sr, sg, sb)
            else
                local mr, mg, mb = UnpackColor(db.manaColor, 0.7, 0.85, 1.0)
                row.manaText:SetTextColor(mr, mg, mb)
            end

            if mock.drinking and showDrink then
                row.statusText:SetText("|cff55ddffDrinking|r")
            else
                row.statusText:SetText("")
            end
        end
    else
        pvListFrame:Hide()
        for _, row in ipairs(pvRows) do row:Hide() end
    end

    -- Style the mock alert banner
    if db.alertEnabled ~= false then
        pvAlertFrame:Show()

        local aFontObj = GetFontObj(db.alertFont or "default", db.alertTextSize or 18, db.alertTextOutline or "outline")
        pvAlertFrame.text:SetFontObject(aFontObj)
        local tr, tg, tb = UnpackColor(db.alertTextColor, 0.33, 0.87, 1.0)
        pvAlertFrame.text:SetTextColor(tr, tg, tb)
        pvAlertFrame.text:SetText("Holypriest is drinking")

        local textW = pvAlertFrame.text:GetStringWidth()
        pvAlertFrame:SetWidth(math.max(textW + 30, 160))

        local abgr, abgg, abgb = MedaUI.Theme.backgroundDark[1], MedaUI.Theme.backgroundDark[2], MedaUI.Theme.backgroundDark[3]
        pvAlertFrame:SetBackdropColor(abgr, abgg, abgb, db.alertBgOpacity or 0.85)
        pvAlertFrame:SetBackdropBorderColor(unpack(MedaUI.Theme.border))

        local barH = db.alertBarHeight or 4
        pvAlertFrame.bar:SetHeight(barH)
        pvAlertFrame.barBg:SetHeight(barH + 2)

        local barr, barg, barb = UnpackColor(db.alertBarColor, 0.2, 0.58, 1.0)
        pvAlertFrame.bar:SetStatusBarColor(barr, barg, barb, 1)
        pvAlertFrame.bar:SetValue(0.65)

        if db.alertShowBar ~= false then
            pvAlertFrame.bar:Show()
            pvAlertFrame.barBg:Show()
        else
            pvAlertFrame.bar:Hide()
            pvAlertFrame.barBg:Hide()
        end

        pvAlertFrame:ClearAllPoints()
        local listBottom
        if db.showManaList ~= false then
            listBottom = listH + 8
        else
            listBottom = 0
        end
        pvAlertFrame:SetPoint("TOPLEFT", pvContainer, "TOPLEFT", 10, -(10 + listBottom))
    else
        pvAlertFrame:Hide()
    end

    -- Resize preview container to fit content
    local totalH = 32
    if db.showManaList ~= false then
        totalH = totalH + listH + 8
    end
    if db.alertEnabled ~= false then
        totalH = totalH + 36 + (db.alertBarHeight or 4) + 12
    end
    totalH = math.max(totalH, 60)
    pvContainer:SetHeight(totalH)
end

local function CreateFloatingPreview()
    local PREVIEW_W = 260
    local PREVIEW_PAD = 10

    local anchor = MedaAurasSettingsPanel or _G["MedaAurasSettingsPanel"]
    if not anchor then return end

    pvContainer = CreateFrame("Frame", nil, anchor)
    pvContainer:SetFrameStrata("HIGH")
    pvContainer:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 0)
    pvContainer:SetSize(PREVIEW_W, 200)
    MedaAuras:RegisterConfigCleanup(pvContainer)

    -- Mock mana list frame
    pvListFrame = CreateFrame("Frame", nil, pvContainer, "BackdropTemplate")
    pvListFrame:SetPoint("TOPLEFT", PREVIEW_PAD, -PREVIEW_PAD)
    pvListFrame:SetSize(170, 100)
    MedaUI:ApplyBackdrop(pvListFrame, "backgroundDark", "border")

    for i = 1, #PREVIEW_MOCK do
        pvRows[i] = CreateRow(pvListFrame)
    end

    -- Mock alert banner
    pvAlertFrame = CreateFrame("Frame", nil, pvContainer, "BackdropTemplate")
    pvAlertFrame:SetSize(220, 36)
    MedaUI:ApplyBackdrop(pvAlertFrame, "backgroundDark", "border")

    pvAlertFrame.text = pvAlertFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pvAlertFrame.text:SetPoint("CENTER", 0, 0)
    pvAlertFrame.text:SetJustifyH("CENTER")

    pvAlertFrame.barBg = CreateFrame("Frame", nil, pvAlertFrame)
    pvAlertFrame.barBg:SetPoint("TOPLEFT", pvAlertFrame, "BOTTOMLEFT", 2, 0)
    pvAlertFrame.barBg:SetPoint("TOPRIGHT", pvAlertFrame, "BOTTOMRIGHT", -2, 0)
    pvAlertFrame.barBg:SetHeight(6)
    local abgTex = pvAlertFrame.barBg:CreateTexture(nil, "BACKGROUND")
    abgTex:SetAllPoints()
    abgTex:SetColorTexture(0, 0, 0, 0.4)

    pvAlertFrame.bar = CreateFrame("StatusBar", nil, pvAlertFrame)
    pvAlertFrame.bar:SetPoint("TOPLEFT", pvAlertFrame, "BOTTOMLEFT", 2, 0)
    pvAlertFrame.bar:SetPoint("TOPRIGHT", pvAlertFrame, "BOTTOMRIGHT", -2, 0)
    pvAlertFrame.bar:SetHeight(4)
    pvAlertFrame.bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    pvAlertFrame.bar:SetMinMaxValues(0, 1)
    pvAlertFrame.bar:SetValue(0.65)

    pvContainer:Show()
    UpdatePreview()
end

local function DestroyFloatingPreview()
    if pvContainer then
        pvContainer:Hide()
        pvContainer:SetParent(nil)
        pvContainer = nil
        pvListFrame = nil
        pvAlertFrame = nil
        wipe(pvRows)
    end
end

local function RestoreAlertSettingsPreview(moduleDB)
    if moduleDB and moduleDB.alertEnabled ~= false then
        ShowAlertPreview(moduleDB)
    else
        HideAlertPreview(moduleDB)
    end
end

local function ShowSettingsPreviews(moduleDB)
    db = moduleDB
    DestroyFloatingPreview()
    CreateFloatingPreview()
    RestoreAlertSettingsPreview(moduleDB)
end

-- ============================================================================
-- Settings UI
-- ============================================================================

local function BuildSettingsPage(parent, moduleDB)
    local LEFT_X, RIGHT_X = 0, 238
    db = moduleDB

    local function pv() UpdatePreview() end
    local function lv()
        if not alertFrame then return end
        ApplyAlertStyle()
        alertFrame:SetLocked(false)
        if alertFrame:IsShown() then
            alertFrame:ShowPreview("Healer Drinking (Preview)")
        end
    end

    ShowSettingsPreviews(moduleDB)

    local tabBar, tabs = MedaAuras:CreateConfigTabs(parent, {
        { id = "general",    label = "General" },
        { id = "layout",     label = "Layout" },
        { id = "appearance", label = "Appearance" },
        { id = "alert",      label = "Drinking Alert" },
    })

    -- ===== General Tab =====
    do
        local p = tabs["general"]
        local yOff = 0

        local hdr = MedaUI:CreateSectionHeader(p, "General")
        hdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local enableCB = MedaUI:CreateCheckbox(p, "Enable Module")
        enableCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        enableCB:SetChecked(moduleDB.enabled)
        enableCB.OnValueChanged = function(_, checked)
            if checked then MedaAuras:EnableModule(MODULE_NAME) else MedaAuras:DisableModule(MODULE_NAME) end
            MedaAuras:RefreshSidebarDot(MODULE_NAME)
        end
        yOff = yOff - 30

        local showManaListCB = MedaUI:CreateCheckbox(p, "Show Mana List")
        showManaListCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        showManaListCB:SetChecked(moduleDB.showManaList ~= false)
        showManaListCB.OnValueChanged = function(_, checked)
            moduleDB.showManaList = checked
            if isEnabled then UpdateDisplay() end
            pv()
        end
        local lockCB = MedaUI:CreateCheckbox(p, "Lock Mana List Position")
        lockCB:SetPoint("TOPLEFT", RIGHT_X, yOff)
        lockCB:SetChecked(moduleDB.locked)
        lockCB.OnValueChanged = function(_, checked) moduleDB.locked = checked end
        yOff = yOff - 30

        local showSelfCB = MedaUI:CreateCheckbox(p, "Show Self")
        showSelfCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        showSelfCB:SetChecked(moduleDB.showSelf)
        showSelfCB.OnValueChanged = function(_, checked)
            moduleDB.showSelf = checked
            if isEnabled then ScanHealers(); UpdateDisplay() end
        end
        local includeNonHealersCB = MedaUI:CreateCheckbox(p, "Include Non-Healers")
        includeNonHealersCB:SetPoint("TOPLEFT", RIGHT_X, yOff)
        includeNonHealersCB:SetChecked(moduleDB.includeNonHealers == true)
        includeNonHealersCB.OnValueChanged = function(_, checked)
            moduleDB.includeNonHealers = checked
            if isEnabled then
                ScanHealers()
                UpdateDisplay()
            end
        end
        yOff = yOff - 30

        local showMaxCB = MedaUI:CreateCheckbox(p, "Show Max Mana")
        showMaxCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        showMaxCB:SetChecked(moduleDB.showMaxMana)
        showMaxCB.OnValueChanged = function(_, checked)
            moduleDB.showMaxMana = checked
            wipe(lastKnownMana)
            if isEnabled then UpdateDisplay() end
            pv()
        end
        yOff = yOff - 40

        local hdr2 = MedaUI:CreateSectionHeader(p, "Content")
        hdr2:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local showDrinkCB = MedaUI:CreateCheckbox(p, "Show Drinking Status")
        showDrinkCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        showDrinkCB:SetChecked(moduleDB.showDrinking ~= false)
        showDrinkCB.OnValueChanged = function(_, checked)
            moduleDB.showDrinking = checked
            if isEnabled then UpdateDisplay() end
            pv()
        end
        local showDeadCB = MedaUI:CreateCheckbox(p, "Show Dead Status")
        showDeadCB:SetPoint("TOPLEFT", RIGHT_X, yOff)
        showDeadCB:SetChecked(moduleDB.showDead ~= false)
        showDeadCB.OnValueChanged = function(_, checked)
            moduleDB.showDead = checked
            if isEnabled then UpdateDisplay() end
        end
        yOff = yOff - 40

        local resetBtn = MedaUI:CreateButton(p, "Reset Mana List Position")
        resetBtn:SetPoint("TOPLEFT", LEFT_X, yOff)
        resetBtn:SetScript("OnClick", function()
            moduleDB.framePoint = nil
            if displayFrame then RestorePosition() end
        end)
    end

    -- ===== Layout Tab =====
    do
        local p = tabs["layout"]
        local yOff = 0

        local hdr = MedaUI:CreateSectionHeader(p, "Mana List Layout")
        hdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local scaleSlider = MedaUI:CreateLabeledSlider(p, "Frame Scale", 200, 50, 200, 5)
        scaleSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
        scaleSlider:SetValue((moduleDB.frameScale or 1) * 100)
        scaleSlider.OnValueChanged = function(_, value)
            moduleDB.frameScale = value / 100
            if isEnabled then ApplyFrameStyle() end
        end
        local growDirDD = MedaUI:CreateLabeledDropdown(p, "Grow Direction", 200, {
            { value = false, label = "Down" },
            { value = true, label = "Up" },
        })
        growDirDD:SetPoint("TOPLEFT", RIGHT_X, yOff)
        growDirDD:SetSelected(moduleDB.growUp or false)
        growDirDD.OnValueChanged = function(_, value)
            moduleDB.growUp = value
            if isEnabled then UpdateDisplay() end
            pv()
        end
        yOff = yOff - 55

        local frameWidthSlider = MedaUI:CreateLabeledSlider(p, "Frame Width", 200, 120, 300, 10)
        frameWidthSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
        frameWidthSlider:SetValue(moduleDB.frameWidth or 160)
        frameWidthSlider.OnValueChanged = function(_, value)
            moduleDB.frameWidth = value
            if isEnabled then UpdateDisplay() end
            pv()
        end
        local paddingSlider = MedaUI:CreateLabeledSlider(p, "Frame Padding", 200, 0, 20, 1)
        paddingSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
        paddingSlider:SetValue(moduleDB.framePadding or 5)
        paddingSlider.OnValueChanged = function(_, value)
            moduleDB.framePadding = value
            if isEnabled then UpdateDisplay() end
            pv()
        end
        yOff = yOff - 55

        local rowSpacingSlider = MedaUI:CreateLabeledSlider(p, "Row Spacing", 200, 0, 8, 1)
        rowSpacingSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
        rowSpacingSlider:SetValue(moduleDB.rowSpacing or 2)
        rowSpacingSlider.OnValueChanged = function(_, value)
            moduleDB.rowSpacing = value
            if isEnabled then UpdateDisplay() end
            pv()
        end
        local iconSizeSlider = MedaUI:CreateLabeledSlider(p, "Icon Size", 200, 10, 32, 1)
        iconSizeSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
        iconSizeSlider:SetValue(moduleDB.iconSize or 18)
        iconSizeSlider.OnValueChanged = function(_, value)
            moduleDB.iconSize = value
            if isEnabled then UpdateDisplay() end
            pv()
        end
    end

    -- ===== Appearance Tab =====
    do
        local p = tabs["appearance"]
        local yOff = 0

        local hdr = MedaUI:CreateSectionHeader(p, "Text")
        hdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local fontPicker = MedaUI:CreateLabeledDropdown(p, "Font", 200, MedaUI:GetFontList(), "font")
        fontPicker:SetPoint("TOPLEFT", LEFT_X, yOff)
        fontPicker:SetSelected(moduleDB.font or "default")
        fontPicker.OnValueChanged = function(_, value)
            moduleDB.font = value
            wipe(fontCache)
            if isEnabled then UpdateDisplay() end
            pv()
        end
        local outlineDD = MedaUI:CreateLabeledDropdown(p, "Text Outline", 200, {
            { value = "none", label = "None" },
            { value = "outline", label = "Outline" },
            { value = "thick", label = "Thick Outline" },
        })
        outlineDD:SetPoint("TOPLEFT", RIGHT_X, yOff)
        outlineDD:SetSelected(moduleDB.textOutline or "none")
        outlineDD.OnValueChanged = function(_, value)
            moduleDB.textOutline = value
            wipe(fontCache)
            if isEnabled then UpdateDisplay() end
            pv()
        end
        yOff = yOff - 55

        local textSizeSlider = MedaUI:CreateLabeledSlider(p, "Name Text Size", 200, 1, 48, 1)
        textSizeSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
        textSizeSlider:SetValue(moduleDB.textSize or 16)
        textSizeSlider.OnValueChanged = function(_, value)
            moduleDB.textSize = value
            wipe(fontCache)
            if isEnabled then UpdateDisplay() end
            pv()
        end
        local manaSizeSlider = MedaUI:CreateLabeledSlider(p, "Mana Text Size", 200, 1, 48, 1)
        manaSizeSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
        manaSizeSlider:SetValue(moduleDB.manaTextSize or 15)
        manaSizeSlider.OnValueChanged = function(_, value)
            moduleDB.manaTextSize = value
            wipe(fontCache)
            if isEnabled then UpdateDisplay() end
            pv()
        end
        yOff = yOff - 55

        local iconModeDD = MedaUI:CreateLabeledDropdown(p, "Icon Mode", 200, {
            { value = "class", label = "Class Icon" },
            { value = "role",  label = "Role Icon" },
            { value = "none",  label = "None (hidden)" },
        })
        iconModeDD:SetPoint("TOPLEFT", LEFT_X, yOff)
        iconModeDD:SetSelected(moduleDB.iconMode or "class")
        iconModeDD.OnValueChanged = function(_, value)
            moduleDB.iconMode = value
            moduleDB.showClassIcon = value ~= "none"
            if isEnabled then UpdateDisplay() end
            pv()
        end
        local iconZoomSlider = MedaUI:CreateLabeledSlider(p, "Icon Zoom (%)", 200, 0, 50, 5)
        iconZoomSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
        iconZoomSlider:SetValue(moduleDB.iconZoom or 0)
        iconZoomSlider.OnValueChanged = function(_, value)
            moduleDB.iconZoom = value
            if isEnabled then UpdateDisplay() end
            pv()
        end
        yOff = yOff - 55

        local hdr2 = MedaUI:CreateSectionHeader(p, "Colors")
        hdr2:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local nameColorDD = MedaUI:CreateLabeledDropdown(p, "Name Color", 200, {
            { value = "class", label = "Class Color" },
            { value = "custom", label = "Custom" },
        })
        nameColorDD:SetPoint("TOPLEFT", LEFT_X, yOff)
        nameColorDD:SetSelected(moduleDB.nameColorMode or "class")
        local manaColorPicker = MedaUI:CreateLabeledColorPicker(p, "Mana Color")
        manaColorPicker:SetPoint("TOPLEFT", RIGHT_X, yOff)
        local mc = moduleDB.manaColor or {0.7, 0.85, 1.0}
        manaColorPicker:SetColor(mc[1], mc[2], mc[3])
        manaColorPicker.OnColorChanged = function(_, r, g, b)
            moduleDB.manaColor = {r, g, b}
            if isEnabled then UpdateDisplay() end
            pv()
        end
        yOff = yOff - 55

        local customNamePicker = MedaUI:CreateLabeledColorPicker(p, "Custom Name Color")
        customNamePicker:SetPoint("TOPLEFT", LEFT_X, yOff)
        local cnc = moduleDB.customNameColor or {1, 1, 1}
        customNamePicker:SetColor(cnc[1], cnc[2], cnc[3])
        customNamePicker.OnColorChanged = function(_, r, g, b)
            moduleDB.customNameColor = {r, g, b}
            if isEnabled then UpdateDisplay() end
            pv()
        end
        if (moduleDB.nameColorMode or "class") ~= "custom" then
            customNamePicker:SetAlpha(0.4)
        end
        nameColorDD.OnValueChanged = function(_, value)
            moduleDB.nameColorMode = value
            customNamePicker:SetAlpha(value == "custom" and 1 or 0.4)
            if isEnabled then UpdateDisplay() end
            pv()
        end
        local staleColorPicker = MedaUI:CreateLabeledColorPicker(p, "Stale Mana Color")
        staleColorPicker:SetPoint("TOPLEFT", RIGHT_X, yOff)
        local sc = moduleDB.staleColor or {0.5, 0.6, 0.7}
        staleColorPicker:SetColor(sc[1], sc[2], sc[3])
        staleColorPicker.OnColorChanged = function(_, r, g, b)
            moduleDB.staleColor = {r, g, b}
            if isEnabled then UpdateDisplay() end
            pv()
        end
        yOff = yOff - 40

        local hdr3 = MedaUI:CreateSectionHeader(p, "Frame")
        hdr3:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local bgAlphaSlider = MedaUI:CreateLabeledSlider(p, "Background Opacity", 200, 0, 100, 5)
        bgAlphaSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
        bgAlphaSlider:SetValue((moduleDB.backgroundOpacity or 0.8) * 100)
        bgAlphaSlider.OnValueChanged = function(_, value)
            moduleDB.backgroundOpacity = value / 100
            if isEnabled then ApplyFrameStyle() end
            pv()
        end
        local showBorderCB = MedaUI:CreateCheckbox(p, "Show Border")
        showBorderCB:SetPoint("TOPLEFT", RIGHT_X, yOff)
        showBorderCB:SetChecked(moduleDB.showBorder ~= false)
        showBorderCB.OnValueChanged = function(_, checked)
            moduleDB.showBorder = checked
            if isEnabled then ApplyFrameStyle() end
            pv()
        end
    end

    -- ===== Drinking Alert Tab =====
    do
        local p = tabs["alert"]
        local yOff = 0

        local hdr = MedaUI:CreateSectionHeader(p, "Drinking Alert")
        hdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local alertEnCB = MedaUI:CreateCheckbox(p, "Enable Drinking Alert")
        alertEnCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        alertEnCB:SetChecked(moduleDB.alertEnabled ~= false)
        alertEnCB.OnValueChanged = function(_, checked)
            moduleDB.alertEnabled = checked
            if checked then
                ShowAlertPreview(moduleDB)
            else
                HideAlert()
                HideAlertPreview(moduleDB)
            end
            pv()
        end
        yOff = yOff - 30

        local alertCombatCB = MedaUI:CreateCheckbox(p, "Only Alert During Combat")
        alertCombatCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        alertCombatCB:SetChecked(moduleDB.alertOnlyInCombat == true)
        alertCombatCB.OnValueChanged = function(_, checked)
            moduleDB.alertOnlyInCombat = checked
        end
        local alertLockCB = MedaUI:CreateCheckbox(p, "Lock Alert Position")
        alertLockCB:SetPoint("TOPLEFT", RIGHT_X, yOff)
        alertLockCB:SetChecked(moduleDB.alertLocked)
        alertLockCB.OnValueChanged = function(_, checked) moduleDB.alertLocked = checked end
        yOff = yOff - 30

        local alertShowBarCB = MedaUI:CreateCheckbox(p, "Show Countdown Bar")
        alertShowBarCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        alertShowBarCB:SetChecked(moduleDB.alertShowBar ~= false)
        alertShowBarCB.OnValueChanged = function(_, checked)
            moduleDB.alertShowBar = checked
            lv(); pv()
        end
        yOff = yOff - 35

        local alertSoundDD = MedaUI:CreateLabeledDropdown(p, "Alert Sound", 200, MedaUI:GetSoundList())
        alertSoundDD:SetPoint("TOPLEFT", LEFT_X, yOff)
        alertSoundDD:SetSelected(moduleDB.alertSound or "none")
        alertSoundDD.OnValueChanged = function(_, value) moduleDB.alertSound = value end
        local soundPreviewBtn = MedaUI:CreateButton(p, "Preview", 60, 24)
        soundPreviewBtn:SetPoint("LEFT", alertSoundDD, "RIGHT", 8, -6)
        soundPreviewBtn:SetScript("OnClick", function()
            local path = MedaUI:GetSoundPath(moduleDB.alertSound)
            if path then MedaUI:PlaySoundPath(path) end
        end)
        local liveAlertTestBtn = MedaUI:CreateButton(p, "Test Alert", 84, 24)
        liveAlertTestBtn:SetPoint("LEFT", soundPreviewBtn, "RIGHT", 8, 0)
        liveAlertTestBtn:SetScript("OnClick", function()
            TestLiveAlert(moduleDB, "Healer Drinking (Live Test)")
        end)
        yOff = yOff - 55

        local alertDurSlider = MedaUI:CreateLabeledSlider(p, "Alert Duration (sec)", 200, 1, 15, 0.5)
        alertDurSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
        alertDurSlider:SetValue(moduleDB.alertDuration or 3)
        alertDurSlider.OnValueChanged = function(_, value) moduleDB.alertDuration = value end
        local alertScaleSlider = MedaUI:CreateLabeledSlider(p, "Alert Scale", 200, 50, 200, 5)
        alertScaleSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
        alertScaleSlider:SetValue((moduleDB.alertScale or 1) * 100)
        alertScaleSlider.OnValueChanged = function(_, value)
            moduleDB.alertScale = value / 100
            lv()
        end
        yOff = yOff - 55

        local alertFontPicker = MedaUI:CreateLabeledDropdown(p, "Alert Font", 200, MedaUI:GetFontList(), "font")
        alertFontPicker:SetPoint("TOPLEFT", LEFT_X, yOff)
        alertFontPicker:SetSelected(moduleDB.alertFont or "default")
        alertFontPicker.OnValueChanged = function(_, value)
            moduleDB.alertFont = value
            wipe(fontCache)
            lv(); pv()
        end
        local alertSizeSlider = MedaUI:CreateLabeledSlider(p, "Alert Text Size", 200, 8, 48, 1)
        alertSizeSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
        alertSizeSlider:SetValue(moduleDB.alertTextSize or 18)
        alertSizeSlider.OnValueChanged = function(_, value)
            moduleDB.alertTextSize = value
            wipe(fontCache)
            lv(); pv()
        end
        yOff = yOff - 55

        local alertOutlineDD = MedaUI:CreateLabeledDropdown(p, "Alert Text Outline", 200, {
            { value = "none", label = "None" },
            { value = "outline", label = "Outline" },
            { value = "thick", label = "Thick Outline" },
        })
        alertOutlineDD:SetPoint("TOPLEFT", LEFT_X, yOff)
        alertOutlineDD:SetSelected(moduleDB.alertTextOutline or "outline")
        alertOutlineDD.OnValueChanged = function(_, value)
            moduleDB.alertTextOutline = value
            wipe(fontCache)
            lv(); pv()
        end
        local alertTextPicker = MedaUI:CreateLabeledColorPicker(p, "Alert Text Color")
        alertTextPicker:SetPoint("TOPLEFT", RIGHT_X, yOff)
        local atc = moduleDB.alertTextColor or {0.33, 0.87, 1.0}
        alertTextPicker:SetColor(atc[1], atc[2], atc[3])
        alertTextPicker.OnColorChanged = function(_, r, g, b)
            moduleDB.alertTextColor = {r, g, b}
            lv(); pv()
        end
        yOff = yOff - 55

        local alertBarPicker = MedaUI:CreateLabeledColorPicker(p, "Alert Bar Color")
        alertBarPicker:SetPoint("TOPLEFT", LEFT_X, yOff)
        local abc = moduleDB.alertBarColor or {0.2, 0.58, 1.0}
        alertBarPicker:SetColor(abc[1], abc[2], abc[3])
        alertBarPicker.OnColorChanged = function(_, r, g, b)
            moduleDB.alertBarColor = {r, g, b}
            lv(); pv()
        end
        local alertBarHSlider = MedaUI:CreateLabeledSlider(p, "Alert Bar Height", 200, 2, 10, 1)
        alertBarHSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
        alertBarHSlider:SetValue(moduleDB.alertBarHeight or 4)
        alertBarHSlider.OnValueChanged = function(_, value)
            moduleDB.alertBarHeight = value
            lv(); pv()
        end
        yOff = yOff - 55

        local alertBgSlider = MedaUI:CreateLabeledSlider(p, "Alert Background Opacity", 200, 0, 100, 5)
        alertBgSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
        alertBgSlider:SetValue((moduleDB.alertBgOpacity or 0.85) * 100)
        alertBgSlider.OnValueChanged = function(_, value)
            moduleDB.alertBgOpacity = value / 100
            lv(); pv()
        end
        yOff = yOff - 55

        local alertResetBtn = MedaUI:CreateButton(p, "Reset Alert Position")
        alertResetBtn:SetPoint("TOPLEFT", LEFT_X, yOff)
        alertResetBtn:SetScript("OnClick", function()
            moduleDB.alertPoint = nil
            ShowAlertPreview(moduleDB)
        end)
    end

    MedaAuras:SetContentHeight(500)

    local sentinel = CreateFrame("Frame", nil, parent)
    sentinel:SetSize(1, 1)
    sentinel:SetPoint("TOPLEFT")
    sentinel:Show()
    sentinel:SetScript("OnHide", function()
        DestroyFloatingPreview()
        HideAlertPreview(moduleDB)
    end)
end

-- ============================================================================
-- Module Defaults
-- ============================================================================

local MODULE_DEFAULTS = {
    enabled = false,
    locked = false,
    showSelf = true,
    includeNonHealers = false,
    showMaxMana = false,
    showManaList = true,

    -- layout
    frameScale = 1.0,
    growUp = false,
    framePadding = 5,
    frameWidth = 160,
    rowSpacing = 2,
    iconSize = 18,

    -- text
    textSize = 16,
    manaTextSize = 15,
    font = "default",
    textOutline = "none",
    showClassIcon = true,
    iconMode = "class",
    iconZoom = 0,

    -- colors
    nameColorMode = "class",
    customNameColor = {1, 1, 1},
    manaColor = {0.7, 0.85, 1.0},
    staleColor = {0.5, 0.6, 0.7},

    -- content
    showDrinking = true,
    showDead = true,

    -- frame
    backgroundOpacity = 0.8,
    showBorder = true,
    framePoint = nil,

    -- drinking alert
    alertEnabled = true,
    alertOnlyInCombat = false,
    alertDuration = 3,
    alertScale = 1.0,
    alertFont = "default",
    alertTextSize = 18,
    alertTextOutline = "outline",
    alertTextColor = {0.33, 0.87, 1.0},
    alertBgOpacity = 0.85,
    alertBarColor = {0.2, 0.58, 1.0},
    alertBarHeight = 4,
    alertShowBar = true,
    alertLocked = false,
    alertPoint = nil,
    alertSound = "none",
}

-- ============================================================================
-- Register Module
-- ============================================================================

MedaAuras:RegisterModule({
    name = MODULE_NAME,
    title = "Group Mana Tracker",
    version = MODULE_VERSION,
    stability = MODULE_STABILITY,
    author = "Medalink",
    description = "Displays healer mana for your group, with optional non-healer mana users.",
    sidebarDesc = "Shows healer mana bars for your group, with an option to include other mana users.",
    defaults = MODULE_DEFAULTS,
    OnInitialize = OnInitialize,
    OnEnable = OnEnable,
    OnDisable = OnDisable,
    pages = {
        { id = "settings", label = "Settings" },
    },
    buildPage = function(_, parent)
        BuildSettingsPage(parent, MedaAuras:GetModuleDB(MODULE_NAME))
        return 820
    end,
    onPageCacheRestore = function(pageName)
        if pageName ~= "settings" then return end
        ShowSettingsPreviews(MedaAuras:GetModuleDB(MODULE_NAME))
    end,
    slashCommands = slashCommands,
})

-- ============================================================================
-- Standalone Secret Extraction Test  (/gmttest)
-- ============================================================================

local testResultFrame

local function AddLine(lines, text)
    lines[#lines + 1] = text
end

local function RunSecretTests()
    local lines = {}

    local unit
    local numGroup = GetNumGroupMembers()
    if numGroup > 0 then
        local prefix = IsInRaid() and "raid" or "party"
        for i = 1, numGroup do
            local u = prefix .. i
            if UnitExists(u) and not UnitIsUnit(u, "player") then
                local pt = UnitPowerType(u)
                if IsUsableNumber(pt) and pt == MANA_POWER_TYPE then
                    unit = u
                    break
                end
            end
        end
    end

    if not unit then unit = "player" end

    local uName = UnitName(unit) or unit
    AddLine(lines, "|cff00ccffTarget:|r " .. uName .. " (" .. unit .. ")")
    AddLine(lines, "")

    local maxOk, maxVal = pcall(UnitPowerMax, unit, MANA_POWER_TYPE, true)
    local maxClean = maxOk and IsUsableNumber(maxVal)
    AddLine(lines, "UnitPowerMax: " .. (maxClean and tostring(maxVal) or "|cffff6666SECRET|r"))

    local curOk, curVal = pcall(UnitPower, unit, MANA_POWER_TYPE)
    if not curOk then
        AddLine(lines, "UnitPower: |cffff4444CALL FAILED|r")
        return lines
    end
    local curClean = IsUsableNumber(curVal)
    AddLine(lines, "UnitPower:    " .. (curClean and tostring(curVal) or "|cffff6666SECRET|r"))
    AddLine(lines, "")

    local hiddenFrame = CreateFrame("Frame", nil, UIParent)
    hiddenFrame:SetSize(1, 1)
    hiddenFrame:SetPoint("CENTER")
    hiddenFrame:Hide()

    -- T1: FontString width
    AddLine(lines, "|cff88bbdd--- T1: FontString GetStringWidth ---|r")
    do
        local fs = hiddenFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        local stOk = pcall(function() fs:SetText(format("%d", curVal)) end)
        if stOk then
            local wOk, w = pcall(fs.GetStringWidth, fs)
            local wClean = wOk and IsUsableNumber(w)
            if not wOk then
                AddLine(lines, "GetStringWidth: |cffff4444CALL FAILED|r")
            elseif wClean then
                AddLine(lines, "GetStringWidth: |cff44ff44CLEAN|r  " .. format("%.1fpx", w))
                if maxClean and maxVal > 0 then
                    local refFS = hiddenFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    refFS:SetText(tostring(maxVal))
                    local rwOk, rw = pcall(refFS.GetStringWidth, refFS)
                    if rwOk and IsUsableNumber(rw) and rw > 0 then
                        AddLine(lines, "  ratio: " .. format("%.4f", w / rw) .. "  (max ref=" .. format("%.1fpx", rw) .. ")")
                    end
                end
            else
                AddLine(lines, "GetStringWidth: |cffff6666TAINTED|r")
            end
        else
            AddLine(lines, "SetText(format): |cffff4444FAILED|r")
        end
    end
    AddLine(lines, "")

    -- T2: StatusBar clamp
    AddLine(lines, "|cff88bbdd--- T2: StatusBar Clamp GetValue ---|r")
    do
        local thresholds = {10000, 20000, 30000, 40000, 50000, 60000, 100000}
        for _, thresh in ipairs(thresholds) do
            local bar = CreateFrame("StatusBar", nil, hiddenFrame)
            bar:SetSize(100, 10)
            bar:SetPoint("CENTER")
            bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
            local mmOk = pcall(bar.SetMinMaxValues, bar, 0, thresh)
            local svOk = pcall(bar.SetValue, bar, curVal)
            if mmOk and svOk then
                local gvOk, gv = pcall(bar.GetValue, bar)
                local gvClean = gvOk and IsUsableNumber(gv)
                local tag
                if not gvOk then tag = "|cffff4444FAIL|r"
                elseif gvClean then tag = "|cff44ff44CLEAN:" .. gv .. "|r"
                else tag = "|cffff6666TAINTED|r" end
                AddLine(lines, "  max=" .. thresh .. "  => " .. tag)
            end
        end
    end
    AddLine(lines, "")

    -- T3: GetText roundtrip
    AddLine(lines, "|cff88bbdd--- T3: GetText Roundtrip ---|r")
    do
        local fs = hiddenFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        local stOk = pcall(function() fs:SetText(format("%d", curVal)) end)
        if stOk then
            local gtOk, gt = pcall(fs.GetText, fs)
            local gtClean = false
            if gtOk and gt then
                local cmpOk = pcall(function() if gt == "___probe___" then end end)
                gtClean = cmpOk
            end
            if gtClean and gt then
                local num = tonumber(gt)
                if num then
                    AddLine(lines, "GetText: |cff44ff44CLEAN|r  parsed=" .. num)
                    if maxClean and maxVal > 0 then
                        AddLine(lines, "  => " .. format("%.1f%%", num / maxVal * 100))
                    end
                else
                    AddLine(lines, "GetText: readable but not numeric")
                end
            else
                AddLine(lines, "GetText: |cffff6666TAINTED|r")
            end
        else
            AddLine(lines, "SetText: |cffff4444FAILED|r")
        end
    end
    AddLine(lines, "")

    -- T4: Fill texture width
    AddLine(lines, "|cff88bbdd--- T4: Fill Texture Width ---|r")
    if maxClean and maxVal > 0 then
        local bar = CreateFrame("StatusBar", nil, hiddenFrame)
        bar:SetSize(200, 10)
        bar:SetPoint("CENTER")
        bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        pcall(bar.SetMinMaxValues, bar, 0, maxVal)
        pcall(bar.SetValue, bar, curVal)
        local ft = bar:GetStatusBarTexture()
        if ft then
            local fwOk, fw = pcall(ft.GetWidth, ft)
            local fwClean = fwOk and IsUsableNumber(fw)
            if not fwOk then
                AddLine(lines, "fillWidth: |cffff4444CALL FAILED|r")
            elseif fwClean then
                AddLine(lines, "fillWidth: |cff44ff44CLEAN|r  " .. format("%.1fpx => ~%.0f%%", fw, fw / 200 * 100))
            else
                AddLine(lines, "fillWidth: |cffff6666TAINTED|r")
            end
        else
            AddLine(lines, "no fill texture")
        end
    else
        AddLine(lines, "SKIPPED (no clean max)")
    end
    AddLine(lines, "")

    -- T5: Secret as max, read back
    AddLine(lines, "|cff88bbdd--- T5: Secret as Max ---|r")
    do
        local bar = CreateFrame("StatusBar", nil, hiddenFrame)
        bar:SetSize(100, 10)
        bar:SetPoint("CENTER")
        bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        local smmOk = pcall(bar.SetMinMaxValues, bar, 0, curVal)
        AddLine(lines, "SetMinMax(0, secret): " .. (smmOk and "ok" or "|cffff4444FAIL|r"))
        if smmOk then
            local gmOk, gMin, gMax = pcall(bar.GetMinMaxValues, bar)
            if gmOk then
                local maxU = IsUsableNumber(gMax)
                AddLine(lines, "GetMinMax: max " .. (maxU and ("|cff44ff44CLEAN:" .. gMax .. "|r") or "|cffff6666TAINTED|r"))
            end
            pcall(bar.SetValue, bar, curVal)
            local gvOk, gv = pcall(bar.GetValue, bar)
            local gvU = gvOk and IsUsableNumber(gv)
            AddLine(lines, "GetValue:  " .. (gvU and ("|cff44ff44CLEAN:" .. gv .. "|r") or "|cffff6666TAINTED|r"))
        end
    end
    AddLine(lines, "")

    -- T6a: Combat state detection
    AddLine(lines, "|cff88bbdd--- T6a: UnitAffectingCombat ---|r")
    do
        local combatUnit = unit
        local cOk, cVal = pcall(UnitAffectingCombat, combatUnit)
        if not cOk then
            AddLine(lines, "  " .. combatUnit .. ": |cffff4444CALL FAILED|r")
        else
            local cClean = pcall(function() if cVal then end end)
            if cClean then
                AddLine(lines, "  " .. combatUnit .. ": |cff44ff44CLEAN|r  inCombat=" .. tostring(cVal))
            else
                AddLine(lines, "  " .. combatUnit .. ": |cffff6666TAINTED|r")
            end
        end

        local pOk, pVal = pcall(UnitAffectingCombat, "player")
        if pOk then
            local pClean = pcall(function() if pVal then end end)
            if pClean then
                AddLine(lines, "  player: |cff44ff44CLEAN|r  inCombat=" .. tostring(pVal))
            else
                AddLine(lines, "  player: |cffff6666TAINTED|r")
            end
        end
    end
    AddLine(lines, "")

    -- T6b: Drinking buff detection
    AddLine(lines, "|cff88bbdd--- T6b: Drinking Buff Detection ---|r")
    do
        local drinkNames = {"Drinking", "Food & Drink", "Refreshment"}
        for _, buffName in ipairs(drinkNames) do
            local findOk, aura = pcall(AuraUtil.FindAuraByName, buffName, unit, "HELPFUL")
            if not findOk then
                AddLine(lines, "  " .. buffName .. ": |cffff4444CALL FAILED|r")
            elseif aura then
                local nameClean = false
                pcall(function() if aura == "___probe___" then end; nameClean = true end)
                if nameClean then
                    AddLine(lines, "  " .. buffName .. ": |cff44ff44FOUND (clean)|r")
                else
                    AddLine(lines, "  " .. buffName .. ": |cffff6666FOUND but TAINTED|r")
                end
            else
                AddLine(lines, "  " .. buffName .. ": not active")
            end
        end

        AddLine(lines, "")
        AddLine(lines, "  |cff88bbddAura scan (first 40 HELPFUL):|r")
        local anyFound = false
        for i = 1, 40 do
            local scanOk, name, _, _, _, _, _, _, _, _, spellId
            if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
                local dOk, data = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
                if dOk and data then
                    scanOk = true
                    spellId = data.spellId
                    local nClean = false
                    pcall(function()
                        if data.name == "___probe___" then end
                        nClean = true
                    end)
                    if nClean then
                        name = data.name
                    else
                        name = "TAINTED_NAME"
                    end
                else
                    break
                end
            else
                local aOk, a1, _, a3, a4, a5, a6, a7, a8, a9, a10 = pcall(UnitBuff, unit, i)
                if aOk and a1 then
                    scanOk = true
                    spellId = a10
                    local nClean = false
                    pcall(function()
                        if a1 == "___probe___" then end
                        nClean = true
                    end)
                    name = nClean and a1 or "TAINTED_NAME"
                else
                    break
                end
            end
            if scanOk and name then
                anyFound = true
                local idStr = spellId and tostring(spellId) or "?"
                local nameColor = (name == "TAINTED_NAME") and "|cffff6666" or "|cffa0ffa0"
                AddLine(lines, "    [" .. i .. "] " .. nameColor .. name .. "|r  (id=" .. idStr .. ")")
            end
        end
        if not anyFound then
            AddLine(lines, "    (no buffs found or all tainted)")
        end
    end

    return lines
end

local function ShowTestResults()
    if testResultFrame then
        testResultFrame:Hide()
        testResultFrame = nil
    end

    local ok, result = xpcall(RunSecretTests, function(e) return tostring(e) end)

    local lines
    if ok then
        lines = result
    else
        lines = {"|cffff4444TEST CRASHED:|r", tostring(result)}
    end

    local f = CreateFrame("Frame", "GMT_TestResults", UIParent, "BackdropTemplate")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.05, 0.05, 0.1, 0.95)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("|cff00ccffGMT Secret Extraction Tests|r")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local yOff = -35
    for _, line in ipairs(lines) do
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", 14, yOff)
        fs:SetWidth(450)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        fs:SetText(line)
        yOff = yOff - 16
    end

    f:SetSize(480, math.abs(yOff) + 20)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    f:Show()

    testResultFrame = f
end

SLASH_GMTTEST1 = "/gmttest"
SlashCmdList["GMTTEST"] = function()
    ShowTestResults()
end
