-- OrchLaunch — debug server started by the plugin for a remote-debug session.
--
-- `server = "lldb-server"` runs `lldb-server gdbserver :PORT -- PROGRAM`, and
-- `server = "gdbserver"` runs `gdbserver :PORT PROGRAM`. The server is started
-- before attach, is awaited until its port listens, and is stopped with the
-- session.

local process = require("orchlaunch.process")

local M = {}

local SERVERS = { ["lldb-server"] = true, ["gdbserver"] = true }

--- Returns true when `port` has a listening TCP socket (IPv4 or IPv6).
---@param port integer
---@return boolean
function M.listening(port)
    local needle = (":%04X"):format(port)
    for _, path in ipairs({ "/proc/net/tcp", "/proc/net/tcp6" }) do
        local file = io.open(path, "r")
        if file then
            for line in file:lines() do
                if line:find(needle, 1, true) and line:find(" 0A ", 1, true) then
                    file:close()
                    return true
                end
            end
            file:close()
        end
    end
    return false
end

--- Builds the command line for `server` listening on `port`.
---@param server string
---@param port integer
---@param program string
---@return string[]?
---@return string? err
function M.command(server, port, program)
    if not SERVERS[server] then
        return nil, ("unknown debug server %q (use lldb-server or gdbserver)"):format(tostring(server))
    end
    if not program or program == "" then
        return nil, "a debug server needs the program to run (the `symbol` field)"
    end
    if server == "lldb-server" then
        return { "lldb-server", "gdbserver", (":%d"):format(port), "--", program }
    end
    return { "gdbserver", (":%d"):format(port), program }
end

--- Starts the server. Returns a handle with `stop()`, or nil and a message.
---@param server string
---@param port integer
---@param program string
---@return table? handle
---@return string? err
function M.start(server, port, program)
    local command, err = M.command(server, port, program)
    if not command then
        return nil, err
    end
    if vim.fn.executable(command[1]) ~= 1 then
        return nil, ("%s is not installed"):format(command[1])
    end

    local job = process.start({ program = command[1], args = vim.list_slice(command, 2) }, nil)
    local handle = { job = job }
    function handle.stop()
        if job then
            pcall(function()
                job:kill(15)
                job:wait(2000)
            end)
        end
        return true
    end
    return handle
end

--- Waits until `port` listens or `timeout_ms` passes.
---@param port integer
---@param timeout_ms? integer
---@return boolean
function M.wait_listening(port, timeout_ms)
    return vim.wait(timeout_ms or 10000, function()
        return M.listening(port)
    end, 50)
end

return M
