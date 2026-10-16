-- OrchLaunch — CMake profile editor reimplemented on fibrous.
--
-- Prototype on purpose: the kit/Volt editor stays in place as the fallback (and
-- for the kit list dialog), while this module is the fibrous take on the same
-- form so the two stacks can be compared. `M.available()` reports whether
-- fibrous is installed; `open` falls back to the kit editor when it is not.
--
-- Manual profiles own every build setting; a new profile starts from sane
-- defaults (generator = Ninja, build type = Debug). Preset-derived profiles
-- (those with `kind`) are read-only and only expose their preset description.

local UI = require("orchlaunch.ui")

local ERROR = vim.log.levels.ERROR
local WARN = vim.log.levels.WARN

-- Flash-style jump: label each field with a letter and hop straight to it. The
-- labels are drawn as overlay virt_text on the canvas, so they need a namespace
-- (module-level: one namespace serves every editor instance).
local flash_ns = vim.api.nvim_create_namespace("orchlaunch_fibrous_flash")

local M = {}

--- @return boolean
function M.available()
    return (pcall(require, "fibrous")) == true
end

--- Common CMake generators offered in the generator dropdown.
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

--- @param value? string
--- @return string?
local function trimmed(value)
    if type(value) ~= "string" then
        return nil
    end
    value = vim.trim(value)
    return value ~= "" and value or nil
end

