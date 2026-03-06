local _, ns = ...

local MedaUI = LibStub("MedaUI-1.0")

local format = format
local pairs = pairs
local ipairs = ipairs
local wipe = wipe
local unpack = unpack
local CreateFrame = CreateFrame
local UnitExists = UnitExists

local MODULE_NAME = "LazyCast"
local MODULE_VERSION = "1.0"
local MODULE_STABILITY = "beta"

-- ============================================================================
-- Keybinding Globals
-- ============================================================================

BINDING_HEADER_MEDAAURAS = "MedaAuras"
BINDING_NAME_CLICK_MedaAurasLazyCast1_LeftButton = "Lazy Cast Slot 1"
BINDING_NAME_CLICK_MedaAurasLazyCast2_LeftButton = "Lazy Cast Slot 2"

-- ============================================================================
-- Constants
-- ============================================================================

local NUM_SLOTS = 2

local ROLE_OPTIONS = {
    { value = "TANK",    label = "Tank" },
    { value = "HEALER",  label = "Healer" },
    { value = "DAMAGER", label = "Damager" },
    { value = "PET",     label = "Pet" },
    { value = "PLAYER",  label = "Self" },
}

local ROLE_LABELS = {}
for _, opt in ipairs(ROLE_OPTIONS) do
    ROLE_LABELS[opt.value] = opt.label
end

-- ============================================================================
-- Module Defaults
-- ============================================================================

local MODULE_DEFAULTS = {
    enabled = false,
    slots = {
        { spellName = "", role = "TANK", selfFallback = false },
        { spellName = "", role = "TANK", selfFallback = false },
    },
}

-- ============================================================================
-- SecureActionButtons (created at load time for Bindings.xml stability)
-- ============================================================================

local buttons = {}
for i = 1, NUM_SLOTS do
    local btn = CreateFrame("Button", "MedaAurasLazyCast" .. i, UIParent, "SecureActionButtonTemplate")
    btn:SetAttribute("type", "spell")
    btn:RegisterForClicks("AnyDown", "AnyUp")
    btn:SetSize(1, 1)
    btn:SetAlpha(0)
    btn:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10, 10)

    buttons[i] = btn
end

-- ============================================================================
-- Role-Based Unit Scanner
-- ============================================================================

local function FindPetUnits()
    local primary, fallback = nil, nil

    if UnitExists("pet") and not UnitIsDeadOrGhost("pet") then
        primary = "pet"
    end

    local prefix, count
    if IsInRaid() then
        prefix, count = "raidpet", GetNumGroupMembers()
    elseif IsInGroup() then
        prefix, count = "partypet", GetNumGroupMembers() - 1
    else
        return primary, nil
    end

    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) and not UnitIsDeadOrGhost(unit) then
            if not primary then
                primary = unit
            elseif not fallback then
                fallback = unit
                break
            end
        end
    end
    return primary, fallback
end

local function FindUnitsByRole(role)
    if role == "PLAYER" then return "player", nil end
    if role == "PET" then return FindPetUnits() end

    local primary, fallback = nil, nil
    local prefix, count
    if IsInRaid() then
        prefix, count = "raid", GetNumGroupMembers()
    elseif IsInGroup() then
        prefix, count = "party", GetNumGroupMembers() - 1
    else
        return nil, nil
    end

    for i = 1, count do
        local unit = prefix .. i
        if UnitGroupRolesAssigned(unit) == role and not UnitIsDeadOrGhost(unit) then
            if not primary then
                primary = unit
            else
                fallback = unit
                break
            end
        end
    end
    return primary, fallback
end

local function GetTargetName(role)
    local primary = FindUnitsByRole(role)
    if not primary then return nil end

    local name = UnitName(primary) or primary
    if role == "PET" then
        local ownerUnit = primary == "pet" and "player" or primary:gsub("pet", "")
        local ownerName = UnitName(ownerUnit)
        if ownerName then
            return format("%s (%s's pet)", name, ownerName)
        end
    end
    return name
end

-- ============================================================================
-- Macro Management
-- ============================================================================

local MACRO_PREFIX = "LazyCast"
local MACRO_ICON = "INV_MISC_QUESTIONMARK"
local MAX_PER_CHAR = 18

local function GetMacroName(slotIdx)
    return MACRO_PREFIX .. slotIdx
end

local function BuildMacroBody(slotIdx, spellName)
    local click = format("/click MedaAurasLazyCast%d LeftButton 1", slotIdx)
    if not spellName or spellName == "" then
        return click
    end
    return format("#showtooltip %s\n%s", spellName, click)
end

