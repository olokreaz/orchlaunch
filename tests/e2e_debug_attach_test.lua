-- Real attach end-to-end test.
--
-- Starts a real `lldb-server gdbserver` for a compiled program, then drives the
-- plugin's remote-debug configuration through `runner.run(..., { mode = "debug" })`
-- — the same path a user takes. Assertions read the real session and the DAP
-- attach config handed to nvim-dap (which must use lldb-dap's gdb-remote-* pair).
--
-- Attaching to an unrelated process by pid is intentionally not tested: the
-- kernel's yama ptrace_scope usually forbids it (needs root). The gdb-remote
-- flow below works as an unprivileged user.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local dap_root
do
    local roots = {}
    if vim.env.ORCHLAUNCH_DEPS and vim.env.ORCHLAUNCH_DEPS ~= "" then
        roots[#roots + 1] = vim.env.ORCHLAUNCH_DEPS
    end
    roots[#roots + 1] = vim.fn.stdpath("data") .. "/lazy"
    roots[#roots + 1] = vim.fn.stdpath("data") .. "/site/pack/deps/start"
    roots[#roots + 1] = vim.fn.stdpath("data") .. "/site/pack/core/opt"
    for _, root in ipairs(roots) do
        if vim.fn.isdirectory(root .. "/nvim-dap") == 1 then
            dap_root = root .. "/nvim-dap"
            break
        end
    end
end

local missing = {}
for _, tool in ipairs({ "clang++", "lldb-server", "lldb-dap" }) do
    if vim.fn.exepath(tool) == "" then
        missing[#missing + 1] = tool
    end
end
if not dap_root then
    missing[#missing + 1] = "nvim-dap"
end
if #missing > 0 then
    print("SKIP  real attach e2e: missing " .. table.concat(missing, ", "))
    h.done("real attach e2e (skipped)")
    return
end

vim.opt.rtp:append(dap_root)
require("dap")

local root = h.tempdir()
h.write(root .. "/prog.cpp", [[
#include <cstdio>
#include <unistd.h>

volatile int sink;
int tick(int n) {
    sink += n;
    return sink;
}

int main() {
    for (int i = 0; i < 100000; i++) {
        tick(i);
        usleep(2000);
    }
    return 0;
}
]])

local tick_line
for n, line in ipairs(vim.fn.readfile(root .. "/prog.cpp")) do
    if line:find("sink += n", 1, true) then
        tick_line = n
    end
end

local exe = root .. "/prog"
local compiled = vim.fn.system({ "clang++", "-g", "-O0", "-o", exe, root .. "/prog.cpp" })
h.eq("program compiles", vim.v.shell_error, 0, compiled)

local breakpoints = require("dap.breakpoints")
local bufnr = vim.fn.bufadd(root .. "/prog.cpp")
vim.fn.bufload(bufnr)
breakpoints.set({}, bufnr, tick_line)

--- Whether something is listening on a TCP port (read from /proc/net/tcp), so
--- we can wait for lldb-server without stealing its single connection.
---@param port integer
---@return boolean
local function port_listening(port)
    local file = io.open("/proc/net/tcp", "r")
    if not file then
        return false
    end
    local needle = (":%04X"):format(port)
    for line in file:lines() do
        if line:find(needle, 1, true) and line:find(" 0A ", 1, true) then
            file:close()
            return true
        end
    end
    file:close()
    return false
end

local port = 45790 + (vim.fn.getpid() % 500)
local server = vim.fn.jobstart(
    { "lldb-server", "gdbserver", ":" .. port, "--", exe },
    vim.empty_dict()
)
h.check("lldb-server started", server > 0)
h.check("lldb-server is listening", vim.wait(8000, function()
    return port_listening(port)
end, 50), port)

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local runner = require("orchlaunch.runner")

orch.create_project(root)
state.add_toolchain(config.toolchain({ name = "Clang", type = "system", cmake = "cmake", c = "clang", cxx = "clang++", debugger = "lldb" }))
state.add_configuration(config.remote_debug({
    name = "attach",
    symbol = exe,
    connection = "localhost:" .. port,
    adapter = "lldb",
}))
state.save()

runner.run("attach", { mode = "debug" })

local function wait_for(pred, ms)
    return vim.wait(ms or 20000, pred, 25)
end

local dbg = require("orchlaunch.debug")

-- The attach config must use lldb-dap's gdb-remote fields, not host/port.
local session_config = require("dap").session() and require("dap").session().config
h.eq("attach request", session_config and session_config.request, "attach")
h.eq("attach remote port", session_config and session_config["gdb-remote-port"], port)
h.check("attach has no bogus host/port", session_config and session_config.port == nil and session_config.host == nil)

-- Wait for the attach to finish initializing and reach its entry stop, then
-- resume exactly once so the breakpoint in tick() fires.
h.check("attached session initializes and stops", wait_for(function()
    local s = require("dap").session()
    return s and s.initialized and s.stopped_thread_id ~= nil and dbg.status() == "stopped"
end, 20000), dbg.status())

if (require("dap").session().current_frame or {}).line ~= tick_line then
    dbg.continue()
end

h.check("breakpoint hit after attach", wait_for(function()
    local s = require("dap").session()
    return dbg.status() == "stopped" and s and s.current_frame ~= nil and s.current_frame.line == tick_line
end, 25000), (require("dap").session().current_frame or {}).line)

wait_for(function()
    return #dbg.scopes() > 0
end)

local locals
for _, scope in ipairs(dbg.scopes()) do
    if scope.name == "Locals" then
        locals = scope
    end
end
local names = {}
if locals then
    dbg.variables(locals.variablesReference)
    wait_for(function()
        return #dbg.variables(locals.variablesReference) > 0
    end)
    for _, v in ipairs(dbg.variables(locals.variablesReference)) do
        names[v.name] = true
    end
end
h.check("attached frame argument visible", names.n == true, vim.inspect(vim.tbl_keys(names)))

dbg.stop()
vim.fn.jobstop(server)
wait_for(function()
    return dbg.status() == "exited"
end, 5000)

h.done("real remote attach (lldb-server + lldb-dap)")
