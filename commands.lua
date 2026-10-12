-- OrchLaunch — user commands.
--
-- Commands are registered once and stay thin; all behaviour lives in the
-- `state`, `runner` and `ui` modules.

local M = {}

local WARN = vim.log.levels.WARN
local ERROR = vim.log.levels.ERROR

local registered = false

--- @param message string
--- @param level? integer
local function notify(message, level)
    vim.notify("[orchlaunch] " .. message, level or vim.log.levels.INFO)
end

--- @return string[]
local function configuration_names()
    local state = require("orchlaunch.state")
    if not state.is_loaded() then
        return {}
    end

    local names = {}
    for _, cfg in ipairs(state.run_configurations().configurations) do
        names[#names + 1] = cfg.name
    end
    return names
end

--- Loads the `.orch` project containing the current directory when needed.
--- @return table? state
local function ensure_loaded()
    local state = require("orchlaunch.state")
    if state.is_loaded() then
        return state
    end

    local project = require("orchlaunch.project")
    local found = project.locate(vim.fn.getcwd())
    if not found then
        notify("no .orch project found; run :OrchLaunchCreateProject first", WARN)
        return nil
    end

    return state.setup(found)
end

--- Resolves a name argument, falling back to the active configuration.
--- @param arg? string
--- @return string?
local function resolve_name(arg)
    if arg and arg ~= "" then
        return arg
    end

    local state = require("orchlaunch.state")
    local active = require("orchlaunch.active")

    local name = active.get(state.root())
    if name and state.configuration(name) then
        return name
    end

    local first = state.run_configurations().configurations[1]
    return first and first.name
end

--- Opens the editor for a configuration.
--- @param name string
local function edit_configuration(name)
    local state = require("orchlaunch.state")
    local editor = require("orchlaunch.ui.editor")

    local cfg = state.configuration(name)
    if not cfg then
        notify(("configuration not found: %s"):format(name), ERROR)
        return
    end

    if cfg.type == "native" then
        editor.open_native(cfg)
    elseif cfg.type == "remote-debug" then
        editor.open_remote(cfg)
    elseif cfg.type == "compound" then
        editor.open_compound(cfg)
    else
        notify(("cannot edit unknown configuration type: %s"):format(cfg.type), ERROR)
    end
end

function M.register()
    if registered then
        return
    end
    registered = true

    vim.api.nvim_create_user_command("OrchLaunch", function()
        if not ensure_loaded() then
            return
        end
        require("orchlaunch.ui.browser").open()
    end, { desc = "Open the OrchLaunch Run/Debug configurations browser" })

    vim.api.nvim_create_user_command("OrchLaunchCreateProject", function(args)
        require("orchlaunch").create_project(args.args ~= "" and args.args or nil)
    end, { nargs = "?", desc = "Create a .orch project", complete = "dir" })

    vim.api.nvim_create_user_command("OrchLaunchReload", function()
        local state = require("orchlaunch.state")
        if not state.is_loaded() then
            notify("no .orch project loaded", WARN)
            return
        end
        state.reload()
        notify("configuration reloaded")
    end, { desc = "Reload the .orch configuration" })

    vim.api.nvim_create_user_command("OrchLaunchSelect", function(args)
        if not ensure_loaded() then
            return
        end

        local state = require("orchlaunch.state")
        local name = resolve_name(args.args)

        if not name then
            notify("no run configurations defined", WARN)
            return
        end

        if not state.configuration(name) then
            notify(("configuration not found: %s"):format(name), ERROR)
            return
        end

        require("orchlaunch.active").set(state.root(), name)
        notify(("active configuration: %s"):format(name))
    end, {
        nargs = "?",
        desc = "Set the active run configuration",
        complete = function()
            return configuration_names()
        end,
    })

    vim.api.nvim_create_user_command("OrchLaunchRun", function(args)
        if not ensure_loaded() then
            return
        end

        local runner = require("orchlaunch.runner")
        if args.args ~= "" then
            runner.run(args.args, { mode = "run" })
        else
            runner.run_active({ mode = "run" })
        end
    end, {
        nargs = "?",
        desc = "Run a configuration (active when omitted)",
        complete = function()
            return configuration_names()
        end,
    })

    vim.api.nvim_create_user_command("OrchLaunchDebug", function(args)
        if not ensure_loaded() then
            return
        end

        local runner = require("orchlaunch.runner")
        if args.args ~= "" then
            runner.run(args.args, { mode = "debug" })
        else
            runner.run_active({ mode = "debug" })
        end
    end, {
        nargs = "?",
        desc = "Debug a configuration (active when omitted)",
        complete = function()
            return configuration_names()
        end,
    })

    vim.api.nvim_create_user_command("OrchLaunchEdit", function(args)
        if not ensure_loaded() then
            return
        end

        local name = resolve_name(args.args)
        if not name then
            notify("no run configurations defined", WARN)
            return
        end

        edit_configuration(name)
    end, {
        nargs = "?",
        desc = "Edit a run configuration",
        complete = function()
            return configuration_names()
        end,
    })

    vim.api.nvim_create_user_command("OrchLaunchToolchains", function()
        if not ensure_loaded() then
            return
        end
        require("orchlaunch.ui.list_dialog").open_toolchains()
    end, { desc = "Manage toolchains" })

    vim.api.nvim_create_user_command("OrchLaunchExternalTools", function()
        if not ensure_loaded() then
            return
        end
        require("orchlaunch.ui.list_dialog").open_external_tools()
    end, { desc = "Manage external tools" })

    vim.api.nvim_create_user_command("OrchLaunchCMake", function()
        if not ensure_loaded() then
            return
        end
        require("orchlaunch.ui.list_dialog").open_cmake_profiles()
    end, { desc = "Manage CMake profiles" })

    vim.api.nvim_create_user_command("OrchLaunchCMakeProject", function()
        if not ensure_loaded() then
            return
        end
        require("orchlaunch.ui.editor").open_cmake_project()
    end, { desc = "Set the CMake project directory" })

    vim.api.nvim_create_user_command("OrchLaunchImportCMakePresets", function()
        if not ensure_loaded() then
            return
        end
        local state = require("orchlaunch.state")
        local added = state.sync_cmake_profiles()
        state.save()
        notify(("imported %d CMake preset profile(s)"):format(added))
    end, { desc = "Import CMake presets as disabled profiles" })

    vim.api.nvim_create_user_command("OrchLaunchLoadCMake", function()
        if not ensure_loaded() then
            return
        end
        require("orchlaunch.runner").load_cmake()
    end, { desc = "Configure the project and load its CMake targets" })

    vim.api.nvim_create_user_command("OrchLaunchExternalTool", function(args)
        if not ensure_loaded() then
            return
        end

        local runner = require("orchlaunch.runner")
        local result = runner.run_external_tool(args.args)
        if result then
            notify(("external tool %q finished with code %d"):format(args.args, result.code))
        end
    end, {
        nargs = 1,
        desc = "Run an external tool",
        complete = function()
            local state = require("orchlaunch.state")
            if not state.is_loaded() then
                return {}
            end

            local names = {}
            for _, tool in ipairs(state.external_tools().tools) do
                names[#names + 1] = tool.name
            end
            return names
        end,
    })
end

return M
