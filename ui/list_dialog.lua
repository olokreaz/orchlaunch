-- OrchLaunch — generic list dialogs for toolchains and external tools.
--
-- Both are simple name + details lists that share the same create/edit/delete
-- workflow; only the labels, the detail formatter and the editor differ.

local UI = require("orchlaunch.ui")

local ERROR = vim.log.levels.ERROR

local M = {}

--- @class OrchListSpec
--- @field title string
--- @field new_label string
--- @field items fun(): table[]
--- @field label fun(item: table): string
--- @field details fun(item: table): string
--- @field find fun(name: string): table?
--- @field open fun(existing: table?, on_saved: fun())
--- @field remove fun(name: string)
--- @field set_active? fun(name: string) Marks a row as the active one.
--- @field toggle? fun(name: string) Toggles a row on/off.
--- @field import? fun(): integer Imports items, returning how many were added.
--- @field project? fun(on_saved: fun()) Opens a project-wide editor.
--- @field solo? boolean Close this list while editing, then reopen it.

--- @param spec OrchListSpec
local function open(spec)
    local n = UI.n()
    local state = require("orchlaunch.state")

    local renderer = UI.renderer({ width = 92, height = 26 })
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
        local items = spec.items()
        local name = selected_name()
        local item = name and spec.find(name) or items[1]
        local newd = item and spec.details(item) or "No items yet. Press (a) to create one."
        model.details = newd
    end

    local function refresh_list()
        local nodes = {}
        for _, item in ipairs(spec.items()) do
            nodes[#nodes + 1] = n.option(spec.label(item), { id = item.name })
        end
        model.list = nodes
        update_details()
    end

    local function open_editor(existing)
        if spec.solo then
            renderer:close()
            spec.open(existing, function()
                open(spec)
            end)
        else
            spec.open(existing, refresh_list)
        end
    end

    local function new_item()
        open_editor(nil)
    end

    local function edit_item()
        local name = selected_name()
        local item = name and spec.find(name)
        if not item then
            UI.notify("no item selected", ERROR)
            return
        end
        open_editor(item)
    end

    local function delete_item()
        local name = selected_name()
        if not name or not spec.find(name) then
            UI.notify("no item selected", ERROR)
            return
        end

        if vim.fn.confirm(("Delete %q?"):format(name), "&Yes\n&No") ~= 1 then
            return
        end

        spec.remove(name)
        state.save()
        refresh_list()
    end

    local function set_active()
        local name = selected_name()
        if not name or not spec.find(name) then
            UI.notify("no item selected", ERROR)
            return
        end
        spec.set_active(name)
        refresh_list()
    end

    local function toggle_item()
        local name = selected_name()
        if not name or not spec.find(name) then
            UI.notify("no item selected", ERROR)
            return
        end
        spec.toggle(name)
        state.save()
        refresh_list()
    end

    local function import_items()
        local added = spec.import()
        state.save()
        refresh_list()
        UI.notify(("imported %d item(s)"):format(added))
    end

    local function edit_project()
        if spec.solo then
            renderer:close()
            spec.project(function()
                open(spec)
            end)
        else
            spec.project(refresh_list)
        end
    end

    renderer:add_mappings({
        { mode = "n", key = "a", handler = new_item },
        { mode = "n", key = "e", handler = edit_item },
        { mode = "n", key = "D", handler = delete_item },
        {
            mode = "n",
            key = "A",
            handler = function()
                if spec.set_active then
                    set_active()
                end
            end,
        },
        {
            mode = "n",
            key = "t",
            handler = function()
                if spec.toggle then
                    toggle_item()
                end
            end,
        },
        {
            mode = "n",
            key = "i",
            handler = function()
                if spec.import then
                    import_items()
                end
            end,
        },
        {
            mode = "n",
            key = "p",
            handler = function()
                if spec.project then
                    edit_project()
                end
            end,
        },
    })

    --- Renders the item list, or a placeholder when it is empty.
    local function list_node()
        local items = model.list:get_value() or {}

        if #items == 0 then
            return n.paragraph({
                flex = 1,
                align = "center",
                autofocus = true,
                is_focusable = true,
                lines = "No items yet. Press (a) to create one.",
                border_label = " Items ",
                border_style = "rounded",
            })
        end

        return n.select({
            id = "orch_list",
            flex = 1,
            autofocus = true,
            data = model.list,
            border_label = " Items ",
            border_style = "rounded",
            on_change = function()
                update_details()
                vim.schedule(update_details)
            end,
        })
    end

    local body = function()
        refresh_list()

        local actions = {
            n.button({ label = spec.new_label, on_press = new_item }),
            n.gap(1),
            n.button({ label = " Edit (e) ", on_press = edit_item }),
            n.gap(1),
            n.button({ label = " Delete (D) ", on_press = delete_item }),
        }

        if spec.project then
            actions[#actions + 1] = n.gap(1)
            actions[#actions + 1] = n.button({ label = " Project (p) ", on_press = edit_project })
        end

        if spec.toggle then
            actions[#actions + 1] = n.gap(1)
            actions[#actions + 1] = n.button({ label = " Toggle (t) ", on_press = toggle_item })
        end

        if spec.set_active then
            actions[#actions + 1] = n.gap(1)
            actions[#actions + 1] = n.button({ label = " Set Active (A) ", on_press = set_active })
        end

        if spec.import then
            actions[#actions + 1] = n.gap(1)
            actions[#actions + 1] = n.button({ label = " Import presets (i) ", on_press = import_items })
        end

        actions[#actions + 1] = n.gap(1)
        actions[#actions + 1] = n.button({
            label = " Close ",
            on_press = function()
                renderer:close()
            end,
        })

        return n.rows(
            { flex = 1, direction = "column", padding = { top = 1, left = 1, right = 1, bottom = 1 } },
            n.paragraph({ lines = spec.title, align = "center", is_focusable = false }),
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
            n.columns({ size = 1 }, (table.unpack or unpack)(actions))
        )
    end

    renderer:render(body)
    mounted = true
    vim.schedule(update_details)
    return renderer
end

-- ============================================================================
-- Toolchains
-- ============================================================================

function M.open_toolchains()
    local state = require("orchlaunch.state")
    local editor = require("orchlaunch.ui.editor")

    return open({
        title = "Toolchains",
        new_label = " New chain (a) ",
        items = function()
            return state.toolchains().toolchains
        end,
        label = function(item)
            return ("%s  (%s)"):format(item.name, item.type or "?")
        end,
        details = function(item)
            return table.concat({
                ("Name:  %s"):format(item.name),
                ("Type:  %s"):format(item.type or "—"),
                ("CMake:  %s"):format(item.cmake or "—"),
                ("C:  %s"):format(item.c or "—"),
                ("C++:  %s"):format(item.cxx or "—"),
                ("Debugger:  %s"):format(item.debugger or "—"),
            }, "\n")
        end,
        find = state.toolchain,
        open = editor.open_toolchain,
        remove = state.remove_toolchain,
    })
end

-- ============================================================================
-- External tools
-- ============================================================================

function M.open_external_tools()
    local state = require("orchlaunch.state")
    local editor = require("orchlaunch.ui.editor")

    return open({
        title = "External Tools",
        new_label = " New tool (a) ",
        items = function()
            return state.external_tools().tools
        end,
        label = function(item)
            return item.name
        end,
        details = function(item)
            return table.concat({
                ("Name:  %s"):format(item.name),
                ("Program:  %s"):format(item.program or "—"),
                ("Working dir:  %s"):format(item.cwd or "${workspace}"),
                ("Arguments:  %s"):format(#(item.args or {}) > 0 and table.concat(item.args, " ") or "—"),
                ("Sudo:  %s"):format(item.sudo and "yes" or "no"),
            }, "\n")
        end,
        find = state.external_tool,
        open = editor.open_external_tool,
        remove = state.remove_external_tool,
    })
end

-- ============================================================================
-- CMake profiles
-- ============================================================================

function M.open_cmake_profiles()
    local state = require("orchlaunch.state")
    local editor = require("orchlaunch.ui.editor")

    return open({
        title = ("CMake Profiles — project: %s"):format(state.cmake_source_dir()),
        new_label = " New profile (a) ",
        items = function()
            return state.cmake_profiles()
        end,
        label = function(item)
            local active = state.active_cmake_profile()
            local marker = item.name == active and "● " or "  "
            local off = item.enabled == false and "  (off)" or ""
            local kind = item.kind and ("  <" .. item.kind .. ">") or ""
            return ("%s%s%s%s"):format(marker, item.name, kind, off)
        end,
        details = function(item)
            local active = state.active_cmake_profile()
            local lines = {
                ("Name:  %s%s"):format(item.name, item.name == active and "  (active)" or ""),
                ("Enabled:  %s"):format(item.enabled == false and "no" or "yes"),
                ("Source:  %s"):format(item.kind or "manual"),
            }

            if item.kind then
                lines[#lines + 1] = ("Configure preset:  %s"):format(item.configure_preset or "—")
                lines[#lines + 1] = ("Build preset:  %s"):format(item.build_preset or "—")
                lines[#lines + 1] = ("Toolchain:  %s"):format(item.toolchain or "—")
            else
                lines[#lines + 1] = ("Toolchain:  %s"):format(item.toolchain or "—")
                lines[#lines + 1] = ("Configure preset:  %s"):format(item.configure_preset or "—")
                lines[#lines + 1] = ("Build preset:  %s"):format(item.build_preset or "—")
                lines[#lines + 1] = ("Generator:  %s"):format(item.generator or "—")
                lines[#lines + 1] = ("Build type:  %s"):format(item.build_type or "—")
                lines[#lines + 1] = ("Build dir:  %s"):format(item.build_dir or "—")
            end

            return table.concat(lines, "\n")
        end,
        find = state.cmake_profile,
        open = editor.open_cmake,
        project = editor.open_cmake_project,
        remove = state.remove_cmake_profile,
        set_active = function(name)
            state.set_active_cmake_profile(name)
            state.save()
        end,
        toggle = function(name)
            state.toggle_cmake_profile(name)
        end,
        import = function()
            return state.sync_cmake_profiles()
        end,
        solo = true,
    })
end

return M
