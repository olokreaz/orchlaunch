-- OrchLaunch test harness.
--
-- Every `*_test.lua` file starts with:
--
--   local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
--   package.path = here .. "/?.lua;" .. package.path
--   local h = require("harness")
--
-- which puts the plugin root on the runtimepath together with its
-- dependencies, and exposes the assertion/reporting helpers used across the
-- suite. Paths are resolved relative to this file, so the suite is portable:
-- no absolute paths are baked in.

-- `source` is <root>/tests/harness.lua; its grandparent is the plugin root
-- that holds `lua/orchlaunch`.
local ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

vim.opt.rtp:append(ROOT)

-- Dependencies live next to the plugin in a plugin manager. Resolve them from
-- the standard locations; an `ORCHLAUNCH_DEPS` env var can override the root.
local deps_roots = {}
if vim.env.ORCHLAUNCH_DEPS and vim.env.ORCHLAUNCH_DEPS ~= "" then
    deps_roots[#deps_roots + 1] = vim.env.ORCHLAUNCH_DEPS
end
deps_roots[#deps_roots + 1] = vim.fn.stdpath("data") .. "/lazy"
deps_roots[#deps_roots + 1] = vim.fn.stdpath("data") .. "/site/pack/deps/start"
deps_roots[#deps_roots + 1] = vim.fn.stdpath("data") .. "/site/pack/core/opt"

for _, name in ipairs({ "volt" }) do
    for _, deps in ipairs(deps_roots) do
        local path = deps .. "/" .. name
        if vim.fn.isdirectory(path) == 1 then
            vim.opt.rtp:append(path)
            break
        end
    end
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
