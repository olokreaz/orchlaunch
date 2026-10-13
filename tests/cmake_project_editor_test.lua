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
local pressed = false
for _, component in ipairs(renderer:get_focusable_components()) do
    local props = component:get_props()
    if type(props.on_press) == "function"
        and type(props.lines) == "string"
        and props.lines:find("Save", 1, true)
    then
        props.on_press(component)
        pressed = true
        break
    end
end
assert(pressed, "no Save button")
print("saved:", saved)
print("raw:", tostring(state.cmake_source_dir_raw()))
print("resolved:", state.cmake_source_dir())
local p = state.presets()
print("presets:", p and p.configure[1].name or "nil")
