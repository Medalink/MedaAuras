local _, NS = ...
local API = NS.API

local MODULE_KEY = "BuffTracker"
local PAGE_NAME = "Settings"

local function BuildPage(_, parent, yOffset)
    local db = API:GetModuleDB(MODULE_KEY, NS.ModuleDefaults[MODULE_KEY])

    local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 0, yOffset)
    header:SetText("Tracked Buff Icon")

    local toggle = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    toggle:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -16)
    toggle:SetChecked(db.enabled)
    toggle:SetScript("OnClick", function(self)
        db.enabled = self:GetChecked() and true or false
    end)
    toggle.text:SetText("Enable Tracked Buff Icon")

    local note = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", toggle, "BOTTOMLEFT", 4, -12)
    note:SetWidth(560)
    note:SetJustifyH("LEFT")
    note:SetText("Wire this module into the parent addon TOC/load order, then replace this page with real controls.")
end

API:RegisterModule(MODULE_KEY, {
    title = "Tracked Buff Icon",
    description = "Scaffolded module for an existing addon.",
    order = 50,
    pages = { PAGE_NAME },
    buildPage = BuildPage,
    onReset = function()
        API:ResetModuleDB(MODULE_KEY)
    end,
})

