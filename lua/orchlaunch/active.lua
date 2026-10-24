-- OrchLaunch — the active run configuration.
--
-- The active configuration is a UI-facing selection, not project configuration,
-- so it is never written into `.orch`. It is persisted in Neovim's state
-- directory, keyed by workspace root.

local config = require("orchlaunch.config")

local M = {}

--- @return string
local function store_path()
    return vim.fs.joinpath(vim.fn.stdpath("state"), "orchlaunch", "active.json")
end

--- @return table<string, string>
local function read_all()
    local data, err = config.load(store_path())
    if not data then
        vim.notify(("[orchlaunch] %s"):format(err), vim.log.levels.WARN)
        return {}
    end

    for root, name in pairs(data) do
        if type(root) ~= "string" or type(name) ~= "string" then
            vim.notify("[orchlaunch] active.json contains invalid entries", vim.log.levels.WARN)
            return {}
        end
    end

    return data
end

--- @param data table<string, string>
--- @return boolean ok
--- @return string? error
local function write_all(data)
    local ok, err = config.save(store_path(), data)
    if not ok then
        vim.notify(("[orchlaunch] %s"):format(err), vim.log.levels.ERROR)
    end
    return ok, err
end

--- Returns the active configuration name for `root`.
---@param root string
---@return string?
function M.get(root)
    return read_all()[root]
end

--- Sets (or clears, when `name` is nil) the active configuration for `root`.
---@param root string
---@param name? string
---@return boolean ok
---@return string? error
function M.set(root, name)
    if name ~= nil and type(name) ~= "string" then
        return false, "active configuration name must be a string"
    end
    local data = read_all()
    data[root] = name
    return write_all(data)
end

return M
