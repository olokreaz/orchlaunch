-- Real debugger-panel end-to-end test.
--
-- This drives the actual `lldb-dap` adapter: it compiles a real C++ program,
-- sets a breakpoint before a printf, starts a real session and opens the
-- fibrous debugger panel *on top of it*. The assertions read the panel's
-- rendered buffer, so they only pass if the adapter, the neutral session and
-- the UI all work together for real — no mocks anywhere. The buttons
-- themselves are exercised by e2e_debug_controls_test.lua.
-- Skips cleanly without clang++/lldb-dap/fibrous.

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
for _, tool in ipairs({ "clang++", "lldb-dap" }) do
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
    print("SKIP  real debugger panel e2e: missing " .. table.concat(missing, ", "))
    h.done("real debugger panel e2e (skipped)")
    return
end

vim.opt.rtp:append(dap_root)
require("dap")

vim.o.columns = 160
vim.o.lines = 44

local root = h.tempdir()
h.write(root .. "/prog.cpp", [[
#include <cstdio>
#include <map>
#include <string>
#include <vector>

int compute(int base) {
    int i = 42;
    float f = 3.5f;
    const char* cstr = "hello";
    std::string str = "world";
    std::vector<int> vec = {1, 2, 3};
    std::map<std::string, int> m = {{"a", 1}, {"b", 2}};
    int total = i + static_cast<int>(f) + cstr[0]
        + static_cast<int>(str.size()) + static_cast<int>(vec.size()) + static_cast<int>(m.size());
    std::printf("total=%d base=%d\n", total, base);
    return total;
}

int main() {
    int result = compute(7);
    std::printf("done=%d\n", result);
    return 0;
}
]])

local exe = root .. "/prog"
local compiled = vim.fn.system({ "clang++", "-g", "-O0", "-o", exe, root .. "/prog.cpp" })
h.eq("program compiles", vim.v.shell_error, 0, compiled)

local printf_line
for n, line in ipairs(vim.fn.readfile(root .. "/prog.cpp")) do
    if line:find('std::printf("total', 1, true) then
        printf_line = n
    end
end

local breakpoints = require("dap.breakpoints")
local bufnr = vim.fn.bufadd(root .. "/prog.cpp")
vim.fn.bufload(bufnr)
breakpoints.set({}, bufnr, printf_line)

local dbg = require("orchlaunch.debug")
dbg.start(nil, { type = "launch", name = "panel", program = exe, cwd = root })

local function wait_for(pred, ms)
    return vim.wait(ms or 20000, pred, 25)
end

h.check("real session stops at the breakpoint", wait_for(function()
    return dbg.status() == "stopped"
end), dbg.status())
wait_for(function()
    return #dbg.frames() > 0 and #dbg.scopes() > 0
end)

-- The panel must render the *real* session.
local panel = require("orchlaunch.ui.fibrous.debugger")
local handle = panel.open()
h.check("panel mounted", handle ~= nil and vim.api.nvim_win_is_valid(handle.winid))
if not handle then
    dbg.stop()
    h.done("real debugger panel e2e")
    return
end

local function screen()
    return table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
end

-- Variables load asynchronously, so wait for the panel to show them.
wait_for(function()
    return screen():find("i = 42", 1, true) ~= nil
end, 10000)

local text = screen()
h.contains("status title", text, "Debug — stopped")
h.contains("threads section", text, "Threads")
h.contains("frames section", text, "Frames")
h.contains("scopes section", text, "Scopes")
h.contains("variables section", text, "Variables")
h.contains("controls rendered", text, "Step Over")
h.contains("real frame rendered", text, "compute")
h.contains("real frame location", text, "prog.cpp:" .. printf_line)
h.contains("real scope rendered", text, "Locals")
h.contains("int variable rendered", text, "i = 42")
h.contains("float variable rendered", text, "f = 3.5")
h.contains("char* variable rendered", text, "cstr = ")
h.contains("std::string rendered", text, 'str = "world"')
h.contains("std::vector rendered", text, "vec = ")
h.contains("std::map rendered", text, "m = ")

panel.close()
dbg.stop()
wait_for(function()
    return dbg.status() == "exited"
end, 5000)

h.done("real debugger panel e2e (lldb + clang++ + fibrous)")
