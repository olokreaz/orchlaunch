-- A persisted breakpoint whose file is missing must survive later edits: it is
-- skipped at load (with a warning), but `persist` must keep its record in
-- `.orch/breakpoints.json` instead of silently dropping it.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local dap_root = (vim.env.ORCHLAUNCH_DEPS and vim.env.ORCHLAUNCH_DEPS ~= "" and vim.env.ORCHLAUNCH_DEPS
    or vim.fn.stdpath("data") .. "/lazy") .. "/nvim-dap"
if vim.fn.isdirectory(dap_root) ~= 1 then
    print("SKIP  missing-file breakpoints: nvim-dap not installed")
    h.done("breakpoints missing-file (skipped)")
    return
end
vim.opt.rtp:append(dap_root)
require("dap")

local root = h.tempdir()
h.write(root .. "/a.cpp", "int a;\nint b;\n")

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local bpm = require("orchlaunch.breakpoints")

orch.create_project(root)
state.get().breakpoints = {
    { file = "a.cpp", line = 1 },
    { file = "moved.cpp", line = 5 },
}
state.save()
state.reset()
state.setup(root, root .. "/.orch")

h.eq("only the existing file is applied", bpm.load(), 1)

bpm.toggle_at("a.cpp", 2, {})

local kept = {}
for _, record in ipairs(state.get().breakpoints) do
    kept[record.file .. ":" .. record.line] = true
end
h.check("existing file breakpoint kept", kept["a.cpp:1"] == true)
h.check("new breakpoint recorded", kept["a.cpp:2"] == true)
h.check("missing-file breakpoint not dropped by a later edit", kept["moved.cpp:5"] == true)

h.done("breakpoints missing-file")
