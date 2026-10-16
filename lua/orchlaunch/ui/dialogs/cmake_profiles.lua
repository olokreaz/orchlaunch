-- OrchLaunch — CMake profiles list dialog.

local list = require("orchlaunch.ui.dialogs.list")

local M = {}

function M.open()
    local state = require("orchlaunch.state")
    local profile = require("orchlaunch.ui.editors.cmake_profile")
    local project = require("orchlaunch.ui.editors.cmake_project")

    return list.open({
        title = ("CMake Profiles — project: %s"):format(state.cmake_source_dir()),
        new_label = " New profile (a) ",
        list_label = " Profiles ",
        items = function()
            return state.cmake_profiles()
        end,
        label = function(item)
            local active = state.active_cmake_profile()
            local marker = item.name == active and "● " or "  "
            local kind = item.kind and ("  <" .. item.kind .. ">") or ""
            return ("%s%s%s"):format(marker, item.name, kind)
        end,
        details = function(item)
            local active = state.active_cmake_profile()
            local lines = {
                ("Name:  %s%s"):format(item.name, item.name == active and "  (active)" or ""),
                ("Source:  %s"):format(item.kind or "manual"),
            }

            if item.kind then
                lines[#lines + 1] = ("Configure preset:  %s"):format(item.configure_preset or "—")
                lines[#lines + 1] = ("Build preset:  %s"):format(item.build_preset or "—")
                lines[#lines + 1] = ("Toolchain:  %s"):format(item.toolchain or "—")
            else
                lines[#lines + 1] = ("Toolchain:  %s"):format(item.toolchain or "—")
                lines[#lines + 1] = ("Configure preset:  %s"):format(item.configure_preset or "—")
                lines[#lines + 1] = ("Build preset:  %s"):format(item.build_preset or "—")
                lines[#lines + 1] = ("Generator:  %s"):format(item.generator or "—")
                lines[#lines + 1] = ("Build type:  %s"):format(item.build_type or "—")
                lines[#lines + 1] = ("Build dir:  %s"):format(item.build_dir or "—")
            end

            return table.concat(lines, "\n")
        end,
        find = state.cmake_profile,
        open = profile.open,
        project = project.open,
        remove = state.remove_cmake_profile,
        set_active = function(name)
            state.set_active_cmake_profile(name)
            state.save()
        end,
        import = function()
            return state.sync_cmake_profiles()
        end,
        solo = true,
    })
end

return M
