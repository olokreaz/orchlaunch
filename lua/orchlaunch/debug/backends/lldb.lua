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

backend.register(backend.executable_dap({
    name = "lldb",
    key = "lldb-dap",
    command = resolve_dap_path,
    available = function()
        return vim.fn.exepath("lldb-dap") ~= "" or vim.fn.exepath("lldb-vscode") ~= ""
    end,
}))

return backend
