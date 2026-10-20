-- Integration test: loading CMake targets auto-creates native run
-- configurations for executables and libraries (cwd = build dir), without
-- duplicates. Libraries keep an empty executable and record their runtime.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
require("harness")

local failures = 0
local function check(name, ok, err)
    if ok then
        print("PASS  " .. name)
    else
        failures = failures + 1
        print("FAIL  " .. name .. "  " .. tostring(err))
    end
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local function write(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
end

write(root .. "/CMakeLists.txt", [[
cmake_minimum_required(VERSION 3.15)
project(autorun C)
add_executable(hello main.c)
add_library(greet STATIC greet.c)
add_library(shared SHARED greet.c)
]])
write(root .. "/main.c", "int main(void){return 0;}\n")
write(root .. "/greet.c", "int greet(void){return 0;}\n")

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local cmake = require("orchlaunch.cmake")
local runner = require("orchlaunch.runner")

orch.create_project(root)
state.add_toolchain(config.toolchain({
    name = "Gcc",
    type = "system",
    cmake = "cmake",
    c = "gcc",
    cxx = "g++",
    debugger = "gdb",
}))
state.set_cmake_settings(config.cmake_settings({ toolchain = "Gcc", generator = "Ninja" }))
state.save()

local targets = runner.load_cmake()
check("load_cmake returns targets", targets ~= nil)

local hello = state.configuration("hello")
check("executable target creates a run configuration", hello ~= nil)
check("configuration is native", hello ~= nil and hello.type == "native", hello and hello.type)
check("configuration targets the target name", hello ~= nil and hello.target == "hello", hello and hello.target)
check("cwd is the build dir", hello ~= nil and hello.cwd == cmake.binary_dir(), hello and hello.cwd)

local static = state.configuration("greet")
check("static library creates a run configuration", static ~= nil)
check("static runtime recorded", static ~= nil and static.runtime == "static", static and static.runtime)
check("static has no executable", static ~= nil and static.target == nil, static and tostring(static.target))

local shared = state.configuration("shared")
check("shared library creates a run configuration", shared ~= nil)
check("shared runtime recorded", shared ~= nil and shared.runtime == "shared", shared and shared.runtime)
check("shared has no executable", shared ~= nil and shared.target == nil, shared and tostring(shared.target))

local count = #state.run_configurations().configurations
runner.load_cmake()
check("reloading does not duplicate configurations", #state.run_configurations().configurations == count, count)

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURE(S)"))
if failures > 0 then
    os.exit(1)
end
