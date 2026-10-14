local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
require("harness")

local root = vim.fn.tempname()
vim.fn.delete(root, "rf")
vim.fn.mkdir(root, "p")

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")

orch.create_project(root)
state.add_cmake_profile(config.cmake_settings({ name = "Debug", build_type = "Debug" }))
state.add_cmake_profile(config.cmake_settings({ name = "Release", build_type = "Release" }))
state.set_active_cmake_profile("Release")
state.save()

local renderer = require("orchlaunch.ui.list_dialog").open_cmake_profiles()
vim.wait(300)

local failures = 0
local function check(name, ok)
    print((ok and "PASS  " or "FAIL  ") .. name)
    if not ok then
        failures = failures + 1
    end
end

local list = renderer:get_component_by_id("orch_list")
check("profile list rendered", list ~= nil)

local screen = {}
for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        screen[#screen + 1] = line
    end
end
local text = table.concat(screen, "\n")

check("Set Active hint present", text:find("Set Active", 1, true) ~= nil)
check("active marker on list item", text:find("● Release", 1, true) ~= nil)

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURE(S)"))
if failures > 0 then
    os.exit(1)
end