local function CreateOrUpdateMacro(slotIdx, spellName)
    if InCombatLockdown() then return false, "Cannot update macros in combat" end

    local name = GetMacroName(slotIdx)
    local body = BuildMacroBody(slotIdx, spellName)
    local existing = GetMacroIndexByName(name)

    if existing and existing > 0 then
        local ok, err = pcall(EditMacro, existing, name, MACRO_ICON, body)
        if not ok then
            MedaAuras.LogError(format("[LazyCast] EditMacro failed: %s", tostring(err)))
            return false, format("Failed to update macro: %s", tostring(err))
        end
        return true, format("Macro \"%s\" updated", name)
    end

    local numGlobal, numPerChar = GetNumMacros()
    local cap = MAX_CHARACTER_MACROS or MAX_PER_CHAR
    if numPerChar >= cap then
        return false, "Per-character macro slots full — delete one in /macro first"
    end

    local ok, result = pcall(CreateMacro, name, MACRO_ICON, body, 1)
    if not ok then
        MedaAuras.LogError(format("[LazyCast] CreateMacro failed: %s", tostring(result)))
        return false, format("Failed to create macro: %s", tostring(result))
    end

    print(format("|cff00ccffMedaAuras:|r LazyCast macro \"%s\" created for %s. Drag it to your action bar to replace the spell.", name, spellName))
    return true, format("Macro \"%s\" created", name)
end

-- ============================================================================
-- Button Attribute Updates
-- ============================================================================

local moduleDB

local function ResolveSpellID(spellName)
    if not spellName or spellName == "" then return nil end
    local info = C_Spell.GetSpellInfo(spellName)
    return info and info.spellID
end

local function UpdateAllButtons()
    if InCombatLockdown() then return end
    local db = moduleDB
    if not db then return end

    for i = 1, NUM_SLOTS do
        local slot = db.slots[i]
        if slot then
            local primary, fallback = FindUnitsByRole(slot.role)
            local unit = primary
            if not unit and slot.selfFallback then
                unit = "player"
            end

            buttons[i]:SetAttribute("unit-primary", primary)
            buttons[i]:SetAttribute("unit-fallback", fallback)
            buttons[i]:SetAttribute("unit", unit)
            buttons[i]:SetAttribute("spell", unit and ResolveSpellID(slot.spellName) or "")

            MedaAuras.LogDebug(format("[LazyCast] Slot %d: spell=%s unit=%s fallback=%s selfFB=%s",
                i, slot.spellName or "", tostring(unit), tostring(fallback),
                tostring(slot.selfFallback)))
        end
    end
end

local function ClearAllButtons()
    if InCombatLockdown() then return end
    for i = 1, NUM_SLOTS do
        buttons[i]:SetAttribute("unit-primary", nil)
        buttons[i]:SetAttribute("unit-fallback", nil)
        buttons[i]:SetAttribute("unit", nil)
        buttons[i]:SetAttribute("spell", "")
    end
end

-- ============================================================================
-- Event Handling
-- ============================================================================

local eventFrame = CreateFrame("Frame")

local function OnEvent()
    UpdateAllButtons()
end

local function RegisterEvents()
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:SetScript("OnEvent", OnEvent)
end

local function UnregisterEvents()
    eventFrame:UnregisterAllEvents()
    eventFrame:SetScript("OnEvent", nil)
end

-- ============================================================================
-- Module Lifecycle
-- ============================================================================

local function SyncMacros(db)
    if InCombatLockdown() then return end
    for i = 1, NUM_SLOTS do
        local slot = db.slots[i]
        if slot and slot.spellName and slot.spellName ~= "" then
            local ok, msg = CreateOrUpdateMacro(i, slot.spellName)
            if ok then
                MedaAuras.LogDebug(format("[LazyCast] SyncMacros: slot %d — %s", i, msg))
            else
                MedaAuras.LogWarn(format("[LazyCast] SyncMacros: slot %d — %s", i, msg))
            end
        end
    end
end

local function OnInitialize(db)
    moduleDB = db
    RegisterEvents()
    UpdateAllButtons()
    SyncMacros(db)
end

local function OnEnable(db)
    OnInitialize(db)
end

local function OnDisable()
    UnregisterEvents()
    ClearAllButtons()
    moduleDB = nil
end

-- ============================================================================
-- Settings UI
-- ============================================================================

