-- Priority Kick Dimmer for Plater
--
-- Purpose:
-- Dim every enemy nameplate except mobs currently casting an interruptible,
-- high-priority spell.
--
-- Install:
-- 1. Plater -> Modding -> Hooking
-- 2. Create a new mod, for example: "Priority Kick Dimmer"
-- 3. Add these hooks and paste the matching function into each hook:
--    - Initialization
--    - Nameplate Added
--    - Nameplate Removed
--    - Nameplate Updated
--    - Cast Start
--    - Cast Update
--    - Cast Stop
--    - Player Talent Update
--    - Mod Option Changed
-- 4. In the mod admin options, add these real Plater options:
--    - Number: Name "Dim Opacity", Key "dimOpacityPercent", Min 0, Max 100, Fraction false, Value 25
--    - Toggle: Name "Match All Interruptible Casts", Key "matchAllInterruptibleCasts", Value false
--    - Toggle: Name "Require Known Interrupt", Key "requireKnownInterrupt", Value false
--    - Toggle: Name "Require Ready Interrupt", Key "requireReadyInterrupt", Value false
--
-- Notes:
-- - The logic hard-filters itself to enemy NPC plates.
-- - Use spell IDs whenever you can. They are more reliable than names.
-- - The shipped starter defaults now use hardcoded client spell IDs pulled from wow-tools exports.
-- - "Death Curse" remains a fallback name match because it was not present as an exact SpellName row in the current export.
-- - dimOpacityPercent is the final alpha for non-priority plates:
--   0 = invisible, 100 = fully opaque.

