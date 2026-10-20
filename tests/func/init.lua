-- Functional-test bootstrap, run inside a real terminal (tmux).
--
-- The driver (run.sh) sets a handful of env vars and launches:
--
--   nvim -u tests/func/init.lua
--
-- This file puts the plugin and its dependencies on the runtimepath, sets up a
-- throwaway project, opens the fibrous CMake profile editor and records every
-- mode/window transition to $ORCH_FUNC_LOG. The driver drives the editor with
-- real keystrokes and asserts against that log and the captured screen.
--
-- The editor is opened on VimEnter: opening it during startup would lose focus
-- to the initial window when nvim finishes booting (only the terminal reveals
-- this, hence the functional suite).
--
-- <F6> is a debug probe (never pressed by the tests themselves): it logs the
-- current buffer/window, whether the field <Tab> map is present there, and the
-- field count. Handy when a keystroke behaves differently in the terminal.

local plugin = assert(vim.env.ORCH_FUNC_PLUGIN, "ORCH_FUNC_PLUGIN is not set")
local deps = vim.env.ORCH_FUNC_DEPS
local root = vim.env.ORCH_FUNC_ROOT or vim.fn.getcwd()
local log = vim.env.ORCH_FUNC_LOG

vim.opt.runtimepath:append(plugin)
if deps and deps ~= "" then
    vim.opt.runtimepath:append(deps .. "/fibrous.nvim")
end

vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.updatetime = 50

local handle

local function append(line)
    if not log then
        return
    end
    local f = io.open(log, "a")
    if f then
        f:write(line .. "\n")
        f:close()
    end
end

local function probe()
    if not (handle and vim.api.nvim_win_is_valid(handle.winid)) then
        append("probe no-editor")
        return
    end
    local buf = vim.api.nvim_get_current_buf()
    local tab = false
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "i")) do
        if m.lhs == "<Tab>" then
            tab = true
            break
        end
    end
    local fields = 0
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.w[win].fibrous_anchor == handle.winid then
            fields = fields + 1
        end
    end
    append(
        ("probe buf=%d win=%d root=%d mode=%s tab=%s fields=%d"):format(
            buf,
            vim.api.nvim_get_current_win(),
            handle.winid,
            vim.api.nvim_get_mode().mode,
            tostring(tab),
            fields
        )
    )
end

local function setup()
    local orch = require("orchlaunch")
    local state = require("orchlaunch.state")

    orch.create_project(root)
    state.add_toolchain({ name = "Clang", c = "clang", cxx = "clang++" })
    state.save()

    handle = require("orchlaunch.ui.fibrous.cmake_profile").open(nil, function() end)
    vim.wait(300)
    handle.focus()
    vim.g.orch_func_root_win = handle.winid
    append(("open root=%d win=%d"):format(handle.winid, vim.api.nvim_get_current_win()))

    vim.api.nvim_create_autocmd("ModeChanged", {
        callback = function()
            append("mode=" .. vim.v.event.new_mode)
        end,
    })
    vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
        callback = function()
            append(("win=%d buf=%d root=%d"):format(
                vim.api.nvim_get_current_win(),
                vim.api.nvim_get_current_buf(),
                handle.winid
            ))
        end,
    })
    vim.keymap.set({ "n", "i" }, "<F6>", probe, { silent = true })
end

vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function()
        local ok, err = pcall(setup)
        if not ok then
            append("error " .. tostring(err))
            print("ORCH_FUNC_INIT_ERROR: " .. tostring(err))
        end
    end,
})
