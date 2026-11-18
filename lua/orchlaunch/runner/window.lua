-- OrchLaunch — the output window for before-launch steps.
--
-- One scratch buffer per run: every step of a before-chain appends to it, so
-- the output of a whole run reads top to bottom. The buffer is created on the
-- first write and reused for the rest of the run. It is shown in a bottom split
-- only when a step asks for it (`open = true`), and is not wiped when closed, so
-- the output stays reachable.

local M = {}

local BUF_NAME_PREFIX = "[orchlaunch] before: "

--- Creates a run-scoped output buffer.
---@param label string the run name (configuration name)
---@return { append: fun(lines: string[], open: boolean), buf: integer? }
function M.new(label)
    local self = { buf = nil }

    local function ensure_buffer()
        if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
            return self.buf
        end
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].bufhidden = "hide"
        vim.bo[buf].swapfile = false
        vim.bo[buf].filetype = "orchlaunch-output"
        pcall(vim.api.nvim_buf_set_name, buf, BUF_NAME_PREFIX .. label .. " #" .. buf)
        self.buf = buf
        return buf
    end

    local function show(buf)
        local existing = vim.fn.win_findbuf(buf)[1]
        if existing then
            return existing
        end
        local current = vim.api.nvim_get_current_win()
        vim.cmd("botright 12split")
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, buf)
        vim.api.nvim_set_current_win(current)
        return win
    end

    --- Appends lines to the run's buffer; opens the window when `open` is set.
    ---@param lines string[]
    ---@param open boolean
    function self.append(lines, open)
        if not lines or #lines == 0 then
            return
        end
        local buf = ensure_buffer()
        local count = vim.api.nvim_buf_line_count(buf)
        local empty = count == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, empty and 0 or count, -1, false, lines)
        vim.bo[buf].modifiable = false
        if open then
            show(buf)
        end
    end

    return self
end

return M
