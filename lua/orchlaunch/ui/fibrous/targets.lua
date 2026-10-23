-- OrchLaunch — CMake targets browser on fibrous.
--
-- Lists every target reported by the CMake File API (name, type, artifact) and
-- lets the user build it, run/debug its native configuration, or edit that
-- configuration. It is the CLion-style "targets" view: build targets are
-- first-class, not an implementation detail of the run-configuration list.

local list = require("orchlaunch.ui.fibrous.list")

local M = {}

--- @param target OrchCMakeTarget
--- @return OrchNativeConfiguration
local function ensure_configuration(target)
    local state = require("orchlaunch.state")
    local config = require("orchlaunch.config")
    local cmake = require("orchlaunch.cmake")

    local cfg = state.configuration(target.name)
    if cfg then
        return cfg
    end

    local runtime = cmake.runtime_for(target.type)
    cfg = config.native({
        name = target.name,
        runtime = runtime,
        target = runtime == "executable" and target.name or nil,
        cwd = cmake.binary_dir(),
        before = config.before({ config.build(target.name) }),
    })
    state.add_configuration(cfg)
    state.save()
    return cfg
end

--- @param target OrchCMakeTarget
--- @return string
local function details(target)
    local state = require("orchlaunch.state")
    local cmake = require("orchlaunch.cmake")
    local cfg = state.configuration(target.name)

    local lines = {
        ("Name:  %s"):format(target.name),
        ("Type:  %s"):format(target.type or "—"),
        ("Runtime:  %s"):format(cmake.runtime_for(target.type)),
        ("Artifact:  %s"):format(target.artifact or "—"),
        ("Configuration:  %s"):format(cfg and cfg.name == target.name and "yes" or "no"),
    }
    return table.concat(lines, "\n")
end

--- Opens the CMake targets browser.
--- @return table handle
function M.open()
    local cmake = require("orchlaunch.cmake")
    local runner = require("orchlaunch.runner")

    return list.open({
        title = "CMake Targets",
        items = function()
            return cmake.targets() or {}
        end,
        label = function(target)
            return ("%s  (%s)"):format(target.name, target.type or "?")
        end,
        details = details,
        find = function(name)
            return cmake.target(name)
        end,
        empty_text = "No targets — run :OrchLaunchLoadCMake",
        extra_keys = {
            {
                lhs = "b",
                handler = function(target, ctx)
                    if not target then
                        return
                    end
                    runner.build(target.name)
                    ctx.refresh()
                end,
            },
            {
                lhs = "r",
                handler = function(target, ctx)
                    if not target then
                        return
                    end
                    ensure_configuration(target)
                    ctx.close()
                    vim.schedule(function()
                        runner.run(target.name, { mode = "run" })
                    end)
                end,
            },
            {
                lhs = "d",
                handler = function(target, ctx)
                    if not target then
                        return
                    end
                    ensure_configuration(target)
                    ctx.close()
                    vim.schedule(function()
                        runner.run(target.name, { mode = "debug" })
                    end)
                end,
            },
            {
                lhs = "e",
                handler = function(target, ctx)
                    if not target then
                        return
                    end
                    local cfg = ensure_configuration(target)
                    require("orchlaunch.ui.fibrous.editors.native").open(cfg, ctx.refresh)
                end,
            },
        },
        extra_hints = { "b  Build", "r  Run", "d  Debug", "e  Edit config" },
    })
end

return M
