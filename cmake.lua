-- OrchLaunch — CMake command construction.
--
-- Turns the project CMake settings (and the selected CMake presets) into
-- process specs for configure, build, install and test, and resolves CMake
-- targets to executables. Programs and arguments are always kept separate.

local config = require("orchlaunch.config")
local presets = require("orchlaunch.presets")
local process = require("orchlaunch.process")
local state = require("orchlaunch.state")

local M = {}

--- File API query client directory name. Must be stable so the reply is
--- preserved between runs.
local FILE_API_CLIENT = "client-orchlaunch"

-- ============================================================================
-- Settings helpers
-- ============================================================================

---@return OrchCMakeSettings
local function settings()
    return state.cmake_settings() or {}
end

--- The toolchain to build with: the configured one, else the first defined.
---@return OrchToolchain?
function M.toolchain()
    local configured = settings().toolchain
    if configured and configured ~= "" then
        local toolchain = state.toolchain(configured)
        if toolchain then
            return toolchain
        end
    end

    return state.toolchains().toolchains[1]
end

---@return string
function M.cmake_program()
    local toolchain = M.toolchain()
    if toolchain and toolchain.cmake and toolchain.cmake ~= "" then
        return state.resolve_tool(toolchain.cmake) or "cmake"
    end
    return "cmake"
end

---@param kind string
---@return string?
function M.preset_name(kind)
    local name = settings()[kind .. "_preset"]
    if name == nil or name == "" then
        return nil
    end
    return name
end

---@param kind string
---@return table?
function M.resolved(kind)
    local discovered = state.presets()
    local name = M.preset_name(kind)
    if not discovered or not name then
        return nil
    end
    return presets.resolve(discovered, kind, name)
end

-- ============================================================================
-- Directories
-- ============================================================================

---@return string
function M.source_dir()
    return state.cmake_source_dir()
end

---@param preset table?
---@param name? string
---@return table
local function preset_context(preset, name)
    local source = M.source_dir()
    local env = vim.fn.environ()

    return {
        source_dir = source,
        source_parent_dir = vim.fs.dirname(source),
        source_dir_name = vim.fs.basename(source),
        file_dir = (preset and preset._file_dir) or source,
        preset_name = name,
        host_system_name = (vim.uv.os_uname().sysname),
        env = env,
        penv = env,
    }
end

--- The build directory: the configure preset's `binaryDir`, else the manual
--- `build_dir`, else `<source>/build`.
---@return string
function M.binary_dir()
    local name = M.preset_name("configure")
    local resolved = M.resolved("configure")

    if resolved and type(resolved.binaryDir) == "string" and resolved.binaryDir ~= "" then
        local expanded = presets.expand(resolved.binaryDir, preset_context(resolved, name))
        if type(expanded) == "string" then
            if not config.is_absolute(expanded) then
                expanded = vim.fs.joinpath(M.source_dir(), expanded)
            end
            return vim.fs.normalize(expanded)
        end
    end

    return state.resolve_path(settings().build_dir) or vim.fs.joinpath(M.source_dir(), "build")
end

---@return string?
function M.install_dir()
    return state.resolve_path(settings().install_dir)
end

-- ============================================================================
-- Spec helpers
-- ============================================================================