local function BuildConfig(parent, db)
    local LEFT_X = 0
    local yOff = 0

    -- Header
    local headerContainer = MedaUI:CreateSectionHeader(parent, "Lazy Cast")
    headerContainer:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 45

    -- Enable checkbox
    local enableCB = MedaUI:CreateCheckbox(parent, "Enable Module")
    enableCB:SetPoint("TOPLEFT", LEFT_X, yOff)
    enableCB:SetChecked(db.enabled)
    enableCB.OnValueChanged = function(_, checked)
        if checked then
            MedaAuras:EnableModule(MODULE_NAME)
        else
            MedaAuras:DisableModule(MODULE_NAME)
        end
        MedaAuras:RefreshSidebarDot(MODULE_NAME)
    end
    yOff = yOff - 30

    -- Description
    local desc = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", LEFT_X, yOff)
    desc:SetWidth(460)
    desc:SetJustifyH("LEFT")
    desc:SetWordWrap(true)
    desc:SetTextColor(unpack(MedaUI.Theme.textDim))
    desc:SetText("Each slot casts a spell on the first alive group member matching the chosen role. Enter a spell name to auto-create a macro you can drag to your action bar.")
    yOff = yOff - 46

    -- Slot rows
    local statusLabels = {}

    for slotIdx = 1, NUM_SLOTS do
        local slot = db.slots[slotIdx]

        local slotHeader = MedaUI:CreateSectionHeader(parent, format("Slot %d", slotIdx))
        slotHeader:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 40

        -- Spell name input
        local spellInput = MedaUI:CreateLabeledEditBox(parent, "Spell Name", 200)
        spellInput:SetPoint("TOPLEFT", LEFT_X, yOff)
        spellInput:SetText(slot.spellName or "")

        -- Role dropdown
        local roleDropdown = MedaUI:CreateLabeledDropdown(parent, "Target Role", 160, ROLE_OPTIONS)
        roleDropdown:SetPoint("TOPLEFT", LEFT_X + 230, yOff)
        roleDropdown:SetSelected(slot.role)
        yOff = yOff - 60

        -- Self-fallback checkbox
        local selfCB = MedaUI:CreateCheckbox(parent, "Fallback to Self Cast")
        selfCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        selfCB:SetChecked(slot.selfFallback or false)
        selfCB.OnValueChanged = function(_, checked)
            slot.selfFallback = checked
            UpdateAllButtons()
        end
        yOff = yOff - 24

        local selfHint = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        selfHint:SetPoint("TOPLEFT", LEFT_X + 22, yOff)
        selfHint:SetWidth(440)
        selfHint:SetJustifyH("LEFT")
        selfHint:SetWordWrap(true)
        selfHint:SetTextColor(unpack(MedaUI.Theme.textDim))
        selfHint:SetText("If no alive target with the chosen role is found, cast on yourself instead. Useful for healers — leave off if you don't want accidental self-casts.")
        yOff = yOff - 34

        -- Status line (target)
        local statusLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        statusLabel:SetPoint("TOPLEFT", LEFT_X + 4, yOff)
        statusLabel:SetJustifyH("LEFT")
        statusLabels[slotIdx] = statusLabel
        yOff = yOff - 20

        -- Macro status line
        local macroLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        macroLabel:SetPoint("TOPLEFT", LEFT_X + 4, yOff)
        macroLabel:SetJustifyH("LEFT")
        macroLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
        yOff = yOff - 26

        -- "Place on Action Bar" button
        local placeBtn = MedaUI:CreateButton(parent, "Place on Action Bar", 160)
        placeBtn:SetPoint("TOPLEFT", LEFT_X, yOff)
        placeBtn:Hide()

        local placeHint = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        placeHint:SetPoint("LEFT", placeBtn, "RIGHT", 8, 0)
        placeHint:SetJustifyH("LEFT")
        placeHint:SetTextColor(unpack(MedaUI.Theme.textDim))
        placeHint:SetText("Picks up the macro — click an action bar slot to place it")
        placeHint:Hide()
        yOff = yOff - 38

        placeBtn:SetScript("OnClick", function()
            local macroName = GetMacroName(slotIdx)
            local idx = GetMacroIndexByName(macroName)
            if idx and idx > 0 then
                PickupMacro(idx)
            end
        end)

        local function UpdateSlotStatus()
            local name = GetTargetName(slot.role)
            local roleLabel = ROLE_LABELS[slot.role] or slot.role
            if slot.role == "PLAYER" then
                statusLabel:SetText(format("|cff88cc88Target:|r Self"))
            elseif name then
                statusLabel:SetText(format("|cff88cc88Target:|r %s (%s)", name, roleLabel))
            elseif slot.selfFallback then
                statusLabel:SetText(format("|cffcccc44No %s found — will self-cast|r", roleLabel:lower()))
            else
                statusLabel:SetText(format("|cffcc8888No %s found in group|r", roleLabel:lower()))
            end
            statusLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
        end

        local function UpdateMacroStatus(msg)
            local macroName = GetMacroName(slotIdx)
            local idx = GetMacroIndexByName(macroName)
            local macroExists = idx and idx > 0

            if msg then
                macroLabel:SetText("|cffaaaaaa" .. msg .. "|r")
            elseif macroExists then
                macroLabel:SetText(format("|cff88cc88Macro:|r \"%s\" ready", macroName))
            else
                macroLabel:SetText("|cffaaaaaaMacro will be created when you enter a spell name|r")
            end

            if macroExists then
                placeBtn:Show()
                placeHint:Show()
            else
                placeBtn:Hide()
                placeHint:Hide()
            end
        end

        spellInput.OnEnterPressed = function(_, text)
            slot.spellName = text
            UpdateAllButtons()
            if text and text ~= "" then
                local ok, msg = CreateOrUpdateMacro(slotIdx, text)
                UpdateMacroStatus(msg)
            else
                UpdateMacroStatus()
            end
        end

        roleDropdown.OnValueChanged = function(_, value)
            slot.role = value
            UpdateAllButtons()
            UpdateSlotStatus()
        end

        UpdateSlotStatus()
        UpdateMacroStatus()
    end

    yOff = yOff - 10

    -- Reset button
    local resetBtn = MedaUI:CreateButton(parent, "Reset to Defaults")
    resetBtn:SetPoint("TOPLEFT", LEFT_X, yOff)
    resetBtn:SetScript("OnClick", function()
        for k, v in pairs(MODULE_DEFAULTS) do
            db[k] = MedaAuras.DeepCopy(v)
        end
        MedaAuras:RefreshModuleConfig()
    end)
    yOff = yOff - 45

    MedaAuras:SetContentHeight(math.abs(yOff))
