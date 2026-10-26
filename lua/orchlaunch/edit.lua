-- OrchLaunch — Buffer-based JSON editing UI.
--
-- Replaces fibrous-based forms with plain JSON buffer editing.
-- Provides :OrchLaunchEdit, :OrchLaunchNew and validation integration.

local config = require("orchlaunch.config")
local jsonpos = require("orchlaunch.jsonpos")
local state = require("orchlaunch.state")
local validate = require("orchlaunch.validate")

local M = {}

local WARN = vim.log.levels.WARN
local ERROR = vim.log.levels.ERROR

---@class EditOptions
---@field window? "split" | "vsplit" | "float" | "tab"
---@field fold_others? boolean
---@field close_on_write? boolean
---@field whole_file? boolean Open the file directly, without the entry picker.

--- Floating editor windows opened by this module, keyed by buffer number.
---@type table<integer, integer>
local float_windows = {}

--- Returns the configured edit options (see `orchlaunch.options`).
---@return EditOptions
local function get_edit_opts()
    return vim.deepcopy(require("orchlaunch.options").get().ui.edit)
end

--- Returns true when `win` is one of our floating editor windows.
---@param win integer
---@param bufnr integer
---@return boolean
local function is_managed_float(win, bufnr)
    return float_windows[bufnr] == win
        and vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_config(win).relative ~= ""
end

--- Closes the floating editor showing `bufnr`, if it is still open.
---@param bufnr? integer
---@return boolean closed
function M.close_float(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local win = float_windows[bufnr]
    if not win or not vim.api.nvim_win_is_valid(win) then
        float_windows[bufnr] = nil
        return false
    end
    if vim.bo[bufnr].modified then
        vim.notify("[orchlaunch] unsaved changes; use :wq to save and close", WARN)
        return false
    end
    float_windows[bufnr] = nil
    vim.api.nvim_win_close(win, false)
    return true
end

--- Installs `q`/`<Esc>` close keys for a floating editor buffer. Outside the
--- float the keys fall through to their normal meaning (e.g. `q` macros).
---@param bufnr integer
local function set_float_close_keys(bufnr)
    for _, lhs in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", lhs, function()
            if is_managed_float(vim.api.nvim_get_current_win(), bufnr) then
                -- Window changes are not allowed while a mapping is running.
                vim.schedule(function()
                    M.close_float(bufnr)
                end)
                return ""
            end
            return lhs
        end, {
            buffer = bufnr,
            expr = true,
            replace_keycodes = true,
            nowait = true,
            silent = true,
            desc = "Close the OrchLaunch editor",
        })
    end
end

--- Opens a file in the configured window style.
---@param path string
---@param opts? EditOptions
---@return integer bufnr
local function open_file_window(path, opts)
    opts = opts or get_edit_opts()

    local cmd
    if opts.window == "vsplit" then
        cmd = "vsplit"
    elseif opts.window == "float" then
        cmd = "float"
    elseif opts.window == "tab" then
        cmd = "tabnew"
    else
        cmd = "split"
    end

    if cmd == "float" then
        local bufnr = vim.fn.bufadd(path)
        vim.fn.bufload(bufnr)
        local width = math.floor(vim.o.columns * 0.8)
        local height = math.floor(vim.o.lines * 0.8)
        local row = math.floor((vim.o.lines - height) / 2)
        local col = math.floor((vim.o.columns - width) / 2)
        local win = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = width,
            height = height,
            row = row,
            col = col,
            style = "minimal",
            border = "rounded",
        })
        float_windows[bufnr] = win
        set_float_close_keys(bufnr)
        return bufnr
    else
        vim.cmd(cmd .. " " .. vim.fn.fnameescape(path))
        return vim.api.nvim_get_current_buf()
    end
end

--- Description of every file the editor can open.
---@class OrchEditFileSpec
---@field label string Text shown in the file picker.
---@field lists? string[][] Candidate key paths of the entry list inside the file.

