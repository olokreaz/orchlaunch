-- Stepping through a plugin-managed remote session: Step In enters a function,
-- Step Out returns to the caller. The breakpoint sits on the call in main().
--
-- With `server = "lldb-server"` and `program`, the plugin starts the server
-- itself, waits until it listens, attaches, and stops it when the session ends.
-- No manual `lldb-server` is involved. Skips cleanly without the toolchain.

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
for _, tool in ipairs({ "clang++", "lldb-server", "lldb-dap" }) do
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
    print("SKIP  remote debug server e2e: missing " .. table.concat(missing, ", "))
    h.done("remote debug server e2e (skipped)")
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
    if line:find("tick(i);", 1, true) then
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
local port = 46200 + (vim.fn.getpid() % 500)

orch.create_project(root)
breakpoints.set({}, bufnr, tick_line)
state.add_toolchain(config.toolchain({ name = "Clang", type = "system", cmake = "cmake", c = "clang", cxx = "clang++", debugger = "lldb" }))
state.add_configuration(config.remote_debug({
    name = "managed",
    symbol = "${workspace}/prog",
    connection = "localhost:" .. port,
    adapter = "lldb",
    server = "lldb-server",
}))
state.save()

runner.run("managed", { mode = "debug" })

local function wait_for(pred, ms)
    return vim.wait(ms or 20000, pred, 25)
end

h.check("plugin starts the server and it listens", wait_for(function()
    return port_listening(port)
end, 10000), port)

h.check("attached session stops at the call in main", wait_for(function()
    return dbg.status() == "stopped" and dbg.current_frame() ~= nil and dbg.current_frame().line == tick_line
end, 25000), (dbg.current_frame() or {}).line)

-- Step In: enter tick(), stop on its first body line (`sink += n;`).
local tick_body_line
for n, line in ipairs(vim.fn.readfile(root .. "/prog.cpp")) do
    if line:find("sink += n", 1, true) then
        tick_body_line = n
    end
end
dbg.step_in()
h.check("step in enters tick()", wait_for(function()
    local f = dbg.current_frame()
    return dbg.status() == "stopped" and f ~= nil and (f.name or ""):find("tick", 1, true) ~= nil
end, 15000), (dbg.current_frame() or {}).name)
h.eq("step in stops on tick()'s first body line", (dbg.current_frame() or {}).line, tick_body_line)

-- Step Out: back in main, on the call line.
dbg.step_out()
h.check("step out returns to main", wait_for(function()
    local f = dbg.current_frame()
    return dbg.status() == "stopped" and f ~= nil and f.name == "main"
end, 15000), (dbg.current_frame() or {}).name)

dbg.stop()
h.check("stopping the session stops the server too", wait_for(function()
    return not port_listening(port)
end, 8000))

h.done("remote debug steps (step in, step out) with a plugin-managed lldb-server")
