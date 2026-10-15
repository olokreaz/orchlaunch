-- OrchLaunch — toolchains list dialog.

local list = require("orchlaunch.ui.dialogs.list")

local M = {}

function M.open()
    local state = require("orchlaunch.state")
    local editor = require("orchlaunch.ui.editors.toolchain")

    return list.open({
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
        open = editor.open,
        remove = state.remove_toolchain,
    })
end

return M
