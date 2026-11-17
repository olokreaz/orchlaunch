-- Unit test: each completion kind has its own icon and highlight group, and
-- the highlight groups link to standard groups (so they follow the theme).
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")
local completion = require("orchlaunch.completion")

local icons, groups = {}, {}
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '{ "configurations": [] }' })

-- Macros + starters come from "", declared vars from "var:", env from "env:".
for _, prefix in ipairs({ "", "var:", "env:" }) do
    for _, it in ipairs(completion.items(prefix, bufnr)) do
        icons[it.kind.icon] = true
        groups[it.kind.hl] = true
    end
end
local icon_count, group_count = 0, 0
for _ in pairs(icons) do icon_count = icon_count + 1 end
for _ in pairs(groups) do group_count = group_count + 1 end

h.check("macros, var: and env: are not all the same icon", icon_count >= 3, icon_count)
h.check("at least three distinct highlight groups", group_count >= 3, group_count)

for group, link in pairs(completion.highlights()) do
    h.check(group .. " links to a standard group", type(link) == "string" and link ~= "", link)
end

h.check("every item group is defined", (function()
    local defined = completion.highlights()
    for group in pairs(groups) do
        if defined[group] == nil then return false end
    end
    return true
end)())

h.done("completion style")
