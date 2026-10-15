-- OrchLaunch — editor for the project-wide CMake project directory.

local UI = require("orchlaunch.ui")
local form = require("orchlaunch.ui.form")

local M = {}

--- Edits the project-wide CMake project directory (`[cmake] source_dir`).
--- @param on_saved? function
--- @param opts? table
function M.open(on_saved, opts)
    local n = UI.n()
    local state = require("orchlaunch.state")

    local renderer = UI.renderer(vim.tbl_extend("force", {
        width = math.max(50, math.min(vim.o.columns - 4, 84)),
        height = 15,
    }, opts or {}))

    local function save()
        form.submit(renderer, function()
            local value = vim.trim(form.read_text(renderer, "source_dir"))
            state.set_cmake_source_dir(value ~= "" and value or nil)
        end, on_saved)
    end

    local content = n.rows(
        { flex = 1, direction = "column" },
        n.paragraph({
            id = "cmake_project_hint",
            lines = table.concat({
                "Directory holding CMakeLists.txt and CMakePresets.json.",
                "Leave empty (or \"${workspace}\") to use the .orch project root.",
                ("Resolved: %s"):format(state.cmake_source_dir()),
            }, "\n"),
            max_lines = 3,
        }),
        n.gap(1),
        form.input(n, "source_dir", " CMake project directory ", state.cmake_source_dir_raw(), { autofocus = true }),
        n.gap(1),
        form.footer(n, renderer, save)
    )

    renderer:render(content)
    return renderer
end

return M
