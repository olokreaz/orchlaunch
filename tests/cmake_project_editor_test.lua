vim.opt.rtp:append("/home/olokreaz/.config/nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui-components.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")
vim.opt.rtp:append("/home/olokreaz/.config/nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui-components.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")

local root = "/tmp/opencode/orch_proj_pedit"
vim.fn.delete(root, "rf")
vim.fn.mkdir(root .. "/boo", "p")
local function write(p, c) local f=assert(io.open(p,"w")); f:write(c); f:close() end
write(root .. "/boo/CMakePresets.json", [[{ "version": 6, "configurePresets": [ { "name": "boo-debug" } ] }]])

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local editor = require("orchlaunch.ui.editor")
orch.create_project(root)

local saved = false
local renderer = editor.open_cmake_project(function() saved = true end)
vim.wait(200)
assert(renderer and renderer:get_component_by_id("source_dir"), "editor did not render")
renderer:get_component_by_id("source_dir"):set_current_value("${workspace}/boo")
assert(renderer._save, "save handler missing")
renderer._save()
vim.wait(50)
print("saved:", saved)
print("raw:", tostring(state.cmake_source_dir_raw()))
print("resolved:", state.cmake_source_dir())
local p = state.presets()
print("presets:", p and p.configure[1].name or "nil")
