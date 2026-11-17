-- Functional bootstrap for the OrchLaunch menu, run inside a real terminal.
--
-- Mirrors what the user's config does (setup, <leader>o keymaps, which-key
-- group, lualine component) without loading the primary profile. The driver
-- (menu_run.sh) launches: nvim -u tests/func/menu_init.lua

local source = debug.getinfo(1, "S").source:sub(2)
local func_dir = vim.fn.fnamemodify(source, ":p:h")
dofile(func_dir .. "/../minimal_init.lua")

local plugin = assert(vim.env.ORCH_FUNC_PLUGIN, "ORCH_FUNC_PLUGIN is not set")
local deps = vim.env.ORCH_FUNC_DEPS
local root = assert(vim.env.ORCH_FUNC_ROOT, "ORCH_FUNC_ROOT is not set")

vim.opt.runtimepath:append(plugin)
if deps and deps ~= "" then
    vim.opt.runtimepath:append(deps .. "/fibrous.nvim")
end

vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.g.mapleader = " "
vim.o.timeoutlen = 300

-- Same as the user's config: setup, then the opt-in keymaps.
require("orchlaunch").setup({ root = root, silent = true })
require("orchlaunch.menu").setup_keymaps("<leader>o")

-- Statusline text, as lualine would render it.
vim.o.statusline = "%!v:lua.require'orchlaunch.menu'.statusline()"

-- Keep the buffer from being a plain empty one.
vim.cmd("enew")
