-- OrchLaunch — pluggable debugger backends.
--
-- A *backend* turns a backend-neutral `OrchDebugRequest` into a Debug Adapter
-- Protocol configuration plus the adapter definition nvim-dap should spawn. It
-- is the plugin's equivalent of CLion's debug profile: the session/state layer
-- and (eventually) the debugger UI stay agnostic, while the concrete debugger
-- (LLDB, GDB or any third-party DAP adapter) lives behind this registry.
--
-- Adding a debugger is a new module under `orchlaunch.debug.backends/` that
-- calls `M.register()`. Backends only *describe* things — they never touch
-- `dap.adapters` or call `dap.run` themselves.

local M = {}

--- @class OrchDebugRequest
--- @field mode "launch"|"attach"
--- @field name? string
--- @field backend? string Explicit backend name (highest priority).
--- @field adapter? string Requested adapter/debugger (e.g. "gdb", "lldb" or a path).
--- @field kind? string Adapter family hint ("lldb"|"gdb"|"custom").
--- @field dap_path? string Explicit adapter executable.
--- @field program? string
--- @field args? string[]
--- @field cwd? string
--- @field env? table<string, string>
--- @field connection? string "host:port" for attach.
--- @field pid? integer
--- @field stop_on_entry? boolean

--- @class OrchDebugBackend
--- @field name string Unique backend name.
--- @field run? fun(req: OrchDebugRequest, dap: table): any Full override (for non-DAP backends).
--- @field available fun(): boolean
--- @field adapter fun(req: OrchDebugRequest): { key: string, definition: table }
--- @field launch fun(req: OrchDebugRequest): table
--- @field attach fun(req: OrchDebugRequest): table

local registry = {}
local order = {}
local default_name = nil

--- Registers (or replaces) a backend.
--- @param backend OrchDebugBackend
function M.register(backend)
    assert(
        type(backend) == "table" and type(backend.name) == "string" and backend.name ~= "",
        "[orchlaunch] a debug backend requires a name"
    )
    if not registry[backend.name] then
        order[#order + 1] = backend.name
    end
    registry[backend.name] = backend
end

--- @param name? string
--- @return OrchDebugBackend?
function M.get(name)
    if not name or name == "" then
        return nil
    end
    return registry[name]
end

--- Marks `name` as the default backend.
--- @param name string
function M.set_default(name)
    assert(registry[name], ("[orchlaunch] unknown debug backend: %s"):format(name))
    default_name = name
end

--- @return OrchDebugBackend?
function M.default()
    if default_name then
        return registry[default_name]
    end
    return registry["lldb"] or (order[#order] and registry[order[#order]]) or nil
end

--- @return string[]
function M.list()
    return vim.deepcopy(order)
end

--- Discards every registration (tests only).
function M.reset()
    registry = {}
    order = {}
    default_name = nil
end

-- ============================================================================
-- Request helpers
-- ============================================================================

--- @param value? string
--- @return boolean
function M.is_path(value)
    return type(value) == "string" and value:find("[/\\]") ~= nil
end

--- Maps an adapter selector to a backend name, returning nil when the backend
--- cannot be determined (caller falls back to the default).
--- @param req OrchDebugRequest
--- @return string?
function M.adapter_to_backend(req)
    local selector = req.backend
    if not selector or selector == "" then
        selector = req.adapter
    end
    if not selector or selector == "" then
        selector = req.kind
    end
    if not selector or selector == "" then
        return nil
    end

    -- An adapter path such as `/usr/bin/gdb` still identifies the debugger;
    -- without this, it falls back to the default backend (lldb).
    if M.is_path(selector) then
        local base = vim.fs.basename(selector):lower()
        for _, name in ipairs(order) do
            if base:find(name, 1, true) then
                return name
            end
        end
        return nil
    end

    local name = selector:lower():gsub("%-dap$", "")
    if registry[name] then
        return name
    end
    if registry[selector] then
        return selector
    end
    return nil
end

--- Resolves the backend for a request, falling back to the default.
--- @param req OrchDebugRequest
--- @return OrchDebugBackend?
function M.resolve(req)
    return registry[M.adapter_to_backend(req) or ""] or M.default()
end

-- ============================================================================
-- DAP helpers
-- ============================================================================

--- Builds an executable DAP adapter definition.
--- @param spec { name: string, key?: string, command: fun(req: OrchDebugRequest): string, args?: string[], available?: fun(): boolean }
--- @return OrchDebugBackend
function M.executable_dap(spec)
    local key = spec.key or spec.name
    return {
        name = spec.name,
        available = spec.available or function()
            return vim.fn.executable(spec.command({})) == 1
        end,
        adapter = function(req)
            return {
                key = key,
                definition = {
                    type = "executable",
                    command = spec.command(req or {}),
                    args = spec.args,
                    name = key,
                },
            }
        end,
        launch = function(req)
            return M.dap_launch(req)
        end,
        attach = function(req)
            return M.dap_attach(req)
        end,
    }
end

--- Generic DAP `launch` request.
--- @param req OrchDebugRequest
--- @return table
function M.dap_launch(req)
    local config = {
        request = "launch",
        name = req.name or "Debug",
        program = req.program,
        args = req.args or {},
    }
    if req.cwd and req.cwd ~= "" then
        config.cwd = req.cwd
    end
    if req.env and next(req.env) ~= nil then
        config.env = req.env
    end
    if req.stop_on_entry ~= nil then
        config.stopOnEntry = req.stop_on_entry
    end
    return config
end

--- Generic DAP `attach` request.
--- @param req OrchDebugRequest
--- @return table
function M.dap_attach(req)
    local config = {
        request = "attach",
        name = req.name or "Attach",
    }

    local host, port = (req.connection or ""):match("([^:]+):(%d+)")
    if host then
        config.host = host
    end
    if port then
        config.port = tonumber(port)
    end
    if req.program then
        config.program = req.program
    end
    if req.pid then
        config.pid = req.pid
    end

    return config
end

return M
