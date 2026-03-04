local _, ns = ...

local MedaUI = LibStub("MedaUI-1.0")
local Pixel = MedaUI.Pixel

-- ============================================================================
-- Constants
-- ============================================================================

local MODULE_NAME      = "ShutIt"
local MODULE_VERSION   = "1.1"
local MODULE_STABILITY = "beta"   -- "experimental" | "beta" | "stable"
local PREFIX = "|cffff6666Shut It:|r"

local MONSTER_EVENTS = {
    "CHAT_MSG_MONSTER_SAY",
    "CHAT_MSG_MONSTER_YELL",
    "CHAT_MSG_MONSTER_EMOTE",
    "CHAT_MSG_MONSTER_WHISPER",
    "CHAT_MSG_MONSTER_PARTY",
}

local EXPLORER_WIDTH = 520
local EXPLORER_HEIGHT = 500
local SIDEBAR_WIDTH = 150
local DETAIL_INSET = 10
local ROW_HEIGHT = 22
-- ============================================================================
-- State
-- ============================================================================

local db
local isEnabled = false

local eventFrame
local minimapButton
local explorerPanel
local indicatorFrame

local activeCaptureNPCName
local activeCaptureNPCID
local activeMutes = {}
local blockedCount = 0
local silencedNameLookup = {}

local selectedNPCID
local detailWidgets = {}
local sidebarButtons = {}
local sidebarScroll, sidebarContent

local talkingHeadHooked = false

-- ============================================================================
-- Helpers
-- ============================================================================

local function Log(msg)
    MedaAuras.Log(format("[ShutIt] %s", msg))
end

local function ParseNPCID(guid)
    if not guid then return nil end
    local unitType, _, _, _, _, npcID = strsplit("-", guid)
    if unitType == "Creature" or unitType == "Vehicle" then
        return npcID
    end
    return nil
end

local function GetTargetNPCInfo()
    if not UnitExists("target") then return nil, nil end
    local guid = UnitGUID("target")
    local npcID = ParseNPCID(guid)
    if not npcID then return nil, nil end
    local name = UnitName("target")
    return name, npcID
end

local function NPCNameToCreatureKey(name)
    if not name then return nil end
    return name:lower():gsub(" ", "_"):gsub("'", "")
end

local function LookupCreatureVO(name)
    local key = NPCNameToCreatureKey(name)
    return key and MedaAuras_CreatureVO and MedaAuras_CreatureVO[key]
end

local function RebuildNameLookup()
    wipe(silencedNameLookup)
    if not db or not db.silencedNPCs then return end
    for id, entry in pairs(db.silencedNPCs) do
        if entry.name then
            silencedNameLookup[entry.name] = id
        end
    end
end

local function IsNPCSilenced(name)
    return silencedNameLookup[name] ~= nil
end

local function GetEntryByName(name)
    local id = silencedNameLookup[name]
    if id and db.silencedNPCs[id] then
        return db.silencedNPCs[id], id
    end
    return nil, nil
end

local function SafeToString(val)
    if val == nil then return "" end
    local ok, str = pcall(tostring, val)
    return ok and str or ""
end

local function AddDetectedMessage(npcID, event, text)
    local entry = db.silencedNPCs[npcID]
    if not entry then return end
    local safeText = SafeToString(text)
    for _, msg in ipairs(entry.detectedMessages) do
        if msg.event == event and msg.text == safeText then return end
    end
    entry.detectedMessages[#entry.detectedMessages + 1] = {
        event = event,
        text = safeText,
    }
end

-- ============================================================================
-- Export / Import Serialization
-- ============================================================================

local EXPORT_PREFIX = "!SHUTIT1!"
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function Base64Encode(data)
    return ((data:gsub(".", function(x)
        local r, b = "", x:byte()
        for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
        return B64:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1])
end

local function Base64Decode(data)
    data = data:gsub("[^%w+/=]", "")
    return (data:gsub(".", function(x)
        if x == "=" then return "" end
        local r, f = "", (B64:find(x) - 1)
        for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then return "" end
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0) end
        return string.char(c)
    end))
end

local function EscapeMsgText(text)
    return text:gsub("\\", "\\\\"):gsub("|", "\\p"):gsub(";", "\\s")
end

local function UnescapeMsgText(text)
    return text:gsub("\\s", ";"):gsub("\\p", "|"):gsub("\\\\", "\\")
end

