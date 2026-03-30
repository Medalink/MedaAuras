-- Priority Kick Dimmer for Plater
--
-- Purpose:
-- Dim every enemy nameplate except mobs currently casting a tracked spell.
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
--    - Number: Name "Cast Dim Opacity", Key "dimOpacityPercent", Min 0, Max 100, Fraction false, Value 25
--    - Toggle: Name "Trigger On Focus Target Casts", Key "matchFocusTargetCasts", Value false
--    - Toggle: Name "Match Any Enemy Cast (Fallback)", Key "matchAnyEnemyCasts", Value false
--    - Toggle: Name "Match All Interruptible Casts", Key "matchAllInterruptibleCasts", Value false
--    - Toggle: Name "Require Known Interrupt", Key "requireKnownInterrupt", Value false
--    - Toggle: Name "Require Ready Interrupt", Key "requireReadyInterrupt", Value false
--
-- Notes:
-- - The logic hard-filters itself to enemy NPC plates.
-- - Use spell IDs whenever you can. They are more reliable than names.
-- - The shipped starter defaults now use hardcoded client spell IDs pulled from wow-tools exports.
-- - "Death Curse" remains a fallback name match because it was not present as an exact SpellName row in the current export.
-- - dimOpacityPercent is the final alpha for non-priority plates during a tracked cast:
--   0 = invisible, 100 = fully opaque.

