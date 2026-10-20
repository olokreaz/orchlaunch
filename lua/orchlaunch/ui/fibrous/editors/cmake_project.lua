-- OrchLaunch — CMake project directory editor on fibrous.

local form = require("orchlaunch.ui.fibrous.form")

local M = {}

--- Edits the project-wide CMake project directory (`[cmake] source_dir`).
--- @param on_saved? function
--- @param opts? table
function M.open(on_saved, opts)
    local ui = require("fibrous").ui
    local state = require("orchlaunch.state")

    return form.open({
        augroup = "OrchlaunchFibrousCMakeProject",
        title = "  CMake project directory",
        size = function(o)
            o.width = math.max(50, math.min(vim.o.columns - 4, 84))
            o.height = 15
        end,
        on_saved = on_saved,
        initial = {
            source_dir = state.cmake_source_dir_raw() or "",
        },
        render = function(_, f)
            local hint = table.concat({
                "Directory holding CMakeLists.txt and CMakePresets.json.",
                'Leave empty (or "${workspace}") to use the .orch project root.',
                ("Resolved: %s"):format(state.cmake_source_dir()),
            }, "\n")
            return {
                comp = ui.col,
                props = { grow = 1, gap = 0, style = { padding = { x = 1, y = 1 } } },
                children = {
                    f.centered(f.title()),
                    { comp = ui.label, props = { text = hint, style = { text_hl = "Comment" } } },
                    f.field_label("Project dir", f.text("source_dir", { singleline = true, grow = 1 })),
                    f.footer("<C-s> Save  ·  Tab/s field  ·  q/<Esc> close"),
                },
            }
        end,
        collect = function(values)
            local value = vim.trim(values.source_dir or "")
            return value ~= "" and value or nil
        end,
        save = function(value)
            state.set_cmake_source_dir(value)
        end,
    })
end

return M
