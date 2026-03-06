local frame
local text
local isEnabled = false

local function ApplyVisuals(db)
    if not frame then return end

    frame:SetScale(db.scale or 1)
    frame:ClearAllPoints()
    frame:SetPoint(db.point or "CENTER", UIParent, db.relativePoint or "CENTER", db.x or 0, db.y or 0)

    frame:SetShown(db.showFrame ~= false and isEnabled)

    if text then
        text:SetText(db.message or "Hello from custom modules!")
        text:SetTextColor(
            (db.color and db.color.r) or 0.35,
            (db.color and db.color.g) or 0.85,
            (db.color and db.color.b) or 1.0
        )
    end
end

local function EnsureFrame(db)
    if frame then
        return
    end

    frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    frame:SetSize(260, 56)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    frame:SetBackdropColor(0.05, 0.05, 0.08, 0.92)
    frame:SetBackdropBorderColor(0.2, 0.6, 0.9, 0.9)

    text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetPoint("CENTER")

    frame:SetScript("OnDragStart", function(self)
        if db.locked then
            return
        end
        self:StartMoving()
    end)

    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint(1)
        db.point = point
        db.relativePoint = relativePoint
        db.x = x
        db.y = y
    end)
end

local function OnInitialize(db)
    EnsureFrame(db)
    ApplyVisuals(db)
end

local function OnEnable(db)
    isEnabled = true
    EnsureFrame(db)
    ApplyVisuals(db)
end

local function OnDisable(db)
    isEnabled = false
    if frame then
        frame:Hide()
    end
end

local function BuildConfig(parent, db)
    local yOff = 0

    local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 0, yOff)
    header:SetText("Hello Sample Settings")
    yOff = yOff - 32

    local desc = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", 0, yOff)
    desc:SetPoint("RIGHT", -10, 0)
    desc:SetJustifyH("LEFT")
    desc:SetText("A simple sample custom module. Drag the frame around when unlocked.")
    yOff = yOff - 34

    local messageLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    messageLabel:SetPoint("TOPLEFT", 0, yOff)
    messageLabel:SetText("Message")
    yOff = yOff - 20

    local messageBox = MedaUI:CreateEditBox(parent, 320, 24)
    messageBox:SetPoint("TOPLEFT", 0, yOff)
    messageBox:SetText(db.message or "")
    messageBox.OnEnterPressed = function(self)
        db.message = self:GetText()
        ApplyVisuals(db)
    end
    yOff = yOff - 36

    local showCheck = MedaUI:CreateCheckbox(parent, "Show Frame")
    showCheck:SetPoint("TOPLEFT", 0, yOff)
    showCheck:SetChecked(db.showFrame ~= false)
    showCheck.OnValueChanged = function(_, checked)
        db.showFrame = checked
        ApplyVisuals(db)
    end
    yOff = yOff - 28

    local lockCheck = MedaUI:CreateCheckbox(parent, "Lock Position")
    lockCheck:SetPoint("TOPLEFT", 0, yOff)
    lockCheck:SetChecked(db.locked == true)
    lockCheck.OnValueChanged = function(_, checked)
        db.locked = checked
    end
    yOff = yOff - 28

    local scaleLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    scaleLabel:SetPoint("TOPLEFT", 0, yOff)
    scaleLabel:SetText("Scale")
    yOff = yOff - 20

    local scaleBox = MedaUI:CreateEditBox(parent, 120, 24)
    scaleBox:SetPoint("TOPLEFT", 0, yOff)
    scaleBox:SetText(tostring(db.scale or 1))
    scaleBox.OnEnterPressed = function(self)
        local value = tonumber(self:GetText())
        if value and value > 0.5 and value < 3 then
            db.scale = value
            ApplyVisuals(db)
        else
            self:SetText(tostring(db.scale or 1))
        end
    end
    yOff = yOff - 40

    MedaAuras:SetContentHeight(math.abs(yOff) + 40)
end

MedaAuras.RegisterCustomModule({
    moduleId = "hello-sample-module-v1",
    name = "HelloSampleModule",
    title = "Hello Sample Module",
    version = "v1.0",
    description = "A sample custom module that shows a movable message frame.",
    dataVersion = 1,
    defaults = {
        enabled = false,
        locked = false,
        showFrame = true,
        message = "Hello from custom modules!",
        scale = 1,
        point = "CENTER",
        relativePoint = "CENTER",
        x = 0,
        y = 180,
        color = {
            r = 0.35,
            g = 0.85,
            b = 1.0,
        },
    },
    OnInitialize = OnInitialize,
    OnEnable = OnEnable,
    OnDisable = OnDisable,
    BuildConfig = BuildConfig,
    MigrateData = function(db, fromDataVersion, toDataVersion)
        if fromDataVersion < 1 and toDataVersion >= 1 then
            db.scale = db.scale or 1
        end
    end,
})
