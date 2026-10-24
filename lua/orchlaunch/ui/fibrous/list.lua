-- OrchLaunch — generic fibrous list dialog.
--
-- A name + details browser with a create/edit/delete workflow. Concrete
-- dialogs supply a spec; only their title, labels, detail formatter, editor
-- and (optional) extra actions differ.
--
-- The editor callbacks re-enter through `on_saved` so a dialog that closes
-- itself while editing (`solo`) can reopen once the editor is done.

local util = require("orchlaunch.ui.fibrous.util")

local ERROR = vim.log.levels.ERROR

local M = {}

--- @return boolean
function M.available()
    return util.available()
end

--- @class OrchFibrousListSpec
--- @field title string
--- @field new_label? string e.g. " New profile (a) "
--- @field items fun(): table[]
--- @field label fun(item: table, active: string?): string
--- @field details fun(item: table, active: string?): string
--- @field find? fun(name: string): table?
--- @field open? fun(existing: table?, on_saved: fun())
--- @field remove? fun(name: string)
--- @field key? fun(item: table): string Defaults to `item.name`.
--- @field label_hl? fun(item: table, active: string?): string? Text highlight for a row.
--- @field empty_text? string
--- @field solo? boolean Close the list while editing, then reopen it.
--- @field active? fun(): string? Marks a row as the active one.
--- @field set_active? fun(name: string)
--- @field import? fun(): integer
--- @field import_note? fun(added: integer): string
--- @field project? fun(on_saved: fun())
--- @field extra_keys? { { lhs: string, handler: function } }[] Extra single-key actions.
--- @field extra_hints? string[] Extra footer hints appended after the standard ones.

