-- fibrous breakpoints manager: render, jump and delete.
--
-- Drives the panel the way a user does (cursor on a chip + <CR>) over the real
-- nvim-dap breakpoint store. No adapter/session is needed. Skips without
-- nvim-dap or fibrous.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local dap_root
do
    local roots = {}
    if vim.env.ORCHLAUNCH_DEPS and vim.env.ORCHLAUNCH_DEPS ~= "" then
        roots[#roots + 1] = vim.env.ORCHLAUNCH_DEPS
    end
    roots[#roots + 1] = vim.fn.stdpath("data") .. "/lazy"
    roots[#roots + 1] = vim.fn.stdpath("data") .. "/site/pack/deps/start"
    roots[#roots + 1] = vim.fn.stdpath("data") .. "/site/pack/core/opt"
    for _, root in ipairs(roots) do
        if vim.fn.isdirectory(root .. "/nvim-dap") == 1 then
            dap_root = root .. "/nvim-dap"
            break
        end
    end
end

local missing = {}
if not dap_root then
    missing[#missing + 1] = "nvim-dap"
end
if not (pcall(require, "fibrous")) then
    missing[#missing + 1] = "fibrous"
end
if #missing > 0 then
    print("SKIP  fibrous breakpoints manager: missing " .. table.concat(missing, ", "))
    h.done("fibrous breakpoints manager (skipped)")
    return
end

vim.opt.rtp:append(dap_root)
require("dap")

vim.o.columns = 140
vim.o.lines = 30

local root = h.tempdir()
h.write(root .. "/prog.cpp", [[
int zero() { return 0; }
int one() { return 1; }
int two() { return 2; }
]])

local orch = require("orchlaunch")
orch.create_project(root)

local breakpoints = require("orchlaunch.breakpoints")
breakpoints.set_at("prog.cpp", 1, { condition = "x > 2" })
breakpoints.set_at("prog.cpp", 3)

local ui = require("orchlaunch.ui.fibrous.breakpoints")
local handle = ui.open()
h.check("manager mounted", handle ~= nil and vim.api.nvim_win_is_valid(handle.winid))
if not handle then
    breakpoints.clear()
    h.done("fibrous breakpoints manager")
    return
end

local function screen()
    return table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
end

local function press(label)
    local buf_lines = vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)
    for i, line in ipairs(buf_lines) do
        local col = line:find(label, 1, true)
        if col then
            vim.api.nvim_set_current_win(handle.winid)
            vim.api.nvim_win_set_cursor(handle.winid, { i, col - 1 })
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
            return true
        end
    end
    return false
end

local text = screen()
h.contains("title with count", text, "Breakpoints — 2")
h.contains("first breakpoint rendered", text, "prog.cpp:1")
h.contains("condition rendered", text, "x > 2")
h.contains("second breakpoint rendered", text, "prog.cpp:3")
h.contains("condition button", text, "[cond]")
h.contains("delete button", text, "[x]")

-- Jump: pressing the first breakpoint's label opens the file in a normal window.
h.check("jump button pressed", press("prog.cpp:1"))
vim.wait(300, function()
    return false
end)
local jumped = false
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_buf_get_name(buf):find("prog.cpp", 1, true) then
            jumped = true
        end
    end
end
h.check("jump revealed prog.cpp in a normal window", jumped)

-- Delete: pressing the first row's [x] removes that breakpoint.
h.check("delete button pressed", press("[x]"))
h.check("row disappears after delete", vim.wait(3000, function()
    return screen():find("Breakpoints — 1", 1, true) ~= nil
end), screen())

ui.close()
breakpoints.clear()

h.done("fibrous breakpoints manager (nvim-dap + fibrous)")
