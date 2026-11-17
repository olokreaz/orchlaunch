-- OrchLaunch — one-stop menu, statusline component and optional keymaps.
--
-- Everything here is a thin layer over functions the plugin already exposes
-- (runner, select, commands). Nothing is registered unless the user asks for
-- it: `setup_keymaps()` and `lualine_component` are opt-in.

local state = require("orchlaunch.state")
local notify = require("orchlaunch.notify").notify

local M = {}

local WARN = vim.log.levels.WARN

--- @return boolean
local function loaded()
    if state.is_loaded() then
        return true
    end
    notify("no .orch project loaded; run :OrchLaunchCreateProject first", WARN)
    return false
end

--- Name of the active run configuration, falling back to the first one (the
--- same rule `runner.run_active` uses).
--- @return string?
local function active_configuration_name()
    local name = require("orchlaunch.active").get(state.root())
    if name and state.configuration(name) then
        return name
    end
    local first = state.run_configurations().configurations[1]
    return first and first.name or nil
end

--- Short status of the current selection: configuration, CMake profile and the
--- native target of the configuration. Returns nil when no project is loaded.
--- @return { configuration?: string, profile?: string, target?: string }?
function M.status()
    if not state.is_loaded() then
        return nil
    end
    local name = active_configuration_name()
    local cfg = name and state.configuration(name) or nil
    return {
        configuration = name,
        profile = state.active_cmake_profile(),
        target = cfg and cfg.type == "native" and cfg.target or nil,
    }
end