---@param argv string[]
---@param cwd string
---@param env? OrchEnvironment
---@return OrchProcessSpec
local function spec_from(argv, cwd, env)
    local args = {}
    for index = 2, #argv do
        args[#args + 1] = argv[index]
    end

    return {
        program = argv[1],
        args = args,
        cwd = cwd,
        env = env,
        inherit_env = true,
        sudo = false,
    }
end

--- @param resolved table?
--- @return OrchEnvironment
local function preset_environment(resolved)
    local out = {}
    for key, value in pairs(settings().environment or {}) do
        out[key] = tostring(value)
    end

    if resolved and type(resolved.environment) == "table" then
        local ctx = preset_context(resolved, M.preset_name("configure"))
        for key, value in pairs(resolved.environment) do
            out[key] = presets.expand(tostring(value), ctx)
        end
    end

    return state.resolve_environment(out)
end

--- @param defined table<string, string>
--- @return string[]
local function definition_args(defined)
    local keys = {}
    for key in pairs(defined or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    local args = {}
    for _, key in ipairs(keys) do
        args[#args + 1] = "-D" .. key .. "=" .. tostring(defined[key])
    end
    return args
end

-- ============================================================================
-- Configure
-- ============================================================================

---@return OrchProcessSpec
function M.configure_spec()
    local opts = settings()
    local name = M.preset_name("configure")
    local resolved = M.resolved("configure")
    local argv = { M.cmake_program() }

    if name and resolved then
        argv[#argv + 1] = "--preset"
        argv[#argv + 1] = name
        for _, arg in ipairs(presets.toolchain_args(resolved, M.toolchain(), state.resolve_tool)) do
            argv[#argv + 1] = arg
        end
    else
        argv[#argv + 1] = "-S"
        argv[#argv + 1] = M.source_dir()
        argv[#argv + 1] = "-B"
        argv[#argv + 1] = M.binary_dir()

        local toolchain = M.toolchain()
        if toolchain then
            if toolchain.c and toolchain.c ~= "" then
                argv[#argv + 1] = "-DCMAKE_C_COMPILER=" .. (state.resolve_tool(toolchain.c) or toolchain.c)
            end
            if toolchain.cxx and toolchain.cxx ~= "" then
                argv[#argv + 1] = "-DCMAKE_CXX_COMPILER=" .. (state.resolve_tool(toolchain.cxx) or toolchain.cxx)
            end
        end
        if opts.generator and opts.generator ~= "" then
            argv[#argv + 1] = "-G"
            argv[#argv + 1] = opts.generator
        end
        if opts.build_type and opts.build_type ~= "" then
            argv[#argv + 1] = "-DCMAKE_BUILD_TYPE=" .. opts.build_type
        end
        for _, arg in ipairs(definition_args(opts.definitions)) do
            argv[#argv + 1] = arg
        end
    end

    for _, arg in ipairs(state.resolve_list(opts.configure_args)) do
        argv[#argv + 1] = arg
    end

    return spec_from(argv, M.source_dir(), preset_environment(resolved))
end

-- ============================================================================
-- Build
-- ============================================================================

---@param target? string
---@return OrchProcessSpec
function M.build_spec(target)
    local opts = settings()
    local name = M.preset_name("build")
    local argv = { M.cmake_program() }

    if name then
        argv[#argv + 1] = "--build"
        argv[#argv + 1] = "--preset"
        argv[#argv + 1] = name
    else
        argv[#argv + 1] = "--build"
        argv[#argv + 1] = M.binary_dir()
        if opts.build_type and opts.build_type ~= "" then
            argv[#argv + 1] = "--config"
            argv[#argv + 1] = opts.build_type
        end
    end

    if target and target ~= "" then
        argv[#argv + 1] = "--target"
        argv[#argv + 1] = target
    end

    for _, arg in ipairs(state.resolve_list(opts.build_args)) do
        argv[#argv + 1] = arg
    end

    return spec_from(argv, M.source_dir(), preset_environment(M.resolved("configure")))
end

-- ============================================================================
-- Install
-- ============================================================================

---@return OrchProcessSpec
function M.install_spec()
    local opts = settings()
    local argv = { M.cmake_program(), "--install", M.binary_dir() }

    if opts.build_type and opts.build_type ~= "" then
        argv[#argv + 1] = "--config"
        argv[#argv + 1] = opts.build_type
    end

    local install_dir = M.install_dir()
    if install_dir then
        argv[#argv + 1] = "--prefix"
        argv[#argv + 1] = install_dir
    end

    for _, arg in ipairs(state.resolve_list(opts.install_args)) do
        argv[#argv + 1] = arg
    end

    return spec_from(argv, M.source_dir(), preset_environment(M.resolved("configure")))
end

-- ============================================================================
-- Test
-- ============================================================================

---@return OrchProcessSpec
function M.test_spec()
    local opts = settings()
    local name = M.preset_name("test")
    local argv

    if name then
        argv = { "ctest", "--preset", name }
    else
        argv = { "ctest", "--test-dir", M.binary_dir() }
        if opts.build_type and opts.build_type ~= "" then
            argv[#argv + 1] = "-C"
            argv[#argv + 1] = opts.build_type
        end
    end

    return spec_from(argv, M.binary_dir(), preset_environment(M.resolved("test")))
end

-- ============================================================================
-- File API — target discovery
-- ============================================================================

---@param path string
---@return table?
local function read_json_file(path)
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

---@param pattern string
---@return string?
local function newest_file(pattern)
    local files = vim.fn.glob(pattern, false, true)
    local best, best_time = nil, -1

    for _, file in ipairs(files) do
        local time = vim.fn.getftime(file)
        if time > best_time then
            best, best_time = file, time
        end
    end

    return best
end

--- Requests a codemodel reply from the File API on the next configure.
---@param binary_dir string
function M.prepare_file_api(binary_dir)
    local query_dir = vim.fs.joinpath(binary_dir, ".cmake", "api", "v1", "query", FILE_API_CLIENT)
    vim.fn.mkdir(query_dir, "p")

    local query = vim.fs.joinpath(query_dir, "codemodel-v2")
    if vim.fn.filereadable(query) == 0 then
        vim.fn.writefile({}, query)
    end
end

--- Normalizes a File API `artifacts` entry: newer codemodel versions use
--- `{ path = "..." }` objects, older ones plain strings. Relative paths are
--- resolved against the build directory.
---@param artifacts any
---@return string?
local function artifact_path(artifacts)
    if type(artifacts) ~= "table" then
        return nil
    end

    local first = artifacts[1]
    local path
    if type(first) == "string" then
        path = first
    elseif type(first) == "table" and type(first.path) == "string" then
        path = first.path
    end

    if not path then
        return nil
    end

    if not config.is_absolute(path) then
        path = vim.fs.joinpath(M.binary_dir(), path)
    end

    return vim.fs.normalize(path)
end

--- Locates the codemodel reference inside a File API index reply. Client
--- queries nest their objects under the client name, so look there too.
---@param index table?
---@return table?
local function find_codemodel_ref(index)
    local reply = index and index.reply
    if type(reply) ~= "table" then
        return nil
    end

    if type(reply["codemodel-v2"]) == "table" then
        return reply["codemodel-v2"]
    end

    for _, value in pairs(reply) do
        if type(value) == "table" and type(value["codemodel-v2"]) == "table" then
            return value["codemodel-v2"]
        end
    end

    return nil
end

--- Reads targets from the last File API codemodel reply.
---
--- Returns nil when no reply is available (the project was never configured
--- through this plugin).
---@return OrchCMakeTarget[]?
function M.read_targets()
    local reply_dir = vim.fs.joinpath(M.binary_dir(), ".cmake", "api", "v1", "reply")
    if vim.fn.isdirectory(reply_dir) == 0 then
        return nil
    end

    local index_path = newest_file(vim.fs.joinpath(reply_dir, "index-*.json"))
    if not index_path then
        return nil
    end

    local index = read_json_file(index_path)
    local codemodel_ref = find_codemodel_ref(index)
    if type(codemodel_ref) ~= "table" or type(codemodel_ref.jsonFile) ~= "string" then
        return nil
    end

    local codemodel = read_json_file(vim.fs.joinpath(reply_dir, codemodel_ref.jsonFile))
    if not codemodel or type(codemodel.configurations) ~= "table" then
        return nil
    end

    local targets, seen = {}, {}
    for _, configuration in ipairs(codemodel.configurations) do
        for _, reference in ipairs(configuration.targets or {}) do
            local name = reference.name
            if type(name) == "string" and not seen[name] then
                seen[name] = true

                local kind = reference.type
                local artifact
                if type(reference.jsonFile) == "string" then
                    local target = read_json_file(vim.fs.joinpath(reply_dir, reference.jsonFile))
                    if target then
                        kind = kind or target.type
                        artifact = artifact_path(target.artifacts)
                    end
                end

                targets[#targets + 1] = { name = name, type = kind, artifact = artifact }
            end
        end
    end

    table.sort(targets, function(a, b)
        return a.name < b.name
    end)

    return targets
end

--- Configures the project and discovers its targets through the File API.
---
--- The discovered targets are cached in runtime data and returned. On a failed
--- configure the process result is returned as the second value.
---@return OrchCMakeTarget[]?
---@return OrchProcessResult?
function M.load_targets()
    local binary_dir = M.binary_dir()
    M.prepare_file_api(binary_dir)

    local result = process.run(M.configure_spec())
    if result.code ~= 0 then
        -- Fall back to the last File API reply, if any, so targets remain
        -- available when a reconfigure fails (e.g. a missing toolchain).
        local cached = M.read_targets()
        if cached and #cached > 0 then
            state.set_runtime("cmake_targets", cached)
            state.set_runtime("cmake_source_dir", M.source_dir())
            state.set_runtime("cmake_binary_dir", binary_dir)
            return cached, result
        end

        return nil, result
    end

    local targets = M.read_targets() or {}
    state.set_runtime("cmake_targets", targets)
    state.set_runtime("cmake_source_dir", M.source_dir())
    state.set_runtime("cmake_binary_dir", binary_dir)

    return targets
end

--- CMake targets for the current project.
---
--- Prefers the runtime cache populated by `load_targets`, but falls back to the
--- last File API reply already present in the build directory, so targets are
--- available in a fresh session (or after a reload) without reconfiguring.
---@return OrchCMakeTarget[]?
function M.targets()
    local source_dir = M.source_dir()
    local cached = state.get_runtime("cmake_targets")
    if type(cached) == "table" and state.get_runtime("cmake_source_dir") == source_dir then
        return cached
    end

    local discovered = M.read_targets()
    if discovered and #discovered > 0 then
        state.set_runtime("cmake_targets", discovered)
        state.set_runtime("cmake_source_dir", source_dir)
        state.set_runtime("cmake_binary_dir", M.binary_dir())
        return discovered
    end

    return nil
end

---@param name string
---@return OrchCMakeTarget?
function M.target(name)
    for _, target in ipairs(M.targets() or {}) do
        if target.name == name then
            return target
        end
    end
    return nil
end

-- ============================================================================
-- Target resolution
-- ============================================================================

--- Finds a built executable for `target`: first the artifact reported by the
--- File API, then a filesystem search inside the build directory.
---@param target? string
---@return string?
function M.find_target(target)
    if not target or target == "" then
        return nil
    end

    local known = M.target(target)
    if known and type(known.artifact) == "string" and vim.fn.filereadable(known.artifact) == 1 then
        return known.artifact
    end

    local dir = M.binary_dir()
    if vim.fn.isdirectory(dir) == 0 then
        return nil
    end

    local candidates = { target, target .. ".exe", "lib" .. target .. ".so", "lib" .. target .. ".a" }
    for _, candidate in ipairs(candidates) do
        local found = vim.fs.find(function(name)
            return name == candidate
        end, { path = dir, type = "file", limit = 1 })

        if found[1] then
            return found[1]
        end
    end

    return nil
end

return M
