-- OrchLaunch — one place for user-facing messages, so every message carries
-- the same "[orchlaunch]" prefix and levels are passed the same way.

local M = {}

--- Shows `message` through vim.notify with the plugin prefix.
---@param message string
---@param level? integer vim.log.levels value; INFO by default.
function M.notify(message, level)
    vim.notify("[orchlaunch] " .. message, level or vim.log.levels.INFO)
end

return M
