local _, ns = ...

local MedaUI = LibStub("MedaUI-2.0")

local format = format
local GetTime = GetTime
local pairs = pairs
local unpack = unpack
local CreateFrame = CreateFrame
local UnitPower = UnitPower
local UnitPowerMax = UnitPowerMax
local UnitPowerType = UnitPowerType
local math_max = math.max

-- ============================================================================
-- Constants
-- ============================================================================

local MODULE_NAME      = "ManaTracker"
local MODULE_VERSION   = "1.0"
local MODULE_STABILITY = "stable"   -- "experimental" | "beta" | "stable"

local PREFIX = "[ManaTracker]"
local Enum_PowerType_Mana = Enum.PowerType.Mana
local MANA_TOKEN = "MANA"

local LOW_COLOR = { 0.8, 0.1, 0.1, 1.0 }
local MEDIUM_COLOR = { 0.9, 0.5, 0.0, 1.0 }
local DEFAULT_BG_COLOR = { 0.1, 0.1, 0.2, 1.0 }
local DEFAULT_BORDER_COLOR = { 0.2, 0.4, 0.7, 1.0 }
local DEFAULT_MANA_COLOR = { 0.0, 0.56, 1.0, 1.0 }
local DEFAULT_OUTER_BORDER = { 0, 0, 0, 1 }

local DEFAULT_WIDTH = 200
local DEFAULT_HEIGHT = 24
local DEFAULT_ORB_SIZE = 64
local INNER_PADDING = 3

local ANCHOR_OFFSETS = {
    CENTER      = { 0, 0 },
    TOP         = { 0, -4 },
    BOTTOM      = { 0, 4 },
    LEFT        = { 4, 0 },
    RIGHT       = { -4, 0 },
    TOPLEFT     = { 4, -4 },
    TOPRIGHT    = { -4, -4 },
    BOTTOMLEFT  = { 4, 4 },
    BOTTOMRIGHT = { -4, 4 },
}

-- ============================================================================
-- State
-- ============================================================================

local containerFrame
local display
local eventFrame
local currentDisplayMode

local previewContainer   -- floating side panel
local previewDisplay
local previewDisplayMode

local percentCurve
local colorCurve
local colorCurveColor -- tracks which manaColor the curve was built for

-- Diagnostic throttle
local diagTickCount = 0
local DIAG_INTERVAL = 6

-- ============================================================================
-- Curves (created once, reused)
-- ============================================================================

local function EnsurePercentCurve()
    if percentCurve then return percentCurve end
    percentCurve = C_CurveUtil.CreateCurve()
    percentCurve:SetType(Enum.LuaCurveType.Step)
    for i = 0, 100 do
        percentCurve:AddPoint(i / 100, i)
    end
    return percentCurve
end

local function EnsureColorCurve(manaColor)
    if colorCurve and colorCurveColor == manaColor then return colorCurve end
    colorCurve = C_CurveUtil.CreateColorCurve()
    colorCurve:SetType(Enum.LuaCurveType.Step)
    colorCurve:AddPoint(0.0, CreateColor(LOW_COLOR[1], LOW_COLOR[2], LOW_COLOR[3], LOW_COLOR[4]))
    colorCurve:AddPoint(0.2, CreateColor(MEDIUM_COLOR[1], MEDIUM_COLOR[2], MEDIUM_COLOR[3], MEDIUM_COLOR[4]))
    colorCurve:AddPoint(0.4, CreateColor(manaColor[1], manaColor[2], manaColor[3], manaColor[4] or 1))
    colorCurveColor = manaColor
    return colorCurve
end

-- ============================================================================
-- Font Object Cache
-- ============================================================================

local fontObjects = {}
local function GetFontObject(fontPath, size)
    local key = (fontPath or "default") .. "_" .. size
    local cached = fontObjects[key]
    if cached then return cached end

    local font = CreateFont("MedaAurasManaFont_" .. key:gsub("[^%w]", "_"))
    if fontPath then
        font:SetFont(fontPath, size, "OUTLINE")
    else
        font:CopyFontObject(GameFontNormal)
        local defaultPath, _, flags = font:GetFont()
        font:SetFont(defaultPath, size, flags)
    end
    fontObjects[key] = font
    return font
end

-- ============================================================================
-- Secret Value Helpers
-- ============================================================================

local function IsSecret(val)
    if val == nil then return true end
    if issecretvalue then return issecretvalue(val) end
    local ok = pcall(function() return val + 0 end)
    return not ok
end

-- ============================================================================
-- Mana Data API
-- ============================================================================

local function GetMana()
    local current = UnitPower("player", Enum_PowerType_Mana)
    local max = UnitPowerMax("player", Enum_PowerType_Mana)
    return current, max, IsSecret(current), IsSecret(max)
end

local function GetManaPercent()
    EnsurePercentCurve()
    local ok, pct = pcall(UnitPowerPercent, "player", Enum_PowerType_Mana, false, percentCurve)
    if ok and pct then return pct end
    return nil
end

local function GetManaColor(manaColor)
    EnsureColorCurve(manaColor)
    local ok, color = pcall(UnitPowerPercent, "player", Enum_PowerType_Mana, false, colorCurve)
    if ok and color and color.GetRGBA then return color:GetRGBA() end
    return manaColor[1], manaColor[2], manaColor[3], manaColor[4] or 1
end

