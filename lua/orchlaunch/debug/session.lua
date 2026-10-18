-- OrchLaunch debug session: maintain consistent state over dap events
local M = {}
local dap = nil

local function get_dap()
    if dap ~= nil then
        return dap
    end
    local ok, d = pcall(require, "dap")
    if not ok then
        return nil
    end
    dap = d
    return dap
end

local state = {
    active = false,
    threads = {},              -- by id
    frames_by_thread = {},     -- tid -> frames
    scopes_by_frame = {},      -- fid -> scopes
    vars_by_ref = {},          -- ref -> vars
    current_thread = nil,
    current_frame = nil,
    status = "idle",           -- idle|running|stopped|exited
}

-- Refs whose `variables` request is still in flight (ref -> waiting callbacks).
-- Without this an eager UI re-rendering while a stop is being inspected would
-- fire one request per render, flooding the adapter and stalling the session.
local pending_vars = {}

function M.reset()
    state.active = false
    state.threads = {}
    state.frames_by_thread = {}
    state.scopes_by_frame = {}
    state.vars_by_ref = {}
    state.current_thread = nil
    state.current_frame = nil
    state.status = "idle"
    pending_vars = {}
    M.emit()
end

-- ============================================================================
-- Change notifications
-- ============================================================================

local subscribers = {}

--- Notifies every subscriber that the session state changed. UI layers
--- subscribe here to re-render on adapter events.
function M.emit()
    for fn in pairs(subscribers) do
        pcall(fn)
    end
end

--- Registers `fn` to run on every session change.
--- @param fn fun()
--- @return fun() unsubscribe
function M.subscribe(fn)
    subscribers[fn] = true
    return function()
        subscribers[fn] = nil
    end
end

function M.is_active()
    return state.active
end

function M.status()
    return state.status
end

function M.threads()
    local list = {}
    for _, t in pairs(state.threads) do
        table.insert(list, t)
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

function M.current_thread()
    return state.current_thread
end

function M.frames(thread_id)
    local tid = thread_id or state.current_thread
    return state.frames_by_thread[tid] or {}
end

function M.current_frame()
    return state.current_frame
end

function M.scopes(frame_id)
    local fid = frame_id or (state.current_frame and state.current_frame.id)
    return state.scopes_by_frame[fid] or {}
end

--- @param v table
--- @return table
local function normalize_variable(v)
    return {
        name = v.name,
        value = v.value,
        type = v.type,
        variablesReference = v.variablesReference,
        indexedVariables = v.indexedVariables,
        namedVariables = v.namedVariables,
    }
end

--- @return table? session The active nvim-dap session, if any.
local function current_session()
    local d = get_dap()
    if not d or type(d.session) ~= "function" then
        return nil
    end
    return d.session()
end

--- Capabilities advertised by the adapter in its `initialize` response.
--- Empty until a session has negotiated them.
---@return table<string, any>
function M.capabilities()
    local session = current_session()
    return (session and session.capabilities) or {}
end

--- Whether the active adapter supports a DAP capability.
---@param capability string
---@return boolean
function M.supports(capability)
    return M.capabilities()[capability] == true
end

