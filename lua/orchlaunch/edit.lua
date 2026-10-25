-- OrchLaunch — Buffer-based JSON editing UI.
--
-- Replaces fibrous-based forms with plain JSON buffer editing.
-- Provides :OrchLaunchEdit, :OrchLaunchNew and validation integration.

local config = require("orchlaunch.config")
local state = require("orchlaunch.state")
local validate = require("orchlaunch.validate")

local M = {}

local WARN = vim.log.levels.WARN
local ERROR = vim.log.levels.ERROR
local INFO = vim.log.levels.INFO

---@class EditOptions
---@field window? "split" | "vsplit" | "float" | "tab"
---@field fold_others? boolean
---@field whole_file? boolean Open the file directly, without the entry picker.

--- Returns the configured edit options (see `orchlaunch.options`).
---@return EditOptions
local function get_edit_opts()
    return vim.deepcopy(require("orchlaunch.options").get().ui.edit)
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
        vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = width,
            height = height,
            row = row,
            col = col,
            style = "minimal",
            border = "rounded",
        })
        return bufnr
    else
        vim.cmd(cmd .. " " .. vim.fn.fnameescape(path))
        return vim.api.nvim_get_current_buf()
    end
end

--- Folds all entries except the one at the given line (0-indexed).
---@param bufnr integer
---@param keep_line integer
local function fold_others(bufnr, keep_line)
    if not vim.wo.foldenable then return end
    local old_foldmethod = vim.wo.foldmethod
    vim.wo.foldmethod = "manual"
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    for i = 1, line_count do
        if i - 1 ~= keep_line then
            pcall(vim.api.nvim_win_call, 0, function()
                vim.cmd(i .. "foldclose")
            end)
        end
    end
    vim.wo.foldmethod = old_foldmethod
end

--- Finds the line number (0-indexed) of a configuration entry by name.
---@param bufnr integer
---@param name string
---@return integer?
local function find_entry_line(bufnr, name)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local in_configurations = false
    local brace_depth = 0
    local in_object = false
    local current_name = nil

    for i, line in ipairs(lines) do
        -- Track brace depth to know when we're inside configurations array
        for _, ch in ipairs(vim.fn.split(line, "")) do
            if ch == "{" then
                brace_depth = brace_depth + 1
            elseif ch == "}" then
                brace_depth = brace_depth - 1
            elseif ch == "[" then
                -- entering array
            elseif ch == "]" then
                -- leaving array
            end
        end

        -- Look for "name": "value" pattern at the right depth
        local match = line:match('"name"%s*:%s*"([^"]+)"')
        if match and brace_depth >= 2 then
            if match == name then
                return i - 1 -- 0-indexed
            end
        end
    end
    return nil
end

