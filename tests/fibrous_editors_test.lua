-- Fibrous editors & browser smoke tests.
--
-- Opens every fibrous screen, asserts it renders its title into the host buffer
-- and closes it again. This catches layout/render regressions (bad props,
-- wrong callback arity) that the pure-logic suites never touch. Skips cleanly
-- when fibrous is not installed.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

if not (pcall(require, "fibrous")) then
    print("SKIP  fibrous is not installed")
    h.done("fibrous editors (skipped)")
    return
end

vim.o.columns = 120
vim.o.lines = 40

local root = h.tempdir()
local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")

orch.create_project(root)
state.add_toolchain(config.toolchain({ name = "Gcc", type = "system", cmake = "cmake", c = "gcc", cxx = "g++", debugger = "gdb" }))
state.add_external_tool(config.external_tool({ name = "gen", program = "${workspace}/gen" }))
state.add_configuration(config.native({ name = "Game", target = "/bin/echo" }))
state.add_configuration(config.remote_debug({ name = "Attach", symbol = "game", connection = "localhost:1234" }))
state.add_configuration(config.compound({ name = "All", configurations = { "Game", "Attach" } }))
state.add_cmake_profile(config.cmake_settings({ name = "Debug", build_type = "Debug" }))
state.save()

local function screen(handle)
    return table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
end

--- Opens `editor.open(...)`, asserts it rendered `needle`, then unmounts it.
local function smoke(name, open, needle)
    local ok, handle = pcall(open)
    if not ok then
        h.check(name, false, handle)
        return
    end
    vim.wait(80)
    h.check(name, handle ~= nil and vim.api.nvim_win_is_valid(handle.winid) and screen(handle):find(needle, 1, true) ~= nil)
    if handle then
        pcall(handle.unmount)
    end
end

smoke("toolchain editor renders", function()
    return require("orchlaunch.ui.fibrous.editors.toolchain").open(state.toolchain("Gcc"))
end, "Toolchain")

smoke("external tool editor renders", function()
    return require("orchlaunch.ui.fibrous.editors.external_tool").open(state.external_tool("gen"))
end, "External tool")

smoke("native editor renders", function()
    return require("orchlaunch.ui.fibrous.editors.native").open(state.configuration("Game"))
end, "Native configuration")

smoke("remote editor renders", function()
    return require("orchlaunch.ui.fibrous.editors.remote").open(state.configuration("Attach"))
end, "Remote debug configuration")

smoke("compound editor renders", function()
    return require("orchlaunch.ui.fibrous.editors.compound").open(state.configuration("All"))
end, "Compound configuration")

smoke("cmake project editor renders", function()
    return require("orchlaunch.ui.fibrous.editors.cmake_project").open()
end, "CMake project directory")

smoke("toolchains list renders", function()
    return require("orchlaunch.ui.dialogs.toolchains").open()
end, "Toolchains")

smoke("external tools list renders", function()
    return require("orchlaunch.ui.dialogs.external_tools").open()
end, "External Tools")

smoke("browser renders", function()
    return require("orchlaunch.ui.fibrous.browser").open()
end, "Run / Debug Configurations")

h.done("fibrous editors & browser")
