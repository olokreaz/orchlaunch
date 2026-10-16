-- OrchLaunch — CMake profiles dialog on fibrous.
--
-- A thin spec over `orchlaunch.ui.fibrous.list`: the CMake profile list is just
-- the generic list dialog with a CMake-flavoured label, details formatter and
-- the presets-import / project-editor actions. Callers fall back to the kit
-- implementation when fibrous is not installed.

local list = require("orchlaunch.ui.fibrous.list")

local M = {}

--- @return boolean
function M.available()
    return list.available()
end

--- @param item table
--- @param active? string
--- @return string
local function details_text(item, active)
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
end

--- @param item table
--- @param active? string
--- @return string
local function label_of(item, active)
    local marker = item.name == active and "● " or "  "
    local kind = item.kind and ("  <" .. item.kind .. ">") or ""
    return marker .. item.name .. kind
end

--- Opens the fibrous CMake profiles dialog.
--- @return table handle
function M.open()
    if not M.available() then
        return require("orchlaunch.ui.dialogs.cmake_profiles").open()
    end

    local state = require("orchlaunch.state")
    local profile_editor = require("orchlaunch.ui.fibrous.cmake_profile")
    local project_editor = require("orchlaunch.ui.fibrous.editors.cmake_project")

    return list.open({
        title = ("CMake Profiles — project: %s"):format(state.cmake_source_dir()),
        new_label = " New profile (a) ",
        solo = true,
        items = state.cmake_profiles,
        label = label_of,
        label_hl = function(item, active)
            return item.name == active and "Title" or "Comment"
        end,
        details = details_text,
        find = state.cmake_profile,
        remove = state.remove_cmake_profile,
        active = state.active_cmake_profile,
        set_active = state.set_active_cmake_profile,
        import = function()
            return state.sync_cmake_profiles()
        end,
        import_note = function(added)
            return ("imported %d CMake preset profile(s)"):format(added)
        end,
        project = function(on_saved)
            project_editor.open(on_saved)
        end,
        open = function(existing, on_saved)
            profile_editor.open(existing, on_saved)
        end,
    })
end

return M
