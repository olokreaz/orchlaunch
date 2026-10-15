-- OrchLaunch — editor for the "remote-debug" run configuration.

local UI = require("orchlaunch.ui")
local form = require("orchlaunch.ui.form")

local M = {}

--- @param existing? OrchRemoteDebugConfiguration
--- @param on_saved? function
--- @param opts? table
function M.open(existing, on_saved, opts)
    local n = UI.n()
    local config = require("orchlaunch.config")
    existing = existing or {}

    local build, install, external = form.before_flags(existing.before)
    local targets = require("orchlaunch.cmake").targets()
    local renderer = UI.renderer(vim.tbl_extend("force", { width = 90, height = 26 }, opts or {}))

    local fields = n.rows(
        { flex = 1, direction = "column" },
        form.input(n, "name", " Name ", existing.name, { autofocus = true }),
        n.gap(1),
        form.target_field(n, targets, existing.symbol, " Symbol (CMake target or executable path) ", "symbol", "symbol_choice"),
        n.gap(1),
        form.input(n, "connection", " Connection (host:port) ", existing.connection),
        n.gap(1),
        form.input(n, "adapter", " Adapter (gdb/lldb or executable path) ", existing.adapter),
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

            local value = config.remote_debug({
                name = name,
                symbol = form.read_target(renderer, targets, "symbol", "symbol_choice") or "",
                connection = form.read_text(renderer, "connection"),
                adapter = form.read_text(renderer, "adapter"),
                before = form.collect_before(renderer),
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
