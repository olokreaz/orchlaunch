-- OrchLaunch — TOML I/O, serialization and object factories.
--
-- This module owns everything related to turning Lua data into TOML and back,
-- plus the canonical factories used to build configuration objects. It is
-- deliberately free of any UI or process logic.

local M = {}

-- ============================================================================
-- TOML backend
-- ============================================================================

--- Returns the available TOML module, or nil when none is installed.
---@return table?
local function toml()
    local ok, module = pcall(require, "toml")
    if not ok or type(module) ~= "table" then
        return nil
    end
    return module
end

--- Requires a TOML parser, raising a helpful error when unavailable.
---@return table
local function require_toml()
    local module = toml()
    assert(module, "[orchlaunch] TOML support requires a `toml` module (wsdjeg/toml.nvim or lua-toml)")
    return module
end

-- ============================================================================
-- Serialization helpers
-- ============================================================================

local BARE_KEY = "^[%w_%-]+$"

--- Lua reserved words that cannot be used as bare keys.
local KEYWORDS = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
    ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
    ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
    ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
    ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
    ["until"] = true, ["while"] = true,
}

--- @param key string
--- @return string
local function encode_key(key)
    if key:match(BARE_KEY) then
        return key
    end
    return '"' .. key:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

--- @param value string
--- @return string
local function encode_string(value)
    local out = value
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\b", "\\b")
        :gsub("\f", "\\f")
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")

    return '"' .. out .. '"'
end

--- True when `value` is a sequence (array) with no holes.
---@param value table
---@return boolean
local function is_array(value)
    if type(value) ~= "table" then
        return false
    end

    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" then
            return false
        end
        count = count + 1
    end

    if count == 0 then
        return false
    end

    for index = 1, count do
        if value[index] == nil then
            return false
        end
    end

    return true
end

--- True when `value` is a non-empty array whose items are all tables.
---@param value table
---@return boolean
local function is_array_of_tables(value)
    if not is_array(value) then
        return false
    end

    for _, item in ipairs(value) do
        if type(item) ~= "table" or is_array(item) then
            return false
        end
    end

    return true
end

