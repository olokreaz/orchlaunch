-- OrchLaunch — compound run configuration editor on fibrous.

local form = require("orchlaunch.ui.fibrous.form")

local M = {}

--- @param existing? OrchCompoundConfiguration
--- @param on_saved? function
--- @param opts? table
function M.open(existing, on_saved, opts)
    local ui = require("fibrous").ui
    local UI = require("orchlaunch.ui")
    local config = require("orchlaunch.config")
    local state = require("orchlaunch.state")
    existing = existing or {}

    return form.open({
        augroup = "OrchlaunchFibrousCompound",
        title = "  Compound configuration",
        size = { width = 80, height = 20 },
        on_saved = on_saved,
        initial = {
            name = existing.name or "",
            configurations = UI.format_lines(existing.configurations),
        },
        render = function(_, f)
            return {
                comp = ui.col,
                props = { grow = 1, gap = 0, style = { padding = { x = 1, y = 1 } } },
                children = {
                    f.centered(f.title()),
                    f.field_label("Name", f.text("name", { singleline = true, grow = 1 })),
                    f.field_label("Configs", f.text("configurations", { height = 6, grow = 1 })),
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
            return config.compound({
                name = name,
                configurations = UI.lines(values.configurations),
            })
        end,
        save = function(value)
            form.upsert_configuration(state, existing.name, value)
        end,
    })
end

return M
