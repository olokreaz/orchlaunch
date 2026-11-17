-- OrchLaunch — Run/Debug dispatch.
--
-- Public entry point for running, debugging and building. The implementation is
-- split across runner/: cmake.lua (build steps), before.lua (before-launch),
-- launch.lua (run and debug paths), targets.lua (CMake target discovery) and
-- state.lua / persist.lua (shared job state and saving). This module only
-- re-exports them, so `require("orchlaunch.runner")` keeps its API.

local process = require("orchlaunch.process")
local notify = require("orchlaunch.notify").notify
local before = require("orchlaunch.runner.before")
local state = require("orchlaunch.state")

local M = {}

local ERROR = vim.log.levels.ERROR

local run_tool = before.run_tool
local run_tool_async = before.run_tool_async

-- CMake steps
local cmake_steps = require("orchlaunch.runner.cmake")
M.cancel = cmake_steps.cancel
M.configure = cmake_steps.configure
M.build = cmake_steps.build
M.clean = cmake_steps.clean
M.rebuild = cmake_steps.rebuild
M.install = cmake_steps.install
M.test = cmake_steps.test
M.configure_async = cmake_steps.configure_async
M.build_async = cmake_steps.build_async
M.clean_async = cmake_steps.clean_async
M.rebuild_async = cmake_steps.rebuild_async
M.install_async = cmake_steps.install_async
M.test_async = cmake_steps.test_async

-- CMake target discovery
local targets = require("orchlaunch.runner.targets")
M.load_cmake = targets.load_cmake
M.load_cmake_async = targets.load_cmake_async
M.refresh_cmake = targets.refresh_cmake

-- Launching
local launch = require("orchlaunch.runner.launch")
M.run = launch.run
M.run_active = launch.run_active
M.launch_environment = launch.launch_environment
M.launch_adapter = launch.launch_adapter

--- Runs an external tool by name synchronously.
---@param name string
---@return OrchProcessResult?
function M.run_external_tool(name)
    if not state.is_loaded() then
        notify("no .orch project loaded", ERROR)
        return nil
    end

    local tool = state.external_tool(name)
    if not tool then
        notify(("external tool not found: %s"):format(name), ERROR)
        return nil
    end

    return run_tool(tool)
end

--- Runs an external tool by name asynchronously.
---@param name string
---@param cb? fun(result: OrchProcessResult?)
---@return boolean started
function M.run_external_tool_async(name, cb)
    cb = cb or function() end
    if not state.is_loaded() then
        notify("no .orch project loaded", ERROR)
        cb(nil)
        return false
    end

    local tool = state.external_tool(name)
    if not tool then
        notify(("external tool not found: %s"):format(name), ERROR)
        cb(nil)
        return false
    end

    run_tool_async(tool, function(result)
        if not process.succeeded(result) then
            local detail = (result.stderr or ""):gsub("%s+$", "")
            notify(
                ("external tool %q failed with code %d%s"):format(
                    name,
                    result.code,
                    detail ~= "" and (": " .. detail) or ""
                ),
                ERROR
            )
        else
            notify(("external tool %q finished with code %d"):format(name, result.code))
        end
        cb(result)
    end)
    return true
end

return M
