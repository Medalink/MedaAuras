local _, ns = ...

local R = ns.Reminders or {}
ns.Reminders = R

local S = R.state or {}
R.state = S

local MedaUI = LibStub("MedaUI-2.0")

local SEVERITY_COLORS = R.SEVERITY_COLORS
local COVERED_COLOR = R.COVERED_COLOR
local RECOMMEND_COLOR = R.RECOMMEND_COLOR
local CHROME_HEIGHT = R.CHROME_HEIGHT

local SPEC_META_BY_ID
local ALL_CLASS_SPECS
local TANK_SPECS
local HEALER_SPECS
local DPS_SPECS
local ALL_CLASSES
local ROLE_LABELS
local GetActivityKey
local GetClassLabel
local EnsurePersonalSchema
local EnsureSpecRegistry
local GetViewerProfile
local BuildStructuredCapabilityOutput
local BuildPerspectiveSummary
local ResolveSpellID
local BeginSpellTooltip
local AddTooltipSpacer
local CreateTooltipTextLine
local CreateTooltipTextBlock
local AddRecommendationTooltip
local RenderRecommendationCardGrid
local GetResultTooltipSpellID

local function GetData(...)
    return R.GetData(...)
end

local function GetCurrentContext(...)
    return R.GetCurrentContext(...)
end

local function ResolveInstanceContext(...)
    return R.ResolveInstanceContext(...)
end

local function IsCurrentPartyFull(...)
    return R.IsCurrentPartyFull(...)
end

local function GetFullGroupWorkaround(...)
    return R.GetFullGroupWorkaround(...)
end

local function GetContextKey(...)
    return R.GetContextKey(...)
end

local function GetDetectedLabel(...)
    return R.GetDetectedLabel(...)
end

local function IsSourceEnabled(...)
    return R.IsSourceEnabled(...)
end

local function ClassifyBuildContentType(...)
    return R.ClassifyBuildContentType(...)
end

local function FormatSourceBadge(...)
    return R.FormatSourceBadge(...)
end

local function FilterNoteBySource(...)
    return R.FilterNoteBySource(...)
end

local function GetEnabledSources(...)
    return R.GetEnabledSources(...)
end

local function FormatProviderText(...)
    return R.FormatProviderText(...)
end

local function ShowCopyPopup(...)
    return R.ShowCopyPopup(...)
end

local function CanCopyLoadoutCode(...)
    return R.CanCopyLoadoutCode(...)
end

local function GetLoadoutAvailabilityNote(...)
    return R.GetLoadoutAvailabilityNote(...)
end

local function BuildSpellMap(...)
    return R.BuildSpellMap(...)
end

local function ColorSpellNames(...)
    return R.ColorSpellNames(...)
end

local function RunPipeline(...)
    return R.RunPipeline(...)