--- @param current? string
--- @return string[]
local function with_current(list, current)
    local out = {}
    local seen = {}
    if current and current ~= "" and not vim.tbl_contains(list, current) then
        out[#out + 1] = current
        seen[current] = true
    end
    for _, item in ipairs(list) do
        if not seen[item] then
            out[#out + 1] = item
            seen[item] = true
        end
    end
    return out
end

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

--- Manual-profile field definitions. `height` is the border-box height in rows:
--- a single-line field is 3 (top border + 1 content row + bottom border); the
--- textareas are 4 (2 content rows).
local MANUAL_FIELDS = {
    { id = "name", kind = "string", height = 3, singleline = true },
    { id = "toolchain", kind = "select" },
    { id = "generator", kind = "select" },
    { id = "build_type", kind = "select" },
    { id = "build_dir", kind = "string", height = 3, singleline = true },
    { id = "install_dir", kind = "string", height = 3, singleline = true },
    { id = "configure_args", kind = "lines", height = 4 },
    { id = "build_args", kind = "lines", height = 4 },
    { id = "install_args", kind = "lines", height = 4 },
    { id = "definitions", kind = "env", height = 4 },
    { id = "environment", kind = "env", height = 4 },
}

--- Opens the fibrous CMake profile editor.
--- @param existing? OrchCMakeProfile
--- @param on_saved? function
--- @param opts? table
--- @return table handle
function M.open(existing, on_saved, opts)
    local ok, nr = pcall(require, "fibrous")
    if not ok then
        return require("orchlaunch.ui.editors.cmake_profile").open(existing, on_saved, opts)
    end

    local ui = nr.ui
    local state = require("orchlaunch.state")

    -- Opt-in trace for the functional suite (tests/func): when ORCH_FUNC_LOG is
    -- set, key handling and map application are recorded there. No-op otherwise.
    local trace = vim.env.ORCH_FUNC_LOG
    local function dlog(line)
        if not trace then
            return
        end
        local f = io.open(trace, "a")
        if f then
            f:write("module " .. line .. "\n")
            f:close()
        end
    end

    existing = existing or {}
    local readonly = existing.kind ~= nil
    local original_name = existing.name

    local initial = {
        name = existing.name or "",
        toolchain = existing.toolchain or "(none)",
        generator = existing.generator or "Ninja",
        build_type = existing.build_type or "Debug",
        build_dir = existing.build_dir or "",
        install_dir = existing.install_dir or "",
        configure_args = UI.format_lines(existing.configure_args),
        build_args = UI.format_lines(existing.build_args),
        install_args = UI.format_lines(existing.install_args),
        definitions = UI.format_env(existing.definitions),
        environment = UI.format_env(existing.environment),
    }

    local toolchain_options = { "(none)" }
    for _, toolchain in ipairs(state.toolchains()) do
        toolchain_options[#toolchain_options + 1] = toolchain.name
    end

    local fields_meta = {}
    if readonly then
        for _, id in ipairs({ "name", "kind", "configure_preset", "build_preset", "test_preset", "package_preset", "workflow_preset", "environment" }) do
            fields_meta[#fields_meta + 1] = { id = id, kind = id == "environment" and "env" or "string", readonly = true }
        end
    else
        for _, def in ipairs(MANUAL_FIELDS) do
            fields_meta[#fields_meta + 1] = { id = def.id, kind = def.kind, readonly = false }
        end
    end

    local form --- state handle, assigned on first render
    local handle
    local closed = false
    local mapped = {}

    --- @param id string
    --- @return string? value
    local function get(id)
        return form and (form.get() or {})[id]
    end

    --- @param id string
    --- @param value string
    local function set(id, value)
        if not form then
            return
        end
        form.set(vim.tbl_extend("force", form.get() or {}, { [id] = value }))
    end

    local function cleanup()
        for _, m in ipairs(mapped) do
            pcall(vim.keymap.del, m[1], m[2])
        end
        mapped = {}
        pcall(vim.api.nvim_del_augroup_by_name, "OrchlaunchFibrousProfileEditor")
    end

    local function close()
        cleanup()
        if not closed and handle then
            closed = true
            handle.unmount()
        end
    end

    local function collect()
        local name = vim.trim(get("name") or "")
        if name == "" then
            error("a profile name is required", 0)
        end

        local clash = state.cmake_profile(name)
        if clash and (original_name == nil or clash.name ~= original_name) then
            error(("a profile named %q already exists"):format(name), 0)
        end

        local toolchain = get("toolchain")
        if toolchain == "(none)" then
            toolchain = nil
        end

        local profile = {
            name = name,
            toolchain = trimmed(toolchain),
            generator = trimmed(get("generator")),
            build_type = trimmed(get("build_type")),
            build_dir = trimmed(get("build_dir")),
            install_dir = trimmed(get("install_dir")),
            configure_args = UI.lines(get("configure_args")),
            build_args = UI.lines(get("build_args")),
            install_args = UI.lines(get("install_args")),
            definitions = UI.parse_env(get("definitions")),
            environment = UI.parse_env(get("environment")),
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

        local ok_save, profile = pcall(collect)
        if not ok_save then
            UI.notify(tostring(profile), ERROR)
            if handle then
                handle.focus()
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

    local title_text = function(name)
        return ("  CMake profile: %s"):format(name ~= "" and name or "new")
    end

    local function editor(ctx)
        form = form or ctx.use_state(initial)
        local v = form.get() or {}

        local function field_label(text, node)
            return {
                comp = ui.row,
                props = { gap = 1, align = "start" },
                children = {
                    { comp = ui.label, props = { text = text, width = 16, style = { text_hl = "Comment" } } },
                    node,
                },
            }
        end

        local function text_field(def)
            return {
                comp = ui.text_input,
                props = {
                    value = initial[def.id],
                    height = def.height or 1,
                    singleline = def.singleline or false,
                    grow = 1,
                    style = { border = "rounded" },
                    on_change = function(value)
                        set(def.id, value)
                    end,
                },
            }
        end

        local function select_field(def, options)
            -- The dropdown itself is one row tall; a 3-row wrapper keeps the two
            -- columns' section headings aligned with the bordered text fields.
            return {
                comp = ui.col,
                props = { grow = 1, height = 3, align = "start", justify = "start" },
                children = {
                    {
                        comp = ui.dropdown,
                        props = {
                            options = options,
                            value = initial[def.id],
                            width = 24,
                            on_select = function(value)
                                set(def.id, value)
                            end,
                        },
                    },
                },
            }
        end

        local function heading(text)
            return { comp = ui.label, props = { text = " " .. text, style = { text_hl = "Title" } } }
        end

        if readonly then
            return {
                comp = ui.col,
                props = { grow = 1, gap = 0, style = { padding = { x = 1, y = 1 } } },
                children = {
                    { comp = ui.label, props = { text = title_text(existing.name or ""), align_self = "center", style = { text_hl = "Title" } } },
                    { comp = ui.label, props = { text = table.concat(preset_lines(state, existing), "\n"), grow = 1 } },
                    { comp = ui.label, props = { text = "  q/<Esc>  Close  ", align_self = "center", style = { text_hl = "Comment" } } },
                },
            }
        end

        local left = {
            comp = ui.col,
            props = { grow = 1, gap = 1 },
            children = {
                heading("Profile"),
                field_label("Name", text_field(MANUAL_FIELDS[1])),
                heading("Build"),
                field_label("Generator", select_field(MANUAL_FIELDS[3], with_current(GENERATORS, initial.generator))),
                field_label("Build type", select_field(MANUAL_FIELDS[4], with_current(BUILD_TYPES, initial.build_type))),
                field_label("Build dir", text_field(MANUAL_FIELDS[5])),
                field_label("Install dir", text_field(MANUAL_FIELDS[6])),
            },
        }

        local right = {
            comp = ui.col,
            props = { grow = 1, gap = 1 },
            children = {
                heading("Toolchain"),
                field_label("Toolchain", select_field(MANUAL_FIELDS[2], toolchain_options)),
                heading("Arguments"),
                field_label("Configure", text_field(MANUAL_FIELDS[7])),
                field_label("Build", text_field(MANUAL_FIELDS[8])),
                field_label("Install", text_field(MANUAL_FIELDS[9])),
                heading("Variables"),
                field_label("Definitions", text_field(MANUAL_FIELDS[10])),
                field_label("Environment", text_field(MANUAL_FIELDS[11])),
            },
        }

        return {
            comp = ui.col,
            props = { grow = 1, gap = 0, style = { padding = { x = 1 } } },
            children = {
                { comp = ui.label, props = { text = title_text(v.name or ""), align_self = "center", style = { text_hl = "Title" } } },
                { comp = ui.row, props = { grow = 1, gap = 3 }, children = { left, right } },
                { comp = ui.label, props = { text = "  <C-s> Save  ·  Tab/s field  ·  ↑↓ pick  ·  Enter ok  ·  q/<Esc> close  ", align_self = "center", style = { text_hl = "Comment" } } },
            },
        }
    end

    local mount_opts = { zindex = 50 }
    local function apply_size()
        mount_opts.width = math.max(80, math.min(vim.o.columns - 4, 120))
        mount_opts.height = math.max(20, math.min(vim.o.lines - 4, 36))
    end

    apply_size()
    mount_opts.on_unmount = function()
        cleanup()
        if on_saved then
            on_saved()
        end
    end
    handle = nr.mount(editor, {}, mount_opts)
    handle.focus()

    for _, m in ipairs({ { "n", "q", close }, { "n", "<C-s>", save } }) do
        mapped[#mapped + 1] = m
        vim.keymap.set(m[1], m[2], function()
            m[3]()
        end, { nowait = true, silent = true })
    end
    vim.keymap.set("n", "<Esc>", close, { buffer = handle.bufnr, nowait = true, silent = true })

    -- fibrous owns canvas traversal: its own <Tab>/<S-Tab> park the cursor on the
    -- next/previous interactive node, and <CR>/`i` dive in. On top of that we
    -- make the form feel continuous:
    --   * <Tab>/<S-Tab>/<C-j>/<C-k> INSIDE a field pop back to the canvas, cycle
    --     to the next/previous stop and enter it ready to type;
    --   * a single <Esc> in a single-line field leaves it (multiline fields keep
    --     the native second-<Esc> so normal editing inside them still works);
    --   * ui.dropdown only navigates its popup with <C-n>/<C-p>, so the arrow
    --     keys are aliased to those on dropdown buffers.
    --
    -- Subwindow floats and their buffers are recreated on every render, so these
    -- buffer-local maps are (re)applied from an autocmd, guarded by a buffer flag
    -- so re-application never clobbers anything the user refined once set.
    local function field_cycle(key, enter)
        dlog(("cycle key=%s mode=%s win=%d"):format(key, vim.api.nvim_get_mode().mode, vim.api.nvim_get_current_win()))
        vim.cmd("stopinsert")
        if vim.api.nvim_win_is_valid(handle.winid) then
            vim.api.nvim_set_current_win(handle.winid)
        end
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "m", false)
        if enter then
            vim.api.nvim_feedkeys("i", "m", false)
        end
    end

    local function field_leave()
        dlog(("leave mode=%s win=%d"):format(vim.api.nvim_get_mode().mode, vim.api.nvim_get_current_win()))
        vim.cmd("stopinsert")
        if vim.api.nvim_win_is_valid(handle.winid) then
            vim.api.nvim_set_current_win(handle.winid)
        end
    end

    -- Field cells are read out of fibrous itself: its <Tab> traversal parks the
    -- root cursor exactly on each interactive node's cell, so we cycle through
    -- the stops once, record where the cursor lands, and restore it. Public
    -- behaviour only, and it stays correct as the form re-renders.
    local function field_cells()
        if not vim.api.nvim_win_is_valid(handle.winid) then
            return {}
        end
        local saved = vim.api.nvim_win_get_cursor(handle.winid)
        vim.api.nvim_win_set_cursor(handle.winid, { 1, 0 })
        local tab = vim.api.nvim_replace_termcodes("<Tab>", true, false, true)
        local cells, seen = {}, {}
        for _ = 1, 64 do
            vim.api.nvim_feedkeys(tab, "mx", false)
            local c = vim.api.nvim_win_get_cursor(handle.winid)
            local key = c[1] .. ":" .. c[2]
            if seen[key] then
                break
            end
            seen[key] = true
            cells[#cells + 1] = { row = c[1] - 1, col = c[2] }
        end
        pcall(vim.api.nvim_win_set_cursor, handle.winid, saved)
        table.sort(cells, function(a, b)
            if a.row ~= b.row then
                return a.row < b.row
            end
            return a.col < b.col
        end)
        return cells
    end

    -- Flash jump: overlay a letter on every field, read one key, hop there and
    -- start typing. Labels are home-row-first; `s` triggers it (also from a
    -- field's normal mode, which first leaves the field).
    local FLASH_LETTERS = "asdfghjklqwertyuiopzxcvbnm"
    local flash_hl = false
    local function flash()
        local cells = field_cells()
        if #cells == 0 then
            return
        end
        if not flash_hl then
            flash_hl = true
            vim.api.nvim_set_hl(0, "OrchlaunchFlash", { bold = true, reverse = true })
        end
        local target = {}
        for i, cell in ipairs(cells) do
            local ch = FLASH_LETTERS:sub(i, i)
            if ch == "" then
                break
            end
            target[ch] = cell
            vim.api.nvim_buf_set_extmark(handle.bufnr, flash_ns, cell.row, cell.col, {
                virt_text = { { ch, "OrchlaunchFlash" } },
                virt_text_pos = "overlay",
                priority = 1000,
            })
        end
        vim.cmd("redraw")
        local ok, ch = pcall(vim.fn.getcharstr)
        vim.api.nvim_buf_clear_namespace(handle.bufnr, flash_ns, 0, -1)
        vim.cmd("redraw")
        if not ok or ch == "" then
            return
        end
        local cell = target[ch]
        if not cell then
            return
        end
        vim.api.nvim_set_current_win(handle.winid)
        vim.api.nvim_win_set_cursor(handle.winid, { cell.row + 1, cell.col })
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i", true, false, true), "m", false)
    end

    local function wire_field_keys()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.w[win].fibrous_anchor == handle.winid then
                local buf = vim.api.nvim_win_get_buf(win)
                if not vim.b[buf].orchlaunch_field_keys then
                    vim.b[buf].orchlaunch_field_keys = true
                    dlog(("map buf=%d lines=%d"):format(buf, vim.api.nvim_buf_line_count(buf)))
                    for _, mode in ipairs({ "n", "i" }) do
                        vim.keymap.set(mode, "<Tab>", function()
                            field_cycle("<Tab>", true)
                        end, { buffer = buf, nowait = true, silent = true })
                        vim.keymap.set(mode, "<S-Tab>", function()
                            field_cycle("<S-Tab>", true)
                        end, { buffer = buf, nowait = true, silent = true })
                        vim.keymap.set(mode, "<C-j>", function()
                            field_cycle("<Tab>", true)
                        end, { buffer = buf, nowait = true, silent = true })
                        vim.keymap.set(mode, "<C-k>", function()
                            field_cycle("<S-Tab>", true)
                        end, { buffer = buf, nowait = true, silent = true })
                    end
                    vim.keymap.set("i", "<Esc>", function()
                        if vim.api.nvim_buf_line_count(buf) > 1 then
                            vim.api.nvim_feedkeys(
                                vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
                                "n",
                                false
                            )
                        else
                            field_leave()
                        end
                    end, { buffer = buf, nowait = true, silent = true })
                    vim.keymap.set("n", "s", function()
                        field_leave()
                        flash()
                    end, { buffer = buf, nowait = true, silent = true })
                end
                local is_dropdown = false
                for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
                    if m.lhs == "<C-n>" or m.lhs == "<C-N>" then
                        is_dropdown = true
                        break
                    end
                end
                if is_dropdown and not vim.b[buf].orchlaunch_arrow_alias then
                    vim.b[buf].orchlaunch_arrow_alias = true
                    for _, mode in ipairs({ "n", "i" }) do
                        vim.keymap.set(mode, "<Down>", function()
                            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-n>", true, false, true), "m", false)
                        end, { buffer = buf, nowait = true, silent = true })
                        vim.keymap.set(mode, "<Up>", function()
                            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-p>", true, false, true), "m", false)
                        end, { buffer = buf, nowait = true, silent = true })
                    end
                end
            end
        end
    end
    wire_field_keys()
    vim.schedule(wire_field_keys)
    vim.api.nvim_create_autocmd({ "BufWinEnter", "WinNew", "BufEnter", "WinEnter" }, {
        group = vim.api.nvim_create_augroup("OrchlaunchFibrousProfileFields", { clear = true }),
        callback = wire_field_keys,
    })
    vim.keymap.set("n", "s", flash, { buffer = handle.bufnr, nowait = true, silent = true })

    vim.api.nvim_create_autocmd("VimResized", {
        group = vim.api.nvim_create_augroup("OrchlaunchFibrousProfileEditor", { clear = true }),
        callback = function()
            apply_size()
            if handle then
                handle.relayout()
            end
        end,
    })

    handle.orch = {
        readonly = readonly,
        fields = fields_meta,
        values = setmetatable({}, {
            __index = function(_, key)
                return get(key)
            end,
        }),
        refresh = function()
            if handle then
                handle.relayout()
            end
        end,
        focus = function()
            if handle then
                handle.focus()
            end
        end,
        save = save,
        close = close,
        get = get,
        set = set,
        _field_cells = field_cells,
        index_of = function(id)
            for index, field in ipairs(fields_meta) do
                if field.id == id then
                    return index
                end
            end
        end,
    }

    return handle
end

return M
