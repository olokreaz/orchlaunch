-- OrchLaunch — the CLion-like Run/Debug Configurations browser.
--
-- Lists every run configuration, shows its details, and exposes the usual
-- actions (Run, Debug, Edit, New, Duplicate, Delete, Set Active) plus the
-- entry points to the toolchain / external tool / CMake editors.

local UI = require("orchlaunch.ui")

local ERROR = vim.log.levels.ERROR

local M = {}

-- ============================================================================
-- Details
-- ============================================================================

--- @param list? string[]
--- @param label string
--- @return string?
local function section(label, list)
    if not list or #list == 0 then
        return nil
    end
    return ("%s: %s"):format(label, table.concat(list, " "))
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
        lines[#lines + 1] = ("Target:  %s"):format(cfg.target or "—")
        lines[#lines + 1] = ("Working dir:  %s"):format(cfg.cwd or "${workspace}")
        lines[#lines + 1] = ("Arguments:  %s"):format(#(cfg.args or {}) > 0 and table.concat(cfg.args, " ") or "—")
        lines[#lines + 1] = ("Environment:  %d entr%s"):format(#vim.tbl_keys(cfg.environment or {}), #vim.tbl_keys(cfg.environment or {}) == 1 and "y" or "ies")
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

-- ============================================================================
-- Helpers
-- ============================================================================

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

-- ============================================================================
-- Browser
-- ============================================================================

function M.open()
    local fibrous = require("orchlaunch.ui.fibrous.browser")
    if fibrous.available() then
        return fibrous.open()
    end

    local state = require("orchlaunch.state")
    local active = require("orchlaunch.active")
    local native_editor = require("orchlaunch.ui.editors.native")
    local remote_editor = require("orchlaunch.ui.editors.remote")
    local compound_editor = require("orchlaunch.ui.editors.compound")
    local runner = require("orchlaunch.runner")

    if not state.is_loaded() then
        UI.notify("no .orch project loaded", ERROR)
        return
    end

    local n = UI.n()
    local root = state.root()
    local renderer = UI.renderer({ width = 120, height = 35 })

    local model = n.create_signal({ list = {}, details = "" })
    local mounted = false

    --- @return string?
    local function selected_name()
        if not mounted then
            return nil
        end

        local list = renderer:get_component_by_id("orch_list")
        local node = list and list:get_focused_node()
        return node and node.id
    end

    local function update_details()
        local name = selected_name()
        local cfg = name and state.configuration(name)

        if not cfg then
            cfg = state.run_configurations().configurations[1]
        end

        model.details = cfg and format_details(active.get(root), cfg) or "No configurations defined. Press (a) to create one."
    end

    --- Rebuilds the list of configurations and refreshes the details pane.
    local function refresh_list()
        local nodes = {}
        for _, cfg in ipairs(state.run_configurations().configurations) do
            local marker = cfg.name == active.get(root) and "● " or "  "
            nodes[#nodes + 1] = n.option(("%s%s  (%s)"):format(marker, cfg.name, cfg.type), { id = cfg.name })
        end
        model.list = nodes
        update_details()
    end

    local function run(mode)
        local name = selected_name()
        if not name then
            UI.notify("no configuration selected", ERROR)
            return
        end
        renderer:close()
        runner.run(name, { mode = mode })
    end

    --- Reopens the browser after a nested chooser or editor closes.
    local function reopen()
        vim.schedule(function()
            M.open()
        end)
    end

    local function new_configuration()
        local chooser = UI.renderer({ width = 40, height = 8 })

        local pick = function(callback)
            return function()
                chooser:close()
                renderer:close()
                callback()
            end
        end

        chooser:render(function()
            return n.rows(
                { flex = 1, direction = "column", padding = { top = 1, left = 1, right = 1, bottom = 1 } },
                n.paragraph({ lines = "New configuration", align = "center", is_focusable = false }),
                n.gap(1),
                n.button({
                    label = " Native ",
                    autofocus = true,
                    on_press = pick(function()
                        native_editor.open(nil, nil, { on_unmount = reopen })
                    end),
                }),
                n.button({ label = " Remote Debug ", on_press = pick(function()
                    remote_editor.open(nil, nil, { on_unmount = reopen })
                end) }),
                n.button({ label = " Compound ", on_press = pick(function()
                    compound_editor.open(nil, nil, { on_unmount = reopen })
                end) })
            )
        end)
    end

    local function edit_selected()
        local name = selected_name()
        local cfg = name and state.configuration(name)
        if not cfg then
            UI.notify("no configuration selected", ERROR)
            return
        end

        renderer:close()

        if cfg.type == "native" then
            native_editor.open(cfg, nil, { on_unmount = reopen })
        elseif cfg.type == "remote-debug" then
            remote_editor.open(cfg, nil, { on_unmount = reopen })
        elseif cfg.type == "compound" then
            compound_editor.open(cfg, nil, { on_unmount = reopen })
        else
            reopen()
            UI.notify(("cannot edit unknown configuration type: %s"):format(cfg.type), ERROR)
        end
    end

    local function duplicate_selected()
        local name = selected_name()
        local cfg = name and state.configuration(name)
        if not cfg then
            UI.notify("no configuration selected", ERROR)
            return
        end

        local copy = vim.deepcopy(cfg)
        copy.name = unique_name(cfg.name .. " copy")
        state.add_configuration(copy)
        state.save()
        refresh_list()
    end

    local function delete_selected()
        local name = selected_name()
        if not name or not state.configuration(name) then
            UI.notify("no configuration selected", ERROR)
            return
        end

        if vim.fn.confirm(("Delete configuration %q?"):format(name), "&Yes\n&No") ~= 1 then
            return
        end

        state.remove_configuration(name)
        if active.get(root) == name then
            active.set(root, nil)
        end
        state.save()
        refresh_list()
    end

    local function set_active()
        local name = selected_name()
        if not name then
            UI.notify("no configuration selected", ERROR)
            return
        end
        active.set(root, name)
        refresh_list()
    end

    local function load_cmake()
        local before = #state.run_configurations().configurations
        runner.load_cmake()

        if #state.run_configurations().configurations ~= before then
            renderer:close()
            reopen()
        end
    end

    renderer:add_mappings({
        {
            mode = "n",
            key = "r",
            handler = function()
                run("run")
            end,
        },
        {
            mode = "n",
            key = "d",
            handler = function()
                run("debug")
            end,
        },
        { mode = "n", key = "e", handler = edit_selected },
        { mode = "n", key = "a", handler = new_configuration },
        { mode = "n", key = "y", handler = duplicate_selected },
        { mode = "n", key = "D", handler = delete_selected },
        { mode = "n", key = "A", handler = set_active },
        { mode = "n", key = "m", handler = load_cmake },
    })

    local function open_toolchains()
        renderer:close()
        require("orchlaunch.ui.dialogs.toolchains").open()
    end

    local function open_external_tools()
        renderer:close()
        require("orchlaunch.ui.dialogs.external_tools").open()
    end

    local function open_cmake()
        renderer:close()
        local dialog = require("orchlaunch.ui.fibrous.cmake_profiles")
        if dialog.available() then
            dialog.open()
        else
            require("orchlaunch.ui.dialogs.cmake_profiles").open()
        end
    end

    --- Renders the configuration list, or a placeholder when it is empty.
    local function list_node()
        local items = model.list:get_value() or {}

        if #items == 0 then
            return n.paragraph({
                flex = 1,
                align = "center",
                autofocus = true,
                is_focusable = true,
                lines = "No configurations yet. Press (a) to create one.",
                border_label = " Configurations ",
                border_style = "rounded",
            })
        end

        return n.select({
            id = "orch_list",
            flex = 1,
            autofocus = true,
            data = model.list,
            border_label = " Configurations ",
            border_style = "rounded",
            on_change = function()
                update_details()
                vim.schedule(update_details)
            end,
            on_select = function()
                update_details()
                vim.schedule(update_details)
            end,
        })
    end

    local body = function()
        refresh_list()

        return n.rows(
            { flex = 1, direction = "column", padding = { top = 1, left = 1, right = 1, bottom = 1 } },
            n.paragraph({ lines = "Run / Debug Configurations", align = "center", is_focusable = false }),
            n.gap(1),
            n.columns(
                { flex = 1 },
                list_node(),
                n.gap(1),
                n.box(
                    { flex = 2, direction = "column" },
                    n.paragraph({
                        id = "orch_details",
                        flex = 1,
                        is_focusable = false,
                        lines = model.details,
                        border_label = " Details ",
                        border_style = "rounded",
                    })
                )
            ),
            n.gap(1),
            n.columns(
                { size = 1 },
                n.button({
                    label = " Run (r) ",
                    on_press = function()
                        run("run")
                    end,
                }),
                n.gap(1),
                n.button({
                    label = " Debug (d) ",
                    on_press = function()
                        run("debug")
                    end,
                }),
                n.gap(1),
                n.button({ label = " Edit (e) ", on_press = edit_selected }),
                n.gap(1),
                n.button({ label = " New (a) ", on_press = new_configuration }),
                n.gap(1),
                n.button({ label = " Duplicate (y) ", on_press = duplicate_selected }),
                n.gap(1),
                n.button({ label = " Delete (D) ", on_press = delete_selected }),
                n.gap(1),
                n.button({ label = " Set Active (A) ", on_press = set_active })
            ),
            n.gap(1),
            n.columns(
                { size = 1 },
                n.button({ label = " Toolchains… ", on_press = open_toolchains }),
                n.gap(1),
                n.button({ label = " External Tools… ", on_press = open_external_tools }),
                n.gap(1),
                n.button({ label = " CMake… ", on_press = open_cmake }),
                n.gap(1),
                n.button({ label = " Load CMake (m) ", on_press = load_cmake }),
                n.gap(1),
                n.button({
                    label = " Close ",
                    on_press = function()
                        renderer:close()
                    end,
                })
            )
        )
    end

    renderer:render(body)
    mounted = true
    vim.schedule(update_details)
    return renderer
end

return M
