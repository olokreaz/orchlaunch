-- Integration tests: build diagnostics use the standard quickfix list (so
-- trouble.nvim/snacks.nvim/:copen render them) and the debugger UI is delegated
-- to nvim-dap-view/nvim-dap-ui when present.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local integrations = require("orchlaunch.integrations")

local root = h.tempdir()
local build = root .. "/build"
h.write(root .. "/src/a.c", "int main(void) { return 0; }\n")
vim.fn.mkdir(build, "p")

vim.fn.setqflist({})

local previous = vim.fn.getcwd()
local count, errors = integrations.quickfix(
    "OrchLaunch: CMake build",
    table.concat({
        "ninja: no work to do",
        "../src/a.c:3:5: error: expected ';'",
        "../src/a.c:7: warning: unused variable",
        "FAILED: CMakeFiles/hello",
    }, "\n"),
    build
)

h.eq("two diagnostics parsed", count, 2)
h.eq("one error counted", errors, 1)
h.eq("cwd restored", vim.fn.getcwd(), previous)

local qf = vim.fn.getqflist()
h.eq("only parsed diagnostics kept", #qf, 2)
h.eq("first diagnostic line", qf[1] and qf[1].lnum, 3)
h.eq("first diagnostic type", qf[1] and qf[1].type, "e")
h.eq("second diagnostic line", qf[2] and qf[2].lnum, 7)
h.eq("second diagnostic type", qf[2] and qf[2].type, "w")
h.contains("relative path resolved against build dir", qf[1] and vim.fn.bufname(qf[1].bufnr), "src/a.c")
h.eq("quickfix title", vim.fn.getqflist({ title = 1 }).title, "OrchLaunch: CMake build")

local clean = integrations.quickfix("OrchLaunch: CMake build", "all good\n", build)
h.eq("successful build clears diagnostics", clean, 0)
h.eq("quickfix list emptied", #vim.fn.getqflist(), 0)
h.eq("cwd still restored", vim.fn.getcwd(), previous)

h.eq("no external debugger UI in the test env", integrations.debugger_ui(), false)

h.done("integrations")
