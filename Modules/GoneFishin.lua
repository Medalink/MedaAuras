local _, ns = ...

local MedaUI = LibStub("MedaUI-1.0")
local Pixel = MedaUI.Pixel

local format = format
local GetTime = GetTime
local pairs = pairs
local ipairs = ipairs
local wipe = wipe
local pcall = pcall
local unpack = unpack
local CreateFrame = CreateFrame
local math_sqrt = math.sqrt
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local math_abs = math.abs
local math_sin = math.sin
local math_cos = math.cos
local math_rad = math.rad
local C_Timer = C_Timer

-- ============================================================================
-- Constants
-- ============================================================================

local MODULE_NAME      = "GoneFishin"
local MODULE_VERSION   = "1.4"
local MODULE_STABILITY = "stable"   -- "experimental" | "beta" | "stable"
local FISHING_SPELL_NAMES = {
    ["Fishing"] = true,
    ["Void Hole Fishing"] = true,
}
local MAX_RECENT = 6
local ICON_ZOOM = 0.22
local ICON_TEXCOORD = { 0.11, 0.89, 0.11, 0.89 }
local OUTLINE_MAP = { none = "", outline = "OUTLINE", thick = "THICKOUTLINE" }
local QUALITY_COLORS = ITEM_QUALITY_COLORS or {}
local DISTANCE_INTERVAL = 2
local TIMER_INTERVAL = 1
local CHECKLIST_MAX_VISIBLE = 6
local CHECKLIST_ROW_HEIGHT = 20
local RARITY_SORT = { common = 1, uncommon = 2, rare = 3 }
local FALLBACK_DIM = { 0.6, 0.6, 0.6 }
local FALLBACK_GOLD = { 0.9, 0.7, 0.15 }
local FALLBACK_BRIGHT = { 1, 1, 1 }

-- ============================================================================
-- State
-- ============================================================================

local db
local isEnabled = false
local isFishing = false
local fishingStartTime = 0
local sessionStartTime = 0
local sessionCaught = 0
local sessionCasts = 0
local sessionJunk = 0
local currentStreak = 0
local hideTimer = nil

local SESSION_TIMEOUT = 300
local sessionTimer = nil
local sessionActive = false

local poolNameSet = {}
local itemInfoCache = {}

local eventFrame
local hudFrame, hudFadeCtrl
local leftPanel, rightPanel, bottomPanel
local statsPanel, tabBar, minimapButton
local scanTip

local arcDirty = true
local hudVisible = false
local distanceElapsed = 0
local timerElapsed = 0

local tabFrames = {}
local tabRendered = {}
local collectionList, zonesList
local collectionSearchBox

local checklistScroll, checklistContent
local checklistRows = {}
local expandRows = {}
local junkExpanded = false
local missingExpanded = false
local junkHeaderBtn, missingHeaderBtn

-- Font cache
local fontCache = {}
local function GetFontObj(fontValue, size, outline)
    local path = MedaUI:GetFontPath(fontValue)
    local flags = OUTLINE_MAP[outline] or outline or ""
    local key = (path or "default") .. "_" .. size .. "_" .. flags
    if fontCache[key] then return fontCache[key] end
    local fo = CreateFont("MedaAurasGF_" .. key:gsub("[^%w]", "_"))
    if path then
        fo:SetFont(path, size, flags)
    else
        fo:CopyFontObject(GameFontNormal)
        local p = fo:GetFont()
        fo:SetFont(p, size, flags)
    end
    fontCache[key] = fo
    return fo
end

-- ============================================================================
-- Data Migration
-- ============================================================================

local DB_VERSION = 3

local MIGRATIONS = {
    [1] = function(mdb)
        mdb.fishLog       = mdb.fishLog or {}
        mdb.zoneStats     = mdb.zoneStats or {}
        mdb.poolStats     = mdb.poolStats or {}
        mdb.favorites     = mdb.favorites or {}
        mdb.recentCatches = mdb.recentCatches or {}
        mdb.totalCaught      = mdb.totalCaught or 0
        mdb.totalCasts       = mdb.totalCasts or 0
        mdb.totalFishingTime = mdb.totalFishingTime or 0
        mdb.sessionCount     = mdb.sessionCount or 0
        mdb.longestStreak    = mdb.longestStreak or 0
    end,
    [2] = function(mdb)
        mdb.discoveredZones = mdb.discoveredZones or {}
        mdb.discoveredPools = mdb.discoveredPools or {}
        mdb.collectionSort  = mdb.collectionSort or "missing"
        for _, entry in pairs(mdb.fishLog) do
            entry.classID     = entry.classID or nil
            entry.subClassID  = entry.subClassID or nil
            entry.expansionID = entry.expansionID or nil
            entry.category    = entry.category or nil
        end
    end,
    [3] = function(mdb)
        if mdb.auraShowRecent ~= nil and mdb.auraShowChecklist == nil then
            mdb.auraShowChecklist = mdb.auraShowRecent
        end
        mdb.poolObjectNames = mdb.poolObjectNames or {}
    end,
}

local function RunMigrations(mdb)
    local currentVersion = mdb.dbVersion or 0
    if currentVersion >= DB_VERSION then return end

    for version = currentVersion + 1, DB_VERSION do
        local migrateFn = MIGRATIONS[version]
        if migrateFn then
            local ok, err = pcall(migrateFn, mdb)
            if ok then
                mdb.dbVersion = version
                MedaAuras.Log(format("[GoneFishin] Migration v%d applied", version))
            else
                MedaAuras.LogError(format("[GoneFishin] Migration v%d FAILED: %s", version, err))
                return
            end
        else
            mdb.dbVersion = version
        end
    end
end

-- ============================================================================
-- Helpers
-- ============================================================================

local function GetQualityColor(quality)
    local c = QUALITY_COLORS[quality]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function FormatTime(seconds)
    seconds = math_floor(seconds)
    if seconds >= 3600 then
        return format("%dh %02dm", math_floor(seconds / 3600), math_floor((seconds % 3600) / 60))
    elseif seconds >= 60 then
        return format("%dm %02ds", math_floor(seconds / 60), seconds % 60)
    end
    return format("%ds", seconds)
end

local function GetCurrentArea()
    local sub = GetSubZoneText()
    if sub and sub ~= "" then return sub end
    return GetMinimapZoneText() or ""
end

local function GetCurrentZone()
    return GetRealZoneText() or ""
end

local function GetFishingSkill()
    local _, _, _, fishIdx = GetProfessions()
    if not fishIdx then return 0, 0 end
    local _, _, cur, max = GetProfessionInfo(fishIdx)
    return cur or 0, max or 0
end

local function GetPlayerMapPos()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return nil, 0, 0 end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return mapID, 0, 0 end
    return mapID, pos:GetXY()
end

local function CacheItemInfo(itemID)
    if itemInfoCache[itemID] then return itemInfoCache[itemID] end
    local gfd = ns.GoneFishinData
    local staticData = gfd and gfd.midnightItems and gfd.midnightItems[itemID]
    if staticData then
        itemInfoCache[itemID] = {
            name = staticData.name, icon = staticData.icon or "",
            quality = staticData.quality or 1, category = staticData.category,
            isMidnight = true,
        }
        return itemInfoCache[itemID]
    end
    local name, _, quality, _, _, _, _, _, _, icon, _, classID, subClassID, _, expansionID = C_Item.GetItemInfo(itemID)
    if name then
        itemInfoCache[itemID] = {
            name = name, icon = icon, quality = quality,
            classID = classID, subClassID = subClassID, expansionID = expansionID,
        }
        return itemInfoCache[itemID]
    end
    return nil
end

-- Runtime item classification for items not in the static dataset
local CLASSID_CATEGORIES = {
    [0]  = "consumable",
    [2]  = "gear",
    [4]  = "gear",
    [7]  = "reagent",
    [9]  = "recipe",
    [12] = "quest",
    [15] = "other",
}
local MISC_SUBCLASS = {
    [0] = "junk", [2] = "pet", [4] = "mount", [5] = "toy",
}

local function ClassifyItem(itemID, info)
    local gfd = ns.GoneFishinData
    if gfd and gfd.midnightItems and gfd.midnightItems[itemID] then
        return gfd.midnightItems[itemID].category, true
    end

    info = info or CacheItemInfo(itemID)
    if not info then return "other", false end

    local quality = info.quality or 1
    if quality == 0 then return "junk", false end

    local classID = info.classID
    local subClassID = info.subClassID

    if classID == 7 and subClassID == 8 then
        return "fish", false
    end

    if classID == 15 then
        local sub = MISC_SUBCLASS[subClassID]
        if sub then return sub, false end
    end

    return CLASSID_CATEGORIES[classID] or "other", false
end

local function BuildPoolNameSet()
    wipe(poolNameSet)
    local gfd = ns.GoneFishinData
    if gfd and gfd.pools then
        for name in pairs(gfd.pools) do
            poolNameSet[name] = true
        end
    end
end

local function ComputeBestSpot()
    if not db then return end
    local best, bestCount = nil, 0
    for subzone, stats in pairs(db.poolStats) do
        if (stats.poolCatches or 0) > bestCount then
            bestCount = stats.poolCatches
            best = subzone
        end
    end
    db.bestSpot = best
end

local function GetCurrentFavId()
    local mapID = C_Map.GetBestMapForUnit("player")
    local subzone = GetCurrentArea()
    if mapID and subzone ~= "" then
        return mapID .. ":" .. subzone
    end
    return nil
end

local function IsCurrentSpotFaved()
    local favId = GetCurrentFavId()
    return favId and db.favorites[favId] ~= nil
end

-- ============================================================================
-- Pool Detection (Tooltip Scan)
-- ============================================================================

local function CreateScanTooltip()
    if scanTip then return end
    scanTip = CreateFrame("GameTooltip", "GoneFishinScanTip", nil, "GameTooltipTemplate")
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
end

local lastSeenPoolName = nil
local poolTooltipHooked = false

local POOL_KEYWORDS = {
    "School", "Pool", "Swarm", "Surge", "Ripple", "Bloom",
    "Torrent", "Vortex", "Cargo", "Treasures", "Salmon",
}

local function LooksLikePool(text)
    if not text then return false end
    if poolNameSet[text] then return true end
    for _, kw in ipairs(POOL_KEYWORDS) do
        if text:find(kw) then return true end
    end
    return false
end

local function HookPoolTooltip()
    if poolTooltipHooked then return end
    poolTooltipHooked = true
    GameTooltip:HookScript("OnShow", function(self)
        local ok, name = pcall(function()
            local line = _G[self:GetName() .. "TextLeft1"]
            if not line then return nil end
            local text = line:GetText()
            if LooksLikePool(text) then return text end
            return nil
        end)
        if ok and name then
            lastSeenPoolName = name
        end
    end)
end

local function LearnPoolObjectName(objectID, realName)
    if not db or not objectID or not realName then return end
    if not db.poolObjectNames then db.poolObjectNames = {} end
    if db.poolObjectNames[objectID] then return end
    db.poolObjectNames[objectID] = realName
    MedaAuras.Log(format("[GoneFishin] Learned pool: #%s = %s", objectID, realName))
end

local function RepairPoolNames()
    if not db or not db.poolObjectNames then return end
    local repaired = 0

    for objectID, realName in pairs(db.poolObjectNames) do
        local badKey = "Pool #" .. objectID

        for _, ps in pairs(db.poolStats) do
            if ps.pools and ps.pools[badKey] then
                ps.pools[realName] = (ps.pools[realName] or 0) + ps.pools[badKey]
                ps.pools[badKey] = nil
                repaired = repaired + 1
            end
        end

        if db.discoveredPools then
            for itemID, pools in pairs(db.discoveredPools) do
                if pools[badKey] then
                    pools[realName] = (pools[realName] or 0) + pools[badKey]
                    pools[badKey] = nil
                    repaired = repaired + 1
                end
            end
        end
    end

    if repaired > 0 then
        MedaAuras.Log(format("[GoneFishin] Repaired %d pool name entries", repaired))
    end
    return repaired
end

local function PurgeOpenWaterPoolData()
    if not db then return 0 end
    RepairPoolNames()
    local purged = 0
    local known = db.poolObjectNames or {}

    for _, ps in pairs(db.poolStats) do
        if ps.pools then
            for poolName, count in pairs(ps.pools) do
                local objID = poolName:match("^Pool #(%d+)$")
                if objID and not known[objID] then
                    ps.poolCatches = math_max(0, (ps.poolCatches or 0) - count)
                    ps.pools[poolName] = nil
                    purged = purged + 1
                end
            end
        end
    end

    if db.discoveredPools then
        for _, pools in pairs(db.discoveredPools) do
            for poolName in pairs(pools) do
                local objID = poolName:match("^Pool #(%d+)$")
                if objID and not known[objID] then
                    pools[poolName] = nil
                    purged = purged + 1
                end
            end
        end
    end

    if purged > 0 then
        MedaAuras.Log(format("[GoneFishin] Purged %d false pool entries from open water catches", purged))
    end
    return purged
end

local function DetectPool()
    for i = 1, GetNumLootItems() do
        local sources = { GetLootSourceInfo(i) }
        if sources[1] then
            local guid = sources[1]
            if type(guid) == "string" and guid:find("^GameObject") then
                local _, _, _, _, _, objectID = strsplit("-", guid)

                local resolvedName = lastSeenPoolName
                if not resolvedName and GameTooltip:IsShown() then
                    local line = _G[GameTooltip:GetName() .. "TextLeft1"]
                    if line then
                        local text = line:GetText()
                        if text and text ~= "" and LooksLikePool(text) then
                            resolvedName = text
                        end
                    end
                end

                lastSeenPoolName = nil

                if resolvedName and objectID then
                    LearnPoolObjectName(objectID, resolvedName)
                    return resolvedName
                end

                if objectID and db and db.poolObjectNames and db.poolObjectNames[objectID] then
                    return db.poolObjectNames[objectID]
                end

                return nil
            end
        end
    end
    lastSeenPoolName = nil
    return nil
end

-- ============================================================================
-- Data Recording
-- ============================================================================

