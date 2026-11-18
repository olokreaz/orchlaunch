-- Integration test: `exec` before-steps run argv without a shell, `capture`
-- feeds later steps through ${var:name}, `log` controls output, and the
-- validator rejects malformed exec steps.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")
local orch = require("orchlaunch")
local before = require("orchlaunch.runner.before")
local state = require("orchlaunch.state")
local validate = require("orchlaunch.validate")
local config = require("orchlaunch.config")

local root = h.tempdir()
orch.setup({ root = root, silent = true })
orch.create_project(root)

-- 1. argv runs without a shell: a literal `$HOME` is not expanded.
-- If a shell expanded $HOME, the captured value would be the home path; with
-- no shell it stays the literal text, so the second step's comparison holds.
local literal = before.run_before({ tools = {
  { type = "exec", argv = { "echo", "$HOME" }, capture = "lit" },
  { type = "exec", argv = { "sh", "-c", "test \"$1\" = '$HOME'", "sh", "${var:lit}" } },
} }, nil)
h.check("argv is not shell-expanded ($HOME stays literal)", literal)

-- 2. capture + later ${var:...} inside a second exec step's argv.
local chain = before.run_before({ tools = {
  { type = "exec", argv = { "sh", "-c", "printf 'linux\n\n'" }, capture = "uname" },
  { type = "exec", argv = { "sh", "-c", "test \"$1\" = linux", "sh", "${var:uname}" } },
} }, nil)
h.check("captured value reaches a later argv (exit 0)", chain)

-- 3. a failing step stops the chain and returns false.
local failing = before.run_before({ tools = {
  { type = "exec", argv = { "sh", "-c", "exit 3" } },
  { type = "exec", argv = { "true" } },
} }, nil)
h.check("failing exec stops the chain", failing == false)

-- 4. capture stores stdout without trailing newlines.
local captured_ok = before.run_before({ tools = {
  { type = "exec", argv = { "sh", "-c", "printf 'abc\n\n'" }, capture = "v" },
  { type = "exec", argv = { "sh", "-c", "test \"$1\" = abc", "sh", "${var:v}" } },
} }, nil)
h.check("capture drops trailing newlines", captured_ok)

-- 5. the macro vocabulary works inside exec argv (buildDir from the project).
local macro_ok = before.run_before({ tools = {
  { type = "exec", argv = { "sh", "-c", "test -n \"$1\"", "sh", "${workspace}" } },
} }, nil)
h.check("macros expand in exec argv", macro_ok)

-- 6. validator: a well-formed exec step is clean, malformed ones are errors.
local function diags_for(step)
    local text = vim.json.encode({ configurations = {
        { name = "G", type = "native", target = "g", before = { tools = { step } } },
    } })
    return validate.check("run_configurations", text, validate.context())
end
local function has_error(list)
    for _, d in ipairs(list) do
        if d.severity == vim.diagnostic.severity.ERROR then return true end
    end
    return false
end
h.check("valid exec step has no error", not has_error(diags_for({ type = "exec", argv = { "uname" }, capture = "u" })))
h.check("empty argv is an error", has_error(diags_for({ type = "exec", argv = {} })))
h.check("bad capture name is an error", has_error(diags_for({ type = "exec", argv = { "x" }, capture = "1bad" })))
h.check("unknown log mode is an error", has_error(diags_for({ type = "exec", argv = { "x" }, log = "loud" })))
h.check("file log object is accepted", not has_error(diags_for({ type = "exec", argv = { "x" }, log = { file = "/tmp/x" } })))

-- 7. before.log is validated too.
local function before_log_diags(log)
    local text = vim.json.encode({ configurations = {
        { name = "G", type = "native", target = "g", before = { log = log, tools = { { type = "exec", argv = { "x" } } } } },
    } })
    return validate.check("run_configurations", text, validate.context())
end
h.check("valid before.log is accepted", not has_error(before_log_diags("show")))
h.check("unknown before.log policy is an error", has_error(before_log_diags("loud")))

-- 8. the output window: one buffer per run, appended to by every step.
local window = require("orchlaunch.runner.window")
local win = window.new("demo")
win.append({ "== a ==", "[out] one" }, false)
win.append({ "== b ==", "[err] two" }, false)
local buf = win.buf
h.eq("window keeps one buffer across appends", vim.api.nvim_buf_line_count(buf), 4)
h.eq("window appends in order", vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1], "[err] two")
h.eq("window buffer is read-only for the user", vim.bo[buf].modifiable, false)

h.done("before exec steps")
