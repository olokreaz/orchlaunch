-- OrchLaunch — output policy for before-launch process steps.
--
-- Every process step (`exec`, `external`) produces stdout and stderr. The
-- `log` setting decides where that output goes. It can be set once on the
-- `before` block and overridden on any single step:
--
--   "before": { "log": "showIfError", "tools": [ ... ] }
--   { "type": "exec", "argv": [...], "log": "show" }
--
-- Policies (string form):
--   "none"         never show; on failure, notify the last stderr line only.
--   "showIfError"  (default) on success stay quiet; on failure open the output
--                  window with everything the step printed.
--   "show"         always open the output window.
--   { "file": p }  always write stdout and stderr to `p` (macros expanded,
--                  directory created), nothing in the window.
--
-- The output window is one scratch buffer per run (see `runner/window.lua`).
-- Capturing (`capture`) is independent: it always stores stdout on success.

local M = {}

M.POLICIES = { none = true, showIfError = true, show = true }

--- Validates a `log` value. Returns the normalized value, or nil and a message.
---@param log any
---@return string|{ file: string }|nil value
---@return string? err
function M.normalize_log(log)
    if log == nil then
        return "showIfError"
    end
    if type(log) == "string" then
        if M.POLICIES[log] then
            return log
        end
        return nil, ("unknown log policy %q (expected none, showIfError, show or { file = ... })"):format(log)
    end
    if type(log) == "table" and type(log.file) == "string" and log.file ~= "" then
        return { file = log.file }
    end
    return nil, "log must be a policy name or { file = \"...\" }"
end

--- Merges a `log` set on the `before` block with the one on a single step.
--- The step's value wins when it is set.
---@param before_log any
---@param step_log any
---@return any
function M.effective_log(before_log, step_log)
    if step_log ~= nil then
        return step_log
    end
    return before_log
end

--- Strips trailing newlines so a captured value can be used as an argument.
---@param text? string
---@return string
function M.capture_value(text)
    return ((text or ""):gsub("[\r\n]+$", ""))
end

--- Last line of stderr (or stdout when stderr is empty), for the `none` policy.
---@param result { stdout?: string, stderr?: string }
---@return string
function M.last_line(result)
    local text = result.stderr ~= nil and result.stderr ~= "" and result.stderr or (result.stdout or "")
    text = text:gsub("%s+$", "")
    local lines = vim.split(text, "\n", { plain = true })
    return lines[#lines] or ""
end

--- Lines to show for a finished step, each tagged with the stream it came from.
---@param label string step name, e.g. "exec uname"
---@param result { stdout?: string, stderr?: string }
---@return string[]
function M.tagged_lines(label, result)
    local out = { ("== %s =="):format(label) }
    local function add(tag, text)
        if text == nil or text == "" then
            return
        end
        for _, line in ipairs(vim.split((text:gsub("%s+$", "")), "\n", { plain = true })) do
            out[#out + 1] = ("[%s] %s"):format(tag, line)
        end
    end
    add("out", result.stdout)
    add("err", result.stderr)
    return out
end

--- Decides what to do with a finished step's output.
---   action = "none"    nothing to do
---   action = "notify"  a single line to notify (value in `text`, level in `level`)
---   action = "window"  append `lines` to the output window; `open` says whether to show it
---   action = "file"    write `lines` to `path`
---@param log string|{ file: string }
---@param ok boolean
---@return { action: string, lines?: string[], open?: boolean, path?: string, text?: string, level?: string }
function M.decide(log, ok, label, result)
    if type(log) == "table" then
        return { action = "file", lines = M.tagged_lines(label, result), path = log.file }
    end
    if log == "none" then
        if ok then
            return { action = "none" }
        end
        return { action = "notify", level = "error", text = ("%s failed: %s"):format(label, M.last_line(result)) }
    end
    if log == "show" then
        return { action = "window", lines = M.tagged_lines(label, result), open = true }
    end
    -- showIfError
    if ok then
        return { action = "window", lines = M.tagged_lines(label, result), open = false }
    end
    return { action = "window", lines = M.tagged_lines(label, result), open = true }
end

return M
