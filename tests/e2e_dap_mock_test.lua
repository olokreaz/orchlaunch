-- DAP mock test: verify our debug overlay (launch/attach + state API) works with mocked dap
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local last_cfg = nil
local events = { after = { event_stopped = {}, event_threads = {}, event_stackTrace = {}, event_scopes = {}, event_variables = {} } }
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
