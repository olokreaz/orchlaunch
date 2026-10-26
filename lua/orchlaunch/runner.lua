-- OrchLaunch — Run/Debug dispatch.
--
-- Turns a run configuration into one or more processes. Build and install
-- before-launch actions are executed through CMake; debugger (DAP) support
-- integrates with nvim-dap via the debug overlay.

local cmake = require("orchlaunch.cmake")
local integrations = require("orchlaunch.integrations")
local process = require("orchlaunch.process")
local state = require("orchlaunch.state")

local M = {}

local WARN = vim.log.levels.WARN
local ERROR = vim.log.levels.ERROR

-- Synchronous build/tool steps must not hang a Neovim session forever.
local DEFAULT_TIMEOUT_MS = 15 * 60 * 1000

--- @param message string
--- @param level? integer
local function notify(message, level)
    vim.notify("[orchlaunch] " .. message, level or vim.log.levels.INFO)
end

-- Forward declaration: `open_terminal` is used by launch paths defined above
-- its implementation (the asynchronous native launch). Declaring the local up
-- front keeps those references bound to it instead of an undefined global.
---@type fun(spec: OrchProcessSpec, console: OrchConsole)
local open_terminal

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
        timeout = tool.timeout or DEFAULT_TIMEOUT_MS,
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

--- @type vim.SystemObj?
local active_job = nil
local active_label = nil

--- Defined below; forward-declared because async launch paths use it.
---@type fun(spec: OrchProcessSpec, console: OrchConsole)
local open_terminal

--- Reports a completed CMake step in the quickfix list.
---@param label string
---@param spec OrchProcessSpec
---@param result OrchProcessResult
---@return boolean
local function report_cmake_result(label, spec, result)
    -- Compiler diagnostics go to the standard quickfix list; trouble.nvim,
    -- snacks.nvim and `:copen` render it without any OrchLaunch-specific UI.
    local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
    local qf_cwd = label == "configure" and spec.cwd or cmake.binary_dir()
    integrations.quickfix(("OrchLaunch: CMake %s"):format(label), output, qf_cwd)

    if not process.succeeded(result) then
        local detail = (result.stderr or ""):gsub("%s+$", "")
        if detail ~= "" then
            detail = ": " .. detail
        end
        local status = (result.signal or 0) ~= 0 and ("signal %d"):format(result.signal)
            or ("code %d"):format(result.code)
        notify(("CMake %s failed with %s%s"):format(label, status, detail), ERROR)
        return false
    end

    return true
end

--- Runs a CMake step spec synchronously, returning false on failure.
---@param label string
---@param spec OrchProcessSpec
---@return boolean
local function run_cmake_spec(label, spec)
    spec.timeout = spec.timeout or DEFAULT_TIMEOUT_MS
    local result = process.run(spec)
    return report_cmake_result(label, spec, result)
end

--- Runs a process asynchronously and delivers the result on the main loop.
---@param spec OrchProcessSpec
---@param label string
---@param on_done fun(result: OrchProcessResult)
local function start_async(spec, label, on_done)
    active_label = label
    local finished = false

    local function finish(result)
        if finished then
            return
        end
        finished = true
        active_job = nil
        active_label = nil
        vim.schedule(function()
            on_done(result)
        end)
    end

    spec.timeout = spec.timeout or DEFAULT_TIMEOUT_MS
    local job = process.start(spec, finish)
    active_job = job
end

--- Runs a CMake step asynchronously.
---@param label string
---@param spec OrchProcessSpec
---@param on_done fun(ok: boolean)
local function run_cmake_spec_async(label, spec, on_done)
    start_async(spec, label, function(result)
        on_done(report_cmake_result(label, spec, result))
    end)
end

--- Cancels the most recently started asynchronous build/tool step.
---@return boolean cancelled
function M.cancel()
    if not active_job then
        notify("no build or tool step is running", WARN)
        return false
    end
    local job = active_job
    local label = active_label
    active_job = nil
    active_label = nil
    local ok = pcall(job.kill, job, 15)
    if ok then
        notify(("cancelled %s"):format(label or "process"), WARN)
    else
        notify("failed to cancel the running process", ERROR)
    end
    return ok
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

