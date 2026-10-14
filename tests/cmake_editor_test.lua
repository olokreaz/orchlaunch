-- Headless test for the raw-nui CMake profile editor.
--
-- Opens the editor, drives it through its `.orch` test hooks and verifies the
-- profile is persisted through `state`. Covers manual profiles (every field),
-- validation (empty/duplicate name) and preset-derived read-only profiles.

vim.opt.rtp:append("/home/olokreaz/.config/nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui-components.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")

local notifications = {}
vim.notify = function(msg)
    notifications[#notifications + 1] = tostring(msg)
end

local failures = 0
local function check(name, ok, err)
    if ok then
        print("PASS  " .. name)
    else
        failures = failures + 1
        print("FAIL  " .. name .. "  " .. tostring(err))
    end
end

local function field_ids(popup)
    local ids = {}
    for _, field in ipairs(popup.orch.fields) do
        ids[field.id] = true
    end
    return ids
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local f = assert(io.open(root .. "/CMakePresets.json", "w"))
f:write([[
{
  "version": 6,
  "configurePresets": [
    { "name": "debug", "binaryDir": "build/debug" },
    { "name": "release", "binaryDir": "build/release" }
  ],
  "buildPresets": [ { "name": "debug-build", "configurePreset": "debug" } ],
  "testPresets": [ { "name": "debug-test", "configurePreset": "debug" } ]
}
]])
f:close()

local editor = require("orchlaunch.ui.editor")
local state = require("orchlaunch.state")
local UI = require("orchlaunch.ui")
require("orchlaunch").create_project(root)
state.add_toolchain({ name = "Clang", c = "clang", cxx = "clang++" })
state.save()

-- ============================================================================
-- 1. manual profile editor
-- ============================================================================
local saved = false
local popup = editor.open_cmake(nil, function()
    saved = true
end)
vim.wait(200)

check("manual editor renders", popup ~= nil and popup.orch ~= nil)
check("manual editor is editable", popup and popup.orch.readonly == false)

local fields = {}
for _, field in ipairs(popup.orch.fields or {}) do
    fields[field.id] = true
end

check("has name field", fields.name)
check("has enabled field", fields.enabled)
check("has toolchain select", fields.toolchain)
check("has generator select", fields.generator)
check("has build_type select", fields.build_type)
check("has definitions field", fields.definitions)
check("has environment field", fields.environment)
check("has no preset fields", not (fields.configure_preset or fields.build_preset or fields.test_preset or fields.package_preset or fields.workflow_preset))
check("new profile defaults to Ninja", popup.orch.values.generator == "Ninja", tostring(popup.orch.values.generator))
check("new profile defaults to Debug", popup.orch.values.build_type == "Debug", tostring(popup.orch.values.build_type))

-- toggling a boolean through `activate` updates the value
local enabled_index = popup.orch.index_of("enabled")
local before_toggle = popup.orch.values.enabled
popup.orch.activate(popup.orch.fields[enabled_index])
check("activate toggles boolean", popup.orch.values.enabled ~= before_toggle)
popup.orch.activate(popup.orch.fields[enabled_index])
check("activate toggles back", popup.orch.values.enabled == before_toggle)

-- string field wiring
popup.orch.set("build_dir", "build/ninja")
vim.wait(50)
check("string field applied", popup.orch.values.build_dir == "build/ninja", tostring(popup.orch.values.build_dir))

-- select field wiring
popup.orch.set("build_type", "Release")
vim.wait(50)
check("select field applied", popup.orch.values.build_type == "Release", tostring(popup.orch.values.build_type))

-- multiline field wiring
popup.orch.set("build_args", "-j4\n --verbose \n")
vim.wait(50)
check("multiline field applied", UI.lines(popup.orch.values.build_args)[1] == "-j4" and UI.lines(popup.orch.values.build_args)[2] == "--verbose", vim.inspect(popup.orch.values.build_args))

popup.orch.set("name", "Debug")
popup.orch.set("toolchain", "Clang")
popup.orch.set("generator", "Ninja")
popup.orch.set("build_type", "Debug")
popup.orch.set("build_dir", "build/custom")
popup.orch.set("install_dir", "${workspace}/out")
popup.orch.set("configure_args", "-DFOO=1\n-DBAR=2")
popup.orch.set("definitions", "CMAKE_CXX_FLAGS=-O2")
popup.orch.set("environment", "CC=clang")
popup.orch.save()
vim.wait(100)

check("manual editor on_saved fired", saved)

state.reload()
local settings = state.cmake_settings()
check("profile persisted", settings.name == "Debug", tostring(settings and settings.name))
check("toolchain persisted", settings.toolchain == "Clang", tostring(settings and settings.toolchain))
check("generator persisted", settings.generator == "Ninja", tostring(settings and settings.generator))
check("build_type persisted", settings.build_type == "Debug", tostring(settings and settings.build_type))
check("build_dir persisted", settings.build_dir == "build/custom", tostring(settings and settings.build_dir))
check("install_dir persisted", settings.install_dir == "${workspace}/out", tostring(settings and settings.install_dir))
check("configure_args persisted", settings.configure_args[1] == "-DFOO=1" and settings.configure_args[2] == "-DBAR=2", vim.inspect(settings and settings.configure_args))
check("definitions persisted", settings.definitions.CMAKE_CXX_FLAGS == "-O2", vim.inspect(settings and settings.definitions))
check("environment persisted", settings.environment.CC == "clang", vim.inspect(settings and settings.environment))

-- ============================================================================
-- 2. validation
-- ============================================================================
local notifications_count = #notifications

local function notifications_grew()
    return #notifications > notifications_count
end

local invalid = editor.open_cmake(nil, nil)
vim.wait(100)
notifications_count = #notifications
invalid.orch.set("name", "")
invalid.orch.save()
vim.wait(50)
check("empty name rejected", notifications_grew(), table.concat(notifications, " | "))
check("editor stays open on error", vim.api.nvim_win_is_valid(invalid.winid))
invalid.orch.close(false)

local dup = editor.open_cmake(nil, nil)
vim.wait(100)
notifications_count = #notifications
dup.orch.set("name", "Debug")
dup.orch.save()
vim.wait(50)
check("duplicate name rejected", notifications_grew(), table.concat(notifications, " | "))
check("duplicate editor stays open", vim.api.nvim_win_is_valid(dup.winid))
dup.orch.close(false)

-- ============================================================================
-- 3. preset-derived profile editor (read-only)
-- ============================================================================
state.add_cmake_profile({
    name = "PresetDebug",
    enabled = true,
    kind = "configure",
    configure_preset = "debug",
})
state.save()

local preset_saved = false
local preset_popup = editor.open_cmake(state.cmake_profile("PresetDebug"), function()
    preset_saved = true
end)
vim.wait(200)

check("preset editor renders", preset_popup ~= nil and preset_popup.orch ~= nil)
check("preset editor is read-only", preset_popup and preset_popup.orch.readonly == true)

local preset_fields = {}
for _, field in ipairs(preset_popup.orch.fields or {}) do
    preset_fields[field.id] = true
end

check("preset editor shows source", preset_fields.kind, "not found")
check("preset editor shows configure_preset", preset_fields.configure_preset, "not found")
check("preset editor hides toolchain", not preset_fields.toolchain, "unexpectedly present")

notifications_count = #notifications
preset_popup.orch.activate(preset_popup.orch.fields[preset_popup.orch.index_of("name")])
vim.wait(50)
check("preset editor rejects edits", notifications_grew(), table.concat(notifications, " | "))

notifications_count = #notifications
preset_popup.orch.save()
vim.wait(50)
check("preset editor rejects save", notifications_grew(), table.concat(notifications, " | "))

preset_popup.orch.close(false)
vim.wait(50)
check("preset on_saved fired", preset_saved)

state.reload()
local preset = state.cmake_profile("PresetDebug")
check("preset kind preserved", preset and preset.kind == "configure", tostring(preset and preset.kind))
check("preset configure_preset preserved", preset and preset.configure_preset == "debug", tostring(preset and preset.configure_preset))

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURE(S)"))
if failures > 0 then
    os.exit(1)
end
