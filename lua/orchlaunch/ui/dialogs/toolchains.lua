-- OrchLaunch — toolchains list dialog.
--
-- A spec over the fibrous list dialog; the editor it opens is fibrous too.

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

    return require("orchlaunch.ui.fibrous.list").open(spec)
end

return M
