-- Fibrous CMake profile editor.
--
-- Opens the fibrous form, drives it through its `.orch` test hooks and verifies
-- the profile is persisted through `state`. Skips cleanly when fibrous is not
-- installed.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

-- The form lays out in two columns; a wide canvas keeps every field on its own
-- cell so the flash-jump scan can tell them apart.
vim.o.columns = 120
vim.o.lines = 40

if not (pcall(require, "fibrous")) then
    print("SKIP  fibrous is not installed")
    h.done("fibrous CMake profile editor (skipped)")
    return
end

local notifications = {}
vim.notify = function(msg)
    notifications[#notifications + 1] = tostring(msg)
end

local root = h.tempdir()
local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local editor = require("orchlaunch.ui.fibrous.cmake_profile")

orch.create_project(root)
state.add_toolchain({ name = "Clang", c = "clang", cxx = "clang++" })
state.save()

local function field_ids(handle)
    local ids = {}
    for _, field in ipairs(handle.orch.fields) do
        ids[field.id] = true
    end
    return ids
end

-- ============================================================================
-- 1. manual profile editor
-- ============================================================================
local saved = false
local handle = editor.open(nil, function()
    saved = true
end)
vim.wait(200)

h.check("manual editor renders", handle ~= nil and handle.orch ~= nil)
h.check("manual editor is editable", handle.orch.readonly == false)

local ids = field_ids(handle)
h.check("has name field", ids.name)
h.check("has no enabled field", not ids.enabled)
h.check("has toolchain select", ids.toolchain)
h.check("has generator select", ids.generator)
h.check("has definitions field", ids.definitions)
h.check("has environment field", ids.environment)
h.check("has no preset fields", not (ids.configure_preset or ids.build_preset))
h.eq("new profile defaults to Ninja", handle.orch.values.generator, "Ninja")
h.eq("new profile defaults to Debug", handle.orch.values.build_type, "Debug")

local cells = handle.orch._field_cells()
h.eq("flash locates every field", #cells, #handle.orch.fields)
local cells_inside = true
for _, c in ipairs(cells) do
    if c.row < 0 or c.col < 0 or c.row >= vim.api.nvim_buf_line_count(handle.bufnr) then
        cells_inside = false
    end
end
h.check("flash cells sit inside the canvas", cells_inside)

handle.orch.set("name", "Debug")
handle.orch.set("toolchain", "Clang")
handle.orch.set("generator", "Ninja")
handle.orch.set("build_type", "Debug")
handle.orch.set("build_dir", "build/custom")
handle.orch.set("install_dir", "${workspace}/out")
handle.orch.set("configure_args", "-DFOO=1\n-DBAR=2")
handle.orch.set("definitions", "CMAKE_CXX_FLAGS=-O2")
handle.orch.set("environment", "CC=clang")
vim.wait(50)
handle.orch.save()
vim.wait(100)

h.check("manual editor on_saved fired", saved)

state.reload()
local settings = state.cmake_settings()
h.eq("profile persisted", settings.name, "Debug")
h.eq("toolchain persisted", settings.toolchain, "Clang")
h.eq("generator persisted", settings.generator, "Ninja")
h.eq("build_dir persisted", settings.build_dir, "build/custom")
h.eq("install_dir persisted", settings.install_dir, "${workspace}/out")
h.check("configure_args persisted", settings.configure_args[1] == "-DFOO=1" and settings.configure_args[2] == "-DBAR=2")
h.eq("definitions persisted", settings.definitions.CMAKE_CXX_FLAGS, "-O2")
h.eq("environment persisted", settings.environment.CC, "clang")

-- ============================================================================
-- 2. validation
-- ============================================================================
local before = #notifications
local function grew()
    return #notifications > before
end

local invalid = editor.open(nil, nil)
vim.wait(100)
before = #notifications
invalid.orch.set("name", "")
invalid.orch.save()
vim.wait(50)
h.check("empty name rejected", grew(), table.concat(notifications, " | "))
h.check("editor stays open on error", vim.api.nvim_win_is_valid(invalid.winid))
invalid.orch.close()

local dup = editor.open(nil, nil)
vim.wait(100)
before = #notifications
dup.orch.set("name", "Debug")
dup.orch.save()
vim.wait(50)
h.check("duplicate name rejected", grew(), table.concat(notifications, " | "))
h.check("duplicate editor stays open", vim.api.nvim_win_is_valid(dup.winid))
dup.orch.close()

-- ============================================================================
-- 3. preset-derived profile editor (read-only)
-- ============================================================================
state.add_cmake_profile({ name = "PresetDebug", kind = "configure", configure_preset = "debug" })
state.save()

local preset_saved = false
local preset = editor.open(state.cmake_profile("PresetDebug"), function()
    preset_saved = true
end)
vim.wait(200)

h.check("preset editor renders", preset ~= nil and preset.orch ~= nil)
h.check("preset editor is read-only", preset.orch.readonly == true)

local preset_ids = field_ids(preset)
h.check("preset editor shows source", preset_ids.kind)
h.check("preset editor shows configure_preset", preset_ids.configure_preset)
h.check("preset editor hides toolchain", not preset_ids.toolchain)

before = #notifications
preset.orch.save()
vim.wait(50)
h.check("preset editor rejects save", grew(), table.concat(notifications, " | "))

preset.orch.close()
vim.wait(50)
h.check("preset on_saved fired", preset_saved)

state.reload()
h.eq("preset kind preserved", state.cmake_profile("PresetDebug").kind, "configure")

h.done("fibrous CMake profile editor")
