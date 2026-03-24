local _, ns = ...

local R = ns.Reminders or {}
ns.Reminders = R

local S = R.state or {}
R.state = S

local MedaUI = LibStub("MedaUI-2.0")

local SEVERITY_COLORS = R.SEVERITY_COLORS
local COVERED_COLOR = R.COVERED_COLOR
local RECOMMEND_COLOR = R.RECOMMEND_COLOR

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
local GetLivePlayerProfile
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
local RenderDungeonFocusSection
local GetResultTooltipSpellID
local GetEncounterSortRank
local GetNormalizedKeyDispels
local GetNormalizedKeyInterrupts
local GetNormalizedBossTips
local GetNormalizedTipsAndTricks
local TrimSummary
local BuildDungeonTimerBody

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

local function GetDungeonTimerInfo(...)
    return R.GetDungeonTimerInfo(...)
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
    local supported = {}
    for _, role in ipairs(GetSupportedRolesForClass(classToken)) do
        supported[role] = true
    end

    local items = {}
    for _, role in ipairs({ "tank", "healer", "dps" }) do
        items[#items + 1] = {
            value = role,
            label = ROLE_LABELS[role] or role,
            disabled = not supported[role],
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
    local data = GetData()
    EnsureSpecRegistry(data)

    local items = {}
    local specs = data and data.specRegistry and data.specRegistry.byClass and data.specRegistry.byClass[classToken] or {}
    for _, spec in ipairs(specs) do
        items[#items + 1] = {
            value = spec.specID,
            label = format("%s (%s)", spec.specName, ROLE_LABELS[spec.role] or spec.role or "Role"),
            disabled = role ~= nil and spec.role ~= role,
        }
    end
    table.sort(items, function(a, b) return (a.label or "") < (b.label or "") end)
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
    toolbar.roleDropdown:SetEnabled(#roleItems > 0)
    toolbar.roleDropdown:SetSelected(viewer.role)

    local classItems = BuildClassDropdownItems()
    toolbar.classDropdown:SetOptions(classItems)
    toolbar.classDropdown:SetSelected(viewer.classToken)

    local specItems = BuildSpecDropdownItems(viewer.classToken, viewer.role)
    toolbar.specDropdown:SetOptions(specItems)
    toolbar.specDropdown:Show()
    toolbar.specDropdown:SetEnabled(#specItems > 0)
    toolbar.specDropdown:SetSelected(viewer.specID)

    if toolbar.liveResetButton then
        local live = GetLivePlayerProfile()
        if viewer.mode == "browse" and live and live.specID then
            toolbar.liveResetButton:Show()
            toolbar.liveResetButton:SetEnabled(true)
        else
            toolbar.liveResetButton:Hide()
            toolbar.liveResetButton:SetEnabled(false)
        end
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

GetLivePlayerProfile = function()
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

local function FormatProviderTargets(targets)
    if type(targets) ~= "table" or #targets == 0 then return nil end

    local seen = {}
    local ordered = {}
    for _, target in ipairs(targets) do
        local text = SafeText(target)
        if text and not seen[text] then
            seen[text] = true
            ordered[#ordered + 1] = text
        end
    end

    if #ordered == 0 then return nil end
    return table.concat(ordered, "/")
end

local function FormatProviderMeta(match)
    if not match then return nil end

    local parts = {}
    local targets = FormatProviderTargets(match.dispelTargets)
    if targets then
        parts[#parts + 1] = targets
    end
    if match.rangeText and match.rangeText ~= "" then
        parts[#parts + 1] = match.rangeText
    end
    if match.castTimeMS ~= nil then
        parts[#parts + 1] = match.castTimeMS <= 0 and "Instant" or format("%.1fs cast", match.castTimeMS / 1000)
    end
    if match.cooldownMS and match.cooldownMS > 0 then
        parts[#parts + 1] = format("%.1fs CD", match.cooldownMS / 1000)
    end

    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

local function BuildCoverageProviderNote(matches)
    if not matches or #matches == 0 then return nil end

    local summaries = {}
    local seen = {}
    for _, match in ipairs(matches) do
        local label = SafeText(match.spellName) or "Unknown spell"
        local meta = FormatProviderMeta(match)
        local summary = meta and format("%s (%s)", label, meta) or label
        if not seen[summary] then
            seen[summary] = true
            summaries[#summaries + 1] = summary
        end
    end

    if #summaries == 0 then return nil end
    if #summaries == 1 then return summaries[1] end
    return format("%s  +%d more", summaries[1], #summaries - 1)
end

local function AddCoverageTooltip(tip, result)
    if not tip or not result then return end

    local capability = result.capability
    local title = capability and capability.label or "Capability"
    local spellID = GetResultTooltipSpellID(result)
    BeginSpellTooltip(tip, spellID, title)

    if capability and capability.description and capability.description ~= "" then
        AddTooltipSpacer(tip)
        tip:AddLine(capability.description, 1, 1, 1, true)
    end

    local matches = result.matches or {}
    AddTooltipSpacer(tip)
    if #matches > 0 then
        tip:AddLine(format("Coverage: %d provider%s", #matches, #matches == 1 and "" or "s"), 0.4, 0.8, 1.0)
        for _, match in ipairs(matches) do
            AddTooltipSpacer(tip)
            tip:AddDoubleLine(match.name or "Unknown", match.spellName or "Unknown spell", 1, 1, 1, 0.75, 0.82, 1.0)

            local classLabel = GetClassLabel(match.class)
            local specMeta = match.specID and SPEC_META_BY_ID[match.specID] or nil
            local classLine = classLabel
            if specMeta and specMeta.specName then
                classLine = classLine .. " - " .. specMeta.specName
            end
            if classLine and classLine ~= "" then
                tip:AddLine(classLine, 0.65, 0.65, 0.65)
            end

            local meta = FormatProviderMeta(match)
            if meta then
                tip:AddLine(meta, 0.75, 0.75, 0.75, true)
            end

            local note = FilterNoteBySource(match.note)
            if note and note ~= "" then
                tip:AddLine(note, 0.9, 0.9, 0.9, true)
            end
        end
    else
        local detail = result.output and (result.output.banner or result.output.detail)
        if detail and detail ~= "" then
            tip:AddLine(detail, 1, 1, 1, true)
        end
        local suggestion = result.output and result.output.suggestion
        if suggestion and suggestion ~= "" then
            AddTooltipSpacer(tip)
            tip:AddLine(suggestion, 0.95, 0.8, 0.45, true)
        end
    end
end

local function AddCard(parent, yOff, title, body, accent)
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

local DUNGEON_FOCUS_LIMIT = 5
local DUNGEON_FOCUS_MOB_HEX = "ffcb96"
local DUNGEON_FOCUS_NPC_HEX = "78d676"
local DUNGEON_FOCUS_INTERRUPT_HEX = "ff7ac8"
local DUNGEON_FOCUS_STUN_HEX = "74f2ff"
local DUNGEON_FOCUS_PRIORITY_HEX = "ffd36b"
local DUNGEON_FOCUS_COVERED_HEX = "67d66d"
local DUNGEON_FOCUS_MISSING_HEX = "ff7474"
local DUNGEON_FOCUS_TALENT_HEX = "ffbe52"
local GET_SPELL_TEXTURE = _G and _G.GetSpellTexture or nil
local DUNGEON_FOCUS_DISPEL_HEX = {
    magic = "59b9ff",
    curse = "bb7fff",
    poison = "51d66f",
    disease = "d6a160",
    bleed = "e26f6f",
    enrage = "ffb357",
}

local function HexToColorTriplet(hex, fallback)
    if type(hex) ~= "string" or #hex ~= 6 then
        return unpack(fallback or { 1, 1, 1 })
    end

    local r = tonumber(hex:sub(1, 2), 16)
    local g = tonumber(hex:sub(3, 4), 16)
    local b = tonumber(hex:sub(5, 6), 16)
    if not r or not g or not b then
        return unpack(fallback or { 1, 1, 1 })
    end

    return r / 255, g / 255, b / 255
end

local function GetDungeonFocusSeverityWeight(severity)
    local weights = {
        critical = 6,
        high = 5,
        warning = 4,
        medium = 3,
        info = 2,
        low = 1,
    }
    return weights[severity] or 0
end

local function GetDungeonFocusAccent(severity)
    return SEVERITY_COLORS[severity] or RECOMMEND_COLOR
end

local function GetDangerTextBlob(danger)
    if not danger then return "" end

    local parts = {
        SafeText(danger.mechanic),
        SafeText(danger.tip),
        SafeText(danger.source),
        SafeText(danger.encounter),
    }
    return table.concat(parts, " "):lower()
end

local function GetDispelTypeKey(danger)
    if not danger then return nil end
    if type(danger.dispelType) == "string" and danger.dispelType ~= "" then
        return danger.dispelType:lower()
    end
    if type(danger.capability) == "string" and danger.capability:match("^dispel_") then
        return danger.capability:gsub("^dispel_", ""):lower()
    end
    return nil
end

local function GetDungeonFocusAction(danger, role)
    local dispelType = GetDispelTypeKey(danger)
    if dispelType then
        return format("%s Dispel", dispelType:gsub("^%l", string.upper)), DUNGEON_FOCUS_DISPEL_HEX[dispelType] or "59b9ff"
    end

    if danger and danger.capability == "offensive_dispel" then
        return "Purge", DUNGEON_FOCUS_DISPEL_HEX.magic
    end

    if danger and danger.capability == "soothe" then
        return "Soothe", DUNGEON_FOCUS_DISPEL_HEX.enrage
    end

    local text = GetDangerTextBlob(danger)
    if role == "tank" then
        if text:find("tank buster", 1, true)
            or text:find("major defensive", 1, true)
            or text:find("tank:", 1, true) then
            return "Tank Buster", DUNGEON_FOCUS_PRIORITY_HEX
        end
        if text:find("frontal", 1, true) then
            return "Frontal", DUNGEON_FOCUS_PRIORITY_HEX
        end
        return "Danger", DUNGEON_FOCUS_PRIORITY_HEX
    end

    if danger and (danger.type == "interrupt" or danger.capability == "interrupt") then
        return "Interrupt", DUNGEON_FOCUS_INTERRUPT_HEX
    end

    if text:find("stun", 1, true) then
        return "Stun", DUNGEON_FOCUS_STUN_HEX
    end

    if text:find("crowd control", 1, true)
        or text:find(" cc ", 1, true)
        or text:find("incap", 1, true)
        or text:find("stop", 1, true) then
        return "CC", DUNGEON_FOCUS_STUN_HEX
    end

    return "Priority", DUNGEON_FOCUS_PRIORITY_HEX
end

local function GetDungeonFocusIcon(data, danger)
    if not danger then return 136116 end
    if type(danger.icon) == "number" and danger.icon > 0 then
        return danger.icon
    end
    if danger.spellID then
        local texture = GET_SPELL_TEXTURE and GET_SPELL_TEXTURE(danger.spellID)
        if texture then return texture end
    end

    local spellID = ResolveSpellID(danger.mechanic)
    if spellID then
        local texture = GET_SPELL_TEXTURE and GET_SPELL_TEXTURE(spellID)
        if texture then return texture end
    end

    local capability = data and data.capabilities and danger.capability and data.capabilities[danger.capability] or nil
    if capability and type(capability.icon) == "number" and capability.icon > 0 then
        return capability.icon
    end

    if danger.type == "interrupt" or danger.capability == "interrupt" then
        return 132357
    end

    local dispelType = GetDispelTypeKey(danger)
    if dispelType == "magic" then return 135894 end
    if dispelType == "curse" then return 135952 end
    if dispelType == "poison" then return 136068 end
    if dispelType == "disease" then return 135935 end
    if dispelType == "bleed" then return 4630445 end

    return 136116
end

local function CreateDungeonFocusEntry(data, danger, role, extra)
    local actionLabel, actionHex = GetDungeonFocusAction(danger, role)
    local entry = {
        id = extra and extra.id or format("%s:%s:%s", role or "role", SafeText(danger and danger.source) or "mob", SafeText(danger and danger.mechanic) or "mechanic"),
        danger = danger,
        title = SafeText(danger and danger.mechanic) or "Priority",
        mob = SafeText(danger and danger.source),
        encounter = SafeText(danger and danger.encounter),
        detail = SafeText(danger and danger.tip),
        spellID = danger and danger.spellID or ResolveSpellID(danger and danger.mechanic),
        icon = GetDungeonFocusIcon(data, danger),
        actionLabel = actionLabel,
        actionHex = actionHex,
        accent = GetDungeonFocusAccent(danger and danger.severity),
        sortWeight = GetDungeonFocusSeverityWeight(danger and danger.severity),
        priorityRank = extra and extra.priorityRank or 99,
        response = danger and danger.response or nil,
        npcID = danger and (danger.npcID or danger.npcId) or nil,
        displayID = danger and (danger.displayID or danger.displayId or danger.modelDisplayID) or nil,
    }

    if extra then
        for key, value in pairs(extra) do
            entry[key] = value
        end
    end

    return entry
end

local function DangerEntryMatches(danger, item)
    if not (danger and item) then return false end

    local itemMechanic = SafeText(item.mechanic) or SafeText(item.spellName)
    local dangerMechanic = SafeText(danger.mechanic) or SafeText(danger.spellName)
    local sameMechanic = (item.spellID and danger.spellID and item.spellID == danger.spellID)
        or (itemMechanic and dangerMechanic and itemMechanic == dangerMechanic)
    local itemSource = SafeText(item.source)
    local dangerSource = SafeText(danger.source)
    local sameSource = not itemSource or not dangerSource or itemSource == dangerSource

    return sameMechanic and sameSource
end

local function FindPersonalDungeonDanger(tk, item)
    local fallback = nil
    for _, danger in ipairs(tk and tk.dangers or {}) do
        if SafeText(danger.capability) == SafeText(item.capability) then
            if DangerEntryMatches(danger, item) then
                return danger
            end
            fallback = fallback or danger
        end
    end
    return fallback
end

local function GetPersonalDungeonStatus(response, defaultLabel, missingLabel)
    if response == "have" then
        return "Covered", DUNGEON_FOCUS_COVERED_HEX, COVERED_COLOR, 4
    end
    if response == "canTalent" then
        return "Talent", DUNGEON_FOCUS_TALENT_HEX, SEVERITY_COLORS.warning, 3
    end
    if response == "unavailable" then
        return missingLabel or "Watch", DUNGEON_FOCUS_MISSING_HEX, SEVERITY_COLORS.critical, 2
    end
    return defaultLabel or "Watch", DUNGEON_FOCUS_PRIORITY_HEX, RECOMMEND_COLOR, 1
end

local function BuildPersonalDungeonInterruptItems(tk, instanceCtx)
    local data = GetData()
    local items = {}

    for index, stop in ipairs(GetNormalizedKeyInterrupts(instanceCtx)) do
        local matched = FindPersonalDungeonDanger(tk, stop)
        local actionLabel, actionHex, accent, statusWeight = GetPersonalDungeonStatus(
            matched and matched.response or nil,
            "Interrupt",
            "Watch"
        )

        items[#items + 1] = CreateDungeonFocusEntry(data, stop, "dps", {
            id = format("personal_interrupt:%s:%s", SafeText(stop.source) or "mob", SafeText(stop.mechanic) or index),
            detail = TrimSummary(stop.tip, 160),
            actionLabel = actionLabel,
            actionHex = actionHex,
            accent = accent,
            response = matched and matched.response or nil,
            priorityRank = index,
            sortWeight = 4 + statusWeight + GetDungeonFocusSeverityWeight(stop.severity),
        })
    end

    table.sort(items, function(a, b)
        if a.priorityRank ~= b.priorityRank then
            return a.priorityRank < b.priorityRank
        end
        if a.sortWeight ~= b.sortWeight then
            return a.sortWeight > b.sortWeight
        end
        return (a.title or "") < (b.title or "")
    end)

    return items
end

local function BuildPersonalDungeonDispelItems(tk, instanceCtx)
    local data = GetData()
    local items = {}

    for index, dispel in ipairs(GetNormalizedKeyDispels(instanceCtx)) do
        local matched = FindPersonalDungeonDanger(tk, dispel)
        local actionLabel, actionHex, accent, statusWeight = GetPersonalDungeonStatus(
            matched and matched.response or nil,
            "Watch",
            "Missing"
        )

        items[#items + 1] = CreateDungeonFocusEntry(data, dispel, "healer", {
            id = format("personal_dispel:%s:%s", SafeText(dispel.capability) or "capability", SafeText(dispel.mechanic) or index),
            detail = TrimSummary(dispel.tip, 160),
            actionLabel = actionLabel,
            actionHex = actionHex,
            accent = accent,
            response = matched and matched.response or nil,
            priorityRank = index,
            sortWeight = 4 + statusWeight + GetDungeonFocusSeverityWeight(dispel.severity),
        })
    end

    table.sort(items, function(a, b)
        if a.priorityRank ~= b.priorityRank then
            return a.priorityRank < b.priorityRank
        end
        if a.sortWeight ~= b.sortWeight then
            return a.sortWeight > b.sortWeight
        end
        return (a.title or "") < (b.title or "")
    end)

    return items
end

local function BuildPersonalDungeonBossItems(instanceCtx)
    local items = {}
    local seen = {}

    for _, bossTip in ipairs(GetNormalizedBossTips(instanceCtx)) do
        local signature = table.concat({
            SafeText(bossTip.title) or "",
            SafeText(bossTip.encounter) or "",
            SafeText(bossTip.detail) or "",
        }, "|")
        if not seen[signature] then
            items[#items + 1] = {
                id = "personal_boss:" .. signature,
                title = bossTip.title or "Boss Tip",
                encounter = bossTip.encounter,
                detail = bossTip.detail,
                icon = 236344,
                actionLabel = "Boss Tip",
                actionHex = DUNGEON_FOCUS_PRIORITY_HEX,
                accent = RECOMMEND_COLOR,
                priorityRank = GetEncounterSortRank(bossTip.encounter or bossTip.title),
                sortWeight = 8,
            }
            seen[signature] = true
        end
    end

    table.sort(items, function(a, b)
        if a.priorityRank ~= b.priorityRank then
            return a.priorityRank < b.priorityRank
        end
        if a.sortWeight ~= b.sortWeight then
            return a.sortWeight > b.sortWeight
        end
        return (a.title or "") < (b.title or "")
    end)

    return items
end

local function BuildPersonalDungeonTrickItems(ctx, instanceCtx)
    local items = {}
    local seen = {}

    local timerInfo = (S.db and S.db.showDungeonTimers ~= false) and GetDungeonTimerInfo(ctx, instanceCtx) or nil
    if timerInfo then
        items[#items + 1] = {
            id = "personal_trick:timer",
            title = "Dungeon Timer",
            detail = BuildDungeonTimerBody(timerInfo),
            icon = 134376,
            actionLabel = "Timer",
            actionHex = DUNGEON_FOCUS_PRIORITY_HEX,
            accent = RECOMMEND_COLOR,
            sortWeight = 8,
            priorityRank = 1,
        }
        seen.timer = true
    end

    for _, trick in ipairs(GetNormalizedTipsAndTricks(instanceCtx)) do
        local signature = table.concat({
            SafeText(trick.title) or "",
            SafeText(trick.encounter) or "",
            SafeText(trick.detail) or "",
        }, "|")
        if not seen[signature] then
            items[#items + 1] = {
                id = "personal_trick:" .. signature,
                title = trick.title or "Tip",
                encounter = trick.encounter,
                detail = trick.detail,
                icon = 134400,
                actionLabel = "Tip",
                actionHex = DUNGEON_FOCUS_NPC_HEX,
                accent = RECOMMEND_COLOR,
                sortWeight = 6,
                priorityRank = 2,
            }
            seen[signature] = true
        end
    end

    table.sort(items, function(a, b)
        if a.sortWeight ~= b.sortWeight then
            return a.sortWeight > b.sortWeight
        end
        if a.priorityRank ~= b.priorityRank then
            return a.priorityRank < b.priorityRank
        end
        return (a.title or "") < (b.title or "")
    end)

    return items
end

local function BuildDungeonRoleFocusModel(ctx, tk, instanceCtx)
    local sections = {}
    local interruptItems = BuildPersonalDungeonInterruptItems(tk, instanceCtx)
    local dispelItems = BuildPersonalDungeonDispelItems(tk, instanceCtx)
    local bossItems = BuildPersonalDungeonBossItems(instanceCtx)
    local trickItems = BuildPersonalDungeonTrickItems(ctx, instanceCtx)

    if #interruptItems > 0 then
        sections[#sections + 1] = {
            key = format("focus:%s:personal:interrupts", tostring(ctx and ctx.instanceID or "world")),
            title = "Key Interrupts",
            subtitle = "The casts worth assigning or watching before each pull.",
            items = interruptItems,
            accent = { HexToColorTriplet(DUNGEON_FOCUS_INTERRUPT_HEX, RECOMMEND_COLOR) },
        }
    end

    if #dispelItems > 0 then
        sections[#sections + 1] = {
            key = format("focus:%s:personal:dispels", tostring(ctx and ctx.instanceID or "world")),
            title = "Key Dispels",
            subtitle = "Dungeon dispels with your current coverage status.",
            items = dispelItems,
            accent = { HexToColorTriplet(DUNGEON_FOCUS_DISPEL_HEX.magic, RECOMMEND_COLOR) },
        }
    end

    if #bossItems > 0 then
        sections[#sections + 1] = {
            key = format("focus:%s:personal:boss", tostring(ctx and ctx.instanceID or "world")),
            title = "Boss Tips",
            subtitle = "Boss-only reminders that stay readable mid-run.",
            items = bossItems,
            accent = { HexToColorTriplet(DUNGEON_FOCUS_PRIORITY_HEX, RECOMMEND_COLOR) },
        }
    end

    if #trickItems > 0 then
        sections[#sections + 1] = {
            key = format("focus:%s:personal:tricks", tostring(ctx and ctx.instanceID or "world")),
            title = "Tips and Tricks",
            subtitle = "Sticky route notes, utility reminders, and the dungeon timer.",
            items = trickItems,
            accent = { HexToColorTriplet(DUNGEON_FOCUS_NPC_HEX, RECOMMEND_COLOR) },
        }
    end

    return {
        title = "Personal Cheat Sheet",
        description = "Dungeon-specific notes for your current viewer profile, organized into the four normalized lanes.",
        sections = sections,
    }
end

local function CompactWhitespace(value)
    local text = SafeText(value)
    if not text then return nil end

    text = text:gsub("[%c\r\n\t]+", " ")
    text = text:gsub("%s+", " ")
    return SafeText(text)
end

TrimSummary = function(value, maxLength)
    local text = CompactWhitespace(value)
    local limit = maxLength or 180
    if not text or #text <= limit then
        return text
    end

    local trimmed = text:sub(1, math.max(1, limit - 3))
    trimmed = trimmed:gsub("%s+%S*$", "")
    return trimmed .. "..."
end

local function FormatClockDuration(seconds)
    if type(seconds) ~= "number" or seconds <= 0 then
        return nil
    end

    local total = math.floor(seconds + 0.5)
    local minutes = math.floor(total / 60)
    local remain = total % 60
    return format("%d:%02d", minutes, remain)
end

BuildDungeonTimerBody = function(timerInfo)
    if not timerInfo or not timerInfo.timeLimitSeconds then
        return nil
    end

    local parts = {
        "Beat timer: " .. (timerInfo.timeLimitLabel or FormatClockDuration(timerInfo.timeLimitSeconds) or tostring(timerInfo.timeLimitSeconds)),
    }
    if timerInfo.source == "api" then
        parts[#parts + 1] = "Resolved from the live Mythic+ map table."
    end
    return table.concat(parts, " ")
end

local function BuildNameList(items, limit)
    local values = {}
    local seen = {}
    local maxItems = limit or #items

    for _, item in ipairs(items or {}) do
        local text = SafeText(item)
        if text and not seen[text] then
            values[#values + 1] = text
            seen[text] = true
            if #values >= maxItems then
                break
            end
        end
    end

    return values
end

local function JoinNameList(items, limit)
    local values = BuildNameList(items, limit)
    if #values == 0 then return nil end
    return table.concat(values, ", ")
end

local function BuildResultMap(results)
    local map = {}
    for _, result in ipairs(results or {}) do
        map[result.capabilityID] = result
    end
    return map
end

GetNormalizedKeyDispels = function(instanceCtx)
    if not instanceCtx then return {} end

    local items = {}
    for index, dispel in ipairs(instanceCtx.keyDispels or {}) do
        local item = {}
        for key, value in pairs(dispel) do
            item[key] = value
        end
        item._priority = index
        items[#items + 1] = item
    end

    table.sort(items, function(a, b)
        if (a._priority or 99) ~= (b._priority or 99) then
            return (a._priority or 99) < (b._priority or 99)
        end
        local pa = GetDungeonFocusSeverityWeight(a and a.severity)
        local pb = GetDungeonFocusSeverityWeight(b and b.severity)
        if pa ~= pb then
            return pa > pb
        end
        return (a and a.mechanic or "") < (b and b.mechanic or "")
    end)

    return items
end

GetNormalizedKeyInterrupts = function(instanceCtx)
    if not instanceCtx then return {} end

    local items = {}
    for index, kick in ipairs(instanceCtx.keyInterrupts or {}) do
        local spellName = SafeText(kick.spell) or SafeText(kick.spellName)
        items[#items + 1] = {
            priorityRank = index,
            severity = kick.danger or "warning",
            mechanic = spellName,
            spellName = kick.spellName,
            source = kick.mob,
            encounter = kick.encounter,
            tip = kick.tip or format("Assign a kick order for %s from %s.", spellName or "the cast", kick.mob or "the mob"),
            spellID = kick.spellID or ResolveSpellID(spellName),
            icon = kick.icon,
            rangeText = kick.rangeText,
            castTimeMS = kick.castTimeMS,
            cooldownMS = kick.cooldownMS,
            type = "interrupt",
            capability = "interrupt",
        }
    end
    return items
end

local function SplitNormalizedTipText(value, fallbackTitle)
    local text = SafeText(value)
    if not text then return fallbackTitle or "Tip", nil, nil end

    local prefix, body = text:match("^(.-):%s*(.+)$")
    if prefix and body then
        return prefix, body, prefix
    end

    return fallbackTitle or "Tip", text, nil
end

local function NormalizeStructuredTipEntry(value, fallbackTitle, prefix, index)
    if type(value) ~= "table" then
        local title, detail, encounter = SplitNormalizedTipText(value, fallbackTitle)
        return {
            id = format("%s:%s", prefix or "tip", tostring(index or 0)),
            title = title,
            detail = detail,
            encounter = encounter,
        }
    end

    local title = SafeText(value.title) or SafeText(value.object) or SafeText(value.buff) or fallbackTitle or "Tip"
    local detail = SafeText(value.detail) or SafeText(value.tip) or SafeText(value.body)
    local encounter = SafeText(value.encounter)
    if not detail then
        local text = SafeText(value.text)
        if text then
            title, detail, encounter = SplitNormalizedTipText(text, fallbackTitle)
        end
    end

    return {
        id = SafeText(value.id) or format("%s:%s", prefix or "tip", tostring(index or 0)),
        title = title,
        detail = detail,
        encounter = encounter,
        spellID = value.spellID or value.buffSpellID,
        buff = SafeText(value.buff),
        object = SafeText(value.object),
        icon = value.icon,
    }
end

GetNormalizedBossTips = function(instanceCtx)
    if not instanceCtx then return {} end

    if type(instanceCtx.bossTips) == "table" and #instanceCtx.bossTips > 0 then
        local items = {}
        for index, text in ipairs(instanceCtx.bossTips) do
            local title, detail, encounter = SplitNormalizedTipText(text, "Boss Tip")
            items[#items + 1] = {
                id = "boss_tip:" .. tostring(index),
                title = title,
                detail = detail,
                encounter = encounter,
            }
        end
        return items
    end

    return {}
end

GetNormalizedTipsAndTricks = function(instanceCtx)
    if not instanceCtx then return {} end

    if type(instanceCtx.tipsAndTricks) == "table" and #instanceCtx.tipsAndTricks > 0 then
        local items = {}
        for index, value in ipairs(instanceCtx.tipsAndTricks) do
            items[#items + 1] = NormalizeStructuredTipEntry(value, "Tip", "tips_and_tricks", index)
        end
        return items
    end

    return {}
end

local function GetGroupCoverageState(result)
    if not result then
        return "Missing", DUNGEON_FOCUS_MISSING_HEX, SEVERITY_COLORS.critical, "unavailable", 5
    end

    if result.matchCount == 0 then
        if result.potentialMatches and #result.potentialMatches > 0 then
            return "Talent Swap", DUNGEON_FOCUS_TALENT_HEX, SEVERITY_COLORS.warning, "canTalent", 5
        end
        if result.personal then
            return "Talent", DUNGEON_FOCUS_TALENT_HEX, SEVERITY_COLORS.warning, "canTalent", 5
        end
        return "Missing", DUNGEON_FOCUS_MISSING_HEX, SEVERITY_COLORS.critical, "unavailable", 5
    end

    if result.matchCount == 1 then
        return "Thin", DUNGEON_FOCUS_PRIORITY_HEX, SEVERITY_COLORS.warning, "have", 4
    end

    return "Covered", DUNGEON_FOCUS_COVERED_HEX, COVERED_COLOR, "have", 2
end

local function BuildCoverageNames(matches)
    local names = {}
    for _, match in ipairs(matches or {}) do
        names[#names + 1] = match.name or "Unknown"
    end
    return JoinNameList(names, 3)
end

local function BuildGroupCoverageDetail(result, structured, primaryDanger)
    local parts = {}
    local providerNames = BuildCoverageNames(result and result.matches)
    local potentialNames = BuildCoverageNames(result and result.potentialMatches)

    if result and result.matchCount > 0 then
        if providerNames then
            if result.matchCount == 1 then
                parts[#parts + 1] = providerNames .. " is the only current answer."
            else
                parts[#parts + 1] = providerNames .. " share this."
            end
        end
        local summary = structured and structured.summary
        if summary and summary ~= "Coverage available." then
            parts[#parts + 1] = TrimSummary(summary, 120)
        end
    else
        local gapText = structured and (structured.missingAction or structured.fullGroupWorkaround or structured.summary)
        if gapText then
            parts[#parts + 1] = TrimSummary(gapText, 140)
        end
    end

    if potentialNames then
        local prefix = (result and result.matchCount > 0) and "Can also swap:" or "Can swap:"
        parts[#parts + 1] = prefix .. " " .. potentialNames .. "."
    end

    if result and result.personal and result.personal.detail then
        parts[#parts + 1] = TrimSummary(result.personal.detail, 140)
    end

    if primaryDanger then
        local dangerText = primaryDanger.mechanic or primaryDanger.tip
        if dangerText then
            local mob = SafeText(primaryDanger.source)
            local prefix = mob and format("Dungeon pressure from %s: ", mob) or "Dungeon pressure: "
            parts[#parts + 1] = prefix .. TrimSummary(primaryDanger.tip or primaryDanger.mechanic, 120)
        end
    end

    return table.concat(parts, " ")
end

local function BuildDungeonGroupDispelItems(ctx, resultMap, instanceCtx)
    local data = GetData()
    local ordered = GetNormalizedKeyDispels(instanceCtx)
    local items = {}
    for index, dispel in ipairs(ordered) do
        local result = resultMap[dispel.capability]
        local structured = result and (result.structured or BuildStructuredCapabilityOutput(result, ctx)) or nil
        local actionLabel, actionHex, accent, response, statusWeight = GetGroupCoverageState(result)
        local detailParts = {}
        if SafeText(dispel.tip) then
            detailParts[#detailParts + 1] = TrimSummary(dispel.tip, 120)
        end
        if result then
            local coverageDetail = BuildGroupCoverageDetail(result, structured, dispel)
            if coverageDetail and coverageDetail ~= "" then
                detailParts[#detailParts + 1] = coverageDetail
            end
        end

        local entry = CreateDungeonFocusEntry(data, dispel, "group", {
            id = format("group_dispel:%s:%s", SafeText(dispel.capability) or "capability", SafeText(dispel.mechanic) or index),
            detail = table.concat(detailParts, " "),
            actionLabel = actionLabel,
            actionHex = actionHex,
            accent = accent,
            response = response,
            priorityRank = index,
            sortWeight = 6 + statusWeight + GetDungeonFocusSeverityWeight(dispel.severity),
            providersNote = result and BuildCoverageProviderNote(result.matches) or nil,
            potentialProvidersNote = result and BuildCoverageNames(result.potentialMatches) or nil,
            groupSummary = structured and structured.summary or nil,
            talentNote = result and result.personal and result.personal.detail or nil,
            missingNote = result and result.matchCount == 0 and (structured and (structured.missingAction or structured.fullGroupWorkaround) or nil) or nil,
        })
        if entry then
            items[#items + 1] = entry
        end
    end

    table.sort(items, function(a, b)
        if a.priorityRank ~= b.priorityRank then
            return a.priorityRank < b.priorityRank
        end
        if a.sortWeight ~= b.sortWeight then
            return a.sortWeight > b.sortWeight
        end
        return (a.title or "") < (b.title or "")
    end)

    return items
end

local function BuildDungeonStopItems(instanceCtx)
    local data = GetData()
    local items = {}

    for _, stop in ipairs(GetNormalizedKeyInterrupts(instanceCtx)) do
        local actionLabel, actionHex = GetDungeonFocusAction(stop, "dps")
        items[#items + 1] = CreateDungeonFocusEntry(data, stop, "dps", {
            id = format("group_stop:%s:%s", SafeText(stop.source) or "mob", SafeText(stop.mechanic) or "cast"),
            detail = TrimSummary(stop.tip, 160),
            actionLabel = actionLabel,
            actionHex = actionHex,
            priorityRank = stop.priorityRank,
            sortWeight = 4 + GetDungeonFocusSeverityWeight(stop.severity),
        })
    end

    table.sort(items, function(a, b)
        if a.priorityRank ~= b.priorityRank then
            return a.priorityRank < b.priorityRank
        end
        if a.sortWeight ~= b.sortWeight then
            return a.sortWeight > b.sortWeight
        end
        return (a.title or "") < (b.title or "")
    end)

    return items
end

GetEncounterSortRank = function(value)
    local text = SafeText(value)
    if not text then return 50 end

    local lower = text:lower()
    if lower:find("1st boss", 1, true) or lower:find("first boss", 1, true) then return 1 end
    if lower:find("2nd boss", 1, true) or lower:find("second boss", 1, true) then return 2 end
    if lower:find("3rd boss", 1, true) or lower:find("third boss", 1, true) then return 3 end
    if lower:find("4th boss", 1, true) or lower:find("fourth boss", 1, true) then return 4 end
    if lower:find("mini%-boss", 1) or lower:find("mini boss", 1, true) then return 40 end
    if lower:find("all bosses", 1, true) then return 90 end
    if lower:find("final boss", 1, true) or lower:find("last boss", 1, true) then return 99 end
    if lower:find("boss", 1, true) then return 70 end
    return 50
end

local function BuildDungeonBossTipItems(instanceCtx, keyPrefix)
    local items = {}
    local seen = {}
    local prefix = keyPrefix or "group_boss"

    for _, bossTip in ipairs(GetNormalizedBossTips(instanceCtx)) do
        local signature = table.concat({
            SafeText(bossTip.title) or "",
            SafeText(bossTip.encounter) or "",
            SafeText(bossTip.detail) or "",
        }, "|")
        if not seen[signature] then
            items[#items + 1] = {
                id = prefix .. ":" .. signature,
                title = bossTip.title or "Boss Tip",
                encounter = bossTip.encounter,
                detail = bossTip.detail,
                icon = 236344,
                actionLabel = "Boss Tip",
                actionHex = DUNGEON_FOCUS_PRIORITY_HEX,
                accent = RECOMMEND_COLOR,
                priorityRank = GetEncounterSortRank(bossTip.encounter or bossTip.title),
                sortWeight = 8,
            }
            seen[signature] = true
        end
    end

    table.sort(items, function(a, b)
        if a.priorityRank ~= b.priorityRank then
            return a.priorityRank < b.priorityRank
        end
        if a.sortWeight ~= b.sortWeight then
            return a.sortWeight > b.sortWeight
        end
        return (a.title or "") < (b.title or "")
    end)

    return items
end

local function BuildDungeonTrickItems(ctx, instanceCtx, keyPrefix)
    local items = {}
    local seen = {}
    local prefix = keyPrefix or "group_trick"

    local timerInfo = (S.db and S.db.showDungeonTimers ~= false) and GetDungeonTimerInfo(ctx, instanceCtx) or nil
    if timerInfo then
        items[#items + 1] = {
            id = prefix .. ":timer",
            title = "Dungeon Timer",
            detail = BuildDungeonTimerBody(timerInfo),
            icon = 134376,
            actionLabel = "Timer",
            actionHex = DUNGEON_FOCUS_PRIORITY_HEX,
            accent = RECOMMEND_COLOR,
            groupSummary = "Mythic+ timer target",
            sortWeight = 8,
            priorityRank = 1,
        }
        seen.timer = true
    end

    for _, trick in ipairs(GetNormalizedTipsAndTricks(instanceCtx)) do
        local signature = table.concat({
            SafeText(trick.title) or "",
            SafeText(trick.encounter) or "",
            SafeText(trick.detail) or "",
        }, "|")
        if not seen[signature] then
            items[#items + 1] = {
                id = prefix .. ":" .. signature,
                title = trick.title or "Tip",
                encounter = trick.encounter,
                detail = trick.detail,
                icon = trick.icon or ((trick.spellID and GET_SPELL_TEXTURE and GET_SPELL_TEXTURE(trick.spellID)) or 134400),
                spellID = trick.spellID,
                buff = trick.buff,
                object = trick.object,
                actionLabel = "Tip",
                actionHex = DUNGEON_FOCUS_NPC_HEX,
                accent = RECOMMEND_COLOR,
                sortWeight = 6,
                priorityRank = 2,
            }
            seen[signature] = true
        end
    end

    table.sort(items, function(a, b)
        if a.sortWeight ~= b.sortWeight then
            return a.sortWeight > b.sortWeight
        end
        if a.priorityRank ~= b.priorityRank then
            return a.priorityRank < b.priorityRank
        end
        return (a.title or "") < (b.title or "")
    end)

    return items
end

local function BuildDungeonGroupFocusModel(ctx, results, noteLines, instanceCtx)
    local resultMap = BuildResultMap(results)
    local sections = {}

    local priorityItems = BuildDungeonGroupDispelItems(ctx, resultMap, instanceCtx)
    local stopItems = BuildDungeonStopItems(instanceCtx)
    local bossItems = BuildDungeonBossTipItems(instanceCtx, "group_boss")
    local trickItems = BuildDungeonTrickItems(ctx, instanceCtx, "group_trick")

    if #stopItems > 0 then
        sections[#sections + 1] = {
            key = format("groupfocus:%s:interrupts", tostring(ctx and ctx.instanceID or "world")),
            title = "Key Interrupts",
            subtitle = "The casts that should have a kick order before the pull starts.",
            items = stopItems,
            accent = { HexToColorTriplet(DUNGEON_FOCUS_INTERRUPT_HEX, RECOMMEND_COLOR) },
        }
    end

    if #priorityItems > 0 then
        sections[#sections + 1] = {
            key = format("groupfocus:%s:dispels", tostring(ctx and ctx.instanceID or "world")),
            title = "Key Dispels",
            subtitle = "Group composition first. Cards show what the dungeon demands and whether the roster is covered, thin, or missing.",
            items = priorityItems,
            accent = { HexToColorTriplet(DUNGEON_FOCUS_DISPEL_HEX.magic, RECOMMEND_COLOR) },
        }
    end

    if #bossItems > 0 then
        sections[#sections + 1] = {
            key = format("groupfocus:%s:boss", tostring(ctx and ctx.instanceID or "world")),
            title = "Boss Tips",
            subtitle = "Boss-only notes worth keeping visible between pulls.",
            items = bossItems,
            accent = { HexToColorTriplet(DUNGEON_FOCUS_PRIORITY_HEX, RECOMMEND_COLOR) },
        }
    end

    if #trickItems > 0 then
        sections[#sections + 1] = {
            key = format("groupfocus:%s:tricks", tostring(ctx and ctx.instanceID or "world")),
            title = "Tips and Tricks",
            subtitle = "Sticky route notes, utility reminders, and the dungeon timer.",
            items = trickItems,
            accent = { HexToColorTriplet(DUNGEON_FOCUS_NPC_HEX, RECOMMEND_COLOR) },
        }
    end

    return {
        title = "Group Cheat Sheet",
        description = "Cheat-sheet view for the group: key interrupts, key dispels, boss reminders, and sticky run notes.",
        sections = sections,
    }
end

local function RenderDungeonGroupFocusPage(content, yOff, ctx, results, noteLines, instanceCtx)
    local viewer = GetViewerProfile()
    local focus = BuildDungeonGroupFocusModel(ctx, results, noteLines, instanceCtx)
    local hasItems = false

    for _, section in ipairs(focus.sections or {}) do
        if section.items and #section.items > 0 then
            hasItems = true
            break
        end
    end

    if not hasItems then
        return yOff, false
    end

    if viewer and viewer.mode == "browse" then
        yOff = AddCard(content, yOff, "Theorycraft View",
            format("Showing the group through a %s %s lens. Shared coverage treats your slot as this spec.",
                viewer.specName or "Spec", viewer.classLabel or "Unknown"),
            SEVERITY_COLORS.info)
    end

    yOff = AddCard(content, yOff, focus.title, focus.description, RECOMMEND_COLOR)

    for _, section in ipairs(focus.sections or {}) do
        if section.items and #section.items > 0 then
            yOff = RenderDungeonFocusSection(content, yOff, section)
        end
    end

    S.uiState.workspaceShell:SetContentHeight(math.abs(yOff) + 32)
    return yOff, true
end

local function EnsureDungeonFocusTooltipModel(tip)
    if not tip then return nil end
    if tip.MedaAurasMobModel then return tip.MedaAurasMobModel end

    local model = CreateFrame("PlayerModel", nil, tip)
    model:SetSize(118, 118)
    model:SetPoint("TOPLEFT", tip, "TOPRIGHT", 10, -8)
    model:SetFrameStrata(tip:GetFrameStrata())
    model:Hide()
    tip.MedaAurasMobModel = model

    tip:HookScript("OnHide", function(self)
        if self.MedaAurasMobModel then
            self.MedaAurasMobModel:Hide()
            if self.MedaAurasMobModel.ClearModel then
                pcall(self.MedaAurasMobModel.ClearModel, self.MedaAurasMobModel)
            end
        end
    end)

    return model
end

local function AttachDungeonFocusTooltipModel(tip, entry)
    if not tip then return end

    local model = EnsureDungeonFocusTooltipModel(tip)
    if not model then return end

    local displayID = entry and entry.displayID or nil
    if not displayID then
        model:Hide()
        return
    end

    if model.ClearModel then
        pcall(model.ClearModel, model)
    end

    local ok = false
    if model.SetDisplayInfo then
        ok = pcall(model.SetDisplayInfo, model, displayID)
    end

    if ok then
        if model.SetPortraitZoom then pcall(model.SetPortraitZoom, model, 0) end
        if model.SetCamDistanceScale then pcall(model.SetCamDistanceScale, model, 1.2) end
        model:Show()
    else
        model:Hide()
    end
end

local function AddDungeonFocusTooltip(tip, entry)
    if not tip or not entry then return end

    local danger = entry.danger or {}
    local title = entry.title or danger.mechanic or entry.mob or "Priority"
    BeginSpellTooltip(tip, entry.spellID or entry.buff or danger.spellID or danger.mechanic, title)

    AddTooltipSpacer(tip)
    if entry.actionLabel and entry.actionLabel ~= "" then
        local r, g, b = HexToColorTriplet(entry.actionHex, { 1, 1, 1 })
        tip:AddLine(entry.actionLabel, r, g, b)
    end

    if entry.mob and entry.mob ~= "" then
        local r, g, b = HexToColorTriplet(DUNGEON_FOCUS_MOB_HEX, { 1, 0.8, 0.6 })
        tip:AddLine("Mob: " .. entry.mob, r, g, b)
    end

    if entry.encounter and entry.encounter ~= "" then
        local r, g, b = HexToColorTriplet(DUNGEON_FOCUS_NPC_HEX, { 0.5, 0.9, 0.5 })
        tip:AddLine("Encounter: " .. entry.encounter, r, g, b)
    end

    if entry.object and entry.object ~= "" then
        tip:AddLine("Object: " .. entry.object, 0.85, 0.82, 0.62)
    end

    if entry.buff and entry.buff ~= "" and entry.buff ~= title then
        tip:AddLine("Buff: " .. entry.buff, 0.62, 0.88, 1.0)
    end

    if danger.dispelType and danger.dispelType ~= "" then
        local dispelHex = DUNGEON_FOCUS_DISPEL_HEX[danger.dispelType:lower()] or DUNGEON_FOCUS_DISPEL_HEX.magic
        local r, g, b = HexToColorTriplet(dispelHex, { 0.4, 0.8, 1.0 })
        tip:AddLine("Dispel Type: " .. danger.dispelType, r, g, b)
    end

    if danger.boosted then
        tip:AddLine("Affix boosted", 1, 0.35, 0.35)
    end

    if entry.detail and entry.detail ~= "" then
        AddTooltipSpacer(tip)
        tip:AddLine(entry.detail, 1, 1, 1, true)
    end

    if entry.providersNote and entry.providersNote ~= "" then
        AddTooltipSpacer(tip)
        tip:AddLine("Coverage: " .. entry.providersNote, 0.75, 0.85, 1.0, true)
    end

    if entry.potentialProvidersNote and entry.potentialProvidersNote ~= "" then
        tip:AddLine("Can swap: " .. entry.potentialProvidersNote, 1.0, 0.78, 0.35, true)
    end

    if entry.groupSummary and entry.groupSummary ~= "" then
        tip:AddLine(entry.groupSummary, 0.8, 0.8, 0.8, true)
    end

    if entry.talentNote and entry.talentNote ~= "" then
        tip:AddLine("Talent swap: " .. entry.talentNote, 1.0, 0.78, 0.35, true)
    end

    if entry.missingNote and entry.missingNote ~= "" then
        tip:AddLine("Gap plan: " .. entry.missingNote, 1.0, 0.5, 0.5, true)
    end

    if entry.response == "have" then
        AddTooltipSpacer(tip)
        tip:AddLine("You already cover this.", 0.3, 0.85, 0.3)
    elseif entry.response == "canTalent" then
        AddTooltipSpacer(tip)
        tip:AddLine("You can talent into coverage for this.", 1.0, 0.75, 0.25)
    elseif entry.response == "unavailable" then
        AddTooltipSpacer(tip)
        tip:AddLine("Your current profile does not cover this.", 0.7, 0.7, 0.7)
    end

    AttachDungeonFocusTooltipModel(tip, entry)
end

local function RenderDungeonFocusTile(parent, yOff, entry)
    local theme = MedaUI.Theme
    local tile = CreateFrame("Button", nil, parent, "BackdropTemplate")
    tile:SetPoint("TOPLEFT", 10, yOff)
    tile:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
    tile:SetBackdrop(MedaUI:CreateBackdrop(true))
    tile:SetBackdropColor(theme.backgroundLight[1], theme.backgroundLight[2], theme.backgroundLight[3], 0.6)
    tile:SetBackdropBorderColor(theme.border[1], theme.border[2], theme.border[3], theme.border[4] or 0.6)

    local accent = entry.accent or RECOMMEND_COLOR
    local accentBar = tile:CreateTexture(nil, "ARTWORK")
    accentBar:SetColorTexture(accent[1], accent[2], accent[3], 1)
    accentBar:SetPoint("TOPLEFT", 0, 0)
    accentBar:SetPoint("BOTTOMLEFT", 0, 0)
    accentBar:SetWidth(4)

    local iconFrame = CreateFrame("Frame", nil, tile, "BackdropTemplate")
    iconFrame:SetSize(46, 46)
    iconFrame:SetPoint("TOPLEFT", 12, -12)
    iconFrame:SetBackdrop(MedaUI:CreateBackdrop(true))
    iconFrame:SetBackdropColor(0, 0, 0, 0.55)
    iconFrame:SetBackdropBorderColor(accent[1], accent[2], accent[3], 0.9)

    local icon = iconFrame:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(entry.icon or 136116)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local titleFS = tile:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleFS:SetPoint("TOPLEFT", iconFrame, "TOPRIGHT", 12, -2)
    titleFS:SetPoint("RIGHT", tile, "RIGHT", -120, 0)
    titleFS:SetJustifyH("LEFT")
    titleFS:SetWordWrap(true)
    titleFS:SetTextColor(unpack(theme.text or { 0.95, 0.95, 0.95, 1 }))
    titleFS:SetText(entry.title or "Priority")

    local badge = CreateFrame("Frame", nil, tile, "BackdropTemplate")
    badge:SetBackdrop(MedaUI:CreateBackdrop(true))
    badge:SetBackdropColor(0, 0, 0, 0.55)
    local br, bg, bb = HexToColorTriplet(entry.actionHex, RECOMMEND_COLOR)
    badge:SetBackdropBorderColor(br, bg, bb, 0.95)

    local badgeText = badge:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    badgeText:SetPoint("CENTER", 0, 0)
    badgeText:SetTextColor(br, bg, bb)
    badgeText:SetText(entry.actionLabel or "Priority")
    badge:SetSize(math.max(74, badgeText:GetStringWidth() + 18), 22)
    badge:SetPoint("TOPRIGHT", tile, "TOPRIGHT", -12, -12)

    local mobButton = CreateFrame("Button", nil, tile)
    mobButton:SetPoint("TOPLEFT", titleFS, "BOTTOMLEFT", 0, -6)
    mobButton:SetPoint("RIGHT", tile, "RIGHT", -12, 0)
    mobButton:SetHeight(18)

    local mobFS = mobButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mobFS:SetAllPoints()
    mobFS:SetJustifyH("LEFT")
    mobFS:SetWordWrap(false)
    local mobText = ""
    if entry.mob and entry.mob ~= "" then
        mobText = "|cff" .. DUNGEON_FOCUS_MOB_HEX .. entry.mob .. "|r"
    end
    if entry.encounter and entry.encounter ~= "" then
        local spacer = mobText ~= "" and "  " or ""
        mobText = mobText .. spacer .. "|cff" .. DUNGEON_FOCUS_NPC_HEX .. entry.encounter .. "|r"
    end
    mobFS:SetText(mobText)

    local detailFS = tile:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    detailFS:SetPoint("TOPLEFT", mobButton, "BOTTOMLEFT", 0, -6)
    detailFS:SetPoint("RIGHT", tile, "RIGHT", -12, 0)
    detailFS:SetJustifyH("LEFT")
    detailFS:SetWordWrap(true)
    detailFS:SetTextColor(unpack(theme.textDim or { 0.78, 0.78, 0.78, 1 }))
    detailFS:SetText(entry.detail or "")

    BindTooltip(tile, function(_, tip)
        AddDungeonFocusTooltip(tip, entry)
    end)

    BindTooltip(mobButton, function(_, tip)
        AddDungeonFocusTooltip(tip, entry)
    end)

    local height = math.max(74, 22 + titleFS:GetStringHeight() + detailFS:GetStringHeight() + 34)
    tile:SetHeight(height)

    return yOff - height - 8
end

RenderDungeonFocusSection = function(parent, yOff, section)
    if not section or not section.items or #section.items == 0 then return yOff end

    local theme = MedaUI.Theme
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetPoint("TOPLEFT", 4, yOff)
    card:SetPoint("RIGHT", parent, "RIGHT", -4, 0)
    card:SetBackdrop(MedaUI:CreateBackdrop(true))
    card:SetBackdropColor(theme.backgroundLight[1], theme.backgroundLight[2], theme.backgroundLight[3], 0.5)

    local accent = section.accent or RECOMMEND_COLOR
    local ar = accent[1] or RECOMMEND_COLOR[1]
    local ag = accent[2] or RECOMMEND_COLOR[2]
    local ab = accent[3] or RECOMMEND_COLOR[3]
    card:SetBackdropBorderColor(ar, ag, ab, 0.85)

    local titleFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFS:SetPoint("TOPLEFT", 10, -8)
    titleFS:SetTextColor(ar, ag, ab)
    titleFS:SetText(section.title or "Focus")

    local countFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countFS:SetPoint("LEFT", titleFS, "RIGHT", 8, 0)
    countFS:SetTextColor(unpack(theme.textDim or { 0.7, 0.7, 0.7, 1 }))
    countFS:SetText(format("%d shown", math.min(#section.items, DUNGEON_FOCUS_LIMIT)))

    local subtitleFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtitleFS:SetPoint("TOPLEFT", titleFS, "BOTTOMLEFT", 0, -4)
    subtitleFS:SetPoint("RIGHT", card, "RIGHT", -10, 0)
    subtitleFS:SetJustifyH("LEFT")
    subtitleFS:SetWordWrap(true)
    subtitleFS:SetTextColor(unpack(theme.textDim or { 0.72, 0.72, 0.72, 1 }))
    subtitleFS:SetText(section.subtitle or "")

    local expanded = S.playerSectionExpanded[section.key] or false
    local shown = expanded and #section.items or math.min(#section.items, DUNGEON_FOCUS_LIMIT)
    local innerY = -(subtitleFS:GetStringHeight() + 28)

    for index = 1, shown do
        innerY = RenderDungeonFocusTile(card, innerY, section.items[index])
    end

    if #section.items > DUNGEON_FOCUS_LIMIT then
        local toggle = MedaUI:CreateExpandToggle(card, {
            hiddenCount = #section.items - DUNGEON_FOCUS_LIMIT,
            expanded = expanded,
            onToggle = function(expandedState)
                S.playerSectionExpanded[section.key] = expandedState
                RunPipeline(false)
            end,
        })
        toggle:SetPoint("TOPLEFT", 10, innerY)
        toggle:SetPoint("RIGHT", card, "RIGHT", -10, 0)
        innerY = innerY - toggle:GetHeight()
    end

    local height = math.abs(innerY) + 12
    card:SetHeight(height)
    return yOff - height - 8
end

local function RenderDungeonRoleFocusPage(content, yOff, ctx, tk, instanceCtx, viewer)
    local focus = BuildDungeonRoleFocusModel(ctx, tk, instanceCtx)
    local hasItems = false
    for _, section in ipairs(focus.sections or {}) do
        if section.items and #section.items > 0 then
            hasItems = true
            break
        end
    end

    if not hasItems then
        return yOff, false
    end

    if viewer and viewer.mode == "browse" then
        yOff = AddCard(content, yOff, "Theorycraft View",
            format("Showing %s %s as your viewer profile. Dungeon focus is being simulated for this role.",
                viewer.specName or "Spec", viewer.classLabel or "Unknown"),
            SEVERITY_COLORS.info)
    end

    yOff = AddCard(content, yOff, focus.title, focus.description, RECOMMEND_COLOR)

    for _, section in ipairs(focus.sections or {}) do
        if section.items and #section.items > 0 then
            yOff = RenderDungeonFocusSection(content, yOff, section)
        end
    end

    S.uiState.workspaceShell:SetContentHeight(math.abs(yOff) + 32)
    return yOff, true
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

    if GetActivityKey(ctx) == "dungeon" then
        local _, handled = RenderDungeonRoleFocusPage(content, yOff, ctx, tk, instanceCtx, viewer)
        if handled then
            return usedSet
        end
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
                        row:SetNote(BuildCoverageProviderNote(result.matches) or FilterNoteBySource(result.matches[1] and result.matches[1].note))
                    else
                        row:SetStatus(structured.status == "missing" and "Missing" or "Covered", accent[1], accent[2], accent[3])
                        row:SetNote(FilterNoteBySource(structured.fullGroupWorkaround or structured.missingAction or structured.summary))
                    end
                    row:SetTooltipFunc(function(_, tip)
                        AddCoverageTooltip(tip, result)
                    end)
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
    if scope == "group" and GetActivityKey(ctx) == "dungeon" then
        local _, handled = RenderDungeonGroupFocusPage(content, -4, ctx, S.lastResults, notes, instanceCtx)
        if handled then
            return usedSet
        end
    end

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
R.GetContextPage = GetContextPage
R.GetDefaultSpecForClassRole = GetDefaultSpecForClassRole
R.BuildRoleDropdownItems = BuildRoleDropdownItems
R.BuildClassDropdownItems = BuildClassDropdownItems
R.BuildSpecDropdownItems = BuildSpecDropdownItems
R.SyncViewerToolbar = SyncViewerToolbar
R.GetEffectiveContext = GetEffectiveContext
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
