-- OrchLaunch — fibrous breakpoints manager.
--
-- Lists the live breakpoints with their conditions/log messages and lets the
-- user jump to one, edit its condition, or delete it. It reads the neutral
-- `orchlaunch.breakpoints` module, so it is independent from any debug adapter
-- and works whether or not a session is running.

local util = require("orchlaunch.ui.fibrous.util")

local M = {}

local handle = nil

--- @return boolean
function M.available()
    return util.available()
end

--- @param bp table
--- @return string
local function label(bp)
    return require("orchlaunch.breakpoints").label(bp)
end

--- Opens the breakpoint location in a non-panel window.
--- @param bp table
function M.jump(bp)
    local path = bp.path
    if not path or vim.fn.filereadable(path) ~= 1 then
        return
    end

    local target
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_config(win).relative == "" then
            target = win
            break
        end
    end

    if not target or (handle and target == handle.winid) then
        vim.cmd("split " .. vim.fn.fnameescape(path))
        target = vim.api.nvim_get_current_win()
    else
        vim.api.nvim_set_current_win(target)
        vim.cmd("edit " .. vim.fn.fnameescape(path))
    end

    pcall(vim.api.nvim_win_set_cursor, target, { bp.line, 0 })
end

--- Prompts for a new condition (empty clears it) and applies it.
--- @param bp table
--- @param on_done fun()
function M.edit_condition(bp, on_done)
    local breakpoints = require("orchlaunch.breakpoints")
    local prompt = ("Condition for %s:%d"):format(vim.fs.basename(bp.path or bp.file), bp.line)

    local function apply(text)
        if text == nil then
            return
        end
        if text == "" then
            breakpoints.set({ log_message = bp.log_message, hit_condition = bp.hit_condition }, bp.bufnr, bp.line)
        else
            breakpoints.set({ condition = text, log_message = bp.log_message, hit_condition = bp.hit_condition }, bp.bufnr, bp.line)
        end
        if on_done then
            on_done()
        end
    end

    local ok = pcall(vim.ui.input, { prompt = prompt .. ": ", default = bp.condition or "" }, apply)
    if not ok then
        apply(vim.fn.input(prompt .. ": ", bp.condition or ""))
    end
end

--- @param nr table
--- @param ctx table
--- @param props table
--- @return table
local function Breakpoints(ctx, props)
    local nr = props.nr
    local breakpoints = props.breakpoints

    local revision = ctx.use_state(0)
    revision.get() -- re-render on change

    local function bump()
        vim.schedule(function()
            nr.batch(function()
                revision.set(revision.get() + 1)
            end)
        end)
    end

    local items = breakpoints.list()

    local rows = {}
    for _, bp in ipairs(items) do
        local row = {}
        row[#row + 1] = {
            comp = nr.ui.button,
            props = {
                label = label(bp),
                theme = false,
                align_self = "stretch",
                on_press = function()
                    M.jump(bp)
                end,
            },
        }
        row[#row + 1] = {
            comp = nr.ui.button,
            props = {
                label = "[cond]",
                on_press = function()
                    M.edit_condition(bp, bump)
                end,
            },
        }
        row[#row + 1] = {
            comp = nr.ui.button,
            props = {
                label = "[x]",
                on_press = function()
                    breakpoints.remove(bp.bufnr, bp.line)
                    bump()
                end,
            },
        }
        rows[#rows + 1] = { comp = nr.ui.row, props = { gap = 1 }, children = row }
    end

    local body = {
        { comp = nr.ui.label, props = { text = ("Breakpoints — %d"):format(#items), style = { text_hl = "Title" } } },
    }
    if #items == 0 then
        body[#body + 1] = { comp = nr.ui.label, props = { text = "No breakpoints. Use :OrchLaunchToggleBreakpoint.", style = { text_hl = "Comment" } } }
    else
        vim.list_extend(body, rows)
    end
    body[#body + 1] = { comp = nr.ui.row, props = { gap = 1 }, children = {
        { comp = nr.ui.button, props = { label = "Clear all", on_press = function()
            breakpoints.clear()
            bump()
        end } },
        { comp = nr.ui.button, props = { label = "Close", on_press = function()
            if props.on_close then
                props.on_close()
            end
        end } },
    } }
    body[#body + 1] = { comp = nr.ui.label, props = { text = "Enter jumps · [cond] edits condition · [x] removes", style = { text_hl = "Comment" } } }

    return {
        comp = nr.ui.col,
        props = { style = { border = "rounded", padding = { x = 1, y = 0 } }, gap = 0, grow = 1 },
        children = body,
    }
end

--- Opens (or focuses) the breakpoints manager.
--- @return table? handle
function M.open()
    if not M.available() then
        return nil
    end

    if handle and handle.winid and vim.api.nvim_win_is_valid(handle.winid) then
        handle.focus()
        return handle
    end

    local nr = require("fibrous")
    handle = nr.mount(Breakpoints, {
        nr = nr,
        breakpoints = require("orchlaunch.breakpoints"),
        on_close = function()
            M.close()
        end,
    }, {
        width = math.min(110, math.max(70, vim.o.columns - 4)),
        height = math.min(30, math.max(10, vim.o.lines - 4)),
        on_unmount = function()
            handle = nil
        end,
    })
    handle.focus()
    return handle
end

function M.close()
    if handle then
        local current = handle
        handle = nil
        pcall(current.unmount)
    end
end

return M
