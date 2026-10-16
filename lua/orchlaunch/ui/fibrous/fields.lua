-- OrchLaunch — fibrous form field navigation.
--
-- fibrous owns canvas traversal (`<Tab>`/`<S-Tab>` park the cursor on the next
-- interactive node, `<CR>`/`i` dive in). On top of that this makes a form feel
-- continuous:
--   * `<Tab>`/`<S-Tab>`/`<C-j>`/`<C-k>` INSIDE a field pop back to the canvas,
--     step to the next/previous field and enter it ready to type;
--   * a single `<Esc>` in a single-line field leaves it (multiline fields keep
--     the native second-`<Esc>` so normal editing inside them still works);
--   * `s` runs a letter flash jump from the canvas or any field;
--   * `ui.dropdown` only navigates its popup with `<C-n>`/`<C-p>`, so the arrow
--     keys are aliased to those on dropdown buffers.
--
-- Field cells come from `fibrous.targets` (the same geometry fibrous shapes for
-- flash.nvim): each widget's real cursor cell in the window displaying it. That
-- is what makes a dropdown reachable — its traversable stop sits on the `[▾`
-- mark, not the input cell, so the raw cursor-parity cycle cannot enter it.
--
-- Subwindow floats and their buffers are recreated on every render, so the
-- buffer-local maps are (re)applied from an autocmd, guarded by a buffer flag.

local util = require("orchlaunch.ui.fibrous.util")

local flash_ns = vim.api.nvim_create_namespace("orchlaunch_fibrous_flash")

local FLASH_LETTERS = "asdfghjklqwertyuiopzxcvbnm"

local M = {}

