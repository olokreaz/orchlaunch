-- OrchLaunch — editor for the "compound" run configuration.

local UI = require("orchlaunch.ui")
local form = require("orchlaunch.ui.form")

local M = {}

--- @param existing? OrchCompoundConfiguration
--- @param on_saved? function
--- @param opts? table
function M.open(existing, on_saved, opts)
    local n = UI.n()
    local config = require("orchlaunch.config")
    existing = existing or {}

    local renderer = UI.renderer(vim.tbl_extend("force", { width = 80, height = 20 }, opts or {}))

    local fields = n.rows(
        { flex = 1, direction = "column" },
        form.input(n, "name", " Name ", existing.name, { autofocus = true }),
        n.gap(1),
        form.input(n, "configurations", " Configurations (one per line) ", UI.format_lines(existing.configurations), { size = 6 })
    )

    local function save()
        form.submit(renderer, function()
            local name = vim.trim(form.read_text(renderer, "name"))
            assert(name ~= "", "configuration name is required")

            local state = require("orchlaunch.state")
            if not existing.name and state.configuration(name) then
                error(("configuration already exists: %s"):format(name))
            end

            local value = config.compound({
                name = name,
                configurations = UI.lines(form.read_text(renderer, "configurations")),
            })

            form.upsert_configuration(state, existing.name, value)
        end, on_saved)
    end

    local body = function()
        return n.rows(
            { flex = 1, direction = "column" },
            fields,
            n.gap(1),
            form.footer(n, renderer, save)
        )
    end

    renderer:render(body)
    return renderer
end

return M
