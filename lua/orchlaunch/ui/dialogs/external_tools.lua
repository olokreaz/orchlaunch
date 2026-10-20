-- OrchLaunch — external tools list dialog.
--
-- A spec over the fibrous list dialog; the editor it opens is fibrous too.

local M = {}

function M.open()
    local state = require("orchlaunch.state")
    local editor = require("orchlaunch.ui.fibrous.editors.external_tool")

    local spec = {
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
        remove = state.remove_external_tool,
        open = function(existing, on_saved)
            return editor.open(existing, on_saved)
        end,
    }

    return require("orchlaunch.ui.fibrous.list").open(spec)
end

return M
