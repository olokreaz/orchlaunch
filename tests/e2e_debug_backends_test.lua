-- Real debug-backend matrix: every bundled backend is exercised against its
-- actual adapter (lldb-dap and gdb --interpreter=dap). No mocks: a real program
-- is compiled, a breakpoint is set before a printf and the session must stop
-- there with the local variables visible.
--
-- Skips per backend when the adapter executable is not installed.

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

if vim.fn.exepath("clang++") == "" or not dap_root then
    print("SKIP  real debug backends: need clang++ and nvim-dap")
    h.done("real debug backends (skipped)")
    return
end

vim.opt.rtp:append(dap_root)
require("dap")

local root = h.tempdir()
h.write(root .. "/prog.cpp", [[
#include <cstdio>
#include <string>

int main() {
    int i = 42;
    std::string s = "hi";
    std::printf("i=%d s=%s\n", i, s.c_str());
    return 0;
}
]])

local printf_line
for n, line in ipairs(vim.fn.readfile(root .. "/prog.cpp")) do
    if line:find("std::printf", 1, true) then
        printf_line = n
    end
end

local breakpoints = require("dap.breakpoints")
local bufnr = vim.fn.bufadd(root .. "/prog.cpp")
vim.fn.bufload(bufnr)
breakpoints.set({}, bufnr, printf_line)

local dbg = require("orchlaunch.debug")

local backends = {
    { name = "lldb", adapter = "lldb", available = vim.fn.exepath("lldb-dap") ~= "" or vim.fn.exepath("lldb-vscode") ~= "" },
    { name = "gdb", adapter = "gdb", available = vim.fn.exepath("gdb") ~= "" },
}

local function wait_for(pred, ms)
    return vim.wait(ms or 20000, pred, 25)
end

for _, backend in ipairs(backends) do
    if not backend.available then
        print("SKIP  " .. backend.name .. ": adapter not installed")
    else
        local exe = root .. "/" .. backend.name .. "-prog"
        local compiled = vim.fn.system({ "clang++", "-g", "-O0", "-o", exe, root .. "/prog.cpp" })
        h.eq(backend.name .. ": program compiles", vim.v.shell_error, 0, compiled)

        local config = dbg.start(nil, {
            type = "launch",
            adapter = backend.adapter,
            name = backend.name,
            program = exe,
            cwd = root,
        })
        local expected_key = backend.adapter == "gdb" and "gdb" or "lldb-dap"
        h.eq(backend.name .. ": backend key", config and config.type, expected_key)

        h.check(backend.name .. ": stops at the breakpoint", wait_for(function()
            return dbg.status() == "stopped"
        end), dbg.status())
        wait_for(function()
            return #dbg.frames() > 0 and #dbg.scopes() > 0
        end)

        local frame = dbg.current_frame()
        h.eq(backend.name .. ": frame line", frame and frame.line, printf_line)

        local locals
        for _, scope in ipairs(dbg.scopes()) do
            if scope.name == "Locals" then
                locals = scope
            end
        end
        local value = nil
        if locals then
            dbg.variables(locals.variablesReference)
            wait_for(function()
                return #dbg.variables(locals.variablesReference) > 0
            end)
            for _, v in ipairs(dbg.variables(locals.variablesReference)) do
                if v.name == "i" then
                    value = v.value
                end
            end
        end
        h.eq(backend.name .. ": int variable visible", value, "42")

        dbg.stop()
        wait_for(function()
            return dbg.status() == "exited"
        end, 5000)
    end
end

h.done("real debug backends (lldb + gdb)")
