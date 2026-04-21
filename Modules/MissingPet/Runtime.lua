local _, ns = ...

local CreateFrame = CreateFrame
local GetSpecialization = GetSpecialization
local GetSpecializationInfo = GetSpecializationInfo
local C_Spell = _G.C_Spell
local C_SpellBook = _G.C_SpellBook
local Enum = _G.Enum
local IsMounted = _G.IsMounted
local IsInInstance = _G.IsInInstance
local IsSpellKnown = _G.IsSpellKnown
local UnitAffectingCombat = _G.UnitAffectingCombat
local UnitClass = UnitClass
local UnitExists = UnitExists
local UnitIsDeadOrGhost = _G.UnitIsDeadOrGhost
local format = format
local ipairs = ipairs
local pcall = pcall

local M = ns.MissingPet or {}
ns.MissingPet = M

local SPEC_UNHOLY = 252
local SPEC_FROST_MAGE = 64

-- Player pet summon spell IDs validated against wow-tools DB2 SpellName.csv.
local PET_REQUIREMENT_RULES = {
    HUNTER = {
        label = "Hunter",
        always = true,
    },
    WARLOCK = {
        label = "Warlock",
        spells = {
            688,
            697,
            691,
            712,
            30146,
            112866,
        },
    },
    DEATHKNIGHT = {
        label = "Unholy Death Knight",
        specID = SPEC_UNHOLY,
        spells = {
            46584,
        },
    },
    MAGE = {
        label = "Frost Mage",
        specID = SPEC_FROST_MAGE,
        spells = {
            31687,
        },
    },
}

local PET_TAUNT_SPELLS = {
    HUNTER = {
        { spellID = 2649, label = "Growl" },
    },
    WARLOCK = {
        { spellID = 17735, label = "Suffering" },
        { spellID = 26150, label = "Torment" },
    },
}

local moduleDB
local eventFrame
local eventsRegistered = false
local previewActive = false

local function IsMountedSafe()
    if not IsMounted then
        return false
    end

    local ok, mounted = pcall(IsMounted)
    return ok and mounted or false
end

local function IsSpellKnownSafe(spellID)
    if not spellID or not IsSpellKnown then
        return false
    end

    local ok, known = pcall(IsSpellKnown, spellID)
    return ok and known or false
end

local function IsInGroupPetContent()
    if not IsInInstance then
        return false, nil
    end

    local ok, inInstance, instanceType = pcall(IsInInstance)
    if not ok or not inInstance then
        return false, nil
    end

    if instanceType == "party" or instanceType == "raid" then
        return true, instanceType
    end

    return false, instanceType
end

local function FindPetSpellBookSlot(spellID)
    if not spellID or not C_SpellBook or not C_SpellBook.FindSpellBookSlotForSpell then
        return nil, nil
    end

    local ok, slotIndex, spellBank = pcall(
        C_SpellBook.FindSpellBookSlotForSpell,
        spellID,
        false,
        false,
        false,
        false
    )
    if not ok or not slotIndex then
        return nil, nil
    end

    if not Enum or not Enum.SpellBookSpellBank or spellBank ~= Enum.SpellBookSpellBank.Pet then
        return nil, nil
    end

    return slotIndex, spellBank
end

local function IsPetSpellAutoCastEnabled(spellID)
    local slotIndex, spellBank = FindPetSpellBookSlot(spellID)
    if slotIndex and spellBank and C_SpellBook and C_SpellBook.GetSpellBookItemAutoCast then
        local ok, autoCastAllowed, autoCastEnabled = pcall(
            C_SpellBook.GetSpellBookItemAutoCast,
            slotIndex,
            spellBank
        )
        if ok then
            return autoCastAllowed and autoCastEnabled or false
        end
    end

    if C_Spell and C_Spell.GetSpellAutoCast then
        local ok, autoCastAllowed, autoCastEnabled = pcall(C_Spell.GetSpellAutoCast, spellID)
        if ok then
            return autoCastAllowed and autoCastEnabled or false
        end
    end

    return false
end

local function GetPlayerSpecID()
    local specIndex = GetSpecialization and GetSpecialization()
    if not specIndex then
        return nil
    end

    return GetSpecializationInfo and GetSpecializationInfo(specIndex) or nil
end

local function MatchesRule(rule, specID)
    if not rule then
        return false
    end

    if rule.specID and rule.specID ~= specID then
        return false
    end

    if rule.always then
        return true
    end

    for _, spellID in ipairs(rule.spells or {}) do
        if IsSpellKnownSafe(spellID) then
            return true
        end
    end

    return false
end

function M.HasLivingPet()
    return UnitExists("pet") and not UnitIsDeadOrGhost("pet")
end

function M.ResolvePetRequirement()
    local _, classToken = UnitClass("player")
    if not classToken then
        return false, nil
    end

    local specID = GetPlayerSpecID()
    local rule = PET_REQUIREMENT_RULES[classToken]
    if rule and MatchesRule(rule, specID) then
        return true, rule.label
    end

    return false, nil
end