-- ============================================================================
-- Shared Text Update (secret-safe for both bar and orb)
-- ============================================================================
-- SetFormattedText crashes on secret values, so we pcall it and fall back to
-- SetText which can render secret numbers directly.

local function UpdateText(text, current, db)
    if not db.showText then
        text:Hide()
        return
    end

    if db.showPercentage then
        local pct = GetManaPercent()
        if pct then
            local fmtOk = pcall(text.SetFormattedText, text, "%d%%", pct)
            if not fmtOk then
                text:SetText(pct)
            end
        else
            text:SetText("?%")
        end
    else
        if IsSecret(current) then
            text:SetText(current)
        else
            text:SetFormattedText("%d", current)
        end
    end
    text:Show()
end

-- ============================================================================
-- Bar Display
-- ============================================================================

local function CreateBarDisplay(parent, db)
    local texturePath = MedaUI:GetBarTexture(db.barTexture or "solid")

    local d = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    d:SetAllPoints()
    d:SetBackdrop(MedaUI:CreateBackdrop(true))
    local bgc = db.backgroundColor or DEFAULT_BG_COLOR
    d:SetBackdropColor(bgc[1], bgc[2], bgc[3], db.backgroundOpacity or 0.8)
    d:SetBackdropBorderColor(DEFAULT_BORDER_COLOR[1], DEFAULT_BORDER_COLOR[2], DEFAULT_BORDER_COLOR[3], DEFAULT_BORDER_COLOR[4])

    local bar = CreateFrame("StatusBar", nil, d)
    bar:SetPoint("TOPLEFT", INNER_PADDING, -INNER_PADDING)
    bar:SetPoint("BOTTOMRIGHT", -INNER_PADDING, INNER_PADDING)
    bar:SetStatusBarTexture(texturePath)
    bar:SetStatusBarColor(0.0, 0.56, 1.0, 1.0)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)

    local orientation = db.barOrientation or "HORIZONTAL"
    bar:SetOrientation(orientation)

    d.bar = bar

    local textOverlay = CreateFrame("Frame", nil, d)
    textOverlay:SetAllPoints()
    textOverlay:SetFrameLevel(bar:GetFrameLevel() + 10)

    local text = textOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER", d, "CENTER")
    text:SetTextColor(1, 1, 1, 1)
    text:SetShadowOffset(1, -1)
    text:SetShadowColor(0, 0, 0, 1)
    d.text = text

    local outerBorder = CreateFrame("Frame", nil, parent)
    outerBorder:SetFrameLevel(math_max(d:GetFrameLevel() - 1, 0))
    local outerTex = outerBorder:CreateTexture(nil, "BACKGROUND")
    outerTex:SetAllPoints()
    outerTex:SetColorTexture(0, 0, 0, 1)
    d.outerBorder = outerBorder
    d.outerBorderTex = outerTex

    d._lastManaColor = nil
    d._lastFontPath = false
    d._lastTextSize = 0
    d._lastAnchor = nil
    d._lastBarTexture = nil
    d._lastOrientation = nil
    d.mode = "bar"

    return d
end

local function UpdateBarDisplay(d, current, max, db)
    local manaColor = db.manaColor or DEFAULT_MANA_COLOR

    -- StatusBar fill (secret-safe)
    d.bar:SetMinMaxValues(0, max)
    d.bar:SetValue(current)

    -- Bar texture
    local barTex = db.barTexture or "solid"
    if d._lastBarTexture ~= barTex then
        d.bar:SetStatusBarTexture(MedaUI:GetBarTexture(barTex))
        d._lastBarTexture = barTex
    end

    -- Bar orientation
    local orientation = db.barOrientation or "HORIZONTAL"
    if d._lastOrientation ~= orientation then
        d.bar:SetOrientation(orientation)
        d._lastOrientation = orientation
    end

    -- Color (pcall-wrapped)
    local r, g, b, a = GetManaColor(manaColor)
    d.bar:SetStatusBarColor(r, g, b, a)

    -- Background / border
    local bgc = db.backgroundColor or DEFAULT_BG_COLOR
    d:SetBackdropColor(bgc[1], bgc[2], bgc[3], db.backgroundOpacity or 0.8)
    if db.showBorder == false then
        d:SetBackdropBorderColor(0, 0, 0, 0)
    else
        local bc = db.borderColor or DEFAULT_BORDER_COLOR
        d:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4] or 1)
    end

    -- Outer border
    if db.showOuterBorder == false then
        d.outerBorder:Hide()
    else
        d.outerBorder:Show()
        local obs = db.outerBorderSize or 2
        d.outerBorder:ClearAllPoints()
        d.outerBorder:SetPoint("TOPLEFT", d, "TOPLEFT", -obs, obs)
        d.outerBorder:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", obs, -obs)
        local obc = db.outerBorderColor or DEFAULT_OUTER_BORDER
        d.outerBorderTex:SetColorTexture(obc[1], obc[2], obc[3], obc[4] or 1)
    end

    -- Font
    local textSize = db.textSize or 14
    local fontPath = db.font
    if d._lastFontPath ~= fontPath or d._lastTextSize ~= textSize then
        d.text:SetFontObject(GetFontObject(fontPath, textSize))
        d._lastFontPath = fontPath
        d._lastTextSize = textSize
    end

    -- Text anchor + user offsets
    local anchor = db.textAnchor or "CENTER"
    local txOff = db.textOffsetX or 0
    local tyOff = db.textOffsetY or 0
    if d._lastAnchor ~= anchor or d._lastTxOff ~= txOff or d._lastTyOff ~= tyOff then
        local offsets = ANCHOR_OFFSETS[anchor] or ANCHOR_OFFSETS.CENTER
        d.text:ClearAllPoints()
        d.text:SetPoint(anchor, d, anchor, offsets[1] + txOff, offsets[2] + tyOff)
        d._lastAnchor = anchor
        d._lastTxOff = txOff
        d._lastTyOff = tyOff
    end

    -- Text content (secret-safe)
    UpdateText(d.text, current, db)