end

-- ============================================================================
-- Diagnostic Dump
-- ============================================================================

local function RunDiagnostic(db)
    local lines = { "|cff00ccffMedaAuras LazyCast Diagnostic:|r" }
    local function add(msg) lines[#lines + 1] = "  " .. msg end

    add(format("Module enabled: %s", tostring(db and db.enabled)))
    add(format("moduleDB set: %s", tostring(moduleDB ~= nil)))
    add(format("InCombatLockdown: %s", tostring(InCombatLockdown())))
    add(format("IsInGroup: %s  IsInRaid: %s  Members: %s",
        tostring(IsInGroup()), tostring(IsInRaid()), tostring(GetNumGroupMembers())))

    for i = 1, NUM_SLOTS do
        local slot = db and db.slots[i]
        local btn = buttons[i]
        add(format("--- Slot %d ---", i))
        add(format("  Config: spell=%q role=%s",
            slot and slot.spellName or "???", slot and slot.role or "???"))
        add(format("  Button: name=%s shown=%s type=%s",
            btn:GetName(), tostring(btn:IsShown()), tostring(btn:GetAttribute("type"))))
        add(format("  Attrs: spell=%q unit-primary=%s unit-fallback=%s unit=%s",
            tostring(btn:GetAttribute("spell") or ""),
            tostring(btn:GetAttribute("unit-primary")),
            tostring(btn:GetAttribute("unit-fallback")),
            tostring(btn:GetAttribute("unit"))))

        if slot then
            local primary, fallback = FindUnitsByRole(slot.role)
            local pName = primary and UnitName(primary) or "none"
            local fName = fallback and UnitName(fallback) or "none"
            add(format("  Live scan: primary=%s (%s) fallback=%s (%s)",
                tostring(primary), pName, tostring(fallback), fName))
        end

        local macroName = GetMacroName(i)
        local macroIdx = GetMacroIndexByName(macroName)
        add(format("  Macro: name=%s index=%s", macroName, tostring(macroIdx)))
    end

    for _, line in ipairs(lines) do
        print(line)
    end
    MedaAuras.Log(table.concat(lines, "\n"))
end

-- ============================================================================
-- Register Module
-- ============================================================================

MedaAuras:RegisterModule({
    name = MODULE_NAME,
    title = "Lazy Cast",
    version = MODULE_VERSION,
    stability = MODULE_STABILITY,
    description = "Auto-cast spells on group members by role (Tank, Healer, DPS, Self) without changing target.",
    sidebarDesc = "Cast spells on tank/healer/dps without targeting",
    defaults = MODULE_DEFAULTS,
    OnInitialize = OnInitialize,
    OnEnable = OnEnable,
    OnDisable = OnDisable,
    BuildConfig = BuildConfig,
    slashCommands = {
        ["diag"] = function(db)
            RunDiagnostic(db)
        end,
    },
})
