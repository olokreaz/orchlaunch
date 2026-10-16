-- Core hardening fixes: find_target recursion, process timeouts, dynamic lldb
-- adapter path, single project locate and non-duplicated autocommands.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local root = h.tempdir()
local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local cmake = require("orchlaunch.cmake")
local process = require("orchlaunch.process")

orch.create_project(root)
state.set_cmake_settings(config.cmake_settings({ build_dir = root .. "/build" }))
state.save()

-- 1. find_target searches build subdirectories ---------------------------------
vim.fn.mkdir(root .. "/build/lib/nested", "p")
local exe = io.open(root .. "/build/lib/nested/game", "w")
exe:write("#!/bin/sh\n")
exe:close()

h.eq("find_target searches subdirectories", cmake.find_target("game"), root .. "/build/lib/nested/game")

-- a match in the build root wins over a nested one
local toplevel = io.open(root .. "/build/game", "w")
toplevel:write("#!/bin/sh\n")
toplevel:close()
h.eq("find_target prefers the shallowest match", cmake.find_target("game"), root .. "/build/game")

-- 2. process timeout kills a hanging step --------------------------------------
local started = vim.uv.hrtime()
local result = process.run({ program = "sleep", args = { "5" }, timeout = 200 })
local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
h.check("process timeout returns quickly", elapsed_ms < 2000, ("elapsed %.0fms"):format(elapsed_ms))
h.check("process was killed", result.signal == 9 or result.code ~= 0, vim.inspect(result))

-- 3. lldb adapter path is resolved dynamically ---------------------------------
local lldb = require("orchlaunch.debug.lldb")
local adapter = lldb.get_dap_adapter("lldb")
local resolved = vim.fn.exepath("lldb-dap")
h.eq("lldb-dap resolves from PATH when present", adapter.command, resolved ~= "" and resolved or "lldb-dap")
h.check(
    "lldb-dap command is executable or a bare name",
    adapter.command == "lldb-dap" or vim.fn.exepath(adapter.command) ~= "",
    adapter.command
)
h.eq("explicit adapter path is honored", lldb.get_dap_adapter("lldb", "/opt/lldb-dap").command, "/opt/lldb-dap")

-- 4. state.setup accepts a pre-resolved orch_dir -------------------------------
local project = require("orchlaunch.project")
local found, orch_dir = project.locate(root)
local loaded = state.setup(found, orch_dir)
h.eq("state.setup(root, orch_dir) keeps the root", loaded.root, found)

-- 5. autocommands live in one augroup and are not duplicated -------------------
orch.setup({ silent = true })
local function count_autocmds(event)
    local n = 0
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = event })) do
        n = n + 1
    end
    return n
end
orch.setup({ silent = true })
h.eq("a single ColorScheme autocmd", count_autocmds("ColorScheme"), 1)
h.eq("a single VimEnter autocmd", count_autocmds("VimEnter"), 1)
h.eq("a single DirChanged autocmd", count_autocmds("DirChanged"), 1)

h.done("core hardening fixes")
