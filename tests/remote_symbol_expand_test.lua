-- The remote-debug `symbol` may use ${workspace}, like every other path field.
-- Both the debug server and the attach request must receive the expanded path.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")

local root = h.tempdir()
orch.setup({ root = root, silent = true })
orch.create_project(root)
state.add_configuration(config.remote_debug({
    name = "rel",
    symbol = "${workspace}/build/prog",
    connection = "localhost:1234",
    adapter = "lldb",
}))
state.save()

local cfg = state.require_configuration("rel")
local expanded = state.resolve_path(cfg.symbol)
h.eq("symbol expands ${workspace} to the project root", expanded, root .. "/build/prog")
h.check("expanded symbol is absolute", vim.startswith(expanded, "/"), expanded)

h.done("remote-debug symbol path expansion")
