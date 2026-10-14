-- OrchLaunch — editors for run configurations, toolchains, external tools and
-- CMake settings. Each editor is a modal form built from `nui-components`.
--
-- Every `open_*` function takes an optional existing object; when present the
-- form is pre-filled and saving updates it, otherwise a new object is added.

local UI = require("orchlaunch.ui")

local ERROR = vim.log.levels.ERROR

local M = {}

-- ============================================================================
-- Field helpers
-- ============================================================================

--- @param n table
--- @param id string
--- @param label string
--- @param value? string
--- @param opts? { size?: integer, flex?: integer, autofocus?: boolean }
local function input(n, id, label, value, opts)
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
local function check(n, id, label, value)
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
local function chooser(n, id, label, values, value)
    local nodes = {}
    for _, item in ipairs(values) do
        nodes[#nodes + 1] = n.option(item, { id = item })
    end

    return n.select({
        id = id,
        data = nodes,
        selected = { id = value },
        size = math.min(math.max(1, #values), 6),
        border_label = label,
        border_style = "rounded",
    })
end

--- A select whose options carry an id different from their display text.
--- @param n table
--- @param id string
--- @param label string
--- @param items { id: string, text: string }[]
--- @param value? string
local function chooser_items(n, id, label, items, value)
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

--- @param renderer table
--- @param id string
--- @return string
local function read_text(renderer, id)
    return renderer:get_component_by_id(id):get_current_value() or ""
end

--- @param renderer table
--- @param id string
--- @return boolean
local function read_bool(renderer, id)
    return renderer:get_component_by_id(id):get_current_value() == true
end

--- @param renderer table
--- @param id string
--- @param fallback? string
--- @return string?
local function read_choice(renderer, id, fallback)
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
local function trimmed(text)
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
local function target_field(n, targets, value, label, input_id, select_id)
    local input_node = input(n, input_id, label, value)

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
        chooser_items(n, select_id, " CMake target ", items, matched and value or "(custom)"),
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
local function read_target(renderer, targets, input_id, select_id)
    if targets and #targets > 0 then
        local choice = read_choice(renderer, select_id, "(custom)")
        if choice and choice ~= "(custom)" then
            return choice
        end
    end

    return trimmed(read_text(renderer, input_id))
end

-- ============================================================================
-- Before-launch helpers
-- ============================================================================

--- @param before? OrchBefore
--- @return boolean build
--- @return boolean install
--- @return string external
local function before_flags(before)
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
local function collect_before(renderer)
    local tools = {}

    if read_bool(renderer, "before_build") then
        tools[#tools + 1] = "build"
    end
    if read_bool(renderer, "before_install") then
        tools[#tools + 1] = "install"
    end
    for _, name in ipairs(UI.lines(read_text(renderer, "before_external"))) do
        tools[#tools + 1] = { type = "external", tool = name }
    end

    return { tools = tools }
end

--- @param n table
--- @param opts { build: boolean, install: boolean, external: string, title?: string }
local function before_fields(n, opts)
    return n.rows(
        { flex = 1, direction = "column" },
        check(n, "before_build", " Build before launch", opts.build),
        check(n, "before_install", " Install before launch", opts.install),
        n.gap(1),
        input(n, "before_external", " External tools before launch (one per line) ", opts.external, { size = 3 })
    )
end

-- ============================================================================
-- Shared dialog scaffolding
-- ============================================================================

--- Renders the footer hint and binds the save key (no action buttons).
--- @param n table
--- @param renderer table
--- @param save function
local function footer(n, renderer, save)
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
local function submit(renderer, collect, on_saved)
    local ok, err = pcall(collect)
    if not ok then
        UI.notify(tostring(err), ERROR)
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
local function upsert_configuration(state, existing_name, value)
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

-- ============================================================================
-- Native configuration
-- ============================================================================

--- @param existing? OrchNativeConfiguration
--- @param on_saved? function
--- @param opts? table
function M.open_native(existing, on_saved, opts)
    local n = UI.n()
    local config = require("orchlaunch.config")
    existing = existing or {}

    local console = existing.console or {}
    local build, install, external = before_flags(existing.before)
    local targets = require("orchlaunch.cmake").targets()

    local renderer = UI.renderer(vim.tbl_extend("force", { width = 108, height = 30 }, opts or {}))

    local left = n.rows(
        { flex = 1, direction = "column" },
        input(n, "name", " Name ", existing.name, { autofocus = true }),
        n.gap(1),
        target_field(n, targets, existing.target, " Target (CMake target or executable path) ", "target", "target_choice"),
        n.gap(1),
        input(n, "cwd", " Working directory ", existing.cwd),
        n.gap(1),
        input(n, "args", " Program arguments (one per line) ", UI.format_lines(existing.args), { size = 4 }),
        n.gap(1),
        input(n, "environment", " Environment (KEY=VALUE, one per line) ", UI.format_env(existing.environment), { size = 4 })
    )

    local right = n.rows(
        { flex = 1, direction = "column" },
        chooser(n, "console_mode", " Console (embedded/hidden/none) ", { "embedded", "hidden", "none" }, console.mode or "embedded"),
        n.gap(1),
        check(n, "keep_open", " Keep console open", console.keep_open ~= false),
        check(n, "clear_on_start", " Clear console on start", console.clear_on_start ~= false),
        n.gap(1),
        check(n, "inherit_env", " Inherit environment", existing.inherit_env ~= false),
        check(n, "sudo", " Run with sudo", existing.sudo == true),
        n.gap(1),
        before_fields(n, { build = build, install = install, external = external })
    )

    local function save()
        submit(renderer, function()
            local name = vim.trim(read_text(renderer, "name"))
            assert(name ~= "", "configuration name is required")

            local state = require("orchlaunch.state")
            if not existing.name and state.configuration(name) then
                error(("configuration already exists: %s"):format(name))
            end

            local value = config.native({
                name = name,
                target = read_target(renderer, targets, "target", "target_choice"),
                cwd = trimmed(read_text(renderer, "cwd")),
                args = UI.lines(read_text(renderer, "args")),
                inherit_env = read_bool(renderer, "inherit_env"),
                sudo = read_bool(renderer, "sudo"),
                environment = UI.parse_env(read_text(renderer, "environment")),
                console = {
                    mode = read_choice(renderer, "console_mode", console.mode or "embedded"),
                    keep_open = read_bool(renderer, "keep_open"),
                    clear_on_start = read_bool(renderer, "clear_on_start"),
                },
                before = collect_before(renderer),
            })

            upsert_configuration(state, existing.name, value)
        end, on_saved)
    end

    local body = function()
        return n.rows(
            { flex = 1, direction = "column" },
            n.columns({ flex = 1 }, left, n.gap(2), right),
            n.gap(1),
            footer(n, renderer, save)
        )
    end

    renderer:render(body)
    return renderer
end

-- ============================================================================
-- Remote debug configuration
-- ============================================================================

--- @param existing? OrchRemoteDebugConfiguration
--- @param on_saved? function
--- @param opts? table
function M.open_remote(existing, on_saved, opts)
    local n = UI.n()
    local config = require("orchlaunch.config")
    existing = existing or {}

    local build, install, external = before_flags(existing.before)
    local targets = require("orchlaunch.cmake").targets()
    local renderer = UI.renderer(vim.tbl_extend("force", { width = 90, height = 26 }, opts or {}))

    local fields = n.rows(
        { flex = 1, direction = "column" },
        input(n, "name", " Name ", existing.name, { autofocus = true }),
        n.gap(1),
        target_field(n, targets, existing.symbol, " Symbol (CMake target or executable path) ", "symbol", "symbol_choice"),
        n.gap(1),
        input(n, "connection", " Connection (host:port) ", existing.connection),
        n.gap(1),
        input(n, "adapter", " Adapter (gdb/lldb or executable path) ", existing.adapter),
        n.gap(1),
        before_fields(n, { build = build, install = install, external = external })
    )

    local function save()
        submit(renderer, function()
            local name = vim.trim(read_text(renderer, "name"))
            assert(name ~= "", "configuration name is required")

            local state = require("orchlaunch.state")
            if not existing.name and state.configuration(name) then
                error(("configuration already exists: %s"):format(name))
            end

            local value = config.remote_debug({
                name = name,
                symbol = read_target(renderer, targets, "symbol", "symbol_choice") or "",
                connection = read_text(renderer, "connection"),
                adapter = read_text(renderer, "adapter"),
                before = collect_before(renderer),
            })

            upsert_configuration(state, existing.name, value)
        end, on_saved)
    end

    local body = function()
        return n.rows(
            { flex = 1, direction = "column" },
            fields,
            n.gap(1),
            footer(n, renderer, save)
        )
    end

    renderer:render(body)
    return renderer
end

-- ============================================================================
-- Compound configuration
-- ============================================================================

--- @param existing? OrchCompoundConfiguration
--- @param on_saved? function
--- @param opts? table
function M.open_compound(existing, on_saved, opts)
    local n = UI.n()
    local config = require("orchlaunch.config")
    existing = existing or {}

    local renderer = UI.renderer(vim.tbl_extend("force", { width = 80, height = 20 }, opts or {}))

    local fields = n.rows(
        { flex = 1, direction = "column" },
        input(n, "name", " Name ", existing.name, { autofocus = true }),
        n.gap(1),
        input(n, "configurations", " Configurations (one per line) ", UI.format_lines(existing.configurations), { size = 6 })
    )

    local function save()
        submit(renderer, function()
            local name = vim.trim(read_text(renderer, "name"))
            assert(name ~= "", "configuration name is required")

            local state = require("orchlaunch.state")
            if not existing.name and state.configuration(name) then
                error(("configuration already exists: %s"):format(name))
            end

            local value = config.compound({
                name = name,
                configurations = UI.lines(read_text(renderer, "configurations")),
            })

            upsert_configuration(state, existing.name, value)
        end, on_saved)
    end

    local body = function()
        return n.rows(
            { flex = 1, direction = "column" },
            fields,
            n.gap(1),
            footer(n, renderer, save)
        )
    end

    renderer:render(body)
    return renderer
end

-- ============================================================================
-- External tool
-- ============================================================================

--- @param existing? OrchExternalTool
--- @param on_saved? function
function M.open_external_tool(existing, on_saved)
    local n = UI.n()
    local config = require("orchlaunch.config")
    existing = existing or {}

    local renderer = UI.renderer({ width = 96, height = 24 })

    local left = n.rows(
        { flex = 1, direction = "column" },
        input(n, "name", " Name ", existing.name, { autofocus = true }),
        n.gap(1),
        input(n, "program", " Program ", existing.program),
        n.gap(1),
        input(n, "cwd", " Working directory ", existing.cwd),
        n.gap(1),
        input(n, "args", " Arguments (one per line) ", UI.format_lines(existing.args), { size = 5 })
    )

    local right = n.rows(
        { flex = 1, direction = "column" },
        check(n, "inherit_env", " Inherit environment", existing.inherit_env ~= false),
        check(n, "sudo", " Run with sudo", existing.sudo == true),
        n.gap(1),
        input(n, "environment", " Environment (KEY=VALUE, one per line) ", UI.format_env(existing.environment), { size = 6 })
    )

    local function save()
        submit(renderer, function()
            local name = vim.trim(read_text(renderer, "name"))
            assert(name ~= "", "external tool name is required")

            local state = require("orchlaunch.state")
            if not existing.name and state.external_tool(name) then
                error(("external tool already exists: %s"):format(name))
            end

            local value = config.external_tool({
                name = name,
                program = read_text(renderer, "program"),
                cwd = trimmed(read_text(renderer, "cwd")),
                args = UI.lines(read_text(renderer, "args")),
                inherit_env = read_bool(renderer, "inherit_env"),
                sudo = read_bool(renderer, "sudo"),
                environment = UI.parse_env(read_text(renderer, "environment")),
            })

            if existing.name then
                state.update_external_tool(existing.name, value)
            else
                state.add_external_tool(value)
            end
        end, on_saved)
    end

    local body = function()
        return n.rows(
            { flex = 1, direction = "column" },
            n.columns({ flex = 1 }, left, n.gap(2), right),
            n.gap(1),
            footer(n, renderer, save)
        )
    end

    renderer:render(body)
    return renderer
end

-- ============================================================================
-- Toolchain
-- ============================================================================

--- @param existing? OrchToolchain
--- @param on_saved? function
function M.open_toolchain(existing, on_saved)
    local n = UI.n()
    local config = require("orchlaunch.config")
    existing = existing or {}

    local renderer = UI.renderer({ width = 90, height = 22 })

    local fields = n.rows(
        { flex = 1, direction = "column" },
        input(n, "name", " Name ", existing.name, { autofocus = true }),
        n.gap(1),
        chooser(n, "type", " Type (system/unix/msvc) ", { "system", "unix", "msvc" }, existing.type or "system"),
        n.gap(1),
        input(n, "cmake", " CMake ", existing.cmake),
        n.gap(1),
        input(n, "c", " C compiler ", existing.c),
        n.gap(1),
        input(n, "cxx", " C++ compiler ", existing.cxx),
        n.gap(1),
        input(n, "debugger", " Debugger (gdb/lldb/lldb-vscode) ", existing.debugger)
    )

    local function save()
        submit(renderer, function()
            local name = vim.trim(read_text(renderer, "name"))
            assert(name ~= "", "toolchain name is required")

            local state = require("orchlaunch.state")
            if not existing.name and state.toolchain(name) then
                error(("toolchain already exists: %s"):format(name))
            end

            local value = config.toolchain({
                name = name,
                type = read_choice(renderer, "type", existing.type or "system"),
                cmake = read_text(renderer, "cmake"),
                c = read_text(renderer, "c"),
                cxx = read_text(renderer, "cxx"),
                debugger = read_text(renderer, "debugger"),
            })

            if existing.name then
                state.update_toolchain(existing.name, value)
            else
                state.add_toolchain(value)
            end
        end, on_saved)
    end

    local body = function()
        return n.rows(
            { flex = 1, direction = "column" },
            fields,
            n.gap(1),
            footer(n, renderer, save)
        )
    end

    renderer:render(body)
    return renderer
end

-- ============================================================================
-- CMake profile
-- ============================================================================

--- Opens the CMake profile editor (raw nui.nvim).
---
--- Manual profiles are fully editable. Preset-derived profiles (carrying a
--- `kind`) are imported from CMakePresets.json / CMakeUserPresets.json and are
--- shown read-only — they cannot be created or edited here.
--- @param existing? OrchCMakeProfile
--- @param on_saved? function
--- @param opts? table
--- @return table popup
function M.open_cmake(existing, on_saved, opts)
    return require("orchlaunch.ui.cmake_profile").open(existing, on_saved, opts)
end

--- Edits the project-wide CMake project directory (`[cmake] source_dir`).
--- @param on_saved? function
--- @param opts? table
function M.open_cmake_project(on_saved, opts)
    local n = UI.n()
    local state = require("orchlaunch.state")

    local renderer = UI.renderer(vim.tbl_extend("force", {
        width = math.max(50, math.min(vim.o.columns - 4, 84)),
        height = 15,
    }, opts or {}))

    local function save()
        submit(renderer, function()
            local value = vim.trim(read_text(renderer, "source_dir"))
            state.set_cmake_source_dir(value ~= "" and value or nil)
        end, on_saved)
    end

    local content = n.rows(
        { flex = 1, direction = "column" },
        n.paragraph({
            id = "cmake_project_hint",
            lines = table.concat({
                "Directory holding CMakeLists.txt and CMakePresets.json.",
                "Leave empty (or \"${workspace}\") to use the .orch project root.",
                ("Resolved: %s"):format(state.cmake_source_dir()),
            }, "\n"),
            max_lines = 3,
        }),
        n.gap(1),
        input(n, "source_dir", " CMake project directory ", state.cmake_source_dir_raw(), { autofocus = true }),
        n.gap(1),
        footer(n, renderer, save)
    )

    renderer:render(content)
    return renderer
end

return M
