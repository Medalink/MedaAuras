--[[
    Prophecy Module -- Init
    Module registration, namespace setup, and event wiring between engine and UI.
    Fully standalone: shares Data/*.lua and Services/*.lua but zero code dependency on Reminders.
]]

local _, ns = ...

ns.Prophecy = {}

local MODULE_NAME = "Prophecy"
local MODULE_VERSION = "0.1"
local MODULE_STABILITY = "experimental"

local MODULE_DEFAULTS = {
    enabled = false,

    overlayOpacity      = 0.8,
    fontSize            = "md",
    maxVisible          = 5,
    showBackground      = false,
    backgroundOpacity   = 0.4,
    showDelta           = true,
    showTimers          = true,
    locked              = false,
    overlayPoint        = nil,
    showInDungeonOnly   = true,

    categories = {
        BUFF = true, LUST = true, INTERRUPT = true,
        BOSS = true, CD = true, AWARENESS = true,
    },

    templateSource = {},

    customTemplates = {},

    recordRuns          = true,
    maxRecordedRuns     = 20,
    autoGenerateAfter   = 3,
    excludeWipesFromAvg = true,

    driftNeutralThreshold = 15,
    driftMildThreshold    = 60,
    enableSoftSync        = false,
}

local function GetDB()
    return MedaAuras:GetModuleDB(MODULE_NAME)
end

-- ----------------------------------------------------------------
-- Engine <-> UI wiring
-- ----------------------------------------------------------------

local function OnInitialize()
    local Engine = ns.Services.ProphecyEngine
    if Engine then
        Engine:RegisterCallback("onStateChange", function(node)
            if ns.Prophecy.OnStateChange then
                ns.Prophecy.OnStateChange(node)
            end
        end)

        Engine:RegisterCallback("onDriftUpdate", function(drift)
            if ns.Prophecy.OnDriftUpdate then
                ns.Prophecy.OnDriftUpdate(drift)
            end
        end)

        Engine:RegisterCallback("onWipeStateChange", function(isWiping)
            if ns.Prophecy.OnWipeStateChange then
                ns.Prophecy.OnWipeStateChange(isWiping)
            end
        end)

        Engine:RegisterCallback("onRefresh", function()
            if ns.Prophecy.OnRefresh then
                ns.Prophecy.OnRefresh()
            end
        end)
    end

    -- Ensure MedaAurasCharDB is initialized
    MedaAurasCharDB = MedaAurasCharDB or {}
    MedaAurasCharDB.prophecy = MedaAurasCharDB.prophecy or {
        recordings = {},
        _checkpoint = nil,
    }
end

local function OnEnable()
    local db = GetDB()
    if not db then return end

    local Engine = ns.Services.ProphecyEngine
    if Engine then
        Engine:Initialize()
    end

    if ns.Prophecy.CreateOverlay then
        ns.Prophecy.CreateOverlay(db)
    end
end

local function OnDisable()
    local Engine = ns.Services.ProphecyEngine
    if Engine then Engine:Shutdown() end

    if ns.Prophecy.HideOverlay then
        ns.Prophecy.HideOverlay()
    end
end

local function BuildPage(pageName, parent)
    local db = GetDB()
    if not db then
        return 800
    end

    if pageName == "timeline" then
        ns.Prophecy.BuildBuilderTabs(parent, db, parent)
        return 760
    end
    if pageName == "editor" then
        ns.Prophecy.BuildEditorTab(parent, db)
        return 820
    end
    if pageName == "history" then
        ns.Prophecy.BuildHistoryTab(parent, db)
        return 760
    end
    if pageName == "appearance" then
        ns.Prophecy.BuildAppearancePage(parent, db)
        return 720
    end

    return 800
end

-- ----------------------------------------------------------------
-- Registration
-- ----------------------------------------------------------------

MedaAuras:RegisterModule({
    name          = MODULE_NAME,
    title         = "Prophecy",
    version       = MODULE_VERSION,
    stability     = MODULE_STABILITY,
    author        = "Medalink",
    description   = "Dungeon timeline overlay with curated templates, personal run recording, "
                 .. "a custom prophecy builder, chained trigger/action architecture, "
                 .. "and race-ghost delta tracking for M+ runs.",
    sidebarDesc   = "M+ dungeon timeline overlay with triggers, drift tracking, and run recording.",
    defaults      = MODULE_DEFAULTS,
    OnInitialize  = OnInitialize,
    OnEnable      = OnEnable,
    OnDisable     = OnDisable,
    pages         = {
        { id = "timeline", label = "Timeline" },
        { id = "editor", label = "Editor" },
        { id = "history", label = "History" },
        { id = "appearance", label = "Appearance" },
    },
    pageHeights   = {
        timeline = 760,
        editor = 820,
        history = 760,
        appearance = 720,
    },
    buildPage     = BuildPage,
    slashCommands = {
        preview = function()
            if ns.Prophecy.TogglePreview then ns.Prophecy.TogglePreview() end
        end,
        reset = function()
            if ns.Prophecy.ResetOverlayPosition then ns.Prophecy.ResetOverlayPosition() end
        end,
    },
})
