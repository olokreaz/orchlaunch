-- OrchLaunch — toolchains list dialog.
--
-- The screen is engine-agnostic: a spec over the list dialog, rendered on
-- fibrous when it is installed and on the kit engine otherwise. The editor it
-- opens makes the same choice internally.

local M = {}

function M.open()
    local state = require("orchlaunch.state")
    local editor = require("orchlaunch.ui.fibrous.editors.toolchain")

    local spec = {
        title = "Toolchains",
        new_label = " New chain (a) ",
        items = function()
            return state.toolchains().toolchains
        end,
        label = function(item)
            return ("%s  (%s)"):format(item.name, item.type or "?")
        end,
        details = function(item)
            return table.concat({
                ("Name:  %s"):format(item.name),
                ("Type:  %s"):format(item.type or "—"),
                ("CMake:  %s"):format(item.cmake or "—"),
                ("C:  %s"):format(item.c or "—"),
                ("C++:  %s"):format(item.cxx or "—"),
                ("Debugger:  %s"):format(item.debugger or "—"),
            }, "\n")
        end,
        find = state.toolchain,
        remove = state.remove_toolchain,
        open = function(existing, on_saved)
            return editor.open(existing, on_saved)
        end,
    }

    local fibrous = require("orchlaunch.ui.fibrous.list")
    if fibrous.available() then
        return fibrous.open(spec)
    end
    return require("orchlaunch.ui.dialogs.list").open(spec)
end

return M
