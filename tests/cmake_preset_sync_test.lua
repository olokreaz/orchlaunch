vim.opt.rtp:append("/home/olokreaz/.config/nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui-components.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")
vim.opt.rtp:append("/home/olokreaz/.config/nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui-components.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")

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

local root = "/tmp/opencode/orch_proj_sync"
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
eq(debug.enabled, false, "imported profile is disabled by default")
eq(debug.configure_preset, "debug", "configure preset set")

local debug_build = state.cmake_profile("debug-build")
eq(debug_build.kind, "build", "debug-build is a build profile")
eq(debug_build.build_preset, "debug-build", "build preset set")
eq(debug_build.configure_preset, "debug", "build profile knows its configure preset")

-- Second import adds nothing
eq(state.sync_cmake_profiles(), 0, "second import is a no-op")

-- Disabled profiles are ignored
eq(state.cmake_settings(), {}, "no enabled profile -> empty settings")

-- Toggle enables
state.toggle_cmake_profile("debug")
eq(state.cmake_settings().name, "debug", "enabled profile becomes effective")
eq(cmake.binary_dir(), root .. "/build/debug", "binary_dir from configure preset")

-- Set active enables and switches
state.set_active_cmake_profile("release")
eq(state.active_cmake_profile(), "release", "active switched")
eq(state.cmake_profile("release").enabled, true, "set active enables")
eq(cmake.binary_dir(), root .. "/build/release", "binary_dir follows active")

-- Save / reload keeps flags and kind
state.save()
state.reload()
eq(state.cmake_profile("debug").kind, "configure", "kind persisted")
eq(state.cmake_profile("debug").enabled, true, "enabled persisted")
eq(state.cmake_profile("debug-build").enabled, false, "disabled persisted")

-- Preset profile scratch editor only exposes env
local editor = require("orchlaunch.ui.editor")
local saved = false
local handle = editor.open_cmake(state.cmake_profile("debug"), function()
    saved = true
end)
local text = table.concat(vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false), "\n")
assert(text:find("Derived from configure preset", 1, true), "header mentions preset")
assert(not text:find("toolchain =", 1, true), "preset profile hides toolchain")
assert(text:find("environment =", 1, true), "preset profile exposes environment")

vim.api.nvim_buf_set_lines(handle.buf, 0, -1, false, {
    "return {",
    '  name = "debug",',
    "  enabled = true,",
    '  environment = { MY_VAR = "42" },',
    "}",
})
vim.api.nvim_buf_call(handle.buf, function()
    vim.cmd("write")
end)
eq(saved, true, "preset profile saved")
local updated = state.cmake_profile("debug")
eq(updated.environment.MY_VAR, "42", "environment override stored")
eq(updated.configure_preset, "debug", "configure preset preserved")
eq(updated.kind, "configure", "kind preserved")

state.reload()
local reloaded = state.cmake_profile("debug")
eq(reloaded.environment.MY_VAR, "42", "environment survives reload")
eq(reloaded.kind, "configure", "kind survives reload")
eq(reloaded.configure_preset, "debug", "configure preset survives reload")

print("\nALL PASS: preset sync")