--- Encodes a scalar or inline TOML value.
---@param value any
---@return string
local function encode_value(value)
    local kind = type(value)

    if kind == "string" then
        return encode_string(value)
    end

    if kind == "number" or kind == "boolean" then
        return tostring(value)
    end

    if kind == "table" then
        if is_array(value) then
            local items = {}
            for _, item in ipairs(value) do
                items[#items + 1] = encode_value(item)
            end
            return "[" .. table.concat(items, ", ") .. "]"
        end

        local keys = {}
        for key in pairs(value) do
            keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)

        local fields = {}
        for _, key in ipairs(keys) do
            local child = value[key]
            -- Empty tables carry no information (as in emit_table); skip them so
            -- inline values stay readable.
            if type(child) ~= "table" or next(child) ~= nil then
                fields[#fields + 1] = encode_key(key) .. " = " .. encode_value(child)
            end
        end
        return "{" .. table.concat(fields, ", ") .. "}"
    end

    error(("[orchlaunch] cannot encode TOML value of type %s"):format(kind))
end

--- Emits a table's body into `lines`.
---@param lines string[]
---@param value table
---@param path string Dotted path of the current table ("" at root).
local function emit_table(lines, value, path)
    local scalars, subtables, table_arrays = {}, {}, {}
    local keys = {}

    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)

    for _, key in ipairs(keys) do
        local child = value[key]
        if type(child) == "table" and next(child) == nil then
            -- Empty tables/arrays carry no information and cannot be
            -- represented unambiguously in TOML; omit them.
        elseif type(child) == "table" and not is_array(child) then
            subtables[#subtables + 1] = key
        elseif is_array_of_tables(child) then
            table_arrays[#table_arrays + 1] = key
        else
            scalars[#scalars + 1] = key
        end
    end

    local function prefix(key)
        if path == "" then
            return encode_key(key)
        end
        return path .. "." .. encode_key(key)
    end

    for _, key in ipairs(scalars) do
        lines[#lines + 1] = encode_key(key) .. " = " .. encode_value(value[key])
    end

    for _, key in ipairs(subtables) do
        local child_path = prefix(key)
        lines[#lines + 1] = ""
        lines[#lines + 1] = "[" .. child_path .. "]"
        emit_table(lines, value[key], child_path)
    end

    for _, key in ipairs(table_arrays) do
        -- Nested arrays-of-tables are emitted inline. Emitting them as
        -- `[[path]]` sections breaks parsers (notably toml.nvim, and some
        -- others) when a sibling sub-table follows.
        if path ~= "" then
            lines[#lines + 1] = encode_key(key) .. " = " .. encode_value(value[key])
        else
            local child_path = prefix(key)
            for _, item in ipairs(value[key]) do
                lines[#lines + 1] = ""
                lines[#lines + 1] = "[[" .. child_path .. "]]"
                emit_table(lines, item, child_path)
            end
        end
    end
end

--- Encodes a Lua table into TOML using the internal encoder.
---@param data table
---@return string
local function encode(data)
    local lines = {}
    emit_table(lines, data, "")

    -- Trim leading blank lines produced by section headers.
    while lines[1] == "" do
        table.remove(lines, 1)
    end

    return table.concat(lines, "\n") .. "\n"
end

-- ============================================================================
-- Runtime marker
-- ============================================================================

--- Recursively prepares a value for serialization.
---
--- Tables marked with `_runtime = true` are dropped completely. The `_runtime`
--- key itself is never emitted. The original value is not modified.
---@param value any
---@return any
local function prepare(value)
    if type(value) ~= "table" then
        return value
    end

    if value._runtime == true then
        return nil
    end

    local result = {}
    for key, child in pairs(value) do
        if key ~= "_runtime" then
            local prepared = prepare(child)
            if prepared ~= nil then
                result[key] = prepared
            end
        end
    end

    return result
end

-- ============================================================================
-- Public TOML API
-- ============================================================================

--- Parses a TOML file. Missing files yield an empty table.
---@param path string
---@return table
function M.load(path)
    if vim.fn.filereadable(path) == 0 then
        return {}
    end

    local module = require_toml()

    local ok, data
    if type(module.parse_file) == "function" then
        ok, data = pcall(module.parse_file, path)
    else
        local file = assert(io.open(path, "r"), ("[orchlaunch] cannot open %s"):format(path))
        local content = file:read("*a")
        file:close()
        ok, data = pcall(module.parse, content)
    end

    assert(ok, ("[orchlaunch] failed to parse %s: %s"):format(path, tostring(data)))

    return data or {}
end

--- Recursively removes runtime data from `data` (does not mutate it).
---@param data table
---@return table
function M.prepare(data)
    return prepare(data) or {}
end

--- Serializes a Lua table into TOML, honoring `_runtime` markers.
---@param data table
---@return string
function M.stringify(data)
    local prepared = prepare(data) or {}

    local module = toml()
    if module then
        if type(module.stringify) == "function" then
            return module.stringify(prepared)
        end
        if type(module.encode) == "function" then
            return module.encode(prepared)
        end
    end

    return encode(prepared)
end

--- Writes a Lua table to a TOML file.
---@param path string
---@param data table
---@return boolean
function M.save(path, data)
    local parent = vim.fs.dirname(path)
    if parent and parent ~= "" and vim.fn.isdirectory(parent) == 0 then
        vim.fn.mkdir(parent, "p")
    end

    local file = assert(io.open(path, "w"), ("[orchlaunch] cannot write %s"):format(path))
    file:write(M.stringify(data))
    file:close()

    return true
end

-- ============================================================================
-- Lua literal serialization (scratch-buffer editor)
-- ============================================================================

local LUA_KEY = "^[%a_][%w_]*$"

--- @param key any
--- @return string
local function lua_key(key)
    if type(key) == "string" and key:match(LUA_KEY) and not KEYWORDS[key] then
        return key
    end
    return "[" .. encode_string(tostring(key)) .. "]"
end

--- Pretty-prints a value as a Lua literal, one field per line.
--- @param value any
--- @param indent string
--- @return string
local function lua_value(value, indent)
    local kind = type(value)

    if kind == "string" then
        return encode_string(value)
    end
    if kind == "number" or kind == "boolean" then
        return tostring(value)
    end
    if kind == "nil" then
        return "nil"
    end

    if kind ~= "table" then
        error(("[orchlaunch] cannot serialize %s as Lua"):format(kind))
    end

    if next(value) == nil then
        return "{}"
    end

    local inner = indent .. "  "
    local items = {}

    if is_array(value) then
        for _, item in ipairs(value) do
            items[#items + 1] = inner .. lua_value(item, inner) .. ","
        end
    else
        local keys = {}
        for key in pairs(value) do
            keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)

        for _, key in ipairs(keys) do
            items[#items + 1] = inner .. lua_key(key) .. " = " .. lua_value(value[key], inner) .. ","
        end
    end

    return "{\n" .. table.concat(items, "\n") .. "\n" .. indent .. "}"
end

--- Serializes a table as a Lua expression (without `return`).
---@param value any
---@return string
function M.to_lua(value)
    return lua_value(value, "")
end

--- Parses a Lua literal (optionally prefixed with `return`).
---@param text string
---@return table
function M.from_lua(text)
    local loader = loadstring or load
    local chunk, err = loader(text, "orchlaunch-profile")
    assert(chunk, ("[orchlaunch] invalid Lua: %s"):format(err or "parse error"))

    local ok, value = pcall(chunk)
    assert(ok, ("[orchlaunch] invalid Lua: %s"):format(value))
    assert(type(value) == "table", "[orchlaunch] profile must be a Lua table")

    return value
end

-- ============================================================================
-- Variable / path resolution
-- ============================================================================

--- Context required to resolve project variables.
---@class OrchResolveContext
---@field workspace string
---@field orch_dir string

--- Expands `${workspace}` and `${orch}` references in a string.
---@param value string
---@param ctx OrchResolveContext
---@return string
function M.expand(value, ctx)
    return (value:gsub("%${([%w_]+)}", function(name)
        if name == "workspace" then
            return ctx.workspace or ""
        end
        if name == "orch" then
            return ctx.orch_dir or ""
        end
        return "${" .. name .. "}"
    end))
end

---@param value string
---@return boolean
function M.is_absolute(value)
    return value:sub(1, 1) == "/" or value:match("^%a:[/\\]") ~= nil
end

--- Resolves a filesystem path: expands variables and makes it absolute.
---
--- Relative paths are resolved against the `.orch` directory.
---@param value? string
---@param ctx OrchResolveContext
---@return string?
function M.resolve_path(value, ctx)
    if value == nil or value == "" then
        return value
    end

    local expanded = M.expand(value, ctx)
    if not M.is_absolute(expanded) then
        expanded = vim.fs.joinpath(ctx.orch_dir, expanded)
    end

    return vim.fs.normalize(expanded)
end

--- Resolves a tool path. Bare command names are kept as-is so the OS can
--- resolve them from `PATH`; paths with a separator are resolved against `.orch`.
---@param value? string
---@param ctx OrchResolveContext
---@return string?
function M.resolve_tool(value, ctx)
    if value == nil or value == "" then
        return value
    end

    local expanded = M.expand(value, ctx)
    if M.is_absolute(expanded) then
        return vim.fs.normalize(expanded)
    end

    if expanded:find("[/\\]") then
        return vim.fs.normalize(vim.fs.joinpath(ctx.orch_dir, expanded))
    end

    return expanded
end

--- Resolves every string in a list.
---@param value? string[]
---@param ctx OrchResolveContext
---@return string[]
function M.resolve_list(value, ctx)
    local out = {}
    for _, item in ipairs(value or {}) do
        out[#out + 1] = M.expand(item, ctx)
    end
    return out
end

--- Expands environment variable values.
---@param value? OrchEnvironment
---@param ctx OrchResolveContext
---@return OrchEnvironment
function M.resolve_environment(value, ctx)
    local out = {}
    for key, item in pairs(value or {}) do
        out[key] = M.expand(tostring(item), ctx)
    end
    return out
end

-- ============================================================================
-- Runtime factories
-- ============================================================================

--- Wraps `data` in a table excluded from serialization.
---@param data table
---@return OrchRuntime
function M.runtime(data)
    assert(type(data) == "table", "runtime data must be a table")

    local result = { _runtime = true }
    for key, value in pairs(data) do
        result[key] = value
    end

    return result
end

--- Runtime CMake target descriptor.
---@param name string
---@param executable? string
---@return OrchRuntime
function M.runtime_target(name, executable)
    return M.runtime({ cmake_target = name, executable = executable })
end

-- ============================================================================
-- Factories — console / before-launch
-- ============================================================================

---@class OrchConsoleOptions
---@field mode? "embedded" | "hidden" | "none"
---@field keep_open? boolean
---@field clear_on_start? boolean

---@param opts? OrchConsoleOptions
---@return OrchConsole
function M.console(opts)
    opts = opts or {}

    return {
        mode = opts.mode or "embedded",
        keep_open = opts.keep_open ~= false,
        clear_on_start = opts.clear_on_start ~= false,
    }
end

---@param target? string
---@return OrchBeforeTool
function M.build(target)
    if target == nil then
        return "build"
    end
    return { type = "build", target = target }
end

---@param target? string
---@return OrchBeforeTool
function M.install(target)
    if target == nil then
        return "install"
    end
    return { type = "install", target = target }
end

---@param name string
---@return OrchBeforeToolSpec
function M.external(name)
    return { type = "external", tool = name }
end

---@param tools? OrchBeforeTool[]
---@return OrchBefore
function M.before(tools)
    return { tools = tools or {} }
end

-- ============================================================================
-- Factories — run configurations
-- ============================================================================

---@class OrchNativeOptions
---@field name string
---@field target? string
---@field cwd? string
---@field args? string[]
---@field inherit_env? boolean
---@field sudo? boolean
---@field environment? OrchEnvironment
---@field console? OrchConsole
---@field before? OrchBefore

---@param opts OrchNativeOptions
---@return OrchNativeConfiguration
function M.native(opts)
    assert(opts.name and opts.name ~= "", "native configuration requires `name`")

    return {
        name = opts.name,
        type = "native",
        target = opts.target,
        cwd = opts.cwd,
        args = opts.args,
        inherit_env = opts.inherit_env ~= false,
        sudo = opts.sudo == true,
        environment = opts.environment,
        console = opts.console,
        before = opts.before,
    }
end

---@class OrchRemoteDebugOptions
---@field name string
---@field symbol? string
---@field connection string
---@field adapter? string
---@field before? OrchBefore

---@param opts OrchRemoteDebugOptions
---@return OrchRemoteDebugConfiguration
function M.remote_debug(opts)
    assert(opts.name and opts.name ~= "", "remote-debug configuration requires `name`")
    assert(opts.connection and opts.connection ~= "", "remote-debug configuration requires `connection`")

    return {
        name = opts.name,
        type = "remote-debug",
        symbol = opts.symbol,
        connection = opts.connection,
        adapter = opts.adapter,
        before = opts.before,
    }
end

---@class OrchCompoundOptions
---@field name string
---@field configurations string[]

---@param opts OrchCompoundOptions
---@return OrchCompoundConfiguration
function M.compound(opts)
    assert(opts.name and opts.name ~= "", "compound configuration requires `name`")
    assert(opts.configurations and #opts.configurations > 0, "compound configuration requires `configurations`")

    return {
        name = opts.name,
        type = "compound",
        configurations = opts.configurations,
    }
end

-- ============================================================================
-- Factories — external tools
-- ============================================================================

---@class OrchExternalToolOptions
---@field name string
---@field program string
---@field cwd? string
---@field args? string[]
---@field inherit_env? boolean
---@field sudo? boolean
---@field environment? OrchEnvironment

---@param opts OrchExternalToolOptions
---@return OrchExternalTool
function M.external_tool(opts)
    assert(opts.name and opts.name ~= "", "external tool requires `name`")
    assert(opts.program and opts.program ~= "", "external tool requires `program`")

    return {
        name = opts.name,
        program = opts.program,
        cwd = opts.cwd,
        args = opts.args,
        inherit_env = opts.inherit_env ~= false,
        sudo = opts.sudo == true,
        environment = opts.environment,
    }
end

-- ============================================================================
-- Factories — toolchains
-- ============================================================================

---@class OrchToolchainOptions
---@field name string
---@field type "system" | "unix" | "msvc"
---@field cmake string
---@field c string
---@field cxx string
---@field debugger string

---@param opts OrchToolchainOptions
---@return OrchToolchain
function M.toolchain(opts)
    assert(opts.name and opts.name ~= "", "toolchain requires `name`")
    assert(opts.type and opts.type ~= "", "toolchain requires `type`")
    assert(opts.cmake and opts.cmake ~= "", "toolchain requires `cmake`")
    assert(opts.c and opts.c ~= "", "toolchain requires `c`")
    assert(opts.cxx and opts.cxx ~= "", "toolchain requires `cxx`")
    assert(opts.debugger and opts.debugger ~= "", "toolchain requires `debugger`")

    return {
        name = opts.name,
        type = opts.type,
        cmake = opts.cmake,
        c = opts.c,
        cxx = opts.cxx,
        debugger = opts.debugger,
    }
end

-- ============================================================================
-- Factories — CMake settings
-- ============================================================================

---@class OrchCMakeSettingsOptions
---@field name? string
---@field toolchain? string
---@field configure_preset? string
---@field build_preset? string
---@field test_preset? string
---@field package_preset? string
---@field workflow_preset? string
---@field generator? string
---@field build_type? string
---@field build_dir? string
---@field install_dir? string
---@field configure_args? string[]
---@field build_args? string[]
---@field install_args? string[]
---@field definitions? table<string, string>
---@field environment? OrchEnvironment

---@param opts? OrchCMakeSettingsOptions
---@return OrchCMakeSettings
function M.cmake_settings(opts)
    opts = opts or {}

    return {
        name = opts.name,
        toolchain = opts.toolchain,
        configure_preset = opts.configure_preset,
        build_preset = opts.build_preset,
        test_preset = opts.test_preset,
        package_preset = opts.package_preset,
        workflow_preset = opts.workflow_preset,
        generator = opts.generator,
        build_type = opts.build_type,
        build_dir = opts.build_dir,
        install_dir = opts.install_dir,
        configure_args = opts.configure_args or {},
        build_args = opts.build_args or {},
        install_args = opts.install_args or {},
        definitions = opts.definitions or {},
        environment = opts.environment or {},
    }
end

-- ============================================================================
-- Factories — root documents
-- ============================================================================

---@return OrchRunConfigurations
function M.run_configurations()
    return { configurations = {} }
end

---@return OrchExternalToolsConfig
function M.external_tools_config()
    return { tools = {} }
end

---@return OrchToolchainConfig
function M.toolchain_config()
    return { toolchains = {} }
end

---@param opts? { active?: string, source_dir?: string, profiles?: OrchCMakeProfile[] }
---@return OrchCMakeConfig
function M.cmake_config(opts)
    opts = opts or {}
    return { active = opts.active, source_dir = opts.source_dir, profiles = opts.profiles or {} }
end

return M
