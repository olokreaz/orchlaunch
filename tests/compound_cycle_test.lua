-- Compound configurations may reference each other. A self-reference or a
-- cycle must be reported instead of recursing until the stack overflows.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local messages = {}
vim.notify = function(message)
    messages[#messages + 1] = tostring(message)
end

local function has(fragment)
    for _, message in ipairs(messages) do
        if message:find(fragment, 1, true) then
            return true
        end
    end
    return false
end

local root = h.tempdir()
local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local runner = require("orchlaunch.runner")

orch.create_project(root)

state.add_configuration(config.compound({ name = "Loop", configurations = { "Loop" } }))
local ok = pcall(runner.run, "Loop", { mode = "run" })
h.check("self-referencing compound does not throw", ok)
h.check("self-referencing compound is reported", has("cycle detected"))

messages = {}
state.add_configuration(config.compound({ name = "A", configurations = { "B" } }))
state.add_configuration(config.compound({ name = "B", configurations = { "A" } }))
ok = pcall(runner.run, "A", { mode = "run" })
h.check("cyclic compound does not throw", ok)
h.check("cyclic compound is reported", has("cycle detected"))

messages = {}
state.add_configuration(config.native({ name = "Leaf" }))
state.add_configuration(config.compound({ name = "Outer", configurations = { "Leaf" } }))
ok = pcall(runner.run, "Outer", { mode = "run" })
h.check("acyclic compound does not throw", ok)
h.check("acyclic compound has no cycle warning", not has("cycle detected"))

h.done("compound cycle detection")
