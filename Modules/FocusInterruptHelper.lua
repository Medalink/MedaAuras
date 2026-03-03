local _, ns = ...

local MedaUI = LibStub("MedaUI-1.0")

-- ============================================================================
-- Module Info
-- ============================================================================

local MODULE_NAME      = "FocusInterruptHelper"
local MODULE_VERSION   = "1.1"
local MODULE_STABILITY = "stable"   -- "experimental" | "beta" | "stable"

-- ============================================================================
-- Interrupt Spell Database
-- ============================================================================

local INTERRUPTS = {
    { id = 351338, name = "Quell",             class = "EVOKER",       baseCD = 18 },
    { id = 1766,   name = "Kick",              class = "ROGUE",        baseCD = 15 },
    { id = 6552,   name = "Pummel",            class = "WARRIOR",      baseCD = 15 },
    { id = 2139,   name = "Counterspell",      class = "MAGE",         baseCD = 24 },
    { id = 57994,  name = "Wind Shear",        class = "SHAMAN",       baseCD = 12 },
    { id = 106839, name = "Skull Bash",        class = "DRUID",        baseCD = 15 },
    { id = 96231,  name = "Rebuke",            class = "PALADIN",      baseCD = 15 },
    { id = 47528,  name = "Mind Freeze",       class = "DEATHKNIGHT",  baseCD = 15 },
    { id = 147362, name = "Counter Shot",      class = "HUNTER",       baseCD = 24 },
    { id = 282220, name = "Muzzle",            class = "HUNTER",       baseCD = 15 },
    { id = 183752, name = "Disrupt",           class = "DEMONHUNTER",  baseCD = 15 },
    { id = 116705, name = "Spear Hand Strike", class = "MONK",         baseCD = 15 },
    { id = 15487,  name = "Silence",           class = "PRIEST",       baseCD = 45 },
    { id = 119910,  name = "Spell Lock",            class = "WARLOCK", baseCD = 24, pet = true, altIDs = {19647, 119898, 1276467, 89766} },
    { id = 19647,   name = "Spell Lock",            class = "WARLOCK", baseCD = 24, pet = true, altIDs = {119910, 119898, 1276467, 89766} },
    { id = 89766,   name = "Axe Toss",              class = "WARLOCK", baseCD = 30, pet = true, altIDs = {119910, 19647, 119898, 1276467} },
    { id = 1276467, name = "Grimoire: Fel Ravager",  class = "WARLOCK", baseCD = 24, pet = false, altIDs = {119910, 19647, 89766} },
}

-- ============================================================================
-- State
-- ============================================================================

local activeSpellID
local activeSpellName
local activeIsPetSpell
local activeSpellTexture
local updateTicker
local iconFrame
local overlayTextures = {}  -- [buttonFrame] = texture
local actionBarFrame        -- event listener for overlay mode bar changes
local hookActive = false
local hooksInstalled = false
local hookEventFrame         -- event listener for hook mode bar changes
local cdmHooked = false
local cdmSeen = {}           -- [icon] = true, dedup for CDM icons in cachedButtons

-- ============================================================================
-- Slot-to-Button mapping for action bar overlay
-- ============================================================================

local SLOT_RANGES = {
    { start = 1,  prefix = "ActionButton" },
    { start = 13, prefix = "ActionButton" },
    { start = 25, prefix = "MultiBarRightButton" },
    { start = 37, prefix = "MultiBarLeftButton" },
    { start = 49, prefix = "MultiBarBottomRightButton" },
    { start = 61, prefix = "MultiBarBottomLeftButton" },
    { start = 73, prefix = "ActionButton" },
    { start = 85, prefix = "ActionButton" },
    { start = 97, prefix = "ActionButton" },
    { start = 109, prefix = "ActionButton" },
    { start = 121, prefix = "ActionButton" },
    { start = 133, prefix = "ActionButton" },
}

local function SlotToButton(slot)
    for _, range in ipairs(SLOT_RANGES) do
        if slot >= range.start and slot < range.start + 12 then
            return _G[range.prefix .. (slot - range.start + 1)]
        end
    end
    return nil
end

local function GetButtonActionSlot(btn)
    if not btn then return nil end
    if btn.GetAction and type(btn.GetAction) == "function" then
        local ok, slot = pcall(btn.GetAction, btn)
        if ok and type(slot) == "number" and slot > 0 then return slot end
    end
    if type(btn.action) == "number" and btn.action > 0 then
        return btn.action
    end
    if btn.GetAttribute then
        local attr = btn:GetAttribute("action")
        if type(attr) == "number" and attr > 0 then return attr end
    end
    return nil
end

local BAR_PREFIXES = {
    "ActionButton",
    "MultiBarRightButton",
    "MultiBarLeftButton",
    "MultiBarBottomRightButton",
    "MultiBarBottomLeftButton",
    "MultiBar5Button",
    "MultiBar6Button",
    "MultiBar7Button",
}

