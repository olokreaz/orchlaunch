-- Preflight ("doctor"): the environment check used by :OrchLaunchCheck.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local preflight = require("orchlaunch.preflight")

local checks = preflight.checks()
h.check("checks are produced", #checks > 0)

local names = {}
for _, check in ipairs(checks) do
    h.check("check has a name", type(check.name) == "string" and check.name ~= "")
    h.check("check has a boolean status", type(check.ok) == "boolean")
    h.check("check has a detail", type(check.detail) == "string")
    h.check("check has a required flag", type(check.required) == "boolean")
    names[check.name] = check
end

h.check("cmake is checked", names["cmake"] ~= nil)
h.check("an LLDB adapter is checked", names["LLDB DAP adapter (lldb-dap)"] ~= nil)
h.check("GDB is checked", names["GDB"] ~= nil)
h.check("nvim-dap is checked", names["nvim-dap"] ~= nil)
h.check("fibrous is checked", names["fibrous.nvim"] ~= nil)

-- A PATH presence check must agree with `exepath` for the tools we can verify.
h.eq("cmake status matches exepath", names["cmake"].ok, vim.fn.exepath("cmake") ~= "")

-- missing() must only contain failing checks.
for _, check in ipairs(preflight.missing()) do
    h.check("missing entries are not ok", not check.ok)
end

h.eq("report has one line per check", #preflight.report(), #checks)
h.eq("ok() returns a boolean", type(preflight.ok()), "boolean")

-- run() reports every line through the supplied notifier.
local seen = 0
preflight.run(function(message, level)
    h.check("notified message is prefixed", message:find("^%[orchlaunch%] ") ~= nil)
    h.check("notified with a level", type(level) == "number")
    seen = seen + 1
end)
h.eq("run notified every check", seen, #checks)

h.done("preflight")