--- Asynchronous version of `run_cmake_step`.
---@param step "build" | "install"
---@param target? string
---@param on_done fun(ok: boolean)
local function run_cmake_step_async(step, target, on_done)
    run_cmake_spec_async("configure", cmake.configure_spec(), function(ok)
        if not ok then
            on_done(false)
            return
        end
        run_cmake_spec_async("build", cmake.build_spec(target), function(built)
            if not built or step ~= "install" then
                on_done(built)
                return
            end
            run_cmake_spec_async("install", cmake.install_spec(), on_done)
        end)
    end)
end

--- Runs only the CMake configure step.
---@return boolean
function M.configure()
    local ok = run_cmake_spec("configure", cmake.configure_spec())
    if ok then
        notify("CMake configure finished")
    end
    return ok
end

--- Builds the project (optionally a single target) and reports diagnostics in
--- the quickfix list.
---@param target? string
---@return boolean
function M.build(target)
    local ok = run_cmake_step("build", target)
    if ok then
        notify(target and ("build finished: " .. target) or "build finished")
    end
    return ok
end

--- Removes build outputs through the build tool's `clean` target.
---@return boolean
function M.clean()
    if not run_cmake_spec("clean", cmake.build_spec("clean")) then
        return false
    end
    notify("clean finished")
    return true
end

