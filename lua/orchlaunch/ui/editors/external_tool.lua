-- OrchLaunch — editor for external tools.

local UI = require("orchlaunch.ui")
local form = require("orchlaunch.ui.form")

local M = {}

--- @param existing? OrchExternalTool
--- @param on_saved? function
function M.open(existing, on_saved)
    local n = UI.n()
    local config = require("orchlaunch.config")
    existing = existing or {}

    local renderer = UI.renderer({ width = 96, height = 24 })

    local left = n.rows(
        { flex = 1, direction = "column" },
        form.input(n, "name", " Name ", existing.name, { autofocus = true }),
        n.gap(1),
        form.input(n, "program", " Program ", existing.program),
        n.gap(1),
        form.input(n, "cwd", " Working directory ", existing.cwd),
        n.gap(1),
        form.input(n, "args", " Arguments (one per line) ", UI.format_lines(existing.args), { size = 5 })
    )

    local right = n.rows(
        { flex = 1, direction = "column" },
        form.check(n, "inherit_env", " Inherit environment", existing.inherit_env ~= false),
        form.check(n, "sudo", " Run with sudo", existing.sudo == true),
        n.gap(1),
        form.input(n, "environment", " Environment (KEY=VALUE, one per line) ", UI.format_env(existing.environment), { size = 6 })
    )

    local function save()
        form.submit(renderer, function()
            local name = vim.trim(form.read_text(renderer, "name"))
            assert(name ~= "", "external tool name is required")

            local state = require("orchlaunch.state")
            if not existing.name and state.external_tool(name) then
                error(("external tool already exists: %s"):format(name))
            end

            local value = config.external_tool({
                name = name,
                program = form.read_text(renderer, "program"),
                cwd = form.trimmed(form.read_text(renderer, "cwd")),
                args = UI.lines(form.read_text(renderer, "args")),
                inherit_env = form.read_bool(renderer, "inherit_env"),
                sudo = form.read_bool(renderer, "sudo"),
                environment = UI.parse_env(form.read_text(renderer, "environment")),
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
            form.footer(n, renderer, save)
        )
    end

    renderer:render(body)
    return renderer
end

return M
