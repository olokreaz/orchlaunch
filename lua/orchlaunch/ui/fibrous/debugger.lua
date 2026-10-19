-- OrchLaunch — fibrous debugger panel.
--
-- A read-only view over the neutral debug session: threads, frames, scopes and
-- variables, plus the stepping controls. It re-renders on every session change
-- through `session.subscribe`, so it stays backend-agnostic — it never talks to
-- a debug adapter directly and works with any registered backend.

local util = require("orchlaunch.ui.fibrous.util")

local M = {}

local handle = nil

--- @return boolean
function M.available()
    return util.available()
end

--- @param path? string
--- @return string?
local function basename(path)
    if not path or path == "" then
        return nil
    end
    return vim.fs.basename(path)
end

--- @param frame table
--- @param selected boolean
--- @return string
local function frame_label(frame, selected)
    local name = frame.name or "?"
    local src = frame.source
    local where = ""
    if src then
        local file = basename(src.path) or src.name
        if file then
            where = ("  %s:%d"):format(file, frame.line or 0)
        end
    elseif frame.line then
        where = ("  :%d"):format(frame.line)
    end
    return ("%s%s%s"):format(selected and "▸ " or "  ", name, where)
end

--- @param nr table
--- @param label string
--- @param selected boolean
--- @param on_press fun()
--- @return table
local function selectable(nr, label, selected, on_press)
    return {
        comp = nr.ui.button,
        props = {
            label = label,
            theme = false,
            align_self = "stretch",
            style = selected and { hl = "Visual" } or nil,
            on_press = on_press,
        },
    }
end

--- @param nr table
--- @param title string
--- @param rows table[]
--- @param width? integer
--- @param grow? integer
--- @return table
local function section(nr, title, rows, width, grow)
    local children = { { comp = nr.ui.label, props = { text = title, style = { text_hl = "Title" } } } }
    vim.list_extend(children, rows)
    return { comp = nr.ui.col, props = { width = width, grow = grow, gap = 0 }, children = children }
end

local function Debugger(ctx, props)
    local nr = props.nr
    local session = props.session
    local debug = props.debug

    local revision = ctx.use_state(0)
    local sel_thread = ctx.use_state(nil)
    local sel_frame = ctx.use_state(nil)
    local sel_scope = ctx.use_state(nil)

    ctx.use_effect(function()
        local function bump()
            vim.schedule(function()
                nr.batch(function()
                    revision.set(revision.get() + 1)
                end)
            end)
        end
        local unsubscribe = session.subscribe(bump)
        bump()
        return unsubscribe
    end, {})

    -- Read the revision so a change re-renders; the value itself is unused.
    revision.get()
    local status = session.status()

    if status == "idle" then
        return {
            comp = nr.ui.col,
            props = { style = { border = "rounded", padding = { x = 1, y = 1 } }, gap = 1 },
            children = {
                { comp = nr.ui.label, props = { text = "Debug — no active session", style = { text_hl = "Title" } } },
                selectable(nr, "Close", false, function()
                    if props.on_close then
                        props.on_close()
                    end
                end),
            },
        }
    end

    local threads = session.threads()
    local tid = sel_thread.get() or session.current_thread()
    local frames = session.frames(tid)
    local fid = sel_frame.get()
    if not fid then
        local current = session.current_frame()
        fid = current and current.id or (frames[1] and frames[1].id)
    end
    local scopes = session.scopes(fid)
    local sref = sel_scope.get()
    if not sref and scopes[1] then
        sref = scopes[1].variablesReference
    end
    local variables = sref and session.variables(sref) or {}

    local thread_rows = {}
    for _, thread in ipairs(threads) do
        local selected = thread.id == tid
        thread_rows[#thread_rows + 1] = selectable(nr, ("%s%s"):format(selected and "▸ " or "  ", thread.name or ("#" .. thread.id)), selected, function()
            nr.batch(function()
                sel_thread.set(thread.id)
                sel_frame.set(nil)
                sel_scope.set(nil)
            end)
        end)
    end

    local frame_rows = {}
    for _, frame in ipairs(frames) do
        local selected = frame.id == fid
        frame_rows[#frame_rows + 1] = selectable(nr, frame_label(frame, selected), selected, function()
            nr.batch(function()
                sel_frame.set(frame.id)
                sel_scope.set(nil)
            end)
        end)
    end

    local scope_rows = {}
    for _, scope in ipairs(scopes) do
        local selected = scope.variablesReference == sref
        scope_rows[#scope_rows + 1] = selectable(nr, ("%s%s"):format(selected and "▸ " or "  ", scope.name or "?"), selected, function()
            nr.batch(function()
                sel_scope.set(scope.variablesReference)
            end)
        end)
    end

    local variable_rows = {}
    for _, variable in ipairs(variables) do
        variable_rows[#variable_rows + 1] = {
            comp = nr.ui.label,
            props = { text = ("%s = %s"):format(variable.name or "?", variable.value or "?"), wrap = false },
        }
    end

    local controls = {}
    local function control(label, action)
        controls[#controls + 1] = { comp = nr.ui.button, props = { label = label, on_press = action } }
    end
    control("Continue", function()
        debug.continue()
    end)
    control("Pause", function()
        debug.pause()
    end)
    control("Toggle BP", function()
        local frame = session.current_frame()
        local src = frame and frame.source
        if src and src.path and src.path ~= "" and frame.line then
            local bufnr = vim.fn.bufadd(src.path)
            vim.fn.bufload(bufnr)
            require("orchlaunch.breakpoints").toggle({}, bufnr, frame.line)
        end
    end)
    control("Step Over", function()
        debug.step_over()
    end)
    control("Step In", function()
        debug.step_in()
    end)
    control("Step Out", function()
        debug.step_out()
    end)
    control("Restart", function()
        debug.restart()
    end)
    control("Stop", function()
        debug.stop()
    end)
    control("Close", function()
        if props.on_close then
            props.on_close()
        end
    end)

    return {
        comp = nr.ui.col,
        props = { style = { border = "rounded", padding = { x = 1, y = 0 } }, gap = 0, grow = 1 },
        children = {
            { comp = nr.ui.label, props = { text = ("Debug — %s"):format(status), style = { text_hl = "Title" } } },
            { comp = nr.ui.row, props = { gap = 1 }, children = controls },
            {
                comp = nr.ui.row,
                props = { gap = 2, grow = 1 },
                children = {
                    section(nr, "Threads", thread_rows, 22),
                    section(nr, "Frames", frame_rows, 34),
                    section(nr, "Scopes", scope_rows, 18),
                    section(nr, "Variables", variable_rows, nil, 1),
                },
            },
            {
                comp = nr.ui.label,
                props = { text = "Continue · Pause · Step Over/In/Out · Restart · Stop", style = { text_hl = "Comment" } },
            },
        },
    }
end

--- Opens (or focuses) the debugger panel.
---@return table? handle
function M.open()
    if not M.available() then
        return nil
    end

    if handle and handle.winid and vim.api.nvim_win_is_valid(handle.winid) then
        handle.focus()
        return handle
    end

    local nr = require("fibrous")
    handle = nr.mount(Debugger, {
        nr = nr,
        session = require("orchlaunch.debug.session"),
        debug = require("orchlaunch.debug"),
        on_close = function()
            M.close()
        end,
    }, {
        width = math.min(120, math.max(80, vim.o.columns - 4)),
        height = math.min(30, math.max(12, vim.o.lines - 4)),
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
