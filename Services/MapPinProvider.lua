local _, ns = ...

local pairs = pairs
local wipe = wipe
local CreateFrame = CreateFrame
local C_Timer = C_Timer

local MAP_PIN_TEMPLATE = "MedaMapPinTemplate"

local MapPinProvider = {}
ns.Services.MapPinProvider = MapPinProvider

local groups = {}
local dataProvider
local refreshPending = false
local initFrame
local mapHooksInstalled = false

MedaMapPinMixin = CreateFromMixins(MapCanvasPinMixin)

function MedaMapPinMixin:OnLoad()
    self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
    self:SetScalingLimits(1, 1, 1)
end

function MedaMapPinMixin:OnAcquired(groupId, pinId, pinData, config)
    self.groupId = groupId
    self.pinId = pinId
    self.data = pinData
    self.tooltipFunc = config and config.tooltipFunc or nil

    local iconPath = (pinData and pinData.icon) or (config and config.icon) or "Interface\\Minimap\\ObjectIconsAtlas"
    local iconSize = (config and config.iconSize) or 16

    self:SetSize(iconSize, iconSize)
    self.icon:SetTexture(iconPath)
    self.icon:SetTexCoord(0, 1, 0, 1)
    self:SetPosition(pinData.x, pinData.y)
    self:Show()
end

function MedaMapPinMixin:OnReleased()
    GameTooltip:Hide()
    self.groupId = nil
    self.pinId = nil
    self.data = nil
    self.tooltipFunc = nil
end

function MedaMapPinMixin:OnMouseEnter()
    if not self.tooltipFunc then
        return
    end

    if WorldMap_HijackTooltip then
        WorldMap_HijackTooltip(self:GetMap())
    else
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    end

    self.tooltipFunc(self)
    GameTooltip:Show()
end

function MedaMapPinMixin:OnMouseLeave()
    GameTooltip:Hide()
    if WorldMap_ResetTooltip then
        WorldMap_ResetTooltip(self:GetMap())
    end
end

local function ScheduleRefresh()
    if refreshPending then
        return
    end

    refreshPending = true
    C_Timer.After(0, function()
        refreshPending = false
        if dataProvider and WorldMapFrame and WorldMapFrame:IsShown() then
            dataProvider:RefreshAllData()
        end
    end)
end

local function InstallMapHooks()
    if mapHooksInstalled or not WorldMapFrame then
        return
    end

    mapHooksInstalled = true
    WorldMapFrame:HookScript("OnShow", ScheduleRefresh)
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
    InstallMapHooks()
    ScheduleRefresh()
    return true
end

function MapPinProvider:RegisterPinGroup(groupId, config)
    TryInitialize()

    if groups[groupId] then
        groups[groupId].config = config or groups[groupId].config or {}
        ScheduleRefresh()
        return
    end

    groups[groupId] = {
        config = config or {},
        pins = {},
        visible = true,
    }
end

function MapPinProvider:SetPin(groupId, pinId, data)
    TryInitialize()
    local group = groups[groupId]
    if not group then
        return
    end

    group.pins[pinId] = data
    ScheduleRefresh()
end

function MapPinProvider:RemovePin(groupId, pinId)
    TryInitialize()
    local group = groups[groupId]
    if not group then
        return
    end

    group.pins[pinId] = nil
    ScheduleRefresh()
end

function MapPinProvider:ClearGroup(groupId)
    TryInitialize()
    local group = groups[groupId]
    if not group then
        return
    end

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
    if not group then
        return
    end

    group.visible = visible
    ScheduleRefresh()
end

function MapPinProvider:UnregisterPinGroup(groupId)
    TryInitialize()
    groups[groupId] = nil
    ScheduleRefresh()
end

MedaMapDataProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function MedaMapDataProviderMixin:RemoveAllData()
    local map = self:GetMap()
    if map then
        map:RemoveAllPinsByTemplate(MAP_PIN_TEMPLATE)
    end
end

function MedaMapDataProviderMixin:RefreshAllData()
    self:RemoveAllData()

    local map = self:GetMap()
    if not map then
        return
    end

    local currentMapID = map:GetMapID()
    if not currentMapID then
        return
    end

    for groupId, group in pairs(groups) do
        if group.visible then
            local cfg = group.config or {}
            for pinId, pinData in pairs(group.pins) do
                if pinData.mapID == currentMapID and pinData.x and pinData.y then
                    map:AcquirePin(MAP_PIN_TEMPLATE, groupId, pinId, pinData, cfg)
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