end
local function BuildContextDropdownItems()
    local data = GetData()
    local items = { { value = "auto", label = "Auto (Live)" } }
    if not data or not data.contexts then return items end

    -- Instance type overrides
    if data.contexts.instanceTypes then
        items[#items + 1] = { value = "_hdr_types", label = "|cff888888--- Instance Types ---|r", disabled = true }
        local sorted = {}
        for key, info in pairs(data.contexts.instanceTypes) do
            sorted[#sorted + 1] = { key = key, label = info.label }
        end
        table.sort(sorted, function(a, b) return a.label < b.label end)
        for _, entry in ipairs(sorted) do
            items[#items + 1] = { value = "type:" .. entry.key, label = entry.label }
        end
    end

    -- Dungeons: split into Season 1 M+ pool and other Midnight dungeons
    if data.contexts.dungeons then
        local s1Pool = {}
        local otherDungeons = {}
        for id, info in pairs(data.contexts.dungeons) do
            if info.season1MPlus then
                s1Pool[#s1Pool + 1] = { id = id, name = info.name }
            else
                otherDungeons[#otherDungeons + 1] = { id = id, name = info.name }
            end
        end
        table.sort(s1Pool, function(a, b) return a.name < b.name end)
        table.sort(otherDungeons, function(a, b) return a.name < b.name end)

        if #s1Pool > 0 then
            items[#items + 1] = { value = "_hdr_s1mplus", label = "|cff888888--- Season 1 M+ Pool ---|r", disabled = true }
            for _, entry in ipairs(s1Pool) do
                items[#items + 1] = { value = "dungeon:" .. entry.id, label = "    " .. entry.name }
            end
        end
        if #otherDungeons > 0 then
            items[#items + 1] = { value = "_hdr_other", label = "|cff888888--- Other Midnight Dungeons ---|r", disabled = true }
            for _, entry in ipairs(otherDungeons) do
                items[#items + 1] = { value = "dungeon:" .. entry.id, label = "    " .. entry.name }
            end
        end
    end

    -- Delves
    if data.contexts.delves and #data.contexts.delves > 0 then
        items[#items + 1] = { value = "_hdr_delves", label = "|cff888888--- Delves ---|r", disabled = true }
        for i, delve in ipairs(data.contexts.delves) do
            items[#items + 1] = { value = "delve:" .. i, label = "    " .. delve.name }
        end
    end

    return items
end

local function ParseContextSelection(value)
    if not value or value == "auto" then return nil end

    -- Ignore header/separator items
    if value:match("^_hdr_") then return nil end

    local typeKey = value:match("^type:(.+)$")
    if typeKey then
        return {
            inInstance   = true,
            instanceType = typeKey,
            instanceID   = nil,
            instanceName = nil,
            isDelve      = (typeKey == "delve"),
        }
    end

    local dungeonID = value:match("^dungeon:(%d+)$")
    if dungeonID then
        dungeonID = tonumber(dungeonID)
        local data = GetData()
        local name
        if data and data.contexts and data.contexts.dungeons and data.contexts.dungeons[dungeonID] then
            name = data.contexts.dungeons[dungeonID].name
        end
        return {
            inInstance    = true,
            instanceType  = "party",
            instanceID    = dungeonID,
            instanceName  = name,
            isDelve       = false,
            difficultyTier = "mythicplus",
        }
    end

    local delveIdx = value:match("^delve:(%d+)$")
    if delveIdx then
        delveIdx = tonumber(delveIdx)
        local data = GetData()
        local name
        if data and data.contexts and data.contexts.delves and data.contexts.delves[delveIdx] then
            name = data.contexts.delves[delveIdx].name
        end
        return {
            inInstance   = true,
            instanceType = "delve",
            instanceID   = nil,
            instanceName = name,
            isDelve      = true,
        }
    end

    local raidKey = value:match("^raid:(.+)$")
    if raidKey then
        local data = GetData()
        local name
        if data and data.contexts and data.contexts.raids and data.contexts.raids[raidKey] then
            name = data.contexts.raids[raidKey].name
        end
        return {
            inInstance   = true,
            instanceType = "raid",
            instanceID   = nil,
            instanceName = name,
            isDelve      = false,
            raidKey      = raidKey,
        }
    end

    return nil
end

local function GetSupportedRolesForClass(classToken)
    local data = GetData()
    EnsureSpecRegistry(data)

    local roleMap = {}
    local specs = data and data.specRegistry and data.specRegistry.byClass and data.specRegistry.byClass[classToken] or nil
    for _, spec in ipairs(specs or {}) do
        roleMap[spec.role] = true
    end

    local roles = {}
    for _, role in ipairs({ "tank", "healer", "dps" }) do
        if roleMap[role] then
            roles[#roles + 1] = role
        end
    end
    return roles
end

local function GetSpecsForRole(classToken, role)
    local data = GetData()
    EnsureSpecRegistry(data)
    local specs = {}
    for _, spec in ipairs(data and data.specRegistry and data.specRegistry.byClass and data.specRegistry.byClass[classToken] or {}) do
        if not role or spec.role == role then
            specs[#specs + 1] = spec
        end
    end
    table.sort(specs, function(a, b) return (a.specName or "") < (b.specName or "") end)
    return specs
end

local function GetDefaultSpecForClassRole(classToken, role)
    local specs = GetSpecsForRole(classToken, role)
    return specs[1]
end

local function BuildRoleDropdownItems(classToken)
    local roles = GetSupportedRolesForClass(classToken)
    local items = {}
    for _, role in ipairs(roles) do
        items[#items + 1] = {
            value = role,
            label = ROLE_LABELS[role] or role,
        }
    end
    return items
end

local function BuildClassDropdownItems()
    local data = GetData()
    EnsureSpecRegistry(data)

    local items = {}
    for _, classToken in ipairs(ALL_CLASSES or {}) do
        if data and data.specRegistry and data.specRegistry.byClass and data.specRegistry.byClass[classToken] then
            items[#items + 1] = {
                value = classToken,
                label = GetClassLabel(classToken),
            }
        end
    end
    table.sort(items, function(a, b) return (a.label or "") < (b.label or "") end)
    return items
end

local function BuildSpecDropdownItems(classToken, role)
    local items = {}
    for _, spec in ipairs(GetSpecsForRole(classToken, role)) do
        items[#items + 1] = {
            value = spec.specID,
            label = spec.specName,
        }
    end
    return items
end

local function SyncViewerToolbar()
    local toolbar = S.uiState.toolbar or {}
    local viewer = GetViewerProfile()
    if not viewer or not toolbar.classDropdown or not toolbar.roleDropdown or not toolbar.specDropdown then
        return
    end

    S.uiState.suppressToolbarCallbacks = true

    local roleItems = BuildRoleDropdownItems(viewer.classToken)
    toolbar.roleDropdown:SetOptions(roleItems)
    toolbar.roleDropdown:SetEnabled(#roleItems > 1)
    toolbar.roleDropdown:SetSelected(viewer.role)

    local classItems = BuildClassDropdownItems()
    toolbar.classDropdown:SetOptions(classItems)
    toolbar.classDropdown:SetSelected(viewer.classToken)

    local specItems = BuildSpecDropdownItems(viewer.classToken, viewer.role)
    toolbar.specDropdown:SetOptions(specItems)
    if #specItems > 1 then
        toolbar.specDropdown:Show()
        toolbar.specDropdown:SetEnabled(true)
        toolbar.specDropdown:SetSelected(viewer.specID)
    else
        toolbar.specDropdown:Hide()
    end

    S.uiState.suppressToolbarCallbacks = false
end

BuildStructuredCapabilityOutput = function(result, ctx)
    local output = result and result.output or {}
    local tone
    if output.severity == "critical" or output.severity == "high" then
        tone = "critical"
    elseif output.severity == "warning" or output.severity == "medium" then
        tone = "warning"
    else
        tone = result and result.matchCount > 0 and "info" or "warning"
    end
    local summary = output.detail or output.banner or "Coverage available."
    local missingAction = output.suggestion
    local fullGroupWorkaround = GetFullGroupWorkaround(result and result.capabilityID)
    local fullGroup = result and result.matchCount == 0 and IsCurrentPartyFull(ctx)

    if fullGroup and fullGroupWorkaround then
        missingAction = nil
    end

    return {
        status = result and result.matchCount > 0 and "covered" or "missing",
        tone = tone,
        title = output.banner or (result and result.capability and result.capability.label) or "Capability",
        summary = summary,
        missingAction = missingAction,
        fullGroupWorkaround = fullGroup and fullGroupWorkaround or nil,
        providers = result and result.matches or nil,
        source = result and result.capability and result.capability.source or nil,
        tags = result and result.capability and result.capability.tags or nil,
        invite_solution = missingAction,
        in_roster_adjustment = fullGroup and fullGroupWorkaround or nil,
        tactical_workaround = fullGroup and fullGroupWorkaround or nil,
    }
end

-- ============================================================================
-- Reminders 2.0 workspace rendering
-- ============================================================================

local function MarkSource(usedSet, source)
    if usedSet and source and IsSourceEnabled(source) then
        usedSet[source] = true
    end
end

local function GetEffectiveContext()
    return S.overrideContext or S.lastContext or GetCurrentContext()
end

GetActivityKey = function(ctx)
    if not ctx or not ctx.inInstance then return "world" end
    if ctx.isDelve or ctx.instanceType == "delve" then return "delve" end
    if ctx.instanceType == "party" then return "dungeon" end
    if ctx.instanceType == "raid" then return "raid" end
    return "world"
end

SPEC_META_BY_ID = {
    [62] = { classToken = "MAGE", specName = "Arcane", role = "dps" },
    [63] = { classToken = "MAGE", specName = "Fire", role = "dps" },
    [64] = { classToken = "MAGE", specName = "Frost", role = "dps" },
    [65] = { classToken = "PALADIN", specName = "Holy", role = "healer" },
    [66] = { classToken = "PALADIN", specName = "Protection", role = "tank" },
    [70] = { classToken = "PALADIN", specName = "Retribution", role = "dps" },
    [71] = { classToken = "WARRIOR", specName = "Arms", role = "dps" },
    [72] = { classToken = "WARRIOR", specName = "Fury", role = "dps" },
    [73] = { classToken = "WARRIOR", specName = "Protection", role = "tank" },
    [102] = { classToken = "DRUID", specName = "Balance", role = "dps" },
    [103] = { classToken = "DRUID", specName = "Feral", role = "dps" },
    [104] = { classToken = "DRUID", specName = "Guardian", role = "tank" },
    [105] = { classToken = "DRUID", specName = "Restoration", role = "healer" },
    [250] = { classToken = "DEATHKNIGHT", specName = "Blood", role = "tank" },
    [251] = { classToken = "DEATHKNIGHT", specName = "Frost", role = "dps" },
    [252] = { classToken = "DEATHKNIGHT", specName = "Unholy", role = "dps" },
    [253] = { classToken = "HUNTER", specName = "Beast Mastery", role = "dps" },
    [254] = { classToken = "HUNTER", specName = "Marksmanship", role = "dps" },
    [255] = { classToken = "HUNTER", specName = "Survival", role = "dps" },
    [256] = { classToken = "PRIEST", specName = "Discipline", role = "healer" },
    [257] = { classToken = "PRIEST", specName = "Holy", role = "healer" },
    [258] = { classToken = "PRIEST", specName = "Shadow", role = "dps" },
    [259] = { classToken = "ROGUE", specName = "Assassination", role = "dps" },
    [260] = { classToken = "ROGUE", specName = "Outlaw", role = "dps" },
    [261] = { classToken = "ROGUE", specName = "Subtlety", role = "dps" },
    [262] = { classToken = "SHAMAN", specName = "Elemental", role = "dps" },
    [263] = { classToken = "SHAMAN", specName = "Enhancement", role = "dps" },
    [264] = { classToken = "SHAMAN", specName = "Restoration", role = "healer" },
    [265] = { classToken = "WARLOCK", specName = "Affliction", role = "dps" },
    [266] = { classToken = "WARLOCK", specName = "Demonology", role = "dps" },
    [267] = { classToken = "WARLOCK", specName = "Destruction", role = "dps" },
    [268] = { classToken = "MONK", specName = "Brewmaster", role = "tank" },
    [269] = { classToken = "MONK", specName = "Windwalker", role = "dps" },
    [270] = { classToken = "MONK", specName = "Mistweaver", role = "healer" },
    [577] = { classToken = "DEMONHUNTER", specName = "Havoc", role = "dps" },
    [581] = { classToken = "DEMONHUNTER", specName = "Vengeance", role = "tank" },
    [1467] = { classToken = "EVOKER", specName = "Devastation", role = "dps" },
    [1468] = { classToken = "EVOKER", specName = "Preservation", role = "healer" },
    [1473] = { classToken = "EVOKER", specName = "Augmentation", role = "dps" },
}

ROLE_LABELS = {
    tank = "Tank",
    healer = "Healer",
    dps = "DPS",
}

local PERSONAL_TAB_BY_BUILD = {
    talent = "talents",
    hero_talent = "talents",
    stats = "talents",
    gear = "gear",
    trinkets = "trinkets",
    consumables = "consumes",
    enchants = "enchants",
}

local PERSONAL_KIND_BY_BUILD = {
    talent = "build",
    hero_talent = "hero_tree",
    stats = "stat_priority",
    gear = "item_list",
    trinkets = "item_list",
    consumables = "item_list",
    enchants = "item_list",
}

local PAGE_SECTION_ORDER = { "overview", "mechanics", "loadout", "utility", "assignments", "helpers", "workarounds" }

local function SafeText(value)
    if value == nil then return nil end
    if type(value) == "string" then
        local trimmed = value:match("^%s*(.-)%s*$")
        if trimmed == "" then return nil end
        return trimmed
    end
    return tostring(value)
end

local function AppendLines(target, value)
    if type(value) == "table" then
        for _, line in ipairs(value) do
            local text = SafeText(line)
            if text then
                target[#target + 1] = text
            end
        end
    else
        local text = SafeText(value)
        if text then
            target[#target + 1] = text
        end
    end
end

GetClassLabel = function(classToken)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classToken])
        or (LOCALIZED_CLASS_NAMES_FEMALE and LOCALIZED_CLASS_NAMES_FEMALE[classToken])
        or classToken
        or "Unknown"
end

local function GetSpecMeta(specID, classToken)
    local meta = specID and SPEC_META_BY_ID[specID]
    if meta then
        return meta
    end

    return {
        classToken = classToken,
        specName = specID and ("Spec " .. specID) or "Unknown Spec",
        role = "dps",
    }
end

local function GetRoleFromSpec(specID, classToken)
    return GetSpecMeta(specID, classToken).role or "dps"
end

local function NormalizeLegacyActivityTag(tag)
    if not tag or tag == "" or tag == "general" then return "all" end
    if tag == "mplus" then return "dungeon" end
    if tag == "delve" then return "delve" end
    if tag == "raid" then return "raid" end
    return tag
end

local function GetContextSelector(activity, ctx, rec)
    if activity == "dungeon" then
        local dungeonID = rec and rec.dungeonID or (ctx and ctx.instanceID)
        if dungeonID then
            return "dungeon:" .. dungeonID
        end
    elseif activity == "raid" then
        local raidKey = (rec and rec.raidKey) or (ctx and ctx.raidKey)
        if raidKey then
            return "raid:" .. raidKey
        end
    elseif activity == "delve" then
        local delveKey = (rec and rec.delveKey) or (ctx and ctx.instanceName)
        if delveKey then
            return "delve:" .. delveKey
        end
    end
    return nil
end

local function BuildContextAwareSummary(rec)
    local parts = {}
    if rec.heroTree and rec.heroTree ~= "" then
        parts[#parts + 1] = rec.heroTree
    end
    if rec.popularity then
        parts[#parts + 1] = format("%.1f%% popularity", rec.popularity)
    end
    if rec.keyLevel then
        parts[#parts + 1] = format("+%d key", rec.keyLevel)
    end
    if rec.notes and rec.notes ~= "" then
        parts[#parts + 1] = rec.notes
    end
    return table.concat(parts, " | ")
end

local function BuildPersonalEntryTitle(rec)
    local titles = {
        talent = "Recommended Talent Build",
        hero_talent = "Hero Tree",
        stats = "Stat Priority",
        gear = "Popular Gear",
        trinkets = "Top Trinkets",
        consumables = "Recommended Consumables",
        enchants = "Enchants & Gems",
    }
    return titles[rec.buildType] or "Recommendation"
end

local function NormalizeRecommendationEntry(specKey, rec, index)
    local activity = NormalizeLegacyActivityTag(ClassifyBuildContentType(rec))
    local tab = PERSONAL_TAB_BY_BUILD[rec.buildType]
    local meta = GetSpecMeta(rec.specID, rec.class)

    return {
        id = format("%s:%s:%d", specKey, rec.buildType or "entry", index),
        kind = PERSONAL_KIND_BY_BUILD[rec.buildType] or "summary_card",
        title = BuildPersonalEntryTitle(rec),
        summary = BuildContextAwareSummary(rec),
        tone = "info",
        source = rec.source,
        activity = activity,
        class = rec.class,
        specID = rec.specID,
        role = meta.role,
        contextKey = GetContextSelector(activity, nil, rec),
        tab = tab,
        heroTree = rec.heroTree,
        popularity = rec.popularity,
        keyLevel = rec.keyLevel,
        exportString = rec.content and rec.content.exportString,
        items = rec.content and rec.content.items,
        stats = rec.buildType == "stats" and rec.content or nil,
        content = rec.content,
        buildType = rec.buildType,
        contentType = rec.contentType,
        notes = rec.notes,
        dungeonID = rec.dungeonID,
        raw = rec,
    }
end

EnsurePersonalSchema = function(data)
    if not data then return end
    data.personal = data.personal or { bySpec = {} }
    data.personal.bySpec = data.personal.bySpec or {}

    for specKey, recs in pairs(data.recommendations or {}) do
        if not data.personal.bySpec[specKey] then
            local entries = {}
            for index, rec in ipairs(recs) do
                entries[#entries + 1] = NormalizeRecommendationEntry(specKey, rec, index)
            end
            data.personal.bySpec[specKey] = entries
        end
    end
end

EnsureSpecRegistry = function(data)
    if not data then return end
    data.specRegistry = data.specRegistry or { byClass = {}, bySpecID = {} }
    data.specRegistry.byClass = {}
    data.specRegistry.bySpecID = {}

    for specKey, recs in pairs(data.recommendations or {}) do
        local first = recs and recs[1]
        local classToken = first and first.class or specKey:match("^(.-)_")
        local specID = first and first.specID or tonumber(specKey:match("_(%d+)$"))
        if classToken and specID then
            local meta = GetSpecMeta(specID, classToken)
            local entry = {
                classToken = classToken,
                classLabel = GetClassLabel(classToken),
                specID = specID,
                specName = meta.specName,
                role = meta.role,
                specKey = specKey,
            }
            data.specRegistry.bySpecID[specID] = entry
            data.specRegistry.byClass[classToken] = data.specRegistry.byClass[classToken] or {}
            data.specRegistry.byClass[classToken][#data.specRegistry.byClass[classToken] + 1] = entry
        end
    end

    for classToken, specs in pairs(data.specRegistry.byClass) do
        table.sort(specs, function(a, b)
            if a.role ~= b.role then
                return (a.role or "") < (b.role or "")
            end
            return (a.specName or "") < (b.specName or "")
        end)
    end
end

local function GetLivePlayerProfile()
    local _, classToken = UnitClass("player")
    local specIndex = GetSpecialization()
    local specID = specIndex and GetSpecializationInfo(specIndex)
    if not classToken or not specID then
        return nil
    end

    local meta = GetSpecMeta(specID, classToken)
    return {
        mode = "live",
        classToken = classToken,
        classLabel = GetClassLabel(classToken),
        specID = specID,
        specName = meta.specName,
        role = meta.role,
        specKey = classToken .. "_" .. specID,
        isLive = true,
    }
end

local function PersistViewerState()
    if not S.db then return end
    local viewer = S.uiState.viewer or {}
    if viewer.mode == "browse" and viewer.classToken and viewer.specID then
        S.db.viewer = {
            mode = "browse",
            classToken = viewer.classToken,
            role = viewer.role,
            specID = viewer.specID,
        }
    else
        S.db.viewer = nil
    end
end

local function SetViewerState(classToken, role, specID, modeOverride)
    local live = GetLivePlayerProfile()
    local selectedClass = classToken or (live and live.classToken)
    local selectedSpec = specID or (live and live.specID)
    local selectedRole = role or (selectedSpec and GetRoleFromSpec(selectedSpec, selectedClass)) or (live and live.role) or "dps"

    S.uiState.viewer.classToken = selectedClass
    S.uiState.viewer.specID = selectedSpec
    S.uiState.viewer.role = selectedRole

    if modeOverride then
        S.uiState.viewer.mode = modeOverride
    elseif live and live.classToken == selectedClass and live.specID == selectedSpec then
        S.uiState.viewer.mode = "live"
    else
        S.uiState.viewer.mode = "browse"
    end

    PersistViewerState()
end

local function EnsureViewerState()
    local live = GetLivePlayerProfile()
    if not live then return end

    local saved = S.db and S.db.viewer
    if saved and saved.classToken and saved.specID then
        SetViewerState(saved.classToken, saved.role, saved.specID, saved.mode or "browse")
        return
    end

    if not S.uiState.viewer.classToken or not S.uiState.viewer.specID then
        SetViewerState(live.classToken, live.role, live.specID, "live")
    end
end

GetViewerProfile = function()
    EnsureViewerState()

    local live = GetLivePlayerProfile()
    local selectedClass = S.uiState.viewer.classToken or (live and live.classToken)
    local selectedSpec = S.uiState.viewer.specID or (live and live.specID)
    if not selectedClass or not selectedSpec then
        return live
    end

    local meta = GetSpecMeta(selectedSpec, selectedClass)
    return {
        mode = S.uiState.viewer.mode or "live",
        classToken = selectedClass,
        classLabel = GetClassLabel(selectedClass),
        specID = selectedSpec,
        specName = meta.specName,
        role = S.uiState.viewer.role or meta.role,
        specKey = selectedClass .. "_" .. selectedSpec,
        isLive = live and live.classToken == selectedClass and live.specID == selectedSpec and (S.uiState.viewer.mode or "live") == "live" or false,
    }
end

BuildPerspectiveSummary = function()
    local profile = GetViewerProfile()
    if not profile then return nil end

    local base = format("Viewing %s %s (%s).", profile.specName or "Spec", profile.classLabel or "Unknown", ROLE_LABELS[profile.role] or "Role")
    if profile.mode == "browse" then
        return base .. " Group and raid pages simulate your slot as this spec."
    end
    return base
end

local function EntryMatchesView(entry, ctx, activityKey)
    local entryActivity = entry.activity or "all"
    local currentActivity = activityKey or "world"

    if entryActivity ~= "all" and entryActivity ~= currentActivity then
        return false
    end

    if not entry.contextKey then
        return true
    end

    local selectedContextKey = GetContextSelector(currentActivity, ctx)
    return selectedContextKey == entry.contextKey
end

local function BuildPersonalViewModel(ctx, profile)
    local data = GetData()
    if not data or not profile or not profile.specKey then
        return {
            tabs = {
                overview = {},
                gear = {},
                trinkets = {},
                consumes = {},
                enchants = {},
                talents = {},
            },
        }
    end

    EnsurePersonalSchema(data)
    local activityKey = GetActivityKey(ctx)
    local sourceEntries = data.personal.bySpec[profile.specKey] or {}
    local view = {
        tabs = {
            overview = {},
            gear = {},
            trinkets = {},
            consumes = {},
            enchants = {},
            talents = {},
        },
    }

    local talentSpecific = {}
    local talentGeneral = {}

    for _, entry in ipairs(sourceEntries) do
        if IsSourceEnabled(entry.source) and EntryMatchesView(entry, ctx, activityKey) then
            local tab = entry.tab
            if tab and view.tabs[tab] then
                view.tabs[tab][#view.tabs[tab] + 1] = entry
            end

            if entry.buildType == "talent" then
                if entry.contextKey then
                    talentSpecific[#talentSpecific + 1] = entry
                else
                    talentGeneral[#talentGeneral + 1] = entry
                end
            end
        end
    end

    if activityKey == "dungeon" and #talentSpecific > 0 then
        view.tabs.talents = {}
        for _, entry in ipairs(sourceEntries) do
            if IsSourceEnabled(entry.source) and entry.buildType ~= "talent" and entry.tab == "talents" and EntryMatchesView(entry, ctx, activityKey) then
                view.tabs.talents[#view.tabs.talents + 1] = entry
            end
        end
        for _, entry in ipairs(talentSpecific) do
            view.tabs.talents[#view.tabs.talents + 1] = entry
        end
    elseif activityKey == "dungeon" and #talentGeneral > 0 then
        view.tabs.talents = {}
        for _, entry in ipairs(sourceEntries) do
            if IsSourceEnabled(entry.source) and entry.buildType ~= "talent" and entry.tab == "talents" and EntryMatchesView(entry, ctx, activityKey) then
                view.tabs.talents[#view.tabs.talents + 1] = entry
            end
        end
        for _, entry in ipairs(talentGeneral) do
            view.tabs.talents[#view.tabs.talents + 1] = entry
        end
    end

    if view.tabs.talents then
        local builds, extras = {}, {}
        for _, entry in ipairs(view.tabs.talents) do
            if entry.buildType == "talent" then
                builds[#builds + 1] = entry
            else
                extras[#extras + 1] = entry
            end
        end
        table.sort(builds, function(a, b)
            return (a.popularity or 0) > (b.popularity or 0)
        end)
        view.tabs.talents = {}
        for _, entry in ipairs(builds) do
            view.tabs.talents[#view.tabs.talents + 1] = entry
        end
        for _, entry in ipairs(extras) do
            view.tabs.talents[#view.tabs.talents + 1] = entry
        end
    end

    return view
end

local function SeverityToTone(severity)
    if severity == "critical" or severity == "high" then return "critical" end
    if severity == "warning" or severity == "medium" then return "warning" end
    return "info"
end

local function CreatePageEntry(id, kind, title, body, tone, extra)
    local entry = {
        id = id,
        kind = kind,
        title = title,
        body = body,
        tone = tone or "info",
    }
    if extra then
        for key, value in pairs(extra) do
            entry[key] = value
        end
    end
    return entry
end

local function EnsureContextPages(context, scopeKey)
    if not context then return nil end
    if context.pages then return context.pages end

    local pages = {
        you = {
            overview = {},
            mechanics = {},
            loadout = {},
            utility = {},
            assignments = {},
            helpers = {},
            workarounds = {},
        },
        group = {
            overview = {},
            mechanics = {},
            loadout = {},
            utility = {},
            assignments = {},
            helpers = {},
            workarounds = {},
        },
        raid = {
            overview = {},
            mechanics = {},
            loadout = {},
            utility = {},
            assignments = {},
            helpers = {},
            workarounds = {},
        },
    }

    local noteLines = {}
    AppendLines(noteLines, context.notes)
    for index, line in ipairs(noteLines) do
        pages.you.overview[#pages.you.overview + 1] = CreatePageEntry(
            format("%s:you:overview:%d", scopeKey, index),
            "callout",
            context.name or "Overview",
            line,
            "info")
        pages.group.overview[#pages.group.overview + 1] = CreatePageEntry(
            format("%s:group:overview:%d", scopeKey, index),
            "callout",
            context.name or "Overview",
            line,
            "info")
    end

    local youLines = {}
    AppendLines(youLines, context.youNotes)
    for index, line in ipairs(youLines) do
        pages.you.overview[#pages.you.overview + 1] = CreatePageEntry(
            format("%s:you:note:%d", scopeKey, index),
            "callout",
            "Personal Focus",
            line,
            "info")
    end

    local groupLines = {}
    AppendLines(groupLines, context.groupNotes)
    for index, line in ipairs(groupLines) do
        pages.group.overview[#pages.group.overview + 1] = CreatePageEntry(
            format("%s:group:note:%d", scopeKey, index),
            "callout",
            "Group Focus",
            line,
            "info")
    end

    local raidLines = {}
    AppendLines(raidLines, context.raidNotes)
    for index, line in ipairs(raidLines) do
        pages.raid.overview[#pages.raid.overview + 1] = CreatePageEntry(
            format("%s:raid:note:%d", scopeKey, index),
            "callout",
            "Raid Focus",
            line,
            "info")
    end

    if context.talentNotes then
        pages.you.loadout[#pages.you.loadout + 1] = CreatePageEntry(
            scopeKey .. ":you:loadout",
            "loadout",
            "Loadout Focus",
            context.talentNotes,
            "info")
        pages.group.loadout[#pages.group.loadout + 1] = CreatePageEntry(
            scopeKey .. ":group:loadout",
            "loadout",
            "Loadout Focus",
            context.talentNotes,
            "info")
        pages.raid.loadout[#pages.raid.loadout + 1] = CreatePageEntry(
            scopeKey .. ":raid:loadout",
            "loadout",
            "Loadout Focus",
            context.talentNotes,
            "info")
    end

    for index, danger in ipairs(context.dangers or {}) do
        local entry = CreatePageEntry(
            format("%s:mechanic:%d", scopeKey, index),
            danger.capability and "coverage_gap" or "mechanic",
            danger.mechanic or danger.spell or "Mechanic",
            danger.tip or "",
            SeverityToTone(danger.severity),
            {
                source = danger.source,
                mob = danger.source,
                spell = danger.mechanic,
                encounter = danger.encounter,
                requiresCapability = danger.capability,
            })
        pages.you.mechanics[#pages.you.mechanics + 1] = entry
        pages.group.mechanics[#pages.group.mechanics + 1] = entry
    end

    for index, tip in ipairs(context.talentTips or {}) do
        pages.you.loadout[#pages.you.loadout + 1] = CreatePageEntry(
            format("%s:tip:%d", scopeKey, index),
            "helper",
            tip.spell or "Class Tip",
            tip.tip or "",
            "info",
            {
                source = "icyveins",
                spell = tip.spell,
            })
    end

    for index, timing in ipairs(context.lustTimings or {}) do
        local title = timing.timing or "Lust Timing"
        pages.group.assignments[#pages.group.assignments + 1] = CreatePageEntry(
            format("%s:lust:%d", scopeKey, index),
            "assignment",
            title,
            timing.note or "",
            "warning",
            { source = timing.source or "wowhead" })
        pages.raid.assignments[#pages.raid.assignments + 1] = CreatePageEntry(
            format("%s:raidlust:%d", scopeKey, index),
            "assignment",
            title,
            timing.note or "",
            "warning",
            { source = timing.source or "wowhead" })
    end

    context.pages = pages
    return pages
end

local function GetContextPage(scope, ctx)
    local context = ResolveInstanceContext(GetData(), ctx)
    if not context then return nil, nil end
    local scopeKey = GetContextKey(ctx)
    local pages = EnsureContextPages(context, scopeKey)
    return pages and pages[scope], context
end

local function GetPageTitle(pageId)
    local titles = {
        personal = "Personal",
        delve_you = "Delves / You",
        delve_group = "Delves / Group",
        dungeon_you = "Dungeons / You",
        dungeon_group = "Dungeons / Group",
        raid_you = "Raids / You",
        raid_group = "Raids / Group",
        raid_raid = "Raids / Raid",
    }
    return titles[pageId] or "Reminders"
end

local function GetSubtitleText(ctx)
    local detected = GetDetectedLabel(GetCurrentContext())
    local selected = GetDetectedLabel(ctx)
    local viewer = GetViewerProfile()
    local viewerText = viewer and format("%s %s", viewer.specName or "Spec", viewer.classLabel or "Unknown") or nil
    if S.overrideContext and viewerText then
        return format("Detected: %s\nViewing: %s\nPerspective: %s", detected, selected, viewerText)
    end
    if S.overrideContext then
        return format("Detected: %s\nViewing: %s", detected, selected)
    end
    if viewer and viewer.mode == "browse" then
        return format("Detected: %s\nPerspective: %s", detected, viewerText)
    end
    if viewerText then
        return format("Detected: %s\nPerspective: %s", detected, viewerText)
    else
        return "Detected: " .. detected
    end
end

local function EnsureSelectedPage(activityKey)
    if S.uiState.selectedPage == "personal" then return end

    if activityKey == "delve" and S.uiState.selectedPage:find("^delve_") then return end
    if activityKey == "dungeon" and S.uiState.selectedPage:find("^dungeon_") then return end

    S.uiState.selectedPage = "personal"
end

local function BuildNavigationModel(activityKey)
    local delveEnabled = activityKey == "delve"
    local dungeonEnabled = activityKey == "dungeon"

    return {
        { label = "Personal", pageId = "personal", enabled = true },
        {
            label = "Delves",
            pageId = "nav_delves",
            enabled = true,
            expanded = S.uiState.navExpanded.delves,
            children = {
                { label = "You", pageId = "delve_you", enabled = delveEnabled },
                { label = "Group", pageId = "delve_group", enabled = delveEnabled },
            },
        },
        {
            label = "Dungeons",
            pageId = "nav_dungeons",
            enabled = true,
            expanded = S.uiState.navExpanded.dungeons,
            children = {
                { label = "You", pageId = "dungeon_you", enabled = dungeonEnabled },
                { label = "Group", pageId = "dungeon_group", enabled = dungeonEnabled },
            },
        },
    }
end

local function GetContentWidth()
    if S.uiState.workspaceShell and S.uiState.workspaceShell.contentHost and S.uiState.workspaceShell.contentHost:GetWidth() > 0 then
        return S.uiState.workspaceShell.contentHost:GetWidth() - 24
    end
    return 560
end

local function ResetContent(content)
    local children = { content:GetChildren() }
    for _, child in ipairs(children) do
        child:Hide()
        child:SetParent(nil)
    end
    local regions = { content:GetRegions() }
    for _, region in ipairs(regions) do
        region:Hide()
    end
end

local function AddWrappedText(parent, yOff, text, r, g, b, leftInset, fontObject)
    local fs = parent:CreateFontString(nil, "OVERLAY", fontObject or "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", leftInset or 8, yOff)
    fs:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    fs:SetTextColor(r or 0.85, g or 0.85, b or 0.85)
    fs:SetText(text or "")
    return yOff - fs:GetStringHeight() - 4, fs
end

ResolveSpellID = function(spellRef)
    if type(spellRef) == "number" then
        return (spellRef > 0) and spellRef or nil
    end
    if type(spellRef) ~= "string" or spellRef == "" or not C_Spell or not C_Spell.GetSpellInfo then
        return nil
    end

    local ok, info = pcall(C_Spell.GetSpellInfo, spellRef)
    if ok and info and info.spellID then
        return info.spellID
    end
    return nil
end

BeginSpellTooltip = function(tip, spellRef, fallbackTitle)
    local spellID = ResolveSpellID(spellRef)
    if spellID and tip and tip.SetSpellByID then
        local ok = pcall(tip.SetSpellByID, tip, spellID)
        if ok then return true, spellID end
    end
    if fallbackTitle and fallbackTitle ~= "" then
        tip:AddLine(fallbackTitle, 1, 0.82, 0)
    end
    return false, spellID
end

local function BeginItemTooltip(tip, itemRef, fallbackTitle)
    if type(itemRef) == "string" and itemRef ~= "" and tip and tip.SetHyperlink then
        local ok = pcall(tip.SetHyperlink, tip, itemRef)
        if ok then return true, itemRef end
    elseif type(itemRef) == "number" and itemRef > 0 and tip and tip.SetHyperlink then
        local ok = pcall(tip.SetHyperlink, tip, "item:" .. itemRef)
        if ok then return true, itemRef end
    end
    if fallbackTitle and fallbackTitle ~= "" then
        tip:AddLine(fallbackTitle, 1, 0.82, 0)
    end
    return false, itemRef
end

local function GetRecommendationTooltipItemRef(item)
    if not item then return nil end
    if type(item.tooltipLink) == "string" and item.tooltipLink ~= "" then
        return item.tooltipLink
    end
    if type(item.itemLink) == "string" and item.itemLink ~= "" then
        return item.itemLink
    end
    if type(item.tooltipItemString) == "string" and item.tooltipItemString ~= "" then
        return item.tooltipItemString
    end
    if type(item.tooltipHyperlink) == "string" and item.tooltipHyperlink ~= "" then
        return item.tooltipHyperlink
    end
    if type(item.itemID) == "number" and item.itemID > 0 then
        return item.itemID
    end
    if type(item.wowheadId) == "number" and item.wowheadId > 0 then
        return item.wowheadId
    end
    return nil
end

local function AddTooltipKeyValue(tip, label, value, r, g, b)
    if value == nil or value == "" then return end
    tip:AddLine(label .. ": " .. tostring(value), r or 0.75, g or 0.75, b or 0.75, true)
end

local function AddItemLevelMetadata(tip, item)
    if not item then return end
    local hasMetadata = item.maxItemLevel or item.tooltipItemLevel or item.upgradeTrack or item.track
        or item.tooltipDifficulty or item.tooltipSource or item.tooltipInstance
    if not hasMetadata then return end

    AddTooltipKeyValue(tip, "Shown as", item.upgradeTrack or item.track, 0.4, 0.8, 1.0)
    AddTooltipKeyValue(tip, "Item Level", item.tooltipItemLevel or item.maxItemLevel, 1, 1, 1)
    AddTooltipKeyValue(tip, "Variant", item.tooltipDifficulty, 0.85, 0.85, 0.85)
    AddTooltipKeyValue(tip, "Drops From", item.tooltipSource, 0.85, 0.85, 0.85)
    AddTooltipKeyValue(tip, "Instance", item.tooltipInstance, 0.85, 0.85, 0.85)
end

AddTooltipSpacer = function(tip)
    if tip and tip.NumLines and tip:NumLines() > 0 then
        tip:AddLine(" ")
    end
end

local function BindTooltip(frame, tooltipFunc)
    if not frame then return end

    if not tooltipFunc then
        frame:EnableMouse(false)
        frame:SetScript("OnEnter", nil)
        frame:SetScript("OnLeave", nil)
        return
    end

    frame:EnableMouse(true)

    if not frame._medaHoverHighlight then
        local highlight = frame:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.04)
        frame._medaHoverHighlight = highlight
    end

    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        tooltipFunc(self, GameTooltip)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

CreateTooltipTextLine = function(parent, yOff, text, tooltipFunc, leftInset, rightInset)
    local button = CreateFrame("Button", nil, parent)
    button:SetPoint("TOPLEFT", leftInset or 8, yOff)
    button:SetPoint("RIGHT", parent, "RIGHT", -(rightInset or 8), 0)
    button:SetHeight(16)

    local fs = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetAllPoints()
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    fs:SetText(text or "")

    BindTooltip(button, tooltipFunc)
    return button, fs
end

CreateTooltipTextBlock = function(parent, yOff, text, tooltipFunc, leftInset, rightInset)
    local button = CreateFrame("Button", nil, parent)
    button:SetPoint("TOPLEFT", leftInset or 8, yOff)
    button:SetPoint("RIGHT", parent, "RIGHT", -(rightInset or 8), 0)

    local fs = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", 0, 0)
    fs:SetPoint("RIGHT", button, "RIGHT", 0, 0)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    fs:SetText(text or "")

    local height = math.max(14, fs:GetStringHeight())
    button:SetHeight(height)

    BindTooltip(button, tooltipFunc)
    return button, fs, height
end

AddRecommendationTooltip = function(tip, item, rec)
    if not item then return end

    BeginItemTooltip(tip, GetRecommendationTooltipItemRef(item), item.name)
    AddTooltipSpacer(tip)
    AddItemLevelMetadata(tip, item)

    if item.slot and item.slot ~= "" then
        tip:AddLine("Slot: " .. item.slot, 0.75, 0.75, 0.75)
    end
    if item.category and item.category ~= "" then
        tip:AddLine("Category: " .. item.category, 0.75, 0.75, 0.75)
    end
    if item.popularity then
        tip:AddLine(format("Popularity: %.1f%%", item.popularity), 1, 1, 1)
    end
    if item.enchant and item.enchant ~= "" then
        tip:AddLine("Enchant: " .. item.enchant, 0.4, 0.8, 1.0, true)
    end
    if item.gem and item.gem ~= "" then
        tip:AddLine("Gem: " .. item.gem, 0.4, 0.8, 1.0, true)
    end
    if item.tooltipNote and item.tooltipNote ~= "" and not (item.tooltipSource or item.tooltipInstance) then
        tip:AddLine(item.tooltipNote, 0.75, 0.75, 0.75, true)
    end

    local sourceInfo = rec and rec.source and GetData() and GetData().sources and GetData().sources[rec.source]
    if sourceInfo and sourceInfo.label then
        tip:AddLine("Source: " .. sourceInfo.label, 0.65, 0.65, 0.65)
    end
end

GetResultTooltipSpellID = function(result)
    if not result then return nil end

    local found
    local conflicted = false

    local function Consider(spellID)
        if type(spellID) ~= "number" or spellID <= 0 then return end
        if not found then
            found = spellID
        elseif found ~= spellID then
            conflicted = true
        end
    end

    for _, match in ipairs(result.matches or {}) do
        Consider(match.spellID)
        if conflicted then return nil end
    end

    if not found and result.capability and result.capability.providers then
        for _, provider in ipairs(result.capability.providers) do
            Consider(provider.spellID)
            if conflicted then return nil end
        end
    end

    return conflicted and nil or found
end

local function AddCard(parent, yOff, title, body, accent)
    local width = GetContentWidth() - 8
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetBackdrop(MedaUI:CreateBackdrop(true))
    card:SetPoint("TOPLEFT", 4, yOff)
    card:SetPoint("RIGHT", parent, "RIGHT", -4, 0)

    local theme = MedaUI.Theme
    local bg = theme.backgroundLight or { 0.16, 0.16, 0.17, 1 }
    local border = theme.border or { 0.2, 0.2, 0.22, 0.6 }
    card:SetBackdropColor(bg[1], bg[2], bg[3], 0.5)
    card:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 0.6)

    local accentTex = card:CreateTexture(nil, "ARTWORK")
    accentTex:SetColorTexture((accent and accent[1]) or theme.gold[1], (accent and accent[2]) or theme.gold[2], (accent and accent[3]) or theme.gold[3], 1)
    accentTex:SetPoint("TOPLEFT", 0, 0)
    accentTex:SetPoint("BOTTOMLEFT", 0, 0)
    accentTex:SetWidth(3)

    local titleFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFS:SetPoint("TOPLEFT", 10, -8)
    titleFS:SetPoint("RIGHT", card, "RIGHT", -10, 0)
    titleFS:SetJustifyH("LEFT")
    titleFS:SetTextColor(unpack(theme.gold or { 0.9, 0.7, 0.15, 1 }))
    titleFS:SetText(title or "")

    local bodyFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bodyFS:SetPoint("TOPLEFT", titleFS, "BOTTOMLEFT", 0, -6)
    bodyFS:SetPoint("RIGHT", card, "RIGHT", -10, 0)
    bodyFS:SetJustifyH("LEFT")
    bodyFS:SetWordWrap(true)
    bodyFS:SetTextColor(unpack(theme.text or { 0.9, 0.9, 0.9, 1 }))
    bodyFS:SetText(body or "")

    local height = 18 + bodyFS:GetStringHeight() + 20
    card:SetHeight(height)
    return yOff - height - 8
end

local function GetSpecRecommendations(ctx)
    local data = GetData()
    local profile = GetViewerProfile()
    if not data or not profile or not profile.specKey then return nil, {}, {}, {} end

    local view = BuildPersonalViewModel(ctx, profile)
    local buckets = {
        talent = {},
        stats = {},
        gear = {},
        enchants = {},
        consumables = {},
        trinkets = {},
        hero_talent = {},
    }

    local tabMapping = {
        talents = { talent = true, hero_talent = true, stats = true },
        gear = { gear = true },
        trinkets = { trinkets = true },
        consumes = { consumables = true },
        enchants = { enchants = true },
    }

    for tabKey, entries in pairs(view.tabs) do
        local allowed = tabMapping[tabKey]
        if allowed then
            for _, entry in ipairs(entries) do
                if buckets[entry.buildType] and allowed[entry.buildType] then
                    buckets[entry.buildType][#buckets[entry.buildType] + 1] = entry
                end
            end
        end
    end

    return profile.specKey, data.personal and data.personal.bySpec and data.personal.bySpec[profile.specKey] or {}, buckets, data
end

local GEAR_SLOT_LABELS = {
    ["INVTYPE_HEAD"] = "Head",
    ["INVTYPE_NECK"] = "Neck",
    ["INVTYPE_SHOULDER"] = "Shoulders",
    ["INVTYPE_CLOAK"] = "Back",
    ["INVTYPE_CHEST"] = "Chest",
    ["INVTYPE_ROBE"] = "Chest",
    ["INVTYPE_WRIST"] = "Wrists",
    ["INVTYPE_HAND"] = "Hands",
    ["INVTYPE_WAIST"] = "Waist",
    ["INVTYPE_LEGS"] = "Legs",
    ["INVTYPE_FEET"] = "Feet",
    ["INVTYPE_FINGER"] = "Rings",
    ["INVTYPE_TRINKET"] = "Trinkets",
    ["INVTYPE_WEAPON"] = "Main Hand",
    ["INVTYPE_2HWEAPON"] = "Main Hand",
    ["INVTYPE_WEAPONMAINHAND"] = "Main Hand",
    ["INVTYPE_WEAPONOFFHAND"] = "Off Hand",
    ["INVTYPE_HOLDABLE"] = "Off Hand",
    ["INVTYPE_SHIELD"] = "Off Hand",
    ["INVTYPE_RANGED"] = "Ranged",
    ["INVTYPE_RANGEDRIGHT"] = "Ranged",
}

local GEAR_SLOT_SORT_ORDER = {
    Head = 1,
    Neck = 2,
    Shoulders = 3,
    Back = 4,
    Chest = 5,
    Wrists = 6,
    Hands = 7,
    Waist = 8,
    Legs = 9,
    Feet = 10,
    Rings = 11,
    Trinkets = 12,
    ["Main Hand"] = 13,
    ["Off Hand"] = 14,
    Ranged = 15,
    Item = 99,
}

local function NormalizeGearSlotLabel(slot)
    if type(slot) ~= "string" or slot == "" then
        return nil
    end

    local normalized = slot:gsub("_", " "):gsub("%-", " ")
    normalized = normalized:gsub("^%l", string.upper)
    normalized = normalized:gsub("(%s+%l)", string.upper)

    local aliases = {
        ["Shoulder"] = "Shoulders",
        ["Shoulders"] = "Shoulders",
        ["Wrist"] = "Wrists",
        ["Wrists"] = "Wrists",
        ["Finger"] = "Rings",
        ["Ring"] = "Rings",
        ["Rings"] = "Rings",
        ["Trinket"] = "Trinkets",
        ["Trinkets"] = "Trinkets",
        ["Main Hand"] = "Main Hand",
        ["Mainhand"] = "Main Hand",
        ["Off Hand"] = "Off Hand",
        ["Offhand"] = "Off Hand",
        ["Cloak"] = "Back",
        ["Back"] = "Back",
    }

    return aliases[normalized] or normalized
end

local function GetRecommendationItemID(item)
    if not item then return nil end
    if type(item.itemID) == "number" and item.itemID > 0 then
        return item.itemID
    end
    if type(item.wowheadId) == "number" and item.wowheadId > 0 then
        return item.wowheadId
    end

    local refs = {
        item.tooltipLink,
        item.itemLink,
        item.tooltipItemString,
        item.tooltipHyperlink,
    }
    for _, ref in ipairs(refs) do
        if type(ref) == "string" then
            local itemID = tonumber(ref:match("item:(%d+)"))
            if itemID and itemID > 0 then
                return itemID
            end
        end
    end

    return nil
end

local function GetRecommendationInstantItemInfo(item)
    local itemID = GetRecommendationItemID(item)
    if not itemID then return nil, nil, nil end

    local equipLoc, icon
    if GetItemInfoInstant then
        local _, _, _, itemEquipLoc, itemIcon = GetItemInfoInstant(itemID)
        equipLoc = itemEquipLoc
        icon = itemIcon
    end

    if (not equipLoc or equipLoc == "") and C_Item and C_Item.GetItemInfoInstant then
        local _, _, _, itemEquipLoc, itemIcon = C_Item.GetItemInfoInstant(itemID)
        equipLoc = equipLoc or itemEquipLoc
        icon = icon or itemIcon
    end

    return itemID, equipLoc, icon
end

local function GetRecommendationSlotLabel(item)
    if item and item.slot and item.slot ~= "" then
        return NormalizeGearSlotLabel(item.slot)
    end

    local _, equipLoc = GetRecommendationInstantItemInfo(item)
    if equipLoc and GEAR_SLOT_LABELS[equipLoc] then
        return GEAR_SLOT_LABELS[equipLoc]
    end

    return "Item"
end

local function GetRecommendationIcon(item)
    if item and type(item.icon) == "number" and item.icon > 0 then
        return item.icon
    end

    local _, _, icon = GetRecommendationInstantItemInfo(item)
    return icon or 134400
end

local function BuildGearDetailText(item)
    if not item then return nil end

    local details = {}
    if item.tooltipItemLevel or item.maxItemLevel then
        details[#details + 1] = "iLvl " .. tostring(item.tooltipItemLevel or item.maxItemLevel)
    end
    if item.upgradeTrack and item.upgradeTrack ~= "" then
        details[#details + 1] = tostring(item.upgradeTrack)
    end
    if item.tooltipDifficulty and item.tooltipDifficulty ~= "" then
        details[#details + 1] = tostring(item.tooltipDifficulty)
    end
    if item.enchant and item.enchant ~= "" then
        details[#details + 1] = "Enchant: " .. item.enchant
    end
    if item.gem and item.gem ~= "" then
        details[#details + 1] = "Gem: " .. item.gem
    end

    return (#details > 0) and table.concat(details, "  ") or nil
end

local function GetRecommendationCardLabel(item, fallback)
    local slotLabel = GetRecommendationSlotLabel(item)
    if slotLabel and slotLabel ~= "" and slotLabel ~= "Item" then
        return slotLabel
    end
    if item and item.category and item.category ~= "" then
        return tostring(item.category)
    end
    return fallback or "Item"
end

local function BuildRecommendationCardDetailText(item)
    local detail = BuildGearDetailText(item)
    if detail then
        return detail
    end

    local details = {}
    if item and item.effect and item.effect ~= "" then
        details[#details + 1] = tostring(item.effect)
    end
    if item and item.tooltipNote and item.tooltipNote ~= "" and not item.tooltipSource then
        details[#details + 1] = tostring(item.tooltipNote)
    end

    return (#details > 0) and table.concat(details, "  ") or nil
end

local function SortGearRecommendationItems(items)
    table.sort(items, function(a, b)
        local slotA = GetRecommendationSlotLabel(a)
        local slotB = GetRecommendationSlotLabel(b)
        local orderA = GEAR_SLOT_SORT_ORDER[slotA] or 98
        local orderB = GEAR_SLOT_SORT_ORDER[slotB] or 98

        if orderA ~= orderB then
            return orderA < orderB
        end

        local popA = a and a.popularity or 0
        local popB = b and b.popularity or 0
        if popA ~= popB then
            return popA > popB
        end

        return (a and a.name or "") < (b and b.name or "")
    end)
end

RenderRecommendationCardGrid = function(parent, yOff, title, rec, usedSet, config)
    if not rec or not rec.content or not rec.content.items or #rec.content.items == 0 then
        return yOff
    end

    config = config or {}
    MarkSource(usedSet, rec.source)

    local items = {}
    for i = 1, #rec.content.items do
        items[#items + 1] = rec.content.items[i]
    end
    if config.sortFunc then
        config.sortFunc(items)
    end

    local totalItems = #items
    local sectionKey = config.sectionKey
    local maxVisible = config.maxVisible or totalItems
    local expandState = config.expandState or S.talentSectionExpanded
    local sectionExpanded = sectionKey and (expandState[sectionKey] or false) or false
    local shown = sectionKey and (sectionExpanded and totalItems or math.min(totalItems, maxVisible)) or math.min(totalItems, maxVisible)

    local theme = MedaUI.Theme
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetBackdrop(MedaUI:CreateBackdrop(true))
    card:SetPoint("TOPLEFT", 4, yOff)
    card:SetPoint("RIGHT", parent, "RIGHT", -4, 0)
    card:SetBackdropColor(theme.backgroundLight[1], theme.backgroundLight[2], theme.backgroundLight[3], 0.4)
    card:SetBackdropBorderColor(theme.border[1], theme.border[2], theme.border[3], theme.border[4] or 0.6)

    local titleFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFS:SetPoint("TOPLEFT", 10, -8)
    titleFS:SetTextColor(unpack(theme.gold or { 0.9, 0.7, 0.15, 1 }))
    titleFS:SetText(title)

    local sourceFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sourceFS:SetPoint("LEFT", titleFS, "RIGHT", 8, 0)
    sourceFS:SetTextColor(unpack(theme.textDim or { 0.6, 0.6, 0.6, 1 }))
    sourceFS:SetText(FormatSourceBadge(rec.source) .. format("  %d %s", totalItems, config.countLabel or "items"))

    local topInset = 38
    if config.hintText and config.hintText ~= "" then
        local hintFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hintFS:SetPoint("TOPLEFT", titleFS, "BOTTOMLEFT", 0, -4)
        hintFS:SetPoint("RIGHT", card, "RIGHT", -10, 0)
        hintFS:SetJustifyH("LEFT")
        hintFS:SetWordWrap(true)
        hintFS:SetTextColor(unpack(theme.textDim or { 0.6, 0.6, 0.6, 1 }))
        hintFS:SetText(config.hintText)
        topInset = 56
    end

    local cardWidth = math.max(320, GetContentWidth() - 8)
    local cols = config.columns or ((cardWidth >= 720 and totalItems > 1) and 2 or 1)
    local gap = 10
    local innerPad = 10
    local slotHeight = config.itemHeight or 78
    local slotWidth = math.floor((cardWidth - (innerPad * 2) - (gap * (cols - 1))) / cols)

    for i = 1, shown do
        local item = items[i]
        local row = math.floor((i - 1) / cols)
        local col = (i - 1) % cols
        local x = innerPad + (slotWidth + gap) * col
        local y = -(topInset + (slotHeight + gap) * row)

        local slotCard = MedaUI:CreateItemSlotCard(card, {
            width = slotWidth,
            height = slotHeight,
        })
        slotCard:SetPoint("TOPLEFT", x, y)
        slotCard:SetSlotLabel((config.labelFunc and config.labelFunc(item, config.defaultLabel)) or GetRecommendationCardLabel(item, config.defaultLabel))
        slotCard:SetValueText(format("%.0f%%", item.popularity or 0))
        slotCard:SetTitle(item.name or "Unknown item")
        slotCard:SetDetail((config.detailFunc and config.detailFunc(item, rec, title)) or BuildRecommendationCardDetailText(item))
        slotCard:SetIcon(GetRecommendationIcon(item))
        slotCard:SetProgress(math.min(math.max((item.popularity or 0) / 100, 0), 1))
        slotCard:SetTooltipFunc(function(_, tip)
            AddRecommendationTooltip(tip, item, rec)
        end)
    end

    local rows = math.ceil(shown / cols)
    local gridHeight = rows > 0 and (rows * slotHeight) + ((rows - 1) * gap) or 0
    local innerY = -(topInset + gridHeight) - 10

    if sectionKey and totalItems > shown then
        local toggle = MedaUI:CreateExpandToggle(card, {
            hiddenCount = totalItems - shown,
            expanded = sectionExpanded,
            onToggle = function(exp)
                expandState[sectionKey] = exp
                if config.onToggle then
                    config.onToggle(exp)
                else
                    RunPipeline(false)
                end
            end,
        })
        toggle:SetPoint("TOPLEFT", 10, innerY)
        toggle:SetPoint("RIGHT", card, "RIGHT", -10, 0)
        innerY = innerY - toggle:GetHeight()
    end

    local cardHeight = math.abs(innerY) + 8
    card:SetHeight(cardHeight)
    return yOff - cardHeight - 8
end

local function RenderGearRecommendationGrid(parent, yOff, title, rec, usedSet, maxVisible)
    return RenderRecommendationCardGrid(parent, yOff, title, rec, usedSet, {
        sectionKey = "personal_gear_visual",
        maxVisible = maxVisible,
        countLabel = "slots",
        hintText = "Character-sheet view with each recommendation pinned to its slot.",
        sortFunc = SortGearRecommendationItems,
        labelFunc = function(item)
            return GetRecommendationSlotLabel(item)
        end,
        detailFunc = function(item)
            return BuildGearDetailText(item)
        end,
    })
end

local function RenderRecommendationList(parent, yOff, title, rec, usedSet, maxVisible)
    return RenderRecommendationCardGrid(parent, yOff, title, rec, usedSet, {
        maxVisible = maxVisible,
        countLabel = "picks",
        defaultLabel = (title == "Top Trinkets" and "Trinket")
            or (title == "Recommended Consumables" and "Consumable")
            or (title == "Enchants & Gems" and "Enhancement")
            or "Item",
        detailFunc = function(item)
            return BuildRecommendationCardDetailText(item)
        end,
    })
end

local function RenderTalentBuilds(parent, yOff, recs, usedSet)
    if not recs or #recs == 0 then return yOff end

    local theme = MedaUI.Theme
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetBackdrop(MedaUI:CreateBackdrop(true))
    card:SetPoint("TOPLEFT", 4, yOff)
    card:SetPoint("RIGHT", parent, "RIGHT", -4, 0)
    card:SetBackdropColor(theme.backgroundLight[1], theme.backgroundLight[2], theme.backgroundLight[3], 0.5)
    card:SetBackdropBorderColor(theme.border[1], theme.border[2], theme.border[3], theme.border[4] or 0.6)

    local titleFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFS:SetPoint("TOPLEFT", 10, -8)
    titleFS:SetTextColor(unpack(theme.gold or { 0.9, 0.7, 0.15, 1 }))
    titleFS:SetText("Recommended Talent Builds")

    local innerY = -30
    local shown = math.min(#recs, 4)
    for i = 1, shown do
        local rec = recs[i]
        local availabilityNote = GetLoadoutAvailabilityNote(rec)
        MarkSource(usedSet, rec.source)
        local hero = rec.heroTree and rec.heroTree ~= "" and rec.heroTree or "Build"
        local detail = FormatSourceBadge(rec.source)
        if rec.notes and rec.notes ~= "" then
            detail = detail .. "  |cffbbbbbb" .. rec.notes:gsub(", raid.*", "") .. "|r"
        end

        local heroFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        heroFS:SetPoint("TOPLEFT", 10, innerY)
        heroFS:SetTextColor(unpack(theme.text or { 0.9, 0.9, 0.9, 1 }))
        heroFS:SetText(hero)

        local detailFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        detailFS:SetPoint("TOPLEFT", heroFS, "BOTTOMLEFT", 0, -2)
        detailFS:SetPoint("RIGHT", card, "RIGHT", CanCopyLoadoutCode(rec) and -72 or -10, 0)
        detailFS:SetJustifyH("LEFT")
        detailFS:SetWordWrap(false)
        detailFS:SetText(detail)

        if availabilityNote then
            local noteFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            noteFS:SetPoint("TOPLEFT", detailFS, "BOTTOMLEFT", 0, -2)
            noteFS:SetPoint("RIGHT", card, "RIGHT", -10, 0)
            noteFS:SetJustifyH("LEFT")
            noteFS:SetWordWrap(true)
            noteFS:SetTextColor(unpack(theme.warning or { 1, 0.7, 0.2, 1 }))
            noteFS:SetText(availabilityNote)
        end

        if CanCopyLoadoutCode(rec) then
            local copyBtn = MedaUI:CreateButton(card, "Copy", 52)
            copyBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, innerY + 4)
            copyBtn:SetHeight(20)
            copyBtn.OnClick = function()
                ShowCopyPopup(rec.content.exportString)
            end
        end

        innerY = innerY - (availabilityNote and 56 or 40)
    end

    local height = math.abs(innerY) + 8
    card:SetHeight(height)
    return yOff - height - 8
end

local function RenderStatsCard(parent, yOff, recs, usedSet)
    local rec = recs and recs[1]
    if not rec or not rec.content then return yOff end

    MarkSource(usedSet, rec.source)

    local pairsList = {}
    for stat, value in pairs(rec.content) do
        if value and value > 0 then
            pairsList[#pairsList + 1] = { stat = stat, value = value }
        end
    end
    table.sort(pairsList, function(a, b) return a.value > b.value end)

    local parts = {}
    for _, entry in ipairs(pairsList) do
        parts[#parts + 1] = format("%s (%d)", entry.stat, entry.value)
    end

    return AddCard(parent, yOff, "Stat Priority", FormatSourceBadge(rec.source) .. "  " .. table.concat(parts, "  >  "))
end

local function RenderPersonalOverview(content, yOff, ctx, buckets, usedSet)
    local activity = GetActivityKey(ctx)
    local activityLabel = ({
        delve = "Delves / Open World",
        dungeon = "Dungeons",
        raid = "Raids",
    })[activity] or "Current Activity"

    yOff = AddCard(content, yOff, "At a Glance", "Focus on the highest-impact changes you can make right now for " .. activityLabel .. ".", RECOMMEND_COLOR)

    if S.playerToolkit and S.playerToolkit.dangers and #S.playerToolkit.dangers > 0 then
        local shown = 0
        for _, danger in ipairs(S.playerToolkit.dangers) do
            if shown >= 3 then break end
            local title = danger.mechanic or "Key mechanic"
            local body = danger.tip or ""
            if danger.response == "canTalent" then
                body = "You can adjust talents for this: " .. body
            elseif danger.response == "have" then
                body = "You already cover this: " .. body
            end
            yOff = AddCard(content, yOff, title, body, SEVERITY_COLORS[danger.severity] or RECOMMEND_COLOR)
            shown = shown + 1
        end
    end

    yOff = RenderTalentBuilds(content, yOff, buckets.talent, usedSet)
    yOff = RenderStatsCard(content, yOff, buckets.stats, usedSet)
    yOff = RenderRecommendationList(content, yOff, "Top Trinkets", buckets.trinkets[1], usedSet, 3)
    yOff = RenderRecommendationList(content, yOff, "Recommended Consumables", buckets.consumables[1], usedSet, 3)

    return yOff
end

local function RenderPersonalPage(ctx)
    if not S.uiState.workspaceShell then return end
    local content = S.uiState.workspaceShell:GetContent()
    ResetContent(content)

    local usedSet = {}
    local viewer = GetViewerProfile()
    local _, _, buckets = GetSpecRecommendations(ctx)
    local hasPersonalData = (#(buckets.talent or {}) + #(buckets.stats or {}) + #(buckets.gear or {})
        + #(buckets.enchants or {}) + #(buckets.consumables or {}) + #(buckets.trinkets or {})) > 0

    local personalTabBar = MedaUI:CreateTabBar(content, {
        { id = "overview", label = "Overview" },
        { id = "gear", label = "Gear" },
        { id = "trinkets", label = "Trinkets" },
        { id = "consumes", label = "Consumes" },
        { id = "enchants", label = "Enchants" },
        { id = "talents", label = "Talents" },
    })
    personalTabBar:SetPoint("TOPLEFT", 4, -4)
    personalTabBar:SetPoint("TOPRIGHT", -4, -4)
    personalTabBar:SetActiveTab(S.uiState.selectedPersonalTab or "overview")
    personalTabBar.OnTabChanged = function(_, tabId)
        S.uiState.selectedPersonalTab = tabId
        RunPipeline(false)
    end

    local yOff = -40
    if viewer and viewer.mode == "browse" then
        yOff = AddCard(content, yOff, "Theorycraft View",
            format("Showing recommendations for %s %s. Personal pages ignore your live inventory and show this spec's data directly.",
                viewer.specName or "Spec", viewer.classLabel or "Unknown"),
            SEVERITY_COLORS.info)
    end

    if S.uiState.selectedPersonalTab == "overview" then
        yOff = RenderPersonalOverview(content, yOff, ctx, buckets, usedSet)
    elseif S.uiState.selectedPersonalTab == "gear" then
        yOff = RenderGearRecommendationGrid(content, yOff, "Popular Gear", buckets.gear[1], usedSet, 8)
    elseif S.uiState.selectedPersonalTab == "trinkets" then
        yOff = RenderRecommendationList(content, yOff, "Top Trinkets", buckets.trinkets[1], usedSet, 6)
    elseif S.uiState.selectedPersonalTab == "consumes" then
        yOff = RenderRecommendationList(content, yOff, "Recommended Consumables", buckets.consumables[1], usedSet, 6)
    elseif S.uiState.selectedPersonalTab == "enchants" then
        yOff = RenderRecommendationList(content, yOff, "Enchants & Gems", buckets.enchants[1], usedSet, 6)
    elseif S.uiState.selectedPersonalTab == "talents" then
        yOff = RenderTalentBuilds(content, yOff, buckets.talent, usedSet)
        yOff = RenderStatsCard(content, yOff, buckets.stats, usedSet)
    end

    if not hasPersonalData then
        yOff = AddCard(content, yOff, "No Data Yet", "No recommendations are available for this specialization and activity.", SEVERITY_COLORS.info)
    end

    S.uiState.workspaceShell:SetContentHeight(math.abs(yOff) + 32)
    return usedSet
end

local function RenderStructuredPageSections(content, yOff, page, usedSet)
    if not page then return yOff end

    local sectionLabels = {
        overview = "Overview",
        mechanics = "Key Mechanics",
        loadout = "Loadout",
        utility = "Utility",
        assignments = "Assignments",
        helpers = "Helpers",
        workarounds = "Workarounds",
    }

    for _, sectionKey in ipairs(PAGE_SECTION_ORDER) do
        local entries = page[sectionKey]
        if entries and #entries > 0 then
            local header = MedaUI:CreateSectionHeader(content, sectionLabels[sectionKey] or sectionKey, GetContentWidth() - 8)
            header:SetPoint("TOPLEFT", 4, yOff)
            yOff = yOff - 32

            for _, entry in ipairs(entries) do
                MarkSource(usedSet, entry.source)
                if entry.kind == "mechanic" or entry.kind == "coverage_gap" or entry.kind == "helper" then
                    local row = MedaUI:CreateStatusRow(content, { width = GetContentWidth(), iconSize = 24, showNote = true, cardStyle = true })
                    row:SetPoint("TOPLEFT", 4, yOff)
                    row:SetPoint("RIGHT", content, "RIGHT", -4, 0)
                    row:SetIcon(136116)
                    row:SetLabel(entry.title or "Helper")
                    local accent = SEVERITY_COLORS[entry.tone] or RECOMMEND_COLOR
                    row:SetAccentColor(accent[1], accent[2], accent[3])
                    row:SetStatus(entry.encounter or sectionLabels[sectionKey] or "Info", accent[1], accent[2], accent[3])
                    row:SetNote(entry.body or "")
                    yOff = yOff - row:GetHeight() - 8
                else
                    yOff = AddCard(content, yOff, entry.title or sectionLabels[sectionKey] or "Info", entry.body or "", SEVERITY_COLORS[entry.tone] or RECOMMEND_COLOR)
                end
            end

            yOff = yOff - 8
        end
    end

    return yOff
end

local function RenderYouPage(ctx)
    if not S.uiState.workspaceShell then return {} end
    local content = S.uiState.workspaceShell:GetContent()
    ResetContent(content)

    local usedSet = {}
    local yOff = -4
    local tk = S.playerToolkit
    local page, instanceCtx = GetContextPage("you", ctx)
    local viewer = GetViewerProfile()

    if not tk and instanceCtx and instanceCtx.youNotes then
        tk = {
            notes = instanceCtx.youNotes,
            dangers = {},
            tips = {},
            lusts = {},
            interactiveBuffs = {},
            header = instanceCtx.name or "Instance",
            tier = ctx and ctx.difficultyTier or "normal",
        }
    end

    if not tk then
        yOff = AddCard(content, yOff, "No Personal Data", "Select or enter content to see what your character can do here.", SEVERITY_COLORS.info)
        S.uiState.workspaceShell:SetContentHeight(math.abs(yOff) + 32)
        return usedSet
    end

    if viewer and viewer.mode == "browse" then
        yOff = AddCard(content, yOff, "Theorycraft View",
            format("Showing %s %s as your viewer profile. Availability checks are simulated for this spec.", viewer.specName or "Spec", viewer.classLabel or "Unknown"),
            SEVERITY_COLORS.info)
    end

    yOff = AddCard(content, yOff, tk.header or "Instance Briefing", table.concat(tk.notes or { "No instance notes available." }, "\n"), RECOMMEND_COLOR)
    yOff = RenderStructuredPageSections(content, yOff, page, usedSet)

    if tk.dangers and #tk.dangers > 0 then
        local section = MedaUI:CreateSectionHeader(content, "Key Dangers", GetContentWidth() - 8)
        section:SetPoint("TOPLEFT", 4, yOff)
        yOff = yOff - 32

        local spellMap = BuildSpellMap(tk.dangers)
        for i = 1, math.min(#tk.dangers, 6) do
            local danger = tk.dangers[i]
            local row = MedaUI:CreateStatusRow(content, { width = GetContentWidth(), iconSize = 28, showNote = true, cardStyle = true })
            row:SetPoint("TOPLEFT", 4, yOff)
            row:SetPoint("RIGHT", content, "RIGHT", -4, 0)
            row:SetIcon((type(danger.icon) == "number" and danger.icon > 0 and danger.icon) or 136116)
            row:SetLabel(danger.mechanic or "Mechanic")
            local accent = SEVERITY_COLORS[danger.severity] or SEVERITY_COLORS.info
            row:SetAccentColor(accent[1], accent[2], accent[3])
            row:SetStatus(danger.response == "canTalent" and "Talent option" or (danger.response == "have" and "Covered" or (danger.severity or "")),
                accent[1], accent[2], accent[3])
            row:SetNote(ColorSpellNames((danger.source and "|cffddaa44" .. danger.source .. "|r  " or "") .. (danger.tip or ""), spellMap))
            yOff = yOff - row:GetHeight() - 8
        end
    end

    if tk.tips and #tk.tips > 0 then
        local lines = {}
        for i = 1, math.min(#tk.tips, 4) do
            local tip = tk.tips[i]
            lines[#lines + 1] = "- " .. (tip.tip or "")
        end
        yOff = AddCard(content, yOff, "Class Tips", table.concat(lines, "\n"), RECOMMEND_COLOR)
    end

    if tk.lusts and #tk.lusts > 0 then
        local lines = {}
        for i = 1, math.min(#tk.lusts, 3) do
            local lust = tk.lusts[i]
            MarkSource(usedSet, lust.source)
            lines[#lines + 1] = format("%s: %s", lust.timing or "Timing", lust.note or "")
        end
        yOff = AddCard(content, yOff, "Common Lust Timings", table.concat(lines, "\n"), RECOMMEND_COLOR)
    end

    if instanceCtx and instanceCtx.talentNotes then
        yOff = AddCard(content, yOff, "Loadout Focus", instanceCtx.talentNotes, RECOMMEND_COLOR)
    end

    S.uiState.workspaceShell:SetContentHeight(math.abs(yOff) + 32)
    return usedSet
end

local function RenderGroupCoverageSection(content, yOff, ctx, results, noteLines, usedSet)
    local data = GetData()
    local theme = MedaUI.Theme

    if noteLines and #noteLines > 0 then
        yOff = AddCard(content, yOff, "Context Notes", table.concat(noteLines, "\n"), RECOMMEND_COLOR)
    end

    local resultMap = {}
    local totalChecks, coveredChecks = 0, 0
    for _, result in ipairs(results or {}) do
        resultMap[result.capabilityID] = result
        totalChecks = totalChecks + 1
        if result.matchCount > 0 then coveredChecks = coveredChecks + 1 end
    end

    if totalChecks > 0 then
        local viewer = GetViewerProfile()
        local color = coveredChecks == totalChecks and COVERED_COLOR
            or (coveredChecks == 0 and SEVERITY_COLORS.critical or SEVERITY_COLORS.warning)
        yOff = AddCard(content, yOff, "Coverage Summary",
            format("%d of %d tracked checks are covered by the %s roster.", coveredChecks, totalChecks,
                viewer and viewer.mode == "browse" and "simulated" or "current"),
            color)
    end

    for _, section in ipairs((data and data.groupCompDisplay) or {}) do
        local any = false
        for _, capID in ipairs(section.capabilities or {}) do
            if resultMap[capID] then
                any = true
                break
            end
        end

        if any then
            local hdr = MedaUI:CreateSectionHeader(content, section.label, GetContentWidth() - 8)
            hdr:SetPoint("TOPLEFT", 4, yOff)
            yOff = yOff - 32

            for _, capID in ipairs(section.capabilities or {}) do
                local result = resultMap[capID]
                if result then
                    local row = MedaUI:CreateStatusRow(content, { width = GetContentWidth(), iconSize = 24, showNote = true, cardStyle = true })
                    row:SetPoint("TOPLEFT", 4, yOff)
                    row:SetPoint("RIGHT", content, "RIGHT", -4, 0)
                    row:SetIcon(result.capability and result.capability.icon or 136116)
                    row:SetLabel(result.capability and result.capability.label or capID)

                    local structured = result.structured or BuildStructuredCapabilityOutput(result, ctx)
                    local accent = SEVERITY_COLORS[structured.tone] or COVERED_COLOR
                    row:SetAccentColor(accent[1], accent[2], accent[3])
                    if result.matchCount > 0 then
                        row:SetStatus(FormatProviderText(result.matches) or "Covered")
                        if result.matches[1] and result.matches[1].note then
                            row:SetNote(FilterNoteBySource(result.matches[1].note))
                        end
                    else
                        row:SetStatus(structured.status == "missing" and "Missing" or "Covered", accent[1], accent[2], accent[3])
                        row:SetNote(FilterNoteBySource(structured.fullGroupWorkaround or structured.missingAction or structured.summary))
                    end
                    yOff = yOff - row:GetHeight() - 8
                end
            end

            yOff = yOff - 8
        end
    end

    local instanceCtx = ResolveInstanceContext(data, ctx)
    local interactiveBuffs = instanceCtx and instanceCtx.interactiveBuffs
    if interactiveBuffs and #interactiveBuffs > 0 then
        local lines = {}
        for i = 1, math.min(#interactiveBuffs, 4) do
            local buff = interactiveBuffs[i]
            lines[#lines + 1] = format("%s: %s", buff.buff or "Buff", buff.effect or "")
        end
        yOff = AddCard(content, yOff, "Group Helpers", table.concat(lines, "\n"), RECOMMEND_COLOR)
    end

    if S.currentAffixes and ctx.instanceType == "party" and S.db and S.db.showAffixTips ~= false then
        local affixLines = {}
        local affixData = data and data.contexts and data.contexts.affixes
        if affixData then
            for _, affixID in ipairs(S.currentAffixes) do
                local affix = affixData[affixID]
                if affix and affix.tip then
                    affixLines[#affixLines + 1] = format("%s: %s", affix.name, affix.tip)
                end
            end
        end
        if #affixLines > 0 then
            yOff = AddCard(content, yOff, "Active Affixes", table.concat(affixLines, "\n"), theme.warning or RECOMMEND_COLOR)
        end
    end

    S.uiState.workspaceShell:SetContentHeight(math.abs(yOff) + 32)
    return yOff
end

local function RenderGroupPage(ctx, scope)
    if not S.uiState.workspaceShell then return {} end
    local content = S.uiState.workspaceShell:GetContent()
    ResetContent(content)

    local pageScope = scope == "raid" and "raid" or "group"
    local page, instanceCtx = GetContextPage(pageScope, ctx)
    local notes = {}
    if scope == "raid" and instanceCtx and instanceCtx.raidNotes then
        notes = instanceCtx.raidNotes
    elseif scope == "group" and instanceCtx and instanceCtx.groupNotes then
        notes = instanceCtx.groupNotes
    elseif instanceCtx and instanceCtx.notes then
        notes = instanceCtx.notes
    end

    local usedSet = {}
    local yOff = RenderGroupCoverageSection(content, -4, ctx, S.lastResults, notes, usedSet)
    yOff = RenderStructuredPageSections(content, yOff, page, usedSet)
    S.uiState.workspaceShell:SetContentHeight(math.abs(yOff) + 32)
    return usedSet
end

local function RenderCurrentPage()
    if not S.uiState.workspaceShell then return end

    local ctx = GetEffectiveContext()
    local activityKey = GetActivityKey(ctx)
    local viewer = GetViewerProfile()
    EnsureSelectedPage(activityKey)

    S.uiState.workspaceShell:SetNavigation(BuildNavigationModel(activityKey))
    S.uiState.workspaceShell:SetActivePage(S.uiState.selectedPage)
    S.uiState.workspaceShell:SetPageTitle(GetPageTitle(S.uiState.selectedPage), GetSubtitleText(ctx))
    SyncViewerToolbar()
    if S.uiState.toolbar and S.uiState.toolbar.contextDropdown then
        S.uiState.suppressToolbarCallbacks = true
        S.uiState.toolbar.contextDropdown:SetOptions(BuildContextDropdownItems())
        if S.overrideContext then
            local activity = GetActivityKey(S.overrideContext)
            local selection = "auto"
            if activity == "dungeon" and S.overrideContext.instanceID then
                selection = "dungeon:" .. S.overrideContext.instanceID
            elseif activity == "delve" and S.overrideContext.instanceName then
                for i, delve in ipairs((GetData() and GetData().contexts and GetData().contexts.delves) or {}) do
                    if delve.name == S.overrideContext.instanceName then
                        selection = "delve:" .. i
                        break
                    end
                end
            elseif S.overrideContext.instanceType then
                selection = "type:" .. S.overrideContext.instanceType
            end
            S.uiState.toolbar.contextDropdown:SetSelected(selection)
        else
            S.uiState.toolbar.contextDropdown:SetSelected("auto")
        end
        S.uiState.suppressToolbarCallbacks = false
    end

    local usedSet
    if S.uiState.selectedPage == "personal" then
        usedSet = RenderPersonalPage(ctx)
    elseif S.uiState.selectedPage:find("_you$") then
        usedSet = RenderYouPage(ctx)
    else
        usedSet = RenderGroupPage(ctx, "group")
    end

    S.uiState.workspaceShell:SetPageSummary(BuildPerspectiveSummary(), viewer and viewer.mode == "browse" and "warning" or nil)
    S.uiState.workspaceShell:SetFreshnessSources(GetEnabledSources(usedSet))
end

ALL_CLASS_SPECS = {
    DEATHKNIGHT = { 250, 251, 252 },
    DEMONHUNTER = { 577, 581 },
    DRUID       = { 102, 103, 104, 105 },
    EVOKER      = { 1467, 1468, 1473 },
    HUNTER      = { 253, 254, 255 },
    MAGE        = { 62, 63, 64 },
    MONK        = { 268, 269, 270 },
    PALADIN     = { 65, 66, 70 },
    PRIEST      = { 256, 257, 258 },
    ROGUE       = { 259, 260, 261 },
    SHAMAN      = { 262, 263, 264 },
    WARLOCK     = { 265, 266, 267 },
    WARRIOR     = { 71, 72, 73 },
}

TANK_SPECS = {
    DEATHKNIGHT = 250, DEMONHUNTER = 581, DRUID = 104,
    MONK = 268, PALADIN = 66, WARRIOR = 73,
}
HEALER_SPECS = {
    DRUID = 105, EVOKER = 1468, MONK = 270,
    PALADIN = 65, PRIEST = { 256, 257 }, SHAMAN = 264,
}
DPS_SPECS = {
    DEATHKNIGHT = { 251, 252 }, DEMONHUNTER = { 577 },
    DRUID = { 102, 103 }, EVOKER = { 1467, 1473 },
    HUNTER = { 253, 254, 255 }, MAGE = { 62, 63, 64 },
    MONK = { 269 }, PALADIN = { 70 },
    PRIEST = { 258 }, ROGUE = { 259, 260, 261 },
    SHAMAN = { 262, 263 }, WARLOCK = { 265, 266, 267 },
    WARRIOR = { 71, 72 },
}

ALL_CLASSES = {}
for token in pairs(ALL_CLASS_SPECS) do ALL_CLASSES[#ALL_CLASSES + 1] = token end
table.sort(ALL_CLASSES)

R.SPEC_META_BY_ID = SPEC_META_BY_ID
R.ALL_CLASS_SPECS = ALL_CLASS_SPECS
R.TANK_SPECS = TANK_SPECS
R.HEALER_SPECS = HEALER_SPECS
R.DPS_SPECS = DPS_SPECS
R.ALL_CLASSES = ALL_CLASSES
R.ROLE_LABELS = ROLE_LABELS
R.GetActivityKey = GetActivityKey
R.GetClassLabel = GetClassLabel
R.EnsurePersonalSchema = EnsurePersonalSchema
R.EnsureSpecRegistry = EnsureSpecRegistry
R.GetViewerProfile = GetViewerProfile
R.BuildStructuredCapabilityOutput = BuildStructuredCapabilityOutput
R.BuildPerspectiveSummary = BuildPerspectiveSummary
R.BuildContextDropdownItems = BuildContextDropdownItems
R.ParseContextSelection = ParseContextSelection
R.GetDefaultSpecForClassRole = GetDefaultSpecForClassRole
R.BuildRoleDropdownItems = BuildRoleDropdownItems
R.BuildClassDropdownItems = BuildClassDropdownItems
R.BuildSpecDropdownItems = BuildSpecDropdownItems
R.SyncViewerToolbar = SyncViewerToolbar
R.GetSpecMeta = GetSpecMeta
R.GetLivePlayerProfile = GetLivePlayerProfile
R.EnsureViewerState = EnsureViewerState
R.SetViewerState = SetViewerState
R.ResolveSpellID = ResolveSpellID
R.BeginSpellTooltip = BeginSpellTooltip
R.AddTooltipSpacer = AddTooltipSpacer
R.CreateTooltipTextLine = CreateTooltipTextLine
R.CreateTooltipTextBlock = CreateTooltipTextBlock
R.AddRecommendationTooltip = AddRecommendationTooltip
R.RenderRecommendationCardGrid = RenderRecommendationCardGrid
R.GetResultTooltipSpellID = GetResultTooltipSpellID
R.RenderCurrentPage = RenderCurrentPage
