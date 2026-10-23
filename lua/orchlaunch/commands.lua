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

--- @return string[]
local function target_names()
    local state = require("orchlaunch.state")
    if not state.is_loaded() then
        return {}
    end

    local cmake = require("orchlaunch.cmake")
    local names = {}
    for _, target in ipairs(cmake.targets() or {}) do
        names[#names + 1] = target.name
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
    local found, orch_dir = project.locate(vim.fn.getcwd())
    if not found then
        notify("no .orch project found; run :OrchLaunchCreateProject first", WARN)
        return nil
    end

    return state.setup(found, orch_dir)
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

    local cfg = state.configuration(name)
    if not cfg then
        notify(("configuration not found: %s"):format(name), ERROR)
        return
    end

    if cfg.type == "native" then
        require("orchlaunch.ui.fibrous.editors.native").open(cfg)
    elseif cfg.type == "remote-debug" then
        require("orchlaunch.ui.fibrous.editors.remote").open(cfg)
    elseif cfg.type == "compound" then
        require("orchlaunch.ui.fibrous.editors.compound").open(cfg)
    else
        notify(("cannot edit unknown configuration type: %s"):format(cfg.type), ERROR)
    end
end

function M.register()
    if registered then
        return
    end
    registered = true

    -- Opt-in: open the debugger panel automatically when a debug session starts.
    vim.api.nvim_create_autocmd("User", {
        group = vim.api.nvim_create_augroup("OrchLaunchDebugger", { clear = true }),
        pattern = "OrchLaunchDebugStarted",
        callback = function()
            if vim.g.orchlaunch_auto_debug_ui == true then
                require("orchlaunch.ui.fibrous.debugger").open()
            end
        end,
    })

    vim.api.nvim_create_user_command("OrchLaunch", function()
        if not ensure_loaded() then
            return
        end
        require("orchlaunch.ui.fibrous.browser").open()
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

    vim.api.nvim_create_user_command("OrchLaunchDebugger", function()
        local opened = require("orchlaunch.integrations").debugger_ui()
        if not opened then
            require("orchlaunch.ui.fibrous.debugger").open()
        end
    end, { desc = "Toggle the debugger UI" })

    --- @return boolean ok, integer? bufnr, integer? line
    local function cursor_breakpoint_target()
        local bufnr = vim.api.nvim_get_current_buf()
        if vim.api.nvim_buf_get_name(bufnr) == "" then
            notify("current buffer is not a file", WARN)
            return false
        end
        local line = vim.api.nvim_win_get_cursor(0)[1]
        return true, bufnr, line
    end

    vim.api.nvim_create_user_command("OrchLaunchToggleBreakpoint", function()
        ensure_loaded()
        local ok, bufnr, line = cursor_breakpoint_target()
        if not ok then
            return
        end
        local breakpoints = require("orchlaunch.breakpoints")
        breakpoints.toggle({}, bufnr, line)
        notify(("breakpoint %s at %s:%d"):format(
            breakpoints.has(bufnr, line) and "set" or "removed",
            vim.fs.basename(vim.api.nvim_buf_get_name(bufnr)), line
        ))
    end, { desc = "Toggle a breakpoint at the cursor" })

    vim.api.nvim_create_user_command("OrchLaunchBreakpoint", function(args)
        ensure_loaded()
        local ok, bufnr, line = cursor_breakpoint_target()
        if not ok then
            return
        end
        require("orchlaunch.breakpoints").set({ condition = args.args }, bufnr, line)
        notify(("conditional breakpoint (%s) at line %d"):format(args.args, line))
    end, { nargs = 1, desc = "Set a conditional breakpoint at the cursor" })

    vim.api.nvim_create_user_command("OrchLaunchLogBreakpoint", function(args)
        ensure_loaded()
        local ok, bufnr, line = cursor_breakpoint_target()
        if not ok then
            return
        end
        require("orchlaunch.breakpoints").set({ log_message = args.args }, bufnr, line)
        notify(("log point (%s) at line %d"):format(args.args, line))
    end, { nargs = 1, desc = "Set a log point at the cursor" })

    vim.api.nvim_create_user_command("OrchLaunchClearBreakpoints", function()
        require("orchlaunch.breakpoints").clear()
        notify("all breakpoints cleared")
    end, { desc = "Clear all breakpoints" })

    vim.api.nvim_create_user_command("OrchLaunchBreakpoints", function()
        ensure_loaded()
        require("orchlaunch.ui.fibrous.breakpoints").open()
    end, { desc = "Manage breakpoints" })

    vim.api.nvim_create_user_command("OrchLaunchCheck", function()
        local preflight = require("orchlaunch.preflight")
        preflight.run(function(message, level)
            vim.notify(message, level)
        end)
        if preflight.ok() then
            notify("environment looks ready")
        else
            notify("some required tools are missing", WARN)
        end
    end, { desc = "Check external tools and integrations" })

    vim.api.nvim_create_user_command("OrchLaunchToolchains", function()
        if not ensure_loaded() then
            return
        end
        require("orchlaunch.ui.dialogs.toolchains").open()
    end, { desc = "Manage toolchains" })

    vim.api.nvim_create_user_command("OrchLaunchExternalTools", function()
        if not ensure_loaded() then
            return
        end
        require("orchlaunch.ui.dialogs.external_tools").open()
    end, { desc = "Manage external tools" })

    vim.api.nvim_create_user_command("OrchLaunchCMake", function()
        if not ensure_loaded() then
            return
        end
        require("orchlaunch.ui.fibrous.cmake_profiles").open()
    end, { desc = "Manage CMake profiles" })

    vim.api.nvim_create_user_command("OrchLaunchCMakeProject", function()
        if not ensure_loaded() then
            return
        end
        require("orchlaunch.ui.fibrous.editors.cmake_project").open()
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

    vim.api.nvim_create_user_command("OrchLaunchRefreshTargets", function()
        if not ensure_loaded() then
            return
        end
        require("orchlaunch.runner").refresh_cmake()
    end, { desc = "Discover CMake targets from an existing build directory (no configure)" })

    vim.api.nvim_create_user_command("OrchLaunchConfigure", function()
        if ensure_loaded() then
            require("orchlaunch.runner").configure()
        end
    end, { desc = "Configure the project with the active CMake profile" })

    vim.api.nvim_create_user_command("OrchLaunchBuild", function(args)
        if ensure_loaded() then
            require("orchlaunch.runner").build(args.args ~= "" and args.args or nil)
        end
    end, {
        nargs = "?",
        desc = "Build the project or a single target",
        complete = function()
            return target_names()
        end,
    })

    vim.api.nvim_create_user_command("OrchLaunchRebuild", function(args)
        if ensure_loaded() then
            require("orchlaunch.runner").rebuild(args.args ~= "" and args.args or nil)
        end
    end, {
        nargs = "?",
        desc = "Clean and rebuild the project or a single target",
        complete = function()
            return target_names()
        end,
    })

    vim.api.nvim_create_user_command("OrchLaunchClean", function()
        if ensure_loaded() then
            require("orchlaunch.runner").clean()
        end
    end, { desc = "Clean build outputs through the active build tool" })

    vim.api.nvim_create_user_command("OrchLaunchInstall", function(args)
        if ensure_loaded() then
            require("orchlaunch.runner").install(args.args ~= "" and args.args or nil)
        end
    end, {
        nargs = "?",
        desc = "Configure, build and install the project",
        complete = function()
            return target_names()
        end,
    })

    vim.api.nvim_create_user_command("OrchLaunchTest", function()
        if ensure_loaded() then
            require("orchlaunch.runner").test()
        end
    end, { desc = "Build and run the CTest suite" })

    vim.api.nvim_create_user_command("OrchLaunchTargets", function()
        if ensure_loaded() then
            require("orchlaunch.ui.fibrous.targets").open()
        end
    end, { desc = "Browse CMake targets" })

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