end

-- ============================================================================
-- Orb Display (vertical StatusBar + MaskTexture)
-- ============================================================================
-- Uses a vertical StatusBar for the fill (accepts secret values natively via
-- SetMinMaxValues/SetValue). A MaskTexture clips the rectangular fill to the
-- circular orb shape. MaskTexture operates in screen-space so the circle stays
-- correct regardless of how StatusBar internally resizes its fill region.

local function CreateOrbDisplay(parent, db)
    local orbTexture = db.orbTexture or "solid"
    local maskPath, ringPath = MedaUI:GetOrbTextures(orbTexture)

    local d = CreateFrame("Frame", nil, parent)
    d:SetAllPoints()

    -- Outer border (circular, behind everything)
    local outerBorderTex = d:CreateTexture(nil, "BACKGROUND", nil, -8)
    outerBorderTex:SetTexture(maskPath)
    local obc = db.outerBorderColor or DEFAULT_OUTER_BORDER
    outerBorderTex:SetVertexColor(obc[1], obc[2], obc[3], obc[4] or 1)
    d.outerBorderTex = outerBorderTex

    -- Background orb (dark)
    local bg = d:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(maskPath)
    local bgc = db.backgroundColor or DEFAULT_BG_COLOR
    bg:SetVertexColor(bgc[1], bgc[2], bgc[3], db.backgroundOpacity or 0.9)
    d.bg = bg

    -- Vertical StatusBar for fill (secret-safe, fills bottom-to-top)
    local fillTexture = MedaUI:GetBarTexture(db.orbFillTexture or "solid")
    local bar = CreateFrame("StatusBar", nil, d)
    bar:SetAllPoints()
    bar:SetOrientation("VERTICAL")
    bar:SetStatusBarTexture(fillTexture)
    bar:SetStatusBarColor(0.0, 0.56, 1.0, 1.0)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    d.bar = bar

    -- MaskTexture for circular clipping (screen-space, sized to the full orb)
    local mask = bar:CreateMaskTexture()
    mask:SetAllPoints(d)
    mask:SetTexture(maskPath)
    bar:GetStatusBarTexture():AddMaskTexture(mask)
    d.mask = mask

    -- Ring overlay
    local ring = d:CreateTexture(nil, "OVERLAY")
    ring:SetAllPoints()
    ring:SetTexture(ringPath)
    ring:SetVertexColor(DEFAULT_BORDER_COLOR[1], DEFAULT_BORDER_COLOR[2], DEFAULT_BORDER_COLOR[3], DEFAULT_BORDER_COLOR[4])
    d.ring = ring

    -- Text overlay
    local textOverlay = CreateFrame("Frame", nil, d)
    textOverlay:SetAllPoints()
    textOverlay:SetFrameLevel(bar:GetFrameLevel() + 10)

    local text = textOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER", d, "CENTER")
    text:SetTextColor(1, 1, 1, 1)
    text:SetShadowOffset(1, -1)
    text:SetShadowColor(0, 0, 0, 1)
    d.text = text

    d._lastFontPath = false
    d._lastTextSize = 0
    d._lastAnchor = nil
    d._lastOrbTexture = nil
    d._lastOrbFillTexture = nil
    d._maskPath = maskPath
    d.mode = "orb"

    return d
end

