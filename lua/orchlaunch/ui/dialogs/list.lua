-- OrchLaunch — generic list dialog engine.
--
-- A list dialog is a name + details browser with a create/edit/delete
-- workflow. Concrete dialogs (toolchains, external tools, CMake profiles)
-- supply a spec and reuse this engine; only their labels, detail formatter
-- and editor differ.

local UI = require("orchlaunch.ui")

local ERROR = vim.log.levels.ERROR

local M = {}

--- @class OrchListSpec
--- @field title string
--- @field new_label string
--- @field list_label? string Border label for the list pane.
--- @field items fun(): table[]
--- @field label fun(item: table): string
--- @field details fun(item: table): string
--- @field find fun(name: string): table?
--- @field open fun(existing: table?, on_saved: fun())
--- @field remove fun(name: string)
--- @field set_active? fun(name: string) Marks a row as the active one.
--- @field import? fun(): integer Imports items, returning how many were added.
--- @field project? fun(on_saved: fun()) Opens a project-wide editor.
--- @field solo? boolean Close this list while editing, then reopen it.

--- @param spec OrchListSpec
--- @return table renderer
function M.open(spec)
    local n = UI.n()
    local state = require("orchlaunch.state")

    local dialog_width = 92
    local renderer = UI.renderer({ width = dialog_width, height = 26 })
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
                M.open(spec)
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
                M.open(spec)
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
            key = "q",
            handler = function()
                renderer:close()
            end,
        },
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
        local label = spec.list_label or " Items "

        if #items == 0 then
            return n.paragraph({
                flex = 1,
                align = "center",
                autofocus = true,
                is_focusable = true,
                lines = "No items yet. Press (a) to create one.",
                border_label = label,
                border_style = "rounded",
            })
        end

        return n.select({
            id = "orch_list",
            flex = 1,
            autofocus = true,
            data = model.list,
            border_label = label,
            border_style = "rounded",
            on_change = function()
                update_details()
                vim.schedule(update_details)
            end,
        })
    end

    --- Builds the footer hint from the actions this spec supports, wrapped
    --- to the available width so nothing gets clipped.
    local function key_hints()
        local parts = {
            vim.trim(spec.new_label),
            "e  Edit",
            "D  Delete",
        }

        if spec.set_active then
            parts[#parts + 1] = "A  Set Active"
        end
        if spec.import then
            parts[#parts + 1] = "i  Import presets"
        end
        if spec.project then
            parts[#parts + 1] = "p  Project"
        end

        parts[#parts + 1] = "<Esc>  Close"

        local max = dialog_width - 8
        local lines, line = {}, ""

        for _, part in ipairs(parts) do
            local candidate = (#line == 0) and part or (line .. "    " .. part)
            if #line > 0 and vim.fn.strwidth(candidate) > max then
                lines[#lines + 1] = line
                line = part
            else
                line = candidate
            end
        end

        if line ~= "" then
            lines[#lines + 1] = line
        end

        return lines
    end

    local function body()
        refresh_list()

        return n.rows(
            { flex = 1, direction = "column" },
            n.paragraph({ lines = spec.title, align = "center", is_focusable = false }),
            n.gap(1),
            n.columns(
                { flex = 1 },
                list_node(),
                n.gap(2),
                n.box(
                    { flex = 2, direction = "column" },
                    n.paragraph({
                        id = "orch_details",
                        flex = 1,
                        is_focusable = false,
                        border_label = " Details ",
                        border_style = "rounded",
                        lines = model.details,
                    })
                )
            ),
            n.gap(1),
            n.paragraph({
                align = "center",
                is_focusable = false,
                lines = table.concat(key_hints(), "\n"),
            })
        )
    end

    renderer:render(body)
    mounted = true
    vim.schedule(update_details)
    return renderer
end

return M