-- =====================================================================
-- Initialization
-- =====================================================================
function(modTable)
    local ipairs = ipairs
    local pairs = pairs
    local GetTime = GetTime
    local UnitName = UnitName
    local UnitCanAttack = UnitCanAttack
    local UnitIsPlayer = UnitIsPlayer
    local IsPlayerSpell = IsPlayerSpell
    local IsSpellKnown = IsSpellKnown
    local issecretvalue = issecretvalue
    local C_NamePlate = C_NamePlate
    local C_Spell = C_Spell

    modTable.config = modTable.config or {}
    local config = modTable.config

    if config.dimOpacityPercent == nil then
        config.dimOpacityPercent = 25
    end

    if config.requireKnownInterrupt == nil then
        config.requireKnownInterrupt = false
    end

    if config.requireReadyInterrupt == nil then
        config.requireReadyInterrupt = false
    end

    if config.matchAllInterruptibleCasts == nil then
        config.matchAllInterruptibleCasts = false
    end

    config.prioritySpellIDs = config.prioritySpellIDs or {
        -- Hardcoded from wow-tools client spell exports.
        [22667] = true,   -- Shadow Command
        [152893] = true,  -- Solar Heal
        [313977] = true,  -- Curse of the Void
        [349141] = true,  -- Radiant Bolt
        [396812] = true,  -- Mystic Blast
        [441747] = true,  -- Dark Mending
        [1261326] = true, -- Necrotic Bolt
        [343154] = true,  -- Holy Wrath
        [323252] = true,  -- Raise Dead
    }

    config.priorityNpcSpellIDs = config.priorityNpcSpellIDs or {
        -- Most precise matching:
        -- [npcID] = {
        --     [spellID] = true,
        -- },
    }

    config.prioritySpellNames = config.prioritySpellNames or {
        -- "Death Curse" does not have an exact SpellName hit in the current wow-tools export.
        -- Leave it as a fallback name match until the authoritative client spell record is identified.
        ["Death Curse"] = true,
    }
    config.priorityNpcSpellNames = config.priorityNpcSpellNames or {
        ["Amani Blood Guard"] = {
            ["Blood Ritual"] = true,
        },
        ["Amani Hex Priest"] = {
            ["Hex of Nalorakk"] = true,
        },
        ["Amani Shaman"] = {
            ["Death Curse"] = true,
        },
        ["Amani Witch Doctors"] = {
            ["Hex"] = true,
        },
        ["Arakkoa Sun-Talon"] = {
            ["Flash Bang"] = true,
        },
        ["Arcane Golems"] = {
            ["Unstable Fission"] = true,
        },
        ["Arcane Ravager"] = {
            ["Arcane Missiles"] = true,
        },
        ["Arena Invoker"] = {
            ["Shadow Nova"] = true,
        },
        ["Blighted Crawler"] = {
            ["Plague Spit"] = true,
        },
        ["Blinding Channeler"] = {
            ["Blinding Surge"] = true,
        },
        ["Cave Shadowcaster"] = {
            ["Shadow Volley"] = true,
        },
        ["Creeping Spindleweb"] = {
            ["Poison Spray"] = true,
        },
        ["Crypt Necromancers"] = {
            ["Raise Dead"] = true,
        },
        ["Deathwhisper Necrolyte"] = {
            ["Shadow Bolt"] = true,
        },
        ["Derelict Channeler"] = {
            ["Shadow Bolt"] = true,
        },
        ["Fel Acolyte"] = {
            ["Shadow Mend"] = true,
        },
        ["Fel Crystal Channeler"] = {
            ["Fel Crystal Strike"] = true,
        },
        ["Fel Practitioner"] = {
            ["Fel Bolt"] = true,
        },
        ["Jungle Alchemist"] = {
            ["Poison Volley"] = true,
        },
        ["Light Zealot"] = {
            ["Radiant Bolt"] = true,
        },
        ["Necromantic Channeler"] = {
            ["Necrotic Bolt"] = true,
        },
        ["Nexus Corruptor"] = {
            ["Curse of the Void"] = true,
        },
        ["Plagueborn Horror"] = {
            ["Plague Blast"] = true,
        },
        ["Shadow Channelers"] = {
            ["Shadow Bolt Volley"] = true,
        },
        ["Shadowguard Caster"] = {
            ["Void Bolt"] = true,
        },
        ["Shadowguard Medics"] = {
            ["Dark Mending"] = true,
        },
        ["Shadowguard Officers"] = {
            ["Shadow Command"] = true,
        },
        ["Shadowguard Subjugator"] = {
            ["Void Bolt"] = true,
        },
        ["Skyreach Arcanist"] = {
            ["Arcane Bolt"] = true,
        },
        ["Solar Familiar"] = {
            ["Solar Heal"] = true,
        },
        ["Spellbound Sentry"] = {
            ["Arcane Salvo"] = true,
        },
        ["Sun Priests"] = {
            ["Holy Smite"] = true,
        },
        ["Sunblade Magister"] = {
            ["Arcane Nova"] = true,
        },
        ["Sunblade Warlock"] = {
            ["Mana Detonation"] = true,
        },
        ["Sunkiller Priests"] = {
            ["Holy Wrath"] = true,
        },
        ["Unruly Textbook"] = {
            ["Mystic Blast"] = true,
        },
        ["Void Champion"] = {
            ["Cosmic Bolt"] = true,
        },
        ["Void Channelers"] = {
            ["Void Bolt"] = true,
        },
        ["Void Memories"] = {
            ["Mind Flay"] = true,
        },
        ["Void Mender"] = {
            ["Shadow Mending"] = true,
        },
        ["Void Warden"] = {
            ["Suppression Field"] = true,
        },
        ["Wrathbone Coldwraith"] = {
            ["Frost Nova"] = true,
        },
    }

    modTable.interruptCandidates = modTable.interruptCandidates or {
        { spellID = 351338 }, -- Quell
        { spellID = 1766 },   -- Kick
        { spellID = 6552 },   -- Pummel
        { spellID = 2139 },   -- Counterspell
        { spellID = 57994 },  -- Wind Shear
        { spellID = 106839 }, -- Skull Bash
        { spellID = 78675 },  -- Solar Beam
        { spellID = 96231 },  -- Rebuke
        { spellID = 47528 },  -- Mind Freeze
        { spellID = 147362 }, -- Counter Shot
        { spellID = 187707 }, -- Muzzle
        { spellID = 183752 }, -- Disrupt
        { spellID = 116705 }, -- Spear Hand Strike
        { spellID = 15487 },  -- Silence
        { spellID = 119910, pet = true }, -- Spell Lock
        { spellID = 19647, pet = true },  -- Spell Lock
        { spellID = 89766, pet = true },  -- Axe Toss
        { spellID = 1276467 },            -- Grimoire: Fel Ravager
    }

    modTable.activePriorityCasts = modTable.activePriorityCasts or {}
    modTable.activePriorityCastCount = modTable.activePriorityCastCount or 0
    modTable.playerInterruptSpellID = modTable.playerInterruptSpellID or nil
    modTable.playerHasInterrupt = modTable.playerHasInterrupt or false
    modTable.playerInterruptResolved = modTable.playerInterruptResolved or false
    modTable.isRefreshing = false
    modTable.lastRefreshAt = 0
    modTable.interruptReadyCachedAt = 0
    modTable.interruptReadyCachedValue = nil
    modTable.interruptReadyCacheWindow = 0.05

    function modTable.ClampPercent(value)
        if type(value) ~= "number" then
            return 100
        end

        if value < 0 then
            return 0
        end

        if value > 100 then
            return 100
        end

        return value
    end

    function modTable.IsSecretValue(value)
        return issecretvalue and issecretvalue(value) or false
    end

    function modTable.GetSafeValue(value)
        if modTable.IsSecretValue(value) then
            return nil
        end

        return value
    end

    function modTable.GetSafeBoolean(value)
        if value == nil or modTable.IsSecretValue(value) then
            return nil
        end

        return value and true or false
    end

    function modTable.RefreshCachedConfig()
        modTable.dimAlpha = modTable.ClampPercent(config.dimOpacityPercent or 25) / 100
    end

    function modTable.ResetInterruptReadyCache()
        modTable.interruptReadyCachedAt = 0
        modTable.interruptReadyCachedValue = nil
    end

    function modTable.GetDimAlpha()
        return modTable.dimAlpha or 0.25
    end

    function modTable.GetShownPlates()
        return (C_NamePlate and C_NamePlate.GetNamePlates and C_NamePlate.GetNamePlates()) or {}
    end

    function modTable.GetUnitFrameFromPlate(plateFrame)
        if not plateFrame then
            return nil
        end

        return plateFrame.unitFrame or plateFrame.UnitFrame
    end

    function modTable.GetGuid(unitFrame)
        if not unitFrame then
            return nil
        end

        return unitFrame.namePlateUnitGUID
            or (unitFrame.PlateFrame and unitFrame.PlateFrame.namePlateUnitGUID)
    end

    function modTable.GetUnitKey(unitFrame)
        if not unitFrame then
            return nil
        end

        local guid = modTable.GetGuid(unitFrame)
        if guid and guid ~= "" then
            return guid
        end

        local unitToken = modTable.GetUnitToken(unitFrame)
        if unitToken and unitToken ~= "" then
            return unitToken
        end

        return unitFrame
    end

    function modTable.GetNpcID(unitFrame)
        if not unitFrame then
            return nil
        end

        local npcID = unitFrame.namePlateNpcId
        if npcID then
            return npcID
        end

        local guid = modTable.GetGuid(unitFrame)
        if guid and Plater and Plater.GetNpcIDFromGUID then
            return Plater.GetNpcIDFromGUID(guid)
        end

        return nil
    end

    function modTable.GetUnitToken(unitFrame)
        if not unitFrame then
            return nil
        end

        return unitFrame.namePlateUnitToken
            or unitFrame.displayedUnit
            or unitFrame.unit
    end

    function modTable.GetUnitDisplayName(unitFrame)
        if not unitFrame then
            return nil
        end

        local unitToken = modTable.GetUnitToken(unitFrame)
        if unitToken then
            return UnitName(unitToken)
        end

        return nil
    end

    function modTable.IsEnemyNpcUnitFrame(unitFrame)
        if not unitFrame or unitFrame.isPlayer then
            return false
        end

        local actorType = unitFrame.ActorType
            or unitFrame.actorType
            or (unitFrame.PlateFrame and unitFrame.PlateFrame.actorType)
        if actorType then
            return actorType == "enemynpc"
        end

        local unitToken = modTable.GetUnitToken(unitFrame)
        if not unitToken then
            return false
        end

        if UnitIsPlayer and UnitIsPlayer(unitToken) then
            return false
        end

        if UnitCanAttack then
            return UnitCanAttack("player", unitToken) or false
        end

        return false
    end

    function modTable.IsPrioritySpell(spellID, spellName, npcID, npcName)
        if config.matchAllInterruptibleCasts then
            return true
        end

        if spellID and config.prioritySpellIDs[spellID] then
            return true
        end

        if spellName and config.prioritySpellNames[spellName] then
            return true
        end

        if npcID and spellID then
            local npcSpells = config.priorityNpcSpellIDs[npcID]
            if npcSpells and npcSpells[spellID] then
                return true
            end
        end

        if npcName and spellName then
            local npcSpellNames = config.priorityNpcSpellNames[npcName]
            if npcSpellNames and npcSpellNames[spellName] then
                return true
            end
        end

        return false
    end

    function modTable.IsInterruptCandidateKnown(entry)
        if not entry or not entry.spellID then
            return false
        end

        if entry.pet then
            local petKnown = IsSpellKnown and IsSpellKnown(entry.spellID, true)
            if petKnown then
                return true
            end

            local playerKnown = IsPlayerSpell and IsPlayerSpell(entry.spellID)
            return playerKnown or false
        end

        local playerKnown = IsPlayerSpell and IsPlayerSpell(entry.spellID)
        if playerKnown then
            return true
        end

        local known = IsSpellKnown and IsSpellKnown(entry.spellID)
        return known or false
    end

    function modTable.RefreshPlayerInterrupt()
        modTable.playerInterruptSpellID = nil
        modTable.playerHasInterrupt = false
        modTable.playerInterruptResolved = true

        for _, entry in ipairs(modTable.interruptCandidates) do
            if modTable.IsInterruptCandidateKnown(entry) then
                modTable.playerInterruptSpellID = entry.spellID
                modTable.playerHasInterrupt = true
                modTable.ResetInterruptReadyCache()
                return entry.spellID
            end
        end

        modTable.ResetInterruptReadyCache()
        return nil
    end

    function modTable.PlayerMeetsInterruptRequirement()
        if not config.requireKnownInterrupt and not config.requireReadyInterrupt then
            return true
        end

        if not modTable.playerInterruptResolved then
            modTable.RefreshPlayerInterrupt()
        end

        if not modTable.playerHasInterrupt then
            return false
        end

        local interruptSpellID = modTable.playerInterruptSpellID

        if not config.requireReadyInterrupt then
            return true
        end

        local now = GetTime()
        if modTable.interruptReadyCachedValue ~= nil and (now - modTable.interruptReadyCachedAt) < modTable.interruptReadyCacheWindow then
            return modTable.interruptReadyCachedValue
        end

        if not C_Spell or not C_Spell.GetSpellCooldown then
            modTable.interruptReadyCachedAt = now
            modTable.interruptReadyCachedValue = false
            return false
        end

        local cooldownInfo = C_Spell.GetSpellCooldown(interruptSpellID)
        if not cooldownInfo then
            modTable.interruptReadyCachedAt = now
            modTable.interruptReadyCachedValue = false
            return false
        end

        local startTime = modTable.GetSafeValue(cooldownInfo.startTime)
        local duration = modTable.GetSafeValue(cooldownInfo.duration)
        if type(startTime) ~= "number" or type(duration) ~= "number" then
            modTable.interruptReadyCachedAt = now
            modTable.interruptReadyCachedValue = false
            return false
        end

        local isReady = duration <= 0 or (startTime + duration) <= now
        modTable.interruptReadyCachedAt = now
        modTable.interruptReadyCachedValue = isReady
        return isReady
    end

    function modTable.IsInterruptibleCastBar(castBar)
        if not castBar then
            return false
        end

        local isInterrupted = modTable.GetSafeBoolean(castBar.IsInterrupted)
        if isInterrupted == true then
            return false
        end

        local canInterrupt = modTable.GetSafeBoolean(castBar.CanInterrupt)
        if canInterrupt ~= nil then
            return canInterrupt
        end

        local notInterruptible = modTable.GetSafeBoolean(castBar.notInterruptible)
        if notInterruptible ~= nil then
            return not notInterruptible
        end

        local borderShield = castBar.BorderShield
        if borderShield and borderShield.GetAlpha then
            local shieldAlpha = modTable.GetSafeValue(borderShield:GetAlpha())
            if type(shieldAlpha) == "number" then
                return shieldAlpha < 0.5
            end
        end

        -- On Midnight, Plater can expose interruptibility as a secret value.
        -- In "match all" mode, prefer dimming on any visible cast over failing closed.
        if config.matchAllInterruptibleCasts then
            return true
        end

        return false
    end

    function modTable.UnitHasPriorityInterruptibleCast(unitFrame, castBar, includeOffscreen)
        if not unitFrame then
            return false
        end

        if not includeOffscreen and not unitFrame.PlaterOnScreen then
            return false
        end

        if not modTable.IsEnemyNpcUnitFrame(unitFrame) then
            return false
        end

        castBar = castBar or unitFrame.castBar
        if not castBar then
            return false
        end

        local isCasting = modTable.GetSafeBoolean(castBar.casting)
        local isChanneling = modTable.GetSafeBoolean(castBar.channeling)
        if isCasting ~= true and isChanneling ~= true then
            return false
        end

        if not modTable.IsInterruptibleCastBar(castBar) then
            return false
        end

        if not modTable.PlayerMeetsInterruptRequirement() then
            return false
        end

        local spellID = modTable.GetSafeValue(castBar.SpellID or castBar.spellID)
        local spellName = modTable.GetSafeValue(castBar.SpellName or castBar.spellName)

        if modTable.IsPrioritySpell(spellID, spellName, nil, nil) then
            return true
        end

        local npcID = modTable.GetSafeValue(modTable.GetNpcID(unitFrame))
        local npcName = modTable.GetSafeValue(modTable.GetUnitDisplayName(unitFrame))

        return modTable.IsPrioritySpell(spellID, spellName, npcID, npcName)
    end

    function modTable.SetUnitPriorityCastState(unitFrame, isActive)
        local unitKey = modTable.GetUnitKey(unitFrame)
        if not unitKey then
            return false, modTable.activePriorityCastCount > 0, modTable.activePriorityCastCount > 0
        end

        local hadAny = modTable.activePriorityCastCount > 0
        local hadState = modTable.activePriorityCasts[unitKey] and true or false
        if isActive then
            modTable.activePriorityCasts[unitKey] = true
        else
            modTable.activePriorityCasts[unitKey] = nil
        end

        if hadState ~= isActive then
            if isActive then
                modTable.activePriorityCastCount = modTable.activePriorityCastCount + 1
            elseif modTable.activePriorityCastCount > 0 then
                modTable.activePriorityCastCount = modTable.activePriorityCastCount - 1
            end
        end

        return hadState ~= isActive, hadAny, modTable.activePriorityCastCount > 0
    end

    function modTable.UpdateUnitPriorityCastState(unitFrame, castBar, includeOffscreen)
        local isActive = modTable.UnitHasPriorityInterruptibleCast(unitFrame, castBar, includeOffscreen)
        local stateChanged, hadAny, hasAny = modTable.SetUnitPriorityCastState(unitFrame, isActive)
        return stateChanged, isActive, hadAny, hasAny
    end

    function modTable.MapsEqual(left, right)
        for key in pairs(left) do
            if not right[key] then
                return false
            end
        end

        for key in pairs(right) do
            if not left[key] then
                return false
            end
        end

        return true
    end

    function modTable.RebuildActivePriorityCasts()
        local updated = {}

        for _, plateFrame in ipairs(modTable.GetShownPlates()) do
            local unitFrame = modTable.GetUnitFrameFromPlate(plateFrame)
            if modTable.UnitHasPriorityInterruptibleCast(unitFrame, nil, true) then
                local unitKey = modTable.GetUnitKey(unitFrame)
                if unitKey then
                    updated[unitKey] = true
                end
            end
        end

        local changed = not modTable.MapsEqual(modTable.activePriorityCasts, updated)
        modTable.activePriorityCasts = updated
        modTable.activePriorityCastCount = 0
        for _ in pairs(updated) do
            modTable.activePriorityCastCount = modTable.activePriorityCastCount + 1
        end
        return changed
    end

    function modTable.HasActivePriorityCast()
        return modTable.activePriorityCastCount > 0
    end

    function modTable.ClearAppliedAlphaCache()
        for _, plateFrame in ipairs(modTable.GetShownPlates()) do
            local unitFrame = modTable.GetUnitFrameFromPlate(plateFrame)
            if unitFrame then
                unitFrame.__medaAppliedDimmerAlpha = nil
            end
        end
    end

    function modTable.RestoreBasePlaterAlpha()
        if modTable.isRefreshing then
            return
        end

        if not Plater or not Plater.UpdateAllPlates then
            return
        end

        modTable.isRefreshing = true
        modTable.ClearAppliedAlphaCache()
        Plater.UpdateAllPlates()
        modTable.isRefreshing = false
    end

    function modTable.ApplyAlphaToUnitFrame(unitFrame)
        if not unitFrame or not unitFrame.PlaterOnScreen then
            return
        end

        if not modTable.IsEnemyNpcUnitFrame(unitFrame) then
            return
        end

        if not modTable.HasActivePriorityCast() then
            return
        end

        local unitKey = modTable.GetUnitKey(unitFrame)
        local targetAlpha
        if unitKey and modTable.activePriorityCasts[unitKey] then
            targetAlpha = 1
        else
            targetAlpha = modTable.GetDimAlpha()
        end

        if unitFrame.__medaAppliedDimmerAlpha ~= targetAlpha then
            unitFrame:SetAlpha(targetAlpha)
            unitFrame.__medaAppliedDimmerAlpha = targetAlpha
        end
    end

    function modTable.ApplyAlphaToAllShownPlates()
        if not modTable.HasActivePriorityCast() then
            return
        end

        for _, plateFrame in ipairs(modTable.GetShownPlates()) do
            local unitFrame = modTable.GetUnitFrameFromPlate(plateFrame)
            modTable.ApplyAlphaToUnitFrame(unitFrame)
        end
    end

    function modTable.ApplyCurrentAlphaState(forceRestore)
        if forceRestore or not modTable.HasActivePriorityCast() then
            modTable.RestoreBasePlaterAlpha()
        end

        if modTable.HasActivePriorityCast() then
            modTable.ApplyAlphaToAllShownPlates()
        end
    end

    function modTable.RefreshAll(force)
        if modTable.isRefreshing then
            return
        end

        local now = GetTime()
        if not force and (now - (modTable.lastRefreshAt or 0)) < 0.05 then
            return
        end

        modTable.lastRefreshAt = now

        local stateChanged = modTable.RebuildActivePriorityCasts()
        modTable.ApplyCurrentAlphaState(force or stateChanged)
    end

    modTable.RefreshCachedConfig()
    modTable.RefreshPlayerInterrupt()
    modTable.RefreshAll(true)
