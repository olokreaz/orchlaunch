-- OrchLaunch — launching a run configuration.
--
-- Turns a configuration into a process (native), an attach (remote-debug), a
-- sequence of children (compound), or a debugger session, synchronously or
-- asynchronously. Before-launch steps come from runner/before.lua and
-- CMake target lookup from cmake.lua. Re-exported by `orchlaunch.runner`.

local cmake = require("orchlaunch.cmake")
local notify = require("orchlaunch.notify").notify
local process = require("orchlaunch.process")
local state = require("orchlaunch.state")
local before = require("orchlaunch.runner.before")
local run_state = require("orchlaunch.runner.state")

local M = {}

local WARN = vim.log.levels.WARN
local ERROR = vim.log.levels.ERROR

local run_before = before.run_before
local run_before_async = before.run_before_async

-- Forward declaration: the native launch paths above call it, and it is
-- defined in the Terminal section below.
---@type fun(spec: OrchProcessSpec, console: OrchConsole)
local open_terminal

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

    run_before_async(cfg.before, { target = cfg.target, target_name = cfg.target_name or cfg.name }, function(proceed)
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
                args = state.resolve_list(cfg.args, { target = cfg.target, target_name = cfg.target_name or cfg.name }),
                cwd = state.resolve_path(cfg.cwd, { target = cfg.target, target_name = cfg.target_name or cfg.name }) or state.root(),
                env = M.launch_environment(cfg),
            })
            on_done(config ~= nil)
            return
        end

        local spec = {
            program = program,
            args = state.resolve_list(cfg.args, { target = cfg.target, target_name = cfg.target_name or cfg.name }),
            cwd = state.resolve_path(cfg.cwd, { target = cfg.target, target_name = cfg.target_name or cfg.name }) or state.root(),
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
        local finished = false
        job = process.start(spec, function(result)
            if finished then
                return
            end
            finished = true
            vim.schedule(function()
                run_state.clear_if(job)
                if console_mode ~= "none" then
                    notify(("%q finished with code %d"):format(name, result.code))
                end
            end)
        end)
        if not finished then
            run_state.set(job, name)
        end
        on_done(true)
    end)
end

--- Starts the debug server a remote-debug configuration asks for (`server`),
--- waits until it listens and stops it with the debug session. Returns false
--- with a message when the server cannot be started; true otherwise (also when
--- no server is configured, so an external server keeps working).
---@param cfg table
---@return boolean
local function start_remote_server(cfg)
    if not cfg.server or cfg.server == "" then
        return true
    end
    local server = require("orchlaunch.debug.server")
    local port = tonumber((cfg.connection or ""):match(":(%d+)$"))
    if not port then
        notify(("remote-debug %q: connection must be host:port"):format(cfg.name), ERROR)
        return false
    end
    local handle, err = server.start(cfg.server, port, state.resolve_path(cfg.symbol))
    if not handle then
        notify(("remote-debug %q: %s"):format(cfg.name, err), ERROR)
        return false
    end
    if not server.wait_listening(port, 10000) then
        handle.stop()
        notify(("remote-debug %q: %s did not listen on port %d"):format(cfg.name, cfg.server, port), ERROR)
        return false
    end
    -- Stop the server once this debug session ends.
    vim.api.nvim_create_autocmd("User", {
        pattern = "OrchLaunchDebugStopped",
        once = true,
        callback = function()
            handle.stop()
        end,
    })
    return true
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
    run_before_async(cfg.before, { target = cfg.target, target_name = cfg.target_name or cfg.name }, function(proceed)
        if not proceed then
            on_done(false)
            return
        end
        if not start_remote_server(cfg) then
            on_done(false)
            return
        end
        local config = require("orchlaunch.debug").start(cfg, {
            type = "attach",
            connection = cfg.connection,
            program = state.resolve_path(cfg.symbol),
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
    for key, value in pairs(state.resolve_environment(cfg.environment, { target = cfg.target, target_name = cfg.target_name or cfg.name })) do
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
        if not run_before(cfg.before, { target = cfg.target, target_name = cfg.target_name or cfg.name }) then
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
            args = state.resolve_list(cfg.args, { target = cfg.target, target_name = cfg.target_name or cfg.name }),
            cwd = state.resolve_path(cfg.cwd, { target = cfg.target, target_name = cfg.target_name or cfg.name }) or state.root(),
            env = M.launch_environment(cfg),
        })
        return
    end

    if not run_before(cfg.before, { target = cfg.target, target_name = cfg.target_name or cfg.name }) then
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
        args = state.resolve_list(cfg.args, { target = cfg.target, target_name = cfg.target_name or cfg.name }),
        cwd = state.resolve_path(cfg.cwd, { target = cfg.target, target_name = cfg.target_name or cfg.name }) or state.root(),
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
    if not run_before(cfg.before, { target = cfg.target, target_name = cfg.target_name or cfg.name }) then
        return
    end
    if not start_remote_server(cfg) then
        return
    end
    local dbg = require("orchlaunch.debug")
    dbg.start(cfg, { type = "attach", connection = cfg.connection, program = state.resolve_path(cfg.symbol) })
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

return M
