vim.opt.rtp:append("/home/olokreaz/.config/nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui-components.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")
vim.opt.rtp:append("/home/olokreaz/.config/nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")

local config = require("orchlaunch.config")

local doc = {
    a = 1,
    rt = config.runtime({ x = 2 }),
    nested = { y = 3 },
}
local text = config.stringify(doc)
assert(text:find("a = 1"), "a missing")
assert(text:find("y = 3"), "nested y missing")
assert(not text:find("x = 2"), "runtime leaked")
assert(not text:find("_runtime"), "runtime key leaked")
print("OK")
