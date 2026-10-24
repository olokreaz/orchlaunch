-- OrchLaunch — CMakePresets discovery and resolution.
--
-- Reads `CMakePresets.json` and `CMakeUserPresets.json`, follows `include`
-- directives and resolves preset inheritance. This module is pure data: it
-- never launches processes nor touches the UI. It knows how to turn a CMake
-- configure preset into the compiler definitions needed to apply the project
-- toolchain when the preset does not select one itself.

local config = require("orchlaunch.config")

local M = {}

-- ============================================================================
-- Constants
-- ============================================================================

--- Preset kinds, mapped to their JSON keys (`<kind>Presets`).
---@type string[]
M.kinds = { "configure", "build", "test", "package", "workflow" }

local FILES = { "CMakePresets.json", "CMakeUserPresets.json" }

-- ============================================================================
-- JSON I/O
-- ============================================================================

---@param path string
---@return table?
local function read_json(path)
    if vim.fn.filereadable(path) == 0 then
        return nil
    end

    local file = io.open(path, "r")
    if not file then
        return nil
    end

    local content = file:read("*a")
    file:close()

    local ok, data = pcall(vim.json.decode, content)
    if not ok or type(data) ~= "table" then
        return nil
    end

    return data
end

-- ============================================================================
-- Macro expansion
-- ============================================================================

---@return string
local function host_system_name()
    local uname = vim.uv and vim.uv.os_uname and vim.uv.os_uname() or {}
    return uname.sysname or "Linux"
end

---@return string
local function path_list_sep()
    return package.config:sub(1, 1) == "\\" and ";" or ":"
end

--- Expands CMake preset macros in a string.
---
--- Supported: `$env{VAR}`, `$penv{VAR}`, `${sourceDir}`,
--- `${sourceParentDir}`, `${sourceDirName}`, `${fileDir}`, `${presetName}`,
--- `${hostSystemName}`, `${pathListSep}`, `${dollar}`.
---@param value any
---@param ctx table
---@return any
local function expand(value, ctx)
    if type(value) ~= "string" then
        return value
    end

    local env = ctx.env or {}
    local penv = ctx.penv or env
    local map = {
        sourceDir = ctx.source_dir,
        sourceParentDir = ctx.source_parent_dir,
        sourceDirName = ctx.source_dir_name,
        fileDir = ctx.file_dir,
        presetName = ctx.preset_name,
        hostSystemName = ctx.host_system_name or host_system_name(),
        pathListSep = path_list_sep(),
        dollar = "$",
    }

    local result = value
    for _ = 1, 20 do
        local before = result

        result = result:gsub("%$penv{([^}]+)}", function(name)
            return penv[name] or env[name] or ""
        end)
        result = result:gsub("%$env{([^}]+)}", function(name)
            return env[name] or ""
        end)
        result = result:gsub("%${([%w_]+)}", function(name)
            local mapped = map[name]
            if mapped ~= nil then
                return mapped
            end
            return "${" .. name .. "}"
        end)

        if result == before then
            break
        end
    end

    return result
end

---@param value any
---@param ctx table
---@return any
function M.expand(value, ctx)
    return expand(value, ctx)
end

-- ============================================================================
-- Discovery
-- ============================================================================

