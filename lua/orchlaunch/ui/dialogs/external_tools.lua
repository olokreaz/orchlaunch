-- OrchLaunch — external tools list dialog.

local list = require("orchlaunch.ui.dialogs.list")

local M = {}

function M.open()
    local state = require("orchlaunch.state")
    local editor = require("orchlaunch.ui.editors.external_tool")

    return list.open({
        title = "External Tools",
        new_label = " New tool (a) ",
        items = function()
            return state.external_tools().tools
        end,
        label = function(item)
            return item.name
        end,
        details = function(item)
            return table.concat({
                ("Name:  %s"):format(item.name),
                ("Program:  %s"):format(item.program or "—"),
                ("Working dir:  %s"):format(item.cwd or "${workspace}"),
                ("Arguments:  %s"):format(#(item.args or {}) > 0 and table.concat(item.args, " ") or "—"),
                ("Sudo:  %s"):format(item.sudo and "yes" or "no"),
            }, "\n")
        end,
        find = state.external_tool,
        open = editor.open,
        remove = state.remove_external_tool,
    })
end

return M
