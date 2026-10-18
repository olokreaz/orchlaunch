-- OrchLaunch debug public API.
--
-- Owns the DAP glue and the neutral request built from a configuration. The
-- actual adapter is chosen through the backend registry, so new debuggers are
-- added as backends without touching this file (or the UI).

local backend_registry = require("orchlaunch.debug.backends")
local session = require("orchlaunch.debug.session")

local M = {}

local dap = nil

local function get_dap()
    if dap then
        return dap
    end
    local ok, d = pcall(require, "dap")
    if not ok then
        return nil
    end
    dap = d
    return dap
end

--- Builds a backend-neutral request from a configuration and launch options.
---@param cfg? table
---@param opts? table
---@return OrchDebugRequest
local function build_request(cfg, opts)
    cfg = cfg or {}
    opts = opts or {}

    local mode = opts.type == "attach" and "attach" or "launch"
    local adapter = opts.adapter or cfg.adapter

    local request = {
        mode = mode,
        name = cfg.name or opts.name,
        backend = opts.backend,
        adapter = adapter,
        kind = opts.kind,
        dap_path = opts.dap_path,
        program = opts.program,
        args = opts.args,
        cwd = opts.cwd,
        env = opts.env,
        connection = cfg.connection or opts.connection,
        pid = opts.pid,
        stop_on_entry = opts.stop_on_entry,
    }

    if mode == "attach" and not request.program then
        request.program = cfg.symbol
    end
    -- An adapter given as a path means "use this executable".
    if not request.dap_path and backend_registry.is_path(adapter) then
        request.dap_path = adapter
    end

    return request
end

--- Starts a debug session for `cfg`.
---@param cfg? table
---@param opts? table
---@return table? config The DAP configuration that was run.
function M.start(cfg, opts)
    opts = opts or {}
    local d = get_dap()
    if not d then
        vim.notify("[orchlaunch] nvim-dap is not installed", vim.log.levels.ERROR)
        return nil
    end

    session.start_session()

    local request = build_request(cfg, opts)
    local backend = backend_registry.resolve(request)
    if not backend then
        vim.notify("[orchlaunch] no debug backend available", vim.log.levels.ERROR)
        return nil
    end

    -- A backend may take over the whole launch (non-DAP debuggers).
    if backend.run then
        return backend.run(request, d)
    end

    local adapter = backend.adapter(request)
    d.adapters[adapter.key] = d.adapters[adapter.key] or adapter.definition

    local config = (request.mode == "attach") and backend.attach(request) or backend.launch(request)
    config.type = adapter.key
    d.run(config)
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "OrchLaunchDebugStarted" })
    return config
end

function M.stop()
    local d = get_dap()
    if d and d.close then
        pcall(d.close)
    end
    session.reset()
end

function M.continue()
    local d = get_dap()
    if d and d.continue then
        d.continue()
    end
end

function M.pause()
    local d = get_dap()
    if d and d.pause then
        d.pause()
    end
end

function M.step_over()
    local d = get_dap()
    if d and d.step_over then
        d.step_over()
    end
end

function M.step_in()
    local d = get_dap()
    if d and d.step_into then
        d.step_into()
    end
end

function M.step_out()
    local d = get_dap()
    if d and d.step_out then
        d.step_out()
    end
end

function M.restart()
    local d = get_dap()
    if d and d.restart then
        d.restart()
    end
end

--- @return string[] Registered backend names.
function M.backends()
    return backend_registry.list()
end

M.threads = session.threads
M.current_thread = session.current_thread
M.frames = session.frames
M.current_frame = session.current_frame
M.scopes = session.scopes
M.variables = session.variables
M.status = session.status
M.capabilities = session.capabilities
M.supports = session.supports
M.stopped = function()
    return session.status() == "stopped"
end
M.evaluate = session.evaluate
M.subscribe = session.subscribe

return M
