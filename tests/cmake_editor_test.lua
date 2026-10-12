vim.opt.rtp:append("/home/olokreaz/.config/nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui-components.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")
-- Headless test that drives the scratch-buffer CMake profile editor: set the
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")
-- Lua content, `:write`, and verify the profile was persisted.

local function add(rtp)
    vim.opt.rtp:append(rtp)
end

add("/home/olokreaz/.config/nvim")
add("/home/olokreaz/.local/share/nvim/lazy/nui.nvim")
add("/home/olokreaz/.local/share/nvim/lazy/nui-components.nvim")
add("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")

local failures = 0
local function check(name, ok, err)
    if ok then
        print("PASS  " .. name)
    else
        failures = failures + 1
        print("FAIL  " .. name .. "  " .. tostring(err))
    end
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local f = assert(io.open(root .. "/CMakePresets.json", "w"))
f:write([[
{
  "version": 6,
  "configurePresets": [
    { "name": "debug", "displayName": "Debug (Ninja)", "generator": "Ninja", "binaryDir": "${sourceDir}/build/debug" },
    { "name": "release", "displayName": "Release" }
  ],
  "buildPresets": [ { "name": "debug-build", "configurePreset": "debug" } ],
  "testPresets": [ { "name": "tests", "configurePreset": "debug" } ]
}
]])
f:close()

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local editor = require("orchlaunch.ui.editor")

orch.create_project(root)
state.add_toolchain(config.toolchain({
    name = "Clang",
    type = "system",
    cmake = "cmake",
    c = "clang",
    cxx = "clang++",
    debugger = "lldb",
}))
state.save()

local saved = false
local handle = editor.open_cmake(nil, function()
    saved = true
end)
vim.wait(100)

check("scratch buffer opened", handle and vim.api.nvim_buf_is_valid(handle.buf))

local buffer_text = table.concat(vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false), "\n")
check("manual profile hides source_dir", not buffer_text:find("source_dir", 1, true))

local content = {
    "return {",
    '  name = "Debug",',
    "  enabled = true,",
    '  toolchain = "Clang",',
    '  configure_preset = "debug",',
    '  build_preset = "debug-build",',
    '  test_preset = "tests",',
    '  build_dir = "build/custom",',
    '  configure_args = { "-DFOO=1" },',
    "}",
}
vim.api.nvim_buf_set_lines(handle.buf, 0, -1, false, content)

local ok, err = pcall(function()
    vim.api.nvim_buf_call(handle.buf, function()
        vim.cmd("write")
    end)
end)
check("write applied", ok, err)
check("on_saved fired", saved == true)

state.reload()
local settings = state.cmake_settings()
check("name persisted", settings.name == "Debug", settings.name)
check("configure_preset persisted", settings.configure_preset == "debug", settings.configure_preset)
check("build_preset persisted", settings.build_preset == "debug-build", settings.build_preset)
check("test_preset persisted", settings.test_preset == "tests", settings.test_preset)
check("toolchain persisted", settings.toolchain == "Clang", settings.toolchain)
check("build_dir persisted", settings.build_dir == "build/custom", settings.build_dir)
check("configure_args persisted", settings.configure_args[1] == "-DFOO=1", tostring(settings.configure_args[1]))

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURE(S)"))
if failures > 0 then
    os.exit(1)
end
