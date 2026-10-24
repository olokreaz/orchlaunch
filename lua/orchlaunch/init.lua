-- OrchLaunch — Neovim run/debug configuration plugin.
--
-- Public entry point. `setup()` registers commands, watches for directory
-- changes and loads the `.orch` project containing the current directory when
-- one is present. Everything else is reachable through the user commands or
-- the modules (`state`, `runner`, `ui`).

local commands = require("orchlaunch.commands")
local project = require("orchlaunch.project")
local state = require("orchlaunch.state")
local schemas = require("orchlaunch.schemas")
local edit = require("orchlaunch.edit")
local select = require("orchlaunch.select")

local M = {}

local autocmds_installed = false
local ui_autocmds_installed = false

--- Loads (or reloads) the `.orch` project that contains `root`.
---
--- Returns nil and resets the current project when none is found.
---@param root? string
---@return OrchState? loaded
---@return string? error
function M.load(root)
    root = root or vim.fn.getcwd()
    local found, orch_dir = project.locate(root)

    if not found then
        state.reset()
        return nil
    end

    local ok, loaded = pcall(state.setup, found, orch_dir)
    if not ok then
        state.reset()
        local message = tostring(loaded):gsub("^%[orchlaunch%]%s*", "")
        state.report_error(message)
        return nil, message
    end

    local breakpoints_ok, breakpoints_err = pcall(function()
        require("orchlaunch.breakpoints").load()
    end)
    if not breakpoints_ok then
        state.report_error(tostring(breakpoints_err))
    end
    return loaded
end

--- @param opts? { root?: string }
local function install_autocmds()
    if autocmds_installed then
        return
    end
    autocmds_installed = true

    local group = vim.api.nvim_create_augroup("OrchLaunch", { clear = true })

    vim.api.nvim_create_autocmd("DirChanged", {
        group = group,
        callback = function()
            M.load(vim.fn.getcwd())
        end,
    })

    local function reload_if_changed()
        if state.is_loaded() then
            state.reload_if_changed()
        end
    end

    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        callback = function(args)
            if not state.is_loaded() then
                return
            end
            if vim.fs.dirname(vim.fs.normalize(args.file)) == state.orch_dir() then
                reload_if_changed()
            end
        end,
    })

    vim.api.nvim_create_autocmd({ "FocusGained", "FileChangedShellPost" }, {
        group = group,
        callback = reload_if_changed,
    })

    vim.api.nvim_create_autocmd({ "ColorScheme", "VimEnter" }, {
        group = group,
        callback = function()
            pcall(function()
                require("orchlaunch.ui").apply_theme()
            end)
        end,
    })
end

---@class OrchSetupOptions
---@field root? string Workspace root to search for `.orch`.
---@field silent? boolean Do not warn when no project is found.
---@field jsonls? boolean Enable automatic JSON Schema registration with jsonls (default: true).
---@field write_schema_ref? boolean Write $schema reference to files on save (default: false).
---@field ui? { backend?: "buffer" | "fibrous", edit?: table, virtual_text?: boolean }

--- Registers commands and loads the project containing `opts.root`
--- (defaults to the current directory).
---@param opts? OrchSetupOptions
---@return OrchState?
function M.setup(opts)
    opts = opts or {}
    commands.register()
    install_autocmds()

    -- Setup JSON Schema integration
    schemas.setup(opts)

    -- Setup buffer-based editing UI
    edit.setup_autocmds()

    local loaded, load_err = M.load(opts.root)
    if not loaded and not opts.silent and not load_err then
        vim.notify("[orchlaunch] no .orch project found", vim.log.levels.WARN)
    end

    return loaded
end

---@return OrchState?
function M.get()
    if not state.is_loaded() then
        return nil
    end
    return state.get()
end

---@return OrchState
function M.state()
    return state.get()
end

--- Opens the Run/Debug configurations browser (uses configured UI backend).
function M.open()
    local backend = "buffer"
    local ok, cfg = pcall(function() return require("orchlaunch").config.ui end)
    if ok and cfg and cfg.backend then
        backend = cfg.backend
    end

    if backend == "fibrous" then
        local ok, fibrous = pcall(require, "orchlaunch.ui.fibrous.browser")
        if ok and fibrous then
            fibrous.open()
            return
        end
        vim.notify("[orchlaunch] fibrous not available, falling back to buffer UI", vim.log.levels.WARN)
    end

    -- Default: buffer-based browser using vim.ui.select
    select.select_and_run({ mode = "run" })
end

--- Opens the buffer-based configuration editor.
---@param file_type? "run_configurations" | "external_tools" | "toolchain" | "cmake_settings" | "breakpoints"
---@param entry_name? string
---@param opts? { window?: "split" | "vsplit" | "float" | "tab", fold_others?: boolean }
function M.edit(file_type, entry_name, opts)
    edit.open(file_type, entry_name, opts)
end

--- Creates a new configuration entry.
---@param config_type? "native" | "remote-debug" | "compound" | "external_tool" | "toolchain" | "cmake_profile"
function M.new(config_type)
    edit.new(config_type)
end

---@param name? string
---@return string?
function M.select(name)
    if not state.is_loaded() then
        return nil
    end

    if not name or name == "" then
        local active = require("orchlaunch.active")
        name = active.get(state.root())
    end

    if name and state.configuration(name) then
        require("orchlaunch.active").set(state.root(), name)
        return name
    end

    return nil
end

---@param name? string
---@param opts? { mode?: "run" | "debug" }
function M.run(name, opts)
    if name and name ~= "" then
        require("orchlaunch.runner").run(name, opts)
    else
        require("orchlaunch.runner").run_active(opts)
    end
end

---@param name? string
function M.debug(name)
    M.run(name, { mode = "debug" })
end

--- Creates (or loads) a `.orch` project at `root`.
---@param root? string
---@return OrchState?
function M.create_project(root)
    root = root or vim.fn.getcwd()
    local created, create_err = project.create(root)
    if created == nil then
        state.report_error(create_err or "failed to create .orch project")
        return nil
    end

    -- Pass the explicit `.orch` directory: `locate()` walks upwards and would
    -- otherwise load the parent project when `root` is nested inside one.
    local ok, loaded = pcall(state.setup, root, project.orch_dir(root))
    if not ok then
        state.report_error(tostring(loaded):gsub("^%[orchlaunch%]%s*", ""))
        return nil
    end

    local breakpoints_ok, breakpoints_err = pcall(function()
        require("orchlaunch.breakpoints").load()
    end)
    if not breakpoints_ok then
        state.report_error(tostring(breakpoints_err))
    end

    local verb = created and "created" or "loaded existing"
    vim.notify(("[orchlaunch] %s .orch project at %s"):format(verb, loaded.root), vim.log.levels.INFO)

    return loaded
end

--- Returns schema check information for :OrchLaunchCheck.
---@return table
function M.check_schemas()
    return schemas.check_info()
end

return M