-- OrchLaunch — Selection UI using vim.ui.select.
--
-- Replaces fibrous-based pickers with vim.ui.select which integrates
-- with telescope, snacks, fzf-lua, dressing, etc.

local state = require("orchlaunch.state")
local runner = require("orchlaunch.runner")

local M = {}

--- Selects a run configuration to run/debug.
---@param opts? { mode?: "run" | "debug", prompt?: string }
function M.select_and_run(opts)
    opts = opts or {}
    if not state.is_loaded() then
        vim.notify("[orchlaunch] no .orch project loaded", vim.log.levels.WARN)
        return
    end

    local configs = state.run_configurations().configurations
    if #configs == 0 then
        vim.notify("[orchlaunch] no run configurations defined", vim.log.levels.WARN)
        return
    end

    local items = {}
    for _, cfg in ipairs(configs) do
        local desc = cfg.type
        if cfg.type == "native" then
            desc = cfg.target and ("native → " .. cfg.target) or "native (no target)"
        elseif cfg.type == "remote-debug" then
            desc = "remote-debug → " .. (cfg.connection or "?")
        elseif cfg.type == "compound" then
            desc = "compound (" .. #cfg.configurations .. " children)"
        end
        items[#items + 1] = { name = cfg.name, desc = desc, cfg = cfg }
    end

    vim.ui.select(items, {
        prompt = opts.prompt or ("Select configuration to " .. (opts.mode == "debug" and "debug" or "run") .. ":"),
        format_item = function(item)
            return string.format("%s  [%s]", item.name, item.desc)
        end,
    }, function(choice)
        if choice then
            runner.run(choice.name, { mode = opts.mode or "run", async = true })
        end
    end)
end

--- Selects and sets the active configuration.
function M.select_active()
    if not state.is_loaded() then
        vim.notify("[orchlaunch] no .orch project loaded", vim.log.levels.WARN)
        return
    end

    local configs = state.run_configurations().configurations
    if #configs == 0 then
        vim.notify("[orchlaunch] no run configurations defined", vim.log.levels.WARN)
        return
    end

    local active = require("orchlaunch.active")
    local current = active.get(state.root())

    local items = {}
    for _, cfg in ipairs(configs) do
        local marker = cfg.name == current and " ● " or "   "
        items[#items + 1] = { name = cfg.name, marker = marker }
    end

    vim.ui.select(items, {
        prompt = "Select active configuration:",
        format_item = function(item)
            return item.marker .. item.name
        end,
    }, function(choice)
        if choice then
            active.set(state.root(), choice.name)
            vim.notify("[orchlaunch] active configuration: " .. choice.name)
        end
    end)
end

--- Selects a CMake target.
---@param opts? { prompt?: string, on_select: fun(target: OrchCMakeTarget) }
function M.select_cmake_target(opts)
    opts = opts or {}
    if not state.is_loaded() then
        vim.notify("[orchlaunch] no .orch project loaded", vim.log.levels.WARN)
        return
    end

    local cmake = require("orchlaunch.cmake")
    local targets = cmake.targets()
    if not targets or #targets == 0 then
        vim.notify("[orchlaunch] no CMake targets loaded. Run :OrchLaunchLoadCMake first.", vim.log.levels.WARN)
        return
    end

    local items = {}
    for _, target in ipairs(targets) do
        items[#items + 1] = {
            name = target.name,
            type = target.type or "?",
            path = target.artifact or "unknown",
            target = target,
        }
    end

    vim.ui.select(items, {
        prompt = opts.prompt or "Select CMake target:",
        format_item = function(item)
            return string.format("%s  (%s)  %s", item.name, item.type, item.path)
        end,
    }, function(choice)
        if choice and opts.on_select then
            opts.on_select(choice.target)
        end
    end)
end

--- Selects a toolchain.
---@param opts? { prompt?: string, on_select: fun(toolchain: OrchToolchain) }
function M.select_toolchain(opts)
    opts = opts or {}
    if not state.is_loaded() then
        vim.notify("[orchlaunch] no .orch project loaded", vim.log.levels.WARN)
        return
    end

    local toolchains = state.toolchains().toolchains
    if #toolchains == 0 then
        vim.notify("[orchlaunch] no toolchains defined", vim.log.levels.WARN)
        return
    end

    local items = {}
    for _, tc in ipairs(toolchains) do
        items[#items + 1] = {
            name = tc.name,
            type = tc.type,
            cmake = tc.cmake,
            c = tc.c,
            cxx = tc.cxx,
            debugger = tc.debugger,
            toolchain = tc,
        }
    end

    vim.ui.select(items, {
        prompt = opts.prompt or "Select toolchain:",
        format_item = function(item)
            return string.format("%s  [%s]  cmake=%s  c=%s  cxx=%s  dbg=%s",
                item.name, item.type, item.cmake, item.c, item.cxx, item.debugger)
        end,
    }, function(choice)
        if choice and opts.on_select then
            opts.on_select(choice.toolchain)
        end
    end)
end

--- Selects a CMake profile.
---@param opts? { kind?: "configure" | "build" | "all", prompt?: string, on_select: fun(profile: OrchCMakeProfile) }
function M.select_cmake_profile(opts)
    opts = opts or {}
    if not state.is_loaded() then
        vim.notify("[orchlaunch] no .orch project loaded", vim.log.levels.WARN)
        return
    end

    local profiles = state.cmake_profiles()
    if #profiles == 0 then
        vim.notify("[orchlaunch] no CMake profiles defined", vim.log.levels.WARN)
        return
    end

    local filtered = {}
    for _, p in ipairs(profiles) do
        if not opts.kind or opts.kind == "all" or p.kind == opts.kind then
            filtered[#filtered + 1] = p
        end
    end

    if #filtered == 0 then
        vim.notify("[orchlaunch] no matching CMake profiles", vim.log.levels.WARN)
        return
    end

    local items = {}
    for _, p in ipairs(filtered) do
        local active = p.name == state.active_cmake_profile() and " ● " or "   "
        items[#items + 1] = {
            name = p.name,
            kind = p.kind,
            configure_preset = p.configure_preset,
            build_preset = p.build_preset,
            toolchain = p.toolchain,
            marker = active,
            profile = p,
        }
    end

    vim.ui.select(items, {
        prompt = opts.prompt or "Select CMake profile:",
        format_item = function(item)
            local parts = { item.marker .. item.name, "[" .. item.kind .. "]" }
            if item.configure_preset then parts[#parts + 1] = "configure=" .. item.configure_preset end
            if item.build_preset then parts[#parts + 1] = "build=" .. item.build_preset end
            if item.toolchain then parts[#parts + 1] = "tc=" .. item.toolchain end
            return table.concat(parts, "  ")
        end,
    }, function(choice)
        if choice and opts.on_select then
            opts.on_select(choice.profile)
        end
    end)
end

--- Selects an external tool.
---@param opts? { prompt?: string, on_select: fun(tool: OrchExternalTool) }
function M.select_external_tool(opts)
    opts = opts or {}
    if not state.is_loaded() then
        vim.notify("[orchlaunch] no .orch project loaded", vim.log.levels.WARN)
        return
    end

    local tools = state.external_tools().tools
    if #tools == 0 then
        vim.notify("[orchlaunch] no external tools defined", vim.log.levels.WARN)
        return
    end

    local items = {}
    for _, tool in ipairs(tools) do
        items[#items + 1] = {
            name = tool.name,
            program = tool.program,
            cwd = tool.cwd,
            tool = tool,
        }
    end

    vim.ui.select(items, {
        prompt = opts.prompt or "Select external tool:",
        format_item = function(item)
            return string.format("%s  %s  (%s)", item.name, item.program, item.cwd or "cwd=workspace")
        end,
    }, function(choice)
        if choice and opts.on_select then
            opts.on_select(choice.tool)
        end
    end)
end

--- Selects a CMake preset (configure or build).
---@param opts? { kind: "configure" | "build", prompt?: string, on_select: fun(preset: OrchCMakePreset) }
function M.select_cmake_preset(opts)
    opts = opts or {}
    if not state.is_loaded() then
        vim.notify("[orchlaunch] no .orch project loaded", vim.log.levels.WARN)
        return
    end

    local presets = state.presets()
    if not presets or not presets[opts.kind] or #presets[opts.kind] == 0 then
        vim.notify(("[orchlaunch] no %s presets found"):format(opts.kind), vim.log.levels.WARN)
        return
    end

    local items = {}
    for _, p in ipairs(presets[opts.kind]) do
        local hidden = p.hidden and " (hidden)" or ""
        local cond = p.condition and " [condition]" or ""
        items[#items + 1] = {
            name = p.name,
            hidden = p.hidden,
            condition = p.condition,
            display = p.name .. hidden .. cond,
            preset = p,
        }
    end

    vim.ui.select(items, {
        prompt = opts.prompt or ("Select " .. opts.kind .. " preset:"),
        format_item = function(item)
            return item.display
        end,
    }, function(choice)
        if choice and opts.on_select then
            opts.on_select(choice.preset)
        end
    end)
end

--- Generic selection helper for any list of named items.
---@param items table[]
---@param opts { prompt?: string, format_item?: fun(item: table): string, on_select: fun(item: table) }
function M.generic_select(items, opts)
    vim.ui.select(items, {
        prompt = opts.prompt or "Select:",
        format_item = opts.format_item or function(item) return item.name or tostring(item) end,
    }, function(choice)
        if choice and opts.on_select then
            opts.on_select(choice)
        end
    end)
end

return M