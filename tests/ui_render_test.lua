local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
require("harness")

local messages = {}
local original_notify = vim.notify
vim.notify = function(msg, ...)
    messages[#messages + 1] = tostring(msg)
    return original_notify(msg, ...)
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")

orch.create_project(root)
state.add_toolchain(config.toolchain({ name = "Clang", type = "system", cmake = "cmake", c = "clang", cxx = "clang++", debugger = "lldb" }))
state.add_external_tool(config.external_tool({ name = "gen", program = "gen" }))
state.add_configuration(config.native({ name = "Game", target = "/bin/echo", console = config.console({ mode = "embedded" }) }))
state.add_configuration(config.remote_debug({ name = "Attach", symbol = "game", connection = "localhost:1234", adapter = "gdb" }))
state.add_configuration(config.compound({ name = "All", configurations = { "Game" } }))
state.save()

local function attempt(name, fn)
    local ok, err = pcall(fn)
    print((ok and "PASS  " or "FAIL  ") .. name .. (ok and "" or "  " .. tostring(err)))
end

attempt("browser render", function()
    local r = require("orchlaunch.ui.browser").open()
    vim.wait(200)
    r:close()
end)

attempt("editor native", function()
    local r = require("orchlaunch.ui.editors.native").open(state.require_configuration("Game"))
    vim.wait(200)
    r:close()
end)

attempt("editor remote", function()
    local r = require("orchlaunch.ui.editors.remote").open(state.require_configuration("Attach"))
    vim.wait(200)
    r:close()
end)

attempt("editor compound", function()
    local r = require("orchlaunch.ui.editors.compound").open(state.require_configuration("All"))
    vim.wait(200)
    r:close()
end)

attempt("editor toolchain", function()
    local r = require("orchlaunch.ui.editors.toolchain").open(state.require_toolchain("Clang"))
    vim.wait(200)
    r:close()
end)

attempt("editor external tool", function()
    local r = require("orchlaunch.ui.editors.external_tool").open(state.require_external_tool("gen"))
    vim.wait(200)
    r:close()
end)

attempt("editor cmake", function()
    local r = require("orchlaunch.ui.editors.cmake_profile").open()
    vim.wait(200)
    assert(r ~= nil and r.orch ~= nil, "editor did not render")
    r.orch.close(false)
end)

attempt("list_dialog toolchains", function()
    local r = require("orchlaunch.ui.dialogs.toolchains").open()
    vim.wait(200)
    r:close()
end)

if #messages > 0 then
    print("\nnotify messages:")
    for _, m in ipairs(messages) do
        print("  " .. m)
    end
end
