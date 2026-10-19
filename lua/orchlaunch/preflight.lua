-- OrchLaunch — environment preflight ("doctor").
--
-- Checks the external tools the plugin relies on (CMake, compilers, debug
-- adapters) and the optional integrations (nvim-dap, fibrous). Reports what is
-- available so a misconfigured toolchain is obvious before a run/debug starts.

local M = {}

--- @class OrchPreflightCheck
--- @field name string
--- @field required boolean
--- @field ok boolean
--- @field detail string

--- @param name string
--- @param command? string
--- @param required? boolean
--- @return OrchPreflightCheck
local function command_check(name, command, required)
    if not command then
        return { name = name, required = required ~= false, ok = true, detail = "configured" }
    end
    local path = vim.fn.exepath(command)
    return {
        name = name,
        required = required ~= false,
        ok = path ~= "",
        detail = path ~= "" and path or ("'" .. command .. "' not found in PATH"),
    }
end

--- @param name string
--- @param module string
--- @return OrchPreflightCheck
local function module_check(name, module)
    local ok = pcall(require, module)
    return {
        name = name,
        required = false,
        ok = ok,
        detail = ok and "available" or (module .. " not installed"),
    }
end

--- All checks, in a stable order.
--- @return OrchPreflightCheck[]
function M.checks()
    return {
        command_check("cmake", "cmake"),
        command_check("ninja (optional)", "ninja", false),
        command_check("clang", "clang", false),
        command_check("clang++", "clang++", false),
        command_check("gcc", "gcc", false),
        command_check("g++", "g++", false),
        command_check("LLDB DAP adapter (lldb-dap)", "lldb-dap", false),
        command_check("LLDB (lldb-server)", "lldb-server", false),
        command_check("GDB", "gdb", false),
        module_check("nvim-dap", "dap"),
        module_check("fibrous.nvim", "fibrous"),
    }
end

--- @return OrchPreflightCheck[]
function M.missing()
    local out = {}
    for _, check in ipairs(M.checks()) do
        if not check.ok then
            out[#out + 1] = check
        end
    end
    return out
end

--- @return boolean
function M.ok()
    for _, check in ipairs(M.checks()) do
        if check.required and not check.ok then
            return false
        end
    end
    return true
end

--- Human-readable report lines.
--- @return string[]
function M.report()
    local lines = {}
    for _, check in ipairs(M.checks()) do
        lines[#lines + 1] = ("%s %-30s %s"):format(check.ok and "ok  " or "MISS", check.name, check.detail)
    end
    return lines
end

--- @param notify? fun(message: string, level: integer)
function M.run(notify)
    notify = notify or function(message, level)
        vim.notify(message, level)
    end
    local WARN = vim.log.levels.WARN
    local INFO = vim.log.levels.INFO
    for _, line in ipairs(M.report()) do
        notify("[orchlaunch] " .. line, line:sub(1, 4) == "MISS" and WARN or INFO)
    end
end

return M
