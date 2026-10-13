-- Headless test for the nui-components CMake profile editor.
--
-- Opens the editor, drives its widgets and verifies the profile is persisted
-- through `state`. Covers both manual profiles (every field) and preset-derived
-- profiles (read-only header + name/enabled/environment).

vim.opt.rtp:append("/home/olokreaz/.config/nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui-components.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")

local notifications = {}
vim.notify = function(msg)
    notifications[#notifications + 1] = tostring(msg)
end

local function noted(fragment)
    for _, msg in ipairs(notifications) do
        if msg:find(fragment, 1, true) then
            return true
        end
    end
    return false
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

--- Presses the first focusable button whose rendered label contains `fragment`.
local function press(renderer, fragment)
    for _, component in ipairs(renderer:get_focusable_components()) do
        local props = component:get_props()
        if type(props.on_press) == "function"
            and type(props.lines) == "string"
            and props.lines:find(fragment, 1, true)
        then
            props.on_press(component)
            return true
        end
    end
    return false
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
require("orchlaunch").create_project(root)
state.add_toolchain({ name = "Clang", c = "clang", cxx = "clang++" })
state.save()

-- ============================================================================
-- 1. manual profile editor
-- ============================================================================
local saved = false
local r = editor.open_cmake(nil, function()
    saved = true
end)
vim.wait(300)

check("manual editor renders", r ~= nil)
check("manual editor name field", r and r:get_component_by_id("name") ~= nil)
check("manual editor enabled checkbox", r and r:get_component_by_id("enabled") ~= nil)
check("manual editor toolchain select", r and r:get_component_by_id("toolchain") ~= nil)
check("manual editor configure preset select", r and r:get_component_by_id("configure_preset") ~= nil)
check("manual editor build preset select", r and r:get_component_by_id("build_preset") ~= nil)
check("manual editor build type select", r and r:get_component_by_id("build_type") ~= nil)
check("manual editor definitions field", r and r:get_component_by_id("definitions") ~= nil)
check("manual editor environment field", r and r:get_component_by_id("environment") ~= nil)

local function set(id, value)
    local component = r:get_component_by_id(id)
    if component then
        component:set_current_value(value)
        return true
    end
    return false
end

set("name", "Debug")
set("toolchain", { id = "Clang" })
set("configure_preset", { id = "debug" })
set("build_preset", { id = "debug-build" })
set("test_preset", { id = "debug-test" })
set("build_type", { id = "Debug" })
set("build_dir", "build/custom")
set("install_dir", "${workspace}/out")
set("configure_args", "-DFOO=1\n-DBAR=2")
set("definitions", "CMAKE_CXX_FLAGS=-O2")
set("environment", "CC=clang")

check("manual editor Save pressed", press(r, "Save"), "no Save button found")
check("manual editor on_saved fired", saved)

state.reload()
local settings = state.cmake_settings()
check("profile persisted", settings.name == "Debug", tostring(settings and settings.name))
check("toolchain persisted", settings.toolchain == "Clang", tostring(settings and settings.toolchain))
check("configure_preset persisted", settings.configure_preset == "debug", tostring(settings and settings.configure_preset))
check("build_preset persisted", settings.build_preset == "debug-build", tostring(settings and settings.build_preset))
check("test_preset persisted", settings.test_preset == "debug-test", tostring(settings and settings.test_preset))
check("build_type persisted", settings.build_type == "Debug", tostring(settings and settings.build_type))
check("build_dir persisted", settings.build_dir == "build/custom", tostring(settings and settings.build_dir))
check("install_dir persisted", settings.install_dir == "${workspace}/out", tostring(settings and settings.install_dir))
check("configure_args persisted", settings.configure_args[1] == "-DFOO=1" and settings.configure_args[2] == "-DBAR=2", vim.inspect(settings and settings.configure_args))
check("definitions persisted", settings.definitions.CMAKE_CXX_FLAGS == "-O2", vim.inspect(settings and settings.definitions))
check("environment persisted", settings.environment.CC == "clang", vim.inspect(settings and settings.environment))

-- empty name is rejected
notifications = {}
local invalid = editor.open_cmake(nil, nil)
vim.wait(200)
press(invalid, "Save")
check("empty name rejected", #notifications > 0, table.concat(notifications, " | "))
check("editor stays open on error", invalid:get_component_by_id("name") ~= nil)
invalid:close()

-- duplicate name is rejected
notifications = {}
local dup = editor.open_cmake(nil, nil)
vim.wait(200)
dup:get_component_by_id("name"):set_current_value("Debug")
press(dup, "Save")
check("duplicate name rejected", #notifications > 0, table.concat(notifications, " | "))
dup:close()

-- ============================================================================
-- 2. preset-derived profile editor
-- ============================================================================
state.add_cmake_profile({
    name = "PresetDebug",
    enabled = true,
    kind = "configure",
    configure_preset = "debug",
})
state.save()

local saved_preset = false
local rp = editor.open_cmake(state.cmake_profile("PresetDebug"), function()
    saved_preset = true
end)
vim.wait(300)

check("preset editor renders", rp ~= nil)
check("preset editor header", rp and rp:get_component_by_id("preset_header") ~= nil)
check("preset editor name field", rp and rp:get_component_by_id("name") ~= nil)
check("preset editor hides toolchain", rp and rp:get_component_by_id("toolchain") == nil)
check("preset editor environment field", rp and rp:get_component_by_id("environment") ~= nil)

rp:get_component_by_id("name"):set_current_value("PresetDebug")
rp:get_component_by_id("environment"):set_current_value("CXX=clang++")
check("preset editor Save pressed", press(rp, "Save"))
check("preset editor on_saved fired", saved_preset)

state.reload()
local preset = state.cmake_profile("PresetDebug")
check("preset kind preserved", preset and preset.kind == "configure", tostring(preset and preset.kind))
check("preset configure_preset preserved", preset and preset.configure_preset == "debug", tostring(preset and preset.configure_preset))
check("preset environment persisted", preset and preset.environment.CXX == "clang++", vim.inspect(preset and preset.environment))

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURE(S)"))
if failures > 0 then
    os.exit(1)
end
