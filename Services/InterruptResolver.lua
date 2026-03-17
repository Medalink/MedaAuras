local _, ns = ...

local GetSpecialization = GetSpecialization
local GetSpecializationInfo = GetSpecializationInfo
local IsPlayerSpell = IsPlayerSpell
local IsSpellKnown = IsSpellKnown
local UnitClass = UnitClass
local pcall = pcall

local InterruptResolver = {}
ns.Services.InterruptResolver = InterruptResolver

local InterruptData = ns.InterruptData

local function IsSpellAvailable(entry)
    if not entry or not entry.spellID then return false end

    if entry.pet then
        local ok, known = pcall(IsSpellKnown, entry.spellID, true)
        if ok and known then return true end

        local ok2, known2 = pcall(IsPlayerSpell, entry.spellID)
        if ok2 and known2 then return true end

        if entry.petSpellID then
            local ok3, known3 = pcall(IsSpellKnown, entry.petSpellID, true)
            if ok3 and known3 then return true end
        end

        return false
    end

    local ok, known = pcall(IsPlayerSpell, entry.spellID)
    if ok and known then return true end

    local ok2, known2 = pcall(IsSpellKnown, entry.spellID)
    return ok2 and known2 or false
end

function InterruptResolver:GetSpecPrimaryInterrupt(specID)
    return InterruptData:GetPrimaryInterruptForSpec(specID)
end

function InterruptResolver:GetSpecInterruptCandidates(specID)
    return InterruptData:GetSpecInterruptCandidates(specID)
end

function InterruptResolver:GetRoleFallbackInterrupt(classToken, role)
    return InterruptData:GetRoleFallbackInterrupt(classToken, role)
end

function InterruptResolver:GetClassFallbackInterrupt(classToken)
    return InterruptData:GetClassFallbackInterrupt(classToken)
end

function InterruptResolver:ResolvePartyPrimaryInterrupt(classToken, specID, role)
    if specID then
        local primary = self:GetSpecPrimaryInterrupt(specID)
        if primary then
            return primary, "spec"
        end

        local specData = InterruptData:GetSpecData(specID)
        if specData and specData.hasInterrupt == false then
            return nil, "spec_no_interrupt"
        end
    end

    local roleRecord = InterruptData:GetRoleFallbackRecord(classToken, role)
    if roleRecord then
        if roleRecord.hasInterrupt == false then
            return nil, "role_no_interrupt"
        end

        local roleFallback = self:GetRoleFallbackInterrupt(classToken, role)
        if roleFallback then
            return roleFallback, "role"
        end
    end

    local classFallback = self:GetClassFallbackInterrupt(classToken)
    if classFallback then
        return classFallback, "class"
    end

    return nil, "unknown"
end

function InterruptResolver:ResolvePlayerInterrupt()
    local _, classToken = UnitClass("player")
    local specIndex = GetSpecialization()
    local specID = specIndex and GetSpecializationInfo(specIndex) or nil

    local candidates
    if specID then
        candidates = self:GetSpecInterruptCandidates(specID)
    else
        candidates = InterruptData:GetPlayerClassInterruptCandidates(classToken)
    end

    for _, entry in ipairs(candidates or {}) do
        if IsSpellAvailable(entry) then
            return entry, specID, classToken
        end
    end

    return nil, specID, classToken
end
