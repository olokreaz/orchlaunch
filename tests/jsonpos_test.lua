local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")
local jp = require("orchlaunch.jsonpos")

-- pretty-printed document, with braces/quotes hidden inside strings
local pretty = table.concat({
    "{",
    '  "configurations": [',
    "    {",
    '      "name": "A {weird} \\"name\\"",',
    '      "type": "native",',
    '      "args": ["-x", "}", "]"]',
    "    },",
    '    { "name": "B", "type": "compound" }',
    "  ]",
    "}",
}, "\n")
local root = assert(jp.parse(pretty))
h.eq("root is an object", root.kind, "object")
local list = jp.get(root, "configurations")
h.eq("array found", list and list.kind, "array")
h.eq("two entries", #list.items, 2)
h.eq("entry 1 starts on its brace line", list.items[1].line, 2)
h.eq("entry 1 ends on its closing line", list.items[1].end_line, 6)
h.eq("escaped quotes decode", jp.get_string(list.items[1], "name"), 'A {weird} "name"')
local m = jp.member(list.items[1], "type")
h.eq("key position: line", m.key_line, 4)
h.eq("key position: col", m.key_col, 6)
h.eq("braces inside strings are ignored", #jp.get(list.items[1], "args").items, 3)
h.eq("compact one-line entry starts correctly", list.items[2].line, 7)
h.eq("compact one-line entry ends on the same line", list.items[2].end_line, 7)
h.eq("compact entry name key line", jp.member(list.items[2], "name").key_line, 7)

-- paths and conversion
local cmake = assert(jp.parse('{"cmake": {"profiles": [{"name": "x"}]}}'))
h.eq("get_path", jp.get_path(cmake, { "cmake", "profiles" }).kind, "array")
h.eq("missing path is nil", jp.get_path(cmake, { "cmake", "nope" }), nil)
h.eq("to_lua round trip", jp.to_lua(cmake).cmake.profiles[1].name, "x")

-- scalars, empty containers, unicode
local misc = assert(jp.parse('{"a": [], "b": {}, "n": -1.5e2, "t": true, "f": false, "z": null, "u": "\\u00e9é"}'))
h.eq("empty array", #jp.get(misc, "a").items, 0)
h.eq("empty object", #jp.get(misc, "b").members, 0)
h.eq("number", jp.get(misc, "n").value, -150)
h.eq("true", jp.get(misc, "t").value, true)
h.eq("false", jp.get(misc, "f").value, false)
h.eq("null", jp.get(misc, "z").kind, "null")
h.eq("unicode", jp.get_string(misc, "u"), "éé")

-- errors carry a position
local bad, err, el, ec = jp.parse('{\n  "a": 1,\n  "b": oops\n}')
h.eq("invalid JSON returns nil", bad, nil)
h.check("error message present", type(err) == "string" and #err > 0, err)
h.eq("error line", el, 2)
h.check("error col is a number", type(ec) == "number")
h.eq("unterminated string", (jp.parse('{"a": "x')), nil)
h.eq("trailing content", (jp.parse('{"a": 1} x')), nil)
h.eq("trailing comma is rejected", (jp.parse('{"a": 1,}')), nil)
h.eq("empty input", (jp.parse("")), nil)

-- buffers
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(pretty, "\n"))
local broot = jp.parse_buffer(buf)
h.eq("parse_buffer", broot and jp.get(broot, "configurations").items[2].line, 7)

h.done("jsonpos")
