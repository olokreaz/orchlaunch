-- Fibrous debugger panel: renders the neutral session and reacts to events.
--
-- Feed a mocked nvim-dap event sequence into the session, mount the panel and
-- assert it shows threads/frames/scopes/variables and updates on new events.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

if not (pcall(require, "fibrous")) then
    print("SKIP  fibrous is not installed")
    h.done("fibrous debugger (skipped)")
    return
end

vim.o.columns = 140
vim.o.lines = 40

local fake_session = {
    capabilities = {},
    request = function(_, command, _, cb)
        if command == "variables" then
            cb(nil, { variables = { { name = "counter", value = "42", type = "int", variablesReference = 0 } } })
        end
    end,
}
local listeners = {
    after = {
        event_stopped = {},
        event_continued = {},
        event_exited = {},
        event_terminated = {},
        event_threads = {},
        event_stackTrace = {},
        event_scopes = {},
    },
}
package.loaded["dap"] = {
    adapters = {},
    listeners = listeners,
    session = function()
        return fake_session
    end,
    run = function() end,
    close = function() end,
    continue = function() end,
    pause = function() end,
    step_over = function() end,
    step_into = function() end,
    step_out = function() end,
    restart = function() end,
}
package.loaded["orchlaunch.debug.session"] = nil
package.loaded["orchlaunch.debug.init"] = nil
package.loaded["orchlaunch.debug.backends"] = nil

local session = require("orchlaunch.debug.session")
session.attach_listeners()

listeners.after.event_stopped[1](nil, { threadId = 1 })
listeners.after.event_threads[1](nil, { threads = { { id = 1, name = "main", state = "stopped", selected = true } } })
listeners.after.event_stackTrace[1](nil, {
    threadId = 1,
    stackFrames = { { id = 10, name = "main", line = 3, column = 1, source = { name = "main.c", path = "/tmp/main.c" } } },
})
listeners.after.event_scopes[1](nil, { scopes = { { name = "Locals", variablesReference = 100, expensive = false } } })

local debugger = require("orchlaunch.ui.fibrous.debugger")
h.check("debugger available", debugger.available())

local handle = debugger.open()
h.check("panel mounted", handle ~= nil and vim.api.nvim_win_is_valid(handle.winid))
vim.wait(150)

local function screen()
    return table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
end

local text = screen()
h.contains("status line", text, "Debug — stopped")
h.contains("thread rendered", text, "main")
h.contains("frame rendered", text, "main.c:3")
h.contains("scope rendered", text, "Locals")
h.contains("variables fetched", text, "counter = 42")
h.contains("controls rendered", text, "Step Over")

-- A new event re-renders the panel.
listeners.after.event_threads[1](nil, { threads = { { id = 2, name = "worker", state = "running" } } })
vim.wait(150)
h.contains("panel reacts to new events", screen(), "worker")

debugger.close()
h.check("panel unmounted", handle.winid == nil or not vim.api.nvim_win_is_valid(handle.winid))

h.done("fibrous debugger")
