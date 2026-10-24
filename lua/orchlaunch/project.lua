-- OrchLaunch — `.orch` project discovery and scaffolding.

local config = require("orchlaunch.config")

local M = {}

local MARKER = ".orch"

--- @param path string
--- @return string
local function normalize(path)
    return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

--- @param path string
--- @return string?
local function parent(path)
    local dirname = vim.fs.dirname(path)
    if dirname == path then
        return nil
    end
    return dirname
end

--- @param root string
--- @return string
function M.orch_dir(root)
    return vim.fs.joinpath(normalize(root), MARKER)
end

--- Walks up from `path` and returns the highest directory containing `.orch`.
---@param path? string
---@return string? root
---@return string? orch_dir
function M.locate(path)
    local current = normalize(path or vim.fn.getcwd())
    local highest = nil

    while current do
        if vim.fn.isdirectory(vim.fs.joinpath(current, MARKER)) == 1 then
            highest = current
        end
        current = parent(current)
    end

    if not highest then
        return nil, nil
    end

    return highest, vim.fs.joinpath(highest, MARKER)
end

--- Creates `.orch` and its configuration files. Returns false if it exists.
---
--- The scaffold is written into a temporary sibling directory and renamed into
--- place, so an interrupted or failing create never leaves a half-populated
--- `.orch` directory that `state.setup()` would then treat as valid.
---@param root string
---@return boolean created
---@return string? error
function M.create(root)
    root = normalize(root)
    local dir = M.orch_dir(root)

    if vim.fn.isdirectory(dir) == 1 then
        return false
    end

    local parent_dir = vim.fs.dirname(dir)
    if parent_dir and parent_dir ~= "" and vim.fn.isdirectory(parent_dir) == 0 then
        vim.fn.mkdir(parent_dir, "p")
        if vim.fn.isdirectory(parent_dir) == 0 then
            return nil, ("cannot create directory %s"):format(parent_dir)
        end
    end

    local tmp = ("%s.tmp.%d.%d"):format(dir, vim.fn.getpid(), vim.uv.hrtime())
    local created, create_err = vim.fn.mkdir(tmp, "p")
    if created ~= 1 and vim.fn.isdirectory(tmp) == 0 then
        return nil, ("failed to create .orch directory: %s"):format(create_err or "unknown error")
    end

    local function cleanup()
        vim.fn.delete(tmp, "rf")
    end

    local files = {
        { "run_configurations.json", config.run_configurations() },
        { "external_tools.json", config.external_tools_config() },
        { "toolchain.json", config.toolchain_config() },
        { "cmake_settings.json", { cmake = config.cmake_config() } },
        { "breakpoints.json", { breakpoints = {} } },
    }

    for _, file in ipairs(files) do
        local path = vim.fs.joinpath(tmp, file[1])
        local ok, err = config.save(path, file[2])
        if not ok then
            cleanup()
            return nil, err
        end
    end

    -- Re-check immediately before the rename: another process may have won
    -- the race while the temporary directory was being populated.
    if vim.fn.isdirectory(dir) == 1 then
        cleanup()
        return false
    end

    local renamed, rename_err = vim.uv.fs_rename(tmp, dir)
    if not renamed then
        cleanup()
        return nil, ("cannot create %s: %s"):format(dir, rename_err or "unknown error")
    end

    return true
end

return M
