-- Real conditional-breakpoint end-to-end test.
--
-- Sets a breakpoint through the project-aware `orchlaunch.breakpoints` module
-- and runs a real `lldb-dap` session. The condition (`i == 3`) must be honoured
-- by the adapter: the session stops only at that iteration, proving the module
-- and the adapter agree on the condition. Skips without the toolchain.

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
if vim.fn.exepath("clang++") == "" then
    missing[#missing + 1] = "clang++"
end
if vim.fn.exepath("lldb-dap") == "" then
    missing[#missing + 1] = "lldb-dap"
end
if not dap_root then
    missing[#missing + 1] = "nvim-dap"
end
if #missing > 0 then
    print("SKIP  real conditional breakpoint e2e: missing " .. table.concat(missing, ", "))
    h.done("real conditional breakpoint e2e (skipped)")
    return
end

vim.opt.rtp:append(dap_root)
require("dap")

local root = h.tempdir()
h.write(root .. "/prog.cpp", [[
#include <cstdio>

int seen = 0;
void tick(int i) {
    seen += i;
}
int main() {
    for (int i = 0; i < 6; i++) {
        tick(i);
    }
    std::printf("seen=%d\n", seen);
    return 0;
}
]])

local tick_line
for n, line in ipairs(vim.fn.readfile(root .. "/prog.cpp")) do
    if line:find("seen += i;", 1, true) then
        tick_line = n
    end
end

local exe = root .. "/prog"
local compiled = vim.fn.system({ "clang++", "-g", "-O0", "-o", exe, root .. "/prog.cpp" })
h.eq("program compiles", vim.v.shell_error, 0, compiled)

local orch = require("orchlaunch")
orch.create_project(root)

local breakpoints = require("orchlaunch.breakpoints")
breakpoints.set_at("prog.cpp", tick_line, { condition = "i == 3" })
local set = breakpoints.list()[1]
h.eq("conditional breakpoint set via module", set and set.condition, "i == 3")

local dbg = require("orchlaunch.debug")
dbg.start(nil, { type = "launch", name = "cond", program = exe, cwd = root })

local function wait_for(pred, ms)
    return vim.wait(ms or 20000, pred, 25)
end

h.check("session stops at the conditional breakpoint", wait_for(function()
    return dbg.status() == "stopped"
end), dbg.status())
wait_for(function()
    return #dbg.frames() > 0 and #dbg.scopes() > 0
end)

local frame = dbg.current_frame()
h.check("stopped inside tick()", frame ~= nil and (frame.name or ""):find("tick", 1, true) ~= nil, frame and frame.name)

local locals
for _, scope in ipairs(dbg.scopes()) do
    if scope.name == "Locals" then
        locals = scope
    end
end
local i_value
if locals then
    dbg.variables(locals.variablesReference)
    wait_for(function()
        return #dbg.variables(locals.variablesReference) > 0
    end)
    for _, v in ipairs(dbg.variables(locals.variablesReference)) do
        if v.name == "i" then
            i_value = v.value
        end
    end
end
h.eq("the condition was honoured (i == 3)", i_value, "3")

dbg.continue()
h.check("program runs to completion", wait_for(function()
    return dbg.status() == "exited"
end, 10000), dbg.status())

dbg.stop()

h.done("real conditional breakpoint e2e (lldb + clang++)")
