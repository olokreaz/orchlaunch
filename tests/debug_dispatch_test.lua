-- Unit test: the run/debug dispatch builds the right DAP launch/attach config
-- for native and remote-debug configurations. nvim-dap is mocked here on
-- purpose (this only checks the request shape); the end-to-end coverage against
-- a real adapter lives in e2e_debug_lldb_test / e2e_debugger_panel_test.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local last_cfg = nil
local events = { after = { event_stopped = {}, event_continued = {}, event_terminated = {}, threads = {}, stackTrace = {}, scopes = {} } }
package.loaded["dap"] = {
    adapters = {},
    listeners = events,
    run = function(cfg) last_cfg = cfg end,
    continue = function() end,
    pause = function() end,
    step_over = function() end,
    step_into = function() end,
    step_out = function() end,
    restart = function() end,
    close = function() end,
    repl = { execute = function() end },
}

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local runner = require("orchlaunch.runner")

local root = h.tempdir()
orch.create_project(root)
state.add_configuration(config.native({ name = "Game", target = "/bin/echo" }))
state.add_configuration(config.remote_debug({ name = "Remote", connection = "localhost:9000" }))
state.save()

-- launch native
last_cfg = nil
runner.run("Game", { mode = "debug" })
h.check("dap.run called for launch", last_cfg ~= nil)
if last_cfg then
    h.eq("launch request", last_cfg.request, "launch")
    h.check("program set", last_cfg.program ~= nil)
end

-- attach remote
last_cfg = nil
runner.run("Remote", { mode = "debug" })
h.check("dap.run called for attach", last_cfg ~= nil)
if last_cfg then
    h.eq("attach request", last_cfg.request, "attach")
    h.eq("attach port", last_cfg.port, 9000)
    h.eq("attach host", last_cfg.host, "localhost")
end

h.done("dap mock overlay")
