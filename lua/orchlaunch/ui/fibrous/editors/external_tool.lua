-- OrchLaunch — external tool editor on fibrous.

local form = require("orchlaunch.ui.fibrous.form")

local M = {}

--- @param existing? OrchExternalTool
--- @param on_saved? function
function M.open(existing, on_saved)
    local ui = require("fibrous").ui
    local UI = require("orchlaunch.ui")
    local config = require("orchlaunch.config")
    local state = require("orchlaunch.state")
    existing = existing or {}

    return form.open({
        augroup = "OrchlaunchFibrousExternalTool",
        title = "  External tool",
        size = { width = 96, height = 24 },
        initial = {
            name = existing.name or "",
            program = existing.program or "",
            cwd = existing.cwd or "",
            args = UI.format_lines(existing.args),
            inherit_env = existing.inherit_env ~= false,
            sudo = existing.sudo == true,
            environment = UI.format_env(existing.environment),
        },
        render = function(_, f)
            local left = {
                comp = ui.col,
                props = { grow = 1, gap = 1 },
                children = {
                    f.field_label("Name", f.text("name", { singleline = true, grow = 1 })),
                    f.field_label("Program", f.text("program", { singleline = true, grow = 1 })),
                    f.field_label("Working dir", f.text("cwd", { singleline = true, grow = 1 })),
                    f.field_label("Args", f.text("args", { height = 5, grow = 1 })),
                },
            }
            local right = {
                comp = ui.col,
                props = { grow = 1, gap = 1 },
                children = {
                    f.check("inherit_env", { label = "Inherit environment" }),
                    f.check("sudo", { label = "Run with sudo" }),
                    f.field_label("Environment", f.text("environment", { height = 6, grow = 1 })),
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
            assert(name ~= "", "external tool name is required")
            local clash = state.external_tool(name)
            if clash and (not existing.name or clash.name ~= existing.name) then
                error(("external tool already exists: %s"):format(name))
            end
            return config.external_tool({
                name = name,
                program = UI.trimmed(values.program),
                cwd = UI.trimmed(values.cwd),
                args = UI.lines(values.args),
                inherit_env = values.inherit_env == true,
                sudo = values.sudo == true,
                environment = UI.parse_env(values.environment),
            })
        end,
        save = function(value)
            if existing.name then
                state.update_external_tool(existing.name, value)
            else
                state.add_external_tool(value)
            end
        end,
        on_saved = on_saved,
    })
end

return M
