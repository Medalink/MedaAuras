-- Pandemic Highlighter for Plater
--
-- Purpose:
-- Highlight player-applied DoTs on enemy nameplates when they enter their
-- pandemic window (last 30% of the current aura duration).
--
-- Install:
-- 1. Plater -> Modding -> Hooking
-- 2. Create a new mod, for example: "Pandemic Highlighter - Medalink"
-- 3. Add these hooks and paste the matching function into each hook:
--    - Initialization
--    - Nameplate Added
--    - Nameplate Removed
--    - Nameplate Updated
--    - Player Talent Update
--    - Mod Option Changed
-- 4. In the mod admin options, add these real Plater options:
--    - Label: "Alert Types"
--    - Toggle: Name "Glow", Key "useGlow", Value false
--    - Toggle: Name "Pixel Glow", Key "usePixelGlow", Value true
--    - Toggle: Name "Enlarge", Key "useEnlarge", Value false
--    - Toggle: Name "Dim Others", Key "useDimOthers", Value false
--    - Label: "Targets"
--    - Toggle: Name "Apply To Debuff Icon", Key "applyToDebuffIcon", Value true
--    - Toggle: Name "Apply To Nameplate", Key "applyToNameplate", Value false
--    - Label: "Sizing"
--    - Number: Name "Icon Enlarge Percent", Key "iconEnlargePercent", Min 100, Max 180, Fraction false, Value 125
--    - Number: Name "Nameplate Enlarge Percent", Key "nameplateEnlargePercent", Min 100, Max 140, Fraction false, Value 108
--    - Number: Name "Dim Others Opacity", Key "dimOpacityPercent", Min 0, Max 100, Fraction false, Value 35
--    - Label: "Sound"
--    - Toggle: Name "Enable Sound", Key "enableSound", Value false
--    - Audio: Name "Pandemic Sound", Key "pandemicSound"
--    - Number: Name "Sound Gap Seconds", Key "soundSpacingSeconds", Min 0.05, Max 0.50, Fraction true, Value 0.12
--    - Label: "Detection"
--    - Toggle: Name "Track All Player Debuffs (Advanced)", Key "trackAllPlayerDebuffs", Value false
--    - Toggle: Name "Debug Output", Key "debugEnabled", Value false
--
-- Notes:
-- - This tracks hostile units only.
-- - It only tracks your own debuffs and your pet-applied debuffs.
-- - The shipped spell table is intentionally editable in-code.
-- - The runtime pandemic check always uses the live aura duration from the
--   nameplate icon: remaining <= duration * 0.30.
-- - The per-spell duration values in the table are reference defaults only.

