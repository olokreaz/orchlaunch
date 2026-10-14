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

function M.reset()
    state.active = false
    state.threads = {}
    state.frames_by_thread = {}
    state.scopes_by_frame = {}
    state.vars_by_ref = {}
    state.current_thread = nil
    state.current_frame = nil
    state.status = "idle"
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

function M.variables(ref)
    if ref == nil then
        return {}
    end
    return state.vars_by_ref[ref] or {}
end

function M.evaluate(expr)
    local d = get_dap()
    if not d then
        error("nvim-dap not available")
    end
    -- request via dap.repl.execute or session
    if d.session and d.session.current_frame and expr then
        -- simplest: use repl
        d.repl.execute(expr)
    end
end

function M.attach_listeners()
    local d = get_dap()
    if not d then
        return
    end
    -- minimal event wiring; store references by id
    d.listeners.after.event_stopped = d.listeners.after.event_stopped or {}
    table.insert(d.listeners.after.event_stopped, function(session, body)
        state.status = "stopped"
        state.active = true
        if body and body.threadId then
            state.current_thread = body.threadId
        end
    end)
    d.listeners.after.event_exited = d.listeners.after.event_exited or {}
    table.insert(d.listeners.after.event_exited, function()
        state.status = "exited"
    end)
    d.listeners.after.event_terminated = d.listeners.after.event_terminated or {}
    table.insert(d.listeners.after.event_terminated, function()
        state.status = "exited"
        state.active = false
    end)
    d.listeners.after.event_threads = d.listeners.after.event_threads or {}
    table.insert(d.listeners.after.event_threads, function(session, body)
        if body and body.threads then
            for _, t in ipairs(body.threads) do
                state.threads[t.id] = { id = t.id, name = t.name, state = t.state, selected = t.selected or false }
                if t.selected then
                    state.current_thread = t.id
                end
            end
        end
    end)
    d.listeners.after.event_stackTrace = d.listeners.after.event_stackTrace or {}
    table.insert(d.listeners.after.event_stackTrace, function(session, body)
        if body and body.stackFrames then
            local tid = body.threadId or state.current_thread
            local frames = {}
            for _, f in ipairs(body.stackFrames) do
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
            state.frames_by_thread[tid] = frames
            if #frames > 0 then
                state.current_frame = frames[1]
            end
        end
    end)
    d.listeners.after.event_scopes = d.listeners.after.event_scopes or {}
    table.insert(d.listeners.after.event_scopes, function(session, body)
        if body and body.scopes and state.current_frame then
            local fid = state.current_frame.id
            local scopes = {}
            for _, s in ipairs(body.scopes) do
                table.insert(scopes, {
                    name = s.name,
                    expensive = s.expensive,
                    variablesReference = s.variablesReference,
                    frame_id = fid,
                })
            end
            state.scopes_by_frame[fid] = scopes
        end
    end)
    d.listeners.after.event_variables = d.listeners.after.event_variables or {}
    table.insert(d.listeners.after.event_variables, function(session, body)
        if body and body.variables and body.variablesReference then
            local vars = {}
            for _, v in ipairs(body.variables) do
                table.insert(vars, {
                    name = v.name,
                    value = v.value,
                    type = v.type,
                    variablesReference = v.variablesReference,
                    indexedVariables = v.indexedVariables,
                    namedVariables = v.namedVariables,
                })
            end
            state.vars_by_ref[body.variablesReference] = vars
        end
    end)
end

function M.start_session()
    M.reset()
    M.attach_listeners()
    state.active = true
    state.status = "running"
end

return M