--- Clean + full configure/build (CLion's Rebuild).
---@param target? string
---@return boolean
function M.rebuild(target)
    if not M.clean() then
        return false
    end
    local ok = run_cmake_step("build", target)
    if ok then
        notify(target and ("rebuild finished: " .. target) or "rebuild finished")
    end
    return ok
end

--- Configure, build and install.
---@param target? string
---@return boolean
function M.install(target)
    local ok = run_cmake_step("install", target)
    if ok then
        notify("install finished")
    end
    return ok
end

--- Configure, build and run the project's CTest suite.
---@return boolean
function M.test()
    if not run_cmake_spec("configure", cmake.configure_spec()) then
        return false
    end
    if not run_cmake_spec("build", cmake.build_spec()) then
        return false
    end
    if not run_cmake_spec("test", cmake.test_spec()) then
        return false
    end
    notify("tests finished")
    return true
end

--- @param cb? fun(ok: boolean)
--- @return boolean ok
function M.configure_async(cb)
    run_cmake_spec_async("configure", cmake.configure_spec(), function(ok)
        if ok then
            notify("CMake configure finished")
        end
        if cb then
            cb(ok)
        end
    end)
    return true
end

--- @param target? string
--- @param cb? fun(ok: boolean)
--- @return boolean ok
function M.build_async(target, cb)
    run_cmake_step_async("build", target, function(ok)
        if ok then
            notify(target and ("build finished: " .. target) or "build finished")
        end
        if cb then
            cb(ok)
        end
    end)
    return true
end

--- @param cb? fun(ok: boolean)
--- @return boolean ok
function M.clean_async(cb)
    run_cmake_spec_async("clean", cmake.build_spec("clean"), function(ok)
        if ok then
            notify("clean finished")
        end
        if cb then
            cb(ok)
        end
    end)
    return true
end

--- @param target? string
--- @param cb? fun(ok: boolean)
--- @return boolean ok
function M.rebuild_async(target, cb)
    run_cmake_spec_async("clean", cmake.build_spec("clean"), function(cleaned)
        if not cleaned then
            if cb then
                cb(false)
            end
            return
        end
        run_cmake_step_async("build", target, function(ok)
            if ok then
                notify(target and ("rebuild finished: " .. target) or "rebuild finished")
            end
            if cb then
                cb(ok)
            end
        end)
    end)
    return true
end

--- @param target? string
--- @param cb? fun(ok: boolean)
--- @return boolean ok
function M.install_async(target, cb)
    run_cmake_step_async("install", target, function(ok)
        if ok then
            notify("install finished")
        end
        if cb then
            cb(ok)
        end
    end)
    return true
end

--- @param cb? fun(ok: boolean)
--- @return boolean ok
function M.test_async(cb)
    run_cmake_spec_async("configure", cmake.configure_spec(), function(configured)
        if not configured then
            if cb then
                cb(false)
            end
            return
        end
        run_cmake_spec_async("build", cmake.build_spec(), function(built)
            if not built then
                if cb then
                    cb(false)
                end
                return
            end
            run_cmake_spec_async("test", cmake.test_spec(), function(ok)
                if ok then
                    notify("tests finished")
                end
                if cb then
                    cb(ok)
                end
            end)
        end)
    end)
    return true
end

--- Saves the project so `cmake_settings.json` reflects the current selection.
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
            if not process.succeeded(result) then
                notify(("external tool %q failed with code %d"):format(name, result.code), ERROR)
                return false
            end
        else
            notify(("unknown before-launch action: %s"):format(tostring(kind)), WARN)
        end
    end

    return true
end

--- Asynchronous external-tool runner.
---@param tool OrchExternalTool
---@param on_done fun(result: OrchProcessResult)
local function run_tool_async(tool, on_done)
    start_async(tool_spec(tool), "external tool " .. tool.name, on_done)
end

--- Asynchronous before-launch chain.
---@param before? OrchBefore
---@param on_done fun(ok: boolean)
local function run_before_async(before, on_done)
    local items = before and before.tools or {}
    local index = 0

    local function next_item()
        index = index + 1
        local item = items[index]
        if item == nil then
            on_done(true)
            return
        end

        local kind = type(item) == "table" and item.type or item
        if kind == "build" or kind == "install" then
            ensure_settings_saved()
            local target = type(item) == "table" and item.target or nil
            run_cmake_step_async(kind, target, function(ok)
                if ok then
                    next_item()
                else
                    on_done(false)
                end
            end)
        elseif kind == "external" then
            local name = type(item) == "table" and item.tool or nil
            local tool = name and state.external_tool(name)
            if not tool then
                notify(("before-launch references unknown external tool: %s"):format(tostring(name)), ERROR)
                on_done(false)
                return
            end

            run_tool_async(tool, function(result)
                if not process.succeeded(result) then
                    local detail = (result.stderr or ""):gsub("%s+$", "")
                    notify(
                        ("external tool %q failed with code %d%s"):format(
                            name,
                            result.code,
                            detail ~= "" and (": " .. detail) or ""
                        ),
                        ERROR
                    )
                    on_done(false)
                else
                    next_item()
                end
            end)
        else
            notify(("unknown before-launch action: %s"):format(tostring(kind)), WARN)
            next_item()
        end
    end

    next_item()
end

---@param cfg OrchNativeConfiguration
---@return string?
local function resolve_program(cfg)
    local target = cfg.target
    if not target or target == "" then
        return nil
    end
    local program = state.resolve_path(target)
    local looks_like_path = target:find("[/\\]") ~= nil or vim.fn.filereadable(program or "") == 1
    if looks_like_path then
        return program
    end
    return cmake.find_target(target)
end

--- Asynchronous native launch/debug path.
---@param name string
---@param mode "run" | "debug"
---@param on_done fun(ok: boolean)
local function launch_native_async(name, mode, on_done)
    local cfg = state.require_configuration(name)

    run_before_async(cfg.before, function(proceed)
        if not proceed then
            on_done(false)
            return
        end

        if not cfg.target or cfg.target == "" then
            if mode == "debug" then
                notify(("configuration %q has no executable; cannot debug"):format(name), WARN)
                on_done(false)
            else
                notify(("configuration %q has no executable; build steps completed"):format(name), WARN)
                on_done(true)
            end
            return
        end

        local program = resolve_program(cfg)
        if not program then
            notify(
                ("cannot resolve CMake target %q; build it first or set target to an executable path"):format(
                    tostring(cfg.target)
                ),
                ERROR
            )
            on_done(false)
            return
        end

        if mode == "debug" then
            if cfg.sudo then
                notify(("configuration %q requests sudo; debug adapters cannot elevate"):format(name), WARN)
            end
            local config = require("orchlaunch.debug").start(cfg, {
                type = "launch",
                adapter = M.launch_adapter(cfg),
                program = program,
                args = state.resolve_list(cfg.args),
                cwd = state.resolve_path(cfg.cwd) or state.root(),
                env = M.launch_environment(cfg),
            })
            on_done(config ~= nil)
            return
        end

        local spec = {
            program = program,
            args = state.resolve_list(cfg.args),
            cwd = state.resolve_path(cfg.cwd) or state.root(),
            env = M.launch_environment(cfg),
            inherit_env = cfg.inherit_env ~= false,
            sudo = cfg.sudo == true,
        }

        local console = cfg.console
        if type(console) ~= "table" then
            console = {}
        end
        local console_mode = console.mode or "embedded"
        if console_mode ~= "embedded" and console_mode ~= "hidden" and console_mode ~= "none" then
            notify(("unknown console mode %q; using embedded"):format(console_mode), WARN)
            console_mode = "embedded"
        end

        if console_mode == "embedded" then
            open_terminal(spec, console)
            on_done(true)
            return
        end

        local job
        job = process.start(spec, function(result)
            vim.schedule(function()
                if active_job == job then
                    active_job = nil
                    active_label = nil
                end
                if console_mode ~= "none" then
                    notify(("%q finished with code %d"):format(name, result.code))
                end
            end)
        end)
        active_job = job
        active_label = name
        on_done(true)
    end)
end

--- Asynchronous remote-debug path.
---@param name string
---@param mode "run" | "debug"
---@param on_done fun(ok: boolean)
local function launch_remote_debug_async(name, mode, on_done)
    if mode ~= "debug" then
        notify(("remote-debug configuration %q is only available in debug mode"):format(name), WARN)
        on_done(false)
        return
    end

    local cfg = state.require_configuration(name)
    run_before_async(cfg.before, function(proceed)
        if not proceed then
            on_done(false)
            return
        end
        local config = require("orchlaunch.debug").start(cfg, {
            type = "attach",
            connection = cfg.connection,
            program = cfg.symbol,
        })
        on_done(config ~= nil)
    end)
end

--- Asynchronous compound expansion (children run in declaration order).
---@param name string
---@param mode "run" | "debug"
---@param stack string[]
---@param on_done fun(ok: boolean)
local function launch_compound_async(name, mode, stack, on_done)
    for _, ancestor in ipairs(stack) do
        if ancestor == name then
            notify(
                ("compound configuration cycle detected: %s -> %s"):format(table.concat(stack, " -> "), name),
                ERROR
            )
            on_done(false)
            return
        end
    end

    stack[#stack + 1] = name
    local cfg = state.require_configuration(name)
    local children = cfg.configurations or {}
    local index = 0
    local all_ok = true

    local function next_child()
        index = index + 1
        if index > #children then
            stack[#stack] = nil
            on_done(all_ok)
            return
        end
        M.run(children[index], {
            mode = mode,
            _compound_stack = stack,
            async = true,
            _on_done = function(ok)
                if not ok then
                    all_ok = false
                end
                next_child()
            end,
        })
    end

    next_child()
end

-- ============================================================================
-- Terminal
-- ============================================================================

--- Opens an embedded terminal running the given spec.
---@param spec OrchProcessSpec
---@param console OrchConsole
open_terminal = function(spec, console)
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

    local channel = vim.fn.termopen(process.command(spec), options)
    if channel <= 0 then
        notify("failed to start the embedded terminal", ERROR)
        return
    end

    if console.clear_on_start ~= false then
        vim.api.nvim_buf_call(buf, function()
            vim.cmd("clear")
        end)
    end

    if console.keep_open == false then
        vim.api.nvim_create_autocmd("TermClose", {
            buffer = buf,
            once = true,
            callback = function()
                vim.schedule(function()
                    if vim.api.nvim_buf_is_valid(buf) then
                        pcall(vim.api.nvim_buf_delete, buf, { force = true })
                    end
                end)
            end,
        })
    end

    vim.cmd("startinsert")
end

-- ============================================================================
-- Configuration dispatch
-- ============================================================================

--- Toolchain environment first, then the active CMake profile, then the
--- configuration's own environment (most specific wins).
---@param cfg OrchNativeConfiguration
---@return OrchEnvironment
function M.launch_environment(cfg)
    local env = cmake.toolchain_environment()
    for key, value in pairs(cmake.profile_environment()) do
        env[key] = value
    end
    for key, value in pairs(state.resolve_environment(cfg.environment)) do
        env[key] = value
    end
    return env
end

--- Uses the toolchain debugger unless the configuration selects one.
---@param cfg OrchNativeConfiguration
---@return string?
function M.launch_adapter(cfg)
    if cfg.adapter and cfg.adapter ~= "" then
        return cfg.adapter
    end
    local toolchain = cmake.toolchain()
    return toolchain and toolchain.debugger ~= "" and toolchain.debugger or nil
end

--- @param name string
--- @param mode "run" | "debug"
local function launch_native(name, mode)
    local cfg = state.require_configuration(name)

    if mode == "debug" then
        local dbg = require("orchlaunch.debug")
        if not run_before(cfg.before) then
            return
        end
        if not cfg.target or cfg.target == "" then
            notify(("configuration %q has no executable; cannot debug"):format(name), WARN)
            return
        end
        if cfg.sudo then
            notify(("configuration %q requests sudo; debug adapters cannot elevate"):format(name), WARN)
        end
        local target = cfg.target
        local program = state.resolve_path(target)
        local looks_like_path = target:find("[/\\]") ~= nil or vim.fn.filereadable(program or "") == 1
        if not looks_like_path then
            program = cmake.find_target(target)
            if not program then
                notify(("cannot resolve CMake target %q; build it first or set target to an executable path"):format(target), ERROR)
                return
            end
        end
        dbg.start(cfg, {
            type = "launch",
            adapter = M.launch_adapter(cfg),
            program = program,
            args = state.resolve_list(cfg.args),
            cwd = state.resolve_path(cfg.cwd) or state.root(),
            env = M.launch_environment(cfg),
        })
        return
    end

    if not run_before(cfg.before) then
        return
    end

    if not cfg.target or cfg.target == "" then
        notify(("configuration %q has no executable; build steps completed"):format(name), WARN)
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

    local spec = {
        program = program,
        args = state.resolve_list(cfg.args),
        cwd = state.resolve_path(cfg.cwd) or state.root(),
        env = M.launch_environment(cfg),
        inherit_env = cfg.inherit_env ~= false,
        sudo = cfg.sudo == true,
    }

    local console = cfg.console
    if type(console) ~= "table" then
        console = {}
    end
    local console_mode = console.mode or "embedded"
    if console_mode ~= "embedded" and console_mode ~= "hidden" and console_mode ~= "none" then
        notify(("unknown console mode %q; using embedded"):format(console_mode), WARN)
        console_mode = "embedded"
    end

    if console_mode == "embedded" then
        open_terminal(spec, console)
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
--- @param stack? string[] Compound configurations currently being expanded.
local function launch_compound(name, mode, stack)
    stack = stack or {}

    for _, ancestor in ipairs(stack) do
        if ancestor == name then
            notify(
                ("compound configuration cycle detected: %s -> %s"):format(table.concat(stack, " -> "), name),
                ERROR
            )
            return
        end
    end

    stack[#stack + 1] = name
    local cfg = state.require_configuration(name)

    for _, child in ipairs(cfg.configurations or {}) do
        M.run(child, { mode = mode, _compound_stack = stack })
    end

    stack[#stack] = nil
end

--- @param name string
--- @param mode "run" | "debug"
local function launch_remote_debug(name, mode)
    if mode ~= "debug" then
        notify(("remote-debug configuration %q is only available in debug mode"):format(name), WARN)
        return
    end

    local cfg = state.require_configuration(name)
    if not run_before(cfg.before) then
        return
    end
    local dbg = require("orchlaunch.debug")
    dbg.start(cfg, { type = "attach", connection = cfg.connection, program = cfg.symbol })
end

--- Runs (or debugs) a configuration by name.
---@param name string
---@param opts? { mode?: "run" | "debug", _compound_stack?: string[] }
function M.run(name, opts)
    opts = opts or {}
    local mode = opts.mode or "run"
    local stack = opts._compound_stack or {}
    local on_done = opts._on_done or function() end

    if not state.is_loaded() then
        notify("no .orch project loaded", ERROR)
        on_done(false)
        return
    end

    local cfg = state.configuration(name)
    if not cfg then
        notify(("configuration not found: %s"):format(name), ERROR)
        on_done(false)
        return
    end

    if opts.async then
        if cfg.type == "compound" then
            launch_compound_async(name, mode, stack, on_done)
        elseif cfg.type == "remote-debug" then
            launch_remote_debug_async(name, mode, on_done)
        elseif cfg.type == "native" then
            launch_native_async(name, mode, on_done)
        else
            notify(("unsupported configuration type %q in %s"):format(tostring(cfg.type), name), ERROR)
            on_done(false)
        end
        return
    end

    if cfg.type == "compound" then
        launch_compound(name, mode, stack)
    elseif cfg.type == "remote-debug" then
        launch_remote_debug(name, mode)
    elseif cfg.type == "native" then
        launch_native(name, mode)
    else
        notify(("unsupported configuration type %q in %s"):format(tostring(cfg.type), name), ERROR)
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

--- Creates a native run configuration for *every* CMake target that does not
--- have one yet, whatever its type (executables, static/shared/module/object/
--- interface libraries, custom targets). Executables carry the target name in
--- `target`; all other kinds have no executable, so their `target` stays empty
--- and only the runtime kind is recorded. Every configuration builds before
--- launch, like CLion. Existing configurations (including ones created by hand
--- before the File API was parsed) are left untouched.
---@param targets OrchCMakeTarget[]
---@return integer created
local function sync_target_configurations(targets)
    local config = require("orchlaunch.config")
    local build_dir = cmake.binary_dir()
    local created = 0

    for _, target in ipairs(targets) do
        if not state.configuration(target.name) then
            local runtime = cmake.runtime_for(target.type)
            state.add_configuration(config.native({
                name = target.name,
                target = runtime == "executable" and target.name or nil,
                runtime = runtime,
                cwd = build_dir,
                before = config.before({ config.build(target.name) }),
            }))
            -- Persist immediately: the configuration exists from this moment on.
            state.save()
            created = created + 1
        end
    end

    return created
end

--- Configures the project and discovers its CMake targets (File API).
---
--- Every CMake target is turned into a native run configuration (unless a
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

    if result and not process.succeeded(result) then
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

--- Asynchronously configures the project and discovers its CMake targets.
---@param cb? fun(targets: OrchCMakeTarget[]?, created?: integer, result?: OrchProcessResult)
---@return boolean started
function M.load_cmake_async(cb)
    cb = cb or function() end
    if not state.is_loaded() then
        notify("no .orch project loaded", ERROR)
        cb(nil)
        return false
    end

    ensure_settings_saved()

    local job
    local finished = false
    job = cmake.load_targets_async(function(targets, result)
        if finished then
            return
        end
        finished = true
        if active_job == job then
            active_job = nil
            active_label = nil
        end

        if not targets then
            local detail = result and (result.stderr or ""):gsub("%s+$", "") or ""
            notify(("CMake configure failed%s"):format(detail ~= "" and (": " .. detail) or ""), ERROR)
            cb(nil, nil, result)
            return
        end

        local created = sync_target_configurations(targets)

        if result and not process.succeeded(result) then
            local detail = (result.stderr or ""):gsub("%s+$", "")
            notify(
                ("CMake configure failed; showing %d cached target(s), %d run configuration(s) added%s"):format(
                    #targets,
                    created,
                    detail ~= "" and (": " .. detail) or ""
                ),
                WARN
            )
            cb(targets, created, result)
            return
        end

        notify(
            ("CMake project loaded: %d target(s) discovered from %s, %d run configuration(s) added"):format(
                #targets,
                cmake.source_dir(),
                created
            )
        )
        cb(targets, created, result)
    end)

    active_job = job
    active_label = "CMake load"
    return true
end

--- Discovers CMake targets from an existing build directory without reconfiguring.
---
--- Useful when configure is expensive and the build already contains a valid
--- CMake File API reply. Executable targets are turned into native run
--- configurations (unless a configuration with the same name already exists).
---@return OrchCMakeTarget[]?
function M.refresh_cmake()
    if not state.is_loaded() then
        notify("no .orch project loaded", ERROR)
        return nil
    end

    ensure_settings_saved()

    local targets = cmake.refresh_targets()
    if not targets or #targets == 0 then
        notify("CMake targets not found; no existing File API reply in the build directory", ERROR)
        return nil
    end

    local created = sync_target_configurations(targets)

    notify(
        ("CMake targets refreshed: %d target(s) from %s, %d run configuration(s) added"):format(
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

--- Runs an external tool by name asynchronously.
---@param name string
---@param cb? fun(result: OrchProcessResult?)
---@return boolean started
function M.run_external_tool_async(name, cb)
    cb = cb or function() end
    if not state.is_loaded() then
        notify("no .orch project loaded", ERROR)
        cb(nil)
        return false
    end

    local tool = state.external_tool(name)
    if not tool then
        notify(("external tool not found: %s"):format(name), ERROR)
        cb(nil)
        return false
    end

    run_tool_async(tool, function(result)
        if not process.succeeded(result) then
            local detail = (result.stderr or ""):gsub("%s+$", "")
            notify(
                ("external tool %q failed with code %d%s"):format(
                    name,
                    result.code,
                    detail ~= "" and (": " .. detail) or ""
                ),
                ERROR
            )
        else
            notify(("external tool %q finished with code %d"):format(name, result.code))
        end
        cb(result)
    end)
    return true
end

return M