-- =====================================================================
-- Initialization
-- =====================================================================
function(modTable)
    local ipairs = ipairs
    local pairs = pairs
    local next = next
    local tostring = tostring
    local tonumber = tonumber
    local type = type
    local math_max = math.max
    local math_min = math.min
    local GetTime = GetTime
    local CreateFrame = CreateFrame
    local PlaySoundFile = PlaySoundFile
    local UnitCanAttack = UnitCanAttack
    local UnitIsUnit = UnitIsUnit
    local C_NamePlate = C_NamePlate
    local C_Spell = C_Spell

    local PANDEMIC_FACTOR = 0.30
    local ICON_GLOW_KEY = "MedaPandemicIconGlow"
    local ICON_PIXEL_GLOW_KEY = "MedaPandemicIconPixelGlow"
    local NAMEPLATE_GLOW_KEY = "MedaPandemicNameplateGlow"
    local NAMEPLATE_PIXEL_GLOW_KEY = "MedaPandemicNameplatePixelGlow"

    modTable.config = modTable.config or {}
    modTable.runtime = modTable.runtime or {}

    local config = modTable.config
    local runtime = modTable.runtime

    modTable.trackedPandemicSpells = modTable.trackedPandemicSpells or {
        -- Reference durations are seeded from the local wow-tools DB2 export.
        -- Runtime uses the live aura duration shown by Plater instead.
        ["Warrior"] = {
            { spellName = "Rend", referenceDuration = 15.0, referencePandemic = 4.5 },
        },
        ["Paladin"] = {
        },
        ["Hunter"] = {
            { spellName = "Serpent Sting", spellIDs = { 271788 }, referenceDuration = 18.0, referencePandemic = 5.4 },
            { spellName = "Black Arrow", referenceDuration = 8.0, referencePandemic = 2.4 },
        },
        ["Rogue"] = {
            { spellName = "Garrote", spellIDs = { 703 }, referenceDuration = 18.0, referencePandemic = 5.4 },
            { spellName = "Rupture", spellIDs = { 1943 }, referenceDuration = 24.0, referencePandemic = 7.2, dynamicDuration = true },
            { spellName = "Crimson Tempest", spellIDs = { 283668 }, referenceDuration = 12.0, referencePandemic = 3.6 },
        },
        ["Priest"] = {
            { spellName = "Shadow Word: Pain", spellIDs = { 589 }, referenceDuration = 16.0, referencePandemic = 4.8 },
            { spellName = "Vampiric Touch", spellIDs = { 34914, 284402 }, referenceDuration = 21.0, referencePandemic = 6.3 },
            { spellName = "Devouring Plague", referenceDuration = 6.0, referencePandemic = 1.8 },
            { spellName = "Purge the Wicked", spellIDs = { 204213, 451740 }, referenceDuration = 20.0, referencePandemic = 6.0 },
        },
        ["Death Knight"] = {
            { spellName = "Blood Plague", spellIDs = { 55078 }, referenceDuration = 24.0, referencePandemic = 7.2 },
            { spellName = "Frost Fever", spellIDs = { 55095 }, referenceDuration = 24.0, referencePandemic = 7.2 },
            { spellName = "Virulent Plague", spellIDs = { 191587 }, referenceDuration = 24.0, referencePandemic = 7.2 },
        },
        ["Shaman"] = {
            { spellName = "Flame Shock", spellIDs = { 188389 }, referenceDuration = 18.0, referencePandemic = 5.4 },
        },
        ["Mage"] = {
            { spellName = "Living Bomb", spellIDs = { 176670 }, referenceDuration = 8.0, referencePandemic = 2.4 },
        },
        ["Warlock"] = {
            { spellName = "Agony", spellIDs = { 980 }, referenceDuration = 18.0, referencePandemic = 5.4 },
            { spellName = "Corruption", spellIDs = { 172, 146739 }, referenceDuration = 14.0, referencePandemic = 4.2 },
            { spellName = "Unstable Affliction", spellIDs = { 316099 }, referenceDuration = 16.0, referencePandemic = 4.8 },
            { spellName = "Immolate", referenceDuration = 18.0, referencePandemic = 5.4 },
            { spellName = "Wither", spellIDs = { 445474 }, referenceDuration = 18.0, referencePandemic = 5.4 },
            { spellName = "Doom", spellIDs = { 603 }, referenceDuration = 20.0, referencePandemic = 6.0 },
        },
        ["Monk"] = {
            { spellName = "Breath of Fire", spellIDs = { 123725 }, referenceDuration = 12.0, referencePandemic = 3.6 },
        },
        ["Druid"] = {
            { spellName = "Moonfire", spellIDs = { 164812 }, referenceDuration = 18.0, referencePandemic = 5.4 },
            { spellName = "Sunfire", spellIDs = { 164815 }, referenceDuration = 18.0, referencePandemic = 5.4 },
            { spellName = "Rip", spellIDs = { 1079 }, referenceDuration = 24.0, referencePandemic = 7.2, dynamicDuration = true },
            { spellName = "Rake", spellIDs = { 155722 }, referenceDuration = 15.0, referencePandemic = 4.5 },
            { spellName = "Thrash", referenceDuration = 15.0, referencePandemic = 4.5 },
            { spellName = "Stellar Flare", spellIDs = { 202347 }, referenceDuration = 24.0, referencePandemic = 7.2 },
        },
        ["Demon Hunter"] = {
            { spellName = "Fiery Brand", spellIDs = { 207771 }, referenceDuration = 12.0, referencePandemic = 3.6 },
            { spellName = "Sigil of Flame", spellIDs = { 204598 }, referenceDuration = 8.0, referencePandemic = 2.4 },
            { spellName = "The Hunt", spellIDs = { 345335, 370969 }, referenceDuration = 6.0, referencePandemic = 1.8 },
        },
        ["Evoker"] = {
            { spellName = "Fire Breath", spellIDs = { 357209, 369416, 387297 }, referenceDuration = 12.0, referencePandemic = 3.6, dynamicDuration = true },
        },
    }

    runtime.plateStates = runtime.plateStates or {}
    runtime.pendingSoundCount = runtime.pendingSoundCount or 0
    runtime.lastSoundAt = runtime.lastSoundAt or 0
    runtime.activePandemicPlateCount = runtime.activePandemicPlateCount or 0
    runtime.lookupBySpellID = runtime.lookupBySpellID or {}
    runtime.lookupBySpellName = runtime.lookupBySpellName or {}
    runtime.casterOwnershipByToken = runtime.casterOwnershipByToken or {}
    runtime.iconScratch = runtime.iconScratch or {}
    runtime.auraStateSerial = runtime.auraStateSerial or 0
    runtime.genericTrackedSpell = runtime.genericTrackedSpell or {
        spellName = "Any Player Debuff",
        referenceDuration = nil,
        referencePandemic = nil,
    }

    local function Debug(...)
        if not config.debugEnabled or not Plater or type(Plater.Msg) ~= "function" then
            return
        end

        Plater:Msg(...)
    end

    local function Clamp(value, minValue, maxValue)
        value = tonumber(value) or minValue
        value = math_max(minValue, value)
        value = math_min(maxValue, value)
        return value
    end

    local function GetUnitToken(unitFrame)
        if not unitFrame then
            return nil
        end

        return unitFrame.namePlateUnitToken or unitFrame.displayedUnit or unitFrame.unit
    end

    local function IsEnemyUnitFrame(unitFrame)
        if not unitFrame then
            return false
        end

        local actorType = unitFrame.ActorType or unitFrame.actorType or (unitFrame.PlateFrame and unitFrame.PlateFrame.actorType)
        if actorType == "enemyplayer" or actorType == "enemynpc" then
            return true
        end

        local unitToken = GetUnitToken(unitFrame)
        if type(unitToken) ~= "string" or unitToken == "" then
            return false
        end

        if UnitCanAttack then
            return UnitCanAttack("player", unitToken) or false
        end

        return false
    end

    local function GetPlateFrames()
        if C_NamePlate and type(C_NamePlate.GetNamePlates) == "function" then
            return C_NamePlate.GetNamePlates() or {}
        end

        return {}
    end

    local function EnsureSoundDriver()
        if runtime.soundDriver then
            return runtime.soundDriver
        end

        local soundDriver = CreateFrame("Frame")
        soundDriver:Hide()
        soundDriver:SetScript("OnUpdate", function(self)
            if runtime.pendingSoundCount <= 0 then
                self:Hide()
                return
            end

            if not config.enableSound or type(config.pandemicSound) ~= "string" or config.pandemicSound == "" then
                runtime.pendingSoundCount = 0
                self:Hide()
                return
            end

            local now = GetTime()
            if now - (runtime.lastSoundAt or 0) < (runtime.cachedSoundSpacingSeconds or 0.12) then
                return
            end

            local willPlay = PlaySoundFile(config.pandemicSound, "Master")
            if willPlay ~= false then
                runtime.lastSoundAt = now
            end

            runtime.pendingSoundCount = math_max(runtime.pendingSoundCount - 1, 0)
            if runtime.pendingSoundCount <= 0 then
                self:Hide()
            end
        end)

        runtime.soundDriver = soundDriver
        return soundDriver
    end

    function modTable.QueuePandemicSound()
        if not config.enableSound or type(config.pandemicSound) ~= "string" or config.pandemicSound == "" then
            return
        end

        runtime.pendingSoundCount = math_min((runtime.pendingSoundCount or 0) + 1, runtime.cachedSoundQueueLimit or 24)

        local now = GetTime()
        if now - (runtime.lastSoundAt or 0) >= (runtime.cachedSoundSpacingSeconds or 0.12) then
            local willPlay = PlaySoundFile(config.pandemicSound, "Master")
            if willPlay ~= false then
                runtime.lastSoundAt = now
            end
            runtime.pendingSoundCount = math_max(runtime.pendingSoundCount - 1, 0)
        end

        if runtime.pendingSoundCount > 0 then
            EnsureSoundDriver():Show()
        end
    end

    function modTable.RefreshTrackedSpellLookups()
        local lookupBySpellID = {}
        local lookupBySpellName = {}

        for className, spells in pairs(modTable.trackedPandemicSpells or {}) do
            if type(spells) == "table" then
                for _, spellData in ipairs(spells) do
                    if type(spellData) == "table" then
                        spellData.className = className
                        spellData.pandemicFactor = tonumber(spellData.pandemicFactor) or PANDEMIC_FACTOR

                        local spellName = spellData.spellName
                        if type(spellName) == "string" and spellName ~= "" then
                            lookupBySpellName[spellName] = spellData
                        end

                        local spellIDs = spellData.spellIDs
                        if type(spellIDs) == "table" then
                            for _, spellID in ipairs(spellIDs) do
                                spellID = tonumber(spellID)
                                if spellID then
                                    lookupBySpellID[spellID] = spellData

                                    if C_Spell and type(C_Spell.GetSpellName) == "function" then
                                        local localizedName = C_Spell.GetSpellName(spellID)
                                        if type(localizedName) == "string" and localizedName ~= "" then
                                            lookupBySpellName[localizedName] = spellData
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        runtime.lookupBySpellID = lookupBySpellID
        runtime.lookupBySpellName = lookupBySpellName
    end

    function modTable.RefreshCachedConfig()
        if config.useGlow == nil then
            config.useGlow = false
        end

        if config.usePixelGlow == nil then
            config.usePixelGlow = true
        end

        if config.useEnlarge == nil then
            config.useEnlarge = false
        end

        if config.useDimOthers == nil then
            config.useDimOthers = false
        end

        if config.applyToDebuffIcon == nil then
            config.applyToDebuffIcon = true
        end

        if config.applyToNameplate == nil then
            config.applyToNameplate = false
        end

        if config.iconEnlargePercent == nil then
            config.iconEnlargePercent = 125
        end

        if config.nameplateEnlargePercent == nil then
            config.nameplateEnlargePercent = 108
        end

        if config.dimOpacityPercent == nil then
            config.dimOpacityPercent = 35
        end

        if config.enableSound == nil then
            config.enableSound = false
        end

        if config.pandemicSound == nil then
            config.pandemicSound = ""
        end

        if config.soundSpacingSeconds == nil then
            config.soundSpacingSeconds = 0.12
        end

        if config.trackAllPlayerDebuffs == nil then
            config.trackAllPlayerDebuffs = false
        end

        if config.debugEnabled == nil then
            config.debugEnabled = false
        end

        runtime.cachedIconScale = Clamp(config.iconEnlargePercent, 100, 180) / 100
        runtime.cachedNameplateScale = Clamp(config.nameplateEnlargePercent, 100, 140) / 100
        runtime.cachedDimAlpha = Clamp(config.dimOpacityPercent, 0, 100) / 100
        runtime.cachedSoundSpacingSeconds = Clamp(config.soundSpacingSeconds, 0.05, 0.50)
        runtime.cachedSoundQueueLimit = 24

        runtime.iconGlowOptions = {
            glowType = "button",
            color = "yellow",
            frequency = 0.14,
            key = ICON_GLOW_KEY,
        }
        runtime.iconPixelGlowOptions = {
            glowType = "pixel",
            color = "yellow",
            N = 6,
            frequency = 0.5,
            length = 4,
            th = 2,
            xOffset = 1,
            yOffset = 1,
            border = false,
            key = ICON_PIXEL_GLOW_KEY,
        }
        runtime.nameplateGlowOptions = {
            glowType = "button",
            color = "orange",
            frequency = 0.12,
            key = NAMEPLATE_GLOW_KEY,
        }
        runtime.nameplatePixelGlowOptions = {
            glowType = "pixel",
            color = "orange",
            N = 8,
            frequency = 0.25,
            length = 7,
            th = 3,
            xOffset = 0,
            yOffset = 0,
            border = false,
            key = NAMEPLATE_PIXEL_GLOW_KEY,
        }
    end

    local function ClearScaledFrame(frame, appliedKey, baseScaleKey)
        if not frame or not frame[appliedKey] then
            return
        end

        local baseScale = frame[baseScaleKey]
        if tonumber(baseScale) then
            frame:SetScale(baseScale)
        else
            frame:SetScale(1)
        end

        frame[appliedKey] = nil
    end

    local function ApplyScaledFrame(frame, scale, appliedKey, baseScaleKey)
        if not frame then
            return
        end

        if not frame[appliedKey] then
            frame[baseScaleKey] = frame:GetScale() or 1
        end

        local baseScale = tonumber(frame[baseScaleKey]) or 1
        frame:SetScale(baseScale * scale)
        frame[appliedKey] = true
    end

    local function StartGlow(frame, options, startedKey)
        if not frame or not Plater then
            return
        end

        if frame[startedKey] then
            return
        end

        if type(Plater.StartGlow) == "function" then
            Plater.StartGlow(frame, nil, options, options.key)
            frame[startedKey] = true
        end
    end

    local function StopGlow(frame, options, startedKey)
        if not frame or not frame[startedKey] then
            return
        end

        if Plater and type(Plater.StopGlow) == "function" then
            Plater.StopGlow(frame, options and options.key or nil)
        end

        frame[startedKey] = nil
    end

    local function StartPixelGlow(frame, options, startedKey)
        if not frame or not Plater then
            return
        end

        if frame[startedKey] then
            return
        end

        if type(Plater.StartPixelGlow) == "function" then
            Plater.StartPixelGlow(frame, nil, options, options.key)
            frame[startedKey] = true
        end
    end

    local function StopPixelGlow(frame, options, startedKey)
        if not frame or not frame[startedKey] then
            return
        end

        if Plater and type(Plater.StopPixelGlow) == "function" then
            Plater.StopPixelGlow(frame, options and options.key or nil)
        end

        frame[startedKey] = nil
    end

    function modTable.ClearIconState(iconFrame)
        if not iconFrame then
            return
        end

        local glowFrame = iconFrame.Cooldown or iconFrame
        StopGlow(glowFrame, runtime.iconGlowOptions, "__MedaPandemicGlowStarted")
        StopPixelGlow(glowFrame, runtime.iconPixelGlowOptions, "__MedaPandemicPixelGlowStarted")
        ClearScaledFrame(iconFrame, "__MedaPandemicScaleApplied", "__MedaPandemicBaseScale")
        iconFrame.__MedaPandemicActive = nil
        iconFrame:SetAlpha(1)
    end

    function modTable.ApplyIconState(iconFrame, isActive)
        if not iconFrame then
            return
        end

        if not config.applyToDebuffIcon or not isActive then
            modTable.ClearIconState(iconFrame)
            return
        end

        local glowFrame = iconFrame.Cooldown or iconFrame

        if config.useGlow then
            StartGlow(glowFrame, runtime.iconGlowOptions, "__MedaPandemicGlowStarted")
        else
            StopGlow(glowFrame, runtime.iconGlowOptions, "__MedaPandemicGlowStarted")
        end

        if config.usePixelGlow then
            StartPixelGlow(glowFrame, runtime.iconPixelGlowOptions, "__MedaPandemicPixelGlowStarted")
        else
            StopPixelGlow(glowFrame, runtime.iconPixelGlowOptions, "__MedaPandemicPixelGlowStarted")
        end

        if config.useEnlarge then
            ApplyScaledFrame(iconFrame, runtime.cachedIconScale, "__MedaPandemicScaleApplied", "__MedaPandemicBaseScale")
        else
            ClearScaledFrame(iconFrame, "__MedaPandemicScaleApplied", "__MedaPandemicBaseScale")
        end

        iconFrame.__MedaPandemicActive = true
        iconFrame:SetAlpha(1)
    end

    function modTable.ClearNameplateState(unitFrame)
        if not unitFrame then
            return
        end

        local healthBar = unitFrame.healthBar or unitFrame
        StopGlow(healthBar, runtime.nameplateGlowOptions, "__MedaPandemicGlowStarted")
        StopPixelGlow(healthBar, runtime.nameplatePixelGlowOptions, "__MedaPandemicPixelGlowStarted")
        ClearScaledFrame(unitFrame, "__MedaPandemicScaleApplied", "__MedaPandemicBaseScale")
        unitFrame:SetAlpha(1)
    end

    function modTable.ApplyNameplateState(unitFrame, isActive)
        if not unitFrame then
            return
        end

        if not config.applyToNameplate or not isActive then
            modTable.ClearNameplateState(unitFrame)
            return
        end

        local healthBar = unitFrame.healthBar or unitFrame

        if config.useGlow then
            StartGlow(healthBar, runtime.nameplateGlowOptions, "__MedaPandemicGlowStarted")
        else
            StopGlow(healthBar, runtime.nameplateGlowOptions, "__MedaPandemicGlowStarted")
        end

        if config.usePixelGlow then
            StartPixelGlow(healthBar, runtime.nameplatePixelGlowOptions, "__MedaPandemicPixelGlowStarted")
        else
            StopPixelGlow(healthBar, runtime.nameplatePixelGlowOptions, "__MedaPandemicPixelGlowStarted")
        end

        if config.useEnlarge then
            ApplyScaledFrame(unitFrame, runtime.cachedNameplateScale, "__MedaPandemicScaleApplied", "__MedaPandemicBaseScale")
        else
            ClearScaledFrame(unitFrame, "__MedaPandemicScaleApplied", "__MedaPandemicBaseScale")
        end
    end

    function modTable.GetAuraLists(unitFrame)
        local firstList
        local secondList

        if unitFrame and unitFrame.BuffFrame then
            firstList = unitFrame.BuffFrame.PlaterBuffList
        end
        if unitFrame and unitFrame.BuffFrame2 then
            secondList = unitFrame.BuffFrame2.PlaterBuffList
        end

        return firstList, secondList
    end

    function modTable.IsOwnCasterToken(sourceUnit)
        if type(sourceUnit) ~= "string" or sourceUnit == "" then
            return false
        end

        if sourceUnit == "player" or sourceUnit == "pet" or sourceUnit == "vehicle" then
            return true
        end

        local cached = runtime.casterOwnershipByToken[sourceUnit]
        if cached ~= nil then
            return cached
        end

        local isOwn = false
        if UnitIsUnit then
            isOwn = UnitIsUnit(sourceUnit, "player")
                or UnitIsUnit(sourceUnit, "pet")
                or UnitIsUnit(sourceUnit, "vehicle")
                or false
        end

        runtime.casterOwnershipByToken[sourceUnit] = isOwn
        return isOwn
    end

    function modTable.IsOwnAuraIcon(iconFrame)
        if not iconFrame or not iconFrame.IsFromPlayer then
            return false
        end

        local casterToken = iconFrame.Caster
        if iconFrame.__MedaCasterToken ~= casterToken then
            iconFrame.__MedaCasterToken = casterToken
            iconFrame.__MedaIsOwnCaster = modTable.IsOwnCasterToken(casterToken)
        end

        return iconFrame.__MedaIsOwnCaster == true
    end

    function modTable.GetTrackedSpellForAura(iconFrame)
        if not iconFrame then
            return nil
        end

        local spellID = tonumber(iconFrame.spellId or iconFrame.SpellID)
        if spellID and runtime.lookupBySpellID[spellID] then
            return runtime.lookupBySpellID[spellID]
        end

        local spellName = iconFrame.SpellName or iconFrame.spellName
        if type(spellName) == "string" and runtime.lookupBySpellName[spellName] then
            return runtime.lookupBySpellName[spellName]
        end

        if config.trackAllPlayerDebuffs then
            return runtime.genericTrackedSpell
        end

        return nil
    end

    function modTable.ShouldDimOtherNameplates()
        return config.applyToNameplate
            and config.useDimOthers
            and (runtime.activePandemicPlateCount or 0) > 0
    end

    function modTable.ApplyNameplateAlpha(unitFrame, isPandemic)
        if not unitFrame then
            return
        end

        if modTable.ShouldDimOtherNameplates() and not isPandemic then
            unitFrame:SetAlpha(runtime.cachedDimAlpha)
        else
            unitFrame:SetAlpha(1)
        end
    end

    function modTable.RefreshGlobalNameplateDimming()
        for _, plateFrame in ipairs(GetPlateFrames()) do
            local unitFrame = plateFrame and plateFrame.unitFrame
            if unitFrame and unitFrame:IsShown() and IsEnemyUnitFrame(unitFrame) then
                local state = runtime.plateStates[unitFrame]
                modTable.ApplyNameplateAlpha(unitFrame, state and state.hasPandemic or false)
            end
        end
    end

    function modTable.ClearUnitState(unitFrame)
        if not unitFrame then
            return false
        end

        local hadPandemic = runtime.plateStates[unitFrame] and runtime.plateStates[unitFrame].hasPandemic or false
        runtime.plateStates[unitFrame] = nil
        modTable.ClearNameplateState(unitFrame)

        local firstList, secondList = modTable.GetAuraLists(unitFrame)
        if firstList then
            for _, iconFrame in ipairs(firstList) do
                modTable.ClearIconState(iconFrame)
            end
        end
        if secondList then
            for _, iconFrame in ipairs(secondList) do
                modTable.ClearIconState(iconFrame)
            end
        end

        if hadPandemic then
            runtime.activePandemicPlateCount = math_max((runtime.activePandemicPlateCount or 1) - 1, 0)
            if runtime.activePandemicPlateCount == 0 then
                modTable.RefreshGlobalNameplateDimming()
            end
        end

        return hadPandemic
    end

    function modTable.UpdateUnitPandemicState(unitFrame, envTable, debugSource)
        if not unitFrame then
            return false, false
        end

        if not IsEnemyUnitFrame(unitFrame) then
            local hadPandemic = modTable.ClearUnitState(unitFrame)
            return hadPandemic, false
        end

        local unitToken = GetUnitToken(unitFrame)
        if type(unitToken) ~= "string" or unitToken == "" then
            local hadPandemic = modTable.ClearUnitState(unitFrame)
            return hadPandemic, false
        end

        local now = GetTime()
        local plateState = runtime.plateStates[unitFrame]
        if not plateState then
            plateState = {
                hasPandemic = false,
                activeAuraKeys = {},
            }
            runtime.plateStates[unitFrame] = plateState
        end

        runtime.auraStateSerial = runtime.auraStateSerial + 1
        local auraStateSerial = runtime.auraStateSerial
        local auraStates = plateState.activeAuraKeys
        local iconScratch = runtime.iconScratch
        local iconScratchCount = 0
        local highlightedIconCount = 0
        local hadPandemic = plateState.hasPandemic

        local function ProcessAuraList(auraList)
            if not auraList then
                return
            end

            for _, iconFrame in ipairs(auraList) do
                local isActive = false
                if iconFrame and iconFrame:IsShown() and iconFrame.filter == "HARMFUL" then
                    iconScratchCount = iconScratchCount + 1
                    iconScratch[iconScratchCount] = iconFrame

                    if modTable.IsOwnAuraIcon(iconFrame) then
                        local trackedSpell = modTable.GetTrackedSpellForAura(iconFrame)
                        if trackedSpell then
                            local duration = tonumber(iconFrame.Duration) or 0
                            local expirationTime = tonumber(iconFrame.ExpirationTime) or 0
                            local remainingTime = math_max(expirationTime - now, 0)

                            if duration > 0 and remainingTime <= (duration * (trackedSpell.pandemicFactor or PANDEMIC_FACTOR)) then
                                local auraKey = tonumber(iconFrame.spellId or iconFrame.SpellID) or (iconFrame.SpellName or iconFrame.spellName or "unknown")
                                if auraStates[auraKey] == nil then
                                    modTable.QueuePandemicSound()
                                    Debug("Pandemic start:", trackedSpell.spellName or auraKey, debugSource or "update")
                                end

                                auraStates[auraKey] = auraStateSerial
                                highlightedIconCount = highlightedIconCount + 1
                                isActive = true
                            end
                        end
                    end
                end

                modTable.ApplyIconState(iconFrame, isActive)
            end
        end

        local firstList, secondList = modTable.GetAuraLists(unitFrame)
        ProcessAuraList(firstList)
        ProcessAuraList(secondList)

        for auraKey, stamp in pairs(auraStates) do
            if stamp ~= auraStateSerial then
                auraStates[auraKey] = nil
            end
        end

        if config.applyToDebuffIcon and config.useDimOthers then
            local shouldDimIcons = highlightedIconCount > 0
            for index = 1, iconScratchCount do
                local iconFrame = iconScratch[index]
                if shouldDimIcons and not iconFrame.__MedaPandemicActive then
                    iconFrame:SetAlpha(runtime.cachedDimAlpha)
                else
                    iconFrame:SetAlpha(1)
                end
                iconScratch[index] = nil
            end
        else
            for index = 1, iconScratchCount do
                local iconFrame = iconScratch[index]
                iconFrame:SetAlpha(1)
                iconScratch[index] = nil
            end
        end

        local hasPandemic = highlightedIconCount > 0

        plateState.hasPandemic = hasPandemic

        modTable.ApplyNameplateState(unitFrame, hasPandemic)
        if hadPandemic ~= hasPandemic then
            if hasPandemic then
                runtime.activePandemicPlateCount = (runtime.activePandemicPlateCount or 0) + 1
                if runtime.activePandemicPlateCount == 1 then
                    modTable.RefreshGlobalNameplateDimming()
                end
            else
                runtime.activePandemicPlateCount = math_max((runtime.activePandemicPlateCount or 1) - 1, 0)
                if runtime.activePandemicPlateCount == 0 then
                    modTable.RefreshGlobalNameplateDimming()
                end
            end
        end
        modTable.ApplyNameplateAlpha(unitFrame, hasPandemic)

        return hadPandemic ~= hasPandemic, hasPandemic
    end

    function modTable.RefreshAll()
        if modTable.isRefreshing then
            return
        end

        modTable.isRefreshing = true

        for _, plateFrame in ipairs(GetPlateFrames()) do
            local unitFrame = plateFrame and plateFrame.unitFrame
            if unitFrame and unitFrame:IsShown() then
                modTable.UpdateUnitPandemicState(unitFrame, nil, "RefreshAll")
            end
        end

        modTable.RefreshGlobalNameplateDimming()
        modTable.isRefreshing = nil
    end

    modTable.RefreshTrackedSpellLookups()
    modTable.RefreshCachedConfig()
    EnsureSoundDriver()
end

-- =====================================================================
-- Nameplate Added
-- =====================================================================
function(self, unitId, unitFrame, envTable, modTable)
    modTable.UpdateUnitPandemicState(unitFrame, envTable, "Nameplate Added")
end

-- =====================================================================
-- Nameplate Removed
-- =====================================================================
function(self, unitId, unitFrame, envTable, modTable)
    modTable.ClearUnitState(unitFrame)
end

-- =====================================================================
-- Nameplate Updated
-- =====================================================================
function(self, unitId, unitFrame, envTable, modTable)
    if modTable.isRefreshing then
        return
    end

    modTable.UpdateUnitPandemicState(unitFrame, envTable, "Nameplate Updated")
end

-- =====================================================================
-- Player Talent Update
-- =====================================================================
function(self, unitId, unitFrame, envTable, modTable)
    modTable.RefreshTrackedSpellLookups()
    modTable.RefreshCachedConfig()
    modTable.RefreshAll()
end

-- =====================================================================
-- Mod Option Changed
-- =====================================================================
function(modTable)
    modTable.RefreshTrackedSpellLookups()
    modTable.RefreshCachedConfig()
    modTable.RefreshAll()
end
