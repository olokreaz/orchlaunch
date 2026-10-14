local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
require("harness")

local config = require("orchlaunch.config")

local doc = {
    a = 1,
    rt = config.runtime({ x = 2 }),
    nested = { y = 3 },
}
local text = config.stringify(doc)
assert(text:find("a = 1"), "a missing")
assert(text:find("y = 3"), "nested y missing")
assert(not text:find("x = 2"), "runtime leaked")
assert(not text:find("_runtime"), "runtime key leaked")
print("OK")
