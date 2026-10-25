-- Regression test: the `:OrchLaunchRun` command goes through the asynchronous
-- launch path. A forward-reference bug there (`open_terminal` used before its
-- local definition) made every embedded-console run crash with
-- "attempt to call global 'open_terminal' (a nil value)" while synchronous
-- API tests stayed green.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

h.require_tool("cmake")
h.require_tool("c++")

local messages = {}
vim.notify = function(msg)
    messages[#messages + 1] = tostring(msg)
end

local orch = require("orchlaunch")
local root = h.tempdir()
h.write(root .. "/CMakeLists.txt", "cmake_minimum_required(VERSION 3.20)\nproject(demo CXX)\nadd_executable(hello main.cpp)\n")
h.write(root .. "/main.cpp", '#include <cstdio>\nint main(){ std::puts("hello from orch"); return 0; }\n')

orch.setup({ root = root, silent = true })
orch.create_project(root)
vim.cmd("OrchLaunchLoadCMake")
vim.wait(20000, function()
    return #vim.fn.glob(root .. "/.orch/run_configurations.json", false, true) > 0
        and h.read(root .. "/.orch/run_configurations.json"):find("hello", 1, true) ~= nil
end, 50)

local function terminal_buffers()
    local n = 0
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[b].buftype == "terminal" then
            n = n + 1
        end
    end
    return n
end

local function run_command(mode)
    vim.cmd("silent! %bwipeout!")
    local cfg = vim.json.decode(h.read(root .. "/.orch/run_configurations.json"))
    cfg.configurations[1].console = { mode = mode }
    h.write(root .. "/.orch/run_configurations.json", vim.json.encode(cfg))
    vim.cmd("OrchLaunchReload")
    messages = {}
    h.reset_errmsg()
    h.ok((":OrchLaunchRun hello (%s) does not raise"):format(mode), function()
        vim.cmd("OrchLaunchRun hello")
    end)
    -- builds and the launch are asynchronous
    vim.wait(30000, function()
        for _, m in ipairs(messages) do
            if m:find("finished with code", 1, true) then
                return true
            end
        end
        return mode == "embedded" and terminal_buffers() > 0
    end, 50)
    vim.wait(300)
    h.check_no_errmsg((":OrchLaunchRun hello (%s): no error in async callbacks"):format(mode))
end

run_command("embedded")
h.check("embedded console opened a terminal buffer", terminal_buffers() == 1, terminal_buffers())

run_command("hidden")
run_command("none")

h.done("async :OrchLaunchRun command")
