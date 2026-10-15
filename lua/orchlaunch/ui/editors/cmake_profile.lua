-- OrchLaunch — CMake profile editor built on the Volt UI engine.
--
-- Manual profiles own every build setting; a new profile starts from sane
-- defaults (generator = Ninja, build type = Debug). Nothing preset-related is
-- exposed here.
--
-- Preset-derived profiles (those with `kind`) are imported from
-- CMakePresets.json / CMakeUserPresets.json and any included files. They are
-- read-only: manage them in the JSON files and re-import through the list.

local UI = require("orchlaunch.ui")

local ERROR = vim.log.levels.ERROR
local WARN = vim.log.levels.WARN

local M = {}

--- Common CMake generators offered in the generator select.
local GENERATORS = {
    "Ninja",
    "Ninja Multi-Config",
    "Unix Makefiles",
    "MinGW Makefiles",
    "MSYS Makefiles",
    "NMake Makefiles",
    "NMake Makefiles JOM",
    "Visual Studio 17 2022",
    "Visual Studio 16 2019",
    "Xcode",
}

local BUILD_TYPES = { "Debug", "Release", "RelWithDebInfo", "MinSizeRel" }

--- Preset references preserved on legacy profiles but hidden from the editor.
local PRESERVED_KEYS = {
    "kind",
    "configure_preset",
    "build_preset",
    "test_preset",
    "package_preset",
    "workflow_preset",
}

-- ============================================================================
-- Option lists
-- ============================================================================

