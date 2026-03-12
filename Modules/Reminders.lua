local _, ns = ...

local MedaUI = LibStub("MedaUI-1.0")

local format = format
local pairs = pairs
local ipairs = ipairs
local wipe = wipe
local pcall = pcall
local unpack = unpack
local CreateFrame = CreateFrame
local IsInGroup = IsInGroup
local UnitExists = UnitExists

-- ============================================================================
-- Constants
-- ============================================================================

local MODULE_NAME      = "Reminders"
local MODULE_VERSION   = "1.1"
local MODULE_STABILITY = "beta"   -- "experimental" | "beta" | "stable"
local MIN_DATA_VERSION = 1
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
local alertBanner
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
local contextDropdown = nil
local detectedLabel = nil

local tabBar = nil
local tabFrames = {}
local tabRendered = {}
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
    local parts = {}
    for key, src in pairs(data.sources) do
        if src.lastFetched then
            local rel = FormatRelativeTime(src.lastFetched)
            if rel then
                local c = src.color or { 0.7, 0.7, 0.7 }
                parts[#parts + 1] = format(
                    "|cff%02x%02x%02x%s|r %s",
                    math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255),
                    src.label, rel
                )
            end
        end
    end
    if #parts == 0 then return nil end
    return "Updated: " .. table.concat(parts, "  |  ")
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

local function CheckPersonalReminder(capability)
    if not capability.personalReminder then return nil end
    if not capability.providers then return nil end

    local _, playerClass = UnitClass("player")
    if not playerClass then return nil end

    for _, provider in ipairs(capability.providers) do
        if provider.class == playerClass then
            local specMatch = true
            if provider.specID then
                local specIndex = GetSpecialization()
                local currentSpec = specIndex and GetSpecializationInfo(specIndex)
                specMatch = currentSpec == provider.specID
            end

            if specMatch and not IsPlayerSpell(provider.spellID) then
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

local function Evaluate()
    local data = GetData()
    if not data then return {} end

    local ctx = overrideContext or GetCurrentContext()
    lastContext = ctx

    local results = {}
    local seenCapabilities = {}
    local GroupInspector = ns.Services.GroupInspector

    if not GroupInspector then
        LogWarn("GroupInspector service not available")
        return results
    end

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

                        local matches = GroupInspector:QueryProviders(capability.providers)
                        local matchCount = #matches
                        local conditionKey = ResolveConditionKey(capability, matchCount)
                        local output = MergeOutput(capability, check, conditionKey)
                        local personal = CheckPersonalReminder(capability)

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
                        }
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

local function AcquireRow(parent)
    local row = table.remove(rowPool)
    if not row then
        row = MedaUI:CreateStatusRow(parent, { width = nil, showNote = true, iconSize = ICON_SIZE })
    else
        row:SetParent(parent)
        row:Reset()
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

    return nil
end

local function GetContextHeader(data, ctx)
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

