local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
script_dir = script_dir:gsub("\\", "/")

local temp_dir = assert(os.getenv("TEMP"), "TEMP is not set"):gsub("\\", "/")
local ace_path = temp_dir .. "/PlaterRepo/libs/AceSerializer-3.0/AceSerializer-3.0.lua"
local deflate_path = temp_dir .. "/PlaterRepo/libs/LibDeflate/LibDeflate.lua"
local source_path = script_dir .. "/pandemic-debuff-highlighter.lua"
local output_path = script_dir .. "/pandemic-debuff-highlighter-import.txt"

local function read_file(path)
    local handle = assert(io.open(path, "rb"))
    local content = assert(handle:read("*a"))
    handle:close()
    return content
end

local function write_file(path, content)
    local handle = assert(io.open(path, "wb"))
    assert(handle:write(content))
    handle:close()
end

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function extract_hooks(content)
    local marker = "-- ====================================================================="
    local hooks = {}
    local required = {
        "Initialization",
        "Nameplate Added",
        "Nameplate Removed",
        "Nameplate Updated",
        "Player Talent Update",
        "Mod Option Changed",
    }

    content = content:gsub("\r\n", "\n")

    local cursor = 1
    while true do
        local marker_start = content:find(marker, cursor, true)
        if not marker_start then
            break
        end

        local marker_end = assert(content:find("\n", marker_start, true), "unterminated marker line")
        local name_line_end = assert(content:find("\n", marker_end + 1, true), "unterminated name line")
        local second_marker_end = assert(content:find("\n", name_line_end + 1, true), "unterminated second marker line")

        local name_line = content:sub(marker_end + 1, name_line_end - 1)
        local hook_name = name_line:gsub("^%-%- ", "")
        local code_start = second_marker_end + 1

        local next_marker = content:find(marker, code_start, true)
        local code_end = next_marker and (next_marker - 2) or #content
        hooks[hook_name] = trim(content:sub(code_start, code_end))

        cursor = next_marker or (#content + 1)
    end

    for _, hook_name in ipairs(required) do
        assert(hooks[hook_name], "missing hook section: " .. hook_name)
    end

    return hooks
end

_G.LibStub = {
    libs = {},
    minors = {},
}
LibStub = _G.LibStub

function _G.LibStub:NewLibrary(major, minor)
    local old_minor = self.minors[major]
    if old_minor then
        if type(old_minor) == type(minor) and old_minor >= minor then
            return nil, old_minor
        end

        if tostring(old_minor) == tostring(minor) then
            return nil, old_minor
        end
    end

    if old_minor and self.libs[major] then
        return nil, old_minor
    end

    local library = self.libs[major] or {}
    self.libs[major] = library
    self.minors[major] = minor
    return library, old_minor
end

function _G.LibStub:GetLibrary(major, silent)
    local library = self.libs[major]
    if not library and not silent then
        error("missing library: " .. major)
    end

    return library, self.minors[major]
end

dofile(deflate_path)
dofile(ace_path)

local LibDeflate = assert(_G.LibStub:GetLibrary("LibDeflate"), "LibDeflate failed to load")
local AceSerializer = assert(_G.LibStub:GetLibrary("AceSerializer-3.0"), "AceSerializer failed to load")

local hooks = extract_hooks(read_file(source_path))

local default_load_conditions = {
    class = {},
    spec = {},
    race = {},
    talent = {},
    pvptalent = {},
    group = {},
    role = {},
    affix = {},
    encounter_ids = {},
    map_ids = {},
}

local options = {
    {
        Type = 5,
        Name = "Alert Types",
        Desc = "Choose which alert styles can fire when a tracked debuff enters the pandemic window.",
    },
    {
        Type = 4,
        Name = "Glow",
        Desc = "Use Plater's regular button glow on the selected alert targets.",
        Key = "useGlow",
        Value = false,
    },
    {
        Type = 4,
        Name = "Pixel Glow",
        Desc = "Use a tighter pixel glow on the selected alert targets.",
        Key = "usePixelGlow",
        Value = true,
    },
    {
        Type = 4,
        Name = "Enlarge",
        Desc = "Scale up the debuff icon and or the nameplate while the pandemic alert is active.",
        Key = "useEnlarge",
        Value = false,
    },
    {
        Type = 4,
        Name = "Dim Others",
        Desc = "Dim non-pandemic debuff icons on the same plate and or dim other enemy nameplates while any tracked pandemic alert is active.",
        Key = "useDimOthers",
        Value = false,
    },
    {
        Type = 5,
        Name = "Targets",
        Desc = "Choose where the alert styles should appear.",
    },
    {
        Type = 4,
        Name = "Apply To Debuff Icon",
        Desc = "Show alerts directly on the debuff icon. This is the closest match to the original pandemic icon scripts.",
        Key = "applyToDebuffIcon",
        Value = true,
    },
    {
        Type = 4,
        Name = "Apply To Nameplate",
        Desc = "Show alerts on the entire enemy nameplate as well. Use this when you want a stronger plate-level signal.",
        Key = "applyToNameplate",
        Value = false,
    },
    {
        Type = 5,
        Name = "Sizing",
        Desc = "Tune how strong enlarge and dim effects should be.",
    },
    {
        Type = 2,
        Name = "Icon Enlarge Percent",
        Desc = "Final scale for highlighted debuff icons. 100 keeps the default size, 125 is a moderate bump, and 150 is intentionally loud.",
        Key = "iconEnlargePercent",
        Value = 125,
        Min = 100,
        Max = 180,
        Fraction = false,
    },
    {
        Type = 2,
        Name = "Nameplate Enlarge Percent",
        Desc = "Final scale for highlighted nameplates. Keep this modest because Plater updates plate layout often.",
        Key = "nameplateEnlargePercent",
        Value = 108,
        Min = 100,
        Max = 140,
        Fraction = false,
    },
    {
        Type = 2,
        Name = "Dim Others Opacity",
        Desc = "Opacity for non-highlighted icons and or nameplates while dimming is active. 0 fully hides them, 100 disables the dim effect.",
        Key = "dimOpacityPercent",
        Value = 35,
        Min = 0,
        Max = 100,
        Fraction = false,
    },
    {
        Type = 5,
        Name = "Sound",
        Desc = "Optional global sound cue when a tracked aura first enters the pandemic window.",
    },
    {
        Type = 4,
        Name = "Enable Sound",
        Desc = "Queue a sound whenever a tracked debuff crosses into the pandemic window. Sounds are buffered so many simultaneous entries are spread out instead of stacked on one frame.",
        Key = "enableSound",
        Value = false,
    },
    {
        Type = 8,
        Name = "Pandemic Sound",
        Desc = "Select the sound file played when a tracked aura enters its pandemic window.",
        Key = "pandemicSound",
        Value = "",
    },
    {
        Type = 2,
        Name = "Sound Gap Seconds",
        Desc = "Minimum gap between queued pandemic sounds. Lower values feel more immediate, higher values are calmer when many DoTs line up together.",
        Key = "soundSpacingSeconds",
        Value = 0.12,
        Min = 0.05,
        Max = 0.50,
        Fraction = true,
    },
    {
        Type = 5,
        Name = "Detection",
        Desc = "Control how strict the pandemic tracker should be.",
    },
    {
        Type = 4,
        Name = "Track All Player Debuffs (Advanced)",
        Desc = "Fallback mode. Any debuff from you or your pet with a duration can trigger the pandemic math, not just the shipped DoT list. This is broader and will include some non-DoT debuffs.",
        Key = "trackAllPlayerDebuffs",
        Value = false,
    },
    {
        Type = 4,
        Name = "Debug Output",
        Desc = "Prints pandemic transitions to chat for troubleshooting. Leave this off outside testing.",
        Key = "debugEnabled",
        Value = false,
    },
}

local export_table = {
    ["1"] = "Pandemic Highlighter - Medalink",
    ["2"] = "Interface\\Icons\\spell_shadow_shadowwordpain",
    ["3"] = "Highlights your own player or pet DoTs on enemy nameplates when they enter the pandemic window.",
    ["4"] = "Medalink",
    ["5"] = 1770000000,
    ["6"] = 1,
    ["7"] = 1,
    ["8"] = default_load_conditions,
    ["9"] = hooks,
    ["options"] = options,
    ["addon"] = "Plater",
    ["tocversion"] = 110205,
    ["type"] = "hook",
    ["UID"] = "medalink-pandemic-debuff-highlighter",
}

local serialized = assert(AceSerializer:Serialize(export_table))
local compressed = assert(LibDeflate:CompressDeflate(serialized, { level = 9 }))
local encoded = assert(LibDeflate:EncodeForPrint(compressed))

local decoded = assert(LibDeflate:DecodeForPrint(encoded))
local inflated = assert(LibDeflate:DecompressDeflate(decoded))
local ok, roundtrip = AceSerializer:Deserialize(inflated)
assert(ok, roundtrip)
assert(roundtrip["1"] == export_table["1"], "roundtrip name mismatch")
assert(roundtrip.type == "hook", "roundtrip type mismatch")
assert(type(roundtrip["9"]) == "table", "roundtrip hook table missing")
assert(type(roundtrip.options) == "table" and #roundtrip.options == #options, "roundtrip options mismatch")

write_file(output_path, encoded .. "\n")
print("Wrote " .. output_path)
