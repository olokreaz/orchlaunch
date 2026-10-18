-- Pluggable debug backends: registry, request normalization and DAP dispatch.
--
-- Drives `orchlaunch.debug` against a mocked nvim-dap so it asserts on the
-- adapter definitions and launch/attach configurations actually handed to dap.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local adapters = {}
local last = nil
local fake_session = { capabilities = { supportsSetVariable = true } }
local listeners = {
    after = {
        event_stopped = {},
        event_threads = {},
        event_stackTrace = {},
        event_scopes = {},
    },
}

package.loaded["dap"] = {
    adapters = adapters,
    listeners = listeners,
    session = function()
        return fake_session
    end,
    run = function(cfg)
        last = cfg
    end,
    close = function() end,
    continue = function() end,
    pause = function() end,
    step_over = function() end,
    step_into = function() end,
    step_out = function() end,
    restart = function() end,
}
package.loaded["orchlaunch.debug.session"] = nil
package.loaded["orchlaunch.debug.init"] = nil
package.loaded["orchlaunch.debug.backends"] = nil

local registry = require("orchlaunch.debug.backends")
local debug = require("orchlaunch.debug")

-- 1. registry ------------------------------------------------------------------
h.check("lldb backend registered", registry.get("lldb") ~= nil)
h.check("gdb backend registered", registry.get("gdb") ~= nil)
h.eq("default backend is lldb", registry.default().name, "lldb")
h.eq("two built-in backends", #registry.list(), 2)

-- 2. resolution ----------------------------------------------------------------
h.eq("resolve defaults to lldb", registry.resolve({}).name, "lldb")
h.eq("resolve by adapter name", registry.resolve({ adapter = "gdb" }).name, "gdb")
h.eq("resolve by kind", registry.resolve({ kind = "lldb" }).name, "lldb")
h.eq("unknown adapter falls back to default", registry.resolve({ adapter = "weird" }).name, "lldb")
h.eq("adapter path falls back to default", registry.resolve({ adapter = "/usr/bin/lldb-dap" }).name, "lldb")
h.eq("explicit backend wins", registry.resolve({ backend = "gdb", adapter = "lldb" }).name, "gdb")

-- 3. launch through the default (lldb) backend ---------------------------------
debug.start({ name = "Game" }, { type = "launch", program = "/bin/echo", args = { "hi" } })
h.eq("launch request", last.request, "launch")
h.eq("launch adapter type", last.type, "lldb-dap")
h.eq("launch program", last.program, "/bin/echo")
h.eq("launch args", last.args[1], "hi")
h.check("lldb-dap adapter installed", adapters["lldb-dap"] ~= nil)

-- 4. attach selects the configured adapter -------------------------------------
last = nil
debug.start(
    { name = "Attach", connection = "localhost:1234", adapter = "gdb", symbol = "app" },
    { type = "attach" }
)
h.eq("attach request", last.request, "attach")
h.eq("attach adapter type", last.type, "gdb")
h.eq("attach host", last.host, "localhost")
h.eq("attach port", last.port, 1234)
h.eq("attach program from symbol", last.program, "app")
h.eq("gdb adapter args", adapters["gdb"].args[1], "--interpreter=dap")

-- 5. an adapter given as a path uses the default backend executable -------------
adapters["lldb-dap"] = nil
last = nil
debug.start({ name = "Custom" }, { type = "launch", program = "p", adapter = "/opt/mydap" })
h.eq("custom path keeps the default backend", last.type, "lldb-dap")
h.eq("custom path is honored", adapters["lldb-dap"].command, "/opt/mydap")

-- 6. capability negotiation ----------------------------------------------------
h.check("capabilities exposed", debug.capabilities().supportsSetVariable == true)
h.check("supports() true", debug.supports("supportsSetVariable") == true)
h.check("supports() false", debug.supports("supportsSetBreakpoints") == false)

h.done("debug backend registry")
