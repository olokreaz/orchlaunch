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

--- @return string[]
local function toolchain_names()
    local state = require("orchlaunch.state")
    if not state.is_loaded() then
        return {}
    end
    local names = {}
    for _, tc in ipairs(state.toolchains().toolchains) do
        names[#names + 1] = tc.name
    end
    return names
end

--- @return string[]
local function profile_names()
    local state = require("orchlaunch.state")
    if not state.is_loaded() then
        return {}
    end
    local names = {}
    for _, p in ipairs(state.cmake_profiles()) do
        names[#names + 1] = p.name
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

--- Determines the UI backend to use.
--- @return "buffer" | "fibrous"
local function get_ui_backend()
    return require("orchlaunch.options").get().ui.backend
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
                local backend = get_ui_backend()
                if backend == "fibrous" then
                    require("orchlaunch.ui.fibrous.debugger").open()
                else
                    notify("debugger UI requires fibrous backend", WARN)
                end
            end
        end,
    })

    -- =========================================================================
    -- Core project commands
    -- =========================================================================

    vim.api.nvim_create_user_command("OrchLaunch", function()
        if not ensure_loaded() then return end
        local backend = get_ui_backend()
        if backend == "fibrous" then
            require("orchlaunch.ui.fibrous.browser").open()
        else
            require("orchlaunch.select").select_and_run({ mode = "run" })
        end
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

    -- =========================================================================
    -- Run/Debug commands
    -- =========================================================================

    vim.api.nvim_create_user_command("OrchLaunchSelect", function(args)
        if not ensure_loaded() then return end
        require("orchlaunch.select").select_active()
    end, {
        nargs = "?",
        desc = "Set the active run configuration",
        complete = function() return configuration_names() end,
    })

    vim.api.nvim_create_user_command("OrchLaunchRun", function(args)
        if not ensure_loaded() then return end
        local runner = require("orchlaunch.runner")
        if args.args ~= "" then
            runner.run(args.args, { mode = "run", async = true })
        else
            runner.run_active({ mode = "run", async = true })
        end
    end, {
        nargs = "?",
        desc = "Run a configuration (active when omitted)",
        complete = function() return configuration_names() end,
    })

    vim.api.nvim_create_user_command("OrchLaunchDebug", function(args)
        if not ensure_loaded() then return end
        local runner = require("orchlaunch.runner")
        if args.args ~= "" then
            runner.run(args.args, { mode = "debug", async = true })
        else
            runner.run_active({ mode = "debug", async = true })
        end
    end, {
        nargs = "?",
        desc = "Debug a configuration (active when omitted)",
        complete = function() return configuration_names() end,
    })

    -- =========================================================================
    -- Buffer-based editing commands (new)
    -- =========================================================================

    vim.api.nvim_create_user_command("OrchLaunchEdit", function(args)
        if not ensure_loaded() then return end

        -- Parse optional subcommand: configs, tools, toolchain, cmake, breakpoints
        -- plus optional entry name: ":OrchLaunchEdit configs Game"
        local parts = vim.split(vim.trim(args.args), "%s+")
        local file_type_map = {
            configs = "run_configurations",
            tools = "external_tools",
            toolchain = "toolchain",
            cmake = "cmake_settings",
            breakpoints = "breakpoints",
        }

        local file_type = nil
        local entry_name = nil

        if #parts >= 1 then
            file_type = file_type_map[parts[1]:lower()]
        end
        if #parts >= 2 then
            entry_name = parts[2]
        end

        require("orchlaunch").edit(file_type, entry_name)
    end, {
        nargs = "?",
        desc = "Open a configuration file for editing (optionally: configs|tools|toolchain|cmake|breakpoints)",
        complete = function(_, line)
            local subcmds = { "configs", "tools", "toolchain", "cmake", "breakpoints" }
            local parts = vim.split(line:sub(#"OrchLaunchEdit " + 1), "%s+")
            if #parts <= 1 then
                return vim.tbl_filter(function(s) return s:find(parts[1] or "") == 1 end, subcmds)
            end
            return {}
        end,
    })

    vim.api.nvim_create_user_command("OrchLaunchNew", function(args)
        if not ensure_loaded() then return end

        local types = { "native", "remote-debug", "compound", "external_tool", "toolchain", "cmake_profile" }
        local arg = args.args:lower()

        if vim.tbl_contains(types, arg) then
            require("orchlaunch").new(arg)
        else
            vim.ui.select(types, { prompt = "Create new:" }, function(choice)
                if choice then require("orchlaunch").new(choice) end
            end)
        end
    end, {
        nargs = "?",
        desc = "Create a new configuration entry",
        complete = function()
            return { "native", "remote-debug", "compound", "external_tool", "toolchain", "cmake_profile" }
        end,
    })

    -- =========================================================================
    -- Legacy fibrous-based editing (kept for compatibility when using fibrous backend)
    -- =========================================================================

    local function edit_configuration_fibrous(name)
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

    vim.api.nvim_create_user_command("OrchLaunchEditConfig", function(args)
        if not ensure_loaded() then return end
        local name = resolve_name(args.args)
        if not name then
            notify("no run configurations defined", WARN)
            return
        end

        local backend = get_ui_backend()
        if backend == "fibrous" then
            edit_configuration_fibrous(name)
        else
            require("orchlaunch").edit("run_configurations", name)
        end
    end, {
        nargs = "?",
        desc = "Edit a run configuration (legacy fibrous editor)",
        complete = function() return configuration_names() end,
    })

    -- =========================================================================
    -- Debugger
    -- =========================================================================

    vim.api.nvim_create_user_command("OrchLaunchDebugger", function()
        local opened = require("orchlaunch.integrations").debugger_ui()
        if not opened then
            local backend = get_ui_backend()
            if backend == "fibrous" then
                require("orchlaunch.ui.fibrous.debugger").open()
            else
                notify("debugger UI requires fibrous backend", WARN)
            end
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
        if not ok then return end
        local breakpoints = require("orchlaunch.breakpoints")
        if not breakpoints.toggle({}, bufnr, line) then
            notify("nvim-dap is not installed; breakpoints are unavailable", WARN)
            return
        end
        notify(("breakpoint %s at %s:%d"):format(
            breakpoints.has(bufnr, line) and "set" or "removed",
            vim.fs.basename(vim.api.nvim_buf_get_name(bufnr)), line
        ))
    end, { desc = "Toggle a breakpoint at the cursor" })

    vim.api.nvim_create_user_command("OrchLaunchBreakpoint", function(args)
        ensure_loaded()
        local ok, bufnr, line = cursor_breakpoint_target()
        if not ok then return end
        if not require("orchlaunch.breakpoints").set({ condition = args.args }, bufnr, line) then
            notify("nvim-dap is not installed; breakpoints are unavailable", WARN)
            return
        end
        notify(("conditional breakpoint (%s) at line %d"):format(args.args, line))
    end, { nargs = 1, desc = "Set a conditional breakpoint at the cursor" })

    vim.api.nvim_create_user_command("OrchLaunchLogBreakpoint", function(args)
        ensure_loaded()
        local ok, bufnr, line = cursor_breakpoint_target()
        if not ok then return end
        if not require("orchlaunch.breakpoints").set({ log_message = args.args }, bufnr, line) then
            notify("nvim-dap is not installed; breakpoints are unavailable", WARN)
            return
        end
        notify(("log point (%s) at line %d"):format(args.args, line))
    end, { nargs = 1, desc = "Set a log point at the cursor" })

    vim.api.nvim_create_user_command("OrchLaunchClearBreakpoints", function()
        if not require("orchlaunch.breakpoints").clear() then
            notify("nvim-dap is not installed; breakpoints are unavailable", WARN)
            return
        end
        notify("all breakpoints cleared")
    end, { desc = "Clear all breakpoints" })

    vim.api.nvim_create_user_command("OrchLaunchBreakpoints", function()
        ensure_loaded()
        local backend = get_ui_backend()
        if backend == "fibrous" then
            require("orchlaunch.ui.fibrous.breakpoints").open()
        else
            require("orchlaunch").edit("breakpoints")
        end
    end, { desc = "Manage breakpoints" })

    -- =========================================================================
    -- Check / Tools
    -- =========================================================================

    vim.api.nvim_create_user_command("OrchLaunchCheck", function()
        local preflight = require("orchlaunch.preflight")
        preflight.run(function(message, level)
            vim.notify(message, level)
        end)
        local orch = require("orchlaunch")
        local info = orch.check_schemas()
        if info.jsonls_found then
            notify(("jsonls: found (%d client%s), schemas %s"):format(
                #info.jsonls_clients,
                #info.jsonls_clients == 1 and "" or "s",
                info.schemas_registered and "registered" or "not registered"
            ))
        else
            notify("jsonls: not found (install vscode-langservers-extracted)", WARN)
        end
        if preflight.ok() then
            notify("environment looks ready")
        else
            notify("some required tools are missing", WARN)
        end
    end, { desc = "Check external tools and integrations" })

    -- =========================================================================
    -- Toolchain / External Tools / CMake (fibrous or vim.ui.select)
    -- =========================================================================

    local function open_toolchains()
        local backend = get_ui_backend()
        if backend == "fibrous" then
            require("orchlaunch.ui.dialogs.toolchains").open()
        else
            require("orchlaunch.select").select_toolchain({
                on_select = function(tc) vim.notify("Selected toolchain: " .. tc.name) end
            })
        end
    end

    local function open_external_tools()
        local backend = get_ui_backend()
        if backend == "fibrous" then
            require("orchlaunch.ui.dialogs.external_tools").open()
        else
            require("orchlaunch.select").select_external_tool({
                on_select = function(t) vim.notify("Selected tool: " .. t.name) end
            })
        end
    end

    vim.api.nvim_create_user_command("OrchLaunchToolchains", function()
        if not ensure_loaded() then return end
        open_toolchains()
    end, { desc = "Manage toolchains" })

    vim.api.nvim_create_user_command("OrchLaunchExternalTools", function()
        if not ensure_loaded() then return end
        open_external_tools()
    end, { desc = "Manage external tools" })

    -- =========================================================================
    -- CMake commands
    -- =========================================================================

    vim.api.nvim_create_user_command("OrchLaunchCMake", function()
        if not ensure_loaded() then return end
        local backend = get_ui_backend()
        if backend == "fibrous" then
            require("orchlaunch.ui.fibrous.cmake_profiles").open()
        else
            require("orchlaunch.select").select_cmake_profile({
                on_select = function(p) vim.notify("Selected profile: " .. p.name) end
            })
        end
    end, { desc = "Manage CMake profiles" })

    vim.api.nvim_create_user_command("OrchLaunchCMakeProject", function()
        if not ensure_loaded() then return end
        local backend = get_ui_backend()
        if backend == "fibrous" then
            require("orchlaunch.ui.fibrous.editors.cmake_project").open()
        else
            require("orchlaunch").edit("cmake_settings")
        end
    end, { desc = "Set the CMake project directory" })

    vim.api.nvim_create_user_command("OrchLaunchImportCMakePresets", function()
        if not ensure_loaded() then return end
        local state = require("orchlaunch.state")
        local added = state.sync_cmake_profiles()
        state.save()
        notify(("imported %d CMake preset profile(s)"):format(added))
    end, { desc = "Import CMake presets as disabled profiles" })

    vim.api.nvim_create_user_command("OrchLaunchLoadCMake", function()
        if not ensure_loaded() then return end
        require("orchlaunch.runner").load_cmake_async()
    end, { desc = "Configure the project and load its CMake targets" })

    vim.api.nvim_create_user_command("OrchLaunchRefreshTargets", function()
        if not ensure_loaded() then return end
        require("orchlaunch.runner").refresh_cmake()
    end, { desc = "Discover CMake targets from an existing build directory (no configure)" })

    vim.api.nvim_create_user_command("OrchLaunchConfigure", function()
        if ensure_loaded() then
            require("orchlaunch.runner").configure_async()
        end
    end, { desc = "Configure the project with the active CMake profile" })

    vim.api.nvim_create_user_command("OrchLaunchBuild", function(args)
        if ensure_loaded() then
            require("orchlaunch.runner").build_async(args.args ~= "" and args.args or nil)
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
            require("orchlaunch.runner").rebuild_async(args.args ~= "" and args.args or nil)
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
            require("orchlaunch.runner").clean_async()
        end
    end, { desc = "Clean build outputs through the active build tool" })

    vim.api.nvim_create_user_command("OrchLaunchInstall", function(args)
        if ensure_loaded() then
            require("orchlaunch.runner").install_async(args.args ~= "" and args.args or nil)
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
            require("orchlaunch.runner").test_async()
        end
    end, { desc = "Build and run the CTest suite" })

    vim.api.nvim_create_user_command("OrchLaunchCancel", function()
        require("orchlaunch.runner").cancel()
    end, { desc = "Cancel the running build or external tool step" })

    vim.api.nvim_create_user_command("OrchLaunchTargets", function()
        if ensure_loaded() then
            local backend = get_ui_backend()
            if backend == "fibrous" then
                require("orchlaunch.ui.fibrous.targets").open()
            else
                require("orchlaunch.select").select_cmake_target({
                    on_select = function(t) vim.notify("Selected target: " .. t.name) end
                })
            end
        end
    end, { desc = "Browse CMake targets" })

    vim.api.nvim_create_user_command("OrchLaunchExternalTool", function(args)
        if not ensure_loaded() then return end
        require("orchlaunch.runner").run_external_tool_async(args.args)
    end, {
        nargs = 1,
        desc = "Run an external tool",
        complete = function()
            local state = require("orchlaunch.state")
            if not state.is_loaded() then return {} end
            local names = {}
            for _, tool in ipairs(state.external_tools().tools) do
                names[#names + 1] = tool.name
            end
            return names
        end,
    })

    -- =========================================================================
    -- Selection commands (new, vim.ui.select based)
    -- =========================================================================

    vim.api.nvim_create_user_command("OrchLaunchSelectConfig", function()
        if not ensure_loaded() then return end
        require("orchlaunch.select").select_and_run({ mode = "run" })
    end, { desc = "Select and run a configuration" })

    vim.api.nvim_create_user_command("OrchLaunchSelectDebug", function()
        if not ensure_loaded() then return end
        require("orchlaunch.select").select_and_run({ mode = "debug" })
    end, { desc = "Select and debug a configuration" })

    vim.api.nvim_create_user_command("OrchLaunchSelectTarget", function()
        if not ensure_loaded() then return end
        require("orchlaunch.select").select_cmake_target({
            on_select = function(t) vim.notify("Selected target: " .. t.name) end
        })
    end, { desc = "Select a CMake target" })

    vim.api.nvim_create_user_command("OrchLaunchSelectToolchain", function()
        if not ensure_loaded() then return end
        require("orchlaunch.select").select_toolchain({
            on_select = function(tc) vim.notify("Selected toolchain: " .. tc.name) end
        })
    end, { desc = "Select a toolchain" })

    vim.api.nvim_create_user_command("OrchLaunchSelectProfile", function(args)
        if not ensure_loaded() then return end
        local kind = args.args:lower()
        if kind ~= "configure" and kind ~= "build" then kind = "all" end
        require("orchlaunch.select").select_cmake_profile({
            kind = kind,
            on_select = function(p) vim.notify("Selected profile: " .. p.name) end
        })
    end, {
        nargs = "?",
        desc = "Select a CMake profile (configure|build|all)",
        complete = function() return { "configure", "build", "all" } end,
    })

    vim.api.nvim_create_user_command("OrchLaunchSelectPreset", function(args)
        if not ensure_loaded() then return end
        local kind = args.args:lower()
        if kind ~= "configure" and kind ~= "build" then kind = "configure" end
        require("orchlaunch.select").select_cmake_preset({
            kind = kind,
            on_select = function(p) vim.notify("Selected preset: " .. p.name) end
        })
    end, {
        nargs = "?",
        desc = "Select a CMake preset (configure|build)",
        complete = function() return { "configure", "build" } end,
    })

    vim.api.nvim_create_user_command("OrchLaunchSelectTool", function()
        if not ensure_loaded() then return end
        require("orchlaunch.select").select_external_tool({
            on_select = function(t) vim.notify("Selected tool: " .. t.name) end
        })
    end, { desc = "Select an external tool" })

    -- Run here (from buffer)
    vim.api.nvim_create_user_command("OrchLaunchRunHere", function()
        local bufnr = vim.api.nvim_get_current_buf()
        local filename = vim.fs.basename(vim.api.nvim_buf_get_name(bufnr))
        if filename ~= "run_configurations.json" then
            notify("OrchLaunchRunHere only works in run_configurations.json", WARN)
            return
        end
        local line = vim.api.nvim_win_get_cursor(0)[1] - 1
        -- Find configuration at cursor
        local validate = require("orchlaunch.validate")
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local configs = {}
        local in_configs = false
        local brace_depth = 0
        local current = {}
        for i, line_text in ipairs(lines) do
            if line_text:match('"configurations"%s*:%s*%[') then in_configs = true end
            if in_configs then
                for _, ch in ipairs(vim.fn.split(line_text, "")) do
                    if ch == "{" then
                        if brace_depth == 1 then current = { start_line = i - 1 } end
                        brace_depth = brace_depth + 1
                    elseif ch == "}" then
                        brace_depth = brace_depth - 1
                        if brace_depth == 1 then
                            current.end_line = i - 1
                            if current.start_line <= line and current.end_line >= line then
                                if current.name then
                                    require("orchlaunch.runner").run(current.name, { mode = "run", async = true })
                                end
                                return
                            end
                            current = {}
                        end
                    end
                end
                if brace_depth >= 2 then
                    local key, val = line_text:match('"(%w+)"%s*:%s*"([^"]*)"')
                    if key and val then current[key] = val end
                end
            end
        end
    end, { desc = "Run the configuration under the cursor in run_configurations.json" })

end

return M