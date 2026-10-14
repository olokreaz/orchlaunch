-- Integration test: CMake File API target discovery + target select editor.

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
project(hello C)
add_executable(hello main.c)
add_library(greet STATIC greet.c)
]])
write(root .. "/main.c", "int main(void){return 0;}\n")
write(root .. "/greet.c", "int greet(void){return 0;}\n")

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

-- 1. load targets via File API ----------------------------------------------
local targets, result = cmake.load_targets()
check("load_targets returns list", targets ~= nil, result and result.stderr)

check("hello discovered as executable", (function()
    local target = cmake.target("hello")
    return target ~= nil and target.type == "EXECUTABLE" and type(target.artifact) == "string"
end)(), vim.inspect(cmake.target("hello")))

check("greet discovered", (function()
    local target = cmake.target("greet")
    return target ~= nil and target.type == "STATIC_LIBRARY"
end)(), vim.inspect(cmake.target("greet")))

check("targets cached", type(cmake.targets()) == "table" and #cmake.targets() >= 2)

-- 2. build then resolve artifact --------------------------------------------
check("build produces artifact", (function()
    local built = require("orchlaunch.process").run(cmake.build_spec("hello"))
    if built.code ~= 0 then
        return false
    end
    local path = cmake.find_target("hello")
    return path ~= nil and vim.fn.filereadable(path) == 1
end)())

-- 3. editor target select ----------------------------------------------------
local editor = require("orchlaunch.ui.editor")
local saved = false

check("open native with target select", pcall(function()
    local renderer = editor.open_native(nil, function()
        saved = true
    end)
    vim.wait(300)

    local select = renderer:get_component_by_id("target_choice")
    assert(select ~= nil, "target_choice select missing")
    select:set_current_value({ id = "hello" })

    local name_input = renderer:get_component_by_id("name")
    name_input:set_current_value("Hello")

    assert(renderer._save, "save handler missing")
    renderer._save()
end))

check("on_saved fired", saved == true)
state.reload()
check("target persisted from select", (function()
    local cfg = state.configuration("Hello")
    return cfg ~= nil and cfg.target == "hello"
end)(), vim.inspect(state.configuration("Hello")))

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURE(S)"))
if failures > 0 then
    os.exit(1)
end
