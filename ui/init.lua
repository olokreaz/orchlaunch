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

--- Creates a centered renderer with a padded frame around the whole layout.
---@param opts? { width?: integer, height?: integer, position?: string|number, relative?: string, keymap?: table, on_mount?: function, on_unmount?: function, frame?: boolean, padding?: false|{ top?: integer, bottom?: integer, left?: integer, right?: integer } }
---@return table
function M.renderer(opts)
    opts = opts or {}

    local pad = M.frame_padding(opts.frame ~= false and opts.padding or false)

    local renderer = M.n().create_renderer({
        width = M.clamp_width((opts.width or 90) + pad.left + pad.right),
        height = M.clamp_height((opts.height or 34) + pad.top + pad.bottom),
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
        -- the next tick; dress it and inset its content in one pass.
        local base_render = renderer.render
        renderer.render = function(self, content)
            if type(content) == "function" then
                content = content()
            end
            base_render(self, M.pad(content, pad))
            M.frame(self)
        end
    end

    return renderer
end

--- Default inner padding between the frame border and the content.
local FRAME_PADDING = { top = 1, bottom = 1, left = 2, right = 2 }

--- Normalizes a padding option into a full `{ top, bottom, left, right }` map.
---@param padding? false|{ top?: integer, bottom?: integer, left?: integer, right?: integer }
---@return { top: integer, bottom: integer, left: integer, right: integer }
function M.frame_padding(padding)
    if padding == false then
        return { top = 0, bottom = 0, left = 0, right = 0 }
    end

    local pad = padding or FRAME_PADDING
    return {
        top = pad.top or 0,
        bottom = pad.bottom or 0,
        left = pad.left or 0,
        right = pad.right or 0,
    }
end

--- @param width integer
--- @return integer
function M.clamp_width(width)
    return math.max(20, math.min(width, vim.o.columns - 2))
end

--- @param height integer
--- @return integer
function M.clamp_height(height)
    return math.max(10, math.min(height, vim.o.lines - 3))
end

--- Wraps `content` in spacer rows/columns so it sits `pad` cells inside the frame.
---@param content any
---@param pad { top: integer, bottom: integer, left: integer, right: integer }
---@return any
function M.pad(content, pad)
    if pad.top == 0 and pad.bottom == 0 and pad.left == 0 and pad.right == 0 then
        return content
    end

    local n = M.n()
    local middle = n.box({ flex = 1 }, content)

    if pad.left > 0 or pad.right > 0 then
        local columns = {}
        if pad.left > 0 then
            columns[#columns + 1] = n.gap(pad.left)
        end
        columns[#columns + 1] = middle
        if pad.right > 0 then
            columns[#columns + 1] = n.gap(pad.right)
        end
        middle = n.columns({ flex = 1 }, unpack(columns))
    end

    local rows = {}
    if pad.top > 0 then
        rows[#rows + 1] = n.gap(pad.top)
    end
    rows[#rows + 1] = middle
    if pad.bottom > 0 then
        rows[#rows + 1] = n.gap(pad.bottom)
    end

    return n.rows({ flex = 1, direction = "column" }, unpack(rows))
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
