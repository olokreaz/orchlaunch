-- OrchLaunch — GDB backend (gdb --interpreter=dap).
--
-- GDB gained a DAP front-end, so it reuses the generic executable-DAP helpers.

local backend = require("orchlaunch.debug.backend")

--- @param req OrchDebugRequest
--- @return string
local function resolve_dap_path(req)
    if req and req.dap_path and req.dap_path ~= "" then
        return req.dap_path
    end
    return "gdb"
end

--- gdb's DAP `attach` does not take the generic `host`/`port` pair (it fails
--- with "attach requires either 'pid', 'target', or 'coreFile'"). A remote
--- target is given as `target = "host:port"`, which gdb turns into
--- `target remote host:port`.
--- @param req OrchDebugRequest
--- @return table
local function gdb_attach(req)
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
    if req.connection and req.connection ~= "" then
        config.target = req.connection
    end

    return config
end

local gdb = backend.executable_dap({
    name = "gdb",
    key = "gdb",
    command = resolve_dap_path,
    args = { "--interpreter=dap", "--quiet" },
    available = function()
        return vim.fn.exepath("gdb") ~= ""
    end,
})
gdb.attach = gdb_attach
backend.register(gdb)

return backend
