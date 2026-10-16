-- Fibrous CMake profiles dialog (prototype).
--
-- The screen is rendered by fibrous into one host buffer; we assert on the
-- rendered text and drive the list through its buffer-local mappings. Skips
-- cleanly when fibrous is not installed (the kit implementation still backs the
-- command in that case).

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

if not (pcall(require, "fibrous")) then
    print("SKIP  fibrous is not installed")
    h.done("fibrous CMake profiles (skipped)")
    return
end

local function screen(bufnr)
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function key(text)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), "x", false)
    vim.wait(120)
end

local root = h.tempdir()
local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")

orch.create_project(root)
state.add_cmake_profile(config.cmake_settings({ name = "Debug", build_type = "Debug", generator = "Ninja" }))
state.add_cmake_profile(config.cmake_settings({ name = "Release", build_type = "Release" }))
state.set_active_cmake_profile("Debug")
state.save()

local dialog = require("orchlaunch.ui.fibrous.cmake_profiles")
h.check("fibrous dialog is available", dialog.available())

local handle = dialog.open()
handle.focus()
vim.wait(200)

local text = screen(handle.bufnr)
h.contains("dialog title", text, "CMake Profiles")
h.contains("dialog lists profiles", text, "Debug")
h.contains("dialog lists second profile", text, "Release")
h.contains("active marker", text, "● Debug")
h.contains("details for the selection", text, "Name:  Debug  (active)")
h.contains("new-profile hint", text, "New profile")
h.contains("import hint", text, "Import presets")

key("j")
h.contains("j moves the selection", screen(handle.bufnr), "Name:  Release")

key("A")
h.eq("A sets the active profile", state.active_cmake_profile(), "Release")

local txt = screen(handle.bufnr)
h.check("details drop the Enabled field", txt:find("Enabled", 1, true) == nil, txt)
h.check("footer drops the Toggle hint", txt:find("Toggle", 1, true) == nil, txt)

handle.unmount()

h.done("fibrous CMake profiles")