-- =====================================================================
-- Initialization
-- =====================================================================
function(modTable)
    local ipairs = ipairs
    local pairs = pairs
    local math_abs = math.abs
    local GetTime = GetTime
    local UnitName = UnitName
    local UnitCanAttack = UnitCanAttack
    local UnitIsPlayer = UnitIsPlayer
    local UnitIsUnit = UnitIsUnit
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

    if config.matchAnyEnemyCasts == nil then
        config.matchAnyEnemyCasts = false
    end

    if config.matchFocusTargetCasts == nil then
        config.matchFocusTargetCasts = false
    end

    if config.debugEnabled == nil then
        config.debugEnabled = false
    end

    if config.debugSuccesses == nil then
        config.debugSuccesses = false
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

    modTable.activePriorityCastCount = modTable.activePriorityCastCount or 0
    modTable.playerInterruptSpellID = modTable.playerInterruptSpellID or nil
    modTable.playerHasInterrupt = modTable.playerHasInterrupt or false
    modTable.playerInterruptResolved = modTable.playerInterruptResolved or false
    modTable.isRefreshing = false
    modTable.lastRefreshAt = 0
    modTable.interruptReadyCachedAt = 0
    modTable.interruptReadyCachedValue = nil
    modTable.interruptReadyCacheWindow = 0.10
    modTable.debugThrottleSeconds = 2
    modTable.debugLastByKey = modTable.debugLastByKey or {}
    modTable.secretMatchBar = modTable.secretMatchBar or nil
    modTable.secretMatchDidChange = false
    modTable.secretNumberBar = modTable.secretNumberBar or nil
    modTable.secretNumberSlider = modTable.secretNumberSlider or nil
    modTable.secretNumberValue = nil
    modTable.secretNumberInit = modTable.secretNumberInit or false
    modTable.prioritySpellIDList = modTable.prioritySpellIDList or {}

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
        modTable.modeFocusCasts = config.matchFocusTargetCasts == true
        modTable.modeAnyEnemyCasts = config.matchAnyEnemyCasts == true
        modTable.modeAllInterruptible = config.matchAllInterruptibleCasts == true
        modTable.priorityModeEnabled = not modTable.modeAnyEnemyCasts and not modTable.modeAllInterruptible
        modTable.hasPrioritySpellNameFallback = next(config.prioritySpellNames or {}) ~= nil
        modTable.hasPriorityNpcSpellIDs = next(config.priorityNpcSpellIDs or {}) ~= nil
        modTable.hasPriorityNpcSpellNames = next(config.priorityNpcSpellNames or {}) ~= nil

        local spellIDs = {}
        for spellID in pairs(config.prioritySpellIDs or {}) do
            spellIDs[#spellIDs + 1] = spellID
        end
        modTable.prioritySpellIDList = spellIDs
    end

    function modTable.ResetInterruptReadyCache()
        modTable.interruptReadyCachedAt = 0
        modTable.interruptReadyCachedValue = nil
    end

    function modTable.GetDimAlpha()
        return modTable.dimAlpha or 0.25
    end

    function modTable.GetFrameAlpha(frame)
        if frame and frame.GetAlpha then
            local alpha = modTable.GetSafeValue(frame:GetAlpha())
            if type(alpha) == "number" then
                return alpha
            end
        end

        return nil
    end

    function modTable.AlphaNeedsUpdate(frame, targetAlpha)
        local currentAlpha = modTable.GetFrameAlpha(frame)
        if type(currentAlpha) ~= "number" then
            return true, currentAlpha
        end

        return math_abs(currentAlpha - targetAlpha) > 0.01, currentAlpha
    end

    function modTable.ApplyFrameAlpha(frame, targetAlpha)
        if not frame or not frame.SetAlpha then
            return false, nil
        end

        local needsUpdate, currentAlpha = modTable.AlphaNeedsUpdate(frame, targetAlpha)
        if needsUpdate or frame.__medaAppliedDimmerAlpha ~= targetAlpha then
            frame:SetAlpha(targetAlpha)
            frame.__medaAppliedDimmerAlpha = targetAlpha
            return true, currentAlpha
        end

        return false, currentAlpha
    end

    function modTable.ClearFrameAlphaCache(frame)
        if frame then
            frame.__medaAppliedDimmerAlpha = nil
        end
    end

    function modTable.ClearAlphaCacheForUnitFrame(unitFrame)
        if not unitFrame then
            return
        end

        local healthBar = unitFrame.healthBar
        modTable.ClearFrameAlphaCache(unitFrame)
        modTable.ClearFrameAlphaCache(healthBar)
        modTable.ClearFrameAlphaCache(unitFrame.castBar)
        modTable.ClearFrameAlphaCache(unitFrame.powerBar)
        modTable.ClearFrameAlphaCache(unitFrame.BuffFrame)
        modTable.ClearFrameAlphaCache(unitFrame.BuffFrame2)
        modTable.ClearFrameAlphaCache(unitFrame.unitName or (healthBar and healthBar.unitName))
        modTable.ClearFrameAlphaCache(unitFrame.ExtraIconFrame)
        modTable.ClearFrameAlphaCache(unitFrame.PlaterRaidTargetFrame)
    end

    function modTable.EnsureSecretMatchBar()
        if modTable.secretMatchBar then
            return modTable.secretMatchBar
        end

        local bar = CreateFrame("StatusBar")
        if not bar then
            return nil
        end

        bar:SetMinMaxValues(0, 9999999)
        bar:SetValue(0)
        bar:SetScript("OnValueChanged", function()
            modTable.secretMatchDidChange = true
        end)

        modTable.secretMatchBar = bar
        return bar
    end

    function modTable.MatchSecretNumber(secretValue, knownValue)
        if type(secretValue) == "number" and not modTable.IsSecretValue(secretValue) then
            return secretValue == knownValue
        end

        if secretValue == nil or type(knownValue) ~= "number" or not pcall then
            return nil
        end

        local bar = modTable.EnsureSecretMatchBar()
        if not bar then
            return nil
        end

        bar:SetMinMaxValues(knownValue, knownValue + 1)
        bar:SetValue(knownValue + 1)
        modTable.secretMatchDidChange = false
        local ok1 = pcall(bar.SetValue, bar, secretValue)
        if not ok1 or not modTable.secretMatchDidChange then
            return false
        end

        bar:SetMinMaxValues(knownValue - 1, knownValue)
        bar:SetValue(knownValue - 1)
        modTable.secretMatchDidChange = false
        local ok2 = pcall(bar.SetValue, bar, secretValue)
        if not ok2 then
            return nil
        end

        if not modTable.secretMatchDidChange then
            return false
        end

        bar:SetMinMaxValues(knownValue + 1, knownValue + 2)
        bar:SetValue(knownValue + 2)
        modTable.secretMatchDidChange = false
        local ok3 = pcall(bar.SetValue, bar, secretValue)
        if not ok3 then
            return nil
        end

        return modTable.secretMatchDidChange ~= true
    end

    function modTable.EnsureSecretNumberBar()
        if modTable.secretNumberInit then
            return modTable.secretNumberBar, modTable.secretNumberSlider
        end

        modTable.secretNumberInit = true

        local bar = CreateFrame("StatusBar")
        if bar then
            bar:SetMinMaxValues(0, 9999999)
            bar:SetValue(0)
            bar:SetScript("OnValueChanged", function(_, value)
                modTable.secretNumberValue = value
            end)
        end

        local slider = CreateFrame("Slider", nil, UIParent)
        if slider then
            slider:SetMinMaxValues(0, 9999999)
            slider:SetValue(0)
            slider:SetSize(1, 1)
            slider:Hide()
            slider:SetScript("OnValueChanged", function(_, value)
                modTable.secretNumberValue = value
            end)
        end

        modTable.secretNumberBar = bar
        modTable.secretNumberSlider = slider
        return bar, slider
    end

    function modTable.LaunderNumber(value, minValue, maxValue)
        if type(value) == "number" and not modTable.IsSecretValue(value) then
            return value
        end

        if value == nil then
            return nil
        end

        local bar, slider = modTable.EnsureSecretNumberBar()
        if (not bar and not slider) or not pcall then
            return nil
        end

        minValue = minValue or 0
        maxValue = maxValue or 9999999

        if bar then
            modTable.secretNumberValue = nil
            bar:SetMinMaxValues(minValue, maxValue)
            bar:SetValue(minValue)

            local ok = pcall(bar.SetValue, bar, value)
            if ok and type(modTable.secretNumberValue) == "number" then
                return modTable.secretNumberValue
            end
        end

        if slider then
            modTable.secretNumberValue = nil
            slider:SetMinMaxValues(minValue, maxValue)
            slider:SetValue(minValue)

            local ok = pcall(slider.SetValue, slider, value)
            if ok and type(modTable.secretNumberValue) == "number" then
                return modTable.secretNumberValue
            end
        end

        return nil
    end

    function modTable.LaunderSecretBoolean(value)
        if type(value) == "boolean" and not modTable.IsSecretValue(value) then
            return value
        end

        if value == nil or not C_CurveUtil or not C_CurveUtil.EvaluateColorValueFromBoolean or not pcall then
            return nil
        end

        local ok, numericValue = pcall(C_CurveUtil.EvaluateColorValueFromBoolean, value, 1, 0)
        if not ok then
            return nil
        end

        local cleanNumeric = modTable.LaunderNumber(numericValue, 0, 1)
        if type(cleanNumeric) == "number" then
            return cleanNumeric >= 0.5
        end

        return nil
    end

    function modTable.ResolveSecretBoolean(value)
        local cleanValue = modTable.GetSafeBoolean(value)
        if cleanValue ~= nil then
            return cleanValue, "safe"
        end

        cleanValue = modTable.LaunderSecretBoolean(value)
        if cleanValue ~= nil then
            return cleanValue, "launder"
        end

        if value ~= nil and C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean and pcall then
            local ok, numericValue = pcall(C_CurveUtil.EvaluateColorValueFromBoolean, value, 1, 0)
            if ok then
                if modTable.MatchSecretNumber(numericValue, 1) then
                    return true, "curve-match-1"
                elseif modTable.MatchSecretNumber(numericValue, 0) then
                    return false, "curve-match-0"
                end
            end
        end

        return nil, nil
    end

    function modTable.ClearCastRuntimeCache(castBar)
        if not castBar then
            return
        end

        castBar.__medaCachedInterruptible = nil
        castBar.__medaCachedInterruptibleResolved = nil
        castBar.__medaCachedSpellID = nil
        castBar.__medaCachedSpellIDResolved = nil
        castBar.__medaMatchedPrioritySpellID = nil
        castBar.__medaMatchedPrioritySpellIDResolved = nil
    end

    function modTable.GetCleanSpellID(castBar, envTable)
        if castBar and castBar.__medaCachedSpellIDResolved then
            return castBar.__medaCachedSpellID
        end

        local rawSpellID = nil
        if envTable then
            rawSpellID = envTable._SpellID
        elseif castBar then
            rawSpellID = castBar.SpellID
        end

        local spellID = modTable.GetSafeValue(rawSpellID)
        if type(spellID) ~= "number" then
            spellID = modTable.LaunderNumber(rawSpellID, 0, 9999999)
        end

        if castBar then
            castBar.__medaCachedSpellID = spellID
            castBar.__medaCachedSpellIDResolved = true
        end

        return spellID
    end

    function modTable.GetRawSpellID(castBar, envTable)
        if envTable then
            return envTable._SpellID
        end

        if castBar then
            return castBar.SpellID
        end

        return nil
    end

    function modTable.GetMatchedPrioritySpellID(castBar, envTable)
        if castBar and castBar.__medaMatchedPrioritySpellIDResolved then
            return castBar.__medaMatchedPrioritySpellID
        end

        local cleanSpellID = modTable.GetCleanSpellID(castBar, envTable)
        if type(cleanSpellID) == "number" and config.prioritySpellIDs[cleanSpellID] then
            if castBar then
                castBar.__medaMatchedPrioritySpellID = cleanSpellID
                castBar.__medaMatchedPrioritySpellIDResolved = true
            end
            return cleanSpellID
        end

        local rawSpellID = modTable.GetRawSpellID(castBar, envTable)
        for i = 1, #modTable.prioritySpellIDList do
            local knownSpellID = modTable.prioritySpellIDList[i]
            local didMatch = modTable.MatchSecretNumber(rawSpellID, knownSpellID)
            if didMatch == true then
                if castBar then
                    castBar.__medaMatchedPrioritySpellID = knownSpellID
                    castBar.__medaMatchedPrioritySpellIDResolved = true
                end
                return knownSpellID
            end
        end

        if castBar then
            castBar.__medaMatchedPrioritySpellID = nil
            castBar.__medaMatchedPrioritySpellIDResolved = true
        end

        return nil
    end

    function modTable.GetStatusBarColor(statusBar)
        if not statusBar then
            return nil
        end

        if statusBar.GetCastColor then
            local castColor = statusBar:GetCastColor()
            if castColor then
                local r = modTable.GetSafeValue(castColor.r)
                local g = modTable.GetSafeValue(castColor.g)
                local b = modTable.GetSafeValue(castColor.b)
                local a = modTable.GetSafeValue(castColor.a)
                if type(r) == "number" and type(g) == "number" and type(b) == "number" then
                    return r, g, b, a, "GetCastColor"
                end
            end
        end

        if statusBar.GetStatusBarColor then
            local r, g, b, a = statusBar:GetStatusBarColor()
            r = modTable.GetSafeValue(r)
            g = modTable.GetSafeValue(g)
            b = modTable.GetSafeValue(b)
            a = modTable.GetSafeValue(a)
            if type(r) == "number" and type(g) == "number" and type(b) == "number" then
                return r, g, b, a, "GetStatusBarColor"
            end
        end

        local texture = statusBar.GetStatusBarTexture and statusBar:GetStatusBarTexture()
        if texture and texture.GetVertexColor then
            local r, g, b, a = texture:GetVertexColor()
            r = modTable.GetSafeValue(r)
            g = modTable.GetSafeValue(g)
            b = modTable.GetSafeValue(b)
            a = modTable.GetSafeValue(a)
            if type(r) == "number" and type(g) == "number" and type(b) == "number" then
                return r, g, b, a, "StatusBarTexture"
            end
        end

        return nil
    end

    function modTable.GetConfiguredNonInterruptibleColor(castBar)
        local colors = castBar and castBar.Colors
        local color = colors and colors.NonInterruptible
        if not color then
            return nil
        end

        local r = modTable.GetSafeValue(color.r)
        local g = modTable.GetSafeValue(color.g)
        local b = modTable.GetSafeValue(color.b)
        local a = modTable.GetSafeValue(color.a)
        if type(r) == "number" and type(g) == "number" and type(b) == "number" then
            return r, g, b, a
        end

        return nil
    end

    function modTable.AreColorsClose(r1, g1, b1, r2, g2, b2, threshold)
        threshold = threshold or 0.12
        return math_abs(r1 - r2) + math_abs(g1 - g2) + math_abs(b1 - b2) <= threshold
    end

    function modTable.GetCastBarColorDebugText(castBar)
        local currentR, currentG, currentB, _, colorSource = modTable.GetStatusBarColor(castBar)
        local niR, niG, niB = modTable.GetConfiguredNonInterruptibleColor(castBar)
        return " colorSource="
            .. modTable.SafeText(colorSource)
            .. " castColor="
            .. modTable.SafeText(currentR) .. "," .. modTable.SafeText(currentG) .. "," .. modTable.SafeText(currentB)
            .. " nonInterruptibleColor="
            .. modTable.SafeText(niR) .. "," .. modTable.SafeText(niG) .. "," .. modTable.SafeText(niB)
    end

    function modTable.GetInterruptDebugText(castBar, envTable)
        local rawCanInterrupt = nil
        if envTable then
            rawCanInterrupt = envTable._CanInterrupt
        elseif castBar then
            rawCanInterrupt = castBar.CanInterrupt
        end

        local cleanCanInterrupt, canInterruptSource = modTable.ResolveSecretBoolean(rawCanInterrupt)

        local rawNotInterruptible = nil
        if envTable then
            rawNotInterruptible = envTable._CannotInterrupt
        elseif castBar then
            rawNotInterruptible = castBar.notInterruptible
        end

        local cleanNotInterruptible, notInterruptibleSource = modTable.ResolveSecretBoolean(rawNotInterruptible)

        local spellID = modTable.GetMatchedPrioritySpellID(castBar, envTable) or modTable.GetCleanSpellID(castBar, envTable)
        return " nativeSecretLaunder=true"
            .. " cleanSpellID=" .. modTable.SafeText(spellID)
            .. " cleanCanInterrupt=" .. modTable.SafeText(cleanCanInterrupt)
            .. " canInterruptSource=" .. modTable.SafeText(canInterruptSource)
            .. " cleanNotInterruptible=" .. modTable.SafeText(cleanNotInterruptible)
            .. " notInterruptibleSource=" .. modTable.SafeText(notInterruptibleSource)
            .. modTable.GetCastBarColorDebugText(castBar)
    end

    function modTable.SafeText(value)
        local valueType = type(value)
        if value == nil then
            return "nil"
        end

        if valueType == "string" then
            return value
        end

        if valueType == "number" then
            return tostring(value)
        end

        if valueType == "boolean" then
            return value and "true" or "false"
        end

        return valueType
    end

    function modTable.BuildDebugKey(source, reason, unitFrame, spellID, spellName)
        local unitKey = modTable.GetUnitKey(unitFrame)
        return (source or "?")
            .. "|"
            .. (reason or "?")
            .. "|"
            .. modTable.SafeText(unitKey)
            .. "|"
            .. modTable.SafeText(spellID or spellName)
    end

    function modTable.DebugLog(source, reason, unitFrame, castBar, spellID, spellName, extra)
        if not config.debugEnabled then
            return
        end

        local now = GetTime()
        local debugKey = modTable.BuildDebugKey(source, reason, unitFrame, spellID, spellName)
        local lastAt = modTable.debugLastByKey[debugKey]
        if lastAt and (now - lastAt) < modTable.debugThrottleSeconds then
            return
        end

        modTable.debugLastByKey[debugKey] = now

        local unitToken = modTable.GetUnitToken(unitFrame)
        local npcName = modTable.GetSafeValue(modTable.GetUnitDisplayName(unitFrame))
        local actorType = unitFrame and (unitFrame.ActorType or unitFrame.actorType or (unitFrame.PlateFrame and unitFrame.PlateFrame.actorType)) or nil
        local message = "[PrioDimmer] "
            .. modTable.SafeText(source)
            .. " "
            .. modTable.SafeText(reason)
            .. " unit="
            .. modTable.SafeText(unitToken)
            .. " actor="
            .. modTable.SafeText(actorType)
            .. " npc="
            .. modTable.SafeText(npcName)
            .. " spellID="
            .. modTable.SafeText(spellID)
            .. " spell="
            .. modTable.SafeText(spellName)

        if extra and extra ~= "" then
            message = message .. " " .. extra
        end

        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage(message)
        end
    end

    function modTable.ShouldDebugLog(isActive, reason, unitFrame, castBar, debugSource, stateChanged)
        if not config.debugEnabled then
            return false
        end

        if isActive then
            return config.debugSuccesses
        end

        if reason == "fail:no_unit" or reason == "fail:offscreen" then
            return false
        end

        if reason == "fail:not_enemy_npc" then
            return debugSource == "Cast Start" or debugSource == "Cast Update"
        end

        local isCasting = castBar and modTable.GetSafeBoolean(castBar.casting)
        local isChanneling = castBar and modTable.GetSafeBoolean(castBar.channeling)
        local hasVisibleCast = isCasting == true or isChanneling == true

        if (debugSource == "Nameplate Added" or debugSource == "Nameplate Updated") and not hasVisibleCast and not stateChanged then
            return false
        end

        if reason == "fail:no_castbar" or reason == "fail:not_casting" then
            return debugSource == "Cast Start" or debugSource == "Cast Update"
        end

        return true
    end

    function modTable.DebugAlphaSweep(shownCount, enemyNpcCount, activeCasterCount, dimmedCount, changedCount, targetAlpha)
        if not config.debugEnabled then
            return
        end

        local now = GetTime()
        local debugKey = "AlphaSweep|" .. modTable.SafeText(activeCasterCount) .. "|" .. modTable.SafeText(targetAlpha)
        local lastAt = modTable.debugLastByKey[debugKey]
        if lastAt and (now - lastAt) < modTable.debugThrottleSeconds then
            return
        end

        modTable.debugLastByKey[debugKey] = now

        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage(
                "[PrioDimmer] AlphaSweep shown="
                    .. modTable.SafeText(shownCount)
                    .. " enemyNpc="
                    .. modTable.SafeText(enemyNpcCount)
                    .. " activeCasters="
                    .. modTable.SafeText(activeCasterCount)
                    .. " dimmed="
                    .. modTable.SafeText(dimmedCount)
                    .. " changed="
                    .. modTable.SafeText(changedCount)
                    .. " targetAlpha="
                    .. modTable.SafeText(targetAlpha)
            )
        end
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

        local guid = unitFrame.namePlateUnitGUID
            or (unitFrame.PlateFrame and unitFrame.PlateFrame.namePlateUnitGUID)
        guid = modTable.GetSafeValue(guid)
        if type(guid) == "string" and guid ~= "" then
            return guid
        end

        return nil
    end

    function modTable.GetUnitKey(unitFrame)
        if not unitFrame then
            return nil
        end

        local guid = modTable.GetGuid(unitFrame)
        if guid then
            return guid
        end

        local unitToken = modTable.GetSafeValue(modTable.GetUnitToken(unitFrame))
        if type(unitToken) == "string" and unitToken ~= "" then
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
        if type(guid) == "string" and Plater and Plater.GetNpcIDFromGUID then
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

        local unitToken = modTable.GetSafeValue(modTable.GetUnitToken(unitFrame))
        if type(unitToken) ~= "string" or unitToken == "" then
            return nil
        end

        if unitFrame.__medaCachedUnitNameToken == unitToken then
            return unitFrame.__medaCachedUnitName
        end

        local unitName = UnitName(unitToken)
        unitName = modTable.GetSafeValue(unitName)
        if type(unitName) == "string" then
            unitFrame.__medaCachedUnitNameToken = unitToken
            unitFrame.__medaCachedUnitName = unitName
            return unitName
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

    function modTable.IsFocusTargetUnitFrame(unitFrame)
        if not unitFrame then
            return false
        end

        local unitToken = modTable.GetSafeValue(modTable.GetUnitToken(unitFrame))
        if type(unitToken) ~= "string" or unitToken == "" then
            return false
        end

        if unitToken == "focus" then
            return true
        end

        local now = GetTime()
        if unitFrame.__medaFocusCheckToken == unitToken and unitFrame.__medaFocusCheckAt and (now - unitFrame.__medaFocusCheckAt) < 0.05 then
            return unitFrame.__medaIsFocusTarget == true
        end

        if not UnitIsUnit or not pcall then
            return false
        end

        local ok, isFocus = pcall(UnitIsUnit, unitToken, "focus")
        if not ok then
            return false
        end

        unitFrame.__medaFocusCheckToken = unitToken
        unitFrame.__medaFocusCheckAt = now
        unitFrame.__medaIsFocusTarget = isFocus == true
        return unitFrame.__medaIsFocusTarget
    end

    function modTable.IsPrioritySpell(spellID, spellName, npcID, npcName)
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

    function modTable.GetPriorityMatchReason(spellID, spellName, npcID, npcName)
        if spellID and config.prioritySpellIDs[spellID] then
            return "pass:spell_match"
        end

        if spellName and config.prioritySpellNames[spellName] then
            return "pass:spell_match"
        end

        if npcID and spellID then
            local npcSpells = config.priorityNpcSpellIDs[npcID]
            if npcSpells and npcSpells[spellID] then
                return "pass:npc_spell_match"
            end
        end

        if npcName and spellName then
            local npcSpellNames = config.priorityNpcSpellNames[npcName]
            if npcSpellNames and npcSpellNames[spellName] then
                return "pass:npc_spell_match"
            end
        end

        return nil
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

    function modTable.IsInterruptibleCastBar(castBar, envTable)
        if not castBar then
            return false
        end

        if castBar.__medaCachedInterruptibleResolved then
            return castBar.__medaCachedInterruptible == true
        end

        local isInterrupted = modTable.GetSafeBoolean(castBar.IsInterrupted)
        if isInterrupted == true then
            castBar.__medaCachedInterruptible = false
            castBar.__medaCachedInterruptibleResolved = true
            return false
        end

        local rawCanInterrupt = castBar.CanInterrupt
        if envTable then
            rawCanInterrupt = envTable._CanInterrupt
        end

        local cleanCanInterrupt = modTable.ResolveSecretBoolean(rawCanInterrupt)
        if cleanCanInterrupt ~= nil then
            castBar.__medaCachedInterruptible = cleanCanInterrupt
            castBar.__medaCachedInterruptibleResolved = true
            return cleanCanInterrupt
        end

        local rawNotInterruptible = castBar.notInterruptible
        if envTable then
            rawNotInterruptible = envTable._CannotInterrupt
        end

        local cleanNotInterruptible = modTable.ResolveSecretBoolean(rawNotInterruptible)

        if cleanNotInterruptible ~= nil then
            castBar.__medaCachedInterruptible = not cleanNotInterruptible
            castBar.__medaCachedInterruptibleResolved = true
            return not cleanNotInterruptible
        end

        return false
    end

    function modTable.EvaluatePriorityInterruptCast(unitFrame, castBar, includeOffscreen, envTable)
        if not unitFrame then
            return false, "fail:no_unit"
        end

        if not includeOffscreen and not unitFrame.PlaterOnScreen then
            return false, "fail:offscreen"
        end

        if not modTable.IsEnemyNpcUnitFrame(unitFrame) then
            return false, "fail:not_enemy_npc"
        end

        castBar = castBar or unitFrame.castBar
        if not castBar then
            return false, "fail:no_castbar"
        end

        local isCasting = modTable.GetSafeBoolean(castBar.casting)
        local isChanneling = modTable.GetSafeBoolean(castBar.channeling)
        if isCasting ~= true and isChanneling ~= true then
            modTable.ClearCastRuntimeCache(castBar)
            return false, "fail:not_casting"
        end

        if not modTable.PlayerMeetsInterruptRequirement() then
            return false, "fail:interrupt_gate",
                nil,
                nil,
                nil,
                nil,
                "requireKnown=" .. modTable.SafeText(config.requireKnownInterrupt)
                .. " requireReady=" .. modTable.SafeText(config.requireReadyInterrupt)
                .. " hasInterrupt=" .. modTable.SafeText(modTable.playerHasInterrupt)
                .. " interruptSpellID=" .. modTable.SafeText(modTable.playerInterruptSpellID)
                .. " interruptReady=" .. modTable.SafeText(modTable.interruptReadyCachedValue)
        end

        if modTable.modeFocusCasts and modTable.IsFocusTargetUnitFrame(unitFrame) then
            return true, "pass:focus_cast"
        end

        if modTable.modeAnyEnemyCasts then
            return true, "pass:any_cast"
        end

        if modTable.modeAllInterruptible then
            if not modTable.IsInterruptibleCastBar(castBar, envTable) then
                return false, "fail:not_interruptible", nil, nil, nil, nil,
                    modTable.GetInterruptDebugText(castBar, envTable)
            end

            return true, "pass:match_all"
        end

        local spellID = nil
        if #modTable.prioritySpellIDList > 0 then
            spellID = modTable.GetMatchedPrioritySpellID(castBar, envTable)
            if spellID and config.prioritySpellIDs[spellID] then
                return true, "pass:spell_match", spellID
            end
        end

        if not spellID and modTable.hasPriorityNpcSpellIDs then
            spellID = modTable.GetCleanSpellID(castBar, envTable)
        end

        local rawSpellName = nil
        local spellName = nil
        if modTable.hasPrioritySpellNameFallback or modTable.hasPriorityNpcSpellNames then
            if envTable then
                rawSpellName = envTable._SpellName
            elseif castBar then
                rawSpellName = castBar.SpellName
            end
            spellName = modTable.GetSafeValue(rawSpellName)
            if spellName and config.prioritySpellNames[spellName] then
                return true, "pass:spell_match", spellID, spellName
            end
        end

        local npcID = nil
        if modTable.hasPriorityNpcSpellIDs then
            npcID = modTable.GetSafeValue(modTable.GetNpcID(unitFrame))
            if npcID and spellID then
                local npcSpells = config.priorityNpcSpellIDs[npcID]
                if npcSpells and npcSpells[spellID] then
                    return true, "pass:npc_spell_match", spellID, spellName, npcID
                end
            end
        end

        local npcName = nil
        if modTable.hasPriorityNpcSpellNames and spellName then
            npcName = modTable.GetSafeValue(modTable.GetUnitDisplayName(unitFrame))
            if npcName then
                local npcSpellNames = config.priorityNpcSpellNames[npcName]
                if npcSpellNames and npcSpellNames[spellName] then
                    return true, "pass:npc_spell_match", spellID, spellName, npcID, npcName
                end
            end
        end

        return false, "fail:priority_miss", spellID, spellName, npcID, npcName
    end

    function modTable.UnitHasPriorityInterruptibleCast(unitFrame, castBar, includeOffscreen, envTable)
        local isActive = modTable.EvaluatePriorityInterruptCast(unitFrame, castBar, includeOffscreen, envTable)
        return isActive
    end

    function modTable.SetUnitPriorityCastState(unitFrame, isActive)
        if not unitFrame then
            return false, modTable.activePriorityCastCount > 0, modTable.activePriorityCastCount > 0
        end

        local hadAny = modTable.activePriorityCastCount > 0
        local hadState = unitFrame.__medaIsActivePriorityCaster == true
        if isActive then
            unitFrame.__medaIsActivePriorityCaster = true
        else
            unitFrame.__medaIsActivePriorityCaster = nil
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

    function modTable.UpdateUnitPriorityCastState(unitFrame, castBar, includeOffscreen, envTable, debugSource)
        local isActive, reason, spellID, spellName, npcID, npcName, extra = modTable.EvaluatePriorityInterruptCast(unitFrame, castBar, includeOffscreen, envTable)
        local stateChanged, hadAny, hasAny = modTable.SetUnitPriorityCastState(unitFrame, isActive)

        if modTable.ShouldDebugLog(isActive, reason, unitFrame, castBar, debugSource, stateChanged) then
            modTable.DebugLog(
                debugSource or "Eval",
                reason,
                unitFrame,
                castBar,
                spellID,
                spellName,
                (extra or "")
                    .. " npcID=" .. modTable.SafeText(npcID)
                    .. " npcName=" .. modTable.SafeText(npcName)
                    .. " activeCount=" .. modTable.SafeText(modTable.activePriorityCastCount)
                    .. " stateChanged=" .. modTable.SafeText(stateChanged)
            )
        end

        return stateChanged, isActive, hadAny, hasAny
    end

    function modTable.RebuildActivePriorityCasts()
        local changed = false
        local activeCount = 0

        for _, plateFrame in ipairs(modTable.GetShownPlates()) do
            local unitFrame = modTable.GetUnitFrameFromPlate(plateFrame)
            if unitFrame then
                local wasActive = unitFrame.__medaIsActivePriorityCaster == true
                local isActive = modTable.UnitHasPriorityInterruptibleCast(unitFrame, nil, true) == true

                if isActive then
                    unitFrame.__medaIsActivePriorityCaster = true
                    activeCount = activeCount + 1
                else
                    unitFrame.__medaIsActivePriorityCaster = nil
                end

                if wasActive ~= isActive then
                    changed = true
                end
            end
        end

        if modTable.activePriorityCastCount ~= activeCount then
            changed = true
        end

        modTable.activePriorityCastCount = activeCount
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
            return false
        end

        if not modTable.IsEnemyNpcUnitFrame(unitFrame) then
            return false
        end

        if not modTable.HasActivePriorityCast() then
            return false
        end

        local targetAlpha = unitFrame.__medaIsActivePriorityCaster == true and 1 or modTable.GetDimAlpha()

        local needsUpdate, currentAlpha = modTable.AlphaNeedsUpdate(unitFrame, targetAlpha)
        if needsUpdate or unitFrame.__medaAppliedDimmerAlpha ~= targetAlpha then
            unitFrame:SetAlpha(targetAlpha)
            unitFrame.__medaAppliedDimmerAlpha = targetAlpha

            if config.debugEnabled and config.debugSuccesses then
                modTable.DebugLog(
                    "AlphaApply",
                    "write",
                    unitFrame,
                    unitFrame.castBar,
                    nil,
                    nil,
                    "currentAlpha=" .. modTable.SafeText(currentAlpha)
                        .. " targetAlpha=" .. modTable.SafeText(targetAlpha)
                        .. " activeCaster=" .. modTable.SafeText(unitFrame.__medaIsActivePriorityCaster == true)
                )
            end

            return true
        end

        return false
    end

    function modTable.ApplyAlphaToAllShownPlates()
        if not modTable.HasActivePriorityCast() then
            return
        end

        local shownCount = 0
        local enemyNpcCount = 0
        local dimmedCount = 0
        local changedCount = 0
        local targetAlpha = modTable.GetDimAlpha()

        for _, plateFrame in ipairs(modTable.GetShownPlates()) do
            shownCount = shownCount + 1
            local unitFrame = modTable.GetUnitFrameFromPlate(plateFrame)
            if unitFrame and modTable.IsEnemyNpcUnitFrame(unitFrame) then
                enemyNpcCount = enemyNpcCount + 1

                if unitFrame.__medaIsActivePriorityCaster ~= true then
                    dimmedCount = dimmedCount + 1
                end
            end

            if modTable.ApplyAlphaToUnitFrame(unitFrame) then
                changedCount = changedCount + 1
            end
        end

        modTable.DebugAlphaSweep(shownCount, enemyNpcCount, modTable.activePriorityCastCount, dimmedCount, changedCount, targetAlpha)
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
    local changed, _, hadAny, hasAny = modTable.UpdateUnitPriorityCastState(unitFrame, unitFrame and unitFrame.castBar, true, envTable, "Nameplate Added")
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

    local changed, isActive, hadAny, hasAny = modTable.UpdateUnitPriorityCastState(unitFrame, unitFrame and unitFrame.castBar, true, envTable, "Nameplate Updated")
    if changed and hadAny and not hasAny then
        modTable.ApplyCurrentAlphaState(true)
        return
    end

    if hasAny then
        if changed and not hadAny then
            modTable.ApplyAlphaToAllShownPlates()
            return
        end

        -- Plater rewrites alpha during regular plate updates, so every updated
        -- enemy NPC plate must be repainted while the dimmer is active.
        modTable.ApplyAlphaToUnitFrame(unitFrame)
    end
end

-- =====================================================================
-- Cast Start
-- =====================================================================
function(self, unitId, unitFrame, envTable, modTable)
    modTable.ClearCastRuntimeCache(self)
    local changed, _, hadAny, hasAny = modTable.UpdateUnitPriorityCastState(unitFrame, self, true, envTable, "Cast Start")
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
    local changed, isActive, hadAny, hasAny = modTable.UpdateUnitPriorityCastState(unitFrame, self, true, envTable, "Cast Update")
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
    modTable.ClearCastRuntimeCache(self)
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
