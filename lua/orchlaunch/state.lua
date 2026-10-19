-- OrchLaunch — single loaded project state and the unified access API.
--
-- Every other module reads and mutates configurations through this module;
-- none of them parse JSON directly.

local config = require("orchlaunch.config")
local project = require("orchlaunch.project")

local M = {}

---@type OrchState?
local state = nil

---@param orch_dir string
---@return OrchPaths
local function build_paths(orch_dir)
    return {
        run_configurations = vim.fs.joinpath(orch_dir, "run_configurations.json"),
        external_tools = vim.fs.joinpath(orch_dir, "external_tools.json"),
        toolchain = vim.fs.joinpath(orch_dir, "toolchain.json"),
        cmake_settings = vim.fs.joinpath(orch_dir, "cmake_settings.json"),
        breakpoints = vim.fs.joinpath(orch_dir, "breakpoints.json"),
    }
end

---@param path string
---@return OrchRunConfigurations
local function load_run_configurations(path)
    local raw = config.load(path)
    local list = raw.configurations or raw.configuration or {}
    return { configurations = type(list) == "table" and list or {} }
end

---@param path string
---@return OrchExternalToolsConfig
local function load_external_tools(path)
    local raw = config.load(path)
    local list = raw.tools or raw.tool or {}
    return { tools = type(list) == "table" and list or {} }
end

---@param path string
---@return OrchToolchainConfig
local function load_toolchains(path)
    local raw = config.load(path)
    local list = raw.toolchains or raw.toolchain or {}
    return { toolchains = type(list) == "table" and list or {} }
end

---@param path string
---@return OrchCMakeConfig
local function load_cmake_settings(path)
    local raw = config.load(path)
    local doc = raw.cmake or raw.settings or raw
    if type(doc) ~= "table" then
        return { profiles = {} }
    end

    -- New format: a document holding `active`, `source_dir` and `profiles`.
    if type(doc.profiles) == "table" then
        return { active = doc.active, source_dir = doc.source_dir, profiles = doc.profiles }
    end

    -- Legacy single `[cmake]` table: wrap it into a single profile. A legacy
    -- `source_dir` becomes the project-wide CMake project directory.
    local legacy = false
    for key in pairs(doc) do
        if key ~= "active" and key ~= "profiles" and key ~= "source_dir" then
            legacy = true
            break
        end
    end

    if legacy then
        local settings = config.cmake_settings(doc)
        settings.name = doc.name or "Default"
        return { active = settings.name, source_dir = doc.source_dir, profiles = { settings } }
    end

    return { source_dir = doc.source_dir, profiles = {} }
end

--- @param path string
--- @return table[]
local function load_breakpoints(path)
    local raw = config.load(path)
    local list = raw.breakpoints or {}
    return type(list) == "table" and list or {}
end

---@param list table[]
---@param name string
---@return table?
local function find_by_name(list, name)
    for _, item in ipairs(list or {}) do
        if item.name == name then
            return item
        end
    end
    return nil
end

