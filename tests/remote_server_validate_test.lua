-- Semantic checks for the remote-debug `server` field: an unknown server name
-- is an error on its line, and a server without `symbol` is an error too,
-- because the plugin has no program to start.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")
local validate = require("orchlaunch.validate")
local SEV = vim.diagnostic.severity

local text = table.concat({
    '{',
    '  "configurations": [',
    '    { "name": "BadServer", "type": "remote-debug", "connection": "localhost:1234", "symbol": "/x", "server": "lldbserver" },',
    '    { "name": "NoSymbol", "type": "remote-debug", "connection": "localhost:1234", "server": "gdbserver" },',
    '    { "name": "Good", "type": "remote-debug", "connection": "localhost:1234", "symbol": "/x", "server": "gdbserver" },',
    '    { "name": "External", "type": "remote-debug", "connection": "localhost:1234", "symbol": "/x" }',
    '  ]',
    '}',
}, "\n")

local d = validate.check("run_configurations", text, { toolchains = {}, tools = {} })

local function find(fragment, severity)
    for _, diag in ipairs(d) do
        if diag.message:find(fragment, 1, true) and diag.severity == severity then
            return diag
        end
    end
end

local bad = find("unknown debug server", SEV.ERROR)
h.check("unknown server name is an ERROR", bad ~= nil, vim.inspect(d))
h.eq("unknown server points at its line", bad and bad.lnum, 2)

local nosym = find("needs a 'symbol'", SEV.ERROR)
h.check("server without symbol is an ERROR", nosym ~= nil, vim.inspect(d))
h.eq("server without symbol points at its line", nosym and nosym.lnum, 3)

-- Valid cases must not be reported at all.
local ok_lines = {}
for _, diag in ipairs(d) do
    if diag.lnum == 4 or diag.lnum == 5 then
        ok_lines[#ok_lines + 1] = diag.message
    end
end
h.eq("valid server and external (no server) produce no diagnostics", #ok_lines, 0, vim.inspect(ok_lines))

h.done("remote-debug server field validation")