--- Returns the children of a variables reference.
---
--- Served from the cache when the reference was fetched before; otherwise the
--- request is sent to the debug adapter and cached once the answer arrives. When
--- `cb` is given it receives the (possibly empty) list of variables.
---@param ref? integer
---@param cb? fun(vars: table[])
---@return table[]
function M.variables(ref, cb)
    if ref == nil then
        return {}
    end

    local cached = state.vars_by_ref[ref]
    if cached then
        if cb then
            cb(cached)
        end
        return cached
    end

    local inflight = pending_vars[ref]
    if inflight then
        if cb then
            inflight[#inflight + 1] = cb
        end
        return {}
    end

    local session = current_session()
    if not session then
        return {}
    end

    local callbacks = {}
    if cb then
        callbacks[#callbacks + 1] = cb
    end
    pending_vars[ref] = callbacks

    session:request("variables", { variablesReference = ref }, function(err, response)
        local waiting = pending_vars[ref] or {}
        pending_vars[ref] = nil
        if err then
            for _, fn in ipairs(waiting) do
                pcall(fn, {})
            end
            M.emit()
            return
        end
        local vars = {}
        for _, v in ipairs(response and response.variables or {}) do
            vars[#vars + 1] = normalize_variable(v)
        end
        state.vars_by_ref[ref] = vars
        for _, fn in ipairs(waiting) do
            pcall(fn, vars)
        end
        M.emit()
    end)

    return {}
end

--- Evaluates `expr` in the context of the current frame.
---
--- Delegates to the adapter's `evaluate` request and forwards the result string
--- to `cb`. Falls back to the repl when no session is active.
---@param expr string
---@param cb? fun(result: string?, response: table?)
function M.evaluate(expr, cb)
    local d = get_dap()
    if not d then
        error("nvim-dap not available")
    end

    local session = current_session()
    if not session then
        if d.repl and d.repl.execute then
            d.repl.execute(expr)
        end
        return
    end

    local args = { expression = expr, context = "repl" }
    if state.current_frame then
        args.frameId = state.current_frame.id
    end

    session:request("evaluate", args, function(err, response)
        if err or not response then
            return
        end
        if cb then
            cb(response.result, response)
        end
    end)
end

local listeners_attached = false

function M.attach_listeners()
    if listeners_attached then
        return
    end

    local d = get_dap()
    if not d then
        return
    end
    listeners_attached = true

    -- minimal event wiring; attached exactly once so repeated sessions do not
    -- pile up duplicate listeners
    d.listeners.after.event_stopped = d.listeners.after.event_stopped or {}
    table.insert(d.listeners.after.event_stopped, function(session, body)
        state.status = "stopped"
        state.active = true
        state.vars_by_ref = {}
        pending_vars = {}
        if body and body.threadId then
            state.current_thread = body.threadId
        end
        M.emit()
    end)
    d.listeners.after.event_continued = d.listeners.after.event_continued or {}
    table.insert(d.listeners.after.event_continued, function()
        state.status = "running"
        state.vars_by_ref = {}
        pending_vars = {}
        M.emit()
    end)
    d.listeners.after.event_exited = d.listeners.after.event_exited or {}
    table.insert(d.listeners.after.event_exited, function()
        state.status = "exited"
        M.emit()
    end)
    d.listeners.after.event_terminated = d.listeners.after.event_terminated or {}
    table.insert(d.listeners.after.event_terminated, function()
        state.status = "exited"
        state.active = false
        M.emit()
    end)

    -- Threads, frames and scopes are *responses* to the `threads`, `stackTrace`
    -- and `scopes` requests that nvim-dap issues while handling `stopped`; they
    -- are not DAP events, so they must be observed through the request listeners
    -- (`after.<command>`), whose signature is (session, err, response).
    d.listeners.after.threads = d.listeners.after.threads or {}
    table.insert(d.listeners.after.threads, function(_, _, response)
        if response and response.threads then
            state.threads = {}
            for _, t in ipairs(response.threads) do
                state.threads[t.id] = { id = t.id, name = t.name, state = t.state, selected = t.selected or false }
                if t.selected then
                    state.current_thread = t.id
                end
            end
        end
        M.emit()
    end)
    d.listeners.after.stackTrace = d.listeners.after.stackTrace or {}
    table.insert(d.listeners.after.stackTrace, function(_, _, response)
        if response and response.stackFrames then
            local tid = state.current_thread
            local frames = {}
            for _, f in ipairs(response.stackFrames) do
                table.insert(frames, {
                    id = f.id,
                    thread_id = tid,
                    line = f.line,
                    column = f.column,
                    name = f.name,
                    source = f.source,
                    address = f.address,
                })
            end
            if tid then
                state.frames_by_thread[tid] = frames
            end
            if #frames > 0 then
                state.current_frame = frames[1]
            end
        end
        M.emit()
    end)
    d.listeners.after.scopes = d.listeners.after.scopes or {}
    table.insert(d.listeners.after.scopes, function(_, _, response)
        if response and response.scopes and state.current_frame then
            local fid = state.current_frame.id
            local scopes = {}
            for _, s in ipairs(response.scopes) do
                table.insert(scopes, {
                    name = s.name,
                    expensive = s.expensive,
                    variablesReference = s.variablesReference,
                    frame_id = fid,
                })
            end
            state.scopes_by_frame[fid] = scopes
        end
        M.emit()
    end)
end

function M.start_session()
    M.reset()
    M.attach_listeners()
    state.active = true
    state.status = "running"
    M.emit()
end

return M
