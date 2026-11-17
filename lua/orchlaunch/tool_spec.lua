-- OrchLaunch — turns a configured external tool into a process spec.
--
-- Pure: no UI and no state changes besides reading the project variables
-- through `state`. Used by the runner for external tools and before-launch
-- steps, so every tool gets the same defaults.

local state = require("orchlaunch.state")

local M = {}

local DEFAULT_TIMEOUT_MS = 15 * 60 * 1000

M.DEFAULT_TIMEOUT_MS = DEFAULT_TIMEOUT_MS

--- Builds the process spec for an external tool.
---@param tool table an external tool configuration
---@param call? { scope?: table, args?: string[], env?: table<string,string>, vars?: table<string,string> }
---  Per-call values from the before-step that invokes the tool. `args` are
---  appended after the tool's own args, `env` overrides its environment, and
---  `scope` / `vars` feed `${target}` and `${var:name}` macros.
---@return table spec suitable for orchlaunch.process
function M.build(tool, call)
    call = call or {}
    local scope = call.scope or {}
    scope = vim.tbl_extend("force", scope, { vars = call.vars })

    local args = state.resolve_list(tool.args, scope)
    for _, arg in ipairs(state.resolve_list(call.args, scope)) do
        args[#args + 1] = arg
    end

    local env = vim.tbl_extend(
        "force",
        state.resolve_environment(tool.environment, scope),
        state.resolve_environment(call.env, scope)
    )

    return {
        program = state.resolve_tool(tool.program, scope),
        args = args,
        cwd = state.resolve_path(tool.cwd, scope) or state.root(),
        env = env,
        inherit_env = tool.inherit_env ~= false,
        sudo = tool.sudo == true,
        timeout = tool.timeout or DEFAULT_TIMEOUT_MS,
    }
end

return M
