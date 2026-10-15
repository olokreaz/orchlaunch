-- OrchLaunch — the Volt-based UI engine.
--
-- Every OrchLaunch window is described with the same small declarative builder
-- (`UI.n()`): containers (`rows`, `columns`, `box`), spacers (`gap`), text
-- (`paragraph`, `line`, `text`) and widgets (`text_input`, `checkbox`, `select`,
-- `option`, `button`). `UI.renderer(opts)` turns that tree into a floating Volt
-- buffer, handles focus, key maps, click actions and the scripting hooks
-- (`get_component_by_id`, `get_focusable_components`, `_save`) the test-suite
-- drives.
--
-- The engine is intentionally small: it implements just the subset of the
-- former nui-components API that OrchLaunch actually uses, so all editors and
-- dialogs keep a single, consistent style while running on Volt.

local api = vim.api
local volt = require("volt")

local M = {}

--- Highlight groups used by the widgets (plain built-ins, no theme needed).
local HL = {
    title = "Title",
    heading = "Title",
    label = "Comment",
    value = "Normal",
    dim = "Comment",
    rule = "Comment",
    active = "Constant",
    button = "Function",
    ok = "String",
    warn = "WarningMsg",
    marker = "Keyword",
}

M.HL = HL

-- ============================================================================
-- Signals
-- ============================================================================

local Signal = {}
Signal.__index = Signal

function Signal:get_value()
    return self._value
end

function Signal:set_value(value)
    self._value = value
    M.schedule_redraw()
end

local ProxyMT = {
    __index = function(self, key)
        return rawget(self, "_sub")[key]
    end,
    __newindex = function(self, key, value)
        local sub = rawget(self, "_sub")
        if sub[key] then
            sub[key]._value = value
        else
            sub[key] = setmetatable({ _value = value }, Signal)
        end
        M.schedule_redraw()
    end,
}

--- Creates a reactive value. Table initialisers yield a proxy whose fields are
--- themselves signals (`model.details`, `model.list:get_value()`, …).
--- @param initial any
--- @return table
function M.create_signal(initial)
    if type(initial) == "table" then
        local sub = {}
        for key, value in pairs(initial) do
            sub[key] = setmetatable({ _value = value }, Signal)
        end
        return setmetatable({ _sub = sub }, ProxyMT)
    end
    return setmetatable({ _value = initial }, Signal)
end

local function is_signal(value)
    return type(value) == "table" and getmetatable(value) == Signal
end

local function resolve(value)
    if is_signal(value) then
        return value:get_value()
    end
    return value
end

-- ============================================================================
-- Redraw scheduling
-- ============================================================================

M.renderers = {}

local redraw_depth = 0
local redraw_scheduled = false

function M.schedule_redraw()
    if redraw_depth > 0 or redraw_scheduled then
        return
    end
    redraw_scheduled = true
    vim.schedule(function()
        redraw_scheduled = false
        for _, renderer in ipairs(vim.deepcopy(M.renderers)) do
            if not renderer.closed then
                renderer:redraw()
            end
        end
    end)
end

-- ============================================================================
-- Builder
-- ============================================================================

--- @return table builder
function M.n()
    local n = {}

    n.rows = function(props, ...)
        return { kind = "rows", props = props or {}, children = { ... } }
    end

    n.columns = function(props, ...)
        return { kind = "columns", props = props or {}, children = { ... } }
    end

    n.box = function(props, ...)
        return { kind = "box", props = props or {}, children = { ... } }
    end

    n.gap = function(size)
        return { kind = "gap", props = size ~= nil and { size = size } or {} }
    end

    n.paragraph = function(props)
        return { kind = "paragraph", props = props or {} }
    end

    n.line = function(...)
        return { kind = "line", segments = { ... } }
    end

    n.text = function(text, hl)
        return { kind = "text", text = text, hl = hl }
    end

    n.text_input = function(props)
        return { kind = "text_input", props = props or {} }
    end

    n.checkbox = function(props)
        return { kind = "checkbox", props = props or {} }
    end

    n.select = function(props)
        return { kind = "select", props = props or {} }
    end

    n.option = function(text, props)
        return { kind = "option", text = text, id = (props or {}).id }
    end

    n.button = function(props)
        return { kind = "button", props = props or {} }
    end

    n.create_signal = M.create_signal

    return n