---@type table<string, OrchEditFileSpec>
local FILES = {
    run_configurations = {
        label = "run_configurations.json (configurations)",
        lists = { { "configurations" } },
    },
    external_tools = {
        label = "external_tools.json (external tools)",
        lists = { { "tools" } },
    },
    toolchain = {
        label = "toolchain.json (toolchains)",
        lists = { { "toolchains" } },
    },
    cmake_settings = {
        label = "cmake_settings.json (CMake profiles)",
        lists = { { "cmake", "profiles" }, { "settings", "profiles" } },
    },
    breakpoints = {
        label = "breakpoints.json (breakpoints)",
    },
}

--- File types offered by the interactive picker, in display order.
local PICKER_ORDER = { "run_configurations", "external_tools", "toolchain", "cmake_settings" }

---@class OrchEditEntry
---@field name string
---@field label string
---@field line integer 0-indexed line of the "name" key.
---@field col integer
---@field start_line integer 0-indexed first line of the entry object.
---@field end_line integer 0-indexed last line of the entry object.

--- Reads a file's text, preferring the loaded buffer (so unsaved edits count).
---@param path string
---@return string? text
local function read_source(path)
    local bufnr = vim.fn.bufnr(vim.fn.fnamemodify(path, ":p"))
    if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
        return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    end
    if vim.fn.filereadable(path) == 1 then
        return table.concat(vim.fn.readfile(path), "\n")
    end
    return nil
end

--- Lists the named entries of a parsed document.
---@param root OrchJsonNode
---@param file_type string
---@return OrchEditEntry[]
local function entries_of(root, file_type)
    local out = {}
    local spec = FILES[file_type]
    if not spec or not spec.lists then
        return out
    end
    for _, path in ipairs(spec.lists) do
        local list = jsonpos.get_path(root, path)
        if list and list.kind == "array" then
            for _, item in ipairs(list.items) do
                if item.kind == "object" then
                    local member = jsonpos.member(item, "name")
                    if member and member.value.kind == "string" then
                        local kind = jsonpos.get_string(item, "type") or jsonpos.get_string(item, "kind") or "profile"
                        out[#out + 1] = {
                            name = member.value.value,
                            label = ("%s (%s)"):format(member.value.value, kind),
                            line = member.key_line,
                            col = member.key_col,
                            start_line = item.line,
                            end_line = item.end_line,
                        }
                    end
                end
            end
            break
        end
    end
    return out
end

--- Returns the path of a file type in the loaded project.
---@param file_type string
---@return string?
local function path_for(file_type)
    local paths = state.get().paths
    return paths[file_type]
end

--- Finds the entry called `name` in a buffer. Positions are 0-indexed.
---@param bufnr integer
---@param name string
---@param file_type? string Defaults to the file type derived from the buffer name.
---@return OrchEditEntry?
function M.find_entry(bufnr, name, file_type)
    file_type = file_type or vim.fs.basename(vim.api.nvim_buf_get_name(bufnr)):gsub("%.json$", "")
    local root = jsonpos.parse_buffer(bufnr)
    if not root then
        return nil
    end
    for _, entry in ipairs(entries_of(root, file_type)) do
        if entry.name == name then
            return entry
        end
    end
    return nil
end

--- Folds every entry except `keep` in window `win` (window-local, the file is
--- not modified).
---@param win integer
---@param entries OrchEditEntry[]
---@param keep OrchEditEntry
local function fold_others(win, entries, keep)
    vim.wo[win].foldmethod = "manual"
    vim.wo[win].foldenable = true
    vim.api.nvim_win_call(win, function()
        vim.cmd("silent! normal! zE")
        for _, entry in ipairs(entries) do
            if entry ~= keep and entry.end_line > entry.start_line then
                vim.cmd(("silent! %d,%dfold"):format(entry.start_line + 1, entry.end_line + 1))
            end
        end
    end)
end

