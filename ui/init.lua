-- OrchLaunch — shared UI helpers built on nui-components.

local M = {}

--- @return table
function M.n()
    return require("nui-components")
end

--- @param message string
--- @param level? integer
function M.notify(message, level)
    vim.notify("[orchlaunch] " .. message, level or vim.log.levels.INFO)
end

--- Creates a centered renderer with a frame around the whole layout.
---@param opts? { width?: integer, height?: integer, position?: string|number, relative?: string, keymap?: table, on_mount?: function, on_unmount?: function, frame?: boolean }
---@return table
function M.renderer(opts)
    opts = opts or {}

    local renderer = M.n().create_renderer({
        width = opts.width or 90,
        height = opts.height or 34,
        position = opts.position or "50%",
        relative = opts.relative or "editor",
        on_mount = opts.on_mount,
        on_unmount = opts.on_unmount,
        keymap = vim.tbl_extend("force", {
            close = "<Esc>",
            focus_next = "<Tab>",
            focus_prev = "<S-Tab>",
        }, opts.keymap or {}),
    })

    if opts.frame ~= false then
        -- The layout container only exists after `render`, and its window opens on
        -- the next tick; dressing it here lands on the window config before mount.
        local base_render = renderer.render
        renderer.render = function(self, content)
            base_render(self, content)
            M.frame(self)
        end
    end

    return renderer
end

--- Glyphs for the rounded frame (Neovim ignores the `style`-table border form
--- on this window, so the explicit list is used).
local FRAME_BORDER = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }

--- Draws a frame (border + solid panel) around a renderer's whole layout.
---
--- `nui-components` layout containers (rows/columns/box/form) have no window of
--- their own; the renderer's underlying `nui.layout` does own a container window,
--- so we give that one a border and an opaque background. Child windows sit on a
--- higher z-index, so they render on top of the panel.
---@param renderer table
---@return table? layout
function M.frame(renderer)
    local layout = renderer and renderer.layout
    local float = layout and layout._ and layout._.float
    if not float then
        return nil
    end

    float.win_config.border = FRAME_BORDER
    float.win_config.style = "minimal"
    float.win_options.winblend = 0

    return layout
end

--- Reads the current value of a component by id.
---@param renderer table
---@param id string
---@return any
function M.value(renderer, id)
    local component = renderer:get_component_by_id(id)
    if not component then
        return nil
    end
    return component:get_current_value()
end

--- Splits a multiline text input into trimmed, non-empty lines.
---@param text? string
---@return string[]
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
---@param text? string
---@return OrchEnvironment
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
---@param env? OrchEnvironment
---@return string
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
---@param list? string[]
---@return string
function M.format_lines(list)
    return table.concat(list or {}, "\n")
end

function M.apply_theme()
  pcall(vim.api.nvim_set_hl, 0, "NuiComponentsSelectOption", { link = "Normal" })
  pcall(vim.api.nvim_set_hl, 0, "NuiComponentsSelectOptionSelected", { link = "Visual" })
  pcall(vim.api.nvim_set_hl, 0, "NuiComponentsButton", { link = "NormalFloat" })
  pcall(vim.api.nvim_set_hl, 0, "NuiComponentsBorder", { link = "FloatBorder" })
end

return M
