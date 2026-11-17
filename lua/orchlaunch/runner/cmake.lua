-- OrchLaunch — CMake build/configure/install/test steps.
--
-- Runs CMake steps synchronously or asynchronously, reports their result in
-- the quickfix list, and tracks the one cancellable step. Re-exported by
-- `orchlaunch.runner`, so existing callers are unchanged.

local cmake = require("orchlaunch.cmake")
local integrations = require("orchlaunch.integrations")
local notify = require("orchlaunch.notify").notify
local process = require("orchlaunch.process")
local M = {}

local WARN = vim.log.levels.WARN
local ERROR = vim.log.levels.ERROR
local DEFAULT_TIMEOUT_MS = 15 * 60 * 1000


local run_state = require("orchlaunch.runner.state")


--- Reports a completed CMake step in the quickfix list.
---@param label string
---@param spec OrchProcessSpec
---@param result OrchProcessResult
---@return boolean
local function report_cmake_result(label, spec, result)
    -- Compiler diagnostics go to the standard quickfix list; trouble.nvim,
    -- snacks.nvim and `:copen` render it without any OrchLaunch-specific UI.
    local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
    local qf_cwd = label == "configure" and spec.cwd or cmake.binary_dir()
    integrations.quickfix(("OrchLaunch: CMake %s"):format(label), output, qf_cwd)

    if not process.succeeded(result) then
        local detail = (result.stderr or ""):gsub("%s+$", "")
        if detail ~= "" then
            detail = ": " .. detail
        end
        local status = (result.signal or 0) ~= 0 and ("signal %d"):format(result.signal)
            or ("code %d"):format(result.code)
        notify(("CMake %s failed with %s%s"):format(label, status, detail), ERROR)
        return false
    end

    return true
end

--- Runs a CMake step spec synchronously, returning false on failure.
---@param label string
---@param spec OrchProcessSpec
---@return boolean
local function run_cmake_spec(label, spec)
    spec.timeout = spec.timeout or DEFAULT_TIMEOUT_MS
    local result = process.run(spec)
    return report_cmake_result(label, spec, result)
end

--- Runs a process asynchronously and delivers the result on the main loop.
---@param spec OrchProcessSpec
---@param label string
---@param on_done fun(result: OrchProcessResult)
local function start_async(spec, label, on_done)
    local finished = false
    local job

    local function finish(result)
        if finished then
            return
        end
        finished = true
        run_state.clear_if(job)
        vim.schedule(function()
            on_done(result)
        end)
    end

    spec.timeout = spec.timeout or DEFAULT_TIMEOUT_MS
    job = process.start(spec, finish)
    if not finished then
        run_state.set(job, label)
    end
end

--- Runs a CMake step asynchronously.
---@param label string
---@param spec OrchProcessSpec
---@param on_done fun(ok: boolean)
local function run_cmake_spec_async(label, spec, on_done)
    start_async(spec, label, function(result)
        on_done(report_cmake_result(label, spec, result))
    end)
end

--- Cancels the most recently started asynchronous build/tool step.
---@return boolean cancelled
function M.cancel()
    local job, label = run_state.get()
    if not job then
        notify("no build or tool step is running", WARN)
        return false
    end
    run_state.clear()
    local ok = pcall(job.kill, job, 15)
    if ok then
        notify(("cancelled %s"):format(label or "process"), WARN)
    else
        notify("failed to cancel the running process", ERROR)
    end
    return ok
end

--- Configures (and optionally builds/installs) the project before launch.
---@param step "build" | "install"
---@param target? string
---@return boolean
local function run_cmake_step(step, target)
    if not run_cmake_spec("configure", cmake.configure_spec()) then
        return false
    end

    if not run_cmake_spec("build", cmake.build_spec(target)) then
        return false
    end

    if step == "install" then
        if not run_cmake_spec("install", cmake.install_spec()) then
            return false
        end
    end

    return true
end

--- Asynchronous version of `run_cmake_step`.
---@param step "build" | "install"
---@param target? string
---@param on_done fun(ok: boolean)
local function run_cmake_step_async(step, target, on_done)
    run_cmake_spec_async("configure", cmake.configure_spec(), function(ok)
        if not ok then
            on_done(false)
            return
        end
        run_cmake_spec_async("build", cmake.build_spec(target), function(built)
            if not built or step ~= "install" then
                on_done(built)
                return
            end
            run_cmake_spec_async("install", cmake.install_spec(), on_done)
        end)
    end)
