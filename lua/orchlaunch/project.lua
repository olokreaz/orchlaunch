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
---@param root string
---@return boolean
function M.create(root)
    root = normalize(root)
    local dir = M.orch_dir(root)

    if vim.fn.isdirectory(dir) == 1 then
        return false
    end

    assert(
        vim.fn.mkdir(dir, "p") == 1 or vim.fn.isdirectory(dir) == 1,
        "[orchlaunch] failed to create .orch directory"
    )

    local files = {
        { "run_configurations.json", config.run_configurations() },
        { "external_tools.json", config.external_tools_config() },
        { "toolchain.json", config.toolchain_config() },
        { "cmake_settings.json", { cmake = config.cmake_config() } },
    }

    for _, file in ipairs(files) do
        local path = vim.fs.joinpath(dir, file[1])
        if vim.fn.filereadable(path) == 0 then
            assert(config.save(path, file[2]), ("[orchlaunch] failed to create %s"):format(path))
        end
    end

    return true
end

return M
