-- Bootstrap a real native-debug session for the tmux/remote-expr e2e test.
-- The test driver supplies isolated project, fixture and dependency paths.
local source = debug.getinfo(1, "S").source:sub(2)
local func_dir = vim.fn.fnamemodify(source, ":p:h")
dofile(func_dir .. "/../minimal_init.lua")

local plugin = assert(vim.env.ORCH_FUNC_PLUGIN, "ORCH_FUNC_PLUGIN is not set")
local deps = assert(vim.env.ORCH_FUNC_DEPS, "ORCH_FUNC_DEPS is not set")
local root = assert(vim.env.ORCH_FUNC_ROOT, "ORCH_FUNC_ROOT is not set")

vim.opt.runtimepath:append(plugin)
vim.opt.runtimepath:append(deps .. "/nvim-dap")
vim.o.swapfile = false
vim.o.shadafile = "NONE"

local source_file = root .. "/main.cpp"
local program = root .. "/native_debug_fixture"
local break_line = 4
-- nvim-dap draws breakpoints with the DapBreakpoint sign; the minimal test
-- profile does not define it, so define it before setting any breakpoint.
vim.fn.sign_define("DapBreakpoint", { text = "B", texthl = "", linehl = "", numhl = "" })
local bufnr = vim.fn.bufadd(source_file)
vim.fn.bufload(bufnr)
require("dap.breakpoints").set({}, bufnr, break_line)
vim.cmd("edit " .. vim.fn.fnameescape(source_file))

require("orchlaunch").create_project(root)
require("orchlaunch.debug").start(nil, {
    type = "launch",
    name = "tmux native debug e2e",
    program = program,
    cwd = root,
})