--- Opens `path` in a window and optionally jumps to an entry.
---@param file_type string
---@param path string
---@param entry_name? string
---@param opts EditOptions
local function open_path(file_type, path, entry_name, opts)
    if vim.fn.filereadable(path) == 0 then
        local spec = FILES[file_type]
        vim.notify(
            ("[orchlaunch] %s does not exist yet"):format(spec and spec.label or path),
            WARN
        )
        return
    end

    local bufnr = open_file_window(path, opts)
    local win = vim.api.nvim_get_current_win()
    vim.bo[bufnr].filetype = "json"
    -- Pick up changes the plugin wrote after this buffer was loaded.
    if not vim.bo[bufnr].modified then
        vim.cmd("silent! checktime " .. bufnr)
    end

    if entry_name then
        local root = jsonpos.parse_buffer(bufnr)
        local entries = root and entries_of(root, file_type) or {}
        local target
        for _, entry in ipairs(entries) do
            if entry.name == entry_name then
                target = entry
                break
            end
        end
        if target then
            vim.api.nvim_win_set_cursor(win, { target.line + 1, target.col })
            vim.cmd("normal! zz")
            if opts.fold_others then
                fold_others(win, entries, target)
            end
        else
            vim.notify(("[orchlaunch] entry %q not found in %s"):format(entry_name, vim.fs.basename(path)), WARN)
        end
    end

    if file_type == "run_configurations" then
        M.show_virtual_text(bufnr)
    end
end

