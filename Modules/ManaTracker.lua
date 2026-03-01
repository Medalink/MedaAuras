local _, ns = ...

local MedaUI = LibStub("MedaUI-1.0")

-- ============================================================================
-- Constants
-- ============================================================================

local PREFIX = "[ManaTracker]"
local Enum_PowerType_Mana = Enum.PowerType.Mana
local MANA_TOKEN = "MANA"

local LOW_COLOR = { 0.8, 0.1, 0.1, 1.0 }
local MEDIUM_COLOR = { 0.9, 0.5, 0.0, 1.0 }
local DEFAULT_BG_COLOR = { 0.1, 0.1, 0.2, 1.0 }
local DEFAULT_BORDER_COLOR = { 0.2, 0.4, 0.7, 1.0 }

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
    d:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
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
    outerBorder:SetFrameLevel(math.max(d:GetFrameLevel() - 1, 0))
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
    local manaColor = db.manaColor or { 0.0, 0.56, 1.0, 1.0 }

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
        local obc = db.outerBorderColor or { 0, 0, 0, 1 }
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
    local obc = db.outerBorderColor or { 0, 0, 0, 1 }
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
    local manaColor = db.manaColor or { 0.0, 0.56, 1.0, 1.0 }

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
        local obc = db.outerBorderColor or { 0, 0, 0, 1 }
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
    UpdatePreview(db)
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
    EnsureColorCurve(db.manaColor or { 0.0, 0.56, 1.0, 1.0 })

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

    EnsureColorCurve(db.manaColor or { 0.0, 0.56, 1.0, 1.0 })
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
    backgroundColor = { 0.1, 0.1, 0.2, 1.0 },
    manaColor = { 0.0, 0.56, 1.0, 1.0 },
    borderColor = { 0.2, 0.4, 0.7, 1.0 },
    backgroundOpacity = 0.8,
    showBorder = true,
    showOuterBorder = true,
    outerBorderSize = 2,
    outerBorderColor = { 0.0, 0.0, 0.0, 1.0 },
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

