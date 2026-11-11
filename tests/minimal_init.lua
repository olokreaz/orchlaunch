-- Minimal, isolated Neovim configuration for OrchLaunch tests.
-- Invoke Neovim with NVIM_APPNAME=orch-test before sourcing this file.

local source = debug.getinfo(1, "S").source:sub(2)
if source:sub(1, 1) == "@" then
    source = source:sub(2)
end
local tests_dir = vim.fn.fnamemodify(source, ":p:h")
local plugin_root = vim.fn.fnamemodify(tests_dir, ":h")

vim.opt.loadplugins = false
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.rtp:append(plugin_root)

local deps_root = vim.env.ORCHLAUNCH_DEPS
if not deps_root or deps_root == "" then
    deps_root = vim.fn.stdpath("data") .. "/lazy"
end

for _, dependency in ipairs({ "plenary.nvim", "fibrous.nvim" }) do
    local path = deps_root .. "/" .. dependency
    if vim.fn.isdirectory(path) == 1 then
        vim.opt.rtp:append(path)
    end
end

-- Tests resolve `harness.lua` through package.path; do not source the user's
-- init.lua or load any plugin-manager configuration from the primary profile.
package.path = tests_dir .. "/?.lua;" .. package.path
