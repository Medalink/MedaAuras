local _, ns = ...

local C_Timer = C_Timer

local C = ns.Cracked or {}
ns.Cracked = C

local updateTicker
local refreshQueued

local function StopDisplayUpdates()
    if updateTicker then
        updateTicker:Cancel()
        updateTicker = nil
    end
end

local function TickDisplay()
    if not C.ShouldShowLiveFrame or not C.ShouldShowLiveFrame() then
        StopDisplayUpdates()
        return false
    end

    if C.CreateUI then
        C.CreateUI()
    end

    local needsAnimation = false
    if C.UpdateDisplayNow then
        needsAnimation = C.UpdateDisplayNow() or false
    end

    if not needsAnimation then
        StopDisplayUpdates()
    end

    return needsAnimation
end

local function FlushDisplayRefresh()
    refreshQueued = nil

    if not C.ShouldShowLiveFrame or not C.ShouldShowLiveFrame() then
        if C.UpdateMainFrameVisibility then
            C.UpdateMainFrameVisibility()
        end
        StopDisplayUpdates()
        return
    end

    local needsAnimation = TickDisplay()

    if updateTicker or not needsAnimation or not C.ShouldShowLiveFrame or not C.ShouldShowLiveFrame() then
        return
    end

    updateTicker = C_Timer.NewTicker(0.1, TickDisplay)
end

function C.RequestDisplayRefresh()
    if refreshQueued then
        return
    end

    refreshQueued = true
    C_Timer.After(0, FlushDisplayRefresh)
end

function C.StopDisplayUpdates()
    refreshQueued = nil
    StopDisplayUpdates()
end
