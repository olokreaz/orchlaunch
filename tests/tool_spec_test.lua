-- The external-tool spec builder lives in its own module. It must turn a
-- configured tool into a process spec with defaults applied, and it must be
-- the one used by the runner (no second copy).

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local ok, tool_spec = pcall(require, "orchlaunch.tool_spec")
h.check("orchlaunch.tool_spec module exists", ok, tostring(tool_spec))
if not ok then
    h.done("tool spec module")
    return
end

local orch = require("orchlaunch")
local root = h.tempdir()
orch.setup({ root = root, silent = true })
orch.create_project(root)

local spec = tool_spec.build({ name = "gen", program = "/bin/echo", args = { "a" } })
h.eq("program is kept", spec.program, "/bin/echo")
h.eq("default timeout is 15 minutes", spec.timeout, 15 * 60 * 1000)
h.eq("env inherited by default", spec.inherit_env, true)
h.eq("sudo is off by default", spec.sudo, false)

local explicit = tool_spec.build({ name = "slow", program = "/bin/echo", timeout = 5, inherit_env = false, sudo = true })
h.eq("explicit timeout wins", explicit.timeout, 5)
h.eq("explicit inherit_env wins", explicit.inherit_env, false)
h.eq("explicit sudo wins", explicit.sudo, true)

h.done("tool spec module")
