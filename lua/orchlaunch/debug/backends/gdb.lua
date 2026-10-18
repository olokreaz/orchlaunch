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

backend.register(backend.executable_dap({
    name = "gdb",
    key = "gdb",
    command = resolve_dap_path,
    args = { "--interpreter=dap", "--quiet" },
    available = function()
        return vim.fn.exepath("gdb") ~= ""
    end,
}))

return backend