local function UpdateOrbDisplay(d, current, max, db)
    local manaColor = db.manaColor or DEFAULT_MANA_COLOR

    -- Orb texture swap
    local orbTex = db.orbTexture or "solid"
    if d._lastOrbTexture ~= orbTex then
        local maskPath, ringPath = MedaUI:GetOrbTextures(orbTex)
        d.bg:SetTexture(maskPath)
        d.mask:SetTexture(maskPath)
        d.ring:SetTexture(ringPath)
        d.outerBorderTex:SetTexture(maskPath)
        d._maskPath = maskPath
        d._lastOrbTexture = orbTex
    end

    -- Fill texture swap
    local fillTex = db.orbFillTexture or "solid"
    if d._lastOrbFillTexture ~= fillTex then
        d.bar:SetStatusBarTexture(MedaUI:GetBarTexture(fillTex))
        d.bar:GetStatusBarTexture():AddMaskTexture(d.mask)
        d._lastOrbFillTexture = fillTex
    end

    -- Fill level (secret-safe -- StatusBar handles it natively)
    d.bar:SetMinMaxValues(0, max)
    d.bar:SetValue(current)

    -- Fill color (color curve returns usable Color objects)
    local r, g, b, a = GetManaColor(manaColor)
    d.bar:SetStatusBarColor(r, g, b, a)

    -- Background color
    local bgc = db.backgroundColor or DEFAULT_BG_COLOR
    d.bg:SetVertexColor(bgc[1], bgc[2], bgc[3], db.backgroundOpacity or 0.9)

    -- Ring / border
    if db.showBorder == false then
        d.ring:Hide()
    else
        d.ring:Show()
        local bc = db.borderColor or DEFAULT_BORDER_COLOR
        d.ring:SetVertexColor(bc[1], bc[2], bc[3], bc[4] or 1)
    end

    -- Outer border
    if db.showOuterBorder == false then
        d.outerBorderTex:Hide()
    else
        d.outerBorderTex:Show()
        local obs = db.outerBorderSize or 2
        d.outerBorderTex:ClearAllPoints()
        d.outerBorderTex:SetPoint("TOPLEFT", -obs, obs)
        d.outerBorderTex:SetPoint("BOTTOMRIGHT", obs, -obs)
        local obc = db.outerBorderColor or DEFAULT_OUTER_BORDER
        d.outerBorderTex:SetVertexColor(obc[1], obc[2], obc[3], obc[4] or 1)
    end

    -- Font
    local textSize = db.textSize or 12
    local fontPath = db.font
    if d._lastFontPath ~= fontPath or d._lastTextSize ~= textSize then
        d.text:SetFontObject(GetFontObject(fontPath, textSize))
        d._lastFontPath = fontPath
        d._lastTextSize = textSize
    end

    -- Text anchor + user offsets
    local anchor = db.textAnchor or "CENTER"
    local txOff = db.textOffsetX or 0
    local tyOff = db.textOffsetY or 0
    if d._lastAnchor ~= anchor or d._lastTxOff ~= txOff or d._lastTyOff ~= tyOff then
        local offsets = ANCHOR_OFFSETS[anchor] or ANCHOR_OFFSETS.CENTER
        d.text:ClearAllPoints()
        d.text:SetPoint(anchor, d, anchor, offsets[1] + txOff, offsets[2] + tyOff)
        d._lastAnchor = anchor
        d._lastTxOff = txOff
        d._lastTyOff = tyOff
    end

    -- Text content (secret-safe)
    UpdateText(d.text, current, db)
end

-- ============================================================================
-- Display Management
-- ============================================================================

local function DestroyDisplay()
    if display then
        display:Hide()
        display:SetParent(nil)
        display = nil
    end
    currentDisplayMode = nil
end

local function CreateDisplay(db)
    DestroyDisplay()

    local mode = db.displayMode or "bar"
    if mode == "orb" then
        local radius = db.orbRadius or (DEFAULT_ORB_SIZE / 2)
        local size = radius * 2
        containerFrame:SetSize(size, size)
        display = CreateOrbDisplay(containerFrame, db)
    else
        containerFrame:SetSize(db.width or DEFAULT_WIDTH, db.height or DEFAULT_HEIGHT)
        display = CreateBarDisplay(containerFrame, db)
    end
    currentDisplayMode = mode
end

local function UpdateDisplay(db)
    if not display or not containerFrame then return end

    local current, max, _, _ = GetMana()

    -- Resize container if settings changed
    local mode = db.displayMode or "bar"
    if mode ~= currentDisplayMode then
        CreateDisplay(db)
    end

    if mode == "bar" then
        local w = db.width or DEFAULT_WIDTH
        local h = db.height or DEFAULT_HEIGHT
        containerFrame:SetSize(w, h)
        UpdateBarDisplay(display, current, max, db)
    elseif mode == "orb" then
        local radius = db.orbRadius or (DEFAULT_ORB_SIZE / 2)
        local size = radius * 2
        containerFrame:SetSize(size, size)
        UpdateOrbDisplay(display, current, max, db)
    end
end

-- ============================================================================
-- Live Preview (settings panel)
-- ============================================================================

local PREVIEW_MOCK_CURRENT = 700
local PREVIEW_MOCK_MAX = 1000

local function DestroyPreview()
    if previewDisplay then
        previewDisplay:Hide()
        previewDisplay:SetParent(nil)
        previewDisplay = nil
    end
    if previewContainer then
        previewContainer:Hide()
        previewContainer:SetParent(nil)
        previewContainer = nil
    end
    previewDisplayMode = nil
end

local function CreatePreviewDisplay(db)
    if previewDisplay then
        previewDisplay:Hide()
        previewDisplay:SetParent(nil)
        previewDisplay = nil
    end
    previewDisplayMode = nil
    if not previewContainer then return end

    local mode = db.displayMode or "bar"
    if mode == "orb" then
        local radius = db.orbRadius or (DEFAULT_ORB_SIZE / 2)
        local size = radius * 2
        previewContainer.inner:SetSize(size, size)
        previewDisplay = CreateOrbDisplay(previewContainer.inner, db)
    else
        local w = db.width or DEFAULT_WIDTH
        local h = db.height or DEFAULT_HEIGHT
        previewContainer.inner:SetSize(w, h)
        previewDisplay = CreateBarDisplay(previewContainer.inner, db)
    end
    previewDisplayMode = mode
end

local function UpdatePreview(db)
    if not previewDisplay or not previewContainer then return end

    local mode = db.displayMode or "bar"
    if mode ~= previewDisplayMode then
        CreatePreviewDisplay(db)
    end

    if mode == "bar" then
        local w = db.width or DEFAULT_WIDTH
        local h = db.height or DEFAULT_HEIGHT
        previewContainer.inner:SetSize(w, h)
        UpdateBarDisplay(previewDisplay, PREVIEW_MOCK_CURRENT, PREVIEW_MOCK_MAX, db)
    elseif mode == "orb" then
        local radius = db.orbRadius or (DEFAULT_ORB_SIZE / 2)
        local size = radius * 2
        previewContainer.inner:SetSize(size, size)
        UpdateOrbDisplay(previewDisplay, PREVIEW_MOCK_CURRENT, PREVIEW_MOCK_MAX, db)
    end