---@param list table[]?
---@param preset table
---@return table[]
local function upsert(list, preset)
    for index, existing in ipairs(list) do
        if existing.name == preset.name then
            list[index] = preset
            return list
        end
    end

    list[#list + 1] = preset
    return list
end

---@param path string
---@param result OrchCMakePresets
---@param seen table<string, boolean>
local function collect_file(path, result, seen)
    path = vim.fs.normalize(path)
    if seen[path] then
        return
    end
    seen[path] = true

    local data = read_json(path)
    if not data then
        return
    end

    result.sources[#result.sources + 1] = path

    if type(data.version) == "number" and (result.version == nil or data.version > result.version) then
        result.version = data.version
    end

    local dir = vim.fs.dirname(path)
    local env = vim.fn.environ()

    local includes = type(data.include) == "table" and data.include or {}

    -- Includes are processed first so the including file overrides them.
    for _, included in ipairs(includes) do
        local relative
        if type(included) == "string" then
            relative = included
        elseif type(included) == "table" and type(included.path) == "string" then
            relative = included.path
        end

        if relative then
            local resolved = expand(relative, { file_dir = dir, env = env, penv = env })
            if type(resolved) == "string" and resolved ~= "" then
                if not config.is_absolute(resolved) then
                    resolved = vim.fs.joinpath(dir, resolved)
                end
                collect_file(resolved, result, seen)
            end
        end
    end

    for _, kind in ipairs(M.kinds) do
        local list = data[kind .. "Presets"]
        if type(list) == "table" then
            for _, preset in ipairs(list) do
                if type(preset) == "table" and type(preset.name) == "string" and preset.name ~= "" then
                    preset._file_dir = dir
                    upsert(result[kind], preset)
                end
            end
        end
    end
end

--- Discovers every preset reachable from `root`.
---
--- `CMakeUserPresets.json` overrides `CMakePresets.json`; entries are keyed by
--- name within each kind, later files winning.
---@param root string
---@return OrchCMakePresets
function M.discover(root)
    ---@type OrchCMakePresets
    local result = {
        version = nil,
        sources = {},
        configure = {},
        build = {},
        test = {},
        package = {},
        workflow = {},
    }

    local seen = {}
    for _, file in ipairs(FILES) do
        collect_file(vim.fs.joinpath(root, file), result, seen)
    end

    return result
end

--- True when no preset source file was found.
---@param presets OrchCMakePresets
---@return boolean
function M.empty(presets)
    return #presets.sources == 0
end

-- ============================================================================
-- Accessors
-- ============================================================================

--- All presets of a kind, including hidden ones.
---@param presets OrchCMakePresets
---@param kind string
---@return OrchCMakePreset[]
function M.list(presets, kind)
    return presets[kind] or {}
end

--- Evaluates a CMake preset `condition` expression.
---
--- Supports the Boolean subset (`const`, `not`, `and`, `or`) and the common
--- comparison operators (`equals`, `in`, `matches`) with `$env{}`/`$penv{}`
--- expansion. Returns nil for an unsupported expression, so callers can choose
--- to exclude the preset instead of showing a preset that may not be valid.
---@param condition any
---@param ctx? table
---@return boolean?
function M.condition(condition, ctx)
    if condition == nil then
        return true
    end

    ctx = ctx or {}
    local env = ctx.env or vim.fn.environ()
    local expand_ctx = {
        env = env,
        penv = ctx.penv or env,
        source_dir = ctx.source_dir,
        source_parent_dir = ctx.source_parent_dir,
        source_dir_name = ctx.source_dir_name,
        file_dir = ctx.file_dir,
        preset_name = ctx.preset_name,
    }

    local function string_value(value)
        if type(value) == "string" then
            return expand(value, expand_ctx)
        end
        return value
    end

    local function as_bool(value)
        value = string_value(value)
        if type(value) == "boolean" then
            return value
        end
        if type(value) == "number" then
            return value ~= 0
        end
        if type(value) == "string" then
            return value ~= "" and value ~= "0" and value:lower() ~= "false"
        end
        return nil
    end

    local evaluate
    evaluate = function(node)
        if node == nil then
            return nil
        end
        if type(node) ~= "table" then
            return as_bool(node)
        end

        local op, arg = next(node)
        if op == "const" then
            return as_bool(arg)
        elseif op == "not" then
            local value = evaluate(arg)
            if value == nil then
                return nil
            end
            return not value
        elseif op == "and" or op == "or" then
            if type(arg) ~= "table" then
                return nil
            end
            local saw_unknown = false
            for _, item in ipairs(arg) do
                local value = evaluate(item)
                if op == "and" and value == false then
                    return false
                end
                if op == "or" and value == true then
                    return true
                end
                if value == nil then
                    saw_unknown = true
                end
            end
            if saw_unknown then
                return nil
            end
            return op == "and"
        elseif op == "equals" then
            if type(arg) ~= "table" or #arg ~= 2 then
                return nil
            end
            return tostring(string_value(arg[1])) == tostring(string_value(arg[2]))
        elseif op == "in" then
            if type(arg) ~= "table" or #arg ~= 2 or type(arg[2]) ~= "table" then
                return nil
            end
            local needle = tostring(string_value(arg[1]))
            for _, item in ipairs(arg[2]) do
                if tostring(string_value(item)) == needle then
                    return true
                end
            end
            return false
        elseif op == "matches" then
            if type(arg) ~= "table" or #arg ~= 2 then
                return nil
            end
            local value = tostring(string_value(arg[1]))
            local pattern = tostring(string_value(arg[2]))
            local ok, matched = pcall(string.match, value, pattern)
            return ok and matched ~= nil
        end

        return nil
    end

    return evaluate(condition)
end

--- Only the presets a user may select (hidden or false-condition presets are
--- excluded).
---@param presets OrchCMakePresets
---@param kind string
---@param ctx? table
---@return OrchCMakePreset[]
function M.visible(presets, kind, ctx)
    local out = {}
    for _, preset in ipairs(presets[kind] or {}) do
        if preset.hidden ~= true then
            local allowed = preset.condition == nil
            if not allowed then
                local preset_ctx = vim.tbl_extend("force", {}, ctx or {})
                preset_ctx.preset_name = preset.name
                preset_ctx.file_dir = preset._file_dir
                allowed = M.condition(preset.condition, preset_ctx) == true
            end
            if allowed then
                out[#out + 1] = preset
            end
        end
    end
    return out
end

---@param presets OrchCMakePresets
---@param kind string
---@param name string
---@return OrchCMakePreset?
function M.find(presets, kind, name)
    for _, preset in ipairs(presets[kind] or {}) do
        if preset.name == name then
            return preset
        end
    end
    return nil
end

-- ============================================================================
-- Inheritance resolution
-- ============================================================================

local DICT_FIELDS = { cacheVariables = true, environment = true }

--- Merges `child` over `parent`, deep-merging dict fields and dropping
--- `inherits` so resolved presets are self-contained.
---@param parent table
---@param child table
---@return table
local function merge(parent, child)
    local out = {}
    for key, value in pairs(parent) do
        out[key] = value
    end

    for key, value in pairs(child) do
        if key ~= "inherits" then
            if DICT_FIELDS[key] and type(value) == "table" and type(out[key]) == "table" then
                local merged = {}
                for item_key, item_value in pairs(out[key]) do
                    merged[item_key] = item_value
                end
                for item_key, item_value in pairs(value) do
                    merged[item_key] = item_value
                end
                out[key] = merged
            else
                out[key] = value
            end
        end
    end

    out.inherits = nil
    return out
end

---@param name string
---@param map table<string, table>
---@param cache table<string, table>
---@param stack table<string, boolean>
---@return table?
---@return string? error
local function resolve_one(name, map, cache, stack)
    if cache[name] then
        return cache[name]
    end

    local preset = map[name]
    if not preset then
        return nil
    end
    if stack[name] then
        return nil, ("preset inheritance cycle at %q"):format(name)
    end
    stack[name] = true

    local resolved = {}
    local inherits = preset.inherits
    if inherits == nil then
        inherits = {}
    elseif type(inherits) == "string" then
        inherits = { inherits }
    elseif type(inherits) ~= "table" or (not vim.islist(inherits) and next(inherits) ~= nil) then
        stack[name] = nil
        return nil, ("preset %q has an invalid `inherits` value"):format(name)
    end

    for _, parent in ipairs(inherits) do
        if type(parent) ~= "string" then
            stack[name] = nil
            return nil, ("preset %q has a non-string `inherits` entry"):format(name)
        end
        local parent_resolved, err = resolve_one(parent, map, cache, stack)
        if err then
            stack[name] = nil
            return nil, err
        end
        if parent_resolved then
            resolved = merge(resolved, parent_resolved)
        end
    end

    resolved = merge(resolved, preset)
    stack[name] = nil
    cache[name] = resolved

    return resolved
end

--- Resolves a preset with all of its `inherits` applied.
---@param presets OrchCMakePresets
---@param kind string
---@param name string
---@return table?
---@return string? error
function M.resolve(presets, kind, name)
    local map = {}
    for _, preset in ipairs(presets[kind] or {}) do
        if preset.name then
            map[preset.name] = preset
        end
    end

    if not map[name] then
        return nil
    end

    return resolve_one(name, map, {}, {})
end

-- ============================================================================
-- Toolchain injection
-- ============================================================================

--- True when a resolved configure preset already selects a compiler or a
--- toolchain file, in which case the project toolchain must not be forced.
---@param resolved table?
---@return boolean
function M.has_compilers(resolved)
    if not resolved then
        return false
    end

    if resolved.toolchainFile and resolved.toolchainFile ~= "" then
        return true
    end

    local cache = resolved.cacheVariables or {}
    return cache.CMAKE_C_COMPILER ~= nil
        or cache.CMAKE_CXX_COMPILER ~= nil
        or cache.CMAKE_TOOLCHAIN_FILE ~= nil
end

--- Builds the `-DCMAKE_*_COMPILER` arguments that apply `toolchain` to a
--- preset that does not define compilers of its own.
---@param resolved table?
---@param toolchain OrchToolchain?
---@param resolve_tool? fun(value: string): string
---@return string[]
function M.toolchain_args(resolved, toolchain, resolve_tool)
    if not toolchain or M.has_compilers(resolved) then
        return {}
    end

    local resolve = resolve_tool or function(value)
        return value
    end

    local args = {}
    if toolchain.c and toolchain.c ~= "" then
        args[#args + 1] = "-DCMAKE_C_COMPILER=" .. resolve(toolchain.c)
    end
    if toolchain.cxx and toolchain.cxx ~= "" then
        args[#args + 1] = "-DCMAKE_CXX_COMPILER=" .. resolve(toolchain.cxx)
    end

    return args
end

return M
