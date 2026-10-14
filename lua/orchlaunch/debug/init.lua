-- OrchLaunch debug public API
local lldb = require("orchlaunch.debug.lldb")
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

function M.start(cfg, opts)
    opts = opts or {}
    local d = get_dap()
    if not d then
        vim.notify("[orchlaunch] nvim-dap is not installed", vim.log.levels.ERROR)
        return nil
    end
    session.start_session()
    local dc
    if opts.type == "attach" then
        dc = lldb.attach_remote(d, {
            kind = opts.kind or "lldb",
            dap_path = opts.dap_path,
            connection = cfg and cfg.connection or opts.connection,
            program = opts.program or (cfg and cfg.symbol),
            pid = opts.pid,
            name = cfg and cfg.name or opts.name,
        })
    else
        dc = lldb.launch_native(d, {
            kind = opts.kind or "lldb",
            dap_path = opts.dap_path,
            program = opts.program,
            args = opts.args,
            cwd = opts.cwd,
            env = opts.env,
            name = cfg.name,
        })
    end
    d.run(dc)
    return dc
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

M.threads = session.threads
M.current_thread = session.current_thread
M.frames = session.frames
M.current_frame = session.current_frame
M.scopes = session.scopes
M.variables = session.variables
M.status = session.status
M.stopped = function()
    return session.status() == "stopped"
end
M.evaluate = session.evaluate

return M
