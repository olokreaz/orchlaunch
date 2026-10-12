-- OrchLaunch — Run/Debug dispatch.
--
-- Turns a run configuration into one or more processes. Build and install
-- before-launch actions are executed through CMake; debugger (DAP) support is
-- not implemented yet and reports a clear message instead of failing silently.

local cmake = require("orchlaunch.cmake")
local process = require("orchlaunch.process")
local state = require("orchlaunch.state")

local M = {}

local WARN = vim.log.levels.WARN
local ERROR = vim.log.levels.ERROR

--- @param message string
--- @param level? integer
local function notify(message, level)
    vim.notify("[orchlaunch] " .. message, level or vim.log.levels.INFO)
end

-- ============================================================================
-- Process specs
-- ============================================================================

--- Builds a process spec from an external tool.
---@param tool OrchExternalTool
---@return OrchProcessSpec
local function tool_spec(tool)
    return {
        program = state.resolve_tool(tool.program),
        args = state.resolve_list(tool.args),
        cwd = state.resolve_path(tool.cwd) or state.root(),
        env = state.resolve_environment(tool.environment),
        inherit_env = tool.inherit_env ~= false,
        sudo = tool.sudo == true,
    }
end

--- Runs an external tool synchronously.
---@param tool OrchExternalTool
---@return OrchProcessResult
local function run_tool(tool)
    return process.run(tool_spec(tool))
end

-- ============================================================================
-- CMake steps
-- ============================================================================

--- Runs a CMake step spec synchronously, returning false on failure.
---@param label string
---@param spec OrchProcessSpec
---@return boolean
local function run_cmake_spec(label, spec)
    local result = process.run(spec)

    if result.code ~= 0 then
        local detail = (result.stderr or ""):gsub("%s+$", "")
        if detail ~= "" then
            detail = ": " .. detail
        end
        notify(("CMake %s failed with code %d%s"):format(label, result.code, detail), ERROR)
        return false
    end

    return true
end

--- Configures (and optionally builds/installs) the project before launch.
---@param step "build" | "install"
---@param target? string
---@return boolean
local function run_cmake_step(step, target)
    if not run_cmake_spec("configure", cmake.configure_spec()) then
        return false
    end

    if not run_cmake_spec("build", cmake.build_spec(target)) then
        return false
    end

    if step == "install" then
        if not run_cmake_spec("install", cmake.install_spec()) then
            return false
        end
    end

    return true
end

--- Saves the project so `cmake_settings.toml` reflects the current selection.
local function ensure_settings_saved()
    pcall(state.save)
end

-- ============================================================================
-- Before launch
-- ============================================================================

--- Runs the before-launch actions in order. Returns false if one failed.
---@param before? OrchBefore
---@return boolean
local function run_before(before)
    for _, item in ipairs(before and before.tools or {}) do
        local kind = type(item) == "table" and item.type or item

        if kind == "build" or kind == "install" then
            ensure_settings_saved()
            local target = type(item) == "table" and item.target or nil
            if not run_cmake_step(kind, target) then
                return false
            end
        elseif kind == "external" then
            local name = type(item) == "table" and item.tool or nil
            local tool = name and state.external_tool(name)

            if not tool then
                notify(("before-launch references unknown external tool: %s"):format(tostring(name)), ERROR)
                return false
            end

            local result = run_tool(tool)
            if result.code ~= 0 then
                notify(("external tool %q failed with code %d"):format(name, result.code), ERROR)
                return false
            end
        else
            notify(("unknown before-launch action: %s"):format(tostring(kind)), WARN)
        end
    end

    return true
end

-- ============================================================================
-- Terminal
-- ============================================================================

--- Opens an embedded terminal running the given spec.
---@param spec OrchProcessSpec
local function open_terminal(spec)
    vim.cmd("botright new")
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].bufhidden = "wipe"

    local env = vim.deepcopy(spec.env or {})
    local options = { cwd = spec.cwd }

    if next(env) ~= nil then
        options.env = env
    end
    if spec.inherit_env == false then
        options.clear_env = true
    end

    vim.fn.termopen(process.command(spec), options)
    vim.cmd("startinsert")
end

-- ============================================================================
-- Configuration dispatch
-- ============================================================================

