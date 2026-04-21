local ADDON_NAME, ns = ...

local MedaUI = LibStub("MedaUI-2.0")
local Pixel = MedaUI.Pixel
local Serializer = (LibStub and LibStub.GetLibrary and LibStub:GetLibrary("LibSerialize", true)) or _G.LibSerialize
local LibDeflate = (LibStub and LibStub.GetLibrary and LibStub:GetLibrary("LibDeflate", true)) or _G.LibDeflate

local format = format
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local type = type
local next = next
local unpack = unpack
local sort = table.sort
local concat = table.concat
local random = math.random
local floor = math.floor
local strmatch = string.match
local gsub = string.gsub
local byte = string.byte
local sub = string.sub
local lower = string.lower
local min = math.min

local CUSTOM_PREFIX = "!MedaAuras:1!"
local CUSTOM_PACKAGE_VERSION = 1
local CUSTOM_API_VERSION = 1
local CUSTOM_CRASH_THRESHOLD = 3

local CUSTOM_COLOR = { 0.35, 0.85, 1.0 }
local WARNING_COLOR = { 1.0, 0.7, 0.2 }
local ERROR_COLOR = { 1.0, 0.35, 0.35 }
local SUCCESS_COLOR = { 0.3, 0.85, 0.3 }

local runtimeModules = {}
local nameToModuleId = {}

local importFrame
local textPopupDialog

local function Log(msg)
    if MedaAuras and MedaAuras.Log then
        MedaAuras.Log(format("[CustomModules] %s", msg))
    end
end

local function LogWarn(msg)
    if MedaAuras and MedaAuras.LogWarn then
        MedaAuras.LogWarn(format("[CustomModules] %s", msg))
    end
end

local function LogError(msg)
    if MedaAuras and MedaAuras.LogError then
        MedaAuras.LogError(format("[CustomModules] %s", msg))
    end
end

local function DeepCopy(value)
    if MedaAuras and MedaAuras.DeepCopy then
        return MedaAuras.DeepCopy(value)
    end

    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for k, v in pairs(value) do
        copy[DeepCopy(k)] = DeepCopy(v)
    end
    return copy
end

local function MergeDefaults(saved, defaults)
    if type(saved) ~= "table" then
        return DeepCopy(defaults)
    end
    for k, v in pairs(defaults or {}) do
        if saved[k] == nil then
            saved[k] = DeepCopy(v)
        elseif type(v) == "table" and type(saved[k]) == "table" then
            MergeDefaults(saved[k], v)
        end
    end
    return saved
end

local function MergeMissingKeys(dest, src)
    if type(dest) ~= "table" or type(src) ~= "table" then
        return dest
    end

    for k, v in pairs(src) do
        if dest[k] == nil then
            dest[k] = DeepCopy(v)
        elseif type(dest[k]) == "table" and type(v) == "table" then
            MergeMissingKeys(dest[k], v)
        end
    end

    return dest
end

local function Trim(text)
    text = tostring(text or "")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

local function GenerateModuleId(seed)
    local clean = tostring(seed or "custom-module"):lower():gsub("[^%w]+", "-"):gsub("%-+", "-")
    clean = clean:gsub("^%-+", ""):gsub("%-+$", "")
    if clean == "" then
        clean = "custom-module"
    end
    return format("%s-%04x%04x", clean, random(0, 0xffff), random(0, 0xffff))
end

local function BuildDisplayKey(moduleId)
    return "custom:" .. tostring(moduleId)
end

local function GetModuleIdFromKey(key)
    if type(key) ~= "string" then return nil end
    return strmatch(key, "^custom:(.+)$")
end

local function SerializeForChecksum(value, seen)
    local valueType = type(value)
    if valueType == "nil" then
        return "nil"
    elseif valueType == "boolean" or valueType == "number" then
        return tostring(value)
    elseif valueType == "string" then
        return ("%q"):format(value)
    elseif valueType ~= "table" then
        return "<" .. valueType .. ">"
    end

    seen = seen or {}
    if seen[value] then
        return "<cycle>"
    end
    seen[value] = true

    local keys = {}
    for k in pairs(value) do
        keys[#keys + 1] = k
    end
    sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta == tb then
            return tostring(a) < tostring(b)
        end
        return ta < tb
    end)

    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = SerializeForChecksum(key, seen) .. "=" .. SerializeForChecksum(value[key], seen)
    end

    seen[value] = nil
    return "{" .. concat(parts, ",") .. "}"
end

local function Adler32(input)
    local a = 1
    local b = 0
    local mod = 65521

    input = tostring(input or "")
    for i = 1, #input do
        a = (a + byte(input, i)) % mod
        b = (b + a) % mod
    end

    return tostring(b * 65536 + a)
end

local function BuildChecksumForPackage(pkg)
    local meta = pkg.metadata or {}
    local payload = {
        packageVersion = pkg.packageVersion or CUSTOM_PACKAGE_VERSION,
        kind = pkg.kind or "MedaAurasCustomModule",
        metadata = {
            moduleId = meta.moduleId,
            name = meta.name,
            title = meta.title,
            author = meta.author,
            description = meta.description,
            moduleVersion = meta.moduleVersion,
            dataVersion = meta.dataVersion,
            apiVersion = meta.apiVersion,
            exportMode = meta.exportMode,
        },
        code = pkg.code or "",
        defaults = pkg.defaults or {},
        data = pkg.data,
    }

    return Adler32(SerializeForChecksum(payload))
end

