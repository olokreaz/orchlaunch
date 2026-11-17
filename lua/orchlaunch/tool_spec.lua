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
---@return table spec suitable for orchlaunch.process
function M.build(tool)
    return {
        program = state.resolve_tool(tool.program),
        args = state.resolve_list(tool.args),
        cwd = state.resolve_path(tool.cwd) or state.root(),
        env = state.resolve_environment(tool.environment),
        inherit_env = tool.inherit_env ~= false,
        sudo = tool.sudo == true,
        timeout = tool.timeout or DEFAULT_TIMEOUT_MS,
    }
end

return M
