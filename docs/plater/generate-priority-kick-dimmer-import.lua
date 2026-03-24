local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
script_dir = script_dir:gsub("\\", "/")

local temp_dir = assert(os.getenv("TEMP"), "TEMP is not set"):gsub("\\", "/")
local ace_path = temp_dir .. "/PlaterRepo/libs/AceSerializer-3.0/AceSerializer-3.0.lua"
local deflate_path = temp_dir .. "/PlaterRepo/libs/LibDeflate/LibDeflate.lua"
local source_path = script_dir .. "/priority-kick-dimmer.lua"
local output_path = script_dir .. "/priority-kick-dimmer-import.txt"

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
        "Cast Start",
        "Cast Update",
        "Cast Stop",
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
        Type = 2,
        Name = "Dim Opacity",
        Desc = "Opacity to use for non-priority enemy NPC plates while a tracked cast is active.",
        Key = "dimOpacityPercent",
        Value = 25,
        Min = 0,
        Max = 100,
        Fraction = false,
    },
    {
        Type = 4,
        Name = "Match All Interruptible Casts",
        Desc = "If enabled, any interruptible enemy NPC cast triggers the dimmer instead of only your priority lists.",
        Key = "matchAllInterruptibleCasts",
        Value = false,
    },
    {
        Type = 4,
        Name = "Require Known Interrupt",
        Desc = "Only dim when your character has at least one supported interrupt. Cheap after init: the known-interrupt result is cached until talents/spec change.",
        Key = "requireKnownInterrupt",
        Value = false,
    },
    {
        Type = 4,
        Name = "Require Ready Interrupt",
        Desc = "Only dim when your interrupt is currently ready to press. Slightly more work than the known-only check because it polls cooldown readiness with a short cache.",
        Key = "requireReadyInterrupt",
        Value = false,
    },
}

local export_table = {
    ["1"] = "Prio Interrupt Dimmer - MedaLink",
    ["2"] = "Interface\\Icons\\ability_kick",
    ["3"] = "Dims other enemy NPC nameplates while a tracked interruptible cast is active.",
    ["4"] = "MedaLink",
    ["5"] = 1770000000,
    ["6"] = 2,
    ["7"] = 1,
    ["8"] = default_load_conditions,
    ["9"] = hooks,
    ["options"] = options,
    ["addon"] = "Plater",
    ["tocversion"] = 110205,
    ["type"] = "hook",
    ["UID"] = "medalink-prio-interrupt-dimmer",
}

local serialized = assert(AceSerializer:Serialize(export_table))
local compressed = assert(LibDeflate:CompressDeflate(serialized, {level = 9}))
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
