-- Remote-debug configuration with the gdb adapter and a plugin-managed gdbserver.
--
-- The plugin starts `gdbserver`, attaches gdb through the DAP `target` field,
-- and stops at a breakpoint. The session is then ended by nvim-dap itself
-- (disconnect), not through `debug.stop()`, and the managed server must stop
-- too. Skips cleanly without the toolchain.

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
    for _, root in ipairs(roots) do
        if vim.fn.isdirectory(root .. "/nvim-dap") == 1 then
            dap_root = root .. "/nvim-dap"
            break
        end
    end
end

local missing = {}
for _, tool in ipairs({ "clang++", "gdbserver", "gdb" }) do
    if vim.fn.exepath(tool) == "" then
        missing[#missing + 1] = tool
    end
end
if not dap_root then
    missing[#missing + 1] = "nvim-dap"
end
if not (pcall(require, "fibrous")) then
    missing[#missing + 1] = "fibrous"
end
if #missing > 0 then
    print("SKIP  gdb remote server e2e: missing " .. table.concat(missing, ", "))
    h.done("gdb remote server e2e (skipped)")
    return
end

vim.opt.rtp:append(dap_root)
require("dap")
vim.o.columns = 160
vim.o.lines = 44

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
vim.fn.sign_define("DapBreakpoint", { text = "B" })
vim.cmd("edit " .. vim.fn.fnameescape(root .. "/prog.cpp"))

local function port_listening(port)
    return require("orchlaunch.debug.server").listening(port)
end

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local runner = require("orchlaunch.runner")
local dbg = require("orchlaunch.debug")

-- A port that is not in use by another test run.
local port = 46800 + (vim.fn.getpid() % 150)

orch.create_project(root)
breakpoints.set({}, bufnr, tick_line)
state.add_toolchain(config.toolchain({ name = "Clang", type = "system", cmake = "cmake", c = "clang", cxx = "clang++", debugger = "gdb" }))
state.add_configuration(config.remote_debug({
    name = "managed-gdb-gdbserver",
    symbol = "${workspace}/prog",
    connection = "localhost:" .. port,
    adapter = "gdb",
    server = "gdbserver",
}))
state.save()

runner.run("managed-gdb-gdbserver", { mode = "debug" })

local function wait_for(pred, ms)
    return vim.wait(ms or 20000, pred, 25)
end

h.check("plugin starts gdbserver and it listens", wait_for(function()
    return port_listening(port)
end, 10000), port)

-- gdb's attach stops wherever the target is (the dynamic loader on a fresh
-- process), not at the breakpoint; continue until the breakpoint is hit.
wait_for(function()
    return dbg.status() == "stopped"
end, 10000)
if (dbg.current_frame() or {}).line ~= tick_line then
    -- Name the thread explicitly: nvim-dap's `continue()` opens an interactive
    -- thread picker when no stopped thread is focused, which blocks headless runs.
    require("dap").session():request("continue", { threadId = dbg.current_thread() or 1 }, function() end)
end

h.check("gdb attach stops at the breakpoint", wait_for(function()
    return dbg.status() == "stopped" and dbg.current_frame() ~= nil and dbg.current_frame().line == tick_line
end, 25000), (dbg.current_frame() or {}).line)

-- gdb does not send `continued`; resuming must still clear the stale stop.
require("dap.breakpoints").remove(bufnr, tick_line)
require("dap").session():request("continue", { threadId = dbg.current_thread() or 1 }, function() end)
h.check("resume after a stop reports running", wait_for(function()
    return dbg.status() == "running"
end, 5000))
h.check("resume clears the stale stack frame", dbg.current_frame() == nil)

-- End the session from nvim-dap's side, as when the adapter or client goes away.
require("dap").disconnect({ terminateDebuggee = true })

h.check("session ended by nvim-dap", wait_for(function()
    return not dbg.stopped() and dbg.status() ~= "running"
end, 10000), dbg.status())

h.check("managed gdbserver stops when the session ends on its own", wait_for(function()
    return not port_listening(port)
end, 8000))

h.done("gdb remote attach with a plugin-managed gdbserver")
