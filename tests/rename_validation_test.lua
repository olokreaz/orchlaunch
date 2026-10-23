-- Rename validation: updating an item to an existing name must fail without
-- mutating the collection. Covers every named collection exposed by state.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local root = h.tempdir()
local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")

orch.create_project(root)

local function rejects(label, fn)
    local ok, err = pcall(fn)
    h.check(label, not ok and tostring(err):find("already exists", 1, true) ~= nil, tostring(err))
end

local function toolchain(name)
    return config.toolchain({
        name = name,
        type = "system",
        cmake = "cmake",
        c = "cc",
        cxx = "c++",
        debugger = "gdb",
    })
end

-- Run configurations
state.add_configuration(config.native({ name = "Game", target = "game" }))
state.add_configuration(config.remote_debug({ name = "Attach", symbol = "game", connection = "localhost:1234" }))
rejects("configuration rename to an existing name is rejected", function()
    state.update_configuration("Game", config.native({ name = "Attach", target = "game" }))
end)
h.eq("configuration count is unchanged", #state.run_configurations().configurations, 2)
h.eq("existing configuration is untouched", state.configuration("Attach").type, "remote-debug")
state.update_configuration("Game", config.native({ name = "Game 2", target = "game" }))
h.check("valid configuration rename still works", state.configuration("Game 2") ~= nil and state.configuration("Game") == nil)

-- Toolchains
state.add_toolchain(toolchain("Gcc"))
state.add_toolchain(toolchain("Clang"))
rejects("toolchain rename to an existing name is rejected", function()
    state.update_toolchain("Gcc", toolchain("Clang"))
end)
h.eq("toolchain count is unchanged", #state.toolchains().toolchains, 2)
state.update_toolchain("Gcc", toolchain("Gcc 2"))
h.check("valid toolchain rename still works", state.toolchain("Gcc 2") ~= nil and state.toolchain("Gcc") == nil)

-- External tools
state.add_external_tool(config.external_tool({ name = "gen", program = "gen" }))
state.add_external_tool(config.external_tool({ name = "fmt", program = "fmt" }))
rejects("external tool rename to an existing name is rejected", function()
    state.update_external_tool("gen", config.external_tool({ name = "fmt", program = "gen" }))
end)
h.eq("external tool count is unchanged", #state.external_tools().tools, 2)
state.update_external_tool("gen", config.external_tool({ name = "gen 2", program = "gen" }))
h.check("valid external tool rename still works", state.external_tool("gen 2") ~= nil and state.external_tool("gen") == nil)

-- CMake profiles
state.add_cmake_profile(config.cmake_settings({ name = "Debug", build_type = "Debug" }))
state.add_cmake_profile(config.cmake_settings({ name = "Release", build_type = "Release" }))
rejects("CMake profile rename to an existing name is rejected", function()
    state.update_cmake_profile("Debug", config.cmake_settings({ name = "Release", build_type = "Debug" }))
end)
h.eq("CMake profile count is unchanged", #state.cmake_profiles(), 2)
state.update_cmake_profile("Debug", config.cmake_settings({ name = "Debug 2", build_type = "Debug" }))
h.check("valid CMake profile rename still works", state.cmake_profile("Debug 2") ~= nil and state.cmake_profile("Debug") == nil)

h.done("rename validation")