end

-- =====================================================================
-- Nameplate Added
-- =====================================================================
function(self, unitId, unitFrame, envTable, modTable)
    local changed, _, hadAny, hasAny = modTable.UpdateUnitPriorityCastState(unitFrame, unitFrame and unitFrame.castBar, true)
    if changed and hadAny and not hasAny then
        modTable.ApplyCurrentAlphaState(true)
    elseif hasAny then
        if hadAny then
            modTable.ApplyAlphaToUnitFrame(unitFrame)
        else
            modTable.ApplyAlphaToAllShownPlates()
        end
    end
end

-- =====================================================================
-- Nameplate Removed
-- =====================================================================
function(self, unitId, unitFrame, envTable, modTable)
    local changed, hadAny, hasAny = modTable.SetUnitPriorityCastState(unitFrame, false)
    if changed and hadAny and not hasAny then
        modTable.ApplyCurrentAlphaState(true)
    end
end

-- =====================================================================
-- Nameplate Updated
-- =====================================================================
function(self, unitId, unitFrame, envTable, modTable)
    if modTable.isRefreshing then
        return
    end

    local changed, isActive, hadAny, hasAny = modTable.UpdateUnitPriorityCastState(unitFrame, unitFrame and unitFrame.castBar, true)
    if changed and hadAny and not hasAny then
        modTable.ApplyCurrentAlphaState(true)
        return
    end

    if hasAny then
        if changed and not hadAny then
            modTable.ApplyAlphaToAllShownPlates()
            return
        end

        if changed or isActive then
            modTable.ApplyAlphaToUnitFrame(unitFrame)
        end
    end
