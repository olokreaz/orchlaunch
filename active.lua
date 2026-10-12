-- OrchLaunch — the active run configuration.
--
-- The active configuration is a UI-facing selection, not project configuration,
-- so it is never written into `.orch`. It is persisted in Neovim's state
-- directory, keyed by workspace root.

local M = {}

--- @return string
local function store_path()
    return vim.fs.joinpath(vim.fn.stdpath("state"), "orchlaunch", "active.json")
end

--- @return table<string, string>
local function read_all()
    local path = store_path()
    if vim.fn.filereadable(path) == 0 then
        return {}
    end

    local file = io.open(path, "r")
    if not file then
        return {}
    end
    local content = file:read("*a")
    file:close()

    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" then
        return {}
    end

    return decoded
end

--- @param data table<string, string>
local function write_all(data)
    local path = store_path()
    local dir = vim.fs.dirname(path)
    if dir and vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end

    local file = io.open(path, "w")
    if not file then
        return
    end
    file:write(vim.json.encode(data))
    file:close()
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
function M.set(root, name)
    local data = read_all()
    data[root] = name
    write_all(data)
end

return M
