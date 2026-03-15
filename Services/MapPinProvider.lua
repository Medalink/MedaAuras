local _, ns = ...

local pairs = pairs
local ipairs = ipairs
local wipe = wipe
local CreateFrame = CreateFrame
local C_Timer = C_Timer

local MapPinProvider = {}
ns.Services.MapPinProvider = MapPinProvider

local groups = {}
local dataProvider
local pinPool = {}
local activePins = {}
local refreshPending = false
local initFrame
local MedaMapDataProviderMixin

local function ScheduleRefresh()
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(0, function()
        refreshPending = false
        if dataProvider and WorldMapFrame and WorldMapFrame:IsShown() then
            dataProvider:RefreshAllData()
        end
    end)
end

local function TryInitialize()
    if dataProvider then
        return true
    end

    if not WorldMapFrame then
        return false
    end

    dataProvider = CreateFromMixins(MedaMapDataProviderMixin)
    WorldMapFrame:AddDataProvider(dataProvider)
    MedaAuras.LogDebug("[MapPinProvider] Initialized, data provider registered with WorldMapFrame")
    ScheduleRefresh()
    return true
end

function MapPinProvider:RegisterPinGroup(groupId, config)
    TryInitialize()
    if groups[groupId] then return end
    groups[groupId] = {
        config = config or {},
        pins = {},
        visible = true,
    }
end

function MapPinProvider:SetPin(groupId, pinId, data)
    TryInitialize()
    local group = groups[groupId]
    if not group then return end
    group.pins[pinId] = data
    ScheduleRefresh()
end

function MapPinProvider:RemovePin(groupId, pinId)
    TryInitialize()
    local group = groups[groupId]
    if not group then return end
    group.pins[pinId] = nil
    ScheduleRefresh()
end

function MapPinProvider:ClearGroup(groupId)
    TryInitialize()
    local group = groups[groupId]
    if not group then return end
    wipe(group.pins)
    ScheduleRefresh()
end

function MapPinProvider:GetPins(groupId)
    local group = groups[groupId]
    return group and group.pins or {}
end

function MapPinProvider:SetGroupVisible(groupId, visible)
    TryInitialize()
    local group = groups[groupId]
    if not group then return end
    group.visible = visible
    ScheduleRefresh()
end

function MapPinProvider:UnregisterPinGroup(groupId)
    TryInitialize()
    groups[groupId] = nil
    ScheduleRefresh()
end

local function AcquirePin(owner)
    local pin = table.remove(pinPool)
    if not pin then
        pin = CreateFrame("Frame", nil, owner)
        pin.icon = pin:CreateTexture(nil, "ARTWORK")
        pin.icon:SetAllPoints()
        pin:EnableMouse(true)
        pin:SetScript("OnEnter", function(self)
            if self.tooltipFunc then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                self.tooltipFunc(self)
                GameTooltip:Show()
            end
        end)
        pin:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end
    pin:SetParent(owner)
    pin:Show()
    return pin
end

local function ReleasePin(pin)
    pin:Hide()
    pin:ClearAllPoints()
    pin:SetParent(nil)
    pin.tooltipFunc = nil
    pin.data = nil
    pin.groupId = nil
    pin.pinId = nil
    pinPool[#pinPool + 1] = pin
end

local function ReleaseAllPins()
    for _, pin in ipairs(activePins) do
        ReleasePin(pin)
    end
    wipe(activePins)
end

MedaMapDataProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function MedaMapDataProviderMixin:RemoveAllData()
    ReleaseAllPins()
end

function MedaMapDataProviderMixin:RefreshAllData(fromOnShow)
    self:RemoveAllData()

    local mapFrame = self:GetMap()
    if not mapFrame then return end

    local currentMapID = mapFrame:GetMapID()
    if not currentMapID then return end

    for groupId, group in pairs(groups) do
        if group.visible then
            local cfg = group.config
            local iconPath = cfg.icon or "Interface\\Minimap\\ObjectIconsAtlas"
            local iconSize = cfg.iconSize or 16

            for pinId, pinData in pairs(group.pins) do
                if pinData.mapID == currentMapID and pinData.x and pinData.y then
                    local pin = AcquirePin(mapFrame:GetCanvas())
                    pin:SetSize(iconSize, iconSize)
                    pin.icon:SetTexture(pinData.icon or iconPath)
                    pin.icon:SetTexCoord(0, 1, 0, 1)
                    pin.data = pinData
                    pin.groupId = groupId
                    pin.pinId = pinId
                    pin.tooltipFunc = cfg.tooltipFunc

                    mapFrame:SetPinPosition(pin, pinData.x, pinData.y)
                    pin:SetFrameStrata("HIGH")

                    activePins[#activePins + 1] = pin
                end
            end
        end
    end
end

function MedaMapDataProviderMixin:OnMapChanged()
    self:RefreshAllData()
end

function MapPinProvider:Initialize()
    if TryInitialize() then
        return
    end

    if initFrame then
        return
    end

    initFrame = CreateFrame("Frame")
    initFrame:RegisterEvent("ADDON_LOADED")
    initFrame:SetScript("OnEvent", function(_, _, addonName)
        if addonName ~= "Blizzard_WorldMap" then
            return
        end

        if TryInitialize() then
            initFrame:UnregisterEvent("ADDON_LOADED")
            initFrame:SetScript("OnEvent", nil)
            initFrame = nil
        end
    end)
end