local function RecordCatch(itemID, name, icon, quality)
    if not db then return end

    local now = time()
    db.totalCaught = db.totalCaught + 1
    sessionCaught = sessionCaught + 1

    local info = CacheItemInfo(itemID)
    local category, isMidnight = ClassifyItem(itemID, info)

    if category == "junk" then
        currentStreak = 0
        sessionJunk = sessionJunk + 1
    else
        currentStreak = currentStreak + 1
        if currentStreak > db.longestStreak then
            db.longestStreak = currentStreak
        end
    end

    local entry = db.fishLog[itemID]
    if not entry then
        entry = {
            name = name, icon = icon, quality = quality,
            count = 0, firstCaught = now, lastCaught = now,
            category = category,
        }
        if info then
            entry.classID     = info.classID
            entry.subClassID  = info.subClassID
            entry.expansionID = info.expansionID
        end
        db.fishLog[itemID] = entry
    end
    entry.count = entry.count + 1
    entry.lastCaught = now
    if not entry.name or entry.name == "" then entry.name = name end
    if not entry.icon or entry.icon == "" then entry.icon = icon end
    if not entry.category then entry.category = category end

    local recent = db.recentCatches
    table.insert(recent, 1, { itemID = itemID, name = name, icon = icon, quality = quality, time = now })
    while #recent > MAX_RECENT do
        table.remove(recent)
    end

    local zone = GetCurrentZone()
    local subzone = GetCurrentArea()
    if zone ~= "" then
        if not db.zoneStats[zone] then
            db.zoneStats[zone] = { total = 0, subZones = {} }
        end
        local zs = db.zoneStats[zone]
        zs.total = zs.total + 1
        if subzone ~= "" then
            if not zs.subZones[subzone] then
                zs.subZones[subzone] = { total = 0, items = {} }
            end
            local ss = zs.subZones[subzone]
            ss.total = ss.total + 1
            ss.items[itemID] = (ss.items[itemID] or 0) + 1
        end
    end

    local poolName = DetectPool()
    if subzone ~= "" then
        if not db.poolStats[subzone] then
            db.poolStats[subzone] = { poolCatches = 0, totalCatches = 0, pools = {} }
        end
        local ps = db.poolStats[subzone]
        ps.totalCatches = ps.totalCatches + 1
        if poolName then
            ps.poolCatches = ps.poolCatches + 1
            ps.pools[poolName] = (ps.pools[poolName] or 0) + 1
        end
    end

    -- Dynamic discovery tracking
    if zone ~= "" then
        if not db.discoveredZones[itemID] then
            db.discoveredZones[itemID] = {}
        end
        db.discoveredZones[itemID][zone] = (db.discoveredZones[itemID][zone] or 0) + 1
    end
    if poolName then
        if not db.discoveredPools[itemID] then
            db.discoveredPools[itemID] = {}
        end
        db.discoveredPools[itemID][poolName] = (db.discoveredPools[itemID][poolName] or 0) + 1
    end

    ComputeBestSpot()
end

-- ============================================================================
-- Favorites
-- ============================================================================

local function SaveFavorite()
    if not db then return end
    local mapID, x, y = GetPlayerMapPos()
    local zone = GetCurrentZone()
    local subzone = GetCurrentArea()
    if not mapID or subzone == "" then
        print("|cff00ccffGone Fishin':|r Cannot save favorite here.")
        return
    end

    local favId = mapID .. ":" .. subzone
    db.favorites[favId] = {
        label = subzone,
        zone = zone,
        subzone = subzone,
        mapID = mapID,
        x = x,
        y = y,
        notes = "",
        poolCatches = db.poolStats[subzone] and db.poolStats[subzone].poolCatches or 0,
    }

    local MapPins = ns.Services.MapPinProvider
    if MapPins then
        MapPins:SetPin("GoneFishin_Favorites", favId, db.favorites[favId])
    end

    print(format("|cff00ccffGone Fishin':|r Saved favorite: |cffffd100%s|r", subzone))
end

local function RemoveFavorite(favId)
    if not db or not favId then return end
    local fav = db.favorites[favId]
    db.favorites[favId] = nil

    local MapPins = ns.Services.MapPinProvider
    if MapPins then
        MapPins:RemovePin("GoneFishin_Favorites", favId)
    end

    if fav then
        print(format("|cff00ccffGone Fishin':|r Removed favorite: |cffffd100%s|r", fav.subzone or favId))
    end
end

local function ToggleFavorite()
    local favId = GetCurrentFavId()
    if not favId then return end
    if db.favorites[favId] then
        RemoveFavorite(favId)
    else
        SaveFavorite()
    end
end

local function SyncMapPins()
    local MapPins = ns.Services.MapPinProvider
    if not MapPins then return end

    MapPins:RegisterPinGroup("GoneFishin_Favorites", {
        icon = "Interface\\Icons\\Trade_Fishing",
        iconSize = 20,
        tooltipFunc = function(pin)
            GameTooltip:AddLine(pin.data.label or "Fishing Spot", 0.9, 0.7, 0.15)
            GameTooltip:AddLine(format("Pool catches: %d", pin.data.poolCatches or 0), 1, 1, 1)
            if pin.data.notes and pin.data.notes ~= "" then
                GameTooltip:AddLine(pin.data.notes, 0.7, 0.7, 0.7, true)
            end
        end,
    })

    for favId, fav in pairs(db.favorites) do
        MapPins:SetPin("GoneFishin_Favorites", favId, fav)
    end

    MapPins:SetGroupVisible("GoneFishin_Favorites", db.showMapPins ~= false)
end

-- ============================================================================
-- Arc HUD
-- ============================================================================

local leftTexts = {}
local centerTexts = {}
local faveButton
local endSessionBtn

local LINE_SPACING = 18

local function MakePanelDraggable(panel, dbKey)
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(not db.auraLockPanels)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self)
        if not db.auraLockPanels then self:StartMoving() end
    end)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local cx, cy = self:GetCenter()
        local hcx, hcy = hudFrame:GetCenter()
        self:ClearAllPoints()
        self:SetPoint("CENTER", hudFrame, "CENTER", cx - hcx, cy - hcy)
        db[dbKey] = { x = cx - hcx, y = cy - hcy }
    end)
end

local function SetPanelsLocked(locked)
    if leftPanel then leftPanel:EnableMouse(not locked) end
    if rightPanel then rightPanel:EnableMouse(not locked) end
    if bottomPanel then bottomPanel:EnableMouse(not locked) end
end

local function RestorePanelPos(panel, dbKey, defX, defY)
    panel:ClearAllPoints()
    local pos = db[dbKey]
    if pos then
        panel:SetPoint("CENTER", hudFrame, "CENTER", pos.x, pos.y)
    else
        panel:SetPoint("CENTER", hudFrame, "CENTER", defX, defY)
    end
end

local function CreateRow(parent)
    local iconSz = db.auraIconSize or 20
    local textFont = GetFontObj(db.auraFont or "default", db.auraTextSize or 13, db.auraTextOutline or "outline")

    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(250, CHECKLIST_ROW_HEIGHT)

    local icon = CreateFrame("Frame", nil, row)
    icon:SetSize(iconSz, iconSz)
    icon:SetPoint("LEFT", row, "LEFT", 0, 0)
    local tex = icon:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexCoord(unpack(ICON_TEXCOORD))
    icon.tex = tex
    row.icon = icon

    local fs = row:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject(textFont)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    fs:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    fs:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.text = fs

    return row
end

local function GetChecklistRow(index)
    if checklistRows[index] then return checklistRows[index] end
    local row = CreateRow(checklistContent)
    checklistRows[index] = row
    return row
end

local function GetExpandRow(index)
    if expandRows[index] then return expandRows[index] end
    local row = CreateRow(rightPanel)
    expandRows[index] = row
    return row
end

