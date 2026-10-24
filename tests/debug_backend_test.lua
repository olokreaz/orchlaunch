-- Pluggable debug backends: registry, resolution and request normalization.
--
-- These are pure functions — turning a backend-neutral request into a DAP
-- configuration and an adapter definition. No nvim-dap (and no adapter) is
-- involved here: the real adapters are exercised by the e2e debug tests, so
-- this file only pins down the request shapes they must receive.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local registry = require("orchlaunch.debug.backends")

local lldb = registry.get("lldb")
local gdb = registry.get("gdb")

-- 1. registry ------------------------------------------------------------------
h.check("lldb backend registered", lldb ~= nil)
h.check("gdb backend registered", gdb ~= nil)
h.eq("default backend is lldb", registry.default().name, "lldb")
h.eq("two built-in backends", #registry.list(), 2)

-- 2. resolution ----------------------------------------------------------------
h.eq("resolve defaults to lldb", registry.resolve({}).name, "lldb")
h.eq("resolve by adapter name", registry.resolve({ adapter = "gdb" }).name, "gdb")
h.eq("resolve by kind", registry.resolve({ kind = "lldb" }).name, "lldb")
h.eq("unknown adapter falls back to default", registry.resolve({ adapter = "weird" }).name, "lldb")
h.eq("lldb adapter path resolves to lldb", registry.resolve({ adapter = "/usr/bin/lldb-dap" }).name, "lldb")
h.eq("gdb adapter path resolves to gdb", registry.resolve({ adapter = "/usr/bin/gdb" }).name, "gdb")
h.eq("unknown adapter path falls back to default", registry.resolve({ adapter = "/opt/mydap" }).name, "lldb")
h.eq("explicit backend wins", registry.resolve({ backend = "gdb", adapter = "lldb" }).name, "gdb")

-- 3. adapter definitions -------------------------------------------------------
local lldb_adapter = lldb.adapter({})
h.eq("lldb adapter key", lldb_adapter.key, "lldb-dap")
h.eq("lldb adapter kind", lldb_adapter.definition.type, "executable")

local gdb_adapter = gdb.adapter({})
h.eq("gdb adapter key", gdb_adapter.key, "gdb")
h.eq("gdb adapter command", gdb_adapter.definition.command, "gdb")
h.eq("gdb adapter args", gdb_adapter.definition.args[1], "--interpreter=dap")

h.eq("custom lldb-dap path honored", lldb.adapter({ dap_path = "/opt/mydap" }).definition.command, "/opt/mydap")

-- 4. launch request ------------------------------------------------------------
local launch = lldb.launch({ name = "Game", program = "/bin/echo", args = { "hi" }, cwd = "/tmp" })
h.eq("launch request", launch.request, "launch")
h.eq("launch name", launch.name, "Game")
h.eq("launch program", launch.program, "/bin/echo")
h.eq("launch args", launch.args[1], "hi")
h.eq("launch cwd", launch.cwd, "/tmp")

-- 5. attach request ------------------------------------------------------------
-- lldb-dap describes a remote target with gdb-remote-hostname/gdb-remote-port
-- and rejects the generic host/port pair.
local lldb_attach = lldb.attach({ name = "Attach", connection = "localhost:1234", program = "app" })
h.eq("lldb attach request", lldb_attach.request, "attach")
h.eq("lldb attach remote port", lldb_attach["gdb-remote-port"], 1234)
h.eq("lldb attach remote host", lldb_attach["gdb-remote-hostname"], "localhost")
h.eq("lldb attach program", lldb_attach.program, "app")
h.check("lldb attach has no generic host/port", lldb_attach.host == nil and lldb_attach.port == nil)

local lldb_pid = lldb.attach({ name = "PID", pid = 4242, program = "app" })
h.eq("lldb attach pid", lldb_pid.pid, 4242)
h.check("lldb attach pid has no remote port", lldb_pid["gdb-remote-port"] == nil)

local gdb_attach = gdb.attach({ name = "Attach", connection = "localhost:9000", program = "app" })
h.eq("gdb attach request", gdb_attach.request, "attach")
h.eq("gdb attach host", gdb_attach.host, "localhost")
h.eq("gdb attach port", gdb_attach.port, 9000)
h.eq("gdb attach program", gdb_attach.program, "app")

h.done("debug backend registry")
