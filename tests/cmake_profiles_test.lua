local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
require("harness")

local function write(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
end

local function read(path)
    local f = assert(io.open(path, "r"))
    local c = f:read("*a")
    f:close()
    return c
end

local root = vim.fn.tempname()
vim.fn.delete(root, "rf")
vim.fn.mkdir(root .. "/.orch", "p")

local function fail(msg)
    error("FAIL: " .. msg, 2)
end

local function eq(a, b, msg)
    if a ~= b then
        fail(("%s (got %s, want %s)"):format(msg, vim.inspect(a), vim.inspect(b)))
    end
end

-- New project
local orch = require("orchlaunch")
orch.create_project(root)

local state = require("orchlaunch.state")
local config = require("orchlaunch.config")

state.add_toolchain(config.toolchain({ name = "Gcc", type = "system", cmake = "cmake", c = "gcc", cxx = "g++", debugger = "gdb" }))

state.add_cmake_profile(config.cmake_settings({ name = "Debug", toolchain = "Gcc", build_type = "Debug", build_dir = "build/debug", definitions = { FOO = "1" }, configure_args = { "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON" } }))
state.add_cmake_profile(config.cmake_settings({ name = "Release", toolchain = "Gcc", build_type = "Release", build_dir = "build/release" }))

eq(state.active_cmake_profile(), "Debug", "first profile becomes active")
state.set_active_cmake_profile("Release")
eq(state.active_cmake_profile(), "Release", "active switched")
eq(state.cmake_settings().build_type, "Release", "cmake_settings returns active profile")
eq(#state.cmake_profiles(), 2, "two profiles")

state.save()

-- File is valid JSON and shaped correctly
local parsed = vim.json.decode(read(root .. "/.orch/cmake_settings.json"))
assert(parsed.cmake, "cmake table present")
eq(parsed.cmake.active, "Release", "active persisted")
eq(#parsed.cmake.profiles, 2, "profiles persisted")
eq(parsed.cmake.profiles[1].name, "Debug", "profile order preserved")
eq(parsed.cmake.profiles[1].definitions.FOO, "1", "definitions persisted")
eq(parsed.cmake.profiles[1].configure_args[1], "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON", "args persisted")

-- Reload re-reads from disk
state.reload()
eq(state.active_cmake_profile(), "Release", "active after reload")
eq(#state.cmake_profiles(), 2, "profiles after reload")
eq(state.cmake_profile("Debug").build_type, "Debug", "profile after reload")

-- cmake.binary_dir honors the active profile
local cmake = require("orchlaunch.cmake")
eq(cmake.binary_dir(), root .. "/.orch/build/release", "binary_dir uses active profile build_dir")

state.set_active_cmake_profile("Debug")
eq(cmake.binary_dir(), root .. "/.orch/build/debug", "binary_dir follows active switch")

-- Rename a profile
state.update_cmake_profile("Release", config.cmake_settings({ name = "RelWithDebInfo", toolchain = "Gcc", build_type = "RelWithDebInfo" }))
eq(state.cmake_profile("RelWithDebInfo") ~= nil, true, "renamed profile exists")
eq(state.cmake_profile("Release"), nil, "old name gone")

-- Remove active profile -> active falls back
state.set_active_cmake_profile("RelWithDebInfo")
state.remove_cmake_profile("RelWithDebInfo")
eq(state.active_cmake_profile(), "Debug", "active falls back after removal")

-- Legacy migration
local legacy_root = vim.fn.tempname()
vim.fn.delete(legacy_root, "rf")
vim.fn.mkdir(legacy_root .. "/.orch", "p")
write(legacy_root .. "/.orch/cmake_settings.json", '{"cmake":{"toolchain":"Gcc","build_dir":"build","generator":"Ninja"}}')
state.setup(legacy_root)
eq(#state.cmake_profiles(), 1, "legacy wrapped into one profile")
eq(state.active_cmake_profile(), "Default", "legacy profile named Default")
eq(state.cmake_settings().generator, "Ninja", "legacy field preserved")
local migrated = require("orchlaunch.cmake").binary_dir()
eq(migrated, legacy_root .. "/.orch/build", "legacy binary_dir")

print("ALL PASS: cmake profiles")
