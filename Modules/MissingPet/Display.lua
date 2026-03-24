local _, ns = ...

local MedaUI = LibStub("MedaUI-2.0")

local CreateFrame = CreateFrame
local max = math.max

local M = ns.MissingPet or {}
ns.MissingPet = M

local displayFrame
local messageText

local function EnsureDisplayFrame()
    if displayFrame then
        return displayFrame
    end

    displayFrame = CreateFrame("Frame", "MedaAurasMissingPetFrame", UIParent)
    displayFrame:SetFrameStrata("HIGH")
    displayFrame:SetClampedToScreen(true)
    displayFrame:SetMovable(true)
    displayFrame:RegisterForDrag("LeftButton")
    displayFrame:SetAlpha(1)

    messageText = displayFrame:CreateFontString(nil, "OVERLAY")
    messageText:SetPoint("CENTER")
    messageText:SetJustifyH("CENTER")
    messageText:SetJustifyV("MIDDLE")
    messageText:SetShadowOffset(1, -1)
    messageText:SetShadowColor(0, 0, 0, 1)

    displayFrame.pulse = displayFrame:CreateAnimationGroup()
    displayFrame.pulse:SetLooping("REPEAT")

    local fadeOut = displayFrame.pulse:CreateAnimation("Alpha")
    fadeOut:SetOrder(1)
    fadeOut:SetDuration(0.55)
    fadeOut:SetFromAlpha(1.0)
    fadeOut:SetToAlpha(0.35)
    fadeOut:SetSmoothing("IN_OUT")

    local fadeIn = displayFrame.pulse:CreateAnimation("Alpha")
    fadeIn:SetOrder(2)
    fadeIn:SetDuration(0.55)
    fadeIn:SetFromAlpha(0.35)
    fadeIn:SetToAlpha(1.0)
    fadeIn:SetSmoothing("IN_OUT")

    displayFrame:SetScript("OnDragStart", function(self)
        local db = M.GetDB and M.GetDB()
        if db and not db.locked then
            self:StartMoving()
        end
    end)

    displayFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()

        local db = M.GetDB and M.GetDB()
        if not db then
            return
        end

        local point, _, _, x, y = self:GetPoint()
        db.position = db.position or {}
        db.position.point = point or "CENTER"
        db.position.x = x or 0
        db.position.y = y or 0
    end)

    return displayFrame
end

local function ApplyPosition(db)
    local frame = EnsureDisplayFrame()
    local position = (db and db.position) or (M.DEFAULTS and M.DEFAULTS.position) or { point = "CENTER", x = 0, y = 220 }

    frame:ClearAllPoints()
    frame:SetPoint(
        position.point or "CENTER",
        UIParent,
        position.point or "CENTER",
        position.x or 0,
        position.y or 0
    )
end

local function ApplyAppearance(db)
    local frame = EnsureDisplayFrame()
    local fontPath = MedaUI:GetFontPath((db and db.font) or "default") or M.DEFAULT_FONT
    local textSize = (db and db.textSize) or 30
    local color = (db and db.color) or { 1.0, 0.28, 0.28, 1.0 }
    local alpha = color[4] or 1
    local text = (M.GetReminderText and M.GetReminderText()) or (db and db.text) or M.DEFAULT_TEXT

    if text == "" then
        text = M.DEFAULT_TEXT
    end

    messageText:SetFont(fontPath, textSize, "OUTLINE")
    messageText:SetTextColor(color[1] or 1, color[2] or 1, color[3] or 1, alpha)
    messageText:SetText(text)

    frame:SetSize(
        max(messageText:GetStringWidth() + 24, 120),
        max(messageText:GetStringHeight() + 16, 42)
    )
    frame:EnableMouse(db and not db.locked or false)
end

function M.RefreshDisplay()
    local db = M.GetDB and M.GetDB()
    local frame = EnsureDisplayFrame()

    ApplyPosition(db)
    ApplyAppearance(db)

    if M.ShouldShowReminder and M.ShouldShowReminder() then
        if frame.pulse and not frame.pulse:IsPlaying() then
            frame.pulse:Play()
        end
        frame:Show()
    else
        if frame.pulse and frame.pulse:IsPlaying() then
            frame.pulse:Stop()
        end
        frame:SetAlpha(1)
        frame:Hide()
    end
end
