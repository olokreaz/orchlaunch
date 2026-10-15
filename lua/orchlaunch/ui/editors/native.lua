-- OrchLaunch — editor for the "native" run configuration.

local UI = require("orchlaunch.ui")
local form = require("orchlaunch.ui.form")

local M = {}

--- @param existing? OrchNativeConfiguration
--- @param on_saved? function
--- @param opts? table
function M.open(existing, on_saved, opts)
    local n = UI.n()
    local config = require("orchlaunch.config")
    existing = existing or {}

    local console = existing.console or {}
    local build, install, external = form.before_flags(existing.before)
    local targets = require("orchlaunch.cmake").targets()

    local renderer = UI.renderer(vim.tbl_extend("force", { width = 108, height = 30 }, opts or {}))

    local left = n.rows(
        { flex = 1, direction = "column" },
        form.input(n, "name", " Name ", existing.name, { autofocus = true }),
        n.gap(1),
        form.target_field(n, targets, existing.target, " Target (CMake target or executable path) ", "target", "target_choice"),
        n.gap(1),
        form.input(n, "cwd", " Working directory ", existing.cwd),
        n.gap(1),
        form.input(n, "args", " Program arguments (one per line) ", UI.format_lines(existing.args), { size = 4 }),
        n.gap(1),
        form.input(n, "environment", " Environment (KEY=VALUE, one per line) ", UI.format_env(existing.environment), { size = 4 })
    )

    local right = n.rows(
        { flex = 1, direction = "column" },
        form.chooser(n, "console_mode", " Console (embedded/hidden/none) ", { "embedded", "hidden", "none" }, console.mode or "embedded"),
        n.gap(1),
        form.check(n, "keep_open", " Keep console open", console.keep_open ~= false),
        form.check(n, "clear_on_start", " Clear console on start", console.clear_on_start ~= false),
        n.gap(1),
        form.check(n, "inherit_env", " Inherit environment", existing.inherit_env ~= false),
        form.check(n, "sudo", " Run with sudo", existing.sudo == true),
        n.gap(1),
        form.before_fields(n, { build = build, install = install, external = external })
    )

    local function save()
        form.submit(renderer, function()
            local name = vim.trim(form.read_text(renderer, "name"))
            assert(name ~= "", "configuration name is required")

            local state = require("orchlaunch.state")
            if not existing.name and state.configuration(name) then
                error(("configuration already exists: %s"):format(name))
            end

            local value = config.native({
                name = name,
                target = form.read_target(renderer, targets, "target", "target_choice"),
                cwd = form.trimmed(form.read_text(renderer, "cwd")),
                args = UI.lines(form.read_text(renderer, "args")),
                inherit_env = form.read_bool(renderer, "inherit_env"),
                sudo = form.read_bool(renderer, "sudo"),
                environment = UI.parse_env(form.read_text(renderer, "environment")),
                console = {
                    mode = form.read_choice(renderer, "console_mode", console.mode or "embedded"),
                    keep_open = form.read_bool(renderer, "keep_open"),
                    clear_on_start = form.read_bool(renderer, "clear_on_start"),
                },
                before = form.collect_before(renderer),
            })

            form.upsert_configuration(state, existing.name, value)
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