--- Opens a configuration file for editing.
---
--- Without `file_type` a picker asks which file to open. For list files
--- (configurations, tools, toolchains, CMake profiles) a second picker offers a
--- specific entry or "Open whole file"; the cursor then jumps to the entry.
--- Pass `opts.whole_file = true` or an `entry_name` to skip that picker.
---@param file_type? "run_configurations" | "external_tools" | "toolchain" | "cmake_settings" | "breakpoints"
---@param entry_name? string
---@param opts? EditOptions
function M.open(file_type, entry_name, opts)
    if not state.is_loaded() then
        local create = vim.fn.confirm("No .orch project found. Create one?", "&Yes\n&No", 1)
        if create == 1 then
            require("orchlaunch").create_project()
        else
            return
        end
        if not state.is_loaded() then
            return
        end
    end

    opts = vim.tbl_extend("force", get_edit_opts(), opts or {})

    -- 1. Which file?
    if not file_type then
        local available = {}
        for _, key in ipairs(PICKER_ORDER) do
            local path = path_for(key)
            if path and vim.fn.filereadable(path) == 1 then
                available[#available + 1] = key
            end
        end
        if #available == 0 then
            vim.notify("[orchlaunch] no configuration files found", WARN)
            return
        end
        if #available == 1 then
            return M.open(available[1], entry_name, opts)
        end
        vim.ui.select(available, {
            prompt = "Open which configuration file?",
            format_item = function(key)
                return FILES[key].label
            end,
        }, function(choice)
            if choice then
                M.open(choice, entry_name, opts)
            end
        end)
        return
    end

    local path = path_for(file_type)
    if not path or not FILES[file_type] then
        vim.notify(("[orchlaunch] unknown file type: %s"):format(tostring(file_type)), ERROR)
        return
    end

    -- 2. Which entry? (only for list files, only when nothing was requested)
    if not entry_name and not opts.whole_file and FILES[file_type].lists then
        local text = read_source(path)
        local root = text and jsonpos.parse(text)
        local entries = root and entries_of(root, file_type) or {}
        if #entries > 0 then
            local items = { { whole = true, label = "Open whole file" } }
            for _, entry in ipairs(entries) do
                items[#items + 1] = { name = entry.name, label = entry.label }
            end
            vim.ui.select(items, {
                prompt = "Open which entry?",
                format_item = function(item)
                    return item.label
                end,
            }, function(choice)
                if not choice then
                    return
                end
                if choice.whole then
                    M.open(file_type, nil, vim.tbl_extend("force", opts, { whole_file = true }))
                else
                    M.open(file_type, choice.name, opts)
                end
            end)
            return
        end
    end

    open_path(file_type, path, entry_name, opts)
end

--- Describes what a native configuration's `target` resolves to, without
--- spawning any process.
---@param target string
---@return string text
---@return boolean found
function M.describe_target(target)
    local resolved = state.resolve_path(target)
    local looks_like_path = target:find("[/\\]") ~= nil or vim.fn.filereadable(resolved or "") == 1
    if looks_like_path then
        if resolved and vim.fn.filereadable(resolved) == 1 then
            return resolved, true
        end
        return (resolved or target) .. " (file not found)", false
    end
    local cmake = require("orchlaunch.cmake")
    local artifact = cmake.find_target(target)
    if artifact then
        return artifact, true
    end
    if cmake.target(target) then
        return "target not built yet", false
    end
    return "target not found", false
end

--- Shows virtual text with the resolved executable of native configurations.
---@param bufnr integer
function M.show_virtual_text(bufnr)
    local ns = vim.api.nvim_create_namespace("orchlaunch_virtual")
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

    if not vim.api.nvim_buf_is_valid(bufnr) or not state.is_loaded() then
        return
    end
    if not require("orchlaunch.options").get().ui.virtual_text then
        return
    end

    local root = jsonpos.parse_buffer(bufnr)
    local list = root and jsonpos.get(root, "configurations")
    if not list or list.kind ~= "array" then
        return
    end

    for _, item in ipairs(list.items) do
        if item.kind == "object" and jsonpos.get_string(item, "type") == "native" then
            local target = jsonpos.get_string(item, "target")
            if target and target ~= "" then
                local text, found = M.describe_target(target)
                vim.api.nvim_buf_set_extmark(bufnr, ns, item.line, -1, {
                    virt_text = { { "   " .. text, found and "Comment" or "DiagnosticHint" } },
                    virt_text_pos = "eol",
                })
            end
        end
    end
end

--- Creates a new configuration entry.
---@param config_type? "native" | "remote-debug" | "compound" | "external_tool" | "toolchain" | "cmake_profile"
function M.new(config_type)
    if not state.is_loaded() then
        local create = vim.fn.confirm("No .orch project found. Create one?", "&Yes\n&No", 1)
        if create == 1 then
            require("orchlaunch").create_project()
        else
            return
        end
        if not state.is_loaded() then
            return
        end
    end

    local types = { "native", "remote-debug", "compound", "external_tool", "toolchain", "cmake_profile" }

    --- Adds `entry`, saves, and opens the file at the new entry. State helpers
    --- assert on duplicate names, so failures are reported instead of raised.
    local function add_and_open(add, entry, file_type)
        local ok, err = pcall(add, entry)
        if not ok then
            vim.notify((tostring(err):gsub("^%[orchlaunch%]%s*", "[orchlaunch] ")), ERROR)
            return
        end
        local saved, save_err = pcall(state.save)
        if not saved then
            vim.notify("[orchlaunch] " .. tostring(save_err), ERROR)
            return
        end
        M.open(file_type, entry.name, { whole_file = true })
    end

    local function ask_name(prompt, on_name)
        vim.ui.input({ prompt = prompt }, function(name)
            name = name and vim.trim(name) or ""
            if name ~= "" then
                on_name(name)
            end
        end)
    end

    local function do_create(ctype)
        if ctype == "native" then
            ask_name("Configuration name: ", function(name)
                add_and_open(state.add_configuration, config.native({ name = name }), "run_configurations")
            end)
        elseif ctype == "remote-debug" then
            ask_name("Configuration name: ", function(name)
                vim.ui.input({ prompt = "Connection (host:port): " }, function(conn)
                    if not conn or vim.trim(conn) == "" then
                        return
                    end
                    add_and_open(
                        state.add_configuration,
                        config.remote_debug({ name = name, connection = vim.trim(conn) }),
                        "run_configurations"
                    )
                end)
            end)
        elseif ctype == "compound" then
            ask_name("Configuration name: ", function(name)
                local remaining = {}
                for _, c in ipairs(state.run_configurations().configurations) do
                    remaining[#remaining + 1] = c.name
                end
                local chosen = {}
                local function pick()
                    if #remaining == 0 then
                        return add_and_open(
                            state.add_configuration,
                            config.compound({ name = name, configurations = chosen }),
                            "run_configurations"
                        )
                    end
                    local items = vim.list_extend({}, remaining)
                    items[#items + 1] = "<done>"
                    vim.ui.select(items, {
                        prompt = ("Add a child to %q (%d selected):"):format(name, #chosen),
                    }, function(child)
                        if not child then
                            return
                        end
                        if child ~= "<done>" then
                            chosen[#chosen + 1] = child
                            remaining = vim.tbl_filter(function(n)
                                return n ~= child
                            end, remaining)
                            return pick()
                        end
                        add_and_open(
                            state.add_configuration,
                            config.compound({ name = name, configurations = chosen }),
                            "run_configurations"
                        )
                    end)
                end
                pick()
            end)
        elseif ctype == "external_tool" then
            ask_name("Tool name: ", function(name)
                vim.ui.input({ prompt = "Program path: " }, function(prog)
                    if not prog or vim.trim(prog) == "" then
                        return
                    end
                    add_and_open(
                        state.add_external_tool,
                        config.external_tool({ name = name, program = vim.trim(prog) }),
                        "external_tools"
                    )
                end)
            end)
        elseif ctype == "toolchain" then
            ask_name("Toolchain name: ", function(name)
                add_and_open(
                    state.add_toolchain,
                    config.toolchain({
                        name = name,
                        type = "unix",
                        cmake = "cmake",
                        c = "gcc",
                        cxx = "g++",
                        debugger = "lldb",
                    }),
                    "toolchain"
                )
            end)
        elseif ctype == "cmake_profile" then
            ask_name("Profile name: ", function(name)
                add_and_open(state.add_cmake_profile, config.cmake_settings({ name = name }), "cmake_settings")
            end)
        else
            vim.notify(("[orchlaunch] unknown type: %s (expected one of: %s)"):format(
                tostring(ctype),
                table.concat(types, ", ")
            ), WARN)
        end
    end

    if config_type then
        do_create(config_type)
    else
        vim.ui.select(types, { prompt = "Create new:" }, function(choice)
            if choice then
                do_create(choice)
            end
        end)
    end
end

--- Returns whether a buffer is an OrchLaunch config buffer.
---@param bufnr integer
---@return boolean
local function is_orch_buffer(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then return false end
    return vim.fs.find(".orch", { path = vim.fs.dirname(name), upward = true })[1] ~= nil
end

--- Validates the current buffer and shows diagnostics.
---@param bufnr? integer
function M.validate_buffer(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not is_orch_buffer(bufnr) then return end
    validate.validate_buffer(bufnr)
end

--- Sets up autocommands for validation and virtual text.
function M.setup_autocmds()
    local group = vim.api.nvim_create_augroup("OrchLaunchEdit", { clear = true })

    -- Validate on write, after the project state picked the change up.
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        pattern = "*/.orch/*.json",
        callback = function(args)
            if state.is_loaded() then
                state.reload_if_changed()
            end
            M.validate_buffer(args.buf)
            if vim.fs.basename(args.file) == "run_configurations.json" then
                M.show_virtual_text(args.buf)
            end
            -- Floating editors behave like a form: saving closes them.
            if require("orchlaunch.options").get().ui.edit.close_on_write then
                vim.schedule(function()
                    M.close_float(args.buf)
                end)
            end
        end,
    })

    -- Forget a floating window once it is closed by any means.
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(args)
            local closed = tonumber(args.match)
            for bufnr, win in pairs(float_windows) do
                if win == closed then
                    float_windows[bufnr] = nil
                end
            end
        end,
    })

    -- Debounced validation while typing. One reusable timer per buffer.
    local timers = {}
    local function stop_timer(bufnr)
        local timer = timers[bufnr]
        if timer then
            timers[bufnr] = nil
            if not timer:is_closing() then
                timer:stop()
                timer:close()
            end
        end
    end

    vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
        group = group,
        pattern = "*/.orch/*.json",
        callback = function(args)
            local bufnr = args.buf
            stop_timer(bufnr)
            local timer = vim.uv.new_timer()
            timers[bufnr] = timer
            timer:start(300, 0, function()
                vim.schedule(function()
                    stop_timer(bufnr)
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        M.validate_buffer(bufnr)
                    end
                end)
            end)
        end,
    })

    -- Clean up on buffer delete.
    vim.api.nvim_create_autocmd("BufDelete", {
        group = group,
        pattern = "*/.orch/*.json",
        callback = function(args)
            stop_timer(args.buf)
            validate.clear_diagnostics(args.buf)
        end,
    })

    -- Update virtual text on cursor hold (less frequent).
    vim.api.nvim_create_autocmd("CursorHold", {
        group = group,
        pattern = "*/.orch/run_configurations.json",
        callback = function(args)
            M.show_virtual_text(args.buf)
        end,
    })
end

return M