end

-- ============================================================================
-- Component
-- ============================================================================

local Component = {}
Component.__index = Component

function Component:get_current_value()
    if self.kind == "select" then
        return { id = self.selected_id }
    end
    if self.kind == "checkbox" then
        return self.value == true
    end
    if self.kind == "paragraph" then
        return self.text
    end
    return self.value
end

function Component:set_current_value(value)
    if self.kind == "select" then
        if type(value) == "table" then
            value = value.id
        end
        self.selected_id = value
    elseif self.kind == "checkbox" then
        self.value = value == true
    else
        self.value = value
    end
    if self.renderer and not self.renderer.closed then
        self.renderer:redraw()
    end
end

function Component:get_props()
    if self.kind == "button" then
        return { id = self.id, on_press = self.on_press, lines = self.label }
    end
    return { id = self.id }
end

function Component:get_focused_node()
    local options = self.options or {}
    if #options == 0 then
        return nil
    end
    local index = self.focused_index or 1
    if self.selected_id then
        for i, option in ipairs(options) do
            if option.id == self.selected_id then
                index = i
                break
            end
        end
    end
    return options[index]
end

function Component:focus()
    if self.renderer and not self.renderer.closed then
        self.renderer:focus()
    end
    return self
end

-- ============================================================================
-- Mark helpers
-- ============================================================================

local function marks_width(marks)
    local width = 0
    for _, mark in ipairs(marks) do
        width = width + vim.fn.strwidth(mark[1] or "")
    end
    return width
end

local function blank_marks(width)
    return { { string.rep(" ", math.max(0, width)) } }
end

