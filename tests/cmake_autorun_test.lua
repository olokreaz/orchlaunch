-- Integration test: loading CMake targets auto-creates native run
-- configurations for executable targets (cwd = build dir), without duplicates.
vim.opt.rtp:append("/home/olokreaz/.config/nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui-components.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")

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

check("library target creates no configuration", state.configuration("greet") == nil)

local count = #state.run_configurations().configurations
runner.load_cmake()
check("reloading does not duplicate configurations", #state.run_configurations().configurations == count, count)

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURE(S)"))
if failures > 0 then
    os.exit(1)
end
