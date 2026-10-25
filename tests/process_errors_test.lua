-- A program that cannot be started must produce a normal failed result with a
-- readable message, never a Lua traceback or Neovim internals.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")
local process = require("orchlaunch.process")

local missing = process.run({ program = "orch-no-such-program-xyz", args = { "--version" } })
h.eq("missing program: code 127", missing.code, 127)
h.check("missing program: readable message", missing.stderr:find("orch-no-such-program-xyz: command not found", 1, true) ~= nil, missing.stderr)
h.check("missing program: no Neovim internals", not missing.stderr:find("vim/_core", 1, true) and not missing.stderr:find("ENOENT", 1, true), missing.stderr)
h.eq("missing program is not a success", process.succeeded(missing), false)

-- async: on_exit is called with the same result
local got
process.start({ program = "orch-no-such-program-xyz" }, function(result)
    got = result
end)
vim.wait(1000, function()
    return got ~= nil
end, 10)
h.check("async: on_exit is called", got ~= nil)
h.eq("async: code 127", got and got.code, 127)

-- permission denied
local dir = h.tempdir()
h.write(dir .. "/not-executable", "#!/bin/sh\necho hi\n")
vim.uv.fs_chmod(dir .. "/not-executable", tonumber("644", 8))
local denied = process.run({ program = dir .. "/not-executable" })
h.eq("non-executable file: code 127", denied.code, 127)
h.check("non-executable file: readable message", denied.stderr:find("permission denied", 1, true) ~= nil, denied.stderr)

-- describe_spawn_error on other errors strips the internal prefix
h.eq(
    "other errors keep only the reason",
    process.describe_spawn_error("tool", "vim/_core/system:324: something odd happened"),
    "tool: something odd happened"
)

-- the runner turns it into a clean notification
local messages = {}
vim.notify = function(msg)
    messages[#messages + 1] = tostring(msg)
end
local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local root = h.tempdir()
orch.setup({ root = root, silent = true })
orch.create_project(root)
state.add_external_tool(config.external_tool({ name = "ghost", program = "orch-no-such-program-xyz" }))
state.save()
local runner = require("orchlaunch.runner")
local sync_result = runner.run_external_tool("ghost")
h.eq("sync API returns the failed result", sync_result and sync_result.code, 127)
messages = {}
h.ok("running a missing external tool does not raise", function()
    runner.run_external_tool_async("ghost")
end)
vim.wait(500)
local text = table.concat(messages, "\n")
h.check("runner message names the problem", text:find("command not found", 1, true) ~= nil, text)
h.check("runner message has no Neovim internals", not text:find("vim/_core", 1, true), text)

h.done("process spawn errors")