--- @param name string
--- @param mode "run" | "debug"
local function launch_native(name, mode)
    local cfg = state.require_configuration(name)

    if mode == "debug" then
        notify(("debugging %q is not implemented yet (DAP integration pending)"):format(name), WARN)
        return
    end

    if not cfg.target or cfg.target == "" then
        notify(("configuration %q has no target"):format(name), ERROR)
        return
    end

    local target = cfg.target
    local program = state.resolve_path(target)
    local looks_like_path = target:find("[/\\]") ~= nil or vim.fn.filereadable(program or "") == 1

    if not looks_like_path then
        program = cmake.find_target(target)
        if not program then
            notify(
                ("cannot resolve CMake target %q; build it first or set target to an executable path"):format(target),
                ERROR
            )
            return
        end
    end

    if not run_before(cfg.before) then
        return
    end

    if not looks_like_path then
        program = cmake.find_target(target) or program
    end

    local spec = {
        program = program,
        args = state.resolve_list(cfg.args),
        cwd = state.resolve_path(cfg.cwd) or state.root(),
        env = state.resolve_environment(cfg.environment),
        inherit_env = cfg.inherit_env ~= false,
        sudo = cfg.sudo == true,
    }

    local console = cfg.console or {}
    local console_mode = console.mode or "embedded"

    if console_mode == "embedded" then
        open_terminal(spec)
    else
        process.start(spec, function(result)
            vim.schedule(function()
                if console_mode ~= "none" then
                    notify(("%q finished with code %d"):format(name, result.code))
                end
            end)
        end)
    end
end

--- @param name string
--- @param mode "run" | "debug"
local function launch_compound(name, mode)
    local cfg = state.require_configuration(name)

    for _, child in ipairs(cfg.configurations or {}) do
        M.run(child, { mode = mode })
    end
end

--- @param name string
--- @param mode "run" | "debug"
local function launch_remote_debug(name, mode)
    if mode ~= "debug" then
        notify(("remote-debug configuration %q is only available in debug mode"):format(name), WARN)
        return
    end

    notify(("remote debugging %q is not implemented yet (DAP integration pending)"):format(name), WARN)
end

--- Runs (or debugs) a configuration by name.
---@param name string
---@param opts? { mode?: "run" | "debug" }
function M.run(name, opts)
    opts = opts or {}
    local mode = opts.mode or "run"

    if not state.is_loaded() then
        notify("no .orch project loaded", ERROR)
        return
    end

    local cfg = state.configuration(name)
    if not cfg then
        notify(("configuration not found: %s"):format(name), ERROR)
        return
    end

    if cfg.type == "compound" then
        launch_compound(name, mode)
    elseif cfg.type == "remote-debug" then
        launch_remote_debug(name, mode)
    else
        launch_native(name, mode)
    end
end

--- Runs the active configuration (or the first one when none is set).
---@param opts? { mode?: "run" | "debug" }
---@return string? name
function M.run_active(opts)
    local active = require("orchlaunch.active")

    if not state.is_loaded() then
        notify("no .orch project loaded", ERROR)
        return nil
    end

    local name = active.get(state.root())
    if not name or not state.configuration(name) then
        local configurations = state.run_configurations().configurations
        name = configurations[1] and configurations[1].name
    end

    if not name then
        notify("no run configurations defined", WARN)
        return nil
    end

    M.run(name, opts)
    return name
end

--- Creates a native run configuration for every executable CMake target that
--- does not have one yet. The working directory is the CMake build directory,
--- and the target field is preset to the target name.
---@param targets OrchCMakeTarget[]
---@return integer created
local function sync_target_configurations(targets)
    local config = require("orchlaunch.config")
    local build_dir = cmake.binary_dir()
    local created = 0

    for _, target in ipairs(targets) do
        if target.type == "EXECUTABLE" and not state.configuration(target.name) then
            state.add_configuration(config.native({
                name = target.name,
                target = target.name,
                cwd = build_dir,
            }))
            created = created + 1
        end
    end

    if created > 0 then
        ensure_settings_saved()
    end

    return created
end

--- Configures the project and discovers its CMake targets (File API).
---
--- Executable targets are turned into native run configurations (unless a
--- configuration with the same name already exists).
---@return OrchCMakeTarget[]?
function M.load_cmake()
    if not state.is_loaded() then
        notify("no .orch project loaded", ERROR)
        return nil
    end

    ensure_settings_saved()

    local targets, result = cmake.load_targets()
    if not targets then
        local detail = result and (result.stderr or ""):gsub("%s+$", "") or ""
        notify(("CMake configure failed%s"):format(detail ~= "" and (": " .. detail) or ""), ERROR)
        return nil
    end

    local created = sync_target_configurations(targets)

    if result and result.code ~= 0 then
        local detail = (result.stderr or ""):gsub("%s+$", "")
        notify(
            ("CMake configure failed; showing %d cached target(s), %d run configuration(s) added%s"):format(
                #targets,
                created,
                detail ~= "" and (": " .. detail) or ""
            ),
            WARN
        )
        return targets
    end

    notify(
        ("CMake project loaded: %d target(s) discovered from %s, %d run configuration(s) added"):format(
            #targets,
            cmake.source_dir(),
            created
        )
    )
    return targets
end

--- Runs an external tool by name synchronously.
---@param name string
---@return OrchProcessResult?
function M.run_external_tool(name)
    if not state.is_loaded() then
        notify("no .orch project loaded", ERROR)
        return nil
    end

    local tool = state.external_tool(name)
    if not tool then
        notify(("external tool not found: %s"):format(name), ERROR)
        return nil
    end

    return run_tool(tool)
end

return M
