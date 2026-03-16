--[[
    Prophecy Templates
    Curated prophecy timeline generator per dungeon.
    Reads shared data directly from ns -- no dependency on any module.
]]

local _, ns = ...

local ProphecyTemplates = {}
ns.ProphecyTemplates = ProphecyTemplates

local LUST_SPELL_IDS = { 80353, 32182, 2825, 390386, 264667 }

local PROPHECY_TYPES = {
    BUFF      = "BUFF",
    LUST      = "LUST",
    INTERRUPT = "INTERRUPT",
    BOSS      = "BOSS",
    CD        = "CD",
    AWARENESS = "AWARENESS",
}

local function IsBossEncounterLabel(encounterName, dungeonName)
    if not encounterName or encounterName == "" then return false end

    local lower = encounterName:lower()
    local genericPatterns = {
        "^throughout$",
        "^final boss$",
        "^all bosses$",
        "^trial encounters$",
        "^mini%-boss encounters$",
        "^mid%-dungeon$",
        "^2nd half of dungeon$",
        "^throughout lower floors$",
        "^below %d+%% hp$",
        "^%d+[a-z][a-z]? boss$",
        "^%d+[a-z][a-z]? and %d+[a-z][a-z]? boss$",
        "^%d+[a-z][a-z]? boss area$",
        "^before .+ boss$",
    }

    for _, pattern in ipairs(genericPatterns) do
        if lower:match(pattern) then
            return false
        end
    end

    if lower:find(" area", 1, true)
        or lower:find(" phase", 1, true)
        or lower:find(" gauntlet", 1, true)
        or lower:find(" corridors", 1, true)
        or lower:find(" trash", 1, true) then
        return false
    end

    if dungeonName and lower == dungeonName:lower() then
        return false
    end

    return true
end

local function BuildLustNode(lustTiming, index)
    return {
        id           = "lust_" .. index,
        text         = "Bloodlust: " .. (lustTiming.timing or ""),
        type         = PROPHECY_TYPES.LUST,
        isAnchor     = true,
        anchorWeight = 0.8,
        triggers     = {
            mode = "any",
            { type = "cleu_spell", spellIds = LUST_SPELL_IDS },
            { type = "manual" },
        },
        actions = {
            { type = "fulfill" },
            { type = "record", eventType = "lust" },
        },
    }
end

local function BuildBuffNode(buff, index)
    return {
        id       = "buff_" .. index,
        text     = buff.object .. ": " .. buff.effect,
        type     = PROPHECY_TYPES.BUFF,
        triggers = {
            mode = "any",
            { type = "buff_gained", pattern = buff.pattern },
            { type = "manual" },
        },
        actions = {
            { type = "fulfill" },
            { type = "record", eventType = "buff_pickup" },
        },
    }
end

local function BuildInterruptNode(entry, index)
    local triggers = { { type = "manual" } }
    if entry.spellID then
        table.insert(triggers, 1, { type = "cleu_spell", spellIds = { entry.spellID }, subevent = "SPELL_CAST_SUCCESS" })
        triggers.mode = "any"
    end

    return {
        id       = "int_" .. index,
        text     = "Interrupt: " .. entry.spell .. " (" .. entry.mob .. ")",
        type     = PROPHECY_TYPES.INTERRUPT,
        icon     = entry.icon,
        triggers = triggers,
        actions  = { { type = "fulfill" } },
    }
end

local function BuildDangerNode(danger, index)
    local triggers = { { type = "manual" } }
    if danger.spellID then
        table.insert(triggers, 1, { type = "cleu_spell", spellIds = { danger.spellID }, subevent = "SPELL_CAST_SUCCESS" })
        triggers.mode = "any"
    end
    return {
        id       = "danger_" .. index,
        text     = danger.mechanic .. " (" .. danger.source .. ")",
        type     = PROPHECY_TYPES.AWARENESS,
        icon     = danger.icon,
        triggers = triggers,
        actions  = { { type = "fulfill" } },
    }