--- Attaches field navigation and the flash jump to a mounted form.
--- @param handle table fibrous mount handle
--- @return table { cells: fun(): table[] } test hook
function M.attach(handle)
    local function dlog(line)
        util.dlog("module", line)
    end

    local field_cells
    local flash_hl = false

    -- Move to the next/previous field and dive in. We enumerate the field cells
    -- once, step by index from the field under the cursor, then move the root
    -- cursor onto the target cell and let fibrous' `i` enter it.
    local function field_cycle(dir, enter)
        local focused = vim.api.nvim_get_current_win() ~= handle.winid
        vim.cmd("stopinsert")
        if not vim.api.nvim_win_is_valid(handle.winid) then
            return
        end
        vim.api.nvim_set_current_win(handle.winid)
        local cur = vim.api.nvim_win_get_cursor(handle.winid)
        local crow, ccol = cur[1] - 1, cur[2]
        local cells = field_cells()
        -- fibrous.targets lists only the widgets shown in the root mirror, so
        -- the field we are leaving is missing while it is focused. The root
        -- cursor still sits on its cell (entering never moved it), so splice it
        -- back in to keep the step aligned.
        if focused then
            cells[#cells + 1] = { row = crow, col = ccol }
            local seen, uniq = {}, {}
            for _, cell in ipairs(cells) do
                local k = cell.row .. ":" .. cell.col
                if not seen[k] then
                    seen[k] = true
                    uniq[#uniq + 1] = cell
                end
            end
            cells = uniq
            table.sort(cells, function(a, b)
                if a.row ~= b.row then
                    return a.row < b.row
                end
                return a.col < b.col
            end)
        end
        if #cells == 0 then
            return
        end
        local idx, best = 1, math.huge
        for i, cell in ipairs(cells) do
            local d = math.abs(cell.row - crow) + math.abs(cell.col - ccol)
            if d < best then
                idx, best = i, d
            end
        end
        local target = cells[((idx - 1 + dir) % #cells) + 1]
        dlog(("cycle dir=%d focused=%s cells=%d cur=%d,%d idx=%d target=%d,%d"):format(dir, tostring(focused), #cells, crow, ccol, idx, target.row, target.col))
        -- Enter on the next event-loop turn: blurring a field schedules a
        -- re-render, and moving the cursor before it flushes lands on a stale
        -- rect that fibrous' hit-test then rejects.
        vim.schedule(function()
            if not vim.api.nvim_win_is_valid(handle.winid) then
                return
            end
            vim.api.nvim_set_current_win(handle.winid)
            vim.api.nvim_win_set_cursor(handle.winid, { target.row + 1, target.col })
            if enter then
                vim.api.nvim_feedkeys("i", "m", false)
            end
        end)
    end

    local function field_leave()
        dlog(("leave mode=%s win=%d"):format(vim.api.nvim_get_mode().mode, vim.api.nvim_get_current_win()))
        vim.cmd("stopinsert")
        if vim.api.nvim_win_is_valid(handle.winid) then
            vim.api.nvim_set_current_win(handle.winid)
        end
    end

    field_cells = function()
        if not vim.api.nvim_win_is_valid(handle.winid) then
            return {}
        end
        local ok, list = pcall(require("fibrous.targets").targets, { winid = handle.winid })
        if not ok or type(list) ~= "table" then
            return {}
        end
        local cells = {}
        for _, t in ipairs(list) do
            cells[#cells + 1] = { row = t.pos[1] - 1, col = t.pos[2] }
        end
        table.sort(cells, function(a, b)
            if a.row ~= b.row then
                return a.row < b.row
            end
            return a.col < b.col
        end)
        return cells
    end

    local function flash()
        local cells = field_cells()
        if #cells == 0 then
            return
        end
        if not flash_hl then
            flash_hl = true
            vim.api.nvim_set_hl(0, "OrchlaunchFlash", { bold = true, reverse = true })
        end
        local target = {}
        for i, cell in ipairs(cells) do
            local ch = FLASH_LETTERS:sub(i, i)
            if ch == "" then
                break
            end
            target[ch] = cell
            vim.api.nvim_buf_set_extmark(handle.bufnr, flash_ns, cell.row, cell.col, {
                virt_text = { { ch, "OrchlaunchFlash" } },
                virt_text_pos = "overlay",
                priority = 1000,
            })
        end
        vim.cmd("redraw")
        local ok, ch = pcall(vim.fn.getcharstr)
        vim.api.nvim_buf_clear_namespace(handle.bufnr, flash_ns, 0, -1)
        vim.cmd("redraw")
        if not ok or ch == "" then
            return
        end
        local cell = target[ch]
        if not cell then
            return
        end
        vim.api.nvim_set_current_win(handle.winid)
        vim.api.nvim_win_set_cursor(handle.winid, { cell.row + 1, cell.col })
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i", true, false, true), "m", false)
    end

    local function wire_field_keys()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.w[win].fibrous_anchor == handle.winid then
                local buf = vim.api.nvim_win_get_buf(win)
                if not vim.b[buf].orchlaunch_field_keys then
                    vim.b[buf].orchlaunch_field_keys = true
                    dlog(("map buf=%d lines=%d"):format(buf, vim.api.nvim_buf_line_count(buf)))
                    for _, mode in ipairs({ "n", "i" }) do
                        vim.keymap.set(mode, "<Tab>", function()
                            field_cycle(1, true)
                        end, { buffer = buf, nowait = true, silent = true })
                        vim.keymap.set(mode, "<S-Tab>", function()
                            field_cycle(-1, true)
                        end, { buffer = buf, nowait = true, silent = true })
                        vim.keymap.set(mode, "<C-j>", function()
                            field_cycle(1, true)
                        end, { buffer = buf, nowait = true, silent = true })
                        vim.keymap.set(mode, "<C-k>", function()
                            field_cycle(-1, true)
                        end, { buffer = buf, nowait = true, silent = true })
                    end
                    vim.keymap.set("i", "<Esc>", function()
                        if vim.api.nvim_buf_line_count(buf) > 1 then
                            vim.api.nvim_feedkeys(
                                vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
                                "n",
                                false
                            )
                        else
                            field_leave()
                        end
                    end, { buffer = buf, nowait = true, silent = true })
                    vim.keymap.set("n", "s", function()
                        field_leave()
                        flash()
                    end, { buffer = buf, nowait = true, silent = true })
                end
                local is_dropdown = false
                for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
                    if m.lhs == "<C-n>" or m.lhs == "<C-N>" then
                        is_dropdown = true
                        break
                    end
                end
                if is_dropdown and not vim.b[buf].orchlaunch_arrow_alias then
                    vim.b[buf].orchlaunch_arrow_alias = true
                    for _, mode in ipairs({ "n", "i" }) do
                        vim.keymap.set(mode, "<Down>", function()
                            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-n>", true, false, true), "m", false)
                        end, { buffer = buf, nowait = true, silent = true })
                        vim.keymap.set(mode, "<Up>", function()
                            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-p>", true, false, true), "m", false)
                        end, { buffer = buf, nowait = true, silent = true })
                    end
                end
            end
        end
    end

    wire_field_keys()
    vim.schedule(wire_field_keys)
    vim.api.nvim_create_autocmd({ "BufWinEnter", "WinNew", "BufEnter", "WinEnter" }, {
        group = vim.api.nvim_create_augroup("OrchlaunchFibrousFields", { clear = true }),
        callback = wire_field_keys,
    })
    vim.keymap.set("n", "s", flash, { buffer = handle.bufnr, nowait = true, silent = true })

    return { cells = field_cells }
end

return M