function M.ResolvePetTauntWarning()
    if not M.HasLivingPet() then
        return false, nil, nil
    end

    local _, classToken = UnitClass("player")
    local tauntSpells = classToken and PET_TAUNT_SPELLS[classToken] or nil
    if not tauntSpells then
        return false, nil, nil
    end

    local inGroupContent, instanceType = IsInGroupPetContent()
    if not inGroupContent then
        return false, nil, instanceType
    end

    for _, info in ipairs(tauntSpells) do
        if IsPetSpellAutoCastEnabled(info.spellID) then
            return true, info.label, instanceType
        end
    end

    return false, nil, instanceType
end

function M.GetActiveIssue()
    local needsPet, label = M.ResolvePetRequirement()
    if not needsPet then
        return nil, label, nil, nil
    end

    if not M.HasLivingPet() then
        return "missing", label, nil, nil
    end

    local hasTauntWarning, tauntLabel, instanceType = M.ResolvePetTauntWarning()
    if hasTauntWarning then
        return "taunt", label, tauntLabel, instanceType
    end

    return nil, label, nil, nil
end

function M.IsPreviewActive()
    return previewActive
end

function M.GetReminderText()
    local db = moduleDB or (M.GetDB and M.GetDB()) or nil
    local text = (db and db.text) or M.DEFAULT_TEXT
    if text == "" then
        text = M.DEFAULT_TEXT
    end

    if previewActive then
        return text
    end

    local issueType = M.GetActiveIssue()
    if issueType == "taunt" then
        return M.DEFAULT_TAUNT_TEXT or "Pet Taunt On"
    end

    return text
end

function M.ShouldShowReminder()
    if previewActive then
        return true
    end

    if not moduleDB or not moduleDB.enabled then
        return false
    end

    if UnitIsDeadOrGhost("player") then
        return false
    end

    if IsMountedSafe() then
        return false
    end

    if moduleDB.onlyInCombat and not UnitAffectingCombat("player") then
        return false
    end

    local issueType = M.GetActiveIssue()
    return issueType ~= nil
end

function M.GetStatusSummary()
    local needsPet, label = M.ResolvePetRequirement()

    if previewActive then
        return "Live preview visible. Unlock the frame to move the text.", M.INFO_COLOR
    end

    if not needsPet then
        return "Current class/spec is not in the explicit pet-user list.", M.INFO_COLOR
    end

    if IsMountedSafe() then
        return "Mounted; pet reminder suppressed.", M.INFO_COLOR
    end

    local issueType, resolvedLabel, tauntLabel, instanceType = M.GetActiveIssue()
    if issueType == "missing" then
        return format("%s pet missing.", resolvedLabel or label or "Tracked"), M.WARN_COLOR
    end

    if issueType == "taunt" then
        local contentLabel = instanceType == "raid" and "raid" or "dungeon"
        return format("%s autocast is enabled in %s content.", tauntLabel or "Pet taunt", contentLabel), M.WARN_COLOR
    end

    if M.HasLivingPet() then
        return format("%s pet detected.", label or "Tracked"), M.GOOD_COLOR
    end

    return format("%s pet missing.", label or "Tracked"), M.WARN_COLOR
end

local function HandleEvent(_, event, unit)
    if event == "UNIT_PET" and unit ~= "player" then
        return
    end

    if (event == "UNIT_HEALTH" or event == "UNIT_FLAGS") and unit ~= "pet" then
        return
    end

    if event == "UNIT_AURA" and unit ~= "player" then
        return
    end

    if M.RefreshDisplay then
        M.RefreshDisplay()
    end
end

local function EnsureEventsRegistered()
    if eventsRegistered then
        return
    end

    eventFrame = eventFrame or CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    eventFrame:RegisterEvent("SPELLS_CHANGED")
    eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_ALIVE")
    eventFrame:RegisterEvent("PLAYER_DEAD")
    eventFrame:RegisterEvent("PLAYER_UNGHOST")
    eventFrame:RegisterEvent("PET_BAR_UPDATE")
    eventFrame:RegisterEvent("PET_UI_UPDATE")
    eventFrame:RegisterUnitEvent("UNIT_AURA", "player")
    eventFrame:RegisterUnitEvent("UNIT_PET", "player")
    eventFrame:RegisterUnitEvent("UNIT_HEALTH", "pet")
    eventFrame:RegisterUnitEvent("UNIT_FLAGS", "pet")
    eventFrame:SetScript("OnEvent", HandleEvent)

    eventsRegistered = true
end

local function StopEvents()
    if not eventsRegistered or not eventFrame then
        return
    end

    eventFrame:UnregisterAllEvents()
    eventFrame:SetScript("OnEvent", nil)
    eventsRegistered = false
end

function M.RefreshRuntime(moduleDBOverride)
    moduleDB = moduleDBOverride or moduleDB or M.GetDB()
    if not moduleDB then
        return
    end

    if previewActive or moduleDB.enabled then
        EnsureEventsRegistered()
    else
        StopEvents()
    end

    if M.RefreshDisplay then
        M.RefreshDisplay()
    end
end

function M.SetPreview(enabled, moduleDBOverride)
    previewActive = enabled and true or false
    M.RefreshRuntime(moduleDBOverride)
end

function M.OnInitialize(moduleDBOverride)
    moduleDB = moduleDBOverride or moduleDB or M.GetDB()
end

function M.OnEnable(moduleDBOverride)
    M.RefreshRuntime(moduleDBOverride)
end

function M.OnDisable(moduleDBOverride)
    moduleDB = moduleDBOverride or moduleDB or M.GetDB()
    M.RefreshRuntime(moduleDB)
end