--- Text for a statusline, e.g. `  launcher_main · Debug · launcher_main`.
--- Empty string when no project is loaded, so it can sit in a statusline
--- without any special casing.
--- @return string
function M.statusline()
    local status = M.status()
    if not status or not status.configuration then
        return ""
    end
    local parts = { status.configuration }
    if status.profile then
        parts[#parts + 1] = status.profile
    end
    if status.target and status.target ~= status.configuration then
        parts[#parts + 1] = status.target
    end
    return " " .. table.concat(parts, " · ")
end

--- lualine component. Add it to a section, e.g.
--- `table.insert(opts.sections.lualine_x, 1, require("orchlaunch.menu").lualine_component)`.
M.lualine_component = {
    M.statusline,
    cond = function()
        return state.is_loaded() and M.statusline() ~= ""
    end,
}

--- Actions shown in the menu. Each `run` is evaluated only when chosen.
--- @return { label: string, run: fun() }[]
local function actions()
    local runner = require("orchlaunch.runner")
    local select = require("orchlaunch.select")
    local cmd = function(name)
        return function()
            vim.cmd(name)
        end
    end

    return {
        {
            label = "Run active configuration",
            run = function()
                runner.run_active({ mode = "run", async = true })
            end,
        },
        {
            label = "Debug active configuration",
            run = function()
                runner.run_active({ mode = "debug", async = true })
            end,
        },
        {
            label = "Choose and run…",
            run = function()
                select.select_and_run({ mode = "run" })
            end,
        },
        {
            label = "Choose and debug…",
            run = function()
                select.select_and_run({ mode = "debug" })
            end,
        },
        {
            label = "Set active configuration…",
            run = function()
                select.select_active()
            end,
        },
        { label = "Choose CMake profile…", run = cmd("OrchLaunchSelectProfile") },
        {
            label = "Choose CMake target…",
            run = function()
                select.select_cmake_target({
                    on_select = function(t)
                        notify("selected target: " .. t.name)
                    end,
                })
            end,
        },
        {
            label = "Configure",
            run = function()
                runner.configure_async()
            end,
        },
        {
            label = "Build",
            run = function()
                runner.build_async(nil)
            end,
        },
        {
            label = "Rebuild",
            run = function()
                runner.rebuild_async(nil)
            end,
        },
        {
            label = "Clean",
            run = function()
                runner.clean_async()
            end,
        },
        {
            label = "Install",
            run = function()
                runner.install_async(nil)
            end,
        },
        {
            label = "Test (CTest)",
            run = function()
                runner.test_async()
            end,
        },
        {
            label = "Cancel running step",
            run = function()
                runner.cancel()
            end,
        },
        {
            label = "Load CMake targets",
            run = function()
                runner.load_cmake_async()
            end,
        },
        { label = "Toggle breakpoint", run = cmd("OrchLaunchToggleBreakpoint") },
        { label = "Breakpoints list", run = cmd("OrchLaunchBreakpoints") },
        { label = "Debugger panel", run = cmd("OrchLaunchDebugger") },
        {
            label = "Run external tool…",
            run = function()
                select.select_external_tool({
                    prompt = "Run which external tool?",
                    on_select = function(t)
                        runner.run_external_tool_async(t.name)
                    end,
                })
            end,
        },
        { label = "Browser (configurations)", run = cmd("OrchLaunch") },
        { label = "Toolchains", run = cmd("OrchLaunchToolchains") },
        { label = "External tools", run = cmd("OrchLaunchExternalTools") },
        { label = "CMake profiles", run = cmd("OrchLaunchCMake") },
        { label = "Reload .orch files", run = cmd("OrchLaunchReload") },
        { label = "Preflight check", run = cmd("OrchLaunchCheck") },
    }
end

--- Opens the single OrchLaunch menu. The current selection is shown in the
--- prompt so the user always sees what "Run" would start.
function M.open()
    if not loaded() then
        return
    end

    local items = actions()
    local status = M.status() or {}
    local prompt = ("OrchLaunch — %s%s"):format(
        status.configuration or "no configuration",
        status.profile and (" · " .. status.profile) or ""
    )

    vim.ui.select(items, {
        prompt = prompt,
        format_item = function(item)
            return item.label
        end,
    }, function(choice)
        if choice then
            local ok, err = pcall(choice.run)
            if not ok then
                notify(tostring(err):gsub("^%[orchlaunch%]%s*", ""), vim.log.levels.ERROR)
            end
        end
    end)
end

--- Default keymaps under `prefix` (default `<leader>o`). Opt-in: call it from
--- your config; the plugin does not map keys by itself.
---
--- The keys are typed after the prefix: `<leader>o` alone opens the menu.
---
---   (none) menu       r  run          d  debug         R  choose & run
---   D  choose & debug  c  active conf  p  CMake profile  t  CMake target
---   b  build           B  rebuild      n  configure     x  cancel
---   T  test            i  install      l  load targets  k  toggle breakpoint
---   K  breakpoints     g  debugger     e  external tool
---
--- @param prefix? string
function M.setup_keymaps(prefix)
    prefix = prefix or "<leader>o"
    local runner = require("orchlaunch.runner")
    local select = require("orchlaunch.select")

    local maps = {
        { "", M.open, "OrchLaunch menu" },
        {
            "r",
            function()
                runner.run_active({ mode = "run", async = true })
            end,
            "Run active",
        },
        {
            "d",
            function()
                runner.run_active({ mode = "debug", async = true })
            end,
            "Debug active",
        },
        {
            "R",
            function()
                select.select_and_run({ mode = "run" })
            end,
            "Choose and run",
        },
        {
            "D",
            function()
                select.select_and_run({ mode = "debug" })
            end,
            "Choose and debug",
        },
        {
            "c",
            function()
                select.select_active()
            end,
            "Set active configuration",
        },
        {
            "p",
            function()
                vim.cmd("OrchLaunchSelectProfile")
            end,
            "Choose CMake profile",
        },
        {
            "t",
            function()
                select.select_cmake_target({
                    on_select = function(t)
                        notify("selected target: " .. t.name)
                    end,
                })
            end,
            "Choose CMake target",
        },
        {
            "b",
            function()
                runner.build_async(nil)
            end,
            "Build",
        },
        {
            "B",
            function()
                runner.rebuild_async(nil)
            end,
            "Rebuild",
        },
        {
            "n",
            function()
                runner.configure_async()
            end,
            "Configure",
        },
        {
            "x",
            function()
                runner.cancel()
            end,
            "Cancel running step",
        },
        {
            "T",
            function()
                runner.test_async()
            end,
            "Test (CTest)",
        },
        {
            "i",
            function()
                runner.install_async(nil)
            end,
            "Install",
        },
        {
            "l",
            function()
                runner.load_cmake_async()
            end,
            "Load CMake targets",
        },
        {
            "k",
            function()
                vim.cmd("OrchLaunchToggleBreakpoint")
            end,
            "Toggle breakpoint",
        },
        {
            "K",
            function()
                vim.cmd("OrchLaunchBreakpoints")
            end,
            "Breakpoints list",
        },
        {
            "g",
            function()
                vim.cmd("OrchLaunchDebugger")
            end,
            "Debugger panel",
        },
        {
            "e",
            function()
                select.select_external_tool({
                    prompt = "Run which external tool?",
                    on_select = function(t)
                        runner.run_external_tool_async(t.name)
                    end,
                })
            end,
            "External tool",
        },
    }

    for _, m in ipairs(maps) do
        vim.keymap.set("n", prefix .. m[1], m[2], { desc = "OrchLaunch: " .. m[3], silent = true })
    end
end

return M
