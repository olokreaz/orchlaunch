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
    local path
    if command:find("[/\\]") then
        path = vim.fn.executable(command) == 1 and command or ""
    else
        path = vim.fn.exepath(command)
    end
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
    local cmake_command = "cmake"
    local c_compiler, cxx_compiler, debugger

    local state_ok, state = pcall(require, "orchlaunch.state")
    local cmake_ok, cmake = pcall(require, "orchlaunch.cmake")
    if state_ok and cmake_ok and state.is_loaded() then
        cmake_command = cmake.cmake_program()
        local toolchain = cmake.toolchain()
        if toolchain then
            c_compiler = toolchain.c
            cxx_compiler = toolchain.cxx
            debugger = toolchain.debugger
        end
    end

    local checks = {
        command_check("cmake", cmake_command),
        command_check("ninja (optional)", "ninja", false),
    }
    if c_compiler and c_compiler ~= "" then
        checks[#checks + 1] = command_check("C compiler (" .. c_compiler .. ")", c_compiler, false)
    else
        checks[#checks + 1] = command_check("clang", "clang", false)
        checks[#checks + 1] = command_check("gcc", "gcc", false)
    end
    if cxx_compiler and cxx_compiler ~= "" then
        checks[#checks + 1] = command_check("C++ compiler (" .. cxx_compiler .. ")", cxx_compiler, false)
    else
        checks[#checks + 1] = command_check("clang++", "clang++", false)
        checks[#checks + 1] = command_check("g++", "g++", false)
    end
    if debugger and debugger ~= "" then
        checks[#checks + 1] = command_check("debugger (" .. debugger .. ")", debugger, false)
    end
    checks[#checks + 1] = command_check("LLDB DAP adapter (lldb-dap)", "lldb-dap", false)
    checks[#checks + 1] = command_check("LLDB (lldb-server)", "lldb-server", false)
    checks[#checks + 1] = command_check("GDB", "gdb", false)
    checks[#checks + 1] = module_check("nvim-dap", "dap")
    checks[#checks + 1] = module_check("fibrous.nvim", "fibrous")
    return checks
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
