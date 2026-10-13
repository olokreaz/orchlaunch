-- OrchLaunch — CMake profile editor built on raw nui.nvim.
--
-- A manual profile is self-contained: name, toolchain, generator, build type,
-- directories, args, definitions and environment. It never references presets.
--
-- Profiles carrying a `kind` are imported from CMakePresets.json /
-- CMakeUserPresets.json (and any included files). They cannot be created or
-- edited here — only viewed. Manage them in the preset JSON files and re-import
-- through the profile list.

local Popup = require("nui.popup")
local Input = require("nui.input")
local Menu = require("nui.menu")
local event = require("nui.utils.autocmd").event

local UI = require("orchlaunch.ui")

local M = {}

local NS = vim.api.nvim_create_namespace("orchlaunch_cmake_profile")

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

local function ensure_highlights()
    vim.api.nvim_set_hl(0, "OrchLaunchLabel", { link = "Title", default = true })
    vim.api.nvim_set_hl(0, "OrchLaunchValue", { link = "Normal", default = true })
    vim.api.nvim_set_hl(0, "OrchLaunchHint", { link = "Comment", default = true })
    vim.api.nvim_set_hl(0, "OrchLaunchBorder", { link = "FloatBorder", default = true })
    vim.api.nvim_set_hl(0, "OrchLaunchCursorLine", { link = "Visual", default = true })
end