local function CreateHUD()
    if hudFrame then return end

    hudFrame = CreateFrame("Frame", "MedaAuras_GoneFishinHUD", UIParent)
    hudFrame:SetSize(1, 1)
    hudFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    hudFrame:SetFrameStrata("BACKGROUND")
    hudFrame:SetFrameLevel(1)
    hudFrame:Hide()

    local textFont = GetFontObj(db.auraFont or "default", db.auraTextSize or 13, db.auraTextOutline or "outline")
    local headerFont = GetFontObj(db.auraFont or "default", (db.auraTextSize or 13) + 2, "thick")
    local smallFont = GetFontObj(db.auraFont or "default", math_max((db.auraTextSize or 13) - 3, 8), db.auraTextOutline or "outline")

    -- ---- Left Panel (zone, session stats) ----
    leftPanel = CreateFrame("Frame", nil, hudFrame)
    leftPanel:SetSize(300, 8 * LINE_SPACING)
    MakePanelDraggable(leftPanel, "leftPanelPos")

    for i = 1, 8 do
        local fs = leftPanel:CreateFontString(nil, "OVERLAY")
        local font = (i <= 2 and headerFont) or textFont
        fs:SetFontObject(font)
        fs:SetJustifyH("RIGHT")
        fs:SetWordWrap(false)
        fs:SetPoint("TOPRIGHT", leftPanel, "TOPRIGHT", 0, -(i - 1) * LINE_SPACING)
        leftTexts[i] = fs
    end

    -- ---- Right Panel (zone fish checklist) ----
    rightPanel = CreateFrame("Frame", nil, hudFrame)
    rightPanel:SetSize(280, CHECKLIST_MAX_VISIBLE * CHECKLIST_ROW_HEIGHT)
    MakePanelDraggable(rightPanel, "rightPanelPos")

    local scrollHeight = CHECKLIST_MAX_VISIBLE * CHECKLIST_ROW_HEIGHT
    checklistScroll = MedaUI:CreateScrollFrame(rightPanel, nil, 280, scrollHeight)
    Pixel.SetPoint(checklistScroll, "TOPLEFT", rightPanel, "TOPLEFT", 0, 0)
    checklistScroll:SetScrollStep(CHECKLIST_ROW_HEIGHT * 2)

    checklistContent = checklistScroll.scrollContent
    Pixel.SetHeight(checklistContent, 1)

    -- Collapsible section headers (outside scroll area, in rightPanel)
    junkHeaderBtn = CreateFrame("Button", nil, rightPanel)
    junkHeaderBtn:SetSize(280, CHECKLIST_ROW_HEIGHT)
    junkHeaderBtn.text = junkHeaderBtn:CreateFontString(nil, "OVERLAY")
    junkHeaderBtn.text:SetFontObject(smallFont)
    junkHeaderBtn.text:SetAllPoints()
    junkHeaderBtn.text:SetJustifyH("LEFT")
    junkHeaderBtn:SetScript("OnClick", function()
        junkExpanded = not junkExpanded
        arcDirty = true
    end)

    missingHeaderBtn = CreateFrame("Button", nil, rightPanel)
    missingHeaderBtn:SetSize(280, CHECKLIST_ROW_HEIGHT)
    missingHeaderBtn.text = missingHeaderBtn:CreateFontString(nil, "OVERLAY")
    missingHeaderBtn.text:SetFontObject(smallFont)
    missingHeaderBtn.text:SetAllPoints()
    missingHeaderBtn.text:SetJustifyH("LEFT")
    missingHeaderBtn:SetScript("OnClick", function()
        missingExpanded = not missingExpanded
        arcDirty = true
    end)

    -- ---- Bottom Panel (fave, best spot, lure hint) ----
    bottomPanel = CreateFrame("Frame", nil, hudFrame)
    bottomPanel:SetSize(300, 70)
    MakePanelDraggable(bottomPanel, "bottomPanelPos")

    for i = 1, 3 do
        local fs = bottomPanel:CreateFontString(nil, "OVERLAY")
        fs:SetFontObject(textFont)
        fs:SetJustifyH("CENTER")
        fs:SetWordWrap(false)
        centerTexts[i] = fs
    end
    centerTexts[1]:SetPoint("TOP", bottomPanel, "TOP", 10, 0)
    centerTexts[2]:SetPoint("TOP", bottomPanel, "TOP", 0, -16)
    centerTexts[3]:SetPoint("TOP", bottomPanel, "TOP", 0, -32)

    faveButton = CreateFrame("Button", nil, bottomPanel)
    faveButton:SetSize(16, 16)
    faveButton.tex = faveButton:CreateTexture(nil, "ARTWORK")
    faveButton.tex:SetAllPoints()
    faveButton.tex:SetAtlas("Waypoint-MapPin-Untracked")
    faveButton:SetScript("OnClick", function()
        ToggleFavorite()
        arcDirty = true
    end)
    faveButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if IsCurrentSpotFaved() then
            GameTooltip:AddLine("Click to remove favorite", 1, 1, 1)
        else
            GameTooltip:AddLine("Click to save as favorite", 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    faveButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    faveButton:SetPoint("RIGHT", centerTexts[1], "LEFT", -2, 0)

    endSessionBtn = CreateFrame("Button", nil, bottomPanel)
    endSessionBtn:SetSize(80, 16)
    endSessionBtn.text = endSessionBtn:CreateFontString(nil, "OVERLAY")
    endSessionBtn.text:SetFontObject(textFont)
    endSessionBtn.text:SetAllPoints()
    endSessionBtn.text:SetText("|cff888888End Session|r")
    endSessionBtn:SetScript("OnClick", function()
        if sessionActive then
            CancelSessionTimeout()
            EndSession()
            HideHUD()
            print("|cff00ccffGone Fishin':|r Session ended.")
        end
    end)
    endSessionBtn:SetScript("OnEnter", function(self)
        self.text:SetText("|cffccccccEnd Session|r")
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Click to end fishing session", 1, 1, 1)
        GameTooltip:Show()
    end)
    endSessionBtn:SetScript("OnLeave", function(self)
        self.text:SetText("|cff888888End Session|r")
        GameTooltip:Hide()
    end)
    endSessionBtn:SetPoint("TOP", bottomPanel, "TOP", 0, -52)

    hudFadeCtrl = MedaUI:CreateFadeEffect(hudFrame, {
        fadeInDuration = db.auraFadeIn or 0.4,
        fadeOutDuration = db.auraFadeOut or 0.6,
    })
end

local function RecalcPositions()
    if not hudFrame then return end

    local scale = db.auraScale or 1.0
    hudFrame:SetScale(scale)
    hudFrame:SetAlpha(db.auraOpacity or 0.92)

    local xOff = db.auraHOffset or 200
    local vOff = db.auraVerticalOffset or -20

    local leftDefX = -xOff - 150
    local leftDefY = vOff + 60 + LINE_SPACING / 2 - 4 * LINE_SPACING
    RestorePanelPos(leftPanel, "leftPanelPos", leftDefX, leftDefY)

    local rightDefX = xOff + 140
    local rightDefY = leftDefY
    RestorePanelPos(rightPanel, "rightPanelPos", rightDefX, rightDefY)

    local bottomDefY = vOff + 60 - 8 * LINE_SPACING - 8 - 35
    RestorePanelPos(bottomPanel, "bottomPanelPos", 0, bottomDefY)

    local iconSz = db.auraIconSize or 20
    for _, row in ipairs(checklistRows) do
        if row.icon then row.icon:SetSize(iconSz, iconSz) end
    end
    for _, row in ipairs(expandRows) do
        if row.icon then row.icon:SetSize(iconSz, iconSz) end
    end

    local textFont = GetFontObj(db.auraFont or "default", db.auraTextSize or 13, db.auraTextOutline or "outline")
    local headerFont = GetFontObj(db.auraFont or "default", (db.auraTextSize or 13) + 2, "thick")
    local smallFont = GetFontObj(db.auraFont or "default", math_max((db.auraTextSize or 13) - 3, 8), db.auraTextOutline or "outline")

    for i = 1, 8 do
        if leftTexts[i] then
            leftTexts[i]:SetFontObject(i <= 2 and headerFont or textFont)
        end
    end
    for i = 1, 3 do
        if centerTexts[i] then centerTexts[i]:SetFontObject(textFont) end
    end
    for _, row in ipairs(checklistRows) do
        if row.text then row.text:SetFontObject(textFont) end
    end
    for _, row in ipairs(expandRows) do
        if row.text then row.text:SetFontObject(textFont) end
    end
    if junkHeaderBtn and junkHeaderBtn.text then junkHeaderBtn.text:SetFontObject(smallFont) end
    if missingHeaderBtn and missingHeaderBtn.text then missingHeaderBtn.text:SetFontObject(smallFont) end
    if endSessionBtn and endSessionBtn.text then endSessionBtn.text:SetFontObject(textFont) end
end

-- Lure hint state for rotation
local lureHintPool = {}
local lureHintIndex = 0
local lureHintLastRotate = 0
local LURE_HINT_ROTATE_INTERVAL = 10

local function GetLureHint(zone, area)
    local gfd = ns.GoneFishinData
    if not gfd or not gfd.midnightItems or not gfd.lureLookup or not gfd.zoneAliasMap then
        return nil
    end

    local canonical = gfd.zoneAliasMap[zone] or gfd.zoneAliasMap[area]

    -- Voidstorm special tip
    if canonical == "Voidstorm" then
        local now = GetTime()
        if now - lureHintLastRotate > LURE_HINT_ROTATE_INTERVAL then
            lureHintLastRotate = now
            lureHintIndex = lureHintIndex + 1
        end
        if lureHintIndex % 2 == 0 then
            return "|cff8888ccTip: Fish from Oceanic Vortex bubbles (no open water here)|r"
        end
    end

    if not canonical then return nil end

    -- Build tips for this zone
    local now = GetTime()
    if now - lureHintLastRotate > LURE_HINT_ROTATE_INTERVAL or #lureHintPool == 0 then
        lureHintLastRotate = now
        wipe(lureHintPool)

        for itemID, info in pairs(gfd.midnightItems) do
            if info.category == "fish" and info.openWaterZones then
                local inZone = false
                for _, z in ipairs(info.openWaterZones) do
                    if z == canonical then inZone = true; break end
                end
                if inZone then
                    local logEntry = db and db.fishLog[itemID]
                    local count = logEntry and logEntry.count or 0
                    if count == 0 then
                        local lure = gfd.lureLookup[info.name]
                        if lure then
                            lureHintPool[#lureHintPool + 1] = format(
                                "|cff88cc88Tip: Use %s for %s|r", lure.lureName, info.name
                            )
                        else
                            lureHintPool[#lureHintPool + 1] = format(
                                "|cffaaaaaa%s not yet caught here|r", info.name
                            )
                        end
                    end
                end
            end
        end

        if #lureHintPool > 0 then
            lureHintIndex = lureHintIndex + 1
        end
    end

    if #lureHintPool == 0 then return nil end
    local idx = ((lureHintIndex - 1) % #lureHintPool) + 1
    return lureHintPool[idx]
end

-- ============================================================================
-- Zone Fish Checklist Data
-- ============================================================================

local function GetZoneFishLists(zone, area)
    local gfd = ns.GoneFishinData
    if not gfd or not gfd.midnightItems or not gfd.zoneAliasMap then
        return {}, {}, {}
    end

    local canonical = gfd.zoneAliasMap[zone] or gfd.zoneAliasMap[area]
    if not canonical then return {}, {}, {} end

    local zoneFishSet = {}
    for itemID, info in pairs(gfd.midnightItems) do
        if info.category == "fish" and info.openWaterZones then
            for _, z in ipairs(info.openWaterZones) do
                if z == canonical then
                    zoneFishSet[itemID] = true
                    break
                end
            end
        end
    end
    if gfd.pools then
        for _, poolInfo in pairs(gfd.pools) do
            local inZone = false
            if poolInfo.zones then
                for _, z in ipairs(poolInfo.zones) do
                    if z == canonical then inZone = true; break end
                end
            end
            if inZone and poolInfo.fish then
                for _, fishID in ipairs(poolInfo.fish) do
                    zoneFishSet[fishID] = true
                end
            end
        end
    end

    local caught, missing = {}, {}
    for itemID in pairs(zoneFishSet) do
        local info = gfd.midnightItems[itemID]
        if info then
            local logEntry = db and db.fishLog[itemID]
            local count = logEntry and logEntry.count or 0
            local entry = {
                itemID = itemID,
                name = info.name,
                icon = info.icon,
                quality = info.quality or 1,
                rarity = info.rarity or "common",
                count = count,
            }
            if count > 0 then
                caught[#caught + 1] = entry
            else
                missing[#missing + 1] = entry
            end
        end
    end

    local junk = {}
    local junkSeen = {}
    if db then
        local zs = db.zoneStats[zone]
        if zs and zs.subZones then
            for _, subInfo in pairs(zs.subZones) do
                if subInfo.items then
                    for itemID, cnt in pairs(subInfo.items) do
                        if not junkSeen[itemID] then
                            local cat = ClassifyItem(itemID)
                            if cat == "junk" then
                                junkSeen[itemID] = true
                                local logEntry = db.fishLog[itemID]
                                junk[#junk + 1] = {
                                    itemID = itemID,
                                    name = logEntry and logEntry.name or ("Item " .. itemID),
                                    icon = logEntry and logEntry.icon or "inv_misc_questionmark",
                                    quality = logEntry and logEntry.quality or 0,
                                    count = logEntry and logEntry.count or cnt,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(caught, function(a, b)
        if a.quality ~= b.quality then return a.quality > b.quality end
        return a.name < b.name
    end)
    table.sort(missing, function(a, b)
        local ra = RARITY_SORT[a.rarity] or 0
        local rb = RARITY_SORT[b.rarity] or 0
        if ra ~= rb then return ra < rb end
        return a.name < b.name
    end)
    table.sort(junk, function(a, b) return a.name < b.name end)

    return caught, missing, junk
end

local function UpdateHUDContent()
    if not hudFrame or not db then return end

    local Theme = MedaUI.Theme
    local gold = Theme and Theme.gold or FALLBACK_GOLD
    local dim = Theme and Theme.textDim or FALLBACK_DIM
    local bright = Theme and Theme.text or FALLBACK_BRIGHT

    local area = GetCurrentArea()
    local zone = GetCurrentZone()
    local skillCur, skillMax = GetFishingSkill()
    local notMaxed = skillMax > 0 and skillCur < skillMax

    leftTexts[1]:SetText(area)
    leftTexts[1]:SetTextColor(gold[1], gold[2], gold[3])
    leftTexts[2]:SetText(area ~= zone and zone or "")
    leftTexts[2]:SetTextColor(dim[1], dim[2], dim[3])
    leftTexts[3]:SetText("")
    if db.auraShowSessionJunk ~= false then
        leftTexts[4]:SetText(format("Session: %d fish | %d junk", sessionCaught, sessionJunk))
    else
        leftTexts[4]:SetText(format("Session: %d fish", sessionCaught))
    end
    leftTexts[4]:SetTextColor(bright[1], bright[2], bright[3])

    local rate = sessionCasts > 0 and math_floor(sessionCaught / sessionCasts * 100) or 0
    leftTexts[5]:SetText(format("Casts: %d | Rate: %d%%", sessionCasts, rate))
    leftTexts[5]:SetTextColor(dim[1], dim[2], dim[3])

    local elapsed = sessionActive and sessionStartTime > 0 and (GetTime() - sessionStartTime) or 0
    leftTexts[6]:SetText(format("Time: %s", FormatTime(elapsed)))
    leftTexts[6]:SetTextColor(dim[1], dim[2], dim[3])

    local streakColor = currentStreak >= db.longestStreak and currentStreak > 0 and gold or dim
    leftTexts[7]:SetText(format("Streak: %d", currentStreak))
    leftTexts[7]:SetTextColor(streakColor[1], streakColor[2], streakColor[3])

    if notMaxed then
        leftTexts[8]:SetText(format("Fishing: %d/%d", skillCur, skillMax))
        leftTexts[8]:SetTextColor(dim[1], dim[2], dim[3])
    else
        leftTexts[8]:SetText("")
    end

    local showChecklist = db.auraShowChecklist ~= false
    if showChecklist and checklistContent then
        rightPanel:Show()
        local caught, missingList, junkList = GetZoneFishLists(zone, area)

        local function PopulateRow(row, entry, desaturate)
            local iconPath = entry.icon
            if type(iconPath) == "string" and not iconPath:find("\\") then
                iconPath = "Interface\\Icons\\" .. iconPath
            end
            row.icon:Show()
            row.icon.tex:SetTexture(iconPath)
            row.icon.tex:SetDesaturated(desaturate or false)

            local r, g, b = GetQualityColor(entry.quality or 1)
            if desaturate then
                row.text:SetText(format("|cff666666%s|r", entry.name or "?"))
            elseif entry.count and entry.count > 0 then
                row.text:SetText(format("|cff%02x%02x%02x%s|r |cff999999(x%d)|r", r * 255, g * 255, b * 255, entry.name or "?", entry.count))
            else
                row.text:SetText(format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, entry.name or "?"))
            end
        end

        -- Caught fish inside the scroll area
        for i, entry in ipairs(caught) do
            local row = GetChecklistRow(i)
            row:Show()
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", checklistContent, "TOPLEFT", 0, -(i - 1) * CHECKLIST_ROW_HEIGHT)
            PopulateRow(row, entry, false)
        end
        for i = #caught + 1, #checklistRows do
            checklistRows[i]:Hide()
        end

        local caughtHeight = #caught * CHECKLIST_ROW_HEIGHT
        checklistContent:SetHeight(math_max(caughtHeight, 1))

        local scrollVisibleH = math_min(CHECKLIST_MAX_VISIBLE, #caught) * CHECKLIST_ROW_HEIGHT
        Pixel.SetHeight(checklistScroll, math_max(scrollVisibleH, 1))

        -- Expand sections below the scroll area
        local belowY = -scrollVisibleH
        local expIdx = 0

        if #junkList > 0 then
            junkHeaderBtn:Show()
            junkHeaderBtn:ClearAllPoints()
            junkHeaderBtn:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 0, belowY)
            local arrow = junkExpanded and "[-]" or "[+]"
            junkHeaderBtn.text:SetText(format("|cff888888%s Junk (%d)|r", arrow, #junkList))
            belowY = belowY - CHECKLIST_ROW_HEIGHT
            if junkExpanded then
                for _, entry in ipairs(junkList) do
                    expIdx = expIdx + 1
                    local row = GetExpandRow(expIdx)
                    row:Show()
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 0, belowY)
                    PopulateRow(row, entry, false)
                    belowY = belowY - CHECKLIST_ROW_HEIGHT
                end
            end
        else
            junkHeaderBtn:Hide()
        end

        if #missingList > 0 then
            missingHeaderBtn:Show()
            missingHeaderBtn:ClearAllPoints()
            missingHeaderBtn:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 0, belowY)
            local arrow = missingExpanded and "[-]" or "[+]"
            missingHeaderBtn.text:SetText(format("|cff888888%s Missing (%d)|r", arrow, #missingList))
            belowY = belowY - CHECKLIST_ROW_HEIGHT
            if missingExpanded then
                for _, entry in ipairs(missingList) do
                    expIdx = expIdx + 1
                    local row = GetExpandRow(expIdx)
                    row:Show()
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 0, belowY)
                    PopulateRow(row, entry, true)
                    belowY = belowY - CHECKLIST_ROW_HEIGHT
                end
            end
        else
            missingHeaderBtn:Hide()
        end

        for i = expIdx + 1, #expandRows do
            expandRows[i]:Hide()
        end

        rightPanel:SetHeight(math_max(-belowY, CHECKLIST_ROW_HEIGHT))
    elseif rightPanel then
        rightPanel:Hide()
    end

    if db.auraShowFaves ~= false then
        faveButton:Show()
        if IsCurrentSpotFaved() then
            faveButton.tex:SetAtlas("Waypoint-MapPin-Tracked")
            faveButton.tex:SetDesaturated(false)
            local subzone = GetCurrentArea()
            centerTexts[1]:SetText(format("|cffffd100Fave: %s|r", subzone))
        else
            faveButton.tex:SetAtlas("Waypoint-MapPin-Untracked")
            faveButton.tex:SetDesaturated(true)
            centerTexts[1]:SetText("|cff666666No favorite set|r")
        end
    else
        faveButton:Hide()
        centerTexts[1]:SetText("")
    end

    if db.auraShowBestSpot ~= false then
        local bestSpot = db.bestSpot
        if bestSpot then
            local ps = db.poolStats[bestSpot]
            local poolCount = ps and ps.poolCatches or 0
            centerTexts[2]:SetText(format("Best Spot: |cffffffff%s|r |cff999999(%d pool catches)|r", bestSpot, poolCount))
        else
            centerTexts[2]:SetText("|cff666666No pool data yet|r")
        end
    else
        centerTexts[2]:SetText("")
    end

    if db.auraShowTips ~= false then
        local lureHint = GetLureHint(zone, area)
        centerTexts[3]:SetText(lureHint or "")
    else
        centerTexts[3]:SetText("")
    end
end

local function UpdateDistanceText()
    if not hudFrame or not db then return end

    local showFaves = db.auraShowFaves ~= false
    local showTips = db.auraShowTips ~= false

    if not showFaves and not showTips then
        centerTexts[3]:SetText("")
        return
    end

    local mapID, px, py = GetPlayerMapPos()

    if showFaves and mapID then
        local nearestDist = math.huge
        for _, fav in pairs(db.favorites) do
            if fav.mapID == mapID and fav.x and fav.y then
                local dx, dy = px - fav.x, py - fav.y
                local dist = math_sqrt(dx * dx + dy * dy)
                if dist < nearestDist then
                    nearestDist = dist
                end
            end
        end
        if nearestDist < math.huge then
            local yards = nearestDist * 1000
            centerTexts[3]:SetText(format("|cff999999~%d yd to fave|r", math_floor(yards)))
            return
        end
    end

    if showTips then
        local zone = GetCurrentZone()
        local area = GetCurrentArea()
        centerTexts[3]:SetText(GetLureHint(zone, area) or "")
    else
        centerTexts[3]:SetText("")
    end
end

local FRAME_THROTTLE = 0.033 -- ~30 Hz cap
local frameElapsed = 0

local function HUD_OnUpdate(self, elapsed)
    frameElapsed = frameElapsed + elapsed
    timerElapsed = timerElapsed + elapsed
    distanceElapsed = distanceElapsed + elapsed

    if frameElapsed < FRAME_THROTTLE then return end
    frameElapsed = 0

    if arcDirty then
        RecalcPositions()
        UpdateHUDContent()
        arcDirty = false
    end

    if timerElapsed >= TIMER_INTERVAL then
        timerElapsed = 0
        if sessionActive and sessionStartTime > 0 then
            local sessionTime = GetTime() - sessionStartTime
            local dim = MedaUI.Theme and MedaUI.Theme.textDim or FALLBACK_DIM
            leftTexts[6]:SetText(format("Time: %s", FormatTime(sessionTime)))
            leftTexts[6]:SetTextColor(dim[1], dim[2], dim[3])
        end
    end

    if distanceElapsed >= DISTANCE_INTERVAL then
        distanceElapsed = 0
        UpdateDistanceText()
    end
end

local function EnableHUDUpdates()
    if hudFrame then
        hudFrame:SetScript("OnUpdate", HUD_OnUpdate)
    end
end

local function DisableHUDUpdates()
    if hudFrame then
        hudFrame:SetScript("OnUpdate", nil)
    end
end

local function ShowHUD()
    if not db or not db.auraEnabled then return end
    if not hudFrame then CreateHUD() end

    if hideTimer then
        hideTimer:Cancel()
        hideTimer = nil
    end

    arcDirty = true
    timerElapsed = 0
    distanceElapsed = 0
    EnableHUDUpdates()

    if not hudVisible then
        hudFadeCtrl:FadeIn()
        hudVisible = true
    end
end

local function HideHUD()
    if not hudFrame or not hudVisible then return end

    local delay = db and db.auraHideDelay or 8
    if hideTimer then hideTimer:Cancel() end
    hideTimer = C_Timer.NewTimer(delay, function()
        hideTimer = nil
        if hudFadeCtrl then
            hudFadeCtrl:FadeOut()
        end
        C_Timer.After((db and db.auraFadeOut or 0.6) + 0.1, function()
            DisableHUDUpdates()
            hudVisible = false
        end)
    end)
end

local function SaveSessionState()
    if not db then return end
    if sessionActive then
        local elapsed = sessionStartTime > 0 and (GetTime() - sessionStartTime) or 0
        db.currentSession = {
            elapsed = elapsed,
            caught = sessionCaught,
            casts = sessionCasts,
            junk = sessionJunk,
            streak = currentStreak,
            savedAt = GetServerTime(),
        }
    else
        db.currentSession = nil
    end
end

local function RestoreSession()
    local s = db and db.currentSession
    if not s then return end
    local gap = GetServerTime() - (s.savedAt or 0)
    if gap > SESSION_TIMEOUT then
        db.currentSession = nil
        return
    end
    sessionActive = true
    sessionStartTime = GetTime() - (s.elapsed or 0) - gap
    sessionCaught = s.caught or 0
    sessionCasts = s.casts or 0
    sessionJunk = s.junk or 0
    currentStreak = s.streak or 0
end

local function EndSession()
    if not sessionActive then return end
    sessionActive = false
    if fishingStartTime > 0 then
        db.totalFishingTime = db.totalFishingTime + (GetTime() - fishingStartTime)
        fishingStartTime = 0
    end
    isFishing = false
    if db then db.currentSession = nil end
end

local function CancelSessionTimeout()
    if sessionTimer then
        sessionTimer:Cancel()
        sessionTimer = nil
    end
end

local function StartSessionTimeout()
    CancelSessionTimeout()
    sessionTimer = C_Timer.NewTimer(SESSION_TIMEOUT, function()
        sessionTimer = nil
        EndSession()
    end)
end

-- ============================================================================
-- Stats Window
-- ============================================================================

local function CreateStatsPanel()
    if statsPanel then return end

    statsPanel = MedaUI:CreatePanel("MedaAurasGoneFishinStats", 520, 500, "Gone Fishin' Stats")
    local content = statsPanel:GetContent()

    tabBar = MedaUI:CreateTabBar(content, {
        { id = "overview",   label = "Overview" },
        { id = "collection", label = "Collection" },
        { id = "zones",      label = "Zones" },
    })
    tabBar:SetPoint("TOPLEFT", 0, 0)
    tabBar:SetPoint("TOPRIGHT", 0, 0)

    for _, tabId in ipairs({ "overview", "collection", "zones" }) do
        local frame = CreateFrame("Frame", nil, content)
        frame:SetPoint("TOPLEFT", 0, -32)
        frame:SetPoint("BOTTOMRIGHT", 0, 0)
        frame:Hide()
        tabFrames[tabId] = frame
    end

    tabBar.OnTabChanged = function(_, tabId)
        for id, frame in pairs(tabFrames) do
            if id == tabId then
                frame:Show()
            else
                frame:Hide()
            end
        end

        if not tabRendered[tabId] then
            if tabId == "overview" then
                BuildOverviewTab(tabFrames.overview)
            elseif tabId == "collection" then
                BuildCollectionTab(tabFrames.collection)
            elseif tabId == "zones" then
                BuildZonesTab(tabFrames.zones)
            end
            tabRendered[tabId] = true
        else
            if tabId == "overview" then
                RefreshOverviewTab()
            elseif tabId == "collection" then
                RefreshCollectionTab()
            elseif tabId == "zones" then
                RefreshZonesTab()
            end
        end
    end

    statsPanel.OnMove = function(self, state)
        if db then db.statsPosition = state.position end
    end

    if db.statsPosition then
        statsPanel:RestoreState({ position = db.statsPosition })
    end

    -- Force-build the default tab since CreateTabBar may auto-select
    -- the first tab before OnTabChanged is assigned
    tabFrames.overview:Show()
    BuildOverviewTab(tabFrames.overview)
    tabRendered.overview = true
end

-- ============================================================================
-- Overview Tab
-- ============================================================================

local overviewTexts = {}

function BuildOverviewTab(parent)
    local yOff = -8
    local Theme = MedaUI.Theme
    local gold = Theme and Theme.gold or FALLBACK_GOLD
    local bright = Theme and Theme.text or FALLBACK_BRIGHT
    local dim = Theme and Theme.textDim or FALLBACK_DIM

    local function AddHeader(text)
        local hdr = MedaUI:CreateSectionHeader(parent, text)
        hdr:SetPoint("TOPLEFT", 0, yOff)
        yOff = yOff - 35
    end

    local function AddStat(label, key, col)
        local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("TOPLEFT", col == 2 and 250 or 8, yOff)
        lbl:SetTextColor(dim[1], dim[2], dim[3])
        lbl:SetText(label)

        local val = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        val:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
        val:SetTextColor(bright[1], bright[2], bright[3])
        overviewTexts[key] = val
    end

    AddHeader("Lifetime Stats")
    AddStat("Total Fish Caught:", "totalCaught", 1)
    AddStat("Total Casts:", "totalCasts", 2)
    yOff = yOff - 22
    AddStat("Catch Rate:", "catchRate", 1)
    AddStat("Time Fishing:", "totalTime", 2)
    yOff = yOff - 22
    AddStat("Fish Per Hour:", "fishPerHour", 1)
    AddStat("Unique Species:", "uniqueSpecies", 2)
    yOff = yOff - 30

    AddHeader("Records")
    AddStat("Most Caught:", "mostCaught", 1)
    AddStat("Rarest Catch:", "rarestCatch", 2)
    yOff = yOff - 22
    AddStat("Longest Streak:", "longestStreak", 1)
    AddStat("Sessions:", "sessionCount", 2)
    yOff = yOff - 22
    AddStat("Avg Fish/Session:", "avgPerSession", 1)
    AddStat("Favorite Zone:", "favZone", 2)
    yOff = yOff - 30

    AddHeader("Spots")
    AddStat("Best Spot:", "bestSpot", 1)
    AddStat("Pool Catches:", "poolCatches", 2)
    yOff = yOff - 22
    AddStat("Open Water:", "openWater", 1)
    AddStat("Favorites Saved:", "favCount", 2)
    yOff = yOff - 22

    RefreshOverviewTab()
end

function RefreshOverviewTab()
    if not db or not overviewTexts.totalCaught then return end

    overviewTexts.totalCaught:SetText(tostring(db.totalCaught))
    overviewTexts.totalCasts:SetText(tostring(db.totalCasts))

    local rate = db.totalCasts > 0 and math_floor(db.totalCaught / db.totalCasts * 100) or 0
    overviewTexts.catchRate:SetText(rate .. "%")
    overviewTexts.totalTime:SetText(FormatTime(db.totalFishingTime))

    local hours = db.totalFishingTime / 3600
    local fph = hours > 0 and math_floor(db.totalCaught / hours) or 0
    overviewTexts.fishPerHour:SetText(tostring(fph))

    local unique = 0
    local mostName, mostCount = "None", 0
    local rarestName, rarestQ, rarestCount = "None", -1, math.huge
    for _, entry in pairs(db.fishLog) do
        unique = unique + 1
        if entry.count > mostCount then
            mostCount = entry.count
            mostName = entry.name or "?"
        end
        local q = entry.quality or 1
        if q > rarestQ or (q == rarestQ and (entry.count or 0) < rarestCount) then
            rarestQ = q
            rarestCount = entry.count or 0
            rarestName = entry.name or "?"
        end
    end
    overviewTexts.uniqueSpecies:SetText(tostring(unique))
    overviewTexts.mostCaught:SetText(format("%s (x%d)", mostName, mostCount))

    local rr, rg, rb = GetQualityColor(rarestQ)
    overviewTexts.rarestCatch:SetText(format("|cff%02x%02x%02x%s|r", rr * 255, rg * 255, rb * 255, rarestName))

    overviewTexts.longestStreak:SetText(tostring(db.longestStreak))
    overviewTexts.sessionCount:SetText(tostring(db.sessionCount))
    local avgPS = db.sessionCount > 0 and format("%.1f", db.totalCaught / db.sessionCount) or "0"
    overviewTexts.avgPerSession:SetText(avgPS)

    local favZone, favZoneCount = "None", 0
    for zone, zs in pairs(db.zoneStats) do
        if zs.total > favZoneCount then
            favZoneCount = zs.total
            favZone = zone
        end
    end
    overviewTexts.favZone:SetText(favZone)

    overviewTexts.bestSpot:SetText(db.bestSpot or "None")

    local totalPool, totalOpen = 0, 0
    for _, ps in pairs(db.poolStats) do
        totalPool = totalPool + (ps.poolCatches or 0)
        totalOpen = totalOpen + ((ps.totalCatches or 0) - (ps.poolCatches or 0))
    end
    overviewTexts.poolCatches:SetText(tostring(totalPool))
    overviewTexts.openWater:SetText(tostring(totalOpen))

    local favCount = 0
    for _ in pairs(db.favorites) do favCount = favCount + 1 end
    overviewTexts.favCount:SetText(tostring(favCount))
end

-- ============================================================================
-- Collection Tab
-- ============================================================================

local collectionHeader, collectionProgressBar, collectionSortDD
local SORT_OPTIONS = {
    { value = "missing",  label = "Missing First" },
    { value = "name",     label = "Name" },
    { value = "quality",  label = "Quality" },
    { value = "count",    label = "Count" },
    { value = "recent",   label = "Recently Caught" },
}

local MIDNIGHT_CATEGORY_ORDER = { "fish", "recipe", "line", "rod", "treasure" }
local MIDNIGHT_CATEGORY_LABELS = {
    fish     = "Fish",
    recipe   = "Lures & Recipes",
    line     = "Fishing Line",
    rod      = "Rods",
    treasure = "Treasures & Special",
}

local function SortCollectionItems(items, sortMode)
    local mode = sortMode or "missing"
    table.sort(items, function(a, b)
        if mode == "missing" then
            if a.caught ~= b.caught then return not a.caught end
            if a.caught then return (a.count or 0) > (b.count or 0) end
            return (a.name or "") < (b.name or "")
        elseif mode == "name" then
            return (a.name or "") < (b.name or "")
        elseif mode == "quality" then
            if (a.quality or 0) ~= (b.quality or 0) then return (a.quality or 0) > (b.quality or 0) end
            return (a.name or "") < (b.name or "")
        elseif mode == "count" then
            if (a.count or 0) ~= (b.count or 0) then return (a.count or 0) > (b.count or 0) end
            return (a.name or "") < (b.name or "")
        elseif mode == "recent" then
            local aTime = a.lastCaught or 0
            local bTime = b.lastCaught or 0
            if aTime ~= bTime then return aTime > bTime end
            return (a.name or "") < (b.name or "")
        end
        return (a.name or "") < (b.name or "")
    end)
end

local function ShowCollectionTooltip(row, item)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local gfd = ns.GoneFishinData

    local r, g, b = GetQualityColor(item.quality or 1)
    GameTooltip:AddLine(item.name or "?", r, g, b)

    local staticInfo = gfd and gfd.midnightItems and gfd.midnightItems[item.itemID]

    if staticInfo then
        local cat = staticInfo.category
        if cat == "fish" then
            if staticInfo.rarity then
                GameTooltip:AddLine(format("Rarity: %s", staticInfo.rarity:sub(1,1):upper() .. staticInfo.rarity:sub(2)), 0.7, 0.7, 0.7)
            end
            if staticInfo.openWaterZones and #staticInfo.openWaterZones > 0 then
                GameTooltip:AddLine("Open water: " .. table.concat(staticInfo.openWaterZones, ", "), 0.6, 0.8, 1.0)
            end
            if staticInfo.pools and #staticInfo.pools > 0 then
                GameTooltip:AddLine("Pools: " .. table.concat(staticInfo.pools, ", "), 0.6, 0.8, 1.0)
            end
            local lureLookup = gfd.lureLookup
            if lureLookup and lureLookup[staticInfo.name] then
                local lureInfo = lureLookup[staticInfo.name]
                GameTooltip:AddLine("Lure: " .. (lureInfo.lureName or "?"), 0.4, 1.0, 0.4)
            end
            if staticInfo.notes and staticInfo.notes ~= "" then
                GameTooltip:AddLine(staticInfo.notes, 1, 0.82, 0, true)
            end
            if gfd.zones then
                for _, zoneName in ipairs(staticInfo.openWaterZones or {}) do
                    local zoneInfo = gfd.zones[zoneName]
                    if zoneInfo then
                        GameTooltip:AddLine(format("  %s: Skill %d (%s)", zoneName, zoneInfo.skill, zoneInfo.range or "?"), 0.5, 0.5, 0.5)
                    end
                end
            end

        elseif cat == "recipe" then
            if staticInfo.craftedName then
                GameTooltip:AddLine("Crafts: " .. staticInfo.craftedName, 0.6, 0.8, 1.0)
            end
            if staticInfo.targetFishName then
                GameTooltip:AddLine("Increases chance for: " .. staticInfo.targetFishName, 0.4, 1.0, 0.4)
            end
            if staticInfo.reagents then
                for _, reagent in ipairs(staticInfo.reagents) do
                    local reagentInfo = CacheItemInfo(reagent[1])
                    local rName = reagentInfo and reagentInfo.name or tostring(reagent[1])
                    GameTooltip:AddLine(format("  %dx %s", reagent[2], rName), 0.7, 0.7, 0.7)
                end
            end
            if staticInfo.source and staticInfo.source ~= "" then
                GameTooltip:AddLine("Drops from: " .. staticInfo.source, 0.6, 0.6, 0.6)
            end

        elseif cat == "line" then
            if staticInfo.chain and staticInfo.tier then
                local chainLabel = staticInfo.chain == "bloom" and "Bloomline" or
                                   staticInfo.chain == "glimmer" and "Glimmerline" or "Grand Line"
                GameTooltip:AddLine(format("Chain: %s (Tier %d)", chainLabel, staticInfo.tier), 0.6, 0.8, 1.0)
            end

        elseif cat == "rod" then
            -- nothing beyond notes

        elseif cat == "treasure" then
            if staticInfo.source and staticInfo.source ~= "" then
                GameTooltip:AddLine("Source: " .. staticInfo.source, 0.6, 0.8, 1.0)
            end
        end

        if staticInfo.notes and staticInfo.notes ~= "" and cat ~= "fish" then
            GameTooltip:AddLine(staticInfo.notes, 1, 0.82, 0, true)
        end
    end

    -- Dynamic discovery data
    if db and item.itemID then
        local discZones = db.discoveredZones[item.itemID]
        if discZones then
            local parts = {}
            for zName, cnt in pairs(discZones) do
                parts[#parts + 1] = format("%s (x%d)", zName, cnt)
            end
            if #parts > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Discovered in: " .. table.concat(parts, ", "), 0.5, 1.0, 0.5, true)
            end
        end
        local discPools = db.discoveredPools[item.itemID]
        if discPools then
            local parts = {}
            for pName, cnt in pairs(discPools) do
                parts[#parts + 1] = format("%s (x%d)", pName, cnt)
            end
            if #parts > 0 then
                GameTooltip:AddLine("Pools discovered: " .. table.concat(parts, ", "), 0.5, 1.0, 0.5, true)
            end
        end
    end

    -- Catch stats
    if item.caught and db then
        GameTooltip:AddLine(" ")
        local logEntry = db.fishLog[item.itemID]
        if logEntry then
            GameTooltip:AddLine(format("Total caught: x%d", logEntry.count or 0), 1, 1, 1)
            if logEntry.firstCaught then
                GameTooltip:AddLine("First caught: " .. date("%b %d, %Y", logEntry.firstCaught), 0.7, 0.7, 0.7)
            end
        end
    end

    GameTooltip:Show()
end

function BuildCollectionTab(parent)
    collectionHeader = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    collectionHeader:SetPoint("TOPLEFT", 8, -8)

    collectionProgressBar = CreateFrame("StatusBar", nil, parent)
    collectionProgressBar:SetSize(200, 12)
    collectionProgressBar:SetPoint("LEFT", collectionHeader, "RIGHT", 12, 0)
    collectionProgressBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    collectionProgressBar:SetStatusBarColor(0.9, 0.7, 0.15, 0.8)
    collectionProgressBar:SetMinMaxValues(0, 1)
    local bg = collectionProgressBar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.15, 0.15, 0.15, 0.8)

    collectionSortDD = MedaUI:CreateDropdown(parent, 140, SORT_OPTIONS)
    collectionSortDD:SetPoint("TOPRIGHT", -8, -4)
    collectionSortDD:SetSelected(db and db.collectionSort or "missing")
    collectionSortDD.OnValueChanged = function(_, v)
        if db then db.collectionSort = v end
        RefreshCollectionTab()
    end

    collectionSearchBox = MedaUI:CreateSearchBox(parent, 200)
    collectionSearchBox:SetPoint("TOPLEFT", 8, -32)
    collectionSearchBox:SetPlaceholder("Search items...")

    local listHeight = parent:GetHeight() and parent:GetHeight() - 70 or 380
    collectionList = MedaUI:CreateScrollList(parent, parent:GetWidth() or 490, listHeight, {
        rowHeight = 32,
        renderRow = function(row, item, index)
            if not row.icon then
                row.icon = row:CreateTexture(nil, "ARTWORK")
                row.icon:SetSize(24, 24)
                row.icon:SetPoint("LEFT", 6, 0)
                row.icon:SetTexCoord(unpack(ICON_TEXCOORD))
            end
            if not row.nameText then
                row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
                row.nameText:SetJustifyH("LEFT")
                row.nameText:SetWidth(260)
                row.nameText:SetWordWrap(false)
            end
            if not row.countText then
                row.countText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                row.countText:SetPoint("RIGHT", -8, 0)
                row.countText:SetJustifyH("RIGHT")
            end
            if not row.zoneText then
                row.zoneText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                row.zoneText:SetPoint("RIGHT", row.countText, "LEFT", -8, 0)
                row.zoneText:SetJustifyH("RIGHT")
                row.zoneText:SetWidth(120)
                row.zoneText:SetWordWrap(false)
            end
            if not row.progressBar then
                row.progressBar = CreateFrame("StatusBar", nil, row)
                row.progressBar:SetSize(row:GetWidth() - 16, 4)
                row.progressBar:SetPoint("BOTTOMLEFT", 8, 2)
                row.progressBar:SetPoint("BOTTOMRIGHT", -8, 2)
                row.progressBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
                row.progressBar:SetMinMaxValues(0, 1)
                local pbg = row.progressBar:CreateTexture(nil, "BACKGROUND")
                pbg:SetAllPoints()
                pbg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
                row.progressBarText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                row.progressBarText:SetPoint("RIGHT", row.progressBar, "RIGHT", 0, 9)
            end

            -- Hover tooltip
            row:EnableMouse(true)
            row:SetScript("OnEnter", function(self)
                if item.isHeader then return end
                ShowCollectionTooltip(self, item)
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)

            if item.isHeader then
                row.icon:Hide()
                row.zoneText:SetText("")
                row.nameText:SetPoint("LEFT", 6, 4)
                row.nameText:SetWidth(300)
                local Theme = MedaUI.Theme
                local gold = Theme and Theme.gold or FALLBACK_GOLD

                if item.isSectionHeader then
                    row.nameText:SetText(format("|cff%02x%02x%02x=== %s ===|r", gold[1]*255, gold[2]*255, gold[3]*255, item.label or ""))
                    row.countText:SetText("")
                    row.progressBar:Hide()
                    row.progressBarText:SetText("")
                else
                    row.nameText:SetText(format("|cff%02x%02x%02x%s|r", gold[1]*255, gold[2]*255, gold[3]*255, item.label or ""))
                    if item.total and item.total > 0 then
                        row.countText:SetText(format("|cffffffff%d/%d|r", item.caught or 0, item.total))
                        row.progressBar:Show()
                        row.progressBar:SetValue((item.total > 0) and ((item.caught or 0) / item.total) or 0)
                        row.progressBar:SetStatusBarColor(gold[1], gold[2], gold[3], 0.7)
                        row.progressBarText:SetText("")
                    else
                        row.countText:SetText(format("|cffffffff%d found|r", item.caught or 0))
                        row.progressBar:Hide()
                        row.progressBarText:SetText("")
                    end
                end
                return
            end

            row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
            row.progressBar:Hide()
            row.progressBarText:SetText("")

            local iconPath = item.icon
            if type(iconPath) == "string" and iconPath ~= "" and not iconPath:find("\\") then
                iconPath = "Interface\\Icons\\" .. iconPath
            end
            if not iconPath or iconPath == "" then
                iconPath = "Interface\\Icons\\INV_Misc_QuestionMark"
            end

            row.icon:Show()
            row.icon:SetTexture(iconPath)

            local zoneHint = ""
            local gfd = ns.GoneFishinData
            local staticInfo = gfd and gfd.midnightItems and gfd.midnightItems[item.itemID]
            if staticInfo and staticInfo.openWaterZones and #staticInfo.openWaterZones > 0 then
                zoneHint = table.concat(staticInfo.openWaterZones, ", ")
            end

            if item.caught then
                row.icon:SetDesaturated(false)
                local r, g, b = GetQualityColor(item.quality or 1)
                row.nameText:SetText(format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, item.name or "?"))
                row.countText:SetText(format("x%d", item.count or 0))
                row.countText:SetTextColor(1, 1, 1)
                row.zoneText:SetText(zoneHint)
                row.zoneText:SetTextColor(0.5, 0.5, 0.5)
            else
                row.icon:SetDesaturated(true)
                row.nameText:SetText(format("|cff666666%s|r", item.name or "?"))
                row.countText:SetText("|cff555555---|r")
                row.zoneText:SetText("|cff555555" .. zoneHint .. "|r")
            end
        end,
    })
    collectionList:SetPoint("TOPLEFT", 0, -58)

    collectionSearchBox.OnSearch = function(_, text)
        if not text or text == "" then
            collectionList:ClearFilter()
        else
            local lower = text:lower()
            collectionList:SetFilter(function(item)
                if item.isHeader then return true end
                return item.name and item.name:lower():find(lower, 1, true)
            end)
        end
    end

    RefreshCollectionTab()
end

function RefreshCollectionTab()
    if not collectionList or not db then return end

    local gfd = ns.GoneFishinData
    local midnightItems = gfd and gfd.midnightItems or {}
    local sortMode = db.collectionSort or "missing"

    local data = {}
    local totalCaught, totalCount = 0, 0

    -- Build Midnight categories
    local categoryItems = {}
    for _, cat in ipairs(MIDNIGHT_CATEGORY_ORDER) do
        categoryItems[cat] = {}
    end

    for itemID, itemInfo in pairs(midnightItems) do
        local cat = itemInfo.category or "other"
        if not categoryItems[cat] then
            categoryItems[cat] = {}
        end
        totalCount = totalCount + 1
        local logEntry = db.fishLog[itemID]
        local isCaught = logEntry and logEntry.count and logEntry.count > 0
        if isCaught then totalCaught = totalCaught + 1 end

        categoryItems[cat][#categoryItems[cat] + 1] = {
            itemID = itemID,
            name = itemInfo.name,
            icon = itemInfo.icon or "",
            quality = itemInfo.quality or 1,
            count = isCaught and logEntry.count or 0,
            caught = isCaught or false,
            lastCaught = logEntry and logEntry.lastCaught or 0,
        }
    end

    -- MIDNIGHT section header
    data[#data + 1] = { isHeader = true, isSectionHeader = true, label = "MIDNIGHT" }

    for _, cat in ipairs(MIDNIGHT_CATEGORY_ORDER) do
        local items = categoryItems[cat]
        if items and #items > 0 then
            SortCollectionItems(items, sortMode)
            local catCaught = 0
            for _, item in ipairs(items) do
                if item.caught then catCaught = catCaught + 1 end
            end
            data[#data + 1] = {
                isHeader = true, isSectionHeader = false,
                label = MIDNIGHT_CATEGORY_LABELS[cat] or cat,
                caught = catCaught, total = #items,
            }
            for _, item in ipairs(items) do
                data[#data + 1] = item
            end
        end
    end

    -- OTHER CATCHES section: items in fishLog not in midnightItems
    local otherCategories = {}
    for itemID, logEntry in pairs(db.fishLog) do
        if not midnightItems[itemID] then
            local cat = logEntry.category or ClassifyItem(itemID) or "other"
            if not otherCategories[cat] then
                otherCategories[cat] = {}
            end
            otherCategories[cat][#otherCategories[cat] + 1] = {
                itemID = itemID,
                name = logEntry.name or "Unknown",
                icon = logEntry.icon or "",
                quality = logEntry.quality or 0,
                count = logEntry.count or 0,
                caught = true,
                lastCaught = logEntry.lastCaught or 0,
            }
        end
    end

    local hasOther = false
    for _ in pairs(otherCategories) do hasOther = true; break end

    if hasOther then
        data[#data + 1] = { isHeader = true, isSectionHeader = true, label = "OTHER CATCHES" }

        local otherCatOrder = { "fish", "junk", "reagent", "gear", "recipe", "consumable", "pet", "mount", "toy", "quest", "other" }
        local otherCatLabels = {
            fish = "Fish", junk = "Junk", reagent = "Reagents", gear = "Gear",
            recipe = "Recipes", consumable = "Consumables", pet = "Pets",
            mount = "Mounts", toy = "Toys", quest = "Quest Items", other = "Other",
        }

        for _, cat in ipairs(otherCatOrder) do
            local items = otherCategories[cat]
            if items and #items > 0 then
                SortCollectionItems(items, sortMode)
                data[#data + 1] = {
                    isHeader = true, isSectionHeader = false,
                    label = otherCatLabels[cat] or cat,
                    caught = #items, total = 0,
                }
                for _, item in ipairs(items) do
                    data[#data + 1] = item
                end
            end
        end
    end

    collectionList:SetData(data)

    if collectionHeader then
        local Theme = MedaUI.Theme
        local gold = Theme and Theme.gold or FALLBACK_GOLD
        collectionHeader:SetText(format("Midnight Pokedex: %d / %d", totalCaught, totalCount))
        collectionHeader:SetTextColor(gold[1], gold[2], gold[3])
    end
    if collectionProgressBar then
        collectionProgressBar:SetValue(totalCount > 0 and totalCaught / totalCount or 0)
    end
end

-- ============================================================================
-- Zones Tab
-- ============================================================================

function BuildZonesTab(parent)
    zonesList = MedaUI:CreateScrollList(parent, parent:GetWidth() or 490, parent:GetHeight() or 420, {
        rowHeight = 28,
        renderRow = function(row, item, index)
            if not row.nameText then
                row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                row.nameText:SetPoint("LEFT", 8, 0)
                row.nameText:SetJustifyH("LEFT")
                row.nameText:SetWidth(280)
                row.nameText:SetWordWrap(false)
            end
            if not row.countText then
                row.countText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                row.countText:SetPoint("RIGHT", -8, 0)
                row.countText:SetJustifyH("RIGHT")
            end
            if not row.starBtn then
                row.starBtn = CreateFrame("Button", nil, row)
                row.starBtn:SetSize(16, 16)
                row.starBtn:SetPoint("RIGHT", row.countText, "LEFT", -8, 0)
                row.starBtn.tex = row.starBtn:CreateTexture(nil, "ARTWORK")
                row.starBtn.tex:SetAllPoints()
            end

            if item.isZone then
                local Theme = MedaUI.Theme
                local gold = Theme and Theme.gold or FALLBACK_GOLD
                row.nameText:SetText(item.name)
                row.nameText:SetTextColor(gold[1], gold[2], gold[3])
                row.countText:SetText(format("%d fish", item.total or 0))
                row.countText:SetTextColor(1, 1, 1)
                row.starBtn:Hide()
            else
                row.nameText:SetText("    " .. (item.name or ""))
                row.nameText:SetTextColor(0.8, 0.8, 0.8)
                local poolCount = item.poolCatches or 0
                row.countText:SetText(format("%d caught (%d pool)", item.total or 0, poolCount))
                row.countText:SetTextColor(0.6, 0.6, 0.6)

                row.starBtn:Show()
                if item.isFaved then
                    row.starBtn.tex:SetAtlas("Waypoint-MapPin-Tracked")
                    row.starBtn.tex:SetDesaturated(false)
                else
                    row.starBtn.tex:SetAtlas("Waypoint-MapPin-Untracked")
                    row.starBtn.tex:SetDesaturated(true)
                end
                row.starBtn:SetScript("OnClick", function()
                    if item.favId and db.favorites[item.favId] then
                        RemoveFavorite(item.favId)
                    else
                        local mapID = C_Map.GetBestMapForUnit("player")
                        if mapID and item.name then
                            local favId = mapID .. ":" .. item.name
                            db.favorites[favId] = {
                                label = item.name,
                                zone = item.zoneName or "",
                                subzone = item.name,
                                mapID = mapID,
                                x = 0.5, y = 0.5,
                                notes = "",
                                poolCatches = item.poolCatches or 0,
                            }
                            local MapPins = ns.Services.MapPinProvider
                            if MapPins then
                                MapPins:SetPin("GoneFishin_Favorites", favId, db.favorites[favId])
                            end
                        end
                    end
                    RefreshZonesTab()
                end)
            end
        end,
    })
    zonesList:SetPoint("TOPLEFT", 0, -4)

    RefreshZonesTab()
end

function RefreshZonesTab()
    if not zonesList or not db then return end

    local data = {}

    local sortedZones = {}
    for zone, zs in pairs(db.zoneStats) do
        sortedZones[#sortedZones + 1] = { name = zone, total = zs.total, subZones = zs.subZones }
    end
    table.sort(sortedZones, function(a, b) return (a.total or 0) > (b.total or 0) end)

    for _, zone in ipairs(sortedZones) do
        data[#data + 1] = { isZone = true, name = zone.name, total = zone.total }

        if zone.subZones then
            local sortedSubs = {}
            for sub, ss in pairs(zone.subZones) do
                sortedSubs[#sortedSubs + 1] = { name = sub, total = ss.total }
            end
            table.sort(sortedSubs, function(a, b) return (a.total or 0) > (b.total or 0) end)

            for _, sub in ipairs(sortedSubs) do
                local ps = db.poolStats[sub.name]
                local poolCatches = ps and ps.poolCatches or 0
                local mapID = C_Map.GetBestMapForUnit("player")
                local favId = mapID and (mapID .. ":" .. sub.name) or nil
                data[#data + 1] = {
                    isZone = false,
                    name = sub.name,
                    total = sub.total,
                    poolCatches = poolCatches,
                    zoneName = zone.name,
                    favId = favId,
                    isFaved = favId and db.favorites[favId] ~= nil,
                }
            end
        end
    end

    zonesList:SetData(data)
end

-- ============================================================================
-- Minimap Button
-- ============================================================================

local function CreateMinimapBtn()
    if minimapButton then return end
    minimapButton = MedaUI:CreateMinimapButton(
        "MedaAurasGoneFishin",
        "Interface\\Icons\\Trade_Fishing",
        function()
            if statsPanel then
                if statsPanel:IsShown() then
                    statsPanel:Hide()
                else
                    CreateStatsPanel()
                    statsPanel:Show()
                    tabBar:SetActiveTab("overview")
                end
            else
                CreateStatsPanel()
                statsPanel:Show()
                tabBar:SetActiveTab("overview")
            end
        end,
        function()
            if MedaAuras.ToggleSettings then
                MedaAuras:ToggleSettings()
            end
        end
    )

    if minimapButton and db.showMinimapButton == false then
        minimapButton.HideButton()
    end
end

-- ============================================================================
-- Event Handling
-- ============================================================================

local function OnEvent(self, event, ...)
    if not isEnabled then return end

    if event == "UNIT_SPELLCAST_CHANNEL_START" then
        local unit, _, spellID = ...
        if unit ~= "player" then return end
        local spellName = C_Spell.GetSpellName(spellID)
        if FISHING_SPELL_NAMES[spellName] then
            CancelSessionTimeout()
            if not sessionActive then
                db.sessionCount = db.sessionCount + 1
                sessionStartTime = GetTime()
                sessionCaught = 0
                sessionCasts = 0
                sessionJunk = 0
                currentStreak = 0
                sessionActive = true
            end
            isFishing = true
            fishingStartTime = GetTime()
            db.totalCasts = db.totalCasts + 1
            sessionCasts = sessionCasts + 1
            ShowHUD()
            arcDirty = true
        end

    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        local unit = ...
        if unit ~= "player" then return end
        if isFishing then
            if fishingStartTime > 0 then
                db.totalFishingTime = db.totalFishingTime + (GetTime() - fishingStartTime)
            end
            isFishing = false
            fishingStartTime = 0
            HideHUD()
            StartSessionTimeout()
        end

    elseif event == "LOOT_OPENED" then
        if not sessionActive then return end
        for i = 1, GetNumLootItems() do
            local lootIcon, lootName, lootQuantity, currencyID, lootQuality = GetLootSlotInfo(i)
            local link = GetLootSlotLink(i)
            if link then
                local itemID = tonumber(link:match("item:(%d+)"))
                if itemID then
                    RecordCatch(itemID, lootName, lootIcon, lootQuality)
                end
            end
        end
        arcDirty = true

        if statsPanel and statsPanel:IsShown() then
            local activeTab = tabBar and tabBar:GetActiveTab()
            if activeTab == "overview" then RefreshOverviewTab() end
            if activeTab == "collection" then RefreshCollectionTab() end
            if activeTab == "zones" then RefreshZonesTab() end
        end

    elseif event == "LOOT_CLOSED" then
        if sessionActive and fishingStartTime > 0 then
            db.totalFishingTime = db.totalFishingTime + (GetTime() - fishingStartTime)
            fishingStartTime = GetTime()
        end

    elseif event == "PLAYER_STARTED_MOVING" then
        if isFishing then
            if fishingStartTime > 0 then
                db.totalFishingTime = db.totalFishingTime + (GetTime() - fishingStartTime)
            end
            isFishing = false
            fishingStartTime = 0
            HideHUD()
            StartSessionTimeout()
        end

    elseif event == "PLAYER_LOGOUT" then
        CancelSessionTimeout()
        if isFishing and fishingStartTime > 0 then
            db.totalFishingTime = db.totalFishingTime + (GetTime() - fishingStartTime)
            fishingStartTime = 0
            isFishing = false
        end
        SaveSessionState()

    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" then
        if hudVisible then
            arcDirty = true
        end
    end
end

local function RegisterEvents()
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", OnEvent)
    end
    eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
    eventFrame:RegisterEvent("LOOT_OPENED")
    eventFrame:RegisterEvent("LOOT_CLOSED")
    eventFrame:RegisterEvent("PLAYER_STARTED_MOVING")
    eventFrame:RegisterEvent("PLAYER_LOGOUT")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("ZONE_CHANGED")
    eventFrame:RegisterEvent("ZONE_CHANGED_INDOORS")
end

local function UnregisterEvents()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
        eventFrame:SetScript("OnEvent", nil)
    end
end

-- ============================================================================
-- Settings Panel (BuildConfig)
-- ============================================================================

local function BuildConfig(parent, moduleDB)
    local LEFT_X, RIGHT_X = 0, 238
    db = moduleDB

    local UpdatePreview

    local function MarkDirty()
        arcDirty = true
        wipe(fontCache)
        if hudFrame and hudVisible then
            RecalcPositions()
            UpdateHUDContent()
        end
        if UpdatePreview then UpdatePreview() end
    end

    local tabBar, tabs = MedaAuras:CreateConfigTabs(parent, {
        { id = "hud",  label = "HUD" },
        { id = "map",  label = "Map" },
        { id = "data", label = "Data" },
    })

    -- ===== HUD Tab =====
    do
        local p = tabs["hud"]
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
        yOff = yOff - 40

        local hdr2 = MedaUI:CreateSectionHeader(p, "Fishing Aura HUD")
        hdr2:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local auraCB = MedaUI:CreateCheckbox(p, "Enable Aura HUD")
        auraCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        auraCB:SetChecked(moduleDB.auraEnabled ~= false)
        auraCB.OnValueChanged = function(_, checked)
            moduleDB.auraEnabled = checked
            if not checked and hudVisible then
                DisableHUDUpdates()
                if hudFrame then hudFrame:Hide() end
                hudVisible = false
            end
        end
        local lockCB = MedaUI:CreateCheckbox(p, "Lock HUD Panels")
        lockCB:SetPoint("TOPLEFT", RIGHT_X, yOff)
        lockCB:SetChecked(moduleDB.auraLockPanels ~= false)
        lockCB.OnValueChanged = function(_, checked)
            moduleDB.auraLockPanels = checked
            SetPanelsLocked(checked)
        end
        yOff = yOff - 30

        local checklistCB = MedaUI:CreateCheckbox(p, "Show Zone Checklist")
        checklistCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        checklistCB:SetChecked(moduleDB.auraShowChecklist ~= false)
        checklistCB.OnValueChanged = function(_, checked) moduleDB.auraShowChecklist = checked; MarkDirty() end
        local faveCB = MedaUI:CreateCheckbox(p, "Show Favorite Spot")
        faveCB:SetPoint("TOPLEFT", RIGHT_X, yOff)
        faveCB:SetChecked(moduleDB.auraShowFaves ~= false)
        faveCB.OnValueChanged = function(_, checked) moduleDB.auraShowFaves = checked; MarkDirty() end
        yOff = yOff - 30

        local bestCB = MedaUI:CreateCheckbox(p, "Show Best Spot")
        bestCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        bestCB:SetChecked(moduleDB.auraShowBestSpot ~= false)
        bestCB.OnValueChanged = function(_, checked) moduleDB.auraShowBestSpot = checked; MarkDirty() end
        local tipsCB = MedaUI:CreateCheckbox(p, "Show Lure Tips")
        tipsCB:SetPoint("TOPLEFT", RIGHT_X, yOff)
        tipsCB:SetChecked(moduleDB.auraShowTips ~= false)
        tipsCB.OnValueChanged = function(_, checked) moduleDB.auraShowTips = checked; MarkDirty() end
        yOff = yOff - 30

        local junkCB = MedaUI:CreateCheckbox(p, "Show Session Junk")
        junkCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        junkCB:SetChecked(moduleDB.auraShowSessionJunk ~= false)
        junkCB.OnValueChanged = function(_, checked) moduleDB.auraShowSessionJunk = checked; MarkDirty() end
        yOff = yOff - 40

        local scaleSlider = MedaUI:CreateLabeledSlider(p, "Scale (%)", 200, 50, 200, 5)
        scaleSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
        scaleSlider:SetValue((moduleDB.auraScale or 1) * 100)
        scaleSlider.OnValueChanged = function(_, v) moduleDB.auraScale = v / 100; MarkDirty() end
        local textSzSlider = MedaUI:CreateLabeledSlider(p, "Text Size", 200, 8, 24, 1)
        textSzSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
        textSzSlider:SetValue(moduleDB.auraTextSize or 13)
        textSzSlider.OnValueChanged = function(_, v) moduleDB.auraTextSize = v; MarkDirty() end
        yOff = yOff - 55

        local iconSzSlider = MedaUI:CreateLabeledSlider(p, "Icon Size", 200, 12, 32, 1)
        iconSzSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
        iconSzSlider:SetValue(moduleDB.auraIconSize or 20)
        iconSzSlider.OnValueChanged = function(_, v) moduleDB.auraIconSize = v; MarkDirty() end
        local opacitySlider = MedaUI:CreateLabeledSlider(p, "Opacity (%)", 200, 0, 100, 5)
        opacitySlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
        opacitySlider:SetValue((moduleDB.auraOpacity or 0.92) * 100)
        opacitySlider.OnValueChanged = function(_, v) moduleDB.auraOpacity = v / 100; MarkDirty() end
        yOff = yOff - 55

        local fontDD = MedaUI:CreateLabeledDropdown(p, "Font", 200, MedaUI:GetFontList(), "font")
        fontDD:SetPoint("TOPLEFT", LEFT_X, yOff)
        fontDD:SetSelected(moduleDB.auraFont or "default")
        fontDD.OnValueChanged = function(_, v) moduleDB.auraFont = v; MarkDirty() end
        local outlineDD = MedaUI:CreateLabeledDropdown(p, "Text Outline", 200, {
            { value = "none", label = "None" },
            { value = "outline", label = "Outline" },
            { value = "thick", label = "Thick Outline" },
        })
        outlineDD:SetPoint("TOPLEFT", RIGHT_X, yOff)
        outlineDD:SetSelected(moduleDB.auraTextOutline or "outline")
        outlineDD.OnValueChanged = function(_, v) moduleDB.auraTextOutline = v; MarkDirty() end
        yOff = yOff - 55

        local fadeInSlider = MedaUI:CreateLabeledSlider(p, "Fade In (sec)", 200, 0, 2, 0.1)
        fadeInSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
        fadeInSlider:SetValue(moduleDB.auraFadeIn or 0.4)
        fadeInSlider.OnValueChanged = function(_, v)
            moduleDB.auraFadeIn = v
            if hudFadeCtrl then hudFadeCtrl:SetDurations(v, moduleDB.auraFadeOut or 0.6) end
        end
        local fadeOutSlider = MedaUI:CreateLabeledSlider(p, "Fade Out (sec)", 200, 0, 2, 0.1)
        fadeOutSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
        fadeOutSlider:SetValue(moduleDB.auraFadeOut or 0.6)
        fadeOutSlider.OnValueChanged = function(_, v)
            moduleDB.auraFadeOut = v
            if hudFadeCtrl then hudFadeCtrl:SetDurations(moduleDB.auraFadeIn or 0.4, v) end
        end
        yOff = yOff - 55

        local delaySlider = MedaUI:CreateLabeledSlider(p, "Hide Delay (sec)", 200, 1, 30, 1)
        delaySlider:SetPoint("TOPLEFT", LEFT_X, yOff)
        delaySlider:SetValue(moduleDB.auraHideDelay or 8)
        delaySlider.OnValueChanged = function(_, v) moduleDB.auraHideDelay = v end
        local resetPosBtn = MedaUI:CreateButton(p, "Reset Panel Positions")
        resetPosBtn:SetPoint("TOPLEFT", RIGHT_X, yOff)
        resetPosBtn:SetScript("OnClick", function()
            moduleDB.leftPanelPos = nil
            moduleDB.rightPanelPos = nil
            moduleDB.bottomPanelPos = nil
            MarkDirty()
        end)
    end

    -- ===== Map Tab =====
    do
        local p = tabs["map"]
        local yOff = 0

        local hdr = MedaUI:CreateSectionHeader(p, "Map & Favorites")
        hdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local mapPinCB = MedaUI:CreateCheckbox(p, "Show Map Pins")
        mapPinCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        mapPinCB:SetChecked(moduleDB.showMapPins ~= false)
        mapPinCB.OnValueChanged = function(_, checked)
            moduleDB.showMapPins = checked
            local MapPins = ns.Services.MapPinProvider
            if MapPins then MapPins:SetGroupVisible("GoneFishin_Favorites", checked) end
        end
        local mmCB = MedaUI:CreateCheckbox(p, "Show Minimap Button")
        mmCB:SetPoint("TOPLEFT", RIGHT_X, yOff)
        mmCB:SetChecked(moduleDB.showMinimapButton ~= false)
        mmCB.OnValueChanged = function(_, checked)
            moduleDB.showMinimapButton = checked
            if minimapButton then
                if checked then minimapButton.ShowButton() else minimapButton.HideButton() end
            end
        end
        yOff = yOff - 40

        local clearFavBtn = MedaUI:CreateButton(p, "Clear All Favorites")
        clearFavBtn:SetPoint("TOPLEFT", LEFT_X, yOff)
        clearFavBtn:SetScript("OnClick", function()
            StaticPopup_Show("GONEFISHIN_CLEAR_FAVORITES")
        end)
        local resetStatsBtn = MedaUI:CreateButton(p, "Reset Stats Position")
        resetStatsBtn:SetPoint("TOPLEFT", RIGHT_X, yOff)
        resetStatsBtn:SetScript("OnClick", function()
            moduleDB.statsPosition = nil
            if statsPanel then
                statsPanel:ClearAllPoints()
                statsPanel:SetPoint("CENTER")
            end
        end)
    end

    -- ===== Data Tab =====
    do
        local p = tabs["data"]
        local yOff = 0
        local Theme = MedaUI.Theme
        local dim = Theme and Theme.textDim or FALLBACK_DIM
        local bright = Theme and Theme.text or FALLBACK_BRIGHT

        local function DataLabel(label, x, y)
            local lbl = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            lbl:SetPoint("TOPLEFT", x, y)
            lbl:SetTextColor(dim[1], dim[2], dim[3])
            lbl:SetText(label)
            return lbl
        end

        local function DataValue(anchor, text)
            local val = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            val:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
            val:SetTextColor(bright[1], bright[2], bright[3])
            val:SetText(text)
            return val
        end

        local hdrSummary = MedaUI:CreateSectionHeader(p, "Data Summary")
        hdrSummary:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 35

        local uniqueItems = 0
        for _ in pairs(db.fishLog or {}) do uniqueItems = uniqueItems + 1 end
        local zoneCount = 0
        for _ in pairs(db.zoneStats or {}) do zoneCount = zoneCount + 1 end
        local poolNames = {}
        for _, ps in pairs(db.poolStats or {}) do
            if ps.pools then
                for name in pairs(ps.pools) do poolNames[name] = true end
            end
        end
        local poolCount = 0
        for _ in pairs(poolNames) do poolCount = poolCount + 1 end
        local faveCount = 0
        for _ in pairs(db.favorites or {}) do faveCount = faveCount + 1 end
        local rate = db.totalCasts > 0 and math_floor(db.totalCaught / db.totalCasts * 100) or 0

        DataValue(DataLabel("Total Caught:", 8, yOff), tostring(db.totalCaught))
        DataValue(DataLabel("Total Casts:", RIGHT_X, yOff), tostring(db.totalCasts))
        yOff = yOff - 20
        DataValue(DataLabel("Catch Rate:", 8, yOff), rate .. "%")
        DataValue(DataLabel("Time Fishing:", RIGHT_X, yOff), FormatTime(db.totalFishingTime))
        yOff = yOff - 20
        DataValue(DataLabel("Sessions:", 8, yOff), tostring(db.sessionCount))
        DataValue(DataLabel("Longest Streak:", RIGHT_X, yOff), tostring(db.longestStreak))
        yOff = yOff - 20
        DataValue(DataLabel("Unique Items:", 8, yOff), tostring(uniqueItems))
        DataValue(DataLabel("Zones Fished:", RIGHT_X, yOff), tostring(zoneCount))
        yOff = yOff - 20
        DataValue(DataLabel("Pools Found:", 8, yOff), tostring(poolCount))
        DataValue(DataLabel("Favorite Spots:", RIGHT_X, yOff), tostring(faveCount))
        yOff = yOff - 35

        local hdr = MedaUI:CreateSectionHeader(p, "Data Management")
        hdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 45

        local exportBtn = MedaUI:CreateButton(p, "Export Data")
        exportBtn:SetPoint("TOPLEFT", LEFT_X, yOff)
        exportBtn:SetScript("OnClick", function() ShowExportWindow() end)
        local resetDataBtn = MedaUI:CreateButton(p, "Reset All Fishing Data")
        resetDataBtn:SetPoint("TOPLEFT", RIGHT_X, yOff)
        resetDataBtn:SetScript("OnClick", function()
            StaticPopup_Show("GONEFISHIN_RESET_DATA")
        end)
        yOff = yOff - 35

        local resetStreakBtn = MedaUI:CreateButton(p, "Reset Streak Record")
        resetStreakBtn:SetPoint("TOPLEFT", LEFT_X, yOff)
        resetStreakBtn:SetScript("OnClick", function()
            StaticPopup_Show("GONEFISHIN_RESET_STREAK")
        end)
        local repairPoolBtn = MedaUI:CreateButton(p, "Repair Pool Data")
        repairPoolBtn:SetPoint("TOPLEFT", RIGHT_X, yOff)
        repairPoolBtn:SetScript("OnClick", function()
            StaticPopup_Show("GONEFISHIN_REPAIR_POOLS")
        end)
    end

    MedaAuras:SetContentHeight(550)

    -- ================================================================
    -- Floating Side Preview (mock HUD panels)
    -- ================================================================
    do
        local anchor = MedaAurasSettingsPanel or _G["MedaAurasSettingsPanel"]
        if not anchor then return end

        local PV_PAD = 12
        local PV_W = 280
        local LINE_H = 15
        local dim = { 0.55, 0.55, 0.55 }
        local gold = { 1, 0.82, 0 }
        local green = { 0.53, 0.80, 0.53 }
        local blue = { 0.4, 0.78, 1 }

        local pvContainer = CreateFrame("Frame", nil, anchor)
        pvContainer:SetFrameStrata("HIGH")
        pvContainer:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 0)
        MedaAuras:RegisterConfigCleanup(pvContainer)

        local pvHeaders = {}
        local pvBodyLines = {}
        local pvSections = { junk = {}, checklist = {}, fave = {}, best = {}, tips = {} }

        local yOff = -PV_PAD

        local function AddLine(text, color, section)
            local fs = pvContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetPoint("TOPLEFT", PV_PAD, yOff)
            fs:SetPoint("RIGHT", -PV_PAD, 0)
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            fs:SetText(text)
            if color then fs:SetTextColor(color[1], color[2], color[3]) end
            yOff = yOff - LINE_H
            pvBodyLines[#pvBodyLines + 1] = fs
            if section then pvSections[section][#pvSections[section] + 1] = fs end
            return fs
        end

        local function AddHeader(text, color)
            local fs = pvContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fs:SetPoint("TOPLEFT", PV_PAD, yOff)
            fs:SetPoint("RIGHT", -PV_PAD, 0)
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            fs:SetText(text)
            if color then fs:SetTextColor(color[1], color[2], color[3]) end
            yOff = yOff - LINE_H
            pvHeaders[#pvHeaders + 1] = fs
            return fs
        end

        local function AddGap(h) yOff = yOff - (h or 6) end

        -- Left panel mock
        AddHeader("Zone Stats", gold)
        AddGap(2)
        AddLine("Silvermoon Harbor", gold)
        AddLine("The Moonwell", dim)
        AddLine("", dim)
        AddLine("Session: 24 fish | 3 junk", { 1, 1, 1 }, "junk")
        AddLine("Casts: 31 | Rate: 77%", dim)
        AddLine("Time: 12m 34s", dim)
        AddLine("Streak: 8", green)
        AddGap(10)

        -- Right panel mock (checklist)
        local checklistHdr = AddHeader("Zone Fish", gold)
        pvSections.checklist[#pvSections.checklist + 1] = checklistHdr
        AddGap(2)
        local QUALITY_COLORS = {
            [1] = { 0.62, 0.62, 0.62 },
            [2] = { 0.12, 1.00, 0.00 },
            [3] = { 0.00, 0.44, 0.87 },
            [4] = { 0.64, 0.21, 0.93 },
        }
        for _, fish in ipairs({
            { name = "Lunker Salmon",       q = 3, count = 7 },
            { name = "Moonpearl Trout",     q = 2, count = 12 },
            { name = "Midnight Anglerfish", q = 4, count = 2 },
            { name = "Duskwater Eel",       q = 1, count = 5 },
        }) do
            AddLine(format("  %s  x%d", fish.name, fish.count), QUALITY_COLORS[fish.q] or dim, "checklist")
        end
        AddLine("  [+] Junk (3)", dim, "checklist")
        AddLine("  [+] Missing (2)", dim, "checklist")
        AddGap(10)

        -- Bottom panel mock
        AddHeader("Info", gold)
        AddGap(2)
        AddLine("Favorite: The Moonwell", blue, "fave")
        AddLine("Best Spot: Sunsail Anchorage (41)", dim, "best")
        AddLine("Tip: Use Moonpearl Lure for rare fish", dim, "tips")
        AddGap(PV_PAD)

        pvContainer:SetSize(PV_W, math_abs(yOff))
        pvContainer:Show()

        UpdatePreview = function()
            local textFont = GetFontObj(moduleDB.auraFont or "default", moduleDB.auraTextSize or 13, moduleDB.auraTextOutline or "outline")
            local headerFont = GetFontObj(moduleDB.auraFont or "default", (moduleDB.auraTextSize or 13) + 2, "thick")

            for _, fs in ipairs(pvHeaders) do fs:SetFontObject(headerFont) end
            for _, fs in ipairs(pvBodyLines) do fs:SetFontObject(textFont) end

            pvContainer:SetScale(moduleDB.auraScale or 1)
            pvContainer:SetAlpha(moduleDB.auraOpacity or 0.92)

            local showJunk = moduleDB.auraShowSessionJunk ~= false
            local showChecklist = moduleDB.auraShowChecklist ~= false
            local showFave = moduleDB.auraShowFaves ~= false
            local showBest = moduleDB.auraShowBestSpot ~= false
            local showTips = moduleDB.auraShowTips ~= false

            for _, fs in ipairs(pvSections.junk) do
                if showJunk then
                    fs:SetText("Session: 24 fish | 3 junk")
                else
                    fs:SetText("Session: 24 fish")
                end
            end
            for _, fs in ipairs(pvSections.checklist) do
                if showChecklist then fs:Show() else fs:Hide() end
            end
            for _, fs in ipairs(pvSections.fave) do
                if showFave then fs:Show() else fs:Hide() end
            end
            for _, fs in ipairs(pvSections.best) do
                if showBest then fs:Show() else fs:Hide() end
            end
            for _, fs in ipairs(pvSections.tips) do
                if showTips then fs:Show() else fs:Hide() end
            end
        end
        UpdatePreview()
    end
end

-- ============================================================================
-- Static Popups
-- ============================================================================

-- ============================================================================
-- Export Feature
-- ============================================================================

local exportFrame

local function SerializeTable(t, indent)
    indent = indent or ""
    local parts = {}
    local nextIndent = indent .. "    "

    local isArray = true
    local maxN = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k ~= math_floor(k) then
            isArray = false
            break
        end
        if k > maxN then maxN = k end
    end
    if isArray and maxN ~= #t then isArray = false end

    if isArray then
        for i = 1, #t do
            local v = t[i]
            if type(v) == "table" then
                parts[#parts + 1] = nextIndent .. SerializeTable(v, nextIndent) .. ","
            elseif type(v) == "string" then
                parts[#parts + 1] = nextIndent .. format("%q", v) .. ","
            else
                parts[#parts + 1] = nextIndent .. tostring(v) .. ","
            end
        end
    else
        local keys = {}
        for k in pairs(t) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            if type(a) == type(b) then return tostring(a) < tostring(b) end
            return type(a) < type(b)
        end)
        for _, k in ipairs(keys) do
            local v = t[k]
            local keyStr
            if type(k) == "number" then
                keyStr = format("[%d]", k)
            else
                keyStr = format("[%q]", tostring(k))
            end
            if type(v) == "table" then
                parts[#parts + 1] = nextIndent .. keyStr .. " = " .. SerializeTable(v, nextIndent) .. ","
            elseif type(v) == "string" then
                parts[#parts + 1] = nextIndent .. keyStr .. " = " .. format("%q", v) .. ","
            elseif type(v) == "boolean" then
                parts[#parts + 1] = nextIndent .. keyStr .. " = " .. tostring(v) .. ","
            elseif v ~= nil then
                parts[#parts + 1] = nextIndent .. keyStr .. " = " .. tostring(v) .. ","
            end
        end
    end

    return "{\n" .. table.concat(parts, "\n") .. "\n" .. indent .. "}"
end

local function BuildExportString()
    if not db then return "-- No data" end

    local exportData = {
        version = DB_VERSION,
        exportDate = date("%Y-%m-%d"),
        character = UnitName("player") .. "-" .. GetRealmName(),
        discoveredZones = db.discoveredZones or {},
        discoveredPools = db.discoveredPools or {},
        poolZones = {},
        fishLog = {},
    }

    for itemID, entry in pairs(db.fishLog) do
        exportData.fishLog[itemID] = {
            count = entry.count,
            firstCaught = entry.firstCaught,
            category = entry.category,
        }
    end

    for subzone, ps in pairs(db.poolStats) do
        if ps.pools then
            for poolName in pairs(ps.pools) do
                if not exportData.poolZones[poolName] then
                    exportData.poolZones[poolName] = {}
                end
                exportData.poolZones[poolName][subzone] = true
            end
        end
    end

    return "GoneFishinExport = " .. SerializeTable(exportData)
end

local function ShowExportWindow()
    if exportFrame then
        exportFrame:Show()
        local exportStr = BuildExportString()
        exportFrame.editBox:SetText(exportStr)
        exportFrame.editBox:HighlightText()
        exportFrame.editBox:SetFocus()
        return
    end

    exportFrame = CreateFrame("Frame", "GoneFishinExportFrame", UIParent, "BackdropTemplate")
    exportFrame:SetSize(600, 400)
    exportFrame:SetPoint("CENTER")
    exportFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    exportFrame:SetBackdropColor(0.08, 0.08, 0.08, 0.95)
    exportFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    exportFrame:SetMovable(true)
    exportFrame:EnableMouse(true)
    exportFrame:RegisterForDrag("LeftButton")
    exportFrame:SetScript("OnDragStart", exportFrame.StartMoving)
    exportFrame:SetScript("OnDragStop", exportFrame.StopMovingOrSizing)
    exportFrame:SetFrameStrata("DIALOG")

    local title = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("|cff00ccffGone Fishin'|r Export Data")

    local closeBtn = CreateFrame("Button", nil, exportFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)

    local scrollParent = MedaUI:CreateScrollFrame(exportFrame)
    Pixel.SetPoint(scrollParent, "TOPLEFT", 12, -36)
    Pixel.SetPoint(scrollParent, "BOTTOMRIGHT", -12, 40)
    scrollParent:SetScrollStep(40)

    local editBox = CreateFrame("EditBox", nil, scrollParent.scrollContent)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject(GameFontHighlightSmall)
    editBox:SetPoint("TOPLEFT")
    editBox:SetPoint("TOPRIGHT")
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editBox:HookScript("OnTextChanged", function(self)
        scrollParent:SetContentHeight(self:GetHeight(), true, true)
    end)
    exportFrame.editBox = editBox

    local hint = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("BOTTOMLEFT", 12, 12)
    hint:SetText("|cff888888Press Ctrl+A to select all, then Ctrl+C to copy.|r")

    local exportStr = BuildExportString()
    editBox:SetText(exportStr)
    editBox:HighlightText()
    editBox:SetFocus()
end

-- ============================================================================
-- Static Popups
-- ============================================================================

StaticPopupDialogs["GONEFISHIN_CLEAR_FAVORITES"] = {
    text = "Remove all favorite fishing spots?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        if not db then return end
        local MapPins = ns.Services.MapPinProvider
        if MapPins then MapPins:ClearGroup("GoneFishin_Favorites") end
        wipe(db.favorites)
        print("|cff00ccffGone Fishin':|r All favorites cleared.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["GONEFISHIN_RESET_DATA"] = {
    text = "Reset ALL fishing data? This cannot be undone!",
    button1 = "Yes, Reset",
    button2 = "Cancel",
    OnAccept = function()
        if not db then return end
        wipe(db.fishLog)
        wipe(db.zoneStats)
        wipe(db.poolStats)
        wipe(db.recentCatches)
        wipe(db.discoveredZones)
        wipe(db.discoveredPools)
        local MapPins = ns.Services.MapPinProvider
        if MapPins then MapPins:ClearGroup("GoneFishin_Favorites") end
        wipe(db.favorites)
        db.totalCaught = 0
        db.totalCasts = 0
        db.totalFishingTime = 0
        db.sessionCount = 0
        db.longestStreak = 0
        db.bestSpot = nil
        sessionCaught = 0
        sessionCasts = 0
        sessionJunk = 0
        currentStreak = 0
        print("|cff00ccffGone Fishin':|r All fishing data has been reset.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["GONEFISHIN_RESET_STREAK"] = {
    text = "Reset your longest streak record? This cannot be undone!",
    button1 = "Yes, Reset",
    button2 = "Cancel",
    OnAccept = function()
        if not db then return end
        db.longestStreak = 0
        currentStreak = 0
        print("|cff00ccffGone Fishin':|r Streak record has been reset.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["GONEFISHIN_REPAIR_POOLS"] = {
    text = "Remove false pool entries caused by open water fishing? This corrects pool catch counts but cannot be undone.",
    button1 = "Yes, Repair",
    button2 = "Cancel",
    OnAccept = function()
        local count = PurgeOpenWaterPoolData()
        if count > 0 then
            print(format("|cff00ccffGone Fishin':|r Purged %d false pool entries from open water catches.", count))
        else
            print("|cff00ccffGone Fishin':|r No false pool entries found.")
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- ============================================================================
-- Lifecycle
-- ============================================================================

local function StartModule()
    isEnabled = true

    BuildPoolNameSet()
    CreateScanTooltip()
    HookPoolTooltip()
    CreateHUD()
    CreateMinimapBtn()

    RegisterEvents()
    SyncMapPins()
    RepairPoolNames()

    MedaAuras.Log("[GoneFishin] Module enabled")
end

local function StopModule()
    isEnabled = false
    isFishing = false

    CancelSessionTimeout()
    sessionActive = false

    UnregisterEvents()
    DisableHUDUpdates()

    if hideTimer then hideTimer:Cancel(); hideTimer = nil end
    if hudFrame then hudFrame:Hide() end
    hudVisible = false

    if statsPanel then statsPanel:Hide() end

    local MapPins = ns.Services.MapPinProvider
    if MapPins then MapPins:UnregisterPinGroup("GoneFishin_Favorites") end

    MedaAuras.Log("[GoneFishin] Module disabled")
end

local function OnInitialize(moduleDB)
    db = moduleDB
    RunMigrations(db)
    RestoreSession()
    if sessionActive then
        StartSessionTimeout()
    end
    StartModule()
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
    ["toggle"] = function(moduleDB)
        db = moduleDB
        if hudFrame and hudVisible then
            DisableHUDUpdates()
            hudFrame:Hide()
            hudVisible = false
        else
            ShowHUD()
        end
    end,
    ["stats"] = function(moduleDB)
        db = moduleDB
        if statsPanel and statsPanel:IsShown() then
            statsPanel:Hide()
        else
            CreateStatsPanel()
            statsPanel:Show()
            tabBar:SetActiveTab("overview")
        end
    end,
    ["fave"] = function(moduleDB)
        db = moduleDB
        ToggleFavorite()
    end,
    ["reset"] = function(moduleDB)
        db = moduleDB
        StaticPopup_Show("GONEFISHIN_RESET_DATA")
    end,
    ["show"] = function(moduleDB)
        db = moduleDB
        ShowHUD()
    end,
    ["hide"] = function(moduleDB)
        db = moduleDB
        if hudFrame and hudVisible then
            DisableHUDUpdates()
            hudFrame:Hide()
            hudVisible = false
        end
    end,
    ["aura"] = function(moduleDB)
        db = moduleDB
        moduleDB.auraEnabled = not moduleDB.auraEnabled
        if not moduleDB.auraEnabled and hudVisible then
            DisableHUDUpdates()
            hudFrame:Hide()
            hudVisible = false
        end
        print(format("|cff00ccffGone Fishin':|r Aura HUD %s.", moduleDB.auraEnabled and "enabled" or "disabled"))
    end,
    ["export"] = function(moduleDB)
        db = moduleDB
        ShowExportWindow()
    end,
    ["endsession"] = function(moduleDB)
        db = moduleDB
        if not sessionActive then
            print("|cff00ccffGone Fishin':|r No active session.")
            return
        end
        CancelSessionTimeout()
        EndSession()
        if hudVisible then
            HideHUD()
        end
        print("|cff00ccffGone Fishin':|r Session ended.")
    end,
    ["repairpools"] = function(moduleDB)
        db = moduleDB
        local count = RepairPoolNames()
        if count > 0 then
            print(format("|cff00ccffGone Fishin':|r Repaired %d pool name entries.", count))
        else
            print("|cff00ccffGone Fishin':|r No pool entries to repair.")
        end
    end,
    ["repairdata"] = function(moduleDB)
        db = moduleDB
        local count = PurgeOpenWaterPoolData()
        if count > 0 then
            print(format("|cff00ccffGone Fishin':|r Purged %d false pool entries from open water catches.", count))
        else
            print("|cff00ccffGone Fishin':|r No false pool entries found.")
        end
    end,
}

-- ============================================================================
-- Module Defaults
-- ============================================================================

local MODULE_DEFAULTS = {
    enabled = false,
    dbVersion = 0,

    fishLog = {},
    zoneStats = {},
    totalCaught = 0,
    totalCasts = 0,
    totalFishingTime = 0,
    sessionCount = 0,
    longestStreak = 0,
    recentCatches = {},

    poolStats = {},
    bestSpot = nil,

    favorites = {},
    showMapPins = true,

    discoveredZones = {},
    discoveredPools = {},
    poolObjectNames = {},
    collectionSort = "missing",

    auraEnabled = true,
    auraLockPanels = true,
    auraShowChecklist = true,
    auraShowRecent = true,
    auraShowTips = true,
    auraShowFaves = true,
    auraShowBestSpot = true,
    auraShowSessionJunk = true,
    auraHOffset = 200,
    auraVerticalOffset = -20,
    auraScale = 1.0,
    auraTextSize = 13,
    auraIconSize = 20,
    auraOpacity = 0.92,
    auraFont = "default",
    auraTextOutline = "outline",
    auraFadeIn = 0.4,
    auraFadeOut = 0.6,
    auraHideDelay = 2,

    leftPanelPos = nil,
    rightPanelPos = nil,
    bottomPanelPos = nil,

    statsPosition = nil,
    statsSize = nil,
    showMinimapButton = true,
}

-- ============================================================================
-- Register Module
-- ============================================================================

MedaAuras:RegisterModule({
    name          = MODULE_NAME,
    title         = "Gone Fishin'",
    version       = MODULE_VERSION,
    stability     = MODULE_STABILITY,
    description   = "Tracks every fish and item caught while fishing. "
                 .. "Displays a three-panel HUD with zone stats, a zone fish checklist "
                 .. "(with collapsible junk and missing sections), and favorites/tips. "
                 .. "Each panel can be dragged independently. "
                 .. "Includes a stats window with Midnight fish collection checklist, "
                 .. "zone breakdowns, and custom map pins for favorite fishing spots.",
    sidebarDesc   = "Tracks every fish and item caught while fishing with a three-panel HUD.",
    defaults      = MODULE_DEFAULTS,
    OnInitialize  = OnInitialize,
    OnEnable      = OnEnable,
    OnDisable     = OnDisable,
    BuildConfig   = BuildConfig,
    slashCommands = slashCommands,
})
