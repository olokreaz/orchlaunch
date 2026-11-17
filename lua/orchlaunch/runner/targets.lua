-- OrchLaunch — CMake target discovery and run-configuration sync.
--
-- Reads the File API model, records the targets it finds, and creates a
-- native run configuration for each target that does not have one yet.
-- Re-exported by `orchlaunch.runner`, so existing callers are unchanged.

local cmake = require("orchlaunch.cmake")
local notify = require("orchlaunch.notify").notify
local process = require("orchlaunch.process")
local persist = require("orchlaunch.runner.persist")
local run_state = require("orchlaunch.runner.state")
local state = require("orchlaunch.state")

local M = {}

local WARN = vim.log.levels.WARN
local ERROR = vim.log.levels.ERROR

--- Creates a native run configuration for *every* CMake target that does not
--- have one yet, whatever its type (executables, static/shared/module/object/
--- interface libraries, custom targets). Executables carry the target name in
--- `target`; all other kinds have no executable, so their `target` stays empty
--- and only the runtime kind is recorded. Every configuration builds before
--- launch, like CLion. Existing configurations (including ones created by hand
--- before the File API was parsed) are left untouched.
---@param targets OrchCMakeTarget[]
---@return integer created
local function sync_target_configurations(targets)
    local config = require("orchlaunch.config")
    local build_dir = cmake.binary_dir()
    local created = 0

    for _, target in ipairs(targets) do
        if not state.configuration(target.name) then
            local runtime = cmake.runtime_for(target.type)
            state.add_configuration(config.native({
                name = target.name,
                target = runtime == "executable" and target.name or nil,
                runtime = runtime,
                cwd = build_dir,
                before = config.before({ config.build(target.name) }),
            }))
            -- Persist immediately: the configuration exists from this moment on.
            state.save()
            created = created + 1
        end
    end

    return created
end

--- Configures the project and discovers its CMake targets (File API).
---
--- Every CMake target is turned into a native run configuration (unless a
--- configuration with the same name already exists).
---@return OrchCMakeTarget[]?
function M.load_cmake()
    if not state.is_loaded() then
        notify("no .orch project loaded", ERROR)
        return nil
    end

    persist.before_action()

    local targets, result = cmake.load_targets()
    if not targets then
        local detail = result and (result.stderr or ""):gsub("%s+$", "") or ""
        notify(("CMake configure failed%s"):format(detail ~= "" and (": " .. detail) or ""), ERROR)
        return nil
    end

    local created = sync_target_configurations(targets)

    if result and not process.succeeded(result) then
        local detail = (result.stderr or ""):gsub("%s+$", "")
        notify(
            ("CMake configure failed; showing %d cached target(s), %d run configuration(s) added%s"):format(
                #targets,
                created,
                detail ~= "" and (": " .. detail) or ""
            ),
            WARN
        )
        return targets
    end

    notify(
        ("CMake project loaded: %d target(s) discovered from %s, %d run configuration(s) added"):format(
            #targets,
            cmake.source_dir(),
            created
        )
    )
    return targets
end

--- Asynchronously configures the project and discovers its CMake targets.
---@param cb? fun(targets: OrchCMakeTarget[]?, created?: integer, result?: OrchProcessResult)
---@return boolean started
function M.load_cmake_async(cb)
    cb = cb or function() end
    if not state.is_loaded() then
        notify("no .orch project loaded", ERROR)
        cb(nil)
        return false
    end

    persist.before_action()

    local job
    local finished = false
    job = cmake.load_targets_async(function(targets, result)
        if finished then
            return
        end
        finished = true
        run_state.clear_if(job)

        if not targets then
            local detail = result and (result.stderr or ""):gsub("%s+$", "") or ""
            notify(("CMake configure failed%s"):format(detail ~= "" and (": " .. detail) or ""), ERROR)
            cb(nil, nil, result)
            return
        end

        local created = sync_target_configurations(targets)

        if result and not process.succeeded(result) then
            local detail = (result.stderr or ""):gsub("%s+$", "")
            notify(
                ("CMake configure failed; showing %d cached target(s), %d run configuration(s) added%s"):format(
                    #targets,
                    created,
                    detail ~= "" and (": " .. detail) or ""
                ),
                WARN
            )
            cb(targets, created, result)
            return
        end

        notify(
            ("CMake project loaded: %d target(s) discovered from %s, %d run configuration(s) added"):format(
                #targets,
                cmake.source_dir(),
                created
            )
        )
        cb(targets, created, result)
    end)

    run_state.set(job, "CMake load")
    return true
end

--- Discovers CMake targets from an existing build directory without reconfiguring.
---
--- Useful when configure is expensive and the build already contains a valid
--- CMake File API reply. Executable targets are turned into native run
--- configurations (unless a configuration with the same name already exists).
---@return OrchCMakeTarget[]?
function M.refresh_cmake()
    if not state.is_loaded() then
        notify("no .orch project loaded", ERROR)
        return nil
    end

    persist.before_action()

    local targets = cmake.refresh_targets()
    if not targets or #targets == 0 then
        notify("CMake targets not found; no existing File API reply in the build directory", ERROR)
        return nil
    end

    local created = sync_target_configurations(targets)

    notify(
        ("CMake targets refreshed: %d target(s) from %s, %d run configuration(s) added"):format(
            #targets,
            cmake.source_dir(),
            created
        )
    )

    return targets
end

return M
