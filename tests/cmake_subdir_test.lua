-- .orch lives in the project root, but CMake source + presets live in a
-- subdirectory named by the profile's `source_dir`.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
require("harness")

local function eq(a, b, msg)
    if vim.inspect(a) ~= vim.inspect(b) then
        error(("FAIL: %s (got %s, want %s)"):format(msg, vim.inspect(a), vim.inspect(b)), 2)
    end
    print("PASS  " .. msg)
end

local function write(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
end

local root = vim.fn.tempname()
vim.fn.delete(root, "rf")
vim.fn.mkdir(root .. "/boo", "p")

write(root .. "/boo/CMakeLists.txt", "cmake_minimum_required(VERSION 3.15)\nproject(demo C)\n")
write(root .. "/boo/CMakePresets.json", [[
{
  "version": 6,
  "configurePresets": [
    { "name": "boo-debug", "generator": "Ninja", "binaryDir": "${sourceDir}/build/debug" }
  ]
}
]])

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local cmake = require("orchlaunch.cmake")

orch.create_project(root)
state.add_toolchain(config.toolchain({ name = "Gcc", type = "system", cmake = "cmake", c = "gcc", cxx = "g++", debugger = "gdb" }))

state.add_cmake_profile({
    name = "Boo",
    enabled = true,
    configure_preset = "boo-debug",
})
state.set_active_cmake_profile("Boo")
state.set_cmake_source_dir("${workspace}/boo")
state.save()

eq(state.cmake_source_dir(), root .. "/boo", "source_dir resolves under the workspace")
eq(cmake.source_dir(), root .. "/boo", "cmake source dir follows the profile")

local discovered = state.presets()
assert(discovered, "presets discovered from the subdirectory")
eq(discovered.configure[1].name, "boo-debug", "preset comes from the subdirectory")

eq(cmake.binary_dir(), root .. "/boo/build/debug", "binaryDir is relative to the subdirectory")

local spec = cmake.configure_spec()
eq(spec.cwd, root .. "/boo", "configure runs in the subdirectory")
eq(spec.program, "cmake", "cmake program")
eq(spec.args[1], "--preset", "configure uses --preset")
eq(spec.args[2], "boo-debug", "configure uses the subdirectory preset")

eq(state.sync_cmake_profiles(), 1, "import sees the subdirectory preset")

state.reload()
eq(state.cmake_source_dir_raw(), "${workspace}/boo", "source_dir persists at [cmake] level")
eq(state.cmake_profile("Boo").source_dir, nil, "profile no longer carries source_dir")

state.set_runtime("cmake_targets", { { name = "demo" } })
state.set_runtime("cmake_source_dir", root .. "/boo")
assert(cmake.targets() ~= nil, "targets visible for the loaded CMake project")
state.set_cmake_source_dir("${workspace}")
eq(cmake.targets(), nil, "changing the CMake project drops stale targets")

print("\nALL PASS: subdirectory source")
