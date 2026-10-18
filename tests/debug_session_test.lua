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
        event_continued = {},
        event_terminated = {},
        threads = {},
        stackTrace = {},
        scopes = {},
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
h.eq("threads listener attached once", #listeners.after.threads, 1)

-- 2. threads/frames/scopes come from request responses, not events -------------
-- (`threads`, `stackTrace` and `scopes` are responses nvim-dap fetches while
-- handling `stopped`; observing the nonexistent `event_*` names silently left
-- the session empty.)
listeners.after.event_stopped[1](nil, { threadId = 1 })
listeners.after.threads[1](nil, nil, { threads = { { id = 1, name = "main", selected = true } } })
h.eq("threads captured from response", session.threads()[1].name, "main")

listeners.after.stackTrace[1](nil, nil, {
    stackFrames = { { id = 10, name = "compute", line = 14, source = { path = "/tmp/prog.cpp" } } },
})
h.eq("frame captured from response", session.current_frame().line, 14)

listeners.after.scopes[1](nil, nil, { scopes = { { name = "Locals", variablesReference = 100 } } })
h.eq("scope captured from response", session.scopes()[1].name, "Locals")

-- 3. variables are requested from the adapter and cached -----------------------
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

-- 4. in-flight variables requests are deduplicated ----------------------------
-- An eager UI re-rendering while a stop is inspected used to send one request
-- per render (thousands), which stalled the adapter and froze the session.
local async_callbacks = {}
package.loaded["dap"].session = function()
    return {
        request = function(_, command, args, cb)
            async_callbacks[#async_callbacks + 1] = { command = command, cb = cb }
        end,
    }
end

session.variables(99, function() end)
session.variables(99, function() end)
session.variables(99)
h.eq("in-flight variables requests are deduplicated", #async_callbacks, 1)

local delivered = nil
session.variables(99, function(vars)
    delivered = vars
end)
async_callbacks[1].cb(nil, { variables = { { name = "y", value = "2", variablesReference = 0 } } })
h.eq("waiting callback receives variables", delivered and delivered[1] and delivered[1].name, "y")
h.eq("value decoded", delivered and delivered[1] and delivered[1].value, "2")

h.done("debug session bookkeeping")
