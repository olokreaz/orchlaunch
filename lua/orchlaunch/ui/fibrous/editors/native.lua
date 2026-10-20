-- OrchLaunch — native run configuration editor on fibrous.

local form = require("orchlaunch.ui.fibrous.form")

local M = {}

--- @param existing? OrchNativeConfiguration
--- @param on_saved? function
--- @param opts? table
function M.open(existing, on_saved, opts)
    local ui = require("fibrous").ui
    local UI = require("orchlaunch.ui")
    local config = require("orchlaunch.config")
    local state = require("orchlaunch.state")
    local targets = require("orchlaunch.cmake").targets()
    existing = existing or {}

    local console = existing.console or {}
    local build, install, external = form.before_flags(existing.before)
    local matched = targets and vim.tbl_contains(vim.tbl_map(function(t)
        return t.name
    end, targets), existing.target)

    return form.open({
        augroup = "OrchlaunchFibrousNative",
        title = "  Native configuration",
        size = { width = 108, height = 32 },
        on_saved = on_saved,
        initial = {
            name = existing.name or "",
            runtime = existing.runtime or "executable",
            target = existing.target or "",
            target_choice = (matched and existing.target) or form.CUSTOM_TARGET,
            cwd = existing.cwd or "",
            args = UI.format_lines(existing.args),
            environment = UI.format_env(existing.environment),
            inherit_env = existing.inherit_env ~= false,
            sudo = existing.sudo == true,
            console_mode = console.mode or "embedded",
            keep_open = console.keep_open ~= false,
            clear_on_start = console.clear_on_start ~= false,
            before_build = build,
            before_install = install,
            before_external = external,
        },
        render = function(_, f)
            local left = {
                comp = ui.col,
                props = { grow = 1, gap = 1 },
                children = {
                    f.field_label("Name", f.text("name", { singleline = true, grow = 1 })),
                    f.target_field({
                        input_id = "target",
                        select_id = "target_choice",
                        targets = targets,
                        label = "Target",
                    }),
                    f.field_label("Working dir", f.text("cwd", { singleline = true, grow = 1 })),
                    f.field_label("Args", f.text("args", { height = 4, grow = 1 })),
                    f.field_label("Environment", f.text("environment", { height = 4, grow = 1 })),
                },
            }
            local right = {
                comp = ui.col,
                props = { grow = 1, gap = 1 },
                children = {
                    f.field_label("Runtime", f.select("runtime", { "executable", "static", "shared", "module", "object", "interface", "utility", "unknown" })),
                    f.field_label("Console", f.select("console_mode", { "embedded", "hidden", "none" })),
                    f.check("keep_open", { label = "Keep console open" }),
                    f.check("clear_on_start", { label = "Clear console on start" }),
                    f.check("inherit_env", { label = "Inherit environment" }),
                    f.check("sudo", { label = "Run with sudo" }),
                    f.before_fields(),
                },
            }
            return {
                comp = ui.col,
                props = { grow = 1, gap = 0, style = { padding = { x = 1, y = 1 } } },
                children = {
                    f.centered(f.title()),
                    { comp = ui.row, props = { grow = 1, gap = 3 }, children = { left, right } },
                    f.footer("<C-s> Save  ·  Tab/s field  ·  q/<Esc> close"),
                },
            }
        end,
        collect = function(values)
            local name = vim.trim(values.name or "")
            assert(name ~= "", "configuration name is required")
            if not existing.name and state.configuration(name) then
                error(("configuration already exists: %s"):format(name))
            end
            local runtime = values.runtime or "executable"
            return config.native({
                name = name,
                runtime = runtime,
                target = form.read_target(values, targets, "target", "target_choice"),
                cwd = UI.trimmed(values.cwd),
                args = UI.lines(values.args),
                inherit_env = values.inherit_env == true,
                sudo = values.sudo == true,
                environment = UI.parse_env(values.environment),
                console = {
                    mode = values.console_mode or "embedded",
                    keep_open = values.keep_open == true,
                    clear_on_start = values.clear_on_start == true,
                },
                before = form.collect_before(values),
            })
        end,
        save = function(value)
            form.upsert_configuration(state, existing.name, value)
        end,
    })
end

return M