end

-- ============================================================================
-- Diagnostic Logging
-- ============================================================================

local function LogDiagnostic(current, max, db)
    diagTickCount = diagTickCount + 1
    if diagTickCount < DIAG_INTERVAL then return end
    diagTickCount = 0

    local secCur = IsSecret(current)
    local secMax = IsSecret(max)

    local pct = GetManaPercent()
    local pctSecret = pct ~= nil and IsSecret(pct)
    local pctStr = pct == nil and "nil" or (pctSecret and "SECRET" or tostring(pct))

    pcall(MedaAuras.Log, format(
        "%s secCur=%s secMax=%s pct=%s pctSecret=%s mode=%s",
        PREFIX,
        tostring(secCur), tostring(secMax),
        pctStr, tostring(pctSecret),
        tostring(db.displayMode or "bar")
    ))
end

-- ============================================================================
-- Container Frame (draggable)
-- ============================================================================

local function CreateContainerFrame()
    local f = CreateFrame("Frame", "MedaAurasManaTrackerFrame", UIParent)
    f:SetSize(DEFAULT_WIDTH, DEFAULT_HEIGHT)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")

    f:SetScript("OnDragStart", function(self)
        local db = MedaAuras:GetModuleDB("ManaTracker")
        if db and not db.locked then
            self:StartMoving()
        end
    end)

    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local db = MedaAuras:GetModuleDB("ManaTracker")
        if db then
            local point, _, _, x, y = self:GetPoint()
            db.position = db.position or {}
            db.position.point = point
            db.position.x = x
            db.position.y = y
        end
    end)

    return f
end

local function ApplyPosition(db)
    if not containerFrame then return end
    containerFrame:ClearAllPoints()
    local pos = db.position or { point = "CENTER", x = 0, y = -200 }
    containerFrame:SetPoint(pos.point, UIParent, pos.point, pos.x, pos.y)
end

local function UpdateLock(db)
    if not containerFrame then return end
    containerFrame:EnableMouse(not db.locked)

    if not db.locked then
        if not containerFrame.unlockBorder then
            containerFrame.unlockBorder = containerFrame:CreateTexture(nil, "OVERLAY")
            containerFrame.unlockBorder:SetAllPoints()
            containerFrame.unlockBorder:SetColorTexture(1, 1, 1, 0.15)
        end
        containerFrame.unlockBorder:Show()
    elseif containerFrame.unlockBorder then
        containerFrame.unlockBorder:Hide()
    end
end

-- ============================================================================
-- Event Handling
-- ============================================================================

local function OnManaEvent(db)
    if previewContainer then
        UpdatePreview(db)
    end
    if not db.enabled then return end
    local current, max = GetMana()
    UpdateDisplay(db)
    LogDiagnostic(current, max, db)
end

local function RegisterEvents(db)
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
    end

    eventFrame:RegisterEvent("UNIT_POWER_UPDATE")
    eventFrame:RegisterEvent("UNIT_MAXPOWER")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

    eventFrame:SetScript("OnEvent", function(_, event, unit, powerType)
        if event == "PLAYER_ENTERING_WORLD"
            or event == "PLAYER_REGEN_ENABLED"
            or event == "PLAYER_REGEN_DISABLED" then
            OnManaEvent(db)
        elseif unit == "player" and (powerType == MANA_TOKEN or powerType == nil) then
            OnManaEvent(db)
        end
    end)
end

local function UnregisterEvents()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
        eventFrame:SetScript("OnEvent", nil)
    end
end

-- ============================================================================
-- Module Lifecycle
-- ============================================================================

local function OnInitialize(db)
    MedaAuras.Log(format("%s Initializing", PREFIX))

    EnsurePercentCurve()
    EnsureColorCurve(db.manaColor or DEFAULT_MANA_COLOR)

    containerFrame = CreateContainerFrame()
    ApplyPosition(db)
    CreateDisplay(db)
    UpdateLock(db)

    containerFrame:Show()
    RegisterEvents(db)
    OnManaEvent(db)

    MedaAuras.Log(format("%s Initialized, mode=%s", PREFIX, db.displayMode or "bar"))
end

local function OnEnable(db)
    if not containerFrame then
        OnInitialize(db)
        return
    end

    EnsureColorCurve(db.manaColor or DEFAULT_MANA_COLOR)
    CreateDisplay(db)
    ApplyPosition(db)
    UpdateLock(db)
    containerFrame:Show()
    RegisterEvents(db)
    OnManaEvent(db)

    MedaAuras.Log(format("%s Enabled", PREFIX))
end

local function OnDisable(db)
    UnregisterEvents()
    DestroyDisplay()
    DestroyPreview()
    previewContainer = nil
    if containerFrame then
        containerFrame:Hide()
    end
    MedaAuras.Log(format("%s Disabled", PREFIX))
end

-- ============================================================================
-- Module Defaults
-- ============================================================================