--- Pads `marks` (in place) with trailing spaces to reach `width`.
local function fit_marks(marks, width)
    local current = marks_width(marks)
    if current < width then
        marks[#marks + 1] = { string.rep(" ", width - current) }
    end
    return marks
end

local function fill_block(lines, width, height)
    for i = 1, height do
        if not lines[i] then
            lines[i] = blank_marks(width)
        else
            fit_marks(lines[i], width)
        end
    end
    for i = #lines, height + 1, -1 do
        lines[i] = nil
    end
    return lines
end

-- ============================================================================
-- Renderer
-- ============================================================================

local Renderer = {}
Renderer.__index = Renderer

--- @param opts { width?: integer, height?: integer, on_mount?: function, on_unmount?: function, on_close?: function }
--- @return table renderer
function M.renderer(opts)
    opts = opts or {}

    local self = setmetatable({}, Renderer)
    self.opts = opts
    self.width = opts.width or 80
    self.height = opts.height or 24
    self.components = {}
    self.focus_order = {}
    self.focus_index = 1
    self.focus_id = nil
    self.mappings = {}
    self.markup = {}
    self.closed = false

    self.ns = api.nvim_create_namespace("OrchLaunch" .. tostring(#M.renderers))

    self.buf = api.nvim_create_buf(false, true)
    vim.bo[self.buf].bufhidden = "wipe"
    vim.bo[self.buf].swapfile = false

    local row = math.max(1, math.floor((vim.o.lines - self.height) / 2))
    local col = math.max(1, math.floor((vim.o.columns - self.width) / 2))

    self.win = api.nvim_open_win(self.buf, true, {
        relative = "editor",
        width = self.width,
        height = self.height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " OrchLaunch ",
        title_pos = "center",
        zindex = 50,
    })
    self.winid = self.win
    self.bufnr = self.buf

    vim.wo[self.win].wrap = false
    vim.wo[self.win].scrolloff = 0
    vim.wo[self.win].number = false
    vim.wo[self.win].relativenumber = false

    api.nvim_set_hl(self.ns, "Normal", api.nvim_get_hl(0, { name = "NormalFloat" }))
    api.nvim_set_hl(self.ns, "FloatBorder", api.nvim_get_hl(0, { name = "FloatBorder" }))
    api.nvim_set_hl(self.ns, "FloatTitle", api.nvim_get_hl(0, { name = "FloatTitle" }))
    api.nvim_win_set_hl_ns(self.win, self.ns)

    require("volt.highlights")
    require("volt.events").enable()

    volt.mappings({
        bufs = { self.buf },
        close_func = function()
            self:close()
        end,
        after_close = function()
            self:close()
        end,
    })

    self:add_mappings({
        { mode = "n", key = "j", handler = function() self:move_focus(1) end },
        { mode = "n", key = "<Down>", handler = function() self:move_focus(1) end },
        { mode = "n", key = "k", handler = function() self:move_focus(-1) end },
        { mode = "n", key = "<Up>", handler = function() self:move_focus(-1) end },
        { mode = "n", key = "<Tab>", handler = function() self:move_focus(1) end },
        { mode = "n", key = "<S-Tab>", handler = function() self:move_focus(-1) end },
        { mode = "n", key = "<CR>", handler = function() self:activate_focused() end },
    })

    M.renderers[#M.renderers + 1] = self

    if opts.on_mount then
        pcall(opts.on_mount, self)
    end

    return self
end

function Renderer:apply_mappings()
    for _, mapping in ipairs(self.mappings) do
        vim.keymap.set(mapping.mode or "n", mapping.key, mapping.handler, {
            buffer = self.buf,
            nowait = true,
            silent = true,
        })
    end
end

--- @param mappings { mode?: string|string[], key: string, handler: function }[]
function Renderer:add_mappings(mappings)
    for _, mapping in ipairs(mappings or {}) do
        self.mappings[#self.mappings + 1] = mapping
    end
    if api.nvim_buf_is_valid(self.buf) then
        self:apply_mappings()
    end
end

--- @param id string
--- @return table?
function Renderer:get_component_by_id(id)
    return self.components[id]
end

--- @return table[]
function Renderer:get_focusable_components()
    return self.focus_order
end

function Renderer:focus()
    if api.nvim_win_is_valid(self.win) then
        api.nvim_set_current_win(self.win)
    end
end

--- Moves the focus cursor by `delta` across the interactive widgets.
--- @param delta integer
function Renderer:move_focus(delta)
    local count = #self.focus_order
    if count == 0 then
        return
    end
    self.focus_index = ((self.focus_index - 1 + delta) % count) + 1
    self.focus_id = self.focus_order[self.focus_index].id
    self:redraw()
end

--- Activates the currently focused widget (toggle / edit / select / press).
function Renderer:activate_focused()
    local component = self.focus_order[self.focus_index]
    if not component then
        return
    end

    if component.kind == "checkbox" then
        component.value = not (component.value == true)
        self:redraw()
    elseif component.kind == "text_input" then
        self:open_editor(component)
    elseif component.kind == "select" then
        local options = component.options or {}
        if #options > 0 then
            component.focused_index = (component.focused_index % #options) + 1
            component.selected_id = options[component.focused_index].id
            self:redraw()
        end
    elseif component.kind == "button" and component.on_press then
        component.on_press(component)
    end
end

--- @param tree table|function
function Renderer:render(tree)
    self.tree = tree
    self:redraw()
end

function Renderer:redraw()
    if self.closed or not self.tree then
        return
    end
    redraw_depth = redraw_depth + 1
    local ok, err = pcall(self._do_render, self)
    redraw_depth = redraw_depth - 1
    if not ok then
        vim.notify("[orchlaunch] render error: " .. tostring(err), vim.log.levels.ERROR)
    end
end

function Renderer:close()
    if self.closed then
        return
    end
    self.closed = true

    if self.prompt_win and api.nvim_win_is_valid(self.prompt_win) then
        pcall(api.nvim_win_close, self.prompt_win, true)
    end
    if self.scratch then
        pcall(self.scratch.close)
        self.scratch = nil
    end

    for i, renderer in ipairs(M.renderers) do
        if renderer == self then
            table.remove(M.renderers, i)
            break
        end
    end

    if api.nvim_win_is_valid(self.win) then
        pcall(api.nvim_win_close, self.win, true)
    end
    if api.nvim_buf_is_valid(self.buf) then
        pcall(api.nvim_buf_delete, self.buf, { force = true })
    end

    if self.opts.on_unmount then
        pcall(self.opts.on_unmount, self)
    end
    if self.opts.on_close then
        pcall(self.opts.on_close, self)
    end
end

--- @param name "n"|"i"|"v"
function Renderer:open_editor(component, modality)
    local value = tostring(component.value or "")
    local label = (component.props.border_label or component.id):gsub("^%s+", ""):gsub("%s+$", "")

    if component.multiline then
        local scratch = require("orchlaunch.ui.scratch")
        self.scratch = scratch.open_lua({
            title = label,
            lines = vim.split(value, "\n", { plain = true }),
            on_save = function(text)
                self.scratch = nil
                component.value = text
                self:focus()
                self:redraw()
            end,
            on_close = function()
                self.scratch = nil
                self:focus()
            end,
        })
        return
    end

    if not self.prompt_buf or not api.nvim_buf_is_valid(self.prompt_buf) then
        self.prompt_buf = api.nvim_create_buf(false, true)
        vim.bo[self.prompt_buf].buftype = "prompt"
        vim.fn.prompt_setprompt(self.prompt_buf, "  ❯ ")
        vim.bo[self.prompt_buf].swapfile = false
        self.prompt_win = api.nvim_open_win(self.prompt_buf, false, {
            relative = "win",
            win = self.win,
            row = self.height,
            col = -1,
            width = self.width,
            height = 1,
            style = "minimal",
            border = "rounded",
        })
    end

    vim.bo[self.prompt_buf].modifiable = true
    api.nvim_buf_set_lines(self.prompt_buf, 0, -1, false, { value })
    vim.fn.prompt_setcallback(self.prompt_buf, function(text)
        component.value = vim.trim(text)
        self:focus()
        self:redraw()
    end)
    vim.keymap.set("n", "<Esc>", function()
        self:focus()
        self:redraw()
    end, { buffer = self.prompt_buf, nowait = true, silent = true })

    api.nvim_set_current_win(self.prompt_win)
    api.nvim_win_set_cursor(self.prompt_win, { 1, #value })
    vim.cmd("startinsert!")
end

-- ---------------------------------------------------------------------------
-- Layout + painting
-- ---------------------------------------------------------------------------

function Renderer:_do_render()
    local function get_component(node, explicit_id)
        local id = explicit_id or (node.props and node.props.id)
        if not id then
            return nil
        end

        local component = self.components[id]
        if not component then
            component = setmetatable({
                id = id,
                kind = node.kind,
                renderer = self,
                winid = self.win,
                focused_index = 1,
            }, Component)
            self.components[id] = component

            if node.kind == "text_input" then
                component.value = tostring(resolve(node.props.value) or "")
            elseif node.kind == "checkbox" then
                component.value = resolve(node.props.value) == true
            elseif node.kind == "select" then
                local selected = resolve(node.props.selected)
                component.selected_id = type(selected) == "table" and selected.id or selected
            end
        end

        component.node = node
        component.props = node.props or {}
        if node.kind == "text_input" then
            component.multiline = (node.props.size or 1) > 1
        end
        if node.kind == "button" then
            component.on_press = node.props.on_press
            component.label = node.props.label
        end
        return component
    end

    local function paragraph_text_lines(node)
        local lines = resolve(node.props.lines)
        if type(lines) == "table" and lines.kind == "line" then
            return { lines }
        end
        if type(lines) ~= "string" then
            lines = tostring(lines or "")
        end
        return vim.split(lines, "\n", { plain = true })
    end

    local function intrinsic_height(node)
        local kind = node.kind
        if kind == "gap" then
            return node.props.size or 0
        elseif kind == "paragraph" then
            return #paragraph_text_lines(node)
        elseif kind == "text_input" then
            return math.max(1, node.props.size or 1)
        elseif kind == "checkbox" or kind == "button" then
            return 1
        elseif kind == "select" then
            local data = resolve(node.props.data) or {}
            return math.max(1, node.props.size or #data)
        elseif kind == "rows" or kind == "columns" or kind == "box" then
            local direction = node.props.direction or (kind == "columns" and "row" or "column")
            if direction == "row" then
                return 1
            end
            local padding = node.props.padding or {}
            local total = (padding.top or 0) + (padding.bottom or 0)
            for _, child in ipairs(node.children) do
                total = total + intrinsic_height(child)
            end
            return total
        end
        return 1
    end

    local function vhspec(node)
        if node.kind == "gap" and node.props.size == nil then
            return { flex = 1 }
        end
        if node.props and node.props.flex then
            return { flex = node.props.flex }
        end
        if node.props and node.props.size then
            return { h = node.props.size }
        end
        return { h = intrinsic_height(node) }
    end

    local function intrinsic_width(node)
        if node.kind == "button" then
            return vim.fn.strwidth(node.props.label or "")
        elseif node.kind == "gap" then
            return node.props.size or 0
        elseif node.kind == "paragraph" then
            local max = 0
            for _, line in ipairs(paragraph_text_lines(node)) do
                local text = type(line) == "string" and line or ""
                max = math.max(max, vim.fn.strwidth(text))
            end
            return max
        end
        return 0
    end

    local function whspec(node)
        if node.kind == "gap" and node.props.size ~= nil then
            return { w = node.props.size }
        end
        if node.props and node.props.flex then
            return { flex = node.props.flex }
        end
        return { w = intrinsic_width(node) }
    end

    local render_node

    local function render_rows(node, width, height)
        local padding = node.props.padding or {}
        local pl, pr = padding.left or 0, padding.right or 0
        local pt, pb = padding.top or 0, padding.bottom or 0
        local inner_w = math.max(0, width - pl - pr)
        local inner_h = math.max(0, height - pt - pb)

        local specs, fixed_total, flex_total = {}, 0, 0
        for i, child in ipairs(node.children) do
            local spec = vhspec(child)
            specs[i] = spec
            if spec.flex then
                flex_total = flex_total + spec.flex
            else
                fixed_total = fixed_total + spec.h
            end
        end

        local remaining = math.max(0, inner_h - fixed_total)
        local total, flex_left = 0, flex_total
        for i, child in ipairs(node.children) do
            local spec = specs[i]
            local h
            if spec.flex then
                h = flex_total > 0 and math.floor(remaining * spec.flex / flex_total) or 0
            else
                h = spec.h
            end
            specs[i].h = h
            total = total + h
        end

        -- Hand any rounding leftover to the flexible children first.
        local leftover = inner_h - total
        for i, child in ipairs(node.children) do
            if leftover <= 0 then
                break
            end
            if specs[i].flex then
                specs[i].h = specs[i].h + 1
                leftover = leftover - 1
            end
        end

        local lines = {}
        for _ = 1, pt do
            lines[#lines + 1] = blank_marks(width)
        end
        for i, child in ipairs(node.children) do
            local block = render_node(child, inner_w, specs[i].h)
            for _, line in ipairs(block) do
                local marks = {}
                if pl > 0 then
                    marks[#marks + 1] = { string.rep(" ", pl) }
                end
                for _, mark in ipairs(line) do
                    marks[#marks + 1] = mark
                end
                lines[#lines + 1] = fit_marks(marks, width)
            end
        end
        return fill_block(lines, width, height)
    end

    local function render_columns(node, width, height)
        local padding = node.props.padding or {}
        local pl, pr = padding.left or 0, padding.right or 0
        local pt, pb = padding.top or 0, padding.bottom or 0
        local inner_w = math.max(0, width - pl - pr)
        local inner_h = math.max(0, height - pt - pb)

        local specs, fixed_total, flex_total = {}, 0, 0
        for i, child in ipairs(node.children) do
            local spec = whspec(child)
            specs[i] = spec
            if spec.flex then
                flex_total = flex_total + spec.flex
            else
                fixed_total = fixed_total + spec.w
            end
        end

        local remaining = math.max(0, inner_w - fixed_total)
        local total = 0
        for i in ipairs(node.children) do
            local spec = specs[i]
            if spec.flex then
                spec.w = flex_total > 0 and math.floor(remaining * spec.flex / flex_total) or 0
            end
            total = total + spec.w
        end

        local leftover = inner_w - total
        local last = #node.children
        if leftover > 0 and last > 0 then
            for i = last, 1, -1 do
                if specs[i].flex or last == i then
                    specs[i].w = specs[i].w + leftover
                    break
                end
            end
        end

        local blocks = {}
        for i, child in ipairs(node.children) do
            blocks[i] = render_node(child, math.max(0, specs[i].w), inner_h)
        end

        local lines = {}
        for _ = 1, pt do
            lines[#lines + 1] = blank_marks(width)
        end
        for row = 1, inner_h do
            local marks = {}
            if pl > 0 then
                marks[#marks + 1] = { string.rep(" ", pl) }
            end
            for i = 1, #node.children do
                local line = blocks[i][row] or blank_marks(specs[i].w)
                fit_marks(line, specs[i].w)
                for _, mark in ipairs(line) do
                    marks[#marks + 1] = mark
                end
            end
            lines[#lines + 1] = fit_marks(marks, width)
        end
        return fill_block(lines, width, height)
    end

    local function render_paragraph(node, width, height)
        local raw_lines = paragraph_text_lines(node)
        local align = node.props.align or "left"

        if node.props.id then
            local component = get_component(node)
            if component then
                local text = {}
                for _, raw in ipairs(raw_lines) do
                    text[#text + 1] = type(raw) == "string" and raw or ""
                end
                component.text = table.concat(text, "\n")
            end
        end

        local lines = {}

        for _, raw in ipairs(raw_lines) do
            local marks
            if type(raw) == "table" and raw.kind == "line" then
                marks = {}
                for _, segment in ipairs(raw.segments) do
                    marks[#marks + 1] = { segment.text or "", segment.hl or HL.value }
                end
            else
                marks = { { raw, HL.value } }
            end

            if align == "center" then
                local current = marks_width(marks)
                if current < width then
                    table.insert(marks, 1, { string.rep(" ", math.floor((width - current) / 2)) })
                end
            end
            lines[#lines + 1] = fit_marks(marks, width)
        end

        return fill_block(lines, width, height)
    end

    local function render_text_input(node, width, height)
        local component = get_component(node)
        if component then
            self.focus_order[#self.focus_order + 1] = component
        end
        local focused = component and component.id == self.focus_id
        local value = component and component.value or tostring(resolve(node.props.value) or "")
        local label = node.props.border_label or ""

        local lines = {}
        local content = vim.split(value, "\n", { plain = true })
        if #content == 0 then
            content = { "" }
        end

        for i = 1, math.max(height, 1) do
            local text = content[i]
            local marks
            if i == 1 then
                if (text == nil or text == "") and node.props.placeholder and value == "" then
                    marks = {
                        { " " .. label .. "  ", focused and HL.active or HL.label },
                        { node.props.placeholder, HL.dim },
                    }
                else
                    marks = {
                        { " " .. label .. "  ", focused and HL.active or HL.label },
                        { text or "", HL.value },
                    }
                end
            else
                marks = { { "  " .. (text or ""), HL.value } }
            end

            if component then
                marks[1][3] = function()
                    self:open_editor(component)
                end
            end
            lines[#lines + 1] = fit_marks(marks, width)
        end

        return fill_block(lines, width, height)
    end

    local function render_checkbox(node, width, height)
        local component = get_component(node)
        if component then
            self.focus_order[#self.focus_order + 1] = component
        end
        local focused = component and component.id == self.focus_id
        local checked = component and component.value == true or resolve(node.props.value) == true
        local sign = checked and "[x]" or "[ ]"
        local hl = checked and HL.active or HL.label
        if focused then
            hl = HL.ok
        end
        local marks = { { " " .. sign .. " " .. (node.props.label or ""), hl } }
        if component then
            marks[1][3] = function()
                component.value = not (component.value == true)
                self:redraw()
            end
        end
        return fill_block({ fit_marks(marks, width) }, width, height)
    end

    local function render_select(node, width, height)
        local component = get_component(node)
        if component then
            self.focus_order[#self.focus_order + 1] = component
        end
        local data = resolve(node.props.data) or {}
        if component then
            component.options = data
        end

        local focused = component and component:get_focused_node() or nil
        local focus_widget = component and component.id == self.focus_id
        local lines = {}

        for i = 1, height do
            local option = data[i]
            if option then
                local is_focused = focused ~= nil and option.id == focused.id
                local hl = is_focused and (focus_widget and HL.ok or HL.active) or HL.value
                local marks = { { is_focused and "▶ " or "  ", HL.marker }, { (option.text or tostring(option.id or "")), hl } }
                if component then
                    local captured = option
                    marks[#marks][3] = function()
                        component.focused_index = i
                        component.selected_id = captured.id
                        if node.props.on_change then
                            pcall(node.props.on_change, captured)
                        end
                        if node.props.on_select then
                            pcall(node.props.on_select, captured)
                        end
                        self:redraw()
                    end
                end
                lines[#lines + 1] = fit_marks(marks, width)
            else
                lines[#lines + 1] = blank_marks(width)
            end
        end

        return fill_block(lines, width, height)
    end

    local function render_button(node, width, height)
        local label = node.props.label or ""
        local component = get_component(node, node.props.id or ("__button__" .. label))
        if component then
            component.on_press = node.props.on_press
            component.label = label
            self.focus_order[#self.focus_order + 1] = component
        end
        local focused = component and component.id == self.focus_id
        local marks = { { label, focused and HL.ok or HL.button } }
        if node.props.on_press then
            marks[1][3] = function()
                node.props.on_press(component)
            end
        end
        return fill_block({ fit_marks(marks, width) }, width, height)
    end

    render_node = function(node, width, height)
        if not node then
            return fill_block({}, width, height)
        end

        local kind = node.kind
        if kind == "rows" then
            return render_rows(node, width, height)
        elseif kind == "box" then
            local direction = node.props.direction or "column"
            if direction == "row" then
                return render_columns(node, width, height)
            end
            return render_rows(node, width, height)
        elseif kind == "columns" then
            return render_columns(node, width, height)
        elseif kind == "paragraph" then
            return render_paragraph(node, width, height)
        elseif kind == "text_input" then
            return render_text_input(node, width, height)
        elseif kind == "checkbox" then
            return render_checkbox(node, width, height)
        elseif kind == "select" then
            return render_select(node, width, height)
        elseif kind == "button" then
            return render_button(node, width, height)
        elseif kind == "gap" then
            return fill_block({}, width, height)
        end

        return fill_block({}, width, height)
    end

    -- 1. Evaluate the tree.
    self.focus_order = {}
    local tree = type(self.tree) == "function" and self.tree() or self.tree
    local markup = render_node(tree, self.width, self.height)

    -- 2. Reconcile the focus cursor with the freshly built widget order.
    local found = false
    for index, component in ipairs(self.focus_order) do
        if component.id == self.focus_id then
            self.focus_index = index
            found = true
            break
        end
    end
    if not found then
        self.focus_index = math.min(math.max(1, self.focus_index), math.max(1, #self.focus_order))
        self.focus_id = self.focus_order[self.focus_index] and self.focus_order[self.focus_index].id
    end

    -- 3. Paint it.
    self.markup = markup
    api.nvim_set_option_value("modifiable", true, { buf = self.buf })
    volt.set_empty_lines(self.buf, self.height, self.width)
    api.nvim_set_option_value("modifiable", false, { buf = self.buf })

    volt.gen_data({
        {
            buf = self.buf,
            ns = self.ns,
            xpad = 0,
            layout = {
                {
                    name = "all",
                    lines = function()
                        return self.markup
                    end,
                },
            },
        },
    })
    volt.redraw(self.buf, "all")
end

-- ============================================================================
-- Test helpers
-- ============================================================================

--- Closes every open renderer.
function M.close_all()
    while #M.renderers > 0 do
        M.renderers[#M.renderers]:close()
    end
end

--- Concatenated, rendered text of every open renderer (for assertions).
--- @return string
function M.rendered_text()
    local parts = {}
    for _, renderer in ipairs(M.renderers) do
        for _, line in ipairs(renderer.markup or {}) do
            local text = {}
            for _, mark in ipairs(line) do
                text[#text + 1] = mark[1] or ""
            end
            parts[#parts + 1] = table.concat(text)
        end
    end
    return table.concat(parts, "\n")
end

return M
