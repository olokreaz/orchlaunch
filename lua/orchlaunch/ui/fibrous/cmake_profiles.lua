-- OrchLaunch — CMake profiles dialog, reimplemented on fibrous.
--
-- Prototype on purpose: the generic kit/Volt list engine stays in place for the
-- other dialogs; this module is the fibrous take on the same screen so the two
-- UI stacks can be compared side by side. `M.available()` reports whether
-- fibrous is installed; callers fall back to the kit implementation when it is
-- not, so the plugin keeps working without the dependency.

local M = {}

local ERROR = vim.log.levels.ERROR

--- @return boolean
function M.available()
    return (pcall(require, "fibrous")) == true
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

--- @param profile table
--- @param active? string
--- @return string
local function label_of(profile, active)
    local marker = profile.name == active and "● " or "  "
    local kind = profile.kind and ("  <" .. profile.kind .. ">") or ""
    return marker .. profile.name .. kind
end

--- Opens the fibrous CMake profiles dialog.
--- @return table renderer
function M.open()
    local ok, nr = pcall(require, "fibrous")
    if not ok then
        return require("orchlaunch.ui.dialogs.cmake_profiles").open()
    end

    local ui = nr.ui
    local state = require("orchlaunch.state")
    local profile_editor = require("orchlaunch.ui.fibrous.cmake_profile")
    local project_editor = require("orchlaunch.ui.editors.cmake_project")

    local selected --- state handle, assigned on first render
    local revision --- state handle, bumped to force a re-render after mutations
    local handle

    --- @return table? item
    --- @return integer index
    local function current()
        local profiles = state.cmake_profiles()
        local index = math.min(math.max(1, selected and selected.get() or 1), math.max(1, #profiles))
        return profiles[index], index
    end

    local function refresh()
        revision.set((revision.get() or 0) + 1)
    end

    local function clamp_selection()
        local count = #state.cmake_profiles()
        if count > 0 and (selected.get() or 1) > count then
            selected.set(count)
        end
    end

    local function close()
        pcall(vim.api.nvim_del_augroup_by_name, "OrchlaunchFibrousProfiles")
        if handle then
            handle.unmount()
        end
    end

    local function reopen()
        vim.schedule(function()
            M.open()
        end)
    end

    local function move_to(index)
        local count = #state.cmake_profiles()
        if count == 0 then
            return
        end
        selected.set(math.min(math.max(1, index), count))
    end

    local function open_editor(existing)
        close()
        profile_editor.open(existing, reopen)
    end

    local function new_item()
        open_editor(nil)
    end

    local function edit_item()
        local item = current()
        if not item then
            vim.notify("[orchlaunch] no profile selected", ERROR)
            return
        end
        open_editor(item)
    end

    local function delete_item()
        local item = current()
        if not item then
            vim.notify("[orchlaunch] no profile selected", ERROR)
            return
        end
        if vim.fn.confirm(("Delete %q?"):format(item.name), "&Yes\n&No") ~= 1 then
            return
        end

        state.remove_cmake_profile(item.name)
        state.save()
        clamp_selection()
        refresh()
    end

    local function set_active()
        local item = current()
        if not item then
            vim.notify("[orchlaunch] no profile selected", ERROR)
            return
        end
        state.set_active_cmake_profile(item.name)
        state.save()
        refresh()
    end

    local function import_items()
        local added = state.sync_cmake_profiles()
        state.save()
        refresh()
        vim.notify(("imported %d CMake preset profile(s)"):format(added))
    end

    local function edit_project()
        close()
        project_editor.open(reopen)
    end

    local title = ("CMake Profiles — project: %s"):format(state.cmake_source_dir())

    local function Profiles(ctx)
        revision = ctx.use_state(0)
        if not selected then
            selected = ctx.use_state(1)
        end

        revision.get() -- re-render on demand after state mutations

        local profiles = state.cmake_profiles()
        local active = state.active_cmake_profile()
        local index = math.min(math.max(1, selected.get()), math.max(1, #profiles))
        local item = profiles[index]

        local rows = {}
        local list_width = 0
        if #profiles == 0 then
            rows[1] = {
                comp = ui.label,
                props = { text = "No items yet. Press (a) to create one.", style = { text_hl = "Comment" } },
            }
        else
            for i, profile in ipairs(profiles) do
                local text = label_of(profile, active)
                list_width = math.max(list_width, vim.fn.strwidth(text))
                local is_active = profile.name == active
                rows[#rows + 1] = {
                    comp = ui.label,
                    props = {
                        text = text,
                        role = "button",
                        on_press = function()
                            selected.set(i)
                        end,
                        style = {
                            -- Active vs. non-active is conveyed by color: exactly
                            -- one profile is active at a time.
                            text_hl = is_active and "Title" or "Comment",
                            hl = i == index and "Visual" or nil,
                            _hover = { hl = i == index and "Visual" or "CursorLine" },
                        },
                        align_self = "stretch",
                    },
                }
            end
        end

        -- The list pane is sized to its longest row so names never clip; the
        -- border (1+1) and horizontal padding (1+1) are inside the border box.
        list_width = math.min(math.max(24, list_width + 5), 64)

        local details = item and details_text(item, active) or "No items yet. Press (a) to create one."

        return {
            comp = ui.col,
            props = { grow = 1, gap = 0, style = { padding = { x = 1, y = 1 } } },
            children = {
                {
                    comp = ui.label,
                    props = { text = title, align_self = "center", style = { text_hl = "Title" } },
                },
                {
                    comp = ui.row,
                    props = { grow = 1, gap = 2 },
                    children = {
                        {
                            comp = ui.col,
                            props = {
                                width = list_width,
                                gap = 0,
                                style = { border = "rounded", padding = { x = 1 } },
                            },
                            children = rows,
                        },
                        {
                            comp = ui.col,
                            props = { grow = 1, gap = 0, style = { border = "rounded", padding = { x = 1 } } },
                            children = {
                                { comp = ui.label, props = { text = details, grow = 1 } },
                            },
                        },
                    },
                },
                {
                    comp = ui.label,
                    props = {
                        text = "  a  New profile    e  Edit    D  Delete    A  Set Active",
                        align_self = "center",
                        style = { text_hl = "Comment" },
                    },
                },
                {
                    comp = ui.label,
                    props = {
                        text = "  i  Import presets    p  Project    q/<Esc>  Close",
                        align_self = "center",
                        style = { text_hl = "Comment" },
                    },
                },
            },
        }
    end

    -- Size as a fraction of the editor, clamped so the dialog stays usable on
    -- both tiny and huge screens. `mount` re-reads these on relayout, so the
    -- VimResized handler below just refreshes them and asks for a relayout.
    local mount_opts = { zindex = 50 }

    local function apply_size()
        mount_opts.width = math.max(80, math.floor(vim.o.columns * 0.75))
        mount_opts.height = math.min(math.max(20, math.floor(vim.o.lines * 0.8)), 36)
    end

    apply_size()
    handle = nr.mount(Profiles, {}, mount_opts)
    handle.focus()

    vim.api.nvim_create_autocmd("VimResized", {
        group = vim.api.nvim_create_augroup("OrchlaunchFibrousProfiles", { clear = true }),
        callback = function()
            apply_size()
            if handle then
                handle.relayout()
            end
        end,
    })

    --- @param lhs string
    --- @param rhs function
    local function map(lhs, rhs)
        vim.keymap.set("n", lhs, rhs, { buffer = handle.bufnr, nowait = true, silent = true })
    end

    map("q", close)
    map("<Esc>", close)
    map("j", function()
        move_to((selected and selected.get() or 1) + 1)
    end)
    map("<Down>", function()
        move_to((selected and selected.get() or 1) + 1)
    end)
    map("k", function()
        move_to((selected and selected.get() or 1) - 1)
    end)
    map("<Up>", function()
        move_to((selected and selected.get() or 1) - 1)
    end)
    map("a", new_item)
    map("e", edit_item)
    map("D", delete_item)
    map("A", set_active)
    map("i", import_items)
    map("p", edit_project)

    return handle
end

return M
