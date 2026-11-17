-- Remote-debug server failures must give one readable message and no Lua
-- traceback: an unknown server name, a missing server binary, and a server
-- that starts but never listens on its port.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local server = require("orchlaunch.debug.server")

-- 1. unknown server name: the helper reports it, nothing is started
local cmd, err = server.command("nginx", 1234, "/bin/true")
h.eq("unknown server gives no command", cmd, nil)
h.check("unknown server message names the value", err and err:find("nginx", 1, true) ~= nil, tostring(err))

-- 2. missing program to run: a clear message instead of a crash
local _, no_prog = server.command("gdbserver", 1234, "")
h.check("missing program is explained", no_prog and no_prog:find("program", 1, true) ~= nil, tostring(no_prog))

-- 3. server binary not installed: start() reports it by name
local saved_path = vim.env.PATH
vim.env.PATH = ""
local handle, missing = server.start("gdbserver", 46850, "/bin/true")
vim.env.PATH = saved_path
h.eq("missing binary gives no handle", handle, nil)
h.check("missing binary is named", missing and missing:find("gdbserver", 1, true) ~= nil, tostring(missing))

-- 4. a server that never listens: wait_listening returns false, no crash
local idle_port = 46851
h.check("an unused port is not listening", not server.listening(idle_port))
h.eq("wait_listening times out cleanly", server.wait_listening(idle_port, 200), false)

h.done("remote debug server error messages")
