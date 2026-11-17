-- Unit test: an external-tool before-step passes its own args, env and vars to
-- the tool, expands macros in them with the owning configuration's target, and
-- expands ${var:name} / ${var:name?default} in a single pass.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")
local config = require("orchlaunch.config")

local ctx = {
    workspace = "/ws",
    orch_dir = "/ws/.orch",
    target = "hello",
    vars = { var1 = "foo", var2 = "bar", tricky = "${target}" },
}

h.eq("${var:name} from vars", config.expand("${var:var1}", ctx), "foo")
h.eq("${var:name?default} uses value when set", config.expand("${var:var1?zzz}", ctx), "foo")
h.eq("${var:missing?fallback} uses default", config.expand("${var:nope?fallback}", ctx), "fallback")
h.eq("${var:missing} without default is kept", config.expand("${var:nope}", ctx), "${var:nope}")
h.eq("empty default is allowed", config.expand("${var:nope?}", ctx), "")
h.eq("macro mixed with var", config.expand("${workspace}/${target}/${var:var2}", ctx), "/ws/hello/bar")
h.eq("var value is not expanded again", config.expand("${var:tricky}", ctx), "${target}")

-- End to end: the tool spec built for a before-step uses the step's args and
-- env, the configuration's target, and the step's vars.
local tool_spec = require("orchlaunch.tool_spec")
local root = h.tempdir()
require("orchlaunch").setup({ root = root, silent = true })
require("orchlaunch").create_project(root)
local state = require("orchlaunch.state")

local tool = {
    name = "gen",
    program = "/bin/echo",
    args = { "base" },
    environment = { GEN_MODE = "tool", KEEP = "from-tool" },
}
local spec = tool_spec.build(tool, {
    scope = { target = "hello" },
    args = { "--opt", "${var:var1}", "--target", "${target}", "${var:none?dflt}" },
    env = { GEN_VERBOSE_LOG = "${workspace}/logs", GEN_MODE = "step" },
    vars = { var1 = "foo" },
})

h.eq("tool args come first", spec.args[1], "base")
h.eq("step args appended in order", table.concat(spec.args, " "), "base --opt foo --target hello dflt")
h.eq("step env overrides tool env", spec.env.GEN_MODE, "step")
h.eq("tool env kept when not overridden", spec.env.KEEP, "from-tool")
h.eq("step env expands workspace macro", spec.env.GEN_VERBOSE_LOG, state.root() .. "/logs")

local plain = tool_spec.build(tool)
h.eq("no call means tool args only", table.concat(plain.args, " "), "base")
h.eq("no call means tool env only", plain.env.GEN_MODE, "tool")

h.done("before-step tool vars")
