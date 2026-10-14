-- OrchLaunch — Neovim run/debug configuration plugin.
--
-- Public entry point. `setup()` registers commands, watches for directory
-- changes and loads the `.orch` project containing the current directory when
-- one is present. Everything else is reachable through the user commands or
-- the modules (`state`, `runner`, `ui`).

local commands = require("orchlaunch.commands")
local project = require("orchlaunch.project")
local state = require("orchlaunch.state")

local M = {}

local autocmds_installed = false

--- Loads (or reloads) the `.orch` project that contains `root`.
---
--- Returns nil and resets the current project when none is found.
---@param root? string
---@return OrchState?
function M.load(root)
    root = root or vim.fn.getcwd()
    local found = project.locate(root)

    if not found then
        state.reset()
        return nil
    end

    return state.setup(found)
end

--- @param opts? { root?: string }
local function install_autocmds()
    if autocmds_installed then
        return
    end
    autocmds_installed = true

    vim.api.nvim_create_autocmd("DirChanged", {
        group = vim.api.nvim_create_augroup("OrchLaunch", { clear = true }),
        callback = function()
            M.load(vim.fn.getcwd())
        end,
    })
end

---@class OrchSetupOptions
---@field root? string Workspace root to search for `.orch`.
---@field silent? boolean Do not warn when no project is found.

--- Registers commands and loads the project containing `opts.root`
--- (defaults to the current directory).
---@param opts? OrchSetupOptions
---@return OrchState?
function M.setup(opts)
    opts = opts or {}
    commands.register()
    install_autocmds()

    local loaded = M.load(opts.root)
    if not loaded and not opts.silent then
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

--- Opens the Run/Debug configurations browser.
function M.open()
    require("orchlaunch.ui.browser").open()
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
    local created = project.create(root)
    local loaded = state.setup(root)

    local verb = created and "created" or "loaded existing"
    vim.notify(("[orchlaunch] %s .orch project at %s"):format(verb, root), vim.log.levels.INFO)

    return loaded
end

do
  local ok, au = pcall(vim.api.nvim_create_autocmd, {"ColorScheme", "VimEnter"}, {
    pattern = "*",
    callback = function()
      pcall(function() require("orchlaunch.ui").apply_theme() end)
    end,
  })
end

return M
