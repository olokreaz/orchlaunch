-- OrchLaunch — external process execution built on `vim.system`.
--
-- Programs and arguments are always passed as separate list entries; nothing
-- is ever concatenated into a shell string.

local M = {}

--- @param program string
--- @return boolean
function M.executable(program)
    if type(program) ~= "string" or program == "" then
        return false
    end
    return vim.fn.executable(program) == 1
end

--- Builds the argv list for a spec, applying `sudo` when requested.
---@param spec OrchProcessSpec
---@return string[]
local function build_command(spec)
    assert(type(spec.program) == "string" and spec.program ~= "", "[orchlaunch] process requires `program`")

    local cmd = { spec.program }
    for _, arg in ipairs(spec.args or {}) do
        cmd[#cmd + 1] = tostring(arg)
    end

    if spec.sudo then
        if not M.executable("sudo") then
            error("[orchlaunch] sudo requested but is not available")
        end
        table.insert(cmd, 1, "sudo")
        table.insert(cmd, 2, "--")
    end

    return cmd
end

--- Builds the argv list for a spec, applying `sudo` when requested.
---@param spec OrchProcessSpec
---@return string[]
function M.command(spec)
    return build_command(spec)
end

--- Builds `vim.system` options from a spec.
---@param spec OrchProcessSpec
---@return vim.SystemOpts
local function build_options(spec)
    local opts = { text = true }

    if spec.cwd and spec.cwd ~= "" then
        opts.cwd = spec.cwd
    end

    if spec.env and next(spec.env) ~= nil then
        opts.env = spec.env
    end

    if spec.inherit_env == false then
        opts.clear_env = true
    end

    if type(spec.timeout) == "number" and spec.timeout > 0 then
        opts.timeout = spec.timeout
    end

    return opts
end

--- Starts a process asynchronously.
---@param spec OrchProcessSpec
---@param on_exit? fun(result: vim.SystemCompleted)
---@return vim.SystemObj
function M.start(spec, on_exit)
    return vim.system(build_command(spec), build_options(spec), on_exit)
end

--- Runs a process synchronously and returns its result.
---@param spec OrchProcessSpec
---@return OrchProcessResult
function M.run(spec)
    local object = M.start(spec)
    local completed = object:wait()

    return {
        code = completed.code,
        signal = completed.signal,
        stdout = completed.stdout,
        stderr = completed.stderr,
    }
end

return M
