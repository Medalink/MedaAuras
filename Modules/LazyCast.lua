local _ = ...

local MedaUI = LibStub("MedaUI-2.0")

local format = format
local ipairs = ipairs
local wipe = wipe
local unpack = unpack
local tinsert = table.insert
local tremove = table.remove
local CreateFrame = CreateFrame
local UnitExists = UnitExists
local UnitName = UnitName
local UnitFullName = UnitFullName
local GetRealmName = GetRealmName
local strtrim = strtrim

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
    { value = "DAMAGER", label = "DPS" },
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
        { spellName = "", role = "TANK", selfFallback = false, favorites = {} },
        { spellName = "", role = "TANK", selfFallback = false, favorites = {} },
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

local function Trim(text)
    if text == nil then return "" end
    if strtrim then
        return strtrim(text)
    end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function NormalizePlayerName(name)
    return Trim(name):lower()
end

local function NormalizeRealmName(realm)
    realm = Trim(realm):lower()
    return (realm:gsub("[%s%-']", ""))
end

local function ParseFavoriteIdentity(nameText, realmText)
    local name = Trim(nameText)
    local realm = Trim(realmText)

    if name == "" then
        return nil, nil
    end

    if realm == "" then
        local splitName, splitRealm = name:match("^([^%-]+)%-(.+)$")
        if splitName and splitRealm then
            name = Trim(splitName)
            realm = Trim(splitRealm)
        end
    end

    return name, realm
end

local function FormatFavoriteLabel(favorite)
    if not favorite or not favorite.name or favorite.name == "" then
        return "Unknown"
    end
    if favorite.realm and favorite.realm ~= "" then
        return format("%s-%s", favorite.name, favorite.realm)
    end
    return favorite.name
end

local function NormalizeFavoriteEntry(favorite)
    if type(favorite) == "string" then
        local name, realm = ParseFavoriteIdentity(favorite, "")
        if not name then return nil end
        return { name = name, realm = realm or "" }
    end

    if type(favorite) ~= "table" then
        return nil
    end

    local name, realm = ParseFavoriteIdentity(favorite.name, favorite.realm)
    if not name then
        return nil
    end

    return {
        name = name,
        realm = realm or "",
    }
end

