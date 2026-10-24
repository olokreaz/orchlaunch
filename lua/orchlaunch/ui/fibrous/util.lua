-- OrchLaunch — shared fibrous helpers.
--
-- Small bits every fibrous screen needs: a dependency probe, the opt-in trace
-- used by the functional suite (tests/func) and the mount-sizing helpers that
-- keep a window usable on tiny and huge terminals alike.

local M = {}

local augroup_seq = 0

--- Returns a fresh augroup name for one dialog instance.
---@param prefix string
---@return string
function M.unique_augroup(prefix)
    augroup_seq = augroup_seq + 1
    return ("%s_%d"):format(prefix, augroup_seq)
end

--- @return boolean Whether fibrous.nvim can be required.
function M.available()
    return (pcall(require, "fibrous")) == true
end

-- Opt-in trace: when ORCH_FUNC_LOG is set, screens append to it. No-op
-- otherwise, so nothing is paid in normal use.
local trace = vim.env.ORCH_FUNC_LOG

--- @param prefix string Namespace written before each line (e.g. "module").
--- @param line string
function M.dlog(prefix, line)
    if not trace then
        return
    end
    local f = io.open(trace, "a")
    if f then
        f:write(prefix .. " " .. line .. "\n")
        f:close()
    end
end

--- Clamps `value` into `[min, max]`.
--- @param min integer
--- @param value integer
--- @param max integer
--- @return integer
function M.clamp(min, value, max)
    return math.max(min, math.min(value, max))
end

--- Fills a mount-options table with a fractional size of the editor, clamped
--- so the window stays usable on tiny and huge screens.
--- @param opts table mount options (mutated)
--- @param frac_cols number e.g. 0.75
--- @param frac_lines number e.g. 0.8
--- @param min_w? integer
--- @param max_w? integer
--- @param min_h? integer
--- @param max_h? integer
function M.apply_size(opts, frac_cols, frac_lines, min_w, max_w, min_h, max_h)
    min_w = min_w or 80
    max_w = max_w or math.huge
    min_h = min_h or 20
    max_h = max_h or math.huge
    opts.width = M.clamp(min_w, math.floor(vim.o.columns * frac_cols), math.min(max_w, vim.o.columns - 4))
    opts.height = M.clamp(min_h, math.floor(vim.o.lines * frac_lines), math.min(max_h, vim.o.lines - 4))
end

--- Installs a VimResized handler that re-sizes and relayouts a mount.
--- @param augroup string
--- @param opts table mount options
--- @param apply_size fun()
--- @param get_handle fun(): table?
function M.watch_resize(augroup, opts, apply_size, get_handle)
    vim.api.nvim_create_autocmd("VimResized", {
        group = vim.api.nvim_create_augroup(augroup, { clear = true }),
        callback = function()
            apply_size()
            local handle = get_handle()
            if handle then
                handle.relayout()
            end
        end,
    })
end

return M
