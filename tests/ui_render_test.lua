vim.opt.rtp:append("/home/olokreaz/.config/nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui-components.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")
local function add(rtp)
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")
    vim.opt.rtp:append(rtp)
end

add("/home/olokreaz/.config/nvim")
add("/home/olokreaz/.local/share/nvim/lazy/nui.nvim")
add("/home/olokreaz/.local/share/nvim/lazy/nui-components.nvim")
add("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")

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
    local r = require("orchlaunch.ui.editor").open_native(state.require_configuration("Game"))
    vim.wait(200)
    r:close()
end)

attempt("editor remote", function()
    local r = require("orchlaunch.ui.editor").open_remote(state.require_configuration("Attach"))
    vim.wait(200)
    r:close()
end)

attempt("editor compound", function()
    local r = require("orchlaunch.ui.editor").open_compound(state.require_configuration("All"))
    vim.wait(200)
    r:close()
end)

attempt("editor toolchain", function()
    local r = require("orchlaunch.ui.editor").open_toolchain(state.require_toolchain("Clang"))
    vim.wait(200)
    r:close()
end)

attempt("editor external tool", function()
    local r = require("orchlaunch.ui.editor").open_external_tool(state.require_external_tool("gen"))
    vim.wait(200)
    r:close()
end)

attempt("editor cmake", function()
    local renderer = require("orchlaunch.ui.editor").open_cmake()
    vim.wait(200)
    assert(renderer and renderer:get_component_by_id("name"), "cmake editor did not render")
    renderer:close()
end)

attempt("list_dialog toolchains", function()
    local r = require("orchlaunch.ui.list_dialog").open_toolchains()
    vim.wait(200)
    r:close()
end)

if #messages > 0 then
    print("\nnotify messages:")
    for _, m in ipairs(messages) do
        print("  " .. m)
    end
end
