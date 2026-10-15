-- Unit test: the configuration layer — variable/path resolution, JSON and Lua
-- serialization round-trips. These are the primitives every other feature is
-- built on, so they get their own edge-case coverage.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local config = require("orchlaunch.config")

local ctx = { workspace = "/ws", orch_dir = "/ws/.orch" }

-- ============================================================================
-- Variable expansion + path resolution
-- ============================================================================
h.eq("expand workspace", config.expand("${workspace}/build", ctx), "/ws/build")
h.eq("expand orch", config.expand("${orch}", ctx), "/ws/.orch")
h.eq("expand leaves unknown variables", config.expand("${workspace}/${nope}", ctx), "/ws/${nope}")

h.check("is_absolute posix", config.is_absolute("/usr/bin"))
h.check("is_absolute windows", config.is_absolute("C:\\tools"))
h.check("is_absolute lowercase drive", config.is_absolute("c:/tools"))
h.check("relative is not absolute", not config.is_absolute("build/debug"))
h.check("dot relative is not absolute", not config.is_absolute("./build"))

h.eq("resolve_path expands + anchors at .orch", config.resolve_path("build", ctx), "/ws/.orch/build")
h.eq("resolve_path expands variables", config.resolve_path("${workspace}/out", ctx), "/ws/out")
h.eq("resolve_path keeps absolute", config.resolve_path("/tmp/x", ctx), "/tmp/x")
h.eq("resolve_path passes nil", config.resolve_path(nil, ctx), nil)
h.eq("resolve_path passes empty", config.resolve_path("", ctx), "")

h.eq("resolve_tool keeps bare name on PATH", config.resolve_tool("cmake", ctx), "cmake")
h.eq("resolve_tool resolves relative path", config.resolve_tool("./tools/gen", ctx), "/ws/.orch/tools/gen")
h.eq("resolve_tool keeps absolute", config.resolve_tool("/usr/bin/gcc", ctx), "/usr/bin/gcc")
h.eq("resolve_tool expands variables", config.resolve_tool("${workspace}/gen", ctx), "/ws/gen")

h.eq("resolve_list expands every entry", config.resolve_list({ "a", "${workspace}" }, ctx), { "a", "/ws" })
h.eq("resolve_list empty", config.resolve_list(nil, ctx), {})
h.eq("resolve_environment expands values", config.resolve_environment({ K = "${workspace}/x" }, ctx), { K = "/ws/x" })

-- ============================================================================
-- JSON round-trip
-- ============================================================================
local doc = {
    title = "Orch",
    count = 3,
    ratio = 1.5,
    flag = true,
    list = { "a", "b", "c" },
    nested = { x = 1, y = { z = "deep" } },
    group = { items = { { id = 1 }, { id = 2 } } },
    weird = {
        ["dash-key"] = "dashes",
        ["local"] = "keyword",
        special = "quote\" back\\ newline\n tab\t end",
        unicode = "héllo ☃",
    },
}

local decoded = vim.json.decode(config.stringify(doc))
h.eq("json round-trip", decoded, doc)
h.eq("json inline array of tables", decoded.group.items, { { id = 1 }, { id = 2 } })
h.eq("json quoted keyword key", decoded.weird["local"], "keyword")
h.eq("json escaped string", decoded.weird.special, "quote\" back\\ newline\n tab\t end")
h.eq("json unicode string", decoded.weird.unicode, "héllo ☃")

-- ============================================================================
-- File persistence
-- ============================================================================
local dir = h.tempdir()
local path = dir .. "/deep/nested/settings.json"
h.check("save creates parent directories", config.save(path, { a = 1, b = { c = "d" } }))
h.check("saved file exists", vim.fn.filereadable(path) == 1)
h.eq("load round-trips", config.load(path), { a = 1, b = { c = "d" } })
h.eq("load missing file is empty", config.load(dir .. "/absent.json"), {})

-- ============================================================================
-- Lua literal round-trip (scratch-buffer editor)
-- ============================================================================
local value = {
    name = "Profile",
    enabled = true,
    args = { "a", "b" },
    environment = { K = "v", ["local"] = "kw" },
    nested = { deep = { level = 3 } },
    empty = {},
}
local literal = config.to_lua(value)
local back = config.from_lua("return " .. literal)
h.eq("lua round-trip", back, value)

h.done("configuration layer")
