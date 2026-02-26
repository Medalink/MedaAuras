local _, ns = ...

local CooldownTimer = {}
ns.Services.CooldownTimer = CooldownTimer

local handleCounter = 0
local tracked = {}        -- [spellID] = { duration, castTime, castHandle }
local readyCallbacks = {} -- [spellID] = { [handle] = func }
local ticker

local function StartTicker()
    if ticker then return end
    ticker = C_Timer.NewTicker(0.1, function()
        local now = GetTime()
        local anyActive = false

        for spellID, entry in pairs(tracked) do
            if entry.castTime then
                local remaining = entry.castTime + entry.duration - now
                if remaining <= 0 then
                    entry.castTime = nil

                    local cbs = readyCallbacks[spellID]
                    if cbs then
                        for _, func in pairs(cbs) do
                            func(spellID)
                        end
                    end
                else
                    anyActive = true
                end
            end
        end

        if not anyActive then
            ticker:Cancel()
            ticker = nil
        end
    end)
end

function CooldownTimer:Initialize()
    -- Nothing needed; services are hooked lazily when :Track() is called.
end

function CooldownTimer:Track(spellID, duration)
    if tracked[spellID] then
        tracked[spellID].duration = duration
        MedaAuras.LogDebug(format("[CooldownTimer] Updated duration for spell %d to %ds", spellID, duration))
        return
    end

    local entry = {
        duration = duration,
        castTime = nil,
        castHandle = nil,
    }

    entry.castHandle = ns.Services.SpellCastTracker:OnPlayerCast(spellID, function(_, timestamp)
        entry.castTime = timestamp
        MedaAuras.LogDebug(format("[CooldownTimer] Spell %d cast detected, starting %ds timer", spellID, duration))
        StartTicker()
    end)

    tracked[spellID] = entry
    MedaAuras.LogDebug(format("[CooldownTimer] Now tracking spell %d with %ds cooldown", spellID, duration))
end

function CooldownTimer:SetDuration(spellID, newDuration)
    local entry = tracked[spellID]
    if entry then
        entry.duration = newDuration
    end
end

function CooldownTimer:IsReady(spellID)
    local entry = tracked[spellID]
    if not entry or not entry.castTime then return true end
    return (GetTime() - entry.castTime) >= entry.duration
end

function CooldownTimer:GetRemaining(spellID)
    local entry = tracked[spellID]
    if not entry or not entry.castTime then return 0 end
    local remaining = entry.castTime + entry.duration - GetTime()
    return remaining > 0 and remaining or 0
end

function CooldownTimer:GetDuration(spellID)
    local entry = tracked[spellID]
    return entry and entry.duration or 0
end

function CooldownTimer:GetProgress(spellID)
    local entry = tracked[spellID]
    if not entry or not entry.castTime or entry.duration == 0 then return 1.0 end
    local elapsed = GetTime() - entry.castTime
    local progress = elapsed / entry.duration
    return progress >= 1 and 1.0 or progress
end

function CooldownTimer:OnReady(spellID, callback)
    handleCounter = handleCounter + 1
    local handle = handleCounter

    if not readyCallbacks[spellID] then
        readyCallbacks[spellID] = {}
    end
    readyCallbacks[spellID][handle] = callback

    return handle
end

function CooldownTimer:Unregister(handle)
    for _, cbs in pairs(readyCallbacks) do
        cbs[handle] = nil
    end
end

function CooldownTimer:Reset(spellID)
    local entry = tracked[spellID]
    if entry then
        entry.castTime = nil
    end
end
