-- OrchLaunch test harness.
--
-- Every `*_test.lua` file starts with:
--
--   local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
--   package.path = here .. "/?.lua;" .. package.path
--   local h = require("harness")
--
-- which appends the runtime path entries the plugin needs and exposes the
-- assertion/reporting helpers used across the suite.

local NVIM_ROOT = "/home/olokreaz/.config/nvim"
local LAZY = "/home/olokreaz/.local/share/nvim/lazy"

for _, path in ipairs({
    NVIM_ROOT,
    LAZY .. "/nui.nvim",
    LAZY .. "/nui-components.nvim",
    LAZY .. "/toml.nvim",
}) do
    vim.opt.rtp:append(path)
end

local M = {}

M.failures = 0
M.passes = 0

--- Records a boolean assertion.
---@param name string
---@param ok any
---@param err? any Extra detail shown on failure.
function M.check(name, ok, err)
    if ok then
        M.passes = M.passes + 1
        print("PASS  " .. name)
    else
        M.failures = M.failures + 1
        local detail = err ~= nil and ("  -- " .. tostring(err)) or ""
        print("FAIL  " .. name .. detail)
    end
end

--- Deep-equality assertion.
---@param name string
---@param got any
---@param want any
function M.eq(name, got, want)
    M.check(name, vim.deep_equal(got, want), ("got %s, want %s"):format(vim.inspect(got), vim.inspect(want)))
end

--- Asserts a string contains `needle` (plain match).
---@param name string
---@param haystack? string
---@param needle string
function M.contains(name, haystack, needle)
    M.check(name, haystack ~= nil and haystack:find(needle, 1, true) ~= nil, ("%q not found in %s"):format(needle, vim.inspect(haystack)))
end

--- Runs `fn` under pcall and asserts it did not raise.
---@param name string
---@param fn function
---@return any
function M.ok(name, fn)
    local ok, value = pcall(fn)
    M.check(name, ok, value)
    return value
end

--- Creates a fresh temporary directory.
---@return string
function M.tempdir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return dir
end

--- Writes a file (creating parent directories).
---@param path string
---@param content string
function M.write(path, content)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local file = assert(io.open(path, "w"))
    file:write(content)
    file:close()
end

--- Reads a file as a string.
---@param path string
---@return string
function M.read(path)
    local file = assert(io.open(path, "r"))
    local content = file:read("*a")
    file:close()
    return content
end

--- Finishes the suite: prints a summary and exits non-zero on failure.
---@param title string
function M.done(title)
    if M.failures == 0 then
        print(("\nALL PASS: %s (%d checks)"):format(title, M.passes))
    else
        print(("\n%d FAILURE(S), %d passed: %s"):format(M.failures, M.passes, title))
        os.exit(1)
    end
end

return M