local ELVUI_PREFIXES = {}
for i = 1, 10 do
    ELVUI_PREFIXES[#ELVUI_PREFIXES + 1] = "ElvUI_Bar" .. i .. "Button"
end

local function ScanAllBarButtons()
    local allButtons = {}
    local seen = {}

    for _, prefix in ipairs(BAR_PREFIXES) do
        for i = 1, 12 do
            local btn = _G[prefix .. i]
            if btn and not seen[btn] then
                seen[btn] = true
                allButtons[#allButtons + 1] = btn
            end
        end
    end

    for _, prefix in ipairs(ELVUI_PREFIXES) do
        for i = 1, 12 do
            local btn = _G[prefix .. i]
            if btn and not seen[btn] then
                seen[btn] = true
                allButtons[#allButtons + 1] = btn
            end
        end
    end

    return allButtons
end

-- ============================================================================
-- Auto-detect interrupt spell
-- ============================================================================

local function IsSpellAvailable(info)
    if info.pet then
        local ok, known = pcall(IsSpellKnown, info.id, true)
        if ok and known then return true end
        local ok2, known2 = pcall(IsPlayerSpell, info.id)
        if ok2 and known2 then return true end
        return false
    end
    return IsPlayerSpell(info.id)
end

local function DetectInterrupt()
    local _, classToken = UnitClass("player")
    MedaAuras.LogDebug(format("[FIH] DetectInterrupt: player class = %s", tostring(classToken)))

    for _, info in ipairs(INTERRUPTS) do
        if info.class == classToken then
            local known = IsSpellAvailable(info)
            MedaAuras.LogDebug(format("[FIH] Checking %s (ID %d, class %s, pet %s): known = %s",
                info.name, info.id, info.class, tostring(info.pet or false), tostring(known)))
            if known then
                MedaAuras.Log(format("[FIH] Detected interrupt: %s (ID %d)", info.name, info.id))
                return info
            end
        end
    end

    MedaAuras.LogDebug("[FIH] No class match, trying fallback (all classes)")
    for _, info in ipairs(INTERRUPTS) do
        local known = IsSpellAvailable(info)
        if known then
            MedaAuras.Log(format("[FIH] Fallback detected: %s (ID %d)", info.name, info.id))
            return info
        end
    end

    MedaAuras.LogWarn("[FIH] No interrupt spell detected for this character")
    return nil
end

-- ============================================================================
-- Icon texture resolution
-- ============================================================================

local function ResolveSpellTexture(spellID)
    if not spellID then return nil end
    local tex = C_Spell.GetSpellTexture(spellID)
    if tex then return tex end
    if C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
        if ok and info and info.iconID then return info.iconID end
    end
    return nil
end

local function ResolveIconTexture(db)
    if db.iconSpellID then
        local tex = ResolveSpellTexture(db.iconSpellID)
        if tex then return tex end
    end
    if activeSpellTexture then return activeSpellTexture end
    if activeSpellID then
        local tex = ResolveSpellTexture(activeSpellID)
        if tex then return tex end
    end
    local _, classToken = UnitClass("player")
    for _, info in ipairs(INTERRUPTS) do
        if info.class == classToken then
            local tex = ResolveSpellTexture(info.id)
            if tex then return tex end
            if info.altIDs then
                for _, altID in ipairs(info.altIDs) do
                    tex = ResolveSpellTexture(altID)
                    if tex then return tex end
                end
            end
        end
    end
    return 134400
end

-- ============================================================================
-- Icon Frame (Mode: "icon")
-- ============================================================================

local function CreateIconFrame(db)
    if iconFrame then return iconFrame end

    local f = CreateFrame("Frame", "MedaAurasInterruptIcon", UIParent, "BackdropTemplate")
    f:SetSize(db.iconSize, db.iconSize)
    f:SetBackdrop(MedaUI:CreateBackdrop(true))
    f:SetBackdropColor(0, 0, 0, 0.6)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetPoint("TOPLEFT", 3, -3)
    f.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    f.colorOverlay = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.colorOverlay:SetPoint("TOPLEFT", f.icon, "TOPLEFT")
    f.colorOverlay:SetPoint("BOTTOMRIGHT", f.icon, "BOTTOMRIGHT")
    f.colorOverlay:SetColorTexture(0, 0, 0, 0)

    f.cdText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.cdText:SetPoint("CENTER", 0, 0)
    f.cdText:SetTextColor(1, 1, 1, 1)
    f.cdText:SetShadowOffset(1, -1)

    -- Dragging
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if not db.locked then
            self:StartMoving()
        end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        db.position.point = point
        db.position.x = x
        db.position.y = y
    end)

    -- Restore position
    f:ClearAllPoints()
    f:SetPoint(db.position.point, UIParent, db.position.point, db.position.x, db.position.y)

    f.icon:SetTexture(ResolveIconTexture(db))

    iconFrame = f
    return f
end

local function UpdateIconSize(db)
    if iconFrame then
        iconFrame:SetSize(db.iconSize, db.iconSize)
    end
end

local function ShowIconFrame(db)
    local f = CreateIconFrame(db)
    f:Show()
end

local function HideIconFrame()
    if iconFrame then iconFrame:Hide() end
end

local ICON_OVERLAY_ALPHA = 0.4

local function SetIconState(state, remaining, db)
    if not iconFrame then return end

    local onCD = remaining and remaining > 0

    -- CD text always shows while the spell is on cooldown
    if onCD then
        iconFrame.cdText:SetText(format("%.1f", remaining))
    else
        iconFrame.cdText:SetText("")
    end

    -- When no target/range info but on CD, promote to "oncd" so
    -- the icon shows the cooldown color instead of going dim.
    if state == "hidden" and onCD then
        state = "oncd"
    end

    if state == "hidden" then
        iconFrame:SetBackdropBorderColor(unpack(MedaUI.Theme.textDim))
        iconFrame.colorOverlay:SetColorTexture(0, 0, 0, 0)
        iconFrame.colorOverlay:Hide()
        return
    end

    local c
    if state == "ready" then
        c = db.colorReady
    elseif state == "oor" then
        c = db.colorOOR
    elseif state == "oncd" then
        c = db.colorOnCD
    end

    if c then
        iconFrame:SetBackdropBorderColor(c.r, c.g, c.b, 1)
        iconFrame.colorOverlay:SetColorTexture(c.r, c.g, c.b, ICON_OVERLAY_ALPHA)
        iconFrame.colorOverlay:Show()
    end
end

-- Forward declarations for CDM functions (defined after hook mode section)
local ScanAllCDMViewers
local StartCDMScanning

-- ============================================================================
-- Action Bar Overlay (Mode: "overlay")
-- ============================================================================

local cachedButtons = {}

local WARLOCK_INTERRUPT_IDS = {
    [119910] = true, [19647] = true, [119898] = true,
    [89766] = true, [1276467] = true,
}

local function MatchSpellID(id)
    if not id then return false end
    if id == activeSpellID then return true end
    if WARLOCK_INTERRUPT_IDS[activeSpellID] and WARLOCK_INTERRUPT_IDS[id] then return true end
    if activeSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, id)
        if ok and name and name == activeSpellName then return true end
    end
    if C_Spell.GetOverrideSpell then
        local ok, overrideID = pcall(C_Spell.GetOverrideSpell, id)
        if ok and overrideID and overrideID ~= id then
            if overrideID == activeSpellID then return true end
            if WARLOCK_INTERRUPT_IDS[activeSpellID] and WARLOCK_INTERRUPT_IDS[overrideID] then return true end
        end
    end
    return false
end

local function MatchButtonToSpell(btn)
    local actionSlot = GetButtonActionSlot(btn)
    if not actionSlot or not HasAction(actionSlot) then return false end

    local actionType, id = GetActionInfo(actionSlot)
    if actionType == "spell" then
        if MatchSpellID(id) then return true end
    elseif actionType == "macro" and id then
        local ok, macroSpell = pcall(GetMacroSpell, id)
        if ok and macroSpell then
            if MatchSpellID(macroSpell) then return true end
        end
    end
    return false
end

local function ScanActionButtons()
    wipe(cachedButtons)
    wipe(cdmSeen)
    if not activeSpellID then
        MedaAuras.LogDebug("[FIH:Overlay] ScanActionButtons: no activeSpellID")
        return
    end

    -- Primary method: Blizzard API slot lookup (try active ID + warlock alternates)
    local idsToTry = { activeSpellID }
    if WARLOCK_INTERRUPT_IDS[activeSpellID] then
        for id in pairs(WARLOCK_INTERRUPT_IDS) do
            if id ~= activeSpellID then
                idsToTry[#idsToTry + 1] = id
            end
        end
    end

    local seenBtn = {}
    for _, tryID in ipairs(idsToTry) do
        local ok, slots = pcall(C_ActionBar.FindSpellActionButtons, tryID)
        if ok and slots and #slots > 0 then
            MedaAuras.LogDebug(format("[FIH:Overlay] FindSpellActionButtons(%d) returned %d slot(s)", tryID, #slots))
            for _, slot in ipairs(slots) do
                local btn = SlotToButton(slot)
                if btn and not seenBtn[btn] then
                    seenBtn[btn] = true
                    MedaAuras.LogDebug(format("[FIH:Overlay] Slot %d -> %s", slot, btn:GetName() or "unnamed"))
                    cachedButtons[#cachedButtons + 1] = btn
                end
            end
        end
    end

    -- Fallback: iterate all bar buttons and match by action info (catches macros & pet spells)
    if #cachedButtons == 0 then
        MedaAuras.LogDebug("[FIH:Overlay] API scan empty, trying brute-force")
        local allButtons = ScanAllBarButtons()
        for _, btn in ipairs(allButtons) do
            if MatchButtonToSpell(btn) then
                MedaAuras.LogDebug(format("[FIH:Overlay] Match: %s", btn:GetName() or "unnamed"))
                cachedButtons[#cachedButtons + 1] = btn
            end
        end
    end

    -- Also scan CDM viewers
    ScanAllCDMViewers()

    if #cachedButtons == 0 then
        MedaAuras.LogWarn(format("[FIH:Overlay] No buttons/icons found for spell %d (%s)",
            activeSpellID, activeSpellName or "?"))
    else
        MedaAuras.Log(format("[FIH:Overlay] Tracking %d button(s)/icon(s)", #cachedButtons))
    end
end

local function GetOrCreateOverlay(button)
    if overlayTextures[button] then
        return overlayTextures[button].texture
    end

    local container = CreateFrame("Frame", nil, button)
    container:SetFrameStrata(button:GetFrameStrata())
    container:SetFrameLevel(button:GetFrameLevel() + 10)
    container:SetAllPoints(button)

    local overlay = container:CreateTexture(nil, "OVERLAY", nil, 7)
    overlay:SetTexture("Interface\\Buttons\\WHITE8X8")
    overlay:SetAllPoints(container)

    overlayTextures[button] = { container = container, texture = overlay }

    MedaAuras.LogDebug(format("[FIH:Overlay] Created overlay on %s (level %d+10, strata %s)",
        button:GetName() or "unnamed", button:GetFrameLevel(), button:GetFrameStrata()))

    return overlay
end

local function HideAllOverlays()
    for _, data in pairs(overlayTextures) do
        data.texture:Hide()
        data.container:Hide()
    end
end

local function ShowOverlayMode(db)
    MedaAuras.Log("[FIH:Overlay] ShowOverlayMode called")
    ScanActionButtons()
    StartCDMScanning()

    if not actionBarFrame then
        actionBarFrame = CreateFrame("Frame")
        actionBarFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
        actionBarFrame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
        actionBarFrame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
        actionBarFrame:RegisterEvent("SPELL_UPDATE_USABLE")
        actionBarFrame:SetScript("OnEvent", function(_, event)
            MedaAuras.LogDebug(format("[FIH:Overlay] Re-scanning buttons due to %s", event))
            ScanActionButtons()
        end)
    end
    actionBarFrame:Show()

    -- Delayed re-scan in case bars weren't ready
    if #cachedButtons == 0 then
        C_Timer.After(0.5, function()
            if #cachedButtons == 0 and db.enabled and db.displayMode == "overlay" then
                MedaAuras.LogDebug("[FIH:Overlay] Delayed re-scan triggered")
                ScanActionButtons()
            end
        end)
        C_Timer.After(2, function()
            if #cachedButtons == 0 and db.enabled and db.displayMode == "overlay" then
                MedaAuras.LogDebug("[FIH:Overlay] Second delayed re-scan (2s)")
                ScanActionButtons()
            end
        end)
    end
end

local function HideOverlayMode()
    HideAllOverlays()
    if actionBarFrame then
        actionBarFrame:Hide()
    end
end

local overlayLogThrottle = 0

local function SetOverlayState(state, db)
    local alpha = db.overlayAlpha
    local c

    if state == "ready" then
        c = db.colorReady
    elseif state == "oor" then
        c = db.colorOOR
    elseif state == "oncd" then
        c = db.colorOnCD
    end

    local now = GetTime()
    if now - overlayLogThrottle > 5 then
        overlayLogThrottle = now
        MedaAuras.LogDebug(format("[FIH:Overlay] SetOverlayState(%s) buttons=%d alpha=%.2f",
            state, #cachedButtons, alpha))
    end

    for _, button in ipairs(cachedButtons) do
        local ok, err = pcall(function()
            local overlayTex = GetOrCreateOverlay(button)
            local data = overlayTextures[button]
            if state == "hidden" or not c then
                overlayTex:Hide()
                if data then data.container:Hide() end
            else
                overlayTex:SetVertexColor(c.r, c.g, c.b, alpha)
                overlayTex:Show()
                if data then data.container:Show() end
            end
        end)
        if not ok then
            MedaAuras.LogWarn(format("[FIH:Overlay] Error on %s: %s",
                button:GetName() or "unnamed", tostring(err)))
        end
    end
end

-- ============================================================================
-- Cooldown Hook Mode (Mode: "hook")
-- Hooks action button updates to reliably detect the interrupt button,
-- then reuses the overlay texture system for the color wash.
-- ============================================================================

local function CheckButtonForSpell(btn)
    if not hookActive or not activeSpellID then return end
    if not btn then return end

    if not MatchButtonToSpell(btn) then return end

    for _, cached in ipairs(cachedButtons) do
        if cached == btn then return end
    end
    cachedButtons[#cachedButtons + 1] = btn
    MedaAuras.LogDebug(format("[FIH:Hook] Detected interrupt on %s",
        btn:GetName() or "unnamed"))
end

local function RescanAllButtonsForHook()
    wipe(cachedButtons)
    wipe(cdmSeen)
    local allBtns = ScanAllBarButtons()
    if allBtns then
        for _, btn in ipairs(allBtns) do
            CheckButtonForSpell(btn)
        end
    end
    ScanAllCDMViewers()
end

local function InstallButtonHooks()
    if hooksInstalled then return end
    hooksInstalled = true

    MedaAuras.Log("[FIH:Hook] Installing action button hooks")

    local count = 0
    local hookCount = 0
    local allButtons = ScanAllBarButtons()

    for _, btn in ipairs(allButtons) do
        count = count + 1
        local hooked = false

        local methodsToTry = { "UpdateAction", "Update", "UpdateState" }
        for _, method in ipairs(methodsToTry) do
            if type(btn[method]) == "function" then
                hooksecurefunc(btn, method, function(self)
                    CheckButtonForSpell(self)
                end)
                hooked = true
            end
        end

        if hooked then
            hookCount = hookCount + 1
        end
    end

    MedaAuras.Log(format("[FIH:Hook] Found %d buttons, hooked %d", count, hookCount))
end

local function ShowHookMode(db)
    MedaAuras.Log("[FIH:Hook] ShowHookMode called")
    wipe(cachedButtons)
    wipe(cdmSeen)
    hookActive = true

    InstallButtonHooks()

    RescanAllButtonsForHook()
    StartCDMScanning()
    MedaAuras.Log(format("[FIH:Hook] Initial scan found %d button(s)/icon(s)", #cachedButtons))

    if not hookEventFrame then
        hookEventFrame = CreateFrame("Frame")
        hookEventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
        hookEventFrame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
        hookEventFrame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
        hookEventFrame:RegisterEvent("SPELL_UPDATE_USABLE")
        hookEventFrame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
        hookEventFrame:SetScript("OnEvent", function(_, event)
            if not hookActive then return end
            MedaAuras.LogDebug(format("[FIH:Hook] Re-scanning due to %s", event))
            RescanAllButtonsForHook()
        end)
    end
    hookEventFrame:Show()

    if #cachedButtons == 0 then
        C_Timer.After(0.5, function()
            if hookActive and #cachedButtons == 0 then
                MedaAuras.LogDebug("[FIH:Hook] Delayed re-scan (0.5s)")
                RescanAllButtonsForHook()
            end
        end)
        C_Timer.After(2, function()
            if hookActive and #cachedButtons == 0 then
                MedaAuras.LogDebug("[FIH:Hook] Delayed re-scan (2s)")
                RescanAllButtonsForHook()
            end
        end)
    end
end

local function HideHookMode()
    hookActive = false
    HideAllOverlays()
    if hookEventFrame then
        hookEventFrame:Hide()
    end
end

-- ============================================================================
-- CooldownViewer (CDM) Overlay
-- Scans Blizzard CooldownViewer frames for the interrupt icon and adds
-- matching icons to cachedButtons so SetOverlayState colours them.
-- ============================================================================

local CDM_VIEWERS = {
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
}

local function GetSpellIDFromCDMIcon(icon)
    if not icon then return nil end
    if icon.cooldownID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(icon.cooldownID)
        if info and info.spellID then
            return info.spellID
        end
    end
    if icon.spellID then return icon.spellID end
    if icon.GetSpellID and type(icon.GetSpellID) == "function" then
        local ok, id = pcall(icon.GetSpellID, icon)
        if ok and id then return id end
    end
    return nil
end

local function ScanCDMViewer(viewerFrame)
    if not viewerFrame or not activeSpellID then return end

    local function ScanChildren(parent, depth)
        if depth > 4 then return end
        local ok, children = pcall(function() return { parent:GetChildren() } end)
        if not ok or not children then return end

        for _, child in ipairs(children) do
            local spellID = GetSpellIDFromCDMIcon(child)
            if spellID then
                local isMatch = (spellID == activeSpellID)
                if not isMatch and activeSpellName then
                    local name = C_Spell.GetSpellName(spellID)
                    isMatch = (name and name == activeSpellName)
                end
                if not isMatch and C_Spell.GetOverrideSpell then
                    local overrideID = C_Spell.GetOverrideSpell(spellID)
                    isMatch = (overrideID == activeSpellID)
                end
                if isMatch and not cdmSeen[child] then
                    cdmSeen[child] = true
                    cachedButtons[#cachedButtons + 1] = child
                    MedaAuras.LogDebug(format("[FIH:CDM] Found interrupt icon in %s (%s)",
                        viewerFrame:GetName() or "CDM", child:GetName() or "unnamed"))
                end
            else
                ScanChildren(child, depth + 1)
            end
        end
    end

    ScanChildren(viewerFrame, 0)
end

ScanAllCDMViewers = function()
    for _, name in ipairs(CDM_VIEWERS) do
        local vf = _G[name]
        if vf then
            ScanCDMViewer(vf)
        end
    end
end

local function HookCDMViewers()
    if cdmHooked then return end

    local hookedAny = false
    for _, name in ipairs(CDM_VIEWERS) do
        local vf = _G[name]
        if vf then
            MedaAuras.Log(format("[FIH:CDM] Hooking viewer: %s", name))

            if vf.RefreshLayout then
                hooksecurefunc(vf, "RefreshLayout", function()
                    C_Timer.After(0, ScanAllCDMViewers)
                end)
            end
            if vf.UpdateIcons then
                hooksecurefunc(vf, "UpdateIcons", function()
                    C_Timer.After(0, ScanAllCDMViewers)
                end)
            end

            vf:HookScript("OnShow", function()
                C_Timer.After(0.1, ScanAllCDMViewers)
            end)

            local container = vf.Container
            if container and container.UpdateLayout then
                hooksecurefunc(container, "UpdateLayout", function()
                    C_Timer.After(0, ScanAllCDMViewers)
                end)
            end

            hookedAny = true
        end
    end

    if hookedAny then
        cdmHooked = true
        ScanAllCDMViewers()
    end
end

StartCDMScanning = function()
    HookCDMViewers()

    if not cdmHooked then
        local attempts = 0
        local ticker
        ticker = C_Timer.NewTicker(1, function()
            attempts = attempts + 1
            HookCDMViewers()
            if cdmHooked or attempts >= 15 then
                ticker:Cancel()
                if cdmHooked then
                    MedaAuras.Log("[FIH:CDM] Viewers hooked successfully")
                else
                    MedaAuras.LogDebug("[FIH:CDM] No CDM viewers found after retries")
                end
            end
        end)
    end
end

-- ============================================================================
-- Update Ticker
-- ============================================================================

local function StartTicker(db)
    if updateTicker then return end

    local CooldownTimer = ns.Services.CooldownTimer
    local UnitPriorityService = ns.Services.UnitPriority

    local isIconMode = (db.displayMode == "icon")

    updateTicker = C_Timer.NewTicker(0.1, function()
        if not activeSpellID then return end

        -- Always compute cooldown state first -- the timer persists
        -- regardless of target/range and only expires naturally or
        -- when a new cast is detected by CooldownTimer.
        local onCD = not CooldownTimer:IsReady(activeSpellID)
        local remaining = onCD and CooldownTimer:GetRemaining(activeSpellID) or 0

        local unit
        if db.focusOnly then
            unit = UnitExists("focus") and "focus" or nil
        else
            unit = UnitPriorityService:FocusOrTarget()
        end

        -- Focus-only: fully hide everything when no focus exists
        if db.focusOnly and not unit then
            if isIconMode then
                if iconFrame then iconFrame:Hide() end
            else
                SetOverlayState("hidden", db)
            end
            return
        end

        -- Restore icon visibility if it was hidden by focus-only
        if isIconMode and iconFrame and not iconFrame:IsShown() then
            iconFrame:Show()
        end

        local state

        if not unit then
            state = "hidden"
        else
            local ok, inRange = pcall(C_Spell.IsSpellInRange, activeSpellID, unit)
            if not ok then inRange = nil end

            if activeIsPetSpell and inRange == nil then
                local petUnit = "pet"
                if UnitExists(petUnit) then
                    local checkOk, checkRange = pcall(C_Spell.IsSpellInRange, 19647, unit)
                    if checkOk and checkRange ~= nil then
                        inRange = checkRange
                    else
                        inRange = UnitExists(unit) and true or nil
                    end
                else
                    inRange = nil
                end
            end

            if inRange == nil then
                state = "hidden"
            elseif not inRange then
                state = "oor"
            elseif onCD then
                state = "oncd"
            else
                state = "ready"
            end
        end

        if isIconMode then
            SetIconState(state, remaining, db)
        else
            SetOverlayState(state, db)
        end
    end)
end

local function StopTicker()
    if updateTicker then
        updateTicker:Cancel()
        updateTicker = nil
    end
end

-- ============================================================================
-- Module Lifecycle
-- ============================================================================

local function OnInitialize(db)
    MedaAuras.Log("[FIH] OnInitialize called")
    MedaAuras.LogDebug(format("[FIH] DB state: displayMode=%s, spellID=%s, cooldownDuration=%s",
        tostring(db.displayMode), tostring(db.spellID), tostring(db.cooldownDuration)))

    local info
    if db.spellID then
        MedaAuras.LogDebug(format("[FIH] Manual spellID override: %d", db.spellID))
        for _, entry in ipairs(INTERRUPTS) do
            if entry.id == db.spellID then
                info = entry
                break
            end
        end
    end

    if not info then
        info = DetectInterrupt()
    end

    if info then
        activeSpellID = info.id
        activeSpellName = info.name
        activeIsPetSpell = info.pet or false
        activeSpellTexture = ResolveSpellTexture(info.id)
        if not activeSpellTexture and info.altIDs then
            for _, altID in ipairs(info.altIDs) do
                activeSpellTexture = ResolveSpellTexture(altID)
                if activeSpellTexture then break end
            end
        end

        if not db.cooldownManual or not db.cooldownDuration then
            db.cooldownDuration = info.baseCD
            MedaAuras.Log(format("[FIH] Using detected CD: %ds for %s", info.baseCD, info.name))
        else
            MedaAuras.Log(format("[FIH] Using manual CD override: %ds (detected: %ds)",
                db.cooldownDuration, info.baseCD))
        end

        MedaAuras.LogDebug(format("[FIH] Registering with CooldownTimer: spellID=%d, duration=%d",
            activeSpellID, db.cooldownDuration))
        ns.Services.CooldownTimer:Track(activeSpellID, db.cooldownDuration)
    else
        MedaAuras.LogWarn("[FIH] No interrupt spell found. Frame will show placeholder.")
    end

    MedaAuras.LogDebug(format("[FIH] Creating display: mode=%s", db.displayMode))
    if db.displayMode == "icon" then
        ShowIconFrame(db)
        MedaAuras.Log("[FIH] Icon frame shown")
    elseif db.displayMode == "overlay" then
        ShowOverlayMode(db)
        MedaAuras.Log("[FIH] Overlay mode activated")
    elseif db.displayMode == "hook" then
        ShowHookMode(db)
        MedaAuras.Log("[FIH] Hook mode activated")
    end

    if activeSpellID then
        StartTicker(db)
        MedaAuras.Log(format("[FIH] Tracking %s (ID %d, CD %ds)",
            activeSpellName, activeSpellID, db.cooldownDuration))
    else
        MedaAuras.LogWarn("[FIH] No spell to track, ticker not started")
    end
end

local function OnEnable(db)
    MedaAuras.Log("[FIH] OnEnable called")
    OnInitialize(db)
end

local function OnDisable(db)
    MedaAuras.Log("[FIH] OnDisable called")
    StopTicker()
    HideIconFrame()
    HideOverlayMode()
    HideHookMode()
    activeSpellID = nil
    activeSpellName = nil
    activeIsPetSpell = false
    activeSpellTexture = nil
end

-- ============================================================================
-- Display Mode Switching
-- ============================================================================

local function HideCurrentMode(mode)
    if mode == "icon" then
        HideIconFrame()
    elseif mode == "overlay" then
        HideOverlayMode()
    elseif mode == "hook" then
        HideHookMode()
    end
end

local function ShowCurrentMode(mode, db)
    if mode == "icon" then
        ShowIconFrame(db)
    elseif mode == "overlay" then
        ShowOverlayMode(db)
    elseif mode == "hook" then
        ShowHookMode(db)
    end
end

local function SwitchDisplayMode(db, newMode)
    MedaAuras.Log(format("[FIH] SwitchDisplayMode: %s -> %s (enabled=%s, spell=%s)",
        tostring(db.displayMode), tostring(newMode),
        tostring(db.enabled), tostring(activeSpellID)))

    StopTicker()
    HideCurrentMode(db.displayMode)

    db.displayMode = newMode

    if not db.enabled or not activeSpellID then
        MedaAuras.LogWarn("[FIH] SwitchDisplayMode: aborting - module disabled or no spell")
        return
    end

    ShowCurrentMode(newMode, db)
    StartTicker(db)
end

-- ============================================================================
-- Module Defaults
-- ============================================================================

local MODULE_DEFAULTS = {
    enabled = false,
    displayMode = "icon",
    locked = false,
    position = { point = "CENTER", x = 0, y = 0 },
    iconSize = 48,
    overlayAlpha = 0.35,
    colorReady = { r = 0,   g = 0.8, b = 0   },
    colorOOR   = { r = 0.8, g = 0,   b = 0   },
    colorOnCD  = { r = 1,   g = 0.5, b = 0   },
    focusOnly = false,
    spellID = nil,
    cooldownDuration = nil,
    cooldownManual = false,
    iconSpellID = nil,
}

-- ============================================================================
-- Settings UI
-- ============================================================================

local function BuildConfig(parent, db)
    local LEFT_X, RIGHT_X = 0, 238
    local yOff = 0
    local UpdatePreviews

    local headerContainer = MedaUI:CreateSectionHeader(parent, "Focus Interrupt Helper")
    headerContainer:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 45

    local enableCB = MedaUI:CreateCheckbox(parent, "Enable Module")
    enableCB:SetPoint("TOPLEFT", LEFT_X, yOff)
    enableCB:SetChecked(db.enabled)
    enableCB.OnValueChanged = function(_, checked)
        if checked then MedaAuras:EnableModule("FocusInterruptHelper")
        else MedaAuras:DisableModule("FocusInterruptHelper") end
        MedaAuras:RefreshSidebarDot("FocusInterruptHelper")
    end
    yOff = yOff - 35

    local focusCB = MedaUI:CreateCheckbox(parent, "Focus target only")
    focusCB:SetPoint("TOPLEFT", LEFT_X, yOff)
    focusCB:SetChecked(db.focusOnly)
    focusCB.OnValueChanged = function(_, checked) db.focusOnly = checked end
    local modeDropdown = MedaUI:CreateLabeledDropdown(parent, "Display Mode", 200, {
        { value = "icon",    label = "Standalone Icon" },
        { value = "overlay", label = "Action Bar Overlay" },
        { value = "hook",    label = "Auto-Detect (CD Hook)" },
    })
    modeDropdown:SetPoint("TOPLEFT", RIGHT_X, yOff)
    modeDropdown:SetSelected(db.displayMode)
    yOff = yOff - 55

    local iconSettings = CreateFrame("Frame", nil, parent)
    iconSettings:SetPoint("TOPLEFT", LEFT_X, yOff)
    iconSettings:SetSize(470, 55)

    local overlaySettings = CreateFrame("Frame", nil, parent)
    overlaySettings:SetPoint("TOPLEFT", LEFT_X, yOff)
    overlaySettings:SetSize(470, 55)

    local hookDesc = overlaySettings:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hookDesc:SetPoint("TOPLEFT", RIGHT_X, 0)
    hookDesc:SetWidth(220)
    hookDesc:SetTextColor(unpack(MedaUI.Theme.textDim))
    hookDesc:SetText("Auto-Detect hooks action button updates to find your interrupt button automatically.")
    hookDesc:SetJustifyH("LEFT")
    hookDesc:SetWordWrap(true)

    local function UpdateModeVisibility()
        if db.displayMode == "icon" then
            iconSettings:Show()
            overlaySettings:Hide()
        else
            iconSettings:Hide()
            overlaySettings:Show()
            hookDesc:SetShown(db.displayMode == "hook")
        end
    end

    local lockCB = MedaUI:CreateCheckbox(iconSettings, "Lock Position")
    lockCB:SetPoint("TOPLEFT", LEFT_X, 0)
    lockCB:SetChecked(db.locked)
    lockCB.OnValueChanged = function(_, checked) db.locked = checked end

    local sizeSlider = MedaUI:CreateLabeledSlider(iconSettings, "Icon Size", 200, 24, 96, 4)
    sizeSlider:SetPoint("TOPLEFT", RIGHT_X, 0)
    sizeSlider:SetValue(db.iconSize)
    sizeSlider.OnValueChanged = function(_, value) db.iconSize = value; UpdateIconSize(db) end

    local alphaSlider = MedaUI:CreateLabeledSlider(overlaySettings, "Overlay Opacity", 200, 0.1, 0.8, 0.05)
    alphaSlider:SetPoint("TOPLEFT", LEFT_X, 0)
    alphaSlider:SetValue(db.overlayAlpha)
    alphaSlider.OnValueChanged = function(_, value) db.overlayAlpha = value end

    UpdateModeVisibility()
    modeDropdown.OnValueChanged = function(_, value)
        SwitchDisplayMode(db, value)
        UpdateModeVisibility()
    end

    yOff = yOff - 60

    local commonHeader = MedaUI:CreateSectionHeader(parent, "Cooldown & Colors")
    commonHeader:SetPoint("TOPLEFT", LEFT_X, yOff)
    yOff = yOff - 45

    local detectedCD = nil
    if activeSpellID then
        for _, entry in ipairs(INTERRUPTS) do
            if entry.id == activeSpellID then detectedCD = entry.baseCD; break end
        end
    end

    local autoCD = MedaUI:CreateCheckbox(parent, "Auto-detect cooldown")
    autoCD:SetPoint("TOPLEFT", LEFT_X, yOff)
    autoCD:SetChecked(not db.cooldownManual)
    local cdSlider = MedaUI:CreateLabeledSlider(parent, "Cooldown Duration (sec)", 200, 5, 120, 1)
    cdSlider:SetPoint("TOPLEFT", RIGHT_X, yOff)
    cdSlider:SetValue(db.cooldownDuration or detectedCD or 15)
    local autoCDHint = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    autoCDHint:SetPoint("TOPLEFT", autoCD, "BOTTOMLEFT", 22, -4)
    autoCDHint:SetTextColor(unpack(MedaUI.Theme.textDim))
    if detectedCD then autoCDHint:SetText(format("(detected: %ds)", detectedCD)) end
    yOff = yOff - 68

    local function UpdateCDSliderState()
        if not db.cooldownManual then
            if detectedCD then
                db.cooldownDuration = detectedCD
                cdSlider:SetValue(detectedCD)
                if activeSpellID then ns.Services.CooldownTimer:SetDuration(activeSpellID, detectedCD) end
            end
            cdSlider:SetAlpha(0.5)
        else
            cdSlider:SetAlpha(1)
        end
    end
    UpdateCDSliderState()

    cdSlider.OnValueChanged = function(_, value)
        db.cooldownDuration = value
        db.cooldownManual = true
        autoCD:SetChecked(false)
        cdSlider:SetAlpha(1)
        if activeSpellID then ns.Services.CooldownTimer:SetDuration(activeSpellID, value) end
    end
    autoCD.OnValueChanged = function(_, checked)
        db.cooldownManual = not checked
        UpdateCDSliderState()
    end

    local iconIDInput = MedaUI:CreateLabeledEditBox(parent, "Icon Spell ID (cosmetic only)", 180)
    iconIDInput:SetPoint("TOPLEFT", LEFT_X, yOff)
    iconIDInput:SetText(db.iconSpellID and tostring(db.iconSpellID) or "")
    iconIDInput:GetControl():SetPlaceholder("Auto-detect")
    iconIDInput.editBox = iconIDInput:GetControl()
    iconIDInput.editBox.editBox:SetNumeric(false)
    local iconIDHint = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    iconIDHint:SetPoint("TOPLEFT", iconIDInput, "TOPRIGHT", 10, -18)
    iconIDHint:SetTextColor(unpack(MedaUI.Theme.textDim))
    iconIDHint:SetText(db.iconSpellID and "" or "(using detected spell)")

    local function ApplyIconSpellID(text)
        local id = tonumber(text)
        if text == "" or not id then
            db.iconSpellID = nil
            iconIDHint:SetText("(using detected spell)")
        else
            local tex = C_Spell.GetSpellTexture(id)
            if tex then db.iconSpellID = id; iconIDHint:SetText("")
            else iconIDHint:SetText("|cffff4444Invalid spell ID|r"); return end
        end
        local newTex = ResolveIconTexture(db)
        if iconFrame and iconFrame.icon then iconFrame.icon:SetTexture(newTex) end
        if UpdatePreviews then UpdatePreviews() end
    end
    iconIDInput.OnEnterPressed = function(_, text) ApplyIconSpellID(text) end
    yOff = yOff - 58

    local readyColor = MedaUI:CreateLabeledColorPicker(parent, "In Range + Ready")
    readyColor:SetPoint("TOPLEFT", LEFT_X, yOff)
    readyColor:SetColor(db.colorReady.r, db.colorReady.g, db.colorReady.b)
    readyColor.OnColorChanged = function(_, r, g, b)
        db.colorReady = { r = r, g = g, b = b }
        if UpdatePreviews then UpdatePreviews() end
    end
    local oorColor = MedaUI:CreateLabeledColorPicker(parent, "Out of Range")
    oorColor:SetPoint("TOPLEFT", LEFT_X + 160, yOff)
    oorColor:SetColor(db.colorOOR.r, db.colorOOR.g, db.colorOOR.b)
    oorColor.OnColorChanged = function(_, r, g, b)
        db.colorOOR = { r = r, g = g, b = b }
        if UpdatePreviews then UpdatePreviews() end
    end
    local oncdColor = MedaUI:CreateLabeledColorPicker(parent, "In Range + On CD")
    oncdColor:SetPoint("TOPLEFT", LEFT_X + 320, yOff)
    oncdColor:SetColor(db.colorOnCD.r, db.colorOnCD.g, db.colorOnCD.b)
    oncdColor.OnColorChanged = function(_, r, g, b)
        db.colorOnCD = { r = r, g = g, b = b }
        if UpdatePreviews then UpdatePreviews() end
    end
    yOff = yOff - 48

    -- ================================================================
    -- Floating Side Preview (all 4 states)
    -- ================================================================
    local PREVIEW_SIZE = 46
    local PREVIEW_GAP = 12
    local previewIcons = {}
    local spellTex = ResolveIconTexture(db)

    local previewStates = {
        { key = "ready",  color = function() return db.colorReady end, label = "Ready",        cdText = "" },
        { key = "oor",    color = function() return db.colorOOR   end, label = "Out of Range", cdText = "" },
        { key = "oncd",   color = function() return db.colorOnCD  end, label = "On Cooldown",  cdText = "12.3" },
        { key = "hidden", color = nil,                                 label = "No Target",    cdText = "" },
    }

    local pvContainer
    do
        local anchor = MedaAurasSettingsPanel or _G["MedaAurasSettingsPanel"]
        if anchor then
            local PREVIEW_COLS = 2
            local PREVIEW_ROWS = 2
            local PV_PAD = 14
            local pvW = PV_PAD * 2 + PREVIEW_COLS * PREVIEW_SIZE + (PREVIEW_COLS - 1) * PREVIEW_GAP
            local pvH = PV_PAD + PREVIEW_ROWS * (PREVIEW_SIZE + 20) + (PREVIEW_ROWS - 1) * PREVIEW_GAP

            pvContainer = CreateFrame("Frame", nil, anchor)
            pvContainer:SetFrameStrata("HIGH")
            pvContainer:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 0)
            pvContainer:SetSize(pvW, pvH)

            for i, info in ipairs(previewStates) do
                local col = (i - 1) % PREVIEW_COLS
                local row = math.floor((i - 1) / PREVIEW_COLS)
                local xOff = PV_PAD + col * (PREVIEW_SIZE + PREVIEW_GAP)
                local pvYOff = -(PV_PAD + row * (PREVIEW_SIZE + 20 + PREVIEW_GAP))

                local f = CreateFrame("Frame", nil, pvContainer, "BackdropTemplate")
                f:SetSize(PREVIEW_SIZE, PREVIEW_SIZE)
                f:SetPoint("TOPLEFT", xOff, pvYOff)
                f:SetBackdrop(MedaUI:CreateBackdrop(true))
                f:SetBackdropColor(0, 0, 0, 0.6)

                f.icon = f:CreateTexture(nil, "ARTWORK")
                f.icon:SetPoint("TOPLEFT", 3, -3)
                f.icon:SetPoint("BOTTOMRIGHT", -3, 3)
                f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                f.icon:SetTexture(spellTex)

                f.colorOverlay = f:CreateTexture(nil, "ARTWORK", nil, 1)
                f.colorOverlay:SetPoint("TOPLEFT", f.icon, "TOPLEFT")
                f.colorOverlay:SetPoint("BOTTOMRIGHT", f.icon, "BOTTOMRIGHT")
                f.colorOverlay:SetColorTexture(0, 0, 0, 0)

                f.cdText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                f.cdText:SetPoint("CENTER", 0, 0)
                f.cdText:SetTextColor(1, 1, 1, 1)
                f.cdText:SetShadowOffset(1, -1)

                local label = pvContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                label:SetPoint("TOP", f, "BOTTOM", 0, -4)
                label:SetTextColor(unpack(MedaUI.Theme.textDim))
                label:SetText(info.label)

                previewIcons[i] = { frame = f, info = info }
            end
            pvContainer:Show()
        end
    end

    UpdatePreviews = function()
        local tex = ResolveIconTexture(db)
        for _, entry in ipairs(previewIcons) do
            local f = entry.frame
            local info = entry.info
            f.icon:SetTexture(tex)
            if info.key == "hidden" then
                f:SetBackdropBorderColor(unpack(MedaUI.Theme.textDim))
                f.colorOverlay:SetColorTexture(0, 0, 0, 0)
                f.colorOverlay:Hide()
                f.cdText:SetText("")
            else
                local c = info.color()
                f.cdText:SetText(info.cdText)
                if c then
                    f:SetBackdropBorderColor(c.r, c.g, c.b, 1)
                    f.colorOverlay:SetColorTexture(c.r, c.g, c.b, ICON_OVERLAY_ALPHA)
                    f.colorOverlay:Show()
                end
            end
        end
    end
    UpdatePreviews()

    if activeSpellName and activeSpellID then
        local infoLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        infoLabel:SetPoint("TOPLEFT", LEFT_X, yOff)
        infoLabel:SetTextColor(unpack(MedaUI.Theme.textDim))
        infoLabel:SetText(format("Detected: %s (ID %d)", activeSpellName, activeSpellID))
        yOff = yOff - 30
    end

    local resetBtn = MedaUI:CreateButton(parent, "Reset to Defaults")
    resetBtn:SetPoint("TOPLEFT", LEFT_X, yOff)
    resetBtn:SetScript("OnClick", function()
        for k, v in pairs(MODULE_DEFAULTS) do db[k] = MedaAuras.DeepCopy(v) end
        MedaAuras:ToggleSettings()
        MedaAuras:ToggleSettings()
    end)
    yOff = yOff - 45

    MedaAuras:SetContentHeight(math.abs(yOff))

    local sentinel = CreateFrame("Frame", nil, parent)
    sentinel:SetSize(1, 1)
    sentinel:SetPoint("TOPLEFT")
    sentinel:Show()
    sentinel:SetScript("OnHide", function()
        if pvContainer then
            pvContainer:Hide()
            pvContainer:SetParent(nil)
            pvContainer = nil
        end
    end)
end

-- ============================================================================
-- Register Module
-- ============================================================================

MedaAuras:RegisterModule({
    name = MODULE_NAME,
    title = "Focus Interrupt Helper",
    version = MODULE_VERSION,
    stability = MODULE_STABILITY,
    description = "Highlights your interrupt spell based on range and cooldown status of focus/target.",
    sidebarDesc = "Highlights your interrupt spell based on focus target interruptability.",
    defaults = MODULE_DEFAULTS,
    OnInitialize = OnInitialize,
    OnEnable = OnEnable,
    OnDisable = OnDisable,
    BuildConfig = BuildConfig,
})
