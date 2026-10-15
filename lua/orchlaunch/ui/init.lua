-- OrchLaunch — shared UI helpers.
--
-- These are the UI-agnostic pieces every screen relies on: notifications, the
-- text <-> value parsers used by the editors and a tiny theme shim. The widgets
-- themselves live in `orchlaunch.ui.kit`.

local M = {}

--- @return table The declarative UI builder.
function M.n()
    return require("orchlaunch.ui.kit").n()
end

--- @param opts table
--- @return table The window renderer.
function M.renderer(opts)
    return require("orchlaunch.ui.kit").renderer(opts)
end

--- @param message string
--- @param level? integer
function M.notify(message, level)
    vim.notify("[orchlaunch] " .. message, level or vim.log.levels.INFO)
end

--- Splits a multiline text input into trimmed, non-empty lines.
--- @param text? string
--- @return string[]
function M.lines(text)
    local out = {}
    for line in (text or ""):gmatch("[^\n]+") do
        local trimmed = vim.trim(line)
        if trimmed ~= "" then
            out[#out + 1] = trimmed
        end
    end
    return out
end

--- Parses `KEY=VALUE` lines into an environment table.
--- @param text? string
--- @return OrchEnvironment
function M.parse_env(text)
    local env = {}
    for _, line in ipairs(M.lines(text)) do
        local key, value = line:match("^([%w_]+)%s*=%s*(.*)$")
        if key then
            env[key] = value
        end
    end
    return env
end

--- Serializes an environment table into `KEY=VALUE` lines.
--- @param env? OrchEnvironment
--- @return string
function M.format_env(env)
    local keys = {}
    for key in pairs(env or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    local out = {}
    for _, key in ipairs(keys) do
        out[#out + 1] = ("%s=%s"):format(key, env[key])
    end
    return table.concat(out, "\n")
end

--- Serializes a list into newline-separated lines.
--- @param list? string[]
--- @return string
function M.format_lines(list)
    return table.concat(list or {}, "\n")
end

--- Trims and normalizes a value to `nil` when empty.
--- @param value? string
--- @return string?
function M.trimmed(value)
    if type(value) ~= "string" then
        return nil
    end
    value = vim.trim(value)
    return value ~= "" and value or nil
end

--- Theme shim kept for backwards compatibility with plugin setup.
function M.apply_theme()
    local kit = require("orchlaunch.ui.kit")
    for _, group in ipairs({ "Title", "Comment", "Function", "Constant" }) do
        pcall(vim.api.nvim_get_hl, 0, { name = group })
    end
    pcall(function()
        vim.api.nvim_set_hl(0, "OrchLaunchBorder", { link = kit.HL.rule })
    end)
end

return M
