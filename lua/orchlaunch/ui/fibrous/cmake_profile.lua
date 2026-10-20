-- OrchLaunch — CMake profile editor on fibrous.
--
-- A manual profile owns every build setting; a new profile starts from sane
-- defaults (generator = Ninja, build type = Debug). Preset-derived profiles
-- (those with `kind`) are read-only and only show their preset description.
--
-- The form scaffolding (state, save/close, field navigation, flash jump) comes
-- from `orchlaunch.ui.fibrous.form`; this module only describes the layout,
-- the collect/save pair and the `.orch` test hooks.

local UI = require("orchlaunch.ui")
local form = require("orchlaunch.ui.fibrous.form")

local M = {}

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

--- @param list string[]
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

--- Field metadata keyed by id, for the two-column layout below.
local MANUAL_BY_ID = {}
for _, def in ipairs(MANUAL_FIELDS) do
    MANUAL_BY_ID[def.id] = def
end

--- Opens the fibrous CMake profile editor.
--- @param existing? OrchCMakeProfile
--- @param on_saved? function
--- @param opts? table
--- @return table handle
function M.open(existing, on_saved, opts)
    local ui = require("fibrous").ui
    local state = require("orchlaunch.state")

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
            if initial[id] == nil and existing[id] ~= nil then
                initial[id] = tostring(existing[id])
            end
        end
    else
        for _, def in ipairs(MANUAL_FIELDS) do
            fields_meta[#fields_meta + 1] = { id = def.id, kind = def.kind, readonly = false }
        end
    end

    return form.open({
        augroup = "OrchlaunchFibrousProfileEditor",
        readonly = readonly,
        on_saved = on_saved,
        size = function(o)
            o.width = math.max(80, math.min(vim.o.columns - 4, 120))
            o.height = math.max(20, math.min(vim.o.lines - 4, 36))
        end,
        title = function(values)
            local name = vim.trim(values.name or "")
            return ("  CMake profile: %s"):format(name ~= "" and name or "new")
        end,
        initial = initial,
        render = function(_, f)
            if readonly then
                return {
                    comp = ui.col,
                    props = { grow = 1, gap = 0, style = { padding = { x = 1, y = 1 } } },
                    children = {
                        f.centered(f.title()),
                        { comp = ui.label, props = { text = table.concat(preset_lines(state, existing), "\n"), grow = 1 } },
                        f.footer("q/<Esc>  Close"),
                    },
                }
            end

            local left = {
                comp = ui.col,
                props = { grow = 1, gap = 1 },
                children = {
                    f.heading("Profile"),
                    f.field_label("Name", f.text("name", { height = 3, singleline = true, grow = 1 })),
                    f.heading("Build"),
                    f.field_label("Generator", f.select("generator", with_current(GENERATORS, initial.generator))),
                    f.field_label("Build type", f.select("build_type", with_current(BUILD_TYPES, initial.build_type))),
                    f.field_label("Build dir", f.text("build_dir", { height = 3, singleline = true, grow = 1 })),
                    f.field_label("Install dir", f.text("install_dir", { height = 3, singleline = true, grow = 1 })),
                },
            }

            local right = {
                comp = ui.col,
                props = { grow = 1, gap = 1 },
                children = {
                    f.heading("Toolchain"),
                    f.field_label("Toolchain", f.select("toolchain", toolchain_options)),
                    f.heading("Arguments"),
                    f.field_label("Configure", f.text("configure_args", { height = 4, grow = 1 })),
                    f.field_label("Build", f.text("build_args", { height = 4, grow = 1 })),
                    f.field_label("Install", f.text("install_args", { height = 4, grow = 1 })),
                    f.heading("Variables"),
                    f.field_label("Definitions", f.text("definitions", { height = 4, grow = 1 })),
                    f.field_label("Environment", f.text("environment", { height = 4, grow = 1 })),
                },
            }

            return {
                comp = ui.col,
                props = { grow = 1, gap = 0, style = { padding = { x = 1 } } },
                children = {
                    f.centered(f.title()),
                    { comp = ui.row, props = { grow = 1, gap = 3 }, children = { left, right } },
                    f.footer("<C-s> Save  ·  Tab/s field  ·  ↑↓ pick  ·  Enter ok  ·  q/<Esc> close"),
                },
            }
        end,
        collect = function(values)
            local name = vim.trim(values.name or "")
            if name == "" then
                error("a profile name is required")
            end

            local clash = state.cmake_profile(name)
            if clash and (original_name == nil or clash.name ~= original_name) then
                error(("a profile named %q already exists"):format(name))
            end

            local toolchain = values.toolchain
            if toolchain == "(none)" then
                toolchain = nil
            end

            local profile = {
                name = name,
                toolchain = trimmed(toolchain),
                generator = trimmed(values.generator),
                build_type = trimmed(values.build_type),
                build_dir = trimmed(values.build_dir),
                install_dir = trimmed(values.install_dir),
                configure_args = UI.lines(values.configure_args),
                build_args = UI.lines(values.build_args),
                install_args = UI.lines(values.install_args),
                definitions = UI.parse_env(values.definitions),
                environment = UI.parse_env(values.environment),
            }

            for _, key in ipairs(PRESERVED_KEYS) do
                if existing[key] ~= nil then
                    profile[key] = existing[key]
                end
            end

            return profile
        end,
        save = function(profile)
            if original_name then
                state.update_cmake_profile(original_name, profile)
            else
                state.add_cmake_profile(profile)
            end
        end,
        attach = function(handle, api)
            handle.orch = {
                readonly = readonly,
                fields = fields_meta,
                values = api.values,
                set = api.set,
                save = api.save,
                close = api.close,
                _field_cells = api.cells,
            }
        end,
    })
end

return M
