local _, ns = ...

local MedaUI = LibStub("MedaUI-1.0")

-- ============================================================================
-- Constants
-- ============================================================================

local MODULE_NAME      = "Reminders"
local MODULE_VERSION   = "1.1"
local MODULE_STABILITY = "beta"   -- "experimental" | "beta" | "stable"
local MIN_DATA_VERSION = 2
local MAX_DATA_VERSION = 10

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
-- State
-- ============================================================================

local db
local eventFrame
local coveragePanel
local minimapButton
local rowPool = {}
local activeRows = {}
local sectionHeaders = {}
local lastResults = {}
local lastContext = {}
local dismissed = false
local dismissedContextKey = nil
local debugMode = false
local isEnabled = false
local overrideContext = nil
local uiState = {
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
    navExpanded = {
        delves = true,
        dungeons = true,
        raids = true,
    },
}
local talentRows = {}
local talentHeaders = {}
local copyPopup = nil
local prepRows = {}
local prepHeaders = {}
local currentAffixes = nil
local playerRows = {}
local playerHeaders = {}
local playerToolkit = nil
local playerSectionExpanded = {}
local playerSectionLastCtxKey = nil
local talentSectionExpanded = {}
local talentSectionLastCtxKey = nil
local prepSectionExpanded = {}
local GetPreferredStats
local FindPlayerBuff
local IsStatRecommended
local ResolveRaidByName
local RunPipeline
local ResolveSpellID
local BeginSpellTooltip
local AddTooltipSpacer
local CreateTooltipTextLine
local CreateTooltipTextBlock
local AddRecommendationTooltip
local GetResultTooltipSpellID
local SPEC_META_BY_ID
local ALL_CLASS_SPECS
local TANK_SPECS
local HEALER_SPECS
local DPS_SPECS
local ALL_CLASSES
local ResolveInstanceContext
local GetActivityKey
local IsCurrentPartyFull
local GetFullGroupWorkaround

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

local function FormatRelativeTime(unixTimestamp)
    if not unixTimestamp or unixTimestamp == 0 then return nil end
    local now = time()
    local diff = now - unixTimestamp
    if diff < 0 then return "just now" end
    local days = math.floor(diff / 86400)
    local hours = math.floor((diff % 86400) / 3600)
    local mins = math.floor((diff % 3600) / 60)
    if days > 0 then
        if hours > 0 then
            return format("%dd %dh ago", days, hours)
        end
        return format("%dd ago", days)
    end
    if hours > 0 then
        if mins > 0 then
            return format("%dh %dm ago", hours, mins)
        end
        return format("%dh ago", hours)
    end
    if mins > 0 then return format("%dm ago", mins) end
    return "just now"
end