--- Lists available configuration files for selection.
---@return string[]
local function list_config_files()
    if not state.is_loaded() then return {} end
    local paths = state.get().paths
    local files = {}
    if vim.fn.filereadable(paths.run_configurations) == 1 then
        files[#files + 1] = "run_configurations.json (configurations)"
    end
    if vim.fn.filereadable(paths.external_tools) == 1 then
        files[#files + 1] = "external_tools.json (external tools)"
    end
    if vim.fn.filereadable(paths.toolchain) == 1 then
        files[#files + 1] = "toolchain.json (toolchains)"
    end
    if vim.fn.filereadable(paths.cmake_settings) == 1 then
        files[#files + 1] = "cmake_settings.json (CMake profiles)"
    end
    return files
end

--- Maps display name to file path.
---@param display string
---@return string?
local function display_to_path(display)
    if display:match("^run_configurations") then
        return state.get().paths.run_configurations
    elseif display:match("^external_tools") then
        return state.get().paths.external_tools
    elseif display:match("^toolchain") then
        return state.get().paths.toolchain
    elseif display:match("^cmake_settings") then
        return state.get().paths.cmake_settings
    end
    return nil
end

--- Lists entries (configurations, tools, toolchains) in a file for selection.
---@param path string
---@return string[]
local function list_entries_in_file(path)
    local data, err = config.load(path)
    if not data then return {} end

    local entries = {}
    local key_map = {
        run_configurations = "configurations",
        external_tools = "tools",
        toolchain = "toolchains",
        cmake_settings = function(d)
            if d.cmake and d.cmake.profiles then return d.cmake.profiles end
            if d.settings and d.settings.profiles then return d.settings.profiles end
            return {}
        end,
    }

    local get_key = key_map[vim.fs.basename(path):gsub("%.json$", "")]
    local list = type(get_key) == "function" and get_key(data) or data[get_key]

    if type(list) == "table" then
        for _, item in ipairs(list) do
            if type(item) == "table" and type(item.name) == "string" then
                local typ = item.type or item.kind or "profile"
                entries[#entries + 1] = string.format("%s (%s)", item.name, typ)
            end
        end
    end
    return entries
end

--- Maps entry display name back to entry name.
---@param display string
---@return string?
local function entry_display_to_name(display)
    return display:match("^(.+) %(")
end

--- Opens a configuration file for editing.
---@param file_type? "run_configurations" | "external_tools" | "toolchain" | "cmake_settings" | "breakpoints"
---@param entry_name? string
---@param opts? EditOptions
function M.open(file_type, entry_name, opts)
    if not state.is_loaded() then
        -- Offer to create project
        local create = vim.fn.confirm("No .orch project found. Create one?", "&Yes\n&No", 1)
        if create == 1 then
            require("orchlaunch").create_project()
        else
            return
        end
        if not state.is_loaded() then return end
    end

    local paths = state.get().paths
    local path

    if file_type then
        local path_map = {
            run_configurations = paths.run_configurations,
            external_tools = paths.external_tools,
            toolchain = paths.toolchain,
            cmake_settings = paths.cmake_settings,
            breakpoints = paths.breakpoints,
        }
        path = path_map[file_type]
    end

    if not path then
        -- Interactive selection of file
        local files = list_config_files()
        if #files == 0 then
            vim.notify("[orchlaunch] no configuration files found", WARN)
            return
        end
        if #files == 1 then
            path = display_to_path(files[1])
        else
            vim.ui.select(files, { prompt = "Open which configuration file?" }, function(choice)
                if not choice then return end
                M.open(nil, entry_name, opts) -- will pick up the choice via display_to_path
            end)
            return
        end
    end

    if not path then return end

    -- If no entry_name specified and it's a list file, offer to pick an entry
    if not entry_name and vim.tbl_contains({ "run_configurations", "external_tools", "toolchain", "cmake_settings" }, file_type) then
        local entries = list_entries_in_file(path)
        if #entries > 0 then
            table.insert(entries, 1, "Open whole file")
            vim.ui.select(entries, { prompt = "Open which entry?" }, function(choice)
                if not choice then return end
                if choice == "Open whole file" then
                    M.open(file_type, nil, opts)
                else
                    local name = entry_display_to_name(choice)
                    M.open(file_type, name, opts)
                end
            end)
            return
        end
    end

    -- Ensure file exists
    if vim.fn.filereadable(path) == 0 then
        local ok, err = config.save(path, config.run_configurations())
        if not ok then
            vim.notify("[orchlaunch] " .. (err or "failed to create file"), ERROR)
            return
        end
    end

    local bufnr = open_file_window(path, opts)

    -- Set filetype for JSON syntax highlighting
    vim.bo[bufnr].filetype = "json"

    -- If entry_name provided, jump to that entry
    if entry_name then
        vim.defer_fn(function()
            local line = find_entry_line(bufnr, entry_name)
            if line then
                vim.api.nvim_win_set_cursor(0, { line + 1, 0 })
                vim.cmd("normal! zz")
                if get_edit_opts().fold_others then
                    fold_others(bufnr, line)
                end
            end
        end, 50)
    end

    -- Show virtual text for native configurations (resolved executable path)
    if file_type == "run_configurations" then
        M.show_virtual_text(bufnr)
    end
end

--- Shows virtual text with resolved executable path for native configurations.
---@param bufnr integer
function M.show_virtual_text(bufnr)
    local ns = vim.api.nvim_create_namespace("orchlaunch_virtual")
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

    if not state.is_loaded() then return end
    if not require("orchlaunch.options").get().ui.virtual_text then return end

    local data = config.load(state.get().paths.run_configurations)
    if not data or not data.configurations then return end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local in_configurations = false
    local brace_depth = 0
    local current_config = {}
    local config_start_line = nil

    for i, line in ipairs(lines) do
        local trimmed = line:match("^%s*(.*)") or ""

        -- Track entry into configurations array
        if trimmed:match('"configurations"%s*:%s*%[') then
            in_configurations = true
        end

        if in_configurations then
            for _, ch in ipairs(vim.fn.split(line, "")) do
                if ch == "{" then
                    if brace_depth == 1 then
                        config_start_line = i - 1
                        current_config = {}
                    end
                    brace_depth = brace_depth + 1
                elseif ch == "}" then
                    brace_depth = brace_depth - 1
                    if brace_depth == 1 and config_start_line then
                        -- End of a configuration object
                        if current_config.type == "native" then
                            local target = current_config.target
                            local resolved = target and state.resolve_path(target)
                            local text = resolved and ("   " .. resolved) or "   target not found"
                            vim.api.nvim_buf_set_extmark(bufnr, ns, config_start_line, -1, {
                                virt_text = { { text, "Comment" } },
                                virt_text_pos = "eol",
                            })
                        end
                        config_start_line = nil
                    end
                end
            end

            -- Capture key-value pairs inside the config object
            if brace_depth >= 2 then
                local key, val = line:match('"(%w+)"%s*:%s*"([^"]*)"')
                if key and val then
                    current_config[key] = val
                end
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
        if not state.is_loaded() then return end
    end

    local types = { "native", "remote-debug", "compound", "external_tool", "toolchain", "cmake_profile" }

    local function do_create(ctype)
        if ctype == "native" then
            vim.ui.input({ prompt = "Configuration name: " }, function(name)
                if not name or name == "" then return end
                local cfg = config.native({ name = name })
                state.add_configuration(cfg)
                state.save()
                M.open("run_configurations", name)
            end)
        elseif ctype == "remote-debug" then
            vim.ui.input({ prompt = "Configuration name: " }, function(name)
                if not name or name == "" then return end
                vim.ui.input({ prompt = "Connection (host:port): " }, function(conn)
                    if not conn or conn == "" then return end
                    local cfg = config.remote_debug({ name = name, connection = conn })
                    state.add_configuration(cfg)
                    state.save()
                    M.open("run_configurations", name)
                end)
            end)
        elseif ctype == "compound" then
            vim.ui.input({ prompt = "Configuration name: " }, function(name)
                if not name or name == "" then return end
                local configs = state.run_configurations().configurations
                local names = {}
                for _, c in ipairs(configs) do names[#names + 1] = c.name end
                vim.ui.select(names, { prompt = "Select child configurations (multi-select not supported, pick first):" }, function(child)
                    if not child then return end
                    local cfg = config.compound({ name = name, configurations = { child } })
                    state.add_configuration(cfg)
                    state.save()
                    M.open("run_configurations", name)
                end)
            end)
        elseif ctype == "external_tool" then
            vim.ui.input({ prompt = "Tool name: " }, function(name)
                if not name or name == "" then return end
                vim.ui.input({ prompt = "Program path: " }, function(prog)
                    if not prog or prog == "" then return end
                    local tool = config.external_tool({ name = name, program = prog })
                    state.add_external_tool(tool)
                    state.save()
                    M.open("external_tools", name)
                end)
            end)
        elseif ctype == "toolchain" then
            vim.ui.input({ prompt = "Toolchain name: " }, function(name)
                if not name or name == "" then return end
                local toolchain = config.toolchain({
                    name = name,
                    type = "unix",
                    cmake = "cmake",
                    c = "gcc",
                    cxx = "g++",
                    debugger = "lldb",
                })
                state.add_toolchain(toolchain)
                state.save()
                M.open("toolchain", name)
            end)
        elseif ctype == "cmake_profile" then
            vim.ui.input({ prompt = "Profile name: " }, function(name)
                if not name or name == "" then return end
                local profile = config.cmake_settings({ name = name })
                state.add_cmake_profile(profile)
                state.save()
                M.open("cmake_settings", name)
            end)
        end
    end

    if config_type then
        do_create(config_type)
    else
        vim.ui.select(types, { prompt = "Create new:" }, function(choice)
            if choice then do_create(choice) end
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

    -- Validate on write
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        pattern = "*/.orch/*.json",
        callback = function(args)
            M.validate_buffer(args.buf)
            -- Reload state to pick up changes
            if state.is_loaded() then
                state.reload_if_changed()
            end
        end,
    })

    -- Debounced validation on text change
    local timers = {}
    vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
        group = group,
        pattern = "*/.orch/*.json",
        callback = function(args)
            local bufnr = args.buf
            if timers[bufnr] then
                vim.uv.timer_stop(timers[bufnr])
            end
            timers[bufnr] = vim.uv.new_timer()
            vim.uv.timer_start(timers[bufnr], 300, 0, function()
                timers[bufnr] = nil
                vim.schedule(function()
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        M.validate_buffer(bufnr)
                    end
                end)
            end)
        end,
    })

    -- Clean up timer on buffer delete
    vim.api.nvim_create_autocmd("BufDelete", {
        group = group,
        pattern = "*/.orch/*.json",
        callback = function(args)
            if timers[args.buf] then
                vim.uv.timer_stop(timers[args.buf])
                timers[args.buf] = nil
            end
            -- Clear diagnostics
            vim.diagnostic.reset(nil, args.buf)
        end,
    })

    -- Update virtual text on cursor hold (less frequent)
    vim.api.nvim_create_autocmd("CursorHold", {
        group = group,
        pattern = "*/.orch/run_configurations.json",
        callback = function(args)
            M.show_virtual_text(args.buf)
        end,
    })
end

return M