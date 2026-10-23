-- OrchLaunch — remote-debug run configuration editor on fibrous.

local form = require("orchlaunch.ui.fibrous.form")

local M = {}

--- @param existing? OrchRemoteDebugConfiguration
--- @param on_saved? function
--- @param opts? table
function M.open(existing, on_saved, opts)
    local ui = require("fibrous").ui
    local UI = require("orchlaunch.ui")
    local config = require("orchlaunch.config")
    local state = require("orchlaunch.state")
    local targets = require("orchlaunch.cmake").targets()
    existing = existing or {}

    local build, install, external, build_target = form.before_flags(existing.before)
    local matched = targets and vim.tbl_contains(vim.tbl_map(function(t)
        return t.name
    end, targets), existing.symbol)

    return form.open({
        augroup = "OrchlaunchFibrousRemote",
        title = "  Remote debug configuration",
        size = { width = 90, height = 30 },
        on_saved = on_saved,
        initial = {
            name = existing.name or "",
            symbol = existing.symbol or "",
            symbol_choice = (matched and existing.symbol) or form.CUSTOM_TARGET,
            connection = existing.connection or "",
            adapter = existing.adapter or "",
            before_build = build,
            before_build_target = build_target or "",
            before_install = install,
            before_external = external,
        },
        render = function(_, f)
            return {
                comp = ui.col,
                props = { grow = 1, gap = 0, style = { padding = { x = 1, y = 1 } } },
                children = {
                    f.centered(f.title()),
                    f.field_label("Name", f.text("name", { singleline = true, grow = 1 })),
                    f.target_field({
                        input_id = "symbol",
                        select_id = "symbol_choice",
                        targets = targets,
                        label = "Symbol",
                    }),
                    f.field_label("Connection", f.text("connection", { singleline = true, grow = 1 })),
                    f.field_label("Adapter", f.text("adapter", { singleline = true, grow = 1 })),
                    f.before_fields(),
                    f.footer("<C-s> Save  ·  Tab/s field  ·  q/<Esc> close"),
                },
            }
        end,
        collect = function(values)
            local name = vim.trim(values.name or "")
            assert(name ~= "", "configuration name is required")
            local clash = state.configuration(name)
            if clash and (not existing.name or clash.name ~= existing.name) then
                error(("configuration already exists: %s"):format(name))
            end
            return config.remote_debug({
                name = name,
                symbol = form.read_target(values, targets, "symbol", "symbol_choice") or "",
                connection = UI.trimmed(values.connection),
                adapter = UI.trimmed(values.adapter),
                before = form.collect_before(values),
            })
        end,
        save = function(value)
            form.upsert_configuration(state, existing.name, value)
        end,
    })
end

return M