--- Opens the fibrous list dialog.
--- @param spec OrchFibrousListSpec
--- @return table handle
function M.open(spec)
    local ok, nr = pcall(require, "fibrous")
    if not ok then
        error("fibrous is not installed", 0)
    end

    local ui = nr.ui
    local state = require("orchlaunch.state")

    local selected --- state handle, assigned on first render
    local revision --- state handle, bumped to force a re-render after mutations
    local handle
    local augroup = util.unique_augroup("OrchlaunchFibrousList")

    local function key_of(item)
        return spec.key and spec.key(item) or item.name
    end

    --- @return table? item
    --- @return integer index
    local function current()
        local items = spec.items()
        local index = math.min(math.max(1, selected and selected.get() or 1), math.max(1, #items))
        return items[index], index
    end

    local function refresh()
        revision.set((revision.get() or 0) + 1)
    end

    local function clamp_selection()
        local count = #spec.items()
        if count > 0 and (selected.get() or 1) > count then
            selected.set(count)
        end
    end

    local function close()
        pcall(vim.api.nvim_del_augroup_by_name, augroup)
        if handle then
            handle.unmount()
        end
    end

    local function reopen()
        vim.schedule(function()
            M.open(spec)
        end)
    end

    local function move_to(index)
        local count = #spec.items()
        if count == 0 then
            return
        end
        selected.set(math.min(math.max(1, index), count))
    end

    local function open_editor(existing)
        if not spec.open then
            return
        end
        if spec.solo then
            close()
            spec.open(existing, reopen)
        else
            spec.open(existing, refresh)
        end
    end

    local function edit_item()
        if not spec.open then
            return
        end
        local item = current()
        if not item then
            vim.notify("[orchlaunch] no item selected", ERROR)
            return
        end
        open_editor(item)
    end

    local function delete_item()
        if not spec.remove then
            return
        end
        local item = current()
        if not item then
            vim.notify("[orchlaunch] no item selected", ERROR)
            return
        end
        if vim.fn.confirm(("Delete %q?"):format(key_of(item)), "&Yes\n&No") ~= 1 then
            return
        end
        spec.remove(key_of(item))
        state.save()
        clamp_selection()
        refresh()
    end

    local function set_active()
        local item = current()
        if not item then
            vim.notify("[orchlaunch] no item selected", ERROR)
            return
        end
        spec.set_active(key_of(item))
        state.save()
        refresh()
    end

    local function import_items()
        local added = spec.import()
        state.save()
        refresh()
        local note = spec.import_note and spec.import_note(added) or ("imported %d item(s)"):format(added)
        vim.notify("[orchlaunch] " .. note)
    end

    local function edit_project()
        if spec.solo then
            close()
            spec.project(reopen)
        else
            spec.project(refresh)
        end
    end

    local mount_opts = { zindex = 50 }
    -- Restore the window focused before the dialog opened (it may itself be a
    -- float, in which case Neovim would otherwise fall back to the editor).
    local origin_winid = vim.api.nvim_get_current_win()
    mount_opts.on_unmount = function()
        if origin_winid and vim.api.nvim_win_is_valid(origin_winid)
            and vim.api.nvim_get_current_win() ~= origin_winid then
            pcall(vim.api.nvim_set_current_win, origin_winid)
        end
    end

    local function Body(ctx)
        revision = ctx.use_state(0)
        if not selected then
            selected = ctx.use_state(1)
        end
        revision.get() -- re-render on demand after state mutations

        local items = spec.items()
        local active = spec.active and spec.active() or nil
        local index = math.min(math.max(1, selected.get()), math.max(1, #items))
        local item = items[index]
        local empty = spec.empty_text or "No items yet. Press (a) to create one."

        local rows = {}
        local list_width = 0
        if #items == 0 then
            rows[1] = { comp = ui.label, props = { text = empty, style = { text_hl = "Comment" } } }
        else
            for i, entry in ipairs(items) do
                local text = spec.label(entry, active)
                list_width = math.max(list_width, vim.fn.strwidth(text))
                rows[#rows + 1] = {
                    comp = ui.label,
                    props = {
                        text = text,
                        role = "button",
                        on_press = function()
                            selected.set(i)
                        end,
                        style = {
                            text_hl = spec.label_hl and spec.label_hl(entry, active) or "Comment",
                            hl = i == index and "Visual" or nil,
                            _hover = { hl = i == index and "Visual" or "CursorLine" },
                        },
                        align_self = "stretch",
                    },
                }
            end
        end

        -- The list pane is sized to its longest row so names never clip; the
        -- border (1+1) and horizontal padding (1+1) are inside the border box.
        list_width = math.min(math.max(24, list_width + 5), 64)

        local details = item and spec.details(item, active) or empty

        local hints = {}
        if spec.new_label then
            hints[#hints + 1] = vim.trim(spec.new_label)
        end
        if spec.open then
            hints[#hints + 1] = "e  Edit"
        end
        if spec.remove then
            hints[#hints + 1] = "D  Delete"
        end
        if spec.set_active then
            hints[#hints + 1] = "A  Set Active"
        end
        if spec.import then
            hints[#hints + 1] = "i  Import presets"
        end
        if spec.project then
            hints[#hints + 1] = "p  Project"
        end
        hints[#hints + 1] = "q/<Esc>  Close"
        if spec.extra_hints then
            for _, hint in ipairs(spec.extra_hints) do
                hints[#hints + 1] = hint
            end
        end

        local hint_lines, line = {}, ""
        local hint_max = (mount_opts.width or vim.o.columns) - 10
        for _, part in ipairs(hints) do
            local candidate = (#line == 0) and part or (line .. "    " .. part)
            if #line > 0 and vim.fn.strwidth(candidate) > hint_max then
                hint_lines[#hint_lines + 1] = line
                line = part
            else
                line = candidate
            end
        end
        if line ~= "" then
            hint_lines[#hint_lines + 1] = line
        end

        local hint_nodes = {}
        for _, hint in ipairs(hint_lines) do
            hint_nodes[#hint_nodes + 1] = {
                comp = ui.label,
                props = { text = "  " .. hint .. "  ", align_self = "center", style = { text_hl = "Comment" } },
            }
        end

        return {
            comp = ui.col,
            props = { grow = 1, gap = 0, style = { padding = { x = 1, y = 1 } } },
            children = {
                {
                    comp = ui.label,
                    props = { text = spec.title, align_self = "center", style = { text_hl = "Title" } },
                },
                {
                    comp = ui.row,
                    props = { grow = 1, gap = 2 },
                    children = {
                        {
                            comp = ui.col,
                            props = { width = list_width, gap = 0, style = { border = "rounded", padding = { x = 1 } } },
                            children = rows,
                        },
                        {
                            comp = ui.col,
                            props = { grow = 1, gap = 0, style = { border = "rounded", padding = { x = 1 } } },
                            children = { { comp = ui.label, props = { text = details, grow = 1 } } },
                        },
                    },
                },
                { comp = ui.col, props = { gap = 0 }, children = hint_nodes },
            },
        }
    end

    local function apply_size()
        util.apply_size(mount_opts, 0.75, 0.8, 80, math.huge, 20, 36)
    end

    apply_size()
    handle = nr.mount(Body, {}, mount_opts)
    handle.focus()

    util.watch_resize(augroup, mount_opts, apply_size, function()
        return handle
    end)

    --- @param lhs string
    --- @param rhs function
    local function map(lhs, rhs)
        vim.keymap.set("n", lhs, rhs, { buffer = handle.bufnr, nowait = true, silent = true })
    end

    map("q", close)
    map("<Esc>", close)
    map("j", function()
        move_to((selected and selected.get() or 1) + 1)
    end)
    map("<Down>", function()
        move_to((selected and selected.get() or 1) + 1)
    end)
    map("k", function()
        move_to((selected and selected.get() or 1) - 1)
    end)
    map("<Up>", function()
        move_to((selected and selected.get() or 1) - 1)
    end)
    if spec.open then
        map("a", function()
            open_editor(nil)
        end)
        map("e", edit_item)
    end
    if spec.remove then
        map("D", delete_item)
    end
    if spec.set_active then
        map("A", set_active)
    end
    if spec.import then
        map("i", import_items)
    end
    if spec.project then
        map("p", edit_project)
    end
    if spec.extra_keys then
        for _, extra in ipairs(spec.extra_keys) do
            map(extra.lhs, function()
                extra.handler(current(), { close = close, refresh = refresh })
            end)
        end
    end

    return handle
end

return M