---@param container table
---@param field string
---@param item table
---@return table
local function add_named(container, field, item)
    assert(type(item) == "table" and type(item.name) == "string" and item.name ~= "", "[orchlaunch] item requires `name`")
    assert(not find_by_name(container[field], item.name), ("[orchlaunch] %s already exists: %s"):format(field, item.name))

    container[field][#container[field] + 1] = item
    return item
end

---@param container table
---@param field string
---@param name string
---@param item table
---@return table
local function update_named(container, field, name, item)
    local list = container[field]
    for index, current in ipairs(list) do
        if current.name == name then
            list[index] = item
            return item
        end
    end
    error(("[orchlaunch] cannot update missing %s: %s"):format(field, name))
end

---@param container table
---@param field string
---@param name string
---@return boolean
local function remove_named(container, field, name)
    local list = container[field]
    for index, current in ipairs(list) do
        if current.name == name then
            table.remove(list, index)
            return true
        end
    end
    return false
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

--- Loads the `.orch` project that contains `root` (or the current directory).
---
--- When `orch_dir` is already known (e.g. resolved by a previous `locate`
--- call) it can be passed to skip the directory walk.
---@param root? string
---@param orch_dir? string
---@return OrchState
function M.setup(root, orch_dir)
    local found
    if orch_dir then
        found = vim.fs.dirname(orch_dir)
    else
        found, orch_dir = project.locate(root)
    end
    assert(found and orch_dir, "[orchlaunch] no .orch project found")

    local paths = build_paths(orch_dir)

    state = {
        root = found,
        orch_dir = orch_dir,
        paths = paths,
        run_configurations = load_run_configurations(paths.run_configurations),
        external_tools = load_external_tools(paths.external_tools),
        toolchains = load_toolchains(paths.toolchain),
        cmake = load_cmake_settings(paths.cmake_settings),
        breakpoints = load_breakpoints(paths.breakpoints),
        runtime = {},
    }

    return state
end

---@return boolean
function M.is_loaded()
    return state ~= nil
end

---@return OrchState
function M.get()
    assert(state, "[orchlaunch] not initialized; call setup() first")
    return state
end

--- Discards the loaded project.
function M.reset()
    state = nil
end

---@return string
function M.root()
    return M.get().root
end

---@return string
function M.orch_dir()
    return M.get().orch_dir
end

--- Resolution context used by `config` path/variable helpers.
---@return OrchResolveContext
function M.context()
    return { workspace = M.root(), orch_dir = M.orch_dir() }
end

-- ============================================================================
-- Collections
-- ============================================================================

---@return OrchRunConfigurations
function M.run_configurations()
    return M.get().run_configurations
end

---@return OrchExternalToolsConfig
function M.external_tools()
    return M.get().external_tools
end

---@return OrchToolchainConfig
function M.toolchains()
    return M.get().toolchains
end

---@return OrchCMakeConfig
function M.cmake()
    return M.get().cmake
end

--- All defined CMake profiles.
---@return OrchCMakeProfile[]
function M.cmake_profiles()
    return M.get().cmake.profiles
end

--- Name of the active CMake profile, or nil when none is marked active.
---@return string?
function M.active_cmake_profile()
    local doc = M.get().cmake
    local profile = find_by_name(doc.profiles, doc.active)
    return profile and profile.name or nil
end

--- The effective CMake settings: the active profile, else an empty table
--- (built-in defaults). Exactly one profile is active at a time.
---@return OrchCMakeProfile
function M.cmake_settings()
    local doc = M.get().cmake
    return find_by_name(doc.profiles, doc.active) or {}
end

--- Persisted breakpoints (project-relative records; applied by `breakpoints`).
---@return table[]
function M.breakpoints()
    return M.get().breakpoints or {}
end

--- The directory that CMake operates on: the project-wide `source_dir`
--- (resolved), else the project root. Presets are discovered here too, so a
--- project rooted at the `.orch` directory can still target a subdirectory.
---@return string
function M.cmake_source_dir()
    return M.resolve_path(M.get().cmake.source_dir) or M.root()
end

--- The raw (unresolved) project-wide CMake `source_dir`, or nil when unset.
---@return string?
function M.cmake_source_dir_raw()
    return M.get().cmake.source_dir
end

--- Sets the project-wide CMake project directory (`nil`/`""` clears it).
---@param value? string
---@return string?
function M.set_cmake_source_dir(value)
    if value == "" then
        value = nil
    end
    M.get().cmake.source_dir = value
    M.get().runtime.presets = nil
    M.get().runtime.cmake_targets = nil
    M.get().runtime.cmake_source_dir = nil
    M.get().runtime.cmake_binary_dir = nil
    return value
end

---@param name string
---@return OrchCMakeProfile?
function M.cmake_profile(name)
    return find_by_name(M.get().cmake.profiles, name)
end

---@param name string
---@return OrchCMakeProfile
function M.set_active_cmake_profile(name)
    local doc = M.get().cmake
    local profile = find_by_name(doc.profiles, name)
    assert(profile, ("[orchlaunch] CMake profile not found: %s"):format(name))
    doc.active = name
    M.get().runtime.presets = nil
    return M.cmake_settings()
end

---@param profile OrchCMakeProfile
---@return OrchCMakeProfile
function M.add_cmake_profile(profile)
    local doc = M.get().cmake
    local added = add_named(doc, "profiles", profile)
    if doc.active == nil then
        doc.active = added.name
    end
    M.get().runtime.presets = nil
    return added
end

---@param name string
---@param profile OrchCMakeProfile
---@return OrchCMakeProfile
function M.update_cmake_profile(name, profile)
    local doc = M.get().cmake
    local updated = update_named(doc, "profiles", name, profile)
    if doc.active == name then
        doc.active = profile.name
    end
    M.get().runtime.presets = nil
    return updated
end

---@param name string
---@return boolean
function M.remove_cmake_profile(name)
    local doc = M.get().cmake
    local removed = remove_named(doc, "profiles", name)
    if removed and doc.active == name then
        doc.active = doc.profiles[1] and doc.profiles[1].name or nil
    end
    M.get().runtime.presets = nil
    return removed
end

--- Generates disabled profiles for every visible CMake configure and build
--- preset, in the spirit of CLion's preset profiles. Existing profiles are
--- left untouched. Configure and build presets are kept separate.
---@return integer added Number of profiles created.
function M.sync_cmake_profiles()
    local presets = require("orchlaunch.presets")
    local discovered = M.refresh_presets()
    if not discovered then
        return 0
    end

    local doc = M.get().cmake
    local added = 0

    local function free_name(base)
        if not find_by_name(doc.profiles, base) then
            return base
        end
        local name = base .. " (build)"
        local index = 2
        while find_by_name(doc.profiles, name) do
            name = ("%s (build %d)"):format(base, index)
            index = index + 1
        end
        return name
    end

    for _, preset in ipairs(presets.visible(discovered, "configure")) do
        if not find_by_name(doc.profiles, preset.name) then
            doc.profiles[#doc.profiles + 1] = {
                name = preset.name,
                kind = "configure",
                configure_preset = preset.name,
            }
            added = added + 1
        end
    end

    for _, preset in ipairs(presets.visible(discovered, "build")) do
        local existing = find_by_name(doc.profiles, preset.name)
        if not (existing and existing.build_preset == preset.name) then
            local resolved = presets.resolve(discovered, "build", preset.name) or {}
            doc.profiles[#doc.profiles + 1] = {
                name = existing and free_name(preset.name) or preset.name,
                kind = "build",
                configure_preset = resolved.configurePreset,
                build_preset = preset.name,
            }
            added = added + 1
        end
    end

    return added
end

--- Replaces the active profile's settings (creating one when none exist).
--- Kept for backward compatibility with callers that edit the effective settings.
---@param settings OrchCMakeSettings
---@return OrchCMakeProfile
function M.set_cmake_settings(settings)
    settings = settings or {}
    local doc = M.get().cmake
    local active = find_by_name(doc.profiles, doc.active) or doc.profiles[1]

    if not active then
        local value = vim.tbl_extend("force", { name = "Default" }, settings)
        return M.add_cmake_profile(value)
    end

    local value = vim.tbl_extend("force", { name = active.name }, settings)
    return M.update_cmake_profile(active.name, value)
end

--- Discovers (and caches) the project's CMake presets.
---
--- The result is cached in runtime data, so it is discarded on reload.
---@return OrchCMakePresets?
function M.presets()
    local current = M.get()

    if current.runtime.presets == nil then
        local ok, discovered = pcall(function()
            return require("orchlaunch.presets").discover(M.cmake_source_dir())
        end)
        current.runtime.presets = (ok and discovered) or false
    end

    local value = current.runtime.presets
    if value == false then
        return nil
    end
    return value
end

--- Discards the cached presets and re-discovers them.
---@return OrchCMakePresets?
function M.refresh_presets()
    M.get().runtime.presets = nil
    return M.presets()
end

-- ============================================================================
-- Lookups
-- ============================================================================

---@param name string
---@return OrchRunConfiguration?
function M.configuration(name)
    return find_by_name(M.run_configurations().configurations, name)
end

---@param name string
---@return OrchRunConfiguration
function M.require_configuration(name)
    local value = M.configuration(name)
    assert(value, ("[orchlaunch] configuration not found: %s"):format(name))
    return value
end

---@param name string
---@return OrchExternalTool?
function M.external_tool(name)
    return find_by_name(M.external_tools().tools, name)
end

---@param name string
---@return OrchExternalTool
function M.require_external_tool(name)
    local value = M.external_tool(name)
    assert(value, ("[orchlaunch] external tool not found: %s"):format(name))
    return value
end

---@param name string
---@return OrchToolchain?
function M.toolchain(name)
    return find_by_name(M.toolchains().toolchains, name)
end

---@param name string
---@return OrchToolchain
function M.require_toolchain(name)
    local value = M.toolchain(name)
    assert(value, ("[orchlaunch] toolchain not found: %s"):format(name))
    return value
end

-- ============================================================================
-- Mutations
-- ============================================================================

---@param value OrchRunConfiguration
---@return OrchRunConfiguration
function M.add_configuration(value)
    return add_named(M.run_configurations(), "configurations", value)
end

---@param name string
---@param value OrchRunConfiguration
---@return OrchRunConfiguration
function M.update_configuration(name, value)
    return update_named(M.run_configurations(), "configurations", name, value)
end

---@param name string
---@return boolean
function M.remove_configuration(name)
    return remove_named(M.run_configurations(), "configurations", name)
end

---@param value OrchExternalTool
---@return OrchExternalTool
function M.add_external_tool(value)
    return add_named(M.external_tools(), "tools", value)
end

---@param name string
---@param value OrchExternalTool
---@return OrchExternalTool
function M.update_external_tool(name, value)
    return update_named(M.external_tools(), "tools", name, value)
end

---@param name string
---@return boolean
function M.remove_external_tool(name)
    return remove_named(M.external_tools(), "tools", name)
end

---@param value OrchToolchain
---@return OrchToolchain
function M.add_toolchain(value)
    return add_named(M.toolchains(), "toolchains", value)
end

---@param name string
---@param value OrchToolchain
---@return OrchToolchain
function M.update_toolchain(name, value)
    return update_named(M.toolchains(), "toolchains", name, value)
end

---@param name string
---@return boolean
function M.remove_toolchain(name)
    return remove_named(M.toolchains(), "toolchains", name)
end

-- ============================================================================
-- Runtime data
-- ============================================================================

--- Runtime-only data store (never serialized).
---@return table<string, any>
function M.runtime()
    return M.get().runtime
end

---@param key string
---@param value any
function M.set_runtime(key, value)
    M.get().runtime[key] = value
end

---@param key string
---@return any
function M.get_runtime(key)
    return M.get().runtime[key]
end

-- ============================================================================
-- Persistence
-- ============================================================================

---@return boolean
function M.save()
    local current = M.get()

    config.save(current.paths.run_configurations, current.run_configurations)
    config.save(current.paths.external_tools, current.external_tools)
    config.save(current.paths.toolchain, current.toolchains)
    config.save(current.paths.cmake_settings, { cmake = current.cmake })
    config.save(current.paths.breakpoints, { breakpoints = current.breakpoints or {} })

    return true
end

---@return OrchState
function M.reload()
    local current = M.get()

    current.run_configurations = load_run_configurations(current.paths.run_configurations)
    current.external_tools = load_external_tools(current.paths.external_tools)
    current.toolchains = load_toolchains(current.paths.toolchain)
    current.cmake = load_cmake_settings(current.paths.cmake_settings)
    current.breakpoints = load_breakpoints(current.paths.breakpoints)
    current.runtime = {}

    return current
end

-- ============================================================================
-- Resolution helpers
-- ============================================================================

---@param value? string
---@return string?
function M.resolve_path(value)
    return config.resolve_path(value, M.context())
end

---@param value? string
---@return string?
function M.resolve_tool(value)
    return config.resolve_tool(value, M.context())
end

---@param value? string[]
---@return string[]
function M.resolve_list(value)
    return config.resolve_list(value, M.context())
end

---@param value? OrchEnvironment
---@return OrchEnvironment
function M.resolve_environment(value)
    return config.resolve_environment(value, M.context())
end

return M
