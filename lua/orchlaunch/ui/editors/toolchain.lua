-- OrchLaunch — editor for toolchains.

local UI = require("orchlaunch.ui")
local form = require("orchlaunch.ui.form")

local M = {}

--- @param existing? OrchToolchain
--- @param on_saved? function
function M.open(existing, on_saved)
    local n = UI.n()
    local config = require("orchlaunch.config")
    existing = existing or {}

    local renderer = UI.renderer({ width = 90, height = 22 })

    local fields = n.rows(
        { flex = 1, direction = "column" },
        form.input(n, "name", " Name ", existing.name, { autofocus = true }),
        n.gap(1),
        form.chooser(n, "type", " Type (system/unix/msvc) ", { "system", "unix", "msvc" }, existing.type or "system"),
        n.gap(1),
        form.input(n, "cmake", " CMake ", existing.cmake),
        n.gap(1),
        form.input(n, "c", " C compiler ", existing.c),
        n.gap(1),
        form.input(n, "cxx", " C++ compiler ", existing.cxx),
        n.gap(1),
        form.input(n, "debugger", " Debugger (gdb/lldb/lldb-vscode) ", existing.debugger)
    )

    local function save()
        form.submit(renderer, function()
            local name = vim.trim(form.read_text(renderer, "name"))
            assert(name ~= "", "toolchain name is required")

            local state = require("orchlaunch.state")
            if not existing.name and state.toolchain(name) then
                error(("toolchain already exists: %s"):format(name))
            end

            local value = config.toolchain({
                name = name,
                type = form.read_choice(renderer, "type", existing.type or "system"),
                cmake = form.read_text(renderer, "cmake"),
                c = form.read_text(renderer, "c"),
                cxx = form.read_text(renderer, "cxx"),
                debugger = form.read_text(renderer, "debugger"),
            })

            if existing.name then
                state.update_toolchain(existing.name, value)
            else
                state.add_toolchain(value)
            end
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
