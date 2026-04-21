local _, ns = ...

local CreateFrame = CreateFrame
local GetInstanceInfo = GetInstanceInfo
local GetNumGroupMembers = GetNumGroupMembers
local IsEncounterInProgress = IsEncounterInProgress
local IsInGroup = IsInGroup
local IsInInstance = IsInInstance
local IsInRaid = IsInRaid
local IsPlayerSpell = IsPlayerSpell
local IsSpellKnown = _G.IsSpellKnown
local UnitAffectingCombat = _G.UnitAffectingCombat
local UnitClass = UnitClass
local UnitExists = UnitExists
local UnitGroupRolesAssigned = _G.UnitGroupRolesAssigned
local UnitIsDeadOrGhost = _G.UnitIsDeadOrGhost
local UnitName = UnitName
local format = format
local ipairs = ipairs
local pcall = pcall

local C_Spell = _G.C_Spell

local M = ns.SoulstoneReminder or {}
ns.SoulstoneReminder = M

local SOULSTONE_SPELL_ID = 20707
local AURA_WATCH_KEY = "SoulstoneReminder"
local TRACKER_CALLBACK_KEY = "SoulstoneReminder"
local INSPECTOR_CALLBACK_KEY = "SoulstoneReminder"

local HEALER_SPEC_IDS = {
    [65] = true,
    [105] = true,
    [256] = true,
    [257] = true,
    [264] = true,
    [270] = true,
    [1468] = true,
}

local moduleDB
local eventFrame
local eventsRegistered = false
local previewActive = false
local trackerActive = false
local evaluationState

local function IsPlayerWarlock()
    local _, classToken = UnitClass("player")
    return classToken == "WARLOCK"
end

local function IsSpellKnownSafe(spellID)
    if not spellID then
        return false
    end

    if IsPlayerSpell and IsPlayerSpell(spellID) then
        return true
    end

    if IsSpellKnown then
        local ok, known = pcall(IsSpellKnown, spellID)
        return ok and known or false
    end

    return false
end

local function IsSupportedInstance()
    if not IsInInstance or not GetInstanceInfo then
        return false
    end

    local ok, inInstance = pcall(IsInInstance)
    if not ok or not inInstance then
        return false
    end

    local _, instanceType = GetInstanceInfo()
    return instanceType == "raid" or instanceType == "party"
end

local function IsSoulstoneReady()
    if not C_Spell or not C_Spell.GetSpellCooldown then
        return true
    end

    local ok, info = pcall(C_Spell.GetSpellCooldown, SOULSTONE_SPELL_ID)
    if not ok or not info then
        return true
    end

    local startTime = tonumber(info.startTime) or 0
    local duration = tonumber(info.duration) or 0
    return startTime <= 0 or duration <= 1.5
end