end

local function BuildBossNodes(dangers, dungeonName)
    local bossDangers = {}
    local bossOrder = {}
    for _, d in ipairs(dangers) do
        if IsBossEncounterLabel(d.encounter, dungeonName) then
            if not bossDangers[d.encounter] then
                bossDangers[d.encounter] = {}
                bossOrder[#bossOrder + 1] = d.encounter
            end
            table.insert(bossDangers[d.encounter], d)
        end
    end

    local bossNodes = {}
    local bossIndex = 0
    for _, encounterName in ipairs(bossOrder) do
        local entries = bossDangers[encounterName]
        bossIndex = bossIndex + 1
        local engageId = "boss_" .. bossIndex .. "_engage"
        local killId = "boss_" .. bossIndex .. "_kill"

        table.insert(bossNodes, {
            id           = engageId,
            text         = encounterName,
            type         = PROPHECY_TYPES.BOSS,
            isAnchor     = true,
            anchorWeight = 1.0,
            triggers     = {
                { type = "encounter_start", encounterName = encounterName },
            },
            actions = {
                { type = "fulfill" },
                { type = "record", eventType = "encounter_start" },
            },
        })

        for i, danger in ipairs(entries) do
            table.insert(bossNodes, {
                id       = engageId .. "_danger_" .. i,
                text     = danger.mechanic .. ": " .. danger.tip,
                type     = PROPHECY_TYPES.AWARENESS,
                icon     = danger.icon,
                triggers = {
                    { type = "chain", afterProphecy = engageId },
                },
                actions = { { type = "fulfill" } },
            })
        end

        table.insert(bossNodes, {
            id           = killId,
            text         = encounterName .. " Killed",
            type         = PROPHECY_TYPES.BOSS,
            isAnchor     = true,
            anchorWeight = 1.0,
            triggers     = {
                { type = "encounter_end", encounterName = encounterName },
            },
            actions = {
                { type = "fulfill" },
                { type = "record", eventType = "encounter_end" },
            },
        })
    end

    return bossNodes
end

--- Generate a curated template for a specific dungeon.
--- @param instanceID number The dungeon instance ID
--- @return table|nil Template with .nodes array, or nil if no data
function ProphecyTemplates:Generate(instanceID)
    local D = ns.RemindersData
    if not D or not D.contexts or not D.contexts.dungeons then return nil end

    local dungeon = D.contexts.dungeons[instanceID]
    if not dungeon then return nil end

    local template = { instanceID = instanceID, name = dungeon.name, nodes = {} }
    local nodeList = template.nodes
    local idx = 0

    -- Phase: pre_key -- interactive buffs
    if dungeon.interactiveBuffs then
        for _, buff in ipairs(dungeon.interactiveBuffs) do
            idx = idx + 1
            table.insert(nodeList, BuildBuffNode(buff, idx))
        end
    end

    -- Phase: pre_key -- lust plan
    if dungeon.lustTimings then
        for _, lt in ipairs(dungeon.lustTimings) do
            idx = idx + 1
            table.insert(nodeList, BuildLustNode(lt, idx))
        end
    end

    -- Phase: trash -- top interrupt targets
    if dungeon.interruptPriority then
        for _, entry in ipairs(dungeon.interruptPriority) do
            if entry.danger == "high" or entry.danger == "critical" then
                idx = idx + 1
                table.insert(nodeList, BuildInterruptNode(entry, idx))
            end
        end
    end

    -- Phase: bosses -- encounter-specific dangers
    if dungeon.dangers then
        local bossNodes = BuildBossNodes(dungeon.dangers, dungeon.name)
        for _, node in ipairs(bossNodes) do
            table.insert(nodeList, node)
        end

        -- Non-boss dangers (trash awareness)
        for _, d in ipairs(dungeon.dangers) do
            if not IsBossEncounterLabel(d.encounter, dungeon.name) and d.severity ~= "info" then
                idx = idx + 1
                table.insert(nodeList, BuildDangerNode(d, idx))
            end
        end
    end

    -- Talent tips (spec-specific ability reminders)
    if dungeon.talentTips then
        local _, _, classID = UnitClass("player")
        local classToken = classID and select(2, GetClassInfo(classID)) or ""
        for _, tip in ipairs(dungeon.talentTips) do
            if not tip.class or tip.class == classToken then
                idx = idx + 1
                table.insert(nodeList, {
                    id       = "talent_" .. idx,
                    text     = tip.spell .. ": " .. tip.tip,
                    type     = PROPHECY_TYPES.CD,
                    triggers = { { type = "manual" } },
                    actions  = { { type = "fulfill" } },
                })
            end
        end
    end

    -- Key start node (always first in execution order)
    table.insert(nodeList, 1, {
        id       = "key_start",
        text     = "Key Started",
        type     = PROPHECY_TYPES.BOSS,
        isAnchor = true,
        expectedTime = 0,
        triggers = { { type = "challenge_start" } },
        actions  = {
            { type = "fulfill" },
            { type = "record", eventType = "key_start" },
        },
    })

    -- Enrich nodes with timing data from ProphecyData (scraper-generated CD timelines)
    ProphecyTemplates:_EnrichWithTimingData(template)

    return template
end

function ProphecyTemplates:_EnrichWithTimingData(template)
    local PD = ns.ProphecyData
    if not PD or not PD.cdTimelines then return end

    local dungeonSlug = nil
    local D = ns.RemindersData
    if D and D.contexts and D.contexts.dungeons and template.instanceID then
        local ctx = D.contexts.dungeons[template.instanceID]
        if ctx and ctx.meta and ctx.meta.slug then
            dungeonSlug = ctx.meta.slug
        elseif ctx and ctx.name then
            dungeonSlug = ctx.name:lower():gsub("%s+", "-"):gsub("[^%w%-]", "")
        end
    end
    if not dungeonSlug then return end

    -- Collect lust spell median times from any spec's timeline
    local lustMedians = {}
    local lustSpellIDs = {}
    for _, dungeons in pairs(PD.cdTimelines) do
        local dungeon = dungeons[dungeonSlug]
        if dungeon and dungeon.spells then
            for _, lustId in ipairs(LUST_SPELL_IDS) do
                local spell = dungeon.spells[lustId]
                if spell and spell.median and not lustMedians[1] then
                    lustMedians[#lustMedians + 1] = spell.median
                    lustSpellIDs[#lustSpellIDs + 1] = lustId
                end
            end
            if #lustMedians > 0 then break end
        end
    end

    -- Apply lust timing to lust nodes
    local lustIdx = 0
    for _, node in ipairs(template.nodes) do
        if node.type == PROPHECY_TYPES.LUST then
            lustIdx = lustIdx + 1
            if lustMedians[lustIdx] then
                node.expectedTime = lustMedians[lustIdx]
            end
            local spellMeta = PD.spells and lustSpellIDs[lustIdx] and PD.spells[lustSpellIDs[lustIdx]]
            if spellMeta then
                node.icon = spellMeta.icon or node.icon
            end
        end
    end
end

--- Get all available dungeon instance IDs that have data.
--- @return table Array of instance IDs
function ProphecyTemplates:GetAvailableDungeons()
    local D = ns.RemindersData
    if not D or not D.contexts or not D.contexts.dungeons then return {} end

    local ids = {}
    for iid, ctx in pairs(D.contexts.dungeons) do
        if ctx.season1MPlus then
            ids[#ids + 1] = iid
        end
    end
    table.sort(ids)
    return ids
end

--- Get the dungeon name for an instance ID.
--- @param instanceID number
--- @return string
function ProphecyTemplates:GetDungeonName(instanceID)
    local D = ns.RemindersData
    if not D or not D.contexts or not D.contexts.dungeons then return "Unknown" end
    local ctx = D.contexts.dungeons[instanceID]
    return ctx and ctx.name or "Unknown"
end
