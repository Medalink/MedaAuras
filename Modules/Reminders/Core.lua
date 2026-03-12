local _, ns = ...

local R = ns.Reminders or {}
ns.Reminders = R

local S = R.state or {
    rowPool = {},
    activeRows = {},
    sectionHeaders = {},
    lastResults = {},
    lastContext = {},
    dismissed = false,
    dismissedContextKey = nil,
    debugMode = false,
    isEnabled = false,
    overrideContext = nil,
    uiState = {
        detectedLabel = nil,
        workspaceShell = nil,
        selectedPage = "personal",
        selectedPersonalTab = "overview",
        viewer = {
            mode = "live",
            classToken = nil,
            role = nil,
            specID = nil,
        },
        toolbar = {},
        suppressToolbarCallbacks = false,
        navExpanded = {
            delves = true,
            dungeons = true,
            raids = true,
        },
    },
    talentRows = {},
    talentHeaders = {},
    copyPopup = nil,
    prepRows = {},
    prepHeaders = {},
    currentAffixes = nil,
    playerRows = {},
    playerHeaders = {},
    playerToolkit = nil,
    playerSectionExpanded = {},
    playerSectionLastCtxKey = nil,
    talentSectionExpanded = {},
    talentSectionLastCtxKey = nil,
    prepSectionExpanded = {},
}
R.state = S

local MedaUI = LibStub("MedaUI-1.0")

local GetPreferredStats
local FindPlayerBuff
local IsStatRecommended
local ResolveRaidByName
local ResolveInstanceContext
local IsCurrentPartyFull
local GetFullGroupWorkaround

local function ResolveSpellID(...)
    return R.ResolveSpellID(...)
end

local function BeginSpellTooltip(...)
    return R.BeginSpellTooltip(...)
end

local function AddTooltipSpacer(...)
    return R.AddTooltipSpacer(...)
end

local function CreateTooltipTextLine(...)
    return R.CreateTooltipTextLine(...)
end

local function CreateTooltipTextBlock(...)
    return R.CreateTooltipTextBlock(...)
end

local function AddRecommendationTooltip(...)
    return R.AddRecommendationTooltip(...)
end

local function RenderRecommendationCardGrid(...)
    return R.RenderRecommendationCardGrid(...)
end

local function GetResultTooltipSpellID(...)
    return R.GetResultTooltipSpellID(...)
end

local function GetViewerProfile(...)
    return R.GetViewerProfile(...)
end

local function BuildStructuredCapabilityOutput(...)
    return R.BuildStructuredCapabilityOutput(...)
end

local function EnsurePersonalSchema(...)
    return R.EnsurePersonalSchema(...)
end
-- ============================================================================
-- Constants
-- ============================================================================

local MODULE_NAME      = "Reminders"
local MODULE_VERSION   = "1.1"
local MODULE_STABILITY = "beta"   -- "experimental" | "beta" | "stable"
local MIN_DATA_VERSION = 1
local MAX_DATA_VERSION = 1

local SEVERITY_PRIORITY = { critical = 3, warning = 2, info = 1 }
local SEVERITY_COLORS = {
    critical = { 0.9, 0.2, 0.2 },
    warning  = { 1.0, 0.7, 0.2 },
    info     = { 0.4, 0.7, 1.0 },
}
local COVERED_COLOR = { 0.3, 0.85, 0.3 }
local RECOMMEND_COLOR = { 1, 0.82, 0 }
local CHROME_HEIGHT = 88

local CLASS_COLORS = RAID_CLASS_COLORS

-- ============================================================================
-- Logging
-- ============================================================================

local function Log(msg)
    MedaAuras.Log(format("[Reminders] %s", msg))
end

local function LogDebug(msg)
    MedaAuras.LogDebug(format("[Reminders] %s", msg))
end

local function LogWarn(msg)
    MedaAuras.LogWarn(format("[Reminders] %s", msg))
end

-- ============================================================================
-- Data compatibility check
-- ============================================================================

local function GetData()
    return ns.RemindersData
end

local function IsDataCompatible()
    local data = GetData()
    if not data or not data.dataVersion then return false, "missing" end
    if data.dataVersion < MIN_DATA_VERSION then return false, "too_old" end
    if data.dataVersion > MAX_DATA_VERSION then return false, "too_new" end
    return true, nil
end

-- ============================================================================
-- Helpers
-- ============================================================================

-- ============================================================================
-- Content-type filtering
-- ============================================================================

local CONTENT_CATEGORIES = {
    { key = "raid",  label = "Raid" },
    { key = "mplus", label = "Mythic+" },
    { key = "delve", label = "Delves / Open World" },
}

local function ClassifyBuildContentType(rec)
    if rec.contentType and rec.contentType ~= "" then
        return rec.contentType
    end
    if not rec.notes then return "general" end
    local lower = rec.notes:lower()
    if lower:find("raid") or lower:find("single.target") then return "raid" end
    if lower:find("mythic") or lower:find("m%+") or lower:find("mplus") or lower:find("dungeon") or lower:find("aoe") then return "mplus" end
    if lower:find("delve") then return "delve" end
    return "general"
end

local function GetContextKey(ctx)
    if not ctx or not ctx.inInstance then return "world" end
    if ctx.raidKey then return "raid:" .. ctx.raidKey end
    if ctx.instanceID then return "inst:" .. ctx.instanceID end
    if ctx.isDelve and ctx.instanceName then return "delve:" .. ctx.instanceName end
    if ctx.isDelve then return "delve" end
    if ctx.instanceType then return "type:" .. ctx.instanceType end
    return "world"
end

-- ============================================================================
-- Trigger matching
-- ============================================================================

local function ResolveDungeonByName(name)
    if not name then return nil end
    local data = GetData()
    if not data or not data.contexts or not data.contexts.dungeons then return nil end
    for id, dungeon in pairs(data.contexts.dungeons) do
        if dungeon.name == name then return id end
    end
    return nil
end

local DIFFICULTY_TIERS = {
    [1] = "normal", [38] = "normal",
    [2] = "heroic", [23] = "heroic",
    [8] = "mythicplus",
}
local TIER_RANK = { normal = 1, heroic = 2, mythicplus = 3 }

local function MapDifficultyTier(diffID)
    return DIFFICULTY_TIERS[diffID] or "normal"
end

local function GetCurrentContext()
    local inInstance, instanceType = IsInInstance()
    local ctx = {
        inInstance    = inInstance,
        instanceType  = instanceType,
        instanceID    = nil,
        instanceName  = nil,
        isDelve       = false,
        raidKey       = nil,
    }

    if C_PartyInfo and C_PartyInfo.IsDelveInProgress and C_PartyInfo.IsDelveInProgress() then
        ctx.isDelve = true
        ctx.inInstance = true
        ctx.instanceType = "delve"
    end

    if inInstance or ctx.isDelve then
        local name, _, diffID, diffName, _, _, _, id = GetInstanceInfo()
        if name then
            ctx.instanceID = id
            ctx.instanceName = name
            ctx.difficultyID = diffID
            ctx.difficultyTier = MapDifficultyTier(diffID)

            local data = GetData()
            if data and data.contexts and data.contexts.dungeons then
                if not data.contexts.dungeons[id] then
                    local resolvedID = ResolveDungeonByName(name)
                    if resolvedID then
                        LogDebug(format("Instance ID %s not in data; resolved '%s' to ID %d by name",
                            tostring(id), name, resolvedID))
                        ctx.instanceID = resolvedID
                    end
                end
            end
            if ctx.instanceType == "raid" then
                ctx.raidKey = ResolveRaidByName(name)
            end
        end
    end
    return ctx
end

