-- OrchLaunch menu: statusline text, keymaps and the single menu picker.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local messages = {}
vim.notify = function(msg, level)
    messages[#messages + 1] = { text = tostring(msg), level = level }
end

local picked_items, picker_choice
vim.ui.select = function(items, opts, cb)
    picked_items = items
    local choice
    for _, item in ipairs(items) do
        if picker_choice and item.label == picker_choice then
            choice = item
        end
    end
    cb(choice)
end

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local menu = require("orchlaunch.menu")

-- ---- no project ------------------------------------------------------------------
h.eq("statusline is empty without a project", menu.statusline(), "")
h.eq("status is nil without a project", menu.status(), nil)
picked_items = nil
menu.open()
h.eq("menu opens no picker without a project", picked_items, nil)

-- ---- project with a configuration and a profile ----------------------------------
local root = h.tempdir()
orch.setup({ root = root, silent = true })
orch.create_project(root)

state.add_toolchain(
    config.toolchain({ name = "gcc", type = "system", cmake = "cmake", c = "gcc", cxx = "g++", debugger = "gdb" })
)
state.add_configuration(config.native({ name = "app", target = "app_bin", toolchain = "gcc" }))
state.add_cmake_profile(config.cmake_settings({ name = "Debug", toolchain = "gcc", build_type = "Debug" }))
state.set_active_cmake_profile("Debug")

h.eq("status names the configuration", menu.status().configuration, "app")
h.eq("status names the profile", menu.status().profile, "Debug")
h.eq("status names the native target", menu.status().target, "app_bin")
h.eq("statusline shows configuration, profile and target", menu.statusline(), " app · Debug · app_bin")

-- ---- menu -----------------------------------------------------------------------
picker_choice = nil
menu.open()
h.check("menu opens a picker", picked_items ~= nil and #picked_items > 10, vim.inspect(picked_items))

local labels = {}
for _, item in ipairs(picked_items or {}) do
    labels[#labels + 1] = item.label
end
h.contains("menu offers Run", table.concat(labels, "|"), "Run active configuration")
h.contains("menu offers Build", table.concat(labels, "|"), "Build")

-- Choosing an entry runs it; choosing nothing does nothing and raises no error.
picker_choice = "Toggle breakpoint"
h.ok("choosing a menu entry does not raise", function()
    menu.open()
end)

-- ---- keymaps -------------------------------------------------------------------
menu.setup_keymaps("<leader>o")
-- maparg expands <leader>, so this checks the key the user actually presses.
local function desc_of(lhs)
    return vim.fn.maparg(lhs, "n", false, true).desc
end
h.check("<leader>o maps the menu", (desc_of("<leader>o") or ""):find("menu", 1, true) ~= nil)
h.check("<leader>or maps run", (desc_of("<leader>or") or ""):find("Run", 1, true) ~= nil)
h.check("<leader>ok maps the breakpoint toggle", (desc_of("<leader>ok") or ""):find("breakpoint", 1, true) ~= nil)

h.done("OrchLaunch menu")