end

-- =====================================================================
-- Cast Start
-- =====================================================================
function(self, unitId, unitFrame, envTable, modTable)
    local changed, _, hadAny, hasAny = modTable.UpdateUnitPriorityCastState(unitFrame, self, true)
    if changed and hadAny and not hasAny then
        modTable.ApplyCurrentAlphaState(true)
    elseif hasAny then
        if hadAny then
            modTable.ApplyAlphaToUnitFrame(unitFrame)
        else
            modTable.ApplyAlphaToAllShownPlates()
        end
    end
end

-- =====================================================================
-- Cast Update
-- =====================================================================
function(self, unitId, unitFrame, envTable, modTable)
    local changed, isActive, hadAny, hasAny = modTable.UpdateUnitPriorityCastState(unitFrame, self, true)
    if changed and hadAny and not hasAny then
        modTable.ApplyCurrentAlphaState(true)
    elseif hasAny then
        if changed then
            if hadAny then
                modTable.ApplyAlphaToUnitFrame(unitFrame)
            else
                modTable.ApplyAlphaToAllShownPlates()
            end
            return
        end

        if isActive then
            modTable.ApplyAlphaToUnitFrame(unitFrame)
        end
    end
end

-- =====================================================================
-- Cast Stop
-- =====================================================================
function(self, unitId, unitFrame, envTable, modTable)
    local changed, hadAny, hasAny = modTable.SetUnitPriorityCastState(unitFrame, false)
    if changed and hadAny and not hasAny then
        modTable.ApplyCurrentAlphaState(true)
    elseif hasAny then
        modTable.ApplyAlphaToUnitFrame(unitFrame)
    end
end

-- =====================================================================
-- Player Talent Update
-- =====================================================================
function(self, unitId, unitFrame, envTable, modTable)
    modTable.RefreshCachedConfig()
    modTable.RefreshPlayerInterrupt()
    modTable.RefreshAll(true)
end

-- =====================================================================
-- Mod Option Changed
-- =====================================================================
function(modTable)
    modTable.RefreshCachedConfig()
    modTable.RefreshPlayerInterrupt()
    modTable.RefreshAll(true)
end
