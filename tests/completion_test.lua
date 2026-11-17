-- Unit test: `${` completion offers macros, declared before-step vars and set
-- environment variables, and only where the cursor is inside `${...`.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")
local completion = require("orchlaunch.completion")

h.eq("prefix after ${", completion.prefix_at('"args": ["${'), "")
h.eq("prefix keeps typed letters", completion.prefix_at('x ${build'), "build")
h.eq("prefix keeps var:", completion.prefix_at('${var:v'), "var:v")
h.eq("no prefix outside ${", completion.prefix_at('plain text'), nil)
h.eq("closed ${x} is not a prefix", completion.prefix_at('${x}'), nil)

local labels = {}
for _, m in ipairs(completion.MACROS) do labels[#labels + 1] = m.label end
h.eq("macro list has buildDir", vim.tbl_contains(labels, "buildDir"), true)
h.eq("macro list has targetPath", vim.tbl_contains(labels, "targetPath"), true)

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "{",
    '  "configurations": [',
    '    { "name": "Game", "type": "native", "target": "game",',
    '      "before": { "tools": [',
    '        { "type": "external", "tool": "gen",',
    '          "vars": { "var1": "foo", "var2": "bar" },',
    '          "args": ["--opt", "${var:var1}"] }',
    "      ] } }",
    "  ]",
    "}",
})

local macro_items = completion.items("", bufnr)
local has = {}
for _, it in ipairs(macro_items) do has[it.label] = it.insert end
h.eq("empty prefix offers buildDir", has.buildDir, "buildDir}")
h.eq("empty prefix offers var:", has["var:"], "var:")
h.eq("empty prefix offers env:", has["env:"], "env:")

local var_items = completion.items("var:", bufnr)
local var_labels = {}
for _, it in ipairs(var_items) do var_labels[#var_labels + 1] = it.label end
h.eq("var: offers only declared names", table.concat(var_labels, ","), "var:var1,var:var2")

vim.env.ORCH_COMPLETION_TEST = "1"
local env_items = completion.items("env:", bufnr)
local env_has = false
for _, it in ipairs(env_items) do
    if it.label == "env:ORCH_COMPLETION_TEST" then env_has = true end
end
h.eq("env: offers the set environment variable", env_has, true)

h.done("completion")
