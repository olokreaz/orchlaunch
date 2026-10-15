-- OrchLaunch — shared form primitives for the Volt editors.
--
-- Every editor builds its fields, reads them back and saves through these
-- helpers so the layout and save plumbing stay identical across windows.

local UI = require("orchlaunch.ui")

local ERROR = vim.log.levels.ERROR

local M = {}

-- ============================================================================
-- Field builders
-- ============================================================================

--- @param n table
--- @param id string
--- @param label string
--- @param value? string
--- @param opts? { size?: integer, flex?: integer, autofocus?: boolean }
function M.input(n, id, label, value, opts)
    opts = opts or {}

    return n.text_input({
        id = id,
        border_label = label,
        border_style = "rounded",
        value = value or "",
        size = opts.size or 1,
        flex = opts.flex,
        autofocus = opts.autofocus,
    })
end

--- @param n table
--- @param id string
--- @param label string
--- @param value? boolean
function M.check(n, id, label, value)
    return n.checkbox({
        id = id,
        label = label,
        value = value == true,
    })
end

--- @param n table
--- @param id string
--- @param label string
--- @param values string[]
--- @param value? string
function M.chooser(n, id, label, values, value)
    local nodes = {}
    for _, item in ipairs(values) do
        nodes[#nodes + 1] = n.option(item, { id = item })
    end

    return n.select({
        id = id,
        data = nodes,
        selected = { id = value or "" },
        size = math.min(math.max(1, #values), 6),
        border_label = label,
        border_style = "rounded",
    })
end

--- @param n table
--- @param id string
--- @param label string
--- @param items { id: string, text: string }[]
--- @param value? string
function M.chooser_items(n, id, label, items, value)
    local nodes = {}
    for _, item in ipairs(items) do
        nodes[#nodes + 1] = n.option(item.text, { id = item.id })
    end

    return n.select({
        id = id,
        data = nodes,
        selected = { id = value },
        size = math.min(math.max(1, #items), 6),
        border_label = label,
        border_style = "rounded",
    })
end

-- ============================================================================
-- Value reads
-- ============================================================================

--- @param renderer table
--- @param id string
--- @return string
function M.read_text(renderer, id)
    local component = renderer:get_component_by_id(id)
    return component and component:get_current_value() or ""
end

--- @param renderer table
--- @param id string
--- @return boolean
function M.read_bool(renderer, id)
    local component = renderer:get_component_by_id(id)
    return component ~= nil and component:get_current_value() == true
end

--- @param renderer table
--- @param id string
--- @param fallback? string
--- @return string?
function M.read_choice(renderer, id, fallback)
    local component = renderer:get_component_by_id(id)
    if not component then
        return fallback
    end

    local value = component:get_current_value()
    if type(value) == "table" and value.id then
        return value.id
    end

    return fallback
end

--- @param text? string
--- @return string?
function M.trimmed(text)
    local value = vim.trim(text or "")
    return value ~= "" and value or nil
end

-- ============================================================================
-- Target picker
-- ============================================================================

--- Builds a target field: a CMake-target select plus a free-form path input
--- when targets are known, or a plain input otherwise.
--- @param n table
--- @param targets OrchCMakeTarget[]?
--- @param value? string
--- @param label string
--- @param input_id string
--- @param select_id string
function M.target_field(n, targets, value, label, input_id, select_id)
    local input_node = M.input(n, input_id, label, value)

    if not targets or #targets == 0 then
        return input_node
    end

    local items = { { id = "(custom)", text = "(executable path…)" } }
    local matched = false
    for _, target in ipairs(targets) do
        local suffix = target.type == "EXECUTABLE" and "  (executable)" or ""
        items[#items + 1] = { id = target.name, text = target.name .. suffix }
        if target.name == value then
            matched = true
        end
    end

    return n.rows(
        { flex = 1, direction = "column" },
        M.chooser_items(n, select_id, " CMake target ", items, matched and value or "(custom)"),
        n.gap(1),
        input_node
    )
end

--- Reads a target value produced by `target_field`.
--- @param renderer table
--- @param targets OrchCMakeTarget[]?
--- @param input_id string
--- @param select_id string
--- @return string?
function M.read_target(renderer, targets, input_id, select_id)
    if targets and #targets > 0 then
        local choice = M.read_choice(renderer, select_id, "(custom)")
        if choice and choice ~= "(custom)" then
            return choice
        end
    end

    return M.trimmed(M.read_text(renderer, input_id))
end

-- ============================================================================
-- Before-launch helpers
-- ============================================================================

--- @param before? OrchBefore
--- @return boolean build
--- @return boolean install
--- @return string external
function M.before_flags(before)
    local build, install = false, false
    local external = {}

    for _, item in ipairs(before and before.tools or {}) do
        local kind = type(item) == "table" and item.type or item
        if kind == "build" then
            build = true
        elseif kind == "install" then
            install = true
        elseif kind == "external" then
            external[#external + 1] = (type(item) == "table" and item.tool) or ""
        end
    end

    return build, install, table.concat(external, "\n")
end

--- @param renderer table
--- @return OrchBefore
function M.collect_before(renderer)
    local tools = {}

    if M.read_bool(renderer, "before_build") then
        tools[#tools + 1] = "build"
    end
    if M.read_bool(renderer, "before_install") then
        tools[#tools + 1] = "install"
    end
    for _, name in ipairs(UI.lines(M.read_text(renderer, "before_external"))) do
        tools[#tools + 1] = { type = "external", tool = name }
    end

    return { tools = tools }
end

--- @param n table
--- @param opts { build: boolean, install: boolean, external: string }
function M.before_fields(n, opts)
    return n.rows(
        { flex = 1, direction = "column" },
        M.check(n, "before_build", " Build before launch", opts.build),
        M.check(n, "before_install", " Install before launch", opts.install),
        n.gap(1),
        M.input(n, "before_external", " External tools before launch (one per line) ", opts.external, { size = 3 })
    )
end

-- ============================================================================
-- Shared dialog scaffolding
-- ============================================================================

--- Renders the footer hint and binds the save key (no action buttons).
--- @param n table
--- @param renderer table
--- @param save function
function M.footer(n, renderer, save)
    renderer:add_mappings({
        { mode = { "n", "i" }, key = "<C-s>", handler = save },
    })
    renderer._save = save

    return n.paragraph({ align = "center", lines = "  <C-s> save    <Esc> cancel  " })
end

--- Runs `collect`, persists the project and closes the renderer.
--- @param renderer table
--- @param collect function
--- @param on_saved? function
function M.submit(renderer, collect, on_saved)
    local ok, err = pcall(collect)
    if not ok then
        UI.notify(tostring(err), vim.log.levels.ERROR)
        return
    end

    require("orchlaunch.state").save()
    renderer:close()
    if on_saved then
        on_saved()
    end
end

--- Adds or updates `value` in the given collection.
--- @param state table
--- @param existing_name? string
--- @param value table
function M.upsert_configuration(state, existing_name, value)
    if existing_name then
        state.update_configuration(existing_name, value)

        if existing_name ~= value.name then
            local active = require("orchlaunch.active")
            if active.get(state.root()) == existing_name then
                active.set(state.root(), value.name)
            end
        end
    else
        state.add_configuration(value)
    end
end

return M
