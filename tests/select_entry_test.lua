-- Choosing an entry with vim.ui.select must move the cursor to that entry in
-- the real .orch file, not run it. A scripted picker stands in for the user.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local choose
local calls = {}
vim.ui.select = function(items, opts, cb)
    calls[#calls + 1] = { items = items, prompt = opts.prompt }
    local index = choose and choose(items)
    cb(index and items[index] or nil, index)
end

local messages = {}
vim.notify = function(msg, level)
    messages[#messages + 1] = { text = tostring(msg), level = level }
end

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local select = require("orchlaunch.select")

local root = h.tempdir()
orch.setup({ root = root, silent = true })
orch.create_project(root)
state.add_configuration(config.native({ name = "Alpha", target = "app" }))
state.add_configuration(config.native({ name = "Beta", target = "app" }))
state.save()

local orch_file = root .. "/.orch/run_configurations.json"
local lines = vim.fn.readfile(orch_file)
local beta_line
for n, line in ipairs(lines) do
    if line:find('"name": "Beta"', 1, true) then
        beta_line = n
    end
end
h.check("fixture has an entry named Beta", beta_line ~= nil)

vim.cmd("edit " .. vim.fn.fnameescape(orch_file))
vim.api.nvim_win_set_cursor(0, { 1, 0 })

-- Pick the second entry (Beta) by its name.
choose = function(items)
    for i, item in ipairs(items) do
        if item.name == "Beta" then
            return i
        end
    end
end

select.select_entry_and_jump()

h.eq("picker offered every configuration", #calls[1] and #calls[1].items, 2)
h.eq("the cursor is in the .orch file", vim.api.nvim_buf_get_name(0), orch_file)
h.eq("selecting Beta moves the cursor to its line", vim.api.nvim_win_get_cursor(0)[1], beta_line)
h.check("selecting an entry does not run it", not vim.tbl_contains(
    vim.tbl_map(function(m) return m.text end, messages), "[orchlaunch] running Beta"
))

-- Cancelling the picker leaves the cursor where it was.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
choose = function() return nil end
select.select_entry_and_jump()
h.eq("cancelling keeps the cursor", vim.api.nvim_win_get_cursor(0)[1], 1)

h.done("select entry and jump (vim.ui.select)")
