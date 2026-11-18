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
local output = require("orchlaunch.runner.output")
local window = require("orchlaunch.runner.window")
local config = require("orchlaunch.config")

local M = {}

local WARN = vim.log.levels.WARN
local ERROR = vim.log.levels.ERROR

local ensure_settings_saved = persist.before_action
local run_cmake_step = cmake_steps.run_cmake_step
local run_cmake_step_async = cmake_steps.run_cmake_step_async
local start_async = cmake_steps.start_async

--- Per-call values of an external-tool step: `args`, `env`, `vars` from the
--- step itself, plus the owning configuration's scope (for `${target}`).
---@param item any
---@param scope? table
---@return table
local function call_of(item, scope, captured)
    local call = { scope = scope }
    if type(item) == "table" then
        call.args = item.args
        call.env = item.env
        -- Step-declared vars win over captured ones only if the step sets them.
        call.vars = vim.tbl_extend("force", captured or {}, item.vars or {})
    else
        call.vars = captured
    end
    return call
end

--- Spec for an `exec` step: the argv runs as given, without a shell. `cwd`
--- and `env` take the same macros as everything else.
---@param item table
---@param scope? table
---@return OrchProcessSpec
local function exec_spec(item, scope, captured)
    local vars_scope = vim.tbl_extend("force", scope or {}, { vars = captured or {} })
    local argv = state.resolve_list(item.argv, vars_scope)
    local program = table.remove(argv, 1)
    return {
        program = program,
        args = argv,
        cwd = state.resolve_path(item.cwd, vars_scope) or state.root(),
        env = state.resolve_environment(item.env, vars_scope),
        inherit_env = item.inherit_env ~= false,
        timeout = item.timeout or require("orchlaunch.tool_spec").DEFAULT_TIMEOUT_MS,
    }
end

--- Applies the output policy to one finished process step.
---@param win table run output window (from runner/window)
---@param label string e.g. "exec uname" or "external gen-assets"
---@param log any effective log policy
---@param result OrchProcessResult
---@param ok boolean
---@param scope? table
local function apply_output(win, label, log, result, ok, scope)
    local decision = output.decide(log, ok, label, result)
    if decision.action == "file" then
        local path = state.resolve_path(decision.path, scope)
        if path then
            vim.fn.mkdir(vim.fs.dirname(path), "p")
            vim.fn.writefile(decision.lines, path)
        end
    elseif decision.action == "window" then
        win.append(decision.lines, decision.open)
    elseif decision.action == "notify" then
        notify(decision.text, ERROR)
    end
end

--- Runs one `exec` step synchronously. Returns ok.
---@return boolean
local function run_exec(item, scope, captured, win, before_log)
    local log, log_err = output.normalize_log(output.effective_log(before_log, item.log))
    if not log then
        notify(("exec step: %s"):format(log_err), ERROR)
        return false
    end
    local spec = exec_spec(item, scope, captured)
    local result = process.run(spec)
    local ok = process.succeeded(result)
    apply_output(win, "exec " .. spec.program, log, result, ok, scope)
    if ok and item.capture then
        captured[item.capture] = output.capture_value(result.stdout)
    end
    return ok
end

--- Runs one `exec` step asynchronously.
local function run_exec_async(item, scope, captured, win, before_log, done)
    local log, log_err = output.normalize_log(output.effective_log(before_log, item.log))
    if not log then
        notify(("exec step: %s"):format(log_err), ERROR)
        done(false)
        return
    end
    local spec = exec_spec(item, scope, captured)
    start_async(spec, "exec " .. spec.program, function(result)
        local ok = process.succeeded(result)
        apply_output(win, "exec " .. spec.program, log, result, ok, scope)
        if ok and item.capture then
            captured[item.capture] = output.capture_value(result.stdout)
        end
        done(ok)
    end)
end

--- Per-step output policy for an `external` tool call: the same policy as
--- `exec`, so a tool's stdout and stderr are shown or filed consistently.
local function run_external(tool, item, scope, captured, win, before_log)
    local log, log_err = output.normalize_log(output.effective_log(before_log, item.log))
    if not log then
        notify(("external step: %s"):format(log_err), ERROR)
        return false
    end
    local result = process.run(tool_spec(tool, call_of(item, scope, captured)))
    local ok = process.succeeded(result)
    apply_output(win, "external " .. tool.name, log, result, ok, scope)
    return ok
end

local function run_external_async(tool, item, scope, captured, win, before_log, done)
    local log, log_err = output.normalize_log(output.effective_log(before_log, item.log))
    if not log then
        notify(("external step: %s"):format(log_err), ERROR)
        done(false)
        return
    end
    start_async(tool_spec(tool, call_of(item, scope, captured)), "external tool " .. tool.name, function(result)
        local ok = process.succeeded(result)
        apply_output(win, "external " .. tool.name, log, result, ok, scope)
        done(ok)
    end)
end

-- ============================================================================
-- Before launch
-- ============================================================================

--- Runs the before-launch actions in order. Returns false if one failed.
--- `before.log` is the default output policy for every step; a step's own
--- `log` overrides it. All process output goes to one window per run.
---@param before? OrchBefore
---@param scope? table
---@return boolean
local function run_before(before, scope)
    local captured = {}
    local win = window.new((scope and scope.target_name) or "run")
    local before_log = before and before.log
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
            if not run_external(tool, item, scope, captured, win, before_log) then
                return false
            end
        elseif kind == "exec" then
            if not run_exec(item, scope, captured, win, before_log) then
                return false
            end
        else
            notify(("unknown before-launch action: %s"):format(tostring(kind)), WARN)
        end
    end

    return true
end

--- Asynchronous before-launch chain. Same steps and policy as `run_before`.
---@param before? OrchBefore
---@param scope? table
---@param on_done fun(ok: boolean)
local function run_before_async(before, scope, on_done)
    local items = before and before.tools or {}
    local captured = {}
    local win = window.new((scope and scope.target_name) or "run")
    local before_log = before and before.log
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
            run_external_async(tool, item, scope, captured, win, before_log, function(ok)
                if ok then
                    next_item()
                else
                    on_done(false)
                end
            end)
        elseif kind == "exec" then
            run_exec_async(item, scope, captured, win, before_log, function(ok)
                if ok then
                    next_item()
                else
                    on_done(false)
                end
            end)
        else
            notify(("unknown before-launch action: %s"):format(tostring(kind)), WARN)
            next_item()
        end
    end

    next_item()
end

--- Runs one external tool on its own (no before-chain): synchronous.
--- Output follows the default policy (showIfError).
---@param tool OrchExternalTool
---@param call? table
---@return OrchProcessResult
local function run_tool(tool, call)
    local result = process.run(tool_spec(tool, call))
    apply_output(window.new(tool.name), "external " .. tool.name, "showIfError", result,
        process.succeeded(result), call and call.scope)
    return result
end

--- Runs one external tool on its own: asynchronous.
---@param tool OrchExternalTool
---@param call? table
---@param on_done fun(result: OrchProcessResult)
local function run_tool_async(tool, call, on_done)
    start_async(tool_spec(tool, call), "external tool " .. tool.name, function(result)
        apply_output(window.new(tool.name), "external " .. tool.name, "showIfError", result,
            process.succeeded(result), call and call.scope)
        on_done(result)
    end)
end

M.run_before = run_before
M.run_before_async = run_before_async
M.run_tool = run_tool
M.run_tool_async = run_tool_async

return M
