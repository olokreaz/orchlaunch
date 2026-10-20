-- OrchLaunch — Run/Debug Configurations browser on fibrous.
--
-- A spec over `orchlaunch.ui.fibrous.list` plus the config-type chooser and the
-- Run/Debug/Duplicate/Load-CMake extras.

local list = require("orchlaunch.ui.fibrous.list")
local util = require("orchlaunch.ui.fibrous.util")

local ERROR = vim.log.levels.ERROR

local M = {}

--- @return boolean
function M.available()
    return list.available()
end

--- @param before? OrchBefore
--- @return string
local function format_before(before)
    local parts = {}
    for _, item in ipairs(before and before.tools or {}) do
        local kind = type(item) == "table" and item.type or item
        if kind == "external" then
            parts[#parts + 1] = (type(item) == "table" and item.tool) or "?"
        else
            parts[#parts + 1] = kind
        end
    end
    return #parts > 0 and table.concat(parts, " → ") or "—"
end

--- @param active? string
--- @param cfg OrchRunConfiguration
--- @return string
local function format_details(active, cfg)
    local lines = {
        ("Name:  %s%s"):format(cfg.name, cfg.name == active and "  (active)" or ""),
        ("Type:  %s"):format(cfg.type),
        "",
    }

    if cfg.type == "native" then
        lines[#lines + 1] = ("Runtime:  %s"):format(cfg.runtime or "executable")
        lines[#lines + 1] = ("Target:  %s"):format(cfg.target or "—")
        lines[#lines + 1] = ("Working dir:  %s"):format(cfg.cwd or "${workspace}")
        lines[#lines + 1] = ("Arguments:  %s"):format(#(cfg.args or {}) > 0 and table.concat(cfg.args, " ") or "—")
        local env_count = #vim.tbl_keys(cfg.environment or {})
        lines[#lines + 1] = ("Environment:  %d entr%s"):format(env_count, env_count == 1 and "y" or "ies")
        lines[#lines + 1] = ("Console:  %s"):format(cfg.console and cfg.console.mode or "embedded")
        lines[#lines + 1] = ("Sudo:  %s"):format(cfg.sudo and "yes" or "no")
    elseif cfg.type == "remote-debug" then
        lines[#lines + 1] = ("Symbol:  %s"):format(cfg.symbol or "—")
        lines[#lines + 1] = ("Connection:  %s"):format(cfg.connection or "—")
        lines[#lines + 1] = ("Adapter:  %s"):format(cfg.adapter or "—")
    elseif cfg.type == "compound" then
        lines[#lines + 1] = "Configurations:"
        for _, name in ipairs(cfg.configurations or {}) do
            lines[#lines + 1] = "  • " .. name
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = ("Before launch:  %s"):format(format_before(cfg.before))

    return table.concat(lines, "\n")
end

--- @param base string
--- @return string
local function unique_name(base)
    local state = require("orchlaunch.state")
    local name = base
    local index = 2
    while state.configuration(name) do
        name = ("%s %d"):format(base, index)
        index = index + 1
    end
    return name
end

--- Small fibrous window offering the run-configuration types.
--- @param on_pick fun()
local function choose_type(on_pick)
    local nr = require("fibrous")
    local ui = nr.ui
    local closed = false
    local handle

    local function pick(open_editor)
        if closed then
            return
        end
        closed = true
        if handle then
            handle.unmount()
        end
        vim.schedule(open_editor)
    end

    local function body()
        local function button(label, editor)
            return {
                comp = ui.button,
                props = {
                    label = label,
                    on_press = function()
                        pick(function()
                            editor.open(nil, on_pick)
                        end)
                    end,
                },
            }
        end
        return {
            comp = ui.col,
            props = { grow = 1, gap = 1, style = { padding = { x = 2, y = 1 } } },
            children = {
                { comp = ui.label, props = { text = "New configuration", align_self = "center" } },
                button(" Native ", require("orchlaunch.ui.fibrous.editors.native")),
                button(" Remote Debug ", require("orchlaunch.ui.fibrous.editors.remote")),
                button(" Compound ", require("orchlaunch.ui.fibrous.editors.compound")),
            },
        }
    end

    handle = nr.mount(body, {}, { width = 40, height = 9, zindex = 55 })
    handle.focus()
end

--- Opens the fibrous browser.
--- @return table handle
function M.open()
    local state = require("orchlaunch.state")
    local active = require("orchlaunch.active")
    local runner = require("orchlaunch.runner")

    if not state.is_loaded() then
        vim.notify("[orchlaunch] no .orch project loaded", ERROR)
        return
    end

    local native_editor = require("orchlaunch.ui.fibrous.editors.native")
    local remote_editor = require("orchlaunch.ui.fibrous.editors.remote")
    local compound_editor = require("orchlaunch.ui.fibrous.editors.compound")

    local root = state.root()

    local function run(item, ctx, mode)
        if not item then
            vim.notify("[orchlaunch] no configuration selected", ERROR)
            return
        end
        ctx.close()
        runner.run(item.name, { mode = mode })
    end

    local function duplicate(item, ctx)
        if not item then
            vim.notify("[orchlaunch] no configuration selected", ERROR)
            return
        end
        local copy = vim.deepcopy(item)
        copy.name = unique_name(item.name .. " copy")
        state.add_configuration(copy)
        state.save()
        ctx.refresh()
    end

    local function load_cmake(_, ctx)
        local before = #state.run_configurations().configurations
        runner.load_cmake()
        if #state.run_configurations().configurations ~= before then
            ctx.close()
            vim.schedule(function()
                M.open()
            end)
        else
            ctx.refresh()
        end
    end

    return list.open({
        title = "Run / Debug Configurations",
        new_label = " New config (a) ",
        solo = true,
        items = function()
            return state.run_configurations().configurations
        end,
        label = function(cfg, act)
            local marker = cfg.name == act and "● " or "  "
            return ("%s%s  (%s)"):format(marker, cfg.name, cfg.type)
        end,
        label_hl = function(cfg, act)
            return cfg.name == act and "Title" or "Comment"
        end,
        details = function(cfg, act)
            return format_details(act, cfg)
        end,
        find = state.configuration,
        remove = function(name)
            state.remove_configuration(name)
            if active.get(root) == name then
                active.set(root, nil)
            end
        end,
        active = function()
            return active.get(root)
        end,
        set_active = function(name)
            active.set(root, name)
        end,
        extra_keys = {
            { lhs = "r", handler = function(item, ctx)
                run(item, ctx, "run")
            end },
            { lhs = "d", handler = function(item, ctx)
                run(item, ctx, "debug")
            end },
            { lhs = "y", handler = duplicate },
            { lhs = "m", handler = load_cmake },
        },
        extra_hints = { "r  Run", "d  Debug", "y  Duplicate", "m  Load CMake" },
        open = function(existing, on_saved)
            if existing == nil then
                return choose_type(on_saved)
            end
            if existing.type == "native" then
                return native_editor.open(existing, on_saved)
            elseif existing.type == "remote-debug" then
                return remote_editor.open(existing, on_saved)
            elseif existing.type == "compound" then
                return compound_editor.open(existing, on_saved)
            end
            vim.notify(("[orchlaunch] cannot edit unknown configuration type: %s"):format(existing.type), ERROR)
            on_saved()
        end,
    })
end

return M