local MODULE_DEFAULTS = {
    enabled = false,
    locked = false,
    position = { point = "CENTER", x = 0, y = -200 },

    displayMode = "bar",

    -- Bar settings
    width = DEFAULT_WIDTH,
    height = DEFAULT_HEIGHT,
    barTexture = "solid",
    barOrientation = "HORIZONTAL",

    -- Orb settings
    orbRadius = DEFAULT_ORB_SIZE / 2,
    orbTexture = "solid",
    orbFillTexture = "solid",

    -- Shared visual settings
    backgroundColor = { 0.1, 0.1, 0.1, 1.0 },
    manaColor = { 0.0, 0.44, 0.87, 1.0 },
    borderColor = { 0.3, 0.3, 0.3, 1.0 },
    backgroundOpacity = 0.8,
    showBorder = true,
    showOuterBorder = false,
    outerBorderSize = 2,
    outerBorderColor = { 0.1, 0.1, 0.1, 1.0 },
    showText = true,
    showPercentage = true,
    textSize = 14,
    textAnchor = "CENTER",
    textOffsetX = 0,
    textOffsetY = 0,
    font = nil,
}

-- ============================================================================
-- Settings Panel (BuildConfig)
-- ============================================================================

local function BuildSettingsPage(parent, db)
    local LEFT_X, RIGHT_X = 0, 238
    local mode = db.displayMode or "bar"
    local isBar = (mode == "bar")

    DestroyPreview()
    do
        local PREVIEW_W = 280
        local PREVIEW_H = 180
        local anchor = MedaAurasSettingsPanel or _G["MedaAurasSettingsPanel"]
        if anchor then
            local pvBg = CreateFrame("Frame", nil, anchor)
            pvBg:SetFrameStrata("HIGH")
            pvBg:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 0)
            pvBg:SetSize(PREVIEW_W, PREVIEW_H)
            MedaAuras:RegisterConfigCleanup(pvBg)
            local pvInner = CreateFrame("Frame", nil, pvBg)
            pvInner:SetPoint("CENTER", 0, 0)
            pvBg.inner = pvInner
            previewContainer = pvBg
            pvBg:Show()
            CreatePreviewDisplay(db)
            UpdatePreview(db)
        end
    end

    local tabBar, tabs = MedaAuras:CreateConfigTabs(parent, {
        { id = "display",    label = "Display" },
        { id = "textcolors", label = "Text & Colors" },
    })

    -- ===== Display Tab =====
    do
        local p = tabs["display"]
        local yOff = 0

        local hdr = MedaUI:CreateSectionHeader(p, "Display")
        hdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 40

        local modeOptions = {
            { value = "bar", label = "Bar" },
            { value = "orb", label = "Orb" },
        }
        local modeDropdown = MedaUI:CreateLabeledDropdown(p, "Display Mode", 160, modeOptions)
        modeDropdown:SetPoint("TOPLEFT", LEFT_X, yOff)
        modeDropdown:SetSelected(mode)
        modeDropdown.OnValueChanged = function(_, value)
            db.displayMode = value
            if containerFrame then
                CreateDisplay(db)
                OnManaEvent(db)
            end
            MedaAuras:ToggleSettings()
            MedaAuras:ToggleSettings()
        end
        local lockCb = MedaUI:CreateCheckbox(p, "Lock Frame")
        lockCb:SetPoint("TOPLEFT", RIGHT_X, yOff)
        lockCb:SetChecked(db.locked)
        lockCb.OnValueChanged = function(_, checked)
            db.locked = checked
            UpdateLock(db)
        end
        yOff = yOff - 55

        local borderHdr = MedaUI:CreateSectionHeader(p, "Border")
        borderHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 40

        local showBorderCb = MedaUI:CreateCheckbox(p, "Show Border")
        showBorderCb:SetPoint("TOPLEFT", LEFT_X, yOff)
        showBorderCb:SetChecked(db.showBorder ~= false)
        showBorderCb.OnValueChanged = function(_, checked)
            db.showBorder = checked
            OnManaEvent(db)
        end
        local showOuterBorderCb = MedaUI:CreateCheckbox(p, "Show Outer Border")
        showOuterBorderCb:SetPoint("TOPLEFT", RIGHT_X, yOff)
        showOuterBorderCb:SetChecked(db.showOuterBorder ~= false)
        showOuterBorderCb.OnValueChanged = function(_, checked)
            db.showOuterBorder = checked
            OnManaEvent(db)
        end
        yOff = yOff - 30

        local bc = db.borderColor or DEFAULT_BORDER_COLOR
        local borderColorPicker = MedaUI:CreateLabeledColorPicker(p, "Border Color", nil, true)
        borderColorPicker:SetPoint("TOPLEFT", LEFT_X, yOff)
        borderColorPicker:SetColor(bc[1], bc[2], bc[3], bc[4] or 1)
        borderColorPicker.OnColorChanged = function(_, r, g, b, a)
            db.borderColor = { r, g, b, a }
            OnManaEvent(db)
        end
        local outerBorderSizeSlider = MedaUI:CreateLabeledSlider(p, "Outer Border Size", 200, 1, 10, 1)
        outerBorderSizeSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
        outerBorderSizeSlider:SetValue(db.outerBorderSize or 2)
        outerBorderSizeSlider.OnValueChanged = function(_, value)
            db.outerBorderSize = value
            OnManaEvent(db)
        end
        yOff = yOff - 55

        local obc = db.outerBorderColor or DEFAULT_OUTER_BORDER
        local outerBorderColorPicker = MedaUI:CreateLabeledColorPicker(p, "Outer Border Color", nil, true)
        outerBorderColorPicker:SetPoint("TOPLEFT", LEFT_X, yOff)
        outerBorderColorPicker:SetColor(obc[1], obc[2], obc[3], obc[4] or 1)
        outerBorderColorPicker.OnColorChanged = function(_, r, g, b, a)
            db.outerBorderColor = { r, g, b, a }
            OnManaEvent(db)
        end
        yOff = yOff - 35

        if isBar then
            local barHdr = MedaUI:CreateSectionHeader(p, "Bar Settings")
            barHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
            yOff = yOff - 40

            local widthSlider = MedaUI:CreateLabeledSlider(p, "Width", 200, 50, 500, 1)
            widthSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
            widthSlider:SetValue(db.width or DEFAULT_WIDTH)
            widthSlider.OnValueChanged = function(_, value) db.width = value; OnManaEvent(db) end
            local heightSlider = MedaUI:CreateLabeledSlider(p, "Height", 200, 8, 100, 1)
            heightSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
            heightSlider:SetValue(db.height or DEFAULT_HEIGHT)
            heightSlider.OnValueChanged = function(_, value) db.height = value; OnManaEvent(db) end
            yOff = yOff - 55

            local orientOptions = {
                { value = "HORIZONTAL", label = "Horizontal" },
                { value = "VERTICAL", label = "Vertical" },
            }
            local orientDropdown = MedaUI:CreateLabeledDropdown(p, "Orientation", 160, orientOptions)
            orientDropdown:SetPoint("TOPLEFT", LEFT_X, yOff)
            orientDropdown:SetSelected(db.barOrientation or "HORIZONTAL")
            orientDropdown.OnValueChanged = function(_, value) db.barOrientation = value; OnManaEvent(db) end
            yOff = yOff - 55

            local barTexList = MedaUI:GetBarTextureList()
            local barTexOptions = {}
            for _, entry in ipairs(barTexList) do
                barTexOptions[#barTexOptions + 1] = {
                    value = entry.id, label = entry.name,
                    texture = MedaUI:GetBarTexture(entry.id),
                }
            end
            if #barTexOptions > 0 then
                local barTexDropdown = MedaUI:CreateLabeledDropdown(p, "Bar Texture", 240, barTexOptions, "fill")
                barTexDropdown:SetPoint("TOPLEFT", LEFT_X, yOff)
                barTexDropdown:SetSelected(db.barTexture or "solid")
                barTexDropdown.OnValueChanged = function(_, value) db.barTexture = value; OnManaEvent(db) end
            end
        else
            local orbHdr = MedaUI:CreateSectionHeader(p, "Orb Settings")
            orbHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
            yOff = yOff - 40

            local radiusSlider = MedaUI:CreateLabeledSlider(p, "Radius", 200, 16, 128, 1)
            radiusSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
            radiusSlider:SetValue(db.orbRadius or (DEFAULT_ORB_SIZE / 2))
            radiusSlider.OnValueChanged = function(_, value) db.orbRadius = value; OnManaEvent(db) end
            yOff = yOff - 55

            local orbTexList = MedaUI:GetOrbTextureList()
            local orbTexOptions = {}
            for _, entry in ipairs(orbTexList) do
                local maskPath = MedaUI:GetOrbTextures(entry.id)
                orbTexOptions[#orbTexOptions + 1] = { value = entry.id, label = entry.name, texture = maskPath }
            end
            if #orbTexOptions > 0 then
                local orbTexDropdown = MedaUI:CreateLabeledDropdown(p, "Orb Shape", 180, orbTexOptions, "preview")
                orbTexDropdown:SetPoint("TOPLEFT", LEFT_X, yOff)
                orbTexDropdown:SetSelected(db.orbTexture or "solid")
                orbTexDropdown.OnValueChanged = function(_, value)
                    db.orbTexture = value
                    if display and display.mode == "orb" then CreateDisplay(db); OnManaEvent(db) end
                end
                yOff = yOff - 60
            end

            local fillTexList = MedaUI:GetBarTextureList()
            local fillTexOptions = {}
            for _, entry in ipairs(fillTexList) do
                fillTexOptions[#fillTexOptions + 1] = {
                    value = entry.id, label = entry.name,
                    texture = MedaUI:GetBarTexture(entry.id),
                }
            end
            if #fillTexOptions > 0 then
                local fillTexDropdown = MedaUI:CreateLabeledDropdown(p, "Fill Texture", 240, fillTexOptions, "fill")
                fillTexDropdown:SetPoint("TOPLEFT", LEFT_X, yOff)
                fillTexDropdown:SetSelected(db.orbFillTexture or "solid")
                fillTexDropdown.OnValueChanged = function(_, value) db.orbFillTexture = value; OnManaEvent(db) end
            end
        end
    end

    -- ===== Text & Colors Tab =====
    do
        local p = tabs["textcolors"]
        local yOff = 0

        local colorHdr = MedaUI:CreateSectionHeader(p, "Colors")
        colorHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 40

        local mc = db.manaColor or DEFAULT_MANA_COLOR
        local manaColorPicker = MedaUI:CreateLabeledColorPicker(p, "Mana Color", nil, true)
        manaColorPicker:SetPoint("TOPLEFT", LEFT_X, yOff)
        manaColorPicker:SetColor(mc[1], mc[2], mc[3], mc[4] or 1)
        manaColorPicker.OnColorChanged = function(_, r, g, b, a)
            db.manaColor = { r, g, b, a }
            colorCurveColor = nil
            EnsureColorCurve(db.manaColor)
            OnManaEvent(db)
        end
        local bgc = db.backgroundColor or DEFAULT_BG_COLOR
        local bgColorPicker = MedaUI:CreateLabeledColorPicker(p, "Background Color", nil, false)
        bgColorPicker:SetPoint("TOPLEFT", RIGHT_X, yOff)
        bgColorPicker:SetColor(bgc[1], bgc[2], bgc[3], bgc[4] or 1)
        bgColorPicker.OnColorChanged = function(_, r, g, b, a)
            db.backgroundColor = { r, g, b, a or 1 }
            OnManaEvent(db)
        end
        yOff = yOff - 35

        local bgSlider = MedaUI:CreateLabeledSlider(p, "Background Opacity", 200, 0, 100, 1)
        bgSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
        bgSlider:SetValue((db.backgroundOpacity or 0.8) * 100)
        bgSlider.OnValueChanged = function(_, value)
            db.backgroundOpacity = value / 100
            OnManaEvent(db)
        end
        yOff = yOff - 55

        local textHdr = MedaUI:CreateSectionHeader(p, "Text")
        textHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 40

        local showTextCb = MedaUI:CreateCheckbox(p, "Show Text")
        showTextCb:SetPoint("TOPLEFT", LEFT_X, yOff)
        showTextCb:SetChecked(db.showText)
        showTextCb.OnValueChanged = function(_, checked) db.showText = checked; OnManaEvent(db) end
        local showPctCb = MedaUI:CreateCheckbox(p, "Show Percentage")
        showPctCb:SetPoint("TOPLEFT", RIGHT_X, yOff)
        showPctCb:SetChecked(db.showPercentage)
        showPctCb.OnValueChanged = function(_, checked) db.showPercentage = checked; OnManaEvent(db) end
        yOff = yOff - 30

        local textSizeSlider = MedaUI:CreateLabeledSlider(p, "Text Size", 200, 8, 28, 1)
        textSizeSlider:SetPoint("TOPLEFT", LEFT_X, yOff)
        textSizeSlider:SetValue(db.textSize or 14)
        textSizeSlider.OnValueChanged = function(_, value) db.textSize = value; OnManaEvent(db) end
        local anchorOptions = {
            { value = "CENTER", label = "Center" },
            { value = "TOP", label = "Top" },
            { value = "BOTTOM", label = "Bottom" },
            { value = "LEFT", label = "Left" },
            { value = "RIGHT", label = "Right" },
        }
        local anchorDropdown = MedaUI:CreateLabeledDropdown(p, "Text Anchor", 160, anchorOptions)
        anchorDropdown:SetPoint("TOPLEFT", RIGHT_X, yOff)
        anchorDropdown:SetSelected(db.textAnchor or "CENTER")
        anchorDropdown.OnValueChanged = function(_, value) db.textAnchor = value; OnManaEvent(db) end
        yOff = yOff - 55

        local xOffsetBox = MedaUI:CreateLabeledEditBox(p, "X Offset", 60)
        xOffsetBox:SetPoint("TOPLEFT", LEFT_X, yOff)
        xOffsetBox:SetText(tostring(db.textOffsetX or 0))
        local function ApplyXOffset(text)
            local val = tonumber(text)
            if val then db.textOffsetX = val; OnManaEvent(db) end
        end
        xOffsetBox.OnEnterPressed = function(_, text) ApplyXOffset(text) end
        local xInner = xOffsetBox:GetControl()
        if xInner and xInner.OnTextChanged ~= nil then
            xInner.OnTextChanged = function(_, text) ApplyXOffset(text) end
        end
        local yOffsetBox = MedaUI:CreateLabeledEditBox(p, "Y Offset", 60)
        yOffsetBox:SetPoint("TOPLEFT", RIGHT_X, yOff)
        yOffsetBox:SetText(tostring(db.textOffsetY or 0))
        local function ApplyYOffset(text)
            local val = tonumber(text)
            if val then db.textOffsetY = val; OnManaEvent(db) end
        end
        yOffsetBox.OnEnterPressed = function(_, text) ApplyYOffset(text) end
        local yInner = yOffsetBox:GetControl()
        if yInner and yInner.OnTextChanged ~= nil then
            yInner.OnTextChanged = function(_, text) ApplyYOffset(text) end
        end
        yOff = yOff - 50

    end

    MedaAuras:SetContentHeight(500)

    local sentinel = CreateFrame("Frame", nil, parent)
    sentinel:SetSize(1, 1)
    sentinel:SetPoint("TOPLEFT")
    sentinel:Show()
    sentinel:SetScript("OnHide", function()
        DestroyPreview()
    end)
end

-- ============================================================================
-- Register Module
-- ============================================================================

MedaAuras:RegisterModule({
    name = MODULE_NAME,
    title = "Mana Tracker",
    version = MODULE_VERSION,
    stability = MODULE_STABILITY,
    author = "Medalink",
    description = "Displays your mana regardless of form or combat state.",
    sidebarDesc = "Displays your mana regardless of current form or combat state.",
    defaults = MODULE_DEFAULTS,
    OnInitialize = OnInitialize,
    OnEnable = OnEnable,
    OnDisable = OnDisable,
    pages = {
        { id = "settings", label = "Settings" },
    },
    buildPage = function(_, parent)
        BuildSettingsPage(parent, MedaAuras:GetModuleDB(MODULE_NAME))
        return 760
    end,
})
