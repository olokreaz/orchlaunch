-- OrchLaunch — scratch-buffer editor.
--
-- Opens an editable Lua buffer in a centered floating window. `:w` / <C-s>
-- parses and applies the content through `on_save`; `q` / <Esc> closes without
-- saving. Used by the CMake profile editor, where a plain buffer is far more
-- comfortable than a form.

local UI = require("orchlaunch.ui")

local M = {}

--- @class OrchScratchOptions
--- @field title string
--- @field lines string[]
--- @field on_save fun(text: string)
--- @field on_close? fun() Called once when the window closes.
--- @field width? integer
--- @field height? integer

--- @param opts OrchScratchOptions
--- @return { buf: integer, win: integer, close: fun() }
function M.open_lua(opts)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
    vim.api.nvim_buf_set_name(buf, ("orchlaunch://%s"):format(vim.uv.hrtime()))

    vim.bo[buf].filetype = "lua"
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modified = false

    local width = opts.width or 92
    local height = opts.height or 30
    local ui = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }
    local row = math.max(0, math.floor((ui.height - height) / 2) - 1)
    local col = math.max(0, math.floor((ui.width - width) / 2))

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = math.min(width, ui.width - 2),
        height = math.min(height, ui.height - 2),
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " " .. opts.title .. " ",
        title_pos = "center",
    })

    local closed = false
    local function close()
        if closed then
            return
        end
        closed = true
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
        if opts.on_close then
            pcall(opts.on_close)
        end
    end

    local function save()
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        local ok, err = pcall(opts.on_save, text)
        if not ok then
            UI.notify(tostring(err), vim.log.levels.ERROR)
            return
        end
        vim.bo[buf].modified = false
        close()
    end

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = save,
    })

    vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set({ "n", "i" }, "<C-s>", save, { buffer = buf, silent = true })

    return { buf = buf, win = win, close = close }
end

return M
