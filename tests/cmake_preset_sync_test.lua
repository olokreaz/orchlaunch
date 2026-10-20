local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
require("harness")

local function write(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
end

local function eq(a, b, msg)
    if vim.inspect(a) ~= vim.inspect(b) then
        error(("FAIL: %s (got %s, want %s)"):format(msg, vim.inspect(a), vim.inspect(b)), 2)
    end
    print("PASS  " .. msg)
end

local root = vim.fn.tempname()
vim.fn.delete(root, "rf")
vim.fn.mkdir(root, "p")
write(root .. "/CMakePresets.json", [[
{
  "version": 6,
  "configurePresets": [
    { "name": "debug", "generator": "Ninja", "binaryDir": "${sourceDir}/build/debug", "cacheVariables": { "CMAKE_BUILD_TYPE": "Debug" } },
    { "name": "release", "generator": "Ninja", "binaryDir": "${sourceDir}/build/release" },
    { "name": "hidden-base", "hidden": true }
  ],
  "buildPresets": [
    { "name": "debug-build", "configurePreset": "debug", "configuration": "Debug" },
    { "name": "release-build", "configurePreset": "release" }
  ]
}
]])

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local cmake = require("orchlaunch.cmake")

orch.create_project(root)

-- Import presets
local added = state.sync_cmake_profiles()
eq(added, 4, "imported 4 profiles (2 configure + 2 build)")
eq(#state.cmake_profiles(), 4, "four profiles")

local debug = state.cmake_profile("debug")
eq(debug.kind, "configure", "debug is a configure profile")
eq(debug.configure_preset, "debug", "configure preset set")

local debug_build = state.cmake_profile("debug-build")
eq(debug_build.kind, "build", "debug-build is a build profile")
eq(debug_build.build_preset, "debug-build", "build preset set")
eq(debug_build.configure_preset, "debug", "build profile knows its configure preset")

-- Second import adds nothing
eq(state.sync_cmake_profiles(), 0, "second import is a no-op")

-- Imported profiles stay inert until one is marked active
eq(state.active_cmake_profile(), nil, "nothing active right after import")
eq(state.cmake_settings(), {}, "no active profile -> empty settings")

-- Set active
state.set_active_cmake_profile("debug")
eq(state.cmake_settings().name, "debug", "active profile becomes effective")
eq(cmake.binary_dir(), root .. "/build/debug", "binary_dir from configure preset")

-- Switching the active profile
state.set_active_cmake_profile("release")
eq(state.active_cmake_profile(), "release", "active switched")
eq(cmake.binary_dir(), root .. "/build/release", "binary_dir follows active")

-- Save / reload keeps kind and the active marker
state.save()
state.reload()
eq(state.cmake_profile("debug").kind, "configure", "kind persisted")
eq(state.active_cmake_profile(), "release", "active persisted")

-- Preset-derived profiles are read-only: they are imported from the preset
-- JSON files and cannot be edited (or created) through the editor.
local notifications = {}
vim.notify = function(msg)
    notifications[#notifications + 1] = tostring(msg)
end

if not (pcall(require, "fibrous")) then
    print("SKIP  preset profile editor (fibrous is not installed)")
else
    local editor = require("orchlaunch.ui.fibrous.cmake_profile")
    local closed = false
    local popup = editor.open(state.cmake_profile("debug"), function()
        closed = true
    end)
    vim.wait(150)

    eq(popup ~= nil and popup.orch ~= nil, true, "preset editor renders")
    eq(popup.orch.readonly, true, "preset profile is read-only")

    local fields = {}
    for _, field in ipairs(popup.orch.fields or {}) do
        fields[field.id] = true
    end

    eq(fields.kind, true, "preset profile shows source")
    eq(fields.configure_preset, true, "preset profile shows configure preset")
    eq(fields.toolchain, nil, "preset profile hides toolchain")

    local count = #notifications
    popup.orch.save()
    vim.wait(50)
    eq(#notifications > count, true, "preset profile save rejected")

    popup.orch.close()
    vim.wait(50)
    eq(closed, true, "preset profile close callback fired")
end

state.reload()
local reloaded = state.cmake_profile("debug")
eq(reloaded.kind, "configure", "kind survives reload")
eq(reloaded.configure_preset, "debug", "configure preset survives reload")

print("\nALL PASS: preset sync")
