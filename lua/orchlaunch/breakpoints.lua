-- OrchLaunch — breakpoints.
--
-- A thin, project-aware layer over nvim-dap's breakpoints: it adds conditions,
-- log messages and hit counts, keeps breakpoints across sessions by persisting
-- them in `.orch/breakpoints.json`, and offers file/line helpers so the UI and
-- commands never touch nvim-dap directly.

local M = {}

local function get_dap()
    local ok, dap = pcall(require, "dap")
    if not ok then
        return nil
    end
    return dap
end

--- nvim-dap keeps breakpoints in a lazily-loaded submodule, not on the `dap`
--- table, so reach it through `require`.
local function get_bp()
    if not get_dap() then
        return nil
    end
    local ok, bp = pcall(require, "dap.breakpoints")
    return ok and bp or nil
end

--- @return OrchState?
local function get_state()
    local ok, state = pcall(require, "orchlaunch.state")
    if not ok or not state.is_loaded() then
        return nil
    end
    return state.get()
end

--- @param path string
--- @return boolean
local function is_absolute(path)
    if vim.fs and vim.fs.isabs then
        return vim.fs.isabs(path)
    end
    return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
end

--- Stores a path relative to the project root when it lives inside it, so the
--- saved breakpoints stay portable.
--- @param path string
--- @return string
function M.to_relative(path)
    local state = get_state()
    if not state or not path or path == "" then
        return path
    end
    local root = state.root
    if path:sub(1, #root + 1) == root .. "/" then
        return path:sub(#root + 2)
    end
    return path
end

--- @param file string
--- @return string
function M.to_absolute(file)
    if is_absolute(file) then
        return vim.fs.normalize(file)
    end
    local state = get_state()
    local base = state and state.root or vim.fn.getcwd()
    return vim.fs.normalize(vim.fs.joinpath(base, file))
end

--- @param path string
--- @return integer
local function buffer_for(path)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    return bufnr
end

-- ============================================================================
-- Mutation
-- ============================================================================

--- @param opts? { condition?: string, log_message?: string, hit_condition?: string }
--- @param bufnr integer
--- @param lnum integer
--- @return boolean ok false when nvim-dap is not available
function M.set(opts, bufnr, lnum)
    local bp = get_bp()
    if not bp then
        return false
    end
    bp.set(opts or {}, bufnr, lnum)
    M.persist()
    return true
end

--- @param opts? { condition?: string, log_message?: string, hit_condition?: string }
--- @param bufnr integer
--- @param lnum integer
--- @return boolean ok false when nvim-dap is not available
function M.toggle(opts, bufnr, lnum)
    local bp = get_bp()
    if not bp then
        return false
    end
    bp.toggle(opts or {}, bufnr, lnum)
    M.persist()
    return true
end

--- @param bufnr integer
--- @param lnum integer
--- @return boolean
function M.remove(bufnr, lnum)
    local bp = get_bp()
    if not bp then
        return false
    end
    local removed = bp.remove(bufnr, lnum)
    M.persist()
    return removed
end

--- @return boolean ok false when nvim-dap is not available
function M.clear()
    local bp = get_bp()
    if not bp then
        return false
    end
    bp.clear()
    M.persist()
    return true
end

--- Removes every breakpoint from nvim-dap without touching the persisted
--- project copy. Used when switching projects or before `load()` re-applies a
--- different project's breakpoints.
function M.clear_live()
    local bp = get_bp()
    if bp then
        bp.clear()
    end
end

-- ============================================================================
-- Queries
-- ============================================================================

--- All current breakpoints, normalized and sorted by file then line.
--- @return table[]
function M.list()
    local bp = get_bp()
    if not bp then
        return {}
    end

    local out = {}
    for bufnr, bps in pairs(bp.get() or {}) do
        local path = vim.api.nvim_buf_get_name(bufnr)
        for _, bp in ipairs(bps) do
            out[#out + 1] = {
                bufnr = bufnr,
                file = M.to_relative(path),
                path = path,
                line = bp.line,
                condition = bp.condition,
                log_message = bp.logMessage,
                hit_condition = bp.hitCondition,
            }
        end
    end

    table.sort(out, function(a, b)
        if a.file == b.file then
            return a.line < b.line
        end
        return a.file < b.file
    end)

    return out
end

--- @param bufnr integer
--- @param lnum integer
--- @return boolean
function M.has(bufnr, lnum)
    if not get_bp() then
        return false
    end
    for _, bp in ipairs(M.list()) do
        if bp.bufnr == bufnr and bp.line == lnum then
            return true
        end
    end
    return false
end

--- A short human label like `prog.cpp:12  (i == 3)`.
--- @param bp table
--- @return string
function M.label(bp)
    local name = vim.fs.basename(bp.path or bp.file or "?")
    local parts = {}
    if bp.condition and bp.condition ~= "" then
        parts[#parts + 1] = "if " .. bp.condition
    end
    if bp.hit_condition and bp.hit_condition ~= "" then
        parts[#parts + 1] = "hit " .. bp.hit_condition
    end
    if bp.log_message and bp.log_message ~= "" then
        parts[#parts + 1] = "log " .. bp.log_message
    end
    local suffix = #parts > 0 and ("  (" .. table.concat(parts, "; ") .. ")") or ""
    return ("%s:%d%s"):format(name, bp.line, suffix)
end

-- ============================================================================
-- File/line helpers
-- ============================================================================

--- Toggles a breakpoint at `file:line`.
--- @param file string
--- @param line integer
--- @param opts? table
function M.toggle_at(file, line, opts)
    local path = M.to_absolute(file)
    local bufnr = buffer_for(path)
    M.toggle(opts, bufnr, line)
end

--- Sets (or replaces) the breakpoint at `file:line` with `opts`.
--- @param file string
--- @param line integer
--- @param opts? table
function M.set_at(file, line, opts)
    local path = M.to_absolute(file)
    local bufnr = buffer_for(path)
    M.set(opts, bufnr, line)
end

--- Removes the breakpoint at `file:line`.
--- @param file string
--- @param line integer
--- @return boolean
function M.remove_at(file, line)
    local path = M.to_absolute(file)
    local bufnr = buffer_for(path)
    return M.remove(bufnr, line)
end

-- ============================================================================
-- Persistence
-- ============================================================================

--- @param bp table
--- @return table
local function to_record(bp)
    local record = { file = bp.file, line = bp.line }
    if bp.condition and bp.condition ~= "" then
        record.condition = bp.condition
    end
    if bp.log_message and bp.log_message ~= "" then
        record.log_message = bp.log_message
    end
    if bp.hit_condition and bp.hit_condition ~= "" then
        record.hit_condition = bp.hit_condition
    end
    return record
end

--- Snapshots the live breakpoints into the project and writes them to disk.
--- @return table[]
function M.persist()
    if not get_bp() then
        return {}
    end

    local records = {}
    for _, bp in ipairs(M.list()) do
        records[#records + 1] = to_record(bp)
    end

    local state = get_state()
    if state then
        state.breakpoints = records
        local ok, err = require("orchlaunch.state").save()
        if not ok then
            vim.notify(("[orchlaunch] %s"):format(err), vim.log.levels.ERROR)
        end
    end

    return records
end

--- Applies the project's persisted breakpoints to nvim-dap.
--- @return integer applied
function M.load()
    local bp = get_bp()
    local state = get_state()
    if not bp or not state then
        return 0
    end

    -- The same buffer number can survive a project switch, so remove the old
    -- project's live breakpoints before applying this project's records.
    M.clear_live()

    local applied = 0
    for _, record in ipairs(state.breakpoints or {}) do
        if type(record.file) == "string" and type(record.line) == "number" then
            local path = M.to_absolute(record.file)
            if vim.fn.filereadable(path) == 1 then
                local bufnr = buffer_for(path)
                bp.set({
                    condition = record.condition,
                    log_message = record.log_message,
                    hit_condition = record.hit_condition,
                }, bufnr, record.line)
                applied = applied + 1
            end
        end
    end

    return applied
end

return M