local function CompareVersions(a, b)
    a = Trim(a or "")
    b = Trim(b or "")
    if a:sub(1, 1):lower() == "v" then
        a = Trim(a:sub(2))
    end
    if b:sub(1, 1):lower() == "v" then
        b = Trim(b:sub(2))
    end
    if a == "" then a = "1.0" end
    if b == "" then b = "1.0" end

    local partsA = {}
    for n in a:gmatch("%d+") do
        partsA[#partsA + 1] = tonumber(n) or 0
    end

    local partsB = {}
    for n in b:gmatch("%d+") do
        partsB[#partsB + 1] = tonumber(n) or 0
    end

    local count = math.max(#partsA, #partsB)
    for i = 1, count do
        local left = partsA[i] or 0
        local right = partsB[i] or 0
        if left < right then return -1 end
        if left > right then return 1 end
    end
    return 0
end

local function BuildVersionSummary(existingVersion, incomingVersion)
    local cmp = CompareVersions(incomingVersion, existingVersion)
    if cmp > 0 then
        return "update"
    elseif cmp < 0 then
        return "rollback"
    end
    return "reinstall"
end

local function NormalizeSimpleVersion(version)
    version = Trim(tostring(version or ""))
    if version == "" then
        return "v1.0"
    end

    if version:sub(1, 1):lower() == "v" then
        version = Trim(version:sub(2))
    end

    if version == "" then
        return "v1.0"
    end

    return "v" .. version
end

local function IsSimpleVersion(version)
    local v = tostring(version or ""):match("^v?(.+)$")
    if not v then return false end
    for segment in v:gmatch("[^%.]+") do
        if not segment:match("^%d+$") then return false end
    end
    return v:match("%d") ~= nil
end

local function FormatVersionDisplay(version)
    local normalized = NormalizeSimpleVersion(version)
    if normalized:sub(1, 1):lower() ~= "v" then
        normalized = "v" .. normalized
    end
    return normalized
end

local function ExtractErrorLine(err)
    err = tostring(err or "")
    return tonumber(err:match("%]:(%d+):") or err:match(":(%d+):"))
end

local function GetStore()
    if not MedaAurasDB then
        return nil
    end
    MedaAurasDB.customModules = MedaAurasDB.customModules or {}
    return MedaAurasDB.customModules
end

local function SetStatus(label, message, color)
    if not label then return end
    label:SetText(message or "")
    if color then
        label:SetTextColor(unpack(color))
    else
        label:SetTextColor(unpack(MedaUI.Theme.text))
    end
end

local function ApplyInputContainerTheme(frame, focused)
    if not frame then return end
    local theme = MedaUI.Theme
    frame:SetBackdropColor(unpack(theme.input or { 0.08, 0.08, 0.12, 0.98 }))
    frame:SetBackdropBorderColor(unpack(focused and (theme.gold or { 1, 0.82, 0 }) or (theme.border or { 0.3, 0.3, 0.3, 1 })))
end

local function AttachInputFocusStyling(editBox, container, clickTarget)
    if not editBox or not container then return end

    local function FocusEditBox()
        editBox:SetFocus()
    end

    editBox:SetTextInsets(8, 8, 8, 8)
    editBox:SetTextColor(0.92, 0.94, 1.0)
    if editBox.EnableKeyboard then
        editBox:EnableKeyboard(true)
    end
    editBox:EnableMouse(true)
    editBox:SetScript("OnEditFocusGained", function(self)
        ApplyInputContainerTheme(container, true)
        if self.SetTextColor then
            self:SetTextColor(0.98, 0.98, 1.0)
        end
    end)
    editBox:SetScript("OnEditFocusLost", function(self)
        ApplyInputContainerTheme(container, false)
        if self.SetTextColor then
            self:SetTextColor(0.92, 0.94, 1.0)
        end
    end)
    editBox:HookScript("OnMouseDown", FocusEditBox)
    editBox:HookScript("OnMouseUp", FocusEditBox)

    container:EnableMouse(true)
    container:SetScript("OnMouseDown", FocusEditBox)

    if clickTarget then
        clickTarget:EnableMouse(true)
        clickTarget:SetScript("OnMouseDown", FocusEditBox)
    end

    ApplyInputContainerTheme(container, false)
end

local function EstimateEditBoxHeight(editBox, minHeight)
    local text = editBox and editBox:GetText() or ""
    local _, lineCount = text:gsub("\n", "\n")
    lineCount = math.max(lineCount + 1, 1)

    local _, fontHeight = editBox:GetFont()
    fontHeight = tonumber(fontHeight) or 14

    return math.max((lineCount * (fontHeight + 4)) + 20, minHeight or 180)
end

local function ReindexRuntimeNames()
    wipe(nameToModuleId)
    for moduleId, runtime in pairs(runtimeModules) do
        if runtime.config and runtime.config.name then
            nameToModuleId[runtime.config.name] = moduleId
        end
    end
end

local function NormalizeMetadata(moduleId, metadata)
    metadata = type(metadata) == "table" and DeepCopy(metadata) or {}
    metadata.moduleId = Trim(metadata.moduleId or moduleId or "")
    if metadata.moduleId == "" then
        metadata.moduleId = GenerateModuleId(metadata.name or metadata.title)
    end
    metadata.name = Trim(metadata.name or metadata.title or metadata.moduleId)
    if metadata.name == "" then
        metadata.name = metadata.moduleId
    end
    metadata.title = Trim(metadata.title or metadata.name)
    if metadata.title == "" then
        metadata.title = metadata.name
    end
    metadata.author = Trim(metadata.author or "Unknown")
    metadata.description = Trim(metadata.description or "Custom MedaAuras module")
    metadata.moduleVersion = NormalizeSimpleVersion(metadata.moduleVersion or metadata.version or "v1.0")
    if metadata.moduleVersion == "" then
        metadata.moduleVersion = "v1.0"
    end
    metadata.dataVersion = tonumber(metadata.dataVersion) or 1
    metadata.apiVersion = tonumber(metadata.apiVersion) or CUSTOM_API_VERSION
    metadata.packageVersion = tonumber(metadata.packageVersion) or CUSTOM_PACKAGE_VERSION
    metadata.createdAt = tonumber(metadata.createdAt) or time()
    metadata.importedAt = tonumber(metadata.importedAt) or time()
    metadata.exportedAt = tonumber(metadata.exportedAt) or nil
    metadata.hasCustomCode = metadata.hasCustomCode ~= false
    metadata.exportMode = metadata.exportMode or "codeOnly"
    return metadata
end

local function NormalizeStoredRecord(moduleId, record)
    record = type(record) == "table" and DeepCopy(record) or {}
    record.source = "custom"
    record.trusted = record.trusted ~= false
    record.metadata = NormalizeMetadata(moduleId, record.metadata)
    moduleId = record.metadata.moduleId
    record.code = tostring(record.code or "")
    record.defaults = type(record.defaults) == "table" and DeepCopy(record.defaults) or {}
    if record.defaults.enabled == nil then
        record.defaults.enabled = false
    end
    record.data = type(record.data) == "table" and DeepCopy(record.data) or {}
    record.data = MergeDefaults(record.data, record.defaults)
    record.checksum = tostring(record.checksum or "")
    if record.checksum == "" then
        record.checksum = BuildChecksumForPackage({
            packageVersion = record.metadata.packageVersion,
            kind = "MedaAurasCustomModule",
            metadata = {
                moduleId = record.metadata.moduleId,
                name = record.metadata.name,
                title = record.metadata.title,
                author = record.metadata.author,
                description = record.metadata.description,
                moduleVersion = record.metadata.moduleVersion,
                dataVersion = record.metadata.dataVersion,
                apiVersion = record.metadata.apiVersion,
                exportMode = "codeAndData",
            },
            code = record.code,
            defaults = record.defaults,
            data = record.data,
        })
    end
    record.lastError = record.lastError or nil
    record.crashCount = tonumber(record.crashCount) or 0
    if type(record.lastBackup) ~= "table" then
        record.lastBackup = nil
    end
    return moduleId, record
end

local function ExtractStringField(code, field)
    local patterns = {
        field .. "%s*=%s*\"([^\"]+)\"",
        field .. "%s*=%s*'([^']+)'",
        "%[\"" .. field .. "\"%]%s*=%s*\"([^\"]+)\"",
        "%['" .. field .. "'%]%s*=%s*'([^']+)'",
    }
    for _, pattern in ipairs(patterns) do
        local value = strmatch(code, pattern)
        if value and value ~= "" then
            return value
        end
    end
end

local function ExtractNumberField(code, field)
    local patterns = {
        field .. "%s*=%s*(%d+)",
        "%[\"" .. field .. "\"%]%s*=%s*(%d+)",
        "%['" .. field .. "'%]%s*=%s*(%d+)",
    }
    for _, pattern in ipairs(patterns) do
        local value = strmatch(code, pattern)
        if value then
            return tonumber(value)
        end
    end
end

local function ExtractMetadataFromCode(code)
    local metadata = {
        moduleId = ExtractStringField(code, "moduleId"),
        name = ExtractStringField(code, "name"),
        title = ExtractStringField(code, "title"),
        author = ExtractStringField(code, "author"),
        description = ExtractStringField(code, "description"),
        moduleVersion = ExtractStringField(code, "version"),
        dataVersion = ExtractNumberField(code, "dataVersion"),
    }
    metadata = NormalizeMetadata(metadata.moduleId, metadata)
    return metadata
end

local function ReplaceStringFieldInCode(code, field, value)
    code = tostring(code or "")
    value = tostring(value or "")

    local replacements = {
        field .. '%s*=%s*"[^"]*"',
        field .. "%s*=%s*'[^']*'",
        '%["' .. field .. '"%]%s*=%s*"[^"]*"',
        "%['" .. field .. "'%]%s*=%s*'[^']*'",
    }

    local replacement = field .. " = " .. ("%q"):format(value)
    for _, pattern in ipairs(replacements) do
        local updated, count = gsub(code, pattern, replacement, 1)
        if count and count > 0 then
            return updated, true
        end
    end

    return code, false
end

local function InsertFieldIntoRegisterCall(code, field, value)
    local quoted = ("%q"):format(tostring(value or ""))
    local line = "    " .. field .. " = " .. quoted .. ","

    local patterns = {
        "RegisterCustomModule%s*%(%s*{%s*\n",
        "RegisterCustomModule%s*%(%s*{",
    }
    for _, pat in ipairs(patterns) do
        local s, e = code:find(pat)
        if s then
            return code:sub(1, e) .. line .. "\n" .. code:sub(e + 1), true
        end
    end

    return code, false
end

local function ApplyMetadataToCode(code, metadata)
    if type(metadata) ~= "table" then
        return tostring(code or "")
    end

    local fields = {
        { "moduleId", metadata.moduleId },
        { "name", metadata.name },
        { "title", metadata.title },
        { "version", metadata.moduleVersion },
        { "author", metadata.author },
        { "description", metadata.description },
    }

    for _, entry in ipairs(fields) do
        local field, value = entry[1], entry[2]
        if value and value ~= "" then
            local updated, replaced = ReplaceStringFieldInCode(code, field, value)
            if replaced then
                code = updated
            else
                local inserted
                code, inserted = InsertFieldIntoRegisterCall(code, field, value)
            end
        end
    end

    return code
end

local function EvaluateModuleCode(code, metadata, preferMetadata)
    local capture
    local function ResolveSourceName()
        local candidate = metadata and (metadata.title or metadata.name)
        if candidate and candidate ~= "" then
            return candidate
        end

        if capture then
            candidate = capture.title or capture.name or capture.moduleId
            if candidate and candidate ~= "" then
                return candidate
            end
        end

        return "Custom Module"
    end

    local function BuildSourceInfo()
        local moduleId = metadata and metadata.moduleId
        if (not moduleId or moduleId == "") and capture then
            moduleId = capture.moduleId or capture.name or capture.title
        end

        local sourceName = ResolveSourceName()
        return {
            kind = "custom",
            id = tostring(moduleId or sourceName),
            name = tostring(sourceName),
            label = format("MedaAuras / Custom: %s", tostring(sourceName)),
        }
    end

    local function ResolveLogArg(selfOrMessage, maybeMessage)
        if maybeMessage ~= nil then
            return maybeMessage
        end
        return selfOrMessage
    end

    local proxy = setmetatable({
        Log = function(selfOrMessage, maybeMessage)
            if MedaAuras and MedaAuras.Log then
                return MedaAuras.Log(ResolveLogArg(selfOrMessage, maybeMessage), BuildSourceInfo())
            end
        end,
        LogDebug = function(selfOrMessage, maybeMessage)
            if MedaAuras and MedaAuras.LogDebug then
                return MedaAuras.LogDebug(ResolveLogArg(selfOrMessage, maybeMessage), BuildSourceInfo())
            end
        end,
        LogWarn = function(selfOrMessage, maybeMessage)
            if MedaAuras and MedaAuras.LogWarn then
                return MedaAuras.LogWarn(ResolveLogArg(selfOrMessage, maybeMessage), BuildSourceInfo())
            end
        end,
        LogError = function(selfOrMessage, maybeMessage)
            if MedaAuras and MedaAuras.LogError then
                return MedaAuras.LogError(ResolveLogArg(selfOrMessage, maybeMessage), BuildSourceInfo())
            end
        end,
        LogTable = function(selfOrTable, maybeTable, maybeName, maybeMaxDepth)
            local tbl
            local name
            local maxDepth
            if type(maybeTable) == "table" then
                tbl = maybeTable
                name = maybeName
                maxDepth = maybeMaxDepth
            else
                tbl = selfOrTable
                name = maybeTable
                maxDepth = maybeName
            end
            if MedaAuras and MedaAuras.LogTable then
                return MedaAuras.LogTable(tbl, name, maxDepth, BuildSourceInfo())
            end
        end,
        RegisterCustomModule = function(selfOrConfig, maybeConfig)
            local config = maybeConfig or selfOrConfig
            if type(config) ~= "table" then
                return
            end
            capture = config
        end,
    }, { __index = MedaAuras })

    local env = setmetatable({
        MedaAuras = proxy,
        MedaUI = MedaUI,
    }, { __index = _G })

    local chunk, err = loadstring(code)
    if not chunk then
        return nil, err
    end

    if setfenv then
        setfenv(chunk, env)
    end

    local ok, runErr = xpcall(chunk, function(e)
        return tostring(e) .. "\n" .. debugstack(2)
    end)
    if not ok then
        return nil, runErr
    end

    if type(capture) ~= "table" then
        return nil, "Code did not call MedaAuras.RegisterCustomModule."
    end

    capture.defaults = type(capture.defaults) == "table" and capture.defaults or {}
    if capture.defaults.enabled == nil then
        capture.defaults.enabled = false
    end

    local function PickMetadataValue(capturedValue, metadataValue)
        if preferMetadata and metadataValue ~= nil then
            return metadataValue
        end
        if capturedValue ~= nil then
            return capturedValue
        end
        return metadataValue
    end

    local mergedMeta = NormalizeMetadata(metadata and metadata.moduleId, {
        moduleId = PickMetadataValue(capture.moduleId, metadata and metadata.moduleId),
        name = PickMetadataValue(capture.name, metadata and metadata.name),
        title = PickMetadataValue(capture.title, metadata and metadata.title),
        author = PickMetadataValue(capture.author, metadata and metadata.author),
        description = PickMetadataValue(capture.description, metadata and metadata.description),
        moduleVersion = PickMetadataValue(capture.version, metadata and metadata.moduleVersion),
        dataVersion = PickMetadataValue(capture.dataVersion, metadata and metadata.dataVersion),
        apiVersion = metadata and metadata.apiVersion or CUSTOM_API_VERSION,
        packageVersion = metadata and metadata.packageVersion or CUSTOM_PACKAGE_VERSION,
        createdAt = metadata and metadata.createdAt or time(),
        importedAt = metadata and metadata.importedAt or time(),
    })

    capture.moduleId = mergedMeta.moduleId
    capture.name = mergedMeta.name
    capture.title = mergedMeta.title
    capture.version = mergedMeta.moduleVersion
    capture.author = mergedMeta.author
    capture.description = mergedMeta.description
    capture.dataVersion = mergedMeta.dataVersion
    capture.apiVersion = mergedMeta.apiVersion
    capture.packageVersion = mergedMeta.packageVersion
    capture.isCustom = true
    capture.provenance = "custom"
    capture.sidebarDesc = capture.sidebarDesc or "User-authored custom module"
    capture.stability = capture.stability or "stable"

    return capture, mergedMeta
end

local function BuildRecordFromCode(code)
    code = tostring(code or "")
    local chunk, err = loadstring(code)
    if not chunk then
        return nil, err
    end

    local captured, execErr = EvaluateModuleCode(code)
    if not captured then
        return nil, execErr
    end

    if not IsSimpleVersion(captured.version) then
        return nil, "Custom modules must use a simple dotted numeric version like v1.0 or 1.1."
    end

    local metadata = NormalizeMetadata(captured.moduleId, {
        moduleId = captured.moduleId,
        name = captured.name,
        title = captured.title,
        author = captured.author,
        description = captured.description,
        moduleVersion = captured.version,
        dataVersion = captured.dataVersion,
        apiVersion = captured.apiVersion,
        packageVersion = CUSTOM_PACKAGE_VERSION,
        createdAt = time(),
        importedAt = time(),
    })

    local record = {
        source = "custom",
        trusted = true,
        metadata = metadata,
        code = code,
        defaults = DeepCopy(captured.defaults or {}),
        data = MergeDefaults({}, captured.defaults or {}),
        crashCount = 0,
        lastError = nil,
    }

    record.checksum = BuildChecksumForPackage({
        packageVersion = CUSTOM_PACKAGE_VERSION,
        kind = "MedaAurasCustomModule",
        metadata = {
            moduleId = metadata.moduleId,
            name = metadata.name,
            title = metadata.title,
            author = metadata.author,
            description = metadata.description,
            moduleVersion = metadata.moduleVersion,
            dataVersion = metadata.dataVersion,
            apiVersion = metadata.apiVersion,
            exportMode = "codeAndData",
        },
        code = record.code,
        defaults = record.defaults,
        data = record.data,
    })

    return record, nil, captured
end

local function GetRecordByRef(ref)
    local store = GetStore()
    if not store then return nil, nil end

    local moduleId = GetModuleIdFromKey(ref) or ref
    if moduleId and store[moduleId] then
        return moduleId, store[moduleId]
    end

    if nameToModuleId[ref] and store[nameToModuleId[ref]] then
        return nameToModuleId[ref], store[nameToModuleId[ref]]
    end

    for id, record in pairs(store) do
        if record.metadata and (record.metadata.name == ref or record.metadata.title == ref) then
            return id, record
        end
    end
end

local function CallRuntimeFunction(moduleId, label, func, ...)
    local store = GetStore()
    local record = store and store[moduleId]
    if type(func) ~= "function" then
        return true
    end

    local ok, err = xpcall(func, function(e)
        return format("[MedaAuras:Custom:%s:%s] %s\n%s", moduleId, label, e, debugstack(2))
    end, ...)

    if not ok then
        if record then
            record.lastError = err
            record.crashCount = (record.crashCount or 0) + 1
            if record.crashCount >= CUSTOM_CRASH_THRESHOLD then
                record.data.enabled = false
                LogWarn(format("Auto-disabled custom module '%s' after %d errors", moduleId, record.crashCount))
            end
        end
        LogError(err)
    elseif record then
        record.lastError = nil
    end

    return ok, err
end

local function EnsureRuntimeLoaded(moduleId)
    local store = GetStore()
    local record = store and store[moduleId]
    if not record then
        return nil, "Unknown custom module."
    end
    if tonumber(record.metadata and record.metadata.apiVersion or 0) > CUSTOM_API_VERSION then
        return nil, format("Custom module API version %s is newer than this MedaAuras build supports.", tostring(record.metadata.apiVersion))
    end

    local runtime = runtimeModules[moduleId]
    if runtime and runtime.code == record.code then
        return runtime
    end

    local captured, codeErr = EvaluateModuleCode(record.code, record.metadata, true)
    if not captured then
        record.lastError = codeErr
        return nil, codeErr
    end

    record.defaults = MergeDefaults(record.defaults or {}, captured.defaults or {})
    record.data = MergeDefaults(record.data or {}, record.defaults)

    runtime = {
        moduleId = moduleId,
        config = captured,
        code = record.code,
        initialized = false,
    }

    runtimeModules[moduleId] = runtime
    ReindexRuntimeNames()
    return runtime
end

local function InitializeRuntime(moduleId, runtime)
    local store = GetStore()
    local record = store and store[moduleId]
    if not runtime or not record then
        return false
    end

    if runtime.initialized then
        return true
    end

    if runtime.config.MigrateData and record.data and record.metadata then
        local fromVersion = tonumber(record.data.__dataVersion or record.metadata.dataVersion or 1) or 1
        local toVersion = tonumber(runtime.config.dataVersion or record.metadata.dataVersion or 1) or 1
        if fromVersion ~= toVersion then
            local ok = CallRuntimeFunction(moduleId, "MigrateData", runtime.config.MigrateData, record.data, fromVersion, toVersion)
            if ok then
                record.data.__dataVersion = toVersion
            end
        end
    end

    if runtime.config.OnInitialize then
        local ok = CallRuntimeFunction(moduleId, "OnInitialize", runtime.config.OnInitialize, record.data)
        if not ok then
            return false
        end
    end

    runtime.initialized = true
    record.data.__dataVersion = tonumber(runtime.config.dataVersion or record.metadata.dataVersion or 1) or 1
    return true
end

local function EnableRuntime(moduleId, runtime, record)
    record = record or (GetStore() and GetStore()[moduleId]) or nil
    if not runtime or not record then
        return false
    end

    if not InitializeRuntime(moduleId, runtime) then
        return false
    end

    if runtime.config.OnEnable then
        local ok = CallRuntimeFunction(moduleId, "OnEnable", runtime.config.OnEnable, record.data)
        if not ok then
            return false
        end
    end

    return true
end

local function BuildPackageFromRecord(record, exportMode)
    if not record then
        return nil
    end

    exportMode = exportMode == "codeAndData" and "codeAndData" or "codeOnly"

    local pkg = {
        packageVersion = CUSTOM_PACKAGE_VERSION,
        kind = "MedaAurasCustomModule",
        metadata = {
            moduleId = record.metadata.moduleId,
            name = record.metadata.name,
            title = record.metadata.title,
            author = record.metadata.author,
            description = record.metadata.description,
            moduleVersion = record.metadata.moduleVersion,
            dataVersion = record.metadata.dataVersion,
            apiVersion = record.metadata.apiVersion,
            exportedAt = time(),
            hasCustomCode = true,
            exportMode = exportMode,
        },
        code = record.code,
        defaults = DeepCopy(record.defaults or {}),
        data = exportMode == "codeAndData" and DeepCopy(record.data or {}) or nil,
    }

    pkg.checksum = BuildChecksumForPackage(pkg)
    return pkg
end

local function RecomputeRecordChecksum(record)
    record.checksum = BuildChecksumForPackage({
        packageVersion = record.metadata.packageVersion or CUSTOM_PACKAGE_VERSION,
        kind = "MedaAurasCustomModule",
        metadata = {
            moduleId = record.metadata.moduleId,
            name = record.metadata.name,
            title = record.metadata.title,
            author = record.metadata.author,
            description = record.metadata.description,
            moduleVersion = record.metadata.moduleVersion,
            dataVersion = record.metadata.dataVersion,
            apiVersion = record.metadata.apiVersion,
            exportMode = "codeAndData",
        },
        code = record.code,
        defaults = record.defaults,
        data = record.data,
    })
    return record
end

local function ReactivateInstalledModule(moduleId, wasEnabled)
    local store = GetStore()
    local record = store and store[moduleId]
    if not record then
        return false
    end

    if not wasEnabled then
        record.data.enabled = false
        return true
    end

    record.data.enabled = false
    return MedaAuras:EnableCustomModule(moduleId)
end

local function InstallRecord(moduleId, newRecord, installMode)
    local store = GetStore()
    if not store then
        return nil, "Custom module DB is not available yet."
    end

    installMode = installMode or {}
    local existing = store[moduleId]
    local wasEnabled = existing and existing.data and existing.data.enabled
    if wasEnabled and MedaAuras.DisableCustomModule then
        MedaAuras:DisableCustomModule(moduleId)
    end
    if existing then
        existing.lastBackup = {
            metadata = DeepCopy(existing.metadata),
            code = existing.code,
            defaults = DeepCopy(existing.defaults),
            data = DeepCopy(existing.data),
            checksum = existing.checksum,
            backedUpAt = time(),
        }
    end

    local dataMode = installMode.dataMode or "keep"
    local finalData
    if existing then
        if dataMode == "replace" then
            finalData = MergeDefaults(DeepCopy(newRecord.data or {}), newRecord.defaults or {})
        elseif dataMode == "merge" then
            finalData = DeepCopy(existing.data or {})
            MergeMissingKeys(finalData, newRecord.data or {})
            MergeDefaults(finalData, newRecord.defaults or {})
        else
            finalData = DeepCopy(existing.data or {})
            MergeDefaults(finalData, newRecord.defaults or {})
        end
    else
        finalData = MergeDefaults(DeepCopy(newRecord.data or {}), newRecord.defaults or {})
    end

    newRecord.data = finalData
    newRecord.lastBackup = existing and existing.lastBackup or newRecord.lastBackup
    newRecord.crashCount = 0
    newRecord.lastError = nil
    RecomputeRecordChecksum(newRecord)

    store[moduleId] = newRecord
    runtimeModules[moduleId] = nil
    ReindexRuntimeNames()
    ReactivateInstalledModule(moduleId, wasEnabled)
    return store[moduleId]
end

local function DecodePackagePayload(str)
    if not Serializer or not LibDeflate then
        return nil, "Import/export libraries are not available. Rebuild externals first."
    end

    str = Trim(str)
    if #str > 500000 then
        return nil, "Import string is too large."
    end
    if not str:find("^" .. CUSTOM_PREFIX:gsub("(%p)", "%%%1")) then
        return nil, "Invalid import string prefix."
    end

    local encoded = sub(str, #CUSTOM_PREFIX + 1)
    local compressed = LibDeflate:DecodeForPrint(encoded)
    if not compressed then
        return nil, "Failed to decode import string."
    end

    local serialized = LibDeflate:DecompressDeflate(compressed)
    if not serialized then
        return nil, "Failed to decompress import string."
    end

    local pcallOk, decoded, second = pcall(Serializer.Deserialize, Serializer, serialized)
    if not pcallOk then
        return nil, "Failed to deserialize package: " .. tostring(decoded)
    end
    if type(decoded) == "boolean" then
        if not decoded then
            return nil, second or "Failed to deserialize package."
        end
        decoded = second
    end

    if type(decoded) ~= "table" then
        return nil, "Decoded import payload is not a table."
    end

    if decoded.kind ~= "MedaAurasCustomModule" then
        return nil, "Unsupported package kind."
    end

    decoded.packageVersion = tonumber(decoded.packageVersion) or CUSTOM_PACKAGE_VERSION
    if decoded.packageVersion > CUSTOM_PACKAGE_VERSION then
        return nil, format("This package uses format v%d, but this addon only supports v%d.", decoded.packageVersion, CUSTOM_PACKAGE_VERSION)
    end
    decoded.metadata = NormalizeMetadata(decoded.metadata and decoded.metadata.moduleId, decoded.metadata)
    if decoded.metadata.apiVersion > CUSTOM_API_VERSION then
        return nil, format("This module requires custom module API v%d, but this addon supports v%d.", decoded.metadata.apiVersion, CUSTOM_API_VERSION)
    end
    decoded.defaults = type(decoded.defaults) == "table" and decoded.defaults or {}
    decoded.data = type(decoded.data) == "table" and decoded.data or nil
    decoded.checksum = tostring(decoded.checksum or "")

    local expected = BuildChecksumForPackage(decoded)
    if decoded.checksum ~= "" and decoded.checksum ~= expected then
        return nil, "Import checksum mismatch. The string may be corrupted."
    end
    decoded.checksum = expected

    return decoded
end

local function BuildRecordFromPackage(pkg, forceCopy)
    local metadata = NormalizeMetadata(pkg.metadata and pkg.metadata.moduleId, {
        moduleId = forceCopy and GenerateModuleId((pkg.metadata and pkg.metadata.name) or "custom-module") or (pkg.metadata and pkg.metadata.moduleId),
        name = pkg.metadata and pkg.metadata.name,
        title = pkg.metadata and pkg.metadata.title,
        author = pkg.metadata and pkg.metadata.author,
        description = pkg.metadata and pkg.metadata.description,
        moduleVersion = pkg.metadata and pkg.metadata.moduleVersion,
        dataVersion = pkg.metadata and pkg.metadata.dataVersion,
        apiVersion = pkg.metadata and pkg.metadata.apiVersion,
        packageVersion = pkg.packageVersion,
        importedAt = time(),
        createdAt = time(),
    })

    local captured, codeErr = EvaluateModuleCode(pkg.code or "", metadata, true)
    if not captured then
        return nil, nil, codeErr
    end

    if not IsSimpleVersion(metadata.moduleVersion) then
        return nil, nil, "Imported modules must use a simple dotted numeric version like v1.0 or 1.1."
    end

    if forceCopy then
        metadata.name = metadata.name .. " Copy"
        metadata.title = metadata.title .. " Copy"
        metadata.moduleId = GenerateModuleId(metadata.name)
    end

    local record = {
        source = "custom",
        trusted = true,
        metadata = metadata,
        code = tostring(pkg.code or ""),
        defaults = MergeDefaults(DeepCopy(captured.defaults or {}), pkg.defaults or {}),
        data = DeepCopy(pkg.data or {}),
        checksum = tostring(pkg.checksum or ""),
        crashCount = 0,
        lastError = nil,
    }
    record.code = ApplyMetadataToCode(record.code, metadata)

    if record.defaults.enabled == nil then
        record.defaults.enabled = false
    end

    record.data = MergeDefaults(record.data, record.defaults)
    record.data.enabled = false
    if record.data.__dataVersion == nil then
        record.data.__dataVersion = metadata.dataVersion
    end
    record.checksum = BuildChecksumForPackage({
        packageVersion = pkg.packageVersion or CUSTOM_PACKAGE_VERSION,
        kind = "MedaAurasCustomModule",
        metadata = {
            moduleId = metadata.moduleId,
            name = metadata.name,
            title = metadata.title,
            author = metadata.author,
            description = metadata.description,
            moduleVersion = metadata.moduleVersion,
            dataVersion = metadata.dataVersion,
            apiVersion = metadata.apiVersion,
            exportMode = pkg.metadata and pkg.metadata.exportMode or "codeOnly",
        },
        code = record.code,
        defaults = record.defaults,
        data = record.data,
    })

    return metadata.moduleId, record, nil
end

function MedaAuras:RegisterCustomModule(_)
    error("MedaAuras.RegisterCustomModule can only be used from custom module code.")
end

function MedaAuras:IsCustomModuleKey(key)
    return GetModuleIdFromKey(key) ~= nil
end

function MedaAuras:GetCustomModuleKey(moduleId)
    return BuildDisplayKey(moduleId)
end

function MedaAuras:GetCustomModule(ref)
    local _, record = GetRecordByRef(ref)
    return record
end

function MedaAuras:GetCustomModuleEntries()
    local store = GetStore()
    local entries = {}
    if not store then
        return entries
    end

    for moduleId, record in pairs(store) do
        entries[#entries + 1] = {
            key = BuildDisplayKey(moduleId),
            moduleId = moduleId,
            record = record,
            runtime = runtimeModules[moduleId],
            title = record.metadata and record.metadata.title or moduleId,
        }
    end

    sort(entries, function(a, b)
        return lower(a.title or "") < lower(b.title or "")
    end)

    return entries
end

function MedaAuras:GetCustomModuleConfig(key)
    local moduleId = GetModuleIdFromKey(key) or key
    local record = moduleId and GetStore() and GetStore()[moduleId]
    if not record then return nil end

    return {
        name = key,
        title = record.metadata.title,
        version = record.metadata.moduleVersion,
        stability = "stable",
        sidebarDesc = record.metadata.description,
        isCustom = true,
        customTag = "Custom",
        customColor = CUSTOM_COLOR,
    }
end

function MedaAuras:GetCustomModuleDB(key)
    local moduleId = GetModuleIdFromKey(key) or key
    local record = moduleId and GetStore() and GetStore()[moduleId]
    return record and record.data
end

function MedaAuras:InitCustomModules()
    local store = GetStore()
    if not store then return end

    local normalized = {}
    for moduleId, record in pairs(store) do
        local newId, newRecord = NormalizeStoredRecord(moduleId, record)
        normalized[newId] = newRecord
    end

    MedaAurasDB.customModules = normalized
    ReindexRuntimeNames()
end

function MedaAuras:LoadCustomModules()
    local store = GetStore()
    if not store then return end

    for moduleId, record in pairs(store) do
        if record.data and record.data.enabled then
            local runtime, err = EnsureRuntimeLoaded(moduleId)
            if runtime then
                if not EnableRuntime(moduleId, runtime, record) then
                    record.data.enabled = false
                end
            else
                record.data.enabled = false
                LogWarn(format("Failed to load custom module '%s': %s", moduleId, tostring(err)))
            end
        end
    end
end

function MedaAuras:EnableCustomModule(ref)
    local moduleId, record = GetRecordByRef(ref)
    if not moduleId or not record then
        return false
    end

    local runtime, err = EnsureRuntimeLoaded(moduleId)
    if not runtime then
        record.lastError = err
        print(format("|cff00ccffMedaAuras:|r Failed to load custom module: %s", tostring(err)))
        return false
    end

    record.data.enabled = true
    if not EnableRuntime(moduleId, runtime, record) then
        record.data.enabled = false
        return false
    end

    return true
end

function MedaAuras:DisableCustomModule(ref)
    local moduleId, record = GetRecordByRef(ref)
    if not moduleId or not record then
        return false
    end

    local runtime = runtimeModules[moduleId]
    if runtime and runtime.config and runtime.config.OnDisable then
        CallRuntimeFunction(moduleId, "OnDisable", runtime.config.OnDisable, record.data)
    end

    record.data.enabled = false
    return true
end

function MedaAuras:BackupCustomModule(ref)
    local moduleId, record = GetRecordByRef(ref)
    if not moduleId or not record then
        return false
    end

    record.lastBackup = {
        metadata = DeepCopy(record.metadata),
        code = record.code,
        defaults = DeepCopy(record.defaults),
        data = DeepCopy(record.data),
        checksum = record.checksum,
        backedUpAt = time(),
    }
    return true
end

function MedaAuras:RestoreCustomModuleBackup(ref)
    local moduleId, record = GetRecordByRef(ref)
    if not moduleId or not record or not record.lastBackup then
        return false, "No backup available."
    end

    local backup = record.lastBackup
    local restoredId = (backup.metadata and backup.metadata.moduleId) or moduleId
    local store = GetStore()
    local wasEnabled = record.data and record.data.enabled
    if wasEnabled then
        self:DisableCustomModule(moduleId)
    end

    local restoredRecord = {
        source = "custom",
        trusted = true,
        metadata = DeepCopy(backup.metadata or {}),
        code = backup.code or "",
        defaults = DeepCopy(backup.defaults or {}),
        data = DeepCopy(backup.data or {}),
        checksum = backup.checksum,
        crashCount = 0,
        lastError = nil,
        lastBackup = {
            metadata = DeepCopy(record.metadata),
            code = record.code,
            defaults = DeepCopy(record.defaults),
            data = DeepCopy(record.data),
            checksum = record.checksum,
            backedUpAt = time(),
        },
    }

    restoredRecord.metadata = NormalizeMetadata(restoredId, restoredRecord.metadata)
    restoredRecord.data = MergeDefaults(restoredRecord.data, restoredRecord.defaults)
    RecomputeRecordChecksum(restoredRecord)
    store[moduleId] = nil
    store[restoredRecord.metadata.moduleId] = restoredRecord
    runtimeModules[moduleId] = nil
    runtimeModules[restoredRecord.metadata.moduleId] = nil
    ReindexRuntimeNames()
    ReactivateInstalledModule(restoredRecord.metadata.moduleId, wasEnabled)
    return true
end

function MedaAuras:RemoveCustomModule(ref)
    local moduleId, record = GetRecordByRef(ref)
    if not moduleId or not record then
        return false
    end

    if record.data and record.data.enabled then
        self:DisableCustomModule(moduleId)
    end

    local store = GetStore()
    if store then
        store[moduleId] = nil
    end
    runtimeModules[moduleId] = nil
    ReindexRuntimeNames()
    return true
end

function MedaAuras:DuplicateCustomModule(ref)
    local moduleId, record = GetRecordByRef(ref)
    if not moduleId or not record then
        return false, "Custom module not found."
    end

    local copyId = GenerateModuleId(record.metadata.name)
    local copyRecord = DeepCopy(record)
    copyRecord.metadata.moduleId = copyId
    copyRecord.metadata.name = copyRecord.metadata.name .. " Copy"
    copyRecord.metadata.title = copyRecord.metadata.title .. " Copy"
    copyRecord.metadata.createdAt = time()
    copyRecord.metadata.importedAt = time()
    copyRecord.code = ApplyMetadataToCode(copyRecord.code, copyRecord.metadata)
    copyRecord.data.enabled = false
    copyRecord.lastBackup = nil
    copyRecord.lastError = nil
    copyRecord.crashCount = 0

    local store = GetStore()
    store[copyId] = copyRecord
    runtimeModules[copyId] = nil
    ReindexRuntimeNames()
    return copyId
end

function MedaAuras:CreateCustomModuleFromCode(code)
    local record, err = BuildRecordFromCode(code)
    if not record then
        return nil, err
    end

    local installed = InstallRecord(record.metadata.moduleId, record, {
        dataMode = "keep",
    })
    return installed
end

function MedaAuras:ExportCustomModule(ref, exportMode)
    local _, record = GetRecordByRef(ref)
    if not record then
        return nil, "Custom module not found."
    end

    if not Serializer or not LibDeflate then
        return nil, "LibSerialize or LibDeflate is not available."
    end

    local pkg = BuildPackageFromRecord(record, exportMode)
    local serialized = Serializer:Serialize(pkg)
    local compressed = LibDeflate:CompressDeflate(serialized, { level = 9 })
    local encoded = LibDeflate:EncodeForPrint(compressed)
    return CUSTOM_PREFIX .. encoded
end

function MedaAuras:DecodeImportString(str)
    return DecodePackagePayload(str)
end

function MedaAuras:InstallImportedCustomModule(pkg, installMode)
    installMode = installMode or {}

    local forceCopy = installMode.action == "copy"
    local moduleId, record, err = BuildRecordFromPackage(pkg, forceCopy)
    if not moduleId or not record then
        return nil, err or "Failed to validate imported module package."
    end

    local existing = GetStore() and GetStore()[moduleId]
    local action = installMode.action or "update"
    if not existing then
        action = "install"
    end

    if action == "rollback" or action == "reinstall" or action == "update" then
        -- Backup happens inside InstallRecord.
    end

    local installed = InstallRecord(moduleId, record, {
        dataMode = installMode.dataMode or "keep",
    })
    return installed
end

function MedaAuras:ShowCustomModuleTextPopup(title, text, highlight)
    if not textPopupDialog then
        textPopupDialog = MedaUI:CreateImportExportDialog({ width = 560, height = 360 })
    end
    textPopupDialog:ShowExport(title or "Custom Module", text)
end

local function EnsureImportFrame()
    if importFrame then
        return importFrame
    end

    importFrame = MedaUI:CreateThemedFrame(UIParent, "MedaAurasCustomModuleImport", 720, 600, "backgroundDark")
    importFrame:SetPoint("CENTER")
    importFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    importFrame:SetMovable(true)
    importFrame:EnableMouse(true)
    importFrame:RegisterForDrag("LeftButton")
    importFrame:SetScript("OnDragStart", importFrame.StartMoving)
    importFrame:SetScript("OnDragStop", importFrame.StopMovingOrSizing)

    importFrame.title = importFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    importFrame.title:SetPoint("TOPLEFT", 14, -12)
    importFrame.title:SetText("Import / Create Custom Module")

    importFrame.warning = importFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    importFrame.warning:SetPoint("TOPLEFT", importFrame.title, "BOTTOMLEFT", 0, -6)
    importFrame.warning:SetPoint("RIGHT", -14, 0)
    importFrame.warning:SetJustifyH("LEFT")
    importFrame.warning:SetText("Paste an import string or raw Lua module code. Only use content from people you trust.")
    importFrame.warning:SetTextColor(unpack(WARNING_COLOR))

    local scrollBg = CreateFrame("Frame", nil, importFrame, "BackdropTemplate")
    scrollBg:SetPoint("TOPLEFT", 14, -64)
    scrollBg:SetPoint("TOPRIGHT", -14, -64)
    scrollBg:SetHeight(210)
    scrollBg:SetBackdrop(MedaUI:CreateBackdrop(true))
    MedaUI:RegisterThemedWidget(scrollBg, function()
        ApplyInputContainerTheme(scrollBg, importFrame.editBox and importFrame.editBox:HasFocus())
    end)
    ApplyInputContainerTheme(scrollBg, false)

    local clickHint = importFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    clickHint:SetPoint("BOTTOMLEFT", scrollBg, "TOPLEFT", 2, 6)
    clickHint:SetText("Paste a shared module string or raw Lua code here.")
    clickHint:SetTextColor(0.7, 0.75, 0.85)

    local scrollParent = MedaUI:CreateScrollFrame(scrollBg)
    Pixel.SetPoint(scrollParent, "TOPLEFT", 6, -6)
    Pixel.SetPoint(scrollParent, "BOTTOMRIGHT", -6, 6)
    importFrame.scrollParent = scrollParent

    local editBox = CreateFrame("EditBox", nil, scrollParent.scrollContent)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject("ChatFontNormal")
    editBox:SetMaxLetters(0)
    editBox:SetPoint("TOPLEFT")
    editBox:SetPoint("TOPRIGHT")
    editBox:SetWidth(660)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editBox:SetScript("OnTextChanged", function()
        local height = EstimateEditBoxHeight(editBox, 180)
        editBox:SetHeight(height)
        scrollParent:SetContentHeight(height, true, true)
        importFrame.decodedPackage = nil
        importFrame.createdRecord = nil
    end)
    importFrame.editBox = editBox
    AttachInputFocusStyling(editBox, scrollBg, scrollParent.scrollFrame)

    importFrame.metadata = importFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    importFrame.metadata:SetPoint("TOPLEFT", scrollBg, "BOTTOMLEFT", 0, -10)
    importFrame.metadata:SetPoint("TOPRIGHT", scrollBg, "BOTTOMRIGHT", 0, -10)
    importFrame.metadata:SetJustifyH("LEFT")
    importFrame.metadata:SetJustifyV("TOP")
    importFrame.metadata:SetText("Paste content above and click Validate to preview.")

    importFrame.actionLabel = importFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    importFrame.actionLabel:SetPoint("TOPLEFT", importFrame.metadata, "BOTTOMLEFT", 0, -12)
    importFrame.actionLabel:SetText("Install Mode")

    importFrame.keepData = MedaUI:CreateCheckbox(importFrame, "Keep Local Data")
    importFrame.keepData:SetPoint("TOPLEFT", importFrame.actionLabel, "BOTTOMLEFT", 0, -8)
    importFrame.keepData:SetChecked(true)
    importFrame.mergeData = MedaUI:CreateCheckbox(importFrame, "Merge Incoming Data")
    importFrame.mergeData:SetPoint("TOPLEFT", importFrame.keepData, "BOTTOMLEFT", 0, -6)
    importFrame.replaceData = MedaUI:CreateCheckbox(importFrame, "Replace Local Data")
    importFrame.replaceData:SetPoint("TOPLEFT", importFrame.mergeData, "BOTTOMLEFT", 0, -6)

    local function SelectDataMode(which)
        importFrame.keepData:SetChecked(which == "keep")
        importFrame.mergeData:SetChecked(which == "merge")
        importFrame.replaceData:SetChecked(which == "replace")
        importFrame.dataMode = which
    end
    importFrame.keepData.OnValueChanged = function(_, checked) if checked then SelectDataMode("keep") end end
    importFrame.mergeData.OnValueChanged = function(_, checked) if checked then SelectDataMode("merge") end end
    importFrame.replaceData.OnValueChanged = function(_, checked) if checked then SelectDataMode("replace") end end
    SelectDataMode("keep")

    importFrame.status = importFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    importFrame.status:SetPoint("TOPLEFT", importFrame.replaceData, "BOTTOMLEFT", 0, -10)
    importFrame.status:SetPoint("RIGHT", -14, 0)
    importFrame.status:SetJustifyH("LEFT")

    local metaFields = CreateFrame("Frame", nil, importFrame)
    metaFields:SetPoint("TOPLEFT", importFrame.metadata, "BOTTOMLEFT", 0, -8)
    metaFields:SetPoint("RIGHT", -14, 0)
    metaFields:SetHeight(120)
    metaFields:Hide()
    importFrame.metaFields = metaFields

    local function CreateMetaField(parent, label, yOff)
        local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", 0, yOff)
        lbl:SetText(label)
        lbl:SetWidth(80)
        lbl:SetJustifyH("RIGHT")
        local box = MedaUI:CreateEditBox(parent, 400, 22)
        box:SetPoint("TOPLEFT", 88, yOff)
        return box
    end

    importFrame.nameField = CreateMetaField(metaFields, "Name:", 0)
    importFrame.authorField = CreateMetaField(metaFields, "Author:", -28)
    importFrame.versionField = CreateMetaField(metaFields, "Version:", -56)
    importFrame.descField = CreateMetaField(metaFields, "Description:", -84)

    local function SetDialogMode(mode)
        importFrame.inputMode = mode
        if mode == "create" then
            importFrame.actionLabel:Hide()
            importFrame.keepData:Hide()
            importFrame.mergeData:Hide()
            importFrame.replaceData:Hide()
            importFrame.metaFields:Show()
            importFrame.copyBtn:Hide()
            importFrame.viewCodeBtn:Hide()
            importFrame.status:ClearAllPoints()
            importFrame.status:SetPoint("TOPLEFT", importFrame.metaFields, "BOTTOMLEFT", 0, -10)
            importFrame.status:SetPoint("RIGHT", -14, 0)
        else
            importFrame.actionLabel:Show()
            importFrame.keepData:Show()
            importFrame.mergeData:Show()
            importFrame.replaceData:Show()
            importFrame.metaFields:Hide()
            importFrame.copyBtn:Show()
            importFrame.viewCodeBtn:Show()
            importFrame.status:ClearAllPoints()
            importFrame.status:SetPoint("TOPLEFT", importFrame.replaceData, "BOTTOMLEFT", 0, -10)
            importFrame.status:SetPoint("RIGHT", -14, 0)
        end
    end

    importFrame.decodeBtn = MedaUI:CreateButton(importFrame, "Validate")
    importFrame.decodeBtn:SetSize(90, 24)
    importFrame.decodeBtn:SetPoint("BOTTOMLEFT", 14, 14)

    importFrame.installBtn = MedaUI:CreateButton(importFrame, "Install")
    importFrame.installBtn:SetSize(90, 24)
    importFrame.installBtn:SetPoint("LEFT", importFrame.decodeBtn, "RIGHT", 8, 0)

    importFrame.copyBtn = MedaUI:CreateButton(importFrame, "Import as Copy")
    importFrame.copyBtn:SetSize(120, 24)
    importFrame.copyBtn:SetPoint("LEFT", importFrame.installBtn, "RIGHT", 8, 0)

    importFrame.viewCodeBtn = MedaUI:CreateButton(importFrame, "View Code")
    importFrame.viewCodeBtn:SetSize(100, 24)
    importFrame.viewCodeBtn:SetPoint("LEFT", importFrame.copyBtn, "RIGHT", 8, 0)

    importFrame.closeBtn = MedaUI:CreateButton(importFrame, "Close")
    importFrame.closeBtn:SetSize(90, 24)
    importFrame.closeBtn:SetPoint("BOTTOMRIGHT", -14, 14)
    importFrame.closeBtn:SetScript("OnClick", function() importFrame:Hide() end)

    importFrame.viewCodeBtn:SetScript("OnClick", function()
        if importFrame.decodedPackage then
            MedaAuras:ShowCustomModuleTextPopup("Imported Custom Module Code", importFrame.decodedPackage.code or "", false)
        end
    end)

    importFrame.decodeBtn:SetScript("OnClick", function()
        local input = importFrame.editBox:GetText()
        local trimmed = Trim(input)

        if trimmed == "" then
            SetStatus(importFrame.status, "Paste an import string or raw Lua module code first.", ERROR_COLOR)
            return
        end

        if trimmed:sub(1, #CUSTOM_PREFIX) == CUSTOM_PREFIX then
            SetDialogMode("import")
            local pkg, err = DecodePackagePayload(trimmed)
            if not pkg then
                importFrame.decodedPackage = nil
                importFrame.metadata:SetText("Decode failed.")
                SetStatus(importFrame.status, err or "Unknown decode error.", ERROR_COLOR)
                return
            end

            importFrame.decodedPackage = pkg
            local existingId, existing = GetRecordByRef(pkg.metadata.moduleId)
            local action = "install"
            local versionLine = "Install as new module."
            if existingId and existing then
                action = BuildVersionSummary(existing.metadata.moduleVersion, pkg.metadata.moduleVersion)
                if action == "update" then
                    versionLine = format("Update available: local %s -> incoming %s", FormatVersionDisplay(existing.metadata.moduleVersion), FormatVersionDisplay(pkg.metadata.moduleVersion))
                elseif action == "rollback" then
                    versionLine = format("Rollback available: local %s -> incoming %s", FormatVersionDisplay(existing.metadata.moduleVersion), FormatVersionDisplay(pkg.metadata.moduleVersion))
                else
                    versionLine = format("Same version detected: %s", FormatVersionDisplay(pkg.metadata.moduleVersion))
                end
            end

            importFrame.installAction = action
            importFrame.installBtn:SetText(action == "update" and "Update" or action == "rollback" and "Rollback" or action == "reinstall" and "Reinstall" or "Install")
            importFrame.metadata:SetText(format(
                "Module ID: %s\nName: %s\nTitle: %s\nAuthor: %s\nModule Version: %s\nData Version: %d\nExport Mode: %s\n%s\n\nDescription: %s",
                pkg.metadata.moduleId,
                pkg.metadata.name,
                pkg.metadata.title,
                pkg.metadata.author,
                FormatVersionDisplay(pkg.metadata.moduleVersion),
                pkg.metadata.dataVersion,
                pkg.metadata.exportMode or "codeOnly",
                versionLine,
                pkg.metadata.description or ""
            ))
            SetStatus(importFrame.status, "Decoded successfully. Imported modules are stored disabled until you enable them.", SUCCESS_COLOR)
        else
            SetDialogMode("create")
            local record, err = BuildRecordFromCode(trimmed)
            if not record then
                importFrame.createdRecord = nil
                importFrame.metadata:SetText("Validation failed.")
                SetStatus(importFrame.status, err or "Unknown validation error.", ERROR_COLOR)
                return
            end

            importFrame.createdRecord = record
            importFrame.installBtn:SetText("Install")
            importFrame.metadata:SetText(format(
                "Module ID: %s\nName: %s\nTitle: %s\nAuthor: %s\nVersion: %s\nData Version: %d",
                record.metadata.moduleId,
                record.metadata.name,
                record.metadata.title,
                record.metadata.author,
                FormatVersionDisplay(record.metadata.moduleVersion),
                record.metadata.dataVersion
            ))
            importFrame.nameField:SetText(record.metadata.name)
            importFrame.authorField:SetText(record.metadata.author)
            importFrame.versionField:SetText(record.metadata.moduleVersion)
            importFrame.descField:SetText(record.metadata.description)
            SetStatus(importFrame.status, "Valid Lua module. Edit metadata below if needed, then click Install.", SUCCESS_COLOR)
        end
    end)

    local function InstallDecoded(asCopy)
        if importFrame.inputMode == "create" then
            local userName = Trim(importFrame.nameField:GetText())
            local userAuthor = Trim(importFrame.authorField:GetText())
            local userVersion = Trim(importFrame.versionField:GetText())
            local userDesc = Trim(importFrame.descField:GetText())

            local code = Trim(importFrame.editBox:GetText())
            if code == "" then
                SetStatus(importFrame.status, "No code to install.", ERROR_COLOR)
                return
            end

            local record, err = BuildRecordFromCode(code)
            if not record then
                SetStatus(importFrame.status, err or "Validation failed.", ERROR_COLOR)
                return
            end

            local meta = record.metadata
            if userName ~= "" then meta.name = userName end
            meta.title = meta.name
            if userAuthor ~= "" then meta.author = userAuthor end
            meta.moduleVersion = NormalizeSimpleVersion(userVersion)
            if meta.moduleVersion == "" then meta.moduleVersion = "v1.0" end
            if userDesc ~= "" then meta.description = userDesc end
            if meta.moduleId == "" then
                meta.moduleId = GenerateModuleId(meta.name)
            end

            record.code = ApplyMetadataToCode(record.code, meta)

            local installed = InstallRecord(meta.moduleId, record, { dataMode = "keep" })
            if not installed then
                SetStatus(importFrame.status, "Install failed.", ERROR_COLOR)
                return
            end

            SetStatus(importFrame.status, "Module installed. Enable it from the sidebar when you are ready.", SUCCESS_COLOR)
            if MedaAuras.RebuildSettingsSidebar then
                MedaAuras:RebuildSettingsSidebar()
            end
            if MedaAuras.RefreshModuleConfig then
                MedaAuras:RefreshModuleConfig()
            end
            return
        end

        local pkg = importFrame.decodedPackage
        if not pkg then
            importFrame.decodeBtn:Click()
            pkg = importFrame.decodedPackage
            if not pkg then
                return
            end
        end

        local installed, err = MedaAuras:InstallImportedCustomModule(pkg, {
            action = asCopy and "copy" or importFrame.installAction,
            dataMode = importFrame.dataMode or "keep",
        })
        if not installed then
            SetStatus(importFrame.status, err or "Install failed.", ERROR_COLOR)
            return
        end

        SetStatus(importFrame.status, "Package imported. Enable the custom module from the sidebar when you are ready.", SUCCESS_COLOR)
        if MedaAuras.RebuildSettingsSidebar then
            MedaAuras:RebuildSettingsSidebar()
        end
        if MedaAuras.RefreshModuleConfig then
            MedaAuras:RefreshModuleConfig()
        end
    end

    importFrame.installBtn:SetScript("OnClick", function() InstallDecoded(false) end)
    importFrame.copyBtn:SetScript("OnClick", function() InstallDecoded(true) end)

    return importFrame
end

function MedaAuras:ShowImportCustomModuleDialog()
    local frame = EnsureImportFrame()
    frame:Show()
    frame.editBox:SetFocus()
end

local function AddInfoLine(parent, yOff, label, value, color)
    local left = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    left:SetPoint("TOPLEFT", 0, yOff)
    left:SetText(label)
    left:SetTextColor(0.7, 0.7, 0.7)

    local right = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    right:SetPoint("TOPLEFT", 140, yOff)
    right:SetPoint("RIGHT", -10, 0)
    right:SetJustifyH("LEFT")
    right:SetText(value or "")
    if color then
        right:SetTextColor(unpack(color))
    else
        right:SetTextColor(unpack(MedaUI.Theme.text))
    end

    return yOff - 18
end

function MedaAuras:BuildCustomModuleConfig(parent, key)
    local moduleId = GetModuleIdFromKey(key)
    local store = GetStore()
    local record = moduleId and store and store[moduleId]
    local stability = "stable"
    local stabilityColors = MedaAuras and MedaAuras.STABILITY_COLORS
    local stabilityColor = (stabilityColors and stabilityColors[stability]) or SUCCESS_COLOR
    if not record then
        return 40
    end

    local yOff = 0
    local header = MedaUI:CreateSectionHeader(parent, record.metadata.title)
    header:SetPoint("TOPLEFT", 0, yOff)
    yOff = yOff - 36

    local warning = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    warning:SetPoint("TOPLEFT", 0, yOff)
    warning:SetPoint("RIGHT", -10, 0)
    warning:SetJustifyH("LEFT")
    warning:SetText("Custom module code should only be imported from people you trust. Imported modules are kept disabled by default.")
    warning:SetTextColor(unpack(WARNING_COLOR))
    yOff = yOff - 36

    yOff = AddInfoLine(parent, yOff, "Module ID", record.metadata.moduleId)
    yOff = AddInfoLine(parent, yOff, "Author", record.metadata.author)
    yOff = AddInfoLine(parent, yOff, "Version", FormatVersionDisplay(record.metadata.moduleVersion))
    yOff = AddInfoLine(parent, yOff, "Stability", "Stable", stabilityColor)
    yOff = AddInfoLine(parent, yOff, "Data Version", tostring(record.metadata.dataVersion))
    yOff = AddInfoLine(parent, yOff, "Status", record.data and record.data.enabled and "Enabled" or "Disabled", record.data and record.data.enabled and SUCCESS_COLOR or WARNING_COLOR)
    yOff = AddInfoLine(parent, yOff, "Description", record.metadata.description)

    local exportCodeBtn = MedaUI:CreateButton(parent, "Export Code")
    exportCodeBtn:SetPoint("TOPLEFT", 0, yOff - 10)
    exportCodeBtn:SetScript("OnClick", function()
        local exportString, err = MedaAuras:ExportCustomModule(moduleId, "codeOnly")
        if exportString then
            MedaAuras:ShowCustomModuleTextPopup("Export Custom Module", exportString, true)
        else
            print(format("|cff00ccffMedaAuras:|r Export failed: %s", tostring(err)))
        end
    end)

    local exportDataBtn = MedaUI:CreateButton(parent, "Export + Settings")
    exportDataBtn:SetPoint("LEFT", exportCodeBtn, "RIGHT", 8, 0)
    exportDataBtn:SetScript("OnClick", function()
        local exportString, err = MedaAuras:ExportCustomModule(moduleId, "codeAndData")
        if exportString then
            MedaAuras:ShowCustomModuleTextPopup("Export Custom Module + Settings", exportString, true)
        else
            print(format("|cff00ccffMedaAuras:|r Export failed: %s", tostring(err)))
        end
    end)

    local viewCodeBtn = MedaUI:CreateButton(parent, "View Code")
    viewCodeBtn:SetPoint("LEFT", exportDataBtn, "RIGHT", 8, 0)
    viewCodeBtn:SetScript("OnClick", function()
        MedaAuras:ShowCustomModuleTextPopup("Custom Module Code", record.code or "", false)
    end)

    yOff = yOff - 44

    local duplicateBtn = MedaUI:CreateButton(parent, "Duplicate")
    duplicateBtn:SetPoint("TOPLEFT", 0, yOff)
    duplicateBtn:SetScript("OnClick", function()
        local copyId = MedaAuras:DuplicateCustomModule(moduleId)
        if copyId then
            print("|cff00ccffMedaAuras:|r Duplicated custom module.")
            if MedaAuras.RebuildSettingsSidebar then
                MedaAuras:RebuildSettingsSidebar()
            end
        end
    end)

    local restoreBtn = MedaUI:CreateButton(parent, "Restore Backup")
    restoreBtn:SetPoint("LEFT", duplicateBtn, "RIGHT", 8, 0)
    restoreBtn:SetEnabled(record.lastBackup ~= nil)
    restoreBtn:SetScript("OnClick", function()
        local ok, err = MedaAuras:RestoreCustomModuleBackup(moduleId)
        if ok then
            print("|cff00ccffMedaAuras:|r Restored custom module backup.")
            if MedaAuras.RebuildSettingsSidebar then
                MedaAuras:RebuildSettingsSidebar()
            end
            MedaAuras:RefreshModuleConfig()
        else
            print(format("|cff00ccffMedaAuras:|r Restore failed: %s", tostring(err)))
        end
    end)

    local removeBtn = MedaUI:CreateButton(parent, "Remove")
    removeBtn:SetPoint("LEFT", restoreBtn, "RIGHT", 8, 0)
    removeBtn:SetScript("OnClick", function()
        MedaAuras:RemoveCustomModule(moduleId)
        if MedaAuras.RebuildSettingsSidebar then
            MedaAuras:RebuildSettingsSidebar()
        end
        MedaAuras:RefreshModuleConfig()
    end)

    yOff = yOff - 44

    local runtime, err = EnsureRuntimeLoaded(moduleId)
    if not runtime then
        record.lastError = err or "Unable to load module code."
        yOff = AddInfoLine(parent, yOff, "Load Status", err or "Unable to load module code.", ERROR_COLOR)
        if MedaAuras.SetContentHeight then
            MedaAuras:SetContentHeight(math.abs(yOff) + 40)
        end
        return math.abs(yOff) + 40
    end

    if runtime.config and runtime.config.BuildConfig then
        local configHeader = MedaUI:CreateSectionHeader(parent, "Module Settings")
        configHeader:SetPoint("TOPLEFT", 0, yOff)
        yOff = yOff - 36

        local configHolder = CreateFrame("Frame", nil, parent)
        configHolder:SetPoint("TOPLEFT", 0, yOff)
        configHolder:SetPoint("RIGHT", -10, 0)
        configHolder:SetHeight(1)

        local originalSetContentHeight = MedaAuras.SetContentHeight
        local requestedConfigHeight = 0
        MedaAuras.SetContentHeight = function(_, height)
            requestedConfigHeight = math.max(requestedConfigHeight, tonumber(height) or 0)
            if originalSetContentHeight then
                originalSetContentHeight(MedaAuras, height + math.abs(yOff))
            end
        end

        local ok, buildErr = xpcall(runtime.config.BuildConfig, function(e)
            return format("[MedaAuras:Custom:%s:BuildConfig] %s\n%s", moduleId, e, debugstack(2))
        end, configHolder, record.data)

        MedaAuras.SetContentHeight = originalSetContentHeight

        if not ok then
            record.lastError = buildErr
            configHolder:Hide()
            if originalSetContentHeight then
                originalSetContentHeight(MedaAuras, math.abs(yOff) + 120)
            end
            AddInfoLine(parent, yOff, "Config Error", buildErr, ERROR_COLOR)
            LogError(buildErr)
            return math.abs(yOff) + 120
        elseif originalSetContentHeight then
            record.lastError = nil
            local finalHeight = math.abs(yOff) + math.max(requestedConfigHeight, 520)
            originalSetContentHeight(MedaAuras, finalHeight)
            return finalHeight
        end
    elseif MedaAuras.SetContentHeight then
        record.lastError = nil
        local finalHeight = math.abs(yOff) + 40
        MedaAuras:SetContentHeight(finalHeight)
        return finalHeight
    end

    return math.abs(yOff) + 40
end