local function SerializeEntry(entry)
    local msgParts = {}
    for _, msg in ipairs(entry.detectedMessages or {}) do
        msgParts[#msgParts + 1] = (msg.event or "") .. ";" .. EscapeMsgText(msg.text or "")
    end
    local parts = {
        entry.npcID or "",
        entry.name or "",
        entry.silenceChat and "1" or "0",
        entry.silenceTalkingHead and "1" or "0",
        table.concat(entry.mutedSoundFileIDs or {}, ","),
        table.concat(entry.mutedSoundKitIDs or {}, ","),
        table.concat(msgParts, "|"),
    }
    return table.concat(parts, "\t")
end

local function SerializeAll()
    if not db or not db.silencedNPCs then return "" end
    local lines = {}
    for _, entry in pairs(db.silencedNPCs) do
        lines[#lines + 1] = SerializeEntry(entry)
    end
    return table.concat(lines, "\n")
end

local function DeserializeEntries(raw)
    local entries = {}
    for line in raw:gmatch("[^\n]+") do
        local parts = { strsplit("\t", line) }
        if #parts >= 4 then
            local fileIDs = {}
            if parts[5] and parts[5] ~= "" then
                for id in parts[5]:gmatch("%d+") do
                    fileIDs[#fileIDs + 1] = tonumber(id)
                end
            end
            local kitIDs = {}
            if parts[6] and parts[6] ~= "" then
                for id in parts[6]:gmatch("%d+") do
                    kitIDs[#kitIDs + 1] = tonumber(id)
                end
            end
            local messages = {}
            if parts[7] and parts[7] ~= "" then
                for chunk in parts[7]:gmatch("[^|]+") do
                    local ev, txt = chunk:match("^([^;]*);(.*)")
                    if ev then
                        messages[#messages + 1] = {
                            event = ev,
                            text = UnescapeMsgText(txt),
                        }
                    end
                end
            end
            entries[#entries + 1] = {
                npcID = parts[1],
                name = parts[2],
                silenceChat = parts[3] == "1",
                silenceTalkingHead = parts[4] == "1",
                mutedSoundFileIDs = fileIDs,
                mutedSoundKitIDs = kitIDs,
                detectedMessages = messages,
                dateAdded = time(),
            }
        end
    end
    return entries
end

local function BuildExportString(serialized)
    return EXPORT_PREFIX .. Base64Encode(serialized)
end

local function ParseImportString(str)
    str = str:trim()
    if not str:find("^!SHUTIT1!") then
        return nil, "Invalid import string (missing header)."
    end
    local encoded = str:sub(#EXPORT_PREFIX + 1)
    local decoded = Base64Decode(encoded)
    if not decoded or decoded == "" then
        return nil, "Failed to decode import string."
    end
    return DeserializeEntries(decoded)
end

-- ============================================================================
-- Sound Mute Management
-- ============================================================================

local function ApplyMutesForEntry(entry)
    if not entry then return end
    for _, fileID in ipairs(entry.mutedSoundFileIDs or {}) do
        if not activeMutes[fileID] then
            MuteSoundFile(fileID)
            activeMutes[fileID] = true
        end
    end
    for _, kitID in ipairs(entry.mutedSoundKitIDs or {}) do
        if not activeMutes[kitID] then
            MuteSoundFile(kitID)
            activeMutes[kitID] = true
        end
    end
end

local function RemoveMutesForEntry(entry)
    if not entry then return end
    for _, fileID in ipairs(entry.mutedSoundFileIDs or {}) do
        if activeMutes[fileID] then
            UnmuteSoundFile(fileID)
            activeMutes[fileID] = nil
        end
    end
    for _, kitID in ipairs(entry.mutedSoundKitIDs or {}) do
        if activeMutes[kitID] then
            UnmuteSoundFile(kitID)
            activeMutes[kitID] = nil
        end
    end
end

local function ApplyAllMutes()
    if not db or not db.silencedNPCs then return end
    for _, entry in pairs(db.silencedNPCs) do
        ApplyMutesForEntry(entry)
    end
end

local function RemoveAllMutes()
    for id in pairs(activeMutes) do
        UnmuteSoundFile(id)
    end
    wipe(activeMutes)
end

-- ============================================================================
-- Chat Suppression
-- ============================================================================

local function ChatFilter(_, _, msg, sender, ...)
    if not isEnabled or not db then return false end
    local guid = select(10, ...)
    local npcID = ParseNPCID(guid)
    if npcID then
        local entry = db.silencedNPCs[npcID]
        if entry and entry.silenceChat then
            blockedCount = blockedCount + 1
            UpdateIndicatorCount()
            return true
        end
    end
    return false
end

local chatFiltersInstalled = false

local function InstallChatFilters()
    if chatFiltersInstalled then return end
    for _, event in ipairs(MONSTER_EVENTS) do
        ChatFrame_AddMessageEventFilter(event, ChatFilter)
    end
    chatFiltersInstalled = true
end

local function RemoveChatFilters()
    if not chatFiltersInstalled then return end
    for _, event in ipairs(MONSTER_EVENTS) do
        ChatFrame_RemoveMessageEventFilter(event, ChatFilter)
    end
    chatFiltersInstalled = false
end

-- ============================================================================
-- Talking Head Suppression
-- ============================================================================

local function HookTalkingHead()
    if talkingHeadHooked then return end
    local frame = TalkingHeadFrame
    if not frame then return end
    hooksecurefunc(frame, "PlayCurrent", function()
        if not isEnabled or not db then return end
        local nameInfo = frame.NameFrame and frame.NameFrame.Name
        local npcName = nameInfo and nameInfo:GetText()
        if not npcName then return end
        local entry = GetEntryByName(npcName)
        if entry and entry.silenceTalkingHead then
            frame:Hide()
            if frame.voHandle then
                C_Timer.After(0.025, function()
                    if frame.voHandle then
                        StopSound(frame.voHandle)
                    end
                end)
            end
        end
    end)
    talkingHeadHooked = true
end

-- ============================================================================
-- Live Capture
-- ============================================================================

local function UpdateIndicatorCount()
    if indicatorFrame and indicatorFrame:IsShown() then
        indicatorFrame.countText:SetText(blockedCount .. " blocked")
    end
end

local function StartLiveCapture(npcName, npcID)
    local safeName = SafeToString(npcName)
    activeCaptureNPCName = safeName
    activeCaptureNPCID = npcID
    blockedCount = 0

    if indicatorFrame then
        indicatorFrame.nameText:SetText("Silencing: " .. safeName)
        indicatorFrame.countText:SetText("0 blocked")
        indicatorFrame:Show()
    end
    Log(format("Live capture started for %s (ID: %s)", safeName, tostring(npcID)))
end

local function StopLiveCapture()
    if not activeCaptureNPCName then return end
    Log(format("Live capture stopped for %s", SafeToString(activeCaptureNPCName)))
    activeCaptureNPCName = nil
    activeCaptureNPCID = nil
    blockedCount = 0
    if indicatorFrame then
        indicatorFrame:Hide()
    end
end

local function SilenceNPC(npcName, npcID)
    if not db then return false end
    local safeName = SafeToString(npcName)
    if db.silencedNPCs[npcID] then return false end

    local voIDs = LookupCreatureVO(safeName)
    local fileIDs = {}
    if voIDs then
        for i, id in ipairs(voIDs) do
            fileIDs[i] = id
        end
    end

    db.silencedNPCs[npcID] = {
        name = safeName,
        npcID = npcID,
        silenceChat = true,
        silenceTalkingHead = true,
        mutedSoundFileIDs = fileIDs,
        mutedSoundKitIDs = {},
        detectedMessages = {},
        dateAdded = time(),
    }
    RebuildNameLookup()
    ApplyMutesForEntry(db.silencedNPCs[npcID])
    MedaAuras:RefreshModuleConfig()

    if voIDs then
        print(format("%s %s silenced with %d voice files.", PREFIX, safeName, #voIDs))
        return true
    else
        print(format("%s %s has been silenced.", PREFIX, safeName))
        return false
    end
end

local function UnsilenceNPC(npcID)
    if not db or not db.silencedNPCs[npcID] then return end
    local entry = db.silencedNPCs[npcID]
    local npcName = entry.name
    RemoveMutesForEntry(entry)
    if activeCaptureNPCID == npcID then
        StopLiveCapture()
    end
    db.silencedNPCs[npcID] = nil
    RebuildNameLookup()
    MedaAuras:RefreshModuleConfig()
    print(format("%s %s has been unsilenced.", PREFIX, npcName or npcID))
end

-- ============================================================================
-- Event Handling
-- ============================================================================

local function OnEvent(self, event, ...)
    if not isEnabled then return end

    if event == "CHAT_MSG_MONSTER_SAY" or event == "CHAT_MSG_MONSTER_YELL"
        or event == "CHAT_MSG_MONSTER_EMOTE" or event == "CHAT_MSG_MONSTER_WHISPER"
        or event == "CHAT_MSG_MONSTER_PARTY" then
        local msg = ...
        local guid = select(12, ...)
        local npcID = ParseNPCID(guid)
        if npcID and activeCaptureNPCID and npcID == activeCaptureNPCID then
            AddDetectedMessage(activeCaptureNPCID, event, msg)
            blockedCount = blockedCount + 1
            UpdateIndicatorCount()
        end

    elseif event == "GOSSIP_SHOW" then
        if activeCaptureNPCName then
            local text = C_GossipInfo and C_GossipInfo.GetText and C_GossipInfo.GetText()
            if text and text ~= "" then
                AddDetectedMessage(activeCaptureNPCID, "GOSSIP_SHOW", text)
            end
        end

    elseif event == "TALKINGHEAD_REQUESTED" then
        C_Timer.After(0.05, function()
            if not TalkingHeadFrame or not activeCaptureNPCID then return end
            local nameInfo = TalkingHeadFrame.NameFrame and TalkingHeadFrame.NameFrame.Name
            local npcName = nameInfo and nameInfo:GetText()
            if npcName then
                local entry = db and db.silencedNPCs[activeCaptureNPCID]
                local safeName = entry and entry.name or SafeToString(activeCaptureNPCName)
                if npcName == safeName then
                    local textInfo = TalkingHeadFrame.TextFrame and TalkingHeadFrame.TextFrame.Text
                    local text = textInfo and textInfo:GetText() or ""
                    AddDetectedMessage(activeCaptureNPCID, "TALKINGHEAD_REQUESTED", text)
                    blockedCount = blockedCount + 1
                    UpdateIndicatorCount()
                end
            end
        end)
    end
end

local function RegisterEvents()
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", OnEvent)
    end
    for _, ev in ipairs(MONSTER_EVENTS) do
        eventFrame:RegisterEvent(ev)
    end
    eventFrame:RegisterEvent("GOSSIP_SHOW")
    eventFrame:RegisterEvent("TALKINGHEAD_REQUESTED")
end

local function UnregisterEvents()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
    end
end

-- ============================================================================
-- Live Silence Indicator
-- ============================================================================

local function SaveIndicatorPosition()
    if not db or not indicatorFrame then return end
    local point, _, relPoint, x, y = indicatorFrame:GetPoint(1)
    db.indicatorPosition = { point = point, relPoint = relPoint, x = x, y = y }
end

local function RestoreIndicatorPosition()
    if not indicatorFrame then return end
    indicatorFrame:ClearAllPoints()
    local pos = db and db.indicatorPosition
    if pos and pos.point then
        indicatorFrame:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    else
        indicatorFrame:SetPoint("TOP", Minimap, "BOTTOM", 0, -8)
    end
end

local function CreateIndicator()
    if indicatorFrame then return end

    indicatorFrame = CreateFrame("Frame", "MedaAurasShutItIndicator", UIParent, "BackdropTemplate")
    indicatorFrame:SetSize(240, 32)
    indicatorFrame:SetBackdrop(MedaUI:CreateBackdrop(true))
    indicatorFrame:SetFrameStrata("MEDIUM")
    indicatorFrame:SetClampedToScreen(true)
    indicatorFrame:EnableMouse(true)
    indicatorFrame:SetMovable(true)
    indicatorFrame:RegisterForDrag("LeftButton")
    indicatorFrame:Hide()

    RestoreIndicatorPosition()

    local isDragging = false

    indicatorFrame:SetScript("OnDragStart", function(self)
        isDragging = true
        self:StartMoving()
    end)

    indicatorFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveIndicatorPosition()
        C_Timer.After(0.05, function() isDragging = false end)
    end)

    indicatorFrame:SetScript("OnMouseUp", function(_, button)
        if isDragging then return end
        if button == "LeftButton" and activeCaptureNPCID then
            selectedNPCID = activeCaptureNPCID
            if explorerPanel then
                ShowExplorerForNPC(activeCaptureNPCID)
            end
        end
    end)

    local function ApplyTheme()
        local Theme = MedaUI.Theme
        indicatorFrame:SetBackdropColor(unpack(Theme.backgroundDark))
        indicatorFrame:SetBackdropBorderColor(unpack(Theme.border))
    end
    MedaUI:RegisterThemedWidget(indicatorFrame, ApplyTheme)
    ApplyTheme()

    indicatorFrame.nameText = indicatorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    indicatorFrame.nameText:SetPoint("LEFT", 8, 0)
    indicatorFrame.nameText:SetPoint("RIGHT", -70, 0)
    indicatorFrame.nameText:SetJustifyH("LEFT")
    indicatorFrame.nameText:SetWordWrap(false)
    indicatorFrame.nameText:SetTextColor(1, 0.4, 0.4)

    indicatorFrame.countText = indicatorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    indicatorFrame.countText:SetPoint("RIGHT", -46, 0)
    indicatorFrame.countText:SetJustifyH("RIGHT")
    indicatorFrame.countText:SetTextColor(0.7, 0.7, 0.7)

    local stopBtn = CreateFrame("Button", nil, indicatorFrame, "BackdropTemplate")
    stopBtn:SetSize(36, 20)
    stopBtn:SetPoint("RIGHT", -4, 0)
    stopBtn:SetBackdrop(MedaUI:CreateBackdrop(false))
    stopBtn:SetBackdropColor(0.5, 0.15, 0.15, 0.8)
    stopBtn:SetBackdropBorderColor(0.6, 0.2, 0.2, 0.6)

    local stopLabel = stopBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stopLabel:SetPoint("CENTER", 0, 1)
    stopLabel:SetText("Stop")
    stopLabel:SetTextColor(1, 0.5, 0.5)

    stopBtn:SetScript("OnClick", function()
        StopLiveCapture()
    end)
    stopBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.7, 0.2, 0.2, 0.9)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Stop live capture")
        GameTooltip:AddLine("NPC stays silenced, stops logging new messages.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    stopBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.5, 0.15, 0.15, 0.8)
        GameTooltip:Hide()
    end)
end

-- ============================================================================
-- NPC Explorer Panel
-- ============================================================================

local RefreshDetail
local ShowExportImportPopup

local function RefreshSidebar()
    if not sidebarContent then return end
    for _, btn in pairs(sidebarButtons) do
        btn:Hide()
    end

    if not db or not db.silencedNPCs then return end

    local yOff = 0
    local idx = 0
    for npcID, entry in pairs(db.silencedNPCs) do
        idx = idx + 1
        local btn = sidebarButtons[idx]
        if not btn then
            btn = CreateFrame("Button", nil, sidebarContent, "BackdropTemplate")
            btn:SetHeight(ROW_HEIGHT)
            btn:SetBackdrop(MedaUI:CreateBackdrop(false))
            btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            btn.label:SetPoint("LEFT", 6, 0)
            btn.label:SetPoint("RIGHT", -6, 0)
            btn.label:SetJustifyH("LEFT")
            btn.label:SetWordWrap(false)
            sidebarButtons[idx] = btn
        end

        btn:SetPoint("TOPLEFT", 0, yOff)
        btn:SetPoint("TOPRIGHT", 0, yOff)
        btn.label:SetText(entry.name or npcID)

        local isActive = activeCaptureNPCID == npcID
        if isActive then
            btn.label:SetTextColor(1, 0.4, 0.4)
        else
            btn.label:SetTextColor(unpack(MedaUI.Theme.text))
        end

        local isSelected = selectedNPCID == npcID
        if isSelected then
            btn:SetBackdropColor(unpack(MedaUI.Theme.buttonHover))
            btn:SetBackdropBorderColor(unpack(MedaUI.Theme.gold))
        else
            btn:SetBackdropColor(0, 0, 0, 0)
            btn:SetBackdropBorderColor(0, 0, 0, 0)
        end

        btn:SetScript("OnClick", function()
            selectedNPCID = npcID
            RefreshSidebar()
            RefreshDetail()
        end)
        btn:SetScript("OnEnter", function(self)
            if selectedNPCID ~= npcID then
                self:SetBackdropColor(unpack(MedaUI.Theme.buttonHover))
            end
        end)
        btn:SetScript("OnLeave", function(self)
            if selectedNPCID ~= npcID then
                self:SetBackdropColor(0, 0, 0, 0)
            end
        end)
        btn:Show()
        yOff = yOff - ROW_HEIGHT
    end
    sidebarContent:SetHeight(math.max(math.abs(yOff), 1))
end

local function CreateIDListSection(parent, title, ids, onAdd, onRemove, onPlay, onClearAll, startY)
    local yOff = startY

    local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header:SetPoint("TOPLEFT", 0, yOff)
    header:SetText(title .. " (" .. #ids .. ")")
    header:SetTextColor(unpack(MedaUI.Theme.gold))

    if #ids > 0 and onClearAll then
        local clearBtn = MedaUI:CreateButton(parent, "Clear All")
        clearBtn:SetSize(60, 16)
        clearBtn:SetPoint("LEFT", header, "RIGHT", 8, 0)
        clearBtn:SetScript("OnClick", function() onClearAll() end)
    end
    yOff = yOff - 20

    local function ParseAndAddIDs(input)
        if not input or input == "" then return end
        local added = 0
        for idStr in input:gmatch("[%d]+") do
            local val = tonumber(idStr)
            if val and val > 0 then
                onAdd(val)
                added = added + 1
            end
        end
        return added
    end

    local addBox = MedaUI:CreateEditBox(parent, 220, 20)
    addBox:SetPoint("TOPLEFT", 0, yOff)

    local addBtn = MedaUI:CreateButton(parent, "Add")
    addBtn:SetSize(50, 20)
    addBtn:SetPoint("LEFT", addBox, "RIGHT", 6, 0)
    addBtn:SetScript("OnClick", function()
        if ParseAndAddIDs(addBox:GetText()) then
            addBox:SetText("")
        end
    end)
    addBox.OnEnterPressed = function(_, text)
        if ParseAndAddIDs(text) then
            addBox:SetText("")
        end
    end
    yOff = yOff - 26

    local rows = {}
    for i, id in ipairs(ids) do
        local row = CreateFrame("Frame", nil, parent)
        row:SetHeight(18)
        row:SetPoint("TOPLEFT", 0, yOff)
        row:SetPoint("TOPRIGHT", 0, yOff)

        local idText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        idText:SetPoint("LEFT", 4, 0)
        idText:SetText(tostring(id))
        idText:SetTextColor(unpack(MedaUI.Theme.text))

        local removeBtn = CreateFrame("Button", nil, row)
        removeBtn:SetSize(16, 16)
        removeBtn:SetPoint("RIGHT", -2, 0)
        removeBtn:SetNormalFontObject("GameFontNormalSmall")
        removeBtn:SetText("|cffcc4444x|r")
        removeBtn:SetHighlightFontObject("GameFontNormalSmall")
        removeBtn:SetScript("OnEnter", function(self)
            self:SetText("|cffff5555x|r")
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Remove this ID")
            GameTooltip:Show()
        end)
        removeBtn:SetScript("OnLeave", function(self)
            self:SetText("|cffcc4444x|r")
            GameTooltip:Hide()
        end)
        removeBtn:SetScript("OnClick", function() onRemove(i) end)

        local playBtn = CreateFrame("Button", nil, row)
        playBtn:SetSize(16, 16)
        playBtn:SetPoint("RIGHT", removeBtn, "LEFT", -2, 0)
        playBtn:SetNormalFontObject("GameFontNormalSmall")
        playBtn:SetText("|cff44dd44>|r")
        playBtn:SetHighlightFontObject("GameFontNormalSmall")
        playBtn:SetScript("OnEnter", function(self)
            self:SetText("|cff66ff66>|r")
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Play sound " .. tostring(id))
            GameTooltip:Show()
        end)
        playBtn:SetScript("OnLeave", function(self)
            self:SetText("|cff44dd44>|r")
            GameTooltip:Hide()
        end)
        playBtn:SetScript("OnClick", function()
            if onPlay then onPlay(id) end
        end)

        rows[i] = row
        yOff = yOff - 18
    end

    yOff = yOff - 6
    return yOff
end

local function ClearDetail()
    if detailWidgets.children then
        for _, child in ipairs(detailWidgets.children) do
            if child.Hide then child:Hide() end
            if child.SetParent then child:SetParent(nil) end
        end
    end
    if detailWidgets.regions then
        for _, region in ipairs(detailWidgets.regions) do
            region:Hide()
        end
    end
    wipe(detailWidgets)
end

RefreshDetail = function()
    if not explorerPanel then return end
    local detailArea = explorerPanel.detailContent
    if not detailArea then return end

    local children = { detailArea:GetChildren() }
    for _, child in ipairs(children) do
        child:Hide()
        child:SetParent(nil)
    end
    local regions = { detailArea:GetRegions() }
    for _, region in ipairs(regions) do
        region:Hide()
    end

    if not selectedNPCID then return end
    local entry = db and db.silencedNPCs and db.silencedNPCs[selectedNPCID]
    if not entry then
        selectedNPCID = nil
        return
    end

    local yOff = 0
    local Theme = MedaUI.Theme

    -- NPC Name
    local nameLabel = detailArea:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameLabel:SetPoint("TOPLEFT", 0, yOff)
    nameLabel:SetText(entry.name or "Unknown")
    nameLabel:SetTextColor(1, 0.82, 0)
    yOff = yOff - 18

    -- NPC ID
    local idLabel = detailArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    idLabel:SetPoint("TOPLEFT", 0, yOff)
    idLabel:SetText("NPC ID: " .. (entry.npcID or selectedNPCID))
    idLabel:SetTextColor(unpack(Theme.textDim))
    yOff = yOff - 14

    -- Date added
    local dateLabel = detailArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dateLabel:SetPoint("TOPLEFT", 0, yOff)
    dateLabel:SetText("Added: " .. (entry.dateAdded and date("%Y-%m-%d %H:%M", entry.dateAdded) or "N/A"))
    dateLabel:SetTextColor(unpack(Theme.textDim))
    yOff = yOff - 22

    -- Silence Chat toggle
    local chatCB = MedaUI:CreateCheckbox(detailArea, "Silence Chat")
    chatCB:SetPoint("TOPLEFT", 0, yOff)
    chatCB:SetChecked(entry.silenceChat)
    chatCB.OnValueChanged = function(_, checked)
        entry.silenceChat = checked
    end
    yOff = yOff - 26

    -- Silence Talking Head toggle
    local thCB = MedaUI:CreateCheckbox(detailArea, "Silence Talking Heads")
    thCB:SetPoint("TOPLEFT", 0, yOff)
    thCB:SetChecked(entry.silenceTalkingHead)
    thCB.OnValueChanged = function(_, checked)
        entry.silenceTalkingHead = checked
    end
    yOff = yOff - 30

    -- Voice database status + manual lookup
    local voIDs = LookupCreatureVO(entry.name)
    local numMuted = #(entry.mutedSoundFileIDs or {})

    if numMuted > 0 and voIDs then
        local statusLabel = detailArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        statusLabel:SetPoint("TOPLEFT", 0, yOff)
        statusLabel:SetText(format("%d voice files auto-muted from database", numMuted))
        statusLabel:SetTextColor(0.3, 0.85, 0.3)
        yOff = yOff - 14
    elseif numMuted > 0 then
        local statusLabel = detailArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        statusLabel:SetPoint("TOPLEFT", 0, yOff)
        statusLabel:SetText(format("%d sound file(s) muted", numMuted))
        statusLabel:SetTextColor(0.3, 0.85, 0.3)
        yOff = yOff - 14
    end

    if voIDs and numMuted == 0 then
        local lookupBtn = MedaUI:CreateButton(detailArea, "Lookup Voice Files")
        lookupBtn:SetSize(140, 20)
        lookupBtn:SetPoint("TOPLEFT", 0, yOff)
        lookupBtn:SetScript("OnClick", function()
            local ids = LookupCreatureVO(entry.name)
            if not ids then return end
            local existing = {}
            for _, id in ipairs(entry.mutedSoundFileIDs or {}) do
                existing[id] = true
            end
            entry.mutedSoundFileIDs = entry.mutedSoundFileIDs or {}
            local added = 0
            for _, id in ipairs(ids) do
                if not existing[id] then
                    entry.mutedSoundFileIDs[#entry.mutedSoundFileIDs + 1] = id
                    added = added + 1
                end
            end
            if added > 0 then
                RemoveMutesForEntry(entry)
                ApplyMutesForEntry(entry)
                print(format("%s Added %d voice files for %s.", PREFIX, added, entry.name or "?"))
            end
            RefreshDetail()
        end)
        yOff = yOff - 24
    end

    local npcNameClean = (entry.name or ""):gsub("[^%w%s]", ""):gsub("%s+", "+")
    local wagoURL = "https://wago.tools/files?search=" .. npcNameClean .. "+vo"

    local urlLabel = detailArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    urlLabel:SetPoint("TOPLEFT", 0, yOff)
    urlLabel:SetText("Manual lookup at wago.tools — copy URL:")
    urlLabel:SetTextColor(unpack(Theme.textDim))
    yOff = yOff - 14

    local urlBox = CreateFrame("EditBox", nil, detailArea, "InputBoxTemplate")
    urlBox:SetSize(detailArea:GetWidth() or 300, 18)
    urlBox:SetPoint("TOPLEFT", 0, yOff)
    urlBox:SetAutoFocus(false)
    urlBox:SetFontObject("GameFontNormalSmall")
    urlBox:SetText(wagoURL)
    urlBox:SetCursorPosition(0)
    urlBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    urlBox:SetScript("OnEditFocusLost", function(self) self:HighlightText(0, 0) end)
    urlBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    urlBox:SetScript("OnTextChanged", function(self)
        self:SetText(wagoURL)
        self:HighlightText()
    end)
    yOff = yOff - 24

    -- Detected Messages
    local msgs = entry.detectedMessages or {}
    local msgHeader = detailArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    msgHeader:SetPoint("TOPLEFT", 0, yOff)
    msgHeader:SetText("Detected Messages (" .. #msgs .. ")")
    msgHeader:SetTextColor(unpack(Theme.gold))
    yOff = yOff - 18

    local msgTextWidth = (detailArea:GetWidth() or (EXPLORER_WIDTH - SIDEBAR_WIDTH - DETAIL_INSET * 2 - 22)) - 24

    for i, m in ipairs(msgs) do
        local row = CreateFrame("Frame", nil, detailArea)
        row:SetPoint("TOPLEFT", 0, yOff)
        row:SetPoint("TOPRIGHT", 0, yOff)

        local msgText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        msgText:SetPoint("TOPLEFT", 4, 0)
        msgText:SetPoint("TOPRIGHT", -20, 0)
        msgText:SetJustifyH("LEFT")
        msgText:SetWordWrap(true)
        msgText:SetWidth(msgTextWidth)
        local short = m.event:gsub("CHAT_MSG_MONSTER_", ""):gsub("TALKINGHEAD_REQUESTED", "TALKHEAD")
        msgText:SetText("|cff888888[" .. short .. "]|r " .. (m.text or ""))
        msgText:SetTextColor(unpack(Theme.text))
        local textHeight = math.max(msgText:GetStringHeight() or 14, 16)
        row:SetHeight(textHeight + 2)

        local removeBtn = CreateFrame("Button", nil, row)
        removeBtn:SetSize(14, 14)
        removeBtn:SetPoint("TOPRIGHT", -2, 0)
        removeBtn:SetNormalFontObject("GameFontNormalSmall")
        removeBtn:SetText("x")
        removeBtn:GetFontString():SetTextColor(0.8, 0.3, 0.3)
        removeBtn:SetScript("OnClick", function()
            table.remove(msgs, i)
            entry.detectedMessages = msgs
            RefreshDetail()
        end)

        yOff = yOff - (textHeight + 2)
    end
    yOff = yOff - 10

    -- Export / Remove buttons
    local exportBtn = MedaUI:CreateButton(detailArea, "Export NPC")
    exportBtn:SetPoint("TOPLEFT", 0, yOff)
    exportBtn:SetScript("OnClick", function()
        local e = db and db.silencedNPCs and db.silencedNPCs[selectedNPCID]
        if e then
            local str = BuildExportString(SerializeEntry(e))
            ShowExportImportPopup("export", str)
        end
    end)

    local removeBtn = MedaUI:CreateButton(detailArea, "Remove NPC")
    removeBtn:SetPoint("LEFT", exportBtn, "RIGHT", 8, 0)
    removeBtn:SetScript("OnClick", function()
        UnsilenceNPC(selectedNPCID)
        selectedNPCID = nil
        RefreshSidebar()
        RefreshDetail()
    end)
    yOff = yOff - 40

    -- Sound FileIDs (below main content so large lists don't push everything down)
    local function RefreshAfterSoundChange()
        RemoveMutesForEntry(entry)
        ApplyMutesForEntry(entry)
        RefreshDetail()
    end

    yOff = CreateIDListSection(detailArea, "Sound FileIDs", entry.mutedSoundFileIDs or {},
        function(val)
            entry.mutedSoundFileIDs = entry.mutedSoundFileIDs or {}
            entry.mutedSoundFileIDs[#entry.mutedSoundFileIDs + 1] = val
            RefreshAfterSoundChange()
        end,
        function(idx)
            if entry.mutedSoundFileIDs then
                local removed = table.remove(entry.mutedSoundFileIDs, idx)
                if removed and activeMutes[removed] then
                    UnmuteSoundFile(removed)
                    activeMutes[removed] = nil
                end
            end
            RefreshDetail()
        end,
        function(id) PlaySoundFile(id) end,
        function()
            RemoveMutesForEntry(entry)
            entry.mutedSoundFileIDs = {}
            ApplyMutesForEntry(entry)
            RefreshDetail()
        end,
        yOff
    )

    -- SoundKit IDs
    yOff = CreateIDListSection(detailArea, "SoundKit IDs", entry.mutedSoundKitIDs or {},
        function(val)
            entry.mutedSoundKitIDs = entry.mutedSoundKitIDs or {}
            entry.mutedSoundKitIDs[#entry.mutedSoundKitIDs + 1] = val
            RefreshAfterSoundChange()
        end,
        function(idx)
            if entry.mutedSoundKitIDs then
                local removed = table.remove(entry.mutedSoundKitIDs, idx)
                if removed and activeMutes[removed] then
                    UnmuteSoundFile(removed)
                    activeMutes[removed] = nil
                end
            end
            RefreshDetail()
        end,
        function(id) PlaySound(id) end,
        function()
            RemoveMutesForEntry(entry)
            entry.mutedSoundKitIDs = {}
            ApplyMutesForEntry(entry)
            RefreshDetail()
        end,
        yOff
    )

    detailArea:SetHeight(math.max(math.abs(yOff), 1))
end

-- ============================================================================
-- Export / Import Popup
-- ============================================================================

local exportImportFrame

ShowExportImportPopup = function(mode, text)
    if not exportImportFrame then
        exportImportFrame = CreateFrame("Frame", "MedaAurasShutItExportImport", UIParent, "BackdropTemplate")
        exportImportFrame:SetSize(480, 220)
        exportImportFrame:SetPoint("CENTER")
        exportImportFrame:SetBackdrop(MedaUI:CreateBackdrop(true))
        exportImportFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        exportImportFrame:SetMovable(true)
        exportImportFrame:EnableMouse(true)
        exportImportFrame:RegisterForDrag("LeftButton")
        exportImportFrame:SetScript("OnDragStart", exportImportFrame.StartMoving)
        exportImportFrame:SetScript("OnDragStop", exportImportFrame.StopMovingOrSizing)

        local function ApplyTheme()
            local Theme = MedaUI.Theme
            exportImportFrame:SetBackdropColor(unpack(Theme.backgroundDark))
            exportImportFrame:SetBackdropBorderColor(unpack(Theme.border))
        end
        MedaUI:RegisterThemedWidget(exportImportFrame, ApplyTheme)
        ApplyTheme()

        exportImportFrame.title = exportImportFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        exportImportFrame.title:SetPoint("TOP", 0, -10)

        local scrollBg = CreateFrame("Frame", nil, exportImportFrame, "BackdropTemplate")
        scrollBg:SetPoint("TOPLEFT", 12, -32)
        scrollBg:SetPoint("BOTTOMRIGHT", -12, 42)
        scrollBg:SetBackdrop(MedaUI:CreateBackdrop(true))
        scrollBg:SetBackdropColor(0.05, 0.05, 0.08, 0.9)
        scrollBg:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)

        local scrollParent = MedaUI:CreateScrollFrame(scrollBg)
        Pixel.SetPoint(scrollParent, "TOPLEFT", 6, -6)
        Pixel.SetPoint(scrollParent, "BOTTOMRIGHT", -6, 6)
        scrollParent:SetScrollStep(40)

        local editBox = CreateFrame("EditBox", nil, scrollParent.scrollContent)
        editBox:SetMultiLine(true)
        editBox:SetAutoFocus(false)
        editBox:SetFontObject("ChatFontNormal")
        editBox:SetMaxLetters(0)
        editBox:SetPoint("TOPLEFT")
        editBox:SetPoint("TOPRIGHT")
        editBox:SetHeight(200)
        editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

        local function RecalcEditBoxHeight()
            local w = editBox:GetWidth()
            if w < 1 then return end
            local textH = editBox:GetHeight()
            scrollParent:SetContentHeight(textH, true, true)
        end
        exportImportFrame.RecalcEditBoxHeight = RecalcEditBoxHeight

        editBox:HookScript("OnTextChanged", function()
            RecalcEditBoxHeight()
        end)
        exportImportFrame.editBox = editBox

        scrollBg:SetScript("OnMouseDown", function()
            editBox:SetFocus()
        end)
        scrollParent.scrollFrame:EnableMouse(true)
        scrollParent.scrollFrame:SetScript("OnMouseDown", function()
            editBox:SetFocus()
        end)

        local closeBtn = MedaUI:CreateButton(exportImportFrame, "Close")
        closeBtn:SetSize(80, 24)
        closeBtn:SetPoint("BOTTOMRIGHT", -12, 12)
        closeBtn:SetScript("OnClick", function() exportImportFrame:Hide() end)

        local importBtn = MedaUI:CreateButton(exportImportFrame, "Import")
        importBtn:SetSize(80, 24)
        importBtn:SetPoint("RIGHT", closeBtn, "LEFT", -8, 0)
        exportImportFrame.importBtn = importBtn
    end

    local frame = exportImportFrame
    local editBox = frame.editBox

    local function RaiseAboveExplorer()
        if explorerPanel then
            local level = explorerPanel:GetFrameLevel()
            frame:SetFrameLevel(level + 50)
        end
    end

    if mode == "export" then
        frame.title:SetText("Export - Copy this string")
        frame.title:SetTextColor(1, 0.82, 0)
        editBox:SetText(text or "")
        frame.importBtn:Hide()
        frame:Show()
        RaiseAboveExplorer()
        C_Timer.After(0, function() frame.RecalcEditBoxHeight() end)
        editBox:SetFocus()
        editBox:HighlightText()
    else
        frame.title:SetText("Import - Paste string below")
        frame.title:SetTextColor(0.4, 0.8, 1)
        editBox:SetText("")
        frame.importBtn:Show()
        frame.importBtn:SetScript("OnClick", function()
            local str = editBox:GetText()
            local entries, err = ParseImportString(str)
            if not entries then
                print(format("%s Import failed: %s", PREFIX, err or "unknown error"))
                return
            end
            local count = 0
            for _, entry in ipairs(entries) do
                if not db.silencedNPCs[entry.npcID] then
                    db.silencedNPCs[entry.npcID] = entry
                    ApplyMutesForEntry(entry)
                    count = count + 1
                end
            end
            RebuildNameLookup()
            print(format("%s Imported %d NPC(s).", PREFIX, count))
            frame:Hide()
            if explorerPanel and explorerPanel:IsShown() then
                RefreshSidebar()
                RefreshDetail()
            end
            MedaAuras:RefreshModuleConfig()
        end)
        frame:Show()
        RaiseAboveExplorer()
        editBox:SetFocus()
    end
end

local function ShowExplorerForNPC(npcID)
    if not explorerPanel then return end
    selectedNPCID = npcID
    if not explorerPanel:IsShown() then
        explorerPanel:Show()
    end
    RefreshSidebar()
    RefreshDetail()
end

local function CreateExplorerPanel()
    if explorerPanel then return end

    explorerPanel = MedaUI:CreatePanel("MedaAurasShutItExplorer", EXPLORER_WIDTH, EXPLORER_HEIGHT, "Shut It - NPC Explorer")
    explorerPanel:SetFrameStrata("FULLSCREEN_DIALOG")
    local content = explorerPanel:GetContent()

    -- Search bar at top
    local searchBox = MedaUI:CreateEditBox(content, EXPLORER_WIDTH - 90, 24)
    searchBox:SetPoint("TOPLEFT", 0, 0)

    local searchBtn = MedaUI:CreateButton(content, "Search")
    searchBtn:SetSize(70, 24)
    searchBtn:SetPoint("LEFT", searchBox, "RIGHT", 6, 0)

    local function DoSearch()
        local query = searchBox:GetText():trim()
        if query == "" then return end

        local asNum = tonumber(query)
        if asNum and db.silencedNPCs[tostring(asNum)] then
            selectedNPCID = tostring(asNum)
            RefreshSidebar()
            RefreshDetail()
            return
        end

        for npcID, entry in pairs(db.silencedNPCs) do
            if entry.name and entry.name:lower():find(query:lower(), 1, true) then
                selectedNPCID = npcID
                RefreshSidebar()
                RefreshDetail()
                return
            end
        end

        -- Not found: create a new entry
        local newID = asNum and tostring(asNum) or query
        local newName = asNum and ("NPC " .. asNum) or query
        db.silencedNPCs[newID] = {
            name = newName,
            npcID = newID,
            silenceChat = true,
            silenceTalkingHead = true,
            mutedSoundFileIDs = {},
            mutedSoundKitIDs = {},
            detectedMessages = {},
            dateAdded = time(),
        }
        RebuildNameLookup()
        selectedNPCID = newID
        RefreshSidebar()
        RefreshDetail()
        MedaAuras:RefreshModuleConfig()
        print(format("%s Added new NPC entry: %s", PREFIX, newName))
    end

    searchBtn:SetScript("OnClick", DoSearch)
    searchBox.OnEnterPressed = function() DoSearch() end

    -- Sidebar (left)
    local sidebarFrame = CreateFrame("Frame", nil, content, "BackdropTemplate")
    sidebarFrame:SetWidth(SIDEBAR_WIDTH)
    sidebarFrame:SetPoint("TOPLEFT", 0, -34)
    sidebarFrame:SetPoint("BOTTOMLEFT", 0, 0)
    sidebarFrame:SetBackdrop(MedaUI:CreateBackdrop(true))

    local function ApplySidebarTheme()
        local Theme = MedaUI.Theme
        sidebarFrame:SetBackdropColor(unpack(Theme.backgroundDark))
        sidebarFrame:SetBackdropBorderColor(unpack(Theme.border))
    end
    MedaUI:RegisterThemedWidget(sidebarFrame, ApplySidebarTheme)
    ApplySidebarTheme()

    sidebarScroll = MedaUI:CreateScrollFrame(sidebarFrame)
    Pixel.SetPoint(sidebarScroll, "TOPLEFT", 4, -4)
    Pixel.SetPoint(sidebarScroll, "BOTTOMRIGHT", -4, 4)
    sidebarScroll:SetScrollStep(30)

    sidebarContent = sidebarScroll.scrollContent
    Pixel.SetHeight(sidebarContent, 1)

    -- Detail area (right, AF custom scrollbar)
    local detailScrollParent = MedaUI:CreateScrollFrame(content)
    Pixel.SetPoint(detailScrollParent, "TOPLEFT", sidebarFrame, "TOPRIGHT", DETAIL_INSET, 0)
    Pixel.SetPoint(detailScrollParent, "BOTTOMRIGHT", -DETAIL_INSET, 0)
    detailScrollParent:SetScrollStep(30)

    local detailContent = detailScrollParent.scrollContent
    Pixel.SetHeight(detailContent, 1)

    explorerPanel.detailContent = detailContent

    -- Bottom bar: Export All / Import buttons
    local bottomBar = CreateFrame("Frame", nil, content)
    bottomBar:SetHeight(28)
    bottomBar:SetPoint("BOTTOMLEFT", 0, -32)
    bottomBar:SetPoint("BOTTOMRIGHT", 0, -32)

    local exportAllBtn = MedaUI:CreateButton(bottomBar, "Export All")
    exportAllBtn:SetSize(90, 24)
    exportAllBtn:SetPoint("LEFT", 0, 0)
    exportAllBtn:SetScript("OnClick", function()
        local serialized = SerializeAll()
        if serialized == "" then
            print(format("%s Nothing to export.", PREFIX))
            return
        end
        ShowExportImportPopup("export", BuildExportString(serialized))
    end)

    local importAllBtn = MedaUI:CreateButton(bottomBar, "Import")
    importAllBtn:SetSize(90, 24)
    importAllBtn:SetPoint("LEFT", exportAllBtn, "RIGHT", 8, 0)
    importAllBtn:SetScript("OnClick", function()
        ShowExportImportPopup("import")
    end)

    RefreshSidebar()
end

-- ============================================================================
-- Minimap Button
-- ============================================================================

local function OnMinimapClick()
    if not db then return end

    local npcName, npcID = GetTargetNPCInfo()

    if npcName and npcID then
        if not db.silencedNPCs[npcID] then
            local hadVO = SilenceNPC(npcName, npcID)
            if not hadVO then
                StartLiveCapture(npcName, npcID)
            end
        else
            StartLiveCapture(npcName, npcID)
        end
        return
    end

    CreateExplorerPanel()
    if explorerPanel:IsShown() then
        explorerPanel:Hide()
    else
        explorerPanel:Show()
        RefreshSidebar()
        RefreshDetail()
    end
end

local function CreateMinimapBtn()
    if minimapButton then return end
    minimapButton = MedaUI:CreateMinimapButton(
        "MedaAurasShutIt",
        "Interface\\Icons\\Spell_Holy_Silence",
        OnMinimapClick,
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
-- Module Lifecycle
-- ============================================================================

local function StartModule()
    isEnabled = true
    RebuildNameLookup()
    InstallChatFilters()
    HookTalkingHead()
    ApplyAllMutes()
    CreateIndicator()
    CreateMinimapBtn()
    RegisterEvents()
    Log("Module enabled")
end

local function StopModule()
    isEnabled = false
    StopLiveCapture()
    RemoveChatFilters()
    RemoveAllMutes()
    UnregisterEvents()
    if explorerPanel then explorerPanel:Hide() end
    if indicatorFrame then indicatorFrame:Hide() end
    Log("Module disabled")
end

local function OnInitialize(moduleDB)
    db = moduleDB
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
-- Module Defaults
-- ============================================================================

local MODULE_DEFAULTS = {
    enabled = false,
    showMinimapButton = true,
    silencedNPCs = {},
    indicatorPosition = nil,
}

-- ============================================================================
-- Settings Panel (BuildConfig)
-- ============================================================================

local function BuildConfig(parent, moduleDB)
    db = moduleDB
    local yOff = 0

    local hdr = MedaUI:CreateSectionHeader(parent, "Shut It")
    hdr:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 45

    local enableCB = MedaUI:CreateCheckbox(parent, "Enable Module")
    enableCB:SetPoint("TOPLEFT", 0, yOff)
    enableCB:SetChecked(moduleDB.enabled)
    enableCB.OnValueChanged = function(_, checked)
        if checked then MedaAuras:EnableModule(MODULE_NAME) else MedaAuras:DisableModule(MODULE_NAME) end
        MedaAuras:RefreshSidebarDot(MODULE_NAME)
    end
    yOff = yOff - 30

    local mmCB = MedaUI:CreateCheckbox(parent, "Show Minimap Button")
    mmCB:SetPoint("TOPLEFT", 0, yOff)
    mmCB:SetChecked(moduleDB.showMinimapButton ~= false)
    mmCB.OnValueChanged = function(_, checked)
        moduleDB.showMinimapButton = checked
        if minimapButton then
            if checked then minimapButton.ShowButton() else minimapButton.HideButton() end
        end
    end
    yOff = yOff - 40

    -- Silenced NPCs summary
    local hdr2 = MedaUI:CreateSectionHeader(parent, "Silenced NPCs")
    hdr2:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 30

    local count = 0
    if moduleDB.silencedNPCs then
        for _ in pairs(moduleDB.silencedNPCs) do
            count = count + 1
        end
    end

    local countLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countLabel:SetPoint("TOPLEFT", 0, yOff)
    countLabel:SetText(format("%d NPC(s) silenced", count))
    countLabel:SetTextColor(unpack(MedaUI.Theme.text))
    yOff = yOff - 20

    if moduleDB.silencedNPCs then
        for npcID, entry in pairs(moduleDB.silencedNPCs) do
            local row = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row:SetPoint("TOPLEFT", 10, yOff)
            local soundCount = #(entry.mutedSoundFileIDs or {}) + #(entry.mutedSoundKitIDs or {})
            local msgCount = #(entry.detectedMessages or {})
            row:SetText(format("  %s (ID: %s) - %d sounds, %d messages",
                entry.name or "?", npcID, soundCount, msgCount))
            row:SetTextColor(unpack(MedaUI.Theme.textDim))
            yOff = yOff - 16
        end
    end
    yOff = yOff - 10

    local openBtn = MedaUI:CreateButton(parent, "Open NPC Explorer")
    openBtn:SetPoint("TOPLEFT", 0, yOff)
    openBtn:SetScript("OnClick", function()
        CreateExplorerPanel()
        explorerPanel:Show()
        RefreshSidebar()
        RefreshDetail()
    end)
    yOff = yOff - 40

    -- Reset
    local resetBtn = MedaUI:CreateButton(parent, "Reset to Defaults")
    resetBtn:SetPoint("TOPLEFT", 0, yOff)
    resetBtn:SetScript("OnClick", function()
        RemoveAllMutes()
        for k, v in pairs(MODULE_DEFAULTS) do
            moduleDB[k] = MedaAuras.DeepCopy(v)
        end
        RebuildNameLookup()
        StopLiveCapture()
        MedaAuras:ToggleSettings()
        MedaAuras:ToggleSettings()
    end)
    yOff = yOff - 45

    MedaAuras:SetContentHeight(math.abs(yOff))
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

local slashCommands = {
    [""] = function(moduleDB)
        db = moduleDB
        CreateExplorerPanel()
        if explorerPanel:IsShown() then
            explorerPanel:Hide()
        else
            explorerPanel:Show()
            RefreshSidebar()
            RefreshDetail()
        end
    end,
    ["scan"] = function(moduleDB)
        db = moduleDB
        local npcName, npcID = GetTargetNPCInfo()
        if not npcName or not npcID then
            print(format("%s Target an NPC first.", PREFIX))
            return
        end
        if not db.silencedNPCs[npcID] then
            local hadVO = SilenceNPC(npcName, npcID)
            if not hadVO then
                StartLiveCapture(npcName, npcID)
            end
        else
            StartLiveCapture(npcName, npcID)
        end
    end,
    ["stop"] = function(moduleDB)
        db = moduleDB
        if activeCaptureNPCName then
            print(format("%s Stopped live capture for %s.", PREFIX, activeCaptureNPCName))
            StopLiveCapture()
        else
            print(format("%s No active live capture.", PREFIX))
        end
    end,
    ["list"] = function(moduleDB)
        db = moduleDB
        if not db.silencedNPCs then
            print(format("%s No silenced NPCs.", PREFIX))
            return
        end
        local count = 0
        for npcID, entry in pairs(db.silencedNPCs) do
            count = count + 1
            local soundCount = #(entry.mutedSoundFileIDs or {}) + #(entry.mutedSoundKitIDs or {})
            print(format("%s  %s (ID: %s) - chat:%s th:%s sounds:%d",
                PREFIX,
                entry.name or "?",
                npcID,
                entry.silenceChat and "ON" or "off",
                entry.silenceTalkingHead and "ON" or "off",
                soundCount
            ))
        end
        if count == 0 then
            print(format("%s No silenced NPCs.", PREFIX))
        end
    end,
    ["export"] = function(moduleDB)
        db = moduleDB
        local serialized = SerializeAll()
        if serialized == "" then
            print(format("%s Nothing to export.", PREFIX))
            return
        end
        ShowExportImportPopup("export", BuildExportString(serialized))
    end,
    ["import"] = function(moduleDB)
        db = moduleDB
        ShowExportImportPopup("import")
    end,
}

-- ============================================================================
-- Register Module
-- ============================================================================

MedaAuras:RegisterModule({
    name          = MODULE_NAME,
    title         = "Shut It",
    version       = MODULE_VERSION,
    stability     = MODULE_STABILITY,
    description   = "Silence annoying NPCs. Target an NPC and click the minimap button to "
                 .. "instantly mute their chat, talking heads, and voice lines. Supports live "
                 .. "capture during delves and dungeons, manual NPC lookup by name or ID, "
                 .. "and muting specific Sound FileIDs and SoundKit IDs.",
    sidebarDesc   = "Silence annoying NPCs by muting their chat, talking heads, and voice lines.",
    defaults      = MODULE_DEFAULTS,
    OnInitialize  = OnInitialize,
    OnEnable      = OnEnable,
    OnDisable     = OnDisable,
    BuildConfig   = BuildConfig,
    slashCommands = slashCommands,
})