local function RefreshAffixes()
    if C_MythicPlus and C_MythicPlus.GetCurrentAffixes then
        local affixes = C_MythicPlus.GetCurrentAffixes()
        if affixes and #affixes > 0 then
            S.currentAffixes = {}
            for _, a in ipairs(affixes) do
                S.currentAffixes[#S.currentAffixes + 1] = a.id
            end
            LogDebug(format("Current affixes: %s", table.concat(S.currentAffixes, ", ")))
        end
    end
end

local function TriggerMatches(trigger, ctx)
    if not trigger or not trigger.type then return false end

    if trigger.type == "instance" then
        if not ctx.inInstance then return false end

        if trigger.instanceType and trigger.instanceType ~= ctx.instanceType then
            return false
        end

        if trigger.instanceIDs then
            local found = false
            for _, id in ipairs(trigger.instanceIDs) do
                if id == ctx.instanceID then
                    found = true
                    break
                end
            end
            if not found then return false end
        end

        return true

    elseif trigger.type == "always" then
        return true
    end

    return false
end

-- ============================================================================
-- Evaluation engine
-- ============================================================================

local function ResolveConditionKey(capability, matchCount)
    local thresholds = capability.thresholds
    if not thresholds then return "none" end

    local bestKey = "none"
    local bestVal = -1

    for key, val in pairs(thresholds) do
        if matchCount > val and val > bestVal then
            bestVal = val
            bestKey = key
        elseif matchCount == val and val > bestVal then
            bestVal = val
            bestKey = key
        end
    end

    if matchCount <= (thresholds.none or 0) then
        return "none"
    end

    return bestKey
end

local function MergeOutput(capability, check, conditionKey)
    local base = capability.conditions and capability.conditions[conditionKey]
    local override = check.overrides and check.overrides[conditionKey]

    if override then
        local merged = {}
        if base then
            for k, v in pairs(base) do merged[k] = v end
        end
        for k, v in pairs(override) do merged[k] = v end
        return merged
    end

    return base or {}
end

local function ViewerMatchesProvider(profile, provider)
    if not profile or not provider then return false end
    if provider.class ~= profile.classToken then return false end
    if provider.specID and provider.specID ~= profile.specID then return false end
    return true
end

local function ViewerHasProvider(profile, provider)
    if not ViewerMatchesProvider(profile, provider) then return false end
    if profile.isLive then
        if provider.talentSpellID then
            return IsPlayerSpell and IsPlayerSpell(provider.spellID)
        end
        return provider.spellID and IsPlayerSpell and IsPlayerSpell(provider.spellID) or false
    end
    return true
end

local function CheckPersonalReminder(capability, profile)
    if not capability.personalReminder then return nil end
    if not capability.providers then return nil end
    profile = profile or GetViewerProfile()
    if not profile then return nil end

    for _, provider in ipairs(capability.providers) do
        if ViewerMatchesProvider(profile, provider) then
            if not ViewerHasProvider(profile, provider) then
                local reminder = {}
                for k, v in pairs(capability.personalReminder) do
                    reminder[k] = v
                end
                if reminder.detail then
                    reminder.detail = reminder.detail:gsub("%%spellName%%", provider.spellName or "")
                end
                if reminder.banner then
                    reminder.banner = reminder.banner:gsub("%%spellName%%", provider.spellName or "")
                end
                return reminder
            end
        end
    end

    return nil
end

local function IsCapabilityEnabled(capability)
    if not capability.tags or not S.db then return true end
    for _, tag in ipairs(capability.tags) do
        local key = "tag_" .. tag
        if S.db[key] == false then return false end
    end
    return true
end

local function GetLiveRoster()
    local roster = {}
    local GroupInspector = ns.Services.GroupInspector

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if UnitExists(unit) then
                local info = GroupInspector and GroupInspector:GetUnitInfo(unit) or nil
                local _, classToken = UnitClass(unit)
                roster[#roster + 1] = {
                    unit = unit,
                    isPlayer = unit == "player",
                    name = info and info.name or UnitName(unit) or "Unknown",
                    class = classToken,
                    specID = info and info.specID,
                }
            end
        end
    elseif IsInGroup() then
        roster[#roster + 1] = {
            unit = "player",
            isPlayer = true,
            name = UnitName("player") or "You",
            class = select(2, UnitClass("player")),
            specID = (function()
                local specIndex = GetSpecialization()
                return specIndex and GetSpecializationInfo(specIndex) or nil
            end)(),
        }
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                local info = GroupInspector and GroupInspector:GetUnitInfo(unit) or nil
                local _, classToken = UnitClass(unit)
                roster[#roster + 1] = {
                    unit = unit,
                    isPlayer = false,
                    name = info and info.name or UnitName(unit) or "Unknown",
                    class = classToken,
                    specID = info and info.specID,
                }
            end
        end
    else
        local specIndex = GetSpecialization()
        roster[#roster + 1] = {
            unit = "player",
            isPlayer = true,
            name = UnitName("player") or "You",
            class = select(2, UnitClass("player")),
            specID = specIndex and GetSpecializationInfo(specIndex) or nil,
        }
    end

    return roster
end

local function BuildViewerRoster(profile)
    local roster = GetLiveRoster()
    if not profile then return roster end

    for _, member in ipairs(roster) do
        if member.isPlayer then
            member.class = profile.classToken
            member.specID = profile.specID
            member.role = profile.role
            break
        end
    end

    if #roster == 0 and profile.classToken and profile.specID then
        roster[1] = {
            unit = "player",
            isPlayer = true,
            name = UnitName("player") or "You",
            class = profile.classToken,
            specID = profile.specID,
            role = profile.role,
        }
    end

    return roster
end

local function QueryProvidersForRoster(providersList, roster, profile)
    if not providersList then return {} end
    local matches = {}

    for _, member in ipairs(roster or {}) do
        for _, provider in ipairs(providersList) do
            if member.class == provider.class then
                local specMatch = (provider.specID == nil) or (member.specID == provider.specID)
                if specMatch then
                    local hasSpell = true
                    if member.isPlayer and profile and profile.isLive then
                        hasSpell = provider.spellID and IsPlayerSpell and IsPlayerSpell(provider.spellID) or false
                    end

                    if hasSpell then
                        matches[#matches + 1] = {
                            unit = member.unit or "player",
                            name = member.name or "Unknown",
                            class = member.class,
                            specID = member.specID,
                            spellID = provider.spellID,
                            spellName = provider.spellName,
                            note = provider.note,
                        }
                    end
                end
            end
        end
    end

    return matches
end

local function Evaluate()
    local data = GetData()
    if not data then return {} end

    local ctx = S.overrideContext or GetCurrentContext()
    S.lastContext = ctx

    local results = {}
    local seenCapabilities = {}
    local viewerProfile = GetViewerProfile()
    local roster = BuildViewerRoster(viewerProfile)

    LogDebug(format("Evaluating -- instance=%s type=%s id=%s",
        tostring(ctx.inInstance), tostring(ctx.instanceType), tostring(ctx.instanceID)))

    for _, rule in ipairs(data.rules) do
        if TriggerMatches(rule.trigger, ctx) then
            LogDebug(format("Rule '%s' triggered -- %d checks", rule.id, #(rule.checks or {})))

            for _, check in ipairs(rule.checks or {}) do
                local capID = check.capability
                if not seenCapabilities[capID] then
                    local capability = data.capabilities[capID]
                    if not capability then
                        LogWarn(format("Capability '%s' referenced by rule '%s' but not found in data",
                            capID, rule.id))
                    elseif IsCapabilityEnabled(capability) then
                        seenCapabilities[capID] = true

                        local matches = QueryProvidersForRoster(capability.providers, roster, viewerProfile)
                        local matchCount = #matches
                        local conditionKey = ResolveConditionKey(capability, matchCount)
                        local output = MergeOutput(capability, check, conditionKey)
                        local personal = CheckPersonalReminder(capability, viewerProfile)

                        LogDebug(format("  Check %s: %d match(es) -> condition '%s'%s",
                            capID, matchCount, conditionKey,
                            personal and " +personal" or ""))

                        results[#results + 1] = {
                            capabilityID = capID,
                            capability   = capability,
                            matchCount   = matchCount,
                            matches      = matches,
                            conditionKey = conditionKey,
                            output       = output,
                            personal     = personal,
                            viewer       = viewerProfile,
                            roster       = roster,
                        }
                        results[#results].structured = BuildStructuredCapabilityOutput(results[#results], ctx)
                    end
                end
            end
        end
    end

    LogDebug(format("Evaluation complete: %d results", #results))

    if S.debugMode then
        MedaAuras.LogTable(results, "Reminders_EvaluationResults", 4)
    end

    return results
end

-- ============================================================================
-- UI: Coverage Panel
-- ============================================================================

local ICON_SIZE = 32
local ICON_ZOOM = { 0.11, 0.89, 0.11, 0.89 }

local function AcquireRow(parent, width)
    local row = table.remove(S.rowPool)
    if not row then
        row = MedaUI:CreateStatusRow(parent, { width = width, showNote = true, iconSize = ICON_SIZE, cardStyle = true })
    else
        row:SetParent(parent)
        row:Reset()
        if width then row:SetWidth(width) end
    end
    row.icon:SetTexCoord(unpack(ICON_ZOOM))
    row:Show()
    return row
end

local function ReleaseRows()
    for _, row in ipairs(S.activeRows) do
        row:Hide()
        row:SetParent(nil)
        S.rowPool[#S.rowPool + 1] = row
    end
    wipe(S.activeRows)
end

local function ReleaseSectionHeaders()
    for _, hdr in ipairs(S.sectionHeaders) do
        hdr:Hide()
    end
    wipe(S.sectionHeaders)
end

local function GetDetectedLabel(ctx)
    if not ctx or not ctx.inInstance then return "World" end
    if ctx.isDelve then
        return ctx.instanceName or "Delve"
    end
    if ctx.instanceName then return ctx.instanceName end
    local data = GetData()
    if data and data.contexts and data.contexts.instanceTypes and ctx.instanceType then
        local it = data.contexts.instanceTypes[ctx.instanceType]
        if it then return it.label end
    end
    return ctx.instanceType or "Instance"
end


local function FormatSourceBadge(source)
    local data = GetData()
    if data and data.sources and data.sources[source] then
        return data.sources[source].badge
    end
    return ""
end

local function IsSourceEnabled(source)
    local data = GetData()
    if not data or not data.sources or not data.sources[source] then
        return false
    end
    if not S.db or not S.db.sources then return true end
    return S.db.sources[source] ~= false
end

local function FilterNoteBySource(note)
    if not note or note == "" then return note end
    if not S.db or not S.db.sources then return note end

    local data = GetData()
    if not data or not data.sources then return note end

    local filtered = note
    for key, src in pairs(data.sources) do
        if not IsSourceEnabled(key) then
            local escaped = src.label:gsub("([%-%.%+%[%]%(%)%$%^%%%?%*])", "%%%1")
            filtered = filtered:gsub("%s*%[" .. escaped .. ":[^%]]*%]", "")
        end
    end
    return filtered:match("^%s*(.-)%s*$") or ""
end

local function GetEnabledSources(usedSet)
    local data = GetData()
    local sources = {}
    if not data or not data.sources then return sources end

    for key, src in pairs(data.sources) do
        if IsSourceEnabled(key) then
            sources[#sources + 1] = {
                id = key,
                label = src.label or key,
                color = src.color,
                lastFetched = src.lastFetched,
                enabled = true,
                usedByCurrentView = usedSet and usedSet[key] or false,
            }
        end
    end

    table.sort(sources, function(a, b)
        if a.usedByCurrentView ~= b.usedByCurrentView then
            return a.usedByCurrentView
        end
        return (a.label or "") < (b.label or "")
    end)

    return sources
end

IsCurrentPartyFull = function(ctx)
    if not ctx or ctx.instanceType ~= "party" then return false end
    if IsInRaid() then return false end
    return IsInGroup() and GetNumGroupMembers() >= 5
end

GetFullGroupWorkaround = function(capabilityID)
    local fallback = {
        bloodlust = "No in-group lust. If your class can cover it via talent or pet swap, adjust before the run; otherwise route pulls around not having lust.",
        battle_res = "No in-group battle res. Play safer on recovery points and save personals for mistake-prone pulls.",
        offensive_dispel = "No in-group purge. Plan stops and kill targets around enemy buffs instead of assuming a dispel.",
        soothe = "No in-group enrage removal. Save crowd control, kiting, and defensives for enrage windows.",
        dispel_magic = "No in-group magic dispel. Use personals and movement to cover mechanics that would normally be dispelled.",
        dispel_disease = "No in-group disease dispel. Use defensives, self-cleanses, and route carefully through disease-heavy pulls.",
        dispel_poison = "No in-group poison dispel. Respect poison-heavy packs and use personals or self-cleanses where available.",
        dispel_curse = "No in-group curse dispel. Plan defensives and interrupts around curse-heavy casts instead of assuming a cleanse.",
    }
    return fallback[capabilityID]
        or "No in-group coverage. Adjust your own build, spec, pet, consumables, and routing to compensate with the current roster."
end

-- ============================================================================
-- Player Toolkit Evaluation ("You" tab)
-- ============================================================================

local function BuildFallbackDangers(dungeonCtx)
    local dangers = {}
    if dungeonCtx.dispelPriority then
        for _, capID in ipairs(dungeonCtx.dispelPriority) do
            dangers[#dangers + 1] = {
                capability = capID,
                severity   = "warning",
                mechanic   = capID:gsub("_", " "),
                source     = "Various",
                tip        = "Dispel required in this dungeon.",
            }
        end
    end
    if dungeonCtx.interruptPriority then
        for _, kick in ipairs(dungeonCtx.interruptPriority) do
            dangers[#dangers + 1] = {
                type     = "interrupt",
                severity = kick.danger or "medium",
                mechanic = kick.spell,
                source   = kick.mob,
                tip      = format("Interrupt %s from %s.", kick.spell, kick.mob),
            }
        end
    end
    return dangers
end

ResolveInstanceContext = function(data, ctx)
    if not data or not ctx then return nil end

    if ctx.raidKey and data.contexts and data.contexts.raids then
        local raid = data.contexts.raids[ctx.raidKey]
        if raid then return raid end
    end

    -- Try dungeon by instanceID first (most reliable)
    if ctx.instanceID and data.contexts and data.contexts.dungeons then
        local dungeon = data.contexts.dungeons[ctx.instanceID]
        if dungeon then return dungeon end
    end

    -- Try delve by name
    if ctx.instanceName and data.contexts and data.contexts.delves then
        for _, delve in ipairs(data.contexts.delves) do
            if delve.name == ctx.instanceName then return delve end
        end
    end

    if ctx.instanceName and data.contexts and data.contexts.raids then
        for _, raid in pairs(data.contexts.raids) do
            if raid.name == ctx.instanceName then return raid end
        end
    end

    -- Try dungeon by name (fallback when instanceID doesn't match)
    if ctx.instanceName and data.contexts and data.contexts.dungeons then
        for _, dungeon in pairs(data.contexts.dungeons) do
            if dungeon.name == ctx.instanceName then return dungeon end
        end
    end

    -- Generic instance type fallback
    if ctx.instanceType and data.contexts and data.contexts.instanceTypes then
        local it = data.contexts.instanceTypes[ctx.instanceType]
        if it then return { name = it.label } end
    end

    return nil
end

local function EvaluatePlayerToolkit(data, ctx)
    if not data or not ctx then return nil end

    local profile = GetViewerProfile()
    if not profile then return nil end
    local playerClass = profile.classToken
    local tierRank = TIER_RANK[ctx.difficultyTier or "normal"] or 1

    local dungeonCtx = ResolveInstanceContext(data, ctx)

    if not dungeonCtx then return nil end

    local dangers = dungeonCtx.dangers
    if not dangers or #dangers == 0 then
        dangers = BuildFallbackDangers(dungeonCtx)
    end

    -- Inject affix dangers
    local affixData = data.contexts and data.contexts.affixes
    if S.currentAffixes and affixData then
        for _, affixID in ipairs(S.currentAffixes) do
            local affix = affixData[affixID]
            if affix and affix.dangers then
                for _, ad in ipairs(affix.dangers) do
                    dangers[#dangers + 1] = {
                        type     = ad.type or "awareness",
                        severity = ad.severity or "warning",
                        mechanic = ad.mechanic,
                        source   = ad.source or affix.name,
                        tip      = ad.tip or "",
                        affix    = true,
                    }
                end
            end
        end
    end

    -- Apply affix boosts: upgrade severity for capabilities referenced by active affix boosts
    local boosted = {}
    if S.currentAffixes and affixData then
        for _, affixID in ipairs(S.currentAffixes) do
            local affix = affixData[affixID]
            if affix and affix.boosts then
                for _, cap in ipairs(affix.boosts) do
                    boosted[cap] = true
                end
            end
        end
    end

    local SEVERITY_UPGRADE = { info = "warning", warning = "critical" }
    if next(boosted) then
        for _, d in ipairs(dangers) do
            if d.capability and boosted[d.capability] then
                d.severity = SEVERITY_UPGRADE[d.severity] or d.severity
                d.boosted = true
            end
        end
    end

    -- Filter by difficulty tier
    local filtered = {}
    for _, d in ipairs(dangers) do
        local dRank = TIER_RANK[d.difficulty or "normal"] or 1
        if dRank <= tierRank then
            filtered[#filtered + 1] = d
        end
    end

    -- Determine player response for capability-based dangers
    local capabilities = data.capabilities or {}
    for _, d in ipairs(filtered) do
        if d.capability then
            local cap = capabilities[d.capability]
            if cap and cap.providers then
                local have, canTalent = false, false
                for _, prov in ipairs(cap.providers) do
                    if ViewerMatchesProvider(profile, prov) then
                        if ViewerHasProvider(profile, prov) then
                            have = true
                            break
                        elseif prov.talentSpellID then
                            canTalent = true
                        end
                    end
                end
                if have then
                    d.response = "have"
                elseif canTalent then
                    d.response = "canTalent"
                else
                    d.response = "unavailable"
                end
            end
        end
    end

    -- Sort: critical first, then warning, then info
    table.sort(filtered, function(a, b)
        local pa = SEVERITY_PRIORITY[a.severity] or 0
        local pb = SEVERITY_PRIORITY[b.severity] or 0
        if pa ~= pb then return pa > pb end
        return (a.mechanic or "") < (b.mechanic or "")
    end)

    -- Filter talent tips by player class
    local tips = {}
    if dungeonCtx.talentTips then
        for _, tt in ipairs(dungeonCtx.talentTips) do
            if tt.class == playerClass then
                local known = false
                local spellID = ResolveSpellID(tt.spell)
                if tt.spell and tt.spell ~= "" and profile.isLive and IsPlayerSpell then
                    known = spellID and IsPlayerSpell(spellID) or false
                elseif tt.spell and tt.spell ~= "" and not profile.isLive then
                    known = true
                end
                tips[#tips + 1] = { spell = tt.spell, spellID = spellID, tip = tt.tip, known = known }
            end
        end
    end

    -- Filter lust timings by active affixes
    local lusts = {}
    if dungeonCtx.lustTimings then
        for _, lt in ipairs(dungeonCtx.lustTimings) do
            local show = true
            if lt.affix then
                show = false
                if S.currentAffixes and affixData then
                    for _, aID in ipairs(S.currentAffixes) do
                        local a = affixData[aID]
                        if a and a.name and a.name:lower():find(lt.affix:lower(), 1, true) then
                            show = true
                            break
                        end
                    end
                end
            end
            if show then
                lusts[#lusts + 1] = lt
            end
        end
    end

    local notes = dungeonCtx.notes
    if type(notes) == "string" and notes ~= "" then
        notes = { notes }
    elseif type(notes) ~= "table" then
        notes = nil
    end

    return {
        dangers   = filtered,
        tips      = tips,
        lusts     = lusts,
        interactiveBuffs = dungeonCtx.interactiveBuffs or {},
        header    = dungeonCtx.header or dungeonCtx.name or "Unknown Instance",
        notes     = notes,
        tier      = ctx.difficultyTier or "normal",
        className = playerClass,
        profile   = profile,
    }
end

local function FormatProviderText(matches)
    if not matches or #matches == 0 then return nil end
    local parts = {}
    for _, m in ipairs(matches) do
        local cc = CLASS_COLORS[m.class]
        local colorStr = cc and format("|cff%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255) or "|cffffffff"
        parts[#parts + 1] = format("%s%s|r", colorStr, m.name or "?")
    end
    return table.concat(parts, ", ")
end

local function UpdateDetectedLabel()
    if not S.uiState.detectedLabel then return end
    local liveCtx = GetCurrentContext()
    S.uiState.detectedLabel:SetText("Detected: " .. GetDetectedLabel(liveCtx))
end

local function ClearTabFrame(frame, preserve)
    if not frame then return end
    ReleaseRows()
    ReleaseSectionHeaders()

    local skip = {}
    if preserve then
        for _, p in ipairs(preserve) do skip[p] = true end
    end

    local kids = { frame:GetChildren() }
    for _, child in ipairs(kids) do
        if not skip[child] then
            child:Hide()
            child:ClearAllPoints()
        end
    end
    for _, region in ipairs({ frame:GetRegions() }) do
        if not skip[region] then
            region:Hide()
        end
    end
end

-- ============================================================================
-- UI: Player ("You") Tab
-- ============================================================================

local function ReleasePlayerRows()
    for _, row in ipairs(S.playerRows) do
        row:Hide()
        row:SetParent(nil)
    end
    wipe(S.playerRows)
end

local function ReleasePlayerHeaders()
    for _, hdr in ipairs(S.playerHeaders) do
        hdr:Hide()
    end
    wipe(S.playerHeaders)
end

-- Dispel school colors (standard WoW convention)
local DISPEL_COLORS = {
    dispel_magic   = "3399ff",   -- blue
    dispel_curse   = "9933cc",   -- purple
    dispel_poison  = "00cc44",   -- green
    dispel_disease = "cc8833",   -- brown
}
local SPELL_COLOR_DEFAULT = "00ccff" -- cyan fallback

-- Color [Spell Name] references, using dispel-type colors when a spellMap is provided.
-- Only colors short bracket content (spell names); leaves long descriptions uncolored.
local function ColorSpellNames(text, spellMap)
    if not text then return text end
    local colored = text:gsub("%[([^%]]+)%]", function(name)
        if spellMap and spellMap[name] then
            return "|cff" .. spellMap[name] .. "[" .. name .. "]|r"
        end
        if #name > 40 then return "[" .. name .. "]" end
        return "|cff" .. SPELL_COLOR_DEFAULT .. "[" .. name .. "]|r"
    end)
    return colored
end

-- Color known mob/NPC names with a distinct mob color (gold)
local function ColorMobNames(text, mobSet)
    if not text or not mobSet then return text end
    for name in pairs(mobSet) do
        text = text:gsub(name, "|cffddaa44" .. name .. "|r")
    end
    return text
end

-- Build a set of known mob names from danger source fields
local function BuildMobSet(dangers)
    local set = {}
    if not dangers then return set end
    for _, d in ipairs(dangers) do
        if d.source and d.source ~= "" then
            for mob in d.source:gmatch("([^,]+)") do
                mob = mob:match("^%s*(.-)%s*$")
                if mob ~= "" then
                    set[mob] = true
                end
            end
        end
    end
    return set
end

-- Build a map of spell name -> hex color from danger mechanic/capability fields
local function BuildSpellMap(dangers)
    local map = {}
    if not dangers then return map end
    for _, d in ipairs(dangers) do
        if d.mechanic and d.capability and DISPEL_COLORS[d.capability] then
            map[d.mechanic] = DISPEL_COLORS[d.capability]
        end
    end
    return map
end

-- Apply spell (with dispel-type colors) and mob coloring to a text string
local function ColorText(text, mobSet, spellMap)
    text = ColorSpellNames(text, spellMap)
    text = ColorMobNames(text, mobSet)
    return text
end

local function RenderPlayerTab(content)
    if not content then return end

    ReleasePlayerRows()
    ReleasePlayerHeaders()

    local kids = { content:GetChildren() }
    for _, child in ipairs(kids) do child:Hide(); child:SetParent(nil) end
    for _, region in ipairs({ content:GetRegions() }) do region:Hide() end

    if not S.playerToolkit then
        local emptyFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        emptyFS:SetPoint("TOPLEFT", 8, -8)
        emptyFS:SetPoint("RIGHT", content, "RIGHT", -8, 0)
        emptyFS:SetJustifyH("LEFT")
        emptyFS:SetWordWrap(true)
        emptyFS:SetTextColor(0.5, 0.5, 0.5)
        emptyFS:SetText("Enter an instance or select one from the dropdown above to see your personal coaching report.")
        if S.coveragePanel then S.coveragePanel:SetContentHeight(CHROME_HEIGHT + 60) end
        return
    end

    local tk = S.playerToolkit
    local Theme = MedaUI.Theme
    local yOff = -4

    local ctxKey = tk.instanceName or tk.header or ""
    if ctxKey ~= S.playerSectionLastCtxKey then
        wipe(S.playerSectionExpanded)
        S.playerSectionLastCtxKey = ctxKey
    end

    local MAX_VISIBLE = 4
    local mobSet = BuildMobSet(tk.dangers)
    local spellMap = BuildSpellMap(tk.dangers)

    -- Instance briefing
    do
        local noteCount = tk.notes and #tk.notes or 0
        local briefExpanded = S.playerSectionExpanded["briefing"] or false
        local briefHdr = MedaUI:CreateCollapsibleSectionHeader(content, {
            text = "Instance Briefing",
            width = content:GetWidth() - 8,
            count = noteCount,
            expanded = briefExpanded,
            onToggle = function(exp)
                S.playerSectionExpanded["briefing"] = exp
                RenderPlayerTab(content)
            end,
        })
        briefHdr:SetPoint("TOPLEFT", 4, yOff)
        S.playerHeaders[#S.playerHeaders + 1] = briefHdr
        yOff = yOff - 32

        local headerFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        headerFS:SetPoint("TOPLEFT", 8, yOff)
        headerFS:SetPoint("RIGHT", content, "RIGHT", -8, 0)
        headerFS:SetJustifyH("LEFT")
        headerFS:SetWordWrap(true)
        headerFS:SetText(tk.header)
        yOff = yOff - headerFS:GetStringHeight() - 4

        local tierLabel = (tk.tier == "mythicplus" and "|cffff8800Mythic+|r") or
                          (tk.tier == "heroic" and "|cff00ccffHeroic|r") or
                          "|cff888888Normal|r"
        local tierFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tierFS:SetPoint("TOPLEFT", 8, yOff)
        tierFS:SetTextColor(0.78, 0.78, 0.78)
        tierFS:SetText("Difficulty: " .. tierLabel)
        yOff = yOff - 16

        if tk.notes then
            local showNotes = briefExpanded and noteCount or math.min(MAX_VISIBLE, noteCount)
            for i = 1, showNotes do
                local note = tk.notes[i]
                local noteFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                noteFS:SetPoint("TOPLEFT", 12, yOff)
                noteFS:SetPoint("RIGHT", content, "RIGHT", -8, 0)
                noteFS:SetJustifyH("LEFT")
                noteFS:SetWordWrap(true)
                noteFS:SetTextColor(0.85, 0.85, 0.85)
                noteFS:SetText("- " .. ColorText(note, mobSet, spellMap))
                yOff = yOff - noteFS:GetStringHeight() - 2
            end

            if noteCount > MAX_VISIBLE then
                local toggle = MedaUI:CreateExpandToggle(content, {
                    hiddenCount = noteCount - MAX_VISIBLE,
                    expanded = briefExpanded,
                    onToggle = function(exp)
                        S.playerSectionExpanded["briefing"] = exp
                        RenderPlayerTab(content)
                    end,
                })
                toggle:SetPoint("TOPLEFT", 8, yOff)
                toggle:SetPoint("RIGHT", content, "RIGHT", 0, 0)
                yOff = yOff - toggle:GetHeight() - 2
            end
        end
        yOff = yOff - 8
    end

    -- Key Dangers
    if #tk.dangers > 0 then
        local SEV_WEIGHT = { critical=6, high=5, warning=4, medium=3, info=2, low=1 }
        table.sort(tk.dangers, function(a, b)
            return (SEV_WEIGHT[a.severity] or 0) > (SEV_WEIGHT[b.severity] or 0)
        end)

        local totalDangers = #tk.dangers
        local dangersExpanded = S.playerSectionExpanded["dangers"] or false
        local showDangers = dangersExpanded and totalDangers or math.min(MAX_VISIBLE, totalDangers)

        local dangerHdr = MedaUI:CreateCollapsibleSectionHeader(content, {
            text = "Key Dangers",
            width = content:GetWidth() - 8,
            count = totalDangers,
            expanded = dangersExpanded,
            onToggle = function(exp)
                S.playerSectionExpanded["dangers"] = exp
                RenderPlayerTab(content)
            end,
        })
        dangerHdr:SetPoint("TOPLEFT", 4, yOff)
        S.playerHeaders[#S.playerHeaders + 1] = dangerHdr
        yOff = yOff - 32

        local DANGER_ACCENT = {
            critical = { 0.9, 0.2, 0.2 },
            high     = { 0.9, 0.4, 0.2 },
            warning  = { 1.0, 0.7, 0.2 },
            medium   = { 1.0, 0.7, 0.2 },
            info     = { 0.4, 0.7, 1.0 },
            low      = { 0.6, 0.6, 0.6 },
        }
        local RESPONSE_TEXT = {
            have        = { label = "You have this",  color = { 0.3, 0.85, 0.3 } },
            canTalent   = { label = "Talent available", color = { 1.0, 0.7, 0.2 } },
            unavailable = { label = "Not available",  color = { 0.5, 0.5, 0.5 } },
        }

        local DANGER_ICONS = {
            interrupt = 132938,
            awareness = 132323,
            dispel_magic  = 135894,
            dispel_curse  = 135952,
            dispel_poison = 136068,
            dispel_disease = 135935,
            offensive_dispel = 135739,
            soothe = 132163,
        }
        local DANGER_ICON_DEFAULT = 136116

        for i = 1, showDangers do
            local d = tk.dangers[i]
            local accent = DANGER_ACCENT[d.severity] or DANGER_ACCENT.info
            local isInterrupt = d.type == "interrupt"
            local isAwareness = d.type == "awareness"

            local row = MedaUI:CreateStatusRow(content, { iconSize = 32, showNote = true, width = content:GetWidth(), cardStyle = true })
            S.playerRows[#S.playerRows + 1] = row

            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOff)
            row:SetPoint("RIGHT", content, "RIGHT", 0, 0)

            local icon = DANGER_ICONS[d.type] or DANGER_ICONS[d.capability] or DANGER_ICON_DEFAULT
            row:SetIcon(icon)
            local mechLabel = d.mechanic or "Unknown"
            local dispelHex = d.capability and DISPEL_COLORS[d.capability]
            if dispelHex then
                mechLabel = "|cff" .. dispelHex .. mechLabel .. "|r"
            end
            row:SetLabel(mechLabel)
            row:SetAccentColor(accent[1], accent[2], accent[3])

            local srcColored = ""
            if d.source and d.source ~= "" then
                srcColored = "|cffddaa44" .. d.source .. "|r"
                if d.encounter and d.encounter ~= "" then
                    local encLower = d.encounter:lower()
                    if not d.source:lower():find(encLower, 1, true) then
                        srcColored = srcColored .. " |cff888888(" .. d.encounter .. ")|r"
                    end
                end
            end

            if d.response and RESPONSE_TEXT[d.response] then
                local rt = RESPONSE_TEXT[d.response]
                row:SetStatus(rt.label, rt.color[1], rt.color[2], rt.color[3])
                row:SetHighlight(d.response == "canTalent")
            elseif isInterrupt then
                row:SetStatus("Interrupt", 0.4, 0.7, 1.0)
                row:SetHighlight(d.severity == "high" or d.severity == "critical")
            elseif isAwareness then
                row:SetStatus("Watch Out", 0.7, 0.5, 0.9)
                row:SetHighlight(d.severity == "critical")
            else
                row:SetStatus(d.severity or "", accent[1], accent[2], accent[3])
                row:SetHighlight(d.severity == "critical")
            end

            local noteText = ""
            if srcColored ~= "" then
                noteText = srcColored .. "  "
            end
            noteText = noteText .. ColorSpellNames(d.tip or "", spellMap)
            if d.boosted then
                noteText = noteText .. "  |cffff4400(boosted by affix)|r"
            end
            row:SetNote(noteText)

            row:SetTooltipFunc(function(_, tip)
                local showedSpell = BeginSpellTooltip(tip, d.spellID or d.mechanic, d.mechanic or "Unknown")
                if showedSpell then
                    AddTooltipSpacer(tip)
                end
                if d.source then tip:AddLine("Source: " .. d.source, 0.87, 0.67, 0.27) end
                if d.encounter and d.encounter ~= "" then tip:AddLine("Encounter: " .. d.encounter, 0.6, 0.6, 0.6) end
                tip:AddLine(" ")
                if d.tip then tip:AddLine(d.tip, 1, 1, 1, true) end
                if d.response and RESPONSE_TEXT[d.response] then
                    tip:AddLine(" ")
                    local rt = RESPONSE_TEXT[d.response]
                    tip:AddLine(rt.label, rt.color[1], rt.color[2], rt.color[3])
                end
            end)

            yOff = yOff - row:GetHeight() - 6
        end

        if totalDangers > MAX_VISIBLE then
            local toggle = MedaUI:CreateExpandToggle(content, {
                hiddenCount = totalDangers - MAX_VISIBLE,
                expanded = dangersExpanded,
                onToggle = function(exp)
                    S.playerSectionExpanded["dangers"] = exp
                    RenderPlayerTab(content)
                end,
            })
            toggle:SetPoint("TOPLEFT", 8, yOff)
            toggle:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            yOff = yOff - toggle:GetHeight() - 2
        end

        yOff = yOff - 8
    end

    -- Lust Timings
    if tk.lusts and #tk.lusts > 0 then
        local totalLusts = #tk.lusts
        local lustsExpanded = S.playerSectionExpanded["lusts"] or false
        local showLusts = lustsExpanded and totalLusts or math.min(MAX_VISIBLE, totalLusts)

        local lustHdr = MedaUI:CreateCollapsibleSectionHeader(content, {
            text = "Bloodlust Timings",
            width = content:GetWidth() - 8,
            count = totalLusts,
            expanded = lustsExpanded,
            onToggle = function(exp)
                S.playerSectionExpanded["lusts"] = exp
                RenderPlayerTab(content)
            end,
        })
        lustHdr:SetPoint("TOPLEFT", 4, yOff)
        S.playerHeaders[#S.playerHeaders + 1] = lustHdr
        yOff = yOff - 32

        local lustNum = 0
        for i = 1, showLusts do
            local lt = tk.lusts[i]
            lustNum = lustNum + 1
            local pct = lt.pct or 0
            local pctColor
            if pct >= 80 then
                pctColor = "44dd44"
            elseif pct >= 40 then
                pctColor = "dddd44"
            elseif pct > 0 then
                pctColor = "dd8844"
            else
                pctColor = "888888"
            end

            local isOutlier = pct > 0 and pct < 40

            local line
            if isOutlier then
                line = format("|TInterface\\AddOns\\MedaUI\\Media\\Textures\\diamond.tga:10:10|t |cff%sALT|r  ", pctColor)
            else
                line = format("|cff%s#%d|r  ", pctColor, lustNum)
            end

            line = line .. format("|cffffcc00%s|r", lt.timing or "?")

            if pct > 0 then
                line = line .. format("  |cff%s(%d%%)|r", pctColor, pct)
            end

            local lustFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            lustFS:SetPoint("TOPLEFT", 8, yOff)
            lustFS:SetPoint("RIGHT", content, "RIGHT", -8, 0)
            lustFS:SetJustifyH("LEFT")
            lustFS:SetWordWrap(true)
            lustFS:SetText(line)
            yOff = yOff - lustFS:GetStringHeight() - 2

            if lt.note then
                local noteFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                noteFS:SetPoint("TOPLEFT", 24, yOff)
                noteFS:SetPoint("RIGHT", content, "RIGHT", -8, 0)
                noteFS:SetJustifyH("LEFT")
                noteFS:SetWordWrap(true)
                noteFS:SetText("|cffcccccc" .. lt.note .. "|r")
                yOff = yOff - noteFS:GetStringHeight() - 4
            end
        end

        if totalLusts > MAX_VISIBLE then
            local toggle = MedaUI:CreateExpandToggle(content, {
                hiddenCount = totalLusts - MAX_VISIBLE,
                expanded = lustsExpanded,
                onToggle = function(exp)
                    S.playerSectionExpanded["lusts"] = exp
                    RenderPlayerTab(content)
                end,
            })
            toggle:SetPoint("TOPLEFT", 8, yOff)
            toggle:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            yOff = yOff - toggle:GetHeight() - 2
        end

        yOff = yOff - 8
    end

    -- Talent Tips
    if #tk.tips > 0 then
        local totalTips = #tk.tips
        local tipsExpanded = S.playerSectionExpanded["tips"] or false
        local showTips = tipsExpanded and totalTips or math.min(MAX_VISIBLE, totalTips)

        local tipHdr = MedaUI:CreateCollapsibleSectionHeader(content, {
            text = "Talent Tips",
            width = content:GetWidth() - 8,
            count = totalTips,
            expanded = tipsExpanded,
            onToggle = function(exp)
                S.playerSectionExpanded["tips"] = exp
                RenderPlayerTab(content)
            end,
        })
        tipHdr:SetPoint("TOPLEFT", 4, yOff)
        S.playerHeaders[#S.playerHeaders + 1] = tipHdr
        yOff = yOff - 32

        for i = 1, showTips do
            local tt = tk.tips[i]
            local icon = tt.known and "|cff4ddb4d+|r " or "|cffffcc00?|r "
            local _, _, height = CreateTooltipTextBlock(
                content,
                yOff,
                icon .. ColorText(tt.tip, mobSet, spellMap),
                function(_, tip)
                    local spellLabel = tt.spell or "Talent Tip"
                    local showedSpell = BeginSpellTooltip(tip, tt.spellID or tt.spell, spellLabel)
                    if showedSpell then
                        AddTooltipSpacer(tip)
                    end
                    if tt.tip and tt.tip ~= "" then
                        tip:AddLine(tt.tip, 1, 1, 1, true)
                    end
                end
            )
            yOff = yOff - height - 4
        end

        if totalTips > MAX_VISIBLE then
            local toggle = MedaUI:CreateExpandToggle(content, {
                hiddenCount = totalTips - MAX_VISIBLE,
                expanded = tipsExpanded,
                onToggle = function(exp)
                    S.playerSectionExpanded["tips"] = exp
                    RenderPlayerTab(content)
                end,
            })
            toggle:SetPoint("TOPLEFT", 8, yOff)
            toggle:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            yOff = yOff - toggle:GetHeight() - 2
        end

        yOff = yOff - 8
    end

    -- Interactive Dungeon Buffs
    if tk.interactiveBuffs and #tk.interactiveBuffs > 0 then
        local preferredStats = GetPreferredStats()
        local buffHdr = MedaUI:CreateSectionHeader(content, "Dungeon Buffs", content:GetWidth() - 8)
        buffHdr:SetPoint("TOPLEFT", 4, yOff)
        S.playerHeaders[#S.playerHeaders + 1] = buffHdr
        yOff = yOff - 32

        for _, ib in ipairs(tk.interactiveBuffs) do
            local ok, detail = FindPlayerBuff(ib.pattern)
            local recommended = IsStatRecommended(ib.statType, preferredStats)

            local row = MedaUI:CreateStatusRow(content, { iconSize = 24, showNote = true, width = content:GetWidth(), cardStyle = true })
            S.playerRows[#S.playerRows + 1] = row
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOff)
            row:SetPoint("RIGHT", content, "RIGHT", 0, 0)

            local labelText = ib.buff
            if recommended and not ok then
                labelText = "|TInterface\\AddOns\\MedaUI\\Media\\Textures\\star-filled.tga:10:10|t " .. labelText
            end
            row:SetLabel(labelText)

            if ok then
                row:SetAccentColor(COVERED_COLOR[1], COVERED_COLOR[2], COVERED_COLOR[3])
                row:SetStatus(detail or "Active")
                row:SetHighlight(false)
            elseif recommended then
                row:SetAccentColor(RECOMMEND_COLOR[1], RECOMMEND_COLOR[2], RECOMMEND_COLOR[3])
                row:SetStatus("Recommended", RECOMMEND_COLOR[1], RECOMMEND_COLOR[2], RECOMMEND_COLOR[3])
                row:SetHighlight(true)
            else
                row:SetAccentColor(0.5, 0.5, 0.5)
                row:SetStatus(ib.effect or "")
                row:SetHighlight(false)
            end

            local noteText = ib.location or ""
            if ib.requires then
                noteText = noteText .. "  |cffdd8888Requires: " .. ib.requires .. "|r"
            end
            row:SetNote(noteText)

            row:SetTooltipFunc(function(_, tip)
                local showedSpell = BeginSpellTooltip(tip, ib.spellID or ib.buff, ib.buff)
                if showedSpell then
                    AddTooltipSpacer(tip)
                end
                tip:AddLine(ib.effect, 1, 1, 1, true)
                if ib.location and ib.location ~= "" then
                    tip:AddLine("Location: " .. ib.location, 0.7, 0.7, 0.7, true)
                end
                if ib.requires then
                    tip:AddLine("Requires: " .. ib.requires, 0.9, 0.5, 0.5, true)
                end
                if recommended then
                    tip:AddLine(" ")
                    tip:AddLine("Matches your spec's preferred stats", RECOMMEND_COLOR[1], RECOMMEND_COLOR[2], RECOMMEND_COLOR[3])
                end
                if ib.tip and ib.tip ~= "" then
                    tip:AddLine(" ")
                    tip:AddLine(ib.tip, 1, 1, 1, true)
                end
            end)

            yOff = yOff - row:GetHeight() - 6
        end
        yOff = yOff - 8
    end

    if S.coveragePanel then S.coveragePanel:SetContentHeight(CHROME_HEIGHT + math.abs(yOff) + 8) end
end

-- ============================================================================
-- UI: Group Comp rendering
-- ============================================================================


local function ShowCopyPopup(text)
    if not S.copyPopup then
        S.copyPopup = MedaUI:CreateImportExportDialog({
            width = 420,
            height = 160,
            title = "Copy Reminder",
            mode = "export",
            hintText = "Press Ctrl+C to copy, then Esc to close.",
        })
    end

    S.copyPopup:ShowExport("Copy Reminder", text)
end

local ARCHON_LOADOUT_UNLOCK_LABEL = "March 24, 2026"
local ARCHON_LOADOUT_UNLOCK_AT = time({
    year = 2026,
    month = 3,
    day = 24,
    hour = 0,
    min = 0,
    sec = 0,
})

local function AreArchonLoadoutsAvailable()
    local now = (GetServerTime and GetServerTime()) or time()
    return now and now >= ARCHON_LOADOUT_UNLOCK_AT
end

local function CanCopyLoadoutCode(rec)
    if not rec or not rec.content or not rec.content.exportString then
        return false
    end

    if rec.source == "archon" and not AreArchonLoadoutsAvailable() then
        return false
    end

    return true
end

local function GetLoadoutAvailabilityNote(rec)
    if not rec or not rec.content or not rec.content.exportString then
        return nil
    end

    if rec.source == "archon" and not AreArchonLoadoutsAvailable() then
        return "Archon beta loadout. Invalid until Season 1 launch on " .. ARCHON_LOADOUT_UNLOCK_LABEL .. "."
    end

    return nil
end

ResolveRaidByName = function(name)
    if not name then return nil end
    local data = GetData()
    if not data or not data.contexts or not data.contexts.raids then return nil end
    for key, raid in pairs(data.contexts.raids) do
        if raid.name == name then return key end
    end
    return nil
end

-- ============================================================================
-- UI: Talents Tab
-- ============================================================================

local function ReleaseTalentRows()
    for _, row in ipairs(S.talentRows) do
        row:Hide()
        row:SetParent(nil)
    end
    wipe(S.talentRows)
end

local function ReleaseTalentHeaders()
    for _, hdr in ipairs(S.talentHeaders) do
        hdr:Hide()
    end
    wipe(S.talentHeaders)
end

local function GetDungeonTalentNotes(data, ctx)
    if ctx and ctx.instanceID and data.contexts and data.contexts.dungeons then
        local dungeon = data.contexts.dungeons[ctx.instanceID]
        if dungeon and dungeon.talentNotes then
            return dungeon.talentNotes
        end
    end
    if ctx and ctx.isDelve and ctx.instanceName and data.contexts and data.contexts.delves then
        for _, delve in ipairs(data.contexts.delves) do
            if delve.name == ctx.instanceName then
                return delve.notes
            end
        end
    end
    return nil
end

local function RenderTalentsTab(content)
    if not content then return end

    ReleaseTalentRows()
    ReleaseTalentHeaders()

    local kids = { content:GetChildren() }
    for _, child in ipairs(kids) do
        child:Hide()
        child:SetParent(nil)
    end
    for _, region in ipairs({ content:GetRegions() }) do
        region:Hide()
    end

    local data = GetData()
    if not data then return end

    local yOff = -4
    local ctx = S.lastContext or {}
    local Theme = MedaUI.Theme
    local MAX_VISIBLE_BUILDS = 2

    -- Reset expand state when context changes
    local ctxKey = tostring(ctx.instanceID or "") .. "_" .. tostring(ctx.instanceType or "")
    if ctxKey ~= S.talentSectionLastCtxKey then
        wipe(S.talentSectionExpanded)
        S.talentSectionLastCtxKey = ctxKey
    end

    -- Dungeon talent notes
    local talentNote = GetDungeonTalentNotes(data, ctx)
    if talentNote then
        local noteFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        noteFS:SetPoint("TOPLEFT", 8, yOff)
        noteFS:SetPoint("RIGHT", content, "RIGHT", -8, 0)
        noteFS:SetJustifyH("LEFT")
        noteFS:SetWordWrap(true)
        noteFS:SetTextColor(1.0, 0.82, 0.2)
        noteFS:SetText(talentNote)
        yOff = yOff - noteFS:GetStringHeight() - 12
    end

    -- Determine player spec
    local _, playerClass = UnitClass("player")
    local specIdx = GetSpecialization()
    local playerSpec = specIdx and GetSpecializationInfo(specIdx)

    if not playerClass or not playerSpec then
        local noSpec = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        noSpec:SetPoint("TOPLEFT", 8, yOff)
        noSpec:SetText("Select a specialization to see talent recommendations.")
        noSpec:SetTextColor(unpack(Theme.textDim or { 0.6, 0.6, 0.6 }))
        if S.coveragePanel then S.coveragePanel:SetContentHeight(CHROME_HEIGHT + math.abs(yOff) + 30) end
        return
    end

    local specKey = playerClass .. "_" .. playerSpec
    local recData = data.recommendations
    local specRecs = recData and recData[specKey]

    if not specRecs or #specRecs == 0 then
        local noRec = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        noRec:SetPoint("TOPLEFT", 8, yOff)
        noRec:SetText("No recommendations available for your spec.")
        noRec:SetTextColor(unpack(Theme.textDim or { 0.6, 0.6, 0.6 }))
        if S.coveragePanel then S.coveragePanel:SetContentHeight(CHROME_HEIGHT + math.abs(yOff) + 30) end
        return
    end

    -- Filter by dungeonID if we have a specific dungeon context
    local contextDungeonID = ctx.instanceID
    local dungeonRecs = {}
    local generalRecs = {}

    for _, rec in ipairs(specRecs) do
        if not rec.source or not IsSourceEnabled(rec.source) then
            -- skip disabled sources
        elseif rec.dungeonID and contextDungeonID and rec.dungeonID == contextDungeonID then
            dungeonRecs[#dungeonRecs + 1] = rec
        elseif not rec.dungeonID then
            generalRecs[#generalRecs + 1] = rec
        end
    end

    local displayRecs = #dungeonRecs > 0 and dungeonRecs or generalRecs

    -- Bucket recommendations by buildType
    local talentBuilds = {}
    local statRecs = {}
    local gearRecs = {}
    local enchantRecs = {}
    local consumableRecs = {}
    local trinketRecs = {}
    for _, rec in ipairs(displayRecs) do
        if rec.buildType == "talent" then
            talentBuilds[#talentBuilds + 1] = rec
        elseif rec.buildType == "stats" then
            statRecs[#statRecs + 1] = rec
        elseif rec.buildType == "gear" then
            gearRecs[#gearRecs + 1] = rec
        elseif rec.buildType == "enchants" then
            enchantRecs[#enchantRecs + 1] = rec
        elseif rec.buildType == "consumables" then
            consumableRecs[#consumableRecs + 1] = rec
        elseif rec.buildType == "trinkets" then
            trinketRecs[#trinketRecs + 1] = rec
        end
    end

    local contentW = content:GetWidth()
    local CARD_PAD = 6
    local CARD_INNER = 8

    -- Helper: render a single talent build row inside a card
    local function RenderBuildRow(parent, rec, innerYOff, rowWidth)
        local availabilityNote = GetLoadoutAvailabilityNote(rec)
        local ROW_HEIGHT = availabilityNote and 52 or 36
        local row = CreateFrame("Frame", nil, parent)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", CARD_INNER, innerYOff)
        row:SetPoint("RIGHT", parent, "RIGHT", -CARD_INNER, 0)
        S.talentRows[#S.talentRows + 1] = row

        -- Hero tree on top line (gold, larger font)
        local heroFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        heroFS:SetPoint("TOPLEFT", 0, -1)
        heroFS:SetJustifyH("LEFT")
        if rec.heroTree and rec.heroTree ~= "" then
            heroFS:SetTextColor(unpack(Theme.gold or { 1, 0.82, 0 }))
            heroFS:SetText(rec.heroTree)
        else
            heroFS:SetTextColor(unpack(Theme.textDim or { 0.6, 0.6, 0.6 }))
            heroFS:SetText("Talent Build")
        end

        -- Source badge + stats on second line
        local badge = FormatSourceBadge(rec.source)
        local detailLine = badge

        if rec.source == "archon" then
            if rec.popularity then
                detailLine = detailLine .. format("  |cffffffff%.0f%% pop|r", rec.popularity)
            end
            if rec.keyLevel then
                detailLine = detailLine .. format("  |cff88bbff+%d key|r", rec.keyLevel)
            end
            if rec.content and rec.content.dps then
                detailLine = detailLine .. format("  |cffaaddaa%s DPS|r", rec.content.dps)
            end
        else
            local label = rec.notes or ""
            local parts = { strsplit(",", label) }
            local cleanLabel = strtrim(parts[1] or "")
            if cleanLabel ~= "" then
                detailLine = detailLine .. "  |cffbbbbbb" .. cleanLabel .. "|r"
            end
        end

        local detailFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        detailFS:SetPoint("TOPLEFT", heroFS, "BOTTOMLEFT", 0, -2)
        detailFS:SetPoint("RIGHT", row, "RIGHT", CanCopyLoadoutCode(rec) and -62 or 0, 0)
        detailFS:SetJustifyH("LEFT")
        detailFS:SetWordWrap(false)
        detailFS:SetText(detailLine)

        if availabilityNote then
            local noteFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            noteFS:SetPoint("TOPLEFT", detailFS, "BOTTOMLEFT", 0, -2)
            noteFS:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            noteFS:SetJustifyH("LEFT")
            noteFS:SetWordWrap(true)
            noteFS:SetTextColor(unpack(Theme.warning or { 1, 0.7, 0.2 }))
            noteFS:SetText(availabilityNote)
        end

        -- Copy button (right-aligned, vertically centered)
        if CanCopyLoadoutCode(rec) then
            local copyBtn = MedaUI:CreateButton(row, "Copy", 56)
            copyBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            copyBtn:SetPoint("TOP", 0, -6)
            copyBtn:SetHeight(22)
            copyBtn.OnClick = function()
                ShowCopyPopup(rec.content.exportString)
            end
        end

        -- Separator line at the bottom
        local sep = row:CreateTexture(nil, "ARTWORK")
        sep:SetHeight(1)
        sep:SetPoint("BOTTOMLEFT", 0, 0)
        sep:SetPoint("BOTTOMRIGHT", 0, 0)
        sep:SetColorTexture(1, 1, 1, 0.04)

        row:Show()
        return ROW_HEIGHT
    end

    -- Group talent builds by content category
    if #talentBuilds > 0 then
        local catBuckets = { raid = {}, mplus = {}, delve = {} }
        for _, rec in ipairs(talentBuilds) do
            local ct = ClassifyBuildContentType(rec)
            if ct == "raid" then
                catBuckets.raid[#catBuckets.raid + 1] = rec
            elseif ct == "mplus" then
                catBuckets.mplus[#catBuckets.mplus + 1] = rec
            else
                catBuckets.delve[#catBuckets.delve + 1] = rec
            end
        end

        local anyRendered = false
        for _, cat in ipairs(CONTENT_CATEGORIES) do
            local builds = catBuckets[cat.key]
            if builds and #builds > 0 then
                anyRendered = true

                local sourceCount = {}
                local topBuilds = {}
                local overflowBuilds = {}
                for _, rec in ipairs(builds) do
                    local src = rec.source or "unknown"
                    sourceCount[src] = (sourceCount[src] or 0) + 1
                    if sourceCount[src] <= MAX_VISIBLE_BUILDS then
                        topBuilds[#topBuilds + 1] = rec
                    else
                        overflowBuilds[#overflowBuilds + 1] = rec
                    end
                end

                local sectionKey = "talent_" .. cat.key
                local sectionExpanded = S.talentSectionExpanded[sectionKey] or false

                -- Category card container with background
                local card = CreateFrame("Frame", nil, content, "BackdropTemplate")
                card:SetPoint("TOPLEFT", CARD_PAD, yOff)
                card:SetPoint("RIGHT", content, "RIGHT", -CARD_PAD, 0)
                card:SetBackdrop(MedaUI:CreateBackdrop(true))
                card:SetBackdropColor(
                    Theme.backgroundLight[1], Theme.backgroundLight[2], Theme.backgroundLight[3],
                    (Theme.backgroundLight[4] or 1) * 0.5
                )
                card:SetBackdropBorderColor(
                    Theme.border[1], Theme.border[2], Theme.border[3],
                    (Theme.border[4] or 0.06) * 2
                )
                S.talentRows[#S.talentRows + 1] = card

                -- Category label inside the card
                local catLabel = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                catLabel:SetPoint("TOPLEFT", CARD_INNER, -CARD_INNER)
                catLabel:SetTextColor(unpack(Theme.gold or { 1, 0.82, 0 }))
                catLabel:SetText(cat.label)

                -- Build count badge
                local countFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                countFS:SetPoint("LEFT", catLabel, "RIGHT", 6, 0)
                countFS:SetTextColor(unpack(Theme.textDim or { 0.6, 0.6, 0.6 }))
                countFS:SetText(format("(%d)", #builds))

                -- Accent line under category label
                local accentLine = card:CreateTexture(nil, "ARTWORK")
                accentLine:SetHeight(1)
                accentLine:SetPoint("TOPLEFT", CARD_INNER, -(CARD_INNER + 18))
                accentLine:SetPoint("RIGHT", card, "RIGHT", -CARD_INNER, 0)
                if Theme.sectionGradientStart and Theme.sectionGradientEnd and accentLine.SetGradient then
                    accentLine:SetColorTexture(1, 1, 1, 1)
                    pcall(function()
                        accentLine:SetGradient("HORIZONTAL", {
                            r = Theme.sectionGradientStart[1], g = Theme.sectionGradientStart[2],
                            b = Theme.sectionGradientStart[3], a = Theme.sectionGradientStart[4],
                        }, {
                            r = Theme.sectionGradientEnd[1], g = Theme.sectionGradientEnd[2],
                            b = Theme.sectionGradientEnd[3], a = Theme.sectionGradientEnd[4],
                        })
                    end)
                else
                    accentLine:SetColorTexture(unpack(Theme.goldDim or { 0.5, 0.4, 0.1, 0.5 }))
                end

                local innerY = -(CARD_INNER + 24)

                -- Render top build rows inside card
                for _, rec in ipairs(topBuilds) do
                    local h = RenderBuildRow(card, rec, innerY, contentW - CARD_PAD * 2)
                    innerY = innerY - h - 2
                end

                -- Overflow builds
                if #overflowBuilds > 0 then
                    if sectionExpanded then
                        for _, rec in ipairs(overflowBuilds) do
                            local h = RenderBuildRow(card, rec, innerY, contentW - CARD_PAD * 2)
                            innerY = innerY - h - 2
                        end
                    end

                    local toggle = MedaUI:CreateExpandToggle(card, {
                        hiddenCount = #overflowBuilds,
                        expanded = sectionExpanded,
                        onToggle = function(exp)
                            S.talentSectionExpanded[sectionKey] = exp
                            RenderTalentsTab(content)
                        end,
                    })
                    toggle:SetPoint("TOPLEFT", CARD_INNER, innerY)
                    toggle:SetPoint("RIGHT", card, "RIGHT", -CARD_INNER, 0)
                    innerY = innerY - toggle:GetHeight()
                end

                -- Finalize card height
                local cardHeight = math.abs(innerY) + CARD_INNER
                card:SetHeight(cardHeight)
                card:Show()

                yOff = yOff - cardHeight - 8
            end
        end

        if not anyRendered then
            local noMatch = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            noMatch:SetPoint("TOPLEFT", 8, yOff)
            noMatch:SetText("No talent builds match your current context.")
            noMatch:SetTextColor(unpack(Theme.textDim or { 0.6, 0.6, 0.6 }))
            yOff = yOff - 20
        end
    end

    -- Stat Priority section (compact, inside a card)
    if #statRecs > 0 then
        local rec = statRecs[1]
        if rec.content then
            local badge = FormatSourceBadge(rec.source)
            local statPairs = {}
            for statName, val in pairs(rec.content) do
                if val > 0 then
                    statPairs[#statPairs + 1] = { name = statName, value = val }
                end
            end
            table.sort(statPairs, function(a, b) return a.value > b.value end)

            local parts = {}
            for _, sp in ipairs(statPairs) do
                parts[#parts + 1] = format("%s (%d)", sp.name, sp.value)
            end

            local statCard = CreateFrame("Frame", nil, content, "BackdropTemplate")
            statCard:SetPoint("TOPLEFT", CARD_PAD, yOff)
            statCard:SetPoint("RIGHT", content, "RIGHT", -CARD_PAD, 0)
            statCard:SetBackdrop(MedaUI:CreateBackdrop(true))
            statCard:SetBackdropColor(
                Theme.backgroundLight[1], Theme.backgroundLight[2], Theme.backgroundLight[3],
                (Theme.backgroundLight[4] or 1) * 0.5
            )
            statCard:SetBackdropBorderColor(
                Theme.border[1], Theme.border[2], Theme.border[3],
                (Theme.border[4] or 0.06) * 2
            )
            S.talentRows[#S.talentRows + 1] = statCard

            local statTitle = statCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            statTitle:SetPoint("TOPLEFT", CARD_INNER, -CARD_INNER)
            statTitle:SetTextColor(unpack(Theme.gold or { 1, 0.82, 0 }))
            statTitle:SetText("Stat Priority")

            local statFS = statCard:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            statFS:SetPoint("TOPLEFT", statTitle, "BOTTOMLEFT", 0, -4)
            statFS:SetPoint("RIGHT", statCard, "RIGHT", -CARD_INNER, 0)
            statFS:SetJustifyH("LEFT")
            statFS:SetWordWrap(true)
            statFS:SetText(badge .. "  " .. table.concat(parts, "  >  "))

            local statCardH = CARD_INNER + 18 + 4 + statFS:GetStringHeight() + CARD_INNER
            statCard:SetHeight(statCardH)
            statCard:Show()

            yOff = yOff - statCardH - 8
        end
    end

    -- Helper to render an item-list section with collapsible overflow inside a card
    local function RenderItemSection(recs, title, sectionKey)
        if #recs == 0 then return end
        local rec = recs[1]
        if not rec.content or not rec.content.items or #rec.content.items == 0 then return end
        yOff = RenderRecommendationCardGrid(content, yOff, title, rec, nil, {
            sectionKey = sectionKey,
            maxVisible = 2,
            countLabel = "picks",
            expandState = S.talentSectionExpanded,
            onToggle = function()
                RenderTalentsTab(content)
            end,
            defaultLabel = (title == "Top Trinkets" and "Trinket")
                or (title == "Consumables" and "Consumable")
                or (title == "Enchants & Gems" and "Enhancement")
                or "Item",
        })
    end

    RenderItemSection(trinketRecs,    "Top Trinkets",   "items_trinkets")
    RenderItemSection(gearRecs,       "Popular Gear",   "items_gear")
    RenderItemSection(enchantRecs,    "Enchants & Gems", "items_enchants")
    RenderItemSection(consumableRecs, "Consumables",    "items_consumables")

    if #talentBuilds == 0 and #statRecs == 0
       and #gearRecs == 0 and #enchantRecs == 0 and #consumableRecs == 0 and #trinketRecs == 0 then
        local noRec = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        noRec:SetPoint("TOPLEFT", 8, yOff)
        noRec:SetText("No recommendations available for current context.")
        noRec:SetTextColor(unpack(Theme.textDim or { 0.6, 0.6, 0.6 }))
        yOff = yOff - 24
    end

    if S.coveragePanel then S.coveragePanel:SetContentHeight(CHROME_HEIGHT + math.abs(yOff) + 8) end
end

-- ============================================================================
-- UI: Prep Tab (consumable/enchant checklist)
-- ============================================================================

local function ReleasePrepRows()
    for _, row in ipairs(S.prepRows) do
        row:Hide()
        row:SetParent(nil)
    end
    wipe(S.prepRows)
end

local function ReleasePrepHeaders()
    for _, hdr in ipairs(S.prepHeaders) do
        hdr:Hide()
    end
    wipe(S.prepHeaders)
end

FindPlayerBuff = function(pattern)
    for i = 1, 40 do
        local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
        if not aura then break end
        if aura.name and aura.name:match(pattern) then return true, aura.name end
    end
    return false, nil
end

GetPreferredStats = function()
    local data = GetData()
    local profile = GetViewerProfile()
    if not data or not profile or not profile.specKey then return {} end

    EnsurePersonalSchema(data)
    local recs = data.personal and data.personal.bySpec and data.personal.bySpec[profile.specKey]
    if not recs then return {} end

    local PRIMARY = { Strength = true, Agility = true, Intellect = true }
    for _, rec in ipairs(recs) do
        if rec.buildType == "stats" and rec.stats then
            local sorted = {}
            for stat, weight in pairs(rec.stats) do
                if not PRIMARY[stat] then
                    sorted[#sorted + 1] = { stat = stat, weight = weight }
                end
            end
            table.sort(sorted, function(a, b) return a.weight > b.weight end)
            return sorted
        end
    end
    return {}
end

IsStatRecommended = function(statType, preferredStats, topN)
    if not statType or #preferredStats == 0 then return false end
    topN = topN or 2
    for i = 1, math.min(topN, #preferredStats) do
        if preferredStats[i].stat == statType then return true end
    end
    return false
end

local PREP_CHECKS = {
    {
        label    = "Flask Active",
        check    = function()
            local ok, name = FindPlayerBuff("[Ff]lask")
            if ok then return true, name end
            return FindPlayerBuff("[Pp]hial")
        end,
        tip      = "Use a flask or phial before the key starts.",
    },
    {
        label    = "Food Buff Active",
        check    = function()
            return FindPlayerBuff("[Ww]ell [Ff]ed")
        end,
        tip      = "Eat stat food for a Well Fed buff before starting.",
    },
    {
        label    = "Weapon Enhancement",
        check    = function()
            local hasMainHand = GetInventoryItemID("player", 16)
            if not hasMainHand then return true, "No weapon" end
            local enchant = select(2, GetWeaponEnchantInfo())
            if enchant then return true, "Active" end
            return false, nil
        end,
        tip      = "Apply a weapon enhancement (oil, stone, or rune) to your main-hand.",
    },
    {
        label    = "Augment Rune",
        check    = function()
            local ok, name = FindPlayerBuff("[Aa]ugment")
            if ok then return true, name end
            return FindPlayerBuff("[Dd]efinite")
        end,
        tip      = "Use an Augment Rune for a small primary stat boost.",
    },
}

local PREP_CHECK_ICONS = {
    ["Flask Active"]        = 136243,
    ["Food Buff Active"]    = 134062,
    ["Weapon Enhancement"]  = 135225,
    ["Augment Rune"]        = 237446,
}

local function RenderPrepTab(content)
    if not content then return end

    ReleasePrepRows()
    ReleasePrepHeaders()

    local kids = { content:GetChildren() }
    for _, child in ipairs(kids) do child:Hide(); child:SetParent(nil) end
    for _, region in ipairs({ content:GetRegions() }) do region:Hide() end

    local data = GetData()
    if not data then return end

    local Theme = MedaUI.Theme
    local yOff = -4
    local ctx = S.lastContext or {}

    -- Affix summary at top of prep tab
    if S.currentAffixes then
        local affixData = data.contexts and data.contexts.affixes
        if affixData then
            local affNames = {}
            for _, aID in ipairs(S.currentAffixes) do
                local a = affixData[aID]
                if a then affNames[#affNames + 1] = a.name end
            end
            if #affNames > 0 then
                local affFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                affFS:SetPoint("TOPLEFT", 8, yOff)
                affFS:SetPoint("RIGHT", content, "RIGHT", -8, 0)
                affFS:SetJustifyH("LEFT")
                affFS:SetWordWrap(true)
                affFS:SetText("|cffffcc00This Week:|r  " .. table.concat(affNames, ", "))
                yOff = yOff - affFS:GetStringHeight() - 8
            end
        end
    end

    -- Pre-Key Checklist (StatusRow widgets)
    local checkHdr = MedaUI:CreateSectionHeader(content, "Pre-Key Checklist", content:GetWidth() - 8)
    checkHdr:SetPoint("TOPLEFT", 4, yOff)
    S.prepHeaders[#S.prepHeaders + 1] = checkHdr
    yOff = yOff - 32

    for _, check in ipairs(PREP_CHECKS) do
        local ok, detail = check.check()
        local accentColor, statusText
        if ok then
            accentColor = COVERED_COLOR
            statusText = detail or "OK"
        else
            accentColor = SEVERITY_COLORS.warning
            statusText = "Missing"
        end

        local row = MedaUI:CreateStatusRow(content, {
            width = content:GetWidth() - 16,
            iconSize = 18,
            showNote = false,
            cardStyle = true,
        })
        row:SetPoint("TOPLEFT", 8, yOff)
        S.prepRows[#S.prepRows + 1] = row

        row:SetIcon(PREP_CHECK_ICONS[check.label])
        row:SetLabel(check.label)
        row:SetStatus(statusText, accentColor[1], accentColor[2], accentColor[3])
        row:SetAccentColor(accentColor[1], accentColor[2], accentColor[3])
        if not ok then row:SetHighlight(true) end

        if check.tip then
            row:SetTooltipFunc(function(_, tooltip)
                tooltip:AddLine(check.label, 1, 0.82, 0)
                tooltip:AddLine(check.tip, 1, 1, 1, true)
            end)
        end

        row:Show()
        yOff = yOff - 28
    end

    yOff = yOff - 8

    -- Dungeon Interactive Buffs (active/recommended shown, rest collapsed)
    local dungeonCtx = ResolveInstanceContext(data, ctx)
    local interactiveBuffs = dungeonCtx and dungeonCtx.interactiveBuffs
    if interactiveBuffs and #interactiveBuffs > 0 then
        local preferredStats = GetPreferredStats()

        -- Partition into prominent (active/recommended) and other
        local prominentBuffs = {}
        local otherBuffs = {}
        for _, ib in ipairs(interactiveBuffs) do
            local ok = FindPlayerBuff(ib.pattern)
            local recommended = IsStatRecommended(ib.statType, preferredStats)
            if ok or recommended then
                prominentBuffs[#prominentBuffs + 1] = ib
            else
                otherBuffs[#otherBuffs + 1] = ib
            end
        end

        local totalBuffs = #interactiveBuffs
        local buffsExpanded = S.prepSectionExpanded["buffs"] or false

        local buffHdr = MedaUI:CreateCollapsibleSectionHeader(content, {
            text = "Dungeon Buffs",
            width = content:GetWidth() - 8,
            count = totalBuffs,
            expanded = buffsExpanded,
            onToggle = function(exp)
                S.prepSectionExpanded["buffs"] = exp
                RenderPrepTab(content)
            end,
        })
        buffHdr:SetPoint("TOPLEFT", 4, yOff)
        S.prepHeaders[#S.prepHeaders + 1] = buffHdr
        yOff = yOff - 32

        local function RenderBuffRow(ib)
            local ok, detail = FindPlayerBuff(ib.pattern)
            local recommended = IsStatRecommended(ib.statType, preferredStats)
            local accentColor, statusText

            if ok then
                accentColor = COVERED_COLOR
                statusText = detail or "Active"
            elseif recommended then
                accentColor = RECOMMEND_COLOR
                statusText = ib.effect or ""
            else
                accentColor = SEVERITY_COLORS.info
                statusText = ib.effect or ""
            end

            local row = MedaUI:CreateStatusRow(content, {
                width = content:GetWidth() - 16,
                iconSize = 18,
                showNote = false,
                accentWidth = (recommended and not ok) and 4 or 3,
                cardStyle = true,
            })
            row:SetPoint("TOPLEFT", 8, yOff)
            S.prepRows[#S.prepRows + 1] = row

            local labelText = ib.buff
            if recommended and not ok then
                labelText = "|TInterface\\AddOns\\MedaUI\\Media\\Textures\\star-filled.tga:10:10|t " .. labelText
            end
            row:SetLabel(labelText)
            row:SetStatus(statusText, accentColor[1], accentColor[2], accentColor[3])
            row:SetAccentColor(accentColor[1], accentColor[2], accentColor[3])
            if recommended and not ok then
                row.highlight:SetColorTexture(
                    RECOMMEND_COLOR[1], RECOMMEND_COLOR[2], RECOMMEND_COLOR[3], 0.06
                )
                row:SetHighlight(true)
            end

            row:SetTooltipFunc(function(_, tooltip)
                local showedSpell = BeginSpellTooltip(tooltip, ib.spellID or ib.buff, ib.buff)
                if showedSpell then
                    AddTooltipSpacer(tooltip)
                end
                tooltip:AddLine(ib.effect, 1, 1, 1, true)
                if ib.location and ib.location ~= "" then
                    tooltip:AddLine("Location: " .. ib.location, 0.7, 0.7, 0.7, true)
                end
                if ib.requires then
                    tooltip:AddLine("Requires: " .. ib.requires, 0.9, 0.5, 0.5, true)
                end
                if recommended then
                    tooltip:AddLine(" ")
                    tooltip:AddLine("Matches your spec's preferred stats", RECOMMEND_COLOR[1], RECOMMEND_COLOR[2], RECOMMEND_COLOR[3])
                end
                if ib.tip and ib.tip ~= "" then
                    tooltip:AddLine(" ")
                    tooltip:AddLine(ib.tip, 1, 1, 1, true)
                end
            end)

            row:Show()
            yOff = yOff - 28
        end

        for _, ib in ipairs(prominentBuffs) do
            RenderBuffRow(ib)
        end

        if #otherBuffs > 0 then
            if buffsExpanded then
                for _, ib in ipairs(otherBuffs) do
                    RenderBuffRow(ib)
                end
            end

            local toggle = MedaUI:CreateExpandToggle(content, {
                hiddenCount = #otherBuffs,
                expanded = buffsExpanded,
                onToggle = function(exp)
                    S.prepSectionExpanded["buffs"] = exp
                    RenderPrepTab(content)
                end,
            })
            toggle:SetPoint("TOPLEFT", 8, yOff)
            toggle:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            yOff = yOff - toggle:GetHeight() - 2
        end

        yOff = yOff - 8
    end

    -- Recommended consumables & enchants from data
    local _, playerClass = UnitClass("player")
    local specIdx = GetSpecialization()
    local playerSpec = specIdx and GetSpecializationInfo(specIdx)

    if playerClass and playerSpec then
        local specKey = playerClass .. "_" .. playerSpec
        local recData = data.recommendations
        local specRecs = recData and recData[specKey]

        if specRecs then
            local contextDungeonID = ctx.instanceID

            local function FindBestRec(buildType)
                local dungeonRec, generalRec
                for _, rec in ipairs(specRecs) do
                    if rec.buildType == buildType and rec.content and rec.content.items
                       and #rec.content.items > 0 and (not rec.source or IsSourceEnabled(rec.source)) then
                        if rec.dungeonID and contextDungeonID and rec.dungeonID == contextDungeonID then
                            dungeonRec = rec
                            break
                        elseif not rec.dungeonID and not generalRec then
                            generalRec = rec
                        end
                    end
                end
                return dungeonRec or generalRec
            end

            local function RenderPrepItemSection(rec, title, sectionKey)
                if not rec then return end
                yOff = RenderRecommendationCardGrid(content, yOff, title, rec, nil, {
                    sectionKey = sectionKey,
                    maxVisible = 2,
                    countLabel = "picks",
                    expandState = S.prepSectionExpanded,
                    onToggle = function()
                        RenderPrepTab(content)
                    end,
                    defaultLabel = (title == "Recommended Consumables" and "Consumable")
                        or (title == "Recommended Enchants" and "Enhancement")
                        or "Item",
                })
            end

            RenderPrepItemSection(FindBestRec("consumables"), "Recommended Consumables", "prep_consumables")
            RenderPrepItemSection(FindBestRec("enchants"),    "Recommended Enchants",    "prep_enchants")
        end
    end

    if S.coveragePanel then S.coveragePanel:SetContentHeight(CHROME_HEIGHT + math.abs(yOff) + 8) end
end

-- ============================================================================
-- Reminders 2.0 workspace rendering
-- ============================================================================


R.MODULE_NAME = MODULE_NAME
R.MODULE_VERSION = MODULE_VERSION
R.MODULE_STABILITY = MODULE_STABILITY
R.MIN_DATA_VERSION = MIN_DATA_VERSION
R.MAX_DATA_VERSION = MAX_DATA_VERSION
R.SEVERITY_COLORS = SEVERITY_COLORS
R.COVERED_COLOR = COVERED_COLOR
R.RECOMMEND_COLOR = RECOMMEND_COLOR
R.CHROME_HEIGHT = CHROME_HEIGHT
R.CLASS_COLORS = CLASS_COLORS
R.Log = Log
R.LogDebug = LogDebug
R.LogWarn = LogWarn
R.GetData = GetData
R.IsDataCompatible = IsDataCompatible
R.ClassifyBuildContentType = ClassifyBuildContentType
R.GetContextKey = GetContextKey
R.ResolveDungeonByName = ResolveDungeonByName
R.GetCurrentContext = GetCurrentContext
R.RefreshAffixes = RefreshAffixes
R.ResolveConditionKey = ResolveConditionKey
R.MergeOutput = MergeOutput
R.CheckPersonalReminder = CheckPersonalReminder
R.IsCapabilityEnabled = IsCapabilityEnabled
R.Evaluate = Evaluate
R.ReleaseRows = ReleaseRows
R.ReleaseSectionHeaders = ReleaseSectionHeaders
R.GetDetectedLabel = GetDetectedLabel
R.FormatSourceBadge = FormatSourceBadge
R.IsSourceEnabled = IsSourceEnabled
R.FilterNoteBySource = FilterNoteBySource
R.GetEnabledSources = GetEnabledSources
R.FormatProviderText = FormatProviderText
R.UpdateDetectedLabel = UpdateDetectedLabel
R.ReleasePlayerRows = ReleasePlayerRows
R.ReleasePlayerHeaders = ReleasePlayerHeaders
R.ColorSpellNames = ColorSpellNames
R.BuildSpellMap = BuildSpellMap
R.ShowCopyPopup = ShowCopyPopup
R.CanCopyLoadoutCode = CanCopyLoadoutCode
R.GetLoadoutAvailabilityNote = GetLoadoutAvailabilityNote
R.ReleaseTalentRows = ReleaseTalentRows
R.ReleaseTalentHeaders = ReleaseTalentHeaders
R.ReleasePrepRows = ReleasePrepRows
R.ReleasePrepHeaders = ReleasePrepHeaders
R.ResolveRaidByName = ResolveRaidByName
R.ResolveInstanceContext = ResolveInstanceContext
R.IsCurrentPartyFull = IsCurrentPartyFull
R.GetFullGroupWorkaround = GetFullGroupWorkaround
R.EvaluatePlayerToolkit = EvaluatePlayerToolkit
R.RenderPlayerTab = RenderPlayerTab
R.RenderTalentsTab = RenderTalentsTab
R.RenderPrepTab = RenderPrepTab
R.GetPreferredStats = GetPreferredStats
R.FindPlayerBuff = FindPlayerBuff
R.IsStatRecommended = IsStatRecommended
