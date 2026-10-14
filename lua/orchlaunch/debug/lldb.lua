-- Backend for lldb-dap
local M = {}

function M.get_dap_adapter(kind, dap_path)
    -- kind: "lldb"|"gdb"|"custom"
    if kind == "gdb" then
        return {
            type = "executable",
            command = dap_path or "gdb",
            args = { "--interpreter=dap", "--quiet" },
            name = "gdb",
        }
    end
    if kind == "lldb" or kind == "custom" then
        return {
            type = "executable",
            command = dap_path or "/usr/bin/lldb-dap",
            name = "lldb-dap",
        }
    end
    -- default to lldb-dap
    return {
        type = "executable",
        command = dap_path or "/usr/bin/lldb-dap",
        name = "lldb-dap",
    }
end

local function ensure_adapter(dap, adapter, key)
    key = key or adapter.name or "lldb-dap"
    if not dap.adapters[key] then
        dap.adapters[key] = adapter
    end
    return key
end

function M.launch_native(dap, opts)
    local a = M.get_dap_adapter(opts.kind or "lldb", opts.dap_path)
    local key = ensure_adapter(dap, a)
    local config = {
        type = key,
        request = "launch",
        name = opts.name or "Debug",
        program = opts.program,
        args = opts.args or {},
        cwd = opts.cwd,
        env = opts.env,
    }
    if opts.stopOnEntry ~= nil then
        config.stopOnEntry = opts.stopOnEntry
    end
    return config
end

function M.attach_remote(dap, opts)
    local a = M.get_dap_adapter(opts.kind or "lldb", opts.dap_path)
    local key = ensure_adapter(dap, a)
    local host, port = (opts.connection or ""):match("([^:]+):(%d+)")
    local config = {
        type = key,
        request = "attach",
        name = opts.name or "Attach",
        host = host,
        port = port and tonumber(port),
    }
    if opts.program then
        config.program = opts.program
    end
    if opts.pid then
        config.pid = opts.pid
    end
    return config
end

return M