--- @param state table
--- @return { id: string, text: string }[]
local function toolchain_items(state)
    local items = { { id = "", text = "(none)" } }
    for _, toolchain in ipairs(state.toolchains()) do
        items[#items + 1] = { id = toolchain.name, text = toolchain.name }
    end
    return items
end

--- @param current? string
--- @return { id: string, text: string }[]
local function generator_items(current)
    local items = {}
    local seen = {}

    if current and current ~= "" then
        items[#items + 1] = { id = current, text = current .. "  (current)" }
        seen[current] = true
    end

    for _, generator in ipairs(GENERATORS) do
        if not seen[generator] then
            items[#items + 1] = { id = generator, text = generator }
            seen[generator] = true
        end
    end

    return items
end

--- @param current? string
--- @return { id: string, text: string }[]
local function build_type_items(current)
    local items = {}

    if current and current ~= "" and not vim.tbl_contains(BUILD_TYPES, current) then
        items[#items + 1] = { id = current, text = current .. "  (custom)" }
    end

    for _, build_type in ipairs(BUILD_TYPES) do
        items[#items + 1] = { id = build_type, text = build_type }
    end

    return items
end

--- @param value? string
--- @return string?
local function trimmed(value)
    if type(value) ~= "string" then
        return nil
    end
    value = vim.trim(value)
    return value ~= "" and value or nil
end

-- ============================================================================
-- Read-only preset description
-- ============================================================================

--- @param state table
--- @param profile table
--- @return string[]
local function preset_lines(state, profile)
    local presets = require("orchlaunch.presets")
    local discovered = state.presets()
    local out = {}

    out[#out + 1] = ("  Imported from a %s preset."):format(profile.kind)

    if profile.kind == "configure" and profile.configure_preset then
        out[#out + 1] = ("  configurePreset = %s"):format(profile.configure_preset)
        local resolved = discovered and presets.resolve(discovered, "configure", profile.configure_preset)
        if resolved then
            if resolved.generator then
                out[#out + 1] = "    generator   = " .. tostring(resolved.generator)
            end
            if resolved.binaryDir then
                out[#out + 1] = "    binaryDir   = " .. tostring(resolved.binaryDir)
            end
            local cache = resolved.cacheVariables or {}
            if cache.CMAKE_BUILD_TYPE then
                out[#out + 1] = "    build type  = " .. tostring(cache.CMAKE_BUILD_TYPE)
            end
        end
    elseif profile.kind == "build" and profile.build_preset then
        out[#out + 1] = ("  buildPreset = %s"):format(profile.build_preset)
        if profile.configure_preset then
            out[#out + 1] = ("  configurePreset = %s"):format(profile.configure_preset)
        end
        local resolved = discovered and presets.resolve(discovered, "build", profile.build_preset)
        if resolved and resolved.configuration then
            out[#out + 1] = "    configuration = " .. tostring(resolved.configuration)
        end
    end

    out[#out + 1] = ""
    out[#out + 1] = "  Generator, directories, compiler and cache variables come from"
    out[#out + 1] = "  the preset. Edit the preset file and re-import to change them."
    out[#out + 1] = "  Only the environment can be adjusted per project."

    return out
end

-- ============================================================================
-- Editor
-- ============================================================================

--- Opens the CMake profile editor.
--- @param existing? OrchCMakeProfile
--- @param on_saved? function
--- @param opts? table
--- @return table renderer
function M.open(existing, on_saved, opts)
    opts = opts or {}

    local n = UI.n()
    local state = require("orchlaunch.state")

    existing = existing or {}
    local readonly = existing.kind ~= nil
    local original_name = existing.name

    -- The form is taller than it is wide; size the float to the terminal while
    -- keeping it usable on short screens.
    local win_height = math.max(14, math.min(vim.o.lines - 4, readonly and 20 or 30))

    local renderer

    local fields = readonly
            and {
                { id = "name", label = "Name", kind = "string", readonly = true },
                { id = "enabled", label = "Enabled", kind = "bool", readonly = true },
                { id = "kind", label = "Imported from", kind = "string", readonly = true },
                { id = "configure_preset", label = "Configure preset", kind = "string", readonly = true },
                { id = "build_preset", label = "Build preset", kind = "string", readonly = true },
                { id = "test_preset", label = "Test preset", kind = "string", readonly = true },
                { id = "package_preset", label = "Package preset", kind = "string", readonly = true },
                { id = "workflow_preset", label = "Workflow preset", kind = "string", readonly = true },
                { id = "environment", label = "Environment", kind = "env", readonly = true },
            }
        or {
            { id = "name", label = "Name", kind = "string" },
            { id = "enabled", label = "Enabled", kind = "bool" },
            { id = "toolchain", label = "Toolchain", kind = "select" },
            { id = "generator", label = "Generator", kind = "select" },
            { id = "build_type", label = "Build type", kind = "select" },
            { id = "build_dir", label = "Build dir", kind = "string" },
            { id = "install_dir", label = "Install dir", kind = "string" },
            { id = "configure_args", label = "Configure args", kind = "lines" },
            { id = "build_args", label = "Build args", kind = "lines" },
            { id = "install_args", label = "Install args", kind = "lines" },
            { id = "definitions", label = "Definitions", kind = "env" },
            { id = "environment", label = "Environment", kind = "env" },
        }

    local kinds = {}
    for _, field in ipairs(fields) do
        kinds[field.id] = field.kind
    end

    local function title_label(name)
        return ("  CMake profile: %s"):format(name ~= "" and name or "new")
    end

    -- A signal drives the live title line; another drives the summary paragraph.
    local title = n.create_signal({ text = title_label(existing.name or "") })
    local summary = n.create_signal({ text = "" })

    -- Forward declarations (assigned once the renderer exists).
    local refresh_summary
    local is_closed = function()
        return false
    end

    local function set_title(name)
        if is_closed() then
            return
        end
        title.text = title_label(name)
    end

    local function refresh_title()
        local value = renderer and renderer:get_component_by_id("name")
        if value then
            set_title(value:get_current_value() or "")
        end
    end

    -- ============================================================================
    -- Component helpers
    -- ============================================================================

    local function cell(component)
        return n.rows({ flex = 1, direction = "column" }, component)
    end

    local function input(id, label, value, extra)
        extra = extra or {}
        return n.text_input({
            id = id,
            border_label = label,
            border_style = "rounded",
            value = value or "",
            size = extra.size or 1,
            placeholder = extra.placeholder,
            autofocus = extra.autofocus,
            on_change = extra.on_change or function() end,
        })
    end

    local function check(id, label, value, on_change)
        return n.checkbox({
            id = id,
            label = label,
            value = value == true,
            on_change = on_change or function() end,
        })
    end

    local function select(id, label, items, value)
        local nodes = {}
        for _, item in ipairs(items) do
            nodes[#nodes + 1] = n.option(item.text, { id = item.id })
        end

        return n.select({
            id = id,
            data = nodes,
            selected = { id = value or "" },
            size = math.min(math.max(1, #items), 2),
            border_label = label,
            border_style = "rounded",
            on_select = function()
                vim.schedule(refresh_summary)
            end,
        })
    end

    local function heading(title_text)
        return n.paragraph({ lines = n.line(n.text(" " .. title_text, "Title")) })
    end

    -- ============================================================================
    -- Value reads
    -- ============================================================================

    local function read_field(id)
        local kind = kinds[id]
        local component = renderer and renderer:get_component_by_id(id)

        if not component then
            return existing[id]
        end

        local value = component:get_current_value()

        if kind == "bool" then
            return value == true
        end
        if kind == "select" then
            return type(value) == "table" and value.id or value
        end
        return value
    end

    local function field_meta()
        local out = {}
        for _, field in ipairs(fields) do
            out[#out + 1] = { id = field.id, kind = field.kind, label = field.label, readonly = field.readonly }
        end
        return out
    end

    -- ============================================================================
    -- Persistence
    -- ============================================================================

    local closed = false

    is_closed = function()
        return closed
    end

    local function close()
        if closed then
            return
        end
        closed = true
        -- Unmount on the next tick so any pending component repaints (queued via
        -- `vim.schedule`) run against live buffers before the windows go away.
        vim.schedule(function()
            pcall(function()
                renderer:close()
            end)
        end)
    end

    local function collect()
        local name = vim.trim(read_field("name") or "")
        if name == "" then
            error("a profile name is required", 0)
        end

        local clash = state.cmake_profile(name)
        if clash and (original_name == nil or clash.name ~= original_name) then
            error(("a profile named %q already exists"):format(name), 0)
        end

        local profile = {
            name = name,
            enabled = read_field("enabled") == true,
            toolchain = trimmed(read_field("toolchain")),
            generator = trimmed(read_field("generator")),
            build_type = trimmed(read_field("build_type")),
            build_dir = trimmed(read_field("build_dir")),
            install_dir = trimmed(read_field("install_dir")),
            configure_args = UI.lines(read_field("configure_args")),
            build_args = UI.lines(read_field("build_args")),
            install_args = UI.lines(read_field("install_args")),
            definitions = UI.parse_env(read_field("definitions")),
            environment = UI.parse_env(read_field("environment")),
        }

        for _, key in ipairs(PRESERVED_KEYS) do
            if existing[key] ~= nil then
                profile[key] = existing[key]
            end
        end

        return profile
    end

    local function save()
        if readonly then
            UI.notify("imported from CMakePresets.json — nothing to save", WARN)
            return
        end

        local ok, profile = pcall(collect)
        if not ok then
            UI.notify(tostring(profile), ERROR)
            if renderer then
                renderer:focus()
            end
            return
        end

        if original_name then
            state.update_cmake_profile(original_name, profile)
        else
            state.add_cmake_profile(profile)
        end
        state.save()
        close()
    end

    -- ============================================================================
    -- Reactive summary
    -- ============================================================================

    local function summary_text()
        local bits = {}

        local generator = trimmed(read_field("generator"))
        if generator then
            bits[#bits + 1] = "generator " .. generator
        end

        local build_type = trimmed(read_field("build_type"))
        if build_type then
            bits[#bits + 1] = "build type " .. build_type
        end

        local toolchain = trimmed(read_field("toolchain"))
        if toolchain then
            bits[#bits + 1] = "toolchain " .. toolchain
        end

        bits[#bits + 1] = read_field("enabled") == true and "enabled" or "disabled"

        return "  " .. table.concat(bits, "  ·  ")
    end

    refresh_summary = function()
        if closed then
            return
        end
        local ok, text = pcall(summary_text)
        if ok then
            summary.text = text
        end
    end

    -- ============================================================================
    -- Layout
    -- ============================================================================

    local function footer()
        renderer:add_mappings({
            { mode = { "n", "i" }, key = "<C-s>", handler = save },
        })
        renderer._save = save

        return n.paragraph({ align = "center", lines = "  <C-s> save    <Esc> cancel  " })
    end

    local function manual_body()
        local left = n.rows(
            { flex = 1, direction = "column" },
            heading("Profile"),
            input("name", " Name ", existing.name, {
                autofocus = true,
                placeholder = "e.g. Debug",
                on_change = function(value)
                    set_title(value)
                    refresh_summary()
                end,
            }),
            n.gap(1),
            check("enabled", " Enabled", existing.enabled ~= false, refresh_summary),
            n.gap(1),
            heading("Build"),
            select(
                "generator",
                " Generator ",
                generator_items(existing.generator or "Ninja"),
                existing.generator or "Ninja"
            ),
            select(
                "build_type",
                " Build type ",
                build_type_items(existing.build_type or "Debug"),
                existing.build_type or "Debug"
            ),
            input("build_dir", " Build directory ", existing.build_dir, { placeholder = "build" }),
            input("install_dir", " Install directory ", existing.install_dir, { placeholder = "install" })
        )

        local right = n.rows(
            { flex = 1, direction = "column" },
            heading("Toolchain"),
            select("toolchain", " Toolchain ", toolchain_items(state), existing.toolchain),
            n.gap(1),
            heading("Arguments"),
            input("configure_args", " Configure args (one per line) ", UI.format_lines(existing.configure_args)),
            input("build_args", " Build args (one per line) ", UI.format_lines(existing.build_args)),
            input("install_args", " Install args (one per line) ", UI.format_lines(existing.install_args)),
            n.gap(1),
            heading("Variables"),
            input("definitions", " Definitions (-DKEY=VALUE, one per line) ", UI.format_env(existing.definitions)),
            input("environment", " Environment (KEY=VALUE, one per line) ", UI.format_env(existing.environment))
        )

        return n.rows(
            { flex = 1, direction = "column" },
            n.gap(1),
            n.paragraph({ id = "title", lines = title.text }),
            n.paragraph({ id = "summary", lines = summary.text }),
            n.gap(1),
            n.columns({ size = math.max(10, win_height - 6) }, cell(left), n.gap(3), cell(right)),
            n.gap(1),
            footer()
        )
    end

    local function imported_body()
        local environment = UI.format_env(existing.environment)
        if environment == "" then
            environment = "  (empty)"
        end

        return n.rows(
            { flex = 1, direction = "column" },
            n.gap(1),
            n.paragraph({ id = "title", lines = title.text }),
            n.box({ flex = 2 }),
            n.paragraph({ id = "preset", lines = table.concat(preset_lines(state, existing), "\n") }),
            n.box({ flex = 1 }),
            n.paragraph({ align = "center", lines = "  <Esc> close  ", autofocus = true })
        )
    end

    -- ============================================================================
    -- Renderer
    -- ============================================================================

    renderer = UI.renderer({
        width = math.max(80, math.min(vim.o.columns - 4, 112)),
        height = win_height,
        on_mount = function()
            local component = renderer:get_component_by_id("name") or renderer:get_component_by_id("environment")
            if component then
                renderer.winid = component.winid
                renderer.bufnr = component.bufnr
            end
        end,
        on_unmount = function()
            if on_saved then
                on_saved()
            end
        end,
    })

    renderer:render(readonly and imported_body() or manual_body())

    -- Route the editor's own close keys through `close()` so `on_saved` fires.
    renderer:add_mappings({
        { mode = { "n" }, key = "<Esc>", handler = close },
        { mode = { "n" }, key = "q", handler = close },
    })

    vim.schedule(function()
        if not readonly then
            refresh_title()
            refresh_summary()
        end
    end)

    -- ============================================================================
    -- Scripting hooks (`popup.orch`)
    -- ============================================================================

    local values = setmetatable({}, {
        __index = function(_, key)
            return read_field(key)
        end,
    })

    renderer.orch = {
        readonly = readonly,
        fields = field_meta(),
        values = values,
        refresh = function()
            renderer:redraw()
        end,
        focus = function()
            renderer:focus()
        end,
        save = save,
        close = close,
        get = read_field,
        index_of = function(id)
            for index, field in ipairs(fields) do
                if field.id == id then
                    return index
                end
            end
        end,
        set = function(id, value)
            local kind = kinds[id]
            local component = renderer:get_component_by_id(id)
            if not component then
                return
            end

            if kind == "bool" then
                component:set_current_value(value == true)
            elseif kind == "select" then
                component:set_current_value({ id = value })
            else
                component:set_current_value(value or "")
                if component.bufnr and vim.api.nvim_buf_is_valid(component.bufnr) then
                    vim.api.nvim_buf_set_lines(component.bufnr, 0, -1, false, vim.split(value or "", "\n"))
                end
            end

            if id == "name" then
                set_title(value or "")
            end
            refresh_summary()
        end,
        activate = function(field)
            if not field then
                return
            end
            if readonly or field.readonly then
                UI.notify("imported from CMakePresets.json — edit the preset file", WARN)
                return
            end

            local component = renderer:get_component_by_id(field.id)
            if field.kind == "bool" and component then
                component:set_current_value(not (component:get_current_value() == true))
                refresh_summary()
                return
            end
            if component then
                component:focus()
            end
            return component
        end,
    }

    return renderer
end

return M
