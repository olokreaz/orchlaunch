-- Specification: the configuration layer stores JSON, not TOML.
--
-- These tests define the target behaviour of the JSON config backend:
--   * `stringify` produces deterministic, pretty-printed JSON;
--   * `load`/`save` round-trip through `vim.json`, with no `toml` dependency;
--   * scalar escaping, unicode and empty tables survive the round-trip.
--
-- They are written before the core is migrated, so they fail against the TOML
-- implementation on purpose.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local config = require("orchlaunch.config")

-- No TOML backend must be required by the config layer.
h.check("toml module not required", package.loaded["toml"] == nil, "config layer pulled in `toml`")

-- ============================================================================
-- Round-trip through the real JSON decoder
-- ============================================================================
local doc = {
    title = "Orch",
    count = 3,
    ratio = 1.5,
    flag = true,
    list = { "a", "b", "c" },
    nested = { x = 1, y = { z = "deep" } },
    group = { items = { { id = 1 }, { id = 2 } } },
    configs = {
        { name = "A", type = "native", args = { "-x", "-y" }, environment = { K = "v" } },
        { name = "B", type = "compound", configurations = { "A" } },
    },
    weird = {
        ["dash-key"] = "dashes",
        special = "quote\" back\\ newline\n tab\t end",
        unicode = "héllo ☃",
    },
}

local text = config.stringify(doc)
h.check("stringify produced text", type(text) == "string" and #text > 0)

local decoded = vim.json.decode(text)
h.eq("json full round-trip", decoded, doc)

-- ============================================================================
-- Output shape: pretty, deterministic, sorted keys
-- ============================================================================
h.check("output is pretty printed", text:find("\n", 1, true) ~= nil and text:find("  ", 1, true) ~= nil)
h.check("output ends with a newline", text:sub(-1) == "\n")
h.eq("stringify is deterministic", config.stringify(doc), text)

local ordered = config.stringify({ z = 1, a = 2, m = 3 })
h.check(
    "object keys are sorted",
    ordered:find('"a"', 1, true) < ordered:find('"m"', 1, true)
        and ordered:find('"m"', 1, true) < ordered:find('"z"', 1, true),
    ordered
)

-- Non-empty tables of arrays keep element order.
local arr = config.stringify({ list = { "c", "a", "b" } })
h.check("array order preserved", arr:find('"c"', 1, true) < arr:find('"a"', 1, true), arr)

-- Empty tables are represented unambiguously and decode back to empty tables.
local empty = vim.json.decode(config.stringify({ e = {} }))
h.check("empty table round-trips", type(empty.e) == "table" and next(empty.e) == nil, vim.inspect(empty.e))

-- ============================================================================
-- File persistence
-- ============================================================================
local dir = h.tempdir()
local path = dir .. "/deep/nested/settings.json"
h.check("save creates parent directories", config.save(path, { a = 1, b = { c = "d" } }))
h.check("saved file exists", vim.fn.filereadable(path) == 1)
h.eq("saved file is valid JSON", vim.json.decode(h.read(path)), { a = 1, b = { c = "d" } })
h.eq("load round-trips", config.load(path), { a = 1, b = { c = "d" } })
h.eq("load missing file is empty", config.load(dir .. "/absent.json"), {})

-- A file holding only whitespace is treated as empty, not as an error.
h.write(dir .. "/blank.json", "  \n")
h.eq("load blank file is empty", config.load(dir .. "/blank.json"), {})

h.done("json config layer")
