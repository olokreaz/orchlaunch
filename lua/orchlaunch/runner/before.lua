-- OrchLaunch — before-launch steps.
--
-- Runs the steps a configuration asks for before it starts (CMake build or
-- install, external tools), synchronously or asynchronously, stopping at the
-- first failure. Used by the launch paths in `runner/launch.lua`.

local notify = require("orchlaunch.notify").notify
local persist = require("orchlaunch.runner.persist")
local cmake_steps = require("orchlaunch.runner.cmake")
local process = require("orchlaunch.process")
local state = require("orchlaunch.state")
local tool_spec = require("orchlaunch.tool_spec").build

local M = {}

local WARN = vim.log.levels.WARN
local ERROR = vim.log.levels.ERROR

local ensure_settings_saved = persist.before_action
local run_cmake_step = cmake_steps.run_cmake_step
local run_cmake_step_async = cmake_steps.run_cmake_step_async
local start_async = cmake_steps.start_async

--- Runs an external tool synchronously.
---@param tool OrchExternalTool
---@return OrchProcessResult
local function run_tool(tool)
    return process.run(tool_spec(tool))
end

-- ============================================================================
-- Before launch
-- ============================================================================

--- Runs the before-launch actions in order. Returns false if one failed.
---@param before? OrchBefore
---@return boolean
local function run_before(before)
    for _, item in ipairs(before and before.tools or {}) do
        local kind = type(item) == "table" and item.type or item

        if kind == "build" or kind == "install" then
            ensure_settings_saved()
            local target = type(item) == "table" and item.target or nil
            if not run_cmake_step(kind, target) then
                return false
            end
        elseif kind == "external" then
            local name = type(item) == "table" and item.tool or nil
            local tool = name and state.external_tool(name)

            if not tool then
                notify(("before-launch references unknown external tool: %s"):format(tostring(name)), ERROR)
                return false
            end

            local result = run_tool(tool)
            if not process.succeeded(result) then
                notify(("external tool %q failed with code %d"):format(name, result.code), ERROR)
                return false
            end
        else
            notify(("unknown before-launch action: %s"):format(tostring(kind)), WARN)
        end
    end

    return true
end

--- Asynchronous external-tool runner.
---@param tool OrchExternalTool
---@param on_done fun(result: OrchProcessResult)
local function run_tool_async(tool, on_done)
    start_async(tool_spec(tool), "external tool " .. tool.name, on_done)
end

--- Asynchronous before-launch chain.
---@param before? OrchBefore
---@param on_done fun(ok: boolean)
local function run_before_async(before, on_done)
    local items = before and before.tools or {}
    local index = 0

    local function next_item()
        index = index + 1
        local item = items[index]
        if item == nil then
            on_done(true)
            return
        end

        local kind = type(item) == "table" and item.type or item
        if kind == "build" or kind == "install" then
            ensure_settings_saved()
            local target = type(item) == "table" and item.target or nil
            run_cmake_step_async(kind, target, function(ok)
                if ok then
                    next_item()
                else
                    on_done(false)
                end
            end)
        elseif kind == "external" then
            local name = type(item) == "table" and item.tool or nil
            local tool = name and state.external_tool(name)
            if not tool then
                notify(("before-launch references unknown external tool: %s"):format(tostring(name)), ERROR)
                on_done(false)
                return
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
                    on_done(false)
                else
                    next_item()
                end
            end)
        else
            notify(("unknown before-launch action: %s"):format(tostring(kind)), WARN)
            next_item()
        end
    end

    next_item()
end

---@param cfg OrchNativeConfiguration
---@return string?

M.run_before = run_before
M.run_before_async = run_before_async
M.run_tool = run_tool
M.run_tool_async = run_tool_async

return M