local function ResolveInstanceContext(data, ctx)
    if not data or not ctx then return nil end

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

    local _, playerClass = UnitClass("player")
    local specIdx = GetSpecialization()
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
                    if prov.class == playerClass then
                        if IsPlayerSpell and IsPlayerSpell(prov.spellID) then
                            have = true
                            break
                        elseif prov.talentSpellID and IsPlayerSpell and not IsPlayerSpell(prov.spellID) then
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
                if tt.spell and tt.spell ~= "" and IsPlayerSpell then
                    local info = C_Spell.GetSpellInfo(tt.spell)
                    if info and info.spellID then
                        known = IsPlayerSpell(info.spellID)
                    end
                end
                tips[#tips + 1] = { spell = tt.spell, tip = tt.tip, known = known }
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
    if not detectedLabel then return end
    local liveCtx = GetCurrentContext()
    detectedLabel:SetText("Detected: " .. GetDetectedLabel(liveCtx))
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

-- Color [Spell Name] references, using dispel-type colors when a spellMap is provided
local function ColorSpellNames(text, spellMap)
    if not text then return text end
    return text:gsub("%[([^%]]+)%]", function(name)
        local color = SPELL_COLOR_DEFAULT
        if spellMap and spellMap[name] then
            color = spellMap[name]
        end
        return "|cff" .. color .. "[" .. name .. "]|r"
    end)
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
        tierFS:SetTextColor(0.6, 0.6, 0.6)
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
                noteFS:SetTextColor(0.7, 0.7, 0.7)
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

            local row = MedaUI:CreateStatusRow(content, { iconSize = 32, showNote = true })
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
                tip:AddLine(d.mechanic or "Unknown", 1, 0.82, 0)
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
                line = format("|cff%s\226\151\134 ALT|r  ", pctColor)
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
                noteFS:SetText("|cffaaaaaa" .. lt.note .. "|r")
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
            local tipFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            tipFS:SetPoint("TOPLEFT", 8, yOff)
            tipFS:SetPoint("RIGHT", content, "RIGHT", -8, 0)
            tipFS:SetJustifyH("LEFT")
            tipFS:SetWordWrap(true)
            tipFS:SetText(icon .. ColorText(tt.tip, mobSet, spellMap))
            yOff = yOff - tipFS:GetStringHeight() - 4
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

            local row = MedaUI:CreateStatusRow(content, { iconSize = 24, showNote = true })
            playerRows[#playerRows + 1] = row
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOff)
            row:SetPoint("RIGHT", content, "RIGHT", 0, 0)

            local labelText = ib.buff
            if recommended and not ok then
                labelText = "\226\152\133 " .. labelText
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
                tip:AddLine(ib.buff, 1, 0.82, 0)
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

    local gcFrame = tabFrames.groupcomp
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
                    local row = AcquireRow(content)
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
                        tip:AddLine(cap.label or capID, 1, 0.82, 0)
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
            local row = AcquireRow(content)
            activeRows[#activeRows + 1] = row
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOff)
            row:SetPoint("RIGHT", content, "RIGHT", 0, 0)

            local labelText = ib.buff
            if recommended then
                labelText = "\226\152\133 " .. labelText
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
                tip:AddLine(ib.buff, 1, 0.82, 0)
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

    -- Personal reminders footer
    if #personalReminders > 0 and db and db.personalReminders ~= false then
        local first = personalReminders[1]
        local text = first.personal.detail or ""
        if first.personal.banner then
            text = first.personal.banner .. "\n" .. text
        end
        coveragePanel:SetFooter(text, 1.0, 0.82, 0.2)
        yOff = yOff - 30
    else
        coveragePanel:SetFooter("")
    end

    coveragePanel:SetContentHeight(CHROME_HEIGHT + math.abs(yOff) + 8)
end

-- ============================================================================
-- UI: Copy-to-clipboard popup
-- ============================================================================

local function ShowCopyPopup(text)
    if not copyPopup then
        copyPopup = CreateFrame("Frame", "MedaAurasRemindersCopy", UIParent, "BackdropTemplate")
        copyPopup:SetFrameStrata("DIALOG")
        copyPopup:SetSize(420, 70)
        copyPopup:SetPoint("CENTER")
        copyPopup:SetMovable(true)
        copyPopup:EnableMouse(true)
        copyPopup:RegisterForDrag("LeftButton")
        copyPopup:SetScript("OnDragStart", function(self) self:StartMoving() end)
        copyPopup:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        copyPopup:SetBackdrop(MedaUI:CreateBackdrop(true))

        local Theme = MedaUI.Theme
        copyPopup:SetBackdropColor(unpack(Theme.background))
        copyPopup:SetBackdropBorderColor(unpack(Theme.border))

        local lbl = copyPopup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", 8, -8)
        lbl:SetText("Press Ctrl+C to copy, then Esc to close:")
        lbl:SetTextColor(unpack(Theme.textDim or { 0.6, 0.6, 0.6 }))

        local eb = CreateFrame("EditBox", nil, copyPopup, "InputBoxTemplate")
        eb:SetSize(396, 24)
        eb:SetPoint("TOPLEFT", 10, -28)
        eb:SetAutoFocus(true)
        eb:SetScript("OnEscapePressed", function() copyPopup:Hide() end)
        copyPopup.editBox = eb
    end

    copyPopup.editBox:SetText(text)
    copyPopup:Show()
    copyPopup.editBox:HighlightText()
    copyPopup.editBox:SetFocus()
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

    -- Helper: render a single talent build card
    local function RenderBuildCard(rec)
        local badge = FormatSourceBadge(rec.source)
        local heroStr = ""
        if rec.heroTree and rec.heroTree ~= "" then
            heroStr = format("  |cffffcc00%s|r", rec.heroTree)
        end

        local line = badge .. heroStr

        if rec.source == "archon" then
            if rec.popularity then
                line = line .. format("  |cffffffff%.0f%% pop|r", rec.popularity)
            end
            if rec.keyLevel then
                line = line .. format("  |cff88bbff+%d key|r", rec.keyLevel)
            end
            if rec.content and rec.content.dps then
                line = line .. format("  |cffaaddaa%s DPS|r", rec.content.dps)
            end
        else
            -- Wowhead / Icy Veins: show label from notes
            local label = rec.notes or ""
            -- Strip the content_type and hero_talent from notes to get just the label
            local parts = { strsplit(",", label) }
            local cleanLabel = strtrim(parts[1] or "")
            if cleanLabel ~= "" then
                line = line .. "  |cffbbbbbb" .. cleanLabel .. "|r"
            end
        end

        local recFrame = CreateFrame("Frame", nil, content)
        recFrame:SetHeight(28)
        recFrame:SetPoint("TOPLEFT", 8, yOff)
        recFrame:SetPoint("RIGHT", content, "RIGHT", -4, 0)
        talentRows[#talentRows + 1] = recFrame

        local infoFS = recFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        infoFS:SetPoint("LEFT", 0, 0)
        infoFS:SetPoint("RIGHT", recFrame, "RIGHT", -64, 0)
        infoFS:SetJustifyH("LEFT")
        infoFS:SetWordWrap(false)
        infoFS:SetText(line)

        if rec.content and rec.content.exportString then
            local copyBtn = MedaUI:CreateButton(recFrame, "Copy", 56)
            copyBtn:SetPoint("RIGHT", recFrame, "RIGHT", 0, 0)
            copyBtn:SetHeight(22)
            copyBtn.OnClick = function()
                ShowCopyPopup(rec.content.exportString)
            end
        end

        recFrame:Show()
        yOff = yOff - 30
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

                -- Pick top builds: up to MAX_VISIBLE_BUILDS per source
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

                local hdr = MedaUI:CreateCollapsibleSectionHeader(content, {
                    text = cat.label,
                    width = content:GetWidth() - 8,
                    count = #builds,
                    expanded = sectionExpanded,
                    onToggle = function(exp)
                        talentSectionExpanded[sectionKey] = exp
                        RenderTalentsTab(content)
                    end,
                })
                hdr:SetPoint("TOPLEFT", 4, yOff)
                talentHeaders[#talentHeaders + 1] = hdr
                yOff = yOff - 32

                for _, rec in ipairs(topBuilds) do
                    RenderBuildCard(rec)
                end

                if #overflowBuilds > 0 then
                    if sectionExpanded then
                        for _, rec in ipairs(overflowBuilds) do
                            RenderBuildCard(rec)
                        end
                    end

                    local toggle = MedaUI:CreateExpandToggle(content, {
                        hiddenCount = #overflowBuilds,
                        expanded = sectionExpanded,
                        onToggle = function(exp)
                            talentSectionExpanded[sectionKey] = exp
                            RenderTalentsTab(content)
                        end,
                    })
                    toggle:SetPoint("TOPLEFT", 8, yOff)
                    toggle:SetPoint("RIGHT", content, "RIGHT", 0, 0)
                    yOff = yOff - toggle:GetHeight() - 2
                end

                yOff = yOff - 6
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

    -- Stat Priority section (kept compact)
    if #statRecs > 0 then
        local rec = statRecs[1]
        if rec.content then
            local hdrContainer = MedaUI:CreateSectionHeader(content, "Stat Priority", content:GetWidth() - 8)
            hdrContainer:SetPoint("TOPLEFT", 4, yOff)
            talentHeaders[#talentHeaders + 1] = hdrContainer
            yOff = yOff - 32

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
            local statLine = badge .. "  " .. table.concat(parts, "  >  ")

            local statFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            statFS:SetPoint("TOPLEFT", 8, yOff)
            statFS:SetPoint("RIGHT", content, "RIGHT", -8, 0)
            statFS:SetJustifyH("LEFT")
            statFS:SetWordWrap(true)
            statFS:SetText(statLine)
            yOff = yOff - statFS:GetStringHeight() - 12
        end
    end

    -- Helper to render an item-list section with collapsible overflow
    local function RenderItemSection(recs, title, sectionKey)
        if #recs == 0 then return end
        local rec = recs[1]
        if not rec.content or not rec.content.items or #rec.content.items == 0 then return end

        local items = rec.content.items
        local totalItems = #items
        local sectionExpanded = talentSectionExpanded[sectionKey] or false
        local shown = sectionExpanded and totalItems or math.min(totalItems, 2)

        local hdr = MedaUI:CreateCollapsibleSectionHeader(content, {
            text = title,
            width = content:GetWidth() - 8,
            count = totalItems,
            expanded = sectionExpanded,
            onToggle = function(exp)
                talentSectionExpanded[sectionKey] = exp
                RenderTalentsTab(content)
            end,
        })
        hdr:SetPoint("TOPLEFT", 4, yOff)
        talentHeaders[#talentHeaders + 1] = hdr
        yOff = yOff - 32

        local badge = FormatSourceBadge(rec.source)

        for i = 1, shown do
            local item = items[i]
            local pop = item.popularity or 0
            local text = format("%s  |cffffffff%s|r  |cff888888%.0f%%|r", badge, item.name, pop)

            local itemFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            itemFS:SetPoint("TOPLEFT", 8, yOff)
            itemFS:SetPoint("RIGHT", content, "RIGHT", -8, 0)
            itemFS:SetJustifyH("LEFT")
            itemFS:SetWordWrap(false)
            itemFS:SetText(text)
            yOff = yOff - 16
        end

        if totalItems > 2 then
            local toggle = MedaUI:CreateExpandToggle(content, {
                hiddenCount = totalItems - 2,
                expanded = sectionExpanded,
                onToggle = function(exp)
                    talentSectionExpanded[sectionKey] = exp
                    RenderTalentsTab(content)
                end,
            })
            toggle:SetPoint("TOPLEFT", 8, yOff)
            toggle:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            yOff = yOff - toggle:GetHeight() - 2
        end

        yOff = yOff - 8
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
    if not data or not data.recommendations then return {} end
    local classToken = select(2, UnitClass("player"))
    local specIdx = GetSpecialization()
    if not classToken or not specIdx then return {} end
    local specID = GetSpecializationInfo(specIdx)
    if not specID then return {} end
    local key = classToken .. "_" .. specID
    local recs = data.recommendations[key]
    if not recs then return {} end
    local PRIMARY = { Strength = true, Agility = true, Intellect = true }
    for _, rec in ipairs(recs) do
        if rec.buildType == "stats" and rec.content then
            local sorted = {}
            for stat, weight in pairs(rec.content) do
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
                statusText = "Recommended"
            else
                accentColor = SEVERITY_COLORS.info
                statusText = ib.effect or ""
            end

            local row = MedaUI:CreateStatusRow(content, {
                width = content:GetWidth() - 16,
                iconSize = 18,
                showNote = false,
            })
            row:SetPoint("TOPLEFT", 8, yOff)
            prepRows[#prepRows + 1] = row

            row:SetLabel(ib.buff)
            row:SetStatus(statusText, accentColor[1], accentColor[2], accentColor[3])
            row:SetAccentColor(accentColor[1], accentColor[2], accentColor[3])
            if recommended and not ok then row:SetHighlight(true) end

            row:SetTooltipFunc(function(_, tooltip)
                tooltip:AddLine(ib.buff, 1, 0.82, 0)
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
                    local itemFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    itemFS:SetPoint("TOPLEFT", 8, yOff)
                    itemFS:SetPoint("RIGHT", content, "RIGHT", -8, 0)
                    itemFS:SetJustifyH("LEFT")
                    itemFS:SetWordWrap(false)
                    itemFS:SetText(text)
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
    if not alertBanner or not db or not db.alertEnabled then return end
    if coveragePanel and coveragePanel:IsShown() then return end

    local threshold = SEVERITY_PRIORITY[db.alertSeverityThreshold or "warning"] or 2

    for _, r in ipairs(results) do
        local output = r.output or {}
        if output.banner and output.severity then
            local pri = SEVERITY_PRIORITY[output.severity] or 0
            if pri >= threshold then
                alertBanner:Show(output.banner, db.alertDuration or 5)
                Log(format("Banner shown: %s", output.banner))
                return
            end
        end
    end
end


local function RefreshFreshnessBar()
    if not coveragePanel then return end
    local text = BuildSourceFreshnessLine()
    coveragePanel:SetStatusBar(text or "", 0.5, 0.5, 0.5)
end

-- ============================================================================
-- Evaluation + render pipeline
-- ============================================================================

local function RunPipeline(clearDismiss)
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

    -- Update panel title from context (applies to all tabs)
    if coveragePanel and data then
        local ctxName = GetContextHeader(data, lastContext)
        coveragePanel:SetTitle(ctxName or "Group Coverage")
    end

    RefreshFreshnessBar()

    RenderPanel(results)
    ShowBannerIfNeeded(results)

    -- Refresh player tab if it's currently active
    if tabBar and tabBar:GetActiveTab() == "player" and tabFrames.player then
        RenderPlayerTab(tabFrames.player)
        tabRendered.player = true
    else
        tabRendered.player = false
    end

    -- Refresh talents tab if it's currently active
    if tabBar and tabBar:GetActiveTab() == "talents" and tabFrames.talents then
        RenderTalentsTab(tabFrames.talents)
        tabRendered.talents = true
    else
        tabRendered.talents = false
    end

    -- Refresh prep tab if it's currently active
    if tabBar and tabBar:GetActiveTab() == "prep" and tabFrames.prep then
        RenderPrepTab(tabFrames.prep)
        tabRendered.prep = true
    else
        tabRendered.prep = false
    end

    -- Auto-show panel only when inside an instance (not in cities/open world)
    if db.autoShowInInstance ~= false and coveragePanel and not dismissed and lastContext and lastContext.inInstance then
        coveragePanel:Show()
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
    -- Coverage panel
    coveragePanel = MedaUI:CreateInfoPanel("MedaAurasRemindersPanel", {
        width       = db.panelWidth or 640,
        height      = db.panelHeight or 720,
        title       = "Group Coverage",
        icon        = 134063,
        strata      = "MEDIUM",
        dismissable = true,
        locked      = db.locked or false,
    })

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
        minWidth  = 420,
        minHeight = 500,
    })
    coveragePanel.OnResize = function(self, w, h)
        db.panelWidth = math.floor(w)
        db.panelHeight = math.floor(h)
    end

    local content = coveragePanel:GetContent()

    -- Tab bar
    tabBar = MedaUI:CreateTabBar(content, {
        { id = "player",    label = "You" },
        { id = "groupcomp", label = "Group Comp" },
        { id = "talents",   label = "Talents" },
        { id = "prep",      label = "Prep" },
    })
    tabBar:SetPoint("TOPLEFT", 0, 0)
    tabBar:SetPoint("TOPRIGHT", 0, 0)

    -- Context selector (shared across all tabs, sits between tab bar and tab content)
    local Theme = MedaUI.Theme
    detectedLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    detectedLabel:SetJustifyH("LEFT")
    detectedLabel:SetWordWrap(false)
    detectedLabel:SetTextColor(unpack(Theme.textDim or {0.6, 0.6, 0.6}))
    detectedLabel:SetText("Detected: World")
    detectedLabel:SetPoint("TOPLEFT", 4, -34)
    detectedLabel:SetPoint("RIGHT", content, "RIGHT", -4, 0)

    local ddItems = BuildContextDropdownItems()
    contextDropdown = MedaUI:CreateDropdown(content, 280, ddItems)
    contextDropdown:SetSelected("auto")
    contextDropdown:SetPoint("TOPLEFT", 4, -50)
    contextDropdown.OnValueChanged = function(_, val)
        if val and val:match("^_hdr_") then return end
        overrideContext = ParseContextSelection(val)
        tabRendered.player = false
        tabRendered.talents = false
        tabRendered.prep = false
        if coveragePanel and coveragePanel.scrollParent then
            coveragePanel.scrollParent:ResetScroll()
        end
        RunPipeline(false)
    end

    -- Tab content frames start below tab bar + context selector area
    local TAB_CONTENT_TOP = -CHROME_HEIGHT
    for _, tabId in ipairs({ "player", "groupcomp", "talents", "prep" }) do
        local frame = CreateFrame("Frame", nil, content)
        frame:SetPoint("TOPLEFT", 0, TAB_CONTENT_TOP)
        frame:SetPoint("BOTTOMRIGHT", 0, 0)
        frame:Hide()
        tabFrames[tabId] = frame
    end

    tabBar.OnTabChanged = function(_, tabId)
        for id, frame in pairs(tabFrames) do
            if id == tabId then
                frame:Show()
            else
                frame:Hide()
            end
        end

        if tabId == "player" and not tabRendered.player then
            RenderPlayerTab(tabFrames.player)
            tabRendered.player = true
        elseif tabId == "talents" and not tabRendered.talents then
            RenderTalentsTab(tabFrames.talents)
            tabRendered.talents = true
        elseif tabId == "prep" and not tabRendered.prep then
            RenderPrepTab(tabFrames.prep)
            tabRendered.prep = true
        end
    end

    -- Force-build the default tab
    tabFrames.player:Show()
    tabRendered.player = true

    -- Notification banner
    alertBanner = MedaUI:CreateNotificationBanner("MedaAurasRemindersAlert", {
        duration = db.alertDuration or 5,
        strata   = "HIGH",
        locked   = db.alertLocked or false,
    })

    alertBanner:HookScript("OnDragStop", function(self)
        db.alertPoint = self:SavePosition()
    end)

    if db.alertPoint then
        alertBanner:RestorePosition(db.alertPoint)
    else
        alertBanner:SetPoint("TOP", UIParent, "TOP", 0, -120)
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
    if alertBanner then alertBanner:Dismiss() end
    if copyPopup then copyPopup:Hide() end

    ReleaseRows()
    ReleaseSectionHeaders()
    ReleaseTalentRows()
    ReleaseTalentHeaders()
    ReleasePrepRows()
    ReleasePrepHeaders()
    ReleasePlayerRows()
    ReleasePlayerHeaders()
    wipe(tabRendered)
    wipe(playerSectionExpanded)
    playerSectionLastCtxKey = nil
    currentAffixes = nil
    playerToolkit = nil

    Log("Module disabled")
end

local function OnInitialize(moduleDB)
    db = moduleDB

    if not db._sizeMigrated then
        if (db.panelWidth or 0) <= 440 then db.panelWidth = 640 end
        if (db.panelHeight or 0) <= 520 then db.panelHeight = 720 end
        db._sizeMigrated = true
    end

    if not db._sizeMigrated2 then
        if (db.panelWidth or 0) <= 520 then db.panelWidth = 640 end
        if (db.panelHeight or 0) <= 620 then db.panelHeight = 720 end
        db._sizeMigrated2 = true
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

local ALL_CLASS_SPECS = {
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

local TANK_SPECS = {
    DEATHKNIGHT = 250, DEMONHUNTER = 581, DRUID = 104,
    MONK = 268, PALADIN = 66, WARRIOR = 73,
}
local HEALER_SPECS = {
    DRUID = 105, EVOKER = 1468, MONK = 270,
    PALADIN = 65, PRIEST = { 256, 257 }, SHAMAN = 264,
}
local DPS_SPECS = {
    DEATHKNIGHT = { 251, 252 }, DEMONHUNTER = { 577 },
    DRUID = { 102, 103 }, EVOKER = { 1467, 1473 },
    HUNTER = { 253, 254, 255 }, MAGE = { 62, 63, 64 },
    MONK = { 269 }, PALADIN = { 70 },
    PRIEST = { 258 }, ROGUE = { 259, 260, 261 },
    SHAMAN = { 262, 263 }, WARLOCK = { 265, 266, 267 },
    WARRIOR = { 71, 72 },
}

local ALL_CLASSES = {}
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

    dismissed = false
    if coveragePanel then coveragePanel:ClearDismissed() end
    RenderPanel(results)
    if coveragePanel then coveragePanel:SetTitle("Group Coverage (Preview)") end
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

        local alertHdr = MedaUI:CreateSectionHeader(p, "Alerts")
        alertHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 34

        local alertCb = MedaUI:CreateCheckbox(p, "Enable notification banners")
        alertCb:SetChecked(db.alertEnabled ~= false)
        alertCb.OnValueChanged = function(_, val) db.alertEnabled = val end
        alertCb:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 28

        local sevLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        sevLabel:SetPoint("TOPLEFT", LEFT_X, yOff)
        sevLabel:SetText("Minimum severity:")
        sevLabel:SetTextColor(unpack(Theme.text))
        local sevDropdown = MedaUI:CreateDropdown(p, 140, {
            { value = "info",     label = "Info" },
            { value = "warning",  label = "Warning" },
            { value = "critical", label = "Critical" },
        })
        sevDropdown:SetSelected(db.alertSeverityThreshold or "warning")
        sevDropdown.OnValueChanged = function(_, val) db.alertSeverityThreshold = val end
        sevDropdown:SetPoint("TOPLEFT", RIGHT_X, yOff)
        yOff = yOff - 40

        local durLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        durLabel:SetPoint("TOPLEFT", LEFT_X, yOff)
        durLabel:SetText("Banner duration (sec):")
        durLabel:SetTextColor(unpack(Theme.text))
        local durSlider = MedaUI:CreateSlider(p, 200, 2, 15, 1)
        durSlider:SetValue(db.alertDuration or 5)
        durSlider.OnValueChanged = function(_, val)
            db.alertDuration = val
            if alertBanner then alertBanner:SetDuration(val) end
        end
        durSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
        yOff = yOff - 48

        local actionsHdr = MedaUI:CreateSectionHeader(p, "Actions")
        actionsHdr:SetPoint("TOPLEFT", LEFT_X, yOff)
        yOff = yOff - 34

        local resetPanelBtn = MedaUI:CreateButton(p, "Reset panel position", 160)
        resetPanelBtn:SetPoint("TOPLEFT", LEFT_X, yOff)
        resetPanelBtn.OnClick = function()
            if coveragePanel then
                coveragePanel:ClearAllPoints()
                coveragePanel:SetPoint("RIGHT", UIParent, "RIGHT", -50, 0)
                coveragePanel:SetSize(640, 720)
                db.panelPoint = nil
                db.panelWidth = 640
                db.panelHeight = 720
            end
        end
        local resetAlertBtn = MedaUI:CreateButton(p, "Reset alert position", 160)
        resetAlertBtn:SetPoint("TOPLEFT", RIGHT_X, yOff)
        resetAlertBtn.OnClick = function()
            if alertBanner then
                alertBanner:ResetPosition()
                db.alertPoint = nil
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

    panelWidth = 640,
    panelHeight = 720,
    panelPoint = nil,
    showBackground = true,
    backgroundOpacity = 0.85,

    alertEnabled = true,
    alertSeverityThreshold = "warning",
    alertDuration = 5,
    alertLocked = false,
    alertPoint = nil,

    sources = { wowhead = true, icyveins = true, archon = true, raiderio = true },

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
