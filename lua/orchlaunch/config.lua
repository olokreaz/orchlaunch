-- OrchLaunch — JSON I/O, serialization and object factories.
--
-- This module owns everything related to turning Lua data into JSON and back,
-- plus the canonical factories used to build configuration objects. It is
-- deliberately free of any UI or process logic.

local M = {}

-- ============================================================================
-- JSON backend
-- ============================================================================

-- Serialization is built on Neovim's built-in `vim.json`: `load` decodes files
-- and `stringify` produces deterministic, pretty-printed JSON. No external
-- parser is required.

-- ============================================================================
-- Serialization helpers
-- ============================================================================

--- Lua reserved words that cannot be used as bare keys in a Lua literal.
local KEYWORDS = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
    ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
    ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
    ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
    ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
    ["until"] = true, ["while"] = true,
}

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

--- Encodes a value as pretty-printed JSON with sorted object keys.
---
--- Object keys are sorted so output is deterministic and diffs stay small;
--- array order is preserved. Empty tables encode as `{}` and decode back to an
--- empty table, which is valid for both arrays and maps in Lua. Scalar escaping
--- is delegated to `vim.json.encode`.
---@param value any
---@param indent string
---@return string
local function encode_json(value, indent)
    if type(value) ~= "table" then
        return vim.json.encode(value)
    end

    if next(value) == nil then
        return "{}"
    end

    local inner = indent .. "  "

    if is_array(value) then
        local items = {}
        for _, item in ipairs(value) do
            items[#items + 1] = inner .. encode_json(item, inner)
        end
        return "[\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "]"
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
        fields[#fields + 1] = inner .. vim.json.encode(tostring(key)) .. ": " .. encode_json(value[key], inner)
    end
    return "{\n" .. table.concat(fields, ",\n") .. "\n" .. indent .. "}"
end

-- ============================================================================
-- Public JSON API
-- ============================================================================

--- Parses a JSON file. Missing (or blank) files yield an empty table.
---@param path string
---@return table
function M.load(path)
    if vim.fn.filereadable(path) == 0 then
        return {}
    end

    local file = assert(io.open(path, "r"), ("[orchlaunch] cannot open %s"):format(path))
    local content = file:read("*a")
    file:close()

    if content:match("^%s*$") then
        return {}
    end

    local ok, data = pcall(vim.json.decode, content)
    assert(ok, ("[orchlaunch] failed to parse %s: %s"):format(path, tostring(data)))

    if type(data) ~= "table" then
        return {}
    end

    return data
end

--- Serializes a Lua table into pretty-printed JSON.
---@param data table
---@return string
function M.stringify(data)
    return encode_json(data, "") .. "\n"
end

--- Writes a Lua table to a JSON file.
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
---@field runtime? string
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
        runtime = opts.runtime,
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
---@field environment? OrchEnvironment

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
        environment = opts.environment,
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