local function GetGroupUnits()
    local units = {}

    if IsInRaid and IsInRaid() then
        local count = GetNumGroupMembers() or 0
        for index = 1, count do
            units[#units + 1] = "raid" .. index
        end
        return units
    end

    if IsInGroup and IsInGroup() then
        units[#units + 1] = "player"
        for index = 1, 4 do
            local unit = "party" .. index
            if UnitExists(unit) then
                units[#units + 1] = unit
            end
        end
        return units
    end

    units[#units + 1] = "player"
    return units
end

local function IsGroupOutOfCombat()
    if IsEncounterInProgress and IsEncounterInProgress() then
        return false
    end

    for _, unit in ipairs(GetGroupUnits()) do
        if UnitExists(unit) and UnitAffectingCombat(unit) then
            return false
        end
    end

    return true
end

local function GetHealerInfo(unit)
    if not unit or not UnitExists(unit) or UnitIsDeadOrGhost(unit) then
        return nil
    end

    local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit) or nil
    if role == "HEALER" then
        return {
            unit = unit,
            name = UnitName(unit) or unit,
            role = role,
        }
    end

    local inspector = ns.Services and ns.Services.GroupInspector
    local info = inspector and inspector.GetUnitInfo and inspector:GetUnitInfo(unit) or nil
    if info and HEALER_SPEC_IDS[info.specID] then
        return {
            unit = unit,
            name = info.name or UnitName(unit) or unit,
            role = "HEALER",
            specID = info.specID,
        }
    end

    return nil
end

local function GetGroupHealers()
    local healers = {}
    for _, unit in ipairs(GetGroupUnits()) do
        local healer = GetHealerInfo(unit)
        if healer then
            healers[#healers + 1] = healer
        end
    end
    return healers
end

local function HasSoulstoneOnUnit(unit)
    local tracker = ns.Services and ns.Services.GroupAuraTracker
    if tracker and tracker.GetUnitSpellState then
        local state = tracker:GetUnitSpellState(AURA_WATCH_KEY, unit, SOULSTONE_SPELL_ID)
        if state and state.active then
            return true
        end
    end

    return false
end

local function EvaluateState()
    local state = {
        showReminder = false,
        reason = "Waiting until you are in an instance.",
        suggestedName = nil,
        soulstonedHealerName = nil,
    }

    if previewActive then
        state.showReminder = true
        state.reason = "Preview active. Drag the text if you need to reposition it."
        state.suggestedName = "Healer"
        return state
    end

    if not moduleDB or not moduleDB.enabled then
        state.reason = "Module disabled."
        return state
    end

    if not IsPlayerWarlock() then
        state.reason = "Current character is not a Warlock."
        return state
    end

    if not IsSpellKnownSafe(SOULSTONE_SPELL_ID) then
        state.reason = "Soulstone is not known on this character."
        return state
    end

    if not IsSupportedInstance() then
        state.reason = "Not in a party or raid instance."
        return state
    end

    local healers = GetGroupHealers()
    if #healers == 0 then
        state.reason = "No healer detected in the current group yet."
        return state
    end

    for _, healer in ipairs(healers) do
        if HasSoulstoneOnUnit(healer.unit) then
            state.soulstonedHealerName = healer.name
            state.reason = format("Soulstone already active on %s.", healer.name)
            return state
        end
    end

    state.suggestedName = healers[1].name

    if not IsGroupOutOfCombat() then
        state.reason = "Group is already in combat."
        return state
    end

    if not IsSoulstoneReady() then
        state.reason = "Soulstone is on cooldown."
        return state
    end

    state.showReminder = true
    state.reason = format("Soulstone %s while the group is out of combat.", state.suggestedName)
    return state
end

function M.UpdateState()
    evaluationState = EvaluateState()
    return evaluationState
end

function M.GetState()
    return evaluationState or M.UpdateState()
end

function M.GetReminderText()
    local db = moduleDB or (M.GetDB and M.GetDB()) or nil
    local text = (db and db.text) or M.DEFAULT_TEXT
    if text == "" then
        text = M.DEFAULT_TEXT
    end

    local state = M.GetState()
    if state and state.suggestedName and db and db.showHealerName ~= false then
        return format("%s: %s", text, state.suggestedName)
    end

    return text
end

function M.ShouldShowReminder()
    return M.GetState().showReminder
end

function M.GetStatusSummary()
    local state = M.UpdateState()
    if state.showReminder then
        return state.reason, M.WARN_COLOR
    end

    if state.soulstonedHealerName then
        return state.reason, M.GOOD_COLOR
    end

    if not moduleDB or not moduleDB.enabled then
        return state.reason, M.INFO_COLOR
    end

    if not IsPlayerWarlock() or not IsSupportedInstance() then
        return state.reason, M.INFO_COLOR
    end

    return state.reason, M.INFO_COLOR
end

local function RefreshDisplay()
    if M.RefreshDisplay then
        M.RefreshDisplay()
    else
        M.UpdateState()
    end
end

local function TrackerChanged()
    RefreshDisplay()
end

local function EnsureTracking()
    if trackerActive then
        return
    end

    local tracker = ns.Services and ns.Services.GroupAuraTracker
    if tracker then
        if tracker.Initialize then
            tracker:Initialize()
        end
        tracker:RegisterWatch(AURA_WATCH_KEY, {
            spells = {
                { spellID = SOULSTONE_SPELL_ID, name = "Soulstone" },
            },
        })
        tracker:RegisterCallback(TRACKER_CALLBACK_KEY, TrackerChanged)
        if tracker.RequestWatchScan then
            tracker:RequestWatchScan(AURA_WATCH_KEY)
        end
    end

    local inspector = ns.Services and ns.Services.GroupInspector
    if inspector then
        if inspector.Initialize then
            inspector:Initialize()
        end
        inspector:RegisterCallback(INSPECTOR_CALLBACK_KEY, TrackerChanged)
        if inspector.RequestReinspectAll then
            inspector:RequestReinspectAll()
        end
    end

    trackerActive = true
end

local function StopTracking()
    if not trackerActive then
        return
    end

    local tracker = ns.Services and ns.Services.GroupAuraTracker
    if tracker then
        tracker:UnregisterCallback(TRACKER_CALLBACK_KEY)
        tracker:UnregisterWatch(AURA_WATCH_KEY)
    end

    local inspector = ns.Services and ns.Services.GroupInspector
    if inspector then
        inspector:UnregisterCallback(INSPECTOR_CALLBACK_KEY)
    end

    trackerActive = false
end

local function HandleEvent(_, event)
    local _ = event
    RefreshDisplay()
end

local function EnsureEventsRegistered()
    if eventsRegistered then
        return
    end

    eventFrame = eventFrame or CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("SPELLS_CHANGED")
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
        EnsureTracking()
        EnsureEventsRegistered()
    else
        StopEvents()
        StopTracking()
    end

    RefreshDisplay()
end

function M.SetPreview(enabled, moduleDBOverride)
    previewActive = enabled and true or false
    M.RefreshRuntime(moduleDBOverride)
end

function M.OnInitialize(moduleDBOverride)
    moduleDB = moduleDBOverride or moduleDB or M.GetDB()
    evaluationState = nil
end

function M.OnEnable(moduleDBOverride)
    M.RefreshRuntime(moduleDBOverride)
end

function M.OnDisable(moduleDBOverride)
    moduleDB = moduleDBOverride or moduleDB or M.GetDB()
    M.RefreshRuntime(moduleDB)
end
