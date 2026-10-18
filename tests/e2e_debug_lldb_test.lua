-- End-to-end debug test: a real C++ CMake project built with clang/clang++ in
-- Debug *and* Release, then debugged for real through lldb-dap.
--
-- Unlike the mocked suites this spawns the actual `lldb-dap` adapter: it sets a
-- breakpoint right before a `printf`, resumes, and asserts the process really
-- stopped there with the local variables visible (int, float, char*, std::string,
-- std::vector, std::map). Skips cleanly when any of cmake/ninja/clang++/lldb-dap
-- or nvim-dap is missing, so the dependency-free suite never fails on it.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

-- nvim-dap is a runtime dependency here; locate it like the other deps.
local dap_root = nil
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
for _, tool in ipairs({ "cmake", "ninja", "clang", "clang++", "lldb-dap" }) do
    if vim.fn.exepath(tool) == "" then
        missing[#missing + 1] = tool
    end
end
if not dap_root then
    missing[#missing + 1] = "nvim-dap"
end

if #missing > 0 then
    print("SKIP  real debug e2e: missing " .. table.concat(missing, ", "))
    h.done("real debug e2e (skipped)")
    return
end

vim.opt.rtp:append(dap_root)
local dap_ok = pcall(require, "dap")
if not dap_ok then
    print("SKIP  real debug e2e: nvim-dap failed to load")
    h.done("real debug e2e (skipped)")
    return
end

local root = h.tempdir()

h.write(root .. "/CMakeLists.txt", [[
cmake_minimum_required(VERSION 3.16)
project(orch_debug CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_executable(prog prog.cpp)
]])

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

local printf_line
for n, line in ipairs(vim.fn.readfile(root .. "/prog.cpp")) do
    if line:find('std::printf("total', 1, true) then
        printf_line = n
    end
end
h.check("breakpoint target line located", printf_line ~= nil)
if not printf_line then
    h.done("real debug e2e")
    return
end

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local cmake = require("orchlaunch.cmake")
local process = require("orchlaunch.process")
local runner = require("orchlaunch.runner")

orch.create_project(root)
state.add_toolchain(config.toolchain({
    name = "Clang", type = "system", cmake = "cmake", c = "clang", cxx = "clang++", debugger = "lldb",
}))

--- Configures and builds the project in `build_type`, returning the executable.
---@param build_type "Debug" | "Release"
---@return string?
local function build(build_type)
    state.set_cmake_settings(config.cmake_settings({
        toolchain = "Clang",
        generator = "Ninja",
        build_type = build_type,
        build_dir = root .. "/build/" .. build_type:lower(),
    }))
    state.save()

    local targets = cmake.load_targets()
    h.check(build_type .. ": configure discovers prog", targets ~= nil, "load_targets returned nil")
    if not targets then
        return nil
    end

    local built = process.run(cmake.build_spec())
    h.eq(build_type .. ": build succeeds", built.code, 0, built.stderr)
    h.contains(build_type .. ": configure uses clang++", table.concat(cmake.configure_spec().args, " "), "clang++")

    local exe = cmake.find_target("prog")
    h.check(build_type .. ": executable exists", exe ~= nil and vim.fn.filereadable(exe) == 1, exe)
    if exe then
        local ran = process.run({ program = exe, cwd = root })
        h.eq(build_type .. ": executable runs", ran.code, 0, ran.stderr)
        h.contains(build_type .. ": executable output", ran.stdout, "done=")
    end
    return exe
end

local debug_exe = build("Debug")
build("Release")

-- Back to the Debug build for the actual debugging session.
state.set_cmake_settings(config.cmake_settings({
    toolchain = "Clang", generator = "Ninja", build_type = "Debug",
    build_dir = root .. "/build/debug",
}))
state.add_configuration(config.native({ name = "prog", target = "prog", cwd = cmake.binary_dir() }))
state.save()

h.eq("debug binary resolved for the session", cmake.find_target("prog"), debug_exe)

-- Breakpoint right before the printf.
local dap = require("dap")
local breakpoints = require("dap.breakpoints")
local bufnr = vim.fn.bufadd(root .. "/prog.cpp")
vim.fn.bufload(bufnr)
breakpoints.set({}, bufnr, printf_line)

local dbg = require("orchlaunch.debug")

local function wait_for(pred, ms)
    return vim.wait(ms or 20000, pred, 25)
end

runner.run("prog", { mode = "debug" })

h.check("session reaches the breakpoint", wait_for(function()
    return dbg.status() == "stopped"
end), dbg.status())

wait_for(function()
    return #dbg.frames() > 0
end)
wait_for(function()
    return #dbg.scopes() > 0
end)

h.check("adapter negotiated capabilities", next(dbg.capabilities()) ~= nil)
h.check("threads reported", #dbg.threads() > 0)

local frame = dbg.current_frame()
h.check("stopped in compute()", frame ~= nil and frame.name:find("compute", 1, true) ~= nil, frame and frame.name)
h.eq("stopped on the printf line", frame and frame.line, printf_line)
h.contains("frame source is prog.cpp", frame and frame.source and frame.source.path or "", "prog.cpp")

local locals
for _, scope in ipairs(dbg.scopes()) do
    if scope.name == "Locals" then
        locals = scope
    end
end
h.check("Locals scope present", locals ~= nil)

local vars = {}
if locals then
    dbg.variables(locals.variablesReference)
    wait_for(function()
        return #dbg.variables(locals.variablesReference) > 0
    end)
    for _, v in ipairs(dbg.variables(locals.variablesReference)) do
        vars[v.name] = v
    end
end

h.check("int variable visible", vars.i ~= nil and vars.i.value == "42", vars.i and vars.i.value)
h.check("float variable visible", vars.f ~= nil and tostring(vars.f.value):find("3.5") == 1, vars.f and vars.f.value)
h.check("char* variable visible", vars.cstr ~= nil and tostring(vars.cstr.type):find("char") ~= nil, vars.cstr and vars.cstr.type)
h.contains("char* value visible", vars.cstr and vars.cstr.value or "", "hello")
h.check("std::string visible", vars.str ~= nil and tostring(vars.str.type):find("string") ~= nil, vars.str and vars.str.type)
h.contains("std::string value visible", vars.str and vars.str.value or "", "world")
h.check("std::vector visible", vars.vec ~= nil and tostring(vars.vec.type):find("vector") ~= nil, vars.vec and vars.vec.type)
h.check("std::map visible", vars.m ~= nil and tostring(vars.m.type):find("map") ~= nil, vars.m and vars.m.type)
h.contains("argument visible", vars.base and vars.base.value or "", "7")

-- Real expression evaluation against the live frame.
local evaluated
dbg.evaluate("i + 1", function(res)
    evaluated = res
end)
h.check("evaluate returns a result", wait_for(function()
    return evaluated ~= nil
end, 5000), tostring(evaluated))
h.contains("evaluate computes i + 1", evaluated or "", "43")

-- Hammer the variable cache: repeated reads must not spawn a request storm or
-- lose the already-fetched values (regression on the in-flight dedup).
for _ = 1, 200 do
    dbg.variables(locals.variablesReference)
end
h.check("variables survive rapid repeated reads", #dbg.variables(locals.variablesReference) > 0)

-- Controls: resuming lets the process run to completion.
dbg.continue()
h.check("continue resumes and the program exits", wait_for(function()
    return dbg.status() == "exited"
end, 10000), dbg.status())

dbg.stop()
wait_for(function()
    return dbg.status() == "exited"
end, 5000)

h.done("real debug e2e (lldb + clang++)")