local function BuildSourceFreshnessLine()
    local data = GetData()
    if not data or not data.sources then return nil end
    local hasTimestamp = false
    local parts = {}
    for key, src in pairs(data.sources) do
        local c = src.color or { 0.7, 0.7, 0.7 }
        local hex = format("%02x%02x%02x",
            math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255))
        if src.lastFetched then
            local rel = FormatRelativeTime(src.lastFetched)
            if rel then
                hasTimestamp = true
                parts[#parts + 1] = format("|cff%s%s|r %s", hex, src.label, rel)
            else
                parts[#parts + 1] = format("|cff%s%s|r", hex, src.label)
            end
        else
            parts[#parts + 1] = format("|cff%s%s|r", hex, src.label)
        end
    end
    if #parts == 0 then return nil end
    local prefix = hasTimestamp and "Updated: " or "Sources: "
    return prefix .. table.concat(parts, "  |  ")
end

-- ============================================================================
-- Content-type filtering
-- ============================================================================

local CONTENT_TAG_MAP = {
    delve = { "delve" },
    party = { "mplus", "key" },
    raid  = { "raid" },
}

local function GetContentTags(ctx)
    if ctx.isDelve then return CONTENT_TAG_MAP.delve end
    if ctx.instanceType then return CONTENT_TAG_MAP[ctx.instanceType] end
    return nil
end

local function RecMatchesContentTags(rec, tags)
    if not tags then return true end
    if not rec.notes then return true end
    local lower = rec.notes:lower()
    if lower:find("general") then return true end
    for _, tag in ipairs(tags) do
        if lower:find(tag) then return true end
    end
    return false
end

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
            currentAffixes = {}
            for _, a in ipairs(affixes) do
                currentAffixes[#currentAffixes + 1] = a.id
            end
            LogDebug(format("Current affixes: %s", table.concat(currentAffixes, ", ")))
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
    if not capability.tags or not db then return true end
    for _, tag in ipairs(capability.tags) do
        local key = "tag_" .. tag
        if db[key] == false then return false end
    end
    return true
end

local function GetLiveRoster()
    local roster = {}
    local GroupInspector = ns.Services.GroupInspector
    if not GroupInspector then return roster end

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if UnitExists(unit) then
                local info = GroupInspector:GetUnitInfo(unit)
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
                local info = GroupInspector:GetUnitInfo(unit)
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

    local ctx = overrideContext or GetCurrentContext()
    lastContext = ctx

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

    if debugMode then
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
    local row = table.remove(rowPool)
    if not row then
        row = MedaUI:CreateStatusRow(parent, { width = width, showNote = true, iconSize = ICON_SIZE })
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
    for _, row in ipairs(activeRows) do
        row:Hide()
        row:SetParent(nil)
        rowPool[#rowPool + 1] = row
    end
    wipe(activeRows)
end

local function ReleaseSectionHeaders()
    for _, hdr in ipairs(sectionHeaders) do
        hdr:Hide()
    end
    wipe(sectionHeaders)
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

    if data.contexts.raids then
        local raids = {}
        for key, raid in pairs(data.contexts.raids) do
            raids[#raids + 1] = { key = key, name = raid.name }
        end
        table.sort(raids, function(a, b) return a.name < b.name end)
        if #raids > 0 then
            items[#items + 1] = { value = "_hdr_raids", label = "|cff888888--- Raids ---|r", disabled = true }
            for _, raid in ipairs(raids) do
                items[#items + 1] = { value = "raid:" .. raid.key, label = "    " .. raid.name }
            end
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

local function BuildStructuredCapabilityOutput(result, ctx)
    local output = result and result.output or {}
    local tone = output.severity or (result and result.matchCount > 0 and "info" or "warning")
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

local function GetContextHeader(data, ctx)
    if ctx.raidKey and data.contexts and data.contexts.raids then
        local raid = data.contexts.raids[ctx.raidKey]
        if raid then
            return raid.name, raid.header, raid.notes
        end
    end
    if ctx.instanceID and data.contexts and data.contexts.dungeons then
        local dungeon = data.contexts.dungeons[ctx.instanceID]
        if dungeon then
            return dungeon.name, dungeon.header, dungeon.notes
        end
    end
    if ctx.instanceName and data.contexts and data.contexts.delves then
        for _, delve in ipairs(data.contexts.delves) do
            if delve.name == ctx.instanceName then
                return delve.name, nil, delve.notes and { delve.notes } or nil
            end
        end
    end
    if ctx.instanceName then
        return ctx.instanceName, nil, nil
    end
    if ctx.instanceType and data.contexts and data.contexts.instanceTypes then
        local it = data.contexts.instanceTypes[ctx.instanceType]
        if it then return it.label, nil, nil end
    end
    return nil, nil, nil
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
    if not db or not db.sources then return true end
    return db.sources[source] ~= false
end

local function FilterNoteBySource(note)
    if not note or note == "" then return note end
    if not db or not db.sources then return note end

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

local function GetFreshnessTone(lastFetched)
    if not lastFetched or lastFetched == 0 then return "warning" end
    local age = time() - lastFetched
    if age >= (86400 * 3) then return "warning" end
    return nil
end

local function BuildFreshnessSummary(usedSet)
    local sources = GetEnabledSources(usedSet)
    if #sources == 0 then
        return "No active data sources enabled.", "warning"
    end

    local summarySources = {}
    for _, source in ipairs(sources) do
        if source.usedByCurrentView then
            summarySources[#summarySources + 1] = source
        end
    end
    if #summarySources == 0 then
        summarySources = sources
    end

    local usedNames = {}
    local oldestAgeText = nil
    local oldestTimestamp = nil
    local unknown = 0
    local tone = nil

    for _, source in ipairs(summarySources) do
        if source.usedByCurrentView then
            usedNames[#usedNames + 1] = source.label
        end
        if source.lastFetched and source.lastFetched > 0 then
            if not oldestTimestamp or source.lastFetched < oldestTimestamp then
                oldestTimestamp = source.lastFetched
            end
        else
            unknown = unknown + 1
            tone = tone or "warning"
        end
        tone = tone or GetFreshnessTone(source.lastFetched)
    end

    if oldestTimestamp then
        oldestAgeText = FormatRelativeTime(oldestTimestamp)
    end

    local prefix
    if #usedNames > 0 then
        prefix = "This page uses " .. table.concat(usedNames, ", ")
    else
        prefix = "This page can draw from " .. table.concat((function()
            local labels = {}
            for _, src in ipairs(sources) do labels[#labels + 1] = src.label end
            return labels
        end)(), ", ")
    end

    if oldestAgeText then
        return prefix .. "; oldest update " .. oldestAgeText .. ".", tone
    end
    if unknown > 0 then
        return prefix .. "; freshness is unknown for some sources.", "warning"
    end
    return prefix .. ".", tone
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

local function GetActionableSuggestion(result, ctx)
    local output = result and result.output or {}
    local suggestion = output.suggestion or output.detail or ""
    if result and result.matchCount == 0 and IsCurrentPartyFull(ctx) then
        local lowered = suggestion:lower()
        if lowered:find("invite ", 1, true) or lowered:find("bring ", 1, true) then
            return GetFullGroupWorkaround(result.capabilityID)
        end
    end
    return suggestion
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
    if currentAffixes and affixData then
        for _, affixID in ipairs(currentAffixes) do
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
    if currentAffixes and affixData then
        for _, affixID in ipairs(currentAffixes) do
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
                if currentAffixes and affixData then
                    for _, aID in ipairs(currentAffixes) do
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
    if not uiState.detectedLabel then return end
    local liveCtx = GetCurrentContext()
    uiState.detectedLabel:SetText("Detected: " .. GetDetectedLabel(liveCtx))
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
    for _, row in ipairs(playerRows) do
        row:Hide()
        row:SetParent(nil)
    end
    wipe(playerRows)
end

local function ReleasePlayerHeaders()
    for _, hdr in ipairs(playerHeaders) do
        hdr:Hide()
    end
    wipe(playerHeaders)
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

    if not playerToolkit then
        local emptyFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        emptyFS:SetPoint("TOPLEFT", 8, -8)
        emptyFS:SetPoint("RIGHT", content, "RIGHT", -8, 0)
        emptyFS:SetJustifyH("LEFT")
        emptyFS:SetWordWrap(true)
        emptyFS:SetTextColor(0.5, 0.5, 0.5)
        emptyFS:SetText("Enter an instance or select one from the dropdown above to see your personal coaching report.")
        if coveragePanel then coveragePanel:SetContentHeight(CHROME_HEIGHT + 60) end
        return
    end

    local tk = playerToolkit
    local Theme = MedaUI.Theme
    local yOff = -4

    local ctxKey = tk.instanceName or tk.header or ""
    if ctxKey ~= playerSectionLastCtxKey then
        wipe(playerSectionExpanded)
        playerSectionLastCtxKey = ctxKey
    end

    local MAX_VISIBLE = 4
    local mobSet = BuildMobSet(tk.dangers)
    local spellMap = BuildSpellMap(tk.dangers)

    -- Instance briefing
    do
        local noteCount = tk.notes and #tk.notes or 0
        local briefExpanded = playerSectionExpanded["briefing"] or false
        local briefHdr = MedaUI:CreateCollapsibleSectionHeader(content, {
            text = "Instance Briefing",
            width = content:GetWidth() - 8,
            count = noteCount,
            expanded = briefExpanded,
            onToggle = function(exp)
                playerSectionExpanded["briefing"] = exp
                RenderPlayerTab(content)
            end,
        })
        briefHdr:SetPoint("TOPLEFT", 4, yOff)
        playerHeaders[#playerHeaders + 1] = briefHdr
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
                        playerSectionExpanded["briefing"] = exp
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
        local dangersExpanded = playerSectionExpanded["dangers"] or false
        local showDangers = dangersExpanded and totalDangers or math.min(MAX_VISIBLE, totalDangers)

        local dangerHdr = MedaUI:CreateCollapsibleSectionHeader(content, {
            text = "Key Dangers",
            width = content:GetWidth() - 8,
            count = totalDangers,
            expanded = dangersExpanded,
            onToggle = function(exp)
                playerSectionExpanded["dangers"] = exp
                RenderPlayerTab(content)
            end,
        })
        dangerHdr:SetPoint("TOPLEFT", 4, yOff)
        playerHeaders[#playerHeaders + 1] = dangerHdr
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

            local row = MedaUI:CreateStatusRow(content, { iconSize = 32, showNote = true, width = content:GetWidth() })
            playerRows[#playerRows + 1] = row

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
                    playerSectionExpanded["dangers"] = exp
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
        local lustsExpanded = playerSectionExpanded["lusts"] or false
        local showLusts = lustsExpanded and totalLusts or math.min(MAX_VISIBLE, totalLusts)

        local lustHdr = MedaUI:CreateCollapsibleSectionHeader(content, {
            text = "Bloodlust Timings",
            width = content:GetWidth() - 8,
            count = totalLusts,
            expanded = lustsExpanded,
            onToggle = function(exp)
                playerSectionExpanded["lusts"] = exp
                RenderPlayerTab(content)
            end,
        })
        lustHdr:SetPoint("TOPLEFT", 4, yOff)
        playerHeaders[#playerHeaders + 1] = lustHdr
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
                    playerSectionExpanded["lusts"] = exp
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
        local tipsExpanded = playerSectionExpanded["tips"] or false
        local showTips = tipsExpanded and totalTips or math.min(MAX_VISIBLE, totalTips)

        local tipHdr = MedaUI:CreateCollapsibleSectionHeader(content, {
            text = "Talent Tips",
            width = content:GetWidth() - 8,
            count = totalTips,
            expanded = tipsExpanded,
            onToggle = function(exp)
                playerSectionExpanded["tips"] = exp
                RenderPlayerTab(content)
            end,
        })
        tipHdr:SetPoint("TOPLEFT", 4, yOff)
        playerHeaders[#playerHeaders + 1] = tipHdr
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
                    playerSectionExpanded["tips"] = exp
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
        playerHeaders[#playerHeaders + 1] = buffHdr
        yOff = yOff - 32

        for _, ib in ipairs(tk.interactiveBuffs) do
            local ok, detail = FindPlayerBuff(ib.pattern)
            local recommended = IsStatRecommended(ib.statType, preferredStats)

            local row = MedaUI:CreateStatusRow(content, { iconSize = 24, showNote = true, width = content:GetWidth() })
            playerRows[#playerRows + 1] = row
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

    if coveragePanel then coveragePanel:SetContentHeight(CHROME_HEIGHT + math.abs(yOff) + 8) end
end

-- ============================================================================
-- UI: Group Comp rendering
-- ============================================================================

local function RenderPanel(results)
    if not coveragePanel then return end

    local data = GetData()
    if not data then return end

    local gcFrame = nil
    if not gcFrame then return end

    ClearTabFrame(gcFrame)

    UpdateDetectedLabel()

    if #results == 0 then return end

    local content = gcFrame
    local yOff = -4

    -- Context header (title already set in RunPipeline)
    local _, ctxHeader, ctxNotes = GetContextHeader(data, lastContext)

    if ctxHeader then
        local headerFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        headerFS:SetPoint("TOPLEFT", 4, yOff)
        headerFS:SetPoint("RIGHT", content, "RIGHT", -4, 0)
        headerFS:SetJustifyH("LEFT")
        headerFS:SetWordWrap(true)
        headerFS:SetTextColor(1.0, 0.82, 0.2)
        headerFS:SetText(ctxHeader)
        yOff = yOff - headerFS:GetStringHeight() - 4
    end

    if ctxNotes and #ctxNotes > 0 then
        for _, note in ipairs(ctxNotes) do
            local noteText = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            noteText:SetPoint("TOPLEFT", 4, yOff)
            noteText:SetPoint("RIGHT", content, "RIGHT", -4, 0)
            noteText:SetJustifyH("LEFT")
            noteText:SetWordWrap(true)
            local Theme = MedaUI.Theme
            noteText:SetTextColor(unpack(Theme.textDim or {0.6, 0.6, 0.6}))
            noteText:SetText(note)
            yOff = yOff - noteText:GetStringHeight() - 4
        end
        yOff = yOff - 4
    end

    -- Collect personal reminders
    local personalReminders = {}
    for _, r in ipairs(results) do
        if r.personal then
            personalReminders[#personalReminders + 1] = r
        end
    end

    -- Build a lookup from capabilityID -> result
    local resultMap = {}
    for _, r in ipairs(results) do
        resultMap[r.capabilityID] = r
    end

    -- Render sections from groupCompDisplay
    local sections = data.groupCompDisplay or {}

    -- Build dungeon-specific dispel priority lookup for row ordering
    local priorityOrder = {}
    if lastContext.instanceID and data.contexts and data.contexts.dungeons then
        local dungeon = data.contexts.dungeons[lastContext.instanceID]
        if dungeon and dungeon.dispelPriority then
            for i, capID in ipairs(dungeon.dispelPriority) do
                priorityOrder[capID] = i
            end
        end
    end

    -- Coverage summary
    local totalChecks = 0
    local coveredChecks = 0
    for _, r in ipairs(results) do
        totalChecks = totalChecks + 1
        if r.matchCount > 0 then coveredChecks = coveredChecks + 1 end
    end
    if totalChecks > 0 then
        local summaryText = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        summaryText:SetPoint("TOPLEFT", 4, yOff)
        summaryText:SetPoint("RIGHT", content, "RIGHT", -4, 0)
        summaryText:SetJustifyH("LEFT")
        if coveredChecks == totalChecks then
            summaryText:SetText(format("|cff4ddb4d%d of %d checks covered|r", coveredChecks, totalChecks))
        elseif coveredChecks == 0 then
            summaryText:SetText(format("|cffe63333%d of %d checks covered|r", coveredChecks, totalChecks))
        else
            summaryText:SetText(format("|cffffb333%d of %d checks covered|r", coveredChecks, totalChecks))
        end
        yOff = yOff - 20
    end

    for _, section in ipairs(sections) do
        local hasContent = false
        for _, capID in ipairs(section.capabilities or {}) do
            if resultMap[capID] then
                hasContent = true
                break
            end
        end

        if hasContent then
            local hdrContainer = MedaUI:CreateSectionHeader(content, section.label, content:GetWidth() - 8)
            hdrContainer:SetPoint("TOPLEFT", 4, yOff)
            sectionHeaders[#sectionHeaders + 1] = hdrContainer

            if section.description then
                hdrContainer:EnableMouse(true)
                hdrContainer:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:AddLine(section.label, 1, 0.82, 0)
                    GameTooltip:AddLine(section.description, 1, 1, 1, true)
                    GameTooltip:Show()
                end)
                hdrContainer:SetScript("OnLeave", function() GameTooltip:Hide() end)
            end

            yOff = yOff - 32

            local orderedCaps = {}
            for _, capID in ipairs(section.capabilities or {}) do
                if resultMap[capID] then
                    orderedCaps[#orderedCaps + 1] = capID
                end
            end
            if next(priorityOrder) then
                table.sort(orderedCaps, function(a, b)
                    local pa = priorityOrder[a] or 999
                    local pb = priorityOrder[b] or 999
                    return pa < pb
                end)
            end

            for _, capID in ipairs(orderedCaps) do
                local r = resultMap[capID]
                if r then
                    local cap = r.capability
                    local row = AcquireRow(content, content:GetWidth())
                    activeRows[#activeRows + 1] = row

                    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOff)
                    row:SetPoint("RIGHT", content, "RIGHT", 0, 0)

                    row:SetIcon(cap.icon)
                    row:SetLabel(cap.label or capID)

                    local output = r.output or {}
                    local severity = output.severity

                    if severity and SEVERITY_COLORS[severity] then
                        local sc = SEVERITY_COLORS[severity]
                        row:SetAccentColor(sc[1], sc[2], sc[3])
                        row:SetHighlight(severity == "critical" or severity == "warning")
                    else
                        row:SetAccentColor(COVERED_COLOR[1], COVERED_COLOR[2], COVERED_COLOR[3])
                        row:SetHighlight(false)
                    end

                    if r.matchCount > 0 then
                        local provText = FormatProviderText(r.matches)
                        row:SetStatus(provText or "Covered")
                    elseif output.panelStatus then
                        local sc = severity and SEVERITY_COLORS[severity] or {1, 1, 1}
                        row:SetStatus(output.panelStatus, sc[1], sc[2], sc[3])
                    else
                        row:SetStatus("")
                    end

                    if r.matchCount > 0 and r.matches[1] and r.matches[1].note then
                        row:SetNote(FilterNoteBySource(r.matches[1].note))
                    elseif output.suggestion then
                        row:SetNote(FilterNoteBySource(output.suggestion))
                    elseif output.detail then
                        row:SetNote(FilterNoteBySource(output.detail))
                    else
                        row:SetNote("")
                    end

                    row:SetTooltipFunc(function(_, tip)
                        local tooltipSpellID = GetResultTooltipSpellID(r)
                        local showedSpell = BeginSpellTooltip(tip, tooltipSpellID, cap.label or capID)
                        if showedSpell then
                            AddTooltipSpacer(tip)
                            tip:AddLine(cap.label or capID, 1, 0.82, 0)
                        end
                        if cap.description then
                            tip:AddLine(cap.description, 1, 1, 1, true)
                        end
                        tip:AddLine(" ")
                        if output.detail then
                            tip:AddLine(output.detail, 1, 1, 1, true)
                        end
                        if r.matches and #r.matches > 0 then
                            tip:AddLine(" ")
                            tip:AddLine("Providers:", 0.6, 0.8, 1.0)
                            for _, m in ipairs(r.matches) do
                                local cc = CLASS_COLORS[m.class]
                                local cr, cg, cb = 1, 1, 1
                                if cc then cr, cg, cb = cc.r, cc.g, cc.b end
                                tip:AddDoubleLine(
                                    format("%s (%s)", m.name, m.spellName or "?"),
                                    "",
                                    cr, cg, cb, 1, 1, 1
                                )
                                if m.note and m.note ~= "" then
                                    tip:AddLine("  " .. m.note, 0.7, 0.7, 0.7, true)
                                end
                            end
                        end
                    end)

                    yOff = yOff - row:GetHeight() - 8
                end
            end

            yOff = yOff - 16
        end
    end

    -- Affix tips (only in M+ / dungeon context)
    if currentAffixes and lastContext.instanceType == "party" and db and db.showAffixTips ~= false then
        local affixData = data.contexts and data.contexts.affixes
        if affixData then
            local hasAffixTip = false
            for _, affixID in ipairs(currentAffixes) do
                local affix = affixData[affixID]
                if affix and affix.tip then
                    if not hasAffixTip then
                        local affHdr = MedaUI:CreateSectionHeader(content, "Active Affixes", content:GetWidth() - 8)
                        affHdr:SetPoint("TOPLEFT", 4, yOff)
                        sectionHeaders[#sectionHeaders + 1] = affHdr
                        yOff = yOff - 32
                        hasAffixTip = true
                    end
                    local affFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    affFS:SetPoint("TOPLEFT", 8, yOff)
                    affFS:SetPoint("RIGHT", content, "RIGHT", -8, 0)
                    affFS:SetJustifyH("LEFT")
                    affFS:SetWordWrap(true)
                    affFS:SetText(format("|cffffcc00%s:|r %s", affix.name, affix.tip))
                    yOff = yOff - affFS:GetStringHeight() - 4
                end
            end
            if hasAffixTip then yOff = yOff - 8 end
        end
    end

    -- Interactive Dungeon Buffs
    local dungeonCtx = lastContext.instanceID
        and data.contexts
        and data.contexts.dungeons
        and data.contexts.dungeons[lastContext.instanceID]
    local interactiveBuffs = dungeonCtx and dungeonCtx.interactiveBuffs
    if interactiveBuffs and #interactiveBuffs > 0 then
        local preferredStats = GetPreferredStats()
        local GI = ns.Services.GroupInspector
        local groupCache = GI and GI:GetAllCached() or {}

        local buffHdr = MedaUI:CreateSectionHeader(content, "Dungeon Buffs", content:GetWidth() - 8)
        buffHdr:SetPoint("TOPLEFT", 4, yOff)
        sectionHeaders[#sectionHeaders + 1] = buffHdr
        yOff = yOff - 32

        for _, ib in ipairs(interactiveBuffs) do
            local reqClasses = ib.requiredClasses
            local hasReq = reqClasses and #reqClasses > 0
            local coveredBy = nil

            if hasReq then
                local reqSet = {}
                for _, cls in ipairs(reqClasses) do reqSet[cls] = true end
                for _, member in pairs(groupCache) do
                    if member.class and reqSet[member.class] then
                        coveredBy = member
                        break
                    end
                end
            end

            local recommended = IsStatRecommended(ib.statType, preferredStats)
            local row = AcquireRow(content, content:GetWidth())
            activeRows[#activeRows + 1] = row
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOff)
            row:SetPoint("RIGHT", content, "RIGHT", 0, 0)

            local labelText = ib.buff
            if recommended then
                labelText = "|TInterface\\AddOns\\MedaUI\\Media\\Textures\\star-filled.tga:10:10|t " .. labelText
            end
            row:SetLabel(labelText)

            if not hasReq then
                row:SetAccentColor(COVERED_COLOR[1], COVERED_COLOR[2], COVERED_COLOR[3])
                row:SetStatus("Anyone")
                row:SetHighlight(false)
                row:SetNote(ib.effect or "")
            elseif coveredBy then
                local cc = CLASS_COLORS[coveredBy.class]
                local cr, cg, cb = 1, 1, 1
                if cc then cr, cg, cb = cc.r, cc.g, cc.b end
                row:SetAccentColor(COVERED_COLOR[1], COVERED_COLOR[2], COVERED_COLOR[3])
                row:SetStatus(format("|cff%02x%02x%02x%s|r", cr*255, cg*255, cb*255, coveredBy.name))
                row:SetHighlight(false)
                row:SetNote(ib.effect or "")
            else
                local warnColor = SEVERITY_COLORS.warning or { 1, 0.6, 0.2 }
                row:SetAccentColor(warnColor[1], warnColor[2], warnColor[3])
                row:SetStatus("Missing", warnColor[1], warnColor[2], warnColor[3])
                row:SetHighlight(true)
                row:SetNote(ib.requires or "Requires specific class")
            end

            row:SetTooltipFunc(function(_, tip)
                local showedSpell = BeginSpellTooltip(tip, ib.spellID or ib.buff, ib.buff)
                if showedSpell then
                    AddTooltipSpacer(tip)
                end
                tip:AddLine(ib.effect, 1, 1, 1, true)
                if ib.location and ib.location ~= "" then
                    tip:AddLine("Location: " .. ib.location, 0.7, 0.7, 0.7, true)
                end
                if hasReq then
                    if coveredBy then
                        local cc = CLASS_COLORS[coveredBy.class]
                        local cr, cg, cb = 1, 1, 1
                        if cc then cr, cg, cb = cc.r, cc.g, cc.b end
                        tip:AddLine(format("Can be activated by: %s", coveredBy.name), cr, cg, cb)
                    else
                        tip:AddLine("Requires: " .. (ib.requires or "specific class"), 0.9, 0.5, 0.5, true)
                    end
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

            yOff = yOff - row:GetHeight() - 8
        end
        yOff = yOff - 8
    end

    coveragePanel:SetContentHeight(CHROME_HEIGHT + math.abs(yOff) + 8)
end

-- ============================================================================
-- UI: Copy-to-clipboard popup
-- ============================================================================

local function ShowCopyPopup(text)
    if not copyPopup then
        copyPopup = MedaUI:CreateImportExportDialog({
            width = 420,
            height = 160,
            title = "Copy Reminder",
            mode = "export",
            hintText = "Press Ctrl+C to copy, then Esc to close.",
        })
    end

    copyPopup:ShowExport("Copy Reminder", text)
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
    for _, row in ipairs(talentRows) do
        row:Hide()
        row:SetParent(nil)
    end
    wipe(talentRows)
end

local function ReleaseTalentHeaders()
    for _, hdr in ipairs(talentHeaders) do
        hdr:Hide()
    end
    wipe(talentHeaders)
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
    local ctx = lastContext or {}
    local Theme = MedaUI.Theme
    local MAX_VISIBLE_BUILDS = 2

    -- Reset expand state when context changes
    local ctxKey = tostring(ctx.instanceID or "") .. "_" .. tostring(ctx.instanceType or "")
    if ctxKey ~= talentSectionLastCtxKey then
        wipe(talentSectionExpanded)
        talentSectionLastCtxKey = ctxKey
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
        if coveragePanel then coveragePanel:SetContentHeight(CHROME_HEIGHT + math.abs(yOff) + 30) end
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
        if coveragePanel then coveragePanel:SetContentHeight(CHROME_HEIGHT + math.abs(yOff) + 30) end
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
        local ROW_HEIGHT = 36
        local row = CreateFrame("Frame", nil, parent)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", CARD_INNER, innerYOff)
        row:SetPoint("RIGHT", parent, "RIGHT", -CARD_INNER, 0)
        talentRows[#talentRows + 1] = row

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
        detailFS:SetPoint("RIGHT", row, "RIGHT", -62, 0)
        detailFS:SetJustifyH("LEFT")
        detailFS:SetWordWrap(false)
        detailFS:SetText(detailLine)

        -- Copy button (right-aligned, vertically centered)
        if rec.content and rec.content.exportString then
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
                local sectionExpanded = talentSectionExpanded[sectionKey] or false

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
                talentRows[#talentRows + 1] = card

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
                            talentSectionExpanded[sectionKey] = exp
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
            talentRows[#talentRows + 1] = statCard

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

        local items = rec.content.items
        local totalItems = #items
        local sectionExpanded = talentSectionExpanded[sectionKey] or false
        local shown = sectionExpanded and totalItems or math.min(totalItems, 2)

        local itemCard = CreateFrame("Frame", nil, content, "BackdropTemplate")
        itemCard:SetPoint("TOPLEFT", CARD_PAD, yOff)
        itemCard:SetPoint("RIGHT", content, "RIGHT", -CARD_PAD, 0)
        itemCard:SetBackdrop(MedaUI:CreateBackdrop(true))
        itemCard:SetBackdropColor(
            Theme.backgroundLight[1], Theme.backgroundLight[2], Theme.backgroundLight[3],
            (Theme.backgroundLight[4] or 1) * 0.35
        )
        itemCard:SetBackdropBorderColor(
            Theme.border[1], Theme.border[2], Theme.border[3],
            (Theme.border[4] or 0.06) * 1.5
        )
        talentRows[#talentRows + 1] = itemCard

        local titleFS = itemCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        titleFS:SetPoint("TOPLEFT", CARD_INNER, -CARD_INNER)
        titleFS:SetTextColor(unpack(Theme.gold or { 1, 0.82, 0 }))
        titleFS:SetText(title)

        local countFS = itemCard:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        countFS:SetPoint("LEFT", titleFS, "RIGHT", 6, 0)
        countFS:SetTextColor(unpack(Theme.textDim or { 0.6, 0.6, 0.6 }))
        countFS:SetText(format("(%d)", totalItems))

        local innerY = -(CARD_INNER + 20)
        local badge = FormatSourceBadge(rec.source)

        for i = 1, shown do
            local item = items[i]
            local pop = item.popularity or 0
            local text = format("%s  |cffffffff%s|r  |cff888888%.0f%%|r", badge, item.name, pop)
            CreateTooltipTextLine(itemCard, innerY, text, function(_, tip)
                AddRecommendationTooltip(tip, item, rec)
            end, CARD_INNER, CARD_INNER)
            innerY = innerY - 16
        end

        if totalItems > 2 then
            local toggle = MedaUI:CreateExpandToggle(itemCard, {
                hiddenCount = totalItems - 2,
                expanded = sectionExpanded,
                onToggle = function(exp)
                    talentSectionExpanded[sectionKey] = exp
                    RenderTalentsTab(content)
                end,
            })
            toggle:SetPoint("TOPLEFT", CARD_INNER, innerY)
            toggle:SetPoint("RIGHT", itemCard, "RIGHT", -CARD_INNER, 0)
            innerY = innerY - toggle:GetHeight()
        end

        local cardH = math.abs(innerY) + CARD_INNER
        itemCard:SetHeight(cardH)
        itemCard:Show()

        yOff = yOff - cardH - 6
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

    if coveragePanel then coveragePanel:SetContentHeight(CHROME_HEIGHT + math.abs(yOff) + 8) end
end

-- ============================================================================
-- UI: Prep Tab (consumable/enchant checklist)
-- ============================================================================

local function ReleasePrepRows()
    for _, row in ipairs(prepRows) do
        row:Hide()
        row:SetParent(nil)
    end
    wipe(prepRows)
end

local function ReleasePrepHeaders()
    for _, hdr in ipairs(prepHeaders) do
        hdr:Hide()
    end
    wipe(prepHeaders)
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
    local ctx = lastContext or {}

    -- Affix summary at top of prep tab
    if currentAffixes then
        local affixData = data.contexts and data.contexts.affixes
        if affixData then
            local affNames = {}
            for _, aID in ipairs(currentAffixes) do
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
    prepHeaders[#prepHeaders + 1] = checkHdr
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
        })
        row:SetPoint("TOPLEFT", 8, yOff)
        prepRows[#prepRows + 1] = row

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
        local buffsExpanded = prepSectionExpanded["buffs"] or false

        local buffHdr = MedaUI:CreateCollapsibleSectionHeader(content, {
            text = "Dungeon Buffs",
            width = content:GetWidth() - 8,
            count = totalBuffs,
            expanded = buffsExpanded,
            onToggle = function(exp)
                prepSectionExpanded["buffs"] = exp
                RenderPrepTab(content)
            end,
        })
        buffHdr:SetPoint("TOPLEFT", 4, yOff)
        prepHeaders[#prepHeaders + 1] = buffHdr
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
            })
            row:SetPoint("TOPLEFT", 8, yOff)
            prepRows[#prepRows + 1] = row

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
                    prepSectionExpanded["buffs"] = exp
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
                local items = rec.content.items
                local totalItems = #items
                local sectionExpanded = prepSectionExpanded[sectionKey] or false
                local shown = sectionExpanded and totalItems or math.min(totalItems, 2)

                local hdr = MedaUI:CreateCollapsibleSectionHeader(content, {
                    text = title,
                    width = content:GetWidth() - 8,
                    count = totalItems,
                    expanded = sectionExpanded,
                    onToggle = function(exp)
                        prepSectionExpanded[sectionKey] = exp
                        RenderPrepTab(content)
                    end,
                })
                hdr:SetPoint("TOPLEFT", 4, yOff)
                prepHeaders[#prepHeaders + 1] = hdr
                yOff = yOff - 32

                local badge = FormatSourceBadge(rec.source)
                for i = 1, shown do
                    local item = items[i]
                    local text = format("%s  |cffffffff%s|r  |cff888888%.0f%%|r", badge, item.name, item.popularity or 0)
                    CreateTooltipTextLine(content, yOff, text, function(_, tip)
                        AddRecommendationTooltip(tip, item, rec)
                    end)
                    yOff = yOff - 16
                end

                if totalItems > 2 then
                    local toggle = MedaUI:CreateExpandToggle(content, {
                        hiddenCount = totalItems - 2,
                        expanded = sectionExpanded,
                        onToggle = function(exp)
                            prepSectionExpanded[sectionKey] = exp
                            RenderPrepTab(content)
                        end,
                    })
                    toggle:SetPoint("TOPLEFT", 8, yOff)
                    toggle:SetPoint("RIGHT", content, "RIGHT", 0, 0)
                    yOff = yOff - toggle:GetHeight() - 2
                end

                yOff = yOff - 8
            end

            RenderPrepItemSection(FindBestRec("consumables"), "Recommended Consumables", "prep_consumables")
            RenderPrepItemSection(FindBestRec("enchants"),    "Recommended Enchants",    "prep_enchants")
        end
    end

    if coveragePanel then coveragePanel:SetContentHeight(CHROME_HEIGHT + math.abs(yOff) + 8) end
end

-- ============================================================================
-- UI: Notification Banner
-- ============================================================================

local function ShowBannerIfNeeded(results)
    if not db or not db.alertEnabled then return end
    if coveragePanel and coveragePanel:IsShown() then return end

    local threshold = SEVERITY_PRIORITY[db.alertSeverityThreshold or "warning"] or 2

    for _, r in ipairs(results) do
        local output = r.output or {}
        if output.banner and output.severity then
            local pri = SEVERITY_PRIORITY[output.severity] or 0
            if pri >= threshold then
                if alertBanner then
                    alertBanner:Show(output.banner, db.alertDuration or 5)
                end
                Log(format("Banner shown: %s", output.banner))
                return
            end
        end
    end
end


local function RefreshFreshnessBar()
    if not coveragePanel then return end
    local text = BuildSourceFreshnessLine()
    coveragePanel:SetFooter(text)
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
    return overrideContext or lastContext or GetCurrentContext()
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

local ROLE_LABELS = {
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

local function GetClassLabel(classToken)
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

local function EnsurePersonalSchema(data)
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

local function EnsureSpecRegistry(data)
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
    if not db then return end
    local viewer = uiState.viewer or {}
    if viewer.mode == "browse" and viewer.classToken and viewer.specID then
        db.viewer = {
            mode = "browse",
            classToken = viewer.classToken,
            role = viewer.role,
            specID = viewer.specID,
        }
    else
        db.viewer = nil
    end
end

local function SetViewerState(classToken, role, specID, modeOverride)
    local live = GetLivePlayerProfile()
    local selectedClass = classToken or (live and live.classToken)
    local selectedSpec = specID or (live and live.specID)
    local selectedRole = role or (selectedSpec and GetRoleFromSpec(selectedSpec, selectedClass)) or (live and live.role) or "dps"

    uiState.viewer.classToken = selectedClass
    uiState.viewer.specID = selectedSpec
    uiState.viewer.role = selectedRole

    if modeOverride then
        uiState.viewer.mode = modeOverride
    elseif live and live.classToken == selectedClass and live.specID == selectedSpec then
        uiState.viewer.mode = "live"
    else
        uiState.viewer.mode = "browse"
    end

    PersistViewerState()
end

local function EnsureViewerState()
    local live = GetLivePlayerProfile()
    if not live then return end

    local saved = db and db.viewer
    if saved and saved.classToken and saved.specID then
        SetViewerState(saved.classToken, saved.role, saved.specID, saved.mode or "browse")
        return
    end

    if not uiState.viewer.classToken or not uiState.viewer.specID then
        SetViewerState(live.classToken, live.role, live.specID, "live")
    end
end

local function GetViewerProfile()
    EnsureViewerState()

    local live = GetLivePlayerProfile()
    local selectedClass = uiState.viewer.classToken or (live and live.classToken)
    local selectedSpec = uiState.viewer.specID or (live and live.specID)
    if not selectedClass or not selectedSpec then
        return live
    end

    local meta = GetSpecMeta(selectedSpec, selectedClass)
    return {
        mode = uiState.viewer.mode or "live",
        classToken = selectedClass,
        classLabel = GetClassLabel(selectedClass),
        specID = selectedSpec,
        specName = meta.specName,
        role = uiState.viewer.role or meta.role,
        specKey = selectedClass .. "_" .. selectedSpec,
        isLive = live and live.classToken == selectedClass and live.specID == selectedSpec and (uiState.viewer.mode or "live") == "live" or false,
    }
end

local function BuildPerspectiveSummary()
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
    if overrideContext then
        return format("Detected: %s  |  Viewing: %s", detected, selected)
    end
    return "Detected: " .. detected
end

local function EnsureSelectedPage(activityKey)
    if uiState.selectedPage == "personal" then return end

    if activityKey == "delve" and uiState.selectedPage:find("^delve_") then return end
    if activityKey == "dungeon" and uiState.selectedPage:find("^dungeon_") then return end
    if activityKey == "raid" and uiState.selectedPage:find("^raid_") then return end

    uiState.selectedPage = "personal"
end

local function BuildNavigationModel(activityKey)
    local delveEnabled = activityKey == "delve"
    local dungeonEnabled = activityKey == "dungeon"
    local raidEnabled = activityKey == "raid"

    return {
        { label = "Personal", pageId = "personal", enabled = true },
        {
            label = "Delves",
            pageId = "nav_delves",
            enabled = true,
            expanded = uiState.navExpanded.delves,
            children = {
                { label = "You", pageId = "delve_you", enabled = delveEnabled },
                { label = "Group", pageId = "delve_group", enabled = delveEnabled },
            },
        },
        {
            label = "Dungeons",
            pageId = "nav_dungeons",
            enabled = true,
            expanded = uiState.navExpanded.dungeons,
            children = {
                { label = "You", pageId = "dungeon_you", enabled = dungeonEnabled },
                { label = "Group", pageId = "dungeon_group", enabled = dungeonEnabled },
            },
        },
        {
            label = "Raids",
            pageId = "nav_raids",
            enabled = true,
            expanded = uiState.navExpanded.raids,
            children = {
                { label = "You", pageId = "raid_you", enabled = raidEnabled },
                { label = "Group", pageId = "raid_group", enabled = raidEnabled },
                { label = "Raid", pageId = "raid_raid", enabled = raidEnabled },
            },
        },
    }
end

local function GetContentWidth()
    if uiState.workspaceShell and uiState.workspaceShell.contentHost and uiState.workspaceShell.contentHost:GetWidth() > 0 then
        return uiState.workspaceShell.contentHost:GetWidth() - 24
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

local function RenderGearRecommendationGrid(parent, yOff, title, rec, usedSet, maxVisible)
    if not rec or not rec.content or not rec.content.items or #rec.content.items == 0 then
        return yOff
    end

    MarkSource(usedSet, rec.source)

    local items = {}
    for i = 1, #rec.content.items do
        items[#items + 1] = rec.content.items[i]
    end
    SortGearRecommendationItems(items)

    local totalItems = #items
    local sectionKey = "personal_gear_visual"
    local sectionExpanded = talentSectionExpanded[sectionKey] or false
    local shown = sectionExpanded and totalItems or math.min(totalItems, maxVisible or totalItems)

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
    sourceFS:SetText(FormatSourceBadge(rec.source) .. format("  %d slots", totalItems))

    local hintFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hintFS:SetPoint("TOPLEFT", titleFS, "BOTTOMLEFT", 0, -4)
    hintFS:SetPoint("RIGHT", card, "RIGHT", -10, 0)
    hintFS:SetJustifyH("LEFT")
    hintFS:SetWordWrap(true)
    hintFS:SetTextColor(unpack(theme.textDim or { 0.6, 0.6, 0.6, 1 }))
    hintFS:SetText("Character-sheet view with each recommendation pinned to its slot.")

    local cardWidth = math.max(320, GetContentWidth() - 8)
    local cols = cardWidth >= 720 and 2 or 1
    local gap = 10
    local innerPad = 10
    local slotHeight = 78
    local slotWidth = math.floor((cardWidth - (innerPad * 2) - (gap * (cols - 1))) / cols)
    local topInset = 56

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
        slotCard:SetSlotLabel(GetRecommendationSlotLabel(item))
        slotCard:SetValueText(format("%.0f%%", item.popularity or 0))
        slotCard:SetTitle(item.name or "Unknown item")
        slotCard:SetDetail(BuildGearDetailText(item))
        slotCard:SetIcon(GetRecommendationIcon(item))
        slotCard:SetProgress(math.min(math.max((item.popularity or 0) / 100, 0), 1))
        slotCard:SetTooltipFunc(function(_, tip)
            AddRecommendationTooltip(tip, item, rec)
        end)
    end

    local rows = math.ceil(shown / cols)
    local gridHeight = rows > 0 and (rows * slotHeight) + ((rows - 1) * gap) or 0
    local innerY = -(topInset + gridHeight) - 10

    if totalItems > shown then
        local toggle = MedaUI:CreateExpandToggle(card, {
            hiddenCount = totalItems - shown,
            expanded = sectionExpanded,
            onToggle = function(exp)
                talentSectionExpanded[sectionKey] = exp
                RunPipeline(false)
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

local function RenderRecommendationList(parent, yOff, title, rec, usedSet, maxVisible)
    if not rec or not rec.content or not rec.content.items or #rec.content.items == 0 then
        return yOff
    end

    MarkSource(usedSet, rec.source)

    local theme = MedaUI.Theme
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetBackdrop(MedaUI:CreateBackdrop(true))
    card:SetPoint("TOPLEFT", 4, yOff)
    card:SetPoint("RIGHT", parent, "RIGHT", -4, 0)
    card:SetBackdropColor(theme.backgroundLight[1], theme.backgroundLight[2], theme.backgroundLight[3], 0.35)
    card:SetBackdropBorderColor(theme.border[1], theme.border[2], theme.border[3], theme.border[4] or 0.6)

    local titleFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFS:SetPoint("TOPLEFT", 10, -8)
    titleFS:SetTextColor(unpack(theme.gold or { 0.9, 0.7, 0.15, 1 }))
    titleFS:SetText(title)

    local badge = FormatSourceBadge(rec.source)
    local shown = math.min(#rec.content.items, maxVisible or #rec.content.items)
    local innerY = -30

    for i = 1, shown do
        local item = rec.content.items[i]
        CreateTooltipTextLine(card, innerY, format("%s  |cffffffff%s|r  |cff888888%.0f%%|r", badge, item.name, item.popularity or 0), function(_, tip)
            AddRecommendationTooltip(tip, item, rec)
        end, 10, 10)
        innerY = innerY - 16
    end

    local cardHeight = math.abs(innerY) + 8
    card:SetHeight(cardHeight)
    return yOff - cardHeight - 8
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
        detailFS:SetPoint("RIGHT", card, "RIGHT", -72, 0)
        detailFS:SetJustifyH("LEFT")
        detailFS:SetWordWrap(false)
        detailFS:SetText(detail)

        if rec.content and rec.content.exportString then
            local copyBtn = MedaUI:CreateButton(card, "Copy", 52)
            copyBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, innerY + 4)
            copyBtn:SetHeight(20)
            copyBtn.OnClick = function()
                ShowCopyPopup(rec.content.exportString)
            end
        end

        innerY = innerY - 40
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

    if playerToolkit and playerToolkit.dangers and #playerToolkit.dangers > 0 then
        local shown = 0
        for _, danger in ipairs(playerToolkit.dangers) do
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
    if not uiState.workspaceShell then return end
    local content = uiState.workspaceShell:GetContent()
    ResetContent(content)

    local usedSet = {}
    local viewer = GetViewerProfile()
    local _, _, buckets = GetSpecRecommendations(ctx)

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
    personalTabBar:SetActiveTab(uiState.selectedPersonalTab or "overview")
    personalTabBar.OnTabChanged = function(_, tabId)
        uiState.selectedPersonalTab = tabId
        RunPipeline(false)
    end

    local yOff = -40
    if viewer and viewer.mode == "browse" then
        yOff = AddCard(content, yOff, "Theorycraft View",
            format("Showing recommendations for %s %s. Personal pages ignore your live inventory and show this spec's data directly.",
                viewer.specName or "Spec", viewer.classLabel or "Unknown"),
            SEVERITY_COLORS.info)
    end

    if uiState.selectedPersonalTab == "overview" then
        yOff = RenderPersonalOverview(content, yOff, ctx, buckets, usedSet)
    elseif uiState.selectedPersonalTab == "gear" then
        yOff = RenderGearRecommendationGrid(content, yOff, "Popular Gear", buckets.gear[1], usedSet, 8)
    elseif uiState.selectedPersonalTab == "trinkets" then
        yOff = RenderRecommendationList(content, yOff, "Top Trinkets", buckets.trinkets[1], usedSet, 6)
    elseif uiState.selectedPersonalTab == "consumes" then
        yOff = RenderRecommendationList(content, yOff, "Recommended Consumables", buckets.consumables[1], usedSet, 6)
    elseif uiState.selectedPersonalTab == "enchants" then
        yOff = RenderRecommendationList(content, yOff, "Enchants & Gems", buckets.enchants[1], usedSet, 6)
    elseif uiState.selectedPersonalTab == "talents" then
        yOff = RenderTalentBuilds(content, yOff, buckets.talent, usedSet)
        yOff = RenderStatsCard(content, yOff, buckets.stats, usedSet)
    end

    if yOff == -40 then
        yOff = AddCard(content, yOff, "No Data Yet", "No recommendations are available for this specialization and activity.", SEVERITY_COLORS.info)
    end

    uiState.workspaceShell:SetContentHeight(math.abs(yOff) + 32)
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
                    local row = MedaUI:CreateStatusRow(content, { width = GetContentWidth(), iconSize = 24, showNote = true })
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
    if not uiState.workspaceShell then return {} end
    local content = uiState.workspaceShell:GetContent()
    ResetContent(content)

    local usedSet = {}
    local yOff = -4
    local tk = playerToolkit
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
        uiState.workspaceShell:SetContentHeight(math.abs(yOff) + 32)
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
            local row = MedaUI:CreateStatusRow(content, { width = GetContentWidth(), iconSize = 28, showNote = true })
            row:SetPoint("TOPLEFT", 4, yOff)
            row:SetPoint("RIGHT", content, "RIGHT", -4, 0)
            row:SetIcon(136116)
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

    uiState.workspaceShell:SetContentHeight(math.abs(yOff) + 32)
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
        local color = coveredChecks == totalChecks and COVERED_COLOR
            or (coveredChecks == 0 and SEVERITY_COLORS.critical or SEVERITY_COLORS.warning)
        yOff = AddCard(content, yOff, "Coverage Summary",
            format("%d of %d tracked checks are covered by the current roster.", coveredChecks, totalChecks),
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
                    local row = MedaUI:CreateStatusRow(content, { width = GetContentWidth(), iconSize = 24, showNote = true })
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

    if currentAffixes and ctx.instanceType == "party" and db and db.showAffixTips ~= false then
        local affixLines = {}
        local affixData = data and data.contexts and data.contexts.affixes
        if affixData then
            for _, affixID in ipairs(currentAffixes) do
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

    uiState.workspaceShell:SetContentHeight(math.abs(yOff) + 32)
    return usedSet
end

local function RenderGroupPage(ctx, scope)
    if not uiState.workspaceShell then return {} end
    local content = uiState.workspaceShell:GetContent()
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
    local yOff = RenderGroupCoverageSection(content, -4, ctx, lastResults, notes, usedSet)
    yOff = RenderStructuredPageSections(content, yOff, page, usedSet)
    uiState.workspaceShell:SetContentHeight(math.abs(yOff) + 32)
    return usedSet
end

local function RenderCurrentPage()
    if not uiState.workspaceShell then return end

    local ctx = GetEffectiveContext()
    local activityKey = GetActivityKey(ctx)
    EnsureSelectedPage(activityKey)

    uiState.workspaceShell:SetNavigation(BuildNavigationModel(activityKey))
    uiState.workspaceShell:SetActivePage(uiState.selectedPage)
    uiState.workspaceShell:SetPageTitle(GetPageTitle(uiState.selectedPage), GetSubtitleText(ctx))

    local usedSet
    if uiState.selectedPage == "personal" then
        usedSet = RenderPersonalPage(ctx)
    elseif uiState.selectedPage:find("_you$") then
        usedSet = RenderYouPage(ctx)
    elseif uiState.selectedPage == "raid_raid" then
        usedSet = RenderGroupPage(ctx, "raid")
    else
        usedSet = RenderGroupPage(ctx, "group")
    end

    uiState.workspaceShell:SetPageSummary(nil)
    uiState.workspaceShell:SetFreshnessSources(GetEnabledSources(usedSet))
end

-- ============================================================================
-- Evaluation + render pipeline
-- ============================================================================

RunPipeline = function(clearDismiss)
    if not isEnabled then return end

    local ok, reason = IsDataCompatible()
    if not ok then return end

    if clearDismiss then
        local currentKey = GetContextKey(overrideContext or GetCurrentContext())
        if not dismissed or currentKey ~= dismissedContextKey then
            dismissed = false
            dismissedContextKey = nil
            if coveragePanel then
                coveragePanel:ClearDismissed()
            end
        end
    end

    RefreshAffixes()

    local results = Evaluate()
    lastResults = results

    -- Evaluate player toolkit for the "You" tab
    local data = GetData()
    local ctx = overrideContext or lastContext
    playerToolkit = EvaluatePlayerToolkit(data, ctx)

    if coveragePanel then
        coveragePanel:SetTitle("Reminders")
    end

    if uiState.workspaceShell then
        RenderCurrentPage()
    end

    -- Auto-show panel only when inside an instance (not in cities/open world)
    if db.autoShowInInstance ~= false and coveragePanel and not dismissed and lastContext and lastContext.inInstance then
        coveragePanel:Show()
        coveragePanel:Raise()
    end
end

-- ============================================================================
-- Event handling
-- ============================================================================

local function OnEvent(_, event, arg1)
    if event == "PLAYER_ENTERING_WORLD" then
        UpdateDetectedLabel()
        RunPipeline(true)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        Log(format("Zone changed -- re-evaluating"))
        UpdateDetectedLabel()
        RunPipeline(true)
    elseif event == "GROUP_ROSTER_UPDATE" then
        RunPipeline(false)
    elseif event == "ACTIVE_DELVE_DATA_UPDATE" then
        Log("Delve data updated -- re-evaluating")
        UpdateDetectedLabel()
        RunPipeline(false)
    elseif event == "CHALLENGE_MODE_START" then
        Log("M+ key started -- re-evaluating")
        RefreshAffixes()
        UpdateDetectedLabel()
        RunPipeline(true)
    end
end

local function OnInspectorUpdate()
    RunPipeline(false)
end

-- ============================================================================
-- UI creation
-- ============================================================================

local function CreateUI()
    if coveragePanel then return end

    if MedaUI and MedaUI.SetTheme and MedaAurasDB and MedaAurasDB.options and MedaAurasDB.options.theme then
        local desiredTheme = MedaAurasDB.options.theme
        if MedaUI.GetActiveThemeName and MedaUI:GetActiveThemeName() ~= desiredTheme then
            MedaUI:SetTheme(desiredTheme)
        end
    end

    -- Coverage panel
    coveragePanel = MedaUI:CreateInfoPanel("MedaAurasRemindersPanel", {
        width       = db.panelWidth or 1120,
        height      = db.panelHeight or 720,
        title       = "Reminders",
        icon        = 134063,
        strata      = "DIALOG",
        dismissable = true,
        locked      = db.locked or false,
    })
    coveragePanel:SetToplevel(true)
    coveragePanel:Raise()
    if coveragePanel.EnableKeyboard then
        coveragePanel:EnableKeyboard(true)
    end
    if coveragePanel.SetPropagateKeyboardInput then
        coveragePanel:SetPropagateKeyboardInput(true)
    end
    local function HandleCoveragePanelKeyDown(self, key)
        if self.SetPropagateKeyboardInput then
            self:SetPropagateKeyboardInput(key ~= "ESCAPE")
        end
        if key == "ESCAPE" and self.IsShown and self:IsShown() and self.Dismiss then
            self:Dismiss()
        end
    end
    if coveragePanel.HookScript then
        coveragePanel:HookScript("OnKeyDown", HandleCoveragePanelKeyDown)
    elseif coveragePanel.SetScript then
        coveragePanel:SetScript("OnKeyDown", HandleCoveragePanelKeyDown)
    end

    coveragePanel.OnDismiss = function()
        dismissed = true
        dismissedContextKey = GetContextKey(lastContext)
        Log("Panel dismissed by user")
    end

    coveragePanel.OnMove = function(self)
        db.panelPoint = self:SavePosition()
    end

    if db.panelPoint then
        coveragePanel:RestorePosition(db.panelPoint)
    else
        coveragePanel:SetPoint("RIGHT", UIParent, "RIGHT", -50, 0)
    end

    coveragePanel:SetBackgroundOpacity(db.backgroundOpacity or 0.85)

    coveragePanel:SetResizable(true, {
        minWidth  = 920,
        minHeight = 500,
    })
    coveragePanel.OnResize = function(self, w, h)
        db.panelWidth = math.floor(w)
        db.panelHeight = math.floor(h)
        if uiState.workspaceShell and uiState.workspaceShell.RefreshNavigation then
            uiState.workspaceShell:RefreshNavigation()
        end
        RunPipeline(false)
    end

    if coveragePanel.scrollParent then coveragePanel.scrollParent:Hide() end
    if coveragePanel.footer then coveragePanel.footer:Hide() end
    if coveragePanel.statusBar then coveragePanel.statusBar:Hide() end

    uiState.workspaceShell = MedaUI:CreateWorkspaceShell(coveragePanel)
    uiState.workspaceShell:SetPoint("TOPLEFT", coveragePanel, "TOPLEFT", 8, -38)
    uiState.workspaceShell:SetPoint("BOTTOMRIGHT", coveragePanel, "BOTTOMRIGHT", -8, 8)
    uiState.workspaceShell.OnNavigate = function(_, pageId)
        uiState.selectedPage = pageId
        RenderCurrentPage()
    end
    uiState.workspaceShell.OnGroupToggle = function(_, groupId, expanded)
        if groupId == "nav_delves" then
            uiState.navExpanded.delves = expanded
        elseif groupId == "nav_dungeons" then
            uiState.navExpanded.dungeons = expanded
        elseif groupId == "nav_raids" then
            uiState.navExpanded.raids = expanded
        end
    end

    local toolbar = uiState.workspaceShell:GetToolbar()
    local ddItems = BuildContextDropdownItems()
    local contextDropdown = MedaUI:CreateDropdown(toolbar, 250, ddItems)
    contextDropdown:SetSelected("auto")
    contextDropdown:SetPoint("TOPRIGHT", toolbar, "TOPRIGHT", 0, 0)
    contextDropdown.OnValueChanged = function(_, val)
        if val and val:match("^_hdr_") then return end
        overrideContext = ParseContextSelection(val)
        uiState.selectedPage = "personal"
        RunPipeline(false)
    end

    -- Minimap button
    minimapButton = MedaUI:CreateMinimapButton(
        "MedaAurasReminders",
        134063,
        function()
            if coveragePanel then
                if coveragePanel:IsShown() then
                    coveragePanel:Dismiss()
                else
                    dismissed = false
                    coveragePanel:ClearDismissed()
                    RunPipeline(false)
                    coveragePanel:Show()
                    coveragePanel:Raise()
                    Log("Panel toggled via minimap button")
                end
            end
        end,
        function()
            if MedaAuras.ToggleSettings then
                MedaAuras:ToggleSettings()
            end
        end
    )

    if minimapButton and db.showMinimapButton == false then
        minimapButton.HideButton()
    end
end

-- ============================================================================
-- Module lifecycle
-- ============================================================================

local function StartModule()
    local ok, reason = IsDataCompatible()
    if not ok then
        if reason == "too_old" then
            local data = GetData()
            LogWarn(format("Data version %s is too old (need >= %d). Re-run the scraper.",
                tostring(data and data.dataVersion), MIN_DATA_VERSION))
        elseif reason == "too_new" then
            local data = GetData()
            LogWarn(format("Data version %s is newer than supported (max %d). Update MedaAuras.",
                tostring(data and data.dataVersion), MAX_DATA_VERSION))
        end
        return
    end

    isEnabled = true
    CreateUI()

    if not eventFrame then
        eventFrame = CreateFrame("Frame")
    end
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("ACTIVE_DELVE_DATA_UPDATE")
    eventFrame:RegisterEvent("CHALLENGE_MODE_START")
    eventFrame:SetScript("OnEvent", OnEvent)

    local GroupInspector = ns.Services.GroupInspector
    if GroupInspector then
        GroupInspector:RegisterCallback("Reminders", OnInspectorUpdate)
    end

    Log("Module enabled")
    RunPipeline(true)
end

local function StopModule()
    isEnabled = false

    if eventFrame then
        eventFrame:UnregisterAllEvents()
        eventFrame:SetScript("OnEvent", nil)
    end

    local GroupInspector = ns.Services.GroupInspector
    if GroupInspector then
        GroupInspector:UnregisterCallback("Reminders")
    end

    if coveragePanel then coveragePanel:Hide() end
    if copyPopup then copyPopup:Hide() end

    ReleaseRows()
    ReleaseSectionHeaders()
    ReleaseTalentRows()
    ReleaseTalentHeaders()
    ReleasePrepRows()
    ReleasePrepHeaders()
    ReleasePlayerRows()
    ReleasePlayerHeaders()
    wipe(playerSectionExpanded)
    playerSectionLastCtxKey = nil
    currentAffixes = nil
    playerToolkit = nil

    Log("Module disabled")
end

local function OnInitialize(moduleDB)
    db = moduleDB

    if not db._sizeMigrated then
        if (db.panelWidth or 0) <= 440 then db.panelWidth = 920 end
        if (db.panelHeight or 0) <= 520 then db.panelHeight = 720 end
        db._sizeMigrated = true
    end

    if not db._sizeMigrated2 then
        if (db.panelWidth or 0) <= 520 then db.panelWidth = 920 end
        if (db.panelHeight or 0) <= 620 then db.panelHeight = 720 end
        db._sizeMigrated2 = true
    end

    if not db._sizeMigrated3 then
        if (db.panelWidth or 0) <= 920 then db.panelWidth = 1120 end
        if (db.panelHeight or 0) <= 620 then db.panelHeight = 720 end
        db._sizeMigrated3 = true
    end

    StartModule()
end

local function OnEnable(moduleDB)
    db = moduleDB
    StartModule()
end

local function OnDisable(moduleDB)
    db = moduleDB
    StopModule()
end

-- ============================================================================
-- Preview / test mode
-- ============================================================================

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

local PREVIEW_NAMES = {
    "Tankyboi", "Healmaster", "Pewpew", "Stabsworth", "Dotlord",
    "Moonfrost", "Shadowbeam", "Flamestrike", "Naturecall", "Holybubble",
    "Ragesmash", "Sneakydagger", "Totemslam", "Beastcaller", "Voidwhisper",
}

local function ShuffleInPlace(t)
    for i = #t, 2, -1 do
        local j = math.random(1, i)
        t[i], t[j] = t[j], t[i]
    end
end

local function PickOneFrom(val)
    if type(val) == "table" then return val[math.random(1, #val)] end
    return val
end

local function GeneratePreviewGroup()
    local _, playerClass = UnitClass("player")
    local playerSpec
    local specIdx = GetSpecialization()
    if specIdx then playerSpec = GetSpecializationInfo(specIdx) end

    local playerIsTank = TANK_SPECS[playerClass] and playerSpec == TANK_SPECS[playerClass]
    local playerIsHealer = false
    if HEALER_SPECS[playerClass] then
        local hs = HEALER_SPECS[playerClass]
        if type(hs) == "table" then
            for _, s in ipairs(hs) do
                if playerSpec == s then playerIsHealer = true; break end
            end
        else
            playerIsHealer = playerSpec == hs
        end
    end

    local usedClasses = { [playerClass] = true }
    local group = {
        { name = UnitName("player") or "You", class = playerClass, specID = playerSpec },
    }

    local namePool = {}
    for _, n in ipairs(PREVIEW_NAMES) do namePool[#namePool + 1] = n end
    ShuffleInPlace(namePool)
    local nameIdx = 0
    local function nextName()
        nameIdx = nameIdx + 1
        return namePool[nameIdx] or ("Player" .. nameIdx)
    end

    local function pickClassForRole(roleMap)
        local candidates = {}
        for cls in pairs(roleMap) do
            if not usedClasses[cls] then candidates[#candidates + 1] = cls end
        end
        if #candidates == 0 then return nil end
        ShuffleInPlace(candidates)
        return candidates[1]
    end

    if not playerIsTank then
        local cls = pickClassForRole(TANK_SPECS)
        if cls then
            usedClasses[cls] = true
            group[#group + 1] = { name = nextName(), class = cls, specID = TANK_SPECS[cls] }
        end
    end

    if not playerIsHealer then
        local cls = pickClassForRole(HEALER_SPECS)
        if cls then
            usedClasses[cls] = true
            group[#group + 1] = { name = nextName(), class = cls, specID = PickOneFrom(HEALER_SPECS[cls]) }
        end
    end

    local dpsPool = {}
    for _, token in ipairs(ALL_CLASSES) do
        if not usedClasses[token] and DPS_SPECS[token] then
            dpsPool[#dpsPool + 1] = token
        end
    end
    ShuffleInPlace(dpsPool)

    local remaining = 5 - #group
    for i = 1, remaining do
        local cls = dpsPool[i]
        if not cls then break end
        usedClasses[cls] = true
        local specs = DPS_SPECS[cls]
        group[#group + 1] = { name = nextName(), class = cls, specID = PickOneFrom(specs) }
    end

    return group
end

local function QueryProvidersPreview(providersList, fakeGroup)
    if not providersList then return {} end
    local results = {}
    for _, member in ipairs(fakeGroup) do
        for _, provider in ipairs(providersList) do
            if member.class == provider.class then
                local specMatch = (provider.specID == nil) or (member.specID == provider.specID)
                if specMatch then
                    results[#results + 1] = {
                        unit      = "player",
                        name      = member.name,
                        class     = member.class,
                        specID    = member.specID,
                        spellID   = provider.spellID,
                        spellName = provider.spellName,
                        note      = provider.note,
                    }
                end
            end
        end
    end
    return results
end

local function EvaluatePreview(fakeGroup)
    local data = GetData()
    if not data then return {} end

    local results = {}
    local seenCapabilities = {}

    for _, rule in ipairs(data.rules) do
        for _, check in ipairs(rule.checks or {}) do
            local capID = check.capability
            if not seenCapabilities[capID] then
                local capability = data.capabilities[capID]
                if capability and IsCapabilityEnabled(capability) then
                    seenCapabilities[capID] = true

                    local matches = QueryProvidersPreview(capability.providers, fakeGroup)
                    local matchCount = #matches
                    local conditionKey = ResolveConditionKey(capability, matchCount)
                    local output = MergeOutput(capability, check, conditionKey)
                    local personal = CheckPersonalReminder(capability)

                    results[#results + 1] = {
                        capabilityID = capID,
                        capability   = capability,
                        matchCount   = matchCount,
                        matches      = matches,
                        conditionKey = conditionKey,
                        output       = output,
                        personal     = personal,
                    }
                end
            end
        end
    end

    return results
end

local function RunPreview()
    local ok, reason = IsDataCompatible()
    if not ok then
        Log("Cannot preview: data " .. (reason or "issue"))
        return
    end

    if not coveragePanel then CreateUI() end

    local fakeGroup = GeneratePreviewGroup()

    local groupDesc = {}
    for _, m in ipairs(fakeGroup) do
        local cc = CLASS_COLORS[m.class]
        local hex = cc and format("%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255) or "ffffff"
        groupDesc[#groupDesc + 1] = format("|cff%s%s|r", hex, m.name)
    end
    Log(format("Preview group: %s", table.concat(groupDesc, ", ")))

    lastContext = { inInstance = true, instanceType = "party", instanceID = nil, instanceName = "Preview" }
    local results = EvaluatePreview(fakeGroup)
    lastResults = results
    playerToolkit = EvaluatePlayerToolkit(GetData(), lastContext)

    dismissed = false
    if coveragePanel then coveragePanel:ClearDismissed() end
    uiState.selectedPage = "dungeon_group"
    if coveragePanel then
        coveragePanel:SetTitle("Reminders (Preview)")
        coveragePanel:Show()
        coveragePanel:Raise()
    end
    if uiState.workspaceShell then
        RenderCurrentPage()
    end
end

-- ============================================================================
-- Settings UI
-- ============================================================================

local function BuildConfig(parent, moduleDB)
    local LEFT_X, RIGHT_X = 0, 238
    db = moduleDB
    local Theme = MedaUI.Theme

    local tabBar, tabs = MedaAuras:CreateConfigTabs(parent, {
        { id = "tracking",   label = "Tracking" },
        { id = "sources",    label = "Sources" },
        { id = "appearance", label = "Appearance" },
    })

    -- ===== Tracking Tab =====
    do
        local p = tabs["tracking"]
        local yOff = 0

        local genHdr = MedaUI:CreateSectionHeader(p, "General")
        genHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 34

        local mmCb = MedaUI:CreateCheckbox(p, "Show minimap button")
        mmCb:SetChecked(db.showMinimapButton ~= false)
        mmCb.OnValueChanged = function(_, val)
            db.showMinimapButton = val
            if minimapButton then
                if val then minimapButton.ShowButton() else minimapButton.HideButton() end
            end
        end
        mmCb:SetPoint("TOPLEFT", LEFT_X, yOff)
        local lockCb = MedaUI:CreateCheckbox(p, "Lock panel position")
        lockCb:SetChecked(db.locked or false)
        lockCb.OnValueChanged = function(_, val)
            db.locked = val
            if coveragePanel then coveragePanel:SetLocked(val) end
        end
        lockCb:SetPoint("TOPLEFT", RIGHT_X, yOff)
        yOff = yOff - 28

        local autoShowCb = MedaUI:CreateCheckbox(p, "Auto-show on instance entrance")
        autoShowCb:SetChecked(db.autoShowInInstance ~= false)
        autoShowCb.OnValueChanged = function(_, val) db.autoShowInInstance = val end
        autoShowCb:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 34

        local talHdr = MedaUI:CreateSectionHeader(p, "Talent")
        talHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 34

        local prCb = MedaUI:CreateCheckbox(p, "Show personal talent reminders")
        prCb:SetChecked(db.personalReminders ~= false)
        prCb.OnValueChanged = function(_, val) db.personalReminders = val; RunPipeline(false) end
        prCb:SetPoint("TOPLEFT", LEFT_X, yOff)
        local talUtilCb = MedaUI:CreateCheckbox(p, "Track utility talents")
        talUtilCb:SetChecked(db.tag_utility ~= false)
        talUtilCb.OnValueChanged = function(_, val) db.tag_utility = val; RunPipeline(false) end
        talUtilCb:SetPoint("TOPLEFT", RIGHT_X, yOff)
        yOff = yOff - 34

        local debuffHdr = MedaUI:CreateSectionHeader(p, "Debuff")
        debuffHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 34

        local dispelMasterCb = MedaUI:CreateCheckbox(p, "Track dispel coverage")
        dispelMasterCb:SetChecked(db.tag_dispel ~= false)
        dispelMasterCb.OnValueChanged = function(_, val) db.tag_dispel = val; RunPipeline(false) end
        dispelMasterCb:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 28

        local curseCb = MedaUI:CreateCheckbox(p, "Curse removal")
        curseCb:SetChecked(db.tag_curse ~= false)
        curseCb.OnValueChanged = function(_, val) db.tag_curse = val; RunPipeline(false) end
        curseCb:SetPoint("TOPLEFT", LEFT_X + 16, yOff)
        local poisonCb = MedaUI:CreateCheckbox(p, "Poison removal")
        poisonCb:SetChecked(db.tag_poison ~= false)
        poisonCb.OnValueChanged = function(_, val) db.tag_poison = val; RunPipeline(false) end
        poisonCb:SetPoint("TOPLEFT", RIGHT_X, yOff)
        yOff = yOff - 28

        local diseaseCb = MedaUI:CreateCheckbox(p, "Disease removal")
        diseaseCb:SetChecked(db.tag_disease ~= false)
        diseaseCb.OnValueChanged = function(_, val) db.tag_disease = val; RunPipeline(false) end
        diseaseCb:SetPoint("TOPLEFT", LEFT_X + 16, yOff)
        local magicCb = MedaUI:CreateCheckbox(p, "Magic removal")
        magicCb:SetChecked(db.tag_magic ~= false)
        magicCb.OnValueChanged = function(_, val) db.tag_magic = val; RunPipeline(false) end
        magicCb:SetPoint("TOPLEFT", RIGHT_X, yOff)
        yOff = yOff - 34

        local diHdr = MedaUI:CreateSectionHeader(p, "Dungeon Info")
        diHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 34

        local intCb = MedaUI:CreateCheckbox(p, "Show interrupt priorities")
        intCb:SetChecked(db.showInterrupts ~= false)
        intCb.OnValueChanged = function(_, val) db.showInterrupts = val; RunPipeline(false) end
        intCb:SetPoint("TOPLEFT", LEFT_X, yOff)
        local affCb = MedaUI:CreateCheckbox(p, "Show affix tips")
        affCb:SetChecked(db.showAffixTips ~= false)
        affCb.OnValueChanged = function(_, val) db.showAffixTips = val; RunPipeline(false) end
        affCb:SetPoint("TOPLEFT", RIGHT_X, yOff)
    end

    -- ===== Sources Tab =====
    do
        local p = tabs["sources"]
        local yOff = 0

        local srcHdr = MedaUI:CreateSectionHeader(p, "Sources")
        srcHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 34

        local srcDesc = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        srcDesc:SetPoint("TOPLEFT", LEFT_X, yOff)
        srcDesc:SetPoint("RIGHT", p, "RIGHT", -4, 0)
        srcDesc:SetJustifyH("LEFT")
        srcDesc:SetWordWrap(true)
        srcDesc:SetTextColor(unpack(Theme.textDim or {0.6, 0.6, 0.6}))
        srcDesc:SetText("Choose which data sources provide recommendations. At least one must be active.")
        yOff = yOff - srcDesc:GetStringHeight() - 8

        if not db.sources then db.sources = {} end

        local configData = GetData()
        local sourceKeys = {}
        if configData and configData.sources then
            for key, src in pairs(configData.sources) do
                sourceKeys[#sourceKeys + 1] = { key = key, label = src.label }
            end
            table.sort(sourceKeys, function(a, b) return a.label < b.label end)
        end

        local function CountActiveSources()
            local count = 0
            for _, sk in ipairs(sourceKeys) do
                if db.sources[sk.key] ~= false then count = count + 1 end
            end
            return count
        end

        for _, sk in ipairs(sourceKeys) do
            local srcMeta = configData.sources[sk.key]
            local cbLabel = srcMeta and srcMeta.url and format("%s  |cff888888(%s)|r", sk.label, srcMeta.url) or sk.label
            local sCb = MedaUI:CreateCheckbox(p, cbLabel)
            sCb:SetChecked(db.sources[sk.key] ~= false)
            sCb.OnValueChanged = function(_, val)
                if not val and CountActiveSources() <= 1 then
                    sCb:SetChecked(true)
                    return
                end
                db.sources[sk.key] = val
                RunPipeline(false)
            end
            sCb:SetPoint("TOPLEFT", LEFT_X, yOff)
            yOff = yOff - 28
        end
    end

    -- ===== Appearance Tab =====
    do
        local p = tabs["appearance"]
        local yOff = 0

        local themeHdr = MedaUI:CreateSectionHeader(p, "Theme")
        themeHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 34

        local bgCb = MedaUI:CreateCheckbox(p, "Show panel background")
        bgCb:SetChecked(db.showBackground ~= false)
        bgCb:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 28

        local bgLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        bgLabel:SetPoint("TOPLEFT", LEFT_X + 16, yOff)
        bgLabel:SetText("Background opacity:")
        bgLabel:SetTextColor(unpack(Theme.text))
        yOff = yOff - 18

        local bgSlider = MedaUI:CreateSlider(p, 200, 0.1, 1.0, 0.05)
        bgSlider:SetValue(db.showBackground and (db.backgroundOpacity > 0 and db.backgroundOpacity or 0.8) or 0.8)
        bgSlider:SetPoint("TOPLEFT", LEFT_X + 16, yOff)
        bgSlider.OnValueChanged = function(_, val)
            if db.showBackground then
                db.backgroundOpacity = val
                if coveragePanel then coveragePanel:SetBackgroundOpacity(val) end
            end
        end

        bgCb.OnValueChanged = function(_, val)
            db.showBackground = val
            if val then
                local opacity = bgSlider:GetValue()
                db.backgroundOpacity = opacity
                bgSlider:Show()
                bgLabel:Show()
            else
                db.backgroundOpacity = 0
                bgSlider:Hide()
                bgLabel:Hide()
            end
            if coveragePanel then coveragePanel:SetBackgroundOpacity(db.backgroundOpacity) end
        end
        if not db.showBackground then bgSlider:Hide(); bgLabel:Hide() end
        yOff = yOff - 48

        local shellHdr = MedaUI:CreateSectionHeader(p, "Workspace")
        shellHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 34

        local shellDesc = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        shellDesc:SetPoint("TOPLEFT", LEFT_X, yOff)
        shellDesc:SetPoint("RIGHT", p, "RIGHT", -4, 0)
        shellDesc:SetJustifyH("LEFT")
        shellDesc:SetWordWrap(true)
        shellDesc:SetTextColor(unpack(Theme.textDim or { 0.6, 0.6, 0.6 }))
        shellDesc:SetText("The new reminders window keeps navigation, activity selection, and source freshness pinned in the chrome at all times.")
        yOff = yOff - shellDesc:GetStringHeight() - 14

        local actionsHdr = MedaUI:CreateSectionHeader(p, "Actions")
        actionsHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 34

        local resetPanelBtn = MedaUI:CreateButton(p, "Reset panel position", 160)
        resetPanelBtn:SetPoint("TOPLEFT", LEFT_X, yOff)
        resetPanelBtn.OnClick = function()
            if coveragePanel then
                coveragePanel:ClearAllPoints()
                coveragePanel:SetPoint("RIGHT", UIParent, "RIGHT", -50, 0)
                coveragePanel:SetSize(1120, 720)
                db.panelPoint = nil
                db.panelWidth = 1120
                db.panelHeight = 720
            end
        end

        local openBtn = MedaUI:CreateButton(p, "Open Reminders", 160)
        openBtn:SetPoint("TOPLEFT", RIGHT_X, yOff)
        openBtn.OnClick = function()
            dismissed = false
            if coveragePanel then
                coveragePanel:ClearDismissed()
                RunPipeline(false)
                coveragePanel:Show()
                coveragePanel:Raise()
            end
        end
    end

    MedaAuras:SetContentHeight(500)
    RunPreview()
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

local slashCommands = {
    show = function()
        if coveragePanel then
            dismissed = false
            coveragePanel:ClearDismissed()
            RunPipeline(false)
            coveragePanel:Show()
            coveragePanel:Raise()
        end
    end,
    hide = function()
        if coveragePanel then coveragePanel:Dismiss() end
    end,
    debug = function()
        debugMode = not debugMode
        Log(format("Debug mode: %s", debugMode and "ON" or "OFF"))
    end,
    refresh = function()
        local GroupInspector = ns.Services.GroupInspector
        if GroupInspector then
            GroupInspector:RequestRefresh()
        end
        RunPipeline(true)
    end,
    preview = function()
        RunPreview()
    end,
    instanceinfo = function()
        local inInstance = IsInInstance()
        if not inInstance then
            Log("Not currently in an instance. Zone into a dungeon or delve first.")
            return
        end
        local name, instType, diffID, diffName, maxPlayers, dynDiff, isDyn, instID = GetInstanceInfo()
        Log(format("Instance: %s | type: %s | ID: %s | diff: %s (%s) | max: %s",
            tostring(name), tostring(instType), tostring(instID),
            tostring(diffID), tostring(diffName), tostring(maxPlayers)))

        local data = GetData()
        local known = data and data.contexts and data.contexts.dungeons and data.contexts.dungeons[instID]
        if known then
            Log(format("  -> Matched data entry: %s (ID %d)", known.name, instID))
        else
            local resolved = ResolveDungeonByName(name)
            if resolved then
                Log(format("  -> ID not in data, but name '%s' resolved to data ID %d", name, resolved))
                Log(format("  -> Update dungeons.json in knowledge base: change instanceID from %d to %d", resolved, instID))
            else
                Log("  -> No matching entry in dungeon data.")
            end
        end
    end,
}

SLASH_MEDAREMINDERS1 = "/mr"
SlashCmdList["MEDAREMINDERS"] = function()
    if coveragePanel then
        dismissed = false
        coveragePanel:ClearDismissed()
        RunPipeline(false)
        coveragePanel:Show()
        coveragePanel:Raise()
    end
end

-- ============================================================================
-- Defaults & Registration
-- ============================================================================

local MODULE_DEFAULTS = {
    enabled = false,
    locked = false,
    showMinimapButton = true,
    autoShowInInstance = true,
    personalReminders = true,

    panelWidth = 1120,
    panelHeight = 720,
    panelPoint = nil,
    showBackground = true,
    backgroundOpacity = 0.85,

    sources = { wowhead = true, icyveins = true, archon = true },

    showInterrupts = true,
    showAffixTips  = true,
}

MedaAuras:RegisterModule({
    name          = MODULE_NAME,
    title         = "Reminders",
    version       = MODULE_VERSION,
    stability     = MODULE_STABILITY,
    author        = "Medalink",
    description   = "Data-driven group composition checker and dungeon prep assistant. "
                 .. "Shows dispel coverage, utility gaps, interrupt priorities, affix tips, "
                 .. "full build recommendations (talents, stats, gear, enchants, consumables), "
                 .. "and a pre-key prep checklist for dungeons, delves, and more.",
    sidebarDesc   = "Pre-key prep checklist with dispel coverage, utility gaps, and build tips.",
    defaults      = MODULE_DEFAULTS,
    OnInitialize  = OnInitialize,
    OnEnable      = OnEnable,
    OnDisable     = OnDisable,
    BuildConfig   = BuildConfig,
    slashCommands = slashCommands,
})
