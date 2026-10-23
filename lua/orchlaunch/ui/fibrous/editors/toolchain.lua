-- OrchLaunch — toolchain editor on fibrous.

local form = require("orchlaunch.ui.fibrous.form")

local M = {}

--- @param existing? OrchToolchain
--- @param on_saved? function
function M.open(existing, on_saved)
    local ui = require("fibrous").ui
    local UI = require("orchlaunch.ui")
    local config = require("orchlaunch.config")
    local state = require("orchlaunch.state")
    existing = existing or {}

    return form.open({
        augroup = "OrchlaunchFibrousToolchain",
        title = "  Toolchain",
        size = { width = 90, height = 28 },
        initial = {
            name = existing.name or "",
            type = existing.type or "system",
            cmake = existing.cmake or "",
            c = existing.c or "",
            cxx = existing.cxx or "",
            debugger = existing.debugger or "",
            environment = UI.format_env(existing.environment),
        },
        render = function(_, f)
            return {
                comp = ui.col,
                props = { grow = 1, gap = 0, style = { padding = { x = 1, y = 1 } } },
                children = {
                    f.centered(f.title()),
                    f.field_label("Name", f.text("name", { singleline = true, grow = 1 })),
                    f.field_label("Type", f.select("type", { "system", "unix", "msvc" })),
                    f.field_label("CMake", f.text("cmake", { singleline = true, grow = 1 })),
                    f.field_label("C", f.text("c", { singleline = true, grow = 1 })),
                    f.field_label("C++", f.text("cxx", { singleline = true, grow = 1 })),
                    f.field_label("Debugger", f.text("debugger", { singleline = true, grow = 1 })),
                    f.field_label("Environment", f.text("environment", { height = 4, grow = 1 })),
                    f.footer("<C-s> Save  ·  Tab/s field  ·  q/<Esc> close"),
                },
            }
        end,
        collect = function(values)
            local name = vim.trim(values.name or "")
            assert(name ~= "", "toolchain name is required")
            local clash = state.toolchain(name)
            if clash and (not existing.name or clash.name ~= existing.name) then
                error(("toolchain already exists: %s"):format(name))
            end
            return config.toolchain({
                name = name,
                type = values.type or "system",
                cmake = UI.trimmed(values.cmake),
                c = UI.trimmed(values.c),
                cxx = UI.trimmed(values.cxx),
                debugger = UI.trimmed(values.debugger),
                environment = UI.parse_env(values.environment),
            })
        end,
        save = function(value)
            if existing.name then
                state.update_toolchain(existing.name, value)
            else
                state.add_toolchain(value)
            end
        end,
        on_saved = on_saved,
    })
end

return M
