-- OrchLaunch — LLDB backend (lldb-dap / lldb-vscode).
--
-- Default backend. Speaks DAP to the LLDB adapter; the executable is resolved
-- from an explicit path, then `$PATH`.

local backend = require("orchlaunch.debug.backend")

--- @param req OrchDebugRequest
--- @return string
local function resolve_dap_path(req)
    if req and req.dap_path and req.dap_path ~= "" then
        return req.dap_path
    end
    for _, name in ipairs({ "lldb-dap", "lldb-vscode" }) do
        local path = vim.fn.exepath(name)
        if path ~= "" then
            return path
        end
    end
    return "lldb-dap"
end

--- lldb-dap's attach request. Unlike the generic helper, a remote target is
--- described with `gdb-remote-hostname`/`gdb-remote-port` (lldb-dap rejects the
--- generic `host`/`port` pair), and the local `program` is used for symbols.
--- @param req OrchDebugRequest
--- @return table
local function lldb_attach(req)
    local config = {
        request = "attach",
        name = req.name or "Attach",
    }

    if req.program and req.program ~= "" then
        config.program = req.program
    end
    if req.pid then
        config.pid = req.pid
    end

    local host, port = (req.connection or ""):match("([^:]*):(%d+)")
    if port then
        config["gdb-remote-port"] = tonumber(port)
        config["gdb-remote-hostname"] = (host ~= "" and host) or "localhost"
    end

    return config
end

local lldb = backend.executable_dap({
    name = "lldb",
    key = "lldb-dap",
    command = resolve_dap_path,
    available = function()
        return vim.fn.exepath("lldb-dap") ~= "" or vim.fn.exepath("lldb-vscode") ~= ""
    end,
})
lldb.attach = lldb_attach
backend.register(lldb)

return backend
