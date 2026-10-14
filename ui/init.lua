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
---@param opts? { width?: integer, height?: integer, position?: string|number, relative?: string, keymap?: table, on_mount?: function, on_unmount?: function, frame?: boolean, frame_label?: string }
---@return table
function M.renderer(opts)
    opts = opts or {}

    local user_on_mount = opts.on_mount
    local renderer

    renderer = M.n().create_renderer({
        width = opts.width or 90,
        height = opts.height or 34,
        position = opts.position or "50%",
        relative = opts.relative or "editor",
        on_mount = function()
            if opts.frame ~= false then
                M.frame(renderer, { label = opts.frame_label })
            end
            if user_on_mount then
                user_on_mount()
            end
        end,
        on_unmount = opts.on_unmount,
        keymap = vim.tbl_extend("force", {
            close = "<Esc>",
            focus_next = "<Tab>",
            focus_prev = "<S-Tab>",
        }, opts.keymap or {}),
    })

    return renderer
end

--- Draws a frame (border) around a renderer's whole layout.
---
--- `nui-components` layout containers (rows/columns/box/form) have no window of
--- their own, so a border set on them is never drawn. The renderer's underlying
--- `nui.layout` does own a container window, so we dress that one up instead.
---@param renderer table
---@param opts? { label?: string }
---@return table? layout
function M.frame(renderer, opts)
    opts = opts or {}

    local layout = renderer and renderer.layout
    local float = layout and layout._ and layout._.float
    if not float then
        return nil
    end

    local border = {
        style = "rounded",
        text = { top = opts.label or "", top_align = "left" },
    }

    float.win_config.border = border
    float.win_options.winblend = opts.winblend or 0

    if layout.winid and vim.api.nvim_win_is_valid(layout.winid) then
        pcall(vim.api.nvim_win_set_config, layout.winid, { border = border })
        pcall(vim.api.nvim_set_option_value, "winblend", opts.winblend or 0, { win = layout.winid })
    end

    return layout
end

--- Updates the top label of a frame previously drawn by `M.frame`.
---@param renderer table
---@param label string
function M.set_frame_label(renderer, label)
    local layout = renderer and renderer.layout
    if not (layout and layout.winid and vim.api.nvim_win_is_valid(layout.winid)) then
        return
    end

    pcall(vim.api.nvim_win_set_config, layout.winid, {
        border = {
            style = "rounded",
            text = { top = label, top_align = "left" },
        },
    })
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
