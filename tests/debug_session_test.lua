-- Debug session bookkeeping: listeners attach once (no leak), variables are
-- fetched from the adapter and cached, evaluate goes through the session.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local requested = {}
local fake_session = {}
function fake_session:request(command, args, cb)
    requested[#requested + 1] = { command = command, args = args }
    if command == "variables" then
        cb(nil, { variables = { { name = "x", value = "1", type = "int", variablesReference = 0 } } })
    elseif command == "evaluate" then
        cb(nil, { result = "42" })
    end
end

local listeners = {
    after = {
        event_stopped = {},
        event_threads = {},
        event_stackTrace = {},
        event_scopes = {},
    },
}

package.loaded["dap"] = {
    listeners = listeners,
    session = function()
        return fake_session
    end,
    repl = { execute = function() end },
}
package.loaded["orchlaunch.debug.session"] = nil

local session = require("orchlaunch.debug.session")

-- 1. repeated sessions do not pile up listeners --------------------------------
session.start_session()
session.start_session()
h.eq("listeners attached exactly once", #listeners.after.event_stopped, 1)
h.eq("threads listener attached once", #listeners.after.event_threads, 1)

-- 2. variables are requested from the adapter and cached -----------------------
local got = nil
session.variables(7, function(vars)
    got = vars
end)
h.eq("variables request sent", requested[#requested].command, "variables")
h.eq("variables request reference", requested[#requested].args.variablesReference, 7)
h.eq("variables decoded", got and got[1] and got[1].name, "x")

local before = #requested
local cached = session.variables(7)
h.eq("cached variables returned", cached[1].name, "x")
h.eq("cache avoids a second request", #requested, before)

-- 3. evaluate goes through the session ----------------------------------------
local result = nil
session.evaluate("1+1", function(r)
    result = r
end)
h.eq("evaluate request sent", requested[#requested].command, "evaluate")
h.eq("evaluate expression forwarded", requested[#requested].args.expression, "1+1")
h.eq("evaluate result forwarded", result, "42")

h.done("debug session bookkeeping")