local function BuildConfig(parent, db)
    local yOff = 0
    local mode = db.displayMode or "bar"
    local isBar = (mode == "bar")

    DestroyPreview()

    -- Display Mode
    local _, _, modeHeader = MedaUI:CreateSectionHeader(parent, "Display")
    modeHeader:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 40

    local modeOptions = {
        { value = "bar", label = "Bar" },
        { value = "orb", label = "Orb" },
    }
    local modeDropdown = MedaUI:CreateDropdown(parent, 160, modeOptions)
    modeDropdown:SetPoint("TOPLEFT", 0, yOff)
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

    local modeLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    modeLabel:SetPoint("LEFT", modeDropdown, "RIGHT", 10, 0)
    modeLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
    modeLabel:SetText("Display Mode")
    yOff = yOff - 40

    -- Lock
    local lockCb = MedaUI:CreateCheckbox(parent, "Lock Frame")
    lockCb:SetPoint("TOPLEFT", 0, yOff)
    lockCb:SetChecked(db.locked)
    lockCb.OnValueChanged = function(_, checked)
        db.locked = checked
        UpdateLock(db)
    end
    yOff = yOff - 35

    -- === Floating Side Preview ===
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

            local pvInner = CreateFrame("Frame", nil, pvBg)
            pvInner:SetPoint("CENTER", 0, 0)
            pvBg.inner = pvInner

            previewContainer = pvBg
            pvBg:Show()
            CreatePreviewDisplay(db)
            UpdatePreview(db)
        end
    end

    -- === Border settings (near preview for real-time feedback) ===
    local _, _, borderHeader = MedaUI:CreateSectionHeader(parent, "Border")
    borderHeader:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 40

    local showBorderCb = MedaUI:CreateCheckbox(parent, "Show Border")
    showBorderCb:SetPoint("TOPLEFT", 0, yOff)
    showBorderCb:SetChecked(db.showBorder ~= false)
    showBorderCb.OnValueChanged = function(_, checked)
        db.showBorder = checked
        OnManaEvent(db)
    end
    yOff = yOff - 30

    local bc = db.borderColor or DEFAULT_BORDER_COLOR
    local borderColorPicker = MedaUI:CreateColorPicker(parent, 24, 24, true)
    borderColorPicker:SetPoint("TOPLEFT", 0, yOff)
    borderColorPicker:SetColor(bc[1], bc[2], bc[3], bc[4] or 1)
    borderColorPicker:SetScript("OnColorChanged", function(_, r, g, b, a)
        db.borderColor = { r, g, b, a }
        OnManaEvent(db)
    end)
    local borderColorLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    borderColorLabel:SetPoint("LEFT", borderColorPicker, "RIGHT", 10, 0)
    borderColorLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
    borderColorLabel:SetText("Border Color")
    yOff = yOff - 35

    local showOuterBorderCb = MedaUI:CreateCheckbox(parent, "Show Outer Border")
    showOuterBorderCb:SetPoint("TOPLEFT", 0, yOff)
    showOuterBorderCb:SetChecked(db.showOuterBorder ~= false)
    showOuterBorderCb.OnValueChanged = function(_, checked)
        db.showOuterBorder = checked
        OnManaEvent(db)
    end
    yOff = yOff - 30

    local outerBorderSizeSlider = MedaUI:CreateSlider(parent, 200, 1, 10, 1)
    outerBorderSizeSlider:SetPoint("TOPLEFT", 0, yOff)
    outerBorderSizeSlider:SetValue(db.outerBorderSize or 2)
    outerBorderSizeSlider.OnValueChanged = function(_, value)
        db.outerBorderSize = value
        OnManaEvent(db)
    end
    local outerBorderSizeLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    outerBorderSizeLabel:SetPoint("LEFT", outerBorderSizeSlider, "RIGHT", 10, 0)
    outerBorderSizeLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
    outerBorderSizeLabel:SetText("Outer Border Size")
    yOff = yOff - 35

    local obc = db.outerBorderColor or { 0.0, 0.0, 0.0, 1.0 }
    local outerBorderColorPicker = MedaUI:CreateColorPicker(parent, 24, 24, true)
    outerBorderColorPicker:SetPoint("TOPLEFT", 0, yOff)
    outerBorderColorPicker:SetColor(obc[1], obc[2], obc[3], obc[4] or 1)
    outerBorderColorPicker:SetScript("OnColorChanged", function(_, r, g, b, a)
        db.outerBorderColor = { r, g, b, a }
        OnManaEvent(db)
    end)
    local outerBorderColorLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    outerBorderColorLabel:SetPoint("LEFT", outerBorderColorPicker, "RIGHT", 10, 0)
    outerBorderColorLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
    outerBorderColorLabel:SetText("Outer Border Color")
    yOff = yOff - 35

    -- === Bar-specific settings ===
    if isBar then
        local _, _, barHeader = MedaUI:CreateSectionHeader(parent, "Bar Settings")
        barHeader:SetPoint("TOPLEFT", 0, yOff)
        yOff = yOff - 40

        local widthSlider = MedaUI:CreateSlider(parent, 200, 50, 500, 1)
        widthSlider:SetPoint("TOPLEFT", 0, yOff)
        widthSlider:SetValue(db.width or DEFAULT_WIDTH)
        widthSlider.OnValueChanged = function(_, value)
            db.width = value
            OnManaEvent(db)
        end
        local widthLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        widthLabel:SetPoint("LEFT", widthSlider, "RIGHT", 10, 0)
        widthLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
        widthLabel:SetText("Width")
        yOff = yOff - 35

        local heightSlider = MedaUI:CreateSlider(parent, 200, 8, 100, 1)
        heightSlider:SetPoint("TOPLEFT", 0, yOff)
        heightSlider:SetValue(db.height or DEFAULT_HEIGHT)
        heightSlider.OnValueChanged = function(_, value)
            db.height = value
            OnManaEvent(db)
        end
        local heightLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        heightLabel:SetPoint("LEFT", heightSlider, "RIGHT", 10, 0)
        heightLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
        heightLabel:SetText("Height")
        yOff = yOff - 35

        local orientOptions = {
            { value = "HORIZONTAL", label = "Horizontal" },
            { value = "VERTICAL", label = "Vertical" },
        }
        local orientDropdown = MedaUI:CreateDropdown(parent, 160, orientOptions)
        orientDropdown:SetPoint("TOPLEFT", 0, yOff)
        orientDropdown:SetSelected(db.barOrientation or "HORIZONTAL")
        orientDropdown.OnValueChanged = function(_, value)
            db.barOrientation = value
            OnManaEvent(db)
        end
        local orientLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        orientLabel:SetPoint("LEFT", orientDropdown, "RIGHT", 10, 0)
        orientLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
        orientLabel:SetText("Orientation")
        yOff = yOff - 40

        local barTexList = MedaUI:GetBarTextureList()
        local barTexOptions = {}
        for _, entry in ipairs(barTexList) do
            barTexOptions[#barTexOptions + 1] = {
                value = entry.id,
                label = entry.name,
                texture = MedaUI:GetBarTexture(entry.id),
            }
        end
        if #barTexOptions > 0 then
            local barTexLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            barTexLabel:SetPoint("TOPLEFT", 0, yOff)
            barTexLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
            barTexLabel:SetText("Bar Texture")
            yOff = yOff - 18
            local barTexDropdown = MedaUI:CreateDropdown(parent, 240, barTexOptions, "fill")
            barTexDropdown:SetPoint("TOPLEFT", 0, yOff)
            barTexDropdown:SetSelected(db.barTexture or "solid")
            barTexDropdown.OnValueChanged = function(_, value)
                db.barTexture = value
                OnManaEvent(db)
            end
            yOff = yOff - 32
        end
    end

    -- === Orb-specific settings ===
    if not isBar then
        local _, _, orbHeader = MedaUI:CreateSectionHeader(parent, "Orb Settings")
        orbHeader:SetPoint("TOPLEFT", 0, yOff)
        yOff = yOff - 40

        local radiusSlider = MedaUI:CreateSlider(parent, 200, 16, 128, 1)
        radiusSlider:SetPoint("TOPLEFT", 0, yOff)
        radiusSlider:SetValue(db.orbRadius or (DEFAULT_ORB_SIZE / 2))
        radiusSlider.OnValueChanged = function(_, value)
            db.orbRadius = value
            OnManaEvent(db)
        end
        local radiusLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        radiusLabel:SetPoint("LEFT", radiusSlider, "RIGHT", 10, 0)
        radiusLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
        radiusLabel:SetText("Radius")
        yOff = yOff - 35

        local orbTexList = MedaUI:GetOrbTextureList()
        local orbTexOptions = {}
        for _, entry in ipairs(orbTexList) do
            local maskPath = MedaUI:GetOrbTextures(entry.id)
            orbTexOptions[#orbTexOptions + 1] = {
                value = entry.id,
                label = entry.name,
                texture = maskPath,
            }
        end
        if #orbTexOptions > 0 then
            local orbTexLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            orbTexLabel:SetPoint("TOPLEFT", 0, yOff)
            orbTexLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
            orbTexLabel:SetText("Orb Shape")
            yOff = yOff - 18
            local orbTexDropdown = MedaUI:CreateDropdown(parent, 180, orbTexOptions, "preview")
            orbTexDropdown:SetPoint("TOPLEFT", 0, yOff)
            orbTexDropdown:SetSelected(db.orbTexture or "solid")
            orbTexDropdown.OnValueChanged = function(_, value)
                db.orbTexture = value
                if display and display.mode == "orb" then
                    CreateDisplay(db)
                    OnManaEvent(db)
                end
            end
            yOff = yOff - 56
        end

        local fillTexList = MedaUI:GetBarTextureList()
        local fillTexOptions = {}
        for _, entry in ipairs(fillTexList) do
            fillTexOptions[#fillTexOptions + 1] = {
                value = entry.id,
                label = entry.name,
                texture = MedaUI:GetBarTexture(entry.id),
            }
        end
        if #fillTexOptions > 0 then
            local fillTexLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fillTexLabel:SetPoint("TOPLEFT", 0, yOff)
            fillTexLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
            fillTexLabel:SetText("Fill Texture")
            yOff = yOff - 18
            local fillTexDropdown = MedaUI:CreateDropdown(parent, 240, fillTexOptions, "fill")
            fillTexDropdown:SetPoint("TOPLEFT", 0, yOff)
            fillTexDropdown:SetSelected(db.orbFillTexture or "solid")
            fillTexDropdown.OnValueChanged = function(_, value)
                db.orbFillTexture = value
                OnManaEvent(db)
            end
            yOff = yOff - 32
        end
    end

    -- === Shared settings: Colors ===
    local _, _, colorHeader = MedaUI:CreateSectionHeader(parent, "Colors")
    colorHeader:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 40

    local mc = db.manaColor or { 0.0, 0.56, 1.0, 1.0 }
    local manaColorPicker = MedaUI:CreateColorPicker(parent, 24, 24, true)
    manaColorPicker:SetPoint("TOPLEFT", 0, yOff)
    manaColorPicker:SetColor(mc[1], mc[2], mc[3], mc[4] or 1)
    manaColorPicker:SetScript("OnColorChanged", function(_, r, g, b, a)
        db.manaColor = { r, g, b, a }
        colorCurveColor = nil
        EnsureColorCurve(db.manaColor)
        OnManaEvent(db)
    end)
    local manaColorLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    manaColorLabel:SetPoint("LEFT", manaColorPicker, "RIGHT", 10, 0)
    manaColorLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
    manaColorLabel:SetText("Mana Color")
    yOff = yOff - 35

    local bgc = db.backgroundColor or DEFAULT_BG_COLOR
    local bgColorPicker = MedaUI:CreateColorPicker(parent, 24, 24, false)
    bgColorPicker:SetPoint("TOPLEFT", 0, yOff)
    bgColorPicker:SetColor(bgc[1], bgc[2], bgc[3], bgc[4] or 1)
    bgColorPicker:SetScript("OnColorChanged", function(_, r, g, b, a)
        db.backgroundColor = { r, g, b, a or 1 }
        OnManaEvent(db)
    end)
    local bgColorLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bgColorLabel:SetPoint("LEFT", bgColorPicker, "RIGHT", 10, 0)
    bgColorLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
    bgColorLabel:SetText("Background Color")
    yOff = yOff - 35

    local bgSlider = MedaUI:CreateSlider(parent, 200, 0, 100, 1)
    bgSlider:SetPoint("TOPLEFT", 0, yOff)
    bgSlider:SetValue((db.backgroundOpacity or 0.8) * 100)
    bgSlider.OnValueChanged = function(_, value)
        db.backgroundOpacity = value / 100
        OnManaEvent(db)
    end
    local bgLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bgLabel:SetPoint("LEFT", bgSlider, "RIGHT", 10, 0)
    bgLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
    bgLabel:SetText("Background Opacity")
    yOff = yOff - 40

    -- === Shared settings: Text ===
    local _, _, textHeader = MedaUI:CreateSectionHeader(parent, "Text")
    textHeader:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 40

    local showTextCb = MedaUI:CreateCheckbox(parent, "Show Text")
    showTextCb:SetPoint("TOPLEFT", 0, yOff)
    showTextCb:SetChecked(db.showText)
    showTextCb.OnValueChanged = function(_, checked)
        db.showText = checked
        OnManaEvent(db)
    end
    yOff = yOff - 30

    local showPctCb = MedaUI:CreateCheckbox(parent, "Show Percentage")
    showPctCb:SetPoint("TOPLEFT", 0, yOff)
    showPctCb:SetChecked(db.showPercentage)
    showPctCb.OnValueChanged = function(_, checked)
        db.showPercentage = checked
        OnManaEvent(db)
    end
    yOff = yOff - 30

    local textSizeSlider = MedaUI:CreateSlider(parent, 200, 8, 28, 1)
    textSizeSlider:SetPoint("TOPLEFT", 0, yOff)
    textSizeSlider:SetValue(db.textSize or 14)
    textSizeSlider.OnValueChanged = function(_, value)
        db.textSize = value
        OnManaEvent(db)
    end
    local textSizeLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    textSizeLabel:SetPoint("LEFT", textSizeSlider, "RIGHT", 10, 0)
    textSizeLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
    textSizeLabel:SetText("Text Size")
    yOff = yOff - 35

    local anchorOptions = {
        { value = "CENTER", label = "Center" },
        { value = "TOP", label = "Top" },
        { value = "BOTTOM", label = "Bottom" },
        { value = "LEFT", label = "Left" },
        { value = "RIGHT", label = "Right" },
    }
    local anchorDropdown = MedaUI:CreateDropdown(parent, 160, anchorOptions)
    anchorDropdown:SetPoint("TOPLEFT", 0, yOff)
    anchorDropdown:SetSelected(db.textAnchor or "CENTER")
    anchorDropdown.OnValueChanged = function(_, value)
        db.textAnchor = value
        OnManaEvent(db)
    end
    local anchorLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    anchorLabel:SetPoint("LEFT", anchorDropdown, "RIGHT", 10, 0)
    anchorLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
    anchorLabel:SetText("Text Anchor")
    yOff = yOff - 40

    local xOffsetBox = MedaUI:CreateEditBox(parent, 60, 24)
    xOffsetBox:SetPoint("TOPLEFT", 0, yOff)
    xOffsetBox:SetText(tostring(db.textOffsetX or 0))
    local function ApplyXOffset(text)
        local val = tonumber(text)
        if val then
            db.textOffsetX = val
            OnManaEvent(db)
        end
    end
    xOffsetBox.OnEnterPressed = function(_, text) ApplyXOffset(text) end
    xOffsetBox.OnTextChanged = function(_, text) ApplyXOffset(text) end
    local xOffsetLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    xOffsetLabel:SetPoint("LEFT", xOffsetBox, "RIGHT", 8, 0)
    xOffsetLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
    xOffsetLabel:SetText("Horizontal Offset")

    local yOffsetBox = MedaUI:CreateEditBox(parent, 60, 24)
    yOffsetBox:SetPoint("TOPLEFT", 180, yOff)
    yOffsetBox:SetText(tostring(db.textOffsetY or 0))
    local function ApplyYOffset(text)
        local val = tonumber(text)
        if val then
            db.textOffsetY = val
            OnManaEvent(db)
        end
    end
    yOffsetBox.OnEnterPressed = function(_, text) ApplyYOffset(text) end
    yOffsetBox.OnTextChanged = function(_, text) ApplyYOffset(text) end
    local yOffsetLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    yOffsetLabel:SetPoint("LEFT", yOffsetBox, "RIGHT", 8, 0)
    yOffsetLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
    yOffsetLabel:SetText("Vertical Offset")
    yOff = yOff - 35

    -- Reset
    local resetBtn = MedaUI:CreateButton(parent, "Reset to Defaults")
    resetBtn:SetPoint("TOPLEFT", 0, yOff)
    resetBtn:SetScript("OnClick", function()
        for k, v in pairs(MODULE_DEFAULTS) do
            db[k] = MedaAuras.DeepCopy(v)
        end
        MedaAuras:ToggleSettings()
        MedaAuras:ToggleSettings()
    end)
    yOff = yOff - 45

    MedaAuras:SetContentHeight(math.abs(yOff))

    -- Sentinel: when the config page is cleared, hide the floating preview
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
    name = "ManaTracker",
    title = "Mana Tracker",
    description = "Displays your mana regardless of form or combat state.",
    defaults = MODULE_DEFAULTS,
    OnInitialize = OnInitialize,
    OnEnable = OnEnable,
    OnDisable = OnDisable,
    BuildConfig = BuildConfig,
})
