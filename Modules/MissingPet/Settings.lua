local _, ns = ...

local MedaUI = LibStub("MedaUI-2.0")

local CreateFrame = CreateFrame
local unpack = unpack

local M = ns.MissingPet or {}
ns.MissingPet = M

local function Trim(text)
    text = tostring(text or "")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

function M.BuildSettingsPage(parent, moduleDB)
    if not moduleDB then
        return
    end

    local LEFT_X = 0
    local RIGHT_X = 248
    local yOff = 0
    local statusText

    local function RefreshStatus()
        if not statusText or not M.GetStatusSummary then
            return
        end

        local message, color = M.GetStatusSummary()
        statusText:SetText(message or "")
        if color then
            statusText:SetTextColor(unpack(color))
        else
            statusText:SetTextColor(unpack(MedaUI.Theme.textDim))
        end
    end

    local function RefreshRuntime()
        if M.RefreshRuntime then
            M.RefreshRuntime(moduleDB)
        end
        RefreshStatus()
    end

    if M.SetPreview then
        M.SetPreview(true, moduleDB)
    end

    local header = MedaUI:CreateSectionHeader(parent, "Missing Pet")
    header:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 42

    local enableCB = MedaUI:CreateCheckbox(parent, "Enable Module")
    enableCB:SetPoint("TOPLEFT", LEFT_X, yOff)
    enableCB:SetChecked(moduleDB.enabled)
    enableCB.OnValueChanged = function(_, checked)
        if checked then
            MedaAuras:EnableModule(M.MODULE_NAME)
        else
            MedaAuras:DisableModule(M.MODULE_NAME)
        end
        MedaAuras:RefreshSidebarDot(M.MODULE_NAME)
        RefreshRuntime()
    end

    local lockCB = MedaUI:CreateCheckbox(parent, "Lock Position")
    lockCB:SetPoint("TOPLEFT", RIGHT_X, yOff)
    lockCB:SetChecked(moduleDB.locked)
    lockCB.OnValueChanged = function(_, checked)
        moduleDB.locked = checked
        RefreshRuntime()
    end
    yOff = yOff - 34

    local onlyCombatCB = MedaUI:CreateCheckbox(parent, "Only Show In Combat")
    onlyCombatCB:SetPoint("TOPLEFT", LEFT_X, yOff)
    onlyCombatCB:SetChecked(moduleDB.onlyInCombat)
    onlyCombatCB.OnValueChanged = function(_, checked)
        moduleDB.onlyInCombat = checked
        RefreshRuntime()
    end
    yOff = yOff - 34

    local previewText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    previewText:SetPoint("TOPLEFT", LEFT_X, yOff)
    previewText:SetWidth(500)
    previewText:SetJustifyH("LEFT")
    previewText:SetWordWrap(true)
    previewText:SetTextColor(unpack(MedaUI.Theme.textDim))
    previewText:SetText("Live preview is shown while this page is open. The explicit pet-user list currently covers Hunters, Warlocks, Unholy Death Knights, and Frost Mages with Summon Water Elemental. Missing-pet warnings use the custom reminder text below; raid and dungeon taunt warnings use a built-in taunt alert.")
    yOff = yOff - 48

    statusText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusText:SetPoint("TOPLEFT", LEFT_X, yOff)
    statusText:SetWidth(500)
    statusText:SetJustifyH("LEFT")
    statusText:SetWordWrap(true)
    yOff = yOff - 36

    local reminderBox = MedaUI:CreateLabeledEditBox(parent, "Missing Pet Text", 240)
    reminderBox:SetPoint("TOPLEFT", LEFT_X, yOff)
    reminderBox:SetText(moduleDB.text or M.DEFAULT_TEXT)

    local sizeSlider = MedaUI:CreateLabeledSlider(parent, "Text Size", 200, 12, 48, 1)
    sizeSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
    sizeSlider:SetValue(moduleDB.textSize or 30)
    sizeSlider.OnValueChanged = function(_, value)
        moduleDB.textSize = value
        RefreshRuntime()
    end
    yOff = yOff - 58

    local colorPicker = MedaUI:CreateLabeledColorPicker(parent, "Text Color", nil, true)
    colorPicker:SetPoint("TOPLEFT", LEFT_X, yOff)
    local color = moduleDB.color or { 1.0, 0.28, 0.28, 1.0 }
    colorPicker:SetColor(color[1], color[2], color[3], color[4] or 1)
    colorPicker.OnColorChanged = function(_, r, g, b, a)
        moduleDB.color = { r, g, b, a or 1 }
        RefreshRuntime()
    end

    local function ApplyReminderText(text)
        local value = Trim(text)
        if value == "" then
            value = M.DEFAULT_TEXT
        end
        moduleDB.text = value
        RefreshRuntime()
    end

    reminderBox.OnEnterPressed = function(_, text)
        ApplyReminderText(text)
    end

    local reminderControl = reminderBox:GetControl()
    if reminderControl and reminderControl.OnTextChanged ~= nil then
        reminderControl.OnTextChanged = function(_, text)
            ApplyReminderText(text)
        end
    end

    RefreshRuntime()
    MedaAuras:SetContentHeight(M.PAGE_HEIGHT)

    local sentinel = CreateFrame("Frame", nil, parent)
    sentinel:SetSize(1, 1)
    sentinel:SetPoint("TOPLEFT")
    sentinel:Show()
    sentinel:SetScript("OnHide", function()
        if M.SetPreview then
            M.SetPreview(false, moduleDB)
        end
    end)
end
