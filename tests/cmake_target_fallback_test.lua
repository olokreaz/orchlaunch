-- Integration test: `load_targets` keeps serving the last File API reply when a
-- reconfigure fails, so targets stay available (e.g. a missing toolchain).
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
project(fallback C)
add_executable(hello main.c)
]])
write(root .. "/main.c", "int main(void){return 0;}\n")

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local cmake = require("orchlaunch.cmake")

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

local targets = cmake.load_targets()
check("initial load discovers targets", targets ~= nil and #targets >= 1)

-- Force the next configure to fail while a valid reply is already present.
state.set_cmake_settings(config.cmake_settings({
    toolchain = "Gcc",
    generator = "Ninja",
    configure_args = { "--definitely-not-a-cmake-flag" },
}))
state.save()

local fallback, result = cmake.load_targets()
check("reconfigure failure reported", result ~= nil and result.code ~= 0, result and result.code)
check("fallback returns cached targets", fallback ~= nil and #fallback >= 1)
check("fallback caches targets", cmake.targets() ~= nil and #cmake.targets() >= 1)

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURE(S)"))
if failures > 0 then
    os.exit(1)
end