end

--- Runs only the CMake configure step.
---@return boolean
function M.configure()
    local ok = run_cmake_spec("configure", cmake.configure_spec())
    if ok then
        notify("CMake configure finished")
    end
    return ok
end

--- Builds the project (optionally a single target) and reports diagnostics in
--- the quickfix list.
---@param target? string
---@return boolean
function M.build(target)
    local ok = run_cmake_step("build", target)
    if ok then
        notify(target and ("build finished: " .. target) or "build finished")
    end
    return ok
end

--- Removes build outputs through the build tool's `clean` target.
---@return boolean
function M.clean()
    if not run_cmake_spec("clean", cmake.build_spec("clean")) then
        return false
    end
    notify("clean finished")
    return true
end

--- Clean + full configure/build (CLion's Rebuild).
---@param target? string
---@return boolean
function M.rebuild(target)
    if not M.clean() then
        return false
    end
    local ok = run_cmake_step("build", target)
    if ok then
        notify(target and ("rebuild finished: " .. target) or "rebuild finished")
    end
    return ok
end

--- Configure, build and install.
---@param target? string
---@return boolean
function M.install(target)
    local ok = run_cmake_step("install", target)
    if ok then
        notify("install finished")
    end
    return ok
end

--- Configure, build and run the project's CTest suite.
---@return boolean
function M.test()
    if not run_cmake_spec("configure", cmake.configure_spec()) then
        return false
    end
    if not run_cmake_spec("build", cmake.build_spec()) then
        return false
    end
    if not run_cmake_spec("test", cmake.test_spec()) then
        return false
    end
    notify("tests finished")
    return true
end

--- @param cb? fun(ok: boolean)
--- @return boolean ok
function M.configure_async(cb)
    run_cmake_spec_async("configure", cmake.configure_spec(), function(ok)
        if ok then
            notify("CMake configure finished")
        end
        if cb then
            cb(ok)
        end
    end)
    return true
end

--- @param target? string
--- @param cb? fun(ok: boolean)
--- @return boolean ok
function M.build_async(target, cb)
    run_cmake_step_async("build", target, function(ok)
        if ok then
            notify(target and ("build finished: " .. target) or "build finished")
        end
        if cb then
            cb(ok)
        end
    end)
    return true
end

--- @param cb? fun(ok: boolean)
--- @return boolean ok
function M.clean_async(cb)
    run_cmake_spec_async("clean", cmake.build_spec("clean"), function(ok)
        if ok then
            notify("clean finished")
        end
        if cb then
            cb(ok)
        end
    end)
    return true
end

--- @param target? string
--- @param cb? fun(ok: boolean)
--- @return boolean ok
function M.rebuild_async(target, cb)
    run_cmake_spec_async("clean", cmake.build_spec("clean"), function(cleaned)
        if not cleaned then
            if cb then
                cb(false)
            end
            return
        end
        run_cmake_step_async("build", target, function(ok)
            if ok then
                notify(target and ("rebuild finished: " .. target) or "rebuild finished")
            end
            if cb then
                cb(ok)
            end
        end)
    end)
    return true
end

--- @param target? string
--- @param cb? fun(ok: boolean)
--- @return boolean ok
function M.install_async(target, cb)
    run_cmake_step_async("install", target, function(ok)
        if ok then
            notify("install finished")
        end
        if cb then
            cb(ok)
        end
    end)
    return true
end

--- @param cb? fun(ok: boolean)
--- @return boolean ok
function M.test_async(cb)
    run_cmake_spec_async("configure", cmake.configure_spec(), function(configured)
        if not configured then
            if cb then
                cb(false)
            end
            return
        end
        run_cmake_spec_async("build", cmake.build_spec(), function(built)
            if not built then
                if cb then
                    cb(false)
                end
                return
            end
            run_cmake_spec_async("test", cmake.test_spec(), function(ok)
                if ok then
                    notify("tests finished")
                end
                if cb then
                    cb(ok)
                end
            end)
        end)
    end)
    return true
end

-- Used by the before-launch steps in runner.lua.
M.run_cmake_step = run_cmake_step
M.run_cmake_step_async = run_cmake_step_async
M.start_async = start_async

return M
