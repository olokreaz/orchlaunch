-- OrchLaunch — output handling for before-launch process steps.
--
-- A process step has two independent concerns:
--   * `capture`: keep stdout (trailing newline removed) as a `${var:name}`.
--   * `log`:     decide what the user sees. Pure decision logic lives here so
--                the synchronous and asynchronous runners share one behaviour.
--
-- `log` values:
--   "none"        (default) show nothing on success; on failure show the tail
--                 of stderr, like `consoleShowIfError` with a short excerpt.
--   "errorsOnly"  show nothing on success; on failure show all output.
--   "console"     always show all output.
--   { file = p }  always write all output to `p` (macros are expanded, the
--                 directory is created). Nothing is shown in the console.

local M = {}

local TAIL_LINES = 20

M.MODES = { none = true, errorsOnly = true, console = true }

--- Validates a `log` value. Returns the normalized value or nil, message.
---@param log any
---@return string|{ file: string }|nil value
---@return string? err
function M.normalize_log(log)
    if log == nil then
        return "none"
    end
    if type(log) == "string" then
        if M.MODES[log] then
            return log
        end
        return nil, ("unknown log mode %q (expected none, errorsOnly, console or { file = ... })"):format(log)
    end
    if type(log) == "table" and type(log.file) == "string" and log.file ~= "" then
        return { file = log.file }
    end
    return nil, "log must be a mode name or { file = \"...\" }"
end

--- Strips trailing newlines so a captured value can be used as an argument.
---@param text? string
---@return string
function M.capture_value(text)
    return ((text or ""):gsub("[\r\n]+$", ""))
end

--- Last `n` lines of a text, for compact error messages.
---@param text? string
---@param n? integer
---@return string
function M.tail(text, n)
    n = n or TAIL_LINES
    local lines = vim.split((text or ""):gsub("%s+$", ""), "\n", { plain = true })
    local start = math.max(1, #lines - n + 1)
    local out = {}
    for i = start, #lines do
        out[#out + 1] = lines[i]
    end
    return table.concat(out, "\n")
end

--- Decides what to show for a finished step.
---@param log string|{ file: string }
---@param result { code: integer, stdout?: string, stderr?: string }
---@param ok boolean whether the step succeeded
---@return { level: "none"|"info"|"error", text?: string, file_text?: string }
function M.plan(log, result, ok)
    local stdout = result.stdout or ""
    local stderr = result.stderr or ""
    local everything = stdout
    if stderr ~= "" then
        everything = everything .. (everything ~= "" and "\n" or "") .. stderr
    end

    if type(log) == "table" then
        return { level = ok and "info" or "error", file_text = everything }
    end
    if log == "console" then
        return { level = ok and "info" or "error", text = everything }
    end
    if not ok then
        if log == "errorsOnly" then
            return { level = "error", text = everything }
        end
        return { level = "error", text = M.tail(stderr ~= "" and stderr or stdout) }
    end
    return { level = "none" }
end

return M