--- @param state table
--- @return string[]
local function toolchain_names(state)
    local names = {}
    for _, toolchain in ipairs(state.toolchains()) do
        names[#names + 1] = toolchain.name
    end
    return names
end

--- Editable (manual) profile fields — nothing preset-related.
--- @param state table
--- @return table[]
local function manual_fields(state)
    return {
        { id = "name", label = "Name", kind = "string" },
        { id = "enabled", label = "Enabled", kind = "bool" },
        { id = "toolchain", label = "Toolchain", kind = "select", options = toolchain_names(state) },
        { id = "generator", label = "Generator", kind = "select", options = GENERATORS },
        { id = "build_type", label = "Build type", kind = "select", options = BUILD_TYPES },
        { id = "build_dir", label = "Build dir", kind = "string" },
        { id = "install_dir", label = "Install dir", kind = "string" },
        { id = "configure_args", label = "Configure args", kind = "lines" },
        { id = "build_args", label = "Build args", kind = "lines" },
        { id = "install_args", label = "Install args", kind = "lines" },
        { id = "definitions", label = "Definitions", kind = "env" },
        { id = "environment", label = "Environment", kind = "env" },
    }
end

--- Read-only fields for a preset-derived ("imported") profile.
--- @return table[]
local function imported_fields()
    return {
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
end

--- @param profile? table
--- @return table
local function snapshot(profile)
    if profile == nil then
        return {
            name = "",
            enabled = true,
            generator = "Ninja",
            build_type = "Debug",
            configure_args = {},
            build_args = {},
            install_args = {},
            definitions = {},
            environment = {},
        }
    end

    return {
        name = profile.name or "",
        enabled = profile.enabled ~= false,
        kind = profile.kind,
        toolchain = profile.toolchain,
        generator = profile.generator,
        build_type = profile.build_type,
        build_dir = profile.build_dir,
        install_dir = profile.install_dir,
        configure_args = vim.deepcopy(profile.configure_args or {}),
        build_args = vim.deepcopy(profile.build_args or {}),
        install_args = vim.deepcopy(profile.install_args or {}),
        definitions = vim.deepcopy(profile.definitions or {}),
        environment = vim.deepcopy(profile.environment or {}),
    }
end

--- @param field table
--- @param values table
--- @return string text, boolean placeholder
local function format_value(field, values)
    local value = values[field.id]

    if field.kind == "bool" then
        return value and "[x]" or "[ ]", false
    end

    if field.kind == "lines" then
        local count = #(value or {})
        if count == 0 then
            return "(empty)", true
        end
        return ("%d item(s)"):format(count), false
    end

    if field.kind == "env" then
        local count = 0
        for _ in pairs(value or {}) do
            count = count + 1
        end
        if count == 0 then
            return "(empty)", true
        end
        return ("%d entr%s"):format(count, count == 1 and "y" or "ies"), false
    end

    if value == nil or value == "" then
        return "(unset)", true
    end

    return tostring(value), false
end

--- @param values table
--- @param original? table
--- @return table
local function to_profile(values, original)
    local function trimmed(value)
        return type(value) == "string" and vim.trim(value) or value
    end

    local profile = {
        name = trimmed(values.name),
        enabled = values.enabled and true or false,
    }

    for _, key in ipairs({
        "toolchain",
        "generator",
        "build_type",
        "build_dir",
        "install_dir",
    }) do
        local value = trimmed(values[key])
        if type(value) == "string" and value ~= "" then
            profile[key] = value
        end
    end

    for _, key in ipairs({ "configure_args", "build_args", "install_args" }) do
        local value = values[key]
        if value and #value > 0 then
            profile[key] = value
        end
    end

    for _, key in ipairs({ "definitions", "environment" }) do
        local value = values[key]
        if value and next(value) then
            profile[key] = value
        end
    end

    -- Preserve preset references on legacy profiles without exposing them.
    if original then
        for _, key in ipairs({
            "kind",
            "configure_preset",
            "build_preset",
            "test_preset",
            "package_preset",
            "workflow_preset",
        }) do
            if original[key] ~= nil then
                profile[key] = original[key]
            end
        end
    end

    return profile
end

--- @param existing? table
--- @param on_saved? function
--- @param opts? table
--- @return table popup
function M.open(existing, on_saved, opts)
    opts = opts or {}
    ensure_highlights()

    local state = require("orchlaunch.state")
    local readonly = existing ~= nil and existing.kind ~= nil
    local original_name = existing and existing.name or nil
    local fields = readonly and imported_fields() or manual_fields(state)
    local values = snapshot(existing)

    local selected = 1
    local closed = false

    local width = math.max(56, math.min(100, math.floor(vim.o.columns * 0.62)))

    local popup = Popup({
        relative = opts.relative or "editor",
        position = opts.position or "50%",
        size = { width = width, height = #fields + 2 },
        border = {
            style = "rounded",
            text = {
                top = " CMake profile ",
                top_align = "center",
                bottom = readonly and " imported from CMakePresets.json · q close "
                    or " <CR> edit · <Space> toggle · j/k move · <C-s> save · q close ",
                bottom_align = "center",
            },
        },
        win_options = {
            cursorline = true,
            wrap = false,
            number = false,
            signcolumn = "no",
            winhighlight = "FloatBorder:OrchLaunchBorder,CursorLine:OrchLaunchCursorLine",
        },
        buf_options = { modifiable = false, bufhidden = "wipe" },
    })

    local function focus()
        if vim.api.nvim_win_is_valid(popup.winid) then
            vim.api.nvim_set_current_win(popup.winid)
        end
    end

    local function render()
        local label_width = 0
        for _, field in ipairs(fields) do
            label_width = math.max(label_width, vim.api.nvim_strwidth(field.label))
        end

        local value_start = 2 + label_width + 3
        local lines = {}

        for index, field in ipairs(fields) do
            local label = field.label .. string.rep(" ", label_width - vim.api.nvim_strwidth(field.label))
            local value = format_value(field, values)
            lines[index] = ("  %s   %s"):format(label, value)
        end

        selected = math.max(1, math.min(selected, #fields))

        vim.bo[popup.bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
        vim.api.nvim_buf_clear_namespace(popup.bufnr, NS, 0, -1)

        for index, field in ipairs(fields) do
            local _, placeholder = format_value(field, values)
            vim.api.nvim_buf_add_highlight(popup.bufnr, NS, "OrchLaunchLabel", index - 1, 2, 2 + label_width)
            vim.api.nvim_buf_add_highlight(
                popup.bufnr,
                NS,
                placeholder and "OrchLaunchHint" or "OrchLaunchValue",
                index - 1,
                value_start,
                -1
            )
        end

        vim.bo[popup.bufnr].modifiable = false

        if vim.api.nvim_win_is_valid(popup.winid) then
            vim.api.nvim_win_set_cursor(popup.winid, { selected, 0 })
        end

        local title = vim.trim(values.name)
        popup.border:set_text("top", (" CMake profile: %s "):format(title ~= "" and title or "new"), "center")
    end

    local function set_field(field, value)
        values[field.id] = value
        render()
        focus()
    end

    local function edit_string(field)
        local value = values[field.id] or ""
        local input = Input({
            relative = "editor",
            position = "50%",
            size = { width = math.min(84, math.max(40, vim.api.nvim_strwidth(value) + 16)) },
            border = {
                style = "rounded",
                text = { top = (" %s "):format(field.label), top_align = "center" },
            },
            win_options = { winhighlight = "FloatBorder:OrchLaunchBorder,NormalFloat:Normal" },
        }, {
            prompt = "> ",
            default_value = value,
            on_submit = function(text)
                set_field(field, text)
            end,
            on_close = function()
                vim.schedule(focus)
            end,
        })

        input:map("n", "<Esc>", function()
            input:unmount()
        end, { nowait = true })

        input.orch_apply = function(text)
            input:unmount()
            set_field(field, text)
        end

        input:mount()
        return input
    end

    local function edit_select(field)
        local options = vim.deepcopy(field.options or {})
        local current = values[field.id]
        if current and current ~= "" and not vim.tbl_contains(options, current) then
            options[#options + 1] = current
        end

        local lines = { Menu.item("(none)", { id = "" }) }
        for _, name in ipairs(options) do
            lines[#lines + 1] = Menu.item(name, { id = name })
        end

        local function choose(id)
            set_field(field, id ~= "" and id or nil)
        end

        local menu = Menu({
            relative = "editor",
            position = "50%",
            size = { width = math.min(60, math.max(30, width - 12)) },
            border = {
                style = "rounded",
                text = { top = (" %s "):format(field.label), top_align = "center" },
            },
            win_options = { winhighlight = "FloatBorder:OrchLaunchBorder,NormalFloat:Normal,CursorLine:OrchLaunchCursorLine" },
        }, {
            lines = lines,
            max_width = math.max(30, width - 12),
            max_height = 12,
            keymap = {
                close = { "<Esc>", "<C-c>", "q" },
                submit = { "<CR>" },
            },
            on_submit = function(item)
                choose(item.id)
            end,
            on_close = function()
                vim.schedule(focus)
            end,
        })

        menu.orch_apply = function(id)
            menu:unmount()
            choose(id)
        end

        menu:mount()
        return menu
    end

    local function edit_multiline(field)
        local initial
        if field.kind == "env" then
            initial = UI.format_env(values[field.id])
        else
            initial = table.concat(values[field.id] or {}, "\n")
        end

        local box = Popup({
            relative = "editor",
            position = "50%",
            size = { width = math.max(60, width - 6), height = 13 },
            border = {
                style = "rounded",
                text = {
                    top = (" %s "):format(field.label),
                    top_align = "center",
                    bottom = field.kind == "env" and " KEY=VALUE per line · <C-s> apply · <Esc> close "
                        or " one per line · <C-s> apply · <Esc> close ",
                    bottom_align = "center",
                },
            },
            win_options = {
                cursorline = true,
                wrap = false,
                winhighlight = "FloatBorder:OrchLaunchBorder,NormalFloat:Normal,CursorLine:OrchLaunchCursorLine",
            },
            buf_options = { modifiable = true, bufhidden = "wipe" },
        })

        local function apply()
            local text = table.concat(vim.api.nvim_buf_get_lines(box.bufnr, 0, -1, false), "\n")
            local value
            if field.kind == "env" then
                value = UI.parse_env(text)
            else
                value = UI.lines(text)
            end
            box:unmount()
            set_field(field, value)
        end

        box:mount()
        vim.api.nvim_buf_set_lines(box.bufnr, 0, -1, false, vim.split(initial, "\n", { plain = true }))
        box:map("n", "<C-s>", apply, { nowait = true })
        box:map("i", "<C-s>", function()
            vim.cmd("stopinsert")
            apply()
        end, { nowait = true })
        box:map("n", "<Esc>", function()
            box:unmount()
        end, { nowait = true })
        box:map("n", "q", function()
            box:unmount()
        end, { nowait = true })
        box:on(event.BufWinLeave, function()
            vim.schedule(focus)
        end)

        box.orch_apply = apply
        return box
    end

    local function activate(field)
        if not field then
            return
        end

        if field.readonly then
            UI.notify("imported from CMakePresets.json — edit the preset file", vim.log.levels.WARN)
            return
        end

        if field.kind == "bool" then
            values[field.id] = not values[field.id]
            render()
            return field
        elseif field.kind == "select" then
            return edit_select(field)
        elseif field.kind == "lines" or field.kind == "env" then
            return edit_multiline(field)
        else
            return edit_string(field)
        end
    end

    local function close(saved)
        if closed then
            return
        end
        closed = true
        if saved then
            state.save()
        end
        pcall(function()
            popup:unmount()
        end)
        if on_saved then
            on_saved()
        end
    end

    local function save()
        if readonly then
            UI.notify("imported from CMakePresets.json — nothing to save", vim.log.levels.WARN)
            return
        end

        local name = vim.trim(values.name)
        if name == "" then
            UI.notify("a profile name is required", vim.log.levels.ERROR)
            focus()
            return
        end

        local clash = state.cmake_profile(name)
        if clash and (original_name == nil or clash.name ~= original_name) then
            UI.notify(("a profile named %q already exists"):format(name), vim.log.levels.ERROR)
            focus()
            return
        end

        local profile = to_profile(values, existing)
        if original_name then
            state.update_cmake_profile(original_name, profile)
        else
            state.add_cmake_profile(profile)
        end

        close(true)
    end

    local function move(delta)
        selected = math.max(1, math.min(selected + delta, #fields))
        render()
    end

    popup:map("n", "j", function()
        move(1)
    end, { nowait = true })
    popup:map("n", "<Down>", function()
        move(1)
    end, { nowait = true })
    popup:map("n", "k", function()
        move(-1)
    end, { nowait = true })
    popup:map("n", "<Up>", function()
        move(-1)
    end, { nowait = true })
    popup:map("n", "g", function()
        selected = 1
        render()
    end, { nowait = true })
    popup:map("n", "G", function()
        selected = #fields
        render()
    end, { nowait = true })
    popup:map("n", "<CR>", function()
        activate(fields[selected])
    end, { nowait = true })
    popup:map("n", "<Space>", function()
        local field = fields[selected]
        if field and field.kind == "bool" and not field.readonly then
            values[field.id] = not values[field.id]
            render()
        end
    end, { nowait = true })
    popup:map("n", "<C-s>", save, { nowait = true })
    popup:map("n", "<Esc>", function()
        close(false)
    end, { nowait = true })
    popup:map("n", "q", function()
        close(false)
    end, { nowait = true })

    popup:mount()
    render()
    focus()
    vim.schedule(focus)

    popup.orch = {
        fields = fields,
        values = values,
        readonly = readonly,
        refresh = render,
        activate = activate,
        save = save,
        close = close,
        select = function(index)
            selected = index
            render()
        end,
        set = function(id, value)
            values[id] = value
            render()
        end,
        index_of = function(id)
            for index, field in ipairs(fields) do
                if field.id == id then
                    return index
                end
            end
        end,
    }

    return popup
end

return M