local function EnsureSlotDefaults(slot)
    slot.spellName = slot.spellName or ""
    slot.role = slot.role or "TANK"
    slot.selfFallback = slot.selfFallback and true or false

    local normalizedFavorites = {}
    for _, favorite in ipairs(slot.favorites or {}) do
        local normalized = NormalizeFavoriteEntry(favorite)
        if normalized then
            normalizedFavorites[#normalizedFavorites + 1] = normalized
        end
    end
    slot.favorites = normalizedFavorites
end

local function EnsureDBShape(db)
    db.slots = db.slots or {}
    for i = 1, NUM_SLOTS do
        db.slots[i] = db.slots[i] or {}
        EnsureSlotDefaults(db.slots[i])
    end
end

local function CollectUnitsByRole(role)
    local units = {}

    if role == "PLAYER" then
        units[1] = "player"
        return units
    end

    if role == "PET" then
        if UnitExists("pet") and not UnitIsDeadOrGhost("pet") then
            units[#units + 1] = "pet"
        end

        local prefix, count
        if IsInRaid() then
            prefix, count = "raidpet", GetNumGroupMembers()
        elseif IsInGroup() then
            prefix, count = "partypet", GetNumGroupMembers() - 1
        else
            return units
        end

        for i = 1, count do
            local unit = prefix .. i
            if UnitExists(unit) and not UnitIsDeadOrGhost(unit) then
                units[#units + 1] = unit
            end
        end

        return units
    end

    local prefix, count
    if IsInRaid() then
        prefix, count = "raid", GetNumGroupMembers()
    elseif IsInGroup() then
        prefix, count = "party", GetNumGroupMembers() - 1
    else
        return units
    end

    for i = 1, count do
        local unit = prefix .. i
        if UnitGroupRolesAssigned(unit) == role and not UnitIsDeadOrGhost(unit) then
            units[#units + 1] = unit
        end
    end

    return units
end

local function UnitMatchesFavorite(unit, favorite)
    if not unit or not favorite then
        return false
    end

    local unitName, unitRealm = UnitFullName(unit)
    unitName = unitName or UnitName(unit)
    if not unitName then
        return false
    end

    if NormalizePlayerName(unitName) ~= NormalizePlayerName(favorite.name) then
        return false
    end

    local favoriteRealm = NormalizeRealmName(favorite.realm)
    if favoriteRealm == "" then
        return true
    end

    local effectiveRealm = unitRealm
    if effectiveRealm == nil or effectiveRealm == "" then
        effectiveRealm = GetRealmName()
    end

    return NormalizeRealmName(effectiveRealm) == favoriteRealm
end

local function RankUnitsByFavorites(units, favorites)
    local ordered = {}
    local preferredFavorite

    if not favorites or #favorites == 0 or #units <= 1 then
        for index, unit in ipairs(units) do
            ordered[index] = unit
        end
        return ordered, nil
    end

    local claimed = {}

    for _, favorite in ipairs(favorites) do
        for index, unit in ipairs(units) do
            if not claimed[index] and UnitMatchesFavorite(unit, favorite) then
                claimed[index] = true
                ordered[#ordered + 1] = unit
                if not preferredFavorite then
                    preferredFavorite = favorite
                end
                break
            end
        end
    end

    for index, unit in ipairs(units) do
        if not claimed[index] then
            ordered[#ordered + 1] = unit
        end
    end

    return ordered, preferredFavorite
end

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

local function FindUnitsByRole(role, favorites)
    if role == "PLAYER" then return "player", nil, nil end
    if role == "PET" then return FindPetUnits() end

    local units = CollectUnitsByRole(role)
    local ordered, preferredFavorite = RankUnitsByFavorites(units, favorites)
    return ordered[1], ordered[2], preferredFavorite
end

local function GetUnitDisplayName(unit)
    if not unit then
        return nil
    end

    local name, realm = UnitFullName(unit)
    name = name or UnitName(unit)
    if not name then
        return nil
    end

    if not realm or realm == "" then
        realm = GetRealmName()
    end

    if realm and realm ~= "" then
        return format("%s-%s", name, realm)
    end
    return name
end

local function GetTargetName(role, favorites)
    local primary, _, matchedFavorite = FindUnitsByRole(role, favorites)
    if not primary then return nil, matchedFavorite end

    local name = GetUnitDisplayName(primary) or primary
    if role == "PET" then
        local ownerUnit = primary == "pet" and "player" or primary:gsub("pet", "")
        local ownerName = GetUnitDisplayName(ownerUnit) or UnitName(ownerUnit)
        if ownerName then
            return format("%s (%s's pet)", name, ownerName), matchedFavorite
        end
    end
    return name, matchedFavorite
end

local function GetOrderedUnitsByRole(role, favorites)
    if role == "PLAYER" then
        return { "player" }, nil
    end
    if role == "PET" then
        local primary, fallback = FindPetUnits()
        local units = {}
        if primary then
            units[#units + 1] = primary
        end
        if fallback then
            units[#units + 1] = fallback
        end
        return units, nil
    end

    local units = CollectUnitsByRole(role)
    return RankUnitsByFavorites(units, favorites)
end

local function RoleUsesPlayerFavorites(role)
    return role == "TANK" or role == "HEALER" or role == "DAMAGER"
end

local function AddFavoriteToSlot(slot, nameText, realmText)
    local name, realm = ParseFavoriteIdentity(nameText, realmText)
    if not name then
        return false, "Enter a player name first."
    end

    slot.favorites = slot.favorites or {}
    for _, favorite in ipairs(slot.favorites) do
        if NormalizePlayerName(favorite.name) == NormalizePlayerName(name)
            and NormalizeRealmName(favorite.realm) == NormalizeRealmName(realm) then
            return false, "That preferred target is already saved for this slot."
        end
    end

    local favorite = {
        name = name,
        realm = realm or "",
    }
    tinsert(slot.favorites, favorite)

    return true, format("Added preferred target: %s", FormatFavoriteLabel(favorite)), favorite
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
local configRefreshers = {}

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
            local primary, fallback = FindUnitsByRole(slot.role, slot.favorites)
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
    for i = 1, #configRefreshers do
        if configRefreshers[i] then
            configRefreshers[i]()
        end
    end
end

local function RegisterEvents()
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("PLAYER_ROLES_ASSIGNED")
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
    EnsureDBShape(db)
    moduleDB = db
    RegisterEvents()
    UpdateAllButtons()
    SyncMacros(db)
end

local function OnEnable(db)
    EnsureDBShape(db)
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

local function BuildSettingsPage(parent, db)
    EnsureDBShape(db)
    wipe(configRefreshers)

    local LEFT_X = 0
    local RIGHT_X = 248
    local LEFT_WIDTH = 220
    local RIGHT_WIDTH = 220
    local WIDE_WIDTH = 468
    local theme = MedaUI.Theme
    local dimColor = theme.textDim

    local _, tabs = MedaAuras:CreateConfigTabs(parent, {
        { id = "overview", label = "Overview" },
        { id = "slot1", label = "Slot 1" },
        { id = "slot2", label = "Slot 2" },
    })

    do
        local p = tabs["overview"]
        local yOff = 0

        local header = MedaUI:CreateSectionHeader(p, "Lazy Cast")
        header:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 40

        local enableCB = MedaUI:CreateCheckbox(p, "Enable Module")
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

        local desc = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        desc:SetPoint("TOPLEFT", LEFT_X, yOff)
        desc:SetWidth(WIDE_WIDTH)
        desc:SetJustifyH("LEFT")
        desc:SetWordWrap(true)
        desc:SetTextColor(unpack(dimColor))
        desc:SetText("Each slot casts on the first alive unit matching the selected role. Preferred targets are checked first, then Lazy Cast falls back to the next matching unit. Open a slot tab to edit favorites, click detected player names, and manage the macro for that slot.")
        yOff = yOff - 56

        for slotIdx = 1, NUM_SLOTS do
            local slot = db.slots[slotIdx]
            local card = MedaUI:CreateThemedFrame(p, nil, WIDE_WIDTH, 88, "backgroundDark", "border")
            card:SetPoint("TOPLEFT", LEFT_X, yOff)

            local title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            title:SetPoint("TOPLEFT", 10, -10)
            title:SetText(format("Slot %d", slotIdx))
            title:SetTextColor(unpack(theme.gold))

            local summary = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            summary:SetPoint("TOPLEFT", 10, -34)
            summary:SetWidth(WIDE_WIDTH - 20)
            summary:SetJustifyH("LEFT")
            summary:SetWordWrap(true)
            summary:SetTextColor(unpack(dimColor))

            local function RefreshOverviewCard()
                local roleLabel = ROLE_LABELS[slot.role] or slot.role
                local targetName, matchedFavorite = GetTargetName(slot.role, slot.favorites)
                local lines = {
                    format("Spell: %s", slot.spellName ~= "" and slot.spellName or "Not set"),
                    format("Role: %s", roleLabel),
                    format("Preferred targets: %d", #(slot.favorites or {})),
                }
                if targetName then
                    lines[#lines + 1] = matchedFavorite and format("Current target: %s (preferred)", targetName)
                        or format("Current target: %s", targetName)
                elseif slot.selfFallback then
                    lines[#lines + 1] = "Current target: Self fallback"
                else
                    lines[#lines + 1] = "Current target: No match found"
                end
                summary:SetText(table.concat(lines, "  |  "))
            end

            tinsert(configRefreshers, RefreshOverviewCard)
            RefreshOverviewCard()

            yOff = yOff - 104
        end
    end

    local function BuildSlotTab(tabParent, slotIdx)
        local slot = db.slots[slotIdx]
        local BOX_WIDTH = 222
        local BOX_HEIGHT = 172
        local LIST_WIDTH = 206
        local LIST_HEIGHT = 126
        local warnColor = theme.warning or theme.gold or theme.textDim
        local yOff = 0

        local setupHeader = MedaUI:CreateSectionHeader(tabParent, format("Slot %d Setup", slotIdx), LEFT_WIDTH)
        setupHeader:SetPoint("TOPLEFT", LEFT_X, yOff)

        local liveHeader = MedaUI:CreateSectionHeader(tabParent, "Live Targeting", RIGHT_WIDTH)
        liveHeader:SetPoint("TOPLEFT", RIGHT_X, yOff)
        yOff = yOff - 40

        local spellInput = MedaUI:CreateLabeledEditBox(tabParent, "Spell Name", LEFT_WIDTH)
        spellInput:SetPoint("TOPLEFT", LEFT_X, yOff)
        spellInput:SetText(slot.spellName or "")

        local targetStatus = tabParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        targetStatus:SetPoint("TOPLEFT", RIGHT_X, yOff)
        targetStatus:SetWidth(RIGHT_WIDTH)
        targetStatus:SetJustifyH("LEFT")
        targetStatus:SetWordWrap(true)
        targetStatus:SetTextColor(unpack(dimColor))
        yOff = yOff - 56

        local roleDropdown = MedaUI:CreateLabeledDropdown(tabParent, "Target Role", LEFT_WIDTH, ROLE_OPTIONS)
        roleDropdown:SetPoint("TOPLEFT", LEFT_X, yOff)
        roleDropdown:SetSelected(slot.role)

        local targetHint = tabParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        targetHint:SetPoint("TOPLEFT", RIGHT_X, yOff + 16)
        targetHint:SetWidth(RIGHT_WIDTH)
        targetHint:SetJustifyH("LEFT")
        targetHint:SetWordWrap(true)
        targetHint:SetTextColor(unpack(dimColor))
        targetHint:SetText("Detected player names below can be clicked to save them as preferred targets for this slot.")
        yOff = yOff - 60

        local selfCB = MedaUI:CreateCheckbox(tabParent, "Fallback to Self Cast")
        selfCB:SetPoint("TOPLEFT", LEFT_X, yOff)
        selfCB:SetChecked(slot.selfFallback or false)

        local targetDetail = tabParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        targetDetail:SetPoint("TOPLEFT", RIGHT_X, yOff)
        targetDetail:SetWidth(RIGHT_WIDTH)
        targetDetail:SetJustifyH("LEFT")
        targetDetail:SetWordWrap(true)
        targetDetail:SetTextColor(unpack(dimColor))
        yOff = yOff - 28

        local selfHint = tabParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        selfHint:SetPoint("TOPLEFT", LEFT_X + 22, yOff)
        selfHint:SetWidth(LEFT_WIDTH - 22)
        selfHint:SetJustifyH("LEFT")
        selfHint:SetWordWrap(true)
        selfHint:SetTextColor(unpack(dimColor))
        selfHint:SetText("If no matching unit is alive, the spell can fall back to you instead.")
        yOff = yOff - 50

        local macroLabel = tabParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        macroLabel:SetPoint("TOPLEFT", LEFT_X, yOff)
        macroLabel:SetWidth(LEFT_WIDTH)
        macroLabel:SetJustifyH("LEFT")
        macroLabel:SetWordWrap(true)
        macroLabel:SetTextColor(unpack(dimColor))

        local placeBtn = MedaUI:CreateButton(tabParent, "Place on Action Bar", 160)
        placeBtn:SetPoint("TOPLEFT", RIGHT_X, yOff - 6)
        placeBtn:Hide()

        local placeHint = tabParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        placeHint:SetPoint("TOPLEFT", RIGHT_X, yOff - 40)
        placeHint:SetWidth(RIGHT_WIDTH)
        placeHint:SetJustifyH("LEFT")
        placeHint:SetWordWrap(true)
        placeHint:SetTextColor(unpack(dimColor))
        placeHint:SetText("Picks up the macro so you can click an action bar slot.")
        placeHint:Hide()
        yOff = yOff - 72

        local favoritesHeader = MedaUI:CreateSectionHeader(tabParent, "Preferred Targets", WIDE_WIDTH)
        favoritesHeader:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 36

        local favoritesHint = tabParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        favoritesHint:SetPoint("TOPLEFT", LEFT_X, yOff)
        favoritesHint:SetWidth(WIDE_WIDTH)
        favoritesHint:SetJustifyH("LEFT")
        favoritesHint:SetWordWrap(true)
        favoritesHint:SetTextColor(unpack(dimColor))
        favoritesHint:SetText("Favorites are separate for each slot. They are only preferred when that player currently matches this slot's role.")
        yOff = yOff - 34

        local favoriteNameInput = MedaUI:CreateLabeledEditBox(tabParent, "Player", 180)
        favoriteNameInput:SetPoint("TOPLEFT", LEFT_X, yOff)

        local favoriteRealmInput = MedaUI:CreateLabeledEditBox(tabParent, "Realm", 180)
        favoriteRealmInput:SetPoint("TOPLEFT", LEFT_X + 196, yOff)

        local addFavoriteBtn = MedaUI:CreateButton(tabParent, "Add Favorite", 92)
        addFavoriteBtn:SetPoint("TOPLEFT", LEFT_X + 392, yOff - 20)
        yOff = yOff - 56

        local favoriteFeedback = tabParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        favoriteFeedback:SetPoint("TOPLEFT", LEFT_X, yOff)
        favoriteFeedback:SetWidth(WIDE_WIDTH)
        favoriteFeedback:SetJustifyH("LEFT")
        favoriteFeedback:SetWordWrap(true)
        favoriteFeedback:SetTextColor(unpack(dimColor))
        favoriteFeedback:SetText("Use Player-Realm in the player box, or click a detected player name to auto-fill and save the exact name and realm.")
        yOff = yOff - 28

        local favoritesBox = MedaUI:CreateThemedFrame(tabParent, nil, BOX_WIDTH, BOX_HEIGHT, "backgroundDark", "border")
        favoritesBox:SetPoint("TOPLEFT", LEFT_X, yOff)

        local detectedBox = MedaUI:CreateThemedFrame(tabParent, nil, BOX_WIDTH, BOX_HEIGHT, "backgroundDark", "border")
        detectedBox:SetPoint("TOPLEFT", RIGHT_X, yOff)

        local favoritesSummary = favoritesBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        favoritesSummary:SetPoint("TOPLEFT", 8, -8)
        favoritesSummary:SetWidth(BOX_WIDTH - 16)
        favoritesSummary:SetJustifyH("LEFT")
        favoritesSummary:SetTextColor(unpack(dimColor))

        local detectedSummary = detectedBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        detectedSummary:SetPoint("TOPLEFT", 8, -8)
        detectedSummary:SetWidth(BOX_WIDTH - 16)
        detectedSummary:SetJustifyH("LEFT")
        detectedSummary:SetTextColor(unpack(dimColor))

        local favoritesScroll = MedaUI:CreateScrollFrame(favoritesBox, nil, LIST_WIDTH, LIST_HEIGHT)
        favoritesScroll:SetPoint("TOPLEFT", favoritesBox, "TOPLEFT", 8, -30)

        local detectedScroll = MedaUI:CreateScrollFrame(detectedBox, nil, LIST_WIDTH, LIST_HEIGHT)
        detectedScroll:SetPoint("TOPLEFT", detectedBox, "TOPLEFT", 8, -30)

        local favoritesContent = favoritesScroll.scrollContent
        local detectedContent = detectedScroll.scrollContent

        local favoritesEmpty = favoritesContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        favoritesEmpty:SetPoint("TOPLEFT", 0, 0)
        favoritesEmpty:SetWidth(LIST_WIDTH)
        favoritesEmpty:SetJustifyH("LEFT")
        favoritesEmpty:SetWordWrap(true)
        favoritesEmpty:SetTextColor(unpack(dimColor))

        local detectedEmpty = detectedContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        detectedEmpty:SetPoint("TOPLEFT", 0, 0)
        detectedEmpty:SetWidth(LIST_WIDTH)
        detectedEmpty:SetJustifyH("LEFT")
        detectedEmpty:SetWordWrap(true)
        detectedEmpty:SetTextColor(unpack(dimColor))

        local favoriteRows = {}
        local detectedRows = {}

        placeBtn:SetScript("OnClick", function()
            local macroName = GetMacroName(slotIdx)
            local idx = GetMacroIndexByName(macroName)
            if idx and idx > 0 then
                PickupMacro(idx)
            end
        end)

        local function SetFavoriteFeedback(text, color)
            favoriteFeedback:SetText(text or "")
            favoriteFeedback:SetTextColor(unpack(color or dimColor))
        end

        local function UnitIsFavorite(unit)
            for _, favorite in ipairs(slot.favorites or {}) do
                if UnitMatchesFavorite(unit, favorite) then
                    return true
                end
            end
            return false
        end

        local RefreshFavoritesList
        local RefreshDetectedList
        local RefreshLiveTarget
        local RefreshMacroStatus
        local RefreshSlotView

        local function AddFavoriteFromValues(nameText, realmText)
            local ok, msg = AddFavoriteToSlot(slot, nameText, realmText)
            if not ok then
                SetFavoriteFeedback(msg, warnColor)
                return
            end

            favoriteNameInput:SetText("")
            favoriteRealmInput:SetText("")
            UpdateAllButtons()
            RefreshSlotView()
            SetFavoriteFeedback(msg, dimColor)
        end

        local function AddFavoriteFromUnit(unit)
            local name, realm = UnitFullName(unit)
            name = name or UnitName(unit)
            if not name then
                SetFavoriteFeedback("Could not resolve that player's name.", warnColor)
                return
            end
            if not realm or realm == "" then
                realm = GetRealmName() or ""
            end
            AddFavoriteFromValues(name, realm)
        end

        RefreshFavoritesList = function()
            local favorites = slot.favorites or {}
            favoritesSummary:SetText(format("%d saved favorite%s", #favorites, #favorites == 1 and "" or "s"))

            for _, row in ipairs(favoriteRows) do
                row:Hide()
            end

            if #favorites == 0 then
                favoritesEmpty:SetText("No preferred targets saved for this slot.")
                favoritesEmpty:Show()
                favoritesScroll:SetContentHeight(28, true)
                favoritesScroll:SetScroll(0)
                return
            end

            favoritesEmpty:Hide()

            local rowHeight = 24
            for index, favorite in ipairs(favorites) do
                local row = favoriteRows[index]
                if not row then
                    row = CreateFrame("Frame", nil, favoritesContent)
                    row:SetHeight(rowHeight)

                    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    row.label:SetPoint("LEFT", 2, 0)
                    row.label:SetWidth(126)
                    row.label:SetJustifyH("LEFT")
                    row.label:SetTextColor(unpack(theme.text))

                    row.removeBtn = MedaUI:CreateButton(row, "Remove", 72, 20)
                    row.removeBtn:SetPoint("RIGHT", -2, 0)

                    favoriteRows[index] = row
                end

                row:ClearAllPoints()
                if index == 1 then
                    row:SetPoint("TOPLEFT", favoritesContent, "TOPLEFT", 0, 0)
                    row:SetPoint("TOPRIGHT", favoritesContent, "TOPRIGHT", 0, 0)
                else
                    row:SetPoint("TOPLEFT", favoriteRows[index - 1], "BOTTOMLEFT", 0, 0)
                    row:SetPoint("TOPRIGHT", favoriteRows[index - 1], "BOTTOMRIGHT", 0, 0)
                end

                row.label:SetText(FormatFavoriteLabel(favorite))
                row.removeBtn:SetScript("OnClick", function()
                    tremove(slot.favorites, index)
                    UpdateAllButtons()
                    RefreshSlotView()
                    SetFavoriteFeedback("Favorite removed.", dimColor)
                end)
                row:Show()
            end

            favoritesScroll:SetContentHeight(#favorites * rowHeight, true)
            favoritesScroll:SetScroll(0)
        end

        RefreshDetectedList = function()
            local favoritesEnabled = RoleUsesPlayerFavorites(slot.role)
            local units = {}
            if favoritesEnabled then
                units = GetOrderedUnitsByRole(slot.role, slot.favorites)
            end

            for _, row in ipairs(detectedRows) do
                row:Hide()
            end

            if not favoritesEnabled then
                detectedSummary:SetText("Detected matches")
                detectedEmpty:SetText("Preferred targets are only used for Tank, Healer, and DPS slots.")
                detectedEmpty:Show()
                detectedScroll:SetContentHeight(40, true)
                detectedScroll:SetScroll(0)
                return
            end

            detectedSummary:SetText(format("%d detected role match%s", #units, #units == 1 and "" or "s"))

            if #units == 0 then
                detectedEmpty:SetText("No alive group members currently match this role.")
                detectedEmpty:Show()
                detectedScroll:SetContentHeight(28, true)
                detectedScroll:SetScroll(0)
                return
            end

            detectedEmpty:Hide()

            local rowHeight = 24
            for index, unit in ipairs(units) do
                local row = detectedRows[index]
                if not row then
                    row = CreateFrame("Frame", nil, detectedContent)
                    row:SetHeight(rowHeight)

                    row.button = MedaUI:CreateButton(row, "", LIST_WIDTH, 20)
                    row.button:SetPoint("LEFT", 0, 0)

                    detectedRows[index] = row
                end

                row:ClearAllPoints()
                if index == 1 then
                    row:SetPoint("TOPLEFT", detectedContent, "TOPLEFT", 0, 0)
                    row:SetPoint("TOPRIGHT", detectedContent, "TOPRIGHT", 0, 0)
                else
                    row:SetPoint("TOPLEFT", detectedRows[index - 1], "BOTTOMLEFT", 0, 0)
                    row:SetPoint("TOPRIGHT", detectedRows[index - 1], "BOTTOMRIGHT", 0, 0)
                end

                local label = GetUnitDisplayName(unit) or (UnitName(unit) or unit)
                local isSaved = UnitIsFavorite(unit)
                row.button:SetText(isSaved and (label .. " (Saved)") or label)
                row.button:SetEnabled(not isSaved)
                row.button:SetScript("OnClick", function()
                    AddFavoriteFromUnit(unit)
                end)
                row:Show()
            end

            detectedScroll:SetContentHeight(#units * rowHeight, true)
            detectedScroll:SetScroll(0)
        end

        RefreshLiveTarget = function()
            local name, matchedFavorite = GetTargetName(slot.role, slot.favorites)
            local roleLabel = ROLE_LABELS[slot.role] or slot.role

            if slot.role == "PLAYER" then
                targetStatus:SetText("|cff88cc88Target:|r Self")
                targetDetail:SetText("Preferred targets are ignored for Self.")
            elseif slot.role == "PET" then
                targetStatus:SetText((name and format("|cff88cc88Target:|r %s", name)) or "|cffcc8888No pet found|r")
                targetDetail:SetText("Preferred targets are ignored for Pet.")
            elseif name then
                targetStatus:SetText(format("|cff88cc88Target:|r %s", name))
                if matchedFavorite then
                    targetDetail:SetText(format("Chosen from your %s favorites before other matching group members.", roleLabel))
                else
                    targetDetail:SetText(format("No favorite matched, so Lazy Cast used the first alive %s found.", roleLabel:lower()))
                end
            elseif slot.selfFallback then
                targetStatus:SetText(format("|cffcccc44No %s found|r", roleLabel:lower()))
                targetDetail:SetText("Self fallback is enabled, so the spell will cast on you instead.")
            else
                targetStatus:SetText(format("|cffcc8888No %s found in group|r", roleLabel:lower()))
                targetDetail:SetText("Add favorites or change role selection once the right player is present.")
            end
        end

        RefreshMacroStatus = function(msg)
            local macroName = GetMacroName(slotIdx)
            local idx = GetMacroIndexByName(macroName)
            local macroExists = idx and idx > 0

            if msg then
                macroLabel:SetText("|cffaaaaaa" .. msg .. "|r")
            elseif macroExists then
                macroLabel:SetText(format("|cff88cc88Macro:|r \"%s\" ready", macroName))
            else
                macroLabel:SetText("|cffaaaaaaMacro will be created when you enter a spell name.|r")
            end

            if macroExists then
                placeBtn:Show()
                placeHint:Show()
            else
                placeBtn:Hide()
                placeHint:Hide()
            end
        end

        RefreshSlotView = function()
            local favoritesEnabled = RoleUsesPlayerFavorites(slot.role)
            if favoritesEnabled then
                favoriteNameInput:Enable()
                favoriteRealmInput:Enable()
                addFavoriteBtn:SetEnabled(true)
            else
                favoriteNameInput:Disable()
                favoriteRealmInput:Disable()
                addFavoriteBtn:SetEnabled(false)
            end
            RefreshLiveTarget()
            RefreshFavoritesList()
            RefreshDetectedList()
            RefreshMacroStatus()
        end

        spellInput.OnEnterPressed = function(_, text)
            slot.spellName = text
            UpdateAllButtons()
            if text and text ~= "" then
                local _, msg = CreateOrUpdateMacro(slotIdx, text)
                RefreshMacroStatus(msg)
            else
                RefreshMacroStatus()
            end
        end

        roleDropdown.OnValueChanged = function(_, value)
            slot.role = value
            UpdateAllButtons()
            RefreshSlotView()
        end

        selfCB.OnValueChanged = function(_, checked)
            slot.selfFallback = checked
            UpdateAllButtons()
            RefreshSlotView()
        end

        addFavoriteBtn:SetScript("OnClick", function()
            AddFavoriteFromValues(favoriteNameInput:GetText(), favoriteRealmInput:GetText())
        end)
        favoriteNameInput.OnEnterPressed = function()
            AddFavoriteFromValues(favoriteNameInput:GetText(), favoriteRealmInput:GetText())
        end
        favoriteRealmInput.OnEnterPressed = function()
            AddFavoriteFromValues(favoriteNameInput:GetText(), favoriteRealmInput:GetText())
        end

        tinsert(configRefreshers, RefreshSlotView)
        RefreshSlotView()
    end

    BuildSlotTab(tabs["slot1"], 1)
    BuildSlotTab(tabs["slot2"], 2)
    MedaAuras:SetContentHeight(560)
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
        if slot and slot.favorites and #slot.favorites > 0 then
            local labels = {}
            for idx, favorite in ipairs(slot.favorites) do
                labels[idx] = FormatFavoriteLabel(favorite)
            end
            add(format("  Favorites: %s", table.concat(labels, ", ")))
        else
            add("  Favorites: none")
        end
        add(format("  Button: name=%s shown=%s type=%s",
            btn:GetName(), tostring(btn:IsShown()), tostring(btn:GetAttribute("type"))))
        add(format("  Attrs: spell=%q unit-primary=%s unit-fallback=%s unit=%s",
            tostring(btn:GetAttribute("spell") or ""),
            tostring(btn:GetAttribute("unit-primary")),
            tostring(btn:GetAttribute("unit-fallback")),
            tostring(btn:GetAttribute("unit"))))

        if slot then
            local primary, fallback, preferredFavorite = FindUnitsByRole(slot.role, slot.favorites)
            local pName = primary and UnitName(primary) or "none"
            local fName = fallback and UnitName(fallback) or "none"
            add(format("  Live scan: primary=%s (%s) fallback=%s (%s)",
                tostring(primary), pName, tostring(fallback), fName))
            add(format("  Preferred hit: %s", preferredFavorite and FormatFavoriteLabel(preferredFavorite) or "none"))
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
    author = "Medalink",
    description = "Auto-cast spells on group members by role (Tank, Healer, DPS, Self) without changing target, with per-slot favorite target priority.",
    sidebarDesc = "Cast spells on tank/healer/DPS without targeting",
    defaults = MODULE_DEFAULTS,
    OnInitialize = OnInitialize,
    OnEnable = OnEnable,
    OnDisable = OnDisable,
    pages = {
        { id = "settings", label = "Settings" },
    },
    buildPage = function(_, parent)
        BuildSettingsPage(parent, MedaAuras:GetModuleDB(MODULE_NAME))
        return 960
    end,
    slashCommands = {
        ["diag"] = function(db)
            RunDiagnostic(db)
        end,
    },
})
